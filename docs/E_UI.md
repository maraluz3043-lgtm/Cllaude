# E. Contenido de UI

Todas las interfaces se construyen por código (StarterGui vacío) con `UIBuilder` y `UITheme` (colores del logo: rojo 196,30,36; blanco; amarillo; azul). Cada controlador crea **una** `ScreenGui` `ColegioRP_<Nombre>` con `ResetOnSpawn=false`, `IgnoreGuiInset=true`; si ya existe la reutiliza (sin duplicados al reaparecer o reconectar). Botones de 44 px mínimo, foco de mando, franja inferior libre para controles táctiles, escala de texto por dispositivo y por ajuste del jugador. Todo en español.

| ScreenGui | Capa | Controlador | Contenido y acciones |
|---|---|---|---|
| `ColegioRP_Carga` | 100 | `ReplicatedFirst/ColegioRP_Carga` | Fondo casi negro, logo (real si `LogoAssetId>0`, si no vectorial), "Cargando…", "Descargando paquetes…", barra real por hitos (Shared, Remotes, scripts, precarga), botón **Saltar** (Enter/A). Máx. 25 s. Intro Horizon Studios ≈4 s, omitible, no se repite (`IntroVista`). |
| `ColegioRP_Notificaciones` | 95 | NotificationController | Toasts (máx. 4 visibles), avisos oficiales destacados 8 s, subtítulos del timbre. |
| `ColegioRP_Menu` | 90 | MenuController | JUGAR (cargos por equipo con disponibilidad y motivo), ACTUALIZACIONES, EQUIPO, AJUSTES, AYUDA, SOPORTE, CONTINUAR. Tecla M / Start. Columna con scroll en móvil horizontal. |
| `ColegioRP_Ajustes` | 50 | SettingsController | Botones Bajo / Medio / Alto (Alto: materiales 2022 con iluminación Future, todo al máximo, realce de luz; Bajo: materiales simplificados y sin efectos); partículas, decoración lejana, postprocesado, sombras, sonidos ambiente, animaciones cosméticas, límite de efectos, escala de texto, movimiento reducido, subtítulos, 12/24 h, ocultar etiquetas, Restaurar. Aviso de FPS bajo. |
| `ColegioRP_Ayuda` | 50 | HelpController | Secciones de `Catalogs.Ayuda`, controles según dispositivo, FAQ, búsqueda. |
| `ColegioRP_Soporte` | 50 | SupportController | Categoría, ubicación (zona actual), descripción con contador; estado de envío e id. |
| `ColegioRP_HUD` | 10 | HUDController | Hora real (aprox.), hora escolar y estado, cargo, salón, próxima actividad, saldo, avisos; botones ☰, Cuaderno, Panel de cargo; acciones contextuales; minimizable. |
| `ColegioRP_Aula` | 50 | ClassroomController | Docente: sesión, tema, aviso, asistencia (sentados/de pie), actividades, respuestas, calificar, resultados, invitar al tablero. Estudiante: Cuaderno (autoguardado), Actividad, Levantar mano, Ver tablero. |
| `ColegioRP_Tablero` | 51 | BoardController | Vista del tablero del aula; texto, plantillas, 4 colores, dibujo con turno temporizado. |
| `ColegioRP_Comedor`, `ColegioRP_Cafeteria` | 50 | Food/CafeteriaController | Estado de raciones y reclamo; cocina por pasos; catálogo, carrito, recibo; panel del vendedor (abrir, precios, reponer, cierre). |
| `ColegioRP_Futbol` | 50 | FootballController | Marcador, reloj, unirse A/B, Patear (E / X / botón táctil con carga). |
| `ColegioRP_PC` | 50 | PCController | Escritorio escolar: Procesador, Cuestionario, Simulador, Programación (cuadrícula 8×8), Pantalla de clase. |
| `ColegioRP_Personal` | 50 | StaffController | Paneles por cargo (dirección, coordinación, convivencia, orientación, enfermería, secretaría, finanzas, recepción/seguridad, limpieza, moderación con confirmación en dos pasos). Tecla P. |
| `ColegioRP_Etiqueta_<id>` | — | NametagController | BillboardGui: nombre, icono del colegio, cargo abreviado; oculta a >60 studs o por ajuste. |

Verificado en el simulador: dos clientes (PC y móvil) crean 11 interfaces sin duplicados ni errores.
