--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.DoorService
	Tipo: ModuleScript
	Puertas del colegio (docs/ARQUITECTURA.md §6): resuelve cada puerta de MapaLogico.Puertas (MapService:Puerta o
	ruta propia con desempate por Centro), detecta la hoja y sus piezas pegadas (pomos, paneles), guarda los valores
	originales (Transparency, CanCollide, CFrame) y añade ProximityPrompts (RPTipo = "Puerta") sobre un Attachment
	propio en la hoja. Estados: Abierta / Cerrada / Bloqueada / Privada (atributo Estado en la hoja).
	Modos: "estado" (abrir = Transparency 0.7 + CanCollide false en la hoja, cerrar = restaurar), "privacidad"
	(baños: quien está dentro bloquea 60 s solo contra la entrada) y "giro" (tween de 90° sobre la arista de la
	bisagra; solo con Config.Puertas.PermitirGiro y con caída a "estado" si falla).
	Reglas: nunca encierra (desde dentro siempre se abre: el bloqueo solo impide entrar desde fuera, calculado con el
	plano de la hoja), cooldown por puerta, autocierre (no si el personal la fijó abierta), bloqueo según
	CargosBloqueo o permiso puertas.aulas / puertas.oficinas. Remoto DoorAction (distancia <= 14) y eventos
	EventoCliente "Puerta" { Sub = "Estado" | "Mensaje", PuertaId, Estado, ... } a la zona de la puerta.
	Estado inicial: todas las puertas "Abierta" y transitables con su aspecto original (como en el mapa); el
	Porton_Blanco conserva su Transparency pero sus hojas quedan con CanCollide = false para no encerrar a nadie.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local MapaLogico = require(Shared:WaitForChild("MapaLogico"))
local Util = Shared:WaitForChild("Util")
local Zones = require(Util:WaitForChild("Zones"))
local Signal = require(Util:WaitForChild("Signal"))

local DoorService = {}
DoorService.Nombre = "DoorService"

local PREFIJO = "[ColegioRP][DoorService]"

---------------------------------------------------------------------------------------------------
-- Parámetros (Config.Puertas y ajustes finos del servicio)
---------------------------------------------------------------------------------------------------
local CFG = Config.Puertas or {}
local COOLDOWN_SEG = tonumber(CFG.CooldownSeg) or 1
local AUTOCIERRE_SEG = tonumber(CFG.AutoCierreSeg) or 8
local PERMITIR_GIRO = CFG.PermitirGiro == true
local PRIVACIDAD_SEG = tonumber(CFG.PrivacidadSeg) or 60
local DISTANCIA_MAX = (Config.Distancias and tonumber(Config.Distancias.Puerta)) or 14
local SONIDO_ID = tonumber(Config.Sonidos and Config.Sonidos.Puerta) or 0
local TAG_HOJA = (Config.Tags and Config.Tags.Puerta) or "ColegioRP_Puerta"

DoorService.TagPrompt = "ColegioRP_PromptPuerta" -- Prompt principal (Abrir/Cerrar) de cada puerta.
DoorService.TagPromptBloqueo = "ColegioRP_PromptBloqueo" -- Prompt de bloqueo para el personal autorizado.
DoorService.TagPromptPrivacidad = "ColegioRP_PromptPrivacidad" -- Prompt de privacidad (solo baños).
DoorService.ToleranciaDistancia = 2 -- Studs añadidos a la distancia máxima (latencia y tamaño del personaje).
DoorService.TransparenciaAbierta = 0.7 -- Transparencia de la hoja abierta en modo "estado".
DoorService.DistanciaPrompt = 8 -- MaxActivationDistance de los prompts.
DoorService.HoldBloqueo = 0.5 -- Pulsación sostenida del prompt de bloqueo/privacidad (evita toques accidentales).
DoorService.DistanciaAvisoVecinos = 20 -- Jugadores fuera de la zona a esta distancia también reciben el evento.
DoorService.CooldownPrivacidadJugador = 20 -- Segundos entre activaciones de privacidad de un mismo jugador.
DoorService.GraciaVaciaSeg = 3 -- Si nadie queda dentro del baño durante este tiempo, la privacidad se libera.
DoorService.UmbralGrosor = 2.5 -- Medio fondo (studs) del umbral: alguien aquí impide el autocierre.
DoorService.ReintentoAutocierreSeg = 2 -- Reintento del autocierre si hay alguien en el umbral.
DoorService.DistanciaReferenciaBano = 9 -- Distancia máxima puerta-inodoro para tomarlo como "dentro" del cubículo.
DoorService.DuracionGiro = 0.5 -- Duración del tween de giro.
DoorService.AnguloGiro = 90 -- Grados de apertura en modo "giro".
DoorService.MargenGrosor = 0.6 -- Margen (studs) en el grosor para incluir pomos y paneles pegados a la hoja.
DoorService.MargenPlano = 0.05 -- Margen en el plano de la hoja para esas piezas.
DoorService.MaxDistanciaCentro = 10 -- Si la instancia resuelta está más lejos de Centro, se buscan homónimas.
DoorService.VisitasMaxRuta = 60000 -- Límite de nodos visitados al resolver rutas con nombres repetidos.
DoorService.IntervaloPromptSeg = 0.25 -- Activaciones de prompt más rápidas que esto (por jugador) se ignoran.
DoorService.IntervaloAuditoriaSeg = 10 -- Un mismo rechazo (jugador, puerta, motivo) se audita como mucho una vez en este tiempo.

local ACCIONES = { Abrir = true, Cerrar = true, Bloquear = true, Desbloquear = true, Privacidad = true }
local TIPOS_AULA = { aula = true, aula_especial = true, aula_pc = true }
-- Piezas de marco que nunca forman parte de la hoja (se buscan en minúsculas dentro del nombre).
local NOMBRES_MARCO = { "marco", "jamba", "dintel", "umbral", "bisagra", "poste", "montante", "pared", "muro", "columna" }
-- Motivos de rechazo que se auditan (los de cooldown, sin cambio u ocupado no aportan información).
local MOTIVOS_AUDITADOS = {
	puerta_inexistente = true, accion_invalida = true, distancia = true, sin_permiso_bloqueo = true,
	bloqueada = true, jugador_invalido = true, fuera = true,
}
-- Motivos que además cuentan como rechazo en MetricsService (peticiones manipuladas o sin permiso).
local MOTIVOS_METRICAS = { puerta_inexistente = true, accion_invalida = true, distancia = true, sin_permiso_bloqueo = true }

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function esJugador(valor)
	return typeof(valor) == "Instance" and valor:IsA("Player")
end

local function posicionJugador(player)
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

