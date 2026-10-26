#!/usr/bin/env python3
"""Empaqueta src/ en entregables instalables en Roblox Studio.

Genera:
  dist/ColegioRP.rbxmx              -> modelo XML para "Insertar desde archivo" (contiene todo el paquete)
  dist/Instalador_ColegioRP.lua     -> script de un solo pegado para la Command Bar (crea e instala todo)
  dist/manifest.json                -> inventario de archivos, tipos, rutas de destino y tamaños

Convención de nombres en src (estilo Rojo):
  Nombre.lua         -> ModuleScript
  Nombre.server.lua  -> Script
  Nombre.client.lua  -> LocalScript
  carpeta            -> Folder

Uso: python3 tools/build.py
"""
import os, sys, json, hashlib, re, datetime

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(RAIZ, 'src')
DIST = os.path.join(RAIZ, 'dist')
HERR = os.path.join(RAIZ, 'herramientas')
NOMBRE_PAQUETE = 'ColegioRP_Paquete'
SERVICIOS_RAIZ = ['ReplicatedFirst', 'ReplicatedStorage', 'ServerScriptService', 'ServerStorage', 'StarterPlayer', 'StarterGui', 'Workspace']

def clase_de(nombre):
    if nombre.endswith('.server.lua'):
        return 'Script', nombre[:-len('.server.lua')]
    if nombre.endswith('.client.lua'):
        return 'LocalScript', nombre[:-len('.client.lua')]
    if nombre.endswith('.lua'):
        return 'ModuleScript', nombre[:-4]
    return None, nombre

def leer_arbol():
    """Devuelve una lista de nodos {ruta, clase, nombre, hijos, fuente} a partir de src."""
    def nodo_dir(path, nombre):
        hijos = []
        for entrada in sorted(os.listdir(path)):
            p = os.path.join(path, entrada)
            if os.path.isdir(p):
                hijos.append(nodo_dir(p, entrada))
            else:
                clase, nom = clase_de(entrada)
                if clase is None:
                    continue
                with open(p, encoding='utf-8') as f:
                    fuente = f.read()
                hijos.append({'clase': clase, 'nombre': nom, 'hijos': [], 'fuente': fuente, 'archivo': os.path.relpath(p, RAIZ)})
        return {'clase': 'Folder', 'nombre': nombre, 'hijos': hijos, 'fuente': None, 'archivo': None}
    raiz = []
    for serv in sorted(os.listdir(SRC)):
        p = os.path.join(SRC, serv)
        if os.path.isdir(p):
            raiz.append(nodo_dir(p, serv))
    return raiz

