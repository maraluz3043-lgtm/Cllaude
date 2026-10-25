# PROMPT — Casa comunal de madera con patio · Roblox Studio (Command Bar)

> **Versión 1 (borrador).** Las secciones marcadas con ⚠️ **PENDIENTE DE VERIFICAR** se están confirmando contra las
> fotos y se completarán en la versión final. Todo lo demás es definitivo.

---

## 0. CÓMO USAR ESTE PROMPT

Adjunta junto a este texto las **10 fotos de referencia** con estos nombres exactos (son las únicas válidas):

| ID | Archivo | Qué muestra (resumen) |
|---|---|---|
| F1 | `cafetería_rústica_vacía_de_madera.png` | Interior: desde la sala de piso naranja hacia la zona de servicio (mostrador de acero) y la escalera vista por detrás, con la puerta de madera del fondo |
| F2 | `exterior_desde_cancha.png` | Exterior REAL desde la cancha vecina: segundo piso de madera a dos aguas, anexo blanco de mampostería, anexo bajo con techo de teja, muro bajo con malla |
| F3 | `indoor_wide_angle_interior_scene_of_a_traditional.png` | Interior: poste grueso en primer plano; a la izquierda el salón de piso beige; a la derecha un rincón de piso naranja con ventana de cajones horizontales |
| F4 | `salón_comunitario_de_madera_vacío.png` | Interior: salón de piso beige, escalera al altillo en primer plano, cocina al fondo bajo el altillo, arcos de madera |
| F5 | `wide_angle_high_resolution_interior_photo_of_a_co.png` | Interior: sala naranja mirando hacia la doble puerta abierta al patio |
| F6 | `wide_angle_high_resolution_interior_photo_of_a_tr.png` | Interior: sala naranja mirando hacia su pared del extremo (ventanas a la cocina) |
| F7 | `wide_angle_outdoor_courtyard_scene_of_a_residentia.png` | Exterior: fachada principal con corredor de baldosa roja y postes negros, desde el patio |
| F8 | `wide_detailed_high_resolution_photo_of_an_indoor.png` | Desde el corredor, a través de la doble puerta abierta: sala naranja, escalera al fondo, congeladores |
| F9 | `wide_outdoor_courtyard_backyard_scene_in_daylight.png` | Exterior: patio a lo largo del corredor, anexo con techo de teja y pérgola, columpio |
| F10 | `wide_outdoor_courtyard_yard_scene_in_daylight_pho.png` | Exterior: fachada desde el lado del anexo blanco, árbol, cilindros de gas, caneca |

Las fotos F1 y F3–F10 son gran angular/panorámicas (mejoradas con IA): una pared recta puede verse curva o parecer que
dobla una esquina. F2 es una foto real sin distorsión. Antes de construir, **estudia cada foto con este texto al lado**.

---

## 1. ROL Y OBJETIVO

Eres un constructor experto de Roblox Studio y programador Luau. Escribe **un único script para la Command Bar** que
construya **la casa completa de las fotos, interior y exterior, con su patio**, de forma **realista, detallada y
fiel**: cada espacio, muro, ventana, calado, celosía, poste, viga, escalera, mueble, objeto y planta en su sitio exacto,
con sus colores y materiales, como si las fotos se hubieran tomado dentro del juego.

## 2. REGLAS DE ORO

1. **Nada de lados confundidos.** Usa SIEMPRE el sistema de coordenadas de la sección 4. Cada "izquierda/derecha" del
   texto está acompañada de su eje (±X, ±Z). Si una foto parece contradecir el texto, gana el texto (ya está verificado
   cruzando todas las fotos).
2. **Fidelidad antes que invención.** No agregues espacios, muebles ni adornos que no estén en las fotos. Lo que no se ve
   se resuelve con la opción más sencilla y coherente con lo visible (y se indica en un comentario del código).
