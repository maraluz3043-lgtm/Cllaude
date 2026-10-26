--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.DataService
	Tipo: ModuleScript
	Persistencia de perfiles (docs/ARQUITECTURA.md §4): carga al entrar con reintentos y backoff 1/2/4 s,
	presupuesto de peticiones, migraciones por Version, saneamiento, caché Perfiles[userId], autoguardado,
	guardado en PlayerRemoving y BindToClose, modo memoria en Studio sin acceso a la API y guardado de reportes.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local RoleDefinitions = require(Shared:WaitForChild("RoleDefinitions"))
local TimetableDefinitions = require(Shared:WaitForChild("TimetableDefinitions"))
local RemoteContracts = require(Shared:WaitForChild("RemoteContracts"))
local Util = Shared:WaitForChild("Util")
local Validate = require(Util:WaitForChild("Validate"))
local Signal = require(Util:WaitForChild("Signal"))

local DataService = {}
DataService.Nombre = "DataService"

local PREFIJO = "[ColegioRP][DataService]"
local CFG = Config.Datos or {}
local ESQUEMA_VERSION = CFG.EsquemaVersion or 1
local REINTENTOS_MAX = math.max(1, CFG.ReintentosMax or 3)
local AUTOGUARDADO_SEG = math.max(30, CFG.AutoguardadoSeg or 120)
local MAX_HISTORIAL = math.max(1, CFG.MaxHistorialEconomia or 30)
local MAX_SALDO = 1000000000
local ESPERA_PRESUPUESTO_MAX = 10 -- segundos máximos esperando presupuesto antes de intentar igualmente
local TIEMPO_CIERRE_MAX = 25 -- segundos máximos de espera en BindToClose

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function copiaProfunda(valor, profundidad)
	if typeof(valor) ~= "table" then
		return valor
	end
	profundidad = profundidad or 0
	if profundidad > 8 then
		return {}
	end
	local copia = {}
	for clave, v in pairs(valor) do
		copia[clave] = copiaProfunda(v, profundidad + 1)
	end
	return copia
end

