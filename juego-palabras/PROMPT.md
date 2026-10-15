# Prompt — Juego «Destapa la Palabra» (grado transición, castellano)

Este es el prompt con el que se construyó (y con el que se puede volver a construir o
modificar) el juego `index.html` de esta carpeta. Cópialo completo y pégalo en Claude,
ChatGPT o cualquier asistente de IA que escriba código.

---

## Prompt

Crea un **juego educativo web, en un solo archivo `index.html`**, para niños y niñas de
**grado transición (5–6 años)** en la asignatura de **castellano**. El tema es escribir
palabras usando únicamente las **consonantes M, P, S y L** más las **vocales**.

### Cómo se juega

1. Aparece una **tarjeta tapada** (boca abajo, con un signo de pregunta y el texto «¡Tócame!»)
   que se mueve suavemente para invitar a tocarla.
2. Al tocarla, la tarjeta **gira en 3D** y muestra un **dibujo** (un emoji grande o un dibujo
   SVG hecho en el mismo archivo). El juego lee la palabra en voz alta con la voz del
   dispositivo (`speechSynthesis`, idioma español) y tiene un botón 🔊 para volver a oírla.
3. Debajo aparecen **cajitas vacías**, una por cada letra de la palabra, y un **teclado gigante
   en pantalla** con SOLO estas teclas: `A E I O U` (amarillas) y `M P S L` (cada consonante de
   un color distinto) más una tecla ⌫ Borrar. También debe funcionar el teclado físico.
4. Cuando la niña llena todas las cajitas se comprueba automáticamente:
   - **Correcto:** confeti, sonido alegre, mensaje tipo «¡Súper! 🌟», las cajitas se ponen
     verdes y saltan, se muestran las **sílabas** (ej. «SA · PO»), se suman **estrellas**
     y, tras 1.5 s, la tarjeta **se desliza hacia la izquierda** y entra la siguiente por la
     derecha.
   - **Incorrecto:** las cajitas tiemblan, las letras malas se ponen rojas, se borran solo las
     malas (las buenas se quedan) y aparece «Casi… ¡inténtalo otra vez! 💪». Al segundo error
     sugiere usar la pista.
5. Botón **💡 Pista**: rellena la siguiente letra correcta (queda fija y de color crema).
   Botón **⏭️ Otra tarjeta**: salta la palabra sin estrellas.
6. **Puntaje:** 3 estrellas por palabra sin ayuda; se resta 1 por usar pista y 1 por fallar;
   mínimo 1 estrella si al final la escribe bien.
7. Arriba hay una **fila de tarjetitas** que muestra el progreso (las resueltas muestran su
   dibujo con una ⭐, la actual late en amarillo, las que faltan tienen «?»).
8. Al terminar las 10 tarjetas: pantalla final con medalla (🏆 / 🥇 / 🌟 / 💪 según el
   puntaje), «¡Eres una campeona, {nombre}!», estrellas obtenidas de las posibles, lista de
   las palabras practicadas con sus estrellas y botones «Jugar otra vez» y «Otra letra».

### Pantalla de inicio

- Título grande y colorido «¡Destapa la palabra!» con emojis que flotan.
- Campo «¿Cómo te llamas?» (se guarda en `localStorage` para la próxima vez).
- Botones de nivel: **M**, **P**, **S**, **L** (10 palabras que contengan esa letra) y
  **🎉 Todas** (mezcla).
- Casilla «Letras minúsculas» para pasar de MAYÚSCULA IMPRENTA a minúscula.
- Muestra la mejor marca guardada.

### Palabras (solo pueden tener vocales y M, P, S, L)

mamá 👩, mesa (SVG), mapa 🗺️, miel 🍯, muela 🦷, paloma 🕊️, pluma (SVG), palma 🌴, papá 👨,
papa 🥔, pulpo 🐙, pie 🦶, sapo 🐸, sopa 🍲, lupa 🔍, palo (SVG), pala (SVG), sol ☀️, sal 🧂,
isla 🏝️, oso 🐻, seis 6️⃣, ola 🌊. Las tildes no se exigen al escribir (mamá = mama), pero
la palabra correcta se muestra con tilde al acertar.

### Estilo visual (¡muy importante!)

Debe parecer **hecho por una niña de tercero de primaria**: colores pastel brillantes (rosa,
amarillo, celeste, menta, lila), todo muy redondeado, botones «gorditos» con sombra de color
abajo que se hunden al tocarlos, bordes punteados, stickers y emojis, fondo con círculos de
colores, tipografía redonda y gruesa (Baloo 2 / Fredoka, con respaldo Comic Sans).
Los mensajes son cortos, alegres y con emojis. Nada de aspecto corporativo.

### Requisitos técnicos

- **Un solo archivo HTML** con todo el CSS y JS dentro. **Cero dependencias**: sin librerías,
  sin imágenes externas, sin internet (las fuentes de Google son opcionales; si no cargan se
  usa la fuente de respaldo). Debe abrir con doble clic desde el celular, tablet o PC.
- Sonidos generados con **Web Audio API** (sin archivos de audio).
- Responsive: funciona desde 360 px de ancho hasta escritorio, sin scroll horizontal,
  teclas de mínimo 48 px para dedos pequeños.
- Respeta `prefers-reduced-motion`; `localStorage` protegido con try/catch.
- Todo el texto de la interfaz en español neutro (Colombia).

---

## Variaciones útiles del prompt

- *«Agrega la letra N y T a las consonantes y 10 palabras nuevas con esas letras.»*
- *«Haz que la tarjeta muestre una foto real: usa estas imágenes en base64: …»*
- *«Cambia el estilo a dinosaurios / princesas / espacio.»*
- *«Agrega un modo de 2 jugadoras por turnos con dos marcadores.»*