3. **Límite de piezas: 5000 BaseParts como máximo absoluto, pero usa EL MÍNIMO POSIBLE con el MÁXIMO DETALLE, todo
   optimizado.** El límite es un techo de seguridad, no una meta. Ver sección 3, punto 2.
4. **Todo une con todo**: muros que tocan techos, vigas apoyadas en postes, escalera que llega al altillo, corredor
   pegado a la fachada, sin huecos ni piezas flotando ni atravesadas.
5. **El código debe funcionar a la primera**: sin errores de sintaxis, sin APIs inexistentes, sin assets externos.

---

## 3. REQUISITOS TÉCNICOS (Roblox Studio · Command Bar)

1. Un solo bloque de código Luau, completo, que se pega en la Command Bar de Roblox Studio (modo edición, sin Play) y se
   ejecuta con Enter. Nada de plugins, módulos externos, `require` de assets, `MeshId`, `TextureId` ni IDs de la
   biblioteca: todo con `Instance.new`.
2. **PIEZAS**: el límite DURO es 5000 BaseParts (Part, WedgePart, CornerWedgePart, TrussPart y UnionOperation cuentan),
   pero la recomendación es usar **el mínimo posible de piezas con el máximo detalle posible y todo optimizado**: lograr
   el mismo realismo con menos piezas. Lleva un contador en la función que crea cada pieza; si se supera 5000,
   `error()` y la construcción parcial se elimina. Al final imprime en Output el total y el desglose por zona.
   Reglas de optimización obligatorias:
   - Una sola pieza por superficie continua (un muro liso sin vanos = 1 pieza; un tramo entre vanos = 1 pieza; el piso
     de un espacio = 1 pieza). Nunca muros hechos de tablas sueltas ni pisos de baldosas sueltas.
   - El detalle repetitivo (juntas de baldosa, rombos del piso naranja, tablillas machihembradas, celosía diagonal,
     cuadrícula de vidrios, letreros) va en `SurfaceGui` + `Frame` / `UIGridLayout` / `UIStroke` / `UIGradient`
     (0 piezas) siempre que se vea bien. Solo se modela con piezas lo que tiene volumen y se ve de cerca: marcos, postes,
     vigas, peldaños, barandas y muebles.
   - Muebles repetidos (sillas plásticas, mesas plegables, sillas apiladas, macetas) con una función constructora
     reutilizable y el número mínimo de piezas que conserve su silueta reconocible.
   - Rendimiento: `CastShadow = false`, `CanTouch = false` y `CanQuery = false` en piezas decorativas pequeñas;
     `CanCollide = false` en todo lo que no deba ser obstáculo; nada de piezas invisibles innecesarias, duplicadas o
     superpuestas; luces (`PointLight`/`SurfaceLight`) solo donde hay una lámpara real, con `Shadows = false` salvo las
     principales.
   - Antes de añadir una pieza: ¿se nota si no está, o se resuelve con SurfaceGui o con el color/material de una pieza
     que ya existe? Si no se nota, no se crea.
3. **Idempotente y seguro**: al ejecutarse de nuevo reemplaza SOLO el modelo que él mismo creó (identificado por el
   atributo `GeneradoPorScriptCasaMadera = true`, aunque se haya renombrado o movido) y nunca borra otros objetos. Si algo
   falla, el modelo anterior queda intacto. Registra la operación en `ChangeHistoryService` (un solo Ctrl+Z la deshace).
   Toda la construcción dentro de `xpcall` con mensajes `warn` claros.
4. Todas las piezas `Anchored = true` y superficies lisas (`TopSurface`/`BottomSurface` = Smooth). `CanCollide = true`
   en pisos, muros, escalones, barandas y muebles grandes; `false` en celosías, rejillas, cables, hojas, vidrios
   decorativos, cadenas y letras.
5. **Unidades**: todo el texto está en METROS. El script trabaja en metros y convierte con `ESCALA` (studs por metro)
   = 3.57 (1 stud = 0.28 m, la escala oficial de Roblox; puertas de 2.1 m = 7.5 studs, el avatar pasa). Una constante
   `ORIGEN` (Vector3, en studs) mueve todo el conjunto; el piso interior terminado queda en `ORIGEN.Y`.
