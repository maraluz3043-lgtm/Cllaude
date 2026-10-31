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
| Esfuerzos en postes y **decisión autosoportado / retenida** (AL, ANG, ANC, FL; método simplificado Tabla 37) | Hecho (`scripts/postes.py`) con el catálogo Afinia ES.03396.TR (27 postes de 9 a 16 m); falta torsión de postes ≥1600 daN y vertical |
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

## Autosoportado vs. retenida (importante)
Un fin de línea o anclaje **no requiere retenida por ser FL/ANC**: se verifica primero el poste autosoportado
(Memoria 9.1). `postes.evaluar(Apoyo(...))` devuelve el veredicto («AUTOSOPORTADO - no requiere retenida» o
«REQUIERE RETENIDA») con el uso de cada comprobación; `postes.poste_minimo_autosoportado(...)` propone el poste
más liviano que sí resiste. Solo si ninguno cumple se pasa a retenida. (El Excel de Efraím marca «R» a todo FL
porque `Esf M.T.!AC` tiene `IF(U="FL","R",...)`.) Probar con `python3 -I scripts/test_postes.py`.

## Reglas al reportar
- Indicar zona (A/B/C), área (rural/urbana), tipo de tense (normal/reducido), conductor y el estado gobernante.
- Tense reducido solo para área urbana y cantones con vano regulador ≤ 50 m; si no se cumplen distancias, usar tense normal.
- Decir qué verificaciones están hechas y cuáles no (esfuerzos en postes, retenidas y cimentaciones aún no están en la skill).
- Si un resultado difiere del Excel del usuario, explicar la causa (hipótesis, interpolación, factores) antes de corregir nada.

## Postes: fuente de datos
- Catálogo, diámetros y carga de rotura: **Afinia ES.03396.TR «Postes de hormigón centrifugado o vibrado»** (ed. 1, 25/01/2021). Acepta nombres `HP-12-1030`, `HP-12-1030 daN` o `PH-12/1030`.
- Empotramiento Le = L/10 + 0,6 m (línea de empotramiento de la ficha del ES.03396.TR); el Excel de COLISEO usa +0,5.
- Viento sobre el poste: Tabla 32 del Proyecto Tipo si el poste está; si no (9, 10 y 16 m), se calcula con Anexo B2.3 (reproduce la Tabla 32 con mediana 1,4 % de error; el resultado lo marca como «calculado»).
- No hay en ninguno de los dos documentos el momento de torsión de los postes ≥1600 daN: pedir el dato al fabricante.
- Zona de viento: el Proyecto Tipo la da por mapas por departamento (Anexo A1.1, imágenes). Zona «costera» = **zona A** (terreno tipo I, 130 km/h rural / 80 urbana). COLISEO DEL NORTE (Cartagena rural, costera) = **zona A rural**.
- Afinia y EPM comparten normas: ET-TD-ME04-01 (EPM) confirma cargas de rotura y empotramiento (NTC 1329, L/10+0,6) y tampoco trae torsión.

## Evaluar un proyecto completo
`python3 -I scripts/proyecto.py <libro.xlsx> A rural` lee la hoja «Ingreso» del Excel, arma las líneas (nueva línea en cada FL marcado «I»), los cantones (terminan en FL; usar `--amarres APOYO1,APOYO2` para dividir en ángulos con amarre), calcula ángulos desde las coordenadas y evalúa cada apoyo con su poste. Los «AC» del Excel se tratan como ANG; un AL con deflexión > 5° se evalúa como ANG. No incluye aún el transformador (FTEE/FLEE: ver Proyecto Tipo de Centros de Transformación tipo poste).
