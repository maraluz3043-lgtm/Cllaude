#!/usr/bin/env python3
"""Inserta los scripts de src/ dentro de un lugar binario de Roblox (.rbxl) sin tocar el mapa.

Uso:  python3 tools/inyectar_rbxl.py <lugar_original.rbxl> <salida.rbxl>

Solo se reescriben los bloques INST/PROP de Folder, Script, LocalScript y ModuleScript (añadiendo las
instancias nuevas al final), el bloque PRNT y la cabecera. El resto del archivo se copia byte a byte.
Si ya existe una carpeta ColegioRP en el lugar, se aborta para no duplicar.
"""
import sys, os, struct, uuid
import zstandard

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build import leer_arbol  # noqa: E402

CLASES = ('Folder', 'Script', 'LocalScript', 'ModuleScript')


# ---------- utilidades del formato ----------
def leer_bloques(data):
    assert data[:8] == b'<roblox!', 'no es un archivo binario de Roblox'
    off = 32
    bloques = []
    dctx = zstandard.ZstdDecompressor()
    while off + 16 <= len(data):
        nombre = data[off:off + 4]
        clen, ulen, _ = struct.unpack_from('<iii', data, off + 4)
        cab = data[off:off + 16]
        off += 16
        crudo = data[off:off + (clen if clen else ulen)]
        off += clen if clen else ulen
        if clen == 0:
            cuerpo = crudo
        elif crudo[:4] == b'\x28\xb5\x2f\xfd':
            cuerpo = dctx.decompress(crudo, max_output_size=ulen)
        else:
            import lz4.block
            cuerpo = lz4.block.decompress(crudo, uncompressed_size=ulen)
        bloques.append({'nombre': nombre.rstrip(b'\x00').decode(), 'cuerpo': cuerpo, 'crudo': cab + crudo, 'cambiado': False})
        if nombre == b'END\x00':
            break
    return data[:32], bloques


def empaquetar(nombre, cuerpo):
    comp = zstandard.ZstdCompressor(level=9).compress(cuerpo)
    return nombre.encode().ljust(4, b'\x00') + struct.pack('<iii', len(comp), len(cuerpo), 0) + comp


def desintercalar(b, n, w):
    return [bytes(b[k * n + i] for k in range(w)) for i in range(n)]


def intercalar(filas, w):
    n = len(filas)
    out = bytearray(n * w)
    for i, f in enumerate(filas):
        for k in range(w):
            out[k * n + i] = f[k]
    return bytes(out)


def zz(v):
    return ((v << 1) ^ (v >> 31)) & 0xFFFFFFFF


def unzz(u):
    return (u >> 1) ^ -(u & 1)


def leer_refs(b, n):
    filas = desintercalar(b, n, 4)
    out, acc = [], 0
    for f in filas:
        acc += unzz(struct.unpack('>I', f)[0])
        out.append(acc)
    return out


def escribir_refs(refs):
    filas, prev = [], 0
    for r in refs:
        filas.append(struct.pack('>I', zz(r - prev)))
        prev = r
    return intercalar(filas, 4)


def leer_cadenas(b, n):
    out, off = [], 0
    for _ in range(n):
        l, = struct.unpack_from('<I', b, off)
        out.append(b[off + 4:off + 4 + l])
        off += 4 + l
    return out, b[off:]


def escribir_cadenas(lista):
    return b''.join(struct.pack('<I', len(s)) + s for s in lista)


ANCHO = {0x02: 1, 0x12: 4, 0x1B: 8, 0x1C: 4, 0x1F: 16, 0x21: 8, 0x03: 4}