6. **Funciones auxiliares obligatorias** (ninguna coordenada suelta fuera de ellas):
   - `caja(nombre, x0,x1, y0,y1, z0,z1, props, padre)`: pieza alineada a ejes definida por sus límites en metros.
   - `vigaEntre(nombre, puntoA, puntoB, ancho, alto, props, padre)`: pieza larga entre dos puntos (cerchas, largueros de
     escalera, pasamanos, diagonales, cadenas, ramas).
   - `cilindro(nombre, puntoA, puntoB, diametro, props, padre)` y `cuña(...)` (WedgePart) para techos y pendientes.
   - `rotulo(part, cara, texto, props)` con `SurfaceGui` + `TextLabel` (0 piezas).
   - `patron(part, cara, tipo, parametros)` para dibujar con SurfaceGui juntas de baldosa, rombos, tablillas y celosías.
7. **Materiales nativos**: `Wood`, `WoodPlanks`, `Concrete`, `Brick`, `Metal`, `DiamondPlate`, `Glass`,
   `SmoothPlastic`, `Plastic`, `Fabric`, `Slate`, `Pavement`, `Grass`, `LeafyGrass`, `Ground`, `CorrodedMetal`, `Neon`.
   Materiales más nuevos (`CeramicTiles`, `ClayRoofTiles`, `RoofShingles`, `Plaster`, `Rubber`) solo con una función
   segura: `local function mat(n, alterno) local ok, m = pcall(function() return Enum.Material[n] end) return ok and m or alterno end`.
8. **Iluminación**: cada plafón LED redondo = disco `Neon` blanco + `PointLight` (blanco frío, Range ≈ 4–5 m). No
   cambies `Lighting` global.
9. **Jerarquía** dentro de `workspace.CasaMadera`: `Terreno_y_Patio`, `Estructura`, `Techos`, `Corredor`,
   `Sala_Naranja`, `Zona_Servicio`, `Salon_Principal`, `Cocina`, `Escalera_y_Altillo`, `Zona_Tras_Escalera`,
   `Volumen_Superior`, `Anexos`, `Mobiliario_Exterior`, `Vegetacion`, `Iluminacion`. Cada mueble es un `Model` con
   nombre descriptivo y `PrimaryPart`.
10. **Transitable**: puertas abiertas como en las fotos (o sin colisión), escalera caminable (peldaños con colisión,
    huella ≥ 0.25 m, contrahuella 0.18–0.20 m), altillo transitable con su baranda.
11. **Sin z-fighting**: separa caras coplanares al menos 0.005 m (zócalos, marcos, baldosas, letreros, vidrios).

---

## 4. SISTEMA DE COORDENADAS (fijo, no lo cambies)

- **Fachada principal** = la fachada larga de madera con el **corredor de baldosa roja y postes metálicos negros** que
  da al **patio de concreto** (F7, F10). Observador de pie en el patio, mirando esa fachada de frente.
- **+X = DERECHA de ese observador**, a lo largo de la fachada. **+Y = arriba**.
- La cara exterior del muro de fachada está en **Z = 0**. **El interior de la casa está en Z < 0**; el corredor y el patio
  en **Z > 0**.
- **X = 0 en el centro de la doble puerta de media vidriera** de esa fachada. **Y = 0 = piso interior terminado**.
- Giros (Y arriba): mirando hacia −Z tu derecha es +X; mirando hacia +Z tu derecha es −X; mirando hacia −X tu derecha
  es −Z; mirando hacia +X tu derecha es +Z.
- En el script: `P(x, y, z)` convierte metros del edificio a studs del mundo (`Vector3.new(x, y, z) * ESCALA + ORIGEN`).
  Es un sistema derecho igual al de Roblox, así que no hay que invertir ningún eje.

---

## 5. LA CASA EN UNA FRASE