local function plano(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function unitarioPlano(v)
	local h = plano(v)
	if h.Magnitude < 0.01 then
		return nil
	end
	return h.Unit
end

local function volumen(parte)
	local s = parte.Size
	return s.X * s.Y * s.Z
end

local function esMarco(nombre)
	local minus = string.lower(tostring(nombre))
	for _, clave in ipairs(NOMBRES_MARCO) do
		if string.find(minus, clave, 1, true) then
			return true
		end
	end
	return false
end

local function contieneHoja(nombre)
	return string.find(string.lower(tostring(nombre)), "hoja", 1, true) ~= nil
end

local function esAsiento(parte)
	return parte:IsA("Seat") or parte:IsA("VehicleSeat")
end

-- Extensión total (studs) de la caja de una BasePart a lo largo de una dirección unitaria.
local function extension(cf, s, direccion)
	return math.abs(cf.RightVector:Dot(direccion)) * s.X
		+ math.abs(cf.UpVector:Dot(direccion)) * s.Y
		+ math.abs(cf.LookVector:Dot(direccion)) * s.Z
end

-- Ejes locales de una parte clasificados: índice del más vertical, del más fino y del más ancho (de los otros dos).
local function clasificarEjes(parte)
	local cf, s = parte.CFrame, parte.Size
	local ejes = { { cf.RightVector, s.X }, { cf.UpVector, s.Y }, { cf.LookVector, s.Z } }
	local iVertical, mejor = 2, -1
	for i, eje in ipairs(ejes) do
		local alineacion = math.abs(eje[1].Y)
		if alineacion > mejor then
			mejor = alineacion
			iVertical = i
		end
	end
	local iFino, iAncho = nil, nil
	for i, eje in ipairs(ejes) do
		if i ~= iVertical then
			if iFino == nil then
				iFino = i
			elseif eje[2] < ejes[iFino][2] then
				iAncho = iFino
				iFino = i
			else
				iAncho = i
			end
		end
	end
	return ejes, iVertical, iFino, iAncho
end

-- Posición representativa de una instancia (BasePart, Model o contenedor con BaseParts).
local function posicionInstancia(instancia)
	if instancia:IsA("BasePart") then
		return instancia.Position
	end
	if instancia:IsA("Model") then
		local ok, cf = pcall(function()
			local caja = instancia:GetBoundingBox()
			return caja
		end)
		if ok and typeof(cf) == "CFrame" then
			return cf.Position
		end
	end
	local suma, n = Vector3.new(0, 0, 0), 0
	local okD, descendientes = pcall(instancia.GetDescendants, instancia)
	if okD then
		for _, d in ipairs(descendientes) do
			if d:IsA("BasePart") then
				suma = suma + d.Position
				n = n + 1
			end
		end
	end
	if n > 0 then
		return suma / n
	end
	return nil
end

-- Lista "a,b,c" -> set y texto.
local function conjuntoCargos(lista)
	local set, textos = {}, {}
	if typeof(lista) == "table" then
		for _, cargo in ipairs(lista) do
			if typeof(cargo) == "string" and cargo ~= "" then
				set[cargo] = true
				table.insert(textos, cargo)
			end
		end
	end
	return set, table.concat(textos, ",")
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

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function DoorService:Init(registro)
	self.registro = registro
	self.Puertas = {} -- puertaId -> registro de puerta (ver ConstruirPuerta)
	self.Orden = {} -- ids resueltos en el orden de MapaLogico.OrdenPuertas
	self.NoResueltas = {} -- ids sin instancia en el mapa
	self.Advertencias = {}
	self.Conexiones = {}
	self.UltimaPrivacidad = {} -- userId -> os.clock() de su última activación de privacidad
	self.UltimoPrompt = {} -- userId -> os.clock() de su última activación de prompt de puerta
	self.UltimaAuditoria = {} -- userId -> { ["puerta|motivo"] = os.clock() }
	self.Activo = false
	self.Listo = false
	self.EstadoCambiado = Signal.new() -- (puertaId, estado, datosEstado)
end

function DoorService:Start()
	self.Activo = true
	local okConstruir, errConstruir = pcall(function()
		self:ConstruirTodas()
	end)
	if not okConstruir then
		warn(PREFIJO .. " Error al preparar las puertas: " .. tostring(errConstruir))
	end
	self.Listo = true

	-- Remoto DoorAction (RemoteService ya validó esquema, límite y permiso fijo; aquí va la lógica).
	local RemoteService = self:Servicio("RemoteService")
	if RemoteService and typeof(RemoteService.Registrar) == "function" then
		RemoteService:Registrar("DoorAction", function(player, datos)
			return self:ManejarDoorAction(player, datos)
		end, {
			Posicion = function(datos)
				local puerta = typeof(datos) == "table" and typeof(datos.PuertaId) == "string" and self.Puertas[datos.PuertaId] or nil
				if puerta then
					return puerta.Punto
				end
				return nil
			end,
		})
		-- Estados de las puertas en el StateSnapshot (el cliente se resincroniza tras reaparecer).
		if typeof(RemoteService.AportarSnapshot) == "function" then
			pcall(RemoteService.AportarSnapshot, RemoteService, "Puertas", function()
				return self:Snapshot()
			end)
		end
	else
		warn(PREFIJO .. " RemoteService no disponible: DoorAction no tendrá handler (los prompts siguen funcionando).")
	end

	table.insert(self.Conexiones, Players.PlayerRemoving:Connect(function(player)
		self.UltimaPrivacidad[player.UserId] = nil
		self.UltimoPrompt[player.UserId] = nil
		self.UltimaAuditoria[player.UserId] = nil
		-- Si su privacidad seguía activa, se libera enseguida.
		for _, id in ipairs(self.Orden) do
			local puerta = self.Puertas[id]
			if puerta and puerta.Privacidad and puerta.Privacidad.UserId == player.UserId then
				self:LiberarPrivacidad(puerta, "salida")
			end
		end
	end))

	-- Revisión periódica de la privacidad de los baños (caducidad y baño vacío). 1 vez por segundo.
	task.spawn(function()
		while self.Activo do
			task.wait(1)
			local ok, err = pcall(self.RevisarPrivacidad, self)
			if not ok then
				warn(PREFIJO .. " Error revisando la privacidad: " .. tostring(err))
			end
		end
	end)

	local AuditLog = self:Servicio("AuditLogService")
	if AuditLog then
		pcall(AuditLog.Registrar, AuditLog, "Sistema", nil, "Puertas", string.format(
			"%d/%d puertas listas (%d no resueltas, giro %s)", #self.Orden, #self.Orden + #self.NoResueltas,
			#self.NoResueltas, PERMITIR_GIRO and "permitido" or "desactivado"))
	end
	for _, aviso in ipairs(self.Advertencias) do
		warn(PREFIJO .. " " .. aviso)
	end
end

-- Servicio por nombre a través del registro (nil si no existe).
function DoorService:Servicio(nombre)
	local registro = self.registro
	if registro and typeof(registro.Get) == "function" then
		local ok, servicio = pcall(registro.Get, nombre)
		if ok then
			return servicio
		end
	end
	return nil
end

function DoorService:Advertir(texto)
	table.insert(self.Advertencias, tostring(texto))
end

---------------------------------------------------------------------------------------------------
-- Resolución de instancias
---------------------------------------------------------------------------------------------------
local function segmentosDe(ruta)
	local segmentos = {}
	if typeof(ruta) ~= "string" then
		return segmentos
	end
	for parte in string.gmatch(ruta, "[^/]+") do
		table.insert(segmentos, parte)
	end
	return segmentos
end

local function raizDe(primero)
	if primero == "Workspace" or primero == "workspace" then
		return workspace
	end
	if primero == "game" then
		return game
	end
	local ok, servicio = pcall(game.FindFirstChild, game, primero)
	if ok then
		return servicio
	end
	return nil
end

-- Recorre todos los caminos que cumplen la ruta (hay hermanos con el mismo nombre, p. ej. varios "Model").
local function candidatosRuta(actual, segmentos, i, salida, contador, limite)
	if i > #segmentos then
		table.insert(salida, actual)
		return
	end
	local okHijos, hijos = pcall(actual.GetChildren, actual)
	if not okHijos then
		return
	end
	for _, hijo in ipairs(hijos) do
		contador.n = contador.n + 1
		if contador.n > limite then
			return
		end
		if hijo.Name == segmentos[i] then
			candidatosRuta(hijo, segmentos, i + 1, salida, contador, limite)
		end
	end
end

-- Instancia de la puerta: la de MapService si está cerca de Centro; si no, la homónima más cercana a Centro
-- (en el mapa hay nombres repetidos, p. ej. dos "Workspace/Puerta_Infantil").
function DoorService:ResolverInstancia(cfg)
	local deMapa = nil
	local MapService = self:Servicio("MapService")
	if MapService and typeof(MapService.Puerta) == "function" then
		local ok, info = pcall(MapService.Puerta, MapService, cfg.Id)
		if ok and typeof(info) == "table" and typeof(info.Instancia) == "Instance" then
			deMapa = info.Instancia
		end
	end
	local centro = cfg.Centro
	if deMapa then
		if typeof(centro) ~= "Vector3" then
			return deMapa
		end
		local pos = posicionInstancia(deMapa)
		if pos and (pos - centro).Magnitude <= self.MaxDistanciaCentro then
			return deMapa
		end
	end

	local segmentos = segmentosDe(cfg.Ruta)
	if #segmentos == 0 then
		return deMapa
	end
	local raiz = raizDe(segmentos[1])
	if not raiz then
		return deMapa
	end
	local resto = {}
	for i = 2, #segmentos do
		table.insert(resto, segmentos[i])
	end
	local candidatos = {}
	if #resto == 0 then
		table.insert(candidatos, raiz)
	else
		candidatosRuta(raiz, resto, 1, candidatos, { n = 0 }, self.VisitasMaxRuta)
	end
	if #candidatos == 0 then
		return deMapa
	end
	if typeof(centro) ~= "Vector3" then
		return candidatos[1]
	end
	local mejor, mejorDist = nil, math.huge
	for _, candidato in ipairs(candidatos) do
		local pos = posicionInstancia(candidato)
		if pos then
			local d = (pos - centro).Magnitude
			if d < mejorDist then
				mejor, mejorDist = candidato, d
			end
		end
	end
	if mejor and deMapa and mejor ~= deMapa then
		self:Advertir("Puerta " .. tostring(cfg.Id) .. ": la ruta " .. tostring(cfg.Ruta) .. " tiene homónimos; se usa la instancia a "
			.. string.format("%.1f", mejorDist) .. " studs de Centro.")
	end
	return mejor or deMapa
end

-- Raíces de la hoja (BasePart o Model), lista de BaseParts de la hoja y parte principal.
-- Orden: Hoja de MapaLogico > contenedores con "hoja" en el nombre (portón) > BasePart con "hoja" > mayor volumen
-- que no sea marco > mayor volumen. Si la puerta es un Model, se añaden las piezas pegadas a la hoja principal.
function DoorService:ResolverHojas(instancia, cfg)
	local raices = {}
	if typeof(cfg.Hoja) == "string" and cfg.Hoja ~= "" and not instancia:IsA("BasePart") then
		local hoja = instancia:FindFirstChild(cfg.Hoja) or instancia:FindFirstChild(cfg.Hoja, true)
		if hoja and (hoja:IsA("BasePart") or hoja:IsA("Model") or hoja:IsA("Folder")) then
			table.insert(raices, hoja)
		else
			self:Advertir("Puerta " .. tostring(cfg.Id) .. ": no se encontró la hoja '" .. cfg.Hoja .. "'; se detecta automáticamente.")
		end
	end

	local descendientes = {}
	if not instancia:IsA("BasePart") or #raices == 0 then
		local okD, lista = pcall(instancia.GetDescendants, instancia)
		if okD then
			descendientes = lista
		end
	end

	if #raices == 0 then
		if instancia:IsA("BasePart") then
			table.insert(raices, instancia)
		else
			-- Contenedores "Hoja_Izquierda" / "Hoja_Derecha" (portón de dos hojas).
			local contenedores = {}
			for _, d in ipairs(descendientes) do
				if (d:IsA("Model") or d:IsA("Folder")) and contieneHoja(d.Name) then
					table.insert(contenedores, d)
				end
			end
			for _, c in ipairs(contenedores) do
				local anidado = false
				for _, otro in ipairs(contenedores) do
					if otro ~= c and c:IsDescendantOf(otro) then
						anidado = true
						break
					end
				end
				if not anidado and c:FindFirstChildWhichIsA("BasePart", true) then
					table.insert(raices, c)
				end
			end
			if #raices == 0 then
				local conNombre, volNombre = nil, -1
				local sinMarco, volSinMarco = nil, -1
				local cualquiera, volCualquiera = nil, -1
				for _, d in ipairs(descendientes) do
					if d:IsA("BasePart") and not esAsiento(d) then
						local v = volumen(d)
						if contieneHoja(d.Name) and v > volNombre then
							conNombre, volNombre = d, v
						end
						if not esMarco(d.Name) and v > volSinMarco then
							sinMarco, volSinMarco = d, v
						end
						if v > volCualquiera then
							cualquiera, volCualquiera = d, v
						end
					end
				end
				local elegida = conNombre or sinMarco or cualquiera
				if elegida then
					table.insert(raices, elegida)
				end
			end
		end
	end

	local partes, vistos = {}, {}
	local function agregar(parte)
		if not vistos[parte] and not esAsiento(parte) then
			vistos[parte] = true
			table.insert(partes, parte)
		end
	end
	for _, raiz in ipairs(raices) do
		if raiz:IsA("BasePart") then
			agregar(raiz)
		end
		local okR, lista = pcall(raiz.GetDescendants, raiz)
		if okR then
			for _, d in ipairs(lista) do
				if d:IsA("BasePart") then
					agregar(d)
				end
			end
		end
	end

	-- Principal: la raíz si es una BasePart; si no, la BasePart de mayor volumen de las hojas.
	local principal = nil
	if raices[1] and raices[1]:IsA("BasePart") then
		principal = raices[1]
	else
		local mejorVol = -1
		for _, parte in ipairs(partes) do
			local v = volumen(parte)
			if v > mejorVol then
				principal, mejorVol = parte, v
			end
		end
	end

	-- Piezas pegadas a la hoja principal (pomos, paneles en relieve, cerraduras) dentro del mismo modelo.
	if principal and #raices == 1 and raices[1] == principal and not instancia:IsA("BasePart") then
		local _, _, iFino = clasificarEjes(principal)
		local cf, s = principal.CFrame, principal.Size
		local tam = { s.X, s.Y, s.Z }
		local margenes = { self.MargenPlano, self.MargenPlano, self.MargenPlano }
		margenes[iFino] = self.MargenGrosor
		local volPrincipal = volumen(principal)
		for _, d in ipairs(descendientes) do
			if d:IsA("BasePart") and not vistos[d] and not esAsiento(d) and not esMarco(d.Name) and volumen(d) <= volPrincipal then
				local rel = cf:PointToObjectSpace(d.Position)
				local r = { rel.X, rel.Y, rel.Z }
				local dentro = true
				for i = 1, 3 do
					if math.abs(r[i]) > tam[i] / 2 + margenes[i] then
						dentro = false
					end
				end
				if dentro then
					agregar(d)
				end
			end
		end
	end
	return raices, partes, principal
end

---------------------------------------------------------------------------------------------------
-- Construcción de cada puerta
---------------------------------------------------------------------------------------------------
function DoorService:ConstruirTodas()
	local ids = MapaLogico.OrdenPuertas
	if typeof(ids) ~= "table" or #ids == 0 then
		ids = {}
		for id in pairs(MapaLogico.Puertas or {}) do
			table.insert(ids, id)
		end
		table.sort(ids)
	end
	for _, id in ipairs(ids) do
		local cfg = MapaLogico.Puertas and MapaLogico.Puertas[id]
		if typeof(cfg) == "table" then
			local ok, resultado = pcall(self.ConstruirPuerta, self, id, cfg)
			if ok and resultado then
				self.Puertas[id] = resultado
				table.insert(self.Orden, id)
			else
				table.insert(self.NoResueltas, id)
				if not ok then
					self:Advertir("Puerta " .. id .. " con error: " .. tostring(resultado))
				end
			end
		end
	end
end

-- Nombre visible en el prompt.
local function nombreVisible(cfg, zona)
	if cfg.Modo == "privacidad" then
		return "Baño"
	end
	if string.find(string.lower(tostring(cfg.Id)), "porton", 1, true) then
		return "Portón principal"
	end
	if zona and typeof(zona.Nombre) == "string" and (utf8.len(zona.Nombre) or #zona.Nombre) <= 24 then
		return "Puerta · " .. zona.Nombre
	end
	return "Puerta " .. tostring(cfg.Zona or cfg.Id)
end

local function nuevoPrompt(padre, nombre, props, atributos)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = nombre
	prompt.ActionText = props.ActionText or "Usar"
	prompt.ObjectText = props.ObjectText or ""
	prompt.HoldDuration = props.HoldDuration or 0
	prompt.MaxActivationDistance = props.MaxActivationDistance or 8
	prompt.RequiresLineOfSight = false
	prompt.ClickablePrompt = true
	if props.KeyboardKeyCode then
		pcall(function()
			prompt.KeyboardKeyCode = props.KeyboardKeyCode
		end)
	end
	if props.GamepadKeyCode then
		pcall(function()
			prompt.GamepadKeyCode = props.GamepadKeyCode
		end)
	end
	if props.UIOffset then
		pcall(function()
			prompt.UIOffset = props.UIOffset
		end)
	end
	for clave, valor in pairs(atributos or {}) do
		pcall(prompt.SetAttribute, prompt, clave, valor)
	end
	prompt.Parent = padre
	return prompt
end

function DoorService:ConstruirPuerta(id, cfg)
	local instancia = self:ResolverInstancia(cfg)
	if not instancia then
		self:Advertir("Puerta " .. id .. " no encontrada en el mapa: " .. tostring(cfg.Ruta))
		return nil
	end
	local raices, partes, principal = self:ResolverHojas(instancia, cfg)
	if not principal or #partes == 0 then
		self:Advertir("Puerta " .. id .. ": no se encontró ninguna pieza que sirva de hoja en " .. tostring(cfg.Ruta))
		return nil
	end
	local zona = Zones.Zona(cfg.Zona)
	if not zona then
		self:Advertir("Puerta " .. id .. ": la zona '" .. tostring(cfg.Zona) .. "' no existe en MapaLogico (dentro/fuera por la normal).")
	end

	-- Valores originales de cada pieza de la hoja.
	local registros = {}
	local principales = {}
	principales[principal] = true
	for _, parte in ipairs(partes) do
		local okLeer, rec = pcall(function()
			return {
				Parte = parte,
				Transparency = parte.Transparency,
				CanCollide = parte.CanCollide,
				CFrame = parte.CFrame,
				Anchored = parte.Anchored,
				Principal = principales[parte] == true,
			}
		end)
		if okLeer and rec then
			table.insert(registros, rec)
		end
	end

	-- Geometría: centro (caja alineada a los ejes de todas las piezas), normal y eje de anchura de la hoja.
	local minV, maxV = nil, nil
	for _, rec in ipairs(registros) do
		local cf, s = rec.CFrame, rec.Parte.Size
		local ex = extension(cf, s, Vector3.new(1, 0, 0)) / 2
		local ey = extension(cf, s, Vector3.new(0, 1, 0)) / 2
		local ez = extension(cf, s, Vector3.new(0, 0, 1)) / 2
		local p = cf.Position
		local a = Vector3.new(p.X - ex, p.Y - ey, p.Z - ez)
		local b = Vector3.new(p.X + ex, p.Y + ey, p.Z + ez)
		if minV == nil then
			minV, maxV = a, b
		else
			minV = Vector3.new(math.min(minV.X, a.X), math.min(minV.Y, a.Y), math.min(minV.Z, a.Z))
			maxV = Vector3.new(math.max(maxV.X, b.X), math.max(maxV.Y, b.Y), math.max(maxV.Z, b.Z))
		end
	end
	local punto = (minV + maxV) / 2
	local ejes, _, iFino, iAncho = clasificarEjes(principal)
	local normal = unitarioPlano(ejes[iFino][1])
	local ejeAncho = unitarioPlano(ejes[iAncho][1])
	if not normal and zona then
		normal = unitarioPlano(zona.Centro - punto)
	end
	if not normal then
		normal = Vector3.new(0, 0, 1)
	end
	if not ejeAncho then
		ejeAncho = Vector3.new(normal.Z, 0, -normal.X)
	end
	local minW, maxW = math.huge, -math.huge
	for _, rec in ipairs(registros) do
		local centro = rec.CFrame.Position:Dot(ejeAncho)
		local medio = extension(rec.CFrame, rec.Parte.Size, ejeAncho) / 2
		minW = math.min(minW, centro - medio)
		maxW = math.max(maxW, centro + medio)
	end
	local proyPunto = punto:Dot(ejeAncho)

	-- Referencia "dentro": inodoro/urinario más cercano (cubículos de baño) o el centro de la zona.
	local modo = cfg.Modo
	if modo ~= "privacidad" and modo ~= "giro" then
		modo = "estado"
	end
	local referencia = zona and zona.Centro or nil
	if modo == "privacidad" and zona and typeof(zona.Objetos) == "table" then
		local mejor, mejorDist = nil, self.DistanciaReferenciaBano
		for _, clave in ipairs({ "Inodoros", "Urinarios" }) do
			local lista = zona.Objetos[clave]
			if typeof(lista) == "table" then
				for _, p in ipairs(lista) do
					if typeof(p) == "Vector3" then
						local d = plano(p - punto).Magnitude
						if d < mejorDist then
							mejor, mejorDist = p, d
						end
					end
				end
			end
		end
		if mejor then
			referencia = mejor
		end
	end

	local cargosSet, cargosTexto = conjuntoCargos(cfg.CargosBloqueo)
	local permiso = "puertas.oficinas"
	if zona and TIPOS_AULA[zona.Tipo] then
		permiso = "puertas.aulas"
	end

	local puerta = {
		Id = id,
		Config = cfg,
		Modo = modo,
		ModoEfectivo = "estado",
		Zona = cfg.Zona,
		ZonaDef = zona,
		Instancia = instancia,
		Raices = raices,
		Partes = registros,
		Principal = principal,
		Punto = punto,
		Normal = normal,
		EjeAncho = ejeAncho,
		MedioAncho = math.max(0.5, (maxW - minW) / 2),
		Referencia = referencia,
		CargosBloqueo = cargosSet,
		CargosTexto = cargosTexto,
		PermisoBloqueo = permiso,
		NombreVisible = nombreVisible(cfg, zona),
		Abierta = true,
		Cerrojo = false,
		Fijada = false,
		Privacidad = nil,
		VisualOriginal = true,
		UltimaAccion = -math.huge,
		TokenCierre = 0,
		Usos = 0,
	}

	-- Modo giro (opcional): bisagra en la arista vertical de la hoja; si algo falta, se queda en "estado".
	if modo == "giro" then
		if PERMITIR_GIRO and typeof(cfg.Hoja) == "string" and cfg.Hoja ~= "" then
			local okGiro, errGiro = pcall(function()
				self:PrepararGiro(puerta, minW, maxW, proyPunto)
			end)
			if not okGiro then
				self:Advertir("Puerta " .. id .. ": giro no disponible (" .. tostring(errGiro) .. "); se usa el modo estado.")
				puerta.Giro = nil
			end
			if puerta.Giro then
				puerta.ModoEfectivo = "giro"
			end
		end
		puerta.Modo = "estado"
		if puerta.ModoEfectivo == "giro" then
			puerta.Modo = "giro"
		end
	end

	self:CrearInstanciasPropias(puerta)
	self:MarcarHojas(puerta)
	self:AplicarVisual(puerta)
	self:ActualizarAtributos(puerta)
	self:ActualizarPrompts(puerta)
	return puerta
end

-- Calcula el pivote (arista de la bisagra) y el ángulo de apertura (hacia dentro).
function DoorService:PrepararGiro(puerta, minW, maxW, proyPunto)
	for _, rec in ipairs(puerta.Partes) do
		if not rec.Anchored then
			error("la hoja tiene piezas sin anclar")
		end
	end
	local eje = puerta.EjeAncho
	local base = puerta.Punto - eje * proyPunto
	local aristaA = base + eje * minW
	local aristaB = base + eje * maxW
	aristaA = Vector3.new(aristaA.X, puerta.Punto.Y, aristaA.Z)
	aristaB = Vector3.new(aristaB.X, puerta.Punto.Y, aristaB.Z)

	-- 1) Bisagras del modelo; 2) extremo más cercano al centro del modelo padre (regla del contrato).
	local objetivo = nil
	local suma, n = Vector3.new(0, 0, 0), 0
	local okD, lista = pcall(puerta.Instancia.GetDescendants, puerta.Instancia)
	if okD then
		for _, d in ipairs(lista) do
			if d:IsA("BasePart") and string.find(string.lower(d.Name), "bisagra", 1, true) then
				suma = suma + d.Position
				n = n + 1
			end
		end
	end
	if n > 0 then
		objetivo = suma / n
	else
		local padre = puerta.Instancia
		if padre == puerta.Principal then
			padre = puerta.Principal.Parent
		end
		if padre and padre ~= workspace then
			objetivo = posicionInstancia(padre)
		end
	end
	local arista = aristaA
	if objetivo and plano(aristaB - objetivo).Magnitude < plano(aristaA - objetivo).Magnitude then
		arista = aristaB
	end
	local pivote = CFrame.new(arista)
	local angulo = math.rad(self.AnguloGiro)
	-- Sentido: la hoja gira hacia el lado de la referencia (dentro del aula/cubículo).
	local signo = 1
	if puerta.Referencia then
		local dr = plano(puerta.Referencia - puerta.Punto):Dot(puerta.Normal)
		local cMas = (pivote * CFrame.Angles(0, angulo, 0) * pivote:Inverse()) * puerta.Punto
		local cMenos = (pivote * CFrame.Angles(0, -angulo, 0) * pivote:Inverse()) * puerta.Punto
		local dMas = plano(cMas - puerta.Punto):Dot(puerta.Normal)
		local dMenos = plano(cMenos - puerta.Punto):Dot(puerta.Normal)
		if (dr >= 0 and dMenos > dMas) or (dr < 0 and dMenos < dMas) then
			signo = -1
		end
	end
	puerta.Giro = { Pivote = pivote, Angulo = angulo * signo }
end

-- Attachment propio en la hoja (centro de la puerta) con los prompts y el sonido.
function DoorService:CrearInstanciasPropias(puerta)
	local principal = puerta.Principal
	local ancla = Instance.new("Attachment")
	ancla.Name = "ColegioRP_Puerta"
	ancla.Position = principal.CFrame:PointToObjectSpace(puerta.Punto)
	ancla.Parent = principal
	puerta.Ancla = ancla

	local zonaId = typeof(puerta.Zona) == "string" and puerta.Zona or ""
	puerta.Prompt = nuevoPrompt(ancla, "ColegioRP_PromptPuerta", {
		ActionText = "Cerrar",
		ObjectText = puerta.NombreVisible,
		HoldDuration = 0,
		MaxActivationDistance = self.DistanciaPrompt,
	}, {
		RPTipo = "Puerta", RPId = puerta.Id, RPAccion = "Alternar", RPZona = zonaId,
	})
	pcall(CollectionService.AddTag, CollectionService, puerta.Prompt, self.TagPrompt)
	table.insert(self.Conexiones, puerta.Prompt.Triggered:Connect(function(player)
		self:AlActivarPrompt(puerta, "Alternar", player)
	end))

	if puerta.Modo == "privacidad" then
		puerta.PromptPrivacidad = nuevoPrompt(ancla, "ColegioRP_PromptPrivacidad", {
			ActionText = "Privacidad",
			ObjectText = "Baño",
			HoldDuration = self.HoldBloqueo,
			MaxActivationDistance = self.DistanciaPrompt,
			KeyboardKeyCode = Enum.KeyCode.R,
			GamepadKeyCode = Enum.KeyCode.ButtonY,
			UIOffset = Vector2.new(0, 64),
		}, {
			RPTipo = "Puerta", RPId = puerta.Id, RPAccion = "Privacidad", RPZona = zonaId,
			RPPunto = puerta.Punto, RPNormal = puerta.Normal, RPReferencia = puerta.Referencia or puerta.Punto,
		})
		pcall(CollectionService.AddTag, CollectionService, puerta.PromptPrivacidad, self.TagPromptPrivacidad)
		table.insert(self.Conexiones, puerta.PromptPrivacidad.Triggered:Connect(function(player)
			self:AlActivarPrompt(puerta, "Privacidad", player)
		end))
	end

	puerta.PromptBloqueo = nuevoPrompt(ancla, "ColegioRP_PromptBloqueo", {
		ActionText = "Bloquear",
		ObjectText = "Personal autorizado",
		HoldDuration = self.HoldBloqueo,
		MaxActivationDistance = self.DistanciaPrompt,
		KeyboardKeyCode = Enum.KeyCode.G,
		GamepadKeyCode = Enum.KeyCode.ButtonR1,
		UIOffset = Vector2.new(0, 128),
	}, {
		RPTipo = "Puerta", RPId = puerta.Id, RPAccion = "Bloqueo", RPZona = zonaId,
		RPCargos = puerta.CargosTexto, RPPermiso = puerta.PermisoBloqueo,
	})
	pcall(CollectionService.AddTag, CollectionService, puerta.PromptBloqueo, self.TagPromptBloqueo)
	table.insert(self.Conexiones, puerta.PromptBloqueo.Triggered:Connect(function(player)
		self:AlActivarPrompt(puerta, "Bloqueo", player)
	end))

	if SONIDO_ID > 0 then
		pcall(function()
			local sonido = Instance.new("Sound")
			sonido.Name = "ColegioRP_SonidoPuerta"
			sonido.SoundId = "rbxassetid://" .. tostring(math.floor(SONIDO_ID))
			sonido.Volume = 0.6
			sonido.RollOffMaxDistance = 45
			sonido.Parent = ancla
			puerta.Sonido = sonido
		end)
	end
end

-- Tag y atributo PuertaId en las hojas (vía MapService para que su Limpiar los retire; si no, directo).
function DoorService:MarcarHojas(puerta)
	local MapService = self:Servicio("MapService")
	local marcarTag = MapService and typeof(MapService.MarcarTag) == "function"
	local marcarAtributo = MapService and typeof(MapService.MarcarAtributo) == "function"
	local destinos = {}
	local vistos = {}
	for _, raiz in ipairs(puerta.Raices) do
		if not vistos[raiz] then
			vistos[raiz] = true
			table.insert(destinos, raiz)
		end
	end
	if not vistos[puerta.Principal] then
		table.insert(destinos, puerta.Principal)
	end
	puerta.Marcadas = destinos
	for _, destino in ipairs(destinos) do
		if marcarTag then
			pcall(MapService.MarcarTag, MapService, destino, TAG_HOJA)
		else
			pcall(CollectionService.AddTag, CollectionService, destino, TAG_HOJA)
		end
		for _, nombre in ipairs({ "PuertaId", "Estado", "Bloqueada", "Fijada" }) do
			local valor = nil
			if nombre == "PuertaId" then
				valor = puerta.Id
			end
			if marcarAtributo then
				pcall(MapService.MarcarAtributo, MapService, destino, nombre, valor)
			else
				pcall(destino.SetAttribute, destino, nombre, valor)
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Estado visual y textos
---------------------------------------------------------------------------------------------------
function DoorService:EstadoTexto(puerta)
	if puerta.Privacidad then
		return "Privada"
	end
	if puerta.Abierta then
		return "Abierta"
	end
	if puerta.Cerrojo then
		return "Bloqueada"
	end
	return "Cerrada"
end

-- Aplica Transparency / CanCollide (y CFrame en modo giro) según el estado. Nunca toca los marcos.
function DoorService:AplicarVisual(puerta)
	if puerta.ModoEfectivo == "giro" and puerta.Giro then
		local okGiro, errGiro = pcall(function()
			local info = TweenInfo.new(self.DuracionGiro, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			local rotar = puerta.Abierta and not puerta.VisualOriginal
			local transformacion = puerta.Giro.Pivote * CFrame.Angles(0, puerta.Giro.Angulo, 0) * puerta.Giro.Pivote:Inverse()
			for _, rec in ipairs(puerta.Partes) do
				local destino = rec.CFrame
				if rotar then
					destino = transformacion * rec.CFrame
				end
				TweenService:Create(rec.Parte, info, { CFrame = destino }):Play()
			end
		end)
		if not okGiro then
			warn(PREFIJO .. " Puerta " .. puerta.Id .. ": el giro falló (" .. tostring(errGiro) .. "); se pasa al modo estado.")
			puerta.ModoEfectivo = "estado"
			puerta.Modo = "estado"
			for _, rec in ipairs(puerta.Partes) do
				pcall(function()
					rec.Parte.CFrame = rec.CFrame
				end)
			end
		end
	end
	local usarTransparencia = puerta.ModoEfectivo == "estado" and puerta.Abierta and not puerta.VisualOriginal
	for _, rec in ipairs(puerta.Partes) do
		pcall(function()
			if puerta.Abierta then
				if usarTransparencia then
					rec.Parte.Transparency = math.max(rec.Transparency, self.TransparenciaAbierta)
				else
					rec.Parte.Transparency = rec.Transparency
				end
				rec.Parte.CanCollide = false
			else
				rec.Parte.Transparency = rec.Transparency
				rec.Parte.CanCollide = rec.CanCollide or rec.Principal
			end
		end)
	end
end

function DoorService:ActualizarAtributos(puerta)
	local estado = self:EstadoTexto(puerta)
	local bloqueada = puerta.Cerrojo or puerta.Fijada
	for _, destino in ipairs(puerta.Marcadas or {}) do
		pcall(destino.SetAttribute, destino, "Estado", estado)
		pcall(destino.SetAttribute, destino, "Bloqueada", bloqueada)
		pcall(destino.SetAttribute, destino, "Fijada", puerta.Fijada)
	end
	if puerta.Prompt then
		pcall(puerta.Prompt.SetAttribute, puerta.Prompt, "Estado", estado)
		pcall(puerta.Prompt.SetAttribute, puerta.Prompt, "Bloqueada", bloqueada)
		pcall(puerta.Prompt.SetAttribute, puerta.Prompt, "Fijada", puerta.Fijada)
	end
end

function DoorService:ActualizarPrompts(puerta)
	pcall(function()
		local prompt = puerta.Prompt
		if prompt then
			local estado = self:EstadoTexto(puerta)
			if estado == "Abierta" then
				prompt.ActionText = "Cerrar"
			elseif estado == "Cerrada" then
				prompt.ActionText = "Abrir"
			else
				prompt.ActionText = "Bloqueada"
			end
			local objeto = puerta.NombreVisible
			if estado == "Privada" then
				objeto = "Baño ocupado"
			elseif estado == "Bloqueada" then
				objeto = puerta.NombreVisible .. " · solo salida"
			elseif puerta.Fijada then
				objeto = puerta.NombreVisible .. " · fijada abierta"
			end
			prompt.ObjectText = objeto
		end
		if puerta.PromptBloqueo then
			if puerta.Cerrojo or puerta.Fijada then
				puerta.PromptBloqueo.ActionText = "Desbloquear"
			elseif puerta.Abierta then
				puerta.PromptBloqueo.ActionText = "Fijar abierta"
			else
				puerta.PromptBloqueo.ActionText = "Bloquear"
			end
		end
		if puerta.PromptPrivacidad then
			if puerta.Privacidad then
				puerta.PromptPrivacidad.ActionText = "Quitar privacidad"
			else
				puerta.PromptPrivacidad.ActionText = "Privacidad (" .. tostring(math.floor(PRIVACIDAD_SEG)) .. " s)"
			end
		end
	end)
end

function DoorService:Sonar(puerta)
	if puerta.Sonido then
		pcall(function()
			puerta.Sonido:Play()
		end)
	end
end

---------------------------------------------------------------------------------------------------
-- Reglas: dentro/fuera, permisos, umbral
---------------------------------------------------------------------------------------------------

-- ¿La posición está "dentro" respecto a la puerta? Lado del plano de la hoja donde está la referencia (centro de la
-- zona o inodoro del cubículo); en el umbral siempre cuenta como dentro (nunca se encierra a nadie).
function DoorService:EsDentro(puerta, posicion)
	if typeof(posicion) ~= "Vector3" then
		return false
	end
	local rel = plano(posicion - puerta.Punto)
	local dp = rel:Dot(puerta.Normal)
	local lateral = math.abs(rel:Dot(puerta.EjeAncho))
	if math.abs(dp) < 0.75 and lateral <= puerta.MedioAncho + 1 then
		return true
	end
	local zona = puerta.ZonaDef
	local dentroPlano = false
	if puerta.Referencia then
		local dr = plano(puerta.Referencia - puerta.Punto):Dot(puerta.Normal)
		if math.abs(dr) >= 0.5 then
			dentroPlano = (dp > 0) == (dr > 0)
		elseif zona then
			dentroPlano = Zones.Contiene(zona, posicion)
		end
	elseif zona then
		dentroPlano = Zones.Contiene(zona, posicion)
	end
	if dentroPlano then
		return true
	end
	-- Puertas de aula con la hoja girada (abierta en el mapa): dentro de la caja de la zona y más hacia su centro.
	if puerta.Modo ~= "privacidad" and zona and Zones.Contiene(zona, posicion) then
		local dJugador = plano(posicion - zona.Centro).Magnitude
		local dPuerta = plano(puerta.Punto - zona.Centro).Magnitude
		if dJugador + 1 < dPuerta then
			return true
		end
	end
	return false
end

-- ¿El jugador puede bloquear/desbloquear? Cargo en CargosBloqueo o permiso puertas.aulas / puertas.oficinas.
function DoorService:PuedeBloquear(player, puerta)
	local RoleService = self:Servicio("RoleService")
	if not RoleService then
		return false
	end
	if typeof(RoleService.Cargo) == "function" then
		local ok, cargo = pcall(RoleService.Cargo, RoleService, player)
		if ok and typeof(cargo) == "string" and puerta.CargosBloqueo[cargo] then
			return true
		end
	end
	if typeof(RoleService.Tiene) == "function" then
		local ok, tiene = pcall(RoleService.Tiene, RoleService, player, puerta.PermisoBloqueo)
		if ok and tiene == true then
			return true
		end
	end
	return false
end

-- ¿Hay algún jugador en el umbral? (el autocierre espera para no empujar a nadie)
function DoorService:HayAlguienEnUmbral(puerta)
	for _, player in ipairs(Players:GetPlayers()) do
		local pos = posicionJugador(player)
		if pos then
			local rel = pos - puerta.Punto
			if math.abs(rel.Y) <= 8 then
				local h = plano(rel)
				if math.abs(h:Dot(puerta.Normal)) <= self.UmbralGrosor and math.abs(h:Dot(puerta.EjeAncho)) <= puerta.MedioAncho + 1 then
					return true
				end
			end
		end
	end
	return false
end

---------------------------------------------------------------------------------------------------
-- Acciones (misma lógica para prompts, remoto y otros servicios)
---------------------------------------------------------------------------------------------------

-- Abre o cierra físicamente (sin comprobar reglas).
function DoorService:CambiarApertura(puerta, abierta)
	if puerta.Abierta == abierta then
		return
	end
	puerta.Abierta = abierta
	puerta.TokenCierre = puerta.TokenCierre + 1
	if not abierta then
		puerta.VisualOriginal = false
	end
	self:AplicarVisual(puerta)
	self:Sonar(puerta)
end

function DoorService:ProgramarAutocierre(puerta)
	if AUTOCIERRE_SEG <= 0 or puerta.Fijada then
		return
	end
	puerta.TokenCierre = puerta.TokenCierre + 1
	local token = puerta.TokenCierre
	task.delay(AUTOCIERRE_SEG, function()
		self:IntentarAutocierre(puerta, token)
	end)
end

function DoorService:IntentarAutocierre(puerta, token)
	if not self.Activo or puerta.TokenCierre ~= token or not puerta.Abierta or puerta.Fijada then
		return
	end
	if self:HayAlguienEnUmbral(puerta) then
		task.delay(self.ReintentoAutocierreSeg, function()
			self:IntentarAutocierre(puerta, token)
		end)
		return
	end
	self:CambiarApertura(puerta, false)
	self:Publicar(puerta, nil, "Autocierre")
end

-- Ejecuta una acción. player = nil para acciones del sistema (sin distancia, cooldown ni permisos).
-- Devuelve ok, mensaje, codigo ("ok" | "sin_cambio" | motivo de rechazo).
function DoorService:Accion(player, puertaId, accion, origen)
	local puerta = typeof(puertaId) == "string" and self.Puertas[puertaId] or nil
	if not puerta then
		return false, "Esa puerta no está disponible.", "puerta_inexistente"
	end
	if typeof(accion) ~= "string" or not ACCIONES[accion] then
		return false, "Acción no válida.", "accion_invalida"
	end
	local ahora = os.clock()
	local dentro = true
	local autorizado = true
	if player ~= nil then
		if not esJugador(player) then
			return false, "Jugador no válido.", "jugador_invalido"
		end
		local pos = posicionJugador(player)
		if not pos then
			return false, "Necesitas tu personaje para usar la puerta.", "sin_personaje"
		end
		if (pos - puerta.Punto).Magnitude > DISTANCIA_MAX + self.ToleranciaDistancia then
			return false, "Acércate más a la puerta.", "distancia"
		end
		if ahora - puerta.UltimaAccion < COOLDOWN_SEG then
			return false, "Espera un momento.", "cooldown"
		end
		dentro = self:EsDentro(puerta, pos)
		autorizado = self:PuedeBloquear(player, puerta)
	end

	local mensaje = nil
	if accion == "Abrir" then
		if puerta.Abierta then
			return true, "La puerta ya está abierta.", "sin_cambio"
		end
		if puerta.Privacidad and not dentro then
			return false, "El baño está ocupado. Espera un momento.", "ocupado"
		end
		if puerta.Cerrojo and not dentro and not autorizado then
			return false, "La puerta está bloqueada: solo se abre desde dentro o por el personal autorizado.", "bloqueada"
		end
		puerta.Privacidad = nil
		self:CambiarApertura(puerta, true)
		self:ProgramarAutocierre(puerta)
	elseif accion == "Cerrar" then
		if not puerta.Abierta then
			return true, "La puerta ya está cerrada.", "sin_cambio"
		end
		if puerta.Fijada and not autorizado then
			return false, "El personal dejó esta puerta fijada abierta.", "fijada"
		end
		if puerta.Fijada then
			-- El personal cierra una puerta fijada: queda cerrada y bloqueada contra la entrada.
			puerta.Fijada = false
			puerta.Cerrojo = true
		end
		self:CambiarApertura(puerta, false)
	elseif accion == "Bloquear" then
		if not autorizado then
			return false, "No tienes permiso para bloquear esta puerta.", "sin_permiso_bloqueo"
		end
		if puerta.Cerrojo or puerta.Fijada then
			return true, "La puerta ya está bloqueada.", "sin_cambio"
		end
		if puerta.Abierta then
			puerta.Fijada = true
			puerta.TokenCierre = puerta.TokenCierre + 1 -- cancela el autocierre pendiente
			mensaje = "Puerta fijada abierta (sin cierre automático)."
		else
			puerta.Cerrojo = true
			mensaje = "Puerta bloqueada: desde dentro siempre se puede salir."
		end
	elseif accion == "Desbloquear" then
		if not autorizado then
			return false, "No tienes permiso para desbloquear esta puerta.", "sin_permiso_bloqueo"
		end
		if not puerta.Cerrojo and not puerta.Fijada then
			return true, "La puerta no estaba bloqueada.", "sin_cambio"
		end
		local estabaFijada = puerta.Fijada
		puerta.Cerrojo = false
		puerta.Fijada = false
		if puerta.Abierta and estabaFijada then
			self:ProgramarAutocierre(puerta)
		end
		mensaje = "Puerta desbloqueada."
	elseif accion == "Privacidad" then
		if puerta.Modo ~= "privacidad" then
			return false, "Esta puerta no tiene modo privacidad.", "sin_privacidad"
		end
		if player == nil then
			if puerta.Privacidad then
				puerta.Privacidad = nil
				mensaje = "Privacidad desactivada."
			else
				return true, "Sin cambios.", "sin_cambio"
			end
		elseif not dentro then
			return false, "La privacidad solo se activa desde dentro del baño.", "fuera"
		elseif puerta.Privacidad then
			puerta.Privacidad = nil
			mensaje = "Privacidad desactivada."
		else
			local ultima = self.UltimaPrivacidad[player.UserId]
			if ultima and ahora - ultima < self.CooldownPrivacidadJugador then
				return false, "Espera unos segundos para volver a activar la privacidad.", "cooldown"
			end
			self.UltimaPrivacidad[player.UserId] = ahora
			if puerta.Abierta then
				self:CambiarApertura(puerta, false)
			end
			puerta.Privacidad = {
				Hasta = ahora + PRIVACIDAD_SEG,
				HastaServidor = ahoraServidor() + PRIVACIDAD_SEG,
				UserId = player.UserId,
				VacioDesde = nil,
			}
			mensaje = "Privacidad activada durante " .. tostring(math.floor(PRIVACIDAD_SEG)) .. " s."
		end
	end

	puerta.UltimaAccion = ahora
	puerta.Usos = puerta.Usos + 1
	self:Publicar(puerta, player, accion)
	if accion == "Bloquear" or accion == "Desbloquear" then
		local AuditLog = self:Servicio("AuditLogService")
		if AuditLog then
			pcall(AuditLog.Registrar, AuditLog, "Sistema", player, "Puerta", puerta.Id .. " " .. accion .. " (" .. tostring(origen or "Sistema") .. ")")
		end
	end
	return true, mensaje, "ok"
end

-- Prompt físico activado (el evento llega al servidor con el jugador).
function DoorService:AlActivarPrompt(puerta, tipo, player)
	if not self.Activo or not esJugador(player) then
		return
	end
	local ahora = os.clock()
	local ultimo = self.UltimoPrompt[player.UserId]
	if ultimo and ahora - ultimo < self.IntervaloPromptSeg then
		return
	end
	self.UltimoPrompt[player.UserId] = ahora
	local accion
	if tipo == "Bloqueo" then
		if puerta.Cerrojo or puerta.Fijada then
			accion = "Desbloquear"
		else
			accion = "Bloquear"
		end
	elseif tipo == "Privacidad" then
		accion = "Privacidad"
	elseif puerta.Abierta then
		accion = "Cerrar"
	else
		accion = "Abrir"
	end
	local ok, mensaje, codigo = self:Accion(player, puerta.Id, accion, "Prompt")
	if not ok then
		self:RegistrarRechazo(player, "Prompt", codigo, puerta.Id, accion)
		self:EnviarMensaje(player, puerta, mensaje, "aviso")
	elseif mensaje and codigo == "ok" and accion ~= "Abrir" and accion ~= "Cerrar" then
		self:EnviarMensaje(player, puerta, mensaje, "exito")
	end
end

-- Handler del remoto DoorAction { PuertaId, Accion }.
function DoorService:ManejarDoorAction(player, datos)
	local puertaId = datos.PuertaId
	local accion = datos.Accion
	local ok, mensaje, codigo = self:Accion(player, puertaId, accion, "Remoto")
	if not ok then
		self:RegistrarRechazo(player, "DoorAction", codigo, puertaId, accion)
		return { ok = false, error = mensaje, datos = { PuertaId = puertaId, Codigo = codigo } }
	end
	local puerta = self.Puertas[puertaId]
	return {
		ok = true,
		datos = {
			PuertaId = puertaId,
			Estado = puerta and self:EstadoTexto(puerta) or nil,
			Mensaje = mensaje,
			Codigo = codigo,
		},
	}
end

function DoorService:RegistrarRechazo(player, origen, codigo, puertaId, accion)
	if not MOTIVOS_AUDITADOS[codigo] then
		return
	end
	-- Un mismo rechazo repetido (p. ej. pulsar sin parar una puerta bloqueada) se audita una vez cada 10 s.
	if esJugador(player) then
		local porJugador = self.UltimaAuditoria[player.UserId]
		if not porJugador then
			porJugador = {}
			self.UltimaAuditoria[player.UserId] = porJugador
		end
		local clave = tostring(puertaId) .. "|" .. tostring(codigo)
		local ahora = os.clock()
		if porJugador[clave] and ahora - porJugador[clave] < self.IntervaloAuditoriaSeg then
			return
		end
		porJugador[clave] = ahora
	end
	local AuditLog = self:Servicio("AuditLogService")
	if AuditLog then
		pcall(AuditLog.Registrar, AuditLog, "Remoto", player, "DoorAction",
			string.format("logica:%s puerta=%s accion=%s origen=%s", tostring(codigo), tostring(puertaId), tostring(accion), tostring(origen)))
	end
	if MOTIVOS_METRICAS[codigo] then
		local Metrics = self:Servicio("MetricsService")
		if Metrics and typeof(Metrics.IncrementarRechazo) == "function" then
			pcall(Metrics.IncrementarRechazo, Metrics, "DoorAction", tostring(codigo))
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Privacidad de baños
---------------------------------------------------------------------------------------------------
function DoorService:LiberarPrivacidad(puerta, motivo)
	local privacidad = puerta.Privacidad
	if not privacidad then
		return
	end
	puerta.Privacidad = nil
	self:Publicar(puerta, nil, "PrivacidadTerminada")
	local dueno = Players:GetPlayerByUserId(privacidad.UserId)
	if dueno and motivo ~= "salida" then
		self:EnviarMensaje(dueno, puerta, "La privacidad del baño terminó.", "info")
	end
end

function DoorService:RevisarPrivacidad()
	local ahora = os.clock()
	for _, id in ipairs(self.Orden) do
		local puerta = self.Puertas[id]
		local privacidad = puerta and puerta.Privacidad
		if privacidad then
			if ahora >= privacidad.Hasta then
				self:LiberarPrivacidad(puerta, "caducidad")
			else
				local alguien = false
				for _, player in ipairs(Players:GetPlayers()) do
					local pos = posicionJugador(player)
					if pos and (pos - puerta.Punto).Magnitude <= DISTANCIA_MAX and self:EsDentro(puerta, pos) then
						alguien = true
						break
					end
				end
				if alguien then
					privacidad.VacioDesde = nil
				elseif privacidad.VacioDesde == nil then
					privacidad.VacioDesde = ahora
				elseif ahora - privacidad.VacioDesde >= self.GraciaVaciaSeg then
					self:LiberarPrivacidad(puerta, "vacio")
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Publicación al cliente
---------------------------------------------------------------------------------------------------
function DoorService:DatosEstado(puerta)
	return {
		PuertaId = puerta.Id,
		Estado = self:EstadoTexto(puerta),
		Abierta = puerta.Abierta,
		Bloqueada = puerta.Cerrojo or puerta.Fijada,
		Fijada = puerta.Fijada,
		Privada = puerta.Privacidad ~= nil,
		PrivadaHasta = puerta.Privacidad and puerta.Privacidad.HastaServidor or nil,
		Zona = puerta.Zona,
		Modo = puerta.Modo,
	}
end

-- Atributos, prompts y evento "Puerta" { Sub = "Estado" } a la zona, a los cercanos y al actor.
function DoorService:Publicar(puerta, actor, accion)
	self:ActualizarAtributos(puerta)
	self:ActualizarPrompts(puerta)
	local datos = self:DatosEstado(puerta)
	datos.Sub = "Estado"
	datos.Accion = accion
	if esJugador(actor) then
		datos.ActorUserId = actor.UserId
	end
	pcall(function()
		self.EstadoCambiado:Fire(puerta.Id, datos.Estado, datos)
	end)
	local RemoteService = self:Servicio("RemoteService")
	if not RemoteService then
		return
	end
	local zona = puerta.ZonaDef
	if zona and typeof(RemoteService.EnviarAZona) == "function" then
		pcall(RemoteService.EnviarAZona, RemoteService, puerta.Zona, "Puerta", datos)
	end
	if typeof(RemoteService.Enviar) ~= "function" then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		local pos = posicionJugador(player)
		local enZona = zona ~= nil and pos ~= nil and Zones.Contiene(zona, pos)
		if not enZona then
			local cerca = pos ~= nil and (pos - puerta.Punto).Magnitude <= self.DistanciaAvisoVecinos
			if cerca or player == actor then
				pcall(RemoteService.Enviar, RemoteService, player, "Puerta", datos)
			end
		end
	end
end

function DoorService:EnviarMensaje(player, puerta, texto, nivel)
	if not esJugador(player) or typeof(texto) ~= "string" or texto == "" then
		return
	end
	local RemoteService = self:Servicio("RemoteService")
	if RemoteService and typeof(RemoteService.Enviar) == "function" then
		pcall(RemoteService.Enviar, RemoteService, player, "Puerta", {
			Sub = "Mensaje", PuertaId = puerta and puerta.Id or nil, Texto = texto, Nivel = nivel or "info",
		})
	end
end

---------------------------------------------------------------------------------------------------
-- API para otros servicios
---------------------------------------------------------------------------------------------------

-- Estado de una puerta (tabla serializable) o, sin id, de todas { [puertaId] = estado }.
function DoorService:Estado(puertaId)
	if puertaId == nil then
		local todas = {}
		for _, id in ipairs(self.Orden) do
			todas[id] = self:DatosEstado(self.Puertas[id])
		end
		return todas
	end
	local puerta = self.Puertas[puertaId]
	if not puerta then
		return nil
	end
	return self:DatosEstado(puerta)
end

-- Resumen compacto para StateSnapshot: { [puertaId] = { Estado, Bloqueada, Fijada } }.
function DoorService:Snapshot()
	local resumen = {}
	for _, id in ipairs(self.Orden) do
		local puerta = self.Puertas[id]
		resumen[id] = { Estado = self:EstadoTexto(puerta), Bloqueada = puerta.Cerrojo or puerta.Fijada, Fijada = puerta.Fijada }
	end
	return resumen
end

-- Ids de las puertas resueltas (copia) y de las que no se encontraron en el mapa.
function DoorService:Lista()
	local copia = {}
	for i, id in ipairs(self.Orden) do
		copia[i] = id
	end
	return copia
end

function DoorService:NoEncontradas()
	local copia = {}
	for i, id in ipairs(self.NoResueltas) do
		copia[i] = id
	end
	return copia
end

-- Abre / cierra. player opcional: con jugador se aplican todas las reglas; sin él es una acción del sistema.
function DoorService:Abrir(puertaId, player)
	return self:Accion(player, puertaId, "Abrir", "Servicio")
end

function DoorService:Cerrar(puertaId, player)
	return self:Accion(player, puertaId, "Cerrar", "Servicio")
end

-- Bloquea (true) o desbloquea (false). Con player se exige CargosBloqueo o permiso puertas.*. Devuelve ok, mensaje.
function DoorService:Bloquear(puertaId, bloquear, player)
	local accion = "Desbloquear"
	if bloquear then
		accion = "Bloquear"
	end
	local ok, mensaje = self:Accion(player, puertaId, accion, "Servicio")
	return ok, mensaje
end

-- Emergencia / fin de jornada: quita bloqueos y privacidad y abre todas las puertas.
function DoorService:AbrirTodas(motivo)
	local n = 0
	for _, id in ipairs(self.Orden) do
		local puerta = self.Puertas[id]
		puerta.Cerrojo = false
		puerta.Fijada = false
		puerta.Privacidad = nil
		if not puerta.Abierta then
			self:CambiarApertura(puerta, true)
			n = n + 1
		end
		self:Publicar(puerta, nil, "AbrirTodas")
	end
	local AuditLog = self:Servicio("AuditLogService")
	if AuditLog then
		pcall(AuditLog.Registrar, AuditLog, "Sistema", nil, "Puertas", "Abrir todas: " .. tostring(motivo or "sin motivo") .. " (" .. n .. " abiertas)")
	end
	return n
end

-- Restaura las hojas a sus valores originales y retira prompts, sonidos, atributos y tags (desinstalación).
function DoorService:Restaurar()
	self.Activo = false
	for _, conexion in ipairs(self.Conexiones) do
		pcall(function()
			conexion:Disconnect()
		end)
	end
	self.Conexiones = {}
	for _, id in ipairs(self.Orden) do
		local puerta = self.Puertas[id]
		for _, rec in ipairs(puerta.Partes) do
			pcall(function()
				rec.Parte.CFrame = rec.CFrame
				rec.Parte.Transparency = rec.Transparency
				rec.Parte.CanCollide = rec.CanCollide
			end)
		end
		for _, destino in ipairs(puerta.Marcadas or {}) do
			for _, nombre in ipairs({ "PuertaId", "Estado", "Bloqueada", "Fijada" }) do
				pcall(destino.SetAttribute, destino, nombre, nil)
			end
			pcall(CollectionService.RemoveTag, CollectionService, destino, TAG_HOJA)
		end
		if puerta.Ancla then
			pcall(function()
				puerta.Ancla:Destroy()
			end)
		end
	end
	self.Puertas = {}
	self.Orden = {}
end

-- Informe para Output / MetricsService.
function DoorService:Inventario()
	local lineas = { string.format("Puertas: %d resueltas, %d no encontradas", #self.Orden, #self.NoResueltas) }
	for _, id in ipairs(self.Orden) do
		local puerta = self.Puertas[id]
		table.insert(lineas, string.format("  %s [%s/%s] %s · %d piezas · zona %s", id, puerta.Modo, puerta.ModoEfectivo,
			self:EstadoTexto(puerta), #puerta.Partes, tostring(puerta.Zona)))
	end
	if #self.NoResueltas > 0 then
		table.insert(lineas, "  No encontradas: " .. table.concat(self.NoResueltas, " "))
	end
	return {
		Resueltas = #self.Orden,
		NoResueltas = self:NoEncontradas(),
		Advertencias = self.Advertencias,
		Texto = table.concat(lineas, "\n"),
	}
end

return DoorService
