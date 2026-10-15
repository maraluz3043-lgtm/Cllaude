# Prompt — Juego «Destapa la Palabra» por niveles (grado transición, castellano)

Este es el prompt con el que se construye el juego `index.html` de esta carpeta.
Cópialo completo y pégalo en Claude, ChatGPT o cualquier asistente de IA que escriba código.

---

## Prompt

Crea un **juego educativo web en un solo archivo `index.html`** para niños y niñas de
**grado transición (5–6 años, Colombia)** en **castellano**. El objetivo es que el niño
aprenda a escribir palabras formadas solo con las **consonantes M, P, S y L** y las **vocales**.

**MUY IMPORTANTE: es para transición.** Los niños apenas están conociendo las letras.
El juego debe ser **muy fácil al principio** y subir de dificultad **por niveles**. En los
primeros niveles la palabra ya aparece casi completa (con consonantes y letras puestas) y el
niño solo pone **una** letra. Solo en el último nivel escribe la palabra completa.

### Mecánica base (igual en todos los niveles)

1. Aparece una **tarjeta tapada** (boca abajo, con un «?» grande y el texto «¡Tócame!») que
   se menea suavemente para invitar a tocarla.
2. Al tocarla, la tarjeta **gira en 3D** y muestra un **dibujo grande** (emoji o SVG dibujado
   en el mismo archivo). La voz del dispositivo (`speechSynthesis` en español) **dice la
   palabra** y hay un botón 🔊 para repetirla.
3. Debajo aparecen las **cajitas de letras** de la palabra. Las letras que el nivel regala ya
   están escritas en cajitas color crema (fijas). Las que faltan son cajitas blancas con borde
   rosado que **laten** para que el niño sepa dónde escribir.
4. Hay un **teclado gigante en pantalla** que muestra **solo las letras que ese nivel
   necesita** (vocales A E I O U en amarillo, consonantes M P S L cada una de un color) y una
   tecla ⌫. También funciona el teclado físico. Al tocar una tecla la voz dice el nombre de la
   letra.
5. Cuando se llenan las cajitas que faltaban se comprueba sola:
   - **Correcto:** confeti, sonido alegre, mensaje tipo «¡Súper! 🌟», cajitas verdes que
     saltan, se muestran las **sílabas** («SA · PO»), la voz repite la palabra, se suman
     estrellas y, tras 1.5 s, la tarjeta **se desliza a la izquierda** y entra la siguiente.
   - **Incorrecto:** cajitas tiemblan, las letras malas se ponen rojas y se borran (las buenas
     se quedan). Mensaje «Casi… ¡inténtalo otra vez! 💪».
   - **En los niveles 1 y 2, al segundo error el juego ayuda:** muestra la letra correcta
     («Mira: es la S»), la pone en su cajita y la lee en voz alta. El niño nunca se queda
     atascado.
6. Botón **💡 Pista**: pone la siguiente letra correcta. Botón **⏭️ Otra tarjeta**: salta.
7. **Estrellas:** 3 por tarjeta sin ayuda; −1 por usar pista, −1 por fallar; mínimo 1 si al
   final la completa.
8. Arriba, una **fila de tarjetitas** muestra el progreso (resueltas con su dibujo y ⭐,
   la actual late en amarillo, las que faltan con «?»).

### Los 5 niveles (de más fácil a más difícil)

| Nivel | Nombre | Qué hace el niño | Teclado | Tarjetas por ronda | Palabras |
|---|---|---|---|---|---|
| 1 🐣 | **La primera letra** | La palabra está completa menos la **primera letra** (una consonante M, P, S o L). Toca la letra con la que empieza. | Solo M P S L | 6 | Cortas (3–4 letras) que empiezan por consonante |
| 2 🌱 | **Falta una vocal** | La palabra está completa menos **una vocal**. | Solo A E I O U | 6 | Cortas (3–4 letras) |
| 3 🌼 | **Pon las vocales** | Están las consonantes, faltan **todas las vocales**. | Solo A E I O U | 8 | Cortas y medianas |
| 4 🌳 | **Pon las consonantes** | Están las vocales, faltan **todas las consonantes**. | Solo M P S L | 8 | Todas |
| 5 🏆 | **Toda la palabra** | No hay letras puestas: escribe la palabra completa. | Vocales y M P S L | 10 | Todas |

