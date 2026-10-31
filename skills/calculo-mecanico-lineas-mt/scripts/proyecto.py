"""Evalua un proyecto completo (hoja 'Ingreso' del Excel de calculos MT) con el Proyecto Tipo Afinia.
Uso: python3 -I proyecto.py <libro.xlsx> <zona A|B|C> <area rural|urbana> [--amarres EPP04,EPP05,...]
- Cantones: terminan en FL (y en apoyos listados en --amarres). Los 'AC' (apoyos de angulo) del Excel se evaluan como ANG dentro del canton.
- Un AL con deflexion > 5 grados se evalua como ANG (conservador) y se avisa.
"""
import sys, math, dataclasses
sys.path.insert(0, __file__.rsplit('/', 1)[0])
import openpyxl, mecanica as m, postes as P

CAL = {"1/0": "ACSR 1/0 (RAVEN)", "4/0": "ACSR 4/0 (PENGUIN)", "266": "ACSR 266.8 (PARTRIDGE)",
       "266.8": "ACSR 266.8 (PARTRIDGE)", "336": "ACSR 336.4 (LINNET)", "477": "ACSR 477 (HAWK)"}
TIPO = {"AL": "AL", "AC": "ANG", "AG": "ANG", "ANG": "ANG", "FL": "FL", "ANC": "ANC"}

def leer_csv(path):
    import csv
    ap = []
    for r in csv.DictReader(open(path, encoding="utf-8")):
        cal = r["calibre"].strip()
        ap.append(dict(nombre=r["apoyo"].strip(), tipo=TIPO[r["tipo"].strip().upper()], marca=r["marca"].strip() or None,
                       cond=CAL[cal], x=float(r["x"]), y=float(r["y"]), largo=float(r["largo"]), existente=False,
                       rotura=int(r["rotura"]), trafo=(r.get("kva"), r.get("tipo_trafo"))))
    return ap

def leer_ingreso(path):
    if path.lower().endswith(".csv"): return leer_csv(path)
    ws = openpyxl.load_workbook(path, data_only=True)["Ingreso"]
    ap = []
    for r in range(6, 400):
        n = ws[f"B{r}"].value
        if not n or n == 0: break
        cal = str(ws[f"I{r}"].value).strip()
        ap.append(dict(nombre=n, tipo=TIPO[str(ws[f"C{r}"].value).strip().upper()], marca=ws[f"D{r}"].value,
                       cond=CAL[cal.replace(".0", "")] if cal.replace(".0", "") in CAL else CAL[cal],
                       x=ws[f"J{r}"].value, y=ws[f"K{r}"].value, largo=float(ws[f"N{r}"].value),
                       existente=str(ws[f"O{r}"].value).strip().upper() == "E", rotura=int(ws[f"Q{r}"].value),
                       trafo=(ws[f"E{r}"].value, ws[f"F{r}"].value)))
    return ap

def lineas(ap):
    """Separa en tramos: una nueva linea empieza en cada FL marcado 'I' (inicio) y termina en el 'F'.
    Criterio Afinia para esquinas ~90 grados y doble armado: dos fines de linea (X y XA) en la misma ubicacion."""
    out, cur = [], []
    for a in ap:
        if a["tipo"] == "FL" and str(a["marca"]).upper() == "I" and cur: out.append(cur); cur = []
        cur.append(a)
    if cur: out.append(cur)
    return out

def deflexion(p0, p1, p2):
    v1 = (p1["x"]-p0["x"], p1["y"]-p0["y"]); v2 = (p2["x"]-p1["x"], p2["y"]-p1["y"])
    c = (v1[0]*v2[0]+v1[1]*v2[1]) / (math.hypot(*v1)*math.hypot(*v2))
    return math.degrees(math.acos(max(-1, min(1, c))))

def evaluar_linea(linea, zona, area, amarres=()):
    n = len(linea); res = []
    dist = [math.hypot(linea[i+1]["x"]-linea[i]["x"], linea[i+1]["y"]-linea[i]["y"]) for i in range(n-1)]
    # cantones
    cortes = [0] + [i for i in range(1, n-1) if linea[i]["tipo"] in ("FL", "ANC") or linea[i]["nombre"] in amarres] + [n-1]
    canton_de = {}
    ars = {}
    for k in range(len(cortes)-1):
        vs = dist[cortes[k]:cortes[k+1]]
        ars[k] = m.vano_regulador(vs)
        for i in range(cortes[k], cortes[k+1]+1): canton_de.setdefault(i, []).append(k)
    for i, a in enumerate(linea):
        c = a["cond"]; ks = canton_de[i]
        ar1 = ars[ks[0]]; ar2 = ars[ks[-1]] if len(ks) > 1 else (ar1 if 0 < i < n-1 else None)
        a1 = dist[i-1] if i > 0 else dist[0]; a2 = dist[i] if i < n-1 else 0.0
        beta = deflexion(linea[i-1], a, linea[i+1]) if 0 < i < n-1 else 0.0
        f = a["tipo"]; nota = ""
        if f == "FL" and 0 < i < n-1 and not a["marca"]: f = "ANC"; nota = "FL sin marca I/F en medio del tramo: evaluado como ANC (anclaje)"
        if f == "AL" and beta > 5: f = "ANG"; nota = f"AL con deflexion {beta:.0f} grados: evaluado como ANG"
        tense = "reducido" if area == "urbana" and max(ar1, ar2 or 0) <= 50 else "normal"
        if f == "FL":
            ar1, ar2 = (ar1, None) if i > 0 else (ars[ks[0]], None)
            if i == 0: a1 = dist[0]
        pole = P.normalizar_poste(f"HP-{int(a['largo'])}-{a['rotura']}")
        hN_ = P.hN(pole)
        ap = P.Apoyo(f, pole, c, zona, area, [hN_-0.106]*3, ar1=ar1, ar2=ar2, a1=a1, a2=a2, beta=beta, tense=tense)
        r = P.evaluar(ap)
        ref, _ = P.poste_minimo_autosoportado(ap, largos=[a["largo"]])
        auto = r["veredicto"].startswith("AUTO")
        ret = 0 if auto else {"FL": 1, "ANC": 2}.get(f, 1)   # FL: una retenida; ANC: una por lado
        res.append(dict(apoyo=a["nombre"], funcion=f, beta=beta, poste=pole, ar=(ar1, ar2), r=r, minimo=ref, nota=nota, retenidas=ret))
    return res

if __name__ == "__main__":
    path, zona, area = sys.argv[1], sys.argv[2].upper(), sys.argv[3].lower()
    am = sys.argv[5].split(",") if len(sys.argv) > 5 and sys.argv[4] == "--amarres" else ()
    for li, linea in enumerate(lineas(leer_ingreso(path)), 1):
        print(f"\n=== Linea {li}: {linea[0]['nombre']} -> {linea[-1]['nombre']}  ({zona} {area}, {linea[0]['cond']})")
        for x in evaluar_linea(linea, zona, area, am):
            r = x["r"]; usos = [v["uso"] for v in r["verificaciones"] if v["uso"] is not None]
            print(f"{x['apoyo']:7s} {x['funcion']:3s} b={x['beta']:5.1f} {x['poste']:11s} uso max {max(usos):5.2f} | {r['veredicto']} | retenidas: {x['retenidas']}"
                  + (f" | minimo autosoportado: {x['minimo']}" if not r['veredicto'].startswith('AUTO') else "") + (f" | {x['nota']}" if x['nota'] else ""))
