"""Calculo mecanico de conductores MT - Proyecto Tipo Afinia/Caribemar (MT sin neutro, v1 2020).

Unidades: m, mm, mm2, daN, daN/m, daN/mm2, grados C.
Referencias: Memoria cap. 8 y Anexo B3 del Proyecto Tipo.
"""
from __future__ import annotations
import math
from dataclasses import dataclass

# ---------------------------------------------------------------- conductores
# Tablas 7 y 8 de la Memoria. E y alfa: ver notas en references/conductores.md
@dataclass(frozen=True)
class Conductor:
    nombre: str
    S: float        # seccion total mm2
    d: float        # diametro mm
    pc: float       # peso daN/m
    CR: float       # carga de rotura daN
    E: float        # modulo elasticidad daN/mm2
    alfa: float     # dilatacion 1/C
    lim: dict       # limites %CR: max, red (viento reducido), tmin, tmax, texc, eds, chs, reducido

def _lim(mx, eds, chs, red=8.0):
    return dict(vmax=mx, vred=mx, tmin=mx, tmax=mx, texc=mx, eds=eds, chs=chs, reducido=red)

CONDUCTORES = {
    "ACSR 336.4 (LINNET)":   Conductor("ACSR 336.4 (LINNET)", 198.17, 18.29, 0.6747, 6270, 7700, 18.9e-6, _lim(17.5, 12.5, 12.0)),
    "ACSR 266.8 (PARTRIDGE)":Conductor("ACSR 266.8 (PARTRIDGE)", 157.21, 16.307, 0.5355, 5028, 7700, 18.9e-6, _lim(21.5, 13.0, 11.5)),
    "ACSR 4/0 (PENGUIN)":   Conductor("ACSR 4/0 (PENGUIN)", 125.09, 14.31, 0.4246, 3716, 8100, 19.1e-6, _lim(29.5, 13.5, 12.5)),
    "ACSR 1/0 (RAVEN)":     Conductor("ACSR 1/0 (RAVEN)", 62.43, 10.109, 0.2118, 1949, 8100, 19.1e-6, _lim(33.0, 15.0, 12.0)),
    "ACSR 477 (HAWK)":      Conductor("ACSR 477 (HAWK)", 280.86, 21.793, 0.9561, 8677, 7700, 18.9e-6, _lim(12.5, 12.0, 12.0)),
    "AAAC 394.5 (CANTON)":  Conductor("AAAC 394.5 (CANTON)", 199.91, 18.30, 0.5379, 5860, 6300, 23e-6, _lim(18.5, 12.5, 10.0)),
    "AAAC 312.8 (BUTTE)":   Conductor("AAAC 312.8 (BUTTE)", 158.58, 16.30, 0.4267, 4650, 6300, 23e-6, _lim(23.5, 13.0, 10.0)),
    "AAAC 246.9 (ALLIANCE)":Conductor("AAAC 246.9 (ALLIANCE)", 125.08, 14.31, 0.3366, 3780, 6300, 23e-6, _lim(29.0, 13.5, 10.0)),
    "AAAC 123.3 (AZUSA)":   Conductor("AAAC 123.3 (AZUSA)", 62.43, 10.11, 0.1680, 1890, 6300, 23e-6, _lim(33.0, 15.0, 9.5)),
    "AAAC 559.5 (DARIEN)":  Conductor("AAAC 559.5 (DARIEN)", 283.66, 21.8, 0.7631, 8310, 6300, 23e-6, _lim(13.0, 10.0, 9.0)),
}

# ---------------------------------------------------------------- viento
# Tabla 27: sobrecarga Q0 (daN/m2) por zona y area. (viento maximo 20C, reducido 28C)
Q0_MAX = {("A","rural"):74.54, ("A","urbana"):37.11, ("B","rural"):47.32,
          ("B","urbana"):20.87, ("C","rural"):30.28, ("C","urbana"):14.49}
Q0_RED = {("A","rural"):26.83, ("A","urbana"):13.36, ("B","rural"):17.03,
          ("B","urbana"):7.51, ("C","rural"):10.90, ("C","urbana"):5.22}

def p_aparente(c: Conductor, Q0: float) -> float:
    """p = sqrt(pc^2 + pv^2), pv = Q0*d*1e-3 (Memoria 8.3)."""
    pv = Q0 * c.d * 1e-3
    return math.hypot(c.pc, pv)

# ---------------------------------------------------------------- hipotesis
# nombre: (temperatura C, usa viento max / reducido / ninguno)
HIPOTESIS = {
    "vmax": (20.0, "max"), "vred": (28.0, "red"), "tmin": (15.0, None),
    "tmax": (50.0, None), "texc": (75.0, None), "eds": (28.0, None), "chs": (18.0, None),
}

