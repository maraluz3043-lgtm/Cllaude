--[[
	Ruta en el Explorer: StarterPlayer.StarterPlayerScripts.ColegioRP.Controllers.HUDController
	Tipo: ModuleScript
	HUD del jugador: hora real del dispositivo (aprox., 12/24 h), hora escolar y estado de la jornada interpolados
	con workspace:GetServerTimeNow(), cargo, salón, próxima actividad, avisos oficiales, saldo, botones (Menú,
	Cuaderno, Panel de cargo), acciones contextuales y minimizar. Solo renderiza: el servidor es la autoridad.
]]

local Players = game:GetService("Players")

local HUDController = {}
HUDController.Nombre = "HUDController"
HUDController.MaxAvisos = 3 -- Avisos oficiales visibles en el HUD.

local UIBuilder, UITheme, Net, Maid, Format, RoleDefinitions, TimetableDefinitions, MapaLogico, Config

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

local function numero(valor)
	local n = tonumber(valor)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return nil
	end
	return n
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

-- Hora del servidor sincronizada (segundos Unix con decimales); respaldo: reloj local.
local function ahoraServidor()
	local ok, valor = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if ok and typeof(valor) == "number" then
		return valor
	end
	return os.time()
end

-- Acepta segundos del día (número) o "HH:MM" (texto); nil si no es válido.
local function segundosDeHora(valor)
	local n = numero(valor)
	if n then
		return n
	end
	if typeof(valor) == "string" then
		return TimetableDefinitions.HHMMASegundos(valor)
	end
	return nil
end

-- Segundos hasta el siguiente cambio de segundo del reloj (para refrescar en el momento justo).
local function esperaAlSiguienteSegundo()
	local ok, ms = pcall(function()
		return DateTime.now().UnixTimestampMillis
	end)
	if ok and typeof(ms) == "number" then
		return math.max(0.05, (1000 - (ms % 1000)) / 1000 + 0.02)
	end
	return 1
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function HUDController:Init(registro)
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
	TimetableDefinitions = requerir(Shared, "TimetableDefinitions")
	MapaLogico = requerir(Shared, "MapaLogico")
	Net = requerir(Util, "Net")
	Maid = requerir(Util, "Maid")
	Format = requerir(Util, "Format")

	self.maid = Maid.new()
	self.jornada = nil
	self.progresoCongelado = nil
	self.cargo = player:GetAttribute("Cargo")
	self.salon = player:GetAttribute("Salon")
	self.saldo = nil
	self.avisos = {}
	self.acciones = {}
	self.ordenAcciones = 0
	self.minimizado = false
	self.visible = true
	self.activo = true
	self:_Construir()
	self:_RefrescarTodo()
end

