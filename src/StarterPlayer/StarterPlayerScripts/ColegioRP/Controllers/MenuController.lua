--[[
	Ruta en el Explorer: StarterPlayer.StarterPlayerScripts.ColegioRP.Controllers.MenuController
	Tipo: ModuleScript
	Menú principal a pantalla completa tras la carga: JUGAR (lista de cargos por equipo con disponibilidad del
	servidor -> RequestJoinRole), ACTUALIZACIONES, EQUIPO, AJUSTES, AYUDA y SOPORTE (delegados a sus controladores).
	Reabrible con la tecla M, el botón ☰ del HUD o Start del mando; oculta el HUD mientras está abierto.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local MenuController = {}
MenuController.Nombre = "MenuController"

local UIBuilder, UITheme, Net, Maid, Format, RoleDefinitions, Catalogs, Config

local player = Players.LocalPlayer

local function requerir(padre, nombre)
	if not padre then
		error("no se encontró la carpeta para " .. nombre)
	end
	local modulo = padre:FindFirstChild(nombre) or padre:WaitForChild(nombre, 10)
	if not modulo then
		error("no se encontró el módulo " .. nombre)
	end
	return require(modulo)
end

-- string.upper que también convierte las vocales acentuadas y la ñ (UTF-8).
local ACENTOS = { ["á"] = "Á", ["é"] = "É", ["í"] = "Í", ["ó"] = "Ó", ["ú"] = "Ú", ["ñ"] = "Ñ", ["ü"] = "Ü" }
local function mayusculas(valor)
	local resultado = string.upper(tostring(valor or ""))
	for minuscula, mayuscula in pairs(ACENTOS) do
		resultado = string.gsub(resultado, minuscula, mayuscula)
	end
	return resultado
end

-- "2026-10-26" -> "26/10/2026" (o el texto tal cual si no tiene ese formato).
local function fechaLegible(fecha)
	if typeof(fecha) ~= "string" then
		return ""
	end
	local a, m, d = string.match(fecha, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if a then
		return d .. "/" .. m .. "/" .. a
	end
	return fecha
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function MenuController:Init(registro)
	self.registro = registro
	Config = registro.Config
	UIBuilder = registro.UIBuilder
	if not UIBuilder then
		error("UIBuilder no está disponible")
	end
	local Shared = registro.Shared
	local Util = Shared:FindFirstChild("Util") or Shared:WaitForChild("Util", 10)
	UITheme = requerir(Shared, "UITheme")
	RoleDefinitions = requerir(Shared, "RoleDefinitions")
	Catalogs = requerir(Shared, "Catalogs")
	Net = requerir(Util, "Net")
	Maid = requerir(Util, "Maid")
	Format = requerir(Util, "Format")

	self.maid = Maid.new()
	self.abierto = false
	self.haJugado = false
	self.puedeContinuar = false
	self.uniendo = false
	self.vista = "Principal"
	self.tokenVista = 0
	self.tokenSuspension = 0
	self.suspendido = nil
	self:_Construir()
end

function MenuController:Start()
	-- Tecla M (si no se está escribiendo), Start del mando para alternar; B del mando para volver.
	self.maid:GiveTask(UserInputService.InputBegan:Connect(function(entrada, procesado)
		local tecla = entrada.KeyCode
		if tecla == Enum.KeyCode.M then
			if procesado or UserInputService:GetFocusedTextBox() ~= nil then
				return
			end
			self:Alternar()
		elseif tecla == Enum.KeyCode.ButtonStart then
			self:Alternar()
		elseif tecla == Enum.KeyCode.ButtonB then
			if self.abierto and not self.suspendido and self.vista ~= "Principal" then
				self:_MostrarPrincipal()
			end
		end
	end))

	-- Si el servidor asigna un cargo (por defecto al entrar o por un administrador), se puede continuar sin elegir.
	local function revisarCargo()
		if RoleDefinitions.Existe(player:GetAttribute("Cargo")) and not self.puedeContinuar then
			self.puedeContinuar = true
			self:_ActualizarBotones()
		end
	end
	self.maid:GiveTask(player:GetAttributeChangedSignal("Cargo"):Connect(revisarCargo))
	revisarCargo()
end

---------------------------------------------------------------------------------------------------
-- Construcción
---------------------------------------------------------------------------------------------------
function MenuController:_Construir()
	local Colores = UITheme.Colores
	local gui = UIBuilder.Pantalla("Menu", (UITheme.Capas and UITheme.Capas.Menu) or 90, { Visible = false })
	self.gui = gui
	self.maid:GiveTask(gui)

	local fondo = Instance.new("Frame")
	fondo.Name = "Fondo"
	fondo.BackgroundColor3 = Colores.Fondo
	fondo.BackgroundTransparency = 0.12
	fondo.BorderSizePixel = 0
	fondo.Size = UDim2.new(1, 0, 1, 0)
	fondo.Active = true
	fondo.Parent = gui
	local degradado = Instance.new("UIGradient")
	degradado.Rotation = 90
	degradado.Color = ColorSequence.new(Colores.Fondo, UITheme.Oscurecer(Colores.RojoOscuro, 0.75))
	degradado.Parent = fondo
	self.fondo = fondo

	local contenido = UIBuilder.Contenedor(fondo, { Nombre = "Contenido" })
	self.contenido = contenido

	-- Créditos.
	UIBuilder.Texto(contenido, tostring(Config.Productora or "Horizon Studios") .. " " .. tostring(Config.Autor or "by Adrian") .. " · v" .. tostring(Config.Version or "?"), {
		Nombre = "Creditos", Tamano = "Pequeno", Color = Colores.TextoApagado,
		Alineacion = Enum.TextXAlignment.Center, AlineacionY = Enum.TextYAlignment.Bottom, AutoAlto = false,
		Size = UDim2.new(1, 0, 0, 20), Position = UDim2.new(0.5, 0, 1, 0), AnchorPoint = Vector2.new(0.5, 1),
	})

	-- Vista principal: logo central y botones.
	local principal = Instance.new("Frame")
	principal.Name = "Principal"
	principal.BackgroundTransparency = 1
	principal.Size = UDim2.new(1, 0, 1, -28)
	principal.Parent = contenido
	self.principal = principal

	local bajo = UIBuilder.AltoUI() < 700
	UIBuilder.Disposicion(principal, {
		Horizontal = bajo,
		Espaciado = bajo and 40 or 18,
		Alineacion = Enum.HorizontalAlignment.Center,
		AlineacionVertical = Enum.VerticalAlignment.Center,
	})

	local anchoMarca = bajo and 320 or 460
	local marca = Instance.new("Frame")
	marca.Name = "Marca"
	marca.BackgroundTransparency = 1
	marca.Size = UDim2.new(0, anchoMarca, 0, 0)
	marca.AutomaticSize = Enum.AutomaticSize.Y
	marca.LayoutOrder = 1
	marca.Parent = principal
	UIBuilder.Disposicion(marca, { Espaciado = 8, Alineacion = Enum.HorizontalAlignment.Center })
	UIBuilder.Logo(marca, bajo and 140 or 176, { LayoutOrder = 1 })
	UIBuilder.Titulo(marca, mayusculas(Config.NombreColegio or "Instituto Educativo Jean Piaget"), {
		LayoutOrder = 2, Alineacion = Enum.TextXAlignment.Center, Tamano = bajo and "Titulo" or "TituloGrande",
	})
	UIBuilder.Subtitulo(marca, tostring(Config.Lema or ""), { LayoutOrder = 3, Alineacion = Enum.TextXAlignment.Center, Tamano = "Texto" })

	local columna = Instance.new("Frame")
	columna.Name = "Botones"
	columna.BackgroundTransparency = 1
	columna.Size = UDim2.new(0, 300, 0, 0)
	columna.AutomaticSize = Enum.AutomaticSize.Y
	columna.LayoutOrder = 2
	columna.Parent = principal
	UIBuilder.Disposicion(columna, { Espaciado = 8, Alineacion = Enum.HorizontalAlignment.Center })
	self.columna = columna

	local alto = UIBuilder.AltoBoton() + 4
	local function boton(textoBoton, orden, estilo, accion)
		return UIBuilder.Boton(columna, textoBoton, accion, {
			Estilo = estilo, Size = UDim2.new(1, 0, 0, alto), LayoutOrder = orden, Tamano = "Subtitulo", Nombre = textoBoton,
		})
	end
	self.botonContinuar = boton("CONTINUAR", 1, "Exito", function()
		self:Cerrar()
	end)
	self.botonJugar = boton("JUGAR", 2, "Primario", function()
		self:_VistaJugar()
	end)
	self.botonActualizaciones = boton("ACTUALIZACIONES", 3, "Secundario", function()
		self:_VistaActualizaciones()
	end)
	self.botonEquipo = boton("EQUIPO", 4, "Secundario", function()
		self:_VistaEquipo()
	end)
	self.botonAjustes = boton("AJUSTES", 5, "Secundario", function()
		self:_Delegar("SettingsController", "Los ajustes no están disponibles todavía.")
	end)
	self.botonAyuda = boton("AYUDA", 6, "Secundario", function()
		self:_Delegar("HelpController", "La ayuda no está disponible todavía.")
	end)
	self.botonSoporte = boton("SOPORTE", 7, "Secundario", function()
		self:_Delegar("SupportController", "El soporte no está disponible todavía.")
	end)

	-- Botón flotante mientras un panel delegado (Ajustes, Ayuda, Soporte) está abierto.
	local escala = math.max(0.5, UIBuilder.EscalaTotal())
	self.botonVolverMenu = UIBuilder.Boton(gui, "Volver al menú", function()
		self:_Reanudar()
	end, {
		Estilo = "Primario", Icono = "☰", Ancho = 200, Nombre = "VolverMenu", Visible = false,
		Position = UDim2.new(0.5, 0, 1, -(math.ceil(UIBuilder.MargenInferiorTactil() / escala) + 16)),
		AnchorPoint = Vector2.new(0.5, 1),
	})

	self:_ActualizarBotones()
end

-- Visibilidad de CONTINUAR y navegación con mando entre los botones visibles.
function MenuController:_ActualizarBotones()
	if not self.botonContinuar then
		return
	end
	self.botonContinuar.Visible = self.haJugado or self.puedeContinuar
	local lista = {}
	for _, b in ipairs({ self.botonContinuar, self.botonJugar, self.botonActualizaciones, self.botonEquipo, self.botonAjustes, self.botonAyuda, self.botonSoporte }) do
		if b.Visible then
			table.insert(lista, b)
		end
	end
	UIBuilder.Encadenar(lista)
end

function MenuController:_PrimerBoton()
	if self.botonContinuar and self.botonContinuar.Visible then
		return self.botonContinuar
	end
	return self.botonJugar
end

---------------------------------------------------------------------------------------------------
-- Vistas
---------------------------------------------------------------------------------------------------
function MenuController:_MostrarPrincipal()
	self.tokenVista = self.tokenVista + 1
	if self.panelVista then
		UIBuilder.Destruir(self.panelVista)
		self.panelVista = nil
	end
	self.vista = "Principal"
	self.principal.Visible = true
	self:_ActualizarBotones()
	UIBuilder.Aparecer(self.columna)
	task.defer(function()
		if self.abierto and self.vista == "Principal" then
			UIBuilder.Enfocar(self:_PrimerBoton())
		end
	end)
end

-- Crea un panel de vista secundaria con botón Volver. Devuelve { Panel, Lista, Siguiente(), Token, Volver }.
function MenuController:_NuevaVista(titulo)
	self.tokenVista = self.tokenVista + 1
	if self.panelVista then
		UIBuilder.Destruir(self.panelVista)
		self.panelVista = nil
	end
	self.principal.Visible = false
	self.vista = titulo
	local ancho = math.floor(math.min(UITheme.AnchoPanelAncho or 640, math.max(260, UIBuilder.AnchoUI() - 24)))
	local panel, lista = UIBuilder.Panel(self.contenido, {
		Titulo = titulo,
		Nombre = "Vista",
		Scroll = true,
		Size = UDim2.new(0, ancho, 1, -28),
		Position = UDim2.new(0.5, 0, 0, 0),
		AnchorPoint = Vector2.new(0.5, 0),
		AlCerrar = function()
			self:_MostrarPrincipal()
		end,
	})
	self.panelVista = panel
	local orden = 0
	local function siguiente()
		orden = orden + 1
		return orden
	end
	local volver = UIBuilder.Boton(lista, "Volver", function()
		self:_MostrarPrincipal()
	end, { Estilo = "Secundario", Icono = "‹", Ancho = 150, LayoutOrder = siguiente(), Nombre = "Volver" })
	UIBuilder.Aparecer(panel)
	return { Panel = panel, Lista = lista, Siguiente = siguiente, Token = self.tokenVista, Volver = volver }
end

function MenuController:_VistaVigente(vista)
	return self.abierto and vista.Token == self.tokenVista and vista.Panel.Parent ~= nil
end

-- JUGAR: lista de cargos agrupada por equipo con la disponibilidad que decide el servidor.
function MenuController:_VistaJugar()
	local vista = self:_NuevaVista("Elige tu cargo")
	local Colores = UITheme.Colores
	local estado = UIBuilder.Texto(vista.Lista, "Cargando cargos…", { LayoutOrder = vista.Siguiente(), Color = Colores.TextoSecundario, Nombre = "Estado" })
	UIBuilder.Enfocar(vista.Volver)

	task.spawn(function()
		local ok, respuesta = Net.Invocar("RequestRoleList", {})
		if not self:_VistaVigente(vista) then
			return
		end
		if not ok or typeof(respuesta.datos) ~= "table" or typeof(respuesta.datos.Cargos) ~= "table" then
			self.puedeContinuar = true
			estado.Text = "No se pudo obtener la lista de cargos: " .. UIBuilder.MensajeError(respuesta and respuesta.error)
			estado.TextColor3 = Colores.Amarillo
			local fila = UIBuilder.Fila(vista.Lista, { LayoutOrder = vista.Siguiente(), Nombre = "Acciones" })
			local reintentar = UIBuilder.Boton(fila, "Reintentar", function()
				self:_VistaJugar()
			end, { Estilo = "Primario", Ancho = 160, LayoutOrder = 1 })
			UIBuilder.Boton(fila, "Cerrar menú", function()
				self:Cerrar()
			end, { Estilo = "Secundario", Ancho = 160, LayoutOrder = 2 })
			UIBuilder.Enfocar(reintentar)
			return
		end
		estado.Text = "Elige un cargo para entrar al colegio. Los cargos deshabilitados requieren autorización (la decide el servidor)."
		self:_PintarCargos(vista, respuesta.datos)
	end)
end

function MenuController:_PintarCargos(vista, datos)
	local Colores = UITheme.Colores
	local porEquipo = {}
	local ordenEquipos = {}
	for _, nombre in ipairs(RoleDefinitions.OrdenEquipos or {}) do
		table.insert(ordenEquipos, nombre)
		porEquipo[nombre] = {}
	end
	for _, cargo in ipairs(datos.Cargos) do
		if typeof(cargo) == "table" and typeof(cargo.Id) == "string" and RoleDefinitions.Existe(cargo.Id) then
			local equipo = cargo.Equipo
			if typeof(equipo) ~= "string" or equipo == "" then
				equipo = RoleDefinitions.Equipo(cargo.Id) or "Otros"
			end
			if not porEquipo[equipo] then
				porEquipo[equipo] = {}
				table.insert(ordenEquipos, equipo)
			end
			table.insert(porEquipo[equipo], cargo)
		end
	end

	local actual = datos.Actual
	if typeof(actual) ~= "string" then
		actual = player:GetAttribute("Cargo")
	end
	local botones = {}
	local disponibles = {}
	local primerDisponible = nil

	for _, equipo in ipairs(ordenEquipos) do
		local lista = porEquipo[equipo]
		if lista and #lista > 0 then
			local info = RoleDefinitions.Equipos and RoleDefinitions.Equipos[equipo]
			UIBuilder.Espacio(vista.Lista, 4, vista.Siguiente())
			UIBuilder.Subtitulo(vista.Lista, mayusculas(equipo), {
				LayoutOrder = vista.Siguiente(), Fuente = "Titulo", Color = (info and info.Color3) or Colores.TextoSecundario,
			})
			if info and typeof(info.Descripcion) == "string" then
				UIBuilder.Texto(vista.Lista, info.Descripcion, { LayoutOrder = vista.Siguiente(), Tamano = "Pequeno", Color = Colores.TextoApagado })
			end
			for _, cargo in ipairs(lista) do
				local id = cargo.Id
				local disponible = cargo.Disponible == true
				local nombre = cargo.Nombre
				if typeof(nombre) ~= "string" or nombre == "" then
					nombre = RoleDefinitions.Nombre(id)
				end
				local etiquetaBoton = nombre
				if id == actual then
					etiquetaBoton = nombre .. "  · actual"
				end
				local boton = UIBuilder.Boton(vista.Lista, etiquetaBoton, function()
					self:_Unirse(id, nombre, vista, botones, disponibles)
				end, {
					Estilo = disponible and "Primario" or "Secundario",
					Size = UDim2.new(1, 0, 0, UIBuilder.AltoBoton()),
					Alineacion = Enum.TextXAlignment.Left,
					Desactivado = not disponible,
					Selectable = disponible,
					LayoutOrder = vista.Siguiente(),
					Nombre = "Cargo_" .. id,
				})
				table.insert(botones, boton)
				disponibles[boton] = disponible
				if disponible and primerDisponible == nil then
					primerDisponible = boton
				end
				local explicacion
				if disponible then
					local def = RoleDefinitions.Obtener(id)
					explicacion = def and def.Descripcion or ""
				else
					explicacion = "Requiere autorización"
					if typeof(cargo.Motivo) == "string" and cargo.Motivo ~= "" and cargo.Motivo ~= explicacion then
						explicacion = explicacion .. ": " .. Format.Truncar(cargo.Motivo, 120)
					end
				end
				if explicacion ~= "" then
					UIBuilder.Texto(vista.Lista, explicacion, {
						LayoutOrder = vista.Siguiente(), Tamano = "Pequeno",
						Color = disponible and Colores.TextoSecundario or Colores.Amarillo,
					})
				end
			end
		end
	end

	vista.EstadoUnion = UIBuilder.Texto(vista.Lista, "", { LayoutOrder = vista.Siguiente(), Color = Colores.TextoSecundario, Visible = false, Nombre = "EstadoUnion" })

	local navegables = { vista.Volver }
	for _, b in ipairs(botones) do
		if disponibles[b] then
			table.insert(navegables, b)
		end
	end
	UIBuilder.Encadenar(navegables)
	if primerDisponible then
		UIBuilder.Enfocar(primerDisponible)
	else
		self.puedeContinuar = true
	end
end

function MenuController:_Unirse(id, nombre, vista, botones, disponibles)
	if self.uniendo or not RoleDefinitions.Existe(id) then
		return
	end
	self.uniendo = true
	for _, b in ipairs(botones) do
		UIBuilder.Habilitar(b, false)
	end
	if vista.EstadoUnion then
		vista.EstadoUnion.Text = "Entrando como " .. nombre .. "…"
		vista.EstadoUnion.Visible = true
	end
	task.spawn(function()
		local ok, respuesta = Net.Invocar("RequestJoinRole", { Cargo = id })
		self.uniendo = false
		if ok then
			local datos = typeof(respuesta.datos) == "table" and respuesta.datos or {}
			local cargo = RoleDefinitions.Existe(datos.Cargo) and datos.Cargo or id
			self.haJugado = true
			self:Cerrar()
			local HUD = self.registro.Get("HUDController")
			if HUD then
				if typeof(HUD.FijarCargo) == "function" then
					local salon = datos.Salon
					if typeof(salon) ~= "string" or salon == "" then
						salon = nil
					end
					pcall(HUD.FijarCargo, HUD, cargo, salon)
				end
				if typeof(HUD.Visible) == "function" then
					pcall(HUD.Visible, HUD, true)
				end
			end
			local mensaje = "Ahora eres " .. RoleDefinitions.Nombre(cargo) .. "."
			if typeof(datos.Salon) == "string" and datos.Salon ~= "" then
				mensaje = mensaje .. " Tu salón: " .. Format.Truncar(datos.Salon, 24) .. "."
			end
			self:_Notificar(mensaje, "exito")
			return
		end
		local mensajeError = UIBuilder.MensajeError(respuesta and respuesta.error)
		self.puedeContinuar = true
		if self:_VistaVigente(vista) then
			for _, b in ipairs(botones) do
				if disponibles[b] then
					UIBuilder.Habilitar(b, true)
				end
			end
			if vista.EstadoUnion then
				vista.EstadoUnion.Text = "No se pudo entrar como " .. nombre .. ": " .. mensajeError
				vista.EstadoUnion.TextColor3 = UITheme.Colores.Amarillo
			end
		end
		self:_Notificar(mensajeError, "error")
	end)
end

-- ACTUALIZACIONES: Catalogs.Changelog.
function MenuController:_VistaActualizaciones()
	local vista = self:_NuevaVista("Actualizaciones")
	local Colores = UITheme.Colores
	local registros = Catalogs.Changelog or {}
	if #registros == 0 then
		UIBuilder.Texto(vista.Lista, "Todavía no hay notas de versión.", { LayoutOrder = vista.Siguiente(), Color = Colores.TextoSecundario })
	end
	for _, entrada in ipairs(registros) do
		if typeof(entrada) == "table" then
			UIBuilder.Espacio(vista.Lista, 4, vista.Siguiente())
			local cabecera = "Versión " .. tostring(entrada.Version or "?")
			local fecha = fechaLegible(entrada.Fecha)
			if fecha ~= "" then
				cabecera = cabecera .. " · " .. fecha
			end
			UIBuilder.Subtitulo(vista.Lista, cabecera, { LayoutOrder = vista.Siguiente(), Fuente = "Titulo", Color = Colores.Blanco })
			for _, linea in ipairs(entrada.Resumen or {}) do
				UIBuilder.Texto(vista.Lista, "• " .. tostring(linea), { LayoutOrder = vista.Siguiente(), Tamano = "Texto", Color = Colores.TextoSecundario })
			end
		end
	end
	UIBuilder.Enfocar(vista.Volver)
end

-- EQUIPO: Catalogs.Equipo.
function MenuController:_VistaEquipo()
	local vista = self:_NuevaVista("Equipo del proyecto")
	local Colores = UITheme.Colores
	UIBuilder.Texto(vista.Lista, "Producción: " .. tostring(Config.Productora or "Horizon Studios") .. " " .. tostring(Config.Autor or "by Adrian"), {
		LayoutOrder = vista.Siguiente(), Fuente = "Subtitulo", Color = Colores.TextoSecundario,
	})
	for _, miembro in ipairs(Catalogs.Equipo or {}) do
		if typeof(miembro) == "table" then
			local fila = Instance.new("Frame")
			fila.Name = "Miembro"
			fila.BackgroundColor3 = Colores.Gris
			fila.BackgroundTransparency = 0.4
			fila.BorderSizePixel = 0
			fila.Size = UDim2.new(1, 0, 0, 0)
			fila.AutomaticSize = Enum.AutomaticSize.Y
			fila.LayoutOrder = vista.Siguiente()
			UIBuilder.Esquinas(fila, UITheme.RadioPequeno)
			UIBuilder.Relleno(fila, 8, 8, 12, 12)
			UIBuilder.Disposicion(fila, { Espaciado = 2 })
			UIBuilder.Texto(fila, tostring(miembro.Nombre or "—"), { LayoutOrder = 1, Fuente = "Titulo" })
			UIBuilder.Texto(fila, tostring(miembro.Rol or ""), { LayoutOrder = 2, Tamano = "Pequeno", Color = Colores.TextoSecundario })
			fila.Parent = vista.Lista
		end
	end
	UIBuilder.Enfocar(vista.Volver)
end

---------------------------------------------------------------------------------------------------
-- Paneles delegados (Ajustes, Ayuda, Soporte)
---------------------------------------------------------------------------------------------------
function MenuController:_Notificar(texto, nivel)
	local Notificaciones = self.registro and self.registro.Get("NotificationController")
	if Notificaciones and typeof(Notificaciones.Notificar) == "function" then
		pcall(Notificaciones.Notificar, Notificaciones, texto, nivel)
	end
end

function MenuController:_Delegar(nombreControlador, mensajeAusente)
	local controlador = self.registro.Get(nombreControlador)
	if not controlador or typeof(controlador.Abrir) ~= "function" then
		self:_Notificar(mensajeAusente, "aviso")
		return
	end
	-- El menú se oculta (queda un botón flotante) para que el panel delegado quede visible.
	self:_Suspender(controlador)
	local ok, err = pcall(controlador.Abrir, controlador)
	if not ok then
		warn("[ColegioRP] MenuController: " .. nombreControlador .. ": " .. tostring(err))
		self:_Reanudar()
		self:_Notificar("No se pudo abrir el panel; inténtalo de nuevo.", "error")
	end
end

function MenuController:_Suspender(controlador)
	self.tokenSuspension = self.tokenSuspension + 1
	local token = self.tokenSuspension
	self.suspendido = controlador
	self.fondo.Visible = false
	UIBuilder.Desenfocar(self.gui)
	self.botonVolverMenu.Visible = true
	-- Si el controlador informa de su estado, el menú vuelve solo al cerrarse el panel.
	if typeof(controlador.EstaAbierto) == "function" then
		local visto = false
		local inicio = os.clock()
		local function vigilar()
			if self.tokenSuspension ~= token or self.suspendido ~= controlador or not self.abierto then
				return
			end
			local ok, abierto = pcall(controlador.EstaAbierto, controlador)
			if ok and abierto == true then
				visto = true
			elseif ok and abierto == false and visto then
				self:_Reanudar()
				return
			end
			if not visto and os.clock() - inicio > 5 then
				return
			end
			task.delay(0.5, vigilar)
		end
		task.delay(0.5, vigilar)
	end
end

function MenuController:_Reanudar()
	self.tokenSuspension = self.tokenSuspension + 1
	self.suspendido = nil
	if self.botonVolverMenu then
		self.botonVolverMenu.Visible = false
	end
	if not self.abierto then
		return
	end
	self.fondo.Visible = true
	if self.vista == "Principal" then
		self:_MostrarPrincipal()
	end
end

---------------------------------------------------------------------------------------------------
-- API pública
---------------------------------------------------------------------------------------------------

-- Abre el menú principal (oculta el HUD). Si un panel delegado lo tenía suspendido, lo restaura.
function MenuController:Abrir()
	if self.abierto then
		if self.suspendido then
			self:_Reanudar()
		end
		return
	end
	self.abierto = true
	self.gui.Enabled = true
	self.fondo.Visible = true
	self.botonVolverMenu.Visible = false
	self.suspendido = nil
	local HUD = self.registro.Get("HUDController")
	if HUD and typeof(HUD.Visible) == "function" then
		pcall(HUD.Visible, HUD, false)
	end
	self.fondo.BackgroundTransparency = 1
	UIBuilder.Tween(self.fondo, { BackgroundTransparency = 0.12 }, "Normal")
	self:_MostrarPrincipal()
end

-- Cierra el menú y muestra el HUD.
function MenuController:Cerrar()
	if not self.abierto then
		return
	end
	self.abierto = false
	self.tokenVista = self.tokenVista + 1
	self.tokenSuspension = self.tokenSuspension + 1
	self.suspendido = nil
	UIBuilder.Desenfocar(self.gui)
	if self.panelVista then
		UIBuilder.Destruir(self.panelVista)
		self.panelVista = nil
	end
	self.vista = "Principal"
	self.principal.Visible = true
	self.botonVolverMenu.Visible = false
	self.gui.Enabled = false
	local HUD = self.registro.Get("HUDController")
	if HUD and typeof(HUD.Visible) == "function" then
		pcall(HUD.Visible, HUD, true)
	end
end

-- Abre o cierra el menú.
function MenuController:Alternar()
	if self.abierto then
		self:Cerrar()
	else
		self:Abrir()
	end
end

-- ¿El menú está abierto (aunque esté suspendido por un panel delegado)?
function MenuController:EstaAbierto()
	return self.abierto == true
end

return MenuController
