"""Genera la tabla de cimentaciones (formato hoja 'Ciment' del Excel) desde el CSV de ingreso.
Uso: python3 -I exportar_cimentaciones.py <ingreso.csv> <zona> <area> <terreno> <salida.xlsx> [--existentes A,B] [--bandera ...] [--t m] [--tipo X=AL] [--proyecto "NOMBRE"]
Una fila por apoyo; los apoyos 'A' (doble armado) comparten el poste fisico de su base y no suman volumen."""
import sys, math
sys.path.insert(0, __file__.rsplit('/', 1)[0])
import proyecto as pr, cimentacion as CM, mecanica as m
from openpyxl import Workbook
from openpyxl.styles import Font, Alignment, PatternFill, Border, Side
from openpyxl.utils import get_column_letter

def arg(n, d=None):
    return sys.argv[sys.argv.index(n)+1] if n in sys.argv else d

csv_path, zona, area, terreno, salida = sys.argv[1], sys.argv[2].upper(), sys.argv[3].lower(), sys.argv[4].lower(), sys.argv[5]
exi = arg("--existentes", "").split(",") if arg("--existentes") else []
ban = arg("--bandera", "").split(",") if arg("--bandera") else []
tb = float(arg("--t", 0)); nombre = arg("--proyecto", "PROYECTO")
datos = pr.leer_ingreso(csv_path)
if arg("--tipo"):
    for kv in arg("--tipo").split(","):
        k, v = kv.split("="); [a.update(tipo=pr.TIPO[v.upper()]) for a in datos if a["nombre"] == k]
res = {x["apoyo"]: x for l in pr.lineas(datos) for x in pr.evaluar_linea(l, zona, area, (), ban, tb)}
todos = list(res.values())
ret = {g["poste_fisico"]: g for g in pr.retenidas_por_poste(todos, existentes=exi)}

wb = Workbook(); ws = wb.active; ws.title = "Cimentaciones"
thin = Side(style="thin", color="999999"); borde = Border(left=thin, right=thin, top=thin, bottom=thin)
hfill = PatternFill("solid", fgColor="1F4E78"); hfont = Font(bold=True, color="FFFFFF")
ws["A1"] = f"CÁLCULO DE CIMENTACIONES - {nombre}"; ws["A1"].font = Font(bold=True, size=13)
ws["A2"] = f"Cimentaciones normalizadas Proyecto Tipo Afinia (Anexo A7.2, monobloque cilíndrico) · terreno {terreno} · zona {zona} {area}"
cols = ["No. Apoyo", "Tipo de apoyo", "Poste", "Tipo de cimentación", "a (m)", "h (m)", "V (m³)", "CS tabla", "CS mínimo",
        "P máx (daN)", "Vertical retenida + gravivano (daN)", "Verifica", "Obs."]
for j, c in enumerate(cols, 1):
    cell = ws.cell(4, j, c); cell.font = hfont; cell.fill = hfill; cell.border = borde
    cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
ws.row_dimensions[4].height = 44
vistos = {}; r = 5; vtot = 0.0
for a in datos:
    n = a["nombre"]; x = res[n]; k = pr.clave_poste(n)
    fila = [n, a["tipo"], x["poste"].replace("PH-", "HP-").replace("/", "-")]
    if n in exi:
        fila += ["POSTE EXISTENTE"] + [None]*8 + ["No se diseña (existente)"]
    else:
        if k not in vistos:
            funcs = [res[o["nombre"]]["funcion"] if o["tipo"] != "AL" else "AL" for o in datos if pr.clave_poste(o["nombre"]) == k and o["nombre"] not in exi]
            funcs = [("ANG" if f == "ANG" else f) for f in funcs]
            g = ret.get(k)
            Pv = (g["sel"]["FVERT"] + 18) if g else 3*m.CONDUCTORES[x["ap"].conductor].pc*(x["ap"].a1 + x["ap"].a2)/2 + 18
            d = CM.normalizada(x["poste"], funcs, terreno)
            vistos[k] = (n, d, Pv)
        base, d, Pv = vistos[k]; primero = base == n
        if primero: vtot += d["V"]
        ok = d["CS"] >= d["cs_min"] and Pv <= d["Pmax"]
        fila += ["MONOBLOQUE CILÍNDRICO (A7.2)", d["a"], d["h"], d["V"] if primero else None, d["CS"], d["cs_min"], d["Pmax"], Pv,
                 "SÍ" if ok else "NO", "" if primero else f"Mismo poste físico que {base} (doble armado)"]
    for j, v in enumerate(fila, 1):
        cell = ws.cell(r, j, v); cell.border = borde
        cell.alignment = Alignment(horizontal="left" if j in (4, 13) else "center")
        if j in (5, 6): cell.number_format = "0.00"
        if j == 7: cell.number_format = "0.000"
        if j in (8, 9): cell.number_format = "0.00"
        if j in (10, 11): cell.number_format = "#,##0"
    r += 1
