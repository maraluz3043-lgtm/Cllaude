--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.PCService
	Tipo: ModuleScript
	Sala de tecnología y computadores (docs/ARQUITECTURA.md §6). Estado por PC con autoridad total del servidor:
	{ Encendido, OcupanteUserId, Bloqueado, Aplicacion, Proyeccion }. Para cada PC de MapService:PCs() crea una
	SurfaceGui en la pantalla real (fondo negro apagado / escritorio con reloj y nombre del colegio, "Libre" u
	"Ocupado por <nombre>", banda de bloqueo; solo se redibuja al cambiar) y un ProximityPrompt (RPTipo "PC",
	RPId, RPAccion "Usar") cuyo Triggered se resuelve aquí. Handler PCAction: Usar / Salir / Encender / Apagar /
	Aplicacion / Resultado (Procesador -> cuaderno; Cuestionario corregido en servidor con una entrega por
	jornada y recompensa de participación si llega al 60 %; actividad del aula reenviada a ClassroomService;
	Simulador recalculado con Catalogs.Simulador y tolerancia del 2 %; Programación ejecutada con el intérprete
	determinista de Catalogs.Programacion) / Bloquear / Desbloquear / Proyectar (docente con pc.bloquear en
	INFORMATICA o ROBOTICA). Libera el PC al salir, levantarse del Seat, alejarse, morir o abandonar el servidor.
	Nunca simula Internet real ni controla ningún PC real.
	Eventos al cliente: "PC" { Sub = "AbrirEscritorio" | "Estado" | "Resultado" | "Proyeccion" | "Bloqueo" }.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Catalogs = require(Shared:WaitForChild("Catalogs"))
local TimetableDefinitions = require(Shared:WaitForChild("TimetableDefinitions"))
local MapaLogico = require(Shared:WaitForChild("MapaLogico"))
local UITheme = require(Shared:WaitForChild("UITheme"))
local Util = Shared:WaitForChild("Util")
local Signal = require(Util:WaitForChild("Signal"))
local Maid = require(Util:WaitForChild("Maid"))
local Zones = require(Util:WaitForChild("Zones"))
local Format = require(Util:WaitForChild("Format"))

local PCService = {}
PCService.Nombre = "PCService"

local PREFIJO = "[ColegioRP][PCService]"
local Colores = UITheme.Colores
local DISTANCIA_PC = (Config.Distancias and Config.Distancias.PC) or 6
local RECOMPENSAS = (Config.Economia and Config.Economia.Recompensas) or {}
local CUADERNO = Config.Cuaderno or {}

---------------------------------------------------------------------------------------------------
-- Parámetros (ajustables sin tocar la lógica)
---------------------------------------------------------------------------------------------------
PCService.ToleranciaDistancia = 1 -- Studs sobre Config.Distancias.PC al usar un PC sin Seat (latencia de red).
PCService.MargenAlejarse = 3 -- Studs extra antes de liberar un PC sin Seat cuando el ocupante se aleja.
PCService.DistanciaPromptSinSeat = DISTANCIA_PC -- MaxActivationDistance del prompt de un PC sin Seat.
PCService.DistanciaPromptConSeat = DISTANCIA_PC + 2 -- Sentado, la raíz del personaje queda algo más lejos del monitor.
PCService.PixelesPorStud = 40 -- Resolución de la SurfaceGui de la pantalla.
PCService.ToleranciaSimulador = 0.02 -- 2 % de margen relativo al validar el simulador.
PCService.UmbralParticipacion = 0.6 -- Fracción mínima de aciertos del cuestionario para la recompensa.
PCService.MaxProyeccion = 300 -- Caracteres del texto proyectado por el docente.
PCService.MaxProcesador = CUADERNO.MaxCaracteresPagina or 1200 -- Caracteres del procesador de texto.
PCService.IntervaloProcesadorSeg = CUADERNO.MinIntervaloGuardadoSeg or 10 -- Segundos entre guardados en el cuaderno.
PCService.MaxPaginasCuaderno = CUADERNO.MaxPaginas or 20 -- Solo para el respaldo sin NotebookService.
PCService.MaxAnidamiento = 2 -- Niveles de REPETIR anidados aceptados en el servidor.
PCService.MaxRespuestaAula = (Config.Limites and Config.Limites.MaxRespuestaCaracteres) or 300
PCService.SalasBloqueables = { INFORMATICA = true, ROBOTICA = true } -- Salas que el docente puede bloquear/proyectar.
PCService.AppsExtra = { PantallaClase = "Pantalla de clase" } -- Apps del escritorio que no están en Catalogs.ActividadesPC.
PCService.MateriaPorDefecto = "TEC"
PCService.CooldownPromptSeg = 0.75 -- Pulsaciones del prompt más seguidas se ignoran.
PCService.IntervaloVigilanciaSeg = 1 -- Revisión de ocupantes (presencia, asiento, distancia).
PCService.CiclosReloj = 5 -- Cada cuántas vigilancias se recalcula el reloj de las pantallas.

local NOMBRE_GUI = "ColegioRP_PantallaPC"
local NOMBRE_PROMPT = "ColegioRP_PromptPC"
local CARAS_LATERALES = { Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right }
-- Claves que nunca se reenvían al cliente dentro del snapshot de clase (privacidad y respuestas correctas).
local CLAVES_PRIVADAS = {
	Submissions = true, Grades = true, Calificaciones = true, Pendientes = true, Destinatarios = true,
	Correcta = true, RespuestaCorrecta = true, Respuestas = true,
}

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function esJugador(valor)
	return typeof(valor) == "Instance" and valor:IsA("Player")
end

local function numeroFinito(valor)
	local n = tonumber(valor)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return nil
	end
	return n
end

local function enteroEn(valor, minimo, maximo)
	if typeof(valor) ~= "number" then
		return nil
	end
	local n = numeroFinito(valor)
	if n == nil or n ~= math.floor(n) or n < minimo or n > maximo then
		return nil
	end
	return n
end

local function nombreVisible(player)
	if not esJugador(player) then
		return "Docente"
	end
	local nombre = player.DisplayName
	if typeof(nombre) ~= "string" or nombre == "" then
		nombre = player.Name
	end
	return nombre
end

local function humanoideVivo(player)
	local personaje = player and player.Character
	if not personaje then
		return nil
	end
	local humanoide = personaje:FindFirstChildOfClass("Humanoid")
	if humanoide and humanoide.Health > 0 then
		return humanoide
	end
	return nil
end

local function posicionDe(player)
	local personaje = player and player.Character
	if not personaje then
		return nil
	end
	local raiz = personaje:FindFirstChild("HumanoidRootPart")
	if raiz and raiz:IsA("BasePart") then
		return raiz.Position
	end
	return nil
end

-- Acepta segundos del día (número) o "HH:MM" (texto).
local function segundosDeHora(valor)
	if typeof(valor) == "number" then
		return numeroFinito(valor)
	end
	if typeof(valor) == "string" then
		return Format.SegundosDeHHMM(valor)
	end
	return nil
end

local function ahoraServidor()
	local ok, valor = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if ok and typeof(valor) == "number" then
		return valor
	end
	return os.time()
end

local function copiarTabla(origen)
	local copia = {}
	if typeof(origen) == "table" then
		for clave, valor in pairs(origen) do
			copia[clave] = valor
		end
	end
	return copia
end

-- Copia apta para un RemoteEvent: solo textos, números finitos, booleanos y tablas acotadas, sin claves privadas.
-- Si una tabla mezcla claves de texto y numéricas, las numéricas pasan a texto (los remotos no admiten mezclas).
local function copiaSegura(valor, profundidad, presupuesto)
	profundidad = profundidad or 0
	presupuesto = presupuesto or { Claves = 0 }
	local tipo = typeof(valor)
	if tipo == "string" or tipo == "boolean" then
		return valor
	end
	if tipo == "number" then
		return numeroFinito(valor)
	end
	if tipo ~= "table" or profundidad > 5 then
		return nil
	end
	local tieneTexto = false
	for clave in pairs(valor) do
		if typeof(clave) == "string" then
			tieneTexto = true
			break
		end
	end
	local copia = {}
	for clave, v in pairs(valor) do
		presupuesto.Claves = presupuesto.Claves + 1
		if presupuesto.Claves > 300 then
			break
		end
		local tipoClave = typeof(clave)
		local valida = false
		if tipoClave == "string" then
			valida = not CLAVES_PRIVADAS[clave]
		elseif tipoClave == "number" then
			valida = clave >= 1 and clave == math.floor(clave)
		end
		if valida then
			local limpio = copiaSegura(v, profundidad + 1, presupuesto)
			if limpio ~= nil then
				if tieneTexto then
					copia[tostring(clave)] = limpio
				else
					copia[clave] = limpio
				end
			end
		end
	end
	return copia
end

-- Llama servicio:metodo(...) en pcall si existe. Devuelve ok, resultado1, resultado2.
local function invocar(servicio, metodo, ...)
	if typeof(servicio) ~= "table" or typeof(servicio[metodo]) ~= "function" then
		return false, nil, nil
	end
	local resultado = table.pack(pcall(servicio[metodo], servicio, ...))
	if not resultado[1] then
		warn(PREFIJO .. " Error en " .. tostring(servicio.Nombre or "?") .. ":" .. tostring(metodo) .. ": " .. tostring(resultado[2]))
		return false, nil, nil
	end
	return true, resultado[2], resultado[3]
end

local function exito(datos)
	return { ok = true, datos = datos or {} }
end

local function fallo(mensaje)
	return { ok = false, error = tostring(mensaje or "No se pudo completar la acción.") }
end

local function fijarTexto(label, valor)
	if label and label.Text ~= valor then
		label.Text = valor
	end
end

local function fijarVisible(objeto, valor)
	if objeto and objeto.Visible ~= valor then
		objeto.Visible = valor
	end
end

