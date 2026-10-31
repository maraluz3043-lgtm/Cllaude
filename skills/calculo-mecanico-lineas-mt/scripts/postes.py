"""Verificacion de postes de concreto AUTOSOPORTADOS y decision "requiere retenida / no" .
Proyecto Tipo Afinia, Memoria cap. 9 (metodo simplificado, Tablas 31-37).

Regla de diseno (cap. 9.1): se disena primero con poste autosoportado; solo si ninguna
comprobacion pasa se pasa a retenida. Este modulo decide eso con el calculo, no por el tipo de apoyo.
"""
from __future__ import annotations
import math
from dataclasses import dataclass, field
import mecanica as m

# Tabla 32: esfuerzo EQUIVALENTE por viento sobre el poste (daN), referido a hN.
# columnas: A rural, A urbana, B rural, B urbana, C rural, C urbana
_COL = {("A","rural"):0, ("A","urbana"):1, ("B","rural"):2, ("B","urbana"):3, ("C","rural"):4, ("C","urbana"):5}
TABLA32 = {
 "PH-11/500": (61.00,52.10,47.30,29.30,30.27,20.35), "PH-11/735": (61.00,52.10,47.30,29.30,30.27,20.35),
 "PH-11/1030": (55.20,66.14,57.13,37.20,38.44,25.84), "PH-11/1324": (57.59,69.03,57.41,38.83,40.13,26.97),
 "PH-12/500": (65.74,58.72,53.36,33.03,34.15,22.94), "PH-12/735": (65.51,64.90,59.00,36.51,37.76,25.35),
 "PH-12/1030": (61.92,74.15,61.66,41.71,43.13,28.96), "PH-12/1324": (64.52,77.29,61.85,43.47,44.97,30.19),
 "PH-12/1600": (73.52,88.07,61.52,49.54,49.94,34.40), "PH-12/2500": (82.53,94.71,56.17,55.59,50.33,38.61),
 "PH-12/4000": (100.80,94.65,68.59,67.88,43.90,47.14),
 "PH-14/735": (66.92,80.07,69.52,45.04,46.64,31.28), "PH-14/1030": (76.18,91.09,70.25,51.24,53.09,35.58),
 "PH-14/1324": (79.19,94.73,70.22,53.28,55.22,37.00), "PH-14/1600": (90.02,105.52,61.25,60.55,57.26,42.05),
 "PH-14/2500": (100.69,106.36,68.55,67.73,57.35,47.03), "PH-14/4000": (122.10,91.25,83.16,80.59,53.22,57.03),
}
# Tabla 36: (rotura a flexion daN, momento ultimo a torsion daN*m | None, vertical ultimo en hN, hN-0.4, hN-0.8, hN-3.3)
# Torsion y vertical: el documento no da torsion para los postes >=1600 daN (se marca None).
TABLA36 = {
 "PH-11/500": (500,351,709,936,1074,6888), "PH-11/735": (735,380,709,936,1074,6888),
 "PH-11/1030": (1030,891,2539,3199,3591,18228), "PH-11/1324": (1324,1079,3240,4067,4558,22720),
 "PH-12/500": (500,351,568,742,847,4919), "PH-12/735": (735,380,568,742,847,4919),
 "PH-12/1030": (1030,891,2034,2538,2835,13060), "PH-12/1324": (1324,1079,2608,3243,3616,16365),
 "PH-14/735": (735,568,652,821,920,4139), "PH-14/1030": (1030,891,1372,1687,1869,7474),
 "PH-14/1324": (1324,1079,1779,2180,2412,9478),
 "PH-12/1600": (1600,None,5096,6212,7581,27487), "PH-12/2500": (2500,None,8831,10604,12755,43322),
 "PH-12/4000": (4000,None,22194,26131,30842,94253), "PH-14/1600": (1600,None,3466,4164,5003,16112),
 "PH-14/2500": (2500,None,6046,7159,8482,25346), "PH-14/4000": (4000,None,15225,17680,20561,55400),
}


