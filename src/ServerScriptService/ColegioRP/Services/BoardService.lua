--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.BoardService
	Tipo: ModuleScript
	Tablero de cada aula (docs/ARQUITECTURA.md §6). Mantiene un BoardState por RoomId
	{ Texto, Trazos, Plantilla, ImagenId, Autor, Actualizado, Proyeccion } con autoridad total del servidor y:
	  - atiende BoardAction: Escribir (filtrado con TextService), Limpiar, Plantilla (índice de Catalogs.Plantillas),
	    Trazo (puntos normalizados 0..1; acumula hasta Config.Tablero.MaxTrazos y descarta el más antiguo) e
	    Imagen (ImagenId numérico, solo docente);
	  - autoriza al docente de la sesión (ClassroomService:EsDocenteDe) o al estudiante con turno vigente
	    (ConcederTurno / RevocarTurno con expiración; al expirar avisa al jugador y al aula);
	  - replica solo a la zona del aula (EventoCliente "Tablero") y envía el estado completo a quien entra en el
	    aula (ciclo de 2 s, solo si su copia está desactualizada);
	  - dibuja el estado en la SurfaceGui del tablero físico creado por MapService (TextLabel, Frames por trazo
	    -1 Frame cada 2 puntos, máx. 600 por tablero- e ImageLabel), actualizando solo cuando cambia.

	Formato de red de un trazo: { Id, Color (1..4), Grosor (1..4), Autor (userId), P = "<puntos>" } donde cada
	punto ocupa 4 caracteres: x e y cuantizados a 0..4095 y escritos en base 64 con el alfabeto ALFABETO
	(2 caracteres por coordenada). Así un tablero lleno (300 trazos x 60 puntos) cabe en ~72 KB.
	Estilo de un trazo recibido por BoardAction: la componente Z del primer punto codifica
	Color * 0.1 + Grosor * 0.01 (p. ej. Z = 0.23 -> color 2, grosor 3); x e y van en 0..1 (izquierda->derecha,
	arriba->abajo).

	Eventos "Tablero" (todos con Sub y RoomId):
	  Estado  -> snapshot completo (ver BoardService:Estado).
	  Texto   -> { Version, Texto, Plantilla, PlantillaTexto, ImagenId, Proyeccion, Autor, AutorNombre, Actualizado }
	  Trazo   -> { Version, Trazo = <trazo de red>, Descartados = { ids }, Autor, AutorNombre, Actualizado }
	  Limpiar -> { Version, Todo = true, Completo = bool (también borra la proyección), Motivo }
	  Turno   -> { Activo, UserId, Nombre, Expira (workspace:GetServerTimeNow()), Segundos, Motivo, Anterior,
	               DocenteUserId, RequiereSesion }
]]

