--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.CafeteriaService
	Tipo: ModuleScript
	Tienda escolar / cafetería (docs/ARQUITECTURA.md §6, prueba P9). Inventario y precios en memoria del servidor a
	partir de Catalogs.Productos; puesto Abierto/Cerrado por el vendedor (VendedorUserId) o atención automática
	(NPC) si no hay vendedor conectado y Config.Cafeteria.NPCVendedorSiNoHayVendedor. El ProximityPrompt del
	mostrador (MapService o uno propio) abre el panel del cliente con el catálogo. CafeteriaPurchase: compra
	atómica (producto, cantidad, stock, precio DEL SERVIDOR, distancia al mostrador, puesto abierto, cooldown;
	EconomyService:Debitar ANTES de descontar stock y reembolso si el descuento falla) con recibo. CafeteriaManage:
	abrir/cerrar, precios en [PrecioMin, PrecioMax], reposición, inventario y cierre de caja. Emite "Cafeteria"
	{ Sub = "Estado" | "Recibo" | "Inventario" | "AbrirPanel" }.
]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Catalogs = require(Shared:WaitForChild("Catalogs"))
local MapaLogico = require(Shared:WaitForChild("MapaLogico"))
local RoleDefinitions = require(Shared:WaitForChild("RoleDefinitions"))
local RemoteContracts = require(Shared:WaitForChild("RemoteContracts"))
local Util = Shared:WaitForChild("Util")
local Signal = require(Util:WaitForChild("Signal"))
local Maid = require(Util:WaitForChild("Maid"))
local Zones = require(Util:WaitForChild("Zones"))
local Format = require(Util:WaitForChild("Format"))

local CafeteriaService = {}
CafeteriaService.Nombre = "CafeteriaService"

local PREFIJO = "[ColegioRP][CafeteriaService]"
local CFG = Config.Cafeteria or {}

CafeteriaService.ZonaTienda = "TIENDA"
CafeteriaService.PrecioMin = math.max(0, math.floor(tonumber(CFG.PrecioMin) or 1))
CafeteriaService.PrecioMax = math.max(CafeteriaService.PrecioMin, math.floor(tonumber(CFG.PrecioMax) or 200))
CafeteriaService.CooldownCompra = math.max(0, tonumber(CFG.CooldownCompra) or 3)
CafeteriaService.CantidadMax = math.max(1, math.floor(tonumber(CFG.CantidadMaxPorCompra) or 5))
CafeteriaService.DistanciaCompra = tonumber(Config.Distancias and Config.Distancias.Mostrador) or 14
CafeteriaService.DistanciaGestion = 20 -- el vendedor abre y repone desde el puesto
CafeteriaService.DistanciaCierrePanel = 20 -- el cliente cierra el panel al alejarse más
CafeteriaService.Tolerancia = 2
CafeteriaService.FactorStockMax = 2 -- stock máximo = stock inicial del catálogo x factor
CafeteriaService.ReposicionMax = 100 -- unidades máximas por reposición
CafeteriaService.CooldownReponerSeg = 2
CafeteriaService.IntervaloPromptSeg = 0.5
CafeteriaService.TamanoVentas = 200
CafeteriaService.ObservadorSeg = 600 -- tiempo que un jugador recibe actualizaciones tras abrir el panel

local MENSAJES = {
	producto_inexistente = "Ese producto no existe en la tienda.",
	cantidad_invalida = "Cantidad no válida (entre 1 y %d).",
	lejos = "Acércate al mostrador de la tienda para comprar.",
	lejos_gestion = "Debes estar en el puesto de la tienda.",
	sin_personaje = "Tu personaje no está disponible en este momento.",
	cerrado = "La tienda está cerrada.",
	cerrado_vendedor = "La tienda está cerrada: el vendedor aún no la ha abierto.",
	cooldown = "Espera %d s antes de otra compra.",
	sin_stock = "No queda stock suficiente de %s (quedan %d).",
	saldo_insuficiente = "No te alcanza: cuesta %s y tienes %s.",
	en_curso = "Ya tienes una compra en curso.",
	perfil = "Tu perfil aún se está cargando. Inténtalo en unos segundos.",
	pago = "No se pudo cobrar la compra. No se descontó nada.",
	sin_economia = "La economía no está disponible ahora mismo.",
	permiso = "No tienes permiso para esta acción.",
	precio_invalido = "El precio debe estar entre %d y %d.",
	reponer_espera = "Espera un momento antes de volver a reponer.",
	reponer_lleno = "El inventario ya está lleno.",
	accion_invalida = "Acción no válida.",
	error_interno = "No se pudo completar la operación. Inténtalo de nuevo.",
}

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function esJugador(player)
	return typeof(player) == "Instance" and player:IsA("Player")
end

