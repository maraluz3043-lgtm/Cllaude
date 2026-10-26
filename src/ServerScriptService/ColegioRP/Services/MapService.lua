--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.MapService
	Tipo: ModuleScript
	Construye Workspace.ColegioRP_Mapa desde MapaLogico (zonas, spawns, aulas con asientos reales, tableros,
	PCs, cocina, cafetería y cancha) con un único recorrido de workspace:GetDescendants(). Nunca modifica la
	geometría existente: solo crea su carpeta propia y añade atributos, tags y prompts. Se construye en Init.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local MapaLogico = require(Shared:WaitForChild("MapaLogico"))
local Catalogs = require(Shared:WaitForChild("Catalogs"))
local Util = Shared:WaitForChild("Util")
local Zones = require(Util:WaitForChild("Zones"))
local Signal = require(Util:WaitForChild("Signal"))

local MapService = {}
MapService.Nombre = "MapService"
MapService.Listo = false
MapService.Advertencias = {}

local PREFIJO = "[ColegioRP][MapService]"

---------------------------------------------------------------------------------------------------
-- Parámetros (ajustables sin tocar la lógica)
---------------------------------------------------------------------------------------------------
MapService.NombreCarpeta = (Config.Nombres and Config.Nombres.CarpetaMapa) or "ColegioRP_Mapa"
MapService.NombreCarpetaManual = "ColegioRP_Mapa_Manual" -- Marcadores colocados a mano (Spawns) que tienen prioridad.
MapService.AtributoAuto = "ColegioRP_Auto" -- Marca los RoomId puestos por MapService (para distinguirlos de los manuales).
MapService.DistanciaDuplicadoAsiento = 0.5 -- Seats a menos de esta distancia se consideran la misma silla.
MapService.DistanciaDuplicadoMonitor = 1 -- Monitores a menos de esta distancia se consideran el mismo PC.
MapService.DistanciaSeatPC = 6 -- Distancia máxima monitor-Seat para emparejar el asiento del PC.
MapService.DistanciaPortatil = 4 -- Distancia máxima estación-"Portatil_pantalla" en robótica.
MapService.DistanciaPizarra = 3 -- Distancia máxima entre Zona.Tablero.Centro y la pizarra real.
MapService.TableroPorDefecto = Vector2.new(10, 6) -- Ancho × alto del tablero si no hay pizarra real válida.
MapService.GrosorTablero = 0.2 -- Grosor de la Part del tablero.
MapService.SeparacionTablero = 0.02 -- Separación entre la pizarra real y la Part del tablero.
MapService.PixelesPorStud = 50 -- Resolución de las SurfaceGui creadas.
MapService.MarcadorPorDefecto = Vector3.new(-2, 12, -1540) -- Posición del marcador si MapaLogico no la define.
MapService.TamanoMarcador = Vector3.new(12, 4, 0.4)
MapService.PrefijosPC = { INFORMATICA = "PC_INF", ROBOTICA = "PC_ROB" }

-- Límites de plausibilidad de una pizarra real (studs) para usar su tamaño.
local PIZARRA_GROSOR_MAX = 1
local PIZARRA_ANCHO_MIN, PIZARRA_ANCHO_MAX = 2, 24
local PIZARRA_ALTO_MIN, PIZARRA_ALTO_MAX = 1, 10
-- Desfase máximo (studs, a lo largo de la normal) aceptado entre el centro lógico y la superficie detectada.
local DESFASE_SUPERFICIE_MAX = 1.5

-- Textos de acción de las estaciones de cocina (ProximityPrompt.ActionText).
local ACCION_ESTACION = {
	Preparacion = "Preparar",
	Coccion = "Cocinar",
	Emplatado = "Emplatar",
	Entrega = "Entregar",
	Reposicion = "Reponer",
}
local ORDEN_ESTACIONES = { "Preparacion", "Coccion", "Emplatado", "Entrega", "Reposicion" }

---------------------------------------------------------------------------------------------------
-- Utilidades generales
---------------------------------------------------------------------------------------------------
local function contarClaves(t)
	local n = 0
	if typeof(t) == "table" then
		for _ in pairs(t) do
			n = n + 1
		end
	end
	return n
end

local function copiarArray(t)
	local copia = {}
	if typeof(t) == "table" then
		for i, v in ipairs(t) do
			copia[i] = v
		end
	end
	return copia
end

local function esVector(v)
	return typeof(v) == "Vector3"
end

local function fmtV3(v)
	if not esVector(v) then
		return "?"
	end
	return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
end

local function recortarTexto(texto)
	return (string.gsub(tostring(texto or ""), "^%s*(.-)%s*$", "%1"))
end

-- "A, B ,C" -> { "A", "B", "C" }
local function separarCargos(texto)
	local lista = {}
	if typeof(texto) ~= "string" then
		return lista
	end
	for parte in string.gmatch(texto, "[^,]+") do
		local limpio = recortarTexto(parte)
		if limpio ~= "" then
			table.insert(lista, limpio)
		end
	end
	return lista
end

local function unirCargos(lista)
	if typeof(lista) ~= "table" then
		return ""
	end
	local partes = {}
	for _, cargo in ipairs(lista) do
		table.insert(partes, tostring(cargo))
	end
	return table.concat(partes, ",")
end

-- Orden estable por posición (Z, luego X, luego Y), redondeando a 0.1 studs.
local function redondear(n)
	return math.floor(n * 10 + 0.5) / 10
end

local function ordenarPorPosicion(lista, obtenerPosicion)
	table.sort(lista, function(a, b)
		local pa, pb = obtenerPosicion(a), obtenerPosicion(b)
		local za, zb = redondear(pa.Z), redondear(pb.Z)
		if za ~= zb then
			return za > zb
		end
		local xa, xb = redondear(pa.X), redondear(pb.X)
		if xa ~= xb then
			return xa < xb
		end
		return redondear(pa.Y) < redondear(pb.Y)
	end)
end

local function unitario(v, porDefecto)
	if esVector(v) and v.Magnitude > 1e-4 then
		return v.Unit
	end
	return porDefecto
end

-- CFrame en "posicion" cuya cara Front (-Z local) mira en la dirección "normal".
local function cframeMirando(posicion, normal)
	local n = unitario(normal, Vector3.new(0, 0, -1))
	if math.abs(n.Y) > 0.99 then
		return CFrame.lookAt(posicion, posicion + n * 2, Vector3.new(0, 0, 1))
	end
	return CFrame.lookAt(posicion, posicion + n * 2)
end

-- Extensión (studs) de la caja de una BasePart a lo largo de una dirección unitaria.
local function extensionSegun(parte, direccion)
	local cf, s = parte.CFrame, parte.Size
	return math.abs(cf.RightVector:Dot(direccion)) * s.X
		+ math.abs(cf.UpVector:Dot(direccion)) * s.Y
		+ math.abs(cf.LookVector:Dot(direccion)) * s.Z
end

-- Ancho, alto y grosor de una pieza plana vertical (alto = eje local más alineado con Y del mundo).
local function dimensionesPlanas(parte)
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
	local otros = {}
	for i, eje in ipairs(ejes) do
		if i ~= iVertical then
			table.insert(otros, eje[2])
		end
	end
	return math.max(otros[1], otros[2]), ejes[iVertical][2], math.min(otros[1], otros[2])
end

-- Volumen de una BasePart (para elegir la pieza principal de un modelo).
local function volumenParte(parte)
	local s = parte.Size
	return s.X * s.Y * s.Z
end

---------------------------------------------------------------------------------------------------
-- Creación de instancias propias
---------------------------------------------------------------------------------------------------
local function nuevaCarpeta(nombre, padre)
	local carpeta = Instance.new("Folder")
	carpeta.Name = nombre
	carpeta.Parent = padre
	return carpeta
end

-- Part invisible, anclada y sin colisiones/consultas/toques (marcador lógico).
local function nuevaParteInvisible(nombre, tamano, cframe, padre)
	local parte = Instance.new("Part")
	parte.Name = nombre
	parte.Anchored = true
	parte.CanCollide = false
	parte.CanQuery = false
	parte.CanTouch = false
	parte.CastShadow = false
	parte.Transparency = 1
	parte.Locked = true
	parte.TopSurface = Enum.SurfaceType.Smooth
	parte.BottomSurface = Enum.SurfaceType.Smooth
	parte.Size = tamano
	parte.CFrame = cframe
	parte.Parent = padre
	return parte