local Players = game:GetService("Players")
local TextService = game:GetService("TextService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Catalogs = require(Shared:WaitForChild("Catalogs"))
local Util = Shared:WaitForChild("Util")
local Zones = require(Util:WaitForChild("Zones"))
local Signal = require(Util:WaitForChild("Signal"))
local Maid = require(Util:WaitForChild("Maid"))

local BoardService = {}
BoardService.Nombre = "BoardService"

local PREFIJO = "[ColegioRP][BoardService]"
local TABLERO = Config.Tablero or {}

---------------------------------------------------------------------------------------------------
-- Parámetros (ajustables sin tocar la lógica)
---------------------------------------------------------------------------------------------------
BoardService.MaxCaracteres = tonumber(TABLERO.MaxCaracteres) or 400 -- Texto máximo del tablero.
BoardService.MaxTrazos = tonumber(TABLERO.MaxTrazos) or 300 -- Trazos guardados por tablero (FIFO).
BoardService.MaxTrazoPuntos = tonumber(TABLERO.MaxTrazoPuntos) or 60 -- Puntos por trazo.
BoardService.TurnoSeg = tonumber(TABLERO.TurnoSeg) or 90 -- Duración por defecto del turno de un invitado.
BoardService.TurnoMinSeg = 10 -- Turno mínimo aceptado por ConcederTurno.
BoardService.TurnoMaxSeg = 600 -- Turno máximo aceptado por ConcederTurno.
BoardService.DistanciaMax = (Config.Distancias and tonumber(Config.Distancias.Tablero)) or 30 -- Studs al tablero si se está fuera de la zona del aula.
BoardService.ToleranciaDistancia = 2 -- Margen por latencia y tamaño del personaje.
BoardService.IntervaloCicloSeg = 2 -- Ciclo de entrada en aulas, docente de la sesión y turnos vencidos.
BoardService.MaxLineas = 12 -- Saltos de línea máximos del texto del tablero.
BoardService.MaxFramesTablero = 600 -- Frames de trazos por tablero físico.
BoardService.MaxFramesGlobal = 6000 -- Frames de trazos sumando todos los tableros físicos.
BoardService.PuntosPorFrame = 2 -- Un Frame (segmento) por cada 2 puntos del trazo.
BoardService.ToleranciaPunto = 0.002 -- Margen aceptado fuera de 0..1 antes de rechazar un punto.
BoardService.PermitirDocenteSinSesion = false -- true: un cargo con tablero.escribir puede usar el tablero de un aula sin sesión abierta.
BoardService.AspectoPorDefecto = 10 / 6 -- Ancho/alto si el aula no tiene tablero físico.
-- Espera mínima (s) entre acciones del mismo tipo por jugador (además del límite de RemoteService).
BoardService.EsperaAccion = { Escribir = 1, Plantilla = 0.5, Imagen = 2, Limpiar = 1, Trazo = 0.08 }

-- Paleta de tiza (índice = Color del trazo). BoardController usa la misma.
BoardService.ColoresTiza = {
	Color3.fromRGB(240, 240, 232), -- 1 Blanco tiza
	Color3.fromRGB(246, 206, 70), -- 2 Amarillo
	Color3.fromRGB(240, 110, 110), -- 3 Rojo claro
	Color3.fromRGB(120, 180, 250), -- 4 Azul claro
}
-- Grosor (índice = Grosor del trazo) como fracción del alto del tablero. BoardController usa los mismos.
BoardService.Grosores = { 0.008, 0.014, 0.022, 0.032 }
BoardService.ColorFondo = Color3.fromRGB(30, 56, 44) -- Verde pizarra (solo visible cuando hay contenido).
BoardService.TransparenciaFondo = 0.04
BoardService.ColorTexto = Color3.fromRGB(240, 240, 232)
BoardService.ColorPlantilla = Color3.fromRGB(246, 206, 70)

-- Motivos de rechazo que sugieren una petición manipulada (se cuentan en MetricsService).
local MOTIVOS_SOSPECHOSOS = { aula_desconocida = true, puntos_invalidos = true, accion_desconocida = true }

-- Mensajes al jugador cuando termina su turno (por motivo).
local MENSAJES_FIN_TURNO = {
	Expirado = "Tu turno en el tablero de %s terminó.",
	Revocado = "El docente retiró tu turno en el tablero de %s.",
	Reemplazado = "El docente dio el turno del tablero de %s a otra persona.",
	SesionCerrada = "La sesión de clase de %s terminó; tu turno en el tablero se cerró.",
	Limpieza = "El tablero de %s se reinició; tu turno terminó.",
	CambioCargo = "Cambiaste de cargo; tu turno en el tablero de %s terminó.",
	OtraAula = "Recibiste turno en otro tablero; el de %s se cerró.",
}

---------------------------------------------------------------------------------------------------
-- Codificación de puntos (base 64, 2 caracteres por coordenada cuantizada a 0..4095)
---------------------------------------------------------------------------------------------------
local ALFABETO = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local CUANTOS = 4095
local CARACTERES = {}
for i = 1, 64 do
	CARACTERES[i] = string.sub(ALFABETO, i, i)
end
BoardService.Alfabeto = ALFABETO
BoardService.Cuantos = CUANTOS

local function clamp(valor, minimo, maximo)
	if valor < minimo then
		return minimo
	end
	if valor > maximo then
		return maximo
	end
	return valor
end

local function cuantizar(valor)
	return clamp(math.floor(valor * CUANTOS + 0.5), 0, CUANTOS)
end

-- puntos = { {x, y}, ... } ya cuantizados -> cadena de 4 caracteres por punto.
local function codificarPuntos(puntos)
	local partes = table.create(#puntos * 4)
	for _, punto in ipairs(puntos) do
		local qx = cuantizar(punto[1])
		local qy = cuantizar(punto[2])
		table.insert(partes, CARACTERES[math.floor(qx / 64) + 1])
		table.insert(partes, CARACTERES[(qx % 64) + 1])
		table.insert(partes, CARACTERES[math.floor(qy / 64) + 1])
		table.insert(partes, CARACTERES[(qy % 64) + 1])
	end
	return table.concat(partes)
end

-- Z del primer punto -> color (1..4) y grosor (1..4). Valores fuera de rango usan blanco / medio.
local function decodificarEstilo(z, colores, grosores)
	local codigo = 0
	if typeof(z) == "number" and z == z then
		codigo = math.floor(clamp(z, 0, 1) * 100 + 0.5)
	end
	local color = math.floor(codigo / 10)
	local grosor = codigo % 10
	if color < 1 or color > #colores then
		color = 1
	end
	if grosor < 1 or grosor > #grosores then
		grosor = 2
	end
	return color, grosor
end

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function esJugador(player)
	return typeof(player) == "Instance" and player:IsA("Player")
end

local function posicionDe(player)
	local personaje = player.Character
	if not personaje then
		return nil
	end
	local raiz = personaje:FindFirstChild("HumanoidRootPart")
	if raiz and raiz:IsA("BasePart") then
		return raiz.Position
	end
	return nil
end

local function ahoraServidor()
	local ok, t = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if ok and typeof(t) == "number" then
		return t
	end
	return os.time()
end

local function nombreJugador(player)
	if not esJugador(player) then
		return ""
	end
	local nombre = player.DisplayName
	if typeof(nombre) ~= "string" or nombre == "" then
		nombre = player.Name
	end
	return nombre
end

local function nombreAula(roomId)
	local zona = Zones.Zona(roomId)
	if zona and typeof(zona.Nombre) == "string" and zona.Nombre ~= "" then
		return zona.Nombre
	end
	return tostring(roomId)
end

local function fuenteSegura(nombre, respaldo)
	local ok, fuente = pcall(function()
		return Enum.Font[nombre]
	end)
	if ok and fuente ~= nil then
		return fuente
	end
	return respaldo
end

local FUENTE_TIZA = fuenteSegura("PatrickHand", Enum.Font.Gotham)
local FUENTE_TITULO = fuenteSegura("GothamBold", Enum.Font.SourceSansBold)
local FUENTE_TEXTO = fuenteSegura("Gotham", Enum.Font.SourceSans)

-- Conecta a una señal Lua (Signal) o de Roblox; devuelve la conexión o nil.
local function conectar(senal, fn)
	if typeof(senal) == "RBXScriptSignal" then
		return senal:Connect(fn)
	end
	if typeof(senal) == "table" and typeof(senal.Connect) == "function" then
		local ok, conexion = pcall(senal.Connect, senal, fn)
		if ok then
			return conexion
		end
	end
	return nil
end

-- Caracteres invisibles o de control de dirección que no se aceptan en el tablero.
local function esInvisible(codigo)
	return (codigo >= 0x200B and codigo <= 0x200F)
		or (codigo >= 0x202A and codigo <= 0x202E)
		or (codigo >= 0x2060 and codigo <= 0x2064)
		or (codigo >= 0x2066 and codigo <= 0x2069)
		or codigo == 0xFEFF or codigo == 0x00AD
end

-- Normaliza el texto: quita controles e invisibles, limita caracteres y líneas, recorta espacios.
local function sanearTexto(texto, maxCaracteres, maxLineas)
	if typeof(texto) ~= "string" or utf8.len(texto) == nil then
		return ""
	end
	local partes = {}
	local lineas = 1
	local cuenta = 0
	local ok = pcall(function()
		for _, codigo in utf8.codes(texto) do
			if cuenta >= maxCaracteres then
				break
			end
			if codigo == 10 then
				if lineas < maxLineas then
					lineas = lineas + 1
					table.insert(partes, "\n")
					cuenta = cuenta + 1
				end
			elseif codigo == 9 then
				table.insert(partes, " ")
				cuenta = cuenta + 1
			elseif codigo >= 32 and codigo ~= 127 and not (codigo >= 128 and codigo < 160) and not esInvisible(codigo) then
				table.insert(partes, utf8.char(codigo))
				cuenta = cuenta + 1
			end
		end
	end)
	if not ok then
		return ""
	end
	local resultado = table.concat(partes)
	resultado = string.gsub(resultado, " +\n", "\n")
	resultado = string.match(resultado, "^%s*(.-)%s*$") or ""
	return resultado
end

local function estadoVacio(estado)
	return estado == nil or (estado.Texto == "" and estado.Plantilla == 0 and #estado.Trazos == 0
		and estado.ImagenId == 0 and estado.Proyeccion == "")
end

local function framesNecesarios(numPuntos, puntosPorFrame)
	if numPuntos <= 1 then
		return 1
	end
	return math.ceil((numPuntos - 1) / puntosPorFrame)
end

-- Trazo en formato de red (se calcula una vez por trazo).
local function trazoRed(trazo)
	if trazo.Red == nil then
		trazo.Red = { Id = trazo.Id, Color = trazo.Color, Grosor = trazo.Grosor, Autor = trazo.Autor, P = trazo.P }
	end
	return trazo.Red
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function BoardService:Init(registro)
	self.registro = registro
	self.Estados = {} -- roomId -> BoardState
	self.Turnos = {} -- roomId -> { UserId, Nombre, Expira (os.clock), ExpiraServidor, Segundos, Token, Otorgante }
	self.Vistas = {} -- roomId -> vista del tablero físico
	self.Enviado = {} -- userId -> { RoomId, Version } (última copia completa/sincronizada del cliente)
	self.UltimaAccion = {} -- userId -> { accion -> os.clock() }
	self.DocenteConocido = {} -- roomId -> userId | 0 (detección de apertura/cierre de sesión)
	self.CacheRed = {} -- roomId -> { Version, Trazos }
	self.FramesGlobal = 0
	self.TokenTurno = 0
	self.SiguienteTrazo = 0
	self.Activo = false
	self.CicloPendiente = false
	self.Maid = Maid.new()
	self.Cambiado = Signal.new() -- (roomId, sub) tras cada cambio de contenido
	self.TurnoCambiado = Signal.new() -- (roomId, turno | nil, motivo)
	self.Estadisticas = { Escrituras = 0, Trazos = 0, Limpiezas = 0, Imagenes = 0, Rechazos = 0, FiltrosFallidos = 0, Snapshots = 0 }
end

function BoardService:Start()
	self.Activo = true

	local RemoteService = self.registro.Get("RemoteService")
	if RemoteService and typeof(RemoteService.Registrar) == "function" then
		RemoteService:Registrar("BoardAction", function(player, datos)
			return self:ManejarAccion(player, datos)
		end)
	else
		warn(PREFIJO .. " RemoteService no disponible: BoardAction no tendrá handler.")
	end

	self.Maid:GiveTask(Players.PlayerRemoving:Connect(function(player)
		self:AlSalir(player)
	end))

	-- Fin de jornada: si ClassroomService no limpió los tableros al cerrar las sesiones, se limpian aquí.
	local SchoolDayService = self.registro.Get("SchoolDayService")
	if SchoolDayService then
		local conexion = conectar(SchoolDayService.JornadaTerminada, function()
			self:LimpiarTodos("FinJornada")
		end)
		if conexion then
			self.Maid:GiveTask(conexion)
		end
	end

	-- Reconstrucción del mapa: las SurfaceGui son nuevas, se redibuja todo.
	local MapService = self.registro.Get("MapService")
	if MapService then
		local conexion = conectar(MapService.Construido, function()
			task.defer(function()
				self:RedibujarTodo()
			end)
		end)
		if conexion then
			self.Maid:GiveTask(conexion)
		end
	end

	-- Cambio de cargo: el turno de tablero pertenece a la situación anterior.
	local RoleService = self.registro.Get("RoleService")
	if RoleService then
		local conexion = conectar(RoleService.CargoCambiado, function(player)
			if esJugador(player) then
				self:_FinTurnosDe(player.UserId, "CambioCargo")
			end
		end)
		if conexion then
			self.Maid:GiveTask(conexion)
		end
	end

	-- Ocupación de asientos: adelanta el ciclo para que quien se sienta reciba el tablero enseguida.
	local RoomService = self.registro.Get("RoomService")
	if RoomService then
		local conexion = conectar(RoomService.OcupacionCambiada, function()
			self:_ProgramarCiclo()
		end)
		if conexion then
			self.Maid:GiveTask(conexion)
		end
	end

	local hilo = task.spawn(function()
		while self.Activo do
			task.wait(self.IntervaloCicloSeg)
			if not self.Activo then
				break
			end
			local ok, err = pcall(self._Ciclo, self)
			if not ok then
				warn(PREFIJO .. " Error en el ciclo: " .. tostring(err))
			end
		end
	end)
	self.Maid:GiveTask(function()
		self.Activo = false
		if coroutine.status(hilo) == "suspended" then
			pcall(task.cancel, hilo)
		end
	end)
end

-- Detiene el ciclo y desconecta (uso de pruebas o desinstalación). El estado se conserva.
function BoardService:Detener()
	self.Activo = false
	self.Maid:DoCleaning()
end

---------------------------------------------------------------------------------------------------
-- Consultas de aula y autorización
---------------------------------------------------------------------------------------------------

-- ¿El id corresponde a un aula (construida por MapService o listada en MapaLogico.Aulas)?
function BoardService:EsAula(roomId)
	if typeof(roomId) ~= "string" or roomId == "" or #roomId > 16 then
		return false
	end
	local MapService = self.registro.Get("MapService")
	if MapService and typeof(MapService.Aula) == "function" then
		local ok, aula = pcall(MapService.Aula, MapService, roomId)
		if ok and aula ~= nil then
			return true
		end
	end
	return Zones.EsAula(roomId) == true
end

-- Registro del aula en MapService ({ Tablero, TableroGui, Zona, ... }) o nil.
function BoardService:_InfoAula(roomId)
	local MapService = self.registro.Get("MapService")
	if not MapService or typeof(MapService.Aula) ~= "function" then
		return nil
	end
	local ok, aula = pcall(MapService.Aula, MapService, roomId)
	if ok and typeof(aula) == "table" then
		return aula
	end
	return nil
end

-- Id de la zona del aula (MapaLogico usa la misma id que el aula).
function BoardService:ZonaDeAula(roomId)
	local aula = self:_InfoAula(roomId)
	if aula and typeof(aula.Zona) == "table" and typeof(aula.Zona.Id) == "string" then
		return aula.Zona.Id
	end
	return roomId
end

-- Relación ancho/alto del tablero físico (la usa el cliente para el lienzo).
function BoardService:Aspecto(roomId)
	local aula = self:_InfoAula(roomId)
	local tablero = aula and aula.Tablero
	if typeof(tablero) == "Instance" and tablero:IsA("BasePart") and tablero.Size.Y > 0 then
		return tablero.Size.X / tablero.Size.Y
	end
	return self.AspectoPorDefecto
end

-- ¿La autorización depende de una sesión de ClassroomService?
function BoardService:RequiereSesion()
	return self.registro.Get("ClassroomService") ~= nil
end

-- userId del docente de la sesión abierta en el aula, o nil.
function BoardService:DocenteDe(roomId)
	local Classroom = self.registro.Get("ClassroomService")
	if not Classroom or typeof(Classroom.SesionDe) ~= "function" then
		return nil
	end
	local ok, sesion = pcall(Classroom.SesionDe, Classroom, roomId)
	if not ok or typeof(sesion) ~= "table" then
		return nil
	end
	if sesion.State == "Cerrada" or sesion.Estado == "Cerrada" then
		return nil
	end
	return tonumber(sesion.TeacherUserId or sesion.DocenteUserId)
end

local function tienePermiso(registro, player, permiso)
	local RoleService = registro.Get("RoleService")
	if RoleService and typeof(RoleService.Tiene) == "function" then
		local ok, tiene = pcall(RoleService.Tiene, RoleService, player, permiso)
		return ok and tiene == true
	end
	return false
end

-- ¿Es el docente del aula? Con ClassroomService: docente de la sesión; sin él: permiso tablero.escribir.
function BoardService:EsDocenteDe(player, roomId)
	local Classroom = self.registro.Get("ClassroomService")
	if Classroom then
		local es = false
		if typeof(Classroom.EsDocenteDe) == "function" then
			local ok, resultado = pcall(Classroom.EsDocenteDe, Classroom, player, roomId)
			es = ok and resultado == true
		else
			local docente = self:DocenteDe(roomId)
			es = docente ~= nil and docente == player.UserId
		end
		if not es and self.PermitirDocenteSinSesion and self:DocenteDe(roomId) == nil then
			es = tienePermiso(self.registro, player, "tablero.escribir")
		end
		return es
	end
	return tienePermiso(self.registro, player, "tablero.escribir")
end

-- Rol del jugador en el tablero: "Docente" | "Invitado" | nil.
function BoardService:RolDe(player, roomId)
	if not esJugador(player) then
		return nil
	end
	if self:EsDocenteDe(player, roomId) then
		return "Docente"
	end
	local turno = self:TurnoDe(roomId)
	if turno and turno.UserId == player.UserId then
		return "Invitado"
	end
	return nil
end

-- ¿Puede escribir ahora? Devuelve bool y el rol.
function BoardService:PuedeEscribir(player, roomId)
	local rol = self:RolDe(player, roomId)
	return rol ~= nil, rol
end

-- ¿Está dentro de la zona del aula o cerca del tablero físico (sin estar dentro de otra aula)?
function BoardService:EstaCerca(player, roomId)
	local posicion = posicionDe(player)
	if not posicion then
		return false
	end
	local zonaId = self:ZonaDeAula(roomId)
	if Zones.Zona(zonaId) and Zones.Contiene(zonaId, posicion) then
		return true
	end
	local otraAula = self:AulaDePosicion(posicion)
	if otraAula ~= nil and otraAula ~= roomId and otraAula ~= zonaId then
		return false
	end
	local aula = self:_InfoAula(roomId)
	local tablero = aula and aula.Tablero
	if typeof(tablero) == "Instance" and tablero:IsA("BasePart") then
		return (tablero.Position - posicion).Magnitude <= self.DistanciaMax + self.ToleranciaDistancia
	end
	local RoomService = self.registro.Get("RoomService")
	if RoomService and typeof(RoomService.EstaEn) == "function" then
		local ok, esta = pcall(RoomService.EstaEn, RoomService, player, roomId)
		return ok and esta == true
	end
	return false
end

function BoardService:EstaSilenciado(player)
	local Moderation = self.registro.Get("ModerationService")
	if Moderation and typeof(Moderation.EstaSilenciado) == "function" then
		local ok, silenciado = pcall(Moderation.EstaSilenciado, Moderation, player)
		if ok then
			return silenciado == true
		end
	end
	return player:GetAttribute("Silenciado") == true
end

-- Aula (zona) en la que está físicamente el jugador, o nil.
function BoardService:AulaDePosicion(posicion)
	if typeof(posicion) ~= "Vector3" then
		return nil
	end
	for _, zona in ipairs(Zones.ZonasEn(posicion)) do
		if self:EsAula(zona.Id) then
			return zona.Id
		end
	end
	return nil
end

---------------------------------------------------------------------------------------------------
-- Estado
---------------------------------------------------------------------------------------------------
function BoardService:_Estado(roomId)
	local estado = self.Estados[roomId]
	if not estado then
		estado = {
			RoomId = roomId,
			Texto = "",
			TextoAutor = 0,
			Trazos = {},
			Plantilla = 0,
			ImagenId = 0,
			Autor = 0,
			AutorNombre = "",
			Actualizado = 0,
			Proyeccion = "",
			Version = 0,
		}
		self.Estados[roomId] = estado
	end
	return estado
end

function BoardService:_MarcarCambio(estado, player)
	estado.Version = estado.Version + 1
	estado.Actualizado = os.time()
	if esJugador(player) then
		estado.Autor = player.UserId
		estado.AutorNombre = nombreJugador(player)
	end
	self.CacheRed[estado.RoomId] = nil
end

function BoardService:_DatosTexto(estado)
	return {
		Sub = "Texto",
		RoomId = estado.RoomId,
		Version = estado.Version,
		Texto = estado.Texto,
		Plantilla = estado.Plantilla,
		PlantillaTexto = Catalogs.Plantillas[estado.Plantilla] or "",
		ImagenId = estado.ImagenId,
		Proyeccion = estado.Proyeccion,
		Autor = estado.Autor,
		AutorNombre = estado.AutorNombre,
		Actualizado = estado.Actualizado,
	}
end

function BoardService:_TrazosRed(roomId, estado)
	local cache = self.CacheRed[roomId]
	if cache and cache.Version == estado.Version then
		return cache.Trazos
	end
	local lista = table.create(#estado.Trazos)
	for i, trazo in ipairs(estado.Trazos) do
		lista[i] = trazoRed(trazo)
	end
	self.CacheRed[roomId] = { Version = estado.Version, Trazos = lista }
	return lista
end

-- Turno vigente del aula (o nil). Comprueba la expiración al consultar.
function BoardService:TurnoDe(roomId)
	local turno = self.Turnos[roomId]
	if not turno then
		return nil
	end
	if os.clock() >= turno.Expira then
		self:_FinTurno(roomId, "Expirado")
		return nil
	end
	return turno
end

-- ¿El jugador tiene turno vigente en el aula?
function BoardService:TieneTurno(player, roomId)
	local turno = self:TurnoDe(roomId)
	return turno ~= nil and esJugador(player) and turno.UserId == player.UserId
end

-- Snapshot completo para el cliente (lo envía este servicio al entrar en el aula y lo incluye
-- ClassroomService en ConsultarEstado). opciones.Puntos = true añade Puntos = { {x, y}, ... } a cada trazo.
-- La lista Trazos se comparte con la caché: no modificarla.
function BoardService:Estado(roomId, opciones)
	if not self:EsAula(roomId) then
		return nil
	end
	local estado = self:_Estado(roomId)
	local datos = self:_DatosTexto(estado)
	datos.Sub = "Estado"
	datos.Nombre = nombreAula(roomId)
	datos.Aspecto = self:Aspecto(roomId)
	datos.Trazos = self:_TrazosRed(roomId, estado)
	if typeof(opciones) == "table" and opciones.Puntos == true then
		local detallados = table.create(#estado.Trazos)
		for i, trazo in ipairs(estado.Trazos) do
			local puntos = table.create(#trazo.Puntos)
			for j, punto in ipairs(trazo.Puntos) do
				puntos[j] = { punto[1], punto[2] }
			end
			detallados[i] = { Id = trazo.Id, Color = trazo.Color, Grosor = trazo.Grosor, Autor = trazo.Autor, P = trazo.P, Puntos = puntos }
		end
		datos.Trazos = detallados
	end
	local turno = self:TurnoDe(roomId)
	if turno then
		datos.Turno = { UserId = turno.UserId, Nombre = turno.Nombre, Expira = turno.ExpiraServidor, Segundos = turno.Segundos }
	end
	datos.DocenteUserId = self:DocenteDe(roomId)
	datos.RequiereSesion = self:RequiereSesion()
	datos.Limites = {
		MaxCaracteres = self.MaxCaracteres,
		MaxTrazos = self.MaxTrazos,
		MaxTrazoPuntos = self.MaxTrazoPuntos,
		TurnoSeg = self.TurnoSeg,
	}
	datos.Vacio = estadoVacio(estado)
	return datos
end

---------------------------------------------------------------------------------------------------
-- Envío a clientes
---------------------------------------------------------------------------------------------------
function BoardService:_JugadoresEnZona(zonaId)
	local lista = {}
	if not Zones.Zona(zonaId) then
		return lista
	end
	for _, player in ipairs(Players:GetPlayers()) do
		local posicion = posicionDe(player)
		if posicion and Zones.Contiene(zonaId, posicion) then
			table.insert(lista, player)
		end
	end
	return lista
end

-- Envía a la zona del aula; si 'actor' está fuera de la zona también lo recibe.
function BoardService:_Difundir(roomId, datos, actor)
	local RemoteService = self.registro.Get("RemoteService")
	if not RemoteService then
		return
	end
	local zonaId = self:ZonaDeAula(roomId)
	local enZona = self:_JugadoresEnZona(zonaId)
	if Zones.Zona(zonaId) and typeof(RemoteService.EnviarAZona) == "function" then
		pcall(RemoteService.EnviarAZona, RemoteService, zonaId, "Tablero", datos)
	elseif typeof(RemoteService.EnviarAAula) == "function" then
		pcall(RemoteService.EnviarAAula, RemoteService, roomId, "Tablero", datos)
	end
	-- Sincronía: los que tenían la versión anterior pasan a tener la nueva; un snapshot sincroniza a todos.
	local version = datos.Version
	local recibido = {}
	for _, player in ipairs(enZona) do
		recibido[player] = true
		if typeof(version) == "number" then
			local enviado = self.Enviado[player.UserId]
			if datos.Sub == "Estado" then
				self.Enviado[player.UserId] = { RoomId = roomId, Version = version }
			elseif enviado and enviado.RoomId == roomId and enviado.Version == version - 1 then
				enviado.Version = version
			end
		end
	end
	if esJugador(actor) and actor.Parent ~= nil and not recibido[actor] and typeof(RemoteService.Enviar) == "function" then
		pcall(RemoteService.Enviar, RemoteService, actor, "Tablero", datos)
	end
	self.Cambiado:Fire(roomId, datos.Sub)
end

-- Envía el snapshot completo a un jugador y marca su copia como sincronizada.
function BoardService:EnviarEstado(player, roomId)
	if not esJugador(player) then
		return false
	end
	local RemoteService = self.registro.Get("RemoteService")
	local datos = self:Estado(roomId)
	if not RemoteService or not datos then
		return false
	end
	local ok, enviado = pcall(RemoteService.Enviar, RemoteService, player, "Tablero", datos)
	if ok and enviado ~= false then
		self.Enviado[player.UserId] = { RoomId = roomId, Version = datos.Version }
		self.Estadisticas.Snapshots = self.Estadisticas.Snapshots + 1
		return true
	end
	return false
end

function BoardService:_Notificar(player, texto, nivel)
	local RemoteService = self.registro.Get("RemoteService")
	if RemoteService and esJugador(player) and player.Parent ~= nil then
		pcall(RemoteService.Enviar, RemoteService, player, "Notificacion", { Texto = texto, Nivel = nivel or "info", Duracion = 5 })
	end
end

function BoardService:_Auditar(player, accion, detalle)
	local AuditLog = self.registro.Get("AuditLogService")
	if AuditLog and typeof(AuditLog.Registrar) == "function" then
		pcall(AuditLog.Registrar, AuditLog, "Clase", player, accion, detalle)
	end
end

function BoardService:_Rechazo(player, motivo, mensaje, detalle)
	self.Estadisticas.Rechazos = self.Estadisticas.Rechazos + 1
	local texto = motivo
	if detalle ~= nil then
		texto = motivo .. ": " .. tostring(detalle)
	end
	self:_Auditar(player, "TableroRechazo", texto)
	if MOTIVOS_SOSPECHOSOS[motivo] then
		local Metrics = self.registro.Get("MetricsService")
		if Metrics and typeof(Metrics.IncrementarRechazo) == "function" then
			pcall(Metrics.IncrementarRechazo, Metrics, "BoardAction", motivo)
		end
	end
	return { ok = false, error = mensaje or ("rechazado:" .. motivo), Motivo = motivo }
end

-- Espera mínima entre acciones del mismo tipo. Devuelve true si se puede continuar.
function BoardService:_Espera(player, accion)
	local espera = self.EsperaAccion[accion] or 0.2
	local porJugador = self.UltimaAccion[player.UserId]
	if not porJugador then
		porJugador = {}
		self.UltimaAccion[player.UserId] = porJugador
	end
	local ahora = os.clock()
	local ultimo = porJugador[accion]
	if ultimo and ahora - ultimo < espera then
		return false
	end
	porJugador[accion] = ahora
	return true
end

---------------------------------------------------------------------------------------------------
-- Filtrado de texto
---------------------------------------------------------------------------------------------------

-- Filtra con TextService para mostrar a todos. Devuelve ok, textoFiltrado. Si falla, no se muestra nada.
function BoardService:Filtrar(texto, player)
	if typeof(texto) ~= "string" or texto == "" then
		return true, ""
	end
	if not esJugador(player) then
		return false, nil
	end
	local okFiltro, resultado = pcall(function()
		return TextService:FilterStringAsync(texto, player.UserId, Enum.TextFilterContext.PublicChat)
	end)
	if not okFiltro or resultado == nil then
		warn(PREFIJO .. " FilterStringAsync falló: " .. tostring(resultado))
		return false, nil
	end
	local okTexto, filtrado = pcall(function()
		return resultado:GetNonChatStringForBroadcastAsync()
	end)
	if not okTexto or typeof(filtrado) ~= "string" then
		warn(PREFIJO .. " GetNonChatStringForBroadcastAsync falló: " .. tostring(filtrado))
		return false, nil
	end
	return true, filtrado
end

---------------------------------------------------------------------------------------------------
-- Handler de BoardAction
---------------------------------------------------------------------------------------------------
function BoardService:ManejarAccion(player, datos)
	if not esJugador(player) or typeof(datos) ~= "table" then
		return { ok = false, error = "rechazado:datos" }
	end
	local accion = datos.Accion
	local roomId = datos.Salon
	if not self:EsAula(roomId) then
		return self:_Rechazo(player, "aula_desconocida", "Ese salón no tiene tablero.", roomId)
	end
	local rol = self:RolDe(player, roomId)
	if rol == nil then
		local mensaje = "Solo el docente de la sesión o un estudiante con turno puede usar el tablero."
		if self:RequiereSesion() and self:DocenteDe(roomId) == nil then
			mensaje = "No hay una sesión de clase abierta en este salón."
		end
		return self:_Rechazo(player, "sin_turno", mensaje, accion)
	end
	if accion == "Imagen" and rol ~= "Docente" then
		return self:_Rechazo(player, "solo_docente", "Solo el docente puede mostrar imágenes en el tablero.")
	end
	if not self:EstaCerca(player, roomId) then
		return self:_Rechazo(player, "distancia", "Acércate al tablero del salón para usarlo.", roomId)
	end
	if accion ~= "Limpiar" and self:EstaSilenciado(player) then
		return self:_Rechazo(player, "silenciado", "Estás silenciado: no puedes escribir en el tablero.")
	end
	if not self:_Espera(player, tostring(accion)) then
		self.Estadisticas.Rechazos = self.Estadisticas.Rechazos + 1
		return { ok = false, error = "rechazado:cooldown", Motivo = "cooldown" }
	end

	if accion == "Escribir" then
		return self:_Escribir(player, roomId, datos.Texto)
	elseif accion == "Trazo" then
		return self:_Trazo(player, roomId, datos.Trazo)
	elseif accion == "Plantilla" then
		return self:_Plantilla(player, roomId, datos.Plantilla)
	elseif accion == "Imagen" then
		return self:_Imagen(player, roomId, datos.ImagenId)
	elseif accion == "Limpiar" then
		return self:_LimpiarPor(player, roomId, rol)
	end
	return self:_Rechazo(player, "accion_desconocida", "Acción de tablero desconocida.", accion)
end

function BoardService:_Escribir(player, roomId, texto)
	if typeof(texto) ~= "string" then
		return self:_Rechazo(player, "texto_requerido", "Escribe un texto para el tablero (o envía un texto vacío para borrarlo).")
	end
	local limpio = sanearTexto(texto, self.MaxCaracteres, self.MaxLineas)
	local final = ""
	if limpio ~= "" then
		local ok, filtrado = self:Filtrar(limpio, player)
		if not ok then
			self.Estadisticas.FiltrosFallidos = self.Estadisticas.FiltrosFallidos + 1
			return self:_Rechazo(player, "filtro", "No se pudo filtrar el texto; inténtalo de nuevo en unos segundos.", roomId)
		end
		final = sanearTexto(filtrado, self.MaxCaracteres, self.MaxLineas)
		-- El filtrado cede el hilo: se comprueba de nuevo que siga autorizado.
		if self:RolDe(player, roomId) == nil then
			return self:_Rechazo(player, "sin_turno", "Tu turno en el tablero terminó antes de publicar el texto.")
		end
	end
	local estado = self:_Estado(roomId)
	if estado.Texto == final then
		return { ok = true, datos = { Version = estado.Version, Texto = final, SinCambios = true } }
	end
	estado.Texto = final
	estado.TextoAutor = player.UserId
	self:_MarcarCambio(estado, player)
	self.Estadisticas.Escrituras = self.Estadisticas.Escrituras + 1
	self:_Auditar(player, "TableroTexto", string.format("%s · %d caracteres", roomId, utf8.len(final) or #final))
	self:_Renderizar(roomId, "Texto")
	self:_Difundir(roomId, self:_DatosTexto(estado), player)
	return { ok = true, datos = { Version = estado.Version, Texto = final } }
end

function BoardService:_Plantilla(player, roomId, indice)
	local valor = 0
	if indice ~= nil then
		if typeof(indice) ~= "number" or math.floor(indice) ~= indice or Catalogs.Plantillas[indice] == nil then
			return self:_Rechazo(player, "plantilla_invalida", "Esa plantilla no existe.", indice)
		end
		valor = indice
	end
	local estado = self:_Estado(roomId)
	if estado.Plantilla == valor then
		return { ok = true, datos = { Version = estado.Version, Plantilla = valor, SinCambios = true } }
	end
	estado.Plantilla = valor
	self:_MarcarCambio(estado, player)
	self:_Renderizar(roomId, "Texto")
	self:_Difundir(roomId, self:_DatosTexto(estado), player)
	return { ok = true, datos = { Version = estado.Version, Plantilla = valor } }
end

function BoardService:_Imagen(player, roomId, imagenId)
	local valor = 0
	if imagenId ~= nil then
		if typeof(imagenId) ~= "number" or imagenId ~= imagenId or math.floor(imagenId) ~= imagenId or imagenId < 0 then
			return self:_Rechazo(player, "imagen_invalida", "El id de imagen debe ser un número entero positivo.", imagenId)
		end
		valor = imagenId
	end
	local estado = self:_Estado(roomId)
	if estado.ImagenId == valor then
		return { ok = true, datos = { Version = estado.Version, ImagenId = valor, SinCambios = true } }
	end
	estado.ImagenId = valor
	self:_MarcarCambio(estado, player)
	self.Estadisticas.Imagenes = self.Estadisticas.Imagenes + 1
	self:_Auditar(player, "TableroImagen", roomId .. " · " .. tostring(valor))
	self:_Renderizar(roomId, "Texto")
	self:_Difundir(roomId, self:_DatosTexto(estado), player)
	return { ok = true, datos = { Version = estado.Version, ImagenId = valor } }
end

function BoardService:_Trazo(player, roomId, puntos)
	if typeof(puntos) ~= "table" or #puntos == 0 then
		return self:_Rechazo(player, "trazo_vacio", "El trazo no tiene puntos.")
	end
	if #puntos > self.MaxTrazoPuntos then
		return self:_Rechazo(player, "puntos_invalidos", "El trazo tiene demasiados puntos.", #puntos)
	end
	local primero = puntos[1]
	if typeof(primero) ~= "Vector3" then
		return self:_Rechazo(player, "puntos_invalidos", "El trazo no es válido.")
	end
	local color, grosor = decodificarEstilo(primero.Z, self.ColoresTiza, self.Grosores)
	local tolerancia = self.ToleranciaPunto
	local lista = {}
	local ultimoX, ultimoY = nil, nil
	for i = 1, #puntos do
		local v = puntos[i]
		if typeof(v) ~= "Vector3" then
			return self:_Rechazo(player, "puntos_invalidos", "El trazo no es válido.", i)
		end
		local x, y = v.X, v.Y
		if x ~= x or y ~= y or x < -tolerancia or x > 1 + tolerancia or y < -tolerancia or y > 1 + tolerancia then
			return self:_Rechazo(player, "puntos_invalidos", "Hay puntos fuera del tablero.", string.format("%d (%.3f, %.3f)", i, x, y))
		end
		x = cuantizar(clamp(x, 0, 1)) / CUANTOS
		y = cuantizar(clamp(y, 0, 1)) / CUANTOS
		if ultimoX == nil or x ~= ultimoX or y ~= ultimoY then
			table.insert(lista, { x, y })
			ultimoX, ultimoY = x, y
		end
	end
	self.SiguienteTrazo = self.SiguienteTrazo + 1
	local trazo = {
		Id = self.SiguienteTrazo,
		Puntos = lista,
		Color = color,
		Grosor = grosor,
		Autor = player.UserId,
	}
	trazo.P = codificarPuntos(lista)

	local estado = self:_Estado(roomId)
	table.insert(estado.Trazos, trazo)
	local descartados = {}
	while #estado.Trazos > self.MaxTrazos do
		local viejo = table.remove(estado.Trazos, 1)
		table.insert(descartados, viejo.Id)
	end
	self:_MarcarCambio(estado, player)
	self.Estadisticas.Trazos = self.Estadisticas.Trazos + 1
	self:_RenderTrazo(roomId, trazo, descartados)
	local red = trazoRed(trazo)
	self:_Difundir(roomId, {
		Sub = "Trazo",
		RoomId = roomId,
		Version = estado.Version,
		Trazo = red,
		Descartados = descartados,
		Autor = estado.Autor,
		AutorNombre = estado.AutorNombre,
		Actualizado = estado.Actualizado,
	}, player)
	return { ok = true, datos = { Version = estado.Version, Trazo = red, Descartados = descartados } }
end

-- Docente: borra todo el contenido (la proyección del PC se conserva). Invitado: solo sus trazos y su texto.
function BoardService:_LimpiarPor(player, roomId, rol)
	local estado = self:_Estado(roomId)
	if rol == "Docente" then
		if estado.Texto == "" and estado.Plantilla == 0 and #estado.Trazos == 0 and estado.ImagenId == 0 then
			return { ok = true, datos = { Version = estado.Version, SinCambios = true } }
		end
		estado.Texto = ""
		estado.TextoAutor = 0
		estado.Plantilla = 0
		estado.Trazos = {}
		estado.ImagenId = 0
		self:_MarcarCambio(estado, player)
		self.Estadisticas.Limpiezas = self.Estadisticas.Limpiezas + 1
		self:_Auditar(player, "TableroLimpiar", roomId)
		self:_Renderizar(roomId, "Todo")
		self:_Difundir(roomId, {
			Sub = "Limpiar", RoomId = roomId, Version = estado.Version, Todo = true, Completo = false,
			Autor = estado.Autor, AutorNombre = estado.AutorNombre, Actualizado = estado.Actualizado,
		}, player)
		return { ok = true, datos = { Version = estado.Version, Todo = true } }
	end

	local restantes = {}
	local quitados = 0
	for _, trazo in ipairs(estado.Trazos) do
		if trazo.Autor == player.UserId then
			quitados = quitados + 1
		else
			table.insert(restantes, trazo)
		end
	end
	local textoPropio = estado.Texto ~= "" and estado.TextoAutor == player.UserId
	if quitados == 0 and not textoPropio then
		return { ok = true, datos = { Version = estado.Version, SinCambios = true } }
	end
	estado.Trazos = restantes
	if textoPropio then
		estado.Texto = ""
		estado.TextoAutor = 0
	end
	self:_MarcarCambio(estado, player)
	self:_Auditar(player, "TableroLimpiarPropio", string.format("%s · %d trazos%s", roomId, quitados, textoPropio and " y texto" or ""))
	self:_Renderizar(roomId, "Todo")
	self:_Difundir(roomId, self:Estado(roomId), player)
	return { ok = true, datos = { Version = estado.Version, Todo = false, Quitados = quitados } }
end

---------------------------------------------------------------------------------------------------
-- API para otros servicios
---------------------------------------------------------------------------------------------------

-- Concede (o renueva) el turno de tablero de un aula a un jugador. Un jugador solo tiene turno en un aula y
-- un aula solo tiene un invitado. Devuelve true, expiraServidor | false, motivo.
function BoardService:ConcederTurno(roomId, player, segundos, otorgante)
	if not self:EsAula(roomId) then
		return false, "aula_desconocida"
	end
	if not esJugador(player) or player.Parent == nil then
		return false, "jugador_invalido"
	end
	local duracion = tonumber(segundos) or self.TurnoSeg
	if duracion ~= duracion then
		duracion = self.TurnoSeg
	end
	duracion = clamp(math.floor(duracion + 0.5), self.TurnoMinSeg, self.TurnoMaxSeg)

	local otras = {}
	for otraAula, turno in pairs(self.Turnos) do
		if otraAula ~= roomId and turno.UserId == player.UserId then
			table.insert(otras, otraAula)
		end
	end
	for _, otraAula in ipairs(otras) do
		self:_FinTurno(otraAula, "OtraAula")
	end
	local actual = self.Turnos[roomId]
	if actual and actual.UserId ~= player.UserId then
		self:_FinTurno(roomId, "Reemplazado")
	end

	self.TokenTurno = self.TokenTurno + 1
	local token = self.TokenTurno
	local turno = {
		UserId = player.UserId,
		Nombre = nombreJugador(player),
		Expira = os.clock() + duracion,
		ExpiraServidor = ahoraServidor() + duracion,
		Segundos = duracion,
		Token = token,
		Otorgante = esJugador(otorgante) and otorgante.UserId or nil,
		Concedido = os.time(),
	}
	self.Turnos[roomId] = turno
	task.delay(duracion + 0.05, function()
		local vigente = self.Turnos[roomId]
		if vigente and vigente.Token == token then
			self:_FinTurno(roomId, "Expirado")
		end
	end)

	self:_Difundir(roomId, self:_DatosTurno(roomId, "Concedido"), player)
	self:_Notificar(player, string.format("Tienes turno en el tablero de %s durante %d s.", nombreAula(roomId), duracion), "exito")
	self:_Auditar(esJugador(otorgante) and otorgante or player, "TableroTurno",
		string.format("%s · %s (%d) · %d s", roomId, player.Name, player.UserId, duracion))
	self.TurnoCambiado:Fire(roomId, turno, "Concedido")
	return true, turno.ExpiraServidor
end

-- Retira el turno vigente del aula (si lo hay). Devuelve true si había turno.
function BoardService:RevocarTurno(roomId, motivo)
	if self.Turnos[roomId] == nil then
		return false
	end
	return self:_FinTurno(roomId, typeof(motivo) == "string" and motivo or "Revocado")
end

function BoardService:_DatosTurno(roomId, motivo)
	local turno = self.Turnos[roomId]
	if turno and os.clock() >= turno.Expira then
		turno = nil
	end
	local datos = {
		Sub = "Turno",
		RoomId = roomId,
		Activo = turno ~= nil,
		Motivo = motivo,
		DocenteUserId = self:DocenteDe(roomId),
		RequiereSesion = self:RequiereSesion(),
	}
	if turno then
		datos.UserId = turno.UserId
		datos.Nombre = turno.Nombre
		datos.Expira = turno.ExpiraServidor
		datos.Segundos = turno.Segundos
	end
	return datos
end

function BoardService:_FinTurno(roomId, motivo)
	local turno = self.Turnos[roomId]
	if not turno then
		return false
	end
	self.Turnos[roomId] = nil
	local player = Players:GetPlayerByUserId(turno.UserId)
	local datos = self:_DatosTurno(roomId, motivo)
	datos.Anterior = turno.UserId
	datos.AnteriorNombre = turno.Nombre
	self:_Difundir(roomId, datos, player)
	local plantilla = MENSAJES_FIN_TURNO[motivo]
	if player and plantilla then
		self:_Notificar(player, string.format(plantilla, nombreAula(roomId)), "info")
	end
	self:_Auditar(player or turno.UserId, "TableroFinTurno", roomId .. " · " .. tostring(motivo))
	self.TurnoCambiado:Fire(roomId, nil, motivo)
	return true
end

function BoardService:_FinTurnosDe(userId, motivo)
	local aulas = {}
	for roomId, turno in pairs(self.Turnos) do
		if turno.UserId == userId then
			table.insert(aulas, roomId)
		end
	end
	for _, roomId in ipairs(aulas) do
		self:_FinTurno(roomId, motivo)
	end
end

-- Borra todo el tablero (texto, plantilla, trazos, imagen y proyección) y retira el turno.
-- Lo llama ClassroomService al cerrar una sesión y este servicio al terminar la jornada.
function BoardService:Limpiar(roomId, motivo)
	if not self:EsAula(roomId) then
		return false, "aula_desconocida"
	end
	if self.Turnos[roomId] then
		self:_FinTurno(roomId, "Limpieza")
	end
	local estado = self.Estados[roomId]
	if estadoVacio(estado) then
		return true
	end
	estado.Texto = ""
	estado.TextoAutor = 0
	estado.Plantilla = 0
	estado.Trazos = {}
	estado.ImagenId = 0
	estado.Proyeccion = ""
	estado.Autor = 0
	estado.AutorNombre = ""
	self:_MarcarCambio(estado, nil)
	self.Estadisticas.Limpiezas = self.Estadisticas.Limpiezas + 1
	self:_Renderizar(roomId, "Todo")
	self:_Difundir(roomId, {
		Sub = "Limpiar", RoomId = roomId, Version = estado.Version, Todo = true, Completo = true,
		Motivo = typeof(motivo) == "string" and motivo or "Sistema", Actualizado = estado.Actualizado,
	})
	self:_Auditar(nil, "TableroReinicio", roomId .. " · " .. tostring(motivo or "Sistema"))
	return true
end

-- Limpia todos los tableros con contenido o turno.
function BoardService:LimpiarTodos(motivo)
	local aulas = {}
	for roomId in pairs(self.Estados) do
		aulas[roomId] = true
	end
	for roomId in pairs(self.Turnos) do
		aulas[roomId] = true
	end
	local n = 0
	for roomId in pairs(aulas) do
		local ok = self:Limpiar(roomId, motivo)
		if ok then
			n = n + 1
		end
	end
	return n
end

-- Texto proyectado (PCService: pantalla de clase). texto vacío/nil quita la proyección. Si se pasa 'player',
-- el texto se filtra a su nombre; si no, se asume ya filtrado por el servicio que llama.
function BoardService:Proyectar(roomId, texto, player)
	if not self:EsAula(roomId) then
		return false, "aula_desconocida"
	end
	local limpio = sanearTexto(tostring(texto or ""), self.MaxCaracteres, self.MaxLineas)
	if limpio ~= "" and esJugador(player) then
		local ok, filtrado = self:Filtrar(limpio, player)
		if not ok then
			self.Estadisticas.FiltrosFallidos = self.Estadisticas.FiltrosFallidos + 1
			return false, "filtro"
		end
		limpio = sanearTexto(filtrado, self.MaxCaracteres, self.MaxLineas)
	end
	local estado = self:_Estado(roomId)
	if estado.Proyeccion == limpio then
		return true
	end
	estado.Proyeccion = limpio
	self:_MarcarCambio(estado, player)
	self:_Renderizar(roomId, "Texto")
	self:_Difundir(roomId, self:_DatosTexto(estado), player)
	return true
end

-- Resumen para métricas y paneles de dirección.
function BoardService:Resumen()
	local tableros, conContenido, trazos = 0, 0, 0
	for _, estado in pairs(self.Estados) do
		tableros = tableros + 1
		trazos = trazos + #estado.Trazos
		if not estadoVacio(estado) then
			conContenido = conContenido + 1
		end
	end
	local turnos = 0
	for _ in pairs(self.Turnos) do
		turnos = turnos + 1
	end
	local copia = {}
	for clave, valor in pairs(self.Estadisticas) do
		copia[clave] = valor
	end
	copia.Tableros = tableros
	copia.ConContenido = conContenido
	copia.TrazosGuardados = trazos
	copia.TurnosActivos = turnos
	copia.FramesFisicos = self.FramesGlobal
	return copia
end

---------------------------------------------------------------------------------------------------
-- Jugadores y ciclo periódico
---------------------------------------------------------------------------------------------------
function BoardService:AlSalir(player)
	local userId = player.UserId
	self:_FinTurnosDe(userId, "Salida")
	self.Enviado[userId] = nil
	self.UltimaAccion[userId] = nil
end

-- Adelanta el siguiente ciclo (agrupa varios avisos en uno).
function BoardService:_ProgramarCiclo()
	if self.CicloPendiente or not self.Activo then
		return
	end
	self.CicloPendiente = true
	task.delay(0.3, function()
		self.CicloPendiente = false
		local ok, err = pcall(self._Ciclo, self)
		if not ok then
			warn(PREFIJO .. " Error en el ciclo: " .. tostring(err))
		end
	end)
end

function BoardService:_Ciclo()
	-- 1. Turnos vencidos (respaldo de task.delay).
	local vencidos = {}
	local ahora = os.clock()
	for roomId, turno in pairs(self.Turnos) do
		if ahora >= turno.Expira then
			table.insert(vencidos, roomId)
		end
	end
	for _, roomId in ipairs(vencidos) do
		self:_FinTurno(roomId, "Expirado")
	end

	-- 2. Quien entra en un aula (o tiene una copia vieja) recibe el estado completo.
	local presentes = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local roomId = self:AulaDePosicion(posicionDe(player))
		if roomId then
			presentes[roomId] = true
			local estado = self.Estados[roomId]
			local version = estado and estado.Version or 0
			local enviado = self.Enviado[player.UserId]
			if not enviado or enviado.RoomId ~= roomId or enviado.Version ~= version then
				self:EnviarEstado(player, roomId)
			end
		end
	end

	-- 3. Cambios de docente de la sesión (apertura/cierre) en aulas con gente: avisa y cierra turnos huérfanos.
	if self:RequiereSesion() then
		for roomId in pairs(self.Turnos) do
			presentes[roomId] = true
		end
		for roomId in pairs(presentes) do
			local docente = self:DocenteDe(roomId) or 0
			local anterior = self.DocenteConocido[roomId]
			self.DocenteConocido[roomId] = docente
			if anterior ~= nil and anterior ~= docente then
				if docente == 0 and self.Turnos[roomId] then
					self:_FinTurno(roomId, "SesionCerrada")
				else
					self:_Difundir(roomId, self:_DatosTurno(roomId, "Sesion"))
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Tablero físico (SurfaceGui creada por MapService)
---------------------------------------------------------------------------------------------------
local NOMBRE_VISTA = "ColegioRP_TableroVista"

local function nuevoTexto(nombre, padre, props)
	local label = Instance.new("TextLabel")
	label.Name = nombre
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.RichText = false
	label.TextWrapped = true
	label.TextScaled = true
	label.Font = props.Fuente or FUENTE_TIZA
	label.TextColor3 = props.Color or BoardService.ColorTexto
	label.TextXAlignment = props.AlineacionX or Enum.TextXAlignment.Left
	label.TextYAlignment = props.AlineacionY or Enum.TextYAlignment.Top
	label.Position = props.Position or UDim2.fromScale(0, 0)
	label.Size = props.Size or UDim2.fromScale(1, 1)
	label.ZIndex = props.ZIndex or 3
	label.Text = ""
	if props.MaxTexto then
		local limite = Instance.new("UITextSizeConstraint")
		limite.MaxTextSize = math.max(8, math.floor(props.MaxTexto))
		limite.MinTextSize = 6
		limite.Parent = label
	end
	label.Parent = padre
	return label
end

function BoardService:_CrearVista(roomId, gui, tablero)
	local anterior = gui:FindFirstChild(NOMBRE_VISTA)
	if anterior then
		pcall(function()
			anterior:Destroy()
		end)
	end
	local alto = 6
	local aspecto = self.AspectoPorDefecto
	if typeof(tablero) == "Instance" and tablero:IsA("BasePart") and tablero.Size.Y > 0 then
		alto = tablero.Size.Y
		aspecto = tablero.Size.X / tablero.Size.Y
	end
	local pixeles = 50
	pcall(function()
		pixeles = gui.PixelsPerStud
	end)
	local altoPx = math.max(60, alto * pixeles)

	local raiz = Instance.new("Frame")
	raiz.Name = NOMBRE_VISTA
	raiz.BackgroundColor3 = self.ColorFondo
	raiz.BackgroundTransparency = self.TransparenciaFondo
	raiz.BorderSizePixel = 0
	raiz.Size = UDim2.fromScale(1, 1)
	raiz.ClipsDescendants = true
	raiz.ZIndex = 1
	raiz.Visible = false
	raiz:SetAttribute("RoomId", roomId)

	local imagen = Instance.new("ImageLabel")
	imagen.Name = "Imagen"
	imagen.BackgroundTransparency = 1
	imagen.BorderSizePixel = 0
	imagen.ScaleType = Enum.ScaleType.Fit
	imagen.AnchorPoint = Vector2.new(0.5, 0.5)
	imagen.Position = UDim2.fromScale(0.5, 0.5)
	imagen.Size = UDim2.fromScale(0.92, 0.86)
	imagen.ZIndex = 2
	imagen.Visible = false
	imagen.Parent = raiz

	local encabezado = nuevoTexto("Plantilla", raiz, {
		Fuente = FUENTE_TITULO, Color = self.ColorPlantilla, Position = UDim2.fromScale(0.04, 0.03),
		Size = UDim2.fromScale(0.92, 0.12), AlineacionY = Enum.TextYAlignment.Center, MaxTexto = altoPx * 0.1,
	})
	encabezado.Visible = false
	local texto = nuevoTexto("Texto", raiz, {
		Position = UDim2.fromScale(0.04, 0.05), Size = UDim2.fromScale(0.92, 0.85), MaxTexto = altoPx * 0.11,
	})

	local capa = Instance.new("Frame")
	capa.Name = "Trazos"
	capa.BackgroundTransparency = 1
	capa.BorderSizePixel = 0
	capa.Size = UDim2.fromScale(1, 1)
	capa.ClipsDescendants = true
	capa.ZIndex = 4
	capa.Parent = raiz

	local proyeccion = Instance.new("Frame")
	proyeccion.Name = "Proyeccion"
	proyeccion.BackgroundColor3 = Color3.fromRGB(18, 34, 26)
	proyeccion.BackgroundTransparency = 0.15
	proyeccion.BorderSizePixel = 0
	proyeccion.Position = UDim2.fromScale(0.03, 0.8)
	proyeccion.Size = UDim2.fromScale(0.94, 0.12)
	proyeccion.ZIndex = 5
	proyeccion.Visible = false
	proyeccion.Parent = raiz
	local textoProyeccion = nuevoTexto("Texto", proyeccion, {
		Fuente = FUENTE_TEXTO, Color = Color3.fromRGB(200, 230, 255), Position = UDim2.fromScale(0.02, 0.08),
		Size = UDim2.fromScale(0.96, 0.84), AlineacionY = Enum.TextYAlignment.Center, ZIndex = 6, MaxTexto = altoPx * 0.06,
	})

	local autor = nuevoTexto("Autor", raiz, {
		Fuente = FUENTE_TEXTO, Color = Color3.fromRGB(170, 190, 175), Position = UDim2.fromScale(0.5, 0.935),
		Size = UDim2.fromScale(0.48, 0.055), AlineacionX = Enum.TextXAlignment.Right,
		AlineacionY = Enum.TextYAlignment.Center, ZIndex = 5, MaxTexto = altoPx * 0.04,
	})

	raiz.Parent = gui
	return {
		RoomId = roomId,
		Gui = gui,
		Raiz = raiz,
		Imagen = imagen,
		Encabezado = encabezado,
		Texto = texto,
		Capa = capa,
		Proyeccion = proyeccion,
		ProyeccionTexto = textoProyeccion,
		Autor = autor,
		Aspecto = aspecto,
		Frames = {}, -- trazoId -> { Frame... }
		Orden = {}, -- trazoIds dibujados, del más antiguo al más reciente
		Total = 0,
		Nueva = true,
	}
end

function BoardService:_DestruirVista(roomId)
	local vista = self.Vistas[roomId]
	if not vista then
		return
	end
	self.Vistas[roomId] = nil
	self.FramesGlobal = math.max(0, self.FramesGlobal - vista.Total)
	vista.Total = 0
	pcall(function()
		vista.Raiz:Destroy()
	end)
end

-- Vista actual del tablero físico del aula (la crea o la rehace si la SurfaceGui cambió). nil si no hay tablero.
function BoardService:_Vista(roomId)
	local aula = self:_InfoAula(roomId)
	local gui = aula and aula.TableroGui
	if typeof(gui) ~= "Instance" or gui.Parent == nil then
		if self.Vistas[roomId] then
			self:_DestruirVista(roomId)
		end
		return nil
	end
	local vista = self.Vistas[roomId]
	if vista and vista.Gui == gui and vista.Raiz.Parent == gui then
		return vista
	end
	if vista then
		self:_DestruirVista(roomId)
	end
	vista = self:_CrearVista(roomId, gui, aula.Tablero)
	self.Vistas[roomId] = vista
	return vista
end

-- Segmento de tiza entre dos puntos normalizados, con posición y tamaño en escala (se adapta a cualquier
-- resolución). aspecto = ancho / alto del lienzo; grosor = fracción del alto.
function BoardService.CrearSegmento(padre, a, b, color, grosor, aspecto, zIndex)
	local dx = b[1] - a[1]
	local dy = b[2] - a[2]
	local dyAncho = dy / aspecto
	local largo = math.sqrt(dx * dx + dyAncho * dyAncho)
	local frame = Instance.new("Frame")
	frame.Name = "T"
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = color
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale((a[1] + b[1]) / 2, (a[2] + b[2]) / 2)
	frame.Size = UDim2.fromScale(largo + grosor / aspecto, grosor)
	frame.Rotation = math.deg(math.atan2(dy, dx * aspecto))
	frame.ZIndex = zIndex or 4
	frame.Parent = padre
	return frame
end

function BoardService:_FramesDeTrazo(vista, trazo)
	local puntos = trazo.Puntos
	local n = #puntos
	local color = self.ColoresTiza[trazo.Color] or self.ColoresTiza[1]
	local grosor = self.Grosores[trazo.Grosor] or self.Grosores[2]
	local frames = {}
	if n == 0 then
		return frames
	end
	if n == 1 then
		table.insert(frames, BoardService.CrearSegmento(vista.Capa, puntos[1], puntos[1], color, grosor, vista.Aspecto, 4))
		return frames
	end
	local i = 1
	while i < n do
		local j = math.min(i + self.PuntosPorFrame, n)
		table.insert(frames, BoardService.CrearSegmento(vista.Capa, puntos[i], puntos[j], color, grosor, vista.Aspecto, 4))
		i = j
	end
	return frames
end

function BoardService:_QuitarFramesTrazo(vista, trazoId)
	local frames = vista.Frames[trazoId]
	if not frames then
		return
	end
	vista.Frames[trazoId] = nil
	for _, frame in ipairs(frames) do
		frame:Destroy()
	end
	vista.Total = math.max(0, vista.Total - #frames)
	self.FramesGlobal = math.max(0, self.FramesGlobal - #frames)
	for i, id in ipairs(vista.Orden) do
		if id == trazoId then
			table.remove(vista.Orden, i)
			break
		end
	end
end

-- Dibuja un trazo respetando los límites (quita los trazos dibujados más antiguos si hace falta).
function BoardService:_DibujarTrazo(vista, trazo)
	local necesarios = framesNecesarios(#trazo.Puntos, self.PuntosPorFrame)
	local function excede()
		return vista.Total + necesarios > self.MaxFramesTablero or self.FramesGlobal + necesarios > self.MaxFramesGlobal
	end
	while excede() and #vista.Orden > 0 do
		self:_QuitarFramesTrazo(vista, vista.Orden[1])
	end
	if excede() then
		return false
	end
	local frames = self:_FramesDeTrazo(vista, trazo)
	vista.Frames[trazo.Id] = frames
	table.insert(vista.Orden, trazo.Id)
	vista.Total = vista.Total + #frames
	self.FramesGlobal = self.FramesGlobal + #frames
	return true
end

function BoardService:_RenderTrazosCompleto(vista, estado)
	for _, id in ipairs(table.clone(vista.Orden)) do
		self:_QuitarFramesTrazo(vista, id)
	end
	vista.Frames = {}
	vista.Orden = {}
	if not estado then
		return
	end
	-- Se eligen los trazos más recientes que caben en el presupuesto y se dibujan en orden cronológico.
	local presupuesto = math.min(self.MaxFramesTablero, math.max(0, self.MaxFramesGlobal - self.FramesGlobal))
	local desde = #estado.Trazos + 1
	local suma = 0
	for i = #estado.Trazos, 1, -1 do
		local n = framesNecesarios(#estado.Trazos[i].Puntos, self.PuntosPorFrame)
		if suma + n > presupuesto then
			break
		end
		suma = suma + n
		desde = i
	end
	for i = desde, #estado.Trazos do
		self:_DibujarTrazo(vista, estado.Trazos[i])
	end
end

function BoardService:_RenderTextos(vista, estado)
	local plantilla = Catalogs.Plantillas[estado.Plantilla]
	vista.Encabezado.Visible = plantilla ~= nil
	vista.Encabezado.Text = plantilla or ""
	local proyecta = estado.Proyeccion ~= ""
	local arriba = 0.05
	if plantilla then
		arriba = 0.16
	end
	local abajo = 0.92
	if proyecta then
		abajo = 0.78
	end
	vista.Texto.Position = UDim2.fromScale(0.04, arriba)
	vista.Texto.Size = UDim2.fromScale(0.92, math.max(0.1, abajo - arriba))
	vista.Texto.Text = estado.Texto
	vista.Proyeccion.Visible = proyecta
	vista.ProyeccionTexto.Text = proyecta and ("Proyección: " .. estado.Proyeccion) or ""
	if estado.ImagenId > 0 then
		vista.Imagen.Image = "rbxassetid://" .. string.format("%.0f", estado.ImagenId)
		vista.Imagen.Visible = true
	else
		vista.Imagen.Image = ""
		vista.Imagen.Visible = false
	end
	if estado.AutorNombre ~= "" then
		vista.Autor.Text = "Última edición: " .. estado.AutorNombre
	else
		vista.Autor.Text = ""
	end
end

-- Actualiza el tablero físico. que = "Texto" (solo textos, plantilla, imagen y proyección) | "Todo".
function BoardService:_Renderizar(roomId, que)
	local ok, err = pcall(function()
		local vista = self:_Vista(roomId)
		if not vista then
			return
		end
		local estado = self.Estados[roomId]
		if que == "Todo" or vista.Nueva then
			self:_RenderTrazosCompleto(vista, estado)
			vista.Nueva = false
		end
		if estado then
			self:_RenderTextos(vista, estado)
		end
		vista.Raiz.Visible = not estadoVacio(estado)
	end)
	if not ok then
		warn(PREFIJO .. " No se pudo dibujar el tablero de " .. tostring(roomId) .. ": " .. tostring(err))
	end
end

-- Añade un trazo al tablero físico y quita los descartados (sin redibujar todo).
function BoardService:_RenderTrazo(roomId, trazo, descartados)
	local ok, err = pcall(function()
		local vista = self:_Vista(roomId)
		if not vista then
			return
		end
		if vista.Nueva then
			self:_RenderTrazosCompleto(vista, self.Estados[roomId])
			self:_RenderTextos(vista, self.Estados[roomId])
			vista.Nueva = false
		else
			for _, id in ipairs(descartados or {}) do
				self:_QuitarFramesTrazo(vista, id)
			end
			self:_DibujarTrazo(vista, trazo)
		end
		vista.Raiz.Visible = not estadoVacio(self.Estados[roomId])
	end)
	if not ok then
		warn(PREFIJO .. " No se pudo dibujar el trazo en " .. tostring(roomId) .. ": " .. tostring(err))
	end
end

-- Redibuja todos los tableros físicos (tras reconstruir el mapa).
function BoardService:RedibujarTodo()
	local aulas = {}
	for roomId in pairs(self.Vistas) do
		aulas[roomId] = true
	end
	for roomId in pairs(self.Estados) do
		aulas[roomId] = true
	end
	for roomId in pairs(aulas) do
		self:_DestruirVista(roomId)
		if self.Estados[roomId] and not estadoVacio(self.Estados[roomId]) then
			self:_Renderizar(roomId, "Todo")
		end
	end
end

return BoardService
