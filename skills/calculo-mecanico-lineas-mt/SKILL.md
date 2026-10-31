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
| Retenidas bisectoras (Tabla 42) y cimentaciones de postes (Sulzberger, Anexo B7) | Hecho (`retenidas.py`, `cimentacion.py`) |
| Anclas de las retenidas (Anexo B8.2) | Pendiente: las fórmulas salen ilegibles del texto extraído; falta la página del PDF o el ancla estándar Afinia |
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

## Criterios de modelado de Efraím (consultores Afinia)
- Cruce de vía / esquina de ~90°: el poste se toma como **dos fines de línea** (`EPP4` y `EPP4A`, mismo punto, cada uno con su cantón), no como ángulo corrido. Cada FL requiere **una sola retenida**, o ninguna si es autosoportado.
- Poste con doble armado: se modela como otro poste con el mismo nombre terminado en `A` (mismas coordenadas).
- Marcas de cantón: `I` = inicio, `F` = final. Un FL sin marca en medio de un tramo se evalúa como ANC (anclaje).
- El plano DXF del proyecto trae tipo, poste, armado y longitud de cada vano (ver `references/plano_coliseo.md`); el CSV acepta la columna `vano_sig` para usar esos vanos. `--tipo EPP7=AL` cambia el tipo de un apoyo.
- **Una retenida por poste físico**: en una esquina (X + XA) la retenida bisectora resiste la *resultante* de los tiros de ambos FL (`retenidas.py`, Tabla 42 con cable 3/8\" o 1/2\", flexión del poste, tiro del cable, compresión con 3·PU y pretensionado). Salida: sección «RETENIDAS por poste físico» de `proyecto.py`. Opciones: `--existentes EPE01,EPE03` (no se diseñan), `--bandera EPP5A,EPP6,EPP7,EPP8 --t <m>` (configuración bandera; `t` = distancia del conductor más lejano al eje, de la cruceta de 2,4 m; las posiciones intermedias se suponen cada 0,6 m).
- Retenida con poste auxiliar a tierra (Figura 6): se calcula igual que la retenida normal; el dimensionamiento del poste auxiliar no está en el método simplificado.
- Pendiente (mejora): verificar el poste físico con los esfuerzos combinados de sus dos armados (X + XA); hoy se evalúan por separado, como en el Excel.

## Evaluar un proyecto completo
Entrada: libro Excel con hoja «Ingreso» o un CSV (`ejemplos/coliseo_ingreso.csv`: apoyo,tipo,marca,calibre,x,y,largo,rotura,kva,tipo_trafo).
`python3 -I scripts/proyecto.py <libro.xlsx> A rural` lee la hoja «Ingreso» del Excel, arma las líneas (nueva línea en cada FL marcado «I»), los cantones (terminan en FL; usar `--amarres APOYO1,APOYO2` para dividir en ángulos con amarre), calcula ángulos desde las coordenadas y evalúa cada apoyo con su poste. Los «AC» del Excel se tratan como ANG; un AL con deflexión > 5° se evalúa como ANG. No incluye aún el transformador (FTEE/FLEE: ver Proyecto Tipo de Centros de Transformación tipo poste).

## Cimentaciones
`python3 -I scripts/proyecto.py <csv> A rural ... --terreno normal` agrega la sección CIMENTACIONES: monobloque cilíndrico, Sulzberger (B7.4.1), F = rotura/2,5, CS ≥ 1,0, tan α = 0,01, c = 0,375; Ch y Ck = C2·h/2 con C2 = 8/12/16 daN/cm³ (flojo/normal/duro, como el Excel) y presión admisible de diseño 1,0/2,0/4,0 daN/cm² (Tabla B7.2; Efraím adoptó este valor por no haber estudio de suelos, al ir la cimentación en hormigón). Ancho mínimo = diámetro de base + 0,20 m; profundidad mínima = empotramiento (L/10+0,6) + solado 0,10 m. Pesos de poste tomados del Excel (verificar con el fabricante). El Excel usa Ch constante (no escala con la profundidad) y F = R/2.

**Entregable:** `scripts/exportar_cimentaciones.py <csv> A rural normal <salida.xlsx> --existentes ... --bandera ... --t ... --proyecto "NOMBRE"` genera la tabla de cimentaciones (formato hoja `Ciment`: apoyo, tipo de cimentación, d, h, volúmenes, Mv, Me, CS) con hoja de supuestos. Los apoyos `A` comparten el poste físico y no suman volumen. Ejemplo generado: `entregables/Tabla_Cimentaciones_COLISEO_DEL_NORTE.xlsx`.