end

local function nuevoObjectValue(nombre, valor, padre)
	local ov = Instance.new("ObjectValue")
	ov.Name = nombre
	ov.Value = valor
	ov.Parent = padre
	return ov
end

-- SurfaceGui vacía en la cara Front de la parte (la rellenan BoardService / FootballService).
local function nuevaSurfaceGui(nombre, parte)
	local gui = Instance.new("SurfaceGui")
	gui.Name = nombre
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = MapService.PixelesPorStud
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.ClipsDescendants = true
	gui.ResetOnSpawn = false
	gui.Parent = parte
	return gui
end

local function nuevoPrompt(parte, props, atributos)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ColegioRP_Prompt"
	prompt.ActionText = props.ActionText or "Usar"
	prompt.ObjectText = props.ObjectText or ""
	prompt.HoldDuration = props.HoldDuration or 0
	prompt.MaxActivationDistance = props.MaxActivationDistance or 8
	prompt.RequiresLineOfSight = false
	prompt.ClickablePrompt = true
	prompt.Enabled = true
	for clave, valor in pairs(atributos or {}) do
		prompt:SetAttribute(clave, valor)
	end
	prompt.Parent = parte
	return prompt
end

---------------------------------------------------------------------------------------------------
-- Estado interno
---------------------------------------------------------------------------------------------------
function MapService:ReiniciarEstado()
	self.Advertencias = {}
	self._carpetas = {} -- nombre -> Folder
	self._zonasParte = {} -- zonaId -> Part
	self._spawns = {} -- zonaId -> { { Punto, Estado, Cargos, Parte } }
	self._aulas = {} -- roomId -> info
	self._listaAulas = {} -- ids en orden de MapaLogico.Aulas
	self._aulaDeSeat = {} -- Seat -> roomId (incluye duplicados)
	self._canonico = {} -- Seat duplicado -> Seat conservado
	self._pcs = {} -- array de registros
	self._pcPorId = {} -- pcId -> registro
	self._pcPorSeat = {} -- Seat -> registro
	self._pcPorPantalla = {} -- BasePart -> registro
	self._puertas = {} -- puertaId -> { Id, Config, Instancia, Hoja, Principal }
	self._puertasNoResueltas = {} -- ids
	self._cocina = nil
	self._cafeteria = nil
	self._futbol = nil
	self._decoracion = {} -- instancias etiquetadas
	self._mostradores = 0
	self._estaciones = 0
	self._spawnsManuales = 0
	self._duracionSeg = 0
	self._marcasAtributo = self._marcasAtributo or {} -- { { Instancia, Nombre, Previo } } (para Limpiar)
	self._marcasTag = self._marcasTag or {} -- { { Instancia, Tag } }
	self.Listo = false
end

function MapService:Advertir(texto)
	table.insert(self.Advertencias, tostring(texto))
end

-- Atributo en una instancia existente del mapa (se recuerda el valor previo para Limpiar).
function MapService:MarcarAtributo(instancia, nombre, valor)
	local ok, previo = pcall(instancia.GetAttribute, instancia, nombre)
	if not ok then
		previo = nil
	end
	local okSet = pcall(instancia.SetAttribute, instancia, nombre, valor)
	if okSet then
		table.insert(self._marcasAtributo, { Instancia = instancia, Nombre = nombre, Previo = previo })
	end
	return okSet
end

-- Tag en una instancia existente del mapa (solo se recuerda si no lo tenía).
function MapService:MarcarTag(instancia, tag)
	if typeof(tag) ~= "string" or tag == "" then
		return false
	end
	local okHas, yaTenia = pcall(CollectionService.HasTag, CollectionService, instancia, tag)
	if okHas and yaTenia then
		return true
	end
	local ok = pcall(CollectionService.AddTag, CollectionService, instancia, tag)
	if ok then
		table.insert(self._marcasTag, { Instancia = instancia, Tag = tag })
	end
	return ok
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function MapService:Init(registro)
	self.registro = registro
	self.Construido = Signal.new() -- (inventarioTabla) tras cada construcción
	self._marcasAtributo = {}
	self._marcasTag = {}
	self:ReiniciarEstado()
	local ok, err = pcall(function()
		self:Construir()
	end)
	if not ok then
		self:Advertir("Error general al construir el mapa: " .. tostring(err))
		warn(PREFIJO .. " Error al construir el mapa: " .. tostring(err))
		self.Listo = true
	end
end

