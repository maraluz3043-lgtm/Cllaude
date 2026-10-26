# CHANGELOG — Colegio RP · Instituto Educativo Jean Piaget · Horizon Studios by Adrian

Formato: por versión, qué cambió, por qué y cómo revertirlo. Las fechas son de la entrega del código; las pruebas en Studio se registran al ejecutarlas (ver `docs/G_Pruebas.md`).

## 2.0.0 — 2026-10-26 — Sistema escolar RP sobre el mapa existente

### Añadido (todo separable; nada del mapa original se modifica)
- **Auditoría binaria del `.rbxl`** (`docs/A_Diagnostico_Mapa.md`, `mapa/zonas.json`, planos cenitales): 36 zonas reales con coordenadas, 24 aulas, asientos, PCs, puertas, letreros, scripts existentes (Adonis, ventiladores, espejo, inodoros, cortinas).
- **Pantalla de carga e intro Horizon Studios** (`ReplicatedFirst/ColegioRP_Carga`): barra real por hitos, "Saltar" seguro, intro omitible y no repetida, logo real (id configurable) o logo vectorial de respaldo.
- **Menú principal** (JUGAR, ACTUALIZACIONES, EQUIPO, AJUSTES/OPTIMIZACIÓN, AYUDA, SOPORTE), **HUD** con hora real aproximada, hora escolar y estado sincronizados, cargo, aula, próxima actividad, avisos, cuaderno y acciones contextuales.
- **Cargos y permisos** (17 cargos, 6 equipos, autorización por UserId/grupo/Adonis/Studio, gestor de cargos para dirección con auditoría y confirmación en dos pasos), **spawns por cargo** en zonas verificadas (provisionales documentados).
- **Jornada escolar** sincronizada (ESPERA → … → REINICIO), modo automático o manual, timbres con subtítulos, asignación de aulas, asistencia (presente/tardanza/ausente) por posición real.
- **Aulas interactivas**: ocupación por `Seat` real, sesiones de clase por aula, actividades (texto/opciones), respuestas únicas, calificación privada, invitación al tablero con turno; **tablero** con texto, plantillas y trazos replicados solo a la sala y dibujados en la pizarra física; **cuaderno** con autosave, límites, compartir y filtrado.
- **Economía escolar** (monedas internas, límite diario, historial), **comedor gratuito** (lotes, recetas por pasos en la cocina real, bandeja, NPC de servicio) y **cafetería comercial** en la tienda real (inventario, precios acotados, compra atómica, recibo, cierre de caja).
- **Cancha**: fútbol con balón servidor-autoritativo, patadas validadas por distancia/frecuencia, arcos, marcador físico, reloj de partido, rescate del balón.
- **Puertas** (6B, 7B, Morada, Blanca 6C, 7A, 8B, aulas 01–05, laboratorio, portón) con estados, bloqueo por cargo, privacidad en baños y protección anti-encierro; **baños** con lavamanos e inodoros interactivos reutilizando el sonido existente.
- **Sala de informática**: 18 PCs reales con pantalla, ocupación única, escritorio escolar (procesador, cuestionario, simulador, programación por comandos validada en servidor, pantalla de clase), bloqueo/proyección del docente.
- **Soporte** (reportes Bug/Abuso/Duda/Sugerencia con filtrado y límite), **moderación** (silenciar, advertir, expulsar, bloqueo temporal, dos pasos, auditoría), **anuncios** (`/anuncio`, `/h`, panel) y **funciones del personal** (dirección, coordinación, convivencia, orientación, enfermería, secretaría, finanzas, recepción/seguridad, limpieza con tareas por zonas).
- **Dos modos gráficos locales** (Calidad / Bajos recursos / Automático) con partículas, decoración lejana, postprocesado, sombras, sonidos ambientales, animaciones cosméticas, límite de efectos, aviso de rendimiento y accesibilidad (escala de texto, movimiento reducido, subtítulos, 12/24 h, ocultar etiquetas).
- **Seguridad**: validación de todos los remotos (tipo, longitud, enum, rangos, frecuencia, permiso, distancia), filtrado de texto, auditoría de rechazos (P14), persistencia versionada con reintentos y presupuesto de DataStore.
- **Entregables**: `dist/ColegioRP.rbxmx` + `dist/Instalador_ColegioRP.lua`, herramientas de Studio (`Auditoria_Mapa`, `Respaldo_Scripts`, `Desinstalar`), `default.project.json` (Rojo), documentación A–H.

### Conservado
- Toda la geometría y los scripts originales (Adonis incluido). `SpawnLocation` original intacto.

### Cómo revertir
- `herramientas/Desinstalar.lua` o restaurar la versión publicada anterior. Detalle en `docs/B_Plan_Modificacion.md` §B.5.

## 1.x — recreación de los salones 6B y 7B (`Salones_Realistas.lua`)
- Script independiente de Command Bar que construye un módulo de dos salones según fotografías (ver README, sección "Salones 6B y 7B"). No forma parte de la instalación de Colegio RP.