Casa/salón comunal de una planta con altillo, **toda de madera barnizada color caoba** (muros de tablas machihembradas
verticales, postes gruesos, vigas a la vista, cielo raso machihembrado), con **franjas altas de celosía diagonal** sobre
casi todas las ventanas y puertas, **calados de bloques y de cajones** en lugar de muros ciegos en la fachada,
**piso naranja con rombos** en la sala de entrada, **piso beige** en el salón y la zona de servicio, **cocina de azulejo
blanco con piso rojo** en un anexo de mampostería blanca, **corredor exterior de baldosa roja** con postes metálicos
negros y techo de fibrocemento, y un **volumen superior de madera a dos aguas**. Frente a ella, un **patio de concreto**
con árbol, cilindros de gas, plantas en matera, un anexo blanco con techo de teja y pérgola, un **columpio** y muros
perimetrales blancos.

---

## 6. PLANTA Y UBICACIÓN DE CADA ESPACIO

### 6.1 Fachada principal (Z = 0), de −X a +X (vista desde el patio)

1. Extremo izquierdo (−X): el muro lateral de la sala naranja asoma hacia una esquina exterior donde están la **palma en
   matera** y, junto al anexo blanco, los **cilindros de gas**. Ese muro lateral tiene **2 ventanas de cuadrícula** de
   vidrio (marco oscuro).
2. **Calado de bloques de madera** (rejilla de cajones rectangulares en hiladas trabadas, ≈ 2.2 m de ancho, desde
   ≈ 0.9 m hasta ≈ 2.1 m de altura) sobre muro de tablas verticales, con **franja de celosía diagonal** encima.
3. **Ventana angosta de cuadrícula** (≈ 0.35 m de ancho, alta) pegada a la puerta.
4. **Doble puerta de media vidriera** (X = 0): dos hojas de ≈ 0.75 m, mitad superior con **cuadrícula de vidrio de 3 × 4
   paños con marco negro**, mitad inferior de **tablas verticales**; pasador, cerrojo de barra y argolla con cordón;
   **abiertas hacia fuera** (hacia +Z), cada hoja girada ≈ 100° contra la fachada. Celosía diagonal sobre el dintel.
5. **Ventana angosta de cuadrícula** al otro lado de la puerta.
6. **Calado de cajones horizontales** (dos paneles, cada uno ≈ 5 columnas × 6 filas de cajones apaisados, marcos
   oscuros), con celosía diagonal encima y muro de tablas abajo. Delante, sobre el corredor: **3 congeladores
   horizontales blancos** (dos abajo, uno encima) y un **saco de fique/papel** apoyado.
7. ⚠️ **PENDIENTE DE VERIFICAR**: tramo de fachada del salón principal hacia +X (ventana de persianas de vidrio, ventanas
   de cuadrícula, paneles de celosía de arabescos) y el **postigo de lamas de madera** del extremo derecho.

### 6.2 Corredor (Z de 0 a ≈ +2.4)

- Piso de **baldosa roja (≈ 0.40 × 0.40 m) con junta gris claro** ancha, borde de ladrillo rojo/cemento hacia el patio.
- **Postes metálicos negros** de sección cuadrada (≈ 0.10 m), separados ≈ 2.5–3 m, sobre el borde exterior.
- Viga-fascia de madera oscura sobre los postes; **cielo de tablas machihembradas con cabios a la vista**
  perpendiculares a la fachada; cubierta de **fibrocemento ondulado gris** con caída hacia el patio (+Z).
- **Plantas en materas negras** a lo largo del borde (crotos, palmas, helechos).

### 6.3 Sala naranja (entrada)

- Detrás de la doble puerta. Piso **naranja con rombos** (baldosa ≈ 0.45 m con un rombo inscrito de tono más claro y
  juntas finas oscuras).
- **Pared del extremo −X**: parte sur (junto a la fachada) con **2 ventanas de cuadrícula** que dan al exterior (se ven
  plantas); parte norte con **2 ventanas grandes de vidrio liso** que dan a la **cocina** (azulejo blanco). Debajo, un
  **router blanco con antenas**, un tomacorriente y un cable.