# ---------- rbxmx ----------
def xml_escape(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')

def cdata(s):
    # CDATA no puede contener ']]>': se parte en dos secciones.
    return '<![CDATA[' + s.replace(']]>', ']]]]><![CDATA[>') + ']]>'

_ref = [0]
def nuevo_ref():
    _ref[0] += 1
    return 'RBX%08d' % _ref[0]

def item_xml(nodo, nivel):
    ind = '\t' * nivel
    out = []
    out.append('%s<Item class="%s" referent="%s">' % (ind, nodo['clase'], nuevo_ref()))
    out.append('%s\t<Properties>' % ind)
    out.append('%s\t\t<string name="Name">%s</string>' % (ind, xml_escape(nodo['nombre'])))
    if nodo['clase'] in ('Script', 'LocalScript', 'ModuleScript'):
        if nodo['clase'] != 'ModuleScript':
            out.append('%s\t\t<bool name="Disabled">false</bool>' % ind)
        out.append('%s\t\t<ProtectedString name="Source">%s</ProtectedString>' % (ind, cdata(nodo['fuente'])))
    out.append('%s\t</Properties>' % ind)
    for h in nodo['hijos']:
        out.extend(item_xml(h, nivel + 1))
    out.append('%s</Item>' % ind)
    return out

def escribir_rbxmx(arbol, instalador_fuente, version):
    paquete = {'clase': 'Folder', 'nombre': NOMBRE_PAQUETE, 'hijos': [], 'fuente': None}
    # Instalador (ModuleScript) + LEEME (ModuleScript con instrucciones) + contenido por servicio
    paquete['hijos'].append({'clase': 'ModuleScript', 'nombre': 'Instalador', 'hijos': [], 'fuente': instalador_fuente})
    leeme = ('--[[ Colegio RP · Instituto Educativo Jean Piaget · Horizon Studios by Adrian · v%s\n'
             'Para instalar: con este modelo insertado en cualquier lugar (p. ej. Workspace), pega en la Command Bar:\n'
             '    require(workspace.%s.Instalador)()\n'
             'El instalador distribuye las carpetas a ReplicatedFirst, ReplicatedStorage, ServerScriptService y StarterPlayer,\n'
             'respalda cualquier versión anterior en ServerStorage/ColegioRP_Respaldos y elimina este paquete.\n'
             'Documentación: docs/D_Instalacion.md del repositorio. ]]\nreturn {}\n') % (version, NOMBRE_PAQUETE)
    paquete['hijos'].append({'clase': 'ModuleScript', 'nombre': 'LEEME', 'hijos': [], 'fuente': leeme})
    for serv in arbol:
        paquete['hijos'].append(serv)
    lineas = ['<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">',
              '\t<Meta name="ExplicitAutoJoints">true</Meta>', '\t<External>null</External>', '\t<External>nil</External>']
    lineas.extend(item_xml(paquete, 1))
    lineas.append('</roblox>')
    return '\n'.join(lineas) + '\n'

# ---------- instalador de un solo pegado ----------
def nivel_long_string(fuente):
    nivel = 1
    while (']' + '=' * nivel + ']') in fuente or ('[' + '=' * nivel + '[') in fuente:
        nivel += 1
    return nivel

def lua_long(fuente):
    n = nivel_long_string(fuente)
    eq = '=' * n
    # Un salto de línea inicial se omite en long strings: añadimos uno para preservar el contenido exacto.
    return '[' + eq + '[\n' + fuente + ']' + eq + ']'

def escribir_instalador_pegado(arbol, instalador_fuente, version):
    out = []
    P = out.append
    P('--[[ INSTALADOR DE UN SOLO PEGADO · Colegio RP v%s · Horizon Studios by Adrian' % version)
    P('     Pegar completo en la Command Bar de Roblox Studio (modo edición) y pulsar Enter.')
    P('     Crea el paquete con todos los scripts y lo instala (respalda versiones anteriores). ]]')
    P('local FUENTES = {}')
    def visitar(nodo, ruta):
        r = ruta + '/' + nodo['nombre'] if ruta else nodo['nombre']
        if nodo['clase'] == 'Folder':
            P('FUENTES[%s] = { clase = "Folder" }' % json.dumps(r, ensure_ascii=False))
            for h in nodo['hijos']:
                visitar(h, r)
        else:
            P('FUENTES[%s] = { clase = "%s", fuente = %s }' % (json.dumps(r, ensure_ascii=False), nodo['clase'], lua_long(nodo['fuente'])))
    P('FUENTES["Instalador"] = { clase = "ModuleScript", fuente = %s }' % lua_long(instalador_fuente))
    for serv in arbol:
        visitar(serv, '')
    P('')
    P('local ORDEN = {}')
    P('for ruta in pairs(FUENTES) do table.insert(ORDEN, ruta) end')
    P('table.sort(ORDEN, function(a, b) return #a < #b or (#a == #b and a < b) end)')
    P('local paquete = Instance.new("Folder")')
    P('paquete.Name = "%s"' % NOMBRE_PAQUETE)
    P('local nodos = {}')
    P('for _, ruta in ipairs(ORDEN) do')
    P('\tlocal info = FUENTES[ruta]')
    P('\tlocal inst = Instance.new(info.clase)')
    P('\tlocal padreRuta, nombre = ruta:match("^(.*)/([^/]+)$")')
    P('\tif not nombre then padreRuta, nombre = nil, ruta end')
    P('\tinst.Name = nombre')
    P('\tif info.fuente then inst.Source = info.fuente:sub(2) end -- quita el salto de línea añadido por el empaquetador')
    P('\tinst.Parent = (padreRuta and nodos[padreRuta]) or paquete')
    P('\tnodos[ruta] = inst')
    P('end')
    P('paquete.Parent = workspace')
    P('local ok, err = pcall(function() require(paquete.Instalador)() end)')
    P('if not ok then warn("[ColegioRP] Error al instalar: " .. tostring(err)) end')
    return '\n'.join(out) + '\n'

def main():
    os.makedirs(DIST, exist_ok=True)
    arbol = leer_arbol()
    with open(os.path.join(HERR, 'Instalador.lua'), encoding='utf-8') as f:
        instalador = f.read()
    version = '0.0.0'
    cfg = os.path.join(SRC, 'ReplicatedStorage', 'ColegioRP', 'Shared', 'Config.lua')
    if os.path.exists(cfg):
        m = re.search(r'Version\s*=\s*"([^"]+)"', open(cfg, encoding='utf-8').read())
        if m:
            version = m.group(1)
    rbxmx = escribir_rbxmx(arbol, instalador, version)
    with open(os.path.join(DIST, 'ColegioRP.rbxmx'), 'w', encoding='utf-8') as f:
        f.write(rbxmx)
    pegado = escribir_instalador_pegado(arbol, instalador, version)
    with open(os.path.join(DIST, 'Instalador_ColegioRP.lua'), 'w', encoding='utf-8') as f:
        f.write(pegado)
    # manifiesto
    manifest = {'version': version, 'generado': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'archivos': []}
    def rec(nodo, ruta):
        r = ruta + '.' + nodo['nombre'] if ruta else nodo['nombre']
        if nodo['clase'] != 'Folder':
            manifest['archivos'].append({'destino': r, 'clase': nodo['clase'], 'origen': nodo.get('archivo'), 'lineas': nodo['fuente'].count('\n') + 1, 'sha1': hashlib.sha1(nodo['fuente'].encode('utf-8')).hexdigest()[:12]})
        for h in nodo['hijos']:
            rec(h, r)
    for serv in arbol:
        rec(serv, '')
    with open(os.path.join(DIST, 'manifest.json'), 'w', encoding='utf-8') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    total = sum(a['lineas'] for a in manifest['archivos'])
    print('dist/ColegioRP.rbxmx: %d KB · dist/Instalador_ColegioRP.lua: %d KB · %d scripts · %d líneas · v%s' % (len(rbxmx) // 1024, len(pegado) // 1024, len(manifest['archivos']), total, version))

if __name__ == '__main__':
    main()