-- Comprueba que no haya más REPETIR anidados de los permitidos (el intérprete de Catalogs admite más).
local function comprobarAnidamiento(lineas, maximo)
	local profundidad = 0
	for i, linea in ipairs(lineas) do
		local limpia = string.upper(Format.Recortar(linea))
		if limpia ~= "" and not string.match(limpia, "^%-%-") then
			if string.match(limpia, "^REPETIR") then
				profundidad = profundidad + 1
				if profundidad > maximo then
					return false, string.format("Línea %d: demasiados REPETIR anidados (máximo %d)", i, maximo)
				end
			elseif limpia == "FIN" then
				profundidad = math.max(0, profundidad - 1)
			end
		end
	end
	return true, nil
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function PCService:Init(registro)
	self.registro = registro
	self.Estados = {} -- pcId -> { Encendido, OcupanteUserId, OcupanteNombre, Bloqueado, Aplicacion, Proyeccion }
	self.Registros = {} -- pcId -> { Id, Pantalla, Seat, RoomId, Marcador, Modelo, Numero }
	self.Orden = {} -- pcIds en el orden de MapService
	self.PorSala = {} -- roomId -> { pcId... }
	self.Salas = {} -- roomId -> { Bloqueado, BloqueadoPor, BloqueadoPorNombre, Proyeccion = { Texto, Autor, AutorUserId, T } }
	self.PcDeJugador = {} -- userId -> pcId
	self.Ocupaciones = {} -- pcId -> Maid con la vigilancia del ocupante
	self.ModoDistancia = {} -- pcId -> true si el ocupante lo usa sin Seat
	self.Pantallas = {} -- pcId -> widgets de la SurfaceGui + Firma
	self.Prompts = {} -- pcId -> ProximityPrompt
	self.Entregas = { Clave = "", PorJugador = {} } -- cuestionarios entregados en la jornada actual
	self.JornadaLocal = 1 -- respaldo de número de jornada si SchoolDayService no lo informa
	self.UltimoPrompt = {} -- userId -> os.clock()
	self.UltimoProcesador = {} -- userId -> os.clock()
	self.RelojTexto = "--:--"
	self.ProgresoCongelado = nil
	self.Estadisticas = { Usos = 0, Resultados = 0, Cuestionarios = 0, Programas = 0, Simulaciones = 0, Textos = 0, Rechazos = 0 }
	self.EstadoCambiado = Signal.new() -- (pcId, estadoPublico)
	self.Maid = Maid.new()
	self.MaidMapa = Maid.new() -- SurfaceGuis, prompts y sus conexiones (se rehacen al reconstruir el mapa)
	self.Activo = false
	self.Listo = false
	self._proyectandoTablero = false
end

function PCService:Start()
	self.Activo = true
	local RemoteService = self:Servicio("RemoteService")
	if RemoteService and typeof(RemoteService.Registrar) == "function" then
		RemoteService:Registrar("PCAction", function(player, datos)
			return self:Manejar(player, datos)
		end)
		-- Parte "PC" del StateSnapshot: el cliente sabe tras reconectar si sigue ocupando un equipo (P10).
		invocar(RemoteService, "AportarSnapshot", "PC", function(player)
			return self:SnapshotJugador(player)
		end)
	else
		warn(PREFIJO .. " RemoteService no disponible: PCAction no tendrá handler.")
	end

	self.RelojTexto = self:CalcularReloj()
	local okConstruir, errConstruir = pcall(self.Construir, self)
	if not okConstruir then
		warn(PREFIJO .. " No se pudieron preparar los PCs: " .. tostring(errConstruir))
	end

	-- Reconstrucción del mapa (MapService:Reconstruir) -> se rehacen pantallas y prompts.
	local MapService = self:Servicio("MapService")
	if MapService and typeof(MapService.Construido) == "table" then
		self:Conectar(MapService.Construido, function()
			task.defer(function()
				local ok, err = pcall(self.Construir, self)
				if not ok then
					warn(PREFIJO .. " Error al reconstruir los PCs: " .. tostring(err))
				end
			end)
		end)
	end

	self:Conectar(Players.PlayerRemoving, function(player)
		self:AlSalirJugador(player)
	end)

	local SchoolDay = self:Servicio("SchoolDayService")
	if SchoolDay then
		if typeof(SchoolDay.JornadaTerminada) == "table" then
			self:Conectar(SchoolDay.JornadaTerminada, function()
				local ok, err = pcall(self.AlTerminarJornada, self)
				if not ok then
					warn(PREFIJO .. " Error al cerrar la jornada: " .. tostring(err))
				end
			end)
		end
		if typeof(SchoolDay.EstadoCambiado) == "table" then
			self:Conectar(SchoolDay.EstadoCambiado, function()
				task.defer(function()
					pcall(self.ActualizarReloj, self)
				end)
			end)
		end
	end

	local RoleService = self:Servicio("RoleService")
	if RoleService and typeof(RoleService.CargoCambiado) == "table" then
		self:Conectar(RoleService.CargoCambiado, function(player)
			pcall(self.AlCambiarCargo, self, player)
		end)
	end

	self.Maid:GiveTask(task.spawn(function()
		self:BucleVigilancia()
	end))
end

-- Detiene el servicio y retira pantallas y prompts (uso desde Studio / desinstalador).
function PCService:Detener()
	self.Activo = false
	for pcId in pairs(self.Ocupaciones) do
		self:Liberar(pcId, "El servicio de computadores se detuvo.")
	end
	self.MaidMapa:DoCleaning()
	self.Maid:DoCleaning()
	self.Pantallas = {}
	self.Prompts = {}
end

-- Servicio por nombre a través del registro (nil si no existe).
function PCService:Servicio(nombre)
	local registro = self.registro
	if registro and typeof(registro.Get) == "function" then
		local ok, servicio = pcall(registro.Get, nombre)
		if ok and typeof(servicio) == "table" then
			return servicio
		end
	end
	return nil
end

-- Conecta una señal (RBXScriptSignal o Signal propio) y guarda la conexión en el Maid indicado.
function PCService:Conectar(senal, fn, maid)
	maid = maid or self.Maid
	if senal == nil then
		return nil
	end
	local ok, conexion = pcall(function()
		return senal:Connect(fn)
	end)
	if ok and conexion ~= nil then
		maid:GiveTask(conexion)
		return conexion
	end
	return nil
end

function PCService:Auditar(categoria, player, accion, detalle)
	local AuditLog = self:Servicio("AuditLogService")
	if AuditLog and typeof(AuditLog.Registrar) == "function" then
		pcall(AuditLog.Registrar, AuditLog, categoria, player, accion, detalle)
	end
end

-- Rechazo lógico de PCAction (estado, distancia, pertenencia, datos): se audita; los sospechosos van a métricas.
function PCService:Rechazo(player, motivo, detalle, sospechoso)
	self.Estadisticas.Rechazos = self.Estadisticas.Rechazos + 1
	local texto = tostring(motivo)
	if detalle ~= nil and detalle ~= "" then
		texto = texto .. ": " .. tostring(detalle)
	end
	self:Auditar("Remoto", player, "PCAction", texto)
	if sospechoso then
		invocar(self:Servicio("MetricsService"), "IncrementarRechazo", "PCAction", motivo)
	end
end

function PCService:Enviar(player, datos)
	if not esJugador(player) or player.Parent == nil then
		return false
	end
	local ok, enviado = invocar(self:Servicio("RemoteService"), "Enviar", player, "PC", datos)
	return ok and enviado == true
end

function PCService:Notificar(player, texto, nivel)
	if not esJugador(player) or typeof(texto) ~= "string" or texto == "" then
		return
	end
	invocar(self:Servicio("RemoteService"), "Enviar", player, "Notificacion", {
		Titulo = "Computador", Texto = texto, Nivel = nivel or "info", Tipo = nivel or "info", Duracion = 4,
	})
end

---------------------------------------------------------------------------------------------------
-- Construcción de PCs (pantallas y prompts) a partir de MapService
---------------------------------------------------------------------------------------------------
function PCService:Sala(roomId)
	local sala = self.Salas[roomId]
	if not sala then
		sala = { RoomId = roomId, Bloqueado = false, BloqueadoPor = nil, BloqueadoPorNombre = nil, Proyeccion = nil }
		self.Salas[roomId] = sala
	end
	return sala
end

