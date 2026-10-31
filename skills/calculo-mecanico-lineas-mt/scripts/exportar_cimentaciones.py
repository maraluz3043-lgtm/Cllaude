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
ws["A2"] = (f"Método de Sulzberger (Proyecto Tipo Afinia, Anexo B7) · terreno {terreno} · zona {zona} {area} · "
            f"F = rotura/2,5 · CS mínimo 1,0 · tan α = 0,01")
cols = ["No. Apoyo", "Tipo de apoyo", "Poste", "Tipo de cimentación", "d (m)", "h (m)", "Vol. excav. (m³)", "Vol. horm. (m³)",
        "F trabajo (daN)", "P vertical (daN)", "Mv (daN·m)", "Me (daN·m)", "CS", "Presión (daN/cm²)", "Obs."]
for j, c in enumerate(cols, 1):
    cell = ws.cell(4, j, c); cell.font = hfont; cell.fill = hfill; cell.border = borde
    cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
ws.row_dimensions[4].height = 32
vistos = {}; r = 5; vexc = vconc = 0.0
for a in datos:
    n = a["nombre"]; x = res[n]; k = pr.clave_poste(n)
    fila = [n, a["tipo"], x["poste"].replace("PH-", "HP-").replace("/", "-")]
    if n in exi:
        fila += ["POSTE EXISTENTE"] + [None]*10 + ["No se diseña (existente)"]
    else:
        if k not in vistos:
            g = ret.get(k); cc = m.CONDUCTORES[x["ap"].conductor]
            Pex = (g["sel"]["FVERT"] + 18) if g else 3*cc.pc*(x["ap"].a1 + x["ap"].a2)/2 + 18
            vistos[k] = (n, CM.dimensionar(x["poste"], terreno, "cilindrica", Pex))
        base, d = vistos[k]
        primero = base == n
        if primero: vexc += d["V_exc"]; vconc += d["V_conc"]
        fila += ["CILÍNDRICA CON HORMIGÓN", d["a"], d["h"], d["V_exc"] if primero else None, d["V_conc"] if primero else None,
                 d["F"], d["P"], d["Mv"], d["Me"], d["CS"], d["sigma"],
                 "" if primero else f"Mismo poste físico que {base} (doble armado)"]
    for j, v in enumerate(fila, 1):
        cell = ws.cell(r, j, v); cell.border = borde
        cell.alignment = Alignment(horizontal="left" if j in (4, 15) else "center")
        if j in (5, 6): cell.number_format = "0.00"
        if j in (7, 8): cell.number_format = "0.000"
        if j in (9, 10, 11, 12): cell.number_format = "#,##0"
        if j in (13, 14): cell.number_format = "0.00"
    r += 1
ws.cell(r, 4, "TOTAL (sin repetir postes dobles)").font = Font(bold=True)
for j, v in ((7, vexc), (8, vconc)):
    c = ws.cell(r, j, v); c.font = Font(bold=True); c.number_format = "0.000"; c.border = borde
for j, w in enumerate([11, 10, 12, 26, 8, 8, 13, 13, 13, 13, 13, 13, 8, 12, 40], 1):
    ws.column_dimensions[get_column_letter(j)].width = w
ws.freeze_panes = "A5"

s = wb.create_sheet("Supuestos")
filas = [("Método", "Sulzberger, monobloque cilíndrico (Proyecto Tipo Afinia, Anexo B7.4.1)"),
         ("Carga horizontal", "F = carga de rotura del poste / 2,5 (B7.3), aplicada a la altura nominal hN"),
         ("Momento de vuelco", "Mv = F·(Hl + 2/3·h)"),
         ("Momento estabilizador", "Me = a·h³·Ch·tanα/52,8 + c·a·P ; c = 0,375 ; tanα = 0,01"),
         ("Coeficiente de terreno", f"Ch = Ck = C2·h/2 con C2 = {CM.TERRENOS[terreno]['C2']} daN/cm³ a 2 m (terreno {terreno}, como el Excel de cálculos)"),
         ("Presión admisible", f"{CM.TERRENOS[terreno]['sadm']} daN/cm² valor de diseño adoptado (Tabla B7.2, terreno {terreno}); no se dispone de estudio de suelos y la cimentación es monobloque de hormigón"),
         ("Geometría mínima", "d ≥ diámetro de base del poste + 0,20 m ; h ≥ empotramiento (L/10 + 0,6 m) + solado 0,10 m"),
         ("P vertical", "Peso del poste (valores del Excel; verificar con el fabricante) + hormigón de la cimentación + cargas verticales de conductores y de la retenida (B·Fh)"),
         ("Pendiente", "Anclas de las retenidas (Anexo B8.2); verificar el peso real de los postes con el fabricante")]
s.append(["Concepto", "Detalle"]); [s.append(list(f)) for f in filas]
s.column_dimensions["A"].width = 26; s.column_dimensions["B"].width = 120
for c in s[1]: c.font = hfont; c.fill = hfill
wb.save(salida); print("OK", salida, f"| {len(vistos)} postes fisicos, excavacion {vexc:.2f} m3, hormigon {vconc:.2f} m3")
