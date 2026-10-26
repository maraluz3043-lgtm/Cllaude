# G. Pruebas

**Alcance de lo verificado en esta entrega (honestidad primero).** El código se escribió contra el `.rbxl` real y se verificó fuera de Studio con un analizador de sintaxis Luau (restringida) y revisiones cruzadas de contrato (remotos, firmas, eventos). **No se ejecutó dentro de Roblox Studio** (este entorno no tiene Studio), así que las pruebas de esta sección son el **plan de verificación que el equipo debe ejecutar** y registrar; las columnas "Resultado" quedan en blanco a propósito. Las métricas FPS/memoria de P15 no se inventan: se miden con el procedimiento de G.3.

## G.1 Pruebas de aceptación P1–P15 (del prompt maestro)

| # | Prueba | Pasos | Resultado esperado | Resultado |
|---|---|---|---|---|
| P1 | Carga con progreso real | Play. Observar barra y textos. Pulsar "Saltar" a los 2 s y, en otra prueba, no pulsarlo | La barra avanza con los hitos (Shared, Remotes, scripts del jugador, precarga). "Saltar" abre el menú si los hitos mínimos están listos; si no, muestra "Preparando recursos esenciales…" y nunca deja sin interfaz (máx. 25 s) | |
| P2 | Menús sin GUIs duplicadas | Abrir y cerrar JUGAR, ACTUALIZACIONES, EQUIPO, AJUSTES, AYUDA, SOPORTE 3 veces en PC y en emulador móvil (Test → Device) | Una sola `ScreenGui` por controlador en `PlayerGui`; botones ≥ 44 px en móvil; navegación con mando (Test → Gamepad) por foco | |
| P3 | Spawn por cargo y persistencia | Elegir Estudiante → patio central. Cambiar a Profesor/a titular → aula asignada. Morir (reset) | Reaparece en la zona del cargo; atributo `Cargo` conservado; aviso "Punto provisional" solo en cargos sin sala propia | |
| P4 | Dos aulas simultáneas | Test → Clients and Servers (3 clientes): docente A abre sesión en 6C; docente B en Grado 5°; cada uno crea una actividad | Las actividades y tableros de 6C no llegan a jugadores en Grado 5° ni viceversa (Output del cliente y HUD) | |
| P5 | Ocupación y entrega por otro | Estudiante se sienta en 6C; docente toma asistencia; estudiante intenta responder la actividad de 5° | El docente ve "Sentados/De pie" correcto; el servidor rechaza la respuesta ajena (`rechazado:...` en Output y AuditLog) | |
| P6 | Cuaderno | Escribir 2 páginas; esperar autosave; salir y entrar; otro jugador intenta "Ver" | Texto recuperado; "Ver" solo funciona para el docente de la sesión sobre páginas compartidas y filtradas | |
| P7 | Pregunta y respuesta | Docente crea actividad de opciones con correcta; 2 alumnos responden; uno intenta responder dos veces | Cada respuesta llega solo al docente; segunda respuesta rechazada; resultado privado al alumno | |
| P8 | Reloj y timbres sincronizados | 2 clientes; comparar hora escolar y estado durante un cambio de periodo; un tercer cliente entra a mitad de CLASE_1 | Mismo estado y hora (±1 s) en todos; el que entra recibe el snapshot actual | |
| P9 | Comida 0 / compra una vez | Reclamar almuerzo en DESCANSO (saldo antes/después); comprar 1 empanada (saldo antes/después); repetir compra con stock 0 | Saldo intacto tras el almuerzo; la compra descuenta exactamente el precio del servidor una sola vez; sin stock → rechazo sin cobro | |
| P10 | Puertas, sillas y PCs tras respawn | Abrir 6B, sentarse, usar un PC; morir; repetir | Estados persisten en servidor; tras reaparecer, prompts y paneles vuelven a funcionar; PC se libera al levantarse/morir. Con latencia simulada (Studio → Network → Incoming replication lag 200 ms) todo sigue respondiendo | |
| P11 | Fútbol | Unirse a A y B, iniciar, patear desde lejos (> 9 studs), patear cerca, meter gol, lanzar el balón fuera | Patada lejana rechazada; gol suma y reinicia; balón recuperado al centro al salir de límites | |
| P12 | Cambio de calidad local | Cliente 1 en Bajos, cliente 2 en Calidad | Cliente 1 ve menos decoración/efectos; cliente 2 no cambia; colisiones y datos iguales (los mismos asientos, puertas y precios) | |
| P13 | Sin regresiones de geometría | `herramientas/Auditoria_Mapa.lua` antes y después de instalar; comparar conteos de BaseParts fuera de `ColegioRP_Mapa` | Conteos iguales; scripts originales intactos; `ServerStorage/ColegioRP_Respaldos` con la copia | |
| P14 | Intentos maliciosos | Desde la consola del cliente (Studio): `game.ReplicatedStorage.ColegioRP.Remotes.CafeteriaPurchase:InvokeServer({ProductoId="EMPANADA",Cantidad=999})`, `RequestJoinRole:InvokeServer({Cargo="Director"})` (sin autorización, con `ModoPruebasEnStudio=false`), `FootballKick:FireServer({Direccion=Vector3.new(0,1,0)*1000, Fuerza=50})`, `AnnouncementBroadcast:InvokeServer({Texto=string.rep("a",1000)})`, `NotebookUpdate` con texto de 5000 caracteres, 50 llamadas seguidas a `StateSnapshot` | Todas rechazadas con `ok=false, error="rechazado:<motivo>"`; entradas en AuditLog (panel del Director → Auditoría) y, tras 20 rechazos/min, atributo `Sospechoso` | |
| P15 | Métricas antes/después | G.3 en PC y en un móvil real (o emulador) | Tabla rellenada con valores medidos; nunca inventados | |