function HUDController:Start()
	-- Atributos replicados del jugador (los fija el servidor).
	self.maid:GiveTask(player:GetAttributeChangedSignal("Cargo"):Connect(function()
		self:FijarCargo(player:GetAttribute("Cargo"), nil)
	end))
	self.maid:GiveTask(player:GetAttributeChangedSignal("Salon"):Connect(function()
		local salon = player:GetAttribute("Salon")
		if salon == nil then
			salon = false
		end
		self:FijarCargo(nil, salon)
	end))
	self.maid:GiveTask(player:GetAttributeChangedSignal("Atendido"):Connect(function()
		self:_RefrescarAtendido()
	end))

	-- Reloj: una actualización por segundo (no por fotograma).
	self.maid:GiveTask(task.spawn(function()
		while self.activo do
			local ok, err = pcall(self._ActualizarReloj, self)
			if not ok then
				warn("[ColegioRP] HUDController: " .. tostring(err))
			end
			task.wait(esperaAlSiguienteSegundo())
		end
	end))

	-- Canal servidor -> cliente.
	task.spawn(function()
		local remoto = Net.Evento("EventoCliente")
		if not remoto then
			warn("[ColegioRP] HUDController: EventoCliente no disponible; el HUD no recibirá actualizaciones.")
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
			if carga.Tipo == "Jornada" then
				ok, err = pcall(self.FijarEstado, self, datos)
			elseif carga.Tipo == "Rol" then
				ok, err = pcall(self._AplicarRol, self, datos)
			elseif carga.Tipo == "Economia" then
				ok, err = pcall(self._FijarSaldo, self, datos.Saldo)
			elseif carga.Tipo == "Aviso" then
				ok, err = pcall(self._AgregarAviso, self, datos)
			end
			if not ok then
				warn("[ColegioRP] HUDController: " .. tostring(err))
			end
		end))
	end)

	-- Snapshot inicial (con reintentos si el servidor todavía no está listo o se superó el límite).
	task.spawn(function()
		local esperas = { 0, 3, 6 }
		for intento, espera in ipairs(esperas) do
			if not self.activo then
				return
			end
			if espera > 0 then
				task.wait(espera)
			end
			local ok, respuesta = Net.Invocar("StateSnapshot", {})
			if ok and typeof(respuesta.datos) == "table" then
				self.snapshot = respuesta.datos
				local okAplicar, err = pcall(self._AplicarSnapshot, self, respuesta.datos)
				if not okAplicar then
					warn("[ColegioRP] HUDController: " .. tostring(err))
				end
				return
			end
			if intento == #esperas then
				warn("[ColegioRP] HUDController: no se pudo obtener StateSnapshot: " .. tostring(respuesta and respuesta.error))
			end
		end
	end)
end

-- Libera conexiones, el hilo del reloj y la pantalla.
function HUDController:Destruir()
	self.activo = false
	if self.maid then
		self.maid:DoCleaning()
	end
	UIBuilder.Destruir(self.gui)
end

---------------------------------------------------------------------------------------------------
-- Construcción de la interfaz
---------------------------------------------------------------------------------------------------
local function etiqueta(parent, contenido, orden, props)
	props = props or {}
	props.LayoutOrder = orden
	return UIBuilder.Texto(parent, contenido, props)
end