local function esFinito(n)
	return typeof(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function posicionDe(player)
	if not esJugador(player) then
		return nil
	end
	local personaje = player.Character
	if not personaje then
		return nil
	end
	local raiz = personaje:FindFirstChild("HumanoidRootPart") or personaje.PrimaryPart
	if raiz and raiz:IsA("BasePart") then
		return raiz.Position
	end
	return nil
end

-- Posición mundial de una instancia (BasePart, Attachment o Model) o nil.
local function posicionInstancia(instancia)
	if typeof(instancia) ~= "Instance" or instancia.Parent == nil then
		return nil
	end
	if instancia:IsA("BasePart") then
		return instancia.Position
	end
	if instancia:IsA("Attachment") then
		return instancia.WorldPosition
	end
	if instancia:IsA("Model") then
		local ok, pivote = pcall(function()
			return instancia:GetPivot()
		end)
		if ok then
			return pivote.Position
		end
	end
	return nil
end

local function fallo(codigo, ...)
	local plantilla = MENSAJES[codigo] or MENSAJES.error_interno
	local ok, mensaje = pcall(string.format, plantilla, ...)
	if not ok then
		mensaje = plantilla
	end
	return false, codigo, mensaje
end

local function nuevaCaja()
	return { Desde = os.time(), Ventas = 0, Unidades = 0, Ingresos = 0, Reembolsos = 0, PorProducto = {} }
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function CafeteriaService:Init(registro)
	self.registro = registro
	self.Productos = {} -- id -> producto en memoria
	self.Orden = {}
	for _, base in ipairs(Catalogs.Productos or {}) do
		if typeof(base) == "table" and typeof(base.Id) == "string" and not self.Productos[base.Id] then
			local stock = math.max(0, math.floor(tonumber(base.Stock) or 0))
			local precio = math.clamp(math.floor(tonumber(base.Precio) or self.PrecioMin), self.PrecioMin, self.PrecioMax)
			self.Productos[base.Id] = {
				Id = base.Id,
				Nombre = tostring(base.Nombre or base.Id),
				Categoria = tostring(base.Categoria or ""),
				Descripcion = tostring(base.Descripcion or ""),
				Precio = precio,
				PrecioBase = precio,
				Stock = stock,
				StockInicial = stock,
				StockMax = math.max(stock * self.FactorStockMax, stock, 10),
				Vendidos = 0,
			}
			table.insert(self.Orden, base.Id)
		end
	end
	self.AbiertoManual = false
	self.VendedorUserId = nil
	self.VendedorNombre = nil
	self.UltimaCompra = {} -- userId -> os.clock()
	self.Comprando = {} -- userId -> true (bloqueo de compra)
	self.UltimaGestion = {} -- userId -> os.clock() de la última reposición
	self.UltimoPrompt = {} -- userId -> os.clock()
	self.Observadores = {} -- userId -> os.clock() en que abrió el panel
	self.VentasBuffer = table.create(self.TamanoVentas)
	self.IndiceVentas = 0
	self.TotalVentas = 0
	self.SiguienteRecibo = 0
	self.Caja = nuevaCaja()
	self.Estadisticas = { Ventas = 0, Unidades = 0, Ingresos = 0, Reembolsos = 0, Rechazos = 0 }
	self.Cambiado = Signal.new() -- (estado)
	self.Vendido = Signal.new() -- (player, recibo)
	self.maidPrompt = Maid.new()
	self.Conexiones = {}
	self.Activo = true
	self._firmaEstado = ""
	self._estadoPendiente = false
	self._inventarioPendiente = false
	self.Puesto = nil -- { Parte, Prompt }
end

function CafeteriaService:Start()
	local RemoteService = self:_S("RemoteService")
	if RemoteService and typeof(RemoteService.Registrar) == "function" then
		RemoteService:Registrar("CafeteriaPurchase", function(player, datos)
			return self:ManejarCompra(player, datos)
		end)
		RemoteService:Registrar("CafeteriaManage", function(player, datos)
			return self:ManejarGestion(player, datos)
		end)
	else
		warn(PREFIJO .. " RemoteService no disponible: CafeteriaPurchase y CafeteriaManage no tendrán handler.")
	end

	local okPrompt, errPrompt = pcall(self.EnlazarPrompt, self)
	if not okPrompt then
		warn(PREFIJO .. " No se pudo enlazar el prompt del mostrador: " .. tostring(errPrompt))
	end
	local MapService = self:_S("MapService")
	if MapService and typeof(MapService.Construido) == "table" and typeof(MapService.Construido.Connect) == "function" then
		table.insert(self.Conexiones, MapService.Construido:Connect(function()
			task.defer(function()
				local ok, err = pcall(self.EnlazarPrompt, self)
				if not ok then
					warn(PREFIJO .. " Error al reenlazar el prompt: " .. tostring(err))
				end
			end)
		end))
	end

	local SchoolDay = self:_S("SchoolDayService")
	if SchoolDay and typeof(SchoolDay.JornadaTerminada) == "table" and typeof(SchoolDay.JornadaTerminada.Connect) == "function" then
		table.insert(self.Conexiones, SchoolDay.JornadaTerminada:Connect(function()
			pcall(self.Reabastecer, self, "Nueva jornada")
		end))
	end

	local RoleService = self:_S("RoleService")
	if RoleService and typeof(RoleService.CargoCambiado) == "table" and typeof(RoleService.CargoCambiado.Connect) == "function" then
		table.insert(self.Conexiones, RoleService.CargoCambiado:Connect(function(player)
			pcall(self._RevisarVendedor, self, player)
		end))
	end

	table.insert(self.Conexiones, Players.PlayerRemoving:Connect(function(player)
		local userId = player.UserId
		self.Comprando[userId] = nil
		self.UltimoPrompt[userId] = nil
		self.Observadores[userId] = nil
		self.UltimaGestion[userId] = nil
		if self.VendedorUserId == userId then
			self.AbiertoManual = false
			self.VendedorUserId = nil
			self.VendedorNombre = nil
			self:_Auditar(nil, "TiendaCerrada", "El vendedor " .. player.Name .. " salió del servidor")
			self:_ProgramarEstado()
		end
	end))

	task.spawn(function()
		while self.Activo do
			task.wait(2)
			local ok, err = pcall(self._Tick, self)
			if not ok then
				warn(PREFIJO .. " Error en el ciclo de la tienda: " .. tostring(err))
			end
		end
	end)
	self._firmaEstado = self:_FirmaEstado()
end

function CafeteriaService:_S(nombre)
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

function CafeteriaService:_Auditar(player, accion, detalle)
	local AuditLog = self:_S("AuditLogService")
	if AuditLog and typeof(AuditLog.Registrar) == "function" then
		pcall(AuditLog.Registrar, AuditLog, "Economia", player, accion, detalle)
	end
end

function CafeteriaService:_Enviar(player, tipo, datos)
	local RemoteService = self:_S("RemoteService")
	if RemoteService and typeof(RemoteService.Enviar) == "function" and esJugador(player) then
		pcall(RemoteService.Enviar, RemoteService, player, tipo, datos)
	end
end

function CafeteriaService:_Notificar(player, texto, nivel, duracion)
	self:_Enviar(player, "Notificacion", { Texto = texto, Nivel = nivel or "info", Duracion = duracion or 5 })
end

function CafeteriaService:_Tiene(player, permiso)
	local RoleService = self:_S("RoleService")
	if RoleService and typeof(RoleService.Tiene) == "function" then
		local ok, tiene = pcall(RoleService.Tiene, RoleService, player, permiso)
		return ok and tiene == true
	end
	return esJugador(player) and RoleDefinitions.Tiene(player:GetAttribute("Cargo"), permiso)
end

-- ¿Puede fijar precios? cafeteria.precios (lo exige RemoteContracts para "Precio") o el propio vendedor
-- si el contrato no fija permiso para esa acción.
function CafeteriaService:PuedeFijarPrecios(player)
	if self:_Tiene(player, "cafeteria.precios") then
		return true
	end
	local permiso = RemoteContracts.PermisoPara("CafeteriaManage", { Accion = "Precio" })
	if permiso == nil then
		return self:_Tiene(player, "cafeteria.vender")
	end
	if permiso ~= RemoteContracts.DENEGADO and permiso ~= "cafeteria.precios" then
		return self:_Tiene(player, permiso) and self:_Tiene(player, "cafeteria.vender")
	end
	return false
end

function CafeteriaService:_HayVendedor()
	local RoleService = self:_S("RoleService")
	if RoleService and typeof(RoleService.ConPermiso) == "function" then
		local ok, lista = pcall(RoleService.ConPermiso, RoleService, "cafeteria.vender")
		if ok and typeof(lista) == "table" then
			return #lista > 0
		end
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if RoleDefinitions.Tiene(player:GetAttribute("Cargo"), "cafeteria.vender") then
			return true
		end
	end
	return false
end

-- Si el vendedor que abrió perdió el cargo, el puesto se cierra.
function CafeteriaService:_RevisarVendedor(player)
	if not self.VendedorUserId then
		return
	end
	if player and player.UserId ~= self.VendedorUserId then
		return
	end
	local vendedor = Players:GetPlayerByUserId(self.VendedorUserId)
	if not vendedor or not self:_Tiene(vendedor, "cafeteria.vender") then
		self.AbiertoManual = false
		self.VendedorUserId = nil
		self.VendedorNombre = nil
		self:_Auditar(vendedor, "TiendaCerrada", "El vendedor dejó el cargo")
		self:_ProgramarEstado()
	end
end

function CafeteriaService:_Tick()
	self:_RevisarVendedor(nil)
	local ahora = os.clock()
	for userId, desde in pairs(self.Observadores) do
		if ahora - desde > self.ObservadorSeg or not Players:GetPlayerByUserId(userId) then
			self.Observadores[userId] = nil
		end
	end
	-- Cambios de modo (llega o se va el último vendedor) -> se avisa a quien mira la tienda.
	local firma = self:_FirmaEstado()
	if firma ~= self._firmaEstado then
		self:_ProgramarEstado()
	end
end

---------------------------------------------------------------------------------------------------
-- Estado e inventario
---------------------------------------------------------------------------------------------------

-- { Abierto, Modo = "Vendedor" | "NPC" | "Cerrado", VendedorUserId, Vendedor, HayVendedor, AbiertoManual }
function CafeteriaService:Estado()
	local hayVendedor = self:_HayVendedor()
	local abierto, modo = false, "Cerrado"
	local vendedorActivo = self.VendedorUserId and Players:GetPlayerByUserId(self.VendedorUserId)
	if self.AbiertoManual and vendedorActivo then
		abierto, modo = true, "Vendedor"
	elseif not hayVendedor and CFG.NPCVendedorSiNoHayVendedor ~= false then
		abierto, modo = true, "NPC"
	end
	local nombre = nil
	if modo == "Vendedor" then
		nombre = self.VendedorNombre
	elseif modo == "NPC" then
		nombre = "Atención automática"
	end
	return {
		Abierto = abierto,
		Modo = modo,
		VendedorUserId = self.VendedorUserId,
		Vendedor = nombre,
		HayVendedor = hayVendedor,
		AbiertoManual = self.AbiertoManual,
	}
end

function CafeteriaService:_FirmaEstado()
	local e = self:Estado()
	return tostring(e.Abierto) .. "|" .. e.Modo .. "|" .. tostring(e.VendedorUserId)
end

-- Catálogo público (sin datos internos), en el orden de Catalogs.Productos.
function CafeteriaService:Catalogo()
	local lista = {}
	for _, id in ipairs(self.Orden) do
		local p = self.Productos[id]
		table.insert(lista, {
			Id = p.Id, Nombre = p.Nombre, Categoria = p.Categoria, Descripcion = p.Descripcion,
			Precio = p.Precio, Stock = p.Stock,
		})
	end
	return lista
end

-- Inventario completo (vendedor / finanzas).
function CafeteriaService:Inventario()
	local lista = {}
	for _, id in ipairs(self.Orden) do
		local p = self.Productos[id]
		table.insert(lista, {
			Id = p.Id, Nombre = p.Nombre, Categoria = p.Categoria, Descripcion = p.Descripcion,
			Precio = p.Precio, PrecioBase = p.PrecioBase, Stock = p.Stock, StockInicial = p.StockInicial,
			StockMax = p.StockMax, Vendidos = p.Vendidos,
		})
	end
	return lista
end

function CafeteriaService:ResumenCaja()
	local caja = self.Caja
	local productos = {}
	for id, datos in pairs(caja.PorProducto) do
		table.insert(productos, { Id = id, Nombre = datos.Nombre, Unidades = datos.Unidades, Ingresos = datos.Ingresos })
	end
	table.sort(productos, function(a, b)
		if a.Ingresos == b.Ingresos then
			return a.Id < b.Id
		end
		return a.Ingresos > b.Ingresos
	end)
	return {
		Desde = caja.Desde,
		Hasta = os.time(),
		Ventas = caja.Ventas,
		Unidades = caja.Unidades,
		Ingresos = caja.Ingresos,
		Reembolsos = caja.Reembolsos,
		Productos = productos,
	}
end

function CafeteriaService:Snapshot()
	return {
		Estado = self:Estado(),
		Catalogo = self:Catalogo(),
		Caja = self:ResumenCaja(),
		TotalVentas = self.TotalVentas,
		Limites = self:_Limites(),
	}
end

-- Últimos n recibos (copia, el más reciente primero).
function CafeteriaService:Ventas(n)
	local limite = math.clamp(math.floor(tonumber(n) or 50), 1, self.TamanoVentas)
	local lista = {}
	local disponibles = math.min(self.TotalVentas, self.TamanoVentas)
	local indice = self.IndiceVentas
	for _ = 1, math.min(limite, disponibles) do
		local v = self.VentasBuffer[indice]
		if v then
			local items = {}
			for _, item in ipairs(v.Items) do
				table.insert(items, { Id = item.Id, Nombre = item.Nombre, Cantidad = item.Cantidad, PrecioUnitario = item.PrecioUnitario, Subtotal = item.Subtotal })
			end
			table.insert(lista, {
				Id = v.Id, Fecha = v.Fecha, UserId = v.UserId, Comprador = v.Comprador, Items = items,
				Total = v.Total, Modo = v.Modo, Vendedor = v.Vendedor,
			})
		end
		indice = indice - 1
		if indice < 1 then
			indice = self.TamanoVentas
		end
	end
	return lista
end

function CafeteriaService:_Limites()
	return {
		PrecioMin = self.PrecioMin,
		PrecioMax = self.PrecioMax,
		CantidadMax = self.CantidadMax,
		Cooldown = self.CooldownCompra,
		DistanciaCierre = self.DistanciaCierrePanel,
		ReposicionMax = self.ReposicionMax,
	}
end

-- Destinatarios de actualizaciones: quien abrió el panel hace poco y sigue cerca, y los vendedores.
function CafeteriaService:_Destinatarios()
	local lista = {}
	local centro = self:PosicionMostrador()
	for _, player in ipairs(Players:GetPlayers()) do
		local incluir = false
		if self.Observadores[player.UserId] then
			local pos = posicionDe(player)
			incluir = centro == nil or (pos ~= nil and (pos - centro).Magnitude <= self.DistanciaCierrePanel * 2)
		end
		if not incluir and (self:_Tiene(player, "cafeteria.vender") or player.UserId == self.VendedorUserId) then
			incluir = true
		end
		if incluir then
			table.insert(lista, player)
		end
	end
	return lista
end

function CafeteriaService:_ProgramarEstado()
	if self._estadoPendiente then
		return
	end
	self._estadoPendiente = true
	task.delay(0.3, function()
		self._estadoPendiente = false
		local estado = self:Estado()
		self._firmaEstado = self:_FirmaEstado()
		local datos = {
			Sub = "Estado", Abierto = estado.Abierto, Modo = estado.Modo, Vendedor = estado.Vendedor,
			VendedorUserId = estado.VendedorUserId, HayVendedor = estado.HayVendedor,
		}
		for _, player in ipairs(self:_Destinatarios()) do
			self:_Enviar(player, "Cafeteria", datos)
		end
		self.Cambiado:Fire(estado)
	end)
end

function CafeteriaService:_ProgramarInventario()
	if self._inventarioPendiente then
		return
	end
	self._inventarioPendiente = true
	task.delay(0.5, function()
		self._inventarioPendiente = false
		local datos = { Sub = "Inventario", Catalogo = self:Catalogo() }
		for _, player in ipairs(self:_Destinatarios()) do
			self:_Enviar(player, "Cafeteria", datos)
		end
	end)
end

-- Repone todo el inventario hasta el stock inicial (nueva jornada: llega el proveedor).
function CafeteriaService:Reabastecer(motivo)
	local unidades = 0
	for _, id in ipairs(self.Orden) do
		local p = self.Productos[id]
		if p.Stock < p.StockInicial then
			unidades = unidades + (p.StockInicial - p.Stock)
			p.Stock = p.StockInicial
		end
	end
	if unidades > 0 then
		self:_Auditar(nil, "TiendaReabastecida", tostring(motivo or "Reabastecimiento") .. ": +" .. unidades .. " unidades")
		self:_ProgramarInventario()
	end
	return unidades
end

---------------------------------------------------------------------------------------------------
-- Mostrador y prompt
---------------------------------------------------------------------------------------------------
function CafeteriaService:PosicionMostrador()
	local enMapa = self.Puesto and posicionInstancia(self.Puesto.Parte)
	if enMapa then
		return enMapa
	end
	local zona = MapaLogico.Zonas[self.ZonaTienda]
	if zona and typeof(zona.Mostrador) == "table" and typeof(zona.Mostrador.Centro) == "Vector3" then
		return zona.Mostrador.Centro
	end
	return nil
end

function CafeteriaService:_Distancia(player)
	local pos = posicionDe(player)
	if not pos then
		return nil
	end
	local centro = self:PosicionMostrador()
	if not centro then
		return 0
	end
	return (pos - centro).Magnitude
end

-- El vendedor gestiona desde el puesto: dentro de la zona TIENDA o cerca del mostrador.
function CafeteriaService:_EnPuesto(player)
	local pos = posicionDe(player)
	if not pos then
		return false, "sin_personaje"
	end
	if Zones.Contiene(self.ZonaTienda, pos) then
		return true
	end
	local distancia = self:_Distancia(player)
	if distancia and distancia <= self.DistanciaGestion + self.Tolerancia then
		return true
	end
	return false, "lejos_gestion"
end

function CafeteriaService:EnlazarPrompt()
	self.maidPrompt:DoCleaning()
	self.Puesto = nil
	local parte, prompt = nil, nil
	local MapService = self:_S("MapService")
	if MapService and typeof(MapService.Cafeteria) == "function" then
		local ok, info = pcall(MapService.Cafeteria, MapService)
		if ok and typeof(info) == "table" and typeof(info.Prompt) == "Instance" and info.Prompt.Parent ~= nil then
			prompt = info.Prompt
			parte = info.Mostrador or info.Prompt.Parent
		end
	end
	if not prompt then
		local raiz = workspace:FindFirstChild((Config.Nombres and Config.Nombres.CarpetaMapa) or "ColegioRP_Mapa")
		local carpeta = raiz and raiz:FindFirstChild("Cafeteria")
		if carpeta then
			for _, d in ipairs(carpeta:GetDescendants()) do
				if d:IsA("ProximityPrompt") and d:GetAttribute("RPTipo") == "Cafeteria" then
					prompt = d
					parte = d.Parent
					break
				end
			end
		end
	end
	if not prompt then
		-- Sin mostrador del mapa: se crea uno propio en el punto de MapaLogico.Zonas.TIENDA.Mostrador.
		local zona = MapaLogico.Zonas[self.ZonaTienda]
		if not zona or typeof(zona.Mostrador) ~= "table" or typeof(zona.Mostrador.Centro) ~= "Vector3" then
			warn(PREFIJO .. " Sin mostrador de tienda (MapaLogico.Zonas.TIENDA.Mostrador); la compra solo funcionará por panel.")
			return
		end
		local padre = nil
		if MapService and typeof(MapService.Carpeta) == "function" then
			local ok, carpeta = pcall(MapService.Carpeta, MapService, "Cafeteria")
			if ok and typeof(carpeta) == "Instance" and carpeta.Parent ~= nil then
				padre = carpeta
			end
		end
		if not padre then
			padre = Instance.new("Folder")
			padre.Name = "ColegioRP_Tienda"
			padre.Parent = workspace
			self.maidPrompt:GiveTask(padre)
		end
		parte = Instance.new("Part")
		parte.Name = "Mostrador"
		parte.Size = Vector3.new(4, 2, 2)
		parte.CFrame = CFrame.new(zona.Mostrador.Centro)
		parte.Anchored = true
		parte.CanCollide = false
		parte.CanQuery = false
		parte.CanTouch = false
		parte.CastShadow = false
		parte.Transparency = 1
		parte.Parent = padre
		self.maidPrompt:GiveTask(parte)
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = "ColegioRP_Prompt"
		prompt.ActionText = "Comprar"
		prompt.ObjectText = "Tienda escolar"
		prompt.MaxActivationDistance = 10
		prompt.HoldDuration = 0
		prompt.RequiresLineOfSight = false
		prompt.Parent = parte
	end
	prompt:SetAttribute("RPTipo", "Cafeteria")
	if prompt:GetAttribute("RPId") == nil then
		prompt:SetAttribute("RPId", self.ZonaTienda)
	end
	if prompt:GetAttribute("RPAccion") == nil then
		prompt:SetAttribute("RPAccion", "AbrirPanel")
	end
	self.Puesto = { Parte = parte, Prompt = prompt }
	self.maidPrompt:GiveTask(prompt.Triggered:Connect(function(player)
		local ok, err = pcall(self.AbrirPanel, self, player)
		if not ok then
			warn(PREFIJO .. " Error al abrir el panel: " .. tostring(err))
		end
	end))
end

-- Envía al jugador el panel de la tienda (catálogo con precios del servidor y estado).
function CafeteriaService:AbrirPanel(player)
	if not esJugador(player) then
		return false
	end
	local ahora = os.clock()
	local ultimo = self.UltimoPrompt[player.UserId]
	if ultimo and ahora - ultimo < self.IntervaloPromptSeg then
		return false
	end
	self.UltimoPrompt[player.UserId] = ahora
	local distancia = self:_Distancia(player)
	if not distancia or distancia > self.DistanciaCompra + self.Tolerancia then
		self:_Notificar(player, MENSAJES.lejos, "aviso", 4)
		return false
	end
	self.Observadores[player.UserId] = ahora
	local estado = self:Estado()
	local Economy = self:_S("EconomyService")
	local saldo = nil
	if Economy and typeof(Economy.Saldo) == "function" then
		local ok, valor = pcall(Economy.Saldo, Economy, player)
		if ok then
			saldo = valor
		end
	end
	local esVendedor = self:_Tiene(player, "cafeteria.vender")
	local datos = {
		Sub = "AbrirPanel",
		Catalogo = self:Catalogo(),
		Abierto = estado.Abierto,
		Modo = estado.Modo,
		Vendedor = estado.Vendedor,
		VendedorUserId = estado.VendedorUserId,
		Saldo = saldo,
		EsVendedor = esVendedor,
		PuedePrecios = self:PuedeFijarPrecios(player),
		Mostrador = self:PosicionMostrador(),
		Limites = self:_Limites(),
	}
	if esVendedor then
		datos.Caja = self:ResumenCaja()
	end
	self:_Enviar(player, "Cafeteria", datos)
	return true
end

---------------------------------------------------------------------------------------------------
-- Compra
---------------------------------------------------------------------------------------------------
function CafeteriaService:_RegistrarVenta(recibo, player)
	self.TotalVentas = self.TotalVentas + 1
	self.IndiceVentas = self.IndiceVentas + 1
	if self.IndiceVentas > self.TamanoVentas then
		self.IndiceVentas = 1
	end
	self.VentasBuffer[self.IndiceVentas] = {
		Id = recibo.Id, Fecha = recibo.Fecha, UserId = player.UserId, Comprador = player.Name, Items = recibo.Items,
		Total = recibo.Total, Modo = recibo.Modo, Vendedor = recibo.Vendedor,
	}
	local caja = self.Caja
	caja.Ventas = caja.Ventas + 1
	caja.Ingresos = caja.Ingresos + recibo.Total
	for _, item in ipairs(recibo.Items) do
		caja.Unidades = caja.Unidades + item.Cantidad
		local porProducto = caja.PorProducto[item.Id]
		if not porProducto then
			porProducto = { Nombre = item.Nombre, Unidades = 0, Ingresos = 0 }
			caja.PorProducto[item.Id] = porProducto
		end
		porProducto.Unidades = porProducto.Unidades + item.Cantidad
		porProducto.Ingresos = porProducto.Ingresos + item.Subtotal
		self.Estadisticas.Unidades = self.Estadisticas.Unidades + item.Cantidad
	end
	self.Estadisticas.Ventas = self.Estadisticas.Ventas + 1
	self.Estadisticas.Ingresos = self.Estadisticas.Ingresos + recibo.Total
end

function CafeteriaService:_Reembolsar(player, total, detalle, motivo)
	local Economy = self:_S("EconomyService")
	local ok = false
	if Economy and typeof(Economy.Acreditar) == "function" then
		local exito, resultado = pcall(Economy.Acreditar, Economy, player, total, "Reembolso", "Reembolso: " .. detalle)
		ok = exito and resultado == true
	end
	self.Caja.Reembolsos = self.Caja.Reembolsos + 1
	self.Estadisticas.Reembolsos = self.Estadisticas.Reembolsos + 1
	self:_Auditar(player, "Reembolso", detalle .. " (" .. total .. "): " .. tostring(motivo) .. (ok and "" or " · REEMBOLSO FALLIDO"))
	return ok
end

-- Compra atómica. Devuelve ok, recibo | (false, codigo, mensaje).
function CafeteriaService:Comprar(player, productoId, cantidad)
	if not esJugador(player) then
		return fallo("sin_personaje")
	end
	local userId = player.UserId
	if self.Comprando[userId] then
		return fallo("en_curso")
	end
	self.Comprando[userId] = true
	local ok, a, b, c = pcall(self._Comprar, self, player, productoId, cantidad)
	self.Comprando[userId] = nil
	if not ok then
		warn(PREFIJO .. " Error en la compra de " .. player.Name .. ": " .. tostring(a))
		self:_Auditar(player, "CompraError", tostring(a))
		return fallo("error_interno")
	end
	return a, b, c
end

function CafeteriaService:_Comprar(player, productoId, cantidad)
	local userId = player.UserId
	local producto = self.Productos[productoId]
	if typeof(productoId) ~= "string" or not producto then
		return fallo("producto_inexistente")
	end
	if not esFinito(cantidad) or cantidad ~= math.floor(cantidad) or cantidad < 1 or cantidad > self.CantidadMax then
		return fallo("cantidad_invalida", self.CantidadMax)
	end
	local distancia = self:_Distancia(player)
	if not distancia then
		return fallo("sin_personaje")
	end
	if distancia > self.DistanciaCompra + self.Tolerancia then
		self.Estadisticas.Rechazos = self.Estadisticas.Rechazos + 1
		self:_Auditar(player, "CompraRechazada", string.format("distancia %.1f > %.0f", distancia, self.DistanciaCompra))
		return fallo("lejos")
	end
	local estado = self:Estado()
	if not estado.Abierto then
		if estado.HayVendedor then
			return fallo("cerrado_vendedor")
		end
		return fallo("cerrado")
	end
	local ultima = self.UltimaCompra[userId]
	if ultima and os.clock() - ultima < self.CooldownCompra then
		return fallo("cooldown", math.max(1, math.ceil(self.CooldownCompra - (os.clock() - ultima))))
	end
	if producto.Stock < cantidad then
		return fallo("sin_stock", producto.Nombre, producto.Stock)
	end

	-- Precio del servidor (nunca del cliente).
	local precio = producto.Precio
	local total = precio * cantidad
	local detalle = cantidad .. "x " .. producto.Nombre
	local Economy = self:_S("EconomyService")
	if not Economy or typeof(Economy.Debitar) ~= "function" then
		return fallo("sin_economia")
	end

	-- 1. Cobro atómico ANTES de tocar el stock.
	local okDebito, saldoOError = Economy:Debitar(player, total, "Compra", detalle)
	if not okDebito then
		if saldoOError == "saldo_insuficiente" then
			local saldo = 0
			if typeof(Economy.Saldo) == "function" then
				saldo = Economy:Saldo(player)
			end
			return fallo("saldo_insuficiente", Format.Moneda(total), Format.Moneda(saldo))
		elseif saldoOError == "transaccion_en_curso" then
			return fallo("en_curso")
		elseif saldoOError == "perfil_no_cargado" then
			return fallo("perfil")
		end
		self:_Auditar(player, "CompraRechazada", "débito fallido: " .. tostring(saldoOError))
		return fallo("pago")
	end

	-- 2. Doble verificación del stock y descuento; si falla, se reembolsa.
	if producto.Stock < cantidad then
		self:_Reembolsar(player, total, detalle, "stock agotado durante el cobro")
		return fallo("sin_stock", producto.Nombre, producto.Stock)
	end
	local okStock, errStock = pcall(function()
		producto.Stock = producto.Stock - cantidad
		producto.Vendidos = producto.Vendidos + cantidad
	end)
	if not okStock then
		self:_Reembolsar(player, total, detalle, "error al descontar stock: " .. tostring(errStock))
		return fallo("error_interno")
	end

	self.UltimaCompra[userId] = os.clock()
	self.SiguienteRecibo = self.SiguienteRecibo + 1
	local fecha = os.time()
	local saldoFinal = saldoOError
	local recibo = {
		Id = string.format("R-%05d", self.SiguienteRecibo),
		Items = {
			{ Id = producto.Id, Nombre = producto.Nombre, Cantidad = cantidad, PrecioUnitario = precio, Subtotal = total },
		},
		Total = total,
		Saldo = saldoFinal,
		Fecha = fecha,
		FechaTexto = Format.Fecha(fecha),
		Modo = estado.Modo,
		Vendedor = estado.Vendedor,
	}
	self:_RegistrarVenta(recibo, player)
	self:_Enviar(player, "Cafeteria", { Sub = "Recibo", Recibo = recibo })
	self.Vendido:Fire(player, recibo)
	self:_ProgramarInventario()
	-- Aviso al vendedor que atiende (si no es el comprador).
	if estado.Modo == "Vendedor" and self.VendedorUserId and self.VendedorUserId ~= userId then
		local vendedor = Players:GetPlayerByUserId(self.VendedorUserId)
		if vendedor then
			self:_Notificar(vendedor, "Venta: " .. detalle .. " a " .. player.DisplayName .. " (" .. Format.Moneda(total) .. ").", "info", 3)
		end
	end
	return true, recibo
end

function CafeteriaService:ManejarCompra(player, datos)
	local ok, a, b = self:Comprar(player, datos.ProductoId, datos.Cantidad)
	if ok then
		local producto = self.Productos[datos.ProductoId]
		return { ok = true, datos = { Recibo = a, Producto = { Id = producto.Id, Stock = producto.Stock } } }
	end
	return { ok = false, error = b or MENSAJES.error_interno, datos = { Codigo = a } }
end

---------------------------------------------------------------------------------------------------
-- Gestión del puesto (vendedor / precios)
---------------------------------------------------------------------------------------------------
function CafeteriaService:_RespuestaGestion(player, mensaje, extra)
	local datos = {
		Mensaje = mensaje,
		Estado = self:Estado(),
		Catalogo = self:Catalogo(),
		Inventario = self:Inventario(),
		PuedePrecios = self:PuedeFijarPrecios(player),
		EsVendedor = self:_Tiene(player, "cafeteria.vender"),
		Limites = self:_Limites(),
	}
	if datos.EsVendedor then
		datos.Caja = self:ResumenCaja()
	end
	for clave, valor in pairs(extra or {}) do
		datos[clave] = valor
	end
	return { ok = true, datos = datos }
end

-- Fija el precio validado en [PrecioMin, PrecioMax]. Devuelve ok, mensaje | (false, codigo, mensaje).
function CafeteriaService:_FijarPrecio(productoId, valor, player)
	local producto = typeof(productoId) == "string" and self.Productos[productoId] or nil
	if not producto then
		return fallo("producto_inexistente")
	end
	if not esFinito(valor) then
		return fallo("precio_invalido", self.PrecioMin, self.PrecioMax)
	end
	local precio = math.floor(valor + 0.5)
	if precio < self.PrecioMin or precio > self.PrecioMax then
		return fallo("precio_invalido", self.PrecioMin, self.PrecioMax)
	end
	local anterior = producto.Precio
	producto.Precio = precio
	self:_Auditar(player, "PrecioCambiado", producto.Id .. ": " .. anterior .. " -> " .. precio)
	self:_ProgramarInventario()
	return true, "Precio de " .. producto.Nombre .. ": " .. Format.Moneda(precio) .. "."
end

-- API para otros servicios (StaffService): FijarPrecio(productoId, precio, actor?) -> ok, mensajeOError.
-- Si se indica el jugador que actúa, debe poder fijar precios (cafeteria.precios).
function CafeteriaService:FijarPrecio(productoId, precio, player)
	if esJugador(player) and not self:PuedeFijarPrecios(player) then
		return false, MENSAJES.permiso
	end
	local ok, a, b = self:_FijarPrecio(productoId, precio, player)
	if ok then
		return true, a
	end
	return false, b
end

-- Devuelve ok, mensaje | (false, codigo, mensaje), extra.
function CafeteriaService:Gestionar(player, datos)
	local accion = datos.Accion
	local esVendedor = self:_Tiene(player, "cafeteria.vender")
	if accion == "Precio" then
		if not self:PuedeFijarPrecios(player) then
			return fallo("permiso")
		end
		local ok, codigoOMensaje, mensaje = self:_FijarPrecio(datos.ProductoId, datos.Valor, player)
		if not ok then
			return false, codigoOMensaje, mensaje
		end
		return true, codigoOMensaje
	end

	-- El resto de acciones son del vendedor (cafeteria.vender; RemoteService ya lo exige).
	if not esVendedor then
		return fallo("permiso")
	end
	if accion == "Abrir" then
		local enPuesto, codigo = self:_EnPuesto(player)
		if not enPuesto then
			return fallo(codigo or "lejos_gestion")
		end
		self.AbiertoManual = true
		self.VendedorUserId = player.UserId
		self.VendedorNombre = player.DisplayName
		self:_Auditar(player, "TiendaAbierta", "Atiende " .. player.Name)
		self:_ProgramarEstado()
		return true, "Abriste la tienda escolar."
	elseif accion == "Cerrar" then
		self.AbiertoManual = false
		self.VendedorUserId = nil
		self.VendedorNombre = nil
		self:_Auditar(player, "TiendaCerrada", "Cerrada por " .. player.Name)
		self:_ProgramarEstado()
		return true, "Cerraste la tienda escolar."
	elseif accion == "Reponer" then
		local enPuesto, codigo = self:_EnPuesto(player)
		if not enPuesto then
			return fallo(codigo or "lejos_gestion")
		end
		local ultimo = self.UltimaGestion[player.UserId]
		if ultimo and os.clock() - ultimo < self.CooldownReponerSeg then
			return fallo("reponer_espera")
		end
		local objetivos = {}
		if datos.ProductoId ~= nil then
			local producto = self.Productos[datos.ProductoId]
			if not producto then
				return fallo("producto_inexistente")
			end
			table.insert(objetivos, producto)
		else
			for _, id in ipairs(self.Orden) do
				table.insert(objetivos, self.Productos[id])
			end
		end
		local cantidad = nil
		if datos.Valor ~= nil then
			if not esFinito(datos.Valor) then
				return fallo("accion_invalida")
			end
			cantidad = math.clamp(math.floor(datos.Valor), 1, self.ReposicionMax)
		end
		local total = 0
		for _, producto in ipairs(objetivos) do
			local nuevo = producto.Stock
			if cantidad then
				nuevo = math.min(producto.StockMax, producto.Stock + cantidad)
			else
				nuevo = math.max(producto.Stock, producto.StockInicial)
			end
			total = total + (nuevo - producto.Stock)
			producto.Stock = nuevo
		end
		if total <= 0 then
			return fallo("reponer_lleno")
		end
		self.UltimaGestion[player.UserId] = os.clock()
		self:_Auditar(player, "TiendaRepuesta", "+" .. total .. " unidades (" .. (datos.ProductoId or "todo") .. ")")
		self:_ProgramarInventario()
		return true, "Repusiste " .. Format.Plural(total, "unidad", "unidades") .. "."
	elseif accion == "Inventario" then
		self.Observadores[player.UserId] = os.clock()
		return true, nil
	elseif accion == "Cierre" then
		local resumen = self:ResumenCaja()
		self.Caja = nuevaCaja()
		self:_Auditar(player, "CierreCaja", string.format("%d ventas, %d unidades, %d monedas", resumen.Ventas, resumen.Unidades, resumen.Ingresos))
		return true, "Cierre de caja: " .. Format.Plural(resumen.Ventas, "venta", "ventas") .. " por " .. Format.Moneda(resumen.Ingresos) .. ".", { Resumen = resumen }
	end
	return fallo("accion_invalida")
end

function CafeteriaService:ManejarGestion(player, datos)
	local ok, a, b = self:Gestionar(player, datos)
	if ok then
		return self:_RespuestaGestion(player, a, b)
	end
	if a == "permiso" or a == "lejos_gestion" or a == "producto_inexistente" then
		self:_Auditar(player, "GestionRechazada", tostring(datos.Accion) .. ": " .. tostring(a))
	end
	return { ok = false, error = b or MENSAJES.error_interno, datos = { Codigo = a, Estado = self:Estado() } }
end

return CafeteriaService