ws.cell(r, 4, "TOTAL (sin repetir postes dobles)").font = Font(bold=True)
c = ws.cell(r, 7, vtot); c.font = Font(bold=True); c.number_format = "0.000"; c.border = borde
for j, w in enumerate([11, 10, 12, 30, 8, 8, 9, 10, 10, 12, 20, 10, 40], 1):
    ws.column_dimensions[get_column_letter(j)].width = w
ws.freeze_panes = "A5"

an = wb.create_sheet("Anclas")
hdr = ["Poste", "Apoyos", "Cable", "Tiro (daN)", "Ancla de concreto", "H (m)", "a (m)", "b (m)", "c (m)", "Carga máx (daN)", "Uso", "Refuerzo", "Verifica", "Obs."]
for j, c in enumerate(hdr, 1):
    cell = an.cell(1, j, c); cell.font = hfont; cell.fill = hfill; cell.alignment = Alignment(horizontal="center", wrap_text=True)
for i, (k, g) in enumerate(ret.items(), 2):
    s = g["sel"]; A = CM.ANCLAS[s["cable"]][terreno if terreno in ("normal", "flojo") else "normal"]
    obs = "Retenida con poste auxiliar a tierra (Fig. 6): dimensionar también el poste auxiliar" if k == "EPP8" else ""
    for j, v in enumerate([k, "+".join(g["apoyos"]), s["cable"] + '"', s["tiro"], f"Concreto {A['tipo']}", A["H"], A["a"], A["b"], A["c"], A["Cmax"],
                           s["tiro"]/A["Cmax"], A["parrilla"], "SÍ" if s["tiro"] <= A["Cmax"] else "NO", obs], 1):
        cell = an.cell(i, j, v); cell.alignment = Alignment(horizontal="center")
        if j == 4 or j == 10: cell.number_format = "#,##0"
        if j == 11: cell.number_format = "0.00"
for j, w in enumerate([9, 16, 8, 11, 28, 8, 8, 8, 8, 14, 8, 12, 9, 60], 1):
    an.column_dimensions[get_column_letter(j)].width = w

s = wb.create_sheet("Supuestos")
filas = [("Fuente", "Proyecto Tipo Afinia MT sin neutro: Anexo A7.2 (cimentaciones normalizadas, monobloque cilíndrico), Tabla 47 (anclas), Tabla 48 (terrenos)"),
         ("Terreno", f"{terreno} (K = {CM.TERRENOS[terreno]['C2']:.0f} daN/cm³, σadm = {CM.TERRENOS[terreno]['sadm']} daN/cm² según Tabla 48); sin estudio de suelos"),
         ("Selección", "Por poste, función (AL/ANG o ANC/FL) y terreno. Poste con doble armado: se toma la mayor dimensión de sus armados"),
         ("Cimentación", "Todos los postes nuevos van cimentados con monobloque de hormigón (decisión de diseño); el Proyecto Tipo prefiere poste directamente empotrado en terreno normal"),
         ("CS mínimo", "1,5 para AL, ANG y FL; 1,9 para ANC (11.2.1). F = rotura/2,5"),
         ("Vertical", "Retenida (B·Fh) + gravivano/conductores + 18 daN de aisladores; P máx ya incluye poste y cimentación. No incluye el transformador de EPP9"),
         ("Anclas", "Tabla 47: tiro del cable ≤ carga máxima del ancla (cable 3/8\" y 1/2\" en terreno normal: 8975 daN)"),
         ("Pendiente", "Peso del transformador de 45 kVA en EPP9; dimensionamiento del poste auxiliar de EPP8")]
s.append(["Concepto", "Detalle"]); [s.append(list(f)) for f in filas]
s.column_dimensions["A"].width = 18; s.column_dimensions["B"].width = 130
for c in s[1]: c.font = hfont; c.fill = hfill
wb.save(salida); print("OK", salida, f"| {len(vistos)} postes fisicos, V total {vtot:.2f} m3")
