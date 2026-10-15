# Prompt — Juego «Destapa la Palabra» por niveles (grado transición, castellano)

Este es el prompt con el que se construye el juego `index.html` de esta carpeta
(fuente: `src/page.html`, que `build.sh` envuelve y convierte en `index.html`).
Cópialo completo y pégalo en Claude, ChatGPT o cualquier asistente de IA que escriba código.

Es la **especificación final**: está pensada para que quien la implemente no tenga que
preguntar nada. Donde dice «hoy» o «como hoy» se refiere al juego que ya existe en
`src/page.html` (el de escribir la palabra completa), que se conserva como último nivel.

---

## Prompt

Crea un **juego educativo web en un solo archivo `index.html`** para niños y niñas de
**grado transición (5–6 años, Colombia)** en **castellano**. El objetivo es que el niño
aprenda a reconocer y escribir palabras formadas solo con las **consonantes M, P, S y L** y
las **vocales**.

**MUY IMPORTANTE: es para transición.** Los niños apenas están conociendo las letras y
**no leen** las instrucciones de la pantalla. El juego debe ser **muy fácil al principio** y
subir de dificultad **por niveles**. En los primeros niveles la palabra ya aparece casi
completa (con sus consonantes y vocales puestas) y el niño solo pone **una** letra. Solo en
el último nivel escribe la palabra completa (ese último nivel es exactamente el juego actual).

Dos reglas que atraviesan todo el juego:

- **Todo se dice en voz alta.** Cada instrucción, pista y felicitación que aparece en
  pantalla también la dice la voz del dispositivo. El texto en pantalla es apoyo para la
  profe; el niño juega oyendo y mirando íconos.
- **Nada depende solo de la voz.** Si el equipo no tiene voz en español, el juego sigue
  siendo jugable gracias a las señales visuales: cajita activa con manita 👆, letra fantasma,
  tecla que brilla, ícono fijo en cada mensaje.

### Mecánica base (igual en todos los niveles)

1. **Tarjeta tapada.** Aparece una tarjeta boca abajo con un «?» grande y el texto
   «¡Tócame!», que se menea suavemente. En las **dos primeras tarjetas de cada ronda** la voz
   dice «Toca la tarjeta». Si pasan **10 s** sin tocarla, se menea más amplio y la voz repite
   «Toca la tarjeta» (una sola vez).
2. **Destapar.** Al tocarla, la tarjeta **gira en 3D** y muestra un **dibujo grande** (emoji
   o SVG dibujado en el mismo archivo). Tras el sonido de voltear (≈500 ms) la voz dice, en
   **una sola locución**, la palabra y la consigna del nivel (ver tabla de niveles; por
   ejemplo «Sapo. ¿Qué vocal falta? Sa, po.»). Un botón redondo **🔊** de 56 px, junto al
   mensaje (no dentro de la tarjeta), repite exactamente esa misma locución.
3. **Cajitas de letras.** Debajo aparecen las cajitas de la palabra, **agrupadas por
   sílabas** (separación extra de 10 px entre sílabas, usando el campo `s` de cada palabra:
   `pa-lo-ma` → `PA  LO  MA`).
   - Las letras que el nivel regala están escritas en cajitas **crema** (fijas, sin
     animación).
   - La **cajita activa** (la siguiente vacía, de izquierda a derecha) es inconfundible:
     fondo blanco, borde rosado grueso de 5 px, escala 1.12, late, y debajo tiene una
     **manita 👆** que rebota (pseudo-elemento `::after`, animación de 0.8 s).
   - Las demás cajitas vacías se ven grises y atenuadas (`opacity: .55`), sin borde de color.
   - El relleno es **siempre automático de izquierda a derecha**. Tocar una cajita **no** la
     selecciona: solo hace que la voz diga **su sílaba** (`silabaDe(palabra, i)`, por ejemplo
     tocar la O de SAPO dice «po»). Es la pista más natural para un niño que no lee.
   - Cajita **fantasma**: cuando el nivel o la ayuda lo indiquen, una cajita vacía muestra la
     letra correcta en **gris claro `#d9cfe6`** (como para repisar). El niño debe igualar esa
     forma en el teclado; la letra fantasma nunca cuenta como escrita.
