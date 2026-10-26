-- Arnés de pruebas del simulador: arranca el juego, crea jugadores (con o sin cliente), invoca remotos como
-- un jugador, avanza el tiempo y registra resultados PASA / FALLA / OMITIDO con un informe final.

local P = require("planificador")
local T = require("tipos")
local I = require("instancias")
local S = require("servicios")
local E = require("entorno")
local C = require("cargador")

local Sim = {}
Sim.T = T
Sim.P = P
Sim.I = I
Sim.S = S
Sim.resultados = {}
Sim.grupoActual = "general"
Sim.jugadores = {}
local siguienteUserId = 1001

local function raiz() return RAIZ_REPO end

function Sim.nuevo(opciones)
	opciones = opciones or {}
	P.imprimir = opciones.silencioso ~= true
	E.mostrarPrints = opciones.prints == true
	E.mostrarAvisos = opciones.avisos == true
	S.config.studio = opciones.studio ~= false
	S.config.datastoreFalla = opciones.datastoreFalla == true
	S.config.studioSinApi = opciones.studioSinApi == true
	local game = S.crearJuego()
	Sim.game = game
	if opciones.mapa ~= false then
		local archivo = RAIZ_SIM .. "/datos/mapa_rbxl.lua"
		local ok, msg = C.cargarMapa(game, archivo)
		Sim.mapaCargado = ok
		print("  · Mapa: " .. tostring(msg))
	end
	local t0 = relojReal()
	C.cargarSrc(game, raiz() .. "/src")
	local n = C.arrancarServidor(game)
	print(string.format("  · Servidor arrancado: %d scripts de servidor", n))
	Sim.tArranqueReal = relojReal() - t0
	return Sim
end

function Sim.avanzar(seg, paso) P.avanzar(seg, paso) end
function Sim.ahora() return P.ahora end

-- Busca una instancia por ruta "ReplicatedStorage/ColegioRP/Remotes/X" o con puntos.
function Sim.buscar(ruta)
	local cur = Sim.game
	for seg in string.gmatch(ruta, "[^/%.]+") do
		if cur == Sim.game then
			cur = Sim.game:FindService(seg) or I.buscarHijo(Sim.game, seg)
		else
			cur = cur and I.buscarHijo(cur, seg)
		end
		if not cur then return nil end
	end
	return cur
end

function Sim.remoto(nombre)
	local rs = Sim.game:GetService("ReplicatedStorage")
	local rp = I.buscarHijo(rs, "ColegioRP")
	local rem = rp and I.buscarHijo(rp, "Remotes")
	return rem and I.buscarHijo(rem, nombre)
end

-- Ejecuta f en el contexto del servidor y devuelve su resultado (pcall incluido).
function Sim.enServidor(f, ...)
	return P.ejecutarHastaTerminar(f, P.ctxServidor, 30, ...)
end

-- require() de un ModuleScript en el contexto del servidor (misma caché que el juego).
function Sim.requerirServidor(ruta)
	local mod = Sim.buscar(ruta)
	if not mod then return nil, "no existe " .. ruta end
	local ok, valor = P.ejecutarHastaTerminar(function() return E.requerir(P.ctxServidor, mod) end, P.ctxServidor, 30)
	if not ok then return nil, valor end
	return valor
end

-- Obtiene un servicio de ColegioRP del registro del servidor (expuesto en _G o en el módulo).
function Sim.servicio(nombre)
	local sss = Sim.game:GetService("ServerScriptService")
	local carpeta = I.buscarHijo(sss, "ColegioRP")
	local servicios = carpeta and I.buscarHijo(carpeta, "Services")
	local mod = servicios and I.buscarHijo(servicios, nombre)
	if not mod then return nil end
	local e = P.ctxServidor.modulos[mod]
	if e and e.estado == "ok" then return e.valor end
	return nil
end

---------------------------------------------------------------------------- jugadores
local JugadorMT = {}
JugadorMT.__index = JugadorMT

