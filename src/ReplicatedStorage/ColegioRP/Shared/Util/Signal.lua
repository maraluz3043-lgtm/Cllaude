--[[
	Ruta en el Explorer: ReplicatedStorage.ColegioRP.Shared.Util.Signal
	Tipo: ModuleScript
	Señal ligera (patrón BindableEvent en Lua puro) para comunicar módulos del mismo lado
	sin crear instancias. API: Signal.new() -> :Connect(fn), :Once(fn), :Fire(...), :Wait(), :Destroy().
]]

local Signal = {}
Signal.__index = Signal

local Conexion = {}
Conexion.__index = Conexion

-- Conexión devuelta por :Connect; imita a RBXScriptConnection (Connected, Disconnect).
function Conexion.new(senal, fn)
	return setmetatable({ _senal = senal, _fn = fn, Connected = true }, Conexion)
end

function Conexion:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false
	local lista = self._senal and self._senal._conexiones
	if lista then
		for i = #lista, 1, -1 do
			if lista[i] == self then
				table.remove(lista, i)
				break
			end
		end
	end
	self._senal = nil
	self._fn = nil
end

Conexion.Destroy = Conexion.Disconnect

-- Crea una señal nueva.
function Signal.new()
	return setmetatable({ _conexiones = {}, _destruida = false }, Signal)
end

-- Comprueba si un valor es una señal creada con este módulo.
function Signal.Es(valor)
	return typeof(valor) == "table" and getmetatable(valor) == Signal
end

-- Conecta una función; devuelve una conexión con :Disconnect().
function Signal:Connect(fn)
	assert(typeof(fn) == "function", "Signal:Connect espera una función")
	if self._destruida then
		-- Señal destruida: devolvemos una conexión ya desconectada para no romper al llamador.
		local muerta = Conexion.new(nil, fn)
		muerta.Connected = false
		return muerta
	end
	local conexion = Conexion.new(self, fn)
	table.insert(self._conexiones, conexion)
	return conexion
end

-- Conecta una función que se desconecta sola tras el primer disparo.
function Signal:Once(fn)
	assert(typeof(fn) == "function", "Signal:Once espera una función")
	local conexion
	conexion = self:Connect(function(...)
		if conexion then
			conexion:Disconnect()
		end
		fn(...)
	end)
	return conexion
end

-- Dispara la señal; cada manejador corre en su propio hilo (un error no afecta a los demás).
function Signal:Fire(...)
	if self._destruida then
		return
	end
	local copia = {}
	for i, conexion in ipairs(self._conexiones) do
		copia[i] = conexion
	end
	for _, conexion in ipairs(copia) do
		if conexion.Connected and conexion._fn then
			task.spawn(conexion._fn, ...)
		end
	end
end

-- Bloquea el hilo actual hasta el siguiente disparo y devuelve sus argumentos.
function Signal:Wait()
	if self._destruida then
		return
	end
	local hilo = coroutine.running()
	local conexion
	conexion = self:Connect(function(...)
		if conexion then
			conexion:Disconnect()
		end
		task.spawn(hilo, ...)
	end)
	return coroutine.yield()
end

-- Desconecta todas las conexiones sin destruir la señal.
function Signal:DisconnectAll()
	for _, conexion in ipairs(self._conexiones) do
		conexion.Connected = false
		conexion._senal = nil
		conexion._fn = nil
	end
	table.clear(self._conexiones)
end

-- Número de conexiones activas (útil para pruebas y métricas).
function Signal:Cantidad()
	return #self._conexiones
end

-- Destruye la señal: desconecta todo y rechaza nuevas conexiones.
function Signal:Destroy()
	self:DisconnectAll()
	self._destruida = true
end

return Signal
