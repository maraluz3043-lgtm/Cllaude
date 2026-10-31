# Método (Proyecto Tipo Afinia, Memoria cap. 8-10 y Anexo B)

## Hipótesis (Tabla 27) y límites (Tabla 28)
| Hipótesis | T (°C) | Sobrecarga viento |
|---|---|---|
| Viento máximo (vmax) | 20 | Q0 máx por zona/área |
| Viento reducido (vred) | 28 | Q0 red (0,6·V) |
| Temperatura mínima (tmin) | 15 | — |
| Temperatura máxima (tmax) | 50 | — |
| Máxima excepcional (texc) | 75 | — |
| EDS | 28 | — |
| CHS | 18 | — |

Límites en % de la carga de rotura por conductor: ver `scripts/mecanica.py` (`CONDUCTORES[...].lim`).
Tense reducido: CHS 8 % como única condición inicial (urbano y cantones con vano regulador ≤ 50 m).

Q0 (daN/m²), rural/urbana — vmax: A 74,54/37,11; B 47,32/20,87; C 30,28/14,49 — vred: A 26,83/13,36; B 17,03/7,51; C 10,90/5,22.
Q0 = q0·Cxc·Gc·GL, q0 = (1/20)·τ·μ·(Vmáx/(3,6·1,37))², Gc = 1,75 (tipo I), 1,88 (II), 2,30 (IV); GL = 1 si el vano < 200 m.
(El Proyecto Tipo escribe "·1,37" pero el factor divide; las tablas se reproducen con la división.)

## Conductor
- pv = Q0·d·10⁻³; p = √(pc²+pv²)  (daN/m, d en mm).
- Vano regulador: ar = k·√(Σa³/Σa), k = Σ(a'³/a²)/Σ(a'²/a), a' = √(a²+b²); k=1 en vanos nivelados.
- Cambio de estado (vano nivelado), tercer grado en T2: T2²(T2+A)=B,
  A = α(θ2−θ1)·S·E + ar²p1²·S·E/(24·T1²) − T1;  B = ar²p2²·S·E/24. Raíz por Cardano (B3.2.2).
- Flecha f = (T/p)(cosh(ar·p/(2T)) − 1); parámetro C = T/p; plantillado y = x²/(2C) con C(75 °C) máxima y C(15 °C) mínima.
- Estado inicial: el que, fijado en su límite, deja todos los demás dentro de su límite (el más restrictivo).
- Flecha en vano del cantón: fi = fr·(a·a'/ar²) si a<300, b/a<0,2, f/a<0,05; si no, método exacto (B3.2.3).

## Postes (pendiente de implementar; fórmulas ya leídas, cap. 9)
- Eolovano av=(a1+a2)/2; gravivano con catenaria (B6.2); P = T01·senh(pc·ag1/T01)+T02·senh(pc·ag2/T02).
- F*TVC (AL) = Pv·av·ΣHi/HN; (ANG) = [Pv·av·cos(β/2) + √((T02−T01)²cos²(β/2)+(T02+T01)²sin²(β/2))]·ΣHi/HN; (FL, 9.2.2.6) = Pv·(a/2)·ΣHi/HN, con a = vano anterior (el texto extraído partía la fracción).
- Longitudinal: desequilibrio real |T02−T01|·ΣHi/HN; FL = T0·ΣHi/HN; 50 % = 0,5·máx(T01,T02)·ΣHi/HN; rotura MT = t·máx(T01,T02) a 28 °C + viento reducido.
- Factores: normal 2,5 (flexión), vertical 1,2; anormal 1,5 (flexión y torsión). Resultante R* = √(ΣT*²+ΣL*²) ≤ rotura/2,5.
- HN = altura libre − 0,2 m. Capacidades de postes: Tabla 36 (17 referencias).

## Implementado en postes.py
Flexión normal AL/ANG/FL con 2,5; ANC por hipótesis anormal (1,5·0,5·máx(T01,T02)·ΣHi/HN) o normal si hay desequilibrio importante;
torsión anormal (1,5·t·máx(T01,T02) a 28 °C + viento reducido) para ANC y FL. Altura libre = L − (0,1·L+0,5); HN = altura libre − 0,2.
Datos faltantes en el documento: momento de torsión de los postes ≥ 1600 daN (Tabla 36); allí la torsión queda «pendiente».
Viento en postes: Tabla 32 (Cxp depende de Re, por eso en zona A rural algunos postes dan menos que en urbana: no es un error).