- Contra la fachada, bajo el calado de cajones (+X de la puerta): **silla de oficina azul** (patas negras) y **2 sillas
  plásticas blancas** de respaldo perforado.
- Contra la fachada, −X de la puerta: **silla infantil** (respaldo verde, asiento rojo, patas blancas).
- Rincón entre la fachada y la pared −X: **papelera negra**; junto a la pared −X: **cojín redondo negro** en el piso.
- Hacia −Z la sala se abre a la zona de servicio y al salón mediante **postes gruesos** (≈ 0.20 × 0.20 m, con
  **interruptor beige**), una **media pared con marco abierto/repisa** y vigas de borde del altillo.
- ⚠️ **PENDIENTE DE VERIFICAR**: medidas exactas y límite +X de la sala naranja (rincón con ventana de cajones de F3).

### 6.4 Zona de servicio (piso beige, detrás de la sala naranja hacia −Z)

- **Mostrador baño maría de acero inoxidable** (≈ 2.4 × 0.8 m, 0.9 m de alto, vitrina de vidrio curvo encima y patas).
- **Caneca plástica blanca con ruedas** y **tapete negro** junto a la pared con ventanas hacia la cocina.
- Pared hacia la cocina con **4 ventanas de vidrio** en fila sobre muro de tablas.

### 6.5 Escalera, altillo y "la otra zona" detrás de la escalera

- **Escalera de madera** de un tramo recto, ≈ 1.0 m de ancho, ≈ 14–15 peldaños de huella oscura, largueros macizos,
  **pasamanos de madera sobre postes** en el lado abierto, sube al **altillo**.
- **Altillo/mezanine** sobre la parte −X/−Z: borde con viga gruesa, **baranda de madera** (pasamanos, 2 largueros y
  balaustres planos verticales) y objetos guardados (letras grandes rojas/amarillas, cajas). Bajo el altillo: **paneles
  de celosía diagonal en marcos con arco** y una mesa plegable.
- **Detrás de la escalera**: zona de piso beige con la **puerta de madera oscura de tablero** en el muro del fondo,
  **bolsas negras de basura**, una **silla plástica blanca** bajo la escalera, un **poste oscuro** y una **cartelera de
  marco verde** apoyada en la pared.
- ⚠️ **PENDIENTE DE VERIFICAR**: posición exacta del pie y la llegada de la escalera y sentido de subida en ejes.

### 6.6 Cocina (anexo de mampostería, lado −X)

- Muros con **azulejo blanco** (≈ 0.20 m), piso de **baldosa roja terracota con junta blanca**.
- **Ventana con reja de rombos/cuadrícula blanca**, **mueble-lavaplatos de madera oscura** con mesón, **barriles azules**,
  **nevera portátil roja**, licuadora y freidora, recipientes azules sobre el mesón.
- Se ve desde la sala naranja y la zona de servicio a través de las ventanas de vidrio, y desde el salón por un **arco**
  bajo el altillo, junto a una **puerta exterior color salmón** abierta.

### 6.7 Salón principal (piso beige) ⚠️ PENDIENTE DE VERIFICAR (ubicación exacta)

- Piso **beige/crema** (baldosa ≈ 0.33 m, junta gris clara, brillante).
- **Postes gruesos con ménsulas en arco** (arcos de madera curvos entre poste y viga), **vigas principales pintadas de
  negro** y vigas secundarias de madera, cielo machihembrado; zona central de **doble altura** con muro alto de tablas,
  **aplique redondo** y **ventilador de techo de aspas de madera**.
- **3 ventiladores oscilantes de pared/techo** blancos colgados de las vigas; **≈ 8 plafones LED redondos**.
- Muro con: **nicho bajo arco con ventana de celosía diagonal** y mesas plegables, **rejilla de ventilación de
  barrotes**, **ventana de persianas de vidrio con extractor** en el paño izquierdo y **postigos de madera** a ambos
  lados, **cuadro de paisaje**, interruptor.
