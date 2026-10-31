"""Pruebas de la decision autosoportado / retenida. Uso: python3 -I test_postes.py"""
import sys; sys.path.insert(0, __file__.rsplit('/', 1)[0])
import postes as P

def fl(pole, a, tense="normal", zona="A", area="urbana", cond="ACSR 1/0 (RAVEN)"):
    return P.Apoyo("FL", pole, cond, zona, area, [11.7]*3, ar1=a, a1=a, tense=tense)

# 1. Un fin de linea NO siempre requiere retenida: depende del poste.
assert P.evaluar(fl("PH-14/735", 64.5))["veredicto"].startswith("REQUIERE RETENIDA")
assert P.evaluar(fl("PH-14/4000", 64.5))["veredicto"].startswith("AUTOSOPORTADO")
# 2. El poste minimo autosoportado crece con la tension: tense reducido (vano corto) permite un poste menor.
min_n = P.poste_minimo_autosoportado(fl("PH-14/735", 64.5))[0]
min_r = P.poste_minimo_autosoportado(fl("PH-14/735", 40, "reducido"))[0]
assert P.TABLA36[min_r][0] <= P.TABLA36[min_n][0], (min_n, min_r)
# 3. Alineacion con poste 735: normalmente cumple.
al = P.Apoyo("AL", "PH-12/735", "ACSR 1/0 (RAVEN)", "A", "urbana", [10.5]*3, a1=60, a2=60)
assert P.evaluar(al)["verificaciones"][0]["ok"] is True
# 4. Un poste sin dato de torsion nunca se declara autosoportado "limpio": queda pendiente y se avisa.
r = P.evaluar(fl("PH-14/4000", 64.5)); assert r["pendientes"] and "pendiente" in r["veredicto"]
print("OK. Minimos FL 64,5 m normal:", min_n, "| 40 m reducido:", min_r)
