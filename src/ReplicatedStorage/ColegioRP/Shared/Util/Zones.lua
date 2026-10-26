--[[
	Ruta en el Explorer: ReplicatedStorage.ColegioRP.Shared.Util.Zones
	Tipo: ModuleScript
	Consultas geométricas sobre MapaLogico (zonas como cajas alineadas a los ejes: Centro ± Tamano/2).
	Funciona en cliente y servidor; no crea instancias. ZonaDe(posicion) prioriza la zona más pequeña
	cuando varias contienen el punto (p. ej. un aula dentro de un patio amplio).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local MapaLogico = require(Shared:WaitForChild("MapaLogico"))

local Zones = {}

-- Margen (studs) añadido a cada lado de la caja al comprobar pertenencia. 0 = caja exacta.
Zones.Margen = 0

---------------------------------------------------------------------------------------------------
-- Preparación: lista de zonas ordenadas por volumen ascendente (para ZonaDe)
---------------------------------------------------------------------------------------------------
local function volumen(zona)
	local t = zona.Tamano
	return t.X * t.Y * t.Z
end

local zonasPorVolumen = {}
for _, id in ipairs(MapaLogico.OrdenZonas) do
	local zona = MapaLogico.Zonas[id]
	if zona and typeof(zona.Centro) == "Vector3" and typeof(zona.Tamano) == "Vector3" then
		table.insert(zonasPorVolumen, zona)
	end
end
table.sort(zonasPorVolumen, function(a, b)
	local va, vb = volumen(a), volumen(b)
	if va == vb then
		return a.Id < b.Id
	end
	return va < vb
end)

local setAulas = {}
for _, id in ipairs(MapaLogico.Aulas) do
	setAulas[id] = true
end

---------------------------------------------------------------------------------------------------
-- Resolución de argumentos
---------------------------------------------------------------------------------------------------

-- Acepta un id de zona (string) o la propia tabla de zona; devuelve la tabla o nil.
function Zones.Zona(zonaOId)
	if typeof(zonaOId) == "string" then
		return MapaLogico.Zonas[zonaOId]
	end
	if typeof(zonaOId) == "table" and typeof(zonaOId.Centro) == "Vector3" and typeof(zonaOId.Tamano) == "Vector3" then
		return zonaOId
	end
	return nil
end

-- Devuelve la definición de una puerta de MapaLogico.Puertas o nil.
function Zones.Puerta(puertaId)
	if typeof(puertaId) ~= "string" then
		return nil
	end
	return MapaLogico.Puertas[puertaId]
end

---------------------------------------------------------------------------------------------------
-- Consultas
---------------------------------------------------------------------------------------------------

-- ¿La posición está dentro de la caja de la zona? (zona = id o tabla; posicion = Vector3)
function Zones.Contiene(zonaOId, posicion)
	local zona = Zones.Zona(zonaOId)
	if not zona or typeof(posicion) ~= "Vector3" then
		return false
	end
	local c, t = zona.Centro, zona.Tamano
	local m = Zones.Margen
	return math.abs(posicion.X - c.X) <= t.X / 2 + m
		and math.abs(posicion.Y - c.Y) <= t.Y / 2 + m
		and math.abs(posicion.Z - c.Z) <= t.Z / 2 + m
end

-- Zona que contiene la posición (la más pequeña si hay varias) o nil si está fuera de todas.
function Zones.ZonaDe(posicion)
	if typeof(posicion) ~= "Vector3" then
		return nil
	end
	for _, zona in ipairs(zonasPorVolumen) do
		if Zones.Contiene(zona, posicion) then
			return zona
		end
	end
	return nil
end

-- Id de la zona que contiene la posición o nil.
function Zones.IdDe(posicion)
	local zona = Zones.ZonaDe(posicion)
	if zona then
		return zona.Id
	end
	return nil
end

-- Todas las zonas que contienen la posición, de menor a mayor volumen.
function Zones.ZonasEn(posicion)
	local lista = {}
	if typeof(posicion) ~= "Vector3" then
		return lista
	end
	for _, zona in ipairs(zonasPorVolumen) do
		if Zones.Contiene(zona, posicion) then
			table.insert(lista, zona)
		end
	end
	return lista
end

-- Zonas de un tipo ("aula", "patio", "oficina", ...) en el orden de MapaLogico.OrdenZonas.
function Zones.ZonasTipo(tipo)
	local lista = {}
	for _, id in ipairs(MapaLogico.OrdenZonas) do
		local zona = MapaLogico.Zonas[id]
		if zona and zona.Tipo == tipo then
			table.insert(lista, zona)
		end
	end
	return lista
end

-- Zonas de un piso (0 planta baja, 1 planta alta).
function Zones.ZonasPiso(piso)
	local lista = {}
	for _, id in ipairs(MapaLogico.OrdenZonas) do
		local zona = MapaLogico.Zonas[id]
		if zona and zona.Piso == piso then
			table.insert(lista, zona)
		end
	end
	return lista
end

-- Distancia (studs) desde la posición hasta la caja de la zona; 0 si está dentro.
function Zones.DistanciaA(zonaOId, posicion)
	local zona = Zones.Zona(zonaOId)
	if not zona or typeof(posicion) ~= "Vector3" then
		return math.huge
	end
	local c, t = zona.Centro, zona.Tamano
	local dx = math.max(math.abs(posicion.X - c.X) - t.X / 2, 0)
	local dy = math.max(math.abs(posicion.Y - c.Y) - t.Y / 2, 0)
	local dz = math.max(math.abs(posicion.Z - c.Z) - t.Z / 2, 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Distancia horizontal (ignora Y) del punto al centro de la zona.
function Zones.DistanciaAlCentro(zonaOId, posicion)
	local zona = Zones.Zona(zonaOId)
	if not zona or typeof(posicion) ~= "Vector3" then
		return math.huge
	end
	local dx = posicion.X - zona.Centro.X
	local dz = posicion.Z - zona.Centro.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- Zona más cercana a la posición (opcionalmente solo de un tipo). Devuelve zona, distancia.
function Zones.MasCercana(posicion, tipo)
	if typeof(posicion) ~= "Vector3" then
		return nil, math.huge
	end
	local mejor, mejorDist = nil, math.huge
	for _, id in ipairs(MapaLogico.OrdenZonas) do
		local zona = MapaLogico.Zonas[id]
		if zona and (tipo == nil or zona.Tipo == tipo) then
			local d = Zones.DistanciaA(zona, posicion)
			if d < mejorDist then
				mejor, mejorDist = zona, d
			end
		end
	end
	return mejor, mejorDist
end

-- Lista de aulas (tablas de zona) en el orden de MapaLogico.Aulas.
function Zones.Aulas()
	local lista = {}
	for _, id in ipairs(MapaLogico.Aulas) do
		local zona = MapaLogico.Zonas[id]
		if zona then
			table.insert(lista, zona)
		end
	end
	return lista
end

-- ¿El id corresponde a un aula (aula / aula_especial / aula_pc)?
function Zones.EsAula(zonaId)
	return setAulas[zonaId] == true
end

-- Piso (0/1) de una posición según MapaLogico.Pisos; usa la zona si la hay, si no la altura Y.
function Zones.PisoDe(posicion)
	local zona = Zones.ZonaDe(posicion)
	if zona then
		return zona.Piso
	end
	if typeof(posicion) ~= "Vector3" then
		return 0
	end
	local mejor, mejorDif = 0, math.huge
	for piso, info in pairs(MapaLogico.Pisos) do
		local dif = math.abs(posicion.Y - info.SueloY)
		if dif < mejorDif then
			mejor, mejorDif = piso, dif
		end
	end
	return mejor
end

-- Altura Y del suelo de la zona (según su piso) y altura Y recomendada de aparición.
function Zones.AlturasDe(zonaOId)
	local zona = Zones.Zona(zonaOId)
	local info = zona and MapaLogico.Pisos[zona.Piso] or MapaLogico.Pisos[0]
	return info.SueloY, info.SpawnY
end

-- Punto de aparición de la zona: Spawn.Punto si existe; si no, el centro a la altura de spawn del piso.
-- Devuelve Vector3, estado ("confirmado" | "provisional" | "derivado").
function Zones.PuntoSpawn(zonaOId)
	local zona = Zones.Zona(zonaOId)
	if not zona then
		return nil, "inexistente"
	end
	if zona.Spawn and typeof(zona.Spawn.Punto) == "Vector3" then
		return zona.Spawn.Punto, zona.Spawn.Estado or "confirmado"
	end
	local _, spawnY = Zones.AlturasDe(zona)
	return Vector3.new(zona.Centro.X, spawnY, zona.Centro.Z), "derivado"
end

-- Punto aleatorio dentro de la caja de la zona (en el plano del suelo), con margen interior.
function Zones.PuntoAleatorio(zonaOId, margenInterior)
	local zona = Zones.Zona(zonaOId)
	if not zona then
		return nil
	end
	local margen = margenInterior or 2
	local hx = math.max(zona.Tamano.X / 2 - margen, 0)
	local hz = math.max(zona.Tamano.Z / 2 - margen, 0)
	local _, spawnY = Zones.AlturasDe(zona)
	local x = zona.Centro.X + (math.random() * 2 - 1) * hx
	local z = zona.Centro.Z + (math.random() * 2 - 1) * hz
	return Vector3.new(x, spawnY, z)
end

-- Esquinas mínima y máxima de la caja de la zona (Vector3, Vector3).
function Zones.Limites(zonaOId)
	local zona = Zones.Zona(zonaOId)
	if not zona then
		return nil, nil
	end
	local medio = zona.Tamano / 2
	return zona.Centro - medio, zona.Centro + medio
end

-- CFrame del centro de la zona a nivel de suelo (útil para colocar Parts de zona).
function Zones.CFrameSuelo(zonaOId)
	local zona = Zones.Zona(zonaOId)
	if not zona then
		return nil
	end
	local sueloY = Zones.AlturasDe(zona)
	return CFrame.new(zona.Centro.X, sueloY, zona.Centro.Z)
end

-- Número total de zonas conocidas.
function Zones.Cantidad()
	return #zonasPorVolumen
end

return Zones
