--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.MetricsService
	Tipo: ModuleScript
	Métricas del servidor (prueba P15): jugadores actuales y pico, rechazos de remotos por motivo, latencia de
	handlers, instancias propias, memoria, tiempo de arranque y FPS reportado por los clientes (StaffService
	llama a RegistrarMetricaCliente). Informe() devuelve una tabla para el panel del Director y Texto() un resumen.
]]

local Players = game:GetService("Players")
local Stats = game:GetService("Stats")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local RemoteContracts = require(Shared:WaitForChild("RemoteContracts"))
local Validate = require(Shared:WaitForChild("Util"):WaitForChild("Validate"))

local MetricsService = {}
MetricsService.Nombre = "MetricsService"

local PREFIJO = "[ColegioRP][MetricsService]"

---------------------------------------------------------------------------------------------------
-- Parámetros
---------------------------------------------------------------------------------------------------
MetricsService.IntervaloClienteSeg = (Config.Metricas and Config.Metricas.IntervaloClienteSeg) or 30 -- Mínimo entre envíos de un cliente.
MetricsService.ToleranciaIntervalo = 0.9 -- Fracción del intervalo aceptada (deriva del temporizador del cliente).
MetricsService.IntervaloMuestreoSeg = 30 -- Muestreo periódico de memoria y pico de jugadores.
MetricsService.MaxMotivos = 64 -- Motivos de rechazo distintos guardados (el resto se agrupa en "otros").
MetricsService.MaxRemotos = 64 -- Remotos distintos guardados en los rechazos.
MetricsService.MaxHandlers = 128 -- Handlers distintos con tiempos guardados.
MetricsService.MaxClaveCaracteres = 48 -- Longitud máxima de un nombre de motivo/remoto/handler.
MetricsService.Top = 10 -- Elementos de las listas "top" del informe.

-- Valores reconocidos de los campos de texto enviados por el cliente (el resto se agrupa como "Otro";
-- así ningún texto libre de un jugador llega al panel de otro jugador).
MetricsService.DispositivosConocidos = { "PC", "Tableta", "Movil", "Mando", "Consola" }
MetricsService.ModosConocidos = RemoteContracts.ModosGraficos or { "Automatico", "Calidad", "Medio", "Bajos" }

local ESQUEMA_CLIENTE = Validate.Esquema({
	FPS = Validate.Num(0, 1000),
	Dispositivo = Validate.Str(16, false, 1),
	ModoGraficos = Validate.Str(16, false, 1),
	Memoria = Validate.Num(0, 1000000, true),
})

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function esJugador(player)
	return typeof(player) == "Instance" and player:IsA("Player")
end