- **Mesas plegables blancas** (≈ 1.8 × 0.75 m), **sillas plásticas blancas** sueltas y **2 pilas de sillas apiladas**
  (≈ 12 cada una), **cámara de seguridad** en una esquina.

---

## 7. EXTERIOR Y PATIO

- **Patio de concreto** gris (agrietado, con charcos más oscuros), frente al corredor.
- **Árbol del patio** de tronco delgado anaranjado y copa de hojas compuestas, entre el anexo blanco y la fachada, con
  piedras sueltas al pie.
- **Anexo blanco de mampostería** (cocina) a −X, techo de lámina ondulada; ventana grande con malla metálica; **2
  cilindros de gas azules** con manguera amarilla delante; **caneca verde azulada con ruedas** cerca.
- **Volumen superior de madera** (tablas verticales color miel/anaranjado) con **techo a dos aguas** de lámina, aleros
  con canecillos, ventanas con postigos de lamas (F2).
- **Anexo bajo con techo de teja** y muros anaranjados (F2, a la izquierda), ventanas pequeñas.
- Frente a la casa, al otro lado del patio: **anexo blanco largo con techo de teja de barro**, **pérgola** con postes
  negros, **baranda de celosía de madera**, **plantas colgantes** y materas en un escalón de baldosa; ventanas y puerta
  con **marcos rojos**.
- **Columpio** de tubo negro en A con **2 asientos verde azulado** y cadenas, entre **2 árboles**, junto al **muro
  perimetral blanco** (≈ 2.5 m, con manchas de humedad); **panel perforado blanco**, **escalera de aluminio** apoyada.
- **Muro bajo blanco con malla eslabonada** sobre marcos de tubo negro hacia la cancha vecina (F2).
- ⚠️ **PENDIENTE DE VERIFICAR**: distancias del patio, posición de cada anexo y del volumen superior respecto a la casa.

---

## 8. PALETA DE COLORES (RGB) Y MATERIALES

| Elemento | RGB | Material Roblox |
|---|---|---|
| Madera barnizada de muros interiores (caoba) | 112, 52, 28 | WoodPlanks |
| Postes, marcos y vigas de madera (más oscuro) | 80, 36, 20 | Wood |
| Cielo raso machihembrado (miel) | 150, 78, 38 | WoodPlanks |
| Vigas principales pintadas de negro | 32, 28, 26 | SmoothPlastic |
| Madera exterior de fachada (chocolate) | 78, 44, 30 | WoodPlanks |
| Madera del volumen superior (miel anaranjada) | 172, 98, 48 | WoodPlanks |
| Marcos de ventanas de cuadrícula | 28, 24, 22 | Wood |
| Piso naranja / rombo claro / junta | 204, 110, 52 / 226, 146, 82 / 150, 74, 38 | CeramicTiles (alterno SmoothPlastic) |
| Piso beige / junta | 226, 214, 184 / 190, 180, 160 | CeramicTiles |
| Baldosa roja del corredor / junta gris | 150, 46, 36 / 160, 160, 155 | CeramicTiles |
| Piso de cocina terracota / junta blanca | 166, 56, 40 / 230, 230, 225 | CeramicTiles |
| Azulejo blanco de cocina | 236, 236, 232 | CeramicTiles |
| Postes metálicos del corredor y columpio | 30, 30, 32 | Metal |
| Fibrocemento ondulado | 150, 150, 146 | Slate |
| Teja de barro | 176, 82, 50 | ClayRoofTiles (alterno Brick) |
| Muros blancos de mampostería | 230, 228, 220 | Plaster (alterno Concrete) |
| Concreto del patio | 148, 144, 134 | Concrete |
| Acero inoxidable | 192, 194, 198 | Metal |
| Plástico blanco (sillas, mesas) | 236, 236, 230 | SmoothPlastic |
| Silla azul de oficina | 42, 82, 170 | Fabric |
| Cilindros de gas | 30, 80, 170 | Metal |
| Asientos del columpio | 40, 150, 170 | SmoothPlastic |
| Tronco del árbol del patio | 182, 102, 70 | Wood |
| Follaje | 70, 130, 50 | LeafyGrass |