local function esFinito(n)
	return typeof(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- Número acotado (entero si se indica); si no es válido devuelve el valor por defecto.
local function numero(valor, defecto, min, max, entero)
	if not esFinito(valor) then
		return defecto
	end
	local n = valor
	if entero then
		n = math.floor(n + 0.5)
	end
	if min ~= nil and n < min then
		n = min
	end
	if max ~= nil and n > max then
		n = max
	end
	return n
end

local function booleano(valor, defecto)
	if typeof(valor) == "boolean" then
		return valor
	end
	return defecto
end

-- Texto UTF-8 válido recortado a max caracteres (texto inválido -> defecto).
local function texto(valor, defecto, max)
	if typeof(valor) ~= "string" then
		return defecto
	end
	local n = utf8.len(valor)
	if n == nil then
		return defecto
	end
	if max and n > max then
		local corte = utf8.offset(valor, max + 1)
		if corte then
			return string.sub(valor, 1, corte - 1)
		end
	end
	return valor
end

-- Lista continua (ipairs) limitada a max elementos, conservando los últimos.
local function ultimos(lista, max)
	if typeof(lista) ~= "table" then
		return {}
	end
	local resultado = {}
	local n = #lista
	local inicio = math.max(1, n - max + 1)
	for i = inicio, n do
		table.insert(resultado, lista[i])
	end
	return resultado
end

-- Mensajes de error que indican falta de acceso a la API en Studio (no reintentar: modo memoria).
local function esErrorDeAccesoApi(mensaje)
	if typeof(mensaje) ~= "string" then
		return false
	end
	local m = string.lower(mensaje)
	return string.find(m, "studio", 1, true) ~= nil
		or string.find(m, "api services", 1, true) ~= nil
		or string.find(m, "api access", 1, true) ~= nil
		or string.find(m, "403", 1, true) ~= nil
end

---------------------------------------------------------------------------------------------------
-- Plantilla de perfil (esquema v1)
---------------------------------------------------------------------------------------------------
function DataService.PerfilPorDefecto()
	local graficos = Config.Graficos or {}
	local economia = Config.Economia or {}
	local spawns = Config.Spawns or {}
	return {
		Version = ESQUEMA_VERSION,
		Ajustes = {
			ModoGraficos = graficos.ModoPorDefecto or "Automatico",
			Particulas = true,
			DecoracionLejana = true,
			Postprocesado = true,
			SonidosAmbiente = true,
			AnimacionesCosmeticas = true,
			LimiteEfectos = 2,
			EscalaTexto = 1,
			MovimientoReducido = false,
			Subtitulos = true,
			FormatoHora = 24,
			OcultarEtiquetas = false,
			IntroVista = false,
		},
		Economia = { Saldo = economia.SaldoInicial or 50, GanadoHoy = 0, DiaUltimo = "", Historial = {} },
		Cuaderno = { Titulo = "Mi cuaderno", Paginas = { { Materia = "MAT", Texto = "", Actualizado = 0 } } },
		Progreso = {
			Asistencias = 0, Tardanzas = 0, Ausencias = 0, RespuestasCorrectas = 0, ClasesCompletadas = 0,
			Goles = 0, TareasLimpieza = 0, UltimoCargo = spawns.CargoPorDefecto or "Estudiante",
		},
		Moderacion = { Advertencias = {}, BloqueoHasta = 0 },
		Meta = { Creado = 0, UltimaEntrada = 0, Entradas = 0 },
	}
end

---------------------------------------------------------------------------------------------------
-- Migraciones: Migraciones[versionOrigen](perfil) -> perfil en versionOrigen + 1
---------------------------------------------------------------------------------------------------
DataService.Migraciones = {
	-- Perfiles sin Version (anteriores a 2.0.0) o con Version 0 -> esquema 1.
	[0] = function(perfil)
		if typeof(perfil.Ajustes) ~= "table" then
			perfil.Ajustes = {}
		end
		if typeof(perfil.Economia) ~= "table" then
			perfil.Economia = {}
		end
		-- Nombres antiguos posibles de campos de monedas.
		if perfil.Economia.Saldo == nil and esFinito(perfil.Monedas) then
			perfil.Economia.Saldo = perfil.Monedas
		end
		perfil.Monedas = nil
		perfil.Version = 1
		return perfil
	end,
}

function DataService:Migrar(perfil)
	if typeof(perfil) ~= "table" then
		return self.PerfilPorDefecto(), false
	end
	local version = perfil.Version
	if not esFinito(version) then
		version = 0
	end
	version = math.floor(version)
	if version > ESQUEMA_VERSION then
		-- Datos de una versión más nueva del juego: no se persisten para no destruir campos desconocidos.
		warn(PREFIJO .. " Perfil con esquema v" .. version .. " superior al soportado (v" .. ESQUEMA_VERSION .. "); se usa en modo solo sesión.")
		return perfil, true
	end
	local iteraciones = 0
	while version < ESQUEMA_VERSION and iteraciones < 32 do
		local migracion = self.Migraciones[version]
		if typeof(migracion) ~= "function" then
			warn(PREFIJO .. " No existe migración desde el esquema v" .. version .. "; se completa con valores por defecto.")
			perfil.Version = ESQUEMA_VERSION
			break
		end
		local ok, resultado = pcall(migracion, perfil)
		if ok and typeof(resultado) == "table" then
			perfil = resultado
		else
			warn(PREFIJO .. " Error en la migración v" .. version .. ": " .. tostring(resultado))
			perfil.Version = version + 1
		end
		if not esFinito(perfil.Version) or perfil.Version <= version then
			perfil.Version = version + 1
		end
		version = math.floor(perfil.Version)
		iteraciones = iteraciones + 1
	end
	perfil.Version = ESQUEMA_VERSION
	return perfil, false
end

---------------------------------------------------------------------------------------------------
-- Saneamiento: devuelve una copia del perfil con tipos y límites garantizados
---------------------------------------------------------------------------------------------------
local camposAjustes = RemoteContracts.EsquemaAjustes and RemoteContracts.EsquemaAjustes.campos or {}

function DataService:Sanear(origen)
	local base = self.PerfilPorDefecto()
	if typeof(origen) ~= "table" then
		return base
	end
	local limites = Config.Limites or {}
	local cuadernoCfg = Config.Cuaderno or {}
	local moderacionCfg = Config.Moderacion or {}

	-- Ajustes: cada clave debe pasar su descriptor de RemoteContracts.EsquemaAjustes.
	local ajustes = typeof(origen.Ajustes) == "table" and origen.Ajustes or {}
	for _, clave in ipairs(RemoteContracts.ClavesAjustes or {}) do
		local descriptor = camposAjustes[clave]
		local valor = ajustes[clave]
		if valor ~= nil and descriptor then
			local ok = Validate.ComprobarValor(descriptor, valor, clave)
			if ok then
				base.Ajustes[clave] = valor
			end
		end
	end

	-- Economía.
	local eco = typeof(origen.Economia) == "table" and origen.Economia or {}
	base.Economia.Saldo = numero(eco.Saldo, base.Economia.Saldo, 0, MAX_SALDO, true)
	base.Economia.GanadoHoy = numero(eco.GanadoHoy, 0, 0, MAX_SALDO, true)
	base.Economia.DiaUltimo = texto(eco.DiaUltimo, "", 10)
	base.Economia.Historial = {}
	for _, mov in ipairs(ultimos(eco.Historial, MAX_HISTORIAL)) do
		if typeof(mov) == "table" then
			table.insert(base.Economia.Historial, {
				T = numero(mov.T, 0, 0, nil, true),
				Tipo = texto(mov.Tipo, "", 24),
				Monto = numero(mov.Monto, 0, -MAX_SALDO, MAX_SALDO, true),
				Detalle = texto(mov.Detalle, "", 80),
			})
		end
	end

	-- Cuaderno.
	local cuaderno = typeof(origen.Cuaderno) == "table" and origen.Cuaderno or {}
	base.Cuaderno.Titulo = texto(cuaderno.Titulo, "Mi cuaderno", limites.MaxNombreCaracteres or 24)
	if base.Cuaderno.Titulo == "" then
		base.Cuaderno.Titulo = "Mi cuaderno"
	end
	local paginas = {}
	if typeof(cuaderno.Paginas) == "table" then
		for i = 1, math.min(#cuaderno.Paginas, cuadernoCfg.MaxPaginas or 20) do
			local pagina = cuaderno.Paginas[i]
			if typeof(pagina) == "table" then
				local materia = texto(pagina.Materia, "MAT", 8)
				if not TimetableDefinitions.ExisteMateria(materia) then
					materia = texto(pagina.Materia, "MAT", 8)
				end
				local entrada = {
					Materia = materia,
					Texto = texto(pagina.Texto, "", cuadernoCfg.MaxCaracteresPagina or 1200),
					Actualizado = numero(pagina.Actualizado, 0, 0, nil, true),
				}
				if typeof(pagina.Compartida) == "boolean" then
					entrada.Compartida = pagina.Compartida
				end
				table.insert(paginas, entrada)
			end
		end
	end
	if #paginas > 0 then
		base.Cuaderno.Paginas = paginas
	end

	-- Progreso.
	local progreso = typeof(origen.Progreso) == "table" and origen.Progreso or {}
	for clave, defecto in pairs(base.Progreso) do
		if clave ~= "UltimoCargo" then
			base.Progreso[clave] = numero(progreso[clave], defecto, 0, MAX_SALDO, true)
		end
	end
	if RoleDefinitions.Existe(progreso.UltimoCargo) then
		base.Progreso.UltimoCargo = progreso.UltimoCargo
	end

	-- Moderación.
	local moderacion = typeof(origen.Moderacion) == "table" and origen.Moderacion or {}
	base.Moderacion.BloqueoHasta = numero(moderacion.BloqueoHasta, 0, 0, nil, true)
	base.Moderacion.Advertencias = {}
	for _, adv in ipairs(ultimos(moderacion.Advertencias, moderacionCfg.MaxAdvertencias or 20)) do
		if typeof(adv) == "table" then
			table.insert(base.Moderacion.Advertencias, {
				T = numero(adv.T, 0, 0, nil, true),
				Motivo = texto(adv.Motivo, "", limites.MaxMotivoCaracteres or 120),
				Autor = texto(adv.Autor, "", 32),
			})
		end
	end

	-- Meta.
	local meta = typeof(origen.Meta) == "table" and origen.Meta or {}
	base.Meta.Creado = numero(meta.Creado, 0, 0, nil, true)
	base.Meta.UltimaEntrada = numero(meta.UltimaEntrada, 0, 0, nil, true)
	base.Meta.Entradas = numero(meta.Entradas, 0, 0, nil, true)

	base.Version = ESQUEMA_VERSION
	return base
end

-- Prepara los datos leídos (o nil) para su uso: migra y sanea. Devuelve perfil, soloSesion.
function DataService:Preparar(datos)
	if datos == nil then
		local nuevo = self.PerfilPorDefecto()
		nuevo.Meta.Creado = os.time()
		return nuevo, false
	end
	if typeof(datos) ~= "table" then
		warn(PREFIJO .. " Datos guardados con tipo inesperado (" .. typeof(datos) .. "); se crea un perfil nuevo.")
		local nuevo = self.PerfilPorDefecto()
		nuevo.Meta.Creado = os.time()
		return nuevo, false
	end
	local migrado, soloSesion = self:Migrar(copiaProfunda(datos))
	return self:Sanear(migrado), soloSesion
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function DataService:Init(registro)
	self.registro = registro
	self.Perfiles = {} -- userId -> perfil (caché)
	self.Meta = {} -- userId -> { Estado, Clave, Sucio, SoloSesion, Guardando, Saliendo, UltimoGuardado }
	self.ModoMemoria = false
	self.MemoriaPerfiles = {} -- clave -> perfil saneado (persistencia dentro de la sesión de Studio)
	self.MemoriaReportes = {} -- clave -> reporte
	self.Store = nil
	self.StoreReportes = nil
	self.Activo = true
	self.PerfilCargado = Signal.new() -- (player, perfil)
	self.PerfilGuardado = Signal.new() -- (userId, ok, motivo)
	self.Estadisticas = {
		Cargas = 0, CargasNuevas = 0, CargasFallidas = 0,
		Guardados = 0, GuardadosFallidos = 0, Reportes = 0, ReportesFallidos = 0,
		UltimoError = "",
	}
	self.Conexiones = {}
end

function DataService:Start()
	self.AuditLog = self.registro.Get("AuditLogService")
	self:ConectarAlmacenes()

	table.insert(self.Conexiones, Players.PlayerAdded:Connect(function(player)
		task.spawn(function()
			self:Cargar(player)
		end)
	end))
	table.insert(self.Conexiones, Players.PlayerRemoving:Connect(function(player)
		task.spawn(function()
			self:AlSalir(player)
		end)
	end))
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			self:Cargar(player)
		end)
	end

	local okBind, errBind = pcall(function()
		game:BindToClose(function()
			self:AlCerrar()
		end)
	end)
	if not okBind then
		warn(PREFIJO .. " No se pudo registrar BindToClose: " .. tostring(errBind))
	end

	task.spawn(function()
		self:BucleAutoguardado()
	end)
end

-- Obtiene los DataStores con pcall; si falla, activa el modo memoria.
function DataService:ConectarAlmacenes()
	local nombrePerfiles = CFG.NombreDataStore or "ColegioRP_Perfiles"
	local nombreReportes = CFG.NombreDataStoreReportes or "ColegioRP_Reportes"
	local ok, store = pcall(DataStoreService.GetDataStore, DataStoreService, nombrePerfiles)
	if ok and store then
		self.Store = store
	else
		self:ActivarModoMemoria("GetDataStore(" .. nombrePerfiles .. "): " .. tostring(store))
		return
	end
	local okR, storeR = pcall(DataStoreService.GetDataStore, DataStoreService, nombreReportes)
	if okR and storeR then
		self.StoreReportes = storeR
	else
		warn(PREFIJO .. " No se pudo obtener el DataStore de reportes: " .. tostring(storeR) .. ". Los reportes se guardarán en memoria.")
	end
end

-- Pasa a modo memoria (Studio sin acceso a la API o DataStore inaccesible). Nunca lanza.
function DataService:ActivarModoMemoria(motivo)
	if self.ModoMemoria then
		return
	end
	self.ModoMemoria = true
	self.Estadisticas.UltimoError = tostring(motivo)
	warn(PREFIJO .. " MODO MEMORIA activado: los perfiles no se persisten en esta sesión. Motivo: " .. tostring(motivo))
	if RunService:IsStudio() then
		warn(PREFIJO .. " En Studio: activa 'Enable Studio Access to API Services' en Game Settings > Security para probar DataStore.")
	end
	if self.AuditLog then
		self.AuditLog:Registrar("Sistema", nil, "ModoMemoria", motivo)
	end
	-- Perfiles que quedaron en "solo sesión" por fallos de lectura pasan a memoria para no bloquear a nadie.
	for userId, meta in pairs(self.Meta) do
		if meta.SoloSesion and meta.MotivoSoloSesion == "fallo_lectura" then
			meta.SoloSesion = false
			meta.Estado = "memoria"
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Presupuesto y reintentos
---------------------------------------------------------------------------------------------------

-- Espera (hasta ESPERA_PRESUPUESTO_MAX s) a que haya presupuesto para el tipo de petición.
function DataService:EsperarPresupuesto(tipo)
	local esperado = 0
	while esperado < ESPERA_PRESUPUESTO_MAX do
		local ok, presupuesto = pcall(DataStoreService.GetRequestBudgetForRequestType, DataStoreService, tipo)
		if not ok or typeof(presupuesto) ~= "number" or presupuesto > 0 then
			return true
		end
		task.wait(1)
		esperado = esperado + 1
	end
	return false
end

-- Ejecuta una operación de DataStore con reintentos y backoff 1/2/4 s. Devuelve ok, resultado|error.
function DataService:ConReintentos(tipoPresupuesto, operacion, descripcion)
	local ultimoError = "desconocido"
	for intento = 1, REINTENTOS_MAX do
		if self.ModoMemoria then
			return false, "modo_memoria"
		end
		self:EsperarPresupuesto(tipoPresupuesto)
		local ok, resultado = pcall(operacion)
		if ok then
			return true, resultado
		end
		ultimoError = tostring(resultado)
		self.Estadisticas.UltimoError = ultimoError
		if esErrorDeAccesoApi(ultimoError) and RunService:IsStudio() then
			self:ActivarModoMemoria(ultimoError)
			return false, "modo_memoria"
		end
		warn(string.format("%s %s falló (intento %d/%d): %s", PREFIJO, tostring(descripcion), intento, REINTENTOS_MAX, ultimoError))
		if intento < REINTENTOS_MAX then
			task.wait(2 ^ (intento - 1))
		end
	end
	return false, ultimoError
end

---------------------------------------------------------------------------------------------------
-- Carga
---------------------------------------------------------------------------------------------------
function DataService:Clave(userId)
	return "P_" .. tostring(userId)
end

local function resolverUserId(player)
	if typeof(player) == "Instance" and player:IsA("Player") then
		return player.UserId
	elseif typeof(player) == "number" then
		return player
	end
	return nil
end

-- Carga (o devuelve de caché) el perfil del jugador. Nunca lanza; devuelve perfil o nil si el jugador se fue.
function DataService:Cargar(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return nil
	end
	local userId = player.UserId
	if self.Perfiles[userId] and self.Meta[userId] and not self.Meta[userId].Saliendo then
		return self.Perfiles[userId]
	end

	-- Si el jugador acaba de salir y su guardado sigue en curso, esperamos a que termine.
	local esperado = 0
	while self.Meta[userId] and self.Meta[userId].Saliendo and esperado < 15 do
		task.wait(0.25)
		esperado = esperado + 0.25
	end
	if self.Meta[userId] and self.Meta[userId].Estado == "cargando" then
		return self:EsperarPerfil(player, 30)
	end

	local clave = self:Clave(userId)
	local meta = { Estado = "cargando", Clave = clave, Sucio = false, SoloSesion = false, Guardando = false, Saliendo = false, UltimoGuardado = os.clock() }
	self.Meta[userId] = meta

	local datos = nil
	local origen = "datastore"
	if self.ModoMemoria or not self.Store then
		datos = self.MemoriaPerfiles[clave]
		origen = "memoria"
	else
		local ok, resultado = self:ConReintentos(Enum.DataStoreRequestType.GetAsync, function()
			return self.Store:GetAsync(clave)
		end, "GetAsync(" .. clave .. ")")
		if ok then
			datos = resultado
		elseif self.ModoMemoria then
			datos = self.MemoriaPerfiles[clave]
			origen = "memoria"
		else
			origen = "fallo"
			self.Estadisticas.CargasFallidas = self.Estadisticas.CargasFallidas + 1
			meta.SoloSesion = true
			meta.MotivoSoloSesion = "fallo_lectura"
			warn(PREFIJO .. " No se pudo cargar el perfil de " .. player.Name .. " (" .. tostring(resultado) .. "); se usa un perfil temporal sin guardado.")
			if self.AuditLog then
				self.AuditLog:Registrar("Sistema", player, "CargaFallida", resultado)
			end
		end
	end

	local perfil, soloSesionPorVersion = self:Preparar(datos)
	if soloSesionPorVersion then
		meta.SoloSesion = true
		meta.MotivoSoloSesion = "version_superior"
	end
	perfil.Meta.UltimaEntrada = os.time()
	perfil.Meta.Entradas = perfil.Meta.Entradas + 1
	if perfil.Meta.Creado == 0 then
		perfil.Meta.Creado = os.time()
	end

	if player.Parent == nil then
		-- El jugador se fue durante la carga: no hay nada que guardar.
		if self.Meta[userId] == meta then
			self.Meta[userId] = nil
		end
		return nil
	end

	self.Perfiles[userId] = perfil
	if datos == nil then
		meta.Estado = "nuevo"
		meta.Sucio = true
		self.Estadisticas.CargasNuevas = self.Estadisticas.CargasNuevas + 1
	elseif origen == "fallo" then
		meta.Estado = "temporal"
	elseif origen == "memoria" then
		meta.Estado = "memoria"
	else
		meta.Estado = "cargado"
	end
	self.Estadisticas.Cargas = self.Estadisticas.Cargas + 1

	if origen == "fallo" then
		local RemoteService = self.registro.Get("RemoteService")
		if RemoteService and typeof(RemoteService.Enviar) == "function" then
			task.delay(5, function()
				if player.Parent then
					RemoteService:Enviar(player, "Notificacion", {
						Titulo = "Progreso temporal",
						Texto = "No se pudo cargar tu progreso guardado. Puedes jugar, pero los cambios de esta sesión no se guardarán.",
						Tipo = "aviso",
						Duracion = 8,
					})
				end
			end)
		end
	end

	self.PerfilCargado:Fire(player, perfil)
	return perfil
end

-- Perfil en caché del jugador (Player o userId) o nil si aún no está cargado.
function DataService:Obtener(player)
	local userId = resolverUserId(player)
	if not userId then
		return nil
	end
	return self.Perfiles[userId]
end

-- Marca el perfil como modificado (se guardará en el próximo autoguardado o al salir).
function DataService:Marcar(player)
	local userId = resolverUserId(player)
	local meta = userId and self.Meta[userId]
	if meta then
		meta.Sucio = true
		return true
	end
	return false
end

-- Espera a que el perfil esté cargado (hasta timeout segundos). Devuelve perfil o nil.
function DataService:EsperarPerfil(player, timeout)
	local userId = resolverUserId(player)
	if not userId then
		return nil
	end
	timeout = tonumber(timeout) or 15
	local inicio = os.clock()
	while os.clock() - inicio < timeout do
		local perfil = self.Perfiles[userId]
		local meta = self.Meta[userId]
		if perfil and meta and not meta.Saliendo then
			return perfil
		end
		if typeof(player) == "Instance" and player.Parent == nil then
			return nil
		end
		task.wait(0.1)
	end
	return self.Perfiles[userId]
end

-- Estado del perfil: "cargando" | "cargado" | "nuevo" | "memoria" | "temporal" | nil.
function DataService:Estado(player)
	local userId = resolverUserId(player)
	local meta = userId and self.Meta[userId]
	if meta then
		return meta.Estado
	end
	return nil
end

-- ¿El perfil se persistirá (no es solo de sesión)?
function DataService:SePersiste(player)
	local userId = resolverUserId(player)
	local meta = userId and self.Meta[userId]
	return meta ~= nil and not meta.SoloSesion
end

---------------------------------------------------------------------------------------------------
-- Guardado
---------------------------------------------------------------------------------------------------

-- Guarda el perfil del jugador (Player o userId). Devuelve ok, motivo.
function DataService:Guardar(player, motivo)
	local userId = resolverUserId(player)
	if not userId then
		return false, "jugador_invalido"
	end
	local perfil = self.Perfiles[userId]
	local meta = self.Meta[userId]
	if not perfil or not meta then
		return false, "sin_perfil"
	end
	if meta.SoloSesion then
		return false, "solo_sesion"
	end

	-- Evitar guardados concurrentes del mismo perfil.
	local esperado = 0
	while meta.Guardando and esperado < 10 do
		task.wait(0.25)
		esperado = esperado + 0.25
	end
	if meta.Guardando then
		return false, "en_curso"
	end
	meta.Guardando = true

	local saneado = self:Sanear(perfil)
	saneado.Meta.UltimaSalida = os.time()
	local ok, err

	if self.ModoMemoria or not self.Store then
		self.MemoriaPerfiles[meta.Clave] = saneado
		ok = true
	else
		ok, err = self:ConReintentos(Enum.DataStoreRequestType.UpdateAsync, function()
			return self.Store:UpdateAsync(meta.Clave, function()
				return saneado
			end)
		end, "UpdateAsync(" .. meta.Clave .. ")")
		if not ok and self.ModoMemoria then
			self.MemoriaPerfiles[meta.Clave] = saneado
			ok = true
		end
	end

	meta.Guardando = false
	if ok then
		meta.Sucio = false
		meta.UltimoGuardado = os.clock()
		self.Estadisticas.Guardados = self.Estadisticas.Guardados + 1
		self.PerfilGuardado:Fire(userId, true, motivo)
		return true
	end
	self.Estadisticas.GuardadosFallidos = self.Estadisticas.GuardadosFallidos + 1
	if self.AuditLog then
		self.AuditLog:Registrar("Sistema", userId, "GuardadoFallido", tostring(err))
	end
	self.PerfilGuardado:Fire(userId, false, tostring(err))
	return false, tostring(err)
end

-- Guarda todos los perfiles sucios (o todos si forzar = true), espaciando las peticiones.
function DataService:GuardarTodos(forzar, motivo)
	local guardados = 0
	for userId, meta in pairs(self.Meta) do
		if self.Perfiles[userId] and not meta.SoloSesion and (forzar or meta.Sucio) then
			local ok = self:Guardar(userId, motivo or "autoguardado")
			if ok then
				guardados = guardados + 1
			end
			if not self.ModoMemoria then
				task.wait(0.5)
			end
		end
	end
	return guardados
end

function DataService:BucleAutoguardado()
	while self.Activo do
		task.wait(AUTOGUARDADO_SEG)
		if not self.Activo then
			break
		end
		local ok, err = pcall(function()
			self:GuardarTodos(false, "autoguardado")
		end)
		if not ok then
			warn(PREFIJO .. " Error en el autoguardado: " .. tostring(err))
		end
	end
end

function DataService:AlSalir(player)
	if typeof(player) ~= "Instance" then
		return
	end
	local userId = player.UserId
	local meta = self.Meta[userId]
	if not meta then
		return
	end
	meta.Saliendo = true
	if self.Perfiles[userId] then
		local ok, err = pcall(function()
			self:Guardar(userId, "salida")
		end)
		if not ok then
			warn(PREFIJO .. " Error al guardar al salir " .. player.Name .. ": " .. tostring(err))
		end
	end
	-- Solo se limpia si no se ha vuelto a cargar mientras guardábamos (reconexión rápida).
	if self.Meta[userId] == meta then
		self.Meta[userId] = nil
		self.Perfiles[userId] = nil
	end
end

-- BindToClose: guarda todos los perfiles en paralelo y espera (máx. TIEMPO_CIERRE_MAX s).
function DataService:AlCerrar()
	self.Activo = false
	local pendientes = 0
	for userId, meta in pairs(self.Meta) do
		if self.Perfiles[userId] and not meta.SoloSesion and not meta.Saliendo then
			pendientes = pendientes + 1
			task.spawn(function()
				pcall(function()
					self:Guardar(userId, "cierre")
				end)
				pendientes = pendientes - 1
			end)
		end
	end
	if self.ModoMemoria then
		return
	end
	local inicio = os.clock()
	while pendientes > 0 and os.clock() - inicio < TIEMPO_CIERRE_MAX do
		task.wait(0.2)
	end
	if pendientes > 0 then
		warn(PREFIJO .. " Cierre con " .. pendientes .. " guardados sin confirmar.")
	end
end

---------------------------------------------------------------------------------------------------
-- Reportes de soporte
---------------------------------------------------------------------------------------------------

-- Guarda un reporte { UserId, Categoria, Ubicacion, Descripcion, ... } con clave R_<unix>_<userId>.
-- Devuelve ok, clave|error.
function DataService:GuardarReporte(reporte)
	if typeof(reporte) ~= "table" then
		return false, "reporte_invalido"
	end
	local userId = numero(reporte.UserId, 0, 0, nil, true)
	local clave = string.format("R_%d_%d", os.time(), userId)
	local copia = copiaProfunda(reporte)
	copia.UserId = userId
	copia.Guardado = os.time()
	copia.Version = Config.Version

	if self.ModoMemoria or not self.StoreReportes then
		local sufijo = 0
		local claveFinal = clave
		while self.MemoriaReportes[claveFinal] do
			sufijo = sufijo + 1
			claveFinal = clave .. "_" .. sufijo
		end
		self.MemoriaReportes[claveFinal] = copia
		self.Estadisticas.Reportes = self.Estadisticas.Reportes + 1
		return true, claveFinal
	end

	local ok, err = self:ConReintentos(Enum.DataStoreRequestType.SetIncrementAsync, function()
		return self.StoreReportes:SetAsync(clave, copia)
	end, "SetAsync(" .. clave .. ")")
	if ok then
		self.Estadisticas.Reportes = self.Estadisticas.Reportes + 1
		return true, clave
	end
	self.Estadisticas.ReportesFallidos = self.Estadisticas.ReportesFallidos + 1
	-- Como respaldo se conserva en memoria para que moderación pueda verlo en esta sesión.
	self.MemoriaReportes[clave] = copia
	return false, tostring(err)
end

-- Reportes guardados en memoria durante esta sesión (lista, el más reciente al final).
function DataService:ReportesEnMemoria()
	local lista = {}
	for clave, reporte in pairs(self.MemoriaReportes) do
		local copia = copiaProfunda(reporte)
		copia.Clave = clave
		table.insert(lista, copia)
	end
	table.sort(lista, function(a, b)
		return (a.Guardado or 0) < (b.Guardado or 0)
	end)
	return lista
end

---------------------------------------------------------------------------------------------------
-- Métricas
---------------------------------------------------------------------------------------------------
-- Resumen numérico para MetricsService (el campo self.Estadisticas guarda los contadores internos).
function DataService:ObtenerEstadisticas()
	local enCache = 0
	local sucios = 0
	for userId, meta in pairs(self.Meta) do
		if self.Perfiles[userId] then
			enCache = enCache + 1
			if meta.Sucio then
				sucios = sucios + 1
			end
		end
	end
	return {
		ModoMemoria = self.ModoMemoria,
		PerfilesEnCache = enCache,
		PerfilesSucios = sucios,
		Cargas = self.Estadisticas.Cargas,
		CargasNuevas = self.Estadisticas.CargasNuevas,
		CargasFallidas = self.Estadisticas.CargasFallidas,
		Guardados = self.Estadisticas.Guardados,
		GuardadosFallidos = self.Estadisticas.GuardadosFallidos,
		Reportes = self.Estadisticas.Reportes,
		ReportesFallidos = self.Estadisticas.ReportesFallidos,
		UltimoError = self.Estadisticas.UltimoError,
	}
end

return DataService
