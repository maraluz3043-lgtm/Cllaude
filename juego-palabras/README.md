# 🌈 Destapa la Palabra

Juego de castellano para **grado transición**: la niña toca una tarjeta, se destapa un dibujo
y debe escribir la palabra con las letras **M, P, S, L** y las vocales. Hecho con estilo
infantil, tarjetas que giran y se deslizan, sonidos, voz, confeti y estrellas.

## Cómo usarlo

| Opción | Cuándo usarla |
|---|---|
| **Enlace web** (publicado en claude.ai) | Para compartir con todos. No necesita que ningún computador esté encendido. |
| **`index.html`** (este archivo) | Para usarlo **sin internet**. Se descarga una vez y se abre con doble clic en celular, tablet o PC. |

### Sin internet en celular o tablet
1. Descarga `index.html` (desde GitHub: botón **Raw** → guardar, o compartido por WhatsApp/correo).
2. Ábrelo con el navegador (Chrome, Safari, Edge).
3. En el menú del navegador elige **«Agregar a pantalla de inicio»**. Queda como una app.

Todo está dentro de un solo archivo: no descarga nada mientras se juega. Las fuentes de Google
son opcionales; sin internet se usa la fuente de respaldo del dispositivo.

## Cómo editar las palabras
Abre `src/page.html`, busca `const PALABRAS` y agrega o quita líneas. Cada palabra tiene un
emoji (`img`) o un dibujo SVG (`svg`) y sus sílabas (`s`). Luego ejecuta `./build.sh` para
regenerar `index.html`. Recuerda: solo vocales y las letras M, P, S, L.

## Archivos
- `index.html` — el juego completo, listo para descargar (generado).
- `src/page.html` — el código fuente (es lo que se publica como artefacto en claude.ai).
- `build.sh` — genera `index.html` a partir de `src/page.html`.
- `PROMPT.md` — el prompt con el que se creó el juego, para reutilizarlo o pedir cambios.
