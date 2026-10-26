# H. Informe final

## Estado
- **Código**: 55 scripts Luau (23 servicios, 15 controladores, capa compartida, carga), 56.215 líneas, sintaxis verificada. Paquete: `dist/ColegioRP.rbxmx` e `dist/Instalador_ColegioRP.lua` (v2.0.0).
- **Mapa**: intacto. Todo se añade en carpetas propias; desinstalable (`herramientas/Desinstalar.lua`).

## Verificación realizada (simulador headless, `tools/simulacion`)
| Escenario | Resultado |
|---|---|
| Arranque con el mapa real (67.117 instancias) | Servidor sin errores, 21 remotos, 202 asientos detectados en aulas, 2 clientes con 11 interfaces sin duplicados |
| P14 fuzzing: 312 cargas maliciosas en 20 remotos | 0 errores del servidor, todas rechazadas, límite de frecuencia activo, auditoría y marca de sospechoso |
| Funcional: P3 cargos y reaparición, P4 aulas paralelas aisladas, P5 respuesta de otra aula rechazada, P6 cuaderno y privacidad, P7 respuesta única, P8 snapshot y control de jornada, P9 comida 0 y compra descontada una vez, tablero por turno, soporte, anuncios, paneles de personal, moderación por permisos | 9/9 |
| Revisiones adversariales | Núcleo servidor (14 hallazgos, 11 corregidos), cliente (14, 10), jornada (7, 6), fútbol (6, 5) |

**No verificado**: ejecución real en Roblox Studio, FPS/memoria (P15) y aspecto visual. Usar `docs/G_Pruebas.md`.

## Bugs corregidos destacados
StateSnapshot y SettingsUpdate sin manejador; pérdida de datos al cerrar el servidor; argumentos extra aceptados; límite de frecuencia después de validar; auditoría saturable; asistencia docente vacía; clase descartada al cambiar escala de tiempo; partidos sin recompensa en el descanso; menú inutilizable en móvil horizontal; JUGAR colgado sin respuesta; reloj escolar que retrocedía; timbre doble; intro repetida en cada sesión; inicio libre de fútbol bloqueado por permiso.

## Pendientes y riesgos
1. Subir el logo y poner `Config.LogoAssetId`; sonidos y uniformes en 0 (silencio/sin ropa).
2. Rellenar `Config.Autorizaciones` y poner `ModoPruebasEnStudio=false` antes de publicar.
3. Verificar en Studio los 18 spawns provisionales, los tableros de ALTO_O1/ALTO_O3 y que el marcador de la cancha no quede oculto.
4. Aulas sin `Seat` (6B, 7B, P1, planta alta oeste, 8B, E3): asistencia por presencia; recomendable añadir pupitres con asiento.
5. Rótulos de puertas incoherentes en el bloque este (ver A.4).
6. Medir P15 (FPS/memoria) en PC y móvil.

## Mantenimiento
- Editar zonas: `mapa/zonas.json` → `python3 tools/gen_mapa_logico.py`.
- Comprobar: `node tools/check_lua.js src` y `cd tools/simulacion && npm test` (requiere exportar el mapa con `tools/exportar_mapa_sim.py`).
- Empaquetar: `python3 tools/build.py`.
