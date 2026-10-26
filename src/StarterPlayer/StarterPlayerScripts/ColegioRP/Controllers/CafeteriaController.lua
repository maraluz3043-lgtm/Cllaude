--[[
	Ruta en el Explorer: StarterPlayer.StarterPlayerScripts.ColegioRP.Controllers.CafeteriaController
	Tipo: ModuleScript
	Panel de la tienda escolar (docs/ARQUITECTURA.md §7). Pestaña "Comprar": catálogo con precios y stock del
	servidor, carrito, total, saldo y compra (CafeteriaPurchase por producto, respetando el cooldown) con recibo.
	Pestaña "Vendedor" (cafeteria.vender / cafeteria.precios): abrir/cerrar el puesto, editar precios dentro de
	[PrecioMin, PrecioMax], reponer, inventario y cierre de caja (CafeteriaManage). Se abre con EventoCliente
	"Cafeteria" Sub = "AbrirPanel" (lo envía el servidor al usar el mostrador) y se cierra con el botón, con
	Escape / B o al alejarse más de 20 studs del mostrador. ScreenGui "ColegioRP_Cafeteria".
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TIMEOUT = 30
local function esperarHijo(padre, nombre)
	local hijo = nil
	if padre then
		hijo = padre:FindFirstChild(nombre) or padre:WaitForChild(nombre, TIMEOUT)
	end
	if not hijo then
		error("[ColegioRP][CafeteriaController] No apareció '" .. tostring(nombre) .. "' en " .. TIMEOUT .. " s")
	end
	return hijo
end

local RP = esperarHijo(ReplicatedStorage, "ColegioRP")
local Shared = esperarHijo(RP, "Shared")
local Util = esperarHijo(Shared, "Util")
local Config = require(esperarHijo(Shared, "Config"))
local UITheme = require(esperarHijo(Shared, "UITheme"))
local RoleDefinitions = require(esperarHijo(Shared, "RoleDefinitions"))
local Net = require(esperarHijo(Util, "Net"))
local Maid = require(esperarHijo(Util, "Maid"))
local Format = require(esperarHijo(Util, "Format"))
local UIBuilder = require(esperarHijo(esperarHijo(script.Parent.Parent, "UI"), "UIBuilder"))

local LocalPlayer = Players.LocalPlayer
local Colores = UITheme.Colores

local CafeteriaController = {}
CafeteriaController.Nombre = "CafeteriaController"
-- Este controlador atiende su propio evento "AbrirPanel" (InteractionController no lo delega).
CafeteriaController.ManejaAperturaPropia = true

---------------------------------------------------------------------------------------------------
-- Constantes
---------------------------------------------------------------------------------------------------
local LOG = "[ColegioRP][CafeteriaController] "
local ORDEN_PANTALLA = (UITheme.Capas and UITheme.Capas.Panel) or 50
local CFG = Config.Cafeteria or {}
local ANCHO_PANEL = 640
local ALTO_PANEL = 560
local INTERVALO_DISTANCIA = 0.5
local MARGEN_ESPERA = 0.25 -- segundos extra sobre el cooldown entre compras del carrito

local CATEGORIAS = { Comida = "Comida", Snack = "Snack", Bebida = "Bebida" }

---------------------------------------------------------------------------------------------------
-- Estado
---------------------------------------------------------------------------------------------------
local activo = false
local abierto = false
local catalogo = {} -- array { Id, Nombre, Categoria, Descripcion, Precio, Stock }
local porId = {}
local inventario = {} -- id -> { StockMax, Vendidos, PrecioBase } (vendedor)
local carrito = {} -- id -> cantidad
local tienda = { Abierto = false, Modo = "Cerrado", Vendedor = nil }
local saldo = nil
local esVendedor = false
local puedePrecios = false
local caja = nil
local mostrador = nil -- Vector3
local limites = {
	PrecioMin = tonumber(CFG.PrecioMin) or 1,
	PrecioMax = tonumber(CFG.PrecioMax) or 200,
	CantidadMax = tonumber(CFG.CantidadMaxPorCompra) or 5,
	Cooldown = tonumber(CFG.CooldownCompra) or 3,
	DistanciaCierre = 20,
}
local pestana = "Comprar"
local comprando = false
local gestionando = false
local estadoCompra = ""
local recibosVistos = {}
local maid = Maid.new()
local maidPanel = Maid.new()
local ui = { FilasCompra = {}, FilasVendedor = {}, IdsCompra = "", IdsVendedor = "" }

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function obtenerControlador(nombre)
	local registro = CafeteriaController.registro
	if typeof(registro) ~= "table" or typeof(registro.Get) ~= "function" then
		return nil
	end
	local ok, controlador = pcall(registro.Get, nombre)
	if ok and typeof(controlador) == "table" then
		return controlador
	end
	return nil
end

local function notificar(texto, nivel, duracion)
	local Notif = obtenerControlador("NotificationController")
	if Notif and typeof(Notif.Notificar) == "function" then
		pcall(Notif.Notificar, Notif, texto, nivel or "info", duracion)
	else
		print(LOG .. tostring(texto))
	end
end

local function tiene(permiso)
	return RoleDefinitions.Tiene(LocalPlayer:GetAttribute("Cargo"), permiso) == true
end

local function posicionPropia()
	local personaje = LocalPlayer.Character
	local raiz = personaje and (personaje:FindFirstChild("HumanoidRootPart") or personaje.PrimaryPart)
	if raiz and raiz:IsA("BasePart") then
		return raiz.Position
	end
	return nil
end

local function entero(valor, porDefecto)
	local n = tonumber(valor)
	if n == nil or n ~= n then
		return porDefecto
	end
	return math.floor(n)
end

local function idsDe(lista)
	local ids = {}
	for _, p in ipairs(lista) do
		table.insert(ids, tostring(p.Id))
	end
	return table.concat(ids, ",")
end

local function maxCarrito(producto)
	return math.max(0, math.min(entero(producto.Stock, 0), entero(limites.CantidadMax, 5)))
end

local function totalCarrito()
	local total, unidades = 0, 0
	for _, p in ipairs(catalogo) do
		local n = carrito[p.Id]
		if n and n > 0 then
			total = total + entero(p.Precio, 0) * n
			unidades = unidades + n
		end
	end
	return total, unidades
end

local function ajustarCarrito()
	for id, n in pairs(carrito) do
		local p = porId[id]
		if not p then
			carrito[id] = nil
		else
			local maximo = maxCarrito(p)
			if n > maximo then
				n = maximo
			end
			if n <= 0 then
				carrito[id] = nil
			else
				carrito[id] = n
			end
		end
	end
end

local function aplicarCatalogo(lista)
	if typeof(lista) ~= "table" then
		return
	end
	local nuevo, mapa = {}, {}
	for _, p in ipairs(lista) do
		if typeof(p) == "table" and typeof(p.Id) == "string" then
			table.insert(nuevo, p)
			mapa[p.Id] = p
		end
	end
	catalogo = nuevo
	porId = mapa
	ajustarCarrito()
end

local function aplicarInventario(lista)
	if typeof(lista) ~= "table" then
		return
	end
	for _, p in ipairs(lista) do
		if typeof(p) == "table" and typeof(p.Id) == "string" then
			inventario[p.Id] = { StockMax = p.StockMax, Vendidos = p.Vendidos, PrecioBase = p.PrecioBase, StockInicial = p.StockInicial }
		end
	end
end

local function aplicarEstado(datos)
	if typeof(datos) ~= "table" then
		return
	end
	if datos.Abierto ~= nil then
		tienda.Abierto = datos.Abierto == true
	end
	if typeof(datos.Modo) == "string" then
		tienda.Modo = datos.Modo
	end
	tienda.Vendedor = datos.Vendedor
end

---------------------------------------------------------------------------------------------------
-- Construcción del panel
---------------------------------------------------------------------------------------------------
local refrescar -- declarada más abajo
local comprar
local gestionar

local function altoFila()
	return math.max(58, UIBuilder.AltoBoton() + 14)
end

local function anchoBotonPequeno()
	local ancho = 40
	if UIBuilder.EsTactil() then
		ancho = math.max(ancho, UIBuilder.MinimoTactil())
	end
	return ancho
end

local function nuevaFila(parent, nombre, orden)
	local fila = Instance.new("Frame")
	fila.Name = nombre
	fila.BackgroundColor3 = Colores.Gris
	fila.BackgroundTransparency = 0.15
	fila.BorderSizePixel = 0
	fila.Size = UDim2.new(1, 0, 0, altoFila())
	fila.LayoutOrder = orden
	UIBuilder.Esquinas(fila, UITheme.RadioPequeno)
	UIBuilder.Relleno(fila, 6, 6, 10, 8)
	fila.Parent = parent
	return fila
end

local function bloqueInfo(fila, anchoDerecha)
	local info = UIBuilder.Marco(fila, { Nombre = "Info", Size = UDim2.new(1, -(anchoDerecha + 8), 1, 0) })
	UIBuilder.Disposicion(info, { Espaciado = 2, AlineacionVertical = Enum.VerticalAlignment.Center })
	local nombre = UIBuilder.Texto(info, "", { Nombre = "Nombre", Fuente = "Subtitulo", Truncar = true, Ajustar = false, Size = UDim2.new(1, 0, 0, 20), LayoutOrder = 1 })
	local sub = UIBuilder.Texto(info, "", { Nombre = "Detalle", Tamano = "Pequeno", Color = Colores.TextoSecundario, Truncar = true, Ajustar = false, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = 2 })
	return nombre, sub
end

local function bloqueControles(fila, anchoDerecha)
	local controles = UIBuilder.Marco(fila, {
		Nombre = "Controles", Size = UDim2.new(0, anchoDerecha, 1, 0),
		Position = UDim2.new(1, 0, 0, 0), AnchorPoint = Vector2.new(1, 0),
	})
	UIBuilder.Disposicion(controles, { Horizontal = true, Espaciado = 6, Alineacion = Enum.HorizontalAlignment.Right })
	return controles
end

local function cambiarCantidad(id, delta)
	if comprando then
		return
	end
	local p = porId[id]
	if not p then
		return
	end
	local actual = carrito[id] or 0
	local nuevo = math.clamp(actual + delta, 0, maxCarrito(p))
	if nuevo <= 0 then
		carrito[id] = nil
	else
		carrito[id] = nuevo
	end
	refrescar()
end

local function crearFilaCompra(producto, orden)
	local btn = anchoBotonPequeno()
	local anchoDerecha = 66 + btn * 2 + 30 + 18
	local fila = nuevaFila(ui.ListaCompra, "Producto_" .. producto.Id, orden)
	local nombre, sub = bloqueInfo(fila, anchoDerecha)
	local controles = bloqueControles(fila, anchoDerecha)
	local altoBtn = UIBuilder.AltoBoton()
	local precio = UIBuilder.Texto(controles, "", {
		Nombre = "Precio", Fuente = "Titulo", Color = Colores.Amarillo, Ajustar = false,
		Alineacion = Enum.TextXAlignment.Right, AlineacionY = Enum.TextYAlignment.Center,
		Size = UDim2.new(0, 66, 1, 0), LayoutOrder = 1,
	})
	local id = producto.Id
	local menos = UIBuilder.Boton(controles, "–", function()
		cambiarCantidad(id, -1)
	end, { Ancho = btn, Alto = altoBtn, LayoutOrder = 2, Estilo = "Secundario", Nombre = "Menos" })
	local cantidad = UIBuilder.Texto(controles, "0", {
		Nombre = "Cantidad", Fuente = "Titulo", Ajustar = false,
		Alineacion = Enum.TextXAlignment.Center, AlineacionY = Enum.TextYAlignment.Center,
		Size = UDim2.new(0, 30, 1, 0), LayoutOrder = 3,
	})
	local mas = UIBuilder.Boton(controles, "+", function()
		cambiarCantidad(id, 1)
	end, { Ancho = btn, Alto = altoBtn, LayoutOrder = 4, Estilo = "Secundario", Nombre = "Mas" })
	UIBuilder.Encadenar({ menos, mas }, true)
	return { Fila = fila, Nombre = nombre, Sub = sub, Precio = precio, Cantidad = cantidad, Menos = menos, Mas = mas }
end

local function crearFilaVendedor(producto, orden)
	local altoBtn = UIBuilder.AltoBoton()
	local anchoPrecio, anchoFijar, anchoReponer = 64, 76, 64
	local anchoDerecha = anchoPrecio + anchoFijar + anchoReponer + 12
	local fila = nuevaFila(ui.ListaVendedor, "Gestion_" .. producto.Id, orden)
	local nombre, sub = bloqueInfo(fila, anchoDerecha)
	local controles = bloqueControles(fila, anchoDerecha)
	local id = producto.Id
	local entrada = UIBuilder.Entrada(controles, "Precio", {
		Nombre = "Precio", Max = 4, Texto = tostring(entero(producto.Precio, 0)),
		Size = UDim2.new(0, anchoPrecio, 0, altoBtn), LayoutOrder = 1,
	})
	local fijar = UIBuilder.Boton(controles, "Fijar", function()
		local valor = tonumber(entrada.Text)
		if valor == nil then
			notificar("Escribe un precio numérico.", "aviso", 4)
			return
		end
		valor = math.floor(valor)
		if valor < limites.PrecioMin or valor > limites.PrecioMax then
			notificar("El precio debe estar entre " .. limites.PrecioMin .. " y " .. limites.PrecioMax .. ".", "aviso", 4)
			return
		end
		gestionar("Precio", { ProductoId = id, Valor = valor })
	end, { Ancho = anchoFijar, Alto = altoBtn, LayoutOrder = 2, Estilo = "Primario", Nombre = "Fijar" })
	local reponer = UIBuilder.Boton(controles, "+10", function()
		gestionar("Reponer", { ProductoId = id, Valor = 10 })
	end, { Ancho = anchoReponer, Alto = altoBtn, LayoutOrder = 3, Estilo = "Secundario", Nombre = "Reponer" })
	return { Fila = fila, Nombre = nombre, Sub = sub, Entrada = entrada, Fijar = fijar, Reponer = reponer, Editando = false }
end

local function fijarEstiloPestana(boton, activa)
	if not boton then
		return
	end
	boton:SetAttribute("Estilo", activa and "Primario" or "Secundario")
	UIBuilder.Habilitar(boton, true)
end

local function cambiarPestana(nombre)
	if nombre == "Vendedor" and not (esVendedor or puedePrecios) then
		nombre = "Comprar"
	end
	pestana = nombre
	if nombre == "Vendedor" and esVendedor then
		gestionar("Inventario", nil, true)
	end
	refrescar()
end

local function construirUI()
	local gui = UIBuilder.Pantalla("Cafeteria", ORDEN_PANTALLA)
	ui.Gui = gui
	local contenedor = UIBuilder.Contenedor(gui)
	local panel, cuerpo = UIBuilder.Panel(contenedor, {
		Nombre = "PanelTienda",
		Titulo = "Tienda escolar",
		AlCerrar = function()
			CafeteriaController.Cerrar()
		end,
		Size = UDim2.new(0, ANCHO_PANEL, 0, ALTO_PANEL),
	})
	pcall(function()
		panel.SelectionGroup = true
	end)
	panel.Visible = false
	ui.Panel = panel

	local altoBtn = UIBuilder.AltoBoton()
	local esp = UITheme.Espaciado
	local altoCabecera = 44
	local altoPestanas = altoBtn
	local altoPie = altoBtn + 26

	-- Cabecera: estado de la tienda y saldo.
	local cabecera = UIBuilder.Marco(cuerpo, { Nombre = "Cabecera", Alto = altoCabecera })
	ui.Estado = UIBuilder.Texto(cabecera, "", {
		Nombre = "Estado", Rico = true, Fuente = "Subtitulo", Ajustar = true,
		Size = UDim2.new(0.62, 0, 1, 0), AlineacionY = Enum.TextYAlignment.Center,
	})
	ui.Saldo = UIBuilder.Texto(cabecera, "", {
		Nombre = "Saldo", Fuente = "Titulo", Color = Colores.Amarillo, Ajustar = false,
		Alineacion = Enum.TextXAlignment.Right, AlineacionY = Enum.TextYAlignment.Center,
		Size = UDim2.new(0.38, 0, 1, 0), Position = UDim2.new(1, 0, 0, 0), AnchorPoint = Vector2.new(1, 0),
	})

	-- Pestañas (solo con permisos de vendedor o de precios).
	local pestanas = UIBuilder.Fila(cuerpo, { Nombre = "Pestanas", Alto = altoPestanas, Position = UDim2.new(0, 0, 0, altoCabecera + esp) })
	ui.Pestanas = pestanas
	ui.TabComprar = UIBuilder.Boton(pestanas, "Comprar", function()
		cambiarPestana("Comprar")
	end, { Ancho = 150, Alto = altoBtn, LayoutOrder = 1, Estilo = "Primario", Nombre = "TabComprar" })
	ui.TabVendedor = UIBuilder.Boton(pestanas, "Puesto", function()
		cambiarPestana("Vendedor")
	end, { Ancho = 150, Alto = altoBtn, LayoutOrder = 2, Estilo = "Secundario", Nombre = "TabVendedor" })
	UIBuilder.Encadenar({ ui.TabComprar, ui.TabVendedor }, true)

	-- Zona central (listas).
	local centro = UIBuilder.Marco(cuerpo, { Nombre = "Centro" })
	ui.Centro = centro
	ui.ListaCompra = UIBuilder.Lista(centro, { Espaciado = 6, Nombre = "ListaCompra" })
	ui.ListaVendedor = UIBuilder.Lista(centro, { Espaciado = 6, Nombre = "ListaVendedor" })
	ui.ListaVendedor.Visible = false

	-- Cabecera de la pestaña del vendedor: acciones y caja.
	local acciones = UIBuilder.Marco(ui.ListaVendedor, { Nombre = "Acciones", AutoAlto = true, LayoutOrder = 1 })
	UIBuilder.Disposicion(acciones, { Horizontal = true, Espaciado = 6, Wraps = true })
	ui.Acciones = acciones
	ui.BotonAbrir = UIBuilder.Boton(acciones, "Abrir tienda", function()
		gestionar("Abrir", nil)
	end, { Ancho = 150, Alto = altoBtn, LayoutOrder = 1, Estilo = "Exito", Nombre = "AbrirTienda" })
	ui.BotonCerrarTienda = UIBuilder.Boton(acciones, "Cerrar tienda", function()
		gestionar("Cerrar", nil)
	end, { Ancho = 150, Alto = altoBtn, LayoutOrder = 2, Estilo = "Peligro", Nombre = "CerrarTienda" })
	ui.BotonReponerTodo = UIBuilder.Boton(acciones, "Reponer todo", function()
		gestionar("Reponer", nil)
	end, { Ancho = 150, Alto = altoBtn, LayoutOrder = 3, Estilo = "Secundario", Nombre = "ReponerTodo" })
	ui.BotonCierre = UIBuilder.Boton(acciones, "Cierre de caja", function()
		UIBuilder.Confirmar("Cierre de caja", "Se mostrará el resumen de ventas y los contadores de la caja volverán a cero. ¿Continuar?", function()
			gestionar("Cierre", nil)
		end, "Cerrar caja", "Primario")
	end, { Ancho = 150, Alto = altoBtn, LayoutOrder = 4, Estilo = "Secundario", Nombre = "CierreCaja" })
	ui.BotonActualizar = UIBuilder.Boton(acciones, "Actualizar", function()
		gestionar("Inventario", nil)
	end, { Ancho = 120, Alto = altoBtn, LayoutOrder = 5, Estilo = "Fantasma", Nombre = "Actualizar" })
	ui.Caja = UIBuilder.Texto(ui.ListaVendedor, "", { Nombre = "Caja", Tamano = "Pequeno", Color = Colores.TextoSecundario, LayoutOrder = 2 })
	ui.AyudaPrecios = UIBuilder.Texto(ui.ListaVendedor, "", { Nombre = "AyudaPrecios", Tamano = "Pequeno", Color = Colores.TextoApagado, LayoutOrder = 3 })

	-- Pie: total del carrito y compra.
	local pie = UIBuilder.Marco(cuerpo, { Nombre = "Pie", Alto = altoPie, Position = UDim2.new(0, 0, 1, 0), AnchorPoint = Vector2.new(0, 1) })
	ui.Pie = pie
	UIBuilder.Separador(pie, { Position = UDim2.new(0, 0, 0, 0) })
	ui.Total = UIBuilder.Texto(pie, "", {
		Nombre = "Total", Fuente = "Subtitulo", Ajustar = true, AlineacionY = Enum.TextYAlignment.Center,
		Size = UDim2.new(1, -330, 0, altoBtn), Position = UDim2.new(0, 0, 0, 10),
	})
	ui.EstadoCompra = UIBuilder.Texto(pie, "", {
		Nombre = "EstadoCompra", Tamano = "Pequeno", Color = Colores.TextoApagado, Ajustar = false, Truncar = true,
		Size = UDim2.new(1, 0, 0, 14), Position = UDim2.new(0, 0, 1, 0), AnchorPoint = Vector2.new(0, 1),
	})
	ui.BotonVaciar = UIBuilder.Boton(pie, "Vaciar", function()
		if not comprando then
			carrito = {}
			refrescar()
		end
	end, { Ancho = 110, Alto = altoBtn, Estilo = "Secundario", Nombre = "Vaciar", Position = UDim2.new(1, -206, 0, 10), AnchorPoint = Vector2.new(1, 0) })
	ui.BotonComprar = UIBuilder.Boton(pie, "Comprar", function()
		comprar()
	end, { Ancho = 196, Alto = altoBtn, Estilo = "Primario", Nombre = "Comprar", Position = UDim2.new(1, 0, 0, 10), AnchorPoint = Vector2.new(1, 0) })

	ui.AltoCabecera = altoCabecera
	ui.AltoPestanas = altoPestanas
	ui.AltoPie = altoPie
	ui.FilasCompra = {}
	ui.FilasVendedor = {}
	ui.IdsCompra = ""
	ui.IdsVendedor = ""
end

local function asegurarUI()
	if not ui.Gui or ui.Gui.Parent == nil or not ui.Panel or ui.Panel.Parent == nil then
		construirUI()
	end
end

-- Tamaño del panel y reparto vertical (cabecera, pestañas, listas, pie) según la pantalla.
local function ajustarPanel()
	if not ui.Panel or ui.Panel.Parent == nil then
		return
	end
	local esp = UITheme.Espaciado
	local escala = math.max(0.5, UIBuilder.EscalaTotal())
	local arriba = math.ceil(UIBuilder.InsetSuperior() / escala) + esp
	local abajo = math.ceil(UIBuilder.MargenInferiorTactil() / escala) + esp
	local disponible = UIBuilder.AltoUI() - arriba - abajo
	local ancho = math.floor(math.min(ANCHO_PANEL, UIBuilder.AnchoUI() - 2 * esp - 8))
	local alto = math.floor(math.max(260, math.min(ALTO_PANEL, disponible)))
	ui.Panel.AnchorPoint = Vector2.new(0.5, 0.5)
	ui.Panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	ui.Panel.Size = UDim2.new(0, ancho, 0, alto)

	local conPestanas = ui.Pestanas.Visible
	local top = ui.AltoCabecera + esp
	if conPestanas then
		top = top + ui.AltoPestanas + esp
	end
	local pie = 0
	if ui.Pie.Visible then
		pie = ui.AltoPie + esp
	end
	ui.Centro.Position = UDim2.new(0, 0, 0, top)
	ui.Centro.Size = UDim2.new(1, 0, 1, -(top + pie))

	-- En pantallas estrechas el pie apila los botones a la derecha con menos ancho.
	local estrecho = ancho < 470
	local anchoComprar = estrecho and 140 or 196
	local anchoVaciar = estrecho and 90 or 110
	ui.BotonComprar.Size = UDim2.new(0, anchoComprar, 0, UIBuilder.AltoBoton())
	ui.BotonVaciar.Size = UDim2.new(0, anchoVaciar, 0, UIBuilder.AltoBoton())
	ui.BotonVaciar.Position = UDim2.new(1, -(anchoComprar + 8), 0, 10)
	ui.Total.Size = UDim2.new(1, -(anchoComprar + anchoVaciar + 24), 0, UIBuilder.AltoBoton())
end

---------------------------------------------------------------------------------------------------
-- Refresco
---------------------------------------------------------------------------------------------------
local function textoEstadoTienda()
	if tienda.Abierto then
		local quien = ""
		if tienda.Modo == "NPC" then
			quien = " · atención automática"
		elseif typeof(tienda.Vendedor) == "string" and tienda.Vendedor ~= "" then
			quien = " · atiende " .. tienda.Vendedor
		end
		return "<font color=\"#2CA05A\">●</font> Abierta" .. quien
	end
	return "<font color=\"#C41E24\">●</font> Cerrada"
end

local function refrescarCompra()
	local ids = idsDe(catalogo)
	if ids ~= ui.IdsCompra then
		for _, fila in pairs(ui.FilasCompra) do
			UIBuilder.Destruir(fila.Fila)
		end
		ui.FilasCompra = {}
		for i, producto in ipairs(catalogo) do
			ui.FilasCompra[producto.Id] = crearFilaCompra(producto, i)
		end
		ui.IdsCompra = ids
	end
	for _, producto in ipairs(catalogo) do
		local fila = ui.FilasCompra[producto.Id]
		if fila then
			local stock = entero(producto.Stock, 0)
			local categoria = CATEGORIAS[producto.Categoria] or tostring(producto.Categoria or "")
			fila.Nombre.Text = tostring(producto.Nombre)
			if stock > 0 then
				fila.Sub.Text = categoria .. " · Stock: " .. stock
			else
				fila.Sub.Text = categoria .. " · Agotado"
			end
			fila.Precio.Text = Format.Moneda(entero(producto.Precio, 0))
			local n = carrito[producto.Id] or 0
			fila.Cantidad.Text = tostring(n)
			UIBuilder.Habilitar(fila.Menos, not comprando and n > 0)
			UIBuilder.Habilitar(fila.Mas, not comprando and tienda.Abierto and n < maxCarrito(producto))
			fila.Fila.BackgroundTransparency = (n > 0) and 0 or 0.15
		end
	end
	local total, unidades = totalCarrito()
	if unidades > 0 then
		local texto = "Total: " .. Format.Moneda(total) .. " (" .. Format.Plural(unidades, "producto", "productos") .. ")"
		if saldo ~= nil and total > saldo then
			texto = texto .. " · saldo insuficiente"
		end
		ui.Total.Text = texto
	else
		ui.Total.Text = "Elige productos con + y –."
	end
	ui.EstadoCompra.Text = estadoCompra
	UIBuilder.Habilitar(ui.BotonComprar, not comprando and tienda.Abierto and unidades > 0)
	UIBuilder.Habilitar(ui.BotonVaciar, not comprando and unidades > 0)
	if comprando then
		UIBuilder.TextoBoton(ui.BotonComprar, "Comprando…")
	else
		UIBuilder.TextoBoton(ui.BotonComprar, "Comprar")
	end
end

local function refrescarVendedor()
	ui.BotonAbrir.Visible = esVendedor and not (tienda.Abierto and tienda.Modo == "Vendedor")
	ui.BotonCerrarTienda.Visible = esVendedor and tienda.Abierto and tienda.Modo == "Vendedor"
	ui.BotonReponerTodo.Visible = esVendedor
	ui.BotonCierre.Visible = esVendedor
	ui.BotonActualizar.Visible = esVendedor
	ui.Acciones.Visible = esVendedor
	for _, boton in ipairs({ ui.BotonAbrir, ui.BotonCerrarTienda, ui.BotonReponerTodo, ui.BotonCierre, ui.BotonActualizar }) do
		UIBuilder.Habilitar(boton, not gestionando)
	end
	if esVendedor and typeof(caja) == "table" then
		local desde = ""
		if tonumber(caja.Desde) then
			desde = " desde " .. Format.Fecha(caja.Desde)
		end
		ui.Caja.Text = "Caja" .. desde .. ": " .. Format.Plural(entero(caja.Ventas, 0), "venta", "ventas") .. " · " ..
			Format.Plural(entero(caja.Unidades, 0), "unidad", "unidades") .. " · " .. Format.Moneda(entero(caja.Ingresos, 0))
		ui.Caja.Visible = true
	else
		ui.Caja.Visible = false
	end
	if puedePrecios then
		ui.AyudaPrecios.Text = "Precios entre " .. Format.Moneda(limites.PrecioMin) .. " y " .. Format.Moneda(limites.PrecioMax) .. ". Escribe el nuevo precio y pulsa «Fijar»."
	else
		ui.AyudaPrecios.Text = "Los precios los fija la administración (permiso de precios)."
	end

	local ids = idsDe(catalogo)
	if ids ~= ui.IdsVendedor then
		for _, fila in pairs(ui.FilasVendedor) do
			UIBuilder.Destruir(fila.Fila)
		end
		ui.FilasVendedor = {}
		for i, producto in ipairs(catalogo) do
			ui.FilasVendedor[producto.Id] = crearFilaVendedor(producto, 10 + i)
		end
		ui.IdsVendedor = ids
	end
	for _, producto in ipairs(catalogo) do
		local fila = ui.FilasVendedor[producto.Id]
		if fila then
			local extra = inventario[producto.Id]
			local stock = entero(producto.Stock, 0)
			local detalle = "Stock " .. stock
			if extra and tonumber(extra.StockMax) then
				detalle = detalle .. "/" .. entero(extra.StockMax, 0)
			end
			if extra and tonumber(extra.Vendidos) then
				detalle = detalle .. " · vendidos " .. entero(extra.Vendidos, 0)
			end
			detalle = detalle .. " · " .. Format.Moneda(entero(producto.Precio, 0))
			fila.Nombre.Text = tostring(producto.Nombre)
			fila.Sub.Text = detalle
			local enFoco = false
			pcall(function()
				enFoco = fila.Entrada:IsFocused()
			end)
			if not enFoco then
				fila.Entrada.Text = tostring(entero(producto.Precio, 0))
			end
			fila.Entrada.Visible = puedePrecios
			fila.Fijar.Visible = puedePrecios
			fila.Reponer.Visible = esVendedor
			UIBuilder.Habilitar(fila.Fijar, not gestionando)
			UIBuilder.Habilitar(fila.Reponer, not gestionando)
		end
	end
end

refrescar = function()
	if not ui.Panel or ui.Panel.Parent == nil then
		return
	end
	ui.Estado.Text = textoEstadoTienda()
	if saldo ~= nil then
		ui.Saldo.Text = "Saldo: " .. Format.Moneda(entero(saldo, 0))
	else
		ui.Saldo.Text = "Saldo: —"
	end
	local conPermisos = esVendedor or puedePrecios
	if not conPermisos then
		pestana = "Comprar"
	end
	ui.Pestanas.Visible = conPermisos
	fijarEstiloPestana(ui.TabComprar, pestana == "Comprar")
	fijarEstiloPestana(ui.TabVendedor, pestana == "Vendedor")
	ui.ListaCompra.Visible = pestana == "Comprar"
	ui.ListaVendedor.Visible = pestana == "Vendedor"
	ui.Pie.Visible = pestana == "Comprar"
	refrescarCompra()
	if pestana == "Vendedor" then
		refrescarVendedor()
	end
	ajustarPanel()
end

---------------------------------------------------------------------------------------------------
-- Recibos
---------------------------------------------------------------------------------------------------
local function mostrarRecibos(recibos, aviso)
	local total = 0
	local ids = {}
	local saldoFinal = nil
	local fecha = nil
	for _, recibo in ipairs(recibos) do
		total = total + entero(recibo.Total, 0)
		table.insert(ids, tostring(recibo.Id))
		saldoFinal = recibo.Saldo
		fecha = recibo.FechaTexto or (tonumber(recibo.Fecha) and Format.Fecha(recibo.Fecha)) or fecha
	end
	UIBuilder.Modal("Recibo de compra", function(cuerpo)
		local orden = 1
		for _, recibo in ipairs(recibos) do
			for _, item in ipairs(recibo.Items or {}) do
				UIBuilder.Texto(cuerpo, entero(item.Cantidad, 0) .. " × " .. tostring(item.Nombre) .. "   " .. Format.Moneda(entero(item.Subtotal, 0)), {
					LayoutOrder = orden,
				})
				orden = orden + 1
			end
		end
		UIBuilder.Separador(cuerpo, { LayoutOrder = orden })
		UIBuilder.Texto(cuerpo, "Total pagado: " .. Format.Moneda(total), { LayoutOrder = orden + 1, Fuente = "Titulo", Color = Colores.Amarillo })
		if saldoFinal ~= nil then
			UIBuilder.Texto(cuerpo, "Saldo restante: " .. Format.Moneda(entero(saldoFinal, 0)), { LayoutOrder = orden + 2 })
		end
		UIBuilder.Texto(cuerpo, "Recibo " .. table.concat(ids, ", ") .. (fecha and (" · " .. fecha) or ""), {
			LayoutOrder = orden + 3, Tamano = "Pequeno", Color = Colores.TextoApagado,
		})
		if aviso then
			UIBuilder.Texto(cuerpo, "No se completó todo el carrito: " .. tostring(aviso), { LayoutOrder = orden + 4, Color = Colores.Aviso, Tamano = "Pequeno" })
		end
	end, { { Texto = "Aceptar", Estilo = "Primario" } }, { Ancho = 400, CerrarAlFondo = true })
end

local function mostrarCierre(resumen)
	if typeof(resumen) ~= "table" then
		return
	end
	UIBuilder.Modal("Cierre de caja", function(cuerpo)
		local desde = tonumber(resumen.Desde) and Format.Fecha(resumen.Desde) or "—"
		local hasta = tonumber(resumen.Hasta) and Format.Fecha(resumen.Hasta) or "—"
		UIBuilder.Texto(cuerpo, "Periodo: " .. desde .. " → " .. hasta, { LayoutOrder = 1, Tamano = "Pequeno", Color = Colores.TextoSecundario })
		UIBuilder.Texto(cuerpo, Format.Plural(entero(resumen.Ventas, 0), "venta", "ventas") .. " · " .. Format.Plural(entero(resumen.Unidades, 0), "unidad", "unidades") .. " · " .. Format.Plural(entero(resumen.Reembolsos, 0), "reembolso", "reembolsos"), { LayoutOrder = 2 })
		UIBuilder.Texto(cuerpo, "Ingresos: " .. Format.Moneda(entero(resumen.Ingresos, 0)), { LayoutOrder = 3, Fuente = "Titulo", Color = Colores.Amarillo })
		local orden = 4
		for _, p in ipairs(resumen.Productos or {}) do
			UIBuilder.Texto(cuerpo, "• " .. tostring(p.Nombre) .. ": " .. entero(p.Unidades, 0) .. " u. · " .. Format.Moneda(entero(p.Ingresos, 0)), {
				LayoutOrder = orden, Tamano = "Pequeno",
			})
			orden = orden + 1
		end
		if orden == 4 then
			UIBuilder.Texto(cuerpo, "No hubo ventas en este periodo.", { LayoutOrder = orden, Tamano = "Pequeno", Color = Colores.TextoApagado })
		end
	end, { { Texto = "Aceptar", Estilo = "Primario" } }, { Ancho = 420 })
end

---------------------------------------------------------------------------------------------------
-- Acciones de red
---------------------------------------------------------------------------------------------------
comprar = function()
	if comprando or not activo then
		return
	end
	local items = {}
	for _, p in ipairs(catalogo) do
		local n = carrito[p.Id]
		if n and n > 0 then
			table.insert(items, { Id = p.Id, Cantidad = n, Nombre = p.Nombre })
		end
	end
	if #items == 0 then
		notificar("Tu carrito está vacío.", "info", 3)
		return
	end
	if not tienda.Abierto then
		notificar("La tienda está cerrada.", "aviso", 4)
		return
	end
	comprando = true
	estadoCompra = ""
	refrescar()
	task.spawn(function()
		local recibos = {}
		local aviso = nil
		local espera = math.max(0, tonumber(limites.Cooldown) or 3) + MARGEN_ESPERA
		for i, item in ipairs(items) do
			if not abierto then
				aviso = "cerraste la tienda antes de terminar."
				break
			end
			if i > 1 then
				estadoCompra = string.format("Esperando para el siguiente producto (%d de %d)…", i, #items)
				refrescar()
				task.wait(espera)
			end
			estadoCompra = string.format("Procesando %d de %d: %s…", i, #items, tostring(item.Nombre))
			refrescar()
			local ok, respuesta = Net.Invocar("CafeteriaPurchase", { ProductoId = item.Id, Cantidad = item.Cantidad })
			local datos = typeof(respuesta) == "table" and respuesta.datos or nil
			if ok and typeof(datos) == "table" and typeof(datos.Recibo) == "table" then
				local recibo = datos.Recibo
				recibosVistos[tostring(recibo.Id)] = true
				table.insert(recibos, recibo)
				carrito[item.Id] = nil
				if recibo.Saldo ~= nil then
					saldo = recibo.Saldo
				end
				if typeof(datos.Producto) == "table" and porId[datos.Producto.Id] then
					porId[datos.Producto.Id].Stock = datos.Producto.Stock
				end
			else
				aviso = UIBuilder.MensajeError(respuesta and respuesta.error)
				break
			end
		end
		comprando = false
		estadoCompra = ""
		ajustarCarrito()
		refrescar()
		if #recibos > 0 then
			mostrarRecibos(recibos, aviso)
		elseif aviso then
			notificar(aviso, "aviso", 5)
		end
	end)
end

gestionar = function(accion, extra, silencioso)
	if gestionando or not activo then
		return
	end
	gestionando = true
	refrescar()
	task.spawn(function()
		local datos = { Accion = accion }
		for clave, valor in pairs(extra or {}) do
			datos[clave] = valor
		end
		local ok, respuesta = Net.Invocar("CafeteriaManage", datos)
		gestionando = false
		local r = typeof(respuesta) == "table" and respuesta.datos or nil
		if typeof(r) == "table" then
			if r.Catalogo then
				aplicarCatalogo(r.Catalogo)
			end
			if r.Inventario then
				aplicarInventario(r.Inventario)
			end
			if r.Estado then
				aplicarEstado(r.Estado)
			end
			if r.Caja then
				caja = r.Caja
			end
			if r.EsVendedor ~= nil then
				esVendedor = r.EsVendedor == true
			end
			if r.PuedePrecios ~= nil then
				puedePrecios = r.PuedePrecios == true
			end
		end
		if ok then
			if typeof(r) == "table" and typeof(r.Mensaje) == "string" and not silencioso then
				notificar(r.Mensaje, "exito", 4)
			end
			if accion == "Cierre" and typeof(r) == "table" then
				mostrarCierre(r.Resumen)
			end
		elseif not silencioso then
			notificar(UIBuilder.MensajeError(respuesta and respuesta.error), "aviso", 5)
		end
		refrescar()
	end)
end

---------------------------------------------------------------------------------------------------
-- Eventos del servidor
---------------------------------------------------------------------------------------------------
local function aplicarPanel(datos)
	aplicarCatalogo(datos.Catalogo)
	aplicarEstado(datos)
	if datos.Saldo ~= nil then
		saldo = tonumber(datos.Saldo)
	end
	esVendedor = datos.EsVendedor == true
	puedePrecios = datos.PuedePrecios == true
	if typeof(datos.Caja) == "table" then
		caja = datos.Caja
	end
	if typeof(datos.Mostrador) == "Vector3" then
		mostrador = datos.Mostrador
	end
	if typeof(datos.Limites) == "table" then
		for clave, valor in pairs(datos.Limites) do
			if tonumber(valor) then
				limites[clave] = tonumber(valor)
			end
		end
	end
end

local function alEventoCafeteria(datos)
	local sub = datos.Sub
	if sub == "AbrirPanel" then
		aplicarPanel(datos)
		CafeteriaController.Abrir()
		return
	elseif sub == "Estado" then
		aplicarEstado(datos)
	elseif sub == "Inventario" then
		aplicarCatalogo(datos.Catalogo)
	elseif sub == "Recibo" then
		local recibo = datos.Recibo
		if typeof(recibo) == "table" then
			if recibo.Saldo ~= nil then
				saldo = tonumber(recibo.Saldo) or saldo
			end
			local id = tostring(recibo.Id)
			-- Las compras del propio panel ya muestran su recibo; aquí solo las hechas por otra vía.
			if not comprando and not recibosVistos[id] then
				recibosVistos[id] = true
				notificar("Compra realizada (" .. id .. "): " .. Format.Moneda(entero(recibo.Total, 0)) .. ".", "exito", 4)
			end
		end
	end
	if abierto then
		refrescar()
	end
end

---------------------------------------------------------------------------------------------------
-- API pública (admite llamada con punto o con dos puntos)
---------------------------------------------------------------------------------------------------
function CafeteriaController.EstaAbierto()
	return abierto
end

-- Abre el panel. datos opcional = carga de "AbrirPanel" (catálogo, estado, permisos, mostrador).
function CafeteriaController.Abrir(a, b)
	if not activo then
		return
	end
	local datos = a
	if a == CafeteriaController then
		datos = b
	end
	if typeof(datos) == "table" then
		aplicarPanel(datos)
	end
	if #catalogo == 0 then
		notificar("Acércate al mostrador de la tienda escolar y usa «Comprar».", "info", 4)
		return
	end
	local ok, err = pcall(asegurarUI)
	if not ok then
		warn(LOG .. "No se pudo construir el panel: " .. tostring(err))
		return
	end
	if not (esVendedor or puedePrecios) then
		pestana = "Comprar"
	end
	refrescar()
	if abierto then
		return
	end
	abierto = true
	ui.Gui.Enabled = true
	UIBuilder.Aparecer(ui.Panel)
	local conexion = UIBuilder.TeclaCerrar(function()
		CafeteriaController.Cerrar()
	end)
	if conexion then
		maidPanel:GiveTask(conexion)
	end
	-- Cierre automático al alejarse del mostrador (o al morir / reaparecer).
	maidPanel:GiveTask(task.spawn(function()
		while abierto do
			task.wait(INTERVALO_DISTANCIA)
			if not abierto then
				break
			end
			local pos = posicionPropia()
			local limite = tonumber(limites.DistanciaCierre) or 20
			if not pos or (mostrador and (pos - mostrador).Magnitude > limite) then
				-- Diferido: Cerrar limpia maidPanel, que cancelaría este mismo hilo.
				task.defer(function()
					if abierto then
						CafeteriaController.Cerrar()
						notificar("Te alejaste de la tienda.", "info", 3)
					end
				end)
				break
			end
		end
	end))
	task.defer(function()
		if abierto and ui.Panel and ui.Panel.Parent ~= nil then
			UIBuilder.EnfocarPrimero(ui.Panel)
		end
	end)
	if esVendedor then
		gestionar("Inventario", nil, true)
	end
end

function CafeteriaController.Cerrar()
	if not abierto then
		return
	end
	abierto = false
	maidPanel:DoCleaning()
	if ui.Panel and ui.Panel.Parent ~= nil then
		for _, fila in pairs(ui.FilasVendedor or {}) do
			pcall(function()
				fila.Entrada:ReleaseFocus()
			end)
		end
		UIBuilder.Desenfocar(ui.Panel)
		UIBuilder.Desaparecer(ui.Panel)
	end
end

function CafeteriaController.Alternar()
	if abierto then
		CafeteriaController.Cerrar()
	else
		CafeteriaController.Abrir()
	end
end

-- Datos actuales (para otros controladores: InteractionController, HUD...).
function CafeteriaController.Estado()
	return { Abierto = tienda.Abierto, Modo = tienda.Modo, Vendedor = tienda.Vendedor, Saldo = saldo, Productos = #catalogo }
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function CafeteriaController:Init(registro)
	self.registro = registro
end

function CafeteriaController:Start()
	if activo then
		return
	end
	activo = true
	esVendedor = tiene("cafeteria.vender")
	puedePrecios = tiene("cafeteria.precios")
	local ok, err = pcall(construirUI)
	if not ok then
		warn(LOG .. "No se pudo construir el panel: " .. tostring(err))
	end

	task.spawn(function()
		local remoto = Net.Evento("EventoCliente")
		if not remoto then
			warn(LOG .. "EventoCliente no disponible; la tienda no recibirá datos del servidor.")
			return
		end
		maid:GiveTask(remoto.OnClientEvent:Connect(function(carga)
			if typeof(carga) ~= "table" then
				return
			end
			local datos = carga.Datos
			if typeof(datos) ~= "table" then
				return
			end
			if carga.Tipo == "Cafeteria" then
				local exito, errEvento = pcall(alEventoCafeteria, datos)
				if not exito then
					warn(LOG .. tostring(errEvento))
				end
			elseif carga.Tipo == "Economia" and datos.Saldo ~= nil then
				saldo = tonumber(datos.Saldo) or saldo
				if abierto then
					pcall(refrescar)
				end
			end
		end))
	end)

	-- Cambio de cargo: permisos de la pestaña del puesto.
	maid:GiveTask(LocalPlayer:GetAttributeChangedSignal("Cargo"):Connect(function()
		esVendedor = tiene("cafeteria.vender")
		puedePrecios = tiene("cafeteria.precios")
		if abierto then
			pcall(refrescar)
		end
	end))

	pcall(function()
		local camara = workspace.CurrentCamera
		if camara then
			maid:GiveTask(camara:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				if abierto then
					ajustarPanel()
				end
			end))
		end
	end)
end

return CafeteriaController
