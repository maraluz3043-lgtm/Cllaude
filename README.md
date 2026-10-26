# Salones faltantes de la planta baja + portón blanco (modelos .rbxm para Roblox Studio)

Generados a partir del archivo `Donde_pondras_los_salones_faltantes.rbxm` (edificio de dos pisos, 12 270 BaseParts) y de las
cuatro fotos de referencia. Los tres vanos marcados en rojo en la captura (vanos 1, 3 y 6 de la planta baja) reciben
las puertas de los tres salones: **"GRADO 5°"** (puerta morada con mariposas, foto 1), **"CUARTO"** (puerta azul con luna
y estrellas, foto 2) y **"6C"** (puerta metálica blanca abierta, foto 3). Los interiores siguen a los tres salones del piso
superior del mismo archivo (pupitres silla-tableta azules y de madera, mesa y silla docente, tablero, carteleras, ventiladores
de pared y techo, split, luminarias fluorescentes, cielo raso PVC, papelera, armario…) pero remodelados con muchas menos parts.

## Archivos

| Archivo | Contenido | Parts |
|---|---|---|
| `modelos/Salones_Planta_Baja.rbxm` | Los 3 salones con fachada (puertas, calados, medias ventanas, afiches, condensadores, maceta) e interiores completos, más los tramos de muro de fachada de reemplazo con los huecos de puerta | **2 245** (16 fachada + 789 + 658 + 782) |
| `modelos/Porton_Blanco.rbxm` | El portón metálico blanco de la foto 4 (modelo independiente) | 256 |
| `modelos/Edificio_Completo_con_Salones.rbxm` | El edificio original completo **ya con los salones integrados** (muros de fachada cortados, ventanas de los vanos de puerta retiradas) | 14 487 (12 270 originales − 28 reemplazadas + 2 245) |
| `modelos/*.rbxmx` | Las mismas piezas en formato XML (por si una versión de Studio rechazara el binario) | — |

## Opción A (recomendada): usar el edificio completo
1. En Roblox Studio, en el Explorer, clic derecho sobre `Workspace` → **Insert from File…** → `Edificio_Completo_con_Salones.rbxm`.
2. Borrar el edificio anterior (el modelo `Model` original). Listo: queda en el mismo sitio y con la misma orientación.

## Opción B: insertar solo los salones en el edificio que ya tienes
1. `Workspace` → **Insert from File…** → `Salones_Planta_Baja.rbxm`. Debe quedar exactamente en su sitio (coordenadas
   absolutas del edificio). Si Studio lo insertara desplazado, pegar en la **Command Bar**:
   ```lua
   workspace.Salones_Planta_Baja:PivotTo(CFrame.new(36.7170, 0.4200, -1485.3511, -0.021994, 0, -0.999756, 0, 1, 0, 0.999754, 0, -0.021996))
   ```
2. Retirar del edificio original las piezas que el modelo reemplaza (los dos muros de fachada macizos, sus zócalos y las tres
   ventanas de los vanos donde ahora hay puertas). Pegar en la Command Bar:
   ```lua
   local objetivos = {
     {"MuroFrontal",   Vector3.new(36.97, 6.52, -1456.14)}, {"MuroFrontal",   Vector3.new(35.62, 6.52, -1394.35)},
     {"ZocaloFrontal", Vector3.new(36.42, 0.82, -1456.15)}, {"ZocaloFrontal", Vector3.new(35.07, 0.82, -1394.36)},
   }
   local ventanas = { Vector3.new(36.69, 9.02, -1468.15), Vector3.new(36.16, 9.02, -1444.15), Vector3.new(35.33, 9.02, -1406.36) }
   local borrados = 0
   for _, d in ipairs(workspace:GetDescendants()) do
     if d:IsA("BasePart") then
       for _, t in ipairs(objetivos) do
         if d.Name == t[1] and (d.Position - t[2]).Magnitude < 1.5 and not d:IsDescendantOf(workspace.Salones_Planta_Baja) then d:Destroy(); borrados += 1 end
       end
     elseif d:IsA("Model") and d.Name:match("^Aula_%d") then
       local v = d:FindFirstChild("Vidrio")
       if v then for _, p in ipairs(ventanas) do if (v.Position - p).Magnitude < 1.5 then d:Destroy(); borrados += 1 end end end
     end
   end
   print("Piezas reemplazadas borradas:", borrados, "(deben ser 7)")
   ```
