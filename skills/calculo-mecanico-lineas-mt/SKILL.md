---
name: calculo-mecanico-lineas-mt
description: Calcular y verificar el diseño mecánico de líneas aéreas de media tensión (13,2 y 34,5 kV, sin neutro) según el Proyecto Tipo Afinia/Caribemar v1 2020 — vano regulador, ecuación de cambio de estado, tablas de cálculo mecánico y de tendido, flechas, curvas de plantillado y (en desarrollo) esfuerzos en postes, retenidas y cimentaciones. Usar cuando Efraím pida calcular tensiones, flechas, tablas de tendido, cantones o verificar apoyos de una red MT aérea, o comparar contra su Excel de cálculos mecánicos.
---

# Cálculo mecánico de líneas MT (Proyecto Tipo Afinia)

Criterio base: **Proyecto Tipo Afinia/Caribemar de líneas aéreas MT sin neutro (v1, 01/10/2020)**. El Excel
"Calculos Mecanicos M.T." de Efraím se usa como caso de validación, no como criterio (usa otras
hipótesis; ver `references/excel_coliseo.md`).

## Estado
| Módulo | Estado |
|---|---|
| Conductores, viento por zona/área, hipótesis y límites %CR | Hecho |
| Vano regulador (con factor de Truxá), cambio de estado (Cardano), flechas, tablas de tendido, plantillado | Hecho y validado |
| Esfuerzos en postes (eolovano, gravivano, ANG/ANC/FL, factores 2,5/1,5/1,2) | Pendiente |
| Retenidas (coeficientes A, B, C) y cimentaciones (Anexo B7/B8) | Pendiente |
| Lectura de tabla de apoyos + coordenadas (hoja "Ingreso") y salida a Excel | Pendiente |

## Cómo usar
1. Leer `references/metodo.md` (ecuaciones y criterios) y `references/conductores.md` (datos).
2. Importar `scripts/mecanica.py` (Python 3, solo librería estándar):
   - `tabla_vano(conductor, zona, area, vano, tense)` → tensión horizontal, flecha, parámetro y %CR por hipótesis, y el estado gobernante.
   - `vano_regulador(vanos, desniveles)` → vano ideal de regulación.
   - `tabla_tendido(...)` → tensión y flecha por temperatura, sin viento.
   - `flecha_vano_en_canton(...)` → flecha de cada vano del cantón (válida si a<300 m, b/a<0,2, f/a<0,05; si no, método exacto B3.2.3).
3. Ejemplo: `python3 -I scripts/ejemplo_canton.py`.
4. Validar siempre que se toque el modelo: `python3 -I scripts/validar_anexoA.py <texto del Proyecto Tipo>`
   compara contra las Tablas A3 del Anexo A (90 tablas, 11.550 valores; error máximo 0,28 %).

## Reglas al reportar
- Indicar zona (A/B/C), área (rural/urbana), tipo de tense (normal/reducido), conductor y el estado gobernante.
- Tense reducido solo para área urbana y cantones con vano regulador ≤ 50 m; si no se cumplen distancias, usar tense normal.
- Decir qué verificaciones están hechas y cuáles no (esfuerzos en postes, retenidas y cimentaciones aún no están en la skill).
- Si un resultado difiere del Excel del usuario, explicar la causa (hipótesis, interpolación, factores) antes de corregir nada.
