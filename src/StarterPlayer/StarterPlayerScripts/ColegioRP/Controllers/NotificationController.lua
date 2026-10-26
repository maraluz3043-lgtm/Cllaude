--[[
	Ruta en el Explorer: StarterPlayer.StarterPlayerScripts.ColegioRP.Controllers.NotificationController
	Tipo: ModuleScript
	Notificaciones del cliente: toasts arriba al centro (cola de máx. 4 visibles, sin tapar los controles táctiles
	inferiores), avisos oficiales destacados (8 s) y subtítulos de timbre según el ajuste Subtitulos. Escucha los
	tipos "Notificacion", "Aviso" y "Jornada" (timbre al cambiar de periodo) del canal EventoCliente.
]]

local ReplicatedFirst = game:GetService("ReplicatedFirst")

local NotificationController = {}
NotificationController.Nombre = "NotificationController"
NotificationController.MaxVisibles = 4 -- Toasts simultáneos en pantalla.
NotificationController.MaxPendientes = 20 -- Toasts en espera (los más antiguos se descartan).
NotificationController.DuracionAviso = 8 -- Segundos que permanece un aviso oficial.
NotificationController.VentanaTimbreSeg = 3 -- Dos timbres dentro de esta ventana se consideran el mismo.

local UIBuilder, UITheme, Net, Maid, Format, RoleDefinitions, Config

-- Niveles públicos (en minúsculas) -> nivel visual de UIBuilder.Toast y duración por defecto.
local NIVELES = {
	info = { Nivel = "Info", Duracion = 4 },
	exito = { Nivel = "Exito", Duracion = 4 },
	aviso = { Nivel = "Aviso", Duracion = 5 },
	error = { Nivel = "Error", Duracion = 6 },
	timbre = { Nivel = "Info", Duracion = 5, Icono = "♪" },
}

local ALIAS_NIVEL = {
	["Info"] = "info", ["Información"] = "info", ["Exito"] = "exito", ["Éxito"] = "exito", ["éxito"] = "exito",
	["Aviso"] = "aviso", ["Advertencia"] = "aviso", ["Error"] = "error", ["Timbre"] = "timbre",
}

local function normalizarNivel(nivel)
	if typeof(nivel) ~= "string" then
		return "info"
	end
	if NIVELES[nivel] then
		return nivel
	end
	if ALIAS_NIVEL[nivel] then
		return ALIAS_NIVEL[nivel]
	end
	local minusculas = string.lower(nivel)
	if NIVELES[minusculas] then
		return minusculas
	end
	return "info"
end

-- require seguro con WaitForChild acotado; lanza un error legible si falta (Init falla y Main lo registra).
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

local function texto(valor)
	if valor == nil then
		return ""
	end
	return tostring(valor)
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function NotificationController:Init(registro)
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
	Net = requerir(Util, "Net")
	Maid = requerir(Util, "Maid")
	Format = requerir(Util, "Format")

	self.maid = Maid.new()
	self.visibles = {} -- { Texto, Nivel, Destacado, Marco, Cerrar }
	self.pendientes = {}
	self.contador = 0
	self.ultimoTimbre = -math.huge
	self.ultimoEstadoJornada = nil
	self.tokenSubtitulo = 0
	self:_Construir()
end

function NotificationController:Start()
	-- Aviso de la pantalla de carga si continuó sin todos los recursos.
	local nombre = (Config.Nombres and Config.Nombres.SenalCargaLista) or "ColegioRP_CargaLista"
	local senal = ReplicatedFirst:FindFirstChild(nombre)
	if senal and senal:GetAttribute("AvisoRecursos") == true then
		self:Notificar("Algunos recursos siguen cargando; la escena puede tardar unos segundos en verse completa.", "aviso", 6)
	end

	task.spawn(function()
		local remoto = Net.Evento("EventoCliente")
		if not remoto then
			warn("[ColegioRP] NotificationController: EventoCliente no disponible; no se recibirán avisos del servidor.")
			return
		end
		self.maid:GiveTask(remoto.OnClientEvent:Connect(function(carga)
			if typeof(carga) ~= "table" or typeof(carga.Tipo) ~= "string" then
				return
			end
			local datos = carga.Datos
			if typeof(datos) ~= "table" then
				datos = {}
			end
			local ok, err = true, nil
			if carga.Tipo == "Notificacion" then
				ok, err = pcall(self._AlRecibirNotificacion, self, datos)
			elseif carga.Tipo == "Aviso" then
				ok, err = pcall(self.Aviso, self, datos)
			elseif carga.Tipo == "Jornada" then
				ok, err = pcall(self._AlRecibirJornada, self, datos)
			end
			if not ok then
				warn("[ColegioRP] NotificationController: " .. tostring(err))
			end
		end))
	end)