4. **Teclado gigante en pantalla.** Muestra **solo las teclas que ese nivel necesita**
   (ver tabla): vocales A E I O U en amarillo, consonantes M P S L cada una con su color de
   hoy (M rosa, P celeste, S menta, L lila). El color por letra se conserva porque ayuda a
   recordarla.
   - **Niveles 1 a 5:** una **sola fila** de 4 o 5 teclas, **sin tecla ⌫** (la letra mala se
     borra sola). Tamaño: `width: clamp(60px, 17vw, 84px); height: clamp(64px, 17vw, 84px);
     font-size: clamp(32px, 9vw, 44px)` (5 teclas de 60 px más separaciones caben en 360 px).
   - **Nivel 6:** las dos filas de hoy (vocales y consonantes) más la tecla ⌫, con el tamaño
     de hoy.
   - También funciona el **teclado físico** (las 9 letras; `Backspace` solo en el nivel 6).
   - Al tocar una tecla la voz dice el **nombre de la letra**, nunca un sonido aislado (ver
     «Voz»). Si el toque provoca una corrección o una celebración, esa locución reemplaza al
     nombre (solo una locución por toque).
5. **Comprobación.** Hay dos modos:
   - **Por letra (niveles 1 a 5).** Cada letra se comprueba **al tocarla**, comparando con
     `norm(palabra)[i]` de la cajita activa.
     - **Correcta:** la cajita se pone **verde**, salta, queda fija, suena un «tin» corto y
       la voz dice el nombre de la letra. La manita pasa a la siguiente cajita vacía.
     - **Incorrecta:** la letra aparece **300 ms en rojo** solo en esa cajita (el rojo nunca
       dura más de 1 s), la cajita tiembla y **se vacía sola**, suena un «boing» suave, y se
       aplica la **escalera de ayuda** (punto 6). No tiembla toda la fila, no se borra nada
       más, y el texto **nunca usa la palabra «mal»**.
     - Al llenarse la última cajita vacía: **celebración** (punto 7).
   - **Por palabra (nivel 6, como hoy).** Se comprueba cuando todas las cajitas están llenas:
     - **Correcto:** celebración.
     - **Incorrecto:** las cajitas tiemblan, las letras malas se ponen rojas y se borran (las
       buenas se quedan). Mensaje «Casi… ¡inténtalo otra vez! 💪» (voz: «Casi. Inténtalo otra
       vez»). Al segundo error: «Mira las letras rojas… ¿quieres una pista? 💡». Botón 💡
       pone la siguiente letra correcta, como hoy. **Este nivel no cambia en nada.**
6. **Escalera de ayuda (niveles 1 a 5).** Se lleva un contador de errores **por cajita**
   (`estado.errores[i]`) que se reinicia al acertar esa cajita. Hace que el niño **toque él
   mismo** la letra; el juego solo la pone en el último escalón.
   - **1.er error:** la voz dice «Casi. Esa es la {nombre de la tecla tocada}. {sílaba del
     hueco}… {palabra}.» (ejemplo: «Casi. Esa es la a. Po… sapo.»). Sin costo.
   - **2.º error:** la cajita activa muestra la **letra fantasma** correcta, la **tecla
     correcta brilla y late** (clase `.tecla.brilla`: `outline: 5px solid` amarillo oscuro,
     escala 1.15, latido de 0.7 s; se quita al tocar cualquier tecla) y la voz dice «Mira: es
     la {nombre}. Tócala.». Mensaje en pantalla «💡 Mira: es la S». Se espera a que el niño la
     toque; la letra **nunca se pone sola** en este escalón.
   - **3.er error:** el juego **pone la letra**, la cajita se pone verde y la voz dice
     «{nombre}. {sílaba del hueco}… {palabra}.» (ejemplo: «Ese. Sa… sapo.»). El juego sigue
     con la siguiente cajita (o celebra si era la última).
   - **Botón 💡 Pista** (redondo, 56 px, junto al mensaje): sube un escalón de la misma
     escalera para la cajita activa (si está en 0 pasa al escalón 2 directamente: fantasma +
     tecla que brilla; si ya está en 2, pasa al 3).
   - **Inactividad:** si la tarjeta está abierta y pasan **8 s** sin tocar nada, la voz repite
     la locución de destapar y la cajita activa da un salto más grande (clase
     `.caja.recordar`, 0.6 s). Si pasan **8 s más**, se aplica el escalón 2. El temporizador
     se reinicia con cada toque y se cancela al cambiar de tarjeta. Máximo dos recordatorios
     por tarjeta; nunca cuenta regresiva ni mensajes negativos.
