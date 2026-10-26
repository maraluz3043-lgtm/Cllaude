-- Planificador con TIEMPO VIRTUAL, biblioteca task, señales (RBXScriptSignal) y contextos de ejecución.
-- Cada corrutina pertenece a un contexto: el servidor o un cliente concreto (jugador). Las señales
-- ejecutan cada manejador en una corrutina nueva con el contexto de quien se conectó, como Roblox.

local P = {}
P.ahora = 0                     -- segundos virtuales desde el arranque
P.cola = {}                     -- { t = vencimiento, co = thread, args = {...} }
P.contextos = setmetatable({}, { __mode = "k" }) -- thread -> contexto
P.errores = {}                  -- errores capturados { mensaje, traza, contexto, t }
P.avisos = {}                   -- warn() capturados
P.salida = {}                   -- print() capturados (opcional)
P.imprimir = true
P.limiteReanudaciones = 200000
P.cancelados = setmetatable({}, { __mode = "k" })
P.unixBase = 1792000000         -- os.time() virtual = base + ahora

local MARCA = {}
P.MARCA = MARCA

P.ctxServidor = { lado = "servidor", nombre = "servidor" }
P.ctxPrincipal = P.ctxServidor

function P.contexto()
	local co = coroutine.running()
	return P.contextos[co] or P.ctxPrincipal
end

function P.esCliente() return P.contexto().lado == "cliente" end

local function clasificar(msg)
	if type(msg) == "string" and msg:find("simulador:", 1, true) then return "LIMITACION" end
	return "JUEGO"
end

function P.registrarError(msg, co)
	local traza = debug.traceback(co, tostring(msg))
	local ctx = P.contextos[co] or P.ctxPrincipal
	local entrada = { mensaje = tostring(msg), traza = traza, contexto = ctx.nombre, t = P.ahora, clase = clasificar(msg) }
	table.insert(P.errores, entrada)
	if P.imprimir then
		print(string.format("  [%s %.1fs %s] %s", entrada.clase == "LIMITACION" and "LIMITACIÓN DEL SIMULADOR" or "ERROR DEL JUEGO", P.ahora, ctx.nombre, tostring(msg)))
	end
end

local secuencia = 0
local function programar(co, t, args)
	secuencia = secuencia + 1
	table.insert(P.cola, { t = t, co = co, args = args, n = secuencia })
end
P.programar = programar

function P.reanudar(co, ...)
	if P.cancelados[co] then return end
	if coroutine.status(co) ~= "suspended" then return end
	local res = table.pack(coroutine.resume(co, ...))
	if not res[1] then
		P.registrarError(res[2], co)
		return
	end
	if coroutine.status(co) == "dead" then return end
	if res[2] == MARCA then
		local tipo = res[3]
		if tipo == "esperar" then
			local dt = res[4] or 0
			if dt < 1 / 60 then dt = 1 / 60 end
			programar(co, P.ahora + dt, { "__dt", P.ahora })
		end
		-- tipo "senal": la reanuda la señal al dispararse
	end
end

function P.crear(f, ctx)
	local co = coroutine.create(f)
	P.contextos[co] = ctx or P.contexto()
	return co
end

-- Ejecuta una función en una corrutina nueva del contexto dado, inmediatamente.
function P.ejecutar(f, ctx, ...)
	local co = P.crear(f, ctx)
	P.reanudar(co, ...)
	return co
end

---------------------------------------------------------------------------- task
local task = {}
function task.spawn(f, ...)
	local co
	if type(f) == "thread" then
		co = f
		if not P.contextos[co] then P.contextos[co] = P.contexto() end
	else
		co = P.crear(f)
	end
	P.reanudar(co, ...)
	return co
end
function task.defer(f, ...)
	local co = type(f) == "thread" and f or P.crear(f)
	programar(co, P.ahora, table.pack(...))
	return co
end
function task.delay(t, f, ...)
	local co = type(f) == "thread" and f or P.crear(f)
	programar(co, P.ahora + (tonumber(t) or 0), table.pack(...))
	return co
end
function task.wait(t)
	t = tonumber(t) or 0
	if coroutine.isyieldable() then
		local inicio = P.ahora
		coroutine.yield(MARCA, "esperar", t)
		return P.ahora - inicio, P.ahora
	end
	-- hilo principal del arnés: avanza el reloj
	P.avanzar(math.max(t, 1 / 60))
	return t, P.ahora
end
function task.cancel(co)
	P.cancelados[co] = true
end
function task.synchronize() end
function task.desynchronize() end
P.task = task

-- Espera genérica usada por WaitForChild, InvokeServer, etc.
function P.ceder(t)
	if coroutine.isyieldable() then
		coroutine.yield(MARCA, "esperar", t or 0)
	else
		P.avanzar(math.max(t or 0, 1 / 60))
	end
end

---------------------------------------------------------------------------- señales
local SenalMT = { __tipo = "RBXScriptSignal" }
local ConexionMT = { __tipo = "RBXScriptConnection" }
local metSenal = {}
local metConexion = {}

function metConexion.Disconnect(c)
	if not c.Connected then return end
	rawset(c, "Connected", false)
	local s = c._senal
	for i, x in ipairs(s._conexiones) do
		if x == c then table.remove(s._conexiones, i) break end
	end