# ---------------------------------------------------------------- mecanica
def cambio_estado(c: Conductor, a: float, T1: float, p1: float, th1: float,
                  p2: float, th2: float) -> float:
    """Ecuacion de cambio de condiciones (Anexo B3.2) para vano nivelado, k=1.
    T = componente horizontal (daN). Resuelve por Cardano (unica raiz real positiva)."""
    S, E, al = c.S, c.E, c.alfa
    A = al*(th2-th1)*S*E + a*a*p1*p1*S*E/(24*T1*T1) - T1
    B = a*a*p2*p2*S*E/24
    # T2^2 (T2 + A) = B
    Q = -A*A/9
    R = B/2 - A**3/27
    D = Q**3 + R*R
    if D > 0:
        s = math.copysign(abs(R + math.sqrt(D))**(1/3), R + math.sqrt(D))
        t = math.copysign(abs(R - math.sqrt(D))**(1/3), R - math.sqrt(D))
        return s + t - A/3
    return 2*math.sqrt(-Q)*math.cos(math.acos(R/math.sqrt(-Q**3))/3) - A/3

def flecha(T: float, p: float, a: float) -> float:
    return T/p*(math.cosh(a*p/(2*T)) - 1)

def vano_regulador(vanos, desniveles=None):
    """Vano ideal de regulacion (Memoria 8.4). Con desniveles aplica el factor k de Truxa."""
    if desniveles is None:
        desniveles = [0.0]*len(vanos)
    ap = [math.hypot(a, b) for a, b in zip(vanos, desniveles)]
    num = sum(a**3 for a in vanos)
    den = sum(a for a in vanos)
    ar = math.sqrt(num/den)
    s3 = sum(x**3/a**2 for x, a in zip(ap, vanos)); s2 = sum(x**2/a for x, a in zip(ap, vanos))
    k = s3/s2 if s2 else 1.0
    return k*ar if desniveles and any(desniveles) else ar

def tabla_vano(c: Conductor, zona: str, area: str, a: float, tense: str = "normal"):
    """Tensiones horizontales To y flechas en cada hipotesis para un vano regulador `a`.
    Estado inicial: el que, fijado en su limite, deja todos los demas dentro de su limite
    (el mas restrictivo). Devuelve dict hipotesis -> (To, f, p, %CR) y el estado que gobierna."""
    Qm, Qr = Q0_MAX[(zona, area)], Q0_RED[(zona, area)]
    p_hip = {"vmax": p_aparente(c, Qm), "vred": p_aparente(c, Qr)}
    for h in ("tmin", "tmax", "texc", "eds", "chs"):
        p_hip[h] = c.pc
    lim = {h: c.lim[h]/100*c.CR for h in HIPOTESIS}
    if tense == "reducido":      # unica condicion inicial CHS 8%
        arranques = ["chs"]; lim["chs"] = c.lim["reducido"]/100*c.CR
    else:
        arranques = list(HIPOTESIS)
    mejor = None
    for h0 in arranques:
        th0 = HIPOTESIS[h0][0]
        res = {h0: lim[h0]}
        for h, (th, _) in HIPOTESIS.items():
            if h != h0:
                res[h] = cambio_estado(c, a, lim[h0], p_hip[h0], th0, p_hip[h], th)
        if all(res[h] <= lim[h] + 1e-6 for h in HIPOTESIS):
            # el mas restrictivo = el de menor tension en el estado mas flojo: elegimos el que
            # produce mayores tensiones sin exceder limites (se cumple solo para el gobernante)
            if mejor is None or sum(res.values()) > sum(mejor[1].values()):
                mejor = (h0, res)
    h0, res = mejor
    out = {h: dict(To=res[h], p=p_hip[h], f=flecha(res[h], p_hip[h], a),
                   pct=res[h]/c.CR*100, C=res[h]/p_hip[h]) for h in HIPOTESIS}
    return h0, out


def tabla_tendido(c: Conductor, zona: str, area: str, ar: float, tense: str = "normal",
                  temps=range(5, 55, 5)):
    """Tabla de tendido (Memoria 8.5/8.7): To y flecha del vano regulador `ar` a cada
    temperatura, sin viento. Parte del estado gobernante de tabla_vano."""
    h0, o = tabla_vano(c, zona, area, ar, tense)
    T0, p0, th0 = o[h0]["To"], o[h0]["p"], HIPOTESIS[h0][0]
    filas = []
    for th in temps:
        T = cambio_estado(c, ar, T0, p0, th0, c.pc, th)
        filas.append(dict(temp=th, To=T, f=flecha(T, c.pc, ar), pct=T/c.CR*100))
    return filas


def flecha_vano_en_canton(fr: float, a: float, b: float, ar: float) -> float:
    """Flecha del vano i del canton (Memoria 8.7): fi = fr * (a*a'/ar^2), a' = sqrt(a^2+b^2).
    Valida si a<300 m, b/a<0.2 y f/a<0.05; si no, usar el metodo exacto (B3.2.3)."""
    ap = math.hypot(a, b)
    return fr * (a * ap / ar**2)


def parabola(C: float, x: float) -> float:
    """Curva de plantillado y = x^2 / (2C) (Memoria 8.6); C = parametro de catenaria (m)."""
    return x * x / (2 * C)


def peso_aparente_tabla(c: Conductor, zona: str, area: str):
    """pv y p (Tablas 29 y 30) para viento maximo."""
    Q = Q0_MAX[(zona, area)]
    return Q * c.d * 1e-3, p_aparente(c, Q)