function HUDController:_Construir()
	local gui = UIBuilder.Pantalla("HUD", (UITheme.Capas and UITheme.Capas.HUD) or 10)
	self.gui = gui
	self.maid:GiveTask(gui)
	local contenido = UIBuilder.Contenedor(gui, { Nombre = "Contenido" })
	self.contenido = contenido
	local estrecho = UIBuilder.EsEstrecho()
	local Colores = UITheme.Colores

	-----------------------------------------------------------------------------------------------
	-- Esquina superior izquierda: horas, estado, cargo, salón, saldo y avisos
	-----------------------------------------------------------------------------------------------
	local info = Instance.new("Frame")
	info.Name = "Info"
	info.BackgroundColor3 = Colores.GrisPanel
	info.BackgroundTransparency = 0.2
	info.BorderSizePixel = 0
	info.Size = UDim2.new(0, estrecho and 214 or 262, 0, 0)
	info.AutomaticSize = Enum.AutomaticSize.Y
	info.Position = UDim2.new(0, 0, 0, 0)
	UIBuilder.Esquinas(info, UITheme.Radio)
	UIBuilder.Borde(info, Colores.Borde, 1, 0.3)
	UIBuilder.Relleno(info, 6, 8, 10, 6)
	UIBuilder.Disposicion(info, { Espaciado = 2 })
	info.Parent = contenido
	self.info = info

	local altoCabecera = 28
	if UIBuilder.EsTactil() then
		altoCabecera = UIBuilder.AltoBoton()
	end
	local cabecera = UIBuilder.Marco(info, { Alto = altoCabecera, Nombre = "Cabecera", LayoutOrder = 1 })
	UIBuilder.Texto(cabecera, mayusculas(Config.NombreCorto or "Colegio Jean Piaget"), {
		Nombre = "Colegio", Tamano = "Etiqueta", Fuente = "Titulo", Color = Colores.TextoSecundario,
		AutoAlto = false, Ajustar = false, Truncar = true, AlineacionY = Enum.TextYAlignment.Center,
		Size = UDim2.new(1, -44, 1, 0),
	})
	self.botonMinimizar = UIBuilder.Boton(cabecera, "–", function()
		self:Minimizar(not self.minimizado)
	end, {
		Estilo = "Fantasma", Ancho = 40, Alto = altoCabecera, Nombre = "Minimizar", Tamano = "Subtitulo",
		Position = UDim2.new(1, 4, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5),
	})

	self.lblHoraReal = etiqueta(info, "Hora real: --:-- (aprox.)", 2, { Tamano = "Pequeno", Color = Colores.TextoSecundario, Nombre = "HoraReal" })
	self.sepHora = UIBuilder.Espacio(info, 4, 3)
	self.lblHoraEscolar = etiqueta(info, "Hora escolar: --:--", 4, { Tamano = "Subtitulo", Fuente = "Titulo", Nombre = "HoraEscolar" })
	self.lblEstado = etiqueta(info, "Estado: esperando datos…", 5, { Tamano = "Pequeno", Nombre = "Estado" })
	self.lblProxima = etiqueta(info, "Próxima actividad: —", 6, { Tamano = "Pequeno", Color = Colores.TextoSecundario, Nombre = "Proxima" })
	self.sepDatos = UIBuilder.Separador(info, { LayoutOrder = 7, Color = Colores.Borde })
	self.lblCargo = etiqueta(info, "Cargo: —", 8, { Tamano = "Pequeno", Nombre = "Cargo" })
	self.lblSalon = etiqueta(info, "Salón: sin asignar", 9, { Tamano = "Pequeno", Nombre = "Salon" })
	self.lblSaldo = etiqueta(info, "Saldo: —", 10, { Tamano = "Pequeno", Color = Colores.Amarillo, Nombre = "Saldo" })
	self.etqAtendido = UIBuilder.Etiqueta(info, "Atendido en enfermería", Colores.Verde, { LayoutOrder = 11, Nombre = "Atendido", Visible = false })

	local avisos = UIBuilder.Marco(info, { Nombre = "Avisos", AutoAlto = true, LayoutOrder = 12 })
	UIBuilder.Disposicion(avisos, { Espaciado = 2 })
	avisos.Visible = false
	UIBuilder.Separador(avisos, { LayoutOrder = 0, Color = Colores.Borde })
	UIBuilder.Texto(avisos, "AVISOS OFICIALES", { Tamano = "Etiqueta", Fuente = "Titulo", Color = Colores.Amarillo, LayoutOrder = 1, Nombre = "TituloAvisos" })
	self.marcoAvisos = avisos
	self.lblAvisos = {}
	for i = 1, self.MaxAvisos do
		self.lblAvisos[i] = UIBuilder.Texto(avisos, "", { Tamano = "Pequeno", LayoutOrder = 1 + i, Nombre = "Aviso" .. i, Visible = false })
	end

	-- Filas que se ocultan al minimizar (quedan la hora escolar y el estado).
	self.detalles = { self.lblHoraReal, self.sepHora, self.lblProxima, self.sepDatos, self.lblCargo, self.lblSalon, self.lblSaldo }

	-----------------------------------------------------------------------------------------------
	-- Esquina superior derecha: botones
	-----------------------------------------------------------------------------------------------
	local anchoBoton = estrecho and 120 or 148
	local botones = UIBuilder.Marco(contenido, {
		Nombre = "Botones", AutoAlto = true,
		Size = UDim2.new(0, anchoBoton, 0, 0),
		Position = UDim2.new(1, 0, 0, 0), AnchorPoint = Vector2.new(1, 0),
	})
	UIBuilder.Disposicion(botones, { Espaciado = 6, Alineacion = Enum.HorizontalAlignment.Right })
	self.botonMenu = UIBuilder.Boton(botones, "Menú", function()
		self:_AbrirMenu()
	end, { Estilo = "Primario", Icono = "☰", Ancho = anchoBoton, LayoutOrder = 1, Nombre = "Menu" })
	self.botonCuaderno = UIBuilder.Boton(botones, "Cuaderno", function()
		self:_AbrirCuaderno()
	end, { Estilo = "Secundario", Ancho = anchoBoton, LayoutOrder = 2, Nombre = "Cuaderno" })
	self.botonPanel = UIBuilder.Boton(botones, "Panel de cargo", function()
		self:_AbrirPanelCargo()
	end, { Estilo = "Secundario", Ancho = anchoBoton, LayoutOrder = 3, Nombre = "PanelCargo", Visible = false })
	UIBuilder.Encadenar({ self.botonMenu, self.botonCuaderno, self.botonPanel })

	-----------------------------------------------------------------------------------------------
	-- Inferior centro: acciones contextuales (por encima de los controles táctiles)
	-----------------------------------------------------------------------------------------------
	local filaAcciones = UIBuilder.Marco(contenido, {
		Nombre = "Acciones", Alto = UIBuilder.AltoBoton(),
		Position = UDim2.new(0.5, 0, 1, 0), AnchorPoint = Vector2.new(0.5, 1),
	})
	UIBuilder.Disposicion(filaAcciones, { Horizontal = true, Espaciado = 8, Alineacion = Enum.HorizontalAlignment.Center })
	filaAcciones.Visible = false
	self.filaAcciones = filaAcciones