function PCService:Construir()
	local MapService = self:Servicio("MapService")
	local lista = {}
	local okLista, resultado = invocar(MapService, "PCs")
	if okLista and typeof(resultado) == "table" then
		lista = resultado
	elseif not MapService then
		warn(PREFIJO .. " MapService no disponible: no hay PCs que preparar.")
	end

	local anteriores = self.Registros
	self.MaidMapa:DoCleaning()
	self.Pantallas = {}
	self.Prompts = {}
	self.Registros = {}
	self.Orden = {}
	self.PorSala = {}

	local conSeat = 0
	for _, registro in ipairs(lista) do
		local valido = typeof(registro) == "table" and typeof(registro.Id) == "string" and registro.Id ~= ""
			and typeof(registro.Pantalla) == "Instance" and registro.Pantalla:IsA("BasePart")
		if valido and self.Registros[registro.Id] == nil then
			local seat = registro.Seat
			if typeof(seat) ~= "Instance" or not seat:IsA("BasePart") then
				seat = nil
			end
			local sala = registro.RoomId
			if typeof(sala) ~= "string" or sala == "" then
				sala = Zones.IdDe(registro.Pantalla.Position) or "SIN_SALA"
			end
			local deSala = self.PorSala[sala]
			if not deSala then
				deSala = {}
				self.PorSala[sala] = deSala
			end
			table.insert(deSala, registro.Id)
			self.Registros[registro.Id] = {
				Id = registro.Id,
				Pantalla = registro.Pantalla,
				Seat = seat,
				RoomId = sala,
				Marcador = registro.Marcador,
				Modelo = registro.Modelo,
				Numero = #deSala,
			}
			table.insert(self.Orden, registro.Id)
			if seat then
				conSeat = conSeat + 1
			end
		end
	end

	-- PCs que desaparecen o cambian de pantalla/asiento: se liberan.
	for pcId, estado in pairs(self.Estados) do
		local actual = self.Registros[pcId]
		if not actual then
			if estado.OcupanteUserId ~= nil then
				self:Liberar(pcId, "El equipo dejó de estar disponible.")
			end
			self.Estados[pcId] = nil
		elseif estado.OcupanteUserId ~= nil then
			local anterior = anteriores[pcId]
			if not anterior or anterior.Seat ~= actual.Seat or anterior.Pantalla ~= actual.Pantalla then
				self:Liberar(pcId, "El equipo se reinició.")
			end
		end
	end

	for _, pcId in ipairs(self.Orden) do
		local info = self.Registros[pcId]
		local sala = self:Sala(info.RoomId)
		local estado = self.Estados[pcId]
		if not estado then
			estado = { Encendido = false, OcupanteUserId = nil, OcupanteNombre = nil, Bloqueado = false, Aplicacion = nil, Proyeccion = nil }
			self.Estados[pcId] = estado
		end
		estado.Bloqueado = sala.Bloqueado == true
		estado.Proyeccion = sala.Proyeccion and sala.Proyeccion.Texto or nil
		local okGui, errGui = pcall(self.CrearPantalla, self, pcId)
		if not okGui then
			warn(PREFIJO .. " No se pudo crear la pantalla de " .. pcId .. ": " .. tostring(errGui))
		end
		local okPrompt, errPrompt = pcall(self.CrearPrompt, self, pcId)
		if not okPrompt then
			warn(PREFIJO .. " No se pudo crear el prompt de " .. pcId .. ": " .. tostring(errPrompt))
		end
		self:ActualizarPantalla(pcId, true)
		self:ActualizarPrompt(pcId)
	end

	local salas = 0
	for _ in pairs(self.PorSala) do
		salas = salas + 1
	end
	self:Auditar("Sistema", nil, "PCs", string.format("%d PCs preparados (%d con Seat) en %d salas", #self.Orden, conSeat, salas))
	self.Listo = true
end

-- Punto hacia el que debe mirar la pantalla: el Seat emparejado o el centro de la sala.
function PCService:PuntoObjetivo(info)
	if info.Seat then
		return info.Seat.Position
	end
	local zona = MapaLogico.Zonas and MapaLogico.Zonas[info.RoomId]
	if zona and typeof(zona.Centro) == "Vector3" then
		return zona.Centro
	end
	return nil
end

-- Cara lateral de la pantalla que mira hacia el objetivo (ponderada por el área: descarta los cantos finos).
function PCService:ElegirCara(pantalla, objetivo)
	if typeof(objetivo) ~= "Vector3" then
		return Enum.NormalId.Front
	end
	local direccion = objetivo - pantalla.Position
	direccion = Vector3.new(direccion.X, 0, direccion.Z)
	if direccion.Magnitude < 0.05 then
		return Enum.NormalId.Front
	end
	direccion = direccion.Unit
	local tamano = pantalla.Size
	local mejor, mejorPuntaje = Enum.NormalId.Front, -math.huge
	for _, cara in ipairs(CARAS_LATERALES) do
		local normal = pantalla.CFrame:VectorToWorldSpace(Vector3.FromNormalId(cara))
		local plano = Vector3.new(normal.X, 0, normal.Z)
		if plano.Magnitude > 0.05 then
			local alineacion = plano.Unit:Dot(direccion) * math.min(1, plano.Magnitude)
			local area = tamano.Z * tamano.Y
			if cara == Enum.NormalId.Front or cara == Enum.NormalId.Back then
				area = tamano.X * tamano.Y
			end
			if alineacion > 0 then
				local puntaje = alineacion * math.sqrt(math.max(area, 0.01))
				if puntaje > mejorPuntaje then
					mejor, mejorPuntaje = cara, puntaje
				end
			end
		end
	end
	return mejor
end

local function nuevoMarco(nombre, padre, color, transparencia, posicion, tamano, z)
	local marco = Instance.new("Frame")
	marco.Name = nombre
	marco.BackgroundColor3 = color
	marco.BackgroundTransparency = transparencia or 0
	marco.BorderSizePixel = 0
	marco.Position = posicion or UDim2.new(0, 0, 0, 0)
	marco.Size = tamano or UDim2.new(1, 0, 1, 0)
	marco.ZIndex = z or 1
	marco.Parent = padre
	return marco
end

local function nuevoTexto(nombre, padre, contenido, fuente, color, posicion, tamano, alineacion, maximo, z)
	local label = Instance.new("TextLabel")
	label.Name = nombre
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Font = fuente
	label.TextColor3 = color
	label.TextScaled = true
	label.TextWrapped = true
	label.Text = contenido
	label.TextXAlignment = alineacion or Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Position = posicion
	label.Size = tamano
	label.ZIndex = z or 2
	local limite = Instance.new("UITextSizeConstraint")
	limite.MaxTextSize = maximo or 40
	limite.MinTextSize = 4
	limite.Parent = label
	label.Parent = padre
	return label
end

-- SurfaceGui de la pantalla. Va dentro del marcador del PC en Workspace.ColegioRP_Mapa.PCs (Adornee = monitor
-- real), así se regenera con el mapa y no se añade nada al modelo original; si no hay marcador, va en el monitor.
function PCService:CrearPantalla(pcId)
	local info = self.Registros[pcId]
	local pantalla = info.Pantalla
	local padre = info.Marcador
	if typeof(padre) ~= "Instance" or padre.Parent == nil then
		padre = pantalla
	end
	local previa = padre:FindFirstChild(NOMBRE_GUI)
	if previa and previa:GetAttribute("ColegioRP") == true then
		previa:Destroy()
	end

	local gui = Instance.new("SurfaceGui")
	gui.Name = NOMBRE_GUI
	gui.Adornee = pantalla
	gui.Face = self:ElegirCara(pantalla, self:PuntoObjetivo(info))
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = self.PixelesPorStud
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.ClipsDescendants = true
	gui:SetAttribute("ColegioRP", true)
	gui:SetAttribute("PcId", pcId)

	local etiquetaEquipo = "Equipo " .. tostring(info.Numero) .. " · " .. pcId
	local base = nuevoMarco("Base", gui, Color3.new(0, 0, 0), 0)
	local escritorio = nuevoMarco("Escritorio", base, Colores.Azul, 0, nil, nil, 2)
	local degradado = Instance.new("UIGradient")
	degradado.Color = ColorSequence.new(Colores.Azul, Colores.GrisPanel)
	degradado.Rotation = 90
	degradado.Parent = escritorio
	local barra = nuevoMarco("Barra", escritorio, Colores.RojoOscuro, 0, UDim2.new(0, 0, 0, 0), UDim2.new(1, 0, 0.2, 0), 3)
	nuevoTexto("Colegio", barra, tostring(Config.NombreCorto or Config.NombreColegio or "Colegio"), UITheme.Fuente("Titulo"),
		Colores.Blanco, UDim2.new(0.04, 0, 0.1, 0), UDim2.new(0.62, 0, 0.8, 0), Enum.TextXAlignment.Left, 28, 4)
	local reloj = nuevoTexto("Reloj", barra, self.RelojTexto, UITheme.Fuente("Titulo"), Colores.Amarillo,
		UDim2.new(0.7, 0, 0.1, 0), UDim2.new(0.26, 0, 0.8, 0), Enum.TextXAlignment.Right, 28, 4)
	local centro = nuevoTexto("Centro", escritorio, "Escritorio escolar", UITheme.Fuente("Subtitulo"), Colores.Blanco,
		UDim2.new(0.06, 0, 0.25, 0), UDim2.new(0.88, 0, 0.47, 0), nil, 36, 3)
	local estadoTexto = nuevoTexto("Estado", escritorio, "Libre", UITheme.Fuente("Texto"), Colores.TextoSecundario,
		UDim2.new(0.06, 0, 0.75, 0), UDim2.new(0.88, 0, 0.12, 0), nil, 24, 3)
	nuevoTexto("Equipo", escritorio, etiquetaEquipo, UITheme.Fuente("Texto"), Colores.TextoApagado,
		UDim2.new(0.06, 0, 0.88, 0), UDim2.new(0.88, 0, 0.09, 0), nil, 14, 3)
	local apagado = nuevoMarco("Apagado", base, Color3.new(0, 0, 0), 0, nil, nil, 5)
	local estadoApagado = nuevoTexto("EstadoApagado", apagado, "Libre", UITheme.Fuente("Texto"), Colores.TextoApagado,
		UDim2.new(0.1, 0, 0.74, 0), UDim2.new(0.8, 0, 0.12, 0), nil, 18, 6)
	nuevoTexto("EquipoApagado", apagado, etiquetaEquipo, UITheme.Fuente("Texto"), Color3.fromRGB(70, 72, 78),
		UDim2.new(0.1, 0, 0.87, 0), UDim2.new(0.8, 0, 0.09, 0), nil, 12, 6)
	local bloqueo = nuevoMarco("Bloqueo", base, Colores.RojoOscuro, 0.1, UDim2.new(0, 0, 0.36, 0), UDim2.new(1, 0, 0.28, 0), 8)
	nuevoTexto("TextoBloqueo", bloqueo, "BLOQUEADO POR EL DOCENTE", UITheme.Fuente("Titulo"), Colores.Blanco,
		UDim2.new(0.04, 0, 0.1, 0), UDim2.new(0.92, 0, 0.8, 0), nil, 28, 9)
	escritorio.Visible = false
	bloqueo.Visible = false

	gui.Parent = padre
	self.MaidMapa:GiveTask(gui)
	self.Pantallas[pcId] = {
		Gui = gui, Escritorio = escritorio, Reloj = reloj, Centro = centro, Estado = estadoTexto,
		Apagado = apagado, EstadoApagado = estadoApagado, Bloqueo = bloqueo, Firma = nil,
	}
end

-- ProximityPrompt sobre el monitor real (añadir prompts a objetos existentes está permitido por §0.1; se retira
-- al reconstruir o detener el servicio). Triggered se resuelve en el servidor.
function PCService:CrearPrompt(pcId)
	local info = self.Registros[pcId]
	local pantalla = info.Pantalla
	local previo = pantalla:FindFirstChild(NOMBRE_PROMPT)
	if previo and previo:IsA("ProximityPrompt") and previo:GetAttribute("ColegioRP") == true then
		previo:Destroy()
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = NOMBRE_PROMPT
	prompt.ActionText = "Usar computador"
	prompt.ObjectText = "Equipo " .. tostring(info.Numero)
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	if info.Seat then
		prompt.MaxActivationDistance = self.DistanciaPromptConSeat
	else
		prompt.MaxActivationDistance = self.DistanciaPromptSinSeat
	end
	pcall(function()
		prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	end)
	prompt:SetAttribute("RPTipo", "PC")
	prompt:SetAttribute("RPId", pcId)
	prompt:SetAttribute("RPAccion", "Usar")
	prompt:SetAttribute("ColegioRP", true)
	prompt.Parent = pantalla
	self.MaidMapa:GiveTask(prompt)
	self.MaidMapa:GiveTask(prompt.Triggered:Connect(function(player)
		self:AlActivarPrompt(player, pcId)
	end))
	self.Prompts[pcId] = prompt
end

---------------------------------------------------------------------------------------------------
-- Pantallas (solo se redibujan al cambiar)
---------------------------------------------------------------------------------------------------
function PCService:NombreApp(app)
	local actividad = Catalogs.ActividadPC(app)
	if actividad then
		return actividad.Nombre
	end
	return self.AppsExtra[app] or tostring(app)
end

function PCService:AppValida(app)
	return typeof(app) == "string" and (Catalogs.ActividadPC(app) ~= nil or self.AppsExtra[app] ~= nil)
end

function PCService:ActualizarPantalla(pcId, forzar)
	local pantalla = self.Pantallas[pcId]
	local estado = self.Estados[pcId]
	local info = self.Registros[pcId]
	if not pantalla or not estado or not info or not pantalla.Gui or pantalla.Gui.Parent == nil then
		return
	end
	local proyeccion = estado.Proyeccion
	local encendidoVisual = estado.Encendido == true or proyeccion ~= nil
	local textoEstado = "Libre"
	if estado.OcupanteUserId ~= nil then
		textoEstado = "Ocupado por " .. tostring(estado.OcupanteNombre or "un estudiante")
	end
	local centro = "Escritorio escolar"
	if proyeccion ~= nil then
		centro = "Proyección del docente:\n" .. proyeccion
	elseif estado.Aplicacion ~= nil then
		centro = self:NombreApp(estado.Aplicacion)
	elseif estado.OcupanteUserId == nil then
		if info.Seat then
			centro = "Siéntate y pulsa para usar"
		else
			centro = "Acércate y pulsa para usar"
		end
	end
	local reloj = ""
	if encendidoVisual then
		reloj = self.RelojTexto
	end
	local firma = table.concat({
		encendidoVisual and "1" or "0", estado.Bloqueado and "1" or "0", textoEstado, centro, reloj,
	}, "|")
	if not forzar and pantalla.Firma == firma then
		return
	end
	pantalla.Firma = firma
	fijarVisible(pantalla.Escritorio, encendidoVisual)
	fijarVisible(pantalla.Apagado, not encendidoVisual)
	fijarVisible(pantalla.Bloqueo, estado.Bloqueado == true)
	fijarTexto(pantalla.Estado, textoEstado)
	fijarTexto(pantalla.EstadoApagado, textoEstado)
	fijarTexto(pantalla.Centro, centro)
	if encendidoVisual then
		fijarTexto(pantalla.Reloj, reloj)
	end
end

function PCService:ActualizarPrompt(pcId)
	local prompt = self.Prompts[pcId]
	local estado = self.Estados[pcId]
	if not prompt or not estado or prompt.Parent == nil then
		return
	end
	local habilitado = estado.OcupanteUserId == nil
	if prompt.Enabled ~= habilitado then
		prompt.Enabled = habilitado
	end
	local accion = "Usar computador"
	if estado.Bloqueado then
		accion = "Bloqueado por el docente"
	end
	if prompt.ActionText ~= accion then
		prompt.ActionText = accion
	end
end

-- Hora escolar (SchoolDayService) o, sin jornada, la hora del servidor. Formato "HH:MM".
function PCService:CalcularReloj()
	local okS, snap = invocar(self:Servicio("SchoolDayService"), "Snapshot")
	if okS and typeof(snap) == "table" and typeof(snap.Estado) == "string" then
		local inicio = segundosDeHora(snap.HoraEscolarInicio) or TimetableDefinitions.HoraEscolarSegundos(snap.Estado)
		if inicio then
			local fin = segundosDeHora(snap.HoraEscolarFin) or TimetableDefinitions.HoraEscolarFinSegundos(snap.Estado) or inicio
			local duracion = numeroFinito(snap.Duracion)
			if duracion == nil then
				local periodo = TimetableDefinitions.Periodo(snap.Estado)
				duracion = (periodo and periodo.Duracion) or 0
			end
			local progreso = 0
			if snap.Pausada == true then
				if self.ProgresoCongelado and self.ProgresoCongelado.Estado == snap.Estado then
					progreso = self.ProgresoCongelado.Valor
				else
					progreso = numeroFinito(snap.Progreso) or 0
				end
			else
				local inicioServidor = numeroFinito(snap.InicioServidor)
				if inicioServidor and duracion > 0 then
					progreso = (ahoraServidor() - inicioServidor) / duracion
				end
			end
			progreso = math.clamp(progreso, 0, 1)
			self.ProgresoCongelado = { Estado = snap.Estado, Valor = progreso }
			return Format.HoraHHMM(inicio + (fin - inicio) * progreso)
		end
	end
	local t = os.date("*t")
	if typeof(t) == "table" then
		return string.format("%02d:%02d", t.hour or 0, t.min or 0)
	end
	return "--:--"
end

function PCService:ActualizarReloj()
	local texto = self:CalcularReloj()
	if texto == self.RelojTexto then
		return
	end
	self.RelojTexto = texto
	for _, pcId in ipairs(self.Orden) do
		self:ActualizarPantalla(pcId)
	end
end

---------------------------------------------------------------------------------------------------
-- Estado público
---------------------------------------------------------------------------------------------------
function PCService:EstadoPublico(pcId)
	local estado = self.Estados[pcId]
	if not estado then
		return nil
	end
	local info = self.Registros[pcId]
	return {
		PcId = pcId,
		RoomId = info and info.RoomId or nil,
		Numero = info and info.Numero or nil,
		Encendido = estado.Encendido == true,
		Ocupante = estado.OcupanteUserId,
		OcupanteNombre = estado.OcupanteNombre,
		Bloqueado = estado.Bloqueado == true,
		Aplicacion = estado.Aplicacion,
		Proyeccion = estado.Proyeccion,
		TieneSeat = info ~= nil and info.Seat ~= nil,
	}
end

function PCService:EmitirCambio(pcId)
	local publico = self:EstadoPublico(pcId)
	local ok, err = pcall(function()
		self.EstadoCambiado:Fire(pcId, publico)
	end)
	if not ok then
		warn(PREFIJO .. " Error en EstadoCambiado: " .. tostring(err))
	end
end

function PCService:EnviarEstado(player, pcId, motivo)
	local publico = self:EstadoPublico(pcId) or { PcId = pcId }
	publico.Sub = "Estado"
	publico.Motivo = motivo
	return self:Enviar(player, publico)
end

-- Destinatarios de los avisos de una sala: jugadores dentro de la zona, ocupantes de sus PCs y un actor extra.
function PCService:EnviarASala(roomId, datos, extraJugador)
	local destinatarios, vistos = {}, {}
	local function agregar(player)
		if esJugador(player) and player.Parent ~= nil and not vistos[player] then
			vistos[player] = true
			table.insert(destinatarios, player)
		end
	end
	local okZona, enZona = invocar(self:Servicio("RemoteService"), "JugadoresEnZona", roomId)
	if okZona and typeof(enZona) == "table" then
		for _, player in ipairs(enZona) do
			agregar(player)
		end
	else
		for _, player in ipairs(Players:GetPlayers()) do
			local posicion = posicionDe(player)
			if posicion and Zones.Contiene(roomId, posicion) then
				agregar(player)
			end
		end
	end
	for _, pcId in ipairs(self.PorSala[roomId] or {}) do
		local estado = self.Estados[pcId]
		if estado and estado.OcupanteUserId ~= nil then
			agregar(Players:GetPlayerByUserId(estado.OcupanteUserId))
		end
	end
	agregar(extraJugador)
	for _, player in ipairs(destinatarios) do
		self:Enviar(player, datos)
	end
	return #destinatarios
end

---------------------------------------------------------------------------------------------------
-- Ocupación: Usar / Liberar / vigilancia
---------------------------------------------------------------------------------------------------

-- ¿El humanoide está sentado en el Seat del PC? Acepta los Seats duplicados que MapService asocia al canónico.
function PCService:EstaSentadoEn(humanoide, seat)
	local actual = humanoide and humanoide.SeatPart
	if actual == nil or seat == nil then
		return false
	end
	if actual == seat then
		return true
	end
	local okCanon, canonico = invocar(self:Servicio("MapService"), "AsientoCanonico", actual)
	if okCanon and canonico == seat then
		return true
	end
	return actual:IsA("BasePart") and (actual.Position - seat.Position).Magnitude < 0.6
end

function PCService:AlActivarPrompt(player, pcId)
	if not esJugador(player) then
		return
	end
	local ahora = os.clock()
	local ultimo = self.UltimoPrompt[player.UserId]
	if ultimo and ahora - ultimo < self.CooldownPromptSeg then
		return
	end
	self.UltimoPrompt[player.UserId] = ahora
	local ok, mensaje = self:Usar(player, pcId, "Prompt")
	if not ok then
		self:Notificar(player, mensaje, "aviso")
	end
end

-- Ocupa el PC. origen: "Prompt" | "Remoto" | otro. Devuelve true, estadoPublico | false, mensaje.
function PCService:Usar(player, pcId, origen)
	if not esJugador(player) or player.Parent == nil then
		return false, "Jugador no válido."
	end
	local info = self.Registros[pcId]
	local estado = self.Estados[pcId]
	if not info or not estado then
		self:Rechazo(player, "pc_desconocido", tostring(pcId), origen == "Remoto")
		return false, "Ese equipo no existe."
	end
	local humanoide = humanoideVivo(player)
	if not humanoide then
		return false, "Necesitas tu personaje para usar el equipo."
	end

	-- El mismo jugador vuelve a pedirlo: se reenvía el escritorio (cliente reconectado o doble pulsación).
	if estado.OcupanteUserId == player.UserId then
		self:EnviarEscritorio(player, pcId)
		return true, self:EstadoPublico(pcId)
	end
	if estado.OcupanteUserId ~= nil then
		local ocupante = Players:GetPlayerByUserId(estado.OcupanteUserId)
		if ocupante and ocupante.Parent ~= nil then
			return false, "Este equipo está ocupado por " .. tostring(estado.OcupanteNombre or nombreVisible(ocupante)) .. "."
		end
		self:Liberar(pcId, nil, true)
	end
	local sala = self:Sala(info.RoomId)
	if estado.Bloqueado or sala.Bloqueado then
		return false, "Este equipo está bloqueado por el docente."
	end

	local modoDistancia = false
	if info.Seat then
		if not self:EstaSentadoEn(humanoide, info.Seat) then
			return false, "Siéntate en la silla de este equipo para usarlo."
		end
	else
		local posicion = posicionDe(player)
		if not posicion then
			return false, "Necesitas tu personaje para usar el equipo."
		end
		local distancia = (posicion - info.Pantalla.Position).Magnitude
		if distancia > DISTANCIA_PC + self.ToleranciaDistancia then
			self:Rechazo(player, "distancia", string.format("%s a %.1f studs", pcId, distancia), origen == "Remoto")
			return false, "Acércate al equipo (máximo " .. tostring(DISTANCIA_PC) .. " studs)."
		end
		modoDistancia = true
	end

	local previo = self.PcDeJugador[player.UserId]
	if previo and previo ~= pcId then
		self:Liberar(previo, "Cambiaste de equipo.", true, player.UserId)
	end

	estado.OcupanteUserId = player.UserId
	estado.OcupanteNombre = nombreVisible(player)
	estado.Encendido = true
	estado.Aplicacion = nil
	self.PcDeJugador[player.UserId] = pcId
	self.ModoDistancia[pcId] = modoDistancia
	self.Estadisticas.Usos = self.Estadisticas.Usos + 1
	self:VigilarOcupante(player, pcId, humanoide)

	-- Sin Seat, la pantalla se orienta hacia quien la usa (portátiles de robótica).
	if modoDistancia then
		local widgets = self.Pantallas[pcId]
		local posicion = posicionDe(player)
		if widgets and widgets.Gui and posicion then
			pcall(function()
				widgets.Gui.Face = self:ElegirCara(info.Pantalla, posicion)
			end)
		end
	end

	self:ActualizarPantalla(pcId)
	self:ActualizarPrompt(pcId)
	self:EnviarEscritorio(player, pcId)
	self:EmitirCambio(pcId)
	return true, self:EstadoPublico(pcId)
end

-- Conexiones que liberan el PC si el ocupante muere, pierde el personaje o se levanta del Seat.
function PCService:VigilarOcupante(player, pcId, humanoide)
	local anterior = self.Ocupaciones[pcId]
	if anterior then
		anterior:DoCleaning()
	end
	local maid = Maid.new()
	self.Ocupaciones[pcId] = maid
	local userId = player.UserId
	local info = self.Registros[pcId]
	maid:GiveTask(humanoide.Died:Connect(function()
		self:Liberar(pcId, "Tu personaje se reinició.", false, userId)
	end))
	maid:GiveTask(player.CharacterRemoving:Connect(function()
		self:Liberar(pcId, nil, false, userId)
	end))
	if info and info.Seat then
		local seat = info.Seat
		maid:GiveTask(humanoide:GetPropertyChangedSignal("SeatPart"):Connect(function()
			if not self:EstaSentadoEn(humanoide, seat) then
				self:Liberar(pcId, "Te levantaste del asiento.", false, userId)
			end
		end))
	end
end

-- Libera el PC. esperadoUserId evita liberar a un ocupante nuevo desde conexiones antiguas.
-- silencioso = true no avisa al ocupante. Devuelve true si se liberó.
function PCService:Liberar(pcId, motivo, silencioso, esperadoUserId)
	local estado = self.Estados[pcId]
	if not estado or estado.OcupanteUserId == nil then
		return false
	end
	if esperadoUserId ~= nil and estado.OcupanteUserId ~= esperadoUserId then
		return false
	end
	local userId = estado.OcupanteUserId
	estado.OcupanteUserId = nil
	estado.OcupanteNombre = nil
	estado.Encendido = false
	estado.Aplicacion = nil
	if self.PcDeJugador[userId] == pcId then
		self.PcDeJugador[userId] = nil
	end
	self.ModoDistancia[pcId] = nil
	local maid = self.Ocupaciones[pcId]
	self.Ocupaciones[pcId] = nil
	if maid then
		maid:DoCleaning()
	end
	self:ActualizarPantalla(pcId)
	self:ActualizarPrompt(pcId)
	if not silencioso then
		local player = Players:GetPlayerByUserId(userId)
		if player and player.Parent ~= nil then
			self:EnviarEstado(player, pcId, motivo)
		end
	end
	self:EmitirCambio(pcId)
	return true
end

function PCService:BucleVigilancia()
	local ciclos = 0
	while self.Activo do
		task.wait(self.IntervaloVigilanciaSeg)
		local ok, err = pcall(self.Vigilar, self)
		if not ok then
			warn(PREFIJO .. " Error al vigilar los PCs: " .. tostring(err))
		end
		ciclos = ciclos + 1
		if ciclos >= self.CiclosReloj then
			ciclos = 0
			local okReloj, errReloj = pcall(self.ActualizarReloj, self)
			if not okReloj then
				warn(PREFIJO .. " Error al actualizar el reloj: " .. tostring(errReloj))
			end
		end
	end
end

-- Respaldo de las conexiones: presencia, vida, asiento y distancia de cada ocupante.
function PCService:Vigilar()
	for _, pcId in ipairs(self.Orden) do
		local estado = self.Estados[pcId]
		if estado and estado.OcupanteUserId ~= nil then
			local userId = estado.OcupanteUserId
			local player = Players:GetPlayerByUserId(userId)
			local info = self.Registros[pcId]
			if not player or player.Parent == nil then
				self:Liberar(pcId, nil, true, userId)
			else
				local humanoide = humanoideVivo(player)
				if not humanoide then
					self:Liberar(pcId, "Tu personaje se reinició.", false, userId)
				elseif info and info.Seat then
					if not self:EstaSentadoEn(humanoide, info.Seat) then
						self:Liberar(pcId, "Te levantaste del asiento.", false, userId)
					end
				elseif info then
					local posicion = posicionDe(player)
					if not posicion or (posicion - info.Pantalla.Position).Magnitude > DISTANCIA_PC + self.MargenAlejarse then
						self:Liberar(pcId, "Te alejaste del equipo.", false, userId)
					end
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Escritorio del cliente
---------------------------------------------------------------------------------------------------
function PCService:MateriaActual()
	local okS, snap = invocar(self:Servicio("SchoolDayService"), "Snapshot")
	if okS and typeof(snap) == "table" and typeof(snap.Materia) == "string" and TimetableDefinitions.Materias[snap.Materia] then
		return snap.Materia
	end
	return self.MateriaPorDefecto
end

-- Clave de la jornada actual: número de jornada de SchoolDayService o, sin él, día + contador local.
function PCService:ClaveJornada()
	local okS, snap = invocar(self:Servicio("SchoolDayService"), "Snapshot")
	if okS and typeof(snap) == "table" and numeroFinito(snap.Jornada) then
		return "J" .. tostring(math.floor(numeroFinito(snap.Jornada)))
	end
	return Format.ClaveDia(os.time()) .. "#" .. tostring(self.JornadaLocal)
end

function PCService:EntregasDe(player)
	local clave = self:ClaveJornada()
	if self.Entregas.Clave ~= clave then
		self.Entregas = { Clave = clave, PorJugador = {} }
	end
	local propias = self.Entregas.PorJugador[player.UserId]
	if not propias then
		propias = {}
		self.Entregas.PorJugador[player.UserId] = propias
	end
	return propias
end

function PCService:ResumenEntregas(player)
	local resumen = {}
	for id, r in pairs(self:EntregasDe(player)) do
		resumen[id] = {
			CuestionarioId = id, Aciertos = r.Aciertos, Total = r.Total, Porcentaje = r.Porcentaje,
			Recompensa = r.Recompensa, Detalle = r.Detalle, Aprobado = r.Aprobado,
		}
	end
	return resumen
end

function PCService:EnviarEscritorio(player, pcId)
	local info = self.Registros[pcId]
	local estado = self.Estados[pcId]
	if not info or not estado then
		return false
	end
	local sala = self:Sala(info.RoomId)
	local actividad = nil
	local okA, snap = invocar(self:Servicio("ClassroomService"), "Snapshot", player)
	if okA and typeof(snap) == "table" then
		actividad = copiaSegura(snap)
	end
	local proyeccion = nil
	if sala.Proyeccion then
		proyeccion = { Texto = sala.Proyeccion.Texto, Autor = sala.Proyeccion.Autor, T = sala.Proyeccion.T }
	end
	local zona = MapaLogico.Zonas and MapaLogico.Zonas[info.RoomId]
	return self:Enviar(player, {
		Sub = "AbrirEscritorio",
		PcId = pcId,
		RoomId = info.RoomId,
		NombreSala = (zona and zona.Nombre) or info.RoomId,
		Apps = Catalogs.ActividadesPC,
		Proyeccion = proyeccion,
		ActividadAula = actividad,
		Estado = self:EstadoPublico(pcId),
		Bloqueado = estado.Bloqueado == true,
		Materia = self:MateriaActual(),
		Entregas = self:ResumenEntregas(player),
		NombreColegio = tostring(Config.NombreCorto or Config.NombreColegio or ""),
		Reloj = self.RelojTexto,
		MaxAnidamiento = self.MaxAnidamiento,
		ToleranciaSimulador = self.ToleranciaSimulador,
		UmbralParticipacion = self.UmbralParticipacion,
	})
end

---------------------------------------------------------------------------------------------------
-- Handler de PCAction
---------------------------------------------------------------------------------------------------
function PCService:Manejar(player, datos)
	if not esJugador(player) or typeof(datos) ~= "table" then
		return fallo("Petición no válida.")
	end
	local accion = datos.Accion
	local pcId = datos.PcId
	local extra = datos.Datos
	if typeof(extra) ~= "table" then
		extra = {}
	end

	if accion == "Usar" then
		local okUsar, resultado = self:Usar(player, pcId, "Remoto")
		if okUsar then
			return exito(resultado)
		end
		return fallo(resultado)
	elseif accion == "Salir" then
		return self:AccionSalir(player, pcId)
	elseif accion == "Encender" or accion == "Apagar" then
		return self:AccionEnergia(player, pcId, accion == "Encender")
	elseif accion == "Aplicacion" then
		return self:AccionAplicacion(player, pcId, extra)
	elseif accion == "Resultado" then
		return self:AccionResultado(player, pcId, extra)
	elseif accion == "Bloquear" or accion == "Desbloquear" then
		return self:AccionBloqueo(player, pcId, accion == "Bloquear")
	elseif accion == "Proyectar" then
		return self:AccionProyectar(player, pcId, extra)
	end
	self:Rechazo(player, "accion_desconocida", tostring(accion), true)
	return fallo("Acción desconocida.")
end

-- Devuelve el estado si el jugador es el ocupante (y, si se pide, el PC está encendido y sin bloqueo).
function PCService:ComprobarOcupante(player, pcId, requiereActivo)
	local estado = self.Estados[pcId]
	if not estado or not self.Registros[pcId] then
		self:Rechazo(player, "pc_desconocido", tostring(pcId), true)
		return nil, "Ese equipo no existe."
	end
	if estado.OcupanteUserId ~= player.UserId then
		self:Rechazo(player, "no_ocupante", pcId, false)
		return nil, "No estás usando este equipo."
	end
	if requiereActivo then
		if estado.Bloqueado then
			return nil, "El docente bloqueó este equipo."
		end
		if not estado.Encendido then
			return nil, "Enciende el equipo primero."
		end
	end
	return estado, nil
end

function PCService:AccionSalir(player, pcId)
	local estado = self.Estados[pcId]
	if estado and estado.OcupanteUserId == player.UserId then
		self:Liberar(pcId, nil, false, player.UserId)
	else
		-- Cliente desfasado: si ocupaba otro PC, se libera igualmente. Salir es idempotente.
		local propio = self.PcDeJugador[player.UserId]
		if propio then
			self:Liberar(propio, nil, false, player.UserId)
		end
	end
	return exito({ PcId = pcId, Libre = true })
end

function PCService:AccionEnergia(player, pcId, encender)
	local estado, err = self:ComprobarOcupante(player, pcId, false)
	if not estado then
		return fallo(err)
	end
	if encender and estado.Bloqueado then
		return fallo("El docente bloqueó este equipo.")
	end
	if estado.Encendido ~= encender then
		estado.Encendido = encender
		if not encender then
			estado.Aplicacion = nil
		end
		self:ActualizarPantalla(pcId)
		self:EmitirCambio(pcId)
	end
	self:EnviarEstado(player, pcId)
	return exito(self:EstadoPublico(pcId))
end

function PCService:AccionAplicacion(player, pcId, extra)
	local estado, err = self:ComprobarOcupante(player, pcId, true)
	if not estado then
		return fallo(err)
	end
	local app = extra.App
	if app == nil or app == "" or app == "Escritorio" then
		app = nil
	elseif not self:AppValida(app) then
		self:Rechazo(player, "app_invalida", tostring(app), true)
		return fallo("Aplicación desconocida.")
	end
	if estado.Aplicacion ~= app then
		estado.Aplicacion = app
		self:ActualizarPantalla(pcId)
		self:EmitirCambio(pcId)
	end
	return exito({ PcId = pcId, Aplicacion = app })
end

function PCService:AccionResultado(player, pcId, extra)
	local estado, err = self:ComprobarOcupante(player, pcId, true)
	if not estado then
		return fallo(err)
	end
	local app = extra.App
	local resultado, errResultado = nil, nil
	if app == "Procesador" then
		resultado, errResultado = self:ResultadoProcesador(player, pcId, extra)
	elseif app == "Cuestionario" then
		resultado, errResultado = self:ResultadoCuestionario(player, pcId, extra)
	elseif app == "Simulador" then
		resultado, errResultado = self:ResultadoSimulador(player, pcId, extra)
	elseif app == "Programacion" then
		resultado, errResultado = self:ResultadoProgramacion(player, pcId, extra)
	else
		self:Rechazo(player, "app_invalida", tostring(app), true)
		return fallo("Aplicación desconocida.")
	end
	if not resultado then
		return fallo(errResultado)
	end
	self.Estadisticas.Resultados = self.Estadisticas.Resultados + 1
	resultado.App = app
	resultado.PcId = pcId
	local solicitud = enteroEn(extra.Solicitud, 0, 1000000000)
	if solicitud then
		resultado.Solicitud = solicitud
	end
	if estado.Aplicacion ~= app then
		estado.Aplicacion = app
		self:ActualizarPantalla(pcId)
	end
	local evento = copiarTabla(resultado)
	evento.Sub = "Resultado"
	self:Enviar(player, evento)
	return exito(resultado)
end

---------------------------------------------------------------------------------------------------
-- Resultados por aplicación
---------------------------------------------------------------------------------------------------

-- Procesador de texto: el texto (≤ 1200) se añade al cuaderno del jugador.
function PCService:ResultadoProcesador(player, pcId, extra)
	local texto = extra.Texto
	if typeof(texto) ~= "string" then
		return nil, "Escribe algo antes de guardar."
	end
	texto = Format.Recortar(texto)
	local largo = utf8.len(texto)
	if largo == nil then
		self:Rechazo(player, "texto_invalido", pcId, true)
		return nil, "El texto contiene caracteres no válidos."
	end
	if largo == 0 then
		return nil, "El documento está vacío."
	end
	if largo > self.MaxProcesador then
		return nil, "El texto supera los " .. tostring(self.MaxProcesador) .. " caracteres."
	end
	local ahora = os.clock()
	local ultimo = self.UltimoProcesador[player.UserId]
	if ultimo and ahora - ultimo < self.IntervaloProcesadorSeg then
		return nil, string.format("Espera %d s antes de volver a guardar.", math.ceil(self.IntervaloProcesadorSeg - (ahora - ultimo)))
	end
	local materia = extra.Materia
	if typeof(materia) ~= "string" or not TimetableDefinitions.Materias[materia] then
		materia = self:MateriaActual()
	end
	local okGuardar, pagina = self:GuardarEnCuaderno(player, materia, texto)
	if not okGuardar then
		return nil, pagina
	end
	self.UltimoProcesador[player.UserId] = ahora
	self.Estadisticas.Textos = self.Estadisticas.Textos + 1
	return {
		Guardado = true,
		Materia = materia,
		NombreMateria = TimetableDefinitions.NombreMateria(materia),
		Caracteres = largo,
		Pagina = numeroFinito(pagina),
	}
end

local MENSAJES_CUADERNO = {
	sin_perfil = "Tu cuaderno todavía no está cargado; inténtalo en unos segundos.",
	texto_vacio = "El documento está vacío.",
	cuaderno_lleno = "Tu cuaderno está lleno: libera una página antes de guardar.",
}

-- Guarda en el cuaderno con NotebookService:AgregarEntrada; sin él, respaldo directo sobre el perfil (§4).
-- Devuelve true, pagina | false, mensaje.
function PCService:GuardarEnCuaderno(player, materia, texto)
	local Notebook = self:Servicio("NotebookService")
	if Notebook and typeof(Notebook.AgregarEntrada) == "function" then
		local ok, resultado, detalle = invocar(Notebook, "AgregarEntrada", player, materia, texto)
		if not ok then
			return false, "El cuaderno no respondió; inténtalo de nuevo."
		end
		if resultado == false then
			return false, MENSAJES_CUADERNO[detalle] or "No se pudo guardar en el cuaderno."
		end
		return true, detalle
	end

	-- Respaldo: perfil de DataService (Cuaderno = { Titulo, Paginas = { { Materia, Texto, Actualizado } } }).
	local DataService = self:Servicio("DataService")
	local okPerfil, perfil = invocar(DataService, "Obtener", player)
	if not okPerfil or typeof(perfil) ~= "table" then
		return false, MENSAJES_CUADERNO.sin_perfil
	end
	if typeof(perfil.Cuaderno) ~= "table" then
		perfil.Cuaderno = { Titulo = "Mi cuaderno", Paginas = {} }
	end
	if typeof(perfil.Cuaderno.Paginas) ~= "table" then
		perfil.Cuaderno.Paginas = {}
	end
	local paginas = perfil.Cuaderno.Paginas
	local numero = nil
	local ultima = paginas[#paginas]
	if ultima and ultima.Materia == materia and typeof(ultima.Texto) == "string" and ultima.Texto ~= "" then
		local combinado = ultima.Texto .. "\n\n" .. texto
		local largo = utf8.len(combinado)
		if largo and largo <= self.MaxProcesador then
			ultima.Texto = combinado
			ultima.Actualizado = os.time()
			numero = #paginas
		end
	end
	if not numero then
		for i, pagina in ipairs(paginas) do
			if typeof(pagina) == "table" and Format.Recortar(tostring(pagina.Texto or "")) == "" then
				pagina.Texto = texto
				pagina.Materia = materia
				pagina.Actualizado = os.time()
				numero = i
				break
			end
		end
	end
	if not numero then
		if #paginas >= self.MaxPaginasCuaderno then
			return false, MENSAJES_CUADERNO.cuaderno_lleno
		end
		table.insert(paginas, { Materia = materia, Texto = texto, Actualizado = os.time() })
		numero = #paginas
	end
	invocar(DataService, "Marcar", player)
	self:Notificar(player, "Se guardó en tu cuaderno (página " .. tostring(numero) .. ").", "exito")
	return true, numero
end

-- Cuestionario público (corregido aquí) o actividad del aula (reenviada a ClassroomService).
function PCService:ResultadoCuestionario(player, pcId, extra)
	if extra.ActividadId ~= nil then
		return self:ResultadoActividadAula(player, pcId, extra)
	end
	local id = extra.CuestionarioId
	local cuestionario = Catalogs.Cuestionario(id)
	local correctas = cuestionario and Catalogs.CuestionariosRespuestas and Catalogs.CuestionariosRespuestas[id]
	if not cuestionario or typeof(correctas) ~= "table" then
		self:Rechazo(player, "cuestionario_invalido", tostring(id), true)
		return nil, "Ese cuestionario no existe."
	end
	local respuestas = extra.Respuestas
	if typeof(respuestas) ~= "table" then
		return nil, "Faltan las respuestas."
	end
	local preguntas = cuestionario.Preguntas
	local limpias = {}
	local contestadas = 0
	for clave, valor in pairs(respuestas) do
		local indice = enteroEn(clave, 1, #preguntas)
		if indice == nil then
			self:Rechazo(player, "respuestas_formato", tostring(clave), true)
			return nil, "Las respuestas tienen un formato no válido."
		end
		local opcion = enteroEn(valor, 1, #preguntas[indice].Opciones)
		if opcion == nil then
			self:Rechazo(player, "respuesta_fuera_de_rango", id .. "#" .. tostring(indice), true)
			return nil, "Respuesta no válida en la pregunta " .. tostring(indice) .. "."
		end
		if limpias[indice] == nil then
			contestadas = contestadas + 1
		end
		limpias[indice] = opcion
	end
	if contestadas < #preguntas then
		return nil, string.format("Responde todas las preguntas antes de enviar (%d de %d).", contestadas, #preguntas)
	end

	local entregas = self:EntregasDe(player)
	local previa = entregas[id]
	if previa then
		self:Rechazo(player, "cuestionario_repetido", id, false)
		local copia = copiarTabla(previa)
		copia.YaEntregado = true
		return copia
	end

	local aciertos, total, detalle = Catalogs.CorregirCuestionario(id, limpias)
	local fraccion = 0
	if total > 0 then
		fraccion = aciertos / total
	end
	local aprobado = fraccion >= self.UmbralParticipacion
	local recompensa, saldo, motivoSinRecompensa = 0, nil, nil
	if aprobado then
		local monto = tonumber(RECOMPENSAS.Participacion) or 3
		local Economy = self:Servicio("EconomyService")
		local okE, acreditado, nuevoSaldo = invocar(Economy, "Acreditar", player, monto, "Participacion", "Cuestionario " .. id .. " · " .. pcId)
		if okE and acreditado == true then
			recompensa = monto
			saldo = numeroFinito(nuevoSaldo)
		elseif okE and acreditado == false then
			motivoSinRecompensa = tostring(nuevoSaldo or "")
			if motivoSinRecompensa == "limite_diario" then
				motivoSinRecompensa = "Alcanzaste el límite diario de monedas."
			else
				motivoSinRecompensa = "No se pudo acreditar la recompensa."
			end
		else
			motivoSinRecompensa = "La economía escolar no está disponible."
		end
	end
	local resultado = {
		CuestionarioId = id,
		Titulo = cuestionario.Titulo,
		Aciertos = aciertos,
		Total = total,
		Porcentaje = math.floor(fraccion * 100 + 0.5),
		Detalle = detalle,
		Aprobado = aprobado,
		Recompensa = recompensa,
		Saldo = saldo,
		SinRecompensa = motivoSinRecompensa,
		T = os.time(),
	}
	entregas[id] = resultado
	self.Estadisticas.Cuestionarios = self.Estadisticas.Cuestionarios + 1
	self:SumarProgreso(player, "RespuestasCorrectas", aciertos)
	self:Auditar("Clase", player, "CuestionarioPC", string.format("%s %d/%d (+%d) en %s", id, aciertos, total, recompensa, pcId))
	return copiarTabla(resultado)
end

-- Respuesta a la actividad abierta por el docente: pasa por RemoteService:Procesar("RequestClassAction") para
-- respetar el contrato, los límites y las reglas de ClassroomService (presencia, una respuesta, filtrado).
function PCService:ResultadoActividadAula(player, pcId, extra)
	local actividadId = extra.ActividadId
	if typeof(actividadId) ~= "string" or actividadId == "" or #actividadId > 48 then
		self:Rechazo(player, "actividad_invalida", tostring(actividadId), true)
		return nil, "Actividad no válida."
	end
	local datosClase = { ActividadId = actividadId }
	if typeof(extra.Respuesta) == "string" then
		local texto = Format.Recortar(extra.Respuesta)
		local largo = utf8.len(texto)
		if largo == nil or largo == 0 then
			return nil, "Escribe tu respuesta."
		end
		if largo > self.MaxRespuestaAula then
			return nil, "La respuesta supera los " .. tostring(self.MaxRespuestaAula) .. " caracteres."
		end
		datosClase.Respuesta = texto
	else
		local indice = enteroEn(extra.Respuesta, 1, 20) or enteroEn(extra.Indice, 1, 20)
		if indice == nil then
			return nil, "Elige una opción antes de enviar."
		end
		datosClase.Indice = indice
	end
	local salon = nil
	local okS, sesion = invocar(self:Servicio("ClassroomService"), "SesionDeJugador", player)
	if okS and typeof(sesion) == "table" and typeof(sesion.RoomId) == "string" then
		salon = sesion.RoomId
	end
	if not salon and typeof(extra.Salon) == "string" and extra.Salon ~= "" and #extra.Salon <= 16 then
		salon = extra.Salon
	end
	if not salon then
		return nil, "No hay una clase activa para enviar la respuesta."
	end
	local okP, respuesta = invocar(self:Servicio("RemoteService"), "Procesar", "RequestClassAction", player, {
		Accion = "Responder", Salon = salon, Datos = datosClase,
	})
	if not okP or typeof(respuesta) ~= "table" then
		return nil, "La clase no respondió; inténtalo de nuevo."
	end
	if respuesta.ok ~= true then
		return nil, tostring(respuesta.error or "No se pudo registrar la respuesta.")
	end
	return {
		Aula = true,
		ActividadId = actividadId,
		Salon = salon,
		Enviado = true,
		Mensaje = "Respuesta enviada a tu docente. El resultado es privado y llegará cuando cierre la actividad.",
		Clase = copiaSegura(respuesta.datos),
	}
end

-- Simulador: recalcula con las fórmulas de Catalogs.Simulador y compara cada salida con tolerancia del 2 %.
function PCService:ResultadoSimulador(player, pcId, extra)
	local Simulador = Catalogs.Simulador
	local idExperimento = extra.Experimento
	local experimento = typeof(idExperimento) == "string" and Simulador and Simulador.Experimentos[idExperimento] or nil
	if not experimento then
		self:Rechazo(player, "experimento_invalido", tostring(idExperimento), true)
		return nil, "Experimento desconocido."
	end
	local entradas = extra.Entradas
	if typeof(entradas) ~= "table" then
		return nil, "Faltan los datos de entrada."
	end
	local limpias = {}
	for _, def in ipairs(experimento.Entradas) do
		local valor = numeroFinito(entradas[def.Clave])
		if valor == nil then
			return nil, "Falta el valor de «" .. def.Nombre .. "»."
		end
		if valor < def.Min or valor > def.Max then
			self:Rechazo(player, "entrada_fuera_de_rango", idExperimento .. "." .. def.Clave, false)
			return nil, string.format("«%s» debe estar entre %s y %s.", def.Nombre, Format.Decimal(def.Min, 1), Format.Decimal(def.Max, 1))
		end
		limpias[def.Clave] = valor
	end
	local salidas = extra.Salidas
	if typeof(salidas) ~= "table" then
		return nil, "Faltan tus resultados."
	end
	local calculo, errCalculo = Simulador.Calcular(idExperimento, limpias)
	if not calculo then
		return nil, tostring(errCalculo or "No se pudo calcular el experimento.")
	end
	local correcto = true
	local revision = {}
	for _, def in ipairs(experimento.Salidas) do
		local esperado = numeroFinito(calculo.Salidas[def.Clave])
		local enviado = numeroFinito(salidas[def.Clave])
		local acierto = false
		if esperado ~= nil and enviado ~= nil then
			local tolerancia = math.max(math.abs(esperado) * self.ToleranciaSimulador, 0.01)
			acierto = math.abs(enviado - esperado) <= tolerancia
		end
		revision[def.Clave] = { Enviado = enviado, Esperado = esperado, Correcto = acierto }
		if not acierto then
			correcto = false
		end
	end
	self.Estadisticas.Simulaciones = self.Estadisticas.Simulaciones + 1
	return {
		Experimento = idExperimento,
		Correcto = correcto,
		Revision = revision,
		Esperado = calculo.Salidas,
		Entradas = limpias,
		ToleranciaPorcentaje = math.floor(self.ToleranciaSimulador * 100 + 0.5),
	}
end

-- Programación: ejecuta el intérprete determinista de Catalogs.Programacion en el servidor (8×8, máx. 200 pasos).
function PCService:ResultadoProgramacion(player, pcId, extra)
	local Programacion = Catalogs.Programacion
	if typeof(Programacion) ~= "table" or typeof(Programacion.Ejecutar) ~= "function" then
		return nil, "La programación no está disponible."
	end
	local reto = Programacion.Reto(extra.RetoId)
	if not reto then
		self:Rechazo(player, "reto_invalido", tostring(extra.RetoId), true)
		return nil, "Reto desconocido."
	end
	local crudas = {}
	local programa = extra.Programa
	if typeof(programa) == "string" then
		local sinRetornos = string.gsub(programa, "\r", "")
		for linea in string.gmatch(sinRetornos .. "\n", "([^\n]*)\n") do
			table.insert(crudas, linea)
		end
	elseif typeof(programa) == "table" then
		for _, linea in ipairs(programa) do
			if typeof(linea) ~= "string" then
				return nil, "El programa no es válido."
			end
			table.insert(crudas, linea)
		end
	else
		return nil, "Escribe un programa antes de ejecutarlo."
	end
	while #crudas > 0 and Format.Recortar(crudas[#crudas]) == "" do
		table.remove(crudas)
	end
	if #crudas == 0 then
		return nil, "El programa está vacío."
	end
	local maxLineas = Programacion.MaxLineas or 40
	if #crudas > maxLineas then
		return nil, string.format("El programa tiene %d líneas (máximo %d).", #crudas, maxLineas)
	end
	local maxCaracteres = Programacion.MaxCaracteresLinea or 32
	local lineas = {}
	for i, linea in ipairs(crudas) do
		local limpia = Format.Recortar(linea)
		if #limpia > maxCaracteres then
			return nil, string.format("La línea %d es demasiado larga (máximo %d caracteres).", i, maxCaracteres)
		end
		table.insert(lineas, limpia)
	end

	local resultado = {
		RetoId = reto.Id,
		Nombre = reto.Nombre,
		Inicio = reto.Inicio,
		Meta = reto.Meta,
		MaxPasos = Programacion.MaxPasos,
		Lineas = #lineas,
		Exito = false,
		Pasos = 0,
		Traza = {},
		Posicion = { X = reto.Inicio.X, Y = reto.Inicio.Y, Dir = reto.Inicio.Dir },
	}
	local okAnidamiento, errAnidamiento = comprobarAnidamiento(lineas, self.MaxAnidamiento)
	if not okAnidamiento then
		resultado.Error = errAnidamiento
		return resultado
	end
	local okEjecutar, ejecucion = pcall(Programacion.Ejecutar, reto, lineas)
	if not okEjecutar or typeof(ejecucion) ~= "table" then
		warn(PREFIJO .. " Error del intérprete: " .. tostring(ejecucion))
		return nil, "No se pudo ejecutar el programa."
	end
	resultado.Exito = ejecucion.Exito == true
	resultado.Pasos = numeroFinito(ejecucion.Pasos) or 0
	resultado.Traza = typeof(ejecucion.Traza) == "table" and ejecucion.Traza or {}
	if typeof(ejecucion.Posicion) == "table" then
		resultado.Posicion = ejecucion.Posicion
	end
	resultado.Error = ejecucion.Error
	self.Estadisticas.Programas = self.Estadisticas.Programas + 1
	return resultado
end

function PCService:SumarProgreso(player, clave, cantidad)
	if not cantidad or cantidad <= 0 then
		return
	end
	local DataService = self:Servicio("DataService")
	local okPerfil, perfil = invocar(DataService, "Obtener", player)
	if okPerfil and typeof(perfil) == "table" and typeof(perfil.Progreso) == "table" then
		perfil.Progreso[clave] = (numeroFinito(perfil.Progreso[clave]) or 0) + cantidad
		invocar(DataService, "Marcar", player)
	end
end

---------------------------------------------------------------------------------------------------
-- Control docente: bloqueo y proyección de la sala
---------------------------------------------------------------------------------------------------

-- Sala que el docente puede controlar a partir de un PcId, un id de sala o su posición. Devuelve roomId | nil, mensaje.
function PCService:SalaDeDocente(player, pcIdOSala)
	local okT, tiene = invocar(self:Servicio("RoleService"), "Tiene", player, "pc.bloquear")
	if not okT or tiene ~= true then
		self:Rechazo(player, "permiso", "pc.bloquear", true)
		return nil, "No tienes permiso para controlar la sala."
	end
	local roomId = nil
	local info = self.Registros[pcIdOSala]
	if info then
		roomId = info.RoomId
	elseif typeof(pcIdOSala) == "string" and self.SalasBloqueables[pcIdOSala] then
		roomId = pcIdOSala
	else
		local posicion = posicionDe(player)
		if posicion then
			local zonaId = Zones.IdDe(posicion)
			if zonaId and self.SalasBloqueables[zonaId] then
				roomId = zonaId
			end
		end
	end
	if not roomId or not self.SalasBloqueables[roomId] then
		self:Rechazo(player, "sala_invalida", tostring(pcIdOSala), false)
		return nil, "Solo se pueden controlar las salas de informática y robótica."
	end
	local okD, esDocente = invocar(self:Servicio("ClassroomService"), "EsDocenteDe", player, roomId)
	if okD and esDocente == true then
		return roomId, nil
	end
	local posicion = posicionDe(player)
	if posicion and Zones.Contiene(roomId, posicion) then
		return roomId, nil
	end
	self:Rechazo(player, "fuera_de_sala", roomId, false)
	return nil, "Debes estar en la sala o dirigir su clase para controlarla."
end

function PCService:AccionBloqueo(player, pcIdOSala, bloquear)
	local roomId, err = self:SalaDeDocente(player, pcIdOSala)
	if not roomId then
		return fallo(err)
	end
	local ok, mensaje = self:BloquearSala(roomId, bloquear, player)
	if not ok then
		return fallo(mensaje)
	end
	return exito({ RoomId = roomId, Bloqueado = bloquear, Mensaje = mensaje })
end

function PCService:AccionProyectar(player, pcIdOSala, extra)
	local roomId, err = self:SalaDeDocente(player, pcIdOSala)
	if not roomId then
		return fallo(err)
	end
	local texto = extra.Texto
	if texto == nil then
		texto = ""
	end
	if typeof(texto) ~= "string" then
		return fallo("El texto no es válido.")
	end
	local ok, resultado = self:Proyectar(roomId, texto, player)
	if not ok then
		return fallo(resultado)
	end
	local datos = { RoomId = roomId }
	if resultado ~= "" then
		datos.Texto = resultado
	end
	return exito(datos)
end

-- Bloquea o desbloquea todos los PCs de la sala. autor (Player) y motivo son opcionales. Devuelve ok, mensaje.
function PCService:BloquearSala(roomId, bloquear, autor, motivo)
	if typeof(roomId) ~= "string" or not self.SalasBloqueables[roomId] then
		return false, "Solo se pueden bloquear las salas de informática y robótica."
	end
	bloquear = bloquear == true
	local sala = self:Sala(roomId)
	if sala.Bloqueado == bloquear then
		if bloquear then
			return true, "La sala ya estaba bloqueada."
		end
		return true, "La sala ya estaba desbloqueada."
	end
	sala.Bloqueado = bloquear
	if bloquear then
		sala.BloqueadoPor = esJugador(autor) and autor.UserId or nil
		sala.BloqueadoPorNombre = nombreVisible(autor)
	else
		sala.BloqueadoPor = nil
		sala.BloqueadoPorNombre = nil
	end
	for _, pcId in ipairs(self.PorSala[roomId] or {}) do
		local estado = self.Estados[pcId]
		if estado then
			estado.Bloqueado = bloquear
			self:ActualizarPantalla(pcId)
			self:ActualizarPrompt(pcId)
			if estado.OcupanteUserId ~= nil then
				local ocupante = Players:GetPlayerByUserId(estado.OcupanteUserId)
				if ocupante then
					self:EnviarEstado(ocupante, pcId)
				end
			end
			self:EmitirCambio(pcId)
		end
	end
	local por = nil
	if esJugador(autor) then
		por = nombreVisible(autor)
	end
	self:EnviarASala(roomId, { Sub = "Bloqueo", RoomId = roomId, Bloqueado = bloquear, Por = por, Motivo = motivo }, autor)
	local detalle = roomId
	if motivo then
		detalle = roomId .. " · " .. tostring(motivo)
	end
	if bloquear then
		self:Auditar("Clase", autor, "BloquearSalaPC", detalle)
	else
		self:Auditar("Clase", autor, "DesbloquearSalaPC", detalle)
	end
	return true, nil
end

-- Proyecta texto (≤ 300) en todas las pantallas de la sala y en el tablero (BoardService:Proyectar si existe).
-- Con autor (Player) el texto se filtra; sin autor se asume ya filtrado por el servicio que llama. "" lo quita.
-- Devuelve true, textoFinal | false, mensaje.
function PCService:Proyectar(roomId, texto, autor)
	if typeof(roomId) ~= "string" or (self.PorSala[roomId] == nil and not self.SalasBloqueables[roomId]) then
		return false, "Sala desconocida."
	end
	if typeof(texto) ~= "string" then
		return false, "El texto no es válido."
	end
	texto = Format.Recortar(texto)
	local largo = utf8.len(texto)
	if largo == nil then
		return false, "El texto contiene caracteres no válidos."
	end
	if largo > self.MaxProyeccion then
		return false, "El texto supera los " .. tostring(self.MaxProyeccion) .. " caracteres."
	end
	local final = texto
	if final ~= "" and esJugador(autor) then
		local filtrado, errFiltro = self:Filtrar(texto, autor)
		if not filtrado then
			return false, errFiltro
		end
		final = filtrado
	end
	local sala = self:Sala(roomId)
	if final == "" then
		sala.Proyeccion = nil
	else
		sala.Proyeccion = {
			Texto = final,
			Autor = nombreVisible(autor),
			AutorUserId = esJugador(autor) and autor.UserId or nil,
			T = os.time(),
		}
	end
	for _, pcId in ipairs(self.PorSala[roomId] or {}) do
		local estado = self.Estados[pcId]
		if estado then
			estado.Proyeccion = sala.Proyeccion and sala.Proyeccion.Texto or nil
			self:ActualizarPantalla(pcId)
		end
	end
	-- Tablero del aula: texto ya filtrado (sin player para no filtrarlo dos veces). Guardia anti-reentrada.
	if final ~= "" and not self._proyectandoTablero then
		local Board = self:Servicio("BoardService")
		if Board then
			self._proyectandoTablero = true
			invocar(Board, "Proyectar", roomId, final)
			self._proyectandoTablero = false
		end
	end
	local evento = { Sub = "Proyeccion", RoomId = roomId }
	if sala.Proyeccion then
		evento.Texto = sala.Proyeccion.Texto
		evento.Autor = sala.Proyeccion.Autor
		evento.T = sala.Proyeccion.T
	end
	self:EnviarASala(roomId, evento, autor)
	if final == "" then
		self:Auditar("Clase", autor, "ProyeccionPC", roomId .. " · (retirada)")
	else
		self:Auditar("Clase", autor, "ProyeccionPC", roomId .. " · " .. Format.Truncar(final, 80))
	end
	return true, final
end

-- Filtrado para difusión (TextService). Si falla, el texto no se muestra a terceros.
function PCService:Filtrar(texto, player)
	local okFiltro, resultado = pcall(function()
		return TextService:FilterStringAsync(texto, player.UserId, Enum.TextFilterContext.PublicChat)
	end)
	if not okFiltro or resultado == nil then
		return nil, "No se pudo filtrar el texto; inténtalo de nuevo."
	end
	local okTexto, filtrado = pcall(function()
		return resultado:GetNonChatStringForBroadcastAsync()
	end)
	if not okTexto or typeof(filtrado) ~= "string" then
		return nil, "No se pudo filtrar el texto; inténtalo de nuevo."
	end
	return filtrado, nil
end

---------------------------------------------------------------------------------------------------
-- Eventos de jugadores y jornada
---------------------------------------------------------------------------------------------------
function PCService:AlSalirJugador(player)
	local userId = player.UserId
	local pcId = self.PcDeJugador[userId]
	if pcId then
		self:Liberar(pcId, nil, true, userId)
	end
	self.UltimoPrompt[userId] = nil
	self.UltimoProcesador[userId] = nil
	self:SoltarControlDocente(player, "El docente salió del servidor.")
end

-- Si el docente pierde pc.bloquear (cambio de cargo) se retiran su bloqueo y su proyección.
function PCService:AlCambiarCargo(player)
	if not esJugador(player) then
		return
	end
	local okT, tiene = invocar(self:Servicio("RoleService"), "Tiene", player, "pc.bloquear")
	if okT and tiene == true then
		return
	end
	self:SoltarControlDocente(player, "El docente cambió de cargo.")
end

function PCService:SoltarControlDocente(player, motivo)
	local userId = player.UserId
	for roomId, sala in pairs(self.Salas) do
		if sala.Bloqueado and sala.BloqueadoPor == userId then
			pcall(self.BloquearSala, self, roomId, false, nil, motivo)
		end
		if sala.Proyeccion and sala.Proyeccion.AutorUserId == userId then
			pcall(self.Proyectar, self, roomId, "", nil)
		end
	end
end

-- Fin de jornada: nueva clave de entregas, salas desbloqueadas y proyecciones retiradas (estado temporal).
function PCService:AlTerminarJornada()
	self.JornadaLocal = self.JornadaLocal + 1
	self.Entregas = { Clave = "", PorJugador = {} }
	for roomId, sala in pairs(self.Salas) do
		if sala.Bloqueado then
			pcall(self.BloquearSala, self, roomId, false, nil, "Fin de la jornada.")
		end
		if sala.Proyeccion then
			pcall(self.Proyectar, self, roomId, "", nil)
		end
	end
end

---------------------------------------------------------------------------------------------------
-- API pública para otros servicios
---------------------------------------------------------------------------------------------------

-- Estado público de un PC (o nil).
function PCService:Estado(pcId)
	return self:EstadoPublico(pcId)
end

-- PC que ocupa el jugador (o nil).
function PCService:PCDeJugador(player)
	if not esJugador(player) then
		return nil
	end
	return self.PcDeJugador[player.UserId]
end

-- Jugadores que ocupan PCs de la sala.
function PCService:Ocupantes(roomId)
	local lista = {}
	for _, pcId in ipairs(self.PorSala[roomId] or {}) do
		local estado = self.Estados[pcId]
		if estado and estado.OcupanteUserId ~= nil then
			local player = Players:GetPlayerByUserId(estado.OcupanteUserId)
			if player then
				table.insert(lista, player)
			end
		end
	end
	return lista
end

-- { RoomId, Bloqueado, BloqueadoPor, Proyeccion, PCs = { estadoPublico... } } de una sala.
function PCService:EstadoSala(roomId)
	local sala = self.Salas[roomId]
	local pcs = {}
	for _, pcId in ipairs(self.PorSala[roomId] or {}) do
		table.insert(pcs, self:EstadoPublico(pcId))
	end
	return {
		RoomId = roomId,
		Bloqueado = sala ~= nil and sala.Bloqueado == true,
		BloqueadoPor = sala and sala.BloqueadoPorNombre or nil,
		Proyeccion = sala and sala.Proyeccion and sala.Proyeccion.Texto or nil,
		PCs = pcs,
	}
end

-- Parte "PC" del StateSnapshot del jugador: equipo ocupado (si hay) y estado de su sala.
function PCService:SnapshotJugador(player)
	local pcId = self:PCDeJugador(player)
	if not pcId then
		return nil
	end
	return { PcId = pcId, Estado = self:EstadoPublico(pcId) }
end

-- Resumen global para paneles de dirección y métricas.
function PCService:Snapshot()
	local pcs, ocupados, encendidos = {}, 0, 0
	for _, pcId in ipairs(self.Orden) do
		local publico = self:EstadoPublico(pcId)
		if publico then
			table.insert(pcs, publico)
			if publico.Ocupante ~= nil then
				ocupados = ocupados + 1
			end
			if publico.Encendido then
				encendidos = encendidos + 1
			end
		end
	end
	local salas = {}
	for roomId, sala in pairs(self.Salas) do
		salas[roomId] = {
			Bloqueado = sala.Bloqueado == true,
			BloqueadoPor = sala.BloqueadoPorNombre,
			Proyeccion = sala.Proyeccion and sala.Proyeccion.Texto or nil,
		}
	end
	return {
		Total = #pcs,
		Ocupados = ocupados,
		Encendidos = encendidos,
		PCs = pcs,
		Salas = salas,
		Estadisticas = copiarTabla(self.Estadisticas),
	}
end

return PCService