7. **Celebración (todos los niveles).** Confeti, sonido alegre, mensaje al azar entre
   «¡Súper! 🌟», «¡Muy bien! 🎉», «¡Eres genial! 💖», «¡Lo lograste! 🦄», «¡Bravo! 🎈»; todas
   las cajitas verdes saltan; se muestran las **sílabas** debajo («SA · PO»); la voz dice las
   sílabas y la palabra: texto pasado a la voz = `sílabas separadas por coma` + «. ¡» +
   palabra + «!» (ejemplo `sa, po. ¡Sapo!`); se suman las estrellas y el dibujo entra con un
   rebote a su tarjetita de progreso. La tarjeta **no se va hasta que la voz termina**
   (`utterance.onend`), con **mínimo 2 s y tope 3 s**; luego se desliza a la izquierda y entra
   la siguiente.
8. **Botón ⏭️ Otra tarjeta:** salta la tarjeta (0 estrellas, tarjetita gris sin número). Es
   de la profe, no del niño: va en la **barra superior** como botón redondo pequeño junto a
   🏠, con `aria-label="Saltar esta tarjeta"` y `title`, lejos del teclado.
9. **Estrellas por tarjeta** (`estado.estrellas` suma; nunca se muestra una resta ni un
   cero):
   - **Niveles 1, 2 y 3:** **siempre 3** por tarjeta completada, haya o no errores o ayuda.
     La pantalla final de estos niveles es siempre una celebración.
   - **Niveles 4 y 5:** empieza en 3; −1 si hubo al menos un error en la tarjeta; −1 si se
     llegó al escalón 2 o 3 en alguna cajita (por errores, por inactividad o por 💡).
     Mínimo 1.
   - **Nivel 6 (como hoy):** `max(1, 3 − pistas − (errores > 0 ? 1 : 0))`.
   - Tarjeta saltada: 0.
10. **Progreso.** Arriba, una fila de tarjetitas: resueltas con su dibujo y sus ⭐, la actual
    late en amarillo, las que faltan con «?». Con 5 o 6 tarjetas cabe completa en 360 px; con
    10 (nivel 6) se desplaza como hoy.

### Los 6 niveles (de más fácil a más difícil)

Orden pedagógico de transición en Colombia: primero igualar formas, luego vocales (que
nombre y sonido coinciden), luego consonantes M, P, S, L. Los grupos de palabras A/B/C se
definen en la sección «Palabras».

| Nivel | Nombre | Qué está puesto y qué pone el niño | Teclado | Tarjetas | Palabras |
|---|---|---|---|---|---|
| 1 🐣 | **Busca la letra** | Toda la palabra puesta menos **una cajita** (posición al azar) que muestra la **letra fantasma** en gris claro. El niño solo iguala la forma: busca esa letra en el teclado. | Una fila: solo **M P S L** si la letra que falta es consonante, solo **A E I O U** si es vocal | 5 | Grupo A |
| 2 🌱 | **Falta una vocal** | Toda la palabra menos **una vocal**: la **última** letra de la palabra; si la palabra **empieza por vocal**, la **primera** (SAP_, MES_, _SO, _LA). Nunca la del medio. | Solo **A E I O U** | 5 | Grupo A |
| 3 🌼 | **La primera letra** | Toda la palabra menos la **primera letra** (siempre una consonante). | Solo **M P S L** | 5 | Grupo A que empieza por consonante |
| 4 🌻 | **Pon las vocales** | Están las consonantes, faltan **todas las vocales**. | Solo **A E I O U** | 6 | Grupos A + B |
| 5 🌳 | **Pon las consonantes** | Están las vocales, faltan **todas las consonantes**. | Solo **M P S L** | 6 | Grupos A + B |
| 6 🏆 | **Toda la palabra** | No hay letras puestas: escribe la palabra completa. **Es el juego actual sin cambios** (dos filas, ⌫, comprobación por palabra, pista que pone letra). | Vocales y M P S L + ⌫ | 10 | Grupos A + B + C |

Mensaje en pantalla y locución al destapar (la voz recibe la cadena entera, con los puntos,
en una sola llamada a `hablar()`; `{p}` es la palabra con tilde, `{sílabas}` son las sílabas
separadas por coma, `{nombre}` es el nombre de la letra):