end

---------------------------------------------------------------------------------------------------
-- Interfaz
---------------------------------------------------------------------------------------------------
function NotificationController:_Construir()
	local capa = ((UITheme.Capas and UITheme.Capas.Menu) or 90) + 5
	local gui = UIBuilder.Pantalla("Notificaciones", capa)
	self.gui = gui

	local contenedor = Instance.new("Frame")
	contenedor.Name = "Toasts"
	contenedor.BackgroundTransparency = 1
	contenedor.BorderSizePixel = 0
	contenedor.AutomaticSize = Enum.AutomaticSize.Y
	contenedor.AnchorPoint = Vector2.new(0.5, 0)
	contenedor.Parent = gui
	UIBuilder.Disposicion(contenedor, { Espaciado = 6, Alineacion = Enum.HorizontalAlignment.Center })
	self.contenedor = contenedor

	local subtitulo = Instance.new("TextLabel")
	subtitulo.Name = "Subtitulo"
	subtitulo.BackgroundColor3 = UITheme.Colores.Sombra
	subtitulo.BackgroundTransparency = 0.35
	subtitulo.BorderSizePixel = 0
	subtitulo.Font = UITheme.Fuente("Subtitulo")
	subtitulo.TextSize = UITheme.Tamanos.Subtitulo
	subtitulo.TextColor3 = UITheme.Colores.Blanco
	subtitulo.TextWrapped = true
	subtitulo.AutomaticSize = Enum.AutomaticSize.Y
	subtitulo.AnchorPoint = Vector2.new(0.5, 1)
	subtitulo.Text = ""
	subtitulo.Visible = false
	UIBuilder.Esquinas(subtitulo, UITheme.RadioPequeno)
	UIBuilder.Relleno(subtitulo, 6, 6, 12, 12)
	subtitulo.Parent = gui
	self.subtitulo = subtitulo

	self:_Reubicar()
	pcall(function()
		local camara = workspace.CurrentCamera
		self.maid:GiveTask(camara:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			self:_Reubicar()
		end))
	end)
end

-- Ancho y posición según el tamaño de pantalla: arriba al centro bajo la barra de Roblox; subtítulos
-- abajo al centro por encima de los controles táctiles y de las acciones contextuales del HUD.
function NotificationController:_Reubicar()
	if not self.contenedor or self.contenedor.Parent == nil then
		return
	end
	local escala = math.max(0.5, UIBuilder.EscalaTotal())
	local anchoUI = UIBuilder.AnchoUI()
	local arriba = math.ceil(UIBuilder.InsetSuperior() / escala) + 8
	local ancho = math.floor(math.min(420, math.max(220, anchoUI - 32)))
	self.contenedor.Size = UDim2.new(0, ancho, 0, 0)
	self.contenedor.Position = UDim2.new(0.5, 0, 0, arriba)
	local abajo = math.ceil(UIBuilder.MargenInferiorTactil() / escala) + UIBuilder.AltoBoton() + 28
	self.subtitulo.Size = UDim2.new(0, math.floor(math.min(560, math.max(220, anchoUI - 48))), 0, 0)
	self.subtitulo.Position = UDim2.new(0.5, 0, 1, -abajo)
end

---------------------------------------------------------------------------------------------------
-- Cola de toasts
---------------------------------------------------------------------------------------------------
function NotificationController:_Duplicado(item)
	for _, visible in ipairs(self.visibles) do
		if visible.Texto == item.Texto and visible.Nivel == item.Nivel then
			return true
		end
	end
	for _, pendiente in ipairs(self.pendientes) do
		if pendiente.Texto == item.Texto and pendiente.Nivel == item.Nivel then
			return true
		end
	end
	return false
end

function NotificationController:_Encolar(item)
	if self:_Duplicado(item) then
		return
	end
	if #self.visibles < self.MaxVisibles then
		self:_Mostrar(item)
		return
	end
	if item.Destacado then
		-- Un aviso oficial se muestra de inmediato: entra primero en la cola y se retira el toast más antiguo.
		table.insert(self.pendientes, 1, item)
		for _, visible in ipairs(self.visibles) do
			if not visible.Destacado and not visible.Cerrando then
				visible.Cerrando = true
				pcall(visible.Cerrar)
				break
			end
		end
	else
		table.insert(self.pendientes, item)
	end
	while #self.pendientes > self.MaxPendientes do
		local indice = #self.pendientes
		for i, pendiente in ipairs(self.pendientes) do
			if not pendiente.Destacado then
				indice = i
				break
			end
		end
		table.remove(self.pendientes, indice)
	end
