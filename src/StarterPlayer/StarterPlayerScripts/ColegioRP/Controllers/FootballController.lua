--[[
	Ruta en el Explorer: StarterPlayer.StarterPlayerScripts.ColegioRP.Controllers.FootballController
	Tipo: ModuleScript
	Interfaz de la cancha (docs/ARQUITECTURA.md §7, prueba P11). Al entrar en la zona CANCHA (comprobación a 1 Hz)
	muestra un panel compacto con marcador, tiempo, equipo propio y botones (Unirse A/B, Iniciar si procede,
	Reiniciar/Finalizar para árbitros, Salir) y habilita la patada: PC = tecla E o clic sobre el balón, mando =
	ButtonX, táctil = botón grande abajo a la derecha, a la izquierda del botón de salto y por encima de los
	controles. La fuerza depende del tiempo de pulsación (0.4..1.0, barra de carga de hasta 1 s) y la dirección
	mezcla 70/30 (jugador->balón horizontal) con la dirección de la cámara. Envía FootballKick y FootballAction;
	no predice físicas: el servidor es la autoridad. Colorea a los jugadores por el atributo EquipoFutbol
	(Highlight local) y muestra un efecto local de "¡Gol!". Se oculta fuera de la zona.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local FootballController = {}
FootballController.Nombre = "FootballController"
FootballController.PeriodoZonaSeg = 1 -- Comprobación de zona, resaltados y posición del botón táctil.
FootballController.PeriodoTextoSeg = 0.25 -- Reloj, estado y disponibilidad de la patada (solo en la zona).
FootballController.CargaMaxSeg = 1 -- Tiempo de pulsación para la fuerza máxima.
FootballController.FuerzaMin = 0.4 -- Fuerza con una pulsación corta.
FootballController.FuerzaMaxima = 1 -- Fuerza con la carga completa.
FootballController.MezclaBalon = 0.7 -- Peso de la dirección jugador->balón (el resto es la cámara).
FootballController.ElevacionBase = 0.1 -- Componente vertical añadida (el servidor la limita al 35 %).
FootballController.MargenCooldownSeg = 0.05 -- Margen local sobre Config.Futbol.CooldownPatada.
FootballController.SoltarAutomaticoSeg = 2.5 -- Una carga mantenida más de esto se suelta sola.
FootballController.RadioClicBalon = 2.2 -- Tolerancia (studs) del clic sobre el balón.
FootballController.DistanciaClicMax = 250
FootballController.EsperaEstadoSeg = 2 -- Si el servidor no envió el estado al entrar, se pide tras esto.
FootballController.MaxResaltados = 20 -- Highlights simultáneos (límite del motor: 31).
FootballController.DuracionGolSeg = 2.6
FootballController.DuracionPistaSeg = 3
FootballController.TamanoBotonPatear = 104 -- Unidades de UI (antes de la UIScale).

local UIBuilder, UITheme, Net, Maid, Format, Zones, Config

local player = Players.LocalPlayer
local ATRIBUTO_EQUIPO = "EquipoFutbol"

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

local function valida(instancia)
	return typeof(instancia) == "Instance" and instancia.Parent ~= nil
end

local function numero(valor)
	local n = tonumber(valor)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return nil
	end
	return n
end

local function servidorAhora()
	local ok, t = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if ok and numero(t) then
		return t
	end
	return os.time()
end

-- HumanoidRootPart del personaje local si está vivo.
local function raizLocal()
	local personaje = player.Character
	if not personaje then
		return nil
	end
	local humanoide = personaje:FindFirstChildOfClass("Humanoid")
	if humanoide and humanoide.Health <= 0 then
		return nil
	end
	local raiz = personaje:FindFirstChild("HumanoidRootPart")
	if raiz and raiz:IsA("BasePart") then
		return raiz
	end
	return nil
end

local function hex(color)
	return string.format("#%02X%02X%02X", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
end

local function miEquipo()
	local equipo = player:GetAttribute(ATRIBUTO_EQUIPO)
	if equipo == "A" or equipo == "B" then
		return equipo
	end
	return nil
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function FootballController:Init(registro)
	self.registro = registro
	Config = registro.Config
	UIBuilder = registro.UIBuilder
	if not UIBuilder then
		error("UIBuilder no está disponible")
	end
	local Shared = registro.Shared
	local Util = Shared:FindFirstChild("Util") or Shared:WaitForChild("Util", 10)
	UITheme = requerir(Shared, "UITheme")
	Net = requerir(Util, "Net")
	Maid = requerir(Util, "Maid")
	Format = requerir(Util, "Format")
	Zones = requerir(Util, "Zones")

	local cfg = Config.Futbol or {}
	self.distanciaPatada = numero(cfg.DistanciaPatada) or 9
	self.cooldown = numero(cfg.CooldownPatada) or 0.6
	self.duracion = numero(cfg.DuracionPartidoSeg) or 300
	self.maxPorEquipo = numero(cfg.JugadoresPorEquipoMax) or 7
	self.colorA = UITheme.Colores.Rojo
	self.colorB = UITheme.Aclarar(UITheme.Colores.Azul, 0.35)

	self.maid = Maid.new()
	self.zonaId = "CANCHA"
	self.enZona = false
	self.estado = nil -- último estado recibido del servidor
	self.estadoRecibidoClock = -math.huge
	self.entradaZonaClock = nil
	self.pedidoEstado = false
	self.cargando = nil -- { Fuente, Inicio, Input }
	self.cooldownHasta = 0
	self.ocupado = false
	self.minimizado = false
	self.autoMinimizado = false -- minimizado por el controlador (teléfono en partido), no por el jugador
	self.resaltados = {} -- Player -> Highlight
	self.balon = nil
	self.carpeta = nil
	self.acumZona = 0
	self.acumTexto = 0
	self.ui = nil
	self.tokenGol = 0
	self.tokenPista = 0
	self.pistaHasta = 0
	self.patearHabilitado = nil
end

function FootballController:Start()
	local okUI, errUI = pcall(self._Construir, self)
	if not okUI then
		warn("[ColegioRP] FootballController: no se pudo construir la interfaz: " .. tostring(errUI))
		return
	end
	self:_ConectarEntrada()

	self.maid:GiveTask(RunService.Heartbeat:Connect(function(dt)
		self:_Paso(dt)
	end))
	self.maid:GiveTask(player:GetAttributeChangedSignal(ATRIBUTO_EQUIPO):Connect(function()
		self:_Refrescar()
	end))
	self.maid:GiveTask(Players.PlayerRemoving:Connect(function(otro)
		self:_QuitarResaltado(otro)
	end))
	pcall(function()
		local camara = workspace.CurrentCamera
		self.maid:GiveTask(camara:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			self:_PosicionarBotonPatear()
		end))
	end)

	task.spawn(function()
		local remoto = Net.Evento("EventoCliente")
		if not remoto then
			warn("[ColegioRP] FootballController: EventoCliente no disponible; la cancha no recibirá datos del servidor.")
			return
		end
		self.maid:GiveTask(remoto.OnClientEvent:Connect(function(carga)
			if typeof(carga) ~= "table" or carga.Tipo ~= "Futbol" or typeof(carga.Datos) ~= "table" then
				return
			end
			local ok, err = pcall(self._AlEvento, self, carga.Datos)
			if not ok then
				warn("[ColegioRP] FootballController: " .. tostring(err))
			end
		end))
	end)

	task.spawn(function()
		pcall(self._ResolverBalon, self, true)
	end)
	-- Precarga de los remotos (Net los guarda en caché) para que la primera patada no espere.
	task.spawn(function()
		Net.Evento("FootballKick")
		Net.Funcion("FootballAction")
	end)
end

-- Libera conexiones, resaltados e interfaz.
function FootballController:Destruir()
	self:_CancelarCarga()
	self:_QuitarResaltados()
	if self.maid then
		self.maid:DoCleaning()
	end
	self.ui = nil
	self.enZona = false
end

---------------------------------------------------------------------------------------------------
-- Balón y zona
---------------------------------------------------------------------------------------------------

-- Busca Workspace.ColegioRP_Mapa.Futbol.Balon (esperando con timeout si 'esperar').
function FootballController:_ResolverBalon(esperar)
	local nombreRaiz = (Config.Nombres and Config.Nombres.CarpetaMapa) or "ColegioRP_Mapa"
	local raiz = workspace:FindFirstChild(nombreRaiz)
	if not raiz and esperar then
		raiz = workspace:WaitForChild(nombreRaiz, 20)
	end
	if not raiz then
		return nil
	end
	local carpeta = raiz:FindFirstChild("Futbol")
	if not carpeta and esperar then
		carpeta = raiz:WaitForChild("Futbol", 10)
	end
	if not carpeta then
		return nil
	end
	self.carpeta = carpeta
	local zona = carpeta:GetAttribute("ZoneId")
	if typeof(zona) == "string" and Zones.Zona(zona) then
		self.zonaId = zona
	end
	local distancia = numero(carpeta:GetAttribute("DistanciaPatada"))
	if distancia and distancia > 0 then
		self.distanciaPatada = distancia
	end
	local cooldown = numero(carpeta:GetAttribute("CooldownPatada"))
	if cooldown and cooldown > 0 then
		self.cooldown = cooldown
	end
	local balon = carpeta:FindFirstChild("Balon")
	if not balon and esperar then
		balon = carpeta:WaitForChild("Balon", 10)
	end
	if balon and balon:IsA("BasePart") then
		self.balon = balon
	end
	return self.balon
end

function FootballController:_DistanciaBalon()
	local balon = self.balon
	local raiz = raizLocal()
	if not valida(balon) or not raiz then
		return nil
	end
	return (raiz.Position - balon.Position).Magnitude
end

function FootballController:_Paso(dt)
	self.acumZona = self.acumZona + dt
	if self.acumZona >= self.PeriodoZonaSeg then
		self.acumZona = 0
		local ok, err = pcall(self._RevisarZona, self)
		if not ok then
			warn("[ColegioRP] FootballController: " .. tostring(err))
		end
	end
	if self.enZona then
		self.acumTexto = self.acumTexto + dt
		if self.acumTexto >= self.PeriodoTextoSeg then
			self.acumTexto = 0
			pcall(self._RefrescarDinamico, self)
		end
	end
end

function FootballController:_RevisarZona()
	local raiz = raizLocal()
	local dentro = false
	if raiz then
		dentro = Zones.Contiene(self.zonaId, raiz.Position)
	end
	if dentro ~= self.enZona then
		self.enZona = dentro
		if dentro then
			self:_AlEntrar()
		else
			self:_AlSalir()
		end
	end
	if not dentro then
		return
	end
	if not valida(self.balon) then
		self:_ResolverBalon(false)
	end
	self:_ActualizarResaltados()
	self:_PosicionarBotonPatear()
	-- Respaldo: el servidor envía el estado al entrar; si no llegó, se pide una vez.
	if not self.pedidoEstado and self.entradaZonaClock and os.clock() - self.entradaZonaClock >= self.EsperaEstadoSeg
		and self.estadoRecibidoClock < self.entradaZonaClock then
		self.pedidoEstado = true
		self:_Accion("Estado", nil, true)
	end
end

function FootballController:_AlEntrar()
	self.entradaZonaClock = os.clock()
	self.pedidoEstado = false
	if self.ui then
		self.ui.Gui.Enabled = true
		UIBuilder.Aparecer(self.ui.Panel)
	end
	self:_Refrescar()
	self:_PosicionarBotonPatear()
end

function FootballController:_AlSalir()
	self:_CancelarCarga()
	self:_QuitarResaltados()
	self.entradaZonaClock = nil
	if self.ui then
		UIBuilder.Desenfocar(self.ui.Gui)
		self.ui.Gui.Enabled = false
		self.ui.GolMarco.Visible = false
	end
end

-- ¿Está el jugador local en la cancha?
function FootballController:EnZona()
	return self.enZona == true
end

-- Último estado de la cancha recibido del servidor (o nil).
function FootballController:Estado()
	return self.estado
end

---------------------------------------------------------------------------------------------------
-- Interfaz
---------------------------------------------------------------------------------------------------
function FootballController:_Construir()
	local Colores = UITheme.Colores
	local capa = (UITheme.Capas and UITheme.Capas.Panel) or 50
	local gui = UIBuilder.Pantalla("Futbol", capa, { Visible = false })
	self.maid:GiveTask(gui)
	local contenido = UIBuilder.Contenedor(gui, { Nombre = "Contenido" })
	local tactil = UIBuilder.EsTactil()
	local estrecho = UIBuilder.EsEstrecho()
	local ancho = 340
	if estrecho then
		ancho = 300
	end
	local ui = { Gui = gui, Contenido = contenido, Tactil = tactil }

	-- Panel compacto. Táctil: arriba al centro (lejos del joystick y del salto). PC/mando: derecha, a media altura.
	local posicion = UDim2.new(1, 0, 0.55, 0)
	local ancla = Vector2.new(1, 0.5)
	if tactil then
		posicion = UDim2.new(0.5, 0, 0, 0)
		ancla = Vector2.new(0.5, 0)
	end
	local panel, cuerpo = UIBuilder.Panel(contenido, {
		Nombre = "PanelFutbol", AutoAlto = true, Espaciado = 6, Transparencia = 0.12,
		Size = UDim2.new(0, ancho, 0, 0), Position = posicion, AnchorPoint = ancla,
	})
	ui.Panel = panel

	-- Fila 1: equipos, marcador, tiempo y minimizar.
	local altoFila = 34
	if tactil then
		altoFila = math.max(34, UIBuilder.MinimoTactil())
	end
	local fila = UIBuilder.Marco(cuerpo, { Nombre = "Marcador", Alto = altoFila, LayoutOrder = 1 })
	local comunes = { AutoAlto = false, Ajustar = false, AlineacionY = Enum.TextYAlignment.Center, Fuente = "Titulo" }
	local function texto(padre, valor, props)
		local copia = {}
		for clave, v in pairs(comunes) do
			copia[clave] = v
		end
		for clave, v in pairs(props) do
			copia[clave] = v
		end
		return UIBuilder.Texto(padre, valor, copia)
	end
	ui.EquipoA = texto(fila, "A", { Nombre = "EquipoA", Tamano = "Subtitulo", Color = self.colorA, Alineacion = Enum.TextXAlignment.Center,
		Size = UDim2.new(0, 26, 1, 0), Position = UDim2.new(0, 0, 0, 0) })
	ui.Marcador = texto(fila, "0 - 0", { Nombre = "Goles", Tamano = "Titulo", Alineacion = Enum.TextXAlignment.Center,
		Size = UDim2.new(0, 84, 1, 0), Position = UDim2.new(0, 26, 0, 0) })
	ui.EquipoB = texto(fila, "B", { Nombre = "EquipoB", Tamano = "Subtitulo", Color = self.colorB, Alineacion = Enum.TextXAlignment.Center,
		Size = UDim2.new(0, 26, 1, 0), Position = UDim2.new(0, 110, 0, 0) })
	local anchoMin = 36
	if tactil then
		anchoMin = UIBuilder.MinimoTactil()
	end
	ui.Tiempo = texto(fila, Format.Tiempo(self.duracion), { Nombre = "Tiempo", Tamano = "Subtitulo", Color = Colores.Amarillo,
		Alineacion = Enum.TextXAlignment.Right, Size = UDim2.new(1, -(140 + anchoMin + 6), 1, 0), Position = UDim2.new(0, 140, 0, 0) })
	ui.Minimizar = UIBuilder.Boton(fila, "–", function()
		self.autoMinimizado = false
		self:_Minimizar(not self.minimizado)
	end, {
		Nombre = "Minimizar", Estilo = "Fantasma", Ancho = anchoMin, Alto = altoFila, Tamano = "Subtitulo",
		Position = UDim2.new(1, 0, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5),
	})

	-- Filas 2 y 3: estado del partido y equipo propio.
	ui.Estado = UIBuilder.Texto(cuerpo, "Conectando con la cancha…", { Nombre = "Estado", Tamano = "Pequeno", Color = Colores.TextoSecundario, LayoutOrder = 2 })
	ui.Equipo = UIBuilder.Texto(cuerpo, "No estás en un equipo", { Nombre = "MiEquipo", Tamano = "Pequeno", LayoutOrder = 3 })

	-- Fila 4: botones (se reparten en varias líneas si no caben).
	local botones = UIBuilder.Marco(cuerpo, { Nombre = "Botones", AutoAlto = true, LayoutOrder = 4 })
	UIBuilder.Disposicion(botones, { Horizontal = true, Espaciado = 6, Alineacion = Enum.HorizontalAlignment.Center, Wraps = true })
	-- Tres botones por línea; el texto se reduce (8..13) si no cabe para no truncarse.
	local interior = ancho - 2 * (UITheme.Espaciado + 6)
	local anchoBoton = math.floor((interior - 2 * 6) / 3)
	local function boton(nombre, etiqueta, estilo, orden, fn)
		local b = UIBuilder.Boton(botones, etiqueta, fn, { Nombre = nombre, Estilo = estilo, Ancho = anchoBoton, LayoutOrder = orden, Tamano = "Pequeno" })
		pcall(function()
			b.TextScaled = true
			local limite = Instance.new("UITextSizeConstraint")
			limite.MinTextSize = 8
			limite.MaxTextSize = UITheme.Tamanos.Pequeno
			limite.Parent = b
		end)
		return b
	end
	ui.UnirseA = boton("UnirseA", "Unirse A", "Secundario", 1, function()
		self:_Accion("Unirse", "A")
	end)
	ui.UnirseB = boton("UnirseB", "Unirse B", "Secundario", 2, function()
		self:_Accion("Unirse", "B")
	end)
	ui.Iniciar = boton("Iniciar", "Iniciar", "Exito", 3, function()
		self:_Accion("Iniciar", nil)
	end)
	ui.Reiniciar = boton("Reiniciar", "Reiniciar", "Secundario", 4, function()
		self:_Accion("Reiniciar", nil)
	end)
	ui.Finalizar = boton("Finalizar", "Finalizar", "Peligro", 5, function()
		self:_Accion("Finalizar", nil)
	end)
	ui.Salir = boton("Salir", "Salir", "Fantasma", 6, function()
		self:_Accion("Salir", nil)
	end)
	ui.Botones = botones
	ui.ListaBotones = { ui.UnirseA, ui.UnirseB, ui.Iniciar, ui.Reiniciar, ui.Finalizar, ui.Salir }
	for _, b in ipairs({ ui.UnirseA, ui.UnirseB }) do
		pcall(function()
			b.RichText = true
		end)
	end

	-- Filas 5 y 6: pista de controles / mensajes y barra de carga.
	ui.Pista = UIBuilder.Texto(cuerpo, "", { Nombre = "Pista", Tamano = "Pequeno", Color = Colores.TextoSecundario, LayoutOrder = 5 })
	ui.Barra = UIBuilder.Barra(cuerpo, 0, { Nombre = "Carga", Alto = 8, LayoutOrder = 6, Color = Colores.Amarillo })
	ui.Barra.Frame.Visible = false
	ui.Detalles = { ui.Estado, ui.Equipo, botones, ui.Pista }

	-- Botón táctil de patada (abajo a la derecha, por encima de los controles táctiles).
	if tactil then
		local tam = self.TamanoBotonPatear
		local patear = UIBuilder.Boton(contenido, "PATEAR", nil, {
			Nombre = "Patear", Estilo = "Primario", Ancho = tam, Alto = tam, Tamano = "Subtitulo",
			Position = UDim2.new(1, 0, 1, 0), AnchorPoint = Vector2.new(1, 1),
		})
		local esquina = patear:FindFirstChildOfClass("UICorner")
		if esquina then
			esquina.CornerRadius = UDim.new(0.5, 0)
		end
		patear.Selectable = false
		local barra = UIBuilder.Barra(patear, 0, {
			Nombre = "CargaTactil", Alto = 6, Size = UDim2.new(0.7, 0, 0, 6),
			Position = UDim2.new(0.5, 0, 1, -16), AnchorPoint = Vector2.new(0.5, 1),
			Color = Colores.Amarillo, ColorFondo = Colores.RojoOscuro,
		})
		barra.Frame.Visible = false
		self.maid:GiveTask(patear.InputBegan:Connect(function(entrada)
			local tipo = entrada.UserInputType
			if tipo == Enum.UserInputType.Touch or tipo == Enum.UserInputType.MouseButton1 then
				self:_IniciarCarga("Tactil", entrada)
			end
		end))
		self.maid:GiveTask(patear.InputEnded:Connect(function(entrada)
			local c = self.cargando
			if not c or c.Fuente ~= "Tactil" then
				return
			end
			local tipo = entrada.UserInputType
			if tipo == Enum.UserInputType.Touch or tipo == Enum.UserInputType.MouseButton1 then
				self:_SoltarCarga()
			end
		end))
		ui.Patear = patear
		ui.BarraTactil = barra
	end

	-- Efecto local de gol (centro de la pantalla).
	local golMarco = Instance.new("Frame")
	golMarco.Name = "Gol"
	golMarco.BackgroundColor3 = Colores.GrisPanel
	golMarco.BackgroundTransparency = 0.15
	golMarco.BorderSizePixel = 0
	golMarco.AnchorPoint = Vector2.new(0.5, 0.5)
	golMarco.Position = UDim2.new(0.5, 0, 0.42, 0)
	golMarco.Size = UDim2.new(0, 360, 0, 0)
	golMarco.AutomaticSize = Enum.AutomaticSize.Y
	golMarco.Visible = false
	golMarco.ZIndex = 20
	UIBuilder.Esquinas(golMarco, UITheme.Radio)
	ui.GolBorde = UIBuilder.Borde(golMarco, Colores.Amarillo, 2)
	UIBuilder.Relleno(golMarco, 10, 12, 14, 14)
	UIBuilder.Disposicion(golMarco, { Espaciado = 2, Alineacion = Enum.HorizontalAlignment.Center })
	ui.GolTitulo = UIBuilder.Texto(golMarco, "¡GOL!", {
		Nombre = "Titulo", Fuente = "Titulo", Tamano = 44, Color = Colores.Amarillo, Alineacion = Enum.TextXAlignment.Center, LayoutOrder = 1, ZIndex = 21,
	})
	ui.GolDetalle = UIBuilder.Texto(golMarco, "", {
		Nombre = "Detalle", Tamano = "Subtitulo", Alineacion = Enum.TextXAlignment.Center, LayoutOrder = 2, ZIndex = 21,
	})
	golMarco.Parent = contenido
	ui.GolMarco = golMarco

	self.ui = ui
	self:_Refrescar()
end

function FootballController:_Minimizar(minimizado)
	self.minimizado = minimizado == true
	local ui = self.ui
	if not ui then
		return
	end
	for _, fila in ipairs(ui.Detalles) do
		fila.Visible = not self.minimizado
	end
	if self.minimizado then
		ui.Barra.Frame.Visible = false
		UIBuilder.TextoBoton(ui.Minimizar, "+")
	else
		UIBuilder.TextoBoton(ui.Minimizar, "–")
	end
	self:_RefrescarBotones()
end

-- Coloca el botón táctil a la izquierda del botón de salto de Roblox (o con un margen de respaldo).
function FootballController:_PosicionarBotonPatear()
	local ui = self.ui
	if not ui or not valida(ui.Patear) then
		return
	end
	local escala = math.max(0.5, UIBuilder.EscalaTotal())
	local anchoPx = UIBuilder.Viewport().X
	local derechaPx = nil
	local okSalto, salto = pcall(function()
		local playerGui = player:FindFirstChildOfClass("PlayerGui")
		local touchGui = playerGui and playerGui:FindFirstChild("TouchGui")
		local marco = touchGui and touchGui:FindFirstChild("TouchControlFrame")
		return marco and marco:FindFirstChild("JumpButton")
	end)
	if okSalto and salto and salto:IsA("GuiObject") and salto.Visible and salto.AbsoluteSize.X > 0 then
		derechaPx = (anchoPx - salto.AbsolutePosition.X) + 12
	end
	if not derechaPx or derechaPx <= 0 or derechaPx > anchoPx * 0.5 then
		derechaPx = 190
		if UIBuilder.EsEstrecho() then
			derechaPx = 110
		end
	end
	-- En pantallas estrechas también se deja libre la columna de botones del HUD (arriba a la derecha).
	if UIBuilder.EsEstrecho() then
		derechaPx = math.max(derechaPx, 132 * escala)
	end
	local desplazamiento = math.max(0, math.floor(derechaPx / escala - UITheme.Espaciado))
	ui.Patear.Position = UDim2.new(1, -desplazamiento, 1, 0)
end

-- Refresco completo tras un cambio de estado.
function FootballController:_Refrescar()
	local ui = self.ui
	if not ui then
		return
	end
	local estado = self.estado or {}
	local marcador = estado.Marcador or { A = 0, B = 0 }
	ui.Marcador.Text = Format.Marcador(marcador.A or 0, marcador.B or 0)
	local mio = miEquipo()
	local conteo = estado.Conteo or { A = 0, B = 0 }
	local maximo = numero(estado.MaxPorEquipo) or self.maxPorEquipo
	local resumen = string.format("A %d/%d · B %d/%d", conteo.A or 0, maximo, conteo.B or 0, maximo)
	if mio then
		ui.Equipo.Text = "Tu equipo: " .. Format.Equipo(mio) .. "  ·  " .. resumen
		if mio == "A" then
			ui.Equipo.TextColor3 = self.colorA
		else
			ui.Equipo.TextColor3 = self.colorB
		end
	else
		ui.Equipo.Text = "No estás en un equipo  ·  " .. resumen
		ui.Equipo.TextColor3 = UITheme.Colores.TextoPrincipal
	end
	self:_RefrescarBotones()
	self:_RefrescarDinamico()
end

function FootballController:_RefrescarBotones()
	local ui = self.ui
	if not ui then
		return
	end
	local estado = self.estado or {}
	local enJuego = estado.Estado == "EnJuego"
	local mio = miEquipo()
	local esArbitro = estado.EsArbitro == true
	local punto = "● "
	if mio == "B" then
		UIBuilder.TextoBoton(ui.UnirseA, '<font color="' .. hex(self.colorA) .. '">' .. punto .. "</font>Cambiar a A")
	else
		UIBuilder.TextoBoton(ui.UnirseA, '<font color="' .. hex(self.colorA) .. '">' .. punto .. "</font>Unirse A")
	end
	if mio == "A" then
		UIBuilder.TextoBoton(ui.UnirseB, '<font color="' .. hex(self.colorB) .. '">' .. punto .. "</font>Cambiar a B")
	else
		UIBuilder.TextoBoton(ui.UnirseB, '<font color="' .. hex(self.colorB) .. '">' .. punto .. "</font>Unirse B")
	end
	ui.UnirseA.Visible = mio ~= "A"
	ui.UnirseB.Visible = mio ~= "B"
	ui.Iniciar.Visible = estado.PuedeIniciar == true and not enJuego
	ui.Reiniciar.Visible = esArbitro and enJuego
	ui.Finalizar.Visible = esArbitro and enJuego
	ui.Salir.Visible = mio ~= nil
	local visibles = {}
	for _, b in ipairs(ui.ListaBotones) do
		UIBuilder.Habilitar(b, not self.ocupado)
		if b.Visible then
			table.insert(visibles, b)
		end
	end
	UIBuilder.Encadenar(visibles, true)
end

-- Reloj, estado del partido, pista de controles y disponibilidad de la patada (4 Hz en la zona).
function FootballController:_RefrescarDinamico()
	local ui = self.ui
	if not ui then
		return
	end
	local estado = self.estado
	local ahora = servidorAhora()
	local texto = "Conectando con la cancha…"
	if estado then
		local cuentaAtras = numero(estado.AutoInicioServidor)
		if estado.Estado == "EnJuego" and numero(estado.InicioServidor) then
			local duracion = numero(estado.Duracion) or self.duracion
			local restante = math.max(0, duracion - (ahora - estado.InicioServidor))
			ui.Tiempo.Text = Format.Tiempo(restante)
			texto = "Partido en juego"
			if estado.Origen == "Arbitro" and estado.IniciadoPor then
				texto = texto .. " · árbitro: " .. tostring(estado.IniciadoPor)
			elseif estado.Origen == "Automatico" then
				texto = texto .. " · inicio automático"
			end
		else
			if estado.Estado == "Terminado" then
				ui.Tiempo.Text = "Final"
			else
				ui.Tiempo.Text = Format.Tiempo(numero(estado.Duracion) or self.duracion)
			end
			if cuentaAtras then
				texto = string.format("El partido empieza solo en %d s", math.max(0, math.ceil(cuentaAtras - ahora)))
			elseif estado.Estado == "Terminado" and typeof(estado.UltimoResultado) == "table" then
				local r = estado.UltimoResultado
				local goles = r.Goles or { A = 0, B = 0 }
				if r.Ganador == "A" or r.Ganador == "B" then
					texto = "Final: gana el " .. Format.Equipo(r.Ganador) .. " (" .. Format.Marcador(goles.A or 0, goles.B or 0) .. ")"
				else
					texto = "Final: empate (" .. Format.Marcador(goles.A or 0, goles.B or 0) .. ")"
				end
			elseif estado.PuedeIniciar then
				texto = "Cancha libre · forma los equipos e inicia el partido"
			elseif estado.ArbitroConectado then
				texto = "Cancha libre · un docente puede iniciar el partido"
			elseif estado.PermiteDeporte == false then
				texto = "Cancha libre · los partidos son en descanso y almuerzo"
			else
				texto = "Cancha libre · con jugadores en A y B el partido empieza solo"
			end
		end
	end
	ui.Estado.Text = texto

	-- Disponibilidad de la patada.
	local distancia = self:_DistanciaBalon()
	local enAlcance = distancia ~= nil and distancia <= self.distanciaPatada
	local enCooldown = os.clock() < self.cooldownHasta
	if ui.Patear then
		local habilitado = enAlcance and not enCooldown
		if habilitado ~= self.patearHabilitado then
			self.patearHabilitado = habilitado
			UIBuilder.Habilitar(ui.Patear, habilitado)
			ui.Patear.Selectable = false
		end
		if self.cargando then
			UIBuilder.TextoBoton(ui.Patear, "SOLTAR")
		elseif enAlcance then
			UIBuilder.TextoBoton(ui.Patear, "PATEAR")
		else
			UIBuilder.TextoBoton(ui.Patear, "ACÉRCATE")
		end
	end
	if os.clock() >= self.pistaHasta then
		ui.Pista.TextColor3 = UITheme.Colores.TextoSecundario
		if ui.Tactil then
			ui.Pista.Text = ""
			ui.Pista.Visible = false
		else
			ui.Pista.Visible = not self.minimizado
			local control = "E o clic en el balón"
			if UIBuilder.TieneMando() then
				control = "E / X (mando) o clic en el balón"
			end
			if enAlcance then
				ui.Pista.Text = control .. ": patear (mantén para más fuerza)"
			else
				ui.Pista.Text = string.format("Acércate al balón (a menos de %d studs) para patear", math.floor(self.distanciaPatada))
			end
		end
	end
end

-- Mensaje temporal en el panel.
function FootballController:_Pista(texto, nivel)
	local ui = self.ui
	if not ui then
		return
	end
	self.tokenPista = self.tokenPista + 1
	self.pistaHasta = os.clock() + self.DuracionPistaSeg
	ui.Pista.Text = tostring(texto or "")
	ui.Pista.Visible = not self.minimizado
	local color = UITheme.Colores.TextoPrincipal
	if nivel == "error" then
		color = UITheme.Colores.Error
	elseif nivel == "aviso" then
		color = UITheme.Colores.Aviso
	elseif nivel == "exito" then
		color = UITheme.Colores.Exito
	end
	ui.Pista.TextColor3 = color
end

-- Notificación por NotificationController (si existe) o pista en el panel.
function FootballController:_Notificar(texto, nivel, duracion)
	local Notificaciones = self.registro and self.registro.Get("NotificationController")
	if Notificaciones and typeof(Notificaciones.Notificar) == "function" then
		local ok = pcall(Notificaciones.Notificar, Notificaciones, texto, nivel or "info", duracion, { Titulo = "Fútbol" })
		if ok then
			return
		end
	end
	self:_Pista(texto, nivel)
end

---------------------------------------------------------------------------------------------------
-- Resaltado de equipos (Highlight local por atributo EquipoFutbol)
---------------------------------------------------------------------------------------------------
function FootballController:_ActualizarResaltados()
	local vistos = {}
	local cantidad = 0
	for _, otro in ipairs(Players:GetPlayers()) do
		local equipo = otro:GetAttribute(ATRIBUTO_EQUIPO)
		local personaje = otro.Character
		if (equipo == "A" or equipo == "B") and personaje and personaje.Parent and cantidad < self.MaxResaltados then
			cantidad = cantidad + 1
			vistos[otro] = true
			local resaltado = self.resaltados[otro]
			if not valida(resaltado) or resaltado.Parent ~= personaje then
				if resaltado then
					UIBuilder.Destruir(resaltado)
				end
				resaltado = Instance.new("Highlight")
				resaltado.Name = "ColegioRP_EquipoFutbol"
				resaltado.FillTransparency = 0.88
				resaltado.OutlineTransparency = 0.15
				resaltado.DepthMode = Enum.HighlightDepthMode.Occluded
				resaltado.Adornee = personaje
				resaltado.Parent = personaje
				self.resaltados[otro] = resaltado
			end
			local color = self.colorB
			if equipo == "A" then
				color = self.colorA
			end
			resaltado.OutlineColor = color
			resaltado.FillColor = color
		end
	end
	for otro, resaltado in pairs(self.resaltados) do
		if not vistos[otro] then
			UIBuilder.Destruir(resaltado)
			self.resaltados[otro] = nil
		end
	end
end

function FootballController:_QuitarResaltado(otro)
	local resaltado = self.resaltados[otro]
	if resaltado then
		UIBuilder.Destruir(resaltado)
		self.resaltados[otro] = nil
	end
end

function FootballController:_QuitarResaltados()
	for otro, resaltado in pairs(self.resaltados) do
		UIBuilder.Destruir(resaltado)
		self.resaltados[otro] = nil
	end
end

---------------------------------------------------------------------------------------------------
-- Patada
---------------------------------------------------------------------------------------------------
function FootballController:_ConectarEntrada()
	self.maid:GiveTask(UserInputService.InputBegan:Connect(function(entrada, procesado)
		if not self.enZona then
			return
		end
		local tecla = entrada.KeyCode
		if tecla == Enum.KeyCode.E or tecla == Enum.KeyCode.ButtonX then
			if procesado or UserInputService:GetFocusedTextBox() ~= nil then
				return
			end
			local fuente = "Teclado"
			if tecla == Enum.KeyCode.ButtonX then
				fuente = "Mando"
			end
			self:_IniciarCarga(fuente, entrada)
		elseif entrada.UserInputType == Enum.UserInputType.MouseButton1 then
			if procesado then
				return
			end
			if self:_ClicSobreBalon(entrada.Position) then
				self:_IniciarCarga("Clic", entrada)
			end
		end
	end))
	self.maid:GiveTask(UserInputService.InputEnded:Connect(function(entrada)
		local c = self.cargando
		if not c then
			return
		end
		if c.Fuente == "Teclado" and entrada.KeyCode == Enum.KeyCode.E then
			self:_SoltarCarga()
		elseif c.Fuente == "Mando" and entrada.KeyCode == Enum.KeyCode.ButtonX then
			self:_SoltarCarga()
		elseif c.Fuente == "Clic" and entrada.UserInputType == Enum.UserInputType.MouseButton1 then
			self:_SoltarCarga()
		elseif c.Fuente == "Tactil" and entrada == c.Input then
			self:_SoltarCarga()
		end
	end))
	-- Si la ventana pierde el foco, la carga se cancela sin patear.
	self.maid:GiveTask(UserInputService.WindowFocusReleased:Connect(function()
		self:_CancelarCarga()
	end))
end

-- ¿El clic (coordenadas de GUI) apunta al balón? Distancia del centro del balón al rayo de la cámara.
function FootballController:_ClicSobreBalon(posicion)
	local balon = self.balon
	local camara = workspace.CurrentCamera
	if not valida(balon) or not camara or typeof(posicion) ~= "Vector3" then
		return false
	end
	local ok, rayo = pcall(camara.ScreenPointToRay, camara, posicion.X, posicion.Y)
	if not ok or not rayo then
		return false
	end
	local origen = rayo.Origin
	local direccion = rayo.Direction.Unit
	local centro = balon.Position
	local t = (centro - origen):Dot(direccion)
	if t < 0 or t > self.DistanciaClicMax then
		return false
	end
	local cercano = origen + direccion * t
	return (centro - cercano).Magnitude <= self.RadioClicBalon
end

function FootballController:_FuerzaDe(segundos)
	local fraccion = math.clamp(segundos / math.max(0.05, self.CargaMaxSeg), 0, 1)
	return self.FuerzaMin + (self.FuerzaMaxima - self.FuerzaMin) * fraccion
end

function FootballController:_MostrarBarras(visible, valor, color)
	local ui = self.ui
	if not ui then
		return
	end
	ui.Barra.Frame.Visible = visible and not self.minimizado and not ui.Tactil
	if color then
		ui.Barra.Relleno.BackgroundColor3 = color
	end
	ui.Barra:Fijar(valor or 0, false)
	if ui.BarraTactil then
		ui.BarraTactil.Frame.Visible = visible
		ui.BarraTactil:Fijar(valor or 0, false)
	end
end

function FootballController:_IniciarCarga(fuente, entrada)
	if self.cargando or not self.enZona then
		return
	end
	if os.clock() < self.cooldownHasta then
		self:_Pista("Espera un momento antes de volver a patear.", "aviso")
		return
	end
	if not raizLocal() then
		return
	end
	local distancia = self:_DistanciaBalon()
	if not distancia then
		self:_Pista("No se encuentra el balón.", "aviso")
		return
	end
	if distancia > self.distanciaPatada then
		self:_Pista("Acércate al balón para patear.", "aviso")
		return
	end
	self.cargando = { Fuente = fuente, Inicio = os.clock(), Input = entrada }
	self:_MostrarBarras(true, 0, UITheme.Colores.Amarillo)
	self.maid.Carga = RunService.RenderStepped:Connect(function()
		local c = self.cargando
		if not c then
			return
		end
		local transcurrido = os.clock() - c.Inicio
		self:_MostrarBarras(true, math.clamp(transcurrido / math.max(0.05, self.CargaMaxSeg), 0, 1), nil)
		if transcurrido >= self.SoltarAutomaticoSeg then
			self:_SoltarCarga()
		end
	end)
	if self.ui and self.ui.Patear then
		UIBuilder.TextoBoton(self.ui.Patear, "SOLTAR")
	end
end

function FootballController:_CancelarCarga()
	self.cargando = nil
	if self.maid then
		self.maid.Carga = nil
	end
	self:_MostrarBarras(false, 0, nil)
end

function FootballController:_SoltarCarga()
	local c = self.cargando
	if not c then
		return
	end
	self.cargando = nil
	self.maid.Carga = nil
	local fuerza = self:_FuerzaDe(os.clock() - c.Inicio)
	self:_Patear(fuerza)
end

-- Dirección = (balón - jugador) horizontal mezclada 70/30 con la cámara (sin inclinación hacia el suelo).
function FootballController:_DireccionPatada(raiz, balon)
	local hacia = Vector3.new(balon.Position.X - raiz.Position.X, 0, balon.Position.Z - raiz.Position.Z)
	if hacia.Magnitude < 0.05 then
		local frente = raiz.CFrame.LookVector
		hacia = Vector3.new(frente.X, 0, frente.Z)
	end
	if hacia.Magnitude < 1e-3 then
		hacia = Vector3.new(0, 0, -1)
	end
	hacia = hacia.Unit
	local camara = workspace.CurrentCamera
	local mirada = hacia
	if camara then
		local look = camara.CFrame.LookVector
		local ajustada = Vector3.new(look.X, math.max(look.Y, 0), look.Z)
		if ajustada.Magnitude > 1e-3 then
			mirada = ajustada.Unit
		end
	end
	local direccion = hacia * self.MezclaBalon + mirada * (1 - self.MezclaBalon) + Vector3.new(0, self.ElevacionBase, 0)
	if direccion.Magnitude < 1e-3 then
		direccion = hacia
	end
	return direccion.Unit
end

function FootballController:_Patear(fuerza)
	local raiz = raizLocal()
	local balon = self.balon
	self:_MostrarBarras(false, 0, nil)
	if not raiz or not valida(balon) then
		return
	end
	if (raiz.Position - balon.Position).Magnitude > self.distanciaPatada then
		self:_Pista("El balón se alejó: acércate de nuevo.", "aviso")
		return
	end
	local direccion = self:_DireccionPatada(raiz, balon)
	fuerza = math.clamp(fuerza, 0, 1)
	task.spawn(function()
		local enviado = Net.Disparar("FootballKick", { Direccion = direccion, Fuerza = fuerza })
		if not enviado then
			self:_Pista("No se pudo enviar la patada.", "error")
		end
	end)
	-- Cooldown local: la patada queda deshabilitada mientras dure.
	local espera = self.cooldown + self.MargenCooldownSeg
	self.cooldownHasta = os.clock() + espera
	self.patearHabilitado = nil
	self:_MostrarBarras(true, 1, UITheme.Colores.Desactivado)
	pcall(self._RefrescarDinamico, self)
	task.delay(espera, function()
		if not self.cargando then
			self:_MostrarBarras(false, 0, nil)
		end
		self.patearHabilitado = nil
		pcall(self._RefrescarDinamico, self)
	end)
end

---------------------------------------------------------------------------------------------------
-- Acciones de equipo / partido
---------------------------------------------------------------------------------------------------
local TEXTOS_ACCION = {
	Unirse = "Te uniste al equipo",
	Salir = "Saliste del equipo.",
	Reiniciar = "Partido reiniciado.",
	Finalizar = "Partido finalizado.",
}

function FootballController:_Accion(accion, equipo, silencioso)
	if self.ocupado then
		return
	end
	self.ocupado = true
	self:_RefrescarBotones()
	task.spawn(function()
		local ok, respuesta = Net.Invocar("FootballAction", { Accion = accion, Equipo = equipo })
		self.ocupado = false
		if ok then
			local datos = respuesta and respuesta.datos
			if typeof(datos) == "table" then
				self:_AplicarEstado(datos)
			end
			if not silencioso and TEXTOS_ACCION[accion] then
				if accion == "Unirse" then
					local mio = miEquipo() or (typeof(datos) == "table" and datos.MiEquipo) or equipo
					self:_Pista(TEXTOS_ACCION.Unirse .. " " .. tostring(mio or "") .. ".", "exito")
				else
					self:_Pista(TEXTOS_ACCION[accion], "exito")
				end
			end
		elseif not silencioso then
			self:_Pista(UIBuilder.MensajeError(respuesta and respuesta.error), "error")
		end
		self:_Refrescar()
	end)
end

function FootballController:_AplicarEstado(estado)
	if typeof(estado) ~= "table" then
		return
	end
	self.estado = estado
	self.estadoRecibidoClock = os.clock()
	local distancia = numero(estado.DistanciaPatada)
	if distancia and distancia > 0 then
		self.distanciaPatada = distancia
	end
	local cooldown = numero(estado.CooldownPatada)
	if cooldown and cooldown > 0 then
		self.cooldown = cooldown
	end
	if typeof(estado.ZonaId) == "string" and Zones.Zona(estado.ZonaId) then
		self.zonaId = estado.ZonaId
	end
	self:_Refrescar()
end

---------------------------------------------------------------------------------------------------
-- Eventos del servidor (EventoCliente, Tipo "Futbol")
---------------------------------------------------------------------------------------------------
function FootballController:_AlEvento(datos)
	local sub = datos.Sub
	if sub == "Estado" then
		self:_AplicarEstado(datos.Estado)
	elseif sub == "Gol" then
		if self.estado and typeof(datos.Marcador) == "table" and datos.Amistoso ~= true then
			self.estado.Marcador = datos.Marcador
		end
		self:_EfectoGol(datos)
		self:_Refrescar()
	elseif sub == "Inicio" or sub == "Reinicio" then
		if self.estado then
			self.estado.Estado = "EnJuego"
			self.estado.Marcador = { A = 0, B = 0 }
			self.estado.InicioServidor = numero(datos.InicioServidor) or servidorAhora()
			self.estado.Duracion = numero(datos.Duracion) or self.duracion
			self.estado.AutoInicioServidor = nil
		end
		if sub == "Inicio" then
			self:_Notificar("¡Comienza el partido! Duración: " .. Format.Duracion(numero(datos.Duracion) or self.duracion) .. ".", "exito", 4)
			-- En teléfonos el panel se compacta durante el partido para dejar ver la cancha.
			if self.ui and self.ui.Tactil and UIBuilder.EsEstrecho() and not self.minimizado then
				self.autoMinimizado = true
				self:_Minimizar(true)
			end
		else
			self:_Pista("El árbitro reinició el partido.", "info")
		end
		self:_Refrescar()
	elseif sub == "Fin" then
		local marcador = typeof(datos.Marcador) == "table" and datos.Marcador or { A = 0, B = 0 }
		if self.estado then
			self.estado.Estado = "Terminado"
			self.estado.Marcador = marcador
			self.estado.UltimoResultado = { Goles = marcador, Ganador = datos.Ganador, Motivo = datos.Motivo }
		end
		local texto = "Final del partido: "
		if datos.Ganador == "A" or datos.Ganador == "B" then
			texto = texto .. "gana el " .. Format.Equipo(datos.Ganador)
		else
			texto = texto .. "empate"
		end
		texto = texto .. " (" .. Format.Marcador(marcador.A or 0, marcador.B or 0) .. ")."
		if typeof(datos.Motivo) == "string" and datos.Motivo ~= "" then
			texto = texto .. " " .. datos.Motivo .. "."
		end
		self:_Notificar(texto, "info", 6)
		if self.autoMinimizado then
			self.autoMinimizado = false
			self:_Minimizar(false)
		end
		self:_Refrescar()
	elseif sub == "PatadaRechazada" then
		self:_Pista(typeof(datos.Texto) == "string" and datos.Texto or "Patada no válida.", "aviso")
	elseif sub == "Rescate" then
		self:_Pista("El balón volvió al centro de la cancha.", "info")
	elseif sub == "Saque" then
		self:_Pista("¡Saque desde el centro!", "info")
	end
end

-- Efecto local de gol: rótulo animado (respeta MovimientoReducido) y sonido Config.Sonidos.Gol si existe.
function FootballController:_EfectoGol(datos)
	local ui = self.ui
	if not ui or not self.enZona then
		return
	end
	self.tokenGol = self.tokenGol + 1
	local token = self.tokenGol
	local equipo = datos.Equipo
	local color = UITheme.Colores.Amarillo
	if equipo == "A" then
		color = self.colorA
	elseif equipo == "B" then
		color = self.colorB
	end
	if datos.Amistoso then
		ui.GolTitulo.Text = "¡GOL! (amistoso)"
	else
		ui.GolTitulo.Text = "¡GOL!"
	end
	local detalle = Format.Equipo(equipo)
	if typeof(datos.Autor) == "string" and datos.Autor ~= "" then
		detalle = detalle .. " · " .. datos.Autor
	end
	if datos.Autogol then
		detalle = detalle .. " (autogol)"
	end
	if datos.Amistoso ~= true and typeof(datos.Marcador) == "table" then
		detalle = detalle .. "  ·  " .. Format.Marcador(datos.Marcador.A or 0, datos.Marcador.B or 0)
	end
	ui.GolDetalle.Text = detalle
	ui.GolBorde.Color = color
	ui.GolMarco.Visible = true
	UIBuilder.Aparecer(ui.GolMarco)
	UIBuilder.Sonido("Gol", 0.6)
	task.delay(self.DuracionGolSeg, function()
		if self.tokenGol == token and self.ui and valida(self.ui.GolMarco) then
			UIBuilder.Desaparecer(self.ui.GolMarco)
		end
	end)
end

return FootballController