end

---------------------------------------------------------------------------------------------------
-- Refrescos de texto
---------------------------------------------------------------------------------------------------
function HUDController:_Ajustes()
	local Settings = self.registro and self.registro.Get("SettingsController")
	if Settings and typeof(Settings.Ajustes) == "function" then
		local ok, ajustes = pcall(Settings.Ajustes, Settings)
		if ok and typeof(ajustes) == "table" then
			return ajustes
		end
	end
	return {}
end

function HUDController:_Formato12()
	local formato = tonumber(self:_Ajustes().FormatoHora)
	return formato == 12
end

-- Calcula hora escolar (segundos del día), segundos restantes del periodo y progreso a partir del snapshot.
function HUDController:_CalcularJornada()
	local j = self.jornada
	if typeof(j) ~= "table" or typeof(j.Estado) ~= "string" then
		return nil
	end
	local inicio = segundosDeHora(j.HoraEscolarInicio) or TimetableDefinitions.HoraEscolarSegundos(j.Estado) or 0
	local fin = segundosDeHora(j.HoraEscolarFin) or TimetableDefinitions.HoraEscolarFinSegundos(j.Estado) or inicio
	local duracion = numero(j.Duracion)
	if duracion == nil then
		local periodo = TimetableDefinitions.Periodo(j.Estado)
		duracion = periodo and periodo.Duracion or 0
	end
	local progreso = 0
	local transcurrido = 0
	if j.Pausada == true then
		progreso = self.progresoCongelado or 0
		transcurrido = progreso * duracion
	else
		local inicioServidor = numero(j.InicioServidor)
		if inicioServidor then
			transcurrido = ahoraServidor() - inicioServidor
		end
		if duracion > 0 then
			progreso = transcurrido / duracion
		end
	end
	progreso = math.clamp(progreso, 0, 1)
	local hora = inicio + (fin - inicio) * progreso
	local restante = math.max(0, duracion - transcurrido)
	return hora, restante, progreso
end

function HUDController:_ActualizarReloj()
	if not self.lblHoraReal or self.lblHoraReal.Parent == nil then
		return
	end
	local formato12 = self:_Formato12()
	local t = os.date("*t")
	local segundosDia = 0
	if typeof(t) == "table" then
		segundosDia = (t.hour or 0) * 3600 + (t.min or 0) * 60
	end
	self.lblHoraReal.Text = "Hora real: " .. Format.HoraHHMM(segundosDia, formato12) .. " (aprox.)"

	local hora, restante = self:_CalcularJornada()
	if hora == nil then
		self.lblHoraEscolar.Text = "Hora escolar: --:--"
		self.lblEstado.Text = "Estado: esperando datos de la jornada…"
		return
	end
	local j = self.jornada
	self.lblHoraEscolar.Text = "Hora escolar: " .. Format.HoraHHMM(hora, formato12)
	local nombre = j.Nombre
	if typeof(nombre) ~= "string" or nombre == "" then
		nombre = TimetableDefinitions.Nombre(j.Estado)
	end
	local partes = { "Estado: " .. nombre }
	if typeof(j.Materia) == "string" and j.Materia ~= "" then
		table.insert(partes, " · " .. TimetableDefinitions.NombreMateria(j.Materia))
	end
	if j.Pausada == true then
		-- SchoolDayService marca Pausada también mientras espera el inicio (EnEspera / MotivoPausa "espera_inicio").
		if j.EnEspera == true or j.MotivoPausa == "espera_inicio" then
			table.insert(partes, " (esperando inicio)")
		else
			table.insert(partes, " (en pausa)")
		end
	else
		table.insert(partes, " (" .. Format.Tiempo(restante) .. ")")
	end
	if j.Modo == "Manual" then
		table.insert(partes, " · manual")
	end
	self.lblEstado.Text = table.concat(partes)