# Catalogo Afinia ES.03396.TR (Tabla 4): ref -> (rotura daN, diametro cima cm, diametro base cm). Conicidad 1,5 cm/m.
CATALOGO = {
 "PH-9/500": (500,14,27.5), "PH-9/735": (735,14,27.5), "PH-9/1030": (1030,19,32.5), "PH-9/1324": (1324,21,34.5),
 "PH-10/500": (500,14,29), "PH-10/735": (735,14,29), "PH-10/1030": (1030,19,34),
 "PH-11/500": (500,14,30.5), "PH-11/735": (735,14,30.5), "PH-11/1030": (1030,19,35.5), "PH-11/1324": (1324,20,36.5),
 "PH-12/500": (500,14,32), "PH-12/735": (735,16,34), "PH-12/1030": (1030,19,37), "PH-12/1324": (1324,20,38),
 "PH-12/1600": (1600,23.5,41.5), "PH-12/2500": (2500,27,45), "PH-12/4000": (4000,34,52),
 "PH-14/735": (735,16,37), "PH-14/1030": (1030,19,40), "PH-14/1324": (1324,20,41),
 "PH-14/1600": (1600,23.5,44.5), "PH-14/2500": (2500,27,48), "PH-14/4000": (4000,34,55),
 "PH-16/1324": (1324,21,45), "PH-16/2000": (2000,26,50), "PH-16/2500": (2500,28,52),
}
import re as _re
def normalizar_poste(ref: str) -> str:
    """Acepta 'HP-12-1030', 'HP-12-1030 daN', 'PH-12/1030', 'HP 12-1030'... -> 'PH-12/1030'."""
    mt = _re.search(r"(\d+)\s*[-/ ]\s*(\d[\d\s]*)", ref.replace("daN", ""))
    if not mt: raise ValueError(f"poste no reconocido: {ref}")
    out = f"PH-{int(mt.group(1))}/{int(mt.group(2).replace(' ', ''))}"
    if out not in CATALOGO: raise ValueError(f"{ref}: no esta en el catalogo ES.03396.TR")
    return out

def rotura(ref: str) -> float:
    return TABLA36[ref][0] if ref in TABLA36 else CATALOGO[ref][0]

def torsion_ultima(ref: str):
    return TABLA36[ref][1] if ref in TABLA36 else None

_TERR = {("A","rural"):(130,0.12,"I"), ("A","urbana"):(80,0.28,"IV"), ("B","rural"):(100,0.16,"II"),
         ("B","urbana"):(60,0.28,"IV"), ("C","rural"):(80,0.16,"II"), ("C","urbana"):(50,0.28,"IV")}
def _GT(t, h):
    return {"I": -0.0002*h*h+0.0232*h+1.4661, "II": -0.0002*h*h+0.0274*h+1.6820,
            "IV": -0.0002*h*h+0.0384*h+2.9284}[t]

def ftvp_calculado(ref: str, zona: str, area: str) -> float:
    """Esfuerzo equivalente por viento sobre el poste (Anexo B2.3), referido a hN. Reproduce la Tabla 32
    con mediana 1,4 % de error (hasta ~16 % en la zona critica de Reynolds): usar la tabla cuando exista."""
    _, dc, db = CATALOGO[ref]; L = largo_poste(ref); Le = empotramiento(ref); hl = L - Le
    de = (db - 1.5*Le)/100; dcm = dc/100
    V, al, terr = _TERR[(zona, area)]
    q0 = 0.06125*(V/(3.6*1.37))**2
    hp = hl - (2*de + dcm)/(de + dcm)*hl/3
    Re = (de + dcm)/2*((V/(3.6*1.37*1.45e-5))*(hp/10)**al)
    cx = 1.2 if Re <= 3e5 else (0.75 if Re >= 4.5e5 else -1.1098*math.log(Re) + 15.1973)
    return q0*cx*_GT(terr, hp)*hl*(de + dcm)/2*hp/(hl - 0.2)

def empotramiento(ref: str) -> float:
    """Le = L/10 + 0,6 m (linea de empotramiento del ES.03396.TR; el Excel de COLISEO usa +0,5)."""
    return largo_poste(ref)/10 + 0.6

def largo_poste(ref: str) -> float:
    return float(ref.split("-")[1].split("/")[0])

def altura_libre(ref: str) -> float:
    """hl = L - Le, con Le = L/10 + 0,6 (ES.03396.TR)."""
    return largo_poste(ref) - empotramiento(ref)

def hN(ref: str) -> float:
    return altura_libre(ref) - 0.2

F_NORMAL, F_ANORMAL, F_VERT = 2.5, 1.5, 1.2


@dataclass
class Apoyo:
    funcion: str                 # AL, ANG, ANC, FL
    poste: str                   # p.ej. "PH-14/1030"
    conductor: str               # clave de mecanica.CONDUCTORES
    zona: str; area: str         # A/B/C ; rural/urbana
    alturas: list                # altura sobre el suelo de cada conductor de fase (m)
    ar1: float | None = None     # vano regulador del canton anterior (None si no hay)
    ar2: float | None = None     # vano regulador del canton posterior (None en FL)
    a1: float = 0.0              # vano anterior (m)
    a2: float = 0.0              # vano posterior (m)
    beta: float = 0.0            # angulo de deflexion (grados) - ANG
    tense: str = "normal"        # normal | reducido
    t_rotura: float = 1.0        # distancia (m) del conductor mas alejado al eje (torsion)
    excentricidades: list = field(default_factory=list)   # [(Pj+Ps daN, Lj m)] solo configuracion en bandera
    FTEE: float = 0.0; FLEE: float = 0.0                  # equipos (trafo): ver Proyecto Tipo de Centros de Transformacion
    desequilibrio_importante: bool = False                # ANC: usar hipotesis normal en vez de la anormal


def _T(c, a, zona, area, tense, hip):
    if a is None: return 0.0
    return m.tabla_vano(c, zona, area, a, tense)[1][hip]["To"]