local function esFinito(n)
	return typeof(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function contarClaves(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

local function conjunto(lista)
	local s = {}
	for _, v in ipairs(lista or {}) do
		s[v] = true
	end
	return s
end

local setDispositivos = conjunto(MetricsService.DispositivosConocidos)
local setModos = conjunto(MetricsService.ModosConocidos)

-- Texto seguro para usar como clave: sin caracteres de control y acotado.
local function claveSegura(valor, porDefecto)
	if valor == nil then
		return porDefecto or "desconocido"
	end
	local texto = string.gsub(tostring(valor), "%c", "")
	if texto == "" then
		return porDefecto or "desconocido"
	end
	if #texto > MetricsService.MaxClaveCaracteres then
		texto = string.sub(texto, 1, MetricsService.MaxClaveCaracteres)
	end
	return texto
end

-- Suma 1 a tabla[clave]; si la tabla ya tiene "maximo" claves distintas, se acumula en "otros".
local function incrementar(tabla, clave, maximo)
	if tabla[clave] == nil and contarClaves(tabla) >= maximo then
		clave = "otros"
	end
	tabla[clave] = (tabla[clave] or 0) + 1
end

-- { clave = n } -> array { { Clave, N } } ordenado de mayor a menor, máximo "limite" elementos.
local function top(tabla, limite, nombreClave)
	local lista = {}
	for clave, n in pairs(tabla) do
		table.insert(lista, { clave, n })
	end
	table.sort(lista, function(a, b)
		if a[2] == b[2] then
			return tostring(a[1]) < tostring(b[1])
		end
		return a[2] > b[2]
	end)
	local salida = {}
	for i = 1, math.min(limite, #lista) do
		local fila = { N = lista[i][2] }
		fila[nombreClave] = lista[i][1]
		table.insert(salida, fila)
	end
	return salida
end

local function redondear(n, decimales)
	if not esFinito(n) then
		return nil
	end
	local factor = 10 ^ (decimales or 2)
	return math.floor(n * factor + 0.5) / factor
end

local function memoriaActualMB()
	local ok, mb = pcall(function()
		return Stats:GetTotalMemoryUsageMb()
	end)
	if ok and esFinito(mb) then
		return mb
	end
	return nil
end

local function contarDescendientes(instancia)
	if typeof(instancia) ~= "Instance" then
		return 0
	end
	local ok, lista = pcall(instancia.GetDescendants, instancia)
	if ok and typeof(lista) == "table" then
		return #lista
	end
	return 0
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function MetricsService:Init(registro)
	self.registro = registro
	self.InitClock = os.clock()
	self.InicioUnix = os.time()
	self.StartClock = nil
	self.ArranqueSeg = nil -- de Init a Start de este servicio
	self.ArranqueTotalSeg = nil -- desde el inicio de Main (si el registro lo expone)
	self.Pico = #Players:GetPlayers()
	self.Rechazos = { Total = 0, PorMotivo = {}, PorRemoto = {} }
	self.Handlers = {} -- nombre -> { Suma, N, Max }
	self.Clientes = {} -- userId -> última métrica del cliente + media
	self.MemoriaPicoMB = 0
	self.Conexiones = {}
	self.Activo = false
end

function MetricsService:Start()
	self.StartClock = os.clock()
	self.ArranqueSeg = self.StartClock - (self.InitClock or self.StartClock)
	local arranque = self.registro and self.registro.Arranque
	if typeof(arranque) == "table" and typeof(arranque.InicioClock) == "number" then
		self.ArranqueTotalSeg = self.StartClock - arranque.InicioClock
	end

	self:ActualizarPico()
	table.insert(self.Conexiones, Players.PlayerAdded:Connect(function()
		self:ActualizarPico()
	end))
	table.insert(self.Conexiones, Players.PlayerRemoving:Connect(function(player)
		self.Clientes[player.UserId] = nil
	end))

	self:Muestrear()
	self.Activo = true
	task.spawn(function()
		while self.Activo do
			task.wait(self.IntervaloMuestreoSeg)
			if not self.Activo then
				break
			end
			local ok, err = pcall(self.Muestrear, self)
			if not ok then
				warn(PREFIJO .. " Error en el muestreo: " .. tostring(err))
			end
		end
	end)

	local AuditLog = self.registro and self.registro.Get("AuditLogService")
	if AuditLog then
		AuditLog:Registrar("Sistema", nil, "Metricas", string.format("MetricsService activo · arranque %.2f s (total %.2f s)",
			self.ArranqueSeg or 0, self.ArranqueTotalSeg or self.ArranqueSeg or 0))
	end
end

-- Detiene el muestreo y desconecta los eventos (cierre del servidor o pruebas).
function MetricsService:Detener()
	self.Activo = false
	for _, conexion in ipairs(self.Conexiones or {}) do
		pcall(function()
			conexion:Disconnect()
		end)
	end
	self.Conexiones = {}
end

function MetricsService:ActualizarPico()
	local n = #Players:GetPlayers()
	if n > (self.Pico or 0) then
		self.Pico = n
	end
	return self.Pico
end

function MetricsService:Muestrear()
	self:ActualizarPico()
	local mb = memoriaActualMB()
	if mb and mb > (self.MemoriaPicoMB or 0) then
		self.MemoriaPicoMB = mb
	end
	return mb
end

---------------------------------------------------------------------------------------------------
-- Entradas de otros servicios
---------------------------------------------------------------------------------------------------

-- Cuenta un rechazo de remoto. Acepta IncrementarRechazo(motivo) o IncrementarRechazo(remoto, motivo)
-- (RemoteService usa la segunda forma).
function MetricsService:IncrementarRechazo(remotoOMotivo, motivo)
	if not self.Rechazos then
		return
	end
	local remoto = nil
	if motivo == nil then
		motivo = remotoOMotivo
	else
		remoto = remotoOMotivo
	end
	self.Rechazos.Total = self.Rechazos.Total + 1
	incrementar(self.Rechazos.PorMotivo, claveSegura(motivo, "desconocido"), self.MaxMotivos)
	if remoto ~= nil then
		incrementar(self.Rechazos.PorRemoto, claveSegura(remoto, "desconocido"), self.MaxRemotos)
	end
end

-- Tiempo (segundos) que tardó un handler de remoto.
function MetricsService:RegistrarTiempoHandler(nombre, seg)
	if not self.Handlers or not esFinito(seg) or seg < 0 then
		return
	end
	local clave = claveSegura(nombre, "desconocido")
	local t = self.Handlers[clave]
	if not t then
		if contarClaves(self.Handlers) >= self.MaxHandlers then
			clave = "otros"
			t = self.Handlers[clave]
		end
		if not t then
			t = { Suma = 0, N = 0, Max = 0 }
			self.Handlers[clave] = t
		end
	end
	t.Suma = t.Suma + seg
	t.N = t.N + 1
	if seg > t.Max then
		t.Max = seg
	end
end

-- Métrica enviada por un cliente (StaffAction { Accion = "Metrica", Datos = {...} } → StaffService).
-- datos = { FPS = number 0..1000, Dispositivo = string ≤ 16, ModoGraficos = string ≤ 16, Memoria = number opcional }.
-- Devuelve true, o false y un motivo ("jugador_invalido", "esquema: ...", "limite").
function MetricsService:RegistrarMetricaCliente(player, datos)
	if not esJugador(player) then
		return false, "jugador_invalido"
	end
	if not self.Clientes then
		return false, "sin_servicio"
	end
	local ok, err = Validate.Comprobar(ESQUEMA_CLIENTE, datos)
	if not ok then
		return false, "esquema: " .. tostring(err)
	end
	local ahora = os.clock()
	local entrada = self.Clientes[player.UserId]
	if entrada and entrada.UltimoClock and ahora - entrada.UltimoClock < self.IntervaloClienteSeg * self.ToleranciaIntervalo then
		return false, "limite"
	end
	if not entrada then
		entrada = { N = 0, SumaFPS = 0, MinFPS = math.huge, MaxFPS = 0 }
		self.Clientes[player.UserId] = entrada
	end
	local dispositivo = datos.Dispositivo
	if not setDispositivos[dispositivo] then
		dispositivo = "Otro"
	end
	local modo = datos.ModoGraficos
	if not setModos[modo] then
		modo = "Otro"
	end
	entrada.Nombre = player.Name
	entrada.FPS = datos.FPS
	entrada.Dispositivo = dispositivo
	entrada.ModoGraficos = modo
	entrada.Memoria = datos.Memoria
	entrada.N = entrada.N + 1
	entrada.SumaFPS = entrada.SumaFPS + datos.FPS
	entrada.MediaFPS = entrada.SumaFPS / entrada.N
	if datos.FPS < entrada.MinFPS then
		entrada.MinFPS = datos.FPS
	end
	if datos.FPS > entrada.MaxFPS then
		entrada.MaxFPS = datos.FPS
	end
	entrada.UltimoClock = ahora
	entrada.T = os.time()
	return true
end

-- Copia de la última métrica de un jugador (o nil).
function MetricsService:MetricaCliente(player)
	if not esJugador(player) or not self.Clientes then
		return nil
	end
	local e = self.Clientes[player.UserId]
	if not e then
		return nil
	end
	return {
		FPS = e.FPS, MediaFPS = redondear(e.MediaFPS, 1), MinFPS = e.MinFPS, MaxFPS = e.MaxFPS, N = e.N,
		Dispositivo = e.Dispositivo, ModoGraficos = e.ModoGraficos, Memoria = e.Memoria, T = e.T,
	}
end

---------------------------------------------------------------------------------------------------
-- Informe
---------------------------------------------------------------------------------------------------
function MetricsService:EstadisticasRemotos()
	local RemoteService = self.registro and self.registro.Get("RemoteService")
	if RemoteService and typeof(RemoteService.ObtenerEstadisticas) == "function" then
		local ok, stats = pcall(RemoteService.ObtenerEstadisticas, RemoteService)
		if ok and typeof(stats) == "table" then
			return stats
		end
	end
	return nil
end

function MetricsService:ResumenFPS()
	local resumen = { media = nil, min = nil, max = nil, n = 0, porDispositivo = {}, porModo = {} }
	local suma = 0
	local acumDisp, acumModo = {}, {}
	for userId, e in pairs(self.Clientes or {}) do
		if esFinito(e.FPS) and Players:GetPlayerByUserId(userId) then
			resumen.n = resumen.n + 1
			suma = suma + e.FPS
			if resumen.min == nil or e.FPS < resumen.min then
				resumen.min = e.FPS
			end
			if resumen.max == nil or e.FPS > resumen.max then
				resumen.max = e.FPS
			end
			local d = acumDisp[e.Dispositivo]
			if not d then
				d = { Suma = 0, N = 0, Min = math.huge }
				acumDisp[e.Dispositivo] = d
			end
			d.Suma = d.Suma + e.FPS
			d.N = d.N + 1
			if e.FPS < d.Min then
				d.Min = e.FPS
			end
			local m = acumModo[e.ModoGraficos]
			if not m then
				m = { Suma = 0, N = 0 }
				acumModo[e.ModoGraficos] = m
			end
			m.Suma = m.Suma + e.FPS
			m.N = m.N + 1
		end
	end
	if resumen.n > 0 then
		resumen.media = redondear(suma / resumen.n, 1)
	end
	for clave, d in pairs(acumDisp) do
		resumen.porDispositivo[clave] = { media = redondear(d.Suma / d.N, 1), min = d.Min, n = d.N }
	end
	for clave, m in pairs(acumModo) do
		resumen.porModo[clave] = { media = redondear(m.Suma / m.N, 1), n = m.N }
	end
	return resumen
end

-- Tabla del informe (solo datos simples; apta para enviarse al panel del Director).
function MetricsService:Informe()
	local remotos = self:EstadisticasRemotos()

	-- Rechazos: los contados aquí; si RemoteService acumula más (p. ej. antes de existir este servicio), se usan los suyos.
	local totalRechazos = (self.Rechazos and self.Rechazos.Total) or 0
	local porMotivo = (self.Rechazos and self.Rechazos.PorMotivo) or {}
	local porRemoto = (self.Rechazos and self.Rechazos.PorRemoto) or {}
	local fuenteRechazos = "MetricsService"
	if remotos and typeof(remotos.Rechazos) == "number" and remotos.Rechazos > totalRechazos then
		totalRechazos = remotos.Rechazos
		porMotivo = remotos.PorMotivo or {}
		porRemoto = {}
		for nombre, r in pairs(remotos.PorRemoto or {}) do
			if typeof(r) == "table" and (r.Rechazos or 0) > 0 then
				porRemoto[nombre] = r.Rechazos
			end
		end
		fuenteRechazos = "RemoteService"
	end

	-- Handlers: los reportados con RegistrarTiempoHandler; si no hay, los tiempos de RemoteService.
	local filas = {}
	local fuenteHandlers = "MetricsService"
	local sumaTotal, nTotal = 0, 0
	for nombre, t in pairs(self.Handlers or {}) do
		if t.N > 0 then
			table.insert(filas, { Nombre = nombre, Media = t.Suma / t.N, Max = t.Max, N = t.N, Total = t.Suma })
			sumaTotal = sumaTotal + t.Suma
			nTotal = nTotal + t.N
		end
	end
	if #filas == 0 and remotos and typeof(remotos.Tiempos) == "table" then
		fuenteHandlers = "RemoteService"
		for nombre, t in pairs(remotos.Tiempos) do
			if typeof(t) == "table" and esFinito(t.Media) and (t.N or 0) > 0 then
				table.insert(filas, { Nombre = nombre, Media = t.Media, Max = t.Max or t.Media, N = t.N, Total = t.Media * t.N })
				sumaTotal = sumaTotal + t.Media * t.N
				nTotal = nTotal + t.N
			end
		end
	end
	table.sort(filas, function(a, b)
		if a.Media == b.Media then
			return a.Nombre < b.Nombre
		end
		return a.Media > b.Media
	end)
	local handlers = {}
	for i = 1, math.min(self.Top, #filas) do
		local f = filas[i]
		table.insert(handlers, {
			Nombre = f.Nombre,
			MediaMs = redondear(f.Media * 1000, 2),
			MaxMs = redondear(f.Max * 1000, 2),
			N = f.N,
			TotalSeg = redondear(f.Total, 3),
		})
	end

	-- Instancias propias.
	local instanciasMapa = 0
	local MapService = self.registro and self.registro.Get("MapService")
	local carpetaMapa = nil
	if MapService and typeof(MapService.Raiz) == "function" then
		local ok, raiz = pcall(MapService.Raiz, MapService)
		if ok and typeof(raiz) == "Instance" then
			carpetaMapa = raiz
		end
	end
	if not carpetaMapa then
		carpetaMapa = workspace:FindFirstChild((Config.Nombres and Config.Nombres.CarpetaMapa) or "ColegioRP_Mapa")
	end
	instanciasMapa = contarDescendientes(carpetaMapa)

	local memoria = self:Muestrear()
	local ahora = os.clock()

	local informe = {
		Jugadores = #Players:GetPlayers(),
		Pico = self.Pico or 0,
		Rechazos = totalRechazos,
		RechazosPorMotivo = top(porMotivo, self.Top, "Motivo"),
		RechazosPorRemoto = top(porRemoto, self.Top, "Remoto"),
		FuenteRechazos = fuenteRechazos,
		InstanciasMapa = instanciasMapa,
		InstanciasColegioRP = contarDescendientes(RP),
		MemoriaMB = memoria and redondear(memoria, 1) or nil,
		MemoriaPicoMB = redondear(self.MemoriaPicoMB or 0, 1),
		ArranqueSeg = self.ArranqueSeg and redondear(self.ArranqueSeg, 3) or nil,
		ArranqueTotalSeg = self.ArranqueTotalSeg and redondear(self.ArranqueTotalSeg, 3) or nil,
		ActivoSeg = math.floor(ahora - (self.InitClock or ahora)),
		FPSClientes = self:ResumenFPS(),
		Handlers = handlers,
		FuenteHandlers = fuenteHandlers,
		LatenciaMediaMs = nTotal > 0 and redondear(sumaTotal / nTotal * 1000, 2) or nil,
		Remotos = nil,
		Version = tostring(Config.Version or ""),
		Generado = os.time(),
	}
	if remotos then
		informe.Remotos = {
			Peticiones = remotos.Peticiones or 0,
			Aceptadas = remotos.Aceptadas or 0,
			Errores = remotos.Errores or 0,
			Sospechosos = remotos.Sospechosos or 0,
			HandlersRegistrados = remotos.HandlersRegistrados or 0,
		}
	end
	return informe
end

local function num(valor, formato)
	if valor == nil then
		return "—"
	end
	return string.format(formato or "%s", valor)
end

-- Resumen multilínea imprimible del informe.
function MetricsService:Texto()
	local ok, informe = pcall(self.Informe, self)
	if not ok or typeof(informe) ~= "table" then
		return "Métricas no disponibles: " .. tostring(informe)
	end
	local lineas = {}
	table.insert(lineas, "---- Métricas de Colegio RP v" .. informe.Version .. " ----")
	table.insert(lineas, string.format("Jugadores: %d (pico %d) · Activo: %d s · Arranque: %s s (total %s s)",
		informe.Jugadores, informe.Pico, informe.ActivoSeg, num(informe.ArranqueSeg, "%.3f"), num(informe.ArranqueTotalSeg, "%.3f")))
	table.insert(lineas, string.format("Memoria: %s MB (pico %s MB) · Instancias: mapa %d, ReplicatedStorage.ColegioRP %d",
		num(informe.MemoriaMB, "%.1f"), num(informe.MemoriaPicoMB, "%.1f"), informe.InstanciasMapa, informe.InstanciasColegioRP))
	if informe.Remotos then
		table.insert(lineas, string.format("Remotos: %d peticiones, %d aceptadas, %d errores, %d sospechosos, %d handlers",
			informe.Remotos.Peticiones, informe.Remotos.Aceptadas, informe.Remotos.Errores, informe.Remotos.Sospechosos,
			informe.Remotos.HandlersRegistrados))
	end
	table.insert(lineas, string.format("Rechazos: %d (fuente %s)", informe.Rechazos, informe.FuenteRechazos))
	for _, fila in ipairs(informe.RechazosPorMotivo) do
		table.insert(lineas, string.format("  %-24s %d", tostring(fila.Motivo), fila.N))
	end
	if #informe.RechazosPorRemoto > 0 then
		local partes = {}
		for _, fila in ipairs(informe.RechazosPorRemoto) do
			table.insert(partes, tostring(fila.Remoto) .. "=" .. fila.N)
		end
		table.insert(lineas, "  Por remoto: " .. table.concat(partes, ", "))
	end
	table.insert(lineas, string.format("Handlers (fuente %s, latencia media %s ms):", informe.FuenteHandlers, num(informe.LatenciaMediaMs, "%.2f")))
	for _, h in ipairs(informe.Handlers) do
		table.insert(lineas, string.format("  %-24s media %.2f ms · máx %.2f ms · %d llamadas", h.Nombre, h.MediaMs or 0, h.MaxMs or 0, h.N))
	end
	local fps = informe.FPSClientes
	table.insert(lineas, string.format("FPS de clientes: %d reportes · media %s · mín %s · máx %s",
		fps.n, num(fps.media, "%.1f"), num(fps.min, "%.1f"), num(fps.max, "%.1f")))
	local dispositivos = {}
	for clave in pairs(fps.porDispositivo) do
		table.insert(dispositivos, clave)
	end
	table.sort(dispositivos)
	for _, clave in ipairs(dispositivos) do
		local d = fps.porDispositivo[clave]
		table.insert(lineas, string.format("  %-10s media %s · mín %s · %d", clave, num(d.media, "%.1f"), num(d.min, "%.1f"), d.n))
	end
	return table.concat(lineas, "\n")
end

-- Imprime el resumen en la salida del servidor.
function MetricsService:Imprimir()
	print(self:Texto())
end

return MetricsService