end

function HUDController:_RefrescarProxima()
	local j = self.jornada
	local proximo = nil
	if typeof(j) == "table" then
		proximo = j.ProximoNombre
		if (typeof(proximo) ~= "string" or proximo == "") and typeof(j.Estado) == "string" then
			proximo = TimetableDefinitions.Nombre(TimetableDefinitions.Siguiente(j.Estado))
		end
	end
	if typeof(proximo) ~= "string" or proximo == "" then
		proximo = "—"
	end
	self.lblProxima.Text = "Próxima actividad: " .. Format.Truncar(proximo, 40)
end

function HUDController:_RefrescarCargo()
	local cargo = self.cargo
	if typeof(cargo) == "string" and cargo ~= "" then
		self.lblCargo.Text = "Cargo: " .. RoleDefinitions.Nombre(cargo)
	else
		self.lblCargo.Text = "Cargo: sin elegir"
	end
	local salon = self.salon
	if typeof(salon) == "string" and salon ~= "" then
		local zona = MapaLogico.Zonas and MapaLogico.Zonas[salon]
		local textoSalon = salon
		if zona and typeof(zona.Nombre) == "string" and zona.Nombre ~= salon then
			textoSalon = salon .. " · " .. zona.Nombre
		end
		self.lblSalon.Text = "Salón: " .. Format.Truncar(textoSalon, 48)
	else
		self.lblSalon.Text = "Salón: sin asignar"
	end
	-- El panel de cargo solo aparece para cargos distintos de Estudiante.
	local esPersonal = RoleDefinitions.Existe(cargo) and cargo ~= "Estudiante"
	if self.botonPanel then
		self.botonPanel.Visible = esPersonal == true
	end
end

function HUDController:_RefrescarSaldo()
	if self.saldo == nil then
		self.lblSaldo.Text = "Saldo: —"
	else
		self.lblSaldo.Text = "Saldo: " .. Format.Moneda(self.saldo)
	end
end

function HUDController:_RefrescarAtendido()
	if self.etqAtendido then
		self.etqAtendido.Visible = player:GetAttribute("Atendido") == true
	end
end

function HUDController:_RefrescarAvisos()
	local total = #self.avisos
	for i = 1, self.MaxAvisos do
		local lbl = self.lblAvisos[i]
		-- El más reciente primero.
		local aviso = self.avisos[total - i + 1]
		if aviso then
			local firma = ""
			if aviso.Cargo ~= "" or aviso.Autor ~= "" then
				firma = "[" .. Format.Recortar(aviso.Cargo .. " " .. aviso.Autor) .. "] "
			end
			lbl.Text = "• " .. firma .. aviso.Texto
			lbl.Visible = true
		else
			lbl.Text = ""
			lbl.Visible = false
		end
	end
	self.marcoAvisos.Visible = total > 0 and not self.minimizado
end

function HUDController:_RefrescarTodo()
	pcall(self._ActualizarReloj, self)
	self:_RefrescarProxima()
	self:_RefrescarCargo()
	self:_RefrescarSaldo()
	self:_RefrescarAtendido()
	self:_RefrescarAvisos()
end

