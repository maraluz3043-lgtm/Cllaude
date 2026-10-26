--[[
	Ruta en el Explorer: ReplicatedStorage.ColegioRP.Shared.Util.Net
	Tipo: ModuleScript
	Acceso seguro a los remotos de ReplicatedStorage.ColegioRP.Remotes desde cliente y servidor.
	Evento/Funcion esperan la instancia (WaitForChild con timeout); en cliente, Invocar hace pcall de
	InvokeServer y devuelve siempre (ok, tablaRespuesta), y Disparar hace FireServer con pcall.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local Net = {}

-- Segundos máximos de espera por la carpeta o por cada remoto.
Net.Timeout = (Config.Red and Config.Red.TimeoutRemotosSeg) or 30
-- Nombre de la carpeta de remotos (la crea RemoteService en el servidor).
Net.NombreCarpeta = (Config.Nombres and Config.Nombres.CarpetaRemotos) or "Remotes"
-- Nombre del canal multiplexado servidor -> cliente.
Net.NombreEventoCliente = "EventoCliente"

local esCliente = RunService:IsClient()
local esServidor = RunService:IsServer()
local cache = {}
local avisados = {}

local function avisarUnaVez(clave, mensaje)
	if avisados[clave] then
		return
	end
	avisados[clave] = true
	warn("[ColegioRP][Net] " .. mensaje)
end

---------------------------------------------------------------------------------------------------
-- Carpeta de remotos
---------------------------------------------------------------------------------------------------

-- Devuelve la carpeta Remotes. En servidor, con crearSiFalta = true, la crea si no existe.
-- En cliente (o sin crear) espera hasta Net.Timeout y devuelve nil si no aparece.
function Net.Carpeta(crearSiFalta)
	local carpeta = RP:FindFirstChild(Net.NombreCarpeta)
	if carpeta then
		return carpeta
	end
	if crearSiFalta and esServidor then
		carpeta = Instance.new("Folder")
		carpeta.Name = Net.NombreCarpeta
		carpeta.Parent = RP
		return carpeta
	end
	carpeta = RP:WaitForChild(Net.NombreCarpeta, Net.Timeout)
	if not carpeta then
		avisarUnaVez("carpeta", "La carpeta " .. Net.NombreCarpeta .. " no apareció en " .. Net.Timeout .. " s")
	end
	return carpeta
end

local function obtener(nombre, clase)
	if typeof(nombre) ~= "string" or nombre == "" then
		return nil
	end
	local enCache = cache[nombre]
	if enCache and enCache.Parent ~= nil then
		return enCache
	end
	local carpeta = Net.Carpeta(false)
	if not carpeta then
		return nil
	end
	local instancia = carpeta:FindFirstChild(nombre)
	if not instancia then
		instancia = carpeta:WaitForChild(nombre, Net.Timeout)
	end
	if not instancia then
		avisarUnaVez("remoto:" .. nombre, "El remoto '" .. nombre .. "' no apareció en " .. Net.Timeout .. " s")
		return nil
	end
	if not instancia:IsA(clase) then
		avisarUnaVez("clase:" .. nombre, "El remoto '" .. nombre .. "' es " .. instancia.ClassName .. " y se esperaba " .. clase)
		return nil
	end
	cache[nombre] = instancia
	return instancia
end

-- RemoteEvent por nombre (o nil tras el timeout, con warn).
function Net.Evento(nombre)
	return obtener(nombre, "RemoteEvent")
end

-- RemoteFunction por nombre (o nil tras el timeout, con warn).
function Net.Funcion(nombre)
	return obtener(nombre, "RemoteFunction")
end

-- Olvida una entrada de la caché (útil si RemoteService recrea un remoto).
function Net.Olvidar(nombre)
	cache[nombre] = nil
end

---------------------------------------------------------------------------------------------------
-- Cliente -> servidor
---------------------------------------------------------------------------------------------------

local function respuestaError(mensaje)
	return { ok = false, error = mensaje }
end

-- (Cliente) Invoca una RemoteFunction con una tabla de datos. Devuelve ok, respuesta.
-- 'respuesta' siempre es una tabla { ok, error, datos }; ok es true solo si la red funcionó y el
-- servidor respondió ok = true. Nunca lanza errores.
function Net.Invocar(nombre, datos)
	if not esCliente then
		return false, respuestaError("Net.Invocar solo puede usarse en el cliente")
	end
	if datos == nil then
		datos = {}
	end
	if typeof(datos) ~= "table" then
		return false, respuestaError("los datos deben ser una tabla")
	end
	local remoto = Net.Funcion(nombre)
	if not remoto then
		return false, respuestaError("remoto no disponible: " .. tostring(nombre))
	end
	local exito, respuesta = pcall(remoto.InvokeServer, remoto, datos)
	if not exito then
		return false, respuestaError("error de red: " .. tostring(respuesta))
	end
	if typeof(respuesta) ~= "table" then
		return false, respuestaError("respuesta inválida del servidor")
	end
	if respuesta.ok ~= true then
		if respuesta.error == nil then
			respuesta.error = "rechazado"
		end
		respuesta.ok = false
		return false, respuesta
	end
	return true, respuesta
end

-- (Cliente) Dispara un RemoteEvent con una tabla de datos. Devuelve true si se envió.
function Net.Disparar(nombre, datos)
	if not esCliente then
		warn("[ColegioRP][Net] Net.Disparar solo puede usarse en el cliente")
		return false
	end
	if datos == nil then
		datos = {}
	end
	if typeof(datos) ~= "table" then
		return false
	end
	local remoto = Net.Evento(nombre)
	if not remoto then
		return false
	end
	local exito, err = pcall(remoto.FireServer, remoto, datos)
	if not exito then
		warn("[ColegioRP][Net] Error al disparar '" .. tostring(nombre) .. "': " .. tostring(err))
		return false
	end
	return true
end

---------------------------------------------------------------------------------------------------
-- Servidor -> cliente (canal EventoCliente: { Tipo = string, Datos = tabla })
---------------------------------------------------------------------------------------------------

-- (Cliente) Se suscribe a EventoCliente filtrando por Tipo. callback(datos, carga).
-- Devuelve la RBXScriptConnection (o nil si el remoto no existe) para guardarla en un Maid.
function Net.Escuchar(tipo, callback)
	assert(typeof(callback) == "function", "Net.Escuchar espera una función")
	if not esCliente then
		warn("[ColegioRP][Net] Net.Escuchar solo puede usarse en el cliente")
		return nil
	end
	local remoto = Net.Evento(Net.NombreEventoCliente)
	if not remoto then
		return nil
	end
	return remoto.OnClientEvent:Connect(function(carga)
		if typeof(carga) ~= "table" then
			return
		end
		if tipo ~= nil and carga.Tipo ~= tipo then
			return
		end
		local datos = carga.Datos
		if datos == nil then
			datos = {}
		end
		local ok, err = pcall(callback, datos, carga)
		if not ok then
			warn("[ColegioRP][Net] Error en manejador de '" .. tostring(carga.Tipo) .. "': " .. tostring(err))
		end
	end)
end

-- (Servidor) Envía por EventoCliente a un jugador. RemoteService lo usa internamente.
function Net.EnviarA(player, tipo, datos)
	if not esServidor then
		return false
	end
	local remoto = Net.Evento(Net.NombreEventoCliente)
	if not remoto or typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end
	local exito, err = pcall(remoto.FireClient, remoto, player, { Tipo = tipo, Datos = datos or {} })
	if not exito then
		warn("[ColegioRP][Net] Error al enviar '" .. tostring(tipo) .. "': " .. tostring(err))
		return false
	end
	return true
end

-- (Servidor) Envía por EventoCliente a todos los jugadores.
function Net.EnviarATodos(tipo, datos)
	if not esServidor then
		return false
	end
	local remoto = Net.Evento(Net.NombreEventoCliente)
	if not remoto then
		return false
	end
	local exito, err = pcall(remoto.FireAllClients, remoto, { Tipo = tipo, Datos = datos or {} })
	if not exito then
		warn("[ColegioRP][Net] Error al enviar a todos '" .. tostring(tipo) .. "': " .. tostring(err))
		return false
	end
	return true
end

-- Construye la respuesta estándar de éxito de una RemoteFunction.
function Net.Ok(datos)
	return { ok = true, datos = datos }
end

-- Construye la respuesta estándar de error de una RemoteFunction.
function Net.Error(mensaje)
	return { ok = false, error = tostring(mensaje or "error") }
end

Net.EsCliente = esCliente
Net.EsServidor = esServidor

return Net
