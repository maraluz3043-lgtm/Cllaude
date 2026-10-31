"""Ejemplo: canton con vanos 60, 80, 70 m, RAVEN, zona A urbana. Uso: python3 -I ejemplo_canton.py"""
import sys; sys.path.insert(0, __file__.rsplit('/', 1)[0])
import mecanica as m
c = m.CONDUCTORES["ACSR 1/0 (RAVEN)"]
vanos = [60, 80, 70]
ar = m.vano_regulador(vanos)
h0, o = m.tabla_vano(c, "A", "urbana", ar)
print(f"Vano regulador {ar:.1f} m | estado gobernante: {h0}")
for h, r in o.items():
    print(f"  {h:5s} To={r['To']:7.1f} daN  {r['pct']:5.1f}%CR  f={r['f']:.2f} m  C={r['C']:.0f} m")
print("Tabla de tendido (sin viento):")
for f in m.tabla_tendido(c, "A", "urbana", ar):
    print(f"  {f['temp']:3d} C  To={f['To']:6.1f} daN  f={f['f']:.2f} m")
print("Flechas por vano a 50 C:", [round(m.flecha_vano_en_canton(o['tmax']['f'], a, 0, ar), 2) for a in vanos])
