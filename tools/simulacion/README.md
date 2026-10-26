# Simulador headless de Roblox — Colegio RP

Ejecuta el código real de `src/` fuera de Roblox Studio, sobre una máquina virtual Lua 5.3 escrita en JavaScript ([fengari](https://github.com/fengari-lua/fengari)), con una imitación de la API de Roblox y la **geometría real del mapa** exportada del `.rbxl`. Sirve para detectar errores de ejecución, incoherencias entre módulos y fallos de seguridad antes de abrir Studio. **No sustituye** las pruebas en Studio (ver `docs/G_Pruebas.md`).

## Uso

```bash
cd tools/simulacion
npm install
# (una vez) exportar la geometría del mapa desde tu copia del lugar:
python3 ../exportar_mapa_sim.py /ruta/a/COLEGIO_JEAN_PIAGET.rbxl   # requiere: pip install zstandard
npm test                                   # todos los escenarios
node run.js escenarios/todos.lua fuzz_remotos   # uno concreto
```

Sin el archivo `datos/mapa_rbxl.lua` el simulador funciona igual, pero las pruebas que dependen del mapa (asientos, PCs, puertas) se omiten o fallan con un aviso. Ese archivo no se versiona: se genera a partir del `.rbxl` de cada desarrollador.

## Escenarios

| Escenario | Qué comprueba |
|---|---|
| `arranque` | El servidor arranca con el mapa (67.117 instancias) sin errores; existen todos los remotos del contrato con su tipo; `Workspace.ColegioRP_Mapa` se construye y detecta asientos; dos clientes (PC y móvil) completan la pantalla de carga sin GUIs duplicadas. |
| `fuzz_remotos` (P14) | Para cada remoto cliente→servidor genera, a partir de su esquema real, cargas maliciosas: tipos erróneos, campos inventados, textos de 10.000 caracteres, ±1e308, NaN, infinito, enums inválidos, anidación de 50 niveles, Vector3 enormes, listas de 5.000 elementos, argumentos extra y ráfagas. Exige cero errores del servidor, respuesta `ok = false`, rechazo por límite de frecuencia, entradas en la auditoría y marca de jugador sospechoso. |
| `funcional` | Flujos de juego extremo a extremo (P3–P11) con jugadores simulados: cargos y spawns, aulas paralelas, asientos, cuaderno, actividades, jornada, comida y compras, puertas tras reaparecer, fútbol. |

## Qué simula

- **Tiempo virtual** con planificador propio: `task.wait/spawn/defer/delay`, `RunService.Heartbeat/Stepped/RenderStepped`, `os.clock/os.time/tick` y `workspace:GetServerTimeNow()` avanzan con el reloj del simulador (horas de juego en segundos reales).
- **Contextos separados** de servidor y de cada cliente: `RunService:IsClient()`, `Players.LocalPlayer`, cachés de `require` independientes, `FireServer` llega con el jugador correcto, `FireClient` solo al cliente destino (con cola hasta que el cliente se conecta, como Roblox). Los argumentos de remotos y bindables se **copian** como en Roblox (sin funciones ni metatablas).
- **Instancias** con jerarquía, propiedades tipadas (asignar un tipo incorrecto lanza el mismo error que Roblox), atributos (solo tipos admitidos), tags, señales, `WaitForChild` con aviso de espera infinita, `Destroy` que bloquea el `Parent`, `Clone`.
- **Mapa**: BaseParts con `CFrame`/`Size`, Seats reales, modelos, textos de letreros; consultas `GetPartBoundsInBox/InRadius`, `Raycast` (cajas alineadas a los ejes) con índice espacial; física mínima para piezas desancladas (gravedad y rebote en el suelo).
- **Servicios**: Players/personajes (muerte y reaparición), Teams, DataStore en memoria (rechaza lo que Roblox no puede guardar: Vector3, Instances, tablas mixtas, NaN; puede simular caídas), TextService con filtro determinista (`malapalabra`, `groseria`, `insulto` → `#`), TextChatService (canales, `TextChatCommand`), TweenService (aplica el objetivo al terminar), CollectionService, HttpService (JSON), ProximityPrompt, UserInputService/GuiService según dispositivo del cliente (pc, movil, tableta, consola).

## Qué no simula

- Render, colisiones físicas entre personajes y piezas, `Touched`, animaciones, sonido, red real (latencia cero salvo cesión de un paso), streaming.
- Diferencias Lua 5.3 frente a Luau: `tostring(2/1)` da `"2.0"` (solo afecta textos); `string.format("%d", 2.5)` se trunca y se informa en el apartado específico del informe (en Luau lanza error).

## Cómo leer el informe

- **ERRORES DEL JUEGO**: excepciones del código de `src/` (con archivo y línea). Hay que corregirlas.
- **LIMITACIONES DEL SIMULADOR**: miembros de la API de Roblox aún no imitados (mensajes con `simulador:`). Se añaden en `lib/instancias.lua` o `lib/servicios.lua` (`definir(clase, padre, { props, metodos, eventos, calc })`).
- **PROPIEDADES NO DECLARADAS**: escrituras a propiedades que el simulador no conoce. Si la propiedad existe en Roblox, añádela a la clase; si no existe, es un error tipográfico del juego.
- **warn() del juego**: avisos emitidos por el código (útiles para ver servicios ausentes o recursos del mapa no encontrados).

## Estructura

```
run.js              ejecutor fengari (leerArchivo, listarDirectorio, relojReal…)
lib/tipos.lua       Vector3, CFrame, Color3, UDim2, Enum, TweenInfo, Random, DateTime…
lib/planificador.lua tiempo virtual, task, señales, contextos
lib/instancias.lua  clases, propiedades, atributos, tags, GUI, BasePart/Model/Seat/Humanoid…
lib/servicios.lua   DataModel y servicios, jugadores y personajes, remotos, DataStore, consultas espaciales
lib/entorno.lua     globales Luau por contexto, require, ejecución de scripts
lib/cargador.lua    src/ → DataModel, carga del mapa, arranque de servidor y clientes
lib/arnes.lua       API de pruebas: Sim.nuevo, Sim.jugador, j:invocar, j:sentar, j:prompt… e informe
escenarios/         escenarios de prueba
datos/              geometría exportada del .rbxl (no versionada)
```