3. El portón: **Insert from File…** → `Porton_Blanco.rbxm` y moverlo donde corresponda (está a 40 studs delante de la
   esquina izquierda del edificio; su pivote está en el centro de su base).

## Distribución
Coordenadas en el marco del edificio (u = a lo largo de la fachada, desde la primera columna; 1 m ≈ 4 studs).

| Salón | Puerta | Vanos | Ancho interior | Interior |
|---|---|---|---|---|
| **Salon_1_Grado5** (789 parts) | morada con 9 mariposas y rótulo "GRADO 5°", cerrada, bisagra izquierda; calado + ventana alta a su derecha con el condensador del aire encima (como en la foto 1) | 0-2 | 34,7 studs | 20 pupitres azules en 5 filas de 4 mirando al tablero de la pared derecha; mesa docente de madera con silla azul; 2 carteleras (HORARIO, VALORES), afiches, reloj, bandera; 2 ventiladores de pared + 1 de techo, split, 6 luminarias, armario, papelera, escoba, dispensador de agua, mochila |
| **Salon_2_Cuarto** (658 parts) | azul con luna y estrellas y rótulo "CUARTO", cerrada; maceta con palma en la acera; calado + media ventana a su derecha | 3-4 | 22,7 studs | 15 pupitres de madera en 3 filas de 5 mirando al tablero de la pared del fondo; escritorio metálico crema con silla negra; carteleras y afiches, reloj, bandera; ventiladores en las paredes laterales + techo, split, 4 luminarias, armario, papelera, escoba, dispensador, mochila |
| **Salon_3_6C** (782 parts) | metálica blanca con paneles en relieve 3×7 y rótulo "6C", **abierta 75° hacia dentro** (foto 3); calado + ventana completa a su izquierda, afiche en la ventana de la derecha | 5-7 | 34,7 studs | 20 pupitres azules en 5 filas de 4 mirando al tablero de la pared izquierda; mesa de madera + silla azul; carteleras, afiches, reloj, bandera; 2 ventiladores de pared + techo, split, 6 luminarias, armario, papelera, escoba, dispensador, mochila |

Común a los tres: piso de baldosa cerámica terracota, zócalo rojo, paredes en yeso blanco (pieles de 4 cm sobre el concreto
existente), tabiques nuevos de 0,6 studs sobre las columnas u = 35,19 y u = 96,98, cielo raso de tablillas PVC con moldura,
canaleta eléctrica, interruptor junto a la puerta, tomas, ventanas interiores con marco naranja y vidrio claro en la cara interior
del muro de fachada y calados vistos desde dentro. Todos los pupitres y sillas tienen `Seat` (el avatar puede sentarse);
las hojas de puerta cerradas no colisionan para poder entrar; textos y dibujos planos (rótulos, afiches, carteleras, rejillas,
carátula del reloj, troquelado del portón) son `SurfaceGui`/`Frame`/`TextLabel` y no cuentan como parts.

Vistas de comprobación en `preview_salones/` (alzado de la fachada, planta e interior de cada salón, detalle de cada puerta, portón).

## Cómo se generó
Scripts Python en `tools/` (lector/escritor del formato binario .rbxm, librería de construcción en el marco local del edificio,
módulos de componentes y ensamblador). Requiere Python 3 con `numpy`, `pillow` y `lz4`. Con el archivo original del edificio:
`RBXM_ORIGINAL=/ruta/Donde_pondras_los_salones_faltantes.rbxm python3 export_all.py <carpeta_salida>` (desde `tools/`) regenera los tres modelos y
`python3 final_renders.py <carpeta>` las vistas. Los módulos `comp_*.py` tienen un `selftest()` que renderiza cada pieza.


---

# (Entrega anterior) Salones 6B y 7B — recreación realista para Roblox Studio

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
   el atributo `GeneradoPorScriptSalones`, aunque se haya renombrado o movido dentro de Workspace);
   nunca toca otros objetos del mapa. `Ctrl+Z` deshace la generación completa (se registra en
   ChangeHistoryService).