end
ConexionMT.__index = function(c, k)
	local f = metConexion[k]
	if f then return f end
	error("simulador: " .. tostring(k) .. " no es un miembro válido de RBXScriptConnection", 2)
end

function P.nuevaSenal(nombre)
	return setmetatable({ _conexiones = {}, _esperando = {}, _nombre = nombre or "Senal" }, SenalMT)
end

function metSenal.Connect(s, f)
	if type(f) ~= "function" then error("Attempt to connect failed: Passed value is not a function", 2) end
	local c = setmetatable({ Connected = true, _f = f, _senal = s, _ctx = P.contexto() }, ConexionMT)
	table.insert(s._conexiones, c)
	local alc = rawget(s, "_alConectar")
	if alc then alc(c) end
	return c
end
metSenal.ConnectParallel = metSenal.Connect
function metSenal.Once(s, f)
	local c
	c = metSenal.Connect(s, function(...)
		metConexion.Disconnect(c)
		f(...)
	end)
	return c
end
function metSenal.Wait(s)
	if not coroutine.isyieldable() then error("simulador: Wait() de señal llamado fuera de una corrutina", 2) end
	local co = coroutine.running()
	table.insert(s._esperando, co)
	local res = table.pack(coroutine.yield(MARCA, "senal"))
	return table.unpack(res, 1, res.n)
end
SenalMT.__index = function(s, k)
	local f = metSenal[k]
	if f then return f end
	error("simulador: " .. tostring(k) .. " no es un miembro válido de RBXScriptSignal", 2)
end

-- Dispara la señal. filtro(conexion) opcional decide qué conexiones reciben (FireClient).
function P.disparar(s, filtro, ...)
	if not s then return end
	local lista = {}
	for i, c in ipairs(s._conexiones) do lista[i] = c end
	for _, c in ipairs(lista) do
		if c.Connected and (not filtro or filtro(c)) then
			local co = P.crear(c._f, c._ctx)
			P.reanudar(co, ...)
		end
	end
	if #s._esperando > 0 then
		local esperando = s._esperando
		s._esperando = {}
		for _, co in ipairs(esperando) do
			if not filtro or filtro({ _ctx = P.contextos[co] }) then
				P.reanudar(co, ...)
			else
				table.insert(s._esperando, co)
			end
		end
	end
end

function P.desconectarTodo(s)
	if not s then return end
	for _, c in ipairs(s._conexiones) do rawset(c, "Connected", false) end
	s._conexiones = {}
	s._esperando = {}
end

function P.tieneConexiones(s) return s and (#s._conexiones > 0 or #s._esperando > 0) end

---------------------------------------------------------------------------- avance del tiempo
P.alPaso = {} -- funciones(dt) que se ejecutan cada paso (Heartbeat, física...)

local function procesarVencidos()
	local iter = 0
	while true do
		local vencidos = {}
		local resto = {}
		for _, e in ipairs(P.cola) do
			if e.t <= P.ahora + 1e-9 then vencidos[#vencidos + 1] = e else resto[#resto + 1] = e end
		end
		if #vencidos == 0 then break end
		P.cola = resto
		table.sort(vencidos, function(a, b) if a.t ~= b.t then return a.t < b.t end return (a.n or 0) < (b.n or 0) end)
		for _, e in ipairs(vencidos) do
			iter = iter + 1
			if e.args and e.args[1] == "__dt" then
				P.reanudar(e.co, P.ahora - e.args[2])
			elseif e.args then
				P.reanudar(e.co, table.unpack(e.args, 1, e.args.n or #e.args))
			else
				P.reanudar(e.co)
			end
		end
		if iter > P.limiteReanudaciones then
			table.insert(P.errores, { mensaje = "simulador: demasiadas reanudaciones en un paso (¿bucle sin espera?)", traza = "", contexto = "planificador", t = P.ahora, clase = "LIMITACION" })
			break
		end
	end
end

function P.avanzar(segundos, paso)
	paso = paso or 0.1
	local objetivo = P.ahora + (segundos or 0)
	procesarVencidos()
	while P.ahora < objetivo - 1e-9 do
		local dt = math.min(paso, objetivo - P.ahora)
		P.ahora = P.ahora + dt
		for _, f in ipairs(P.alPaso) do
			local ok, err = pcall(f, dt)
			if not ok then P.registrarError(err, coroutine.running()) end
		end
		procesarVencidos()
	end
end

-- Ejecuta f en una corrutina del contexto dado y avanza el reloj hasta que termine (o venza el plazo).
function P.ejecutarHastaTerminar(f, ctx, plazo, ...)
	local terminado, resultado = false, nil
	local args = table.pack(...)
	local co = P.crear(function()
		resultado = table.pack(pcall(f, table.unpack(args, 1, args.n)))
		terminado = true
	end, ctx)
	P.reanudar(co)
	local limite = P.ahora + (plazo or 30)
	while not terminado and P.ahora < limite do
		P.avanzar(0.05, 0.05)
	end
	if not terminado then return false, "simulador: tiempo agotado esperando la respuesta" end
	return table.unpack(resultado, 1, resultado.n)
end

return P
