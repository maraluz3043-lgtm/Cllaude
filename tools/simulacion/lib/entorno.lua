-- Entorno global de cada máquina virtual (servidor y cada cliente): API de Roblox + biblioteca estándar de Luau
-- sobre Lua 5.3, require() con caché por contexto y ejecución de Scripts/LocalScripts como corrutinas.

local P = require("planificador")
local T = require("tipos")
local I = require("instancias")
local S = require("servicios")

local E = {}
E.avisosFormato = {}

---------------------------------------------------------------------------- biblioteca estándar estilo Luau
local function copiaTabla(t) local r = {} for k, v in pairs(t) do r[k] = v end return r end

local tablaLuau = copiaTabla(table)
function tablaLuau.find(t, v, inicio)
	for i = inicio or 1, #t do if t[i] == v then return i end end
	return nil
end
function tablaLuau.create(n, v) local r = {} for i = 1, n do r[i] = v end return r end
function tablaLuau.clear(t) for k in pairs(t) do t[k] = nil end end
function tablaLuau.clone(t)
	if type(t) ~= "table" then error("invalid argument #1 to 'clone' (table expected)", 2) end
	return setmetatable(copiaTabla(t), getmetatable(t))
end
local congeladas = setmetatable({}, { __mode = "k" })
function tablaLuau.freeze(t) congeladas[t] = true return t end
function tablaLuau.isfrozen(t) return congeladas[t] == true end
function tablaLuau.maxn(t) local m = 0 for k in pairs(t) do if type(k) == "number" and k > m then m = k end end return m end
function tablaLuau.getn(t) return #t end
function tablaLuau.foreach(t, f) for k, v in pairs(t) do f(k, v) end end
function tablaLuau.foreachi(t, f) for i, v in ipairs(t) do f(i, v) end end

local mathLuau = copiaTabla(math)
function mathLuau.clamp(x, a, b)
	if b < a then error("invalid argument #3 to 'clamp' (max must be greater than or equal to min)", 2) end
	if x < a then return a end
	if x > b then return b end
	return x
end
function mathLuau.round(x) if x >= 0 then return math.floor(x + 0.5) end return -math.floor(-x + 0.5) end
function mathLuau.sign(x) if x > 0 then return 1 elseif x < 0 then return -1 end return 0 end
function mathLuau.noise(x, y, z)
	local s = math.sin((x or 0) * 12.9898 + (y or 0) * 78.233 + (z or 0) * 37.719) * 43758.5453
	return (s - math.floor(s)) * 2 - 1
end
function mathLuau.log(x, base) if base then return math.log(x) / math.log(base) end return math.log(x) end
mathLuau.pow = function(a, b) return a ^ b end
mathLuau.ldexp = function(m, e) return m * 2 ^ e end
mathLuau.cosh = function(x) return (math.exp(x) + math.exp(-x)) / 2 end
mathLuau.sinh = function(x) return (math.exp(x) - math.exp(-x)) / 2 end
mathLuau.tanh = function(x) local a, b = math.exp(x), math.exp(-x) return (a - b) / (a + b) end
mathLuau.log10 = function(x) return math.log(x, 10) end
mathLuau.atan2 = function(y, x) return math.atan(y, x) end
mathLuau.frexp = function(x)
	if x == 0 then return 0, 0 end
	local e = math.floor(math.log(math.abs(x), 2)) + 1
	return x / 2 ^ e, e
end
mathLuau.lerp = function(a, b, t) return a + (b - a) * t end
mathLuau.map = function(x, a, b, c, d) return c + (x - a) * (d - c) / (b - a) end