---------------------------------------------------------------------------------------------------
-- Datos del servidor
---------------------------------------------------------------------------------------------------
function HUDController:_AplicarSnapshot(datos)
	if typeof(datos.Jornada) == "table" then
		self:FijarEstado(datos.Jornada)
	end
	if typeof(datos.Rol) == "table" then
		self:_AplicarRol(datos.Rol)
	elseif typeof(datos.Rol) == "string" then
		self:FijarCargo(datos.Rol, nil)
	end
	if typeof(datos.Economia) == "table" then
		self:_FijarSaldo(datos.Economia.Saldo)
	end
	if typeof(datos.Anuncios) == "table" then
		local inicio = math.max(1, #datos.Anuncios - self.MaxAvisos + 1)
		for i = inicio, #datos.Anuncios do
			local anuncio = datos.Anuncios[i]
			if typeof(anuncio) == "table" then
				self:_AgregarAviso(anuncio, true)
			end
		end
		self:_RefrescarAvisos()
	end
end

function HUDController:_AplicarRol(datos)
	local salon = datos.Salon
	if salon == nil then
		salon = player:GetAttribute("Salon")
	end
	if salon == nil then
		salon = false
	end
	self:FijarCargo(datos.Cargo, salon)
end

function HUDController:_FijarSaldo(saldo)
	local n = numero(saldo)
	if n == nil then
		return
	end
	self.saldo = math.floor(n)
	self:_RefrescarSaldo()
end

function HUDController:_AgregarAviso(datos, sinRefrescar)
	if typeof(datos) ~= "table" or typeof(datos.Texto) ~= "string" or datos.Texto == "" then
		return
	end
	local cargo = ""
	if typeof(datos.Cargo) == "string" and datos.Cargo ~= "" then
		if RoleDefinitions.Existe(datos.Cargo) then
			cargo = RoleDefinitions.Nombre(datos.Cargo)
		else
			cargo = Format.Truncar(datos.Cargo, 24)
		end
	end
	local autor = ""
	if typeof(datos.Autor) == "string" then
		autor = Format.Truncar(datos.Autor, 24)
	end
	table.insert(self.avisos, {
		Texto = Format.Truncar(datos.Texto, 100),
		Cargo = cargo,
		Autor = autor,
		Alcance = datos.Alcance,
	})
	while #self.avisos > self.MaxAvisos do
		table.remove(self.avisos, 1)
	end
	if not sinRefrescar then
		self:_RefrescarAvisos()
	end
end

---------------------------------------------------------------------------------------------------
-- Botones
---------------------------------------------------------------------------------------------------
function HUDController:_Notificar(texto, nivel)
	local Notificaciones = self.registro and self.registro.Get("NotificationController")
	if Notificaciones and typeof(Notificaciones.Notificar) == "function" then
		pcall(Notificaciones.Notificar, Notificaciones, texto, nivel)
	end
end

function HUDController:_AbrirMenu()
	local Menu = self.registro.Get("MenuController")
	if Menu and typeof(Menu.Abrir) == "function" then
		Menu:Abrir()
	else
		self:_Notificar("El menú principal no está disponible.", "aviso")
	end
end

function HUDController:_AbrirCuaderno()
	local Aula = self.registro.Get("ClassroomController")
	if Aula and typeof(Aula.AbrirCuaderno) == "function" then
		Aula:AbrirCuaderno()
	else
		self:_Notificar("Disponible en el aula", "info")
	end
end

function HUDController:_AbrirPanelCargo()
	local Staff = self.registro.Get("StaffController")
	if Staff and typeof(Staff.Abrir) == "function" then
		Staff:Abrir()
	else
		self:_Notificar("El panel de cargo no está disponible todavía.", "aviso")
	end
end

---------------------------------------------------------------------------------------------------
-- API pública
---------------------------------------------------------------------------------------------------

-- Aplica un snapshot de jornada { Estado, Nombre, Indice, InicioServidor, Duracion, HoraEscolarInicio,
-- HoraEscolarFin, Materia, Pausada, ProximoNombre, Modo }. Si Pausada, el reloj escolar no avanza.
function HUDController:FijarEstado(snapshot)
	if typeof(snapshot) ~= "table" or typeof(snapshot.Estado) ~= "string" then
		return
	end
	-- Descarta snapshots más antiguos que el último aplicado (p. ej. la respuesta de StateSnapshot que llega
	-- después de un evento "Jornada" más reciente): evita saltos hacia atrás del reloj escolar.
	local horaSnapshot = numero(snapshot.HoraServidor)
	if horaSnapshot and self.horaUltimaJornada and horaSnapshot < self.horaUltimaJornada then
		return
	end
	if horaSnapshot then
		self.horaUltimaJornada = horaSnapshot
	end
	local copia = {}
	for clave, valor in pairs(snapshot) do
		copia[clave] = valor
	end
	self.jornada = copia
	self.progresoCongelado = nil
	if copia.Pausada == true then
		local duracion = numero(copia.Duracion) or 0
		local transcurrido = numero(copia.Transcurrido)
		if transcurrido == nil then
			local inicioServidor = numero(copia.InicioServidor)
			transcurrido = inicioServidor and (ahoraServidor() - inicioServidor) or 0
		end
		if duracion > 0 then
			self.progresoCongelado = math.clamp(transcurrido / duracion, 0, 1)
		else
			self.progresoCongelado = 0
		end
	end
	self:_RefrescarProxima()
	pcall(self._ActualizarReloj, self)
end

-- Fija el cargo (id de RoleDefinitions) y el salón (id de zona de MapaLogico). nil conserva el valor;
-- false o "" en salon lo borra.
function HUDController:FijarCargo(cargo, salon)
	if typeof(cargo) == "string" and cargo ~= "" then
		self.cargo = cargo
	end
	if salon == false or salon == "" then
		self.salon = nil
	elseif typeof(salon) == "string" then
		self.salon = salon
	end
	self:_RefrescarCargo()
end

-- Añade (callback = función) o quita (callback = nil) un botón de acción contextual en la fila inferior.
-- Devuelve el botón creado (o nil al quitar).
function HUDController:AccionContextual(nombre, callback)
	if typeof(nombre) ~= "string" or nombre == "" then
		return nil
	end
	local existente = self.acciones[nombre]
	if existente then
		self.acciones[nombre] = nil
		UIBuilder.Destruir(existente)
	end
	local resultado = nil
	if typeof(callback) == "function" then
		self.ordenAcciones = self.ordenAcciones + 1
		local longitud = utf8.len(nombre) or #nombre
		local ancho = math.clamp(longitud * 9 + 40, 110, 260)
		resultado = UIBuilder.Boton(self.filaAcciones, nombre, function()
			callback()
		end, { Estilo = "Primario", Ancho = ancho, LayoutOrder = self.ordenAcciones, Nombre = "Accion_" .. nombre })
		self.acciones[nombre] = resultado
	end
	local hay = next(self.acciones) ~= nil
	self.filaAcciones.Visible = hay
	return resultado
end

-- Muestra u oculta todo el HUD.
function HUDController:Visible(visible)
	self.visible = visible ~= false
	if self.gui and self.gui.Parent then
		self.gui.Enabled = self.visible
	end
	if not self.visible then
		UIBuilder.Desenfocar(self.gui)
	end
end

-- ¿El HUD está visible?
function HUDController:EstaVisible()
	return self.visible == true
end

-- Minimiza (true) o expande (false) el panel de información.
function HUDController:Minimizar(minimizado)
	self.minimizado = minimizado == true
	for _, fila in ipairs(self.detalles) do
		if fila and fila.Parent then
			fila.Visible = not self.minimizado
		end
	end
	self:_RefrescarAvisos()
	if self.minimizado then
		UIBuilder.TextoBoton(self.botonMinimizar, "+")
	else
		UIBuilder.TextoBoton(self.botonMinimizar, "–")
	end
end

-- Último snapshot completo recibido de StateSnapshot (o nil).
function HUDController:Snapshot()
	return self.snapshot
end

return HUDController
