# Salones 6B y 7B — recreación realista para Roblox Studio

Script único en Luau (`Salones_Realistas.lua`) que reconstruye, en un solo pegado en la
**Command Bar** de Roblox Studio (modo edición), los dos salones de las fotografías de
referencia: la fachada del corredor con las puertas **6B** (verde) y **7B** (metálica blanca),
y los dos interiores completos.

## Cómo usarlo

1. Abrir el lugar en Roblox Studio (modo edición) y mostrar la Command Bar (`Vista > Command Bar`).
2. Copiar **todo** el contenido de `Salones_Realistas.lua`, pegarlo en la Command Bar y pulsar Enter.
3. Aparece `workspace.Salones_Realistas` con `Estructura`, `Corredor`, `Salon_1_6B` y `Salon_2_7B`.
   En la ventana **Output** se imprime el resumen (salones, BaseParts por modelo, advertencias).
4. Para mover la construcción cambiar `ORIGEN` (studs) al principio del script; para cambiar
   la escala, `ESCALA` (studs por metro). Todas las medidas internas están en metros.
5. Volver a ejecutar el script reemplaza únicamente el modelo generado por él (lo reconoce por
   el atributo `GeneradoPorScriptSalones`); nunca toca otros objetos del mapa. `Ctrl+Z` deshace
   la generación completa (se registran waypoints en ChangeHistoryService).

Si ocurre un error o se supera el límite de 1000 BaseParts, el script elimina la construcción
parcial y lo reporta en Output.

## Interpretación de la distribución (análisis de las fotos)

Sistema de referencia fijo: observador de pie en el corredor mirando la fachada de frente.
`+X` es su derecha, la fachada está en `Z = 0`, los salones en `Z < 0`, el corredor en `Z > 0`.

- **Fachada (foto real).** De izquierda a derecha: panel de bloques calados (ventilación) con la
  ventana de marco de madera rojo oscuro encima, muro blanco, **puerta 6B** (hoja verde lisa con
  cuatro lápices colgando del borde superior, rótulo "6B" y pomo a la izquierda), **columna**
  entre las dos puertas (donde la medianera llega a la fachada), **puerta 7B** (lámina metálica
  blanca con 3 × 7 paneles cuadrados estampados, rótulo "7B" en forma de lápiz morado, manija a
  la derecha, umbral de cemento) y el letrero verde "Ruta de evacuación" con flecha hacia la
  izquierda sobre el tercio derecho de la puerta 7B. Arriba, la losa del corredor cubierto con la
  canaleta eléctrica; abajo, baldosa terracota con franja de cemento gris junto al muro.
- **Posición de los salones.** Las dos puertas están a sólo ~0,4 m una de otra, separadas por la
  columna: por lo tanto el salón **6B queda a la IZQUIERDA** y el **7B a la DERECHA**, comparten
  la pared medianera, y cada puerta está en el extremo de su fachada más próximo a la medianera.
  La ventana y el calado de 6B quedan a la izquierda de su puerta (como en la foto); para 7B,
  cuya fachada no aparece completa, se usa la disposición espejo (ventana a la derecha de su
  puerta, 0,36 m más lejos de la puerta que en 6B porque la foto muestra ~0,7 m de muro liso a la
  derecha de la puerta 7B).
- **Interior (render).** La pared con la ventana de marco rojo y el aire acondicionado es la
  **fachada** vista desde dentro (coincide con la ventana de marco de madera de la foto exterior).
  La cámara del render está junto a la puerta mirando hacia la pared extrema: los cinco carteles
  colgados del riel están en la **pared extrema opuesta a la medianera**, el escritorio de madera
  aparece al fondo a la derecha junto a la **pared trasera** (opuesta a la fachada) y los pupitres
  azules miran hacia la cámara, es decir, hacia la **medianera** (lado de la puerta). En la imagen
  del escritorio, la silla negra está pegada a la pared trasera y el tablero blanco está en esa
  misma pared a la derecha del escritorio (las pendientes de la línea de zócalo y del borde del
  tablero muestran la esquina trasera-extrema del salón detrás del escritorio). El script
  reproduce exactamente esa relación.
- **7B** se construye como espejo de 6B respecto a la medianera (misma geometría, posiciones
  reflejadas, objetos no reflejados): puerta junto a la medianera, tablero y escritorio en la
  pared trasera, carteles en la pared extrema derecha, pupitres mirando hacia la medianera.

## Elementos no visibles y valores por defecto (no confirmados por las fotos)

- Largo interior 7,5 m, fondo 6,5 m, altura libre 3,0 m, muros 0,15 m (estimados por proporción).
- Fachada de 7B a la derecha de su puerta (ventana, calado, aire acondicionado) = espejo de 6B.
- Fachada de 6B a la izquierda de la ventana: muro blanco liso (en la foto se corta ahí; el
  fragmento de mural pintado del borde izquierdo no se reproduce).
- Ancho del corredor cubierto 2,2 m; la losa de cubierta vuela sobre él sin columnas exteriores.
- Grosor y patrón exacto del calado: rejilla 5 × 4 bloques con cruz central (4 aberturas por
  bloque), con vista real a través de ella.
- Vidrio de la ventana esmerilado (en la foto es opaco; en el render interior es claro).
- Texto pequeño bajo "6B": ilegible en la foto; se escribió "MISS LICETH", que es la lectura más
  probable. Cambiarlo en una sola línea si no corresponde.
- Textos del riel y de los carteles: sólo marcas genéricas (en el render son ilegibles).
- Hojas de puerta cerradas (el sentido de apertura no se ve).

## Presupuesto de Parts (resultado real de la ejecución)

| Modelo | BaseParts |
|---|---|
| Estructura (pisos, muros ciegos, medianera, losa) | 9 |
| Corredor (baldosa, franja, columna, canaleta, 2 vigas) | 8 |
| Salon_1_6B (fachada 67 · techo 58 · acabados 17 · mobiliario 235) | 377 |
| Salon_2_7B (fachada 102 · techo 58 · acabados 17 · mobiliario 235) | 412 |
| **Total** | **806 / 1000** |

Desglose por salón: 20 pupitres × 11 parts, escritorio 6, silla del profesor 9, 10 vigas,
9 luminarias fluorescentes × 4, 4 plafones redondos, 2 ventiladores de jaula × 4, aire
acondicionado 3, interruptor 1, tablero 3, carteles 7 + riel 1, canaletas 2, ventana 9, calado 20,
puerta 6B 20 (hoja, marco 3, 12 piezas de lápices, pomo, pegatina) o puerta 7B 51 (hoja, marco 3,
umbral, 42 piezas de paneles, rótulo 3, manija 2) y letrero 1, más los tramos de muro de fachada.
Todos los textos (6B, 7B, letrero, riel) son `SurfaceGui` + `TextLabel`: 0 Parts.

### Cómo verificar el recuento real después de ejecutar

El propio script lo imprime en Output. Para comprobarlo de forma independiente, pegar en la
Command Bar:

```lua
local n = 0
for _, d in ipairs(workspace.Salones_Realistas:GetDescendants()) do
	if d:IsA("BasePart") then n = n + 1 end
end
print("BaseParts en Salones_Realistas:", n)
```

## Escala

`ESCALA = 4` studs por metro: puertas de 3,8 × 8,6 studs (un avatar R15 de 5 studs pasa con
holgura), escritorio a 3 studs de altura, asientos a 1,9 studs, techo a 12 studs.
