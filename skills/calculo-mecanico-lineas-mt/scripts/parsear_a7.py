"""Extrae la Tabla 2 del Anexo A7.2 (monobloque cilindrico) del texto del Proyecto Tipo a references/a7_2_cilindricas.json.
Uso: python3 -I parsear_a7.py <texto_proyecto_tipo.txt> <salida.json>"""
import re, sys, json
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
ini = next(i for i, l in enumerate(lines) if l.startswith("A7.2  CIMENTACIONES MONOBLOQUES CIL"))
fin = next(i for i, l in enumerate(lines) if i > ini and l.startswith("A7.3  CIMENTACIONES MONOBLOQUES PRISM"))
TER = ["flojo", "normal", "duro", "muy_duro"]
out = {}; grupo = "AL_ANG"; pend = None
num = lambda s: float(s.replace(",", "."))
for l in lines[ini:fin]:
    s = l.strip()
    if s.startswith("AL y ANG"): grupo = "AL_ANG"
    if s.startswith("ANC y FL"): grupo = "ANC_FL"
    mt = re.match(r"^HP\s*(\d+)-(\d+)\s*daN\s*(.*)$", s)
    if mt:
        pend = f"PH-{mt.group(1)}/{mt.group(2)}"; resto = mt.group(3)
    elif pend and re.match(r"^[\d,\. ]+$", s) and s:
        resto = s
    else:
        continue
    v = [num(x) for x in resto.split()] if resto.strip() else []
    if len(v) == 20 and pend:
        for k, t in enumerate(TER):
            a, h, cs, vol, pm = v[5*k:5*k+5]
            out.setdefault(grupo, {}).setdefault(pend, {})[t] = dict(a=a, h=h, CS=cs, V=vol, Pmax=pm)
        pend = None
json.dump(out, open(sys.argv[2], "w"), indent=1)
print({g: len(p) for g, p in out.items()})