- El mensaje de cada nivel es claro y corto: «¿Con qué letra empieza? 👇», «¿Qué vocal
  falta? 👇», «Pon las vocales 👇», «Pon las consonantes 👇», «Escribe la palabra 👇».
- Todos los niveles están disponibles desde el inicio (la profe elige), pero el juego guarda
  la **mejor marca de cada nivel** y al terminar un nivel con buen puntaje ofrece el botón
  **«➡️ Siguiente nivel»**.

### Pantalla de inicio

- Título grande y colorido «¡Destapa la palabra!» con emojis que flotan.
- «¿Cómo te llamas?» (se guarda con `localStorage`).
- **5 botones grandes de nivel** con su emoji, número y nombre, y debajo las estrellas de la
  mejor marca (ej. «⭐ 14/18»).
- Fila de fichas **Letra: M · P · S · L · Todas** (por defecto Todas) para practicar una sola
  consonante. En el nivel 1 filtra por la letra inicial; en los demás, por palabras que
  contengan esa letra.
- Casilla «Letras minúsculas» (por defecto MAYÚSCULA IMPRENTA, que es lo que se usa en
  transición).

### Palabras (solo vocales + M P S L)

Cortas: sol ☀️, sal 🧂, oso 🐻, ola 🌊, pie 🦶, mamá 👩, papá 👨, sapo 🐸, sopa 🍲, mesa (SVG),
mapa 🗺️, lupa 🔍, pala (SVG), palo (SVG), papa 🥔, miel 🍯, seis 6️⃣.
Medianas/largas: muela 🦷, pluma (SVG), palma 🌴, pulpo 🐙, isla 🏝️, paloma 🕊️.
Las tildes no se exigen al escribir (mamá = mama), pero la palabra correcta se muestra con tilde.

### Pantalla final

Medalla según puntaje (🏆 / 🥇 / 🌟 / 💪), «¡Eres una campeona, {nombre}!», estrellas obtenidas
de las posibles, lista de palabras con sus estrellas y botones «🔁 Jugar otra vez»,
«➡️ Siguiente nivel» (si sacó al menos el 60 %) y «🏠 Inicio».

### Estilo visual (¡muy importante!)

Debe parecer **hecho por una niña de tercero de primaria**: colores pastel brillantes (rosa,
amarillo, celeste, menta, lila), todo muy redondo, botones «gorditos» con sombra de color que
se hunden al tocarlos, bordes punteados, stickers y emojis, fondo con círculos de colores,
letra redonda y gruesa (Baloo 2 / Fredoka, con respaldo Comic Sans). Mensajes cortos, alegres
y con emojis. Nada de aspecto corporativo. Letras y teclas **grandes** (mínimo 48 px) para
dedos pequeños.

### Requisitos técnicos

- **Un solo archivo HTML** con todo el CSS y JS. **Cero dependencias**: sin librerías ni
  imágenes externas. Debe funcionar **sin internet** abriéndolo con doble clic en celular,
  tablet o PC (las fuentes de Google son opcionales: si no cargan, se usa la de respaldo).
- Sonidos con **Web Audio API** (sin archivos de audio).
- Responsive desde 360 px de ancho, sin scroll horizontal. Respeta `prefers-reduced-motion`.
  `localStorage` siempre dentro de try/catch.
- Todo el texto en español neutro (Colombia).

---

## Variaciones útiles del prompt

- *«Agrega las letras N y T y 10 palabras nuevas con esas letras.»*
- *«Pon fotos reales en las tarjetas: usa estas imágenes en base64: …»*
- *«Cambia el estilo a dinosaurios / princesas / espacio.»*
- *«Agrega un nivel 0 donde el niño solo escucha la palabra y toca el dibujo correcto entre tres.»*