Si ocurre un error o se supera el límite de 1000 BaseParts, el script elimina la construcción
parcial, deja intacto el modelo anterior y lo reporta en Output. Si en Workspace ya hay un objeto
ajeno llamado `Salones_Realistas`, el nuevo modelo se llama `Salones_Realistas_generado`.

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
  colgados del riel están en la **pared extrema opuesta a la medianera**, la pared de la derecha es
  la **pared trasera** (opuesta a la fachada) y los pupitres azules miran hacia la cámara, es decir,
  hacia la **medianera**, que es el frente de la clase (la pared de la puerta).
- **Escritorio y tablero (imagen 1).** Las pendientes de la línea de zócalo y del borde del tablero
  muestran una esquina justo detrás del escritorio: la silla negra está contra la pared trasera y el
  tablero empieza en esa esquina sobre la pared perpendicular. Combinado con lo anterior, el tablero
  queda en la **medianera** (desde la esquina trasera hacia la fachada, 2,4 m) y el escritorio en la
  **esquina trasera junto a la medianera**, con la silla entre el escritorio y la pared trasera. Así
  los pupitres miran al tablero y la puerta queda en la esquina delantera de esa misma pared. (En el
  render interior el escritorio aparece al fondo a la derecha; se prioriza la imagen 1, que es la
  referencia explícita del escritorio y el tablero. Para moverlo basta cambiar una línea en
  `ETAPA 7`.)
- **7B** se construye como espejo de 6B respecto a la medianera (misma geometría, posiciones
  reflejadas, objetos no reflejados): puerta junto a la medianera, tablero y escritorio contra la
  medianera, carteles en la pared extrema derecha, pupitres mirando hacia la medianera. Los dos
  tableros quedan espalda con espalda en el muro compartido.

## Elementos no visibles y valores por defecto (no confirmados por las fotos)

- Largo interior 7,5 m, fondo 6,5 m, altura libre 3,0 m, muros 0,15 m (estimados por proporción).
- Anchos de puerta: 6B 0,84 m de hueco (hoja 0,74 m; en la foto la verde mide ~0,85 de la metálica),
  7B 0,96 m (hoja 0,86 m); ambas de 2,15 m de alto, con 0,39 m entre hojas y la columna en medio.
- Las hojas se construyen cerradas (como en la foto) pero sin colisión, para que el avatar pueda entrar.
- La ventana se modela según la foto (un solo panel opaco de 0,95 × 1,20 m con marco de dos tonos);
  el render interior muestra una ventana mayor de tres paños, pero la foto real tiene prioridad.
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
| Estructura (piso, muros ciegos en dos capas, medianera, losa) | 9 |
| Corredor (baldosa, franja de cemento, columna, canaleta en 2 tramos) | 5 |
| Salon_1_6B (fachada 67 · techo 58 · acabados 17 · mobiliario 235) | 377 |
| Salon_2_7B (fachada 102 · techo 58 · acabados 17 · mobiliario 235) | 412 |
| **Total** | **803 / 1000** |

Desglose por salón: 20 pupitres × 11 parts, escritorio 6, silla del profesor 9, 10 vigas,
9 luminarias fluorescentes × 4, 4 plafones redondos, 2 ventiladores de jaula × 4, aire
acondicionado 3, interruptor 1, tablero 3, carteles 7 + riel 1, canaletas 2, ventana 9, calado 20,
puerta 6B 20 (hoja, marco 3, 12 piezas de lápices, pomo, pegatina) o puerta 7B 51 (hoja, marco 3,
umbral, 42 piezas de paneles, rótulo 3, manija 2) y letrero 1, caja eléctrica 2, más los tramos de
muro de fachada (dos capas: piel exterior blanca y capa interior gris).
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

`ESCALA = 4` studs por metro: luz libre de puertas de 3,0 (6B) y 3,4 (7B) × 8,4 studs (el
HumanoidRootPart de 2 studs pasa; las hojas cerradas no colisionan), pasillos entre filas de
pupitres ≥ 2,9 studs, escritorio a 3 studs de altura, asientos a 1,9 studs, techo a 12 studs.