end

function NotificationController:_Mostrar(item)
	if not self.contenedor or self.contenedor.Parent == nil then
		return
	end
	self.contador = self.contador + 1
	local orden = self.contador
	if item.Destacado then
		orden = orden - 1000000
	end
	local entrada = { Texto = item.Texto, Nivel = item.Nivel, Destacado = item.Destacado == true }
	local marco, cerrar = UIBuilder.Toast(self.contenedor, item.Texto, item.Nivel, item.Duracion, {
		Titulo = item.Titulo,
		Icono = item.Icono,
		LayoutOrder = orden,
		AlCerrar = function()
			self:_AlCerrarToast(entrada)
		end,
	})
	if not marco then
		return
	end
	entrada.Marco = marco
	entrada.Cerrar = cerrar
	table.insert(self.visibles, entrada)

	if item.Destacado then
		local borde = marco:FindFirstChildOfClass("UIStroke")
		if borde then
			borde.Color = UITheme.Colores.Amarillo
			borde.Thickness = 2
		end
	end

	-- Tocar o pulsar el toast lo cierra.
	local zona = Instance.new("TextButton")
	zona.Name = "Cerrar"
	zona.BackgroundTransparency = 1
	zona.Text = ""
	zona.Selectable = false
	zona.AutoButtonColor = false
	zona.Size = UDim2.new(1, 58, 1, 0)
	zona.Position = UDim2.new(0, -46, 0, 0)
	zona.ZIndex = marco.ZIndex + 5
	zona.Parent = marco
	zona.Activated:Connect(function()
		if typeof(cerrar) == "function" then
			cerrar()
		end
	end)

	if item.Destacado or item.Nivel == "Aviso" or item.Nivel == "Error" then
		UIBuilder.Sonido("Notificacion", 0.5)
	end
end

function NotificationController:_AlCerrarToast(entrada)
	for i, visible in ipairs(self.visibles) do
		if visible == entrada then
			table.remove(self.visibles, i)
			break
		end
	end
	task.defer(function()
		while #self.visibles < self.MaxVisibles and #self.pendientes > 0 do
			local siguiente = table.remove(self.pendientes, 1)
			self:_Mostrar(siguiente)
		end
	end)
end

---------------------------------------------------------------------------------------------------
-- API pública
---------------------------------------------------------------------------------------------------

-- Muestra una notificación. nivel: "info" | "exito" | "aviso" | "error" | "timbre". duracion en segundos (opcional).
-- opciones (opcional): { Titulo = string, Destacado = bool, Icono = string }.
function NotificationController:Notificar(contenido, nivel, duracion, opciones)
	local mensaje = Format.Truncar(texto(contenido), 220)
	if mensaje == "" then
		return
	end
	local clave = normalizarNivel(nivel)
	if clave == "timbre" then
		self:Timbre(mensaje, duracion)
		return
	end
	local def = NIVELES[clave]
	local segundos = tonumber(duracion) or def.Duracion
	if segundos ~= segundos then
		segundos = def.Duracion
	end
	segundos = math.clamp(segundos, 1, 20)
	opciones = typeof(opciones) == "table" and opciones or {}
	self:_Encolar({
		Texto = mensaje,
		Nivel = def.Nivel,
		Duracion = segundos,
		Icono = opciones.Icono or def.Icono,
		Titulo = opciones.Titulo,
		Destacado = opciones.Destacado == true,
	})
end

-- Timbre escolar: sonido (si Config.Sonidos.Timbre > 0) y subtítulo si el ajuste Subtitulos está activo;
-- con los subtítulos desactivados se muestra como toast informativo.
function NotificationController:Timbre(contenido, duracion)
	local ahora = os.clock()
	if ahora - self.ultimoTimbre < self.VentanaTimbreSeg then
		return
	end
	self.ultimoTimbre = ahora
	local mensaje = Format.Truncar(texto(contenido), 160)
	UIBuilder.Sonido("Timbre", 0.6)
	if mensaje == "" then
		mensaje = "Suena el timbre"
	end
	if self:SubtitulosActivos() then
		self:Subtitulo("♪ [Timbre] " .. mensaje, tonumber(duracion) or 5)
	else
		self:_Encolar({ Texto = mensaje, Nivel = "Info", Duracion = tonumber(duracion) or 5, Icono = "♪" })
	end
end

