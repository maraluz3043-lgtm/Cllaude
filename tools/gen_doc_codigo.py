#!/usr/bin/env python3
"""Genera docs/C_Codigo.md: índice del código Luau por archivo (ruta en el Explorer, tipo, líneas,
descripción tomada del encabezado del propio archivo) + remotos y handlers detectados.

Uso: python3 tools/gen_doc_codigo.py
"""
import os, re

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(RAIZ, 'src')
DESTINO = os.path.join(RAIZ, 'docs', 'C_Codigo.md')

def clase_y_nombre(archivo):
    if archivo.endswith('.server.lua'):
        return 'Script', archivo[:-11]
    if archivo.endswith('.client.lua'):
        return 'LocalScript', archivo[:-11]
    if archivo.endswith('.lua'):
        return 'ModuleScript', archivo[:-4]
    return None, archivo

def descripcion(fuente):
    """Primer bloque de comentario del archivo, compactado a 1-3 frases."""
    texto = ''
    m = re.match(r'\s*--\[(=*)\[(.*?)\]\1\]', fuente, re.S)
    if m:
        texto = m.group(2)
    else:
        lineas = []
        for l in fuente.splitlines():
            s = l.strip()
            if s.startswith('--'):
                lineas.append(s.lstrip('-').strip())
            elif s == '' and not lineas:
                continue
            else:
                break
        texto = '\n'.join(lineas)
    partes = []
    for l in texto.splitlines():
        s = l.strip().strip('=').strip()
        if not s:
            continue
        low = s.lower()
        if low.startswith('ruta') or low.startswith('tipo') or 'explorer' in low[:20]:
            continue
        partes.append(s)
    d = ' '.join(partes)
    d = re.sub(r'\s+', ' ', d)
    if len(d) > 320:
        d = d[:317].rsplit(' ', 1)[0] + '…'
    return d.replace('|', '\\|')

def main():
    filas = []
    registros = {}
    for base, dirs, files in os.walk(SRC):
        dirs.sort()
        for f in sorted(files):
            clase, nombre = clase_y_nombre(f)
            if not clase:
                continue
            p = os.path.join(base, f)
            rel = os.path.relpath(p, SRC)
            ruta_explorer = os.path.dirname(rel).replace(os.sep, '.')
            ruta_explorer = (ruta_explorer + '.' if ruta_explorer else '') + nombre
            ruta_explorer = ruta_explorer.replace('StarterPlayer.StarterPlayerScripts', 'StarterPlayer.StarterPlayerScripts')
            fuente = open(p, encoding='utf-8').read()
            nlin = fuente.count('\n') + 1
            filas.append((ruta_explorer, clase, nlin, os.path.relpath(p, RAIZ), descripcion(fuente)))
            for m in re.finditer(r'Registrar\(\s*"([A-Za-z]+)"', fuente):
                registros.setdefault(m.group(1), []).append(nombre)
    # remotos del contrato
    rc = os.path.join(SRC, 'ReplicatedStorage', 'ColegioRP', 'Shared', 'RemoteContracts.lua')
    remotos = []
    if os.path.exists(rc):
        texto = open(rc, encoding='utf-8').read()
        m = re.search(r'Nombres\s*=\s*\{(.*?)\}', texto, re.S)
        if m:
            remotos = re.findall(r'"([A-Za-z]+)"', m.group(1))
    out = []
    P = out.append
    P('# C. Código Luau por archivo')
    P('')
    P('El código completo y listo para copiar está en [`src/`](../src) (un archivo por instancia) y empaquetado en `dist/ColegioRP.rbxmx` y `dist/Instalador_ColegioRP.lua`. Convención: `Nombre.lua` = **ModuleScript**, `Nombre.server.lua` = **Script**, `Nombre.client.lua` = **LocalScript**; cada carpeta es un **Folder**. La ruta del Explorer es la ruta del archivo bajo `src/`.')
    P('')
    P('Contrato de diseño (APIs, remotos, esquemas, permisos, ciclo de vida): [`docs/ARQUITECTURA.md`](ARQUITECTURA.md). Este índice se genera con `python3 tools/gen_doc_codigo.py`.')
    P('')
    total = sum(f[2] for f in filas)
    P('**%d archivos · %d líneas de Luau.**' % (len(filas), total))
    P('')
    grupos = [('ReplicatedFirst', 'Carga e intro'), ('ReplicatedStorage', 'Compartido (cliente y servidor)'), ('ServerScriptService', 'Servidor'), ('StarterPlayer', 'Cliente')]
    for pref, titulo in grupos:
        sel = [f for f in filas if f[0].startswith(pref)]
        if not sel:
            continue
        P('## %s — `%s`' % (titulo, pref))
        P('')
        P('| Ruta en el Explorer | Tipo | Líneas | Descripción | Archivo |')
        P('|---|---|---|---|---|')
        for ruta, clase, nlin, archivo, desc in sel:
            P('| `%s` | %s | %d | %s | [`%s`](../%s) |' % (ruta, clase, nlin, desc, os.path.basename(archivo), archivo))
        P('')
    if remotos:
        P('## Remotos (`ReplicatedStorage.ColegioRP.Remotes`, creados por `RemoteService` al arrancar)')
        P('')
        P('| Remoto | Handler registrado en |')
        P('|---|---|')
        for r in remotos:
            P('| `%s` | %s |' % (r, ', '.join('`%s`' % h for h in sorted(set(registros.get(r, [])))) or '— (servidor→cliente o sin handler)'))
        P('')
        P('Esquemas, límites de frecuencia y permisos de cada remoto: `Shared/RemoteContracts` y §5 de la arquitectura.')
        P('')
    P('## Atributos y tags que el sistema añade a objetos existentes (reversibles)')
    P('')
    P('| Dónde | Atributo / tag | Lo pone |')
    P('|---|---|---|')
    P('| `Seat` de aula | atributo `RoomId`, tag `ColegioRP_Asiento` | MapService |')
    P('| Monitor de PC | atributo `PcId`, tag `ColegioRP_PantallaPC` | MapService |')
    P('| Hoja de puerta | atributos `PuertaId`, `Estado`; tag `ColegioRP_Puerta`; `ProximityPrompt` hijo | DoorService |')
    P('| Lavamanos / inodoro | atributo `ObjetoId`, tag `ColegioRP_Bano`; `ProximityPrompt` hijo | BathroomService |')
    P('| Modelos pesados (ventiladores, espejo, árboles) | tag `ColegioRP_Decoracion` | MapService |')
    P('| `Player` | atributos `Cargo`, `Equipo`, `Salon`, `Silenciado`, `Atendido`, `EquipoFutbol`, `Sospechoso` | RoleService, ModerationService, StaffService, FootballService, RemoteService |')
    P('')
    os.makedirs(os.path.dirname(DESTINO), exist_ok=True)
    with open(DESTINO, 'w', encoding='utf-8') as f:
        f.write('\n'.join(out) + '\n')
    print('escrito', DESTINO, len(filas), 'archivos', total, 'líneas')

if __name__ == '__main__':
    main()