## G.2 Pruebas por módulo (positivas y negativas)

| Módulo | Positiva | Negativa |
|---|---|---|
| RemoteService | Cada remoto responde a datos válidos | Datos no-tabla, campo extra, string demasiado largo, enum inválido, exceso de frecuencia → rechazo + AuditLog |
| DataService | Perfil se crea con `SaldoInicial`; autosave; guardado al salir | Sin API en Studio → modo memoria con `warn`; DataStore caído (simular desconectando la red) → reintentos y mensaje, sin error fatal |
| MapService | Output lista 24 aulas, asientos detectados (6C 20, 5° 20, 7A 20, P2 15, ADAPTADA 16, A01–A06 9, E1 13, INFORMATICA 18, ROBOTICA 24), 18 PCs, 15 puertas | Renombrar `Workspace/Puerta_6B` → advertencia, el resto sigue |
| RoleService | Estudiante libre; en Studio todos los cargos; Director asigna Tutor a otro | Jugador sin autorización pide Director (fuera de Studio) → rechazo; Subdirector intenta asignar Director → rechazo |
| SpawnService | Spawn por cargo; respaldo AUDITORIO si falta zona | Zona sin spawn → respaldo y aviso |
| SchoolDayService | Ciclo completo automático (~22 min); Manual inicia solo con Director; asistencia marca Presente/Tardanza/Ausente | Saltar sin permiso → rechazo; configurar duración 5 s → rechazado (mín. 15) |
| RoomService | Occupant → Sentados; levantarse → De pie | Sentarse en aula ajena → aviso, no expulsión |
| ClassroomService | Flujo completo sesión→actividad→respuesta→calificación→resultados | Docente cambia de cargo → sesión cancelada; alumno fuera de la zona no recibe actividad |
| BoardService | Texto/plantilla/trazos replicados en la sala y en la pizarra física | Escribir sin turno → rechazo; 400+ caracteres → rechazo; 301 trazos → se descarta el más antiguo |
| NotebookService | Guardar/cargar/compartir/ver (docente) | 2 guardados en < 10 s → segundo rechazado; "Ver" por un alumno → rechazo |
| EconomyService | Acreditar/debitar; límite diario | Débito mayor que saldo → rechazo; dos compras simultáneas (2 clientes) → una sola descuenta por unidad de stock |
| FoodService | Reclamo gratis en periodo; receta por pasos; NPC repone | Reclamo en CLASE_1 → rechazo "fuera de horario"; paso fuera de orden → rechazo |
| CafeteriaService | Vendedor abre/cierra/precio/repone; recibo | Precio fuera de rango → rechazo; compra con puesto cerrado y sin NPC → rechazo |
| FootballService | Partido completo; marcador físico | Patada a 20 studs → rechazo; velocidad anómala → reset |
| DoorService | Abrir/cerrar/bloquear/privacidad; autocierre | Bloquear sin cargo → rechazo; nunca encerrado (desde dentro siempre abre) |
| BathroomService | Lavar manos / usar con cooldown | Spam → cooldown |
| PCService | Usar sentado; apps; resultados validados | Usar PC ocupado/bloqueado → rechazo; resultado de cuestionario con índices inválidos → rechazo |
| ReportService | Envío con id | 3 reportes/min → rechazo; texto con contenido filtrable → se guarda filtrado |
| ModerationService | Silenciar/advertir; expulsar con confirmación de dos pasos | Token caducado → rechazo; objetivo con cargo superior → rechazo |
| AnnouncementService | `/anuncio Hola` por Director; panel | `/h` por Estudiante → ignorado con mensaje; 161 caracteres → rechazo |
| StaffService | Cada acción de cargo | Acción de otro cargo → rechazo |
| SettingsController | Cambio de modo y accesibilidad aplicados y guardados | Perfil no cargado → valores por defecto sin error |