---

## 9. CÓMO CONSTRUIR CADA TIPO DE ELEMENTO CON POCAS PIEZAS

- **Muro de tablas verticales**: 1 pieza por tramo + SurfaceGui con franjas verticales finas oscuras cada ≈ 0.10 m en
  ambas caras visibles; zócalo de 1 pieza.
- **Celosía diagonal**: pieza transparente con dos SurfaceGui (cara interior y exterior) de listones rotados ±45° de
  ≈ 0.03 m cada ≈ 0.10 m; marco perimetral de 4 piezas finas (o 2 si se reaprovechan dintel y viga).
- **Calado de bloques / de cajones**: marco + listones horizontales y verticales como piezas finas (es volumétrico y se
  ve de cerca), con el número de filas y columnas indicado.
- **Ventana de cuadrícula**: vidrio de 1 pieza (`Glass`, Transparency ≈ 0.6) + marco perimetral de 4 piezas + parteluces
  en SurfaceGui o piezas finas.
- **Piso con rombos y juntas**: 1 pieza + SurfaceGui con `UIGridLayout` (celda = baldosa, rombo = Frame rotado 45°).
- **Silla plástica**: asiento, respaldo (con perforaciones en SurfaceGui), 4 patas; **silla apilada**: una pila = un
  bloque de asientos escalonados + respaldos, no sillas enteras repetidas.
- **Mesa plegable**: tablero + 2 caballetes en A de tubo.
- **Ventilador oscilante**: soporte, motor (cilindro), rejilla (cilindro corto con SurfaceGui de radios).
- **Planta en matera**: matera cónica (cilindro) + 3–6 hojas (piezas finas rotadas) o una copa simple.
- **Árbol**: tronco en 2–4 tramos (`vigaEntre`) + 3–6 masas de follaje (`Ball`/bloques, `LeafyGrass`).

---

## 10. ORDEN DE CONSTRUCCIÓN

1. Configuración, utilidades, contador, limpieza segura.
2. Terreno y patio → 3. Losa y pisos → 4. Muros con vanos → 5. Postes, vigas, ménsulas, cielo raso → 6. Techos →
7. Corredor → 8. Ventanas, puertas, calados, celosías → 9. Escalera y altillo → 10. Cocina → 11. Mobiliario y objetos →
12. Iluminación → 13. Exterior (anexos, volumen superior, columpio, árboles, plantas, muros) → 14. Resumen en Output.

---

## 11. VERIFICACIÓN FINAL (compruébalo antes de entregar)

- [ ] Desde el patio, mirando la fachada (hacia −Z): a la IZQUIERDA (−X) de la doble puerta, la ventana angosta y el
  calado de bloques; a la DERECHA (+X), la otra ventana angosta, el calado de cajones y los congeladores.
- [ ] Dentro de la sala naranja, mirando hacia −X: la doble puerta queda a la IZQUIERDA (+Z) y la pared del fondo tiene
  2 ventanas de cuadrícula a la izquierda y 2 ventanas a la cocina a la derecha (como F6).
- [ ] Desde el corredor mirando por la doble puerta hacia −Z: sala naranja, media pared con repisa a la izquierda,
  escalera al fondo (como F8).
- [ ] Total de BaseParts impreso en Output ≤ 5000 y lo más bajo posible.
- [ ] Ninguna pieza flotando ni atravesando otra; escalera caminable; puertas transitables.

---

## 12. FORMATO DE TU RESPUESTA

1. El script completo en un solo bloque de código Luau.
2. Debajo: tabla con el número de piezas por zona y la lista de supuestos que tomaste en lo que no se ve.