function MapService:Start()
	local AuditLog = self.registro and self.registro.Get("AuditLogService")
	if AuditLog then
		local okInv, tabla = pcall(self.Inventario, self)
		if okInv and typeof(tabla) == "table" then
			AuditLog:Registrar("Sistema", nil, "Mapa", string.format(
				"%d zonas, %d aulas, %d asientos, %d PCs, puertas %d/%d, %d advertencias (%.2f s)",
				tabla.Zonas, tabla.Aulas, tabla.Asientos, tabla.PCs, tabla.PuertasResueltas, tabla.Puertas,
				#tabla.Advertencias, tabla.DuracionSeg or 0))
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Construcción completa
---------------------------------------------------------------------------------------------------
function MapService:Construir()
	local t0 = os.clock()
	self:ReiniciarEstado()

	-- 1. Carpeta de una ejecución anterior: se destruye (se regenera siempre).
	local intentos = 0
	local vieja = workspace:FindFirstChild(self.NombreCarpeta)
	while vieja and intentos < 10 do
		intentos = intentos + 1
		local okDestruir, errDestruir = pcall(function()
			vieja:Destroy()
		end)
		if not okDestruir then
			self:Advertir("No se pudo destruir la carpeta anterior " .. self.NombreCarpeta .. ": " .. tostring(errDestruir))
			pcall(function()
				vieja.Name = self.NombreCarpeta .. "_Antigua"
			end)
		end
		vieja = workspace:FindFirstChild(self.NombreCarpeta)
	end

	-- 2. Marcadores manuales.
	self._manual = workspace:FindFirstChild(self.NombreCarpetaManual)

	-- 3. Único recorrido del Workspace.
	self:Escanear()

	-- 4. Carpeta raíz (se construye sin padre y se publica al final de una sola vez).
	local raiz = Instance.new("Folder")
	raiz.Name = self.NombreCarpeta
	raiz:SetAttribute("Version", tostring(Config.Version or ""))
	raiz:SetAttribute("MapaLogicoVersion", MapaLogico.Version or 0)
	self._raiz = raiz
	for _, nombre in ipairs({ "Zonas", "Spawns", "Aulas", "PCs", "Cocina", "Cafeteria", "Futbol" }) do
		self._carpetas[nombre] = nuevaCarpeta(nombre, raiz)
	end

	local bloques = {
		{ "Zonas", self.ConstruirZonas },
		{ "Spawns", self.ConstruirSpawns },
		{ "Aulas", self.ConstruirAulas },
		{ "PCs", self.ConstruirPCs },
		{ "Cocina", self.ConstruirCocina },
		{ "Cafeteria", self.ConstruirCafeteria },
		{ "Futbol", self.ConstruirFutbol },
		{ "Decoracion", self.EtiquetarDecoracion },
		{ "Puertas", self.ResolverPuertas },
	}
	for _, bloque in ipairs(bloques) do
		local ok, err = pcall(bloque[2], self)
		if not ok then
			self:Advertir("Bloque " .. bloque[1] .. " con error: " .. tostring(err))
			warn(PREFIJO .. " Error en el bloque " .. bloque[1] .. ": " .. tostring(err))
		end
	end

	-- 5. Publicación.
	local okPadre, errPadre = pcall(function()
		raiz.Parent = workspace
	end)
	if not okPadre then
		self:Advertir("No se pudo publicar la carpeta del mapa: " .. tostring(errPadre))
	end

	self._escaneo = nil -- libera las listas del recorrido
	self._duracionSeg = os.clock() - t0
	self.Listo = true
	if self.Construido then
		local okInv, tabla = pcall(self.Inventario, self)
		if okInv then
			self.Construido:Fire(tabla)
		end
	end
	return raiz
end

-- Quita la carpeta propia y los atributos/tags añadidos a instancias existentes (reversible).
function MapService:Limpiar()
	for i = #self._marcasTag, 1, -1 do
		local marca = self._marcasTag[i]
		if marca.Instancia then
			pcall(CollectionService.RemoveTag, CollectionService, marca.Instancia, marca.Tag)
		end
	end
	for i = #self._marcasAtributo, 1, -1 do
		local marca = self._marcasAtributo[i]
		if marca.Instancia then
			pcall(marca.Instancia.SetAttribute, marca.Instancia, marca.Nombre, marca.Previo)
		end
	end
	self._marcasTag = {}
	self._marcasAtributo = {}
	local carpeta = workspace:FindFirstChild(self.NombreCarpeta)
	if carpeta then
		pcall(function()
			carpeta:Destroy()
		end)
	end
	self.Listo = false
end

-- Reconstruye todo (uso desde Studio / administración). Devuelve la tabla del inventario.
function MapService:Reconstruir()
	self:Limpiar()
	local ok, err = pcall(function()
		self:Construir()
	end)
	if not ok then
		self:Advertir("Error al reconstruir el mapa: " .. tostring(err))
		self.Listo = true
	end
	return (self:Inventario())
end

---------------------------------------------------------------------------------------------------
-- Recorrido único del Workspace
---------------------------------------------------------------------------------------------------
function MapService:Escanear()
	local escaneo = {
		Seats = {}, -- Seat / VehicleSeat
		Computers = {}, -- Model "Computer"
		Portatiles = {}, -- BasePart "Portatil_pantalla"
		Pizarras = {}, -- BasePart cuyo nombre contiene "pizarra" o "tablero"
		Decoracion = {}, -- Model/BasePart/Folder con nombre de Catalogs.DecoracionPesada
	}
	self._escaneo = escaneo

	local nombresDecoracion = Catalogs.DecoracionPesadaNombres or {}
	local carpetaPropia = workspace:FindFirstChild(self.NombreCarpeta)
	local manual = self._manual

	local ok, descendientes = pcall(function()
		return workspace:GetDescendants()
	end)
	if not ok or typeof(descendientes) ~= "table" then
		self:Advertir("No se pudo recorrer el Workspace: " .. tostring(descendientes))
		return escaneo
	end

	for _, inst in ipairs(descendientes) do
		local nombre = inst.Name
		if inst:IsA("BasePart") then
			if inst:IsA("Seat") or inst:IsA("VehicleSeat") then
				table.insert(escaneo.Seats, inst)
			elseif nombre == "Portatil_pantalla" then
				table.insert(escaneo.Portatiles, inst)
			end
			local minus = string.lower(nombre)
			if string.find(minus, "pizarra", 1, true) or string.find(minus, "tablero", 1, true) then
				table.insert(escaneo.Pizarras, inst)
			end
			if nombresDecoracion[nombre] then
				table.insert(escaneo.Decoracion, inst)
			end
		elseif nombre == "Computer" and inst:IsA("Model") then
			table.insert(escaneo.Computers, inst)
			if nombresDecoracion[nombre] then
				table.insert(escaneo.Decoracion, inst)
			end
		elseif nombresDecoracion[nombre] and (inst:IsA("Model") or inst:IsA("Folder")) then
			table.insert(escaneo.Decoracion, inst)
		end
	end

	-- Exclusión de la carpeta propia (por si no se pudo destruir) y de los marcadores manuales.
	local function filtrar(lista, excluirManual)
		local salida = {}
		for _, inst in ipairs(lista) do
			local fuera = true
			if carpetaPropia and inst:IsDescendantOf(carpetaPropia) then
				fuera = false
			end
			if excluirManual and manual and inst:IsDescendantOf(manual) then
				fuera = false
			end
			if fuera then
				table.insert(salida, inst)
			end
		end
		return salida
	end
	if carpetaPropia then
		escaneo.Seats = filtrar(escaneo.Seats, false)
	end
	escaneo.Computers = filtrar(escaneo.Computers, true)
	escaneo.Portatiles = filtrar(escaneo.Portatiles, true)
	escaneo.Pizarras = filtrar(escaneo.Pizarras, true)
	escaneo.Decoracion = filtrar(escaneo.Decoracion, true)
	escaneo.Total = #descendientes
	return escaneo
end

---------------------------------------------------------------------------------------------------
-- Zonas
---------------------------------------------------------------------------------------------------
function MapService:ConstruirZonas()
	local carpeta = self._carpetas.Zonas
	for _, id in ipairs(MapaLogico.OrdenZonas or {}) do
		local zona = MapaLogico.Zonas[id]
		if zona and esVector(zona.Centro) and esVector(zona.Tamano) then
			local parte = nuevaParteInvisible(id, zona.Tamano, CFrame.new(zona.Centro), carpeta)
			parte:SetAttribute("ZoneId", id)
			parte:SetAttribute("Tipo", tostring(zona.Tipo or ""))
			parte:SetAttribute("Piso", zona.Piso or 0)
			parte:SetAttribute("Nombre", tostring(zona.Nombre or id))
			self._zonasParte[id] = parte
		else
			self:Advertir("Zona " .. tostring(id) .. " sin Centro/Tamano válidos en MapaLogico.")
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Spawns (MapaLogico + marcadores manuales)
---------------------------------------------------------------------------------------------------
function MapService:LeerSpawnsManuales()
	local porZona = {}
	local manual = self._manual
	if not manual then
		return porZona
	end
	local origen = manual:FindFirstChild("Spawns") or manual
	for _, inst in ipairs(origen:GetDescendants()) do
		if inst:IsA("BasePart") then
			local zonaId = inst:GetAttribute("ZoneId")
			local cargos = inst:GetAttribute("Cargos")
			if typeof(zonaId) == "string" and zonaId ~= "" then
				if MapaLogico.Zonas[zonaId] then
					if not porZona[zonaId] then
						porZona[zonaId] = {}
					end
					table.insert(porZona[zonaId], {
						Punto = inst.Position,
						Estado = "manual",
						Cargos = separarCargos(cargos),
						Marcador = inst,
					})
				else
					self:Advertir("Spawn manual " .. inst:GetFullName() .. " con ZoneId desconocido: " .. zonaId)
				end
			elseif origen ~= manual then
				self:Advertir("Spawn manual " .. inst:GetFullName() .. " sin atributo ZoneId (se ignora).")
			end
		end
	end
	return porZona
end

function MapService:ConstruirSpawns()
	local carpeta = self._carpetas.Spawns
	local manuales = self:LeerSpawnsManuales()
	local provisionales = {}
	for _, id in ipairs(MapaLogico.OrdenZonas or {}) do
		local zona = MapaLogico.Zonas[id]
		local lista = {}
		if manuales[id] and #manuales[id] > 0 then
			for _, punto in ipairs(manuales[id]) do
				table.insert(lista, punto)
				self._spawnsManuales = self._spawnsManuales + 1
			end
		elseif zona and zona.Spawn and esVector(zona.Spawn.Punto) then
			table.insert(lista, {
				Punto = zona.Spawn.Punto,
				Estado = zona.Spawn.Estado or "confirmado",
				Cargos = copiarArray(zona.Spawn.Cargos),
			})
		end
		for i, punto in ipairs(lista) do
			local nombre = id
			if i > 1 then
				nombre = id .. "_" .. i
			end
			local parte = nuevaParteInvisible(nombre, Vector3.new(4, 1, 4), CFrame.new(punto.Punto), carpeta)
			parte:SetAttribute("ZoneId", id)
			parte:SetAttribute("Cargos", unirCargos(punto.Cargos))
			parte:SetAttribute("Estado", punto.Estado)
			punto.Parte = parte
			if punto.Estado == "provisional" then
				table.insert(provisionales, id)
			end
		end
		if #lista > 0 then
			self._spawns[id] = lista
		end
	end
	if #provisionales > 0 then
		self:Advertir(string.format("Spawns provisionales (%d, verificar en Studio o colocar marcadores en %s.Spawns): %s",
			#provisionales, self.NombreCarpetaManual, table.concat(provisionales, ", ")))
	end
end

---------------------------------------------------------------------------------------------------
-- Aulas: asientos reales, puesto docente y tablero
---------------------------------------------------------------------------------------------------

-- Reparte los Seats escaneados entre las aulas: los que tienen RoomId puesto a mano van a esa aula;
-- el resto, al aula cuyo volumen los contiene (si la zona más pequeña que los contiene es un aula).
function MapService:RepartirAsientos()
	local manuales, automaticos = {}, {}
	local seats = (self._escaneo and self._escaneo.Seats) or {}
	for _, seat in ipairs(seats) do
		local roomId = seat:GetAttribute("RoomId")
		local esAuto = seat:GetAttribute(self.AtributoAuto) == true
		if typeof(roomId) == "string" and roomId ~= "" and not esAuto then
			if Zones.EsAula(roomId) then
				if not manuales[roomId] then
					manuales[roomId] = {}
				end
				table.insert(manuales[roomId], seat)
			else
				self:Advertir("Seat " .. seat:GetFullName() .. " con RoomId manual desconocido: " .. roomId)
			end
		else
			-- La zona más específica (menor volumen) que contiene el Seat decide; solo cuenta si es un aula.
			local zona = Zones.ZonaDe(seat.Position)
			if zona and Zones.EsAula(zona.Id) then
				if not automaticos[zona.Id] then
					automaticos[zona.Id] = {}
				end
				table.insert(automaticos[zona.Id], seat)
			end
		end
	end
	return manuales, automaticos
end

-- Busca la pizarra real más cercana al centro lógico del tablero.
function MapService:PizarraCercana(centro)
	local mejor, mejorDist = nil, math.huge
	local pizarras = (self._escaneo and self._escaneo.Pizarras) or {}
	for _, parte in ipairs(pizarras) do
		local d = (parte.Position - centro).Magnitude
		if d <= self.DistanciaPizarra and d < mejorDist then
			mejor, mejorDist = parte, d
		end
	end
	return mejor
end

-- Plano (producto escalar con la normal) de la superficie visible delante del centro lógico, por rayo.
function MapService:SuperficiePorRayo(centro, normal)
	local params = RaycastParams.new()
	local okFiltro = pcall(function()
		params.FilterType = Enum.RaycastFilterType.Exclude
	end)
	if not okFiltro then
		pcall(function()
			params.FilterType = Enum.RaycastFilterType.Blacklist
		end)
	end
	params.FilterDescendantsInstances = {}
	params.IgnoreWater = true
	local origen = centro + normal * DESFASE_SUPERFICIE_MAX
	local ok, resultado = pcall(function()
		return workspace:Raycast(origen, -normal * (DESFASE_SUPERFICIE_MAX * 2), params)
	end)
	if ok and resultado then
		return resultado.Position:Dot(normal)
	end
	return nil
end

function MapService:ConstruirTablero(roomId, zona, modelo)
	local def = zona.Tablero
	if typeof(def) ~= "table" or not esVector(def.Centro) then
		return nil, nil, nil
	end
	local normal = unitario(def.Normal, Vector3.new(0, 0, -1))
	local centro = def.Centro
	local planoCentro = centro:Dot(normal)
	local ancho, alto = self.TableroPorDefecto.X, self.TableroPorDefecto.Y
	local base = centro
	local fuente = "defecto"
	local superficie = nil

	local pizarra = self:PizarraCercana(centro)
	if pizarra then
		local anchoReal, altoReal, grosorReal = dimensionesPlanas(pizarra)
		local frente = pizarra.Position:Dot(normal) + extensionSegun(pizarra, normal) / 2
		if math.abs(frente - planoCentro) <= DESFASE_SUPERFICIE_MAX then
			superficie = frente
		end
		local plausible = grosorReal <= PIZARRA_GROSOR_MAX
			and anchoReal >= PIZARRA_ANCHO_MIN and anchoReal <= PIZARRA_ANCHO_MAX
			and altoReal >= PIZARRA_ALTO_MIN and altoReal <= PIZARRA_ALTO_MAX
		if plausible then
			ancho, alto = anchoReal, altoReal
			base = pizarra.Position
			fuente = "pizarra:" .. pizarra.Name
		else
			fuente = "defecto (pieza cercana " .. pizarra.Name .. " fuera de rango)"
			self:Advertir(string.format("Tablero de %s: la pieza cercana '%s' (%.1f×%.1f×%.1f) no parece una pizarra; tamaño por defecto.",
				roomId, pizarra.Name, anchoReal, altoReal, grosorReal))
		end
	end
	if not superficie then
		local plano = self:SuperficiePorRayo(centro, normal)
		if plano and math.abs(plano - planoCentro) <= DESFASE_SUPERFICIE_MAX then
			superficie = plano
		end
	end
	if not pizarra then
		self:Advertir("Tablero de " .. roomId .. ": no se encontró pizarra real a ≤ " .. self.DistanciaPizarra .. " studs de " .. fmtV3(centro) .. " (tamaño por defecto; verificar en Studio).")
	end

	-- Plano de la cara trasera de nuestra Part: la superficie detectada, o el centro lógico + 0.05.
	if not superficie then
		superficie = planoCentro + 0.05
	end
	local planoParte = superficie + self.GrosorTablero / 2 + self.SeparacionTablero
	local posicion = base + normal * (planoParte - base:Dot(normal))

	local tablero = nuevaParteInvisible("Tablero", Vector3.new(ancho, alto, self.GrosorTablero), cframeMirando(posicion, normal), modelo)
	tablero:SetAttribute("RoomId", roomId)
	tablero:SetAttribute("Ancho", ancho)
	tablero:SetAttribute("Alto", alto)
	tablero:SetAttribute("Normal", normal)
	tablero:SetAttribute("Fuente", fuente)
	local gui = nuevaSurfaceGui("TableroGui", tablero)
	return tablero, gui, fuente
end

function MapService:ConstruirAulas()
	local carpeta = self._carpetas.Aulas
	local manuales, automaticos = self:RepartirAsientos()
	local tagAsiento = Config.Tags and Config.Tags.Asiento

	for _, roomId in ipairs(MapaLogico.Aulas or {}) do
		local zona = MapaLogico.Zonas[roomId]
		if not zona then
			self:Advertir("Aula " .. tostring(roomId) .. " listada en MapaLogico.Aulas sin zona definida.")
		else
			local ok, err = pcall(function()
				local modelo = Instance.new("Model")
				modelo.Name = roomId
				modelo:SetAttribute("RoomId", roomId)
				modelo:SetAttribute("Nombre", tostring(zona.Nombre or roomId))
				modelo:SetAttribute("Tipo", tostring(zona.Tipo or ""))
				modelo:SetAttribute("Piso", zona.Piso or 0)

				-- Candidatos: primero los manuales, luego los del volumen; des-duplicado a < 0.5 studs.
				local candidatos = {}
				local esManual = {}
				for _, seat in ipairs(manuales[roomId] or {}) do
					table.insert(candidatos, seat)
					esManual[seat] = true
				end
				for _, seat in ipairs(automaticos[roomId] or {}) do
					table.insert(candidatos, seat)
				end
				local conservados, duplicados = {}, {}
				for _, seat in ipairs(candidatos) do
					local original = nil
					for _, otro in ipairs(conservados) do
						if (otro.Position - seat.Position).Magnitude < self.DistanciaDuplicadoAsiento then
							original = otro
							break
						end
					end
					if original then
						table.insert(duplicados, { Seat = seat, Canonico = original })
					else
						table.insert(conservados, seat)
					end
				end
				ordenarPorPosicion(conservados, function(seat)
					return seat.Position
				end)

				local carpetaSeats = nuevaCarpeta("Seats", modelo)
				local indice = {}
				for n, seat in ipairs(conservados) do
					nuevoObjectValue("Asiento_" .. n, seat, carpetaSeats)
					indice[seat] = n
					self._aulaDeSeat[seat] = roomId
					if esManual[seat] then
						if seat:GetAttribute(self.AtributoAuto) ~= nil then
							self:MarcarAtributo(seat, self.AtributoAuto, nil)
						end
					else
						self:MarcarAtributo(seat, "RoomId", roomId)
						self:MarcarAtributo(seat, self.AtributoAuto, true)
					end
					self:MarcarTag(seat, tagAsiento)
				end
				for _, par in ipairs(duplicados) do
					self._aulaDeSeat[par.Seat] = roomId
					self._canonico[par.Seat] = par.Canonico
				end

				local puesto = nil
				if esVector(zona.PuestoDocente) then
					puesto = nuevaParteInvisible("PuestoDocente", Vector3.new(4, 1, 4), CFrame.new(zona.PuestoDocente), modelo)
					puesto:SetAttribute("RoomId", roomId)
				end

				local tablero, gui, fuente = nil, nil, nil
				if zona.Tablero then
					local okTablero, errTablero = pcall(function()
						tablero, gui, fuente = self:ConstruirTablero(roomId, zona, modelo)
					end)
					if not okTablero then
						self:Advertir("Tablero de " .. roomId .. " con error: " .. tostring(errTablero))
					end
				end

				modelo:SetAttribute("Capacidad", #conservados)
				modelo:SetAttribute("TieneTablero", tablero ~= nil)
				if tablero then
					modelo.PrimaryPart = tablero
				elseif puesto then
					modelo.PrimaryPart = puesto
				end
				modelo.Parent = carpeta

				local esperados = zona.Asientos or 0
				if #conservados < esperados then
					self:Advertir(string.format("Aula %s: se esperaban %d asientos y se encontraron %d.", roomId, esperados, #conservados))
				end

				self._aulas[roomId] = {
					RoomId = roomId,
					Model = modelo,
					Seats = conservados,
					Duplicados = duplicados,
					Indice = indice,
					Capacidad = #conservados,
					Esperados = esperados,
					Tablero = tablero,
					TableroGui = gui,
					FuenteTablero = fuente,
					PuestoDocente = puesto,
					Zona = zona,
				}
				table.insert(self._listaAulas, roomId)
			end)
			if not ok then
				self:Advertir("Aula " .. tostring(roomId) .. " con error: " .. tostring(err))
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- PCs (informática: modelos "Computer"; robótica: portátiles por estación)
---------------------------------------------------------------------------------------------------
function MapService:RegistrarPC(id, pantalla, seat, roomId, modeloReal)
	local carpeta = self._carpetas.PCs
	local marcador = Instance.new("Model")
	marcador.Name = id
	marcador:SetAttribute("PcId", id)
	marcador:SetAttribute("RoomId", roomId)
	nuevoObjectValue("Pantalla", pantalla, marcador)
	if seat then
		nuevoObjectValue("Seat", seat, marcador)
	end
	if modeloReal then
		nuevoObjectValue("Modelo", modeloReal, marcador)
	end
	marcador.Parent = carpeta

	self:MarcarAtributo(pantalla, "PcId", id)
	self:MarcarTag(pantalla, Config.Tags and Config.Tags.PantallaPC)
	if seat then
		self:MarcarAtributo(seat, "PcId", id)
	end

	local registro = {
		Id = id,
		Pantalla = pantalla,
		Seat = seat,
		RoomId = roomId,
		Modelo = modeloReal,
		Marcador = marcador,
	}
	table.insert(self._pcs, registro)
	self._pcPorId[id] = registro
	self._pcPorPantalla[pantalla] = registro
	if seat then
		self._pcPorSeat[seat] = registro
	end
	return registro
end

-- Asientos disponibles para emparejar en una zona: los del aula si existe; si no, los escaneados (des-duplicados).
function MapService:AsientosDeZona(zonaId)
	local aula = self._aulas[zonaId]
	if aula then
		return aula.Seats
	end
	local lista = {}
	for _, seat in ipairs((self._escaneo and self._escaneo.Seats) or {}) do
		if Zones.Contiene(zonaId, seat.Position) then
			local duplicado = false
			for _, otro in ipairs(lista) do
				if (otro.Position - seat.Position).Magnitude < self.DistanciaDuplicadoAsiento then
					duplicado = true
					break
				end
			end
			if not duplicado then
				table.insert(lista, seat)
			end
		end
	end
	return lista
end

function MapService:ConstruirPCsComputer(zonaId)
	local zona = MapaLogico.Zonas[zonaId]
	if not zona then
		return
	end
	local prefijo = self.PrefijosPC[zonaId] or ("PC_" .. zonaId)

	-- Monitores "Computer Monitor 1" dentro de la zona.
	local monitores = {}
	for _, modelo in ipairs((self._escaneo and self._escaneo.Computers) or {}) do
		local monitor = modelo:FindFirstChild("Computer Monitor 1")
		if not monitor then
			monitor = modelo:FindFirstChild("Computer Monitor 1", true)
		end
		if monitor and monitor:IsA("BasePart") and Zones.Contiene(zona, monitor.Position) then
			table.insert(monitores, { Monitor = monitor, Modelo = modelo })
		end
	end
	ordenarPorPosicion(monitores, function(m)
		return m.Monitor.Position
	end)

	-- Monitores superpuestos (modelos duplicados): se conserva el modelo más completo (más piezas).
	local unicos = {}
	for _, m in ipairs(monitores) do
		m.Piezas = #m.Modelo:GetDescendants()
		local iRepetido = nil
		for i, u in ipairs(unicos) do
			if (u.Monitor.Position - m.Monitor.Position).Magnitude < self.DistanciaDuplicadoMonitor then
				iRepetido = i
				break
			end
		end
		if iRepetido then
			local descartado = m
			if m.Piezas > unicos[iRepetido].Piezas then
				descartado = unicos[iRepetido]
				unicos[iRepetido] = m
			end
			self:Advertir("PC duplicado ignorado en " .. zonaId .. ": " .. descartado.Modelo:GetFullName() .. " " .. fmtV3(descartado.Monitor.Position))
		else
			table.insert(unicos, m)
		end
	end
	if #unicos == 0 then
		self:Advertir("No se encontraron modelos 'Computer' con 'Computer Monitor 1' en " .. zonaId .. ".")
		return
	end

	-- Emparejamiento global por distancia (cada Seat se usa una sola vez).
	local asientos = self:AsientosDeZona(zonaId)
	local pares = {}
	for i, m in ipairs(unicos) do
		for _, seat in ipairs(asientos) do
			local d = (seat.Position - m.Monitor.Position).Magnitude
			if d <= self.DistanciaSeatPC then
				table.insert(pares, { I = i, Seat = seat, D = d })
			end
		end
	end
	table.sort(pares, function(a, b)
		return a.D < b.D
	end)
	local seatDe, usados = {}, {}
	for _, par in ipairs(pares) do
		if not seatDe[par.I] and not usados[par.Seat] then
			seatDe[par.I] = par.Seat
			usados[par.Seat] = true
		end
	end

	for i, m in ipairs(unicos) do
		local id = prefijo .. "_" .. i
		local seat = seatDe[i]
		if not seat then
			self:Advertir("PC " .. id .. " sin Seat a ≤ " .. self.DistanciaSeatPC .. " studs (se usará la distancia).")
		end
		self:RegistrarPC(id, m.Monitor, seat, zonaId, m.Modelo)
	end
	local esperados = (typeof(zona.PCs) == "table") and #zona.PCs or 0
	if esperados > 0 and #unicos ~= esperados then
		self._notasPC = self._notasPC or {}
		table.insert(self._notasPC, string.format("%s: %d PCs únicos (MapaLogico lista %d posiciones).", zonaId, #unicos, esperados))
	end
end

function MapService:ConstruirPCsEstaciones(zonaId)
	local zona = MapaLogico.Zonas[zonaId]
	if not zona or typeof(zona.EstacionesPC) ~= "table" then
		return
	end
	local prefijo = self.PrefijosPC[zonaId] or ("PC_" .. zonaId)
	local portatiles = (self._escaneo and self._escaneo.Portatiles) or {}
	local usados = {}
	local n = 0
	for i, punto in ipairs(zona.EstacionesPC) do
		if esVector(punto) then
			local mejor, mejorDist = nil, math.huge
			for _, parte in ipairs(portatiles) do
				if not usados[parte] then
					local d = (parte.Position - punto).Magnitude
					if d <= self.DistanciaPortatil and d < mejorDist then
						mejor, mejorDist = parte, d
					end
				end
			end
			if mejor then
				usados[mejor] = true
				n = n + 1
				local modeloReal = mejor:FindFirstAncestorWhichIsA("Model")
				self:RegistrarPC(prefijo .. "_" .. n, mejor, nil, zonaId, modeloReal)
			else
				self:Advertir(string.format("Estación PC %d de %s %s sin 'Portatil_pantalla' a ≤ %s studs.", i, zonaId, fmtV3(punto), tostring(self.DistanciaPortatil)))
			end
		end
	end
end

function MapService:ConstruirPCs()
	self._notasPC = {}
	for _, id in ipairs(MapaLogico.OrdenZonas or {}) do
		local zona = MapaLogico.Zonas[id]
		if zona then
			if zona.Tipo == "aula_pc" or (typeof(zona.PCs) == "table" and #zona.PCs > 0) then
				local ok, err = pcall(self.ConstruirPCsComputer, self, id)
				if not ok then
					self:Advertir("PCs de " .. id .. " con error: " .. tostring(err))
				end
			end
			if typeof(zona.EstacionesPC) == "table" and #zona.EstacionesPC > 0 then
				local ok, err = pcall(self.ConstruirPCsEstaciones, self, id)
				if not ok then
					self:Advertir("Estaciones PC de " .. id .. " con error: " .. tostring(err))
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Cocina (estaciones + reclamo) y cafetería (mostrador)
---------------------------------------------------------------------------------------------------
local function nombresEstacionesOrdenados(estaciones)
	local lista, vistos = {}, {}
	for _, nombre in ipairs(ORDEN_ESTACIONES) do
		if esVector(estaciones[nombre]) then
			table.insert(lista, nombre)
			vistos[nombre] = true
		end
	end
	local otros = {}
	for nombre, punto in pairs(estaciones) do
		if not vistos[nombre] and typeof(nombre) == "string" and esVector(punto) then
			table.insert(otros, nombre)
		end
	end
	table.sort(otros)
	for _, nombre in ipairs(otros) do
		table.insert(lista, nombre)
	end
	return lista
end

function MapService:ConstruirCocina()
	local carpeta = self._carpetas.Cocina
	local zonaId = "COCINA"
	local zona = MapaLogico.Zonas[zonaId]
	if not zona then
		self:Advertir("No existe la zona COCINA en MapaLogico; sin estaciones de cocina.")
		return
	end
	carpeta:SetAttribute("ZoneId", zonaId)
	local info = { Carpeta = carpeta, Estaciones = {}, Prompts = {}, Reclamo = nil, ReclamoPrompt = nil, Mostrador = nil, Zona = zona }

	if typeof(zona.Estaciones) == "table" then
		for _, nombre in ipairs(nombresEstacionesOrdenados(zona.Estaciones)) do
			local punto = zona.Estaciones[nombre]
			local parte = nuevaParteInvisible(nombre, Vector3.new(2, 2, 2), CFrame.new(punto), carpeta)
			parte:SetAttribute("Estacion", nombre)
			parte:SetAttribute("Nombre", (Catalogs.Estaciones and Catalogs.Estaciones[nombre]) or nombre)
			parte:SetAttribute("ZoneId", zonaId)
			local prompt = nuevoPrompt(parte, {
				ActionText = ACCION_ESTACION[nombre] or "Usar",
				ObjectText = "Cocina",
				HoldDuration = 0.5,
				MaxActivationDistance = 8,
			}, { RPTipo = "Cocina", RPId = nombre })
			info.Estaciones[nombre] = parte
			info.Prompts[nombre] = prompt
			self._estaciones = self._estaciones + 1
		end
	else
		self:Advertir("La zona COCINA no define Estaciones.")
	end

	local fila = zona.FilaEstudiantes
	if typeof(fila) == "table" and esVector(fila.Centro) then
		local reclamo = nuevaParteInvisible("Reclamo", Vector3.new(2, 2, 2), CFrame.new(fila.Centro), carpeta)
		reclamo:SetAttribute("ZoneId", zonaId)
		if esVector(fila.Tamano) then
			reclamo:SetAttribute("TamanoFila", fila.Tamano)
		end
		info.Reclamo = reclamo
		info.ReclamoPrompt = nuevoPrompt(reclamo, {
			ActionText = "Reclamar almuerzo",
			ObjectText = "Comedor",
			HoldDuration = 0.3,
			MaxActivationDistance = 12,
		}, { RPTipo = "Comida", RPAccion = "Reclamar" })
	else
		self:Advertir("La zona COCINA no define FilaEstudiantes; sin punto de reclamo de almuerzo.")
	end

	if typeof(zona.Mostrador) == "table" and esVector(zona.Mostrador.Centro) then
		local frente = unitario(zona.Mostrador.Frente, Vector3.new(0, 0, 1))
		local mostrador = nuevaParteInvisible("Mostrador", Vector3.new(4, 2, 2), cframeMirando(zona.Mostrador.Centro, frente), carpeta)
		mostrador:SetAttribute("ZoneId", zonaId)
		mostrador:SetAttribute("Frente", frente)
		info.Mostrador = mostrador
		self._mostradores = self._mostradores + 1
	end
	self._cocina = info
end

function MapService:ConstruirCafeteria()
	local carpeta = self._carpetas.Cafeteria
	local zonaId = "TIENDA"
	local zona = MapaLogico.Zonas[zonaId]
	if not zona or typeof(zona.Mostrador) ~= "table" or not esVector(zona.Mostrador.Centro) then
		self:Advertir("La zona TIENDA no existe o no define Mostrador; sin mostrador de cafetería.")
		return
	end
	carpeta:SetAttribute("ZoneId", zonaId)
	local frente = unitario(zona.Mostrador.Frente, Vector3.new(-1, 0, 0))
	local mostrador = nuevaParteInvisible("Mostrador", Vector3.new(4, 2, 2), cframeMirando(zona.Mostrador.Centro, frente), carpeta)
	mostrador:SetAttribute("ZoneId", zonaId)
	mostrador:SetAttribute("Frente", frente)
	local prompt = nuevoPrompt(mostrador, {
		ActionText = "Comprar",
		ObjectText = "Tienda escolar",
		HoldDuration = 0,
		MaxActivationDistance = 10,
	}, { RPTipo = "Cafeteria", RPId = zonaId })
	self._mostradores = self._mostradores + 1
	self._cafeteria = { Carpeta = carpeta, Mostrador = mostrador, Prompt = prompt, Zona = zona }
end

---------------------------------------------------------------------------------------------------
-- Fútbol (balón, arcos, marcador)
---------------------------------------------------------------------------------------------------
function MapService:ConstruirFutbol()
	local carpeta = self._carpetas.Futbol
	local zonaId, def = nil, nil
	for _, id in ipairs(MapaLogico.OrdenZonas or {}) do
		local zona = MapaLogico.Zonas[id]
		if zona and typeof(zona.Futbol) == "table" then
			zonaId, def = id, zona.Futbol
			break
		end
	end
	if not def then
		self:Advertir("Ninguna zona define Futbol en MapaLogico; sin cancha.")
		return
	end
	carpeta:SetAttribute("ZoneId", zonaId)
	local info = { Carpeta = carpeta, ZonaId = zonaId, Balon = nil, ArcoA = nil, ArcoB = nil, Marcador = nil, MarcadorGui = nil, Limites = nil, Inicio = nil }

	if typeof(def.Limites) == "table" and esVector(def.Limites.Min) and esVector(def.Limites.Max) then
		carpeta:SetAttribute("LimiteMin", def.Limites.Min)
		carpeta:SetAttribute("LimiteMax", def.Limites.Max)
		info.Limites = { Min = def.Limites.Min, Max = def.Limites.Max }
	else
		self:Advertir("Futbol sin Limites válidos en " .. zonaId .. ".")
	end

	if esVector(def.Balon) then
		local balon = Instance.new("Part")
		balon.Name = "Balon"
		balon.Shape = Enum.PartType.Ball
		balon.Size = Vector3.new(2, 2, 2)
		balon.Color = Color3.fromRGB(245, 245, 245)
		balon.Material = Enum.Material.SmoothPlastic
		balon.TopSurface = Enum.SurfaceType.Smooth
		balon.BottomSurface = Enum.SurfaceType.Smooth
		balon.Anchored = true
		balon.CanCollide = true
		balon.CanQuery = true
		balon.CanTouch = true
		balon.CFrame = CFrame.new(def.Balon)
		balon:SetAttribute("Inicio", def.Balon)
		balon.Parent = carpeta
		carpeta:SetAttribute("BalonInicio", def.Balon)
		info.Balon = balon
		info.Inicio = def.Balon
	else
		self:Advertir("Futbol sin posición de Balon en " .. zonaId .. ".")
	end

	for _, letra in ipairs({ "A", "B" }) do
		local arcoDef = def["Arco" .. letra]
		if typeof(arcoDef) == "table" and esVector(arcoDef.Centro) and esVector(arcoDef.Tamano) then
			local arco = nuevaParteInvisible("Arco" .. letra, arcoDef.Tamano, CFrame.new(arcoDef.Centro), carpeta)
			arco.CanTouch = true
			arco:SetAttribute("Equipo", letra)
			info["Arco" .. letra] = arco
		else
			self:Advertir("Futbol sin Arco" .. letra .. " válido en " .. zonaId .. ".")
		end
	end

	local posMarcador = self.MarcadorPorDefecto
	local normalMarcador = Vector3.new(0, 0, -1)
	if typeof(def.Marcador) == "table" and esVector(def.Marcador.Centro) then
		posMarcador = def.Marcador.Centro
		normalMarcador = unitario(def.Marcador.Normal, normalMarcador)
	elseif esVector(def.Marcador) then
		posMarcador = def.Marcador
	end
	local marcador = Instance.new("Part")
	marcador.Name = "Marcador"
	marcador.Anchored = true
	marcador.CanCollide = false
	marcador.CanQuery = false
	marcador.CanTouch = false
	marcador.CastShadow = false
	marcador.Locked = true
	marcador.Material = Enum.Material.SmoothPlastic
	marcador.Color = Color3.fromRGB(20, 20, 24)
	marcador.Size = self.TamanoMarcador
	marcador.CFrame = cframeMirando(posMarcador, normalMarcador)
	marcador.Parent = carpeta
	info.Marcador = marcador
	info.MarcadorGui = nuevaSurfaceGui("MarcadorGui", marcador)

	self._futbol = info
end

---------------------------------------------------------------------------------------------------
-- Decoración pesada (tag para el modo de bajos recursos)
---------------------------------------------------------------------------------------------------
function MapService:EtiquetarDecoracion()
	local tag = Config.Tags and Config.Tags.Decoracion
	if typeof(tag) ~= "string" then
		self:Advertir("Config.Tags.Decoracion no definido; no se etiqueta la decoración pesada.")
		return
	end
	local etiquetados = {}
	for _, inst in ipairs((self._escaneo and self._escaneo.Decoracion) or {}) do
		-- Se omite si un ancestro ya quedó etiquetado (p. ej. "Fan" dentro de otro "Fan").
		local cubierto = false
		local padre = inst.Parent
		while padre and padre ~= workspace do
			if etiquetados[padre] then
				cubierto = true
				break
			end
			padre = padre.Parent
		end
		if not cubierto then
			if self:MarcarTag(inst, tag) then
				etiquetados[inst] = true
				table.insert(self._decoracion, inst)
			end
		end
	end
	local encontrados = {}
	for _, inst in ipairs(self._decoracion) do
		encontrados[inst.Name] = true
	end
	for _, entrada in ipairs(Catalogs.DecoracionPesada or {}) do
		if not encontrados[entrada.Nombre] then
			self:Advertir("Decoración pesada no encontrada en el mapa: " .. tostring(entrada.Nombre))
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Puertas (resolución de rutas "Workspace/A/B")
---------------------------------------------------------------------------------------------------
local VISITAS_MAX_RUTA = 50000

local function buscarRuta(actual, segmentos, i, contador)
	if i > #segmentos then
		return actual
	end
	local nombre = segmentos[i]
	local okHijos, hijos = pcall(actual.GetChildren, actual)
	if not okHijos then
		return nil
	end
	for _, hijo in ipairs(hijos) do
		contador.n = contador.n + 1
		if contador.n > VISITAS_MAX_RUTA then
			return nil
		end
		if hijo.Name == nombre then
			local encontrado = buscarRuta(hijo, segmentos, i + 1, contador)
			if encontrado then
				return encontrado
			end
		end
	end
	return nil
end

-- Resuelve "Workspace/A/B" desde game: primero FindFirstChild encadenado; si un nombre repetido lo
-- impide (varios "Model" hermanos), búsqueda en profundidad por todos los hijos con ese nombre.
function MapService:ResolverRuta(ruta)
	if typeof(ruta) ~= "string" or ruta == "" then
		return nil
	end
	local segmentos = {}
	for parte in string.gmatch(ruta, "[^/]+") do
		table.insert(segmentos, parte)
	end
	if #segmentos == 0 then
		return nil
	end
	local inicio = nil
	local primero = segmentos[1]
	if primero == "Workspace" or primero == "workspace" then
		inicio = workspace
	elseif primero == "game" then
		inicio = game
	else
		local ok, servicio = pcall(game.FindFirstChild, game, primero)
		if ok then
			inicio = servicio
		end
	end
	if not inicio then
		return nil
	end
	local actual = inicio
	for i = 2, #segmentos do
		if not actual then
			break
		end
		actual = actual:FindFirstChild(segmentos[i])
	end
	if actual then
		return actual
	end
	local resto = {}
	for i = 2, #segmentos do
		table.insert(resto, segmentos[i])
	end
	return buscarRuta(inicio, resto, 1, { n = 0 })
end

local function partePrincipal(instancia)
	if instancia:IsA("BasePart") then
		return instancia
	end
	local mejor, mejorVol = nil, -1
	for _, d in ipairs(instancia:GetDescendants()) do
		if d:IsA("BasePart") then
			local v = volumenParte(d)
			if v > mejorVol then
				mejor, mejorVol = d, v
			end
		end
	end
	return mejor
end

function MapService:ResolverPuertas()
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
		if cfg then
			local okRuta, instancia = pcall(self.ResolverRuta, self, cfg.Ruta)
			if okRuta and instancia then
				local hoja = nil
				if typeof(cfg.Hoja) == "string" and cfg.Hoja ~= "" then
					hoja = instancia:FindFirstChild(cfg.Hoja) or instancia:FindFirstChild(cfg.Hoja, true)
					if not hoja then
						self:Advertir("Puerta " .. id .. ": no se encontró la hoja '" .. cfg.Hoja .. "' en " .. tostring(cfg.Ruta) .. ".")
					end
				end
				local okPrincipal, principal = pcall(partePrincipal, hoja or instancia)
				self._puertas[id] = {
					Id = id,
					Config = cfg,
					Instancia = instancia,
					Hoja = hoja,
					Principal = okPrincipal and principal or nil,
				}
			else
				table.insert(self._puertasNoResueltas, id)
				self:Advertir("Puerta " .. id .. " no resuelta: " .. tostring(cfg.Ruta))
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- API pública
---------------------------------------------------------------------------------------------------

-- Tabla de zona de MapaLogico (o nil).
function MapService:Zona(id)
	return Zones.Zona(id)
end

-- Zona (tabla) que contiene la posición; la más pequeña si hay varias.
function MapService:ZonaDe(posicion)
	return Zones.ZonaDe(posicion)
end

-- Part invisible de la zona en Workspace.ColegioRP_Mapa.Zonas (o nil).
function MapService:ZonaParte(id)
	return self._zonasParte and self._zonasParte[id] or nil
end

-- ¿El id es un aula construida?
function MapService:EsAula(roomId)
	return self._aulas ~= nil and self._aulas[roomId] ~= nil
end

-- { RoomId, Model, Seats = {Seat...}, Duplicados, Indice, Capacidad, Esperados, Tablero, TableroGui,
--   FuenteTablero, PuestoDocente, Zona } o nil.
function MapService:Aula(roomId)
	return self._aulas and self._aulas[roomId] or nil
end

-- { roomId = info } de todas las aulas construidas.
function MapService:Aulas()
	return self._aulas or {}
end

-- Ids de aula en el orden de MapaLogico.Aulas (copia).
function MapService:ListaAulas()
	return copiarArray(self._listaAulas)
end

-- RoomId del aula a la que pertenece un Seat (también para los Seats duplicados) o nil.
function MapService:AulaDeAsiento(seat)
	return self._aulaDeSeat and self._aulaDeSeat[seat] or nil
end

-- Seat conservado equivalente (el propio Seat si no es un duplicado).
function MapService:AsientoCanonico(seat)
	if self._canonico and self._canonico[seat] then
		return self._canonico[seat]
	end
	return seat
end

-- Array de registros de PC { Id, Pantalla, Seat, RoomId, Modelo, Marcador } (copia del array).
function MapService:PCs()
	return copiarArray(self._pcs)
end

function MapService:PC(pcId)
	return self._pcPorId and self._pcPorId[pcId] or nil
end

function MapService:PCDeSeat(seat)
	return self._pcPorSeat and self._pcPorSeat[seat] or nil
end

function MapService:PCDePantalla(parte)
	return self._pcPorPantalla and self._pcPorPantalla[parte] or nil
end

-- { Id, Config, Instancia, Hoja, Principal } de una puerta resuelta, o nil.
function MapService:Puerta(id)
	return self._puertas and self._puertas[id] or nil
end

-- { puertaId = info } de las puertas resueltas.
function MapService:Puertas()
	return self._puertas or {}
end

function MapService:PuertasNoResueltas()
	return copiarArray(self._puertasNoResueltas)
end

-- Carpeta propia por nombre: Zonas, Spawns, Aulas, PCs, Cocina, Cafeteria, Futbol (o nil).
function MapService:Carpeta(nombre)
	return self._carpetas and self._carpetas[nombre] or nil
end

-- Folder raíz Workspace.ColegioRP_Mapa.
function MapService:Raiz()
	return self._raiz
end

-- { Carpeta, Estaciones = {nombre = Part}, Prompts = {nombre = ProximityPrompt}, Reclamo, ReclamoPrompt, Mostrador, Zona } o nil.
function MapService:Cocina()
	return self._cocina
end

function MapService:Estacion(nombre)
	if self._cocina then
		return self._cocina.Estaciones[nombre]
	end
	return nil
end

-- { Carpeta, Mostrador, Prompt, Zona } o nil.
function MapService:Cafeteria()
	return self._cafeteria
end

-- { Carpeta, ZonaId, Balon, ArcoA, ArcoB, Marcador, MarcadorGui, Limites = {Min, Max}, Inicio } o nil.
function MapService:Futbol()
	return self._futbol
end

-- Instancias etiquetadas como decoración pesada (copia).
function MapService:Decoracion()
	return copiarArray(self._decoracion)
end

-- Punto de aparición de la zona: marcador manual > MapaLogico > (opcional) derivado del centro.
-- Devuelve Vector3|nil, estado ("manual" | "confirmado" | "provisional" | "derivado" | "inexistente"), cargos.
function MapService:PuntoSpawn(zonaId, permitirDerivado)
	local lista = self._spawns and self._spawns[zonaId]
	if lista and lista[1] then
		return lista[1].Punto, lista[1].Estado, copiarArray(lista[1].Cargos)
	end
	if not MapaLogico.Zonas[zonaId] then
		return nil, "inexistente", {}
	end
	if permitirDerivado then
		local punto, estado = Zones.PuntoSpawn(zonaId)
		return punto, estado, {}
	end
	return nil, "sin_spawn", {}
end

-- Todos los puntos de spawn de una zona (copia): { { Punto, Estado, Cargos } }.
function MapService:PuntosSpawn(zonaId)
	local salida = {}
	for _, punto in ipairs((self._spawns and self._spawns[zonaId]) or {}) do
		table.insert(salida, { Punto = punto.Punto, Estado = punto.Estado, Cargos = copiarArray(punto.Cargos) })
	end
	return salida
end

-- Estado del spawn de una zona: "manual" | "confirmado" | "provisional" | "sin_spawn" | "inexistente".
function MapService:EstadoSpawn(zonaId)
	local _, estado = self:PuntoSpawn(zonaId, false)
	return estado
end

-- Inventario para la salida del servidor: devuelve (tabla, texto multilínea).
function MapService:Inventario()
	local totalAsientos = 0
	local detalleAulas = {}
	for _, roomId in ipairs(self._listaAulas or {}) do
		local aula = self._aulas[roomId]
		if aula then
			totalAsientos = totalAsientos + #aula.Seats
			table.insert(detalleAulas, {
				RoomId = roomId,
				Asientos = #aula.Seats,
				Duplicados = #aula.Duplicados,
				Esperados = aula.Esperados,
				Tablero = aula.Tablero ~= nil,
				FuenteTablero = aula.FuenteTablero,
				PuestoDocente = aula.PuestoDocente ~= nil,
			})
		end
	end
	local detallePCs = {}
	local conSeat = 0
	for _, pc in ipairs(self._pcs or {}) do
		if pc.Seat then
			conSeat = conSeat + 1
		end
		table.insert(detallePCs, { Id = pc.Id, RoomId = pc.RoomId, Seat = pc.Seat ~= nil })
	end
	local totalPuertas = contarClaves(MapaLogico.Puertas)
	local resueltas = contarClaves(self._puertas)
	local totalSpawns = 0
	for _, lista in pairs(self._spawns or {}) do
		totalSpawns = totalSpawns + #lista
	end
	local instancias = 0
	if self._raiz then
		local ok, desc = pcall(self._raiz.GetDescendants, self._raiz)
		if ok then
			instancias = #desc
		end
	end

	local tabla = {
		Listo = self.Listo == true,
		Zonas = contarClaves(self._zonasParte),
		Aulas = #(self._listaAulas or {}),
		Asientos = totalAsientos,
		PCs = #(self._pcs or {}),
		PCsConSeat = conSeat,
		Puertas = totalPuertas,
		PuertasResueltas = resueltas,
		PuertasNoResueltas = copiarArray(self._puertasNoResueltas),
		Estaciones = self._estaciones or 0,
		Mostradores = self._mostradores or 0,
		Decoracion = #(self._decoracion or {}),
		Spawns = totalSpawns,
		SpawnsManuales = self._spawnsManuales or 0,
		Futbol = self._futbol ~= nil,
		Instancias = instancias,
		DuracionSeg = self._duracionSeg or 0,
		DetalleAulas = detalleAulas,
		DetallePCs = detallePCs,
		Advertencias = copiarArray(self.Advertencias),
	}

	local lineas = {}
	table.insert(lineas, "---- Inventario de MapService (" .. self.NombreCarpeta .. ") ----")
	table.insert(lineas, string.format("Zonas: %d · Spawns: %d (%d manuales) · Instancias propias: %d · Construido en %.2f s",
		tabla.Zonas, tabla.Spawns, tabla.SpawnsManuales, tabla.Instancias, tabla.DuracionSeg))
	local zonasTexto = {}
	for _, id in ipairs(MapaLogico.OrdenZonas or {}) do
		local zona = MapaLogico.Zonas[id]
		if zona then
			local estado = self:EstadoSpawn(id)
			table.insert(zonasTexto, id .. "[" .. tostring(zona.Tipo) .. ", piso " .. tostring(zona.Piso) .. ", spawn " .. estado .. "]")
		end
	end
	table.insert(lineas, "  " .. table.concat(zonasTexto, " "))
	table.insert(lineas, string.format("Aulas: %d · Asientos: %d", tabla.Aulas, tabla.Asientos))
	for _, d in ipairs(detalleAulas) do
		table.insert(lineas, string.format("  %-14s asientos %2d (esperados %2d, duplicados %2d) · tablero: %s · puesto docente: %s",
			d.RoomId, d.Asientos, d.Esperados or 0, d.Duplicados, d.Tablero and tostring(d.FuenteTablero) or "no",
			d.PuestoDocente and "sí" or "no"))
	end
	table.insert(lineas, string.format("PCs: %d (%d con Seat)", tabla.PCs, conSeat))
	local pcsTexto = {}
	for _, pc in ipairs(self._pcs or {}) do
		table.insert(pcsTexto, pc.Id .. (pc.Seat and "" or "*"))
	end
	if #pcsTexto > 0 then
		table.insert(lineas, "  " .. table.concat(pcsTexto, " ") .. "   (* = sin Seat)")
	end
	for _, nota in ipairs(self._notasPC or {}) do
		table.insert(lineas, "  " .. nota)
	end
	table.insert(lineas, string.format("Puertas: %d/%d resueltas", resueltas, totalPuertas))
	local puertasTexto = {}
	for _, id in ipairs(MapaLogico.OrdenPuertas or {}) do
		local p = self._puertas and self._puertas[id]
		if p then
			table.insert(puertasTexto, id .. (p.Hoja and "(hoja)" or ""))
		end
	end
	if #puertasTexto > 0 then
		table.insert(lineas, "  Resueltas: " .. table.concat(puertasTexto, " "))
	end
	if #tabla.PuertasNoResueltas > 0 then
		table.insert(lineas, "  No resueltas: " .. table.concat(tabla.PuertasNoResueltas, " "))
	end
	table.insert(lineas, string.format("Cocina: %d estaciones%s · Mostradores: %d · Cancha: %s · Decoración etiquetada: %d",
		tabla.Estaciones, (self._cocina and self._cocina.Reclamo) and " + reclamo" or "", tabla.Mostradores,
		tabla.Futbol and "sí" or "no", tabla.Decoracion))
	if #tabla.Advertencias > 0 then
		table.insert(lineas, string.format("Advertencias (%d):", #tabla.Advertencias))
		for _, aviso in ipairs(tabla.Advertencias) do
			table.insert(lineas, "  * " .. aviso)
		end
	else
		table.insert(lineas, "Sin advertencias.")
	end
	return tabla, table.concat(lineas, "\n")
end

return MapService