## G.3 Procedimiento de medición (P15)

1. **Línea base (mapa sin Colegio RP)**: abrir el `.rbxl` original, Play, esperar 60 s en el patio central y en el bloque de dos plantas. Anotar: FPS (View → Stats → Summary), memoria del cliente (Stats → Memory, "PlaceMemory"), instancias (`#game:GetDescendants()` en la consola), tiempo de arranque (desde Play hasta control del personaje), "Network → Received kB/s".
2. **Con Colegio RP, modo Calidad**: mismos puntos y tiempos. Añadir: tiempo de la pantalla de carga, número de instancias bajo `Workspace/ColegioRP_Mapa` (lo imprime Output), rechazos de remotos (panel Director → Métricas).
3. **Con Colegio RP, modo Bajos recursos**: repetir.
4. **Móvil**: un teléfono real con la experiencia publicada (o Test → Device → teléfono) en los mismos puntos.
5. Registrar en la tabla:

| Escenario | Dispositivo | FPS medio | Memoria (MB) | Instancias | Arranque (s) | Red (kB/s) |
|---|---|---|---|---|---|---|
| Base | PC | | | | | |
| RP Calidad | PC | | | | | |
| RP Bajos | PC | | | | | |
| RP Automático | Móvil | | | | | |

Objetivo orientativo (no garantía): ≥ 30 FPS en móviles modestos en Bajos y fluidez alta en PC en Calidad. Si el mapa original ya baja de 30 FPS en móvil (es probable por los 60k Parts y 2k SurfaceGui), el modo Bajos mitiga pero no corrige la base: anotar la diferencia real.

## G.4 Pruebas gráficas LOW/HIGH

- Capturas en el mismo punto y hora (`Lighting.TimeOfDay` fija) en ambos modos; comparar sombras, SunRays, árboles PBR, espejo, ventiladores.
- Verificar que en Bajos las colisiones y los asientos son idénticos (sentarse en los mismos pupitres).

## G.5 Registro de ejecución

Añadir a `CHANGELOG.md` la fecha, el build (`dist/manifest.json` → `version` y `sha1`) y los resultados de G.1 y G.3.