| Nivel | Mensaje en pantalla | Voz al destapar (y al tocar 🔊) |
|---|---|---|
| 1 🐣 | «🐣 Busca esta letra 👇» | «{p}. Busca la letra {nombre}.» → «Sapo. Busca la letra ese.» |
| 2 🌱 | «🌱 ¿Qué vocal falta? 👇» | «{p}. ¿Qué vocal falta? {sílabas}.» → «Sapo. ¿Qué vocal falta? Sa, po.» |
| 3 🌼 | «🌼 ¿Con qué letra empieza? 👇» | «{p}. ¿Con qué letra empieza? {primera sílaba}… {p}.» → «Sapo. ¿Con qué letra empieza? Sa… sapo.» |
| 4 🌻 | «🌻 Pon las vocales 👇» | «{p}. Pon las vocales de {p}.» |
| 5 🌳 | «🌳 Pon las consonantes 👇» | «{p}. Pon las consonantes de {p}.» |
| 6 🏆 | «🏆 Escribe la palabra 👇» | «{p}. Escribe {p}.» |

Reglas por nivel que no admiten interpretación:

- **Nivel 1:** si la tecla tocada es incorrecta, la cajita tiembla y la voz dice «Esa es la
  {nombre tocada}. Busca la {nombre correcta}.»; en el segundo error la tecla correcta brilla;
  en el tercero el juego la pone (misma escalera, pero el escalón 1 usa esa frase en vez de
  la sílaba). Al acertar, celebración de inmediato (solo hay una cajita).
- **Nivel 2:** la vocal que falta se elige por la regla de la tabla, no al azar. Al barajar
  la ronda se intenta (una pasada simple) que dos tarjetas seguidas no tengan la misma vocal
  faltante.
- **Nivel 3:** solo palabras que empiezan por M, P, S o L. Se intenta que dos tarjetas
  seguidas no empiecen por la misma consonante.
- **Niveles 4 y 5:** las cajitas vacías se llenan de izquierda a derecha, una por una, con
  comprobación por letra.
- **Nivel 6:** idéntico al juego actual. Ni el teclado, ni la comprobación, ni la pista, ni
  las estrellas cambian.
- En el código: una tabla `NIVELES` con un objeto por nivel
  `{id, nombre, emoji, teclas:'vocales'|'cons'|'todas'|'segunLetra', chequeo:'letra'|'palabra',
  tarjetas, grupos:['A'...], huecos(palabra)}` donde `huecos()` devuelve los índices que
  quedan vacíos; `cargarTarjeta()` marca fijas las demás y pinta sus letras;
  `construirTeclado(nivel)` pinta las filas que el nivel pide; `listaParaNivel(nivel, letra)`
  usa `NIVELES[nivel]`.

### Voz (`speechSynthesis`)

- `hablar(texto)` hace `speechSynthesis.cancel()` antes de hablar, así que **cada evento
  produce una sola locución** (una cadena con puntos y comas para las pausas; no encadenar
  llamadas). Mantener `rate 0.8` y la preferencia de voces `es-CO`, `es-MX`, `es-US`, `es-419`,
  luego cualquier `es`.
- `mensaje(txt, clase, voz)`: escribe el texto en pantalla y, salvo que `voz === false`,
  llama a `hablar(voz || txt sin emojis)`.
- **Nombre de cada tecla** (texto exacto que se pasa a `speechSynthesis`):
  `NOMBRES = {a:'a', e:'e', i:'i', o:'o', u:'u', m:'eme', p:'pe', s:'ese', l:'ele'}`.
  Es decir: A → «a», E → «e», I → «i», O → «o», U → «u», M → «eme», P → «pe», S → «ese»,
  L → «ele». **Nunca** pedir a la voz sonidos aislados («mmm», «sss») ni pasarle
  una letra con tilde suelta («á»): el sonido se enseña con la **sílaba** y el nombre de la
  letra es el que usa la profe.
- **Sílaba del hueco:** `silabaDe(p, i)` devuelve la sílaba de `p.s` que contiene la letra
  `i` (con su tilde: `má`). Se pasa tal cual a la voz. Si una sílaba suelta suena mal en el
  dispositivo, se dice dentro de la palabra: «po… sapo».
- Al tocar una cajita: la voz dice su sílaba.
- Al terminar la ronda: «¡Felicitaciones {nombre}!» y, si hay siguiente nivel, «¡Muy bien!
  ¿Vamos al siguiente nivel?».
- En iOS la voz solo suena tras un toque; las locuciones automáticas (recordatorios de
  inactividad, «Toca la tarjeta» al entrar una tarjeta) pueden quedar mudas y por eso no
  llevan nada crítico.

### Pantalla de inicio (es para la profe)

- Título grande y colorido «¡Destapa la palabra!» con emojis que flotan y debajo, pequeño:
  «Profe: elige el nivel».
