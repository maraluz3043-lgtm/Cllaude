--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.EconomyService
	Tipo: ModuleScript
	Economía escolar (docs/ARQUITECTURA.md §6, prueba P9): saldo en Perfil.Economia (DataService), créditos con
	límite diario (GanadoHoy / DiaUltimo por os.date("%Y-%m-%d")), débitos atómicos con bloqueo por jugador
	("en transacción"), historial por perfil (máx. Config.Datos.MaxHistorialEconomia), buffer circular de las
	últimas 200 transacciones para finanzas, resumen global y evento "Economia" { Sub = "Saldo", Saldo, Delta,
	Detalle } al jugador en cada movimiento. Sin DataService funciona en memoria (solo durante la sesión).
]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Util = Shared:WaitForChild("Util")
local Signal = require(Util:WaitForChild("Signal"))
local Format = require(Util:WaitForChild("Format"))

local EconomyService = {}
EconomyService.Nombre = "EconomyService"

local PREFIJO = "[ColegioRP][EconomyService]"
local CFG = Config.Economia or {}
local MAX_SALDO = 1000000000

-- Entradas del historial por perfil (DataService sanea con el mismo límite).
EconomyService.MaxHistorial = math.max(1, math.floor(tonumber(Config.Datos and Config.Datos.MaxHistorialEconomia) or 30))
-- Tamaño del buffer circular de transacciones (panel de finanzas / auditoría económica).
EconomyService.TamanoTransacciones = 200
-- Tipos de crédito que no cuentan para el límite diario (devoluciones y saldo de bienvenida).
EconomyService.TiposSinLimite = { Reembolso = true, Inicial = true }
-- Longitudes máximas guardadas (coinciden con el saneamiento de DataService).
EconomyService.MaxTipoCaracteres = 24
EconomyService.MaxDetalleCaracteres = 80

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function esFinito(n)
	return typeof(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- Monto entero no negativo o nil si no es válido.
local function montoValido(valor)
	if not esFinito(valor) then
		return nil
	end
	local n = math.floor(valor + 0.5)
	if n < 0 or n > MAX_SALDO then
		return nil
	end
	return n
end

-- Resuelve Player o userId a (player|nil, userId|nil).
local function resolver(objetivo)
	if typeof(objetivo) == "Instance" and objetivo:IsA("Player") then
		return objetivo, objetivo.UserId
	end
	if typeof(objetivo) == "number" and esFinito(objetivo) then
		local userId = math.floor(objetivo)
		return Players:GetPlayerByUserId(userId), userId
	end
	return nil, nil
end

local function texto(valor, max)
	if valor == nil then
		return ""
	end
	local t = tostring(valor)
	t = string.gsub(t, "[%c]", " ")
	return Format.Truncar(t, max)
end

-- Clave del día ("AAAA-MM-DD") para el límite diario.
local function claveDia()
	local ok, valor = pcall(os.date, "%Y-%m-%d")
	if ok and typeof(valor) == "string" and string.match(valor, "^%d%d%d%d%-%d%d%-%d%d$") then
		return valor
	end
	return Format.ClaveDia(os.time())
end

local function copiarMovimiento(m)
	return { T = m.T, Tipo = m.Tipo, Monto = m.Monto, Detalle = m.Detalle }
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function EconomyService:Init(registro)
	self.registro = registro
	self.EnTransaccion = {} -- userId -> true mientras dura un débito (bloqueo por jugador)
	self.Memoria = {} -- userId -> { Economia = {...} } si no hay DataService
	self.Transacciones = table.create(self.TamanoTransacciones)
	self.IndiceTx = 0 -- última posición escrita en el buffer circular
	self.TotalTx = 0 -- transacciones registradas desde el arranque (también Id)
	self.Totales = { Acreditado = 0, Debitado = 0, RechazosSaldo = 0, RechazosLimite = 0, RechazosBloqueo = 0, PorTipo = {} }
	self.LimiteAvisado = {} -- userId -> clave del día en que ya se avisó del límite
	self.InicioUnix = os.time()
	self.SaldoCambiado = Signal.new() -- (player, saldo, delta, tipo, detalle)
	self.Conexiones = {}
end

function EconomyService:Start()
	local DataService = self:_S("DataService")
	if DataService and DataService.PerfilCargado and typeof(DataService.PerfilCargado.Connect) == "function" then
		table.insert(self.Conexiones, DataService.PerfilCargado:Connect(function(player, perfil)
			local ok, err = pcall(self._AlCargarPerfil, self, player, perfil)
			if not ok then
				warn(PREFIJO .. " Error al preparar la economía de " .. tostring(player) .. ": " .. tostring(err))
			end
		end))
	elseif not DataService then
		warn(PREFIJO .. " DataService no disponible: los saldos solo vivirán en memoria durante la sesión.")
	end

	-- Perfiles que ya estaban cargados antes de este Start.
	for _, player in ipairs(Players:GetPlayers()) do
		local perfil = DataService and DataService:Obtener(player)
		if perfil then
			pcall(self._AlCargarPerfil, self, player, perfil)
		end
	end

	table.insert(self.Conexiones, Players.PlayerRemoving:Connect(function(player)
		self.EnTransaccion[player.UserId] = nil
		self.LimiteAvisado[player.UserId] = nil
		self.Memoria[player.UserId] = nil
	end))
end

function EconomyService:_S(nombre)
	local registro = self.registro
	if typeof(registro) ~= "table" or typeof(registro.Get) ~= "function" then
		return nil
	end
	local ok, servicio = pcall(registro.Get, nombre)
	if ok and typeof(servicio) == "table" then
		return servicio
	end
	return nil
end

function EconomyService:_Auditar(player, accion, detalle)
	local AuditLog = self:_S("AuditLogService")
	if AuditLog and typeof(AuditLog.Registrar) == "function" then
		pcall(AuditLog.Registrar, AuditLog, "Economia", player, accion, detalle)
	end
end

function EconomyService:_Enviar(player, tipo, datos)
	if typeof(player) ~= "Instance" or player.Parent == nil then
		return false
	end
	local RemoteService = self:_S("RemoteService")
	if RemoteService and typeof(RemoteService.Enviar) == "function" then
		local ok, resultado = pcall(RemoteService.Enviar, RemoteService, player, tipo, datos)
		return ok and resultado == true
	end
	return false
end

---------------------------------------------------------------------------------------------------
-- Acceso al bloque Economia del perfil
---------------------------------------------------------------------------------------------------

-- Normaliza el bloque Economia (tipos y campos) y aplica el cambio de día. Devuelve la tabla.
function EconomyService:_Normalizar(eco)
	if not esFinito(eco.Saldo) then
		eco.Saldo = math.floor(tonumber(CFG.SaldoInicial) or 50)
	end
	eco.Saldo = math.clamp(math.floor(eco.Saldo), 0, MAX_SALDO)
	if not esFinito(eco.GanadoHoy) then
		eco.GanadoHoy = 0
	end
	if typeof(eco.DiaUltimo) ~= "string" then
		eco.DiaUltimo = ""
	end
	if typeof(eco.Historial) ~= "table" then
		eco.Historial = {}
	end
	local hoy = claveDia()
	if eco.DiaUltimo ~= hoy then
		eco.DiaUltimo = hoy
		eco.GanadoHoy = 0
	end
	return eco
end

-- Bloque Economia del jugador (Player o userId) o nil si el perfil aún no está cargado.
function EconomyService:_Economia(objetivo)
	local player, userId = resolver(objetivo)
	if not userId then
		return nil, nil
	end
	local DataService = self:_S("DataService")
	if DataService and typeof(DataService.Obtener) == "function" then
		local ok, perfil = pcall(DataService.Obtener, DataService, player or userId)
		if not ok or typeof(perfil) ~= "table" then
			return nil, player
		end
		if typeof(perfil.Economia) ~= "table" then
			perfil.Economia = { Saldo = math.floor(tonumber(CFG.SaldoInicial) or 50), GanadoHoy = 0, DiaUltimo = "", Historial = {} }
		end
		return self:_Normalizar(perfil.Economia), player
	end
	-- Sin DataService: perfil en memoria de la sesión (solo jugadores conectados).
	if not player then
		return nil, nil
	end
	local memoria = self.Memoria[userId]
	if not memoria then
		local saldoInicial = math.floor(tonumber(CFG.SaldoInicial) or 50)
		memoria = { Economia = { Saldo = saldoInicial, GanadoHoy = 0, DiaUltimo = "", Historial = {} } }
		table.insert(memoria.Economia.Historial, { T = os.time(), Tipo = "Inicial", Monto = saldoInicial, Detalle = "Saldo inicial de bienvenida" })
		self.Memoria[userId] = memoria
	end
	return self:_Normalizar(memoria.Economia), player
end

function EconomyService:_Marcar(player)
	local DataService = self:_S("DataService")
	if DataService and typeof(DataService.Marcar) == "function" then
		pcall(DataService.Marcar, DataService, player)
	end
end

-- Al cargar un perfil: normaliza, registra el saldo de bienvenida en perfiles nuevos y envía el saldo.
function EconomyService:_AlCargarPerfil(player, perfil)
	if typeof(perfil) ~= "table" then
		return
	end
	local eco = self:_Economia(player)
	if not eco then
		return
	end
	local DataService = self:_S("DataService")
	local estado = nil
	if DataService and typeof(DataService.Estado) == "function" then
		local ok, valor = pcall(DataService.Estado, DataService, player)
		if ok then
			estado = valor
		end
	end
	-- DataService ya pone Saldo = Config.Economia.SaldoInicial en perfiles nuevos (§4); aquí solo se deja constancia.
	if estado == "nuevo" and #eco.Historial == 0 then
		table.insert(eco.Historial, { T = os.time(), Tipo = "Inicial", Monto = eco.Saldo, Detalle = "Saldo inicial de bienvenida" })
		self:_Marcar(player)
	end
	self:_Enviar(player, "Economia", self:_DatosEvento(eco, 0, "", "Sincronizacion"))
end

---------------------------------------------------------------------------------------------------
-- Registro interno de movimientos
---------------------------------------------------------------------------------------------------
function EconomyService:_DatosEvento(eco, delta, detalle, tipo)
	return {
		Sub = "Saldo",
		Saldo = eco.Saldo,
		Delta = delta,
		Detalle = detalle,
		Tipo = tipo,
		GanadoHoy = eco.GanadoHoy,
		LimiteDiario = self:LimiteDiario(),
		Simbolo = CFG.MonedaSimbolo or "◎",
	}
end

function EconomyService:_AgregarHistorial(eco, tipo, monto, detalle)
	table.insert(eco.Historial, { T = os.time(), Tipo = tipo, Monto = monto, Detalle = detalle })
	while #eco.Historial > self.MaxHistorial do
		table.remove(eco.Historial, 1)
	end
end

function EconomyService:_RegistrarTransaccion(player, userId, tipo, monto, saldo, detalle)
	self.TotalTx = self.TotalTx + 1
	self.IndiceTx = self.IndiceTx + 1
	if self.IndiceTx > self.TamanoTransacciones then
		self.IndiceTx = 1
	end
	local nombre = ""
	if typeof(player) == "Instance" then
		nombre = player.Name
	end
	self.Transacciones[self.IndiceTx] = {
		Id = self.TotalTx,
		T = os.time(),
		UserId = userId,
		Jugador = nombre,
		Tipo = tipo,
		Monto = monto,
		Saldo = saldo,
		Detalle = detalle,
	}
	local porTipo = self.Totales.PorTipo[tipo]
	if not porTipo then
		porTipo = { Cantidad = 0, Entradas = 0, Salidas = 0 }
		self.Totales.PorTipo[tipo] = porTipo
	end
	porTipo.Cantidad = porTipo.Cantidad + 1
	if monto >= 0 then
		porTipo.Entradas = porTipo.Entradas + monto
		self.Totales.Acreditado = self.Totales.Acreditado + monto
	else
		porTipo.Salidas = porTipo.Salidas - monto
		self.Totales.Debitado = self.Totales.Debitado - monto
	end
end

-- Aplica un movimiento ya validado (monto con signo). Devuelve el saldo nuevo.
function EconomyService:_Aplicar(player, userId, eco, tipo, monto, detalle)
	eco.Saldo = math.clamp(eco.Saldo + monto, 0, MAX_SALDO)
	self:_AgregarHistorial(eco, tipo, monto, detalle)
	self:_RegistrarTransaccion(player, userId, tipo, monto, eco.Saldo, detalle)
	if player then
		self:_Marcar(player)
		self:_Enviar(player, "Economia", self:_DatosEvento(eco, monto, detalle, tipo))
	end
	self.SaldoCambiado:Fire(player, eco.Saldo, monto, tipo, detalle)
	return eco.Saldo
end

---------------------------------------------------------------------------------------------------
-- API pública
---------------------------------------------------------------------------------------------------

-- Límite diario de créditos por jugador.
function EconomyService:LimiteDiario()
	return math.max(0, math.floor(tonumber(CFG.LimiteDiario) or 300))
end

-- Saldo actual del jugador (0 si el perfil aún no está cargado).
function EconomyService:Saldo(player)
	local eco = self:_Economia(player)
	if not eco then
		return 0
	end
	return eco.Saldo
end

-- ¿El perfil económico del jugador está disponible?
function EconomyService:Disponible(player)
	return self:_Economia(player) ~= nil
end

-- Acredita 'monto' al jugador respetando Config.Economia.LimiteDiario (salvo TiposSinLimite).
-- Si solo cabe una parte del monto en el límite, se acredita esa parte.
-- Devuelve ok, saldoOError, acreditado.
function EconomyService:Acreditar(player, monto, tipo, detalle)
	local objetivo, userId = resolver(player)
	if not userId then
		return false, "jugador_invalido", 0
	end
	local n = montoValido(monto)
	if not n or n <= 0 then
		return false, "monto_invalido", 0
	end
	local eco = self:_Economia(objetivo or userId)
	if not eco then
		return false, "perfil_no_cargado", 0
	end
	tipo = texto(tipo or "Recompensa", self.MaxTipoCaracteres)
	if tipo == "" then
		tipo = "Recompensa"
	end
	detalle = texto(detalle, self.MaxDetalleCaracteres)

	local acreditable = n
	if not self.TiposSinLimite[tipo] then
		local limite = self:LimiteDiario()
		local restante = math.max(0, limite - eco.GanadoHoy)
		if restante <= 0 then
			self.Totales.RechazosLimite = self.Totales.RechazosLimite + 1
			local hoy = claveDia()
			if self.LimiteAvisado[userId] ~= hoy then
				self.LimiteAvisado[userId] = hoy
				self:_Auditar(objetivo or userId, "LimiteDiario", "Alcanzado el límite diario de " .. limite .. " (" .. tipo .. ")")
				if objetivo then
					self:_Enviar(objetivo, "Notificacion", {
						Texto = "Has alcanzado el límite diario de " .. Format.Moneda(limite) .. ". Mañana podrás ganar más.",
						Nivel = "aviso",
						Duracion = 6,
					})
				end
			end
			return false, "limite_diario", 0
		end
		acreditable = math.min(n, restante)
		eco.GanadoHoy = eco.GanadoHoy + acreditable
	end
	local saldo = self:_Aplicar(objetivo, userId, eco, tipo, acreditable, detalle)
	return true, saldo, acreditable
end

-- Recompensa por clave de Config.Economia.Recompensas (Asistencia, Respuesta, ...). Devuelve como Acreditar.
function EconomyService:Recompensar(player, clave, detalle)
	local recompensas = CFG.Recompensas or {}
	local monto = tonumber(recompensas[clave])
	if not monto or monto <= 0 then
		return false, "recompensa_desconocida", 0
	end
	return self:Acreditar(player, monto, clave, detalle)
end

-- Debita 'monto' de forma atómica: bloqueo por jugador, comprobación de saldo y registro en un único paso.
-- Devuelve ok, saldoOError ("saldo_insuficiente" | "transaccion_en_curso" | "perfil_no_cargado" | ...).
function EconomyService:Debitar(player, monto, tipo, detalle)
	local objetivo, userId = resolver(player)
	if not userId then
		return false, "jugador_invalido"
	end
	local n = montoValido(monto)
	if not n then
		return false, "monto_invalido"
	end
	if self.EnTransaccion[userId] then
		self.Totales.RechazosBloqueo = self.Totales.RechazosBloqueo + 1
		self:_Auditar(objetivo or userId, "DebitoBloqueado", "Débito concurrente rechazado (" .. tostring(tipo) .. ", " .. n .. ")")
		return false, "transaccion_en_curso"
	end
	self.EnTransaccion[userId] = true
	local ok, resultado, extra = pcall(function()
		local eco = self:_Economia(objetivo or userId)
		if not eco then
			return false, "perfil_no_cargado"
		end
		if n == 0 then
			return true, eco.Saldo
		end
		if eco.Saldo < n then
			self.Totales.RechazosSaldo = self.Totales.RechazosSaldo + 1
			return false, "saldo_insuficiente"
		end
		local tipoTexto = texto(tipo or "Compra", self.MaxTipoCaracteres)
		if tipoTexto == "" then
			tipoTexto = "Compra"
		end
		local saldo = self:_Aplicar(objetivo, userId, eco, tipoTexto, -n, texto(detalle, self.MaxDetalleCaracteres))
		return true, saldo
	end)
	self.EnTransaccion[userId] = nil
	if not ok then
		warn(PREFIJO .. " Error en Debitar: " .. tostring(resultado))
		self:_Auditar(objetivo or userId, "ErrorDebito", tostring(resultado))
		return false, "error_interno"
	end
	return resultado, extra
end

-- ¿Hay un débito en curso para el jugador?
function EconomyService:EnTransaccionActiva(player)
	local _, userId = resolver(player)
	return userId ~= nil and self.EnTransaccion[userId] == true
end

-- Historial del jugador (copia, el más reciente primero). n opcional.
function EconomyService:Historial(player, n)
	local eco = self:_Economia(player)
	local lista = {}
	if not eco then
		return lista
	end
	local limite = math.floor(tonumber(n) or #eco.Historial)
	for i = #eco.Historial, 1, -1 do
		if #lista >= limite then
			break
		end
		table.insert(lista, copiarMovimiento(eco.Historial[i]))
	end
	return lista
end

-- Datos económicos del jugador para el cliente (StateSnapshot, panel de cafetería).
function EconomyService:Snapshot(player)
	local eco = self:_Economia(player)
	local base = {
		Saldo = 0,
		GanadoHoy = 0,
		LimiteDiario = self:LimiteDiario(),
		Simbolo = CFG.MonedaSimbolo or "◎",
		Nombre = CFG.MonedaNombre or "Monedas escolares",
		Disponible = eco ~= nil,
		Historial = {},
	}
	if eco then
		base.Saldo = eco.Saldo
		base.GanadoHoy = eco.GanadoHoy
		base.Historial = self:Historial(player, 10)
	end
	return base
end

-- Últimas n transacciones del servidor (copia, la más reciente primero; máx. TamanoTransacciones).
function EconomyService:Transacciones(n)
	local limite = math.clamp(math.floor(tonumber(n) or 50), 1, self.TamanoTransacciones)
	local lista = {}
	local disponibles = math.min(self.TotalTx, self.TamanoTransacciones)
	local indice = self.IndiceTx
	for _ = 1, math.min(limite, disponibles) do
		local tx = self.Transacciones[indice]
		if tx then
			table.insert(lista, {
				Id = tx.Id, T = tx.T, UserId = tx.UserId, Jugador = tx.Jugador, Tipo = tx.Tipo,
				Monto = tx.Monto, Saldo = tx.Saldo, Detalle = tx.Detalle,
			})
		end
		indice = indice - 1
		if indice < 1 then
			indice = self.TamanoTransacciones
		end
	end
	return lista
end

-- Resumen global para finanzas / dirección.
function EconomyService:ResumenGlobal()
	local circulante, jugadores = 0, 0
	for _, player in ipairs(Players:GetPlayers()) do
		local eco = self:_Economia(player)
		if eco then
			circulante = circulante + eco.Saldo
			jugadores = jugadores + 1
		end
	end
	local porTipo = {}
	for tipo, datos in pairs(self.Totales.PorTipo) do
		porTipo[tipo] = { Cantidad = datos.Cantidad, Entradas = datos.Entradas, Salidas = datos.Salidas }
	end
	local medio = 0
	if jugadores > 0 then
		medio = math.floor(circulante / jugadores + 0.5)
	end
	return {
		Moneda = CFG.MonedaNombre or "Monedas escolares",
		Simbolo = CFG.MonedaSimbolo or "◎",
		Transacciones = self.TotalTx,
		TotalAcreditado = self.Totales.Acreditado,
		TotalDebitado = self.Totales.Debitado,
		Neto = self.Totales.Acreditado - self.Totales.Debitado,
		Circulante = circulante,
		Jugadores = jugadores,
		SaldoMedio = medio,
		LimiteDiario = self:LimiteDiario(),
		RechazosSaldo = self.Totales.RechazosSaldo,
		RechazosLimite = self.Totales.RechazosLimite,
		RechazosBloqueo = self.Totales.RechazosBloqueo,
		PorTipo = porTipo,
		Desde = self.InicioUnix,
	}
end

return EconomyService
