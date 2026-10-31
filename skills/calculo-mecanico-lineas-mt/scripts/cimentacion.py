"""Cimentaciones de postes por el metodo de Sulzberger (Proyecto Tipo Afinia, Anexo B7).
Monobloque cilindrico o prismatico; F = carga de trabajo del poste = rotura/2,5 (B7.3); CS = Me/Mv >= 1,0 (B7.4.1).
"""
from __future__ import annotations
import math
import postes as P

# Coeficiente de compresibilidad a 2 m (daN/cm3) como el Excel (Flojo 8, Normal 12, Duro 16) y capacidad portante
# adoptada como valor de diseno (Tabla B7.2) cuando no hay estudio de suelos; con cimentacion de hormigon no es critica.
# Tabla 48 del Proyecto Tipo (caracterizacion de terrenos): sadm daN/cm2, K = Ch = Ck daN/cm3
TERRENOS = {"flojo": dict(C2=8.0, sadm=0.5, mu=0.2), "normal": dict(C2=12.0, sadm=1.0, mu=0.3),
            "duro": dict(C2=16.0, sadm=1.5, mu=0.4), "muy_duro": dict(C2=20.0, sadm=2.0, mu=0.5)}
TAN_ALFA = 0.01; C_COEF = 0.375; GAMMA_CONC = 2400.0

# Peso aproximado del poste (daN) tomado del Excel de COLISEO ('Ciment'): verificar con el fabricante.
PESO_POSTE = {(9, 500): 490.2, (9, 735): 490.2, (9, 1030): 490.2, (12, 735): 882.4, (12, 1030): 882.4, (12, 1324): 1421.6,
              (12, 1600): 1421.6, (14, 735): 1568.6, (14, 1030): 1568.6, (14, 1324): 1568.6, (14, 1600): 1568.6}

def peso_poste(ref):
    L = int(P.largo_poste(ref)); r = P.rotura(ref)
    if (L, int(r)) in PESO_POSTE: return PESO_POSTE[(L, int(r))]
    cand = [v for (l, rr), v in PESO_POSTE.items() if l == L]
    return max(cand) if cand else 1600.0

def momentos(forma, a, h, F, Hl, Pv, terreno):
    t = TERRENOS[terreno]
    Ch = Ck = t["C2"]*1e6*h/2            # daN/m3, lineal con la profundidad (B7.9)
    if forma == "cilindrica":
        Meh = a*h**3/52.8*Ch*TAN_ALFA
        Mev = C_COEF*a*Pv
    else:
        Meh = a*h**3/36*Ch*TAN_ALFA
        Mev = Pv*(a/2 - math.sqrt(2)/3*math.sqrt(Pv/(a*Ck*TAN_ALFA)))
    Mv = F*(Hl + 2/3*h)
    return Meh, Mev, Mv

def verificar(poste, terreno, forma, a, h, F=None, Pextra=0.0):
    poste = P.normalizar_poste(poste)
    ERF = P.rotura(poste); F = ERF/2.5 if F is None else F
    Hl = P.hN(poste); Lp = P.largo_poste(poste); dc, db = P.CATALOGO[poste][1:]
    area_b = math.pi*a*a/4 if forma == "cilindrica" else a*a
    Vexc = area_b*h
    Vposte = math.pi*((dc+db)/2/100/2)**2*P.empotramiento(poste)         # poste dentro de la excavacion
    Vconc = max(Vexc - Vposte, 0.0)
    Pv = peso_poste(poste) + GAMMA_CONC*Vconc + Pextra
    Meh, Mev, Mv = momentos(forma, a, h, F, Hl, Pv, terreno)
    sig = Pv/(area_b*1e4)                                                   # daN/cm2 en el fondo
    return dict(poste=poste, terreno=terreno, forma=forma, a=a, h=h, F=F, Hl=Hl, P=Pv, Meh=Meh, Mev=Mev, Me=Meh+Mev, Mv=Mv,
                CS=(Meh+Mev)/Mv, sigma=sig, sigma_adm=TERRENOS[terreno]["sadm"], V_exc=Vexc, V_conc=Vconc,
                ok=(Meh+Mev)/Mv >= 1.0 and sig <= TERRENOS[terreno]["sadm"])

def dimensionar(poste, terreno="normal", forma="cilindrica", Pextra=0.0, F=None, cs_min=1.0):
    """Menor volumen de excavacion (a, h) con CS >= cs_min y presion admisible; h >= empotramiento + solado 0,10 m."""
    poste = P.normalizar_poste(poste); hmin = P.empotramiento(poste) + 0.10
    amin = math.ceil((P.CATALOGO[poste][2]/100 + 0.20)/0.05)*0.05          # diametro base + 2 * pared minima 0,10 m (B7.4.1)
    mejor = None
    for a in [round(amin + 0.05*i, 2) for i in range(0, 14)]:
        for h in [round(hmin + 0.05*j, 2) for j in range(0, 25)]:
            r = verificar(poste, terreno, forma, a, h, F, Pextra)
            if r["CS"] >= cs_min and r["sigma"] <= r["sigma_adm"]:
                if mejor is None or r["V_exc"] < mejor["V_exc"]: mejor = r
                break
    return mejor


# ---- Cimentaciones NORMALIZADAS del Proyecto Tipo (Anexo A7.2, monobloque cilindrico) -> references/a7_2_cilindricas.json
import json, os
_A72 = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "references", "a7_2_cilindricas.json")))
CS_MIN = {"AL": 1.5, "ANG": 1.5, "FL": 1.5, "ANC": 1.9}          # 11.2.1

def normalizada(poste, funciones, terreno="normal"):
    """Cimentacion normalizada A7.2. `funciones`: funciones de los armados del poste fisico (envolvente: mayor ancho).
    Devuelve dict(a, h, CS, V, Pmax, grupo, cs_min)."""
    poste = P.normalizar_poste(poste)
    cands = []
    for f in funciones:
        g = "ANC_FL" if f in ("FL", "ANC") else "AL_ANG"
        r = dict(_A72[g][poste][terreno]); r["grupo"] = g; r["cs_min"] = CS_MIN[f]; cands.append(r)
    return max(cands, key=lambda r: (r["a"], r["V"]))

# ---- Anclas de concreto (Tabla 47): cable -> terreno -> dimensiones y carga maxima (daN)
ANCLAS = {"3/8": {"normal": dict(H=1.88, a=0.40, b=0.25, c=0.30, Cmax=8975, parrilla='3/8"@10cm', tipo="prefabricada"),
                  "flojo": dict(H=1.94, a=0.65, b=0.25, c=0.30, Cmax=4770, parrilla='3/8"@10cm', tipo="prefabricada")},
          "1/2": {"normal": dict(H=1.88, a=0.40, b=0.25, c=0.30, Cmax=8975, parrilla='3/8"@10cm', tipo="prefabricada"),
                  "flojo": dict(H=1.78, a=1.45, b=0.25, c=1.50, Cmax=8160, parrilla='1/2"@20cm', tipo="fabricada in situ")}}