-- Muestra un subtítulo abajo al centro durante 'duracion' segundos (reemplaza al anterior).
function NotificationController:Subtitulo(contenido, duracion)
	local etiqueta = self.subtitulo
	if not etiqueta or etiqueta.Parent == nil then
		return
	end
	self.tokenSubtitulo = self.tokenSubtitulo + 1
	local token = self.tokenSubtitulo
	etiqueta.Text = Format.Truncar(texto(contenido), 200)
	etiqueta.TextTransparency = 1
	etiqueta.BackgroundTransparency = 1
	etiqueta.Visible = true
	UIBuilder.Tween(etiqueta, { TextTransparency = 0, BackgroundTransparency = 0.35 }, "Rapida")
	local segundos = tonumber(duracion) or 5
	if segundos ~= segundos then
		segundos = 5
	end
	task.delay(math.clamp(segundos, 1, 15), function()
		if self.tokenSubtitulo ~= token or etiqueta.Parent == nil then
			return
		end
		UIBuilder.Tween(etiqueta, { TextTransparency = 1, BackgroundTransparency = 1 }, "Normal", function()
			if self.tokenSubtitulo == token and etiqueta.Parent ~= nil then
				etiqueta.Visible = false
			end
		end)
	end)
end

-- Aviso oficial { Texto, Autor, Cargo, Alcance }: toast destacado durante 8 s.
function NotificationController:Aviso(datos)
	if typeof(datos) ~= "table" then
		return
	end
	local maximo = (Config.Limites and Config.Limites.MaxAvisoCaracteres) or 160
	local mensaje = Format.Truncar(texto(datos.Texto), maximo)
	if mensaje == "" then
		return
	end
	local titulo = "AVISO OFICIAL"
	if datos.Alcance == "Aula" then
		titulo = "AVISO DEL AULA"
	end
	local firma = {}
	if typeof(datos.Cargo) == "string" and datos.Cargo ~= "" then
		if RoleDefinitions.Existe(datos.Cargo) then
			table.insert(firma, RoleDefinitions.Nombre(datos.Cargo))
		else
			table.insert(firma, Format.Truncar(datos.Cargo, 32))
		end
	end
	if typeof(datos.Autor) == "string" and datos.Autor ~= "" then
		table.insert(firma, Format.Truncar(datos.Autor, 32))
	end
	if #firma > 0 then
		titulo = titulo .. " · " .. table.concat(firma, " ")
	end
	self:_Encolar({
		Texto = mensaje,
		Nivel = "Aviso",
		Duracion = self.DuracionAviso,
		Titulo = titulo,
		Icono = "!",
		Destacado = true,
	})
end

-- Cierra todos los toasts y vacía la cola.
function NotificationController:Limpiar()
	table.clear(self.pendientes)
	local copia = {}
	for i, visible in ipairs(self.visibles) do
		copia[i] = visible
	end
	for _, visible in ipairs(copia) do
		if typeof(visible.Cerrar) == "function" then
			pcall(visible.Cerrar)
		end
	end
end

-- ¿Están activos los subtítulos? (ajuste Subtitulos de SettingsController; por defecto sí).
function NotificationController:SubtitulosActivos()
	local Settings = self.registro and self.registro.Get("SettingsController")
	if Settings and typeof(Settings.Ajustes) == "function" then
		local ok, ajustes = pcall(Settings.Ajustes, Settings)
		if ok and typeof(ajustes) == "table" and ajustes.Subtitulos ~= nil then
			return ajustes.Subtitulos == true
		end
	end
	return true
end

---------------------------------------------------------------------------------------------------
-- Eventos del servidor
---------------------------------------------------------------------------------------------------
function NotificationController:_AlRecibirNotificacion(datos)
	if typeof(datos.Texto) ~= "string" then
		return
	end
	local duracion = tonumber(datos.Duracion)
	if duracion ~= nil and duracion ~= duracion then
		duracion = nil
	end
	if duracion then
		duracion = math.clamp(duracion, 1, 15)
	end
	-- Algunos servicios (RoleService, FootballService) envían también Titulo y el nivel en Tipo.
	local opciones = nil
	if typeof(datos.Titulo) == "string" and datos.Titulo ~= "" then
		opciones = { Titulo = Format.Truncar(datos.Titulo, 60) }
	end
	self:Notificar(datos.Texto, datos.Nivel or datos.Tipo, duracion, opciones)
end

-- Cambio de periodo de la jornada -> timbre (el primer snapshot solo fija la referencia).
function NotificationController:_AlRecibirJornada(datos)
	local estado = datos.Estado
	if typeof(estado) ~= "string" then
		return
	end
	local anterior = self.ultimoEstadoJornada
	self.ultimoEstadoJornada = estado
	if anterior == nil or anterior == estado or datos.Timbre == false then
		return
	end
	local nombre = datos.Nombre
	if typeof(nombre) ~= "string" or nombre == "" then
		nombre = estado
	end
	self:Timbre("Comienza: " .. nombre)
end

return NotificationController