- **6 botones de nivel** tipo tarjeta (`.nivel-btn`) en **dos columnas** (tres filas) en
  360 px, mínimo 72 px de alto: emoji a 48–56 px arriba, número grande, nombre pequeño
  debajo, una línea de ejemplo con mini-cajitas de la misma estética (1: `S A P ▢` con la ▢
  en gris fantasma; 2: `S A P ▢`; 3: `▢ A P O`; 4: `S ▢ P ▢`; 5: `▢ A ▢ O`; 6: `▢ ▢ ▢ ▢`) y la
  mejor marca de ese nivel si existe («⭐ 12/15»). Al tocarlo la voz dice «Nivel {n}:
  {nombre}» y empieza la ronda.
- El nivel siguiente al último completado lleva una etiqueta «Empieza aquí» (se guarda
  `destapa.ultimoNivel`).
- Debajo de los niveles, **opcional**: «¿Cómo te llamas?» (se guarda en `destapa.nombre`).
- Al final, un `<details>` cerrado por defecto «👩‍🏫 Para la profe» con:
  - Fichas **Letra: M · P · S · L · Todas** (por defecto Todas). En el nivel 3 filtra por la
    letra inicial; en los demás, por palabras que contengan esa letra. Con letra elegida en el
    nivel 3, **3 de las 5 tarjetas** empiezan por esa letra y **2 por otra consonante**
    (distractores: si no, el niño aprende a tocar siempre la misma tecla); el teclado muestra
    siempre las 4 consonantes. Si la lista filtrada tiene menos palabras que tarjetas, se
    completa con palabras de «Todas» del mismo grupo; la ronda nunca empieza con menos
    tarjetas de las que dice la tabla.
  - Casilla «Letras minúsculas» (por defecto MAYÚSCULA IMPRENTA, que es lo que se usa en
    transición).
- Todos los niveles están disponibles desde el inicio: la profe elige.

### Palabras (solo vocales + M P S L), por dificultad

La dificultad para transición no es el largo de la palabra sino el **tipo de sílaba**. Cada
entrada de `PALABRAS` lleva `{w, img|svg, s, g:'A'|'B'|'C'}`.

- **Grupo A — sílabas directas (consonante + vocal) o vocal sola:** mamá 👩 `ma-má`,
  papá 👨 `pa-pá`, mesa (SVG) `me-sa`, mapa 🗺️ `ma-pa`, sapo 🐸 `sa-po`, sopa 🍲 `so-pa`,
  lupa 🔍 `lu-pa`, pala (SVG) `pa-la`, palo (SVG) `pa-lo`, oso 🐻 `o-so`, ola 🌊 `o-la`, y
  **nuevas** con SVG propio dibujado en el archivo (los emojis recientes no se ven sin
  internet en equipos viejos): **lulo** `lu-lo` (fruta naranja redonda con hojita verde),
  **loma** `lo-ma` (colina verde con sol), **mula** `mu-la`, **puma** `pu-ma` (cara de felino
  color arena), **pelo** `pe-lo` (cara con pelo). Total 16; 14 empiezan por consonante
  (sirven para el nivel 3) y 4 empiezan por L.
- **Grupo B — una sílaba cerrada o tres sílabas, sin diptongos ni trabadas:** sol ☀️ `sol`,
  sal 🧂 `sal`, paloma 🕊️ `pa-lo-ma`, pulpo 🐙 `pul-po`, palma 🌴 `pal-ma`, isla 🏝️ `is-la`.
- **Grupo C — reto (diptongos y trabadas, son de primero):** pie 🦶 `pie`, miel 🍯 `miel`,
  muela 🦷 `mue-la`, pluma (SVG) `plu-ma`.
- **Se quitan** «papa» 🥔 (sin tilde se escribe igual que papá y confunde) y «seis» 6️⃣ (el
  niño quiere escribir el número).
- Filtro por nivel: 1, 2 y 3 → solo A; 4 y 5 → A + B; 6 → A + B + C. Un nivel con 5 tarjetas
  y una letra filtrada puede quedar corto: aplicar la regla de relleno de la pantalla de
  inicio. Dentro de una ronda no se repite palabra.
- Las tildes no se exigen al escribir (mamá = mama), pero la palabra correcta se muestra con
  tilde.
- Para agregar palabras: ponerlas en el grupo que corresponda según sus sílabas; si el
  dibujo es un emoji reciente o ambiguo, dibujar un SVG en el mismo archivo.

### Pantalla final

