# Geometría del edificio y de los salones nuevos (coordenadas locales u,y,v; ver API.md)

## Planta baja existente (lo que ya hay en el rbxm del usuario)
- Dos naves vacías de 13 studs de alto: Nave 1 interior u 0.2..58.2, Nave 2 interior u 62.0..120.0; ambas v 1.40..21.40 (fondo 20 studs).
  Sin piso (hay que ponerlo), losa de techo existente de y 13.03 a 13.93 (el cielo raso nuevo va justo debajo: y ≤ 13.03).
- Muro de fachada MACIZO (sin huecos) v 0.40..1.40, y 0.02..13.02, color (222,224,226). Muro trasero v 21.40..22.40. Muros laterales de nave en u -0.8..0.2, 58.2..59.2, 61.0..62.0, 120.0..121.0.
- Columnas de fachada (1.6 de ancho en u, v -0.60..0.60, y 0.02..13.02), centros u = 0, 11.2, 23.19, 35.19, 47.19, 58.38 | 61.79, 72.99, 84.99, 96.98, 108.98, 120.18.
- Vanos (entre columnas): vano0 u 0.8..10.4, vano1 12.0..22.39, vano2 23.99..34.39, vano3 35.99..46.39, vano4 47.99..57.58 | vano5 62.59..72.19, vano6 73.79..84.19, vano7 85.79..96.18, vano8 97.78..108.18, vano9 109.78..119.38.
- En cada vano hay una ventana existente pegada a la cara exterior del muro (v 0.10..0.40): marco naranja (201,112,60) de 8.3 x 5.7 (y 6.2..11.9), 3 paños, vidrio (233,235,237) y debajo una "Rejilla" (calado) de 6.0 x 4.2 (y 1.5..5.7) color (206,206,208) con SurfaceGui de 16 puntos oscuros redondeados. Centros u de ventana: 5.15, 17.15, 29.15, 41.15, 53.15 | 67.05, 79.05, 91.05, 103.05, 115.05.
- Franja roja (150,22,26) en las columnas y 3.5..4.3; zócalo rojo exterior y 0.4..1.2 en v 0.30..0.40. Acera de baldosa roja (170,72,48) en v -7.6..0.9, y 0.02..0.42.

## Salones nuevos (el usuario marcó en rojo los vanos 1, 3 y 6 = dónde van las puertas)
| Salón | Puerta (foto) | Vanos | u interior | Vano de la puerta (hueco libre) |
|---|---|---|---|---|
| Salón 1 "GRADO 5°" | morada con mariposas (foto1) | 0,1,2 | 0.2 .. 34.89 | vano1: 12.0..22.39 |
| Salón 2 "CUARTO" | azul con luna y estrellas (foto2) | 3,4 | 35.49 .. 58.2 | vano3: 35.99..46.39 |
| Salón 3 "6C" | metálica blanca abierta (foto3) | 5,6,7 | 62.0 .. 96.68 | vano6: 73.79..84.19 |
- Tabiques nuevos de 0.6 de espesor centrados en las columnas u = 35.19 y u = 96.98 (de v 1.4 a 21.4, y 0.42..13.03).
- Piso nuevo y -0.10..0.42 (tope a ras de la acera). Altura libre interior 0.42..13.03 (12.6 studs).
- Hueco de puerta en el muro de fachada: 4.2 de ancho x 8.6 de alto (y 0.42..9.02). Marco dentro del hueco (jambas 0.2, dintel 0.2) → hoja ≈ 3.8 x 8.4 x 0.12.
  * Salón 1: hueco u 12.7..16.9 ; a la derecha calado 4.4 (u 17.3..21.7, y 1.5..5.7) con media ventana encima (u 17.3..21.7, y 6.2..11.9, 2 paños).
  * Salón 2: hueco u 36.7..40.9 ; a la derecha calado + media ventana u 41.3..45.7 ; maceta con palma en la acera junto a la columna izquierda.
  * Salón 3: calado + media ventana u 74.5..78.9 ; hueco de puerta u 79.3..83.5 (la hoja abierta hacia dentro, abisagrada a la derecha vista desde el corredor, como en la foto 3).
- Las hojas moradas/azules cerradas (sin colisión para que el avatar pueda pasar) y la 6C abierta ≈ 75°.

## Interiores (según los salones del piso de arriba, optimizados)
Cada salón: piso de baldosa terracota, zócalo rojo, paredes blancas, cielo raso de tablillas PVC con moldura, 6 luminarias fluorescentes,
2 ventiladores de pared + 1 de techo, split de aire acondicionado, tablero blanco con porta-marcadores, 2-3 carteleras y afiches,
reloj, mesa + silla docente, 16-24 pupitres (silla-pupitre azul de plástico con tableta como `Pupitre_16` del piso superior, o de madera como `Pupitre_06`),
papelera, armario metálico, escoba, interruptor/tomas/canaleta, ventanas interiores (marco + vidrio claro) en la cara interior del muro de fachada.
Presupuesto TOTAL del modelo de salones: < 4000 parts (objetivo ≈ 2800). Presupuestos por componente en el encargo de cada agente.