def evaluar(ap: Apoyo) -> dict:
    c = m.CONDUCTORES[ap.conductor]
    ap.poste = normalizar_poste(ap.poste)
    rot, tors = rotura(ap.poste), torsion_ultima(ap.poste)
    HN = hN(ap.poste); SH = sum(ap.alturas); k = SH/HN
    T01 = _T(c, ap.ar1, ap.zona, ap.area, ap.tense, "vmax"); T02 = _T(c, ap.ar2, ap.zona, ap.area, ap.tense, "vmax")
    T01r = _T(c, ap.ar1, ap.zona, ap.area, ap.tense, "vred"); T02r = _T(c, ap.ar2, ap.zona, ap.area, ap.tense, "vred")
    pv, _ = m.peso_aparente_tabla(c, ap.zona, ap.area)
    if ap.poste in TABLA32:
        FTVP, fuente = TABLA32[ap.poste][_COL[(ap.zona, ap.area)]], "Tabla 32"
    else:
        FTVP, fuente = ftvp_calculado(ap.poste, ap.zona, ap.area), "calculado B2.3 (poste fuera de Tabla 32)"
    FTEC = sum(P*L for P, L in ap.excentricidades)/HN
    av = (ap.a1 + ap.a2)/2
    f = ap.funcion.upper()
    d = dict(funcion=f, poste=ap.poste, HN=HN, sumH_HN=k, T01=T01, T02=T02, FTVP=FTVP, fuente_FTVP=fuente, pv=pv)
    chk = []                       # (nombre, esfuerzo*factor, capacidad, ok)

    if f == "AL":
        FTVC = pv*av*k
        R = math.hypot(FTEC + FTVC + FTVP, ap.FLEE)
        chk.append(("Flexion normal (AL)", F_NORMAL*R, rot))
    elif f == "ANG":
        b = math.radians(ap.beta)/2
        Tres = math.sqrt(((T02-T01)*math.cos(b))**2 + ((T02+T01)*math.sin(b))**2)
        FTVC = (pv*av*math.cos(b) + Tres)*k
        R = math.hypot(FTEC + FTVC + FTVP, ap.FLEE)
        chk.append(("Flexion normal (ANG)", F_NORMAL*R, rot))
    elif f in ("ANC", "FL"):
        if f == "FL":
            FTVC = pv*(ap.a1/2)*k                 # 9.2.2.6: Pv*a/2
            FLTC = T01*k                           # desequilibrio 100 %
            Tmax_r = T01r
        else:
            FTVC = pv*av*k
            FLTC = abs(T02 - T01)*k
            Tmax_r = max(T01r, T02r)
        Rn = math.hypot(FTEC + FTVC + FTVP + ap.FTEE, FLTC)
        if f == "FL" or ap.desequilibrio_importante:
            chk.append((f"Flexion normal ({f}, desequilibrio real)", F_NORMAL*Rn, rot))
        else:
            FLMC = 0.5*max(T01, T02)*k
            chk.append(("Flexion anormal ANC (50 % desequilibrio)", F_ANORMAL*FLMC, rot))
        MT = ap.t_rotura*Tmax_r
        chk.append(("Torsion anormal (rotura de un conductor, viento reducido 28 C)", F_ANORMAL*MT, tors))
        d.update(FTVC=FTVC, FLTC=FLTC, MT=MT)
    else:
        raise ValueError("funcion debe ser AL, ANG, ANC o FL")

    filas, pendientes = [], []
    for nombre, solic, cap in chk:
        if cap is None:
            pendientes.append(nombre); filas.append(dict(nombre=nombre, solicitado=solic, capacidad=None, uso=None, ok=None))
        else:
            filas.append(dict(nombre=nombre, solicitado=solic, capacidad=cap, uso=solic/cap, ok=solic <= cap))
    ok = all(r["ok"] is not False for r in filas)
    d["verificaciones"] = filas
    if not ok:
        d["veredicto"] = "REQUIERE RETENIDA (el poste no es autosoportado)" if f in ("ANC", "FL", "ANG") else "NO CUMPLE: aumentar poste"
    elif pendientes:
        d["veredicto"] = "AUTOSOPORTADO por flexion - no requiere retenida (torsion pendiente: falta dato del poste)"
    else:
        d["veredicto"] = "AUTOSOPORTADO - no requiere retenida"
    d["pendientes"] = pendientes
    return d


def poste_minimo_autosoportado(ap: Apoyo, largos=None):
    """Poste mas liviano (por rotura) que cumple autosoportado, del mismo largo (o de los `largos` dados)."""
    largos = largos or [largo_poste(ap.poste)]
    cand = sorted((r[0], k) for k, r in CATALOGO.items() if largo_poste(k) in largos)
    import dataclasses
    for rot, ref in cand:
        r = evaluar(dataclasses.replace(ap, poste=ref))
        if r["veredicto"].startswith("AUTOSOPORTADO"):
            return ref, r
    return None, None
