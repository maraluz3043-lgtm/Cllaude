"""Retenida bisectora (metodo simplificado, Proyecto Tipo Afinia cap. 10, Tablas 38-42) para postes FL/ANC.
Una esquina (dos FL en el mismo poste fisico) lleva UNA retenida en la bisectriz que resiste la resultante de ambos tiros.
"""
from __future__ import annotations
import math
import postes as P

# Tabla 11-14: cable de acero galvanizado y accesorios (daN)
CABLE = {"3/8": 6840, "1/2": 11960}
ACCESORIOS = dict(varilla_3_4=10000, tensor_54_2=5300, tensor_54_4=8900, pletina=8900)

# Tabla 42 (alpha = 60 grados, angulo 30 con la vertical): {cable: {grupo_poste: [(A,B,C) banda1, banda2, banda3]}}
# Bandas medidas desde la cima: <=1,2 m | 1,2 a 2,2 m | > 2,2 m (el documento rotula la 3a como "> 3,0 m": entre 2,2 y 3,0 no esta definido).
TABLA42 = {
 "3/8": {"500-735": [(0.11,1.54,1.82),(0.16,1.46,1.69),(0.19,1.40,1.62)],
         "1030-1324": [(0.21,1.37,1.65),(0.24,1.32,1.44),(0.33,1.16,1.56)]},
 "1/2": {"500-735": [(0.06,1.63,1.88),(0.09,1.58,1.82),(0.11,1.54,1.78)],
         "1030-1324": [(0.12,1.51,1.75),(0.14,1.48,1.71),(0.21,1.38,1.59)]},
}

def coef(cable: str, rotura: float, y_cima: float):
    grupo = "500-735" if rotura <= 735 else "1030-1324" if rotura <= 1324 else None
    if grupo is None:
        raise ValueError("Tabla 42 solo cubre postes de 500 a 1324 daN")
    banda = 0 if y_cima <= 1.2 else 1 if y_cima <= 2.2 else 2
    aviso = "banda 2,2-3,0 m no definida en Tabla 42: se uso la de > 3,0 m" if 2.2 < y_cima < 3.0 else ""
    return TABLA42[cable][grupo][banda] + (aviso,)

def retenida_bisectora(poste: str, cable: str, Fh: float, y_cima: float, FTVC: float, FTVP: float,
                       PC: float = 0.0, FTEC: float = 0.0, FTEE: float = 0.0, FLEE: float = 0.0,
                       hip: str = "normal"):
    """Verifica poste + retenida. Fh: tiro horizontal resultante que se retiene (daN).
    hip: 'normal' (FL, factor 2,5) o 'anormal' (ANC, factor 1,5). Devuelve dict con comprobaciones."""
    poste = P.normalizar_poste(poste)
    ERF = P.rotura(poste); HN = P.hN(poste)
    Hj = P.altura_libre(poste) - y_cima + 0.0            # altura del punto de la retenida sobre el suelo
    A, B, C, aviso = coef(cable, ERF, y_cima)
    f = 2.5 if hip == "normal" else 1.5
    RU = CABLE[cable]
    FRES = A*Fh*Hj/HN
    flex = f*math.hypot(FTEC + FTVC + FTVP + FTEE, FRES)
    FVERT = B*Fh + PC
    # Tabla 46/36: vertical ultimo en hN, hN-0.4, hN-0.8, hN-3.3; se toma el nivel de la tabla igual o mas alto que el punto de la retenida
    prof = y_cima - 0.2                       # profundidad del punto bajo hN (la cima esta 0,2 m sobre hN)
    PU = None
    if poste in P.TABLA36:
        pus = P.TABLA36[poste][2:6]; niveles = (0.0, 0.4, 0.8, 3.3)
        PU = pus[max(i for i, nv in enumerate(niveles) if nv <= max(prof, 0.0) + 1e-9)]
    tir = 1.5*C*Fh
    T0 = max(2*abs(A*Fh - ERF/f), 0.05*RU)
    chk = [dict(nombre="Flexion del poste (residual absorbido)", solicitado=flex, capacidad=ERF, ok=flex <= ERF),
           dict(nombre="Tiro del cable de retenida", solicitado=tir, capacidad=RU, ok=tir <= RU)]
    if PU:
        chk.append(dict(nombre="Compresion del poste (1,2*Fvert <= 3*PU, B6.1)", solicitado=1.2*FVERT, capacidad=3*PU, ok=1.2*FVERT <= 3*PU))
    acc = [k for k, v in ACCESORIOS.items() if tir > v]
    return dict(poste=poste, cable=cable, A=A, B=B, C=C, Fh=Fh, FRES=FRES, FVERT=FVERT, tiro=tir, pretension=T0, y_cima=y_cima,
                verificaciones=chk, ok=all(c["ok"] for c in chk), accesorios_insuficientes=acc, aviso=aviso)

def seleccionar_retenida(poste, Fh, y_cima, FTVC, FTVP, PC=0.0, **kw):
    """Primer cable (3/8 -> 1/2) que cumple; None si ninguno."""
    ultimo = None
    for cable in ("3/8", "1/2"):
        r = retenida_bisectora(poste, cable, Fh, y_cima, FTVC, FTVP, PC, **kw)
        ultimo = r
        if r["ok"] and not r["accesorios_insuficientes"]: return r
    return ultimo