function Sim.jugador(nombre, opciones)
	opciones = opciones or {}
	local userId = opciones.userId or siguienteUserId
	siguienteUserId = siguienteUserId + 1
	local pl = S.crearJugador(nombre, userId, { displayName = opciones.displayName })
	local j = setmetatable({ nombre = nombre, userId = userId, inst = pl, recibidos = {}, opciones = opciones }, JugadorMT)
	if opciones.cliente then
		j.ctx = C.arrancarCliente(Sim.game, pl, opciones.dispositivo)
	else
		j.ctx = E.nuevoContextoCliente(pl, opciones.dispositivo)
		S.contextosCliente[pl] = j.ctx
	end
	-- registrador de EventoCliente en el contexto del cliente
	local function enganchar()
		local rem = Sim.remoto("EventoCliente")
		if not rem then return false end
		P.ejecutar(function()
			rem.OnClientEvent:Connect(function(tipo, datos)
				-- admite tanto (tipo, datos) como ({Tipo=, Datos=})
				if type(tipo) == "table" and datos == nil then
					table.insert(j.recibidos, { tipo = tipo.Tipo, datos = tipo.Datos or tipo, t = P.ahora })
				else
					table.insert(j.recibidos, { tipo = tipo, datos = datos, t = P.ahora })
				end
			end)
		end, j.ctx)
		return true
	end
	if not enganchar() then
		P.task.spawn(function()
			for _ = 1, 300 do
				if enganchar() then return end
				P.task.wait(0.1)
			end
		end)
	end
	Sim.jugadores[#Sim.jugadores + 1] = j
	P.avanzar(0.3)
	return j
end

function JugadorMT:personaje() local c = self.inst._p.Character if c == I.NIL then return nil end return c end
function JugadorMT:raiz() local c = self:personaje() return c and I.buscarHijo(c, "HumanoidRootPart") end
function JugadorMT:humanoide() local c = self:personaje() return c and I.buscarHijo(c, "Humanoid") end
function JugadorMT:posicion() local r = self:raiz() return r and r.Position end
function JugadorMT:atributo(n) return self.inst:GetAttribute(n) end

-- Invoca un RemoteFunction como este jugador. Devuelve (okLlamada, respuesta).
function JugadorMT:invocar(nombre, datos, ...)
	local rem = Sim.remoto(nombre)
	if not rem then return false, "simulador: no existe el remoto " .. nombre end
	local extra = table.pack(...)
	local hayExtra = extra.n > 0
	return P.ejecutarHastaTerminar(function()
		if hayExtra then return rem:InvokeServer(datos, table.unpack(extra, 1, extra.n)) end
		return rem:InvokeServer(datos)
	end, self.ctx, 30)
end
-- Invoca con argumentos crudos (para fuzzing: permite nil, números, etc.)
function JugadorMT:invocarCrudo(nombre, ...)
	local rem = Sim.remoto(nombre)
	if not rem then return false, "simulador: no existe el remoto " .. nombre end
	local args = table.pack(...)
	return P.ejecutarHastaTerminar(function() return rem:InvokeServer(table.unpack(args, 1, args.n)) end, self.ctx, 30)
end
function JugadorMT:disparar(nombre, ...)
	local rem = Sim.remoto(nombre)
	if not rem then return false, "simulador: no existe el remoto " .. nombre end
	local args = table.pack(...)
	local ok, err = P.ejecutarHastaTerminar(function() rem:FireServer(table.unpack(args, 1, args.n)) end, self.ctx, 5)
	P.avanzar(0.1)
	return ok, err
end
function JugadorMT:eventos(tipo)
	local r = {}
	for _, e in ipairs(self.recibidos) do if tipo == nil or e.tipo == tipo then r[#r + 1] = e end end
	return r
end
function JugadorMT:ultimoEvento(tipo, sub)
	for i = #self.recibidos, 1, -1 do
		local e = self.recibidos[i]
		if (tipo == nil or e.tipo == tipo) and (sub == nil or (type(e.datos) == "table" and e.datos.Sub == sub)) then return e end
	end
	return nil
end
function JugadorMT:limpiarEventos() self.recibidos = {} end
function JugadorMT:mover(pos)
	local c = self:personaje()
	if not c then return false end
	local h = self:humanoide()
	if h and h._p.SeatPart and h._p.SeatPart ~= I.NIL then I.levantar(h) end
	c:PivotTo(T.CFrame.new(pos))
	P.avanzar(0.2)
	return true
end
function JugadorMT:sentar(seat)
	local h = self:humanoide()
	if not h then return false end
	self:mover(seat.Position + T.Vector3.new(0, 2, 0))
	seat:Sit(h)
	P.avanzar(0.2)
	return seat._p.Occupant == h
end
function JugadorMT:levantar()
	local h = self:humanoide()
	if h then I.levantar(h) end
	P.avanzar(0.2)
end
function JugadorMT:morir()
	local h = self:humanoide()
	if h then h.Health = 0 end
	P.avanzar(0.2)
end
function JugadorMT:salir()
	S.quitarJugador(self.inst)
	P.avanzar(0.5)
end
function JugadorMT:prompt(pp)
	if not pp then return false end
	P.ejecutar(function()
		local s = I.senalSiExiste(pp, "Triggered")
		if s then P.disparar(s, nil, self.inst) end
		local pps = Sim.game:GetService("ProximityPromptService")
		local s2 = I.senalSiExiste(pps, "PromptTriggered")
		if s2 then P.disparar(s2, nil, pp, self.inst) end
	end, P.ctxServidor)
	P.avanzar(0.3)
	return true
end
function JugadorMT:chat(texto)
	local tcs = Sim.game:GetService("TextChatService")
	local alias = texto:match("^(%S+)")
	for _, d in ipairs(tcs:GetDescendants()) do
		if d:IsA("TextChatCommand") and (d._p.PrimaryAlias == alias or d._p.SecondaryAlias == alias) then
			local fuente
			local canales = tcs:FindFirstChild("TextChannels")
			local general = canales and canales:FindFirstChild("RBXGeneral")
			if general then fuente = general:FindFirstChild(tostring(self.userId)) end
			P.ejecutar(function()
				local s = I.senalSiExiste(d, "Triggered")
				if s then P.disparar(s, nil, fuente, texto) end
			end, P.ctxServidor)
			P.avanzar(0.3)
			return true
		end
	end
	return false
end
function JugadorMT:gui(nombre)
	local pg = self.inst:FindFirstChild("PlayerGui")
	return pg and pg:FindFirstChild(nombre)
end
function JugadorMT:guisColegio()
	local r = {}
	local pg = self.inst:FindFirstChild("PlayerGui")
	if not pg then return r end
	for _, g in ipairs(pg:GetChildren()) do
		if g._p.Name:sub(1, 10) == "ColegioRP_" then r[#r + 1] = g._p.Name end
	end
	table.sort(r)
	return r
end

---------------------------------------------------------------------------- pruebas y aserciones
local actual = nil
function Sim.grupo(nombre) Sim.grupoActual = nombre print("\n== " .. nombre .. " ==") end

function Sim.prueba(nombre, f)
	local erroresAntes = #P.errores
	local r = { grupo = Sim.grupoActual, nombre = nombre, estado = "PASA", detalles = {} }
	actual = r
	local ok, err = pcall(f)
	if not ok then
		if type(err) == "table" and err.omitir then
			r.estado = "OMITIDO"
			table.insert(r.detalles, err.motivo)
		else
			r.estado = "FALLA"
			table.insert(r.detalles, "excepción en la prueba: " .. tostring(err))
		end
	end
	local nuevosJuego = 0
	for i = erroresAntes + 1, #P.errores do
		if P.errores[i].clase == "JUEGO" then nuevosJuego = nuevosJuego + 1 end
	end
	if nuevosJuego > 0 and r.estado == "PASA" and not r.toleraErrores then
		r.estado = "FALLA"
		table.insert(r.detalles, nuevosJuego .. " error(es) del juego durante la prueba (ver lista de errores)")
	end
	actual = nil
	table.insert(Sim.resultados, r)
	print(string.format("  [%s] %s%s", r.estado, nombre, #r.detalles > 0 and (" — " .. table.concat(r.detalles, " | ")) or ""))
	return r
end
function Sim.toleraErrores() if actual then actual.toleraErrores = true end end
function Sim.afirmar(cond, mensaje)
	if not cond then
		if actual then
			actual.estado = "FALLA"
			table.insert(actual.detalles, mensaje or "aserción fallida")
		else
			print("  [FALLA] " .. tostring(mensaje))
		end
	end
	return cond
end
function Sim.omitir(motivo) error({ omitir = true, motivo = motivo }, 0) end
function Sim.nota(texto) if actual then table.insert(actual.detalles, texto) end end

function Sim.informe()
	print("\n================ INFORME DEL SIMULADOR ================")
	local cuenta = { PASA = 0, FALLA = 0, OMITIDO = 0 }
	for _, r in ipairs(Sim.resultados) do cuenta[r.estado] = (cuenta[r.estado] or 0) + 1 end
	print(string.format("Pruebas: %d · PASA %d · FALLA %d · OMITIDO %d", #Sim.resultados, cuenta.PASA, cuenta.FALLA, cuenta.OMITIDO))
	for _, r in ipairs(Sim.resultados) do
		if r.estado ~= "PASA" then
			print(string.format("  %-8s [%s] %s: %s", r.estado, r.grupo, r.nombre, table.concat(r.detalles, " | ")))
		end
	end
	local juego, limit = {}, {}
	local vistos = {}
	for _, e in ipairs(P.errores) do
		local clave = e.mensaje
		if not vistos[clave] then
			vistos[clave] = true
			if e.clase == "LIMITACION" then limit[#limit + 1] = e else juego[#juego + 1] = e end
		end
	end
	print(string.format("\nERRORES DEL JUEGO (únicos): %d", #juego))
	for i, e in ipairs(juego) do
		if i > 40 then print("  … " .. (#juego - 40) .. " más") break end
		print(string.format("  · [%s %.1fs] %s", e.contexto, e.t, e.mensaje))
		local primera = e.traza:match("\n%s*(src/[^\n]-:%d+:[^\n]*)")
		if primera then print("      en " .. primera) end
	end
	print(string.format("\nLIMITACIONES DEL SIMULADOR (únicas): %d", #limit))
	for i, e in ipairs(limit) do
		if i > 30 then print("  … " .. (#limit - 30) .. " más") break end
		print(string.format("  · [%s] %s", e.contexto, e.mensaje))
		local primera = e.traza:match("\n%s*(src/[^\n]-:%d+:[^\n]*)")
		if primera then print("      en " .. primera) end
	end
	local props = {}
	for k, n in pairs(I.avisosPropiedades) do props[#props + 1] = k .. " (" .. n .. ")" end
	table.sort(props)
	if #props > 0 then
		print(string.format("\nPROPIEDADES NO DECLARADAS EN EL SIMULADOR (revisar: ¿propiedad real o error tipográfico?): %d", #props))
		for i, k in ipairs(props) do if i > 60 then break end print("  · " .. k) end
	end
	local fmt = {}
	for k, n in pairs(E.avisosFormato) do fmt[#fmt + 1] = k .. " (" .. n .. ")" end
	if #fmt > 0 then
		print("\nstring.format con %d y número no entero (en Luau lanza error):")
		for _, k in ipairs(fmt) do print("  · " .. k) end
	end
	local avisosJuego = {}
	local vistosA = {}
	for _, a in ipairs(P.avisos) do
		local m = a.mensaje or ""
		if not vistosA[m] then vistosA[m] = true avisosJuego[#avisosJuego + 1] = a end
	end
	print(string.format("\nwarn() del juego (únicos): %d", #avisosJuego))
	for i, a in ipairs(avisosJuego) do
		if i > 40 then print("  … " .. (#avisosJuego - 40) .. " más") break end
		print(string.format("  · [%s %.1fs] %s", a.contexto or "?", a.t or 0, a.mensaje))
	end
	print("========================================================")
	local codigo = (cuenta.FALLA > 0) and 1 or 0
	return codigo, cuenta
end

return Sim