# ---------- inyección ----------
def main(origen, destino):
    data = open(origen, 'rb').read()
    cabecera, bloques = leer_bloques(data)
    n_clases, n_inst = struct.unpack_from('<II', cabecera, 16)

    # Clases, referentes y nombres de todo el lugar.
    clase_de_id, refs_de_clase, inst_bloque = {}, {}, {}
    nombre_de, clase_de_ref = {}, {}
    for bl in bloques:
        b = bl['cuerpo']
        if bl['nombre'] == 'INST':
            cid, l = struct.unpack_from('<II', b, 0)
            cname = b[8:8 + l].decode()
            es_servicio = b[8 + l]
            n, = struct.unpack_from('<I', b, 9 + l)
            refs = leer_refs(b[13 + l:13 + l + 4 * n], n)
            clase_de_id[cid] = cname
            refs_de_clase[cid] = refs
            inst_bloque[cid] = (bl, es_servicio, b[13 + l + 4 * n:])
            for r in refs:
                clase_de_ref[r] = cname
        elif bl['nombre'] == 'PROP':
            cid, l = struct.unpack_from('<II', b, 0)
            if b[8:8 + l] == b'Name' and b[8 + l] == 0x01:
                nombres, _ = leer_cadenas(b[9 + l:], len(refs_de_clase[cid]))
                for r, s in zip(refs_de_clase[cid], nombres):
                    nombre_de[r] = s.decode('utf-8', 'replace')
    prnt = next(bl for bl in bloques if bl['nombre'] == 'PRNT')
    pb = prnt['cuerpo']
    n_prnt, = struct.unpack_from('<I', pb, 1)
    hijos = leer_refs(pb[5:5 + 4 * n_prnt], n_prnt)
    padres = leer_refs(pb[5 + 4 * n_prnt:5 + 8 * n_prnt], n_prnt)
    padre_de = dict(zip(hijos, padres))
    hijos_de = {}
    for h, p in zip(hijos, padres):
        hijos_de.setdefault(p, []).append(h)

    def buscar_hijo(padre, nombre):
        for h in hijos_de.get(padre, []):
            if nombre_de.get(h) == nombre:
                return h
        return None

    servicios = {clase_de_id[cid]: refs[0] for cid, refs in refs_de_clase.items() if inst_bloque[cid][1] == 1}
    id_de_clase = {v: k for k, v in clase_de_id.items()}
    for c in CLASES:
        assert c in id_de_clase, 'el lugar no tiene la clase ' + c

    # Instancias nuevas: (ref, clase, nombre, fuente, padre)
    nuevas = []
    siguiente = [max(clase_de_ref) + 1]

    def crear(nodo, padre):
        ref = siguiente[0]
        siguiente[0] += 1
        nuevas.append((ref, nodo['clase'], nodo['nombre'], nodo['fuente'], padre))
        for h in nodo['hijos']:
            crear(h, ref)

    for serv in leer_arbol():
        destino_ref = servicios.get(serv['nombre'])
        if destino_ref is None:
            print('aviso: el lugar no tiene el servicio', serv['nombre'], '- se omite')
            continue
        pendientes = [(serv, destino_ref)]
        while pendientes:
            nodo, padre = pendientes.pop()
            for h in nodo['hijos']:
                existente = buscar_hijo(padre, h['nombre'])
                if existente is not None and h['clase'] == 'Folder' and clase_de_ref[existente] not in CLASES:
                    pendientes.append((h, existente))  # contenedor propio de Roblox (StarterPlayerScripts)
                elif existente is not None:
                    sys.exit('ya existe %s en %s: desinstala la versión anterior primero' % (h['nombre'], nombre_de.get(padre)))
                else:
                    crear(h, padre)

    por_clase = {c: [x for x in nuevas if x[1] == c] for c in CLASES}

    # INST
    for c in CLASES:
        cid = id_de_clase[c]
        bl, es_servicio, resto = inst_bloque[cid]
        refs = refs_de_clase[cid] + [x[0] for x in por_clase[c]]
        nb = c.encode()
        bl['cuerpo'] = struct.pack('<I', cid) + struct.pack('<I', len(nb)) + nb + bytes([es_servicio]) + struct.pack('<I', len(refs)) + escribir_refs(refs) + resto
        bl['cambiado'] = True

    # PROP
    for bl in bloques:
        if bl['nombre'] != 'PROP':
            continue
        b = bl['cuerpo']
        cid, l = struct.unpack_from('<II', b, 0)
        c = clase_de_id.get(cid)
        if c not in CLASES or not por_clase[c]:
            continue
        prop = b[8:8 + l].decode()
        tipo = b[8 + l]
        datos = b[9 + l:]
        n = len(refs_de_clase[cid])
        extra = por_clase[c]
        if tipo == 0x01:
            lista, cola = leer_cadenas(datos, n)
            for (_, _, nombre, fuente, _) in extra:
                if prop == 'Name':
                    v = nombre.encode('utf-8')
                elif prop == 'Source':
                    v = (fuente or '').encode('utf-8')
                elif prop == 'ScriptGuid':
                    v = ('{' + str(uuid.uuid4()).upper() + '}').encode()
                else:
                    v = b''
                lista.append(v)
            nuevo = escribir_cadenas(lista) + cola
        elif tipo == 0x0C:  # Color3: 3 bloques de float intercalados; se copia el valor de la primera instancia
            partes = [desintercalar(datos[k * 4 * n:(k + 1) * 4 * n], n, 4) for k in range(3)]
            nuevo = b''.join(intercalar(p + [p[0]] * len(extra), 4) for p in partes) + datos[12 * n:]
        elif tipo in ANCHO:
            w = ANCHO[tipo]
            filas = desintercalar(datos[:w * n], n, w)
            for _ in extra:
                if tipo == 0x1F:
                    filas.append(os.urandom(16))  # UniqueId / HistoryId únicos
                elif tipo == 0x1C:
                    filas.append(filas[0])  # índice de SharedString (Tags vacíos) de la primera instancia
                else:
                    filas.append(bytes(w))  # false / 0 / Enum 0 (RunContext Legacy)
            nuevo = intercalar(filas, w) + datos[w * n:]
        else:
            sys.exit('tipo de propiedad no soportado %s.%s 0x%02x' % (c, prop, tipo))
        bl['cuerpo'] = b[:9 + l] + nuevo
        bl['cambiado'] = True

    # PRNT
    hijos2 = hijos + [x[0] for x in nuevas]
    padres2 = padres + [x[4] for x in nuevas]
    prnt['cuerpo'] = bytes([0]) + struct.pack('<I', len(hijos2)) + escribir_refs(hijos2) + escribir_refs(padres2)
    prnt['cambiado'] = True

    cab = bytearray(cabecera)
    struct.pack_into('<II', cab, 16, n_clases, n_inst + len(nuevas))
    salida = bytes(cab) + b''.join(empaquetar(bl['nombre'], bl['cuerpo']) if bl['cambiado'] else bl['crudo'] for bl in bloques)
    with open(destino, 'wb') as f:
        f.write(salida)
    print('instancias añadidas: %d (%s) -> %s (%d KB)' % (len(nuevas), ', '.join('%s=%d' % (c, len(por_clase[c])) for c in CLASES), destino, len(salida) // 1024))


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