local stringLuau = copiaTabla(string)
function stringLuau.split(s, sep)
	sep = sep or ","
	local r = {}
	if sep == "" then
		for i = 1, #s do r[i] = s:sub(i, i) end
		return r
	end
	local inicio = 1
	while true do
		local i, j = string.find(s, sep, inicio, true)
		if not i then r[#r + 1] = s:sub(inicio) break end
		r[#r + 1] = s:sub(inicio, i - 1)
		inicio = j + 1
	end
	return r
end
-- string.format tolerante: en Luau "%d" con un número no entero lanza error igual que en Lua 5.3,
-- pero aquí se registra el sitio para revisarlo y se trunca para seguir la simulación.
local formatoOriginal = string.format
function stringLuau.format(fmt, ...)
	local ok, r = pcall(formatoOriginal, fmt, ...)
	if ok then return r end
	if tostring(r):find("integer representation", 1, true) then
		local args = table.pack(...)
		for i = 1, args.n do
			if type(args[i]) == "number" and args[i] ~= math.floor(args[i]) then args[i] = math.floor(args[i]) end
		end
		local info = debug.getinfo(2, "Sl")
		local sitio = info and (info.short_src .. ":" .. tostring(info.currentline)) or "?"
		E.avisosFormato[sitio] = (E.avisosFormato[sitio] or 0) + 1
		return formatoOriginal(fmt, table.unpack(args, 1, args.n))
	end
	error(r, 2)
end

local function osVirtual()
	local o = copiaTabla(os)
	o.time = function(t) if t then return os.time(t) end return math.floor(P.unixBase + P.ahora) end
	o.clock = function() return P.ahora end
	o.date = function(fmt, t) return os.date(fmt, t or math.floor(P.unixBase + P.ahora)) end
	o.exit = nil
	o.execute = nil
	o.remove = nil
	o.rename = nil
	o.getenv = nil
	o.tmpname = nil
	return o
end
T.relojUnix = function() return P.unixBase + P.ahora end

local bit32 = {}
function bit32.band(...) local r = 0xFFFFFFFF for _, v in ipairs({ ... }) do r = r & (math.floor(v) & 0xFFFFFFFF) end return r end
function bit32.bor(...) local r = 0 for _, v in ipairs({ ... }) do r = r | (math.floor(v) & 0xFFFFFFFF) end return r end
function bit32.bxor(...) local r = 0 for _, v in ipairs({ ... }) do r = r ~ (math.floor(v) & 0xFFFFFFFF) end return r end
function bit32.bnot(x) return (~math.floor(x)) & 0xFFFFFFFF end
function bit32.lshift(x, n) return (math.floor(x) << n) & 0xFFFFFFFF end
function bit32.rshift(x, n) return (math.floor(x) & 0xFFFFFFFF) >> n end
function bit32.arshift(x, n) local v = math.floor(x) & 0xFFFFFFFF if v >= 0x80000000 then v = v - 0x100000000 end return (v >> n) & 0xFFFFFFFF end
function bit32.btest(...) return bit32.band(...) ~= 0 end
function bit32.extract(x, f, w) w = w or 1 return (math.floor(x) >> f) & ((1 << w) - 1) end

-- coroutine compatible con el planificador: si una corrutina creada por el juego cede con task.wait,
-- el planificador se hace cargo de reanudarla (como en Roblox).
local function coroutineLuau()
	local c = copiaTabla(coroutine)
	c.create = function(f) return P.crear(f) end
	c.resume = function(co, ...)
		local res = table.pack(coroutine.resume(co, ...))
		if res[1] and res[2] == P.MARCA then
			if res[3] == "esperar" then
				local dt = res[4] or 0
				if dt < 1 / 60 then dt = 1 / 60 end
				P.programar(co, P.ahora + dt, { "__dt", P.ahora })
			end
			return true
		end
		return table.unpack(res, 1, res.n)
	end
	c.wrap = function(f)
		local co = P.crear(f)
		return function(...)
			local res = table.pack(c.resume(co, ...))
			if not res[1] then error(res[2], 2) end
			return table.unpack(res, 2, res.n)
		end
	end
	c.close = function(co) P.cancelados[co] = true return true end
	return c
end

---------------------------------------------------------------------------- require
local function rutaFuente(mod)
	return rawget(mod, "_archivo") or I.ruta(mod)
end
local CARGANDO = {}
local function requerir(ctx, mod)
	if type(mod) == "number" then error("simulador: require por id de activo no soportado", 2) end
	if not I.esInstancia(mod) or not mod:IsA("ModuleScript") then
		error("Attempted to call require with invalid argument(s).", 2)
	end
	local cache = ctx.modulos
	local e = cache[mod]
	if e then
		if e.estado == "ok" then return e.valor end
		if e.estado == "error" then error("Requested module experienced an error while loading", 2) end
		if e.estado == CARGANDO then
			if e.hilo == coroutine.running() then error("Recursive requires are not supported: " .. I.ruta(mod), 2) end
			while e.estado == CARGANDO do P.ceder(0) end
			if e.estado == "ok" then return e.valor end
			error("Requested module experienced an error while loading", 2)
		end
	end
	e = { estado = CARGANDO, hilo = coroutine.running() }
	cache[mod] = e
	local fuente = mod._p.Source or ""
	local env = E.entorno(ctx, mod)
	local f, err = load(fuente, "@" .. rutaFuente(mod), "t", env)
	if not f then
		e.estado = "error"
		P.registrarError("error de sintaxis en " .. rutaFuente(mod) .. ": " .. tostring(err), coroutine.running())
		error("Requested module experienced an error while loading", 2)
	end
	local res = table.pack(pcall(f))
	if not res[1] then
		e.estado = "error"
		P.registrarError(res[2], coroutine.running())
		error("Requested module experienced an error while loading", 2)
	end
	if res.n < 2 then
		e.estado = "error"
		error("Module code did not return exactly one value", 2)
	end
	e.estado = "ok"
	e.valor = res[2]
	return res[2]
end

---------------------------------------------------------------------------- globales por contexto
function E.globales(ctx)
	if ctx.globales then return ctx.globales end
	local game = S.game
	local g = {}
	local function imprimir(...)
		local n = select("#", ...)
		local t = {}
		for i = 1, n do t[i] = tostring((select(i, ...))) end
		local linea = table.concat(t, " ")
		table.insert(P.salida, { t = P.ahora, contexto = ctx.nombre, texto = linea })
		if P.imprimir and E.mostrarPrints then print(string.format("    [%s %.1fs] %s", ctx.nombre, P.ahora, linea)) end
	end
	local function avisar(...)
		local n = select("#", ...)
		local t = {}
		for i = 1, n do t[i] = tostring((select(i, ...))) end
		local linea = table.concat(t, " ")
		table.insert(P.avisos, { t = P.ahora, contexto = ctx.nombre, mensaje = linea })
		if P.imprimir and E.mostrarAvisos then print(string.format("    [AVISO %s %.1fs] %s", ctx.nombre, P.ahora, linea)) end
	end
	local api = {
		game = game, workspace = game:GetService("Workspace"), Workspace = game:GetService("Workspace"),
		Instance = {
			new = function(clase, padre)
				local inst = I.nuevo(clase)
				if padre then inst.Parent = padre end
				return inst
			end,
			fromExisting = function(x) return x:Clone() end,
		},
		Vector3 = T.Vector3, Vector2 = T.Vector2, CFrame = T.CFrame, Color3 = T.Color3, BrickColor = T.BrickColor,
		UDim = T.UDim, UDim2 = T.UDim2, Enum = T.Enum, NumberRange = T.NumberRange, NumberSequence = T.NumberSequence,
		NumberSequenceKeypoint = T.NumberSequenceKeypoint, ColorSequence = T.ColorSequence, ColorSequenceKeypoint = T.ColorSequenceKeypoint,
		TweenInfo = T.TweenInfo, PhysicalProperties = T.PhysicalProperties, Ray = T.Ray, RaycastParams = T.RaycastParams,
		OverlapParams = T.OverlapParams, Rect = T.Rect, Region3 = T.Region3, Font = T.Font, Random = T.Random, DateTime = T.DateTime,
		typeof = T.typeof, task = P.task,
		wait = function(t) local dt = P.task.wait(t or 0.03) return dt, P.ahora end,
		delay = function(t, f) P.task.delay(t, f) end,
		spawn = function(f) P.task.defer(f) end,
		tick = function() return P.unixBase + P.ahora end,
		time = function() return P.ahora end,
		elapsedTime = function() return P.ahora end,
		print = imprimir, warn = avisar,
		require = function(m) return requerir(ctx, m) end,
		settings = function() return { Rendering = { QualityLevel = T.Enum.QualityLevel.Automatic }, Physics = {}, Network = {} } end,
		UserSettings = function()
			return {
				GameSettings = { SavedQualityLevel = T.Enum.SavedQualitySetting.Automatic, MasterVolume = 1, ComputerMovementMode = T.Enum.ComputerMovementMode.Default, RotationType = T.Enum.RotationType.MovementRelative, GetCameraYInvertValue = function() return 1 end, GetTutorialState = function() return false end },
				GetService = function(self, n) if n == "UserGameSettings" then return self.GameSettings end error("UserSettings: servicio desconocido " .. tostring(n), 2) end,
				IsUserFeatureEnabled = function() return false end,
			}
		end,
		version = function() return "0.600.0.6000000" end,
		gcinfo = function() return collectgarbage("count") end,
		collectgarbage = function(op) if op == "count" then return collectgarbage("count") end return 0 end,
		_G = ctx._G, shared = ctx.shared,
		table = tablaLuau, math = mathLuau, string = stringLuau, os = osVirtual(), utf8 = utf8, bit32 = bit32,
		coroutine = coroutineLuau(),
		debug = { traceback = debug.traceback, info = function(nivel, campos) local i = debug.getinfo((type(nivel) == "number" and nivel + 1) or 2, "Sln") if not i then return nil end return i.short_src, i.currentline, i.name end, profilebegin = function() end, profileend = function() end, setmemorycategory = function() end, resetmemorycategory = function() end },
		pcall = pcall, xpcall = xpcall, error = error, assert = assert, select = select, next = next, pairs = pairs, ipairs = ipairs,
		setmetatable = setmetatable, getmetatable = getmetatable, rawget = rawget, rawset = rawset, rawequal = rawequal, rawlen = rawlen,
		tostring = tostring, tonumber = tonumber, type = type, unpack = table.unpack,
		newproxy = function(conMt) local t = {} if conMt then setmetatable(t, {}) end return t end,
		buffer = nil, loadstring = nil, getfenv = nil, setfenv = nil,
	}
	ctx.globales = api
	return api
end

function E.entorno(ctx, scriptInst)
	local base = E.globales(ctx)
	return setmetatable({ script = scriptInst }, { __index = base })
end

---------------------------------------------------------------------------- contextos
function E.nuevoContextoCliente(jugador, dispositivo)
	return { lado = "cliente", nombre = "cliente:" .. jugador._p.Name, jugador = jugador, dispositivo = dispositivo or "pc", modulos = {}, _G = {}, shared = {} }
end
P.ctxServidor.modulos = P.ctxServidor.modulos or {}
P.ctxServidor._G = P.ctxServidor._G or {}
P.ctxServidor.shared = P.ctxServidor.shared or {}

---------------------------------------------------------------------------- ejecución de scripts
function E.ejecutarScript(scriptInst, ctx)
	if scriptInst._p.Disabled == true or scriptInst._p.Enabled == false then return nil end
	local fuente = scriptInst._p.Source or ""
	local env = E.entorno(ctx, scriptInst)
	local f, err = load(fuente, "@" .. rutaFuente(scriptInst), "t", env)
	if not f then
		P.registrarError("error de sintaxis en " .. rutaFuente(scriptInst) .. ": " .. tostring(err), coroutine.running())
		return nil
	end
	return P.ejecutar(f, ctx)
end
E.requerir = requerir

return E
