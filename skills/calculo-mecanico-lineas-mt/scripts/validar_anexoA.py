"""Compara mecanica.tabla_vano contra las Tablas de Calculo Mecanico (Anexo A3) del Proyecto Tipo.
Uso: python3 -I validar_anexoA.py <texto_proyecto_tipo.txt>"""
import re, sys, math
sys.path.insert(0, __file__.rsplit('/', 1)[0])
import mecanica as m

txt = open(sys.argv[1], encoding='utf-8').read().split('\n')
SECC = [(5596, 'urbana', 'normal'), (7859, 'urbana', 'reducido'), (9508, 'rural', 'normal'), (11761, None, None)]
ZONAS = {}  # linea inicio -> zona
for i, l in enumerate(txt, 1):
    mt = re.match(r'^A3\.[123]\.([123]) ZONA ([ABC])', l)
    if mt: ZONAS[i] = mt.group(2)
def ctx(i):
    area = tense = None
    for s, a, t in SECC:
        if i >= s: area, tense = a, t
    zona = None
    for s, z in sorted(ZONAS.items()):
        if i >= s: zona = z
    return zona, area, tense

by_key = {(round(c.S, 1), round(c.CR)): c for c in m.CONDUCTORES.values()}
orden = ['vmax', 'vred', 'tmin', 'tmax', 'texc', 'tmin2', 'eds', 'chs']
stats = {}; fallos = []; cur = None
for i, l in enumerate(txt, 1):
    if i < 5596 or i > 11760: continue
    ms = re.match(r'^Sección\s+([\d,\.]+)\s*mm.*rotura\s+(\d+)', l)
    if ms:
        cur = by_key.get((round(float(ms.group(1).replace(',', '.')), 1), int(ms.group(2))))
        continue
    if cur is None or '%' not in l: continue
    tk = l.replace(',', '.').replace('%', '').split()
    try: v = [float(x) for x in tk]
    except ValueError: continue
    if len(v) != 28: continue
    a = v[0]; zona, area, tense = ctx(i)
    h0, o = m.tabla_vano(cur, zona, area, a, tense)
    for k, h in enumerate(orden):
        if h == 'tmin2': continue
        ref = v[1 + 3*k]; got = o[h]['To']
        err = abs(got - ref) / ref
        key = (cur.nombre, zona, area, tense)
        s = stats.setdefault(key, [0, 0.0]); s[0] += 1; s[1] = max(s[1], err)
        if err > 0.01: fallos.append((cur.nombre, zona, area, tense, a, h, ref, round(got, 1)))
n = sum(s[0] for s in stats.values()); worst = max(s[1] for s in stats.values())
print(f'{len(stats)} tablas, {n} comparaciones, error relativo maximo {worst*100:.2f}%')
bad = {k: s for k, s in stats.items() if s[1] > 0.01}
for k, s in sorted(bad.items()): print('  >1%:', k, f'max {s[1]*100:.1f}%')
print('fallos >1%:', len(fallos)); [print(' ', f) for f in fallos[:8]]
