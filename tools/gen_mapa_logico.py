#!/usr/bin/env python3
"""Genera src/ReplicatedStorage/ColegioRP/Shared/MapaLogico.lua a partir de mapa/zonas.json.

Uso: python3 tools/gen_mapa_logico.py
"""
import json, os, sys

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ORIGEN = os.path.join(RAIZ, 'mapa', 'zonas.json')
DESTINO = os.path.join(RAIZ, 'src', 'ReplicatedStorage', 'ColegioRP', 'Shared', 'MapaLogico.lua')

def lua_str(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'

def v3(v):
    return 'Vector3.new(%s, %s, %s)' % (fmt(v[0]), fmt(v[1]), fmt(v[2]))

def fmt(n):
    if isinstance(n, bool):
        return 'true' if n else 'false'
    if isinstance(n, int):
        return str(n)
    s = ('%.3f' % n).rstrip('0').rstrip('.')
    return s if s not in ('', '-0') else '0'

def lua_list_str(items, indent):
    return '{ ' + ', '.join(lua_str(x) for x in items) + ' }'

def main():
    with open(ORIGEN, encoding='utf-8') as f:
        data = json.load(f)
    out = []
    P = out.append
    P('-- GENERADO AUTOMÁTICAMENTE por tools/gen_mapa_logico.py a partir de mapa/zonas.json. No editar a mano.')
    P('-- Mapa lógico del lugar COLEGIO_JEAN_PIAGET.rbxl: zonas reales con coordenadas auditadas (studs).')
    P('local MapaLogico = {}')
    P('MapaLogico.Version = %d' % data['version'])
    P('MapaLogico.Pisos = {')
    for k, v in data['pisos'].items():
        P('\t[%s] = { SueloY = %s, SpawnY = %s },' % (k, fmt(v['sueloY']), fmt(v['spawnY'])))
    P('}')
    P('MapaLogico.Zonas = {}')
    P('MapaLogico.OrdenZonas = {}')
    P('MapaLogico.Aulas = {}')
    aula_tipos = ('aula', 'aula_especial', 'aula_pc')
    for z in data['zonas']:
        P('MapaLogico.Zonas[%s] = {' % lua_str(z['id']))
        P('\tId = %s,' % lua_str(z['id']))
        P('\tNombre = %s,' % lua_str(z['nombre']))
        P('\tTipo = %s,' % lua_str(z['tipo']))
        P('\tPiso = %d,' % z['piso'])
        P('\tCentro = %s,' % v3(z['centro']))
        P('\tTamano = %s,' % v3(z['tamano']))
        sp = z.get('spawn')
        if sp:
            P('\tSpawn = { Punto = %s, Estado = %s, Cargos = %s },' % (v3(sp['punto']), lua_str(sp['estado']), lua_list_str(sp.get('cargos', []), 2)))
        P('\tAsientos = %d,' % z.get('asientos', 0))
        tb = z.get('tablero')
        if tb:
            P('\tTablero = { Centro = %s, Normal = %s },' % (v3(tb['centro']), v3(tb['normal'])))
        if z.get('puestoDocente'):
            P('\tPuestoDocente = %s,' % v3(z['puestoDocente']))
        if z.get('pcs'):
            P('\tPCs = { %s },' % ', '.join(v3(p) for p in z['pcs']))
        if z.get('estacionesPC'):
            P('\tEstacionesPC = { %s },' % ', '.join(v3(p) for p in z['estacionesPC']))
        if z.get('estaciones'):
            P('\tEstaciones = { %s },' % ', '.join('%s = %s' % (k, v3(v)) for k, v in z['estaciones'].items()))
        if z.get('mostrador'):
            P('\tMostrador = { Centro = %s, Frente = %s },' % (v3(z['mostrador']['centro']), v3(z['mostrador']['frente'])))
        if z.get('filaEstudiantes'):
            P('\tFilaEstudiantes = { Centro = %s, Tamano = %s },' % (v3(z['filaEstudiantes']['centro']), v3(z['filaEstudiantes']['tamano'])))
        if z.get('escenario'):
            P('\tEscenario = %s,' % v3(z['escenario']))
        fb = z.get('futbol')
        if fb:
            P('\tFutbol = {')
            P('\t\tBalon = %s,' % v3(fb['balon']))
            P('\t\tArcoA = { Centro = %s, Tamano = %s },' % (v3(fb['arcoA']['centro']), v3(fb['arcoA']['tamano'])))
            P('\t\tArcoB = { Centro = %s, Tamano = %s },' % (v3(fb['arcoB']['centro']), v3(fb['arcoB']['tamano'])))
            P('\t\tLimites = { Min = %s, Max = %s },' % (v3(fb['limites']['min']), v3(fb['limites']['max'])))
            P('\t},')
        ob = z.get('objetos')
        if ob:
            P('\tObjetos = {')
            for k, lst in ob.items():
                P('\t\t%s = { %s },' % (k.capitalize(), ', '.join(v3(p) for p in lst)))
            P('\t},')
        if z.get('puertas'):
            P('\tPuertas = %s,' % lua_list_str(z['puertas'], 2))
        P('\tEvidencia = {')
        for e in z.get('evidencia', []):
            P('\t\t%s,' % lua_str(e))
        P('\t},')
        P('\tNotas = %s,' % lua_str(z.get('notas', '')))
        P('}')
        P('table.insert(MapaLogico.OrdenZonas, %s)' % lua_str(z['id']))
        if z['tipo'] in aula_tipos:
            P('table.insert(MapaLogico.Aulas, %s)' % lua_str(z['id']))
    P('MapaLogico.Puertas = {}')
    P('MapaLogico.OrdenPuertas = {}')
    for p in data['puertas']:
        P('MapaLogico.Puertas[%s] = { Id = %s, Ruta = %s, Hoja = %s, Centro = %s, Zona = %s, Modo = %s, CargosBloqueo = %s }' % (
            lua_str(p['id']), lua_str(p['id']), lua_str(p['ruta']), lua_str(p['hoja']) if p.get('hoja') else 'nil', v3(p['centro']), lua_str(p['zona']), lua_str(p['modo']), lua_list_str(p.get('cargosBloqueo', []), 1)))
        P('table.insert(MapaLogico.OrdenPuertas, %s)' % lua_str(p['id']))
    so = data['spawnOriginal']
    P('MapaLogico.SpawnOriginal = { Ruta = %s, Posicion = %s, Neutral = %s }' % (lua_str(so['ruta']), v3(so['posicion']), fmt(so['neutral'])))
    P('')
    P('-- Utilidades mínimas (las completas están en Util/Zones)')
    P('function MapaLogico.Zona(id)')
    P('\treturn MapaLogico.Zonas[id]')
    P('end')
    P('')
    P('function MapaLogico.ZonasPorTipo(tipo)')
    P('\tlocal lista = {}')
    P('\tfor _, id in ipairs(MapaLogico.OrdenZonas) do')
    P('\t\tlocal z = MapaLogico.Zonas[id]')
    P('\t\tif z.Tipo == tipo then table.insert(lista, z) end')
    P('\tend')
    P('\treturn lista')
    P('end')
    P('')
    P('return MapaLogico')
    os.makedirs(os.path.dirname(DESTINO), exist_ok=True)
    with open(DESTINO, 'w', encoding='utf-8') as f:
        f.write('\n'.join(out) + '\n')
    print('escrito', DESTINO, len(out), 'líneas')

if __name__ == '__main__':
    main()