- 1 s extra de confeti antes de mostrar los botones. Medalla según puntaje (🏆 ≥ 90 %, 🥇
  ≥ 70 %, 🌟 ≥ 50 %, 💪 el resto; siempre positiva), «¡Eres una campeona, {nombre}!», «⭐
  {obtenidas} de {tarjetas × 3}», fila de repaso con el **dibujo** de cada palabra y sus ⭐
  como stickers (las saltadas en gris).
- Botones: «🔁 Jugar otra vez», «➡️ {emoji del nivel siguiente} Siguiente nivel» (grande;
  solo si sacó al menos el **60 %** y no es el nivel 6) y «🏠 Inicio».
- Guarda la mejor marca **por nivel** en `destapa.mejor.<id>` = `{estrellas, total, nombre}`
  y `destapa.ultimoNivel`. Leer siempre con valor por defecto y dentro de try/catch para no
  romper lo guardado por versiones anteriores (`destapa.mejor` viejo se ignora).

### Estilo visual (¡muy importante!)

No se rediseña: se conserva el estilo que ya tiene. Debe parecer **hecho por una niña de
tercero de primaria**: colores pastel brillantes (rosa, amarillo, celeste, menta, lila), todo
muy redondo, botones «gorditos» con sombra de color que se hunden al tocarlos, bordes
punteados, stickers y emojis, fondo con círculos de colores, letra redonda y gruesa (Baloo 2 /
Fredoka, con respaldo Comic Sans). Mensajes cortos, alegres y con emojis; cada mensaje del
niño lleva un ícono fijo que aprende a leer como señal (👇 toca, 💡 ayuda, 🔊 escucha).
Nada de aspecto corporativo. Zonas de toque **grandes** para dedos pequeños: teclas de los
niveles 1–5 mínimo 60 px, cajitas `clamp(44px, 12vw, 70px)` (PALOMA con sus 6 cajitas y
separaciones de sílaba debe caber en una línea a 360 px), botones 🔊 y 💡 de 56 px.

### Requisitos técnicos

- **Un solo archivo HTML** con todo el CSS y JS. **Cero dependencias**: sin librerías ni
  imágenes externas. Debe funcionar **sin internet** abriéndolo con doble clic en celular,
  tablet o PC (las fuentes de Google son opcionales: si no cargan, se usa la de respaldo).
- Sonidos con **Web Audio API** (sin archivos de audio). Voz con `speechSynthesis`; si no
  existe o no hay voz en español, el juego funciona igual con las señales visuales.
- Responsive desde 360 px de ancho, sin scroll horizontal. **En 360 × 640 con la tarjeta
  abierta, se ven completos y sin desplazar:** barra superior, fila de progreso, tarjeta
  (`max-height: 36vh`; en pantallas de alto ≤ 640 px la tarjeta baja a 160 px), mensaje con
  🔊 y 💡, cajitas y teclado. El pie «Juego para grado transición…» se oculta en la pantalla
  de juego. La pantalla de inicio puede hacer scroll (la usa la profe), pero los 6 niveles
  caben en la primera pantalla.
- Respeta `prefers-reduced-motion`: sin latidos ni manita que rebota (la manita se queda
  fija), sin viajes ni saltos; la letra aparece directa.
- `localStorage` siempre dentro de try/catch y con valor por defecto.
- Todo el texto en español neutro (Colombia). En escuela pública lo más común es un solo
  dispositivo proyectado en el tablero: los niveles 1–5 funcionan muy bien en grupo (todos
  dicen la letra y uno pasa a tocar); el nivel 6 es para jugar uno a uno.

---

## Variaciones útiles del prompt

- *«Agrega las letras N y T y 10 palabras nuevas con esas letras (clasifícalas en los grupos
  A, B o C según sus sílabas).»*
- *«Agrega un nivel 🧩 “Falta una sílaba” entre “Pon las vocales” y “Pon las consonantes”:
  están todas las letras menos una sílaba directa (consonante + vocal); teclado con las dos
  filas; solo palabras del grupo A.»*
- *«Cuando la profe elige una letra, antes de la primera tarjeta muestra un calentamiento con
  las fichas MA ME MI MO MU que suenan al tocarlas.»*
- *«Pon fotos reales en las tarjetas: usa estas imágenes en base64: …»*
- *«Cambia el estilo a dinosaurios / princesas / espacio.»*
- *«Agrega un nivel 0 donde el niño solo escucha la palabra y toca el dibujo correcto entre
  tres.»*
