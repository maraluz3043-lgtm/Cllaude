#!/usr/bin/env python3
"""Exporta la geometría del lugar .rbxl a un módulo Lua de datos para el simulador de pruebas.

Uso: python3 tools/exportar_mapa_sim.py <COLEGIO_JEAN_PIAGET.rbxl> [salida.lua]
  salida por defecto: tools/simulacion/datos/mapa_rbxl.lua (no se versiona: lo genera cada desarrollador
  a partir de su copia del lugar).

Requiere el paquete Python 'zstandard' (pip install zstandard) y el lector tools/rbxl_lector.py.

Formato de salida (Lua 5.3/Luau):
  return {
    raiz = <id de Workspace>,
    nodos = {
      { id, padre, "Clase", "Nombre", props },   -- props: tabla opcional
      ...
    }
  }
props de BaseParts: p = {x,y,z}, r = {9 componentes} (omitido si es identidad), s = {sx,sy,sz},
t = Transparency (omitido si 0), c = CanCollide (omitido si true), a = Anchored (omitido si true).
Se exportan: Workspace y todos sus descendientes de clases geométricas o contenedoras
(Model, Folder, BasePart y derivados, Seat, VehicleSeat, SpawnLocation, Sound, ClickDetector,
SurfaceGui, TextLabel con su texto), más los servicios raíz relevantes (vacíos).
"""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rbxl_lector

BASEPARTS = {'Part', 'MeshPart', 'UnionOperation', 'WedgePart', 'CornerWedgePart', 'TrussPart', 'Seat', 'VehicleSeat', 'SpawnLocation', 'NegateOperation', 'IntersectOperation', 'PartOperation'}
CONTENEDORES = {'Model', 'Folder', 'Workspace', 'Terrain', 'Camera'}
OTRAS = {'Sound', 'ClickDetector', 'SurfaceGui', 'TextLabel', 'Decal', 'Texture', 'ProximityPrompt', 'StringValue', 'BoolValue', 'NumberValue'}
IDENT = (1, 0, 0, 0, 1, 0, 0, 0, 1)

def lua_str(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '') + '"'

def num(n):
    if abs(n) < 1e-6:
        return '0'
    s = ('%.4f' % n).rstrip('0').rstrip('.')
    return s if s not in ('-0', '') else '0'

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, 'simulacion', 'datos', 'mapa_rbxl.lua')
    meta, inst, _ = rbxl_lector.parse(src)
    ws = next(r for r, it in inst.items() if it['class'] == 'Workspace')
    # recorrido en orden padre→hijo para que el cargador cree los padres antes
    orden = []
    pila = [ws]
    while pila:
        r = pila.pop()
        it = inst[r]
        cl = it['class']
        if r != ws and cl not in BASEPARTS and cl not in CONTENEDORES and cl not in OTRAS:
            continue
        orden.append(r)
        for c in reversed(it['children']):
            pila.append(c)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, 'w', encoding='utf-8') as f:
        f.write('-- GENERADO por tools/exportar_mapa_sim.py desde %s. Solo para el simulador de pruebas.\n' % os.path.basename(src))
        f.write('local N = {}\n')
        f.write('local function n(...) N[#N + 1] = { ... } end\n')
        for r in orden:
            it = inst[r]
            cl = it['class']
            p = it['props']
            nombre = p.get('Name', cl) or cl
            padre = it['parent'] if r != ws else -1
            props = []
            if cl in BASEPARTS:
                cf = p.get('CFrame')
                sz = p.get('size') or p.get('Size')
                if cf:
                    props.append('p={%s,%s,%s}' % tuple(num(v) for v in cf['pos']))
                    rot = tuple(cf['rot'])
                    if any(abs(a - b) > 1e-5 for a, b in zip(rot, IDENT)):
                        props.append('r={%s}' % ','.join(num(v) for v in rot))
                if sz:
                    props.append('s={%s,%s,%s}' % tuple(num(v) for v in sz))
                tr = p.get('Transparency')
                if tr:
                    props.append('t=%s' % num(tr))
                if p.get('CanCollide') is False:
                    props.append('c=false')
                if p.get('Anchored') is False:
                    props.append('a=false')
            elif cl == 'TextLabel':
                t = p.get('Text') or ''
                if t:
                    props.append('x=%s' % lua_str(t[:120]))
            elif cl == 'Sound':
                sid = p.get('SoundId') or ''
                if isinstance(sid, str) and sid:
                    props.append('x=%s' % lua_str(sid))
            f.write('n(%d,%d,"%s",%s%s)\n' % (r, padre, cl, lua_str(nombre), (',{' + ','.join(props) + '}') if props else ''))
        f.write('return { raiz = %d, nodos = N }\n' % ws)
    print('exportados', len(orden), 'nodos ->', dst, '(%d KB)' % (os.path.getsize(dst) // 1024))

if __name__ == '__main__':
    main()
