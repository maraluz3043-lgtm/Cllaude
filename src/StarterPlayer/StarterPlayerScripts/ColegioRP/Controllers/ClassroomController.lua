--[[
	Ruta en el Explorer: StarterPlayer.StarterPlayerScripts.ColegioRP.Controllers.ClassroomController
	Tipo: ModuleScript
	Panel del aula (docs/ARQUITECTURA.md §7). Docente: abrir/cerrar sesión, tema, aviso, asistencia con la lista
	de sentados y de pie, actividades de texto u opciones (tiempo y opción correcta), cierre, respuestas,
	calificación privada, publicación de resultados, manos levantadas, invitación y revocación del tablero, revisión
	de cuadernos compartidos. Estudiante: Cuaderno (páginas, materia, autoguardado con indicador, compartir, vaciar),
	Actividad (pregunta, temporizador, una sola respuesta, resultados privados) y Clase (tema, levantar la mano,
	ver tablero, aceptar invitación). Se abre solo al entrar en el aula asignada (bucle de 1 Hz con Zones) o al
	sentarse en uno de sus asientos; se puede minimizar o cerrar. Solo renderiza: el servidor decide todo.
	API: Abrir(opciones), Cerrar(), Minimizar(bool), AbrirCuaderno(), EstaAbierto(), Sala().
]]

local Players = game:GetService("Players")

local ClassroomController = {}
ClassroomController.Nombre = "ClassroomController"
ClassroomController.AnchoPanel = 420 -- Ancho del panel lateral en PC (unidades de UI).
ClassroomController.MargenSuperiorPC = 172 -- Deja libres los botones del HUD (esquina superior derecha).
ClassroomController.IntervaloTickSeg = 1 -- Detección de aula, temporizadores y autoguardado (1 Hz).
ClassroomController.MinConsultaSeg = 2 -- Mínimo entre dos ConsultarEstado automáticos.

local UIBuilder, UITheme, Net, Maid, Format, Zones, RoleDefinitions, TimetableDefinitions, MapaLogico, Config
local Colores

local player = Players.LocalPlayer

local TIEMPOS = {
	{ Valor = 30, Texto = "30 s" }, { Valor = 60, Texto = "1 min" }, { Valor = 90, Texto = "1 min 30 s" },
	{ Valor = 120, Texto = "2 min" }, { Valor = 180, Texto = "3 min" }, { Valor = 300, Texto = "5 min" },
	{ Valor = 600, Texto = "10 min" },
}

local PESTANAS = {
	Docente = {
		{ Id = "Sesion", Texto = "Sesión" }, { Id = "Actividad", Texto = "Actividad" },
		{ Id = "Respuestas", Texto = "Respuestas" }, { Id = "Alumnos", Texto = "Alumnos" },
		{ Id = "Cuaderno", Texto = "Cuaderno" },
	},
	Estudiante = {
		{ Id = "Cuaderno", Texto = "Cuaderno" }, { Id = "Actividad", Texto = "Actividad" }, { Id = "Clase", Texto = "Clase" },
	},
	Personal = { { Id = "Cuaderno", Texto = "Cuaderno" } },
}

local LETRAS = { "A", "B", "C", "D" }

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
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

local function ahoraServidor()
	local ok, valor = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if ok and typeof(valor) == "number" then
		return valor
	end
	return os.time()
end

local function limpiarHijos(marco)
	if typeof(marco) ~= "Instance" then
		return
	end
	for _, hijo in ipairs(marco:GetChildren()) do
		if not hijo:IsA("UIListLayout") and not hijo:IsA("UIPadding") and not hijo:IsA("UIGridLayout") then
			hijo:Destroy()
		end
	end
end

local function nombreAula(roomId)
	local zona = roomId and MapaLogico.Zonas[roomId]
	if zona and typeof(zona.Nombre) == "string" and zona.Nombre ~= "" then
		return zona.Nombre
	end
	return tostring(roomId or "—")
end

local function mensajeDe(respuesta)
	if typeof(respuesta) == "table" then
		if typeof(respuesta.mensaje) == "string" and respuesta.mensaje ~= "" then
			return respuesta.mensaje
		end
		return UIBuilder.MensajeError(respuesta.error)
	end
	return "Ocurrió un error inesperado."
end

local function recortar(texto)
	local resultado = string.gsub(tostring(texto or ""), "^%s+", "")
	resultado = string.gsub(resultado, "%s+$", "")
	return resultado
end

local function horaLocal(unix)
	local ok, t = pcall(os.date, "*t", math.floor(tonumber(unix) or os.time()))
	if ok and typeof(t) == "table" then
		return string.format("%02d:%02d", t.hour, t.min)
	end
	return "--:--"
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function ClassroomController:Init(registro)
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
	Zones = requerir(Util, "Zones")
	Colores = UITheme.Colores

	local cfg = Config.Cuaderno or {}
	self.MaxPaginas = tonumber(cfg.MaxPaginas) or 20
	self.MaxCaracteres = tonumber(cfg.MaxCaracteresPagina) or 1200
	self.AutoguardadoSeg = tonumber(cfg.AutoguardadoSeg) or 45
	self.MinIntervaloGuardado = tonumber(cfg.MinIntervaloGuardadoSeg) or 10
	self.MaxRespuesta = (Config.Limites and Config.Limites.MaxRespuestaCaracteres) or 300
	self.MaxTema = (Config.Limites and Config.Limites.MaxTemaCaracteres) or 80
	self.MaxAviso = (Config.Limites and Config.Limites.MaxAvisoCaracteres) or 160

	self.maid = Maid.new() -- conexiones globales
	self.maidUI = Maid.new() -- panel construido (se rehace al cambiar de modo)
	self.maidPersonaje = Maid.new()
	self.activo = true
	self.abierto = false
	self.minimizado = false
	self.abiertoAuto = false
	self.cerradoManual = nil
	self.modo = self:_ModoActual()
	self.pestana = PESTANAS[self.modo][1].Id
	self.aulaActual = nil
	self.sala = nil
	self.estado = nil
	self.jornada = nil
	self.ultimaConsulta = -math.huge
	self.consultando = false
	-- Cuaderno
	self.cuaderno = nil
	self.cargandoCuaderno = false
	self.paginaActual = 1
	self.pendientes = {}
	self.guardando = false
	self.guardarPronto = false
	self.ultimoGuardado = -math.huge
	self.ultimoAutoguardado = os.clock()
	self.ultimoErrorGuardado = -math.huge
	self._cargandoTexto = false
	-- Estudiante
	self.actividad = nil
	self.miRespuesta = nil
	self.enviandoRespuesta = false
	self.resultados = {}
	self.resumen = nil
	self.invitacion = nil
	self.turno = nil
	self.mano = false
	self.asistenciaPropia = false
	-- Docente
	self.actividadDocente = nil
	self.respuestas = {}
	self.manos = {}
	self.ocupacion = nil
	self.asistencia = nil
	self.invitacionDocente = nil

	self.ui = {}
	self:_ConstruirPantalla()
end

function ClassroomController:Start()
	-- Atributos replicados (los fija el servidor).
	self.maid:GiveTask(player:GetAttributeChangedSignal("Cargo"):Connect(function()
		self:_AlCambiarCargo()
	end))
	self.maid:GiveTask(player:GetAttributeChangedSignal("Salon"):Connect(function()
		self:_RecalcularSala()
		self:_RefrescarTodo()
	end))

	-- Personaje: Humanoid.Seated abre el panel al sentarse en un asiento del aula.
	self.maid:GiveTask(player.CharacterAdded:Connect(function(personaje)
		self:_ConectarPersonaje(personaje)
	end))
	if player.Character then
		self:_ConectarPersonaje(player.Character)
	end

	-- Cierre con Escape / botón B (si no hay un modal abierto encima).
	local tecla = UIBuilder.TeclaCerrar(function()
		if self.abierto and not self.minimizado and not self:_HayModal() then
			self:Cerrar(true)
		end
	end)
	if tecla then
		self.maid:GiveTask(tecla)
	end

	-- Reajuste al girar la pantalla o cambiar el tamaño de la ventana.
	local camara = workspace.CurrentCamera
	if camara then
		self.maid:GiveTask(camara:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			if self.abierto then
				self:_AplicarLayout()
			end
		end))
	end

	-- Canal servidor -> cliente.
	task.spawn(function()
		local remoto = Net.Evento("EventoCliente")
		if not remoto then
			warn("[ColegioRP] ClassroomController: EventoCliente no disponible; el panel del aula no recibirá eventos.")
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
			if carga.Tipo == "Aula" then
				ok, err = pcall(self._AlEventoAula, self, datos)
			elseif carga.Tipo == "Jornada" then
				ok, err = pcall(self._AlJornada, self, datos)
			end
			if not ok then
				warn("[ColegioRP] ClassroomController: " .. tostring(err))
			end
		end))
	end)

	-- Jornada y aula iniciales desde el snapshot que ya pidió el HUD (sin repetir StateSnapshot).
	task.spawn(function()
		for _, espera in ipairs({ 2, 4, 8 }) do
			task.wait(espera)
			if not self.activo or self.jornada ~= nil then
				return
			end
			local HUD = self.registro.Get("HUDController")
			if HUD and typeof(HUD.Snapshot) == "function" then
				local ok, snapshot = pcall(HUD.Snapshot, HUD)
				if ok and typeof(snapshot) == "table" then
					if typeof(snapshot.Jornada) == "table" then
						self:_AlJornada(snapshot.Jornada)
					end
					if typeof(snapshot.Aula) == "table" and snapshot.Aula.RoomId == self.sala then
						self:_AplicarEstado(snapshot.Aula)
					end
					return
				end
			end
		end
	end)

	-- Bucle de 1 Hz: aula actual, temporizadores y autoguardado (sin RenderStepped).
	self.maid:GiveTask(task.spawn(function()
		while self.activo do
			local ok, err = pcall(self._Tick, self)
			if not ok then
				warn("[ColegioRP] ClassroomController: " .. tostring(err))
			end
			task.wait(self.IntervaloTickSeg)
		end
	end))
end

function ClassroomController:Destruir()
	self.activo = false
	self.maidPersonaje:DoCleaning()
	self.maidUI:DoCleaning()
	self.maid:DoCleaning()
	UIBuilder.Destruir(self.gui)
end

---------------------------------------------------------------------------------------------------
-- Estado local auxiliar
---------------------------------------------------------------------------------------------------
function ClassroomController:_ModoActual()
	local cargo = player:GetAttribute("Cargo")
	if typeof(cargo) == "string" and RoleDefinitions.Existe(cargo) then
		if RoleDefinitions.Tiene(cargo, "aula.docente") then
			return "Docente"
		end
		if RoleDefinitions.Tiene(cargo, "aula.estudiante") then
			return "Estudiante"
		end
		return "Personal"
	end
	return "Estudiante"
end

function ClassroomController:_PuedeCualquierAula()
	local cargo = player:GetAttribute("Cargo")
	return typeof(cargo) == "string" and RoleDefinitions.Tiene(cargo, "horario.editar")
end

function ClassroomController:_Salon()
	local salon = player:GetAttribute("Salon")
	if typeof(salon) == "string" and salon ~= "" then
		return salon
	end
	return nil
end

function ClassroomController:_HayModal()
	local gui = player:FindFirstChild("PlayerGui")
	local modal = gui and gui:FindFirstChild((UIBuilder.Prefijo or "ColegioRP_") .. "Modal")
	return modal ~= nil and modal:FindFirstChild("Modal") ~= nil
end

function ClassroomController:_Notificar(texto, nivel, duracion)
	local Notif = self.registro.Get("NotificationController")
	if Notif and typeof(Notif.Notificar) == "function" then
		pcall(Notif.Notificar, Notif, texto, nivel or "info", duracion)
	end
end

-- ¿La jornada permite acciones de clase? Devuelve true | false, motivo. Sin datos de jornada: true.
function ClassroomController:_EnClase()
	local jornada = self.jornada
	if typeof(jornada) ~= "table" or typeof(jornada.Estado) ~= "string" then
		return true, nil
	end
	if TimetableDefinitions.EsClase(jornada.Estado) then
		return true, nil
	end
	local nombre = jornada.Nombre
	if typeof(nombre) ~= "string" or nombre == "" then
		nombre = TimetableDefinitions.Nombre(jornada.Estado)
	end
	return false, "Fuera del periodo de clase (" .. nombre .. "): las actividades están desactivadas."
end

function ClassroomController:_SesionAbierta()
	return typeof(self.estado) == "table" and self.estado.SesionAbierta == true
end

function ClassroomController:_SoyDocenteDeSesion()
	return self:_SesionAbierta() and self.estado.DocenteUserId == player.UserId
end

function ClassroomController:_Presente()
	return self.sala ~= nil and self.aulaActual == self.sala
end

---------------------------------------------------------------------------------------------------
-- Pantalla y panel
---------------------------------------------------------------------------------------------------
function ClassroomController:_ConstruirPantalla()
	local gui = UIBuilder.Pantalla("Aula", (UITheme.Capas and UITheme.Capas.Panel) or 50)
	gui.Enabled = false
	self.gui = gui
	self.maid:GiveTask(gui)
	local contenido = UIBuilder.Contenedor(gui, { Nombre = "Contenido" })
	self.contenido = contenido

	-- Pastilla del panel minimizado (borde derecho, a media altura: no tapa HUD ni controles táctiles).
	self.pastilla = UIBuilder.Boton(contenido, "Aula", function()
		self:Minimizar(false)
	end, {
		Estilo = "Primario", Icono = "◂", Ancho = 120, Nombre = "Pastilla",
		Position = UDim2.new(1, 0, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5), Visible = false,
	})
	self:_ConstruirPanel()
end

function ClassroomController:_ConstruirPanel()
	self.maidUI:DoCleaning()
	self.ui = {}
	local titulo = "Aula"
	if self.modo == "Personal" then
		titulo = "Mi cuaderno"
	end
	local panel, cuerpo = UIBuilder.Panel(self.contenido, {
		Titulo = titulo, Nombre = "PanelAula",
		AlCerrar = function()
			self:Cerrar(true)
		end,
	})
	self.panel = panel
	self.maidUI:GiveTask(panel)
	self.ui.Cuerpo = cuerpo
	local cabecera = panel:FindFirstChild("Cabecera")
	if cabecera then
		local etiqueta = cabecera:FindFirstChild("Titulo")
		if etiqueta then
			etiqueta.Size = UDim2.new(1, -124, 1, 0)
			self.ui.Titulo = etiqueta
		end
		self.ui.Minimizar = UIBuilder.Boton(cabecera, "–", function()
			self:Minimizar(true)
		end, {
			Estilo = "Fantasma", Ancho = 40, Alto = 36, Nombre = "Minimizar", Tamano = "Subtitulo",
			Position = UDim2.new(1, -50, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5),
		})
	end

	self.ui.Info = UIBuilder.Texto(cuerpo, "", {
		Nombre = "Info", Tamano = "Pequeno", Color = Colores.TextoSecundario, AutoAlto = false, Truncar = true,
		Size = UDim2.new(1, 0, 0, 34),
	})
	self.ui.Banner = UIBuilder.Texto(cuerpo, "", {
		Nombre = "Banner", Tamano = "Pequeno", Color = Colores.Amarillo, AutoAlto = false, Truncar = true,
		Size = UDim2.new(1, 0, 0, 30), Visible = false,
	})
	local barra = UIBuilder.Lista(cuerpo, { Horizontal = true, Espaciado = 6 })
	barra.Name = "Pestanas"
	self.ui.Barra = barra
	local paginas = Instance.new("Frame")
	paginas.Name = "Paginas"
	paginas.BackgroundTransparency = 1
	paginas.BorderSizePixel = 0
	paginas.Parent = cuerpo
	self.ui.Paginas = paginas

	self.botonesPestana = {}
	self.paginas = {}
	local lista = PESTANAS[self.modo] or PESTANAS.Estudiante
	local controles = {}
	local valida = false
	for i, def in ipairs(lista) do
		if def.Id == self.pestana then
			valida = true
		end
		local boton = UIBuilder.Boton(barra, def.Texto, function()
			self:_MostrarPestana(def.Id)
		end, { Estilo = "Secundario", Ancho = 104, LayoutOrder = i, Nombre = "Pestana_" .. def.Id, Tamano = "Pequeno" })
		self.botonesPestana[def.Id] = boton
		table.insert(controles, boton)
		local pagina = UIBuilder.Lista(paginas, { Espaciado = 8 })
		pagina.Name = "Pagina_" .. def.Id
		pagina.Visible = false
		self.paginas[def.Id] = pagina
	end
	UIBuilder.Encadenar(controles, true)
	if not valida then
		self.pestana = lista[1].Id
	end

	if self.paginas.Cuaderno then
		self:_ConstruirCuaderno(self.paginas.Cuaderno)
	end
	if self.modo == "Docente" then
		self:_ConstruirSesionDocente(self.paginas.Sesion)
		self:_ConstruirActividadDocente(self.paginas.Actividad)
		self:_ConstruirRespuestas(self.paginas.Respuestas)
		self:_ConstruirAlumnos(self.paginas.Alumnos)
	elseif self.modo == "Estudiante" then
		self:_ConstruirActividadAlumno(self.paginas.Actividad)
		self:_ConstruirClase(self.paginas.Clase)
	end
	-- Al reconstruir (cambio de cargo) el TextBox nace vacío: se repinta la página ya cargada para que
	-- la siguiente edición no sustituya el texto guardado por uno vacío.
	if self.cuaderno and self.ui.EntradaCuaderno then
		self:_MostrarPaginaCuaderno()
	end

	self:_Reubicar()
	self:_AplicarLayout()
	self:_MostrarPestana(self.pestana)
	panel.Visible = self.abierto and not self.minimizado
end

-- Coloca cabecera, banner, barra de pestañas y páginas (alturas fijas en unidades de UI).
function ClassroomController:_Reubicar()
	local y = 36
	if self.ui.Banner and self.ui.Banner.Visible then
		self.ui.Banner.Position = UDim2.new(0, 0, 0, y)
		y = y + 32
	end
	local altoBarra = UIBuilder.AltoBoton() + 8
	if self.ui.Barra then
		self.ui.Barra.Position = UDim2.new(0, 0, 0, y)
		self.ui.Barra.Size = UDim2.new(1, 0, 0, altoBarra)
	end
	y = y + altoBarra + 6
	if self.ui.Paginas then
		self.ui.Paginas.Position = UDim2.new(0, 0, 0, y)
		self.ui.Paginas.Size = UDim2.new(1, 0, 1, -y)
	end
end

-- PC/tableta: panel lateral derecho bajo los botones del HUD. Móvil o pantalla estrecha: casi completa.
function ClassroomController:_AplicarLayout()
	local panel = self.panel
	if not panel or panel.Parent == nil then
		return
	end
	local compacto = UIBuilder.EsEstrecho() or UIBuilder.Dispositivo() == "Movil"
	if compacto then
		panel.AnchorPoint = Vector2.new(0.5, 0.5)
		panel.Position = UDim2.new(0.5, 0, 0.5, 0)
		panel.Size = UDim2.new(1, 0, 1, 0)
	else
		local ancho = math.min(self.AnchoPanel, math.max(320, UIBuilder.AnchoUI() * 0.42))
		panel.AnchorPoint = Vector2.new(1, 0)
		panel.Position = UDim2.new(1, 0, 0, self.MargenSuperiorPC)
		panel.Size = UDim2.new(0, ancho, 1, -self.MargenSuperiorPC)
	end
end

function ClassroomController:_MostrarPestana(id)
	if not self.paginas or not self.paginas[id] then
		return
	end
	self.pestana = id
	for clave, pagina in pairs(self.paginas) do
		pagina.Visible = clave == id
	end
	for clave, boton in pairs(self.botonesPestana) do
		boton:SetAttribute("Estilo", clave == id and "Primario" or "Secundario")
		UIBuilder.Habilitar(boton, true)
	end
	if id == "Cuaderno" and not self.cuaderno and self.abierto then
		self:_CargarCuaderno()
	end
	self:_RefrescarTodo()
end

---------------------------------------------------------------------------------------------------
-- API pública
---------------------------------------------------------------------------------------------------

-- Abre el panel. opciones = { Pestana = "Cuaderno" | "Actividad" | ..., Automatico = bool }.
function ClassroomController:Abrir(opciones)
	opciones = typeof(opciones) == "table" and opciones or {}
	if not self.gui or self.gui.Parent == nil then
		self:_ConstruirPantalla()
	end
	local yaAbierto = self.abierto
	self.abierto = true
	self.minimizado = false
	if opciones.Automatico then
		if not yaAbierto then
			self.abiertoAuto = true
		end
	else
		self.abiertoAuto = false
	end
	self.gui.Enabled = true
	self.pastilla.Visible = false
	self:_AplicarLayout()
	if typeof(opciones.Pestana) == "string" and self.paginas[opciones.Pestana] then
		self:_MostrarPestana(opciones.Pestana)
	else
		self:_RefrescarTodo()
	end
	if not yaAbierto or not self.panel.Visible then
		UIBuilder.Aparecer(self.panel)
		task.defer(function()
			if self.abierto and self.panel and self.panel.Parent then
				UIBuilder.EnfocarPrimero(self.panel)
			end
		end)
	end
	self.panel.Visible = true
	-- El cuaderno se carga al abrir el panel por primera vez (nunca durante Init).
	if self.paginas.Cuaderno and not self.cuaderno then
		self:_CargarCuaderno()
	end
	self:_ActualizarAccionHUD()
end

-- Cierra el panel. manual = true recuerda el aula para no reabrirlo solo hasta salir de ella.
function ClassroomController:Cerrar(manual)
	if manual and self.aulaActual then
		self.cerradoManual = self.aulaActual
	end
	if self:_HayPendientes() then
		self.guardarPronto = true
		self:_ProcesarGuardado(true)
	end
	self.abierto = false
	self.abiertoAuto = false
	self.minimizado = false
	if self.gui then
		UIBuilder.Desenfocar(self.gui)
		self.gui.Enabled = false
	end
	if self.pastilla then
		self.pastilla.Visible = false
	end
	self:_ActualizarAccionHUD()
end

-- Minimiza (true) a la pastilla lateral o expande (false) el panel.
function ClassroomController:Minimizar(minimizado)
	if not self.abierto then
		if minimizado == false then
			self:Abrir()
		end
		return
	end
	self.minimizado = minimizado == true
	if self.minimizado then
		UIBuilder.Desenfocar(self.panel)
		self.panel.Visible = false
		self.pastilla.Visible = true
		UIBuilder.TextoBoton(self.pastilla, "◂  " .. (self.sala and ("Aula " .. self.sala) or "Aula"))
	else
		self.pastilla.Visible = false
		self.panel.Visible = true
		self:_AplicarLayout()
		UIBuilder.Aparecer(self.panel)
		self:_RefrescarTodo()
		task.defer(function()
			UIBuilder.EnfocarPrimero(self.panel)
		end)
	end
end

-- Abre directamente la pestaña Cuaderno (botón del HUD).
function ClassroomController:AbrirCuaderno()
	self:Abrir({ Pestana = "Cuaderno" })
end

function ClassroomController:EstaAbierto()
	return self.abierto == true
end

-- Aula que muestra el panel (o nil).
function ClassroomController:Sala()
	return self.sala
end

-- Botón contextual del HUD para reabrir el panel mientras se está en un aula con el panel cerrado.
function ClassroomController:_ActualizarAccionHUD()
	local HUD = self.registro.Get("HUDController")
	if not HUD or typeof(HUD.AccionContextual) ~= "function" then
		return
	end
	local mostrar = not self.abierto and self.aulaActual ~= nil and self.modo ~= "Personal"
	if mostrar == self._accionHUD then
		return
	end
	self._accionHUD = mostrar
	if mostrar then
		pcall(HUD.AccionContextual, HUD, "Panel del aula", function()
			self:Abrir()
		end)
	else
		pcall(HUD.AccionContextual, HUD, "Panel del aula", nil)
	end
end

---------------------------------------------------------------------------------------------------
-- Personaje, aula actual y sala
---------------------------------------------------------------------------------------------------
function ClassroomController:_ConectarPersonaje(personaje)
	self.maidPersonaje:DoCleaning()
	task.spawn(function()
		local humanoid = personaje:FindFirstChildOfClass("Humanoid") or personaje:WaitForChild("Humanoid", 15)
		if not humanoid or not humanoid:IsA("Humanoid") or personaje.Parent == nil then
			return
		end
		self.maidPersonaje:GiveTask(humanoid.Seated:Connect(function(activo, asiento)
			if not activo or typeof(asiento) ~= "Instance" then
				return
			end
			local roomId = asiento:GetAttribute("RoomId")
			if typeof(roomId) ~= "string" or roomId == "" then
				return
			end
			if roomId ~= self.aulaActual then
				self:_CambioDeAula(roomId)
			end
			-- Sentarse expresa intención: se reabre aunque se hubiera cerrado a mano (solo en el aula propia).
			if self.modo ~= "Personal" and (roomId == self:_Salon() or self:_PuedeCualquierAula()) then
				self.cerradoManual = nil
				self:Abrir({ Automatico = true })
			end
		end))
	end)
end

-- Aula en la que está el jugador: la del asiento (atributo RoomId) o la zona de aula más pequeña que lo contiene.
function ClassroomController:_DetectarAula()
	local personaje = player.Character
	if not personaje then
		return nil
	end
	local humanoid = personaje:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.SeatPart then
		local roomId = humanoid.SeatPart:GetAttribute("RoomId")
		if typeof(roomId) == "string" and roomId ~= "" then
			return roomId
		end
	end
	local raiz = personaje:FindFirstChild("HumanoidRootPart")
	if not raiz then
		return nil
	end
	for _, zona in ipairs(Zones.ZonasEn(raiz.Position)) do
		if Zones.EsAula(zona.Id) then
			return zona.Id
		end
	end
	return nil
end

function ClassroomController:_CambioDeAula(nueva)
	local anterior = self.aulaActual
	self.aulaActual = nueva
	if nueva == nil then
		self.cerradoManual = nil
	end
	self:_RecalcularSala()
	if nueva then
		local propia = nueva == self:_Salon()
		if self.modo == "Docente" and self:_PuedeCualquierAula() then
			propia = true
		end
		if propia and self.modo ~= "Personal" and self.cerradoManual ~= nueva then
			self:Abrir({ Automatico = true })
		end
		-- Fuera del aula no llegan sus eventos: al entrar se refresca el estado (SesionCerrada, actividades...).
		-- Sin forzar: si _RecalcularSala acaba de consultar, no se repite.
		if self.sala == nueva then
			self:_ConsultarEstado(false)
		end
	elseif anterior and self.abierto and self.abiertoAuto and self.pestana ~= "Cuaderno" then
		self:Cerrar(false)
	end
	self:_ActualizarAccionHUD()
	self:_RefrescarTodo()
end

-- Sala que muestra el panel: docente con sesión -> su aula; si no, el aula actual o el salón asignado.
function ClassroomController:_RecalcularSala()
	local nueva
	if self.modo == "Docente" and self:_SoyDocenteDeSesion() then
		nueva = self.estado.RoomId
	else
		nueva = self.aulaActual or self:_Salon()
	end
	if nueva == self.sala then
		return
	end
	self.sala = nueva
	self:_ReiniciarEstadoSala()
	if nueva then
		self:_ConsultarEstado(true)
	end
end

function ClassroomController:_ReiniciarEstadoSala()
	self.estado = nil
	self.actividad = nil
	self.miRespuesta = nil
	self.resultados = {}
	self.resumen = nil
	self.invitacion = nil
	self.turno = nil
	self.mano = false
	self.asistenciaPropia = false
	self.actividadDocente = nil
	self.respuestas = {}
	self.manos = {}
	self.ocupacion = nil
	self.asistencia = nil
	self.invitacionDocente = nil
	self:_RenderOpciones()
end

function ClassroomController:_AlCambiarCargo()
	local modo = self:_ModoActual()
	if modo == self.modo then
		return
	end
	self.modo = modo
	self.pestana = PESTANAS[modo][1].Id
	self.sala = nil
	self:_ReiniciarEstadoSala()
	self:_ConstruirPanel()
	self:_RecalcularSala()
	if modo == "Personal" and self.abierto and self.pestana ~= "Cuaderno" then
		self:Cerrar(false)
	end
	self:_ActualizarAccionHUD()
	self:_RefrescarTodo()
end

-- Pide al servidor el estado del aula (quien entra a mitad de clase).
function ClassroomController:_ConsultarEstado(forzar)
	local sala = self.sala
	if not sala or self.consultando then
		return
	end
	if not forzar and os.clock() - self.ultimaConsulta < self.MinConsultaSeg then
		return
	end
	self.consultando = true
	self.ultimaConsulta = os.clock()
	task.spawn(function()
		local ok, respuesta = Net.Invocar("RequestClassAction", { Accion = "ConsultarEstado", Salon = sala, Datos = {} })
		self.consultando = false
		if self.sala ~= sala then
			-- La sala cambió durante la consulta (la petición de la sala nueva se descartó por estar esta en
			-- curso): se consulta la sala actual para no quedarse en "Consultando…".
			if self.sala then
				self:_ConsultarEstado(true)
			end
			return
		end
		if ok and typeof(respuesta.datos) == "table" then
			self:_AplicarEstado(respuesta.datos)
		else
			self.estado = { SesionAbierta = false, RoomId = sala, SinAcceso = true }
			self:_RefrescarTodo()
			-- En el borde de la zona el servidor puede no vernos aún: un reintento breve.
			task.delay(3, function()
				if self.sala == sala and self.aulaActual == sala and self.estado and self.estado.SinAcceso then
					self:_ConsultarEstado(true)
				end
			end)
		end
	end)
end

---------------------------------------------------------------------------------------------------
-- Bucle de 1 Hz
---------------------------------------------------------------------------------------------------
function ClassroomController:_Tick()
	local aula = self:_DetectarAula()
	if aula ~= self.aulaActual then
		self:_CambioDeAula(aula)
	end
	if self.abierto and not self.minimizado then
		self:_RefrescarTemporizadores()
	end
	self:_ProcesarGuardado(false)
end

---------------------------------------------------------------------------------------------------
-- Llamadas al servidor
---------------------------------------------------------------------------------------------------

-- RequestClassAction en segundo plano. alExito(datos) | opciones.AlFallar(respuesta).
function ClassroomController:_Accion(accion, datos, alExito, opciones)
	opciones = opciones or {}
	local sala = opciones.Sala or self.sala
	if not sala then
		self:_Notificar("No estás en un aula.", "aviso")
		return
	end
	task.spawn(function()
		local ok, respuesta = Net.Invocar("RequestClassAction", { Accion = accion, Salon = sala, Datos = datos or {} })
		if ok then
			if typeof(alExito) == "function" then
				local okCb, err = pcall(alExito, respuesta.datos or {})
				if not okCb then
					warn("[ColegioRP] ClassroomController: " .. tostring(err))
				end
			end
		else
			if not opciones.Silencioso then
				self:_Notificar(mensajeDe(respuesta), "error")
			end
			if typeof(opciones.AlFallar) == "function" then
				pcall(opciones.AlFallar, respuesta)
			end
		end
		self:_RefrescarTodo()
	end)
end

function ClassroomController:_VerTablero()
	local sala = self.sala
	if not sala then
		self:_Notificar("No estás en un aula.", "aviso")
		return
	end
	local Board = self.registro.Get("BoardController")
	if Board and typeof(Board.Abrir) == "function" then
		local ok, err = pcall(Board.Abrir, Board, sala)
		if not ok then
			warn("[ColegioRP] ClassroomController: BoardController:Abrir falló: " .. tostring(err))
			self:_Notificar("No se pudo abrir el tablero.", "error")
		end
	else
		self:_Notificar("La vista del tablero aún no está disponible. Mira el tablero del aula.", "aviso")
	end
end

---------------------------------------------------------------------------------------------------
-- Eventos del servidor
---------------------------------------------------------------------------------------------------
function ClassroomController:_AlJornada(datos)
	if typeof(datos) ~= "table" or typeof(datos.Estado) ~= "string" then
		return
	end
	self.jornada = datos
	self:_RefrescarTodo()
end

function ClassroomController:_AlEventoAula(datos)
	local sub = datos.Sub
	if sub == "Cuaderno" then
		-- Entrada añadida desde un PC: se recarga (los borradores sin guardar se conservan en la fusión).
		local numero = tonumber(datos.Pagina)
		if numero and self.pendientes[numero] then
			self:_Notificar("Tienes cambios sin guardar en la página " .. numero .. ": al guardarlos sustituirán lo añadido desde el PC.", "aviso", 6)
		end
		self:_CargarCuaderno()
		return
	end
	local roomId = datos.RoomId
	local esMiSala = roomId ~= nil and roomId == self.sala
	-- Docente: los eventos de su propia sesión llegan aunque esté fuera del aula.
	if sub == "SesionAbierta" and datos.DocenteUserId == player.UserId then
		self.estado = datos
		self:_RecalcularSala()
		esMiSala = roomId == self.sala
	end
	if not esMiSala then
		if sub == "Resultado" and typeof(datos.Prompt) == "string" then
			self:_NotificarResultado(datos)
		end
		return
	end

	if sub == "SesionAbierta" then
		self:_ReiniciarEstadoSala()
		self.estado = datos
		if datos.DocenteUserId ~= player.UserId then
			local materia = datos.NombreMateria and (" de " .. datos.NombreMateria) or ""
			self:_Notificar("Comenzó la clase" .. materia .. " con " .. tostring(datos.Docente or "el docente") .. ".", "info")
		end
	elseif sub == "SesionCerrada" then
		local motivo = datos.Motivo or "La clase terminó."
		self:_ReiniciarEstadoSala()
		self.estado = { SesionAbierta = false, RoomId = roomId }
		self:_Notificar(motivo, "info")
		self:_RecalcularSala()
	elseif sub == "Tema" then
		if self.estado then
			self.estado.Tema = datos.Tema
		end
		if not self:_SoyDocenteDeSesion() then
			self:_Notificar("Tema de la clase: " .. tostring(datos.Tema), "info")
		end
	elseif sub == "Aviso" then
		local Notif = self.registro.Get("NotificationController")
		if Notif and typeof(Notif.Aviso) == "function" then
			pcall(Notif.Aviso, Notif, { Texto = datos.Texto, Autor = datos.Docente, Cargo = datos.Cargo, Alcance = "Aula" })
		else
			self:_Notificar(tostring(datos.Texto), "aviso", 8)
		end
	elseif sub == "Actividad" then
		self:_AlActividad(datos)
	elseif sub == "ActividadCerrada" then
		if datos.Actividad then
			self.actividadDocente = datos.Actividad
			if typeof(datos.Respuestas) == "table" then
				self.respuestas = datos.Respuestas
			end
		elseif self.actividad and self.actividad.Id == datos.ActividadId then
			self.actividad.Estado = "Cerrada"
			if not self.miRespuesta then
				self:_Notificar("La actividad se cerró: " .. tostring(datos.Motivo or ""), "info")
			end
		end
		self:_RenderOpciones()
	elseif sub == "Respuesta" then
		self:_AlRespuesta(datos)
	elseif sub == "Resultado" then
		self:_AlResultado(datos)
	elseif sub == "Resultados" then
		self.resumen = datos
		if not self:_SoyDocenteDeSesion() then
			self:_Notificar("El docente publicó los resultados de la actividad.", "info")
		end
	elseif sub == "Asistencia" then
		if datos.Propia then
			self.asistenciaPropia = true
			self:_Notificar("Asistencia registrada: presente.", "exito")
		else
			self.asistencia = datos
			self.ocupacion = { Sentados = datos.Sentados or {}, DePie = datos.DePie or {}, Capacidad = datos.Capacidad, Total = datos.Total }
		end
	elseif sub == "Mano" then
		if typeof(datos.Manos) == "table" then
			self.manos = datos.Manos
		end
		if datos.Levantada and datos.UserId ~= player.UserId then
			self:_Notificar(tostring(datos.Nombre) .. " levantó la mano.", "info", 3)
		end
	elseif sub == "Invitacion" then
		self:_AlInvitacion(datos)
	elseif sub == "TurnoTablero" then
		self:_AlTurno(datos)
	elseif sub == "Estado" then
		if datos.Parcial then
			if typeof(datos.Ocupacion) == "table" then
				self.ocupacion = datos.Ocupacion
			end
			if typeof(datos.Manos) == "table" then
				self.manos = datos.Manos
			end
		else
			self:_AplicarEstado(datos)
			return
		end
	end
	self:_RefrescarTodo()
end

function ClassroomController:_AlActividad(datos)
	local act = datos.Actividad
	if typeof(act) ~= "table" then
		return
	end
	if datos.Docente then
		self.actividadDocente = act
		self.respuestas = {}
		self.resumen = nil
		self:_Notificar(string.format("Actividad enviada a %d estudiante(s).", tonumber(datos.Destinatarios) or 0), "exito")
		return
	end
	self.actividad = act
	self.miRespuesta = nil
	self.resumen = nil
	if self.ui.EntradaRespuesta then
		self.ui.EntradaRespuesta.Text = ""
	end
	self:_RenderOpciones()
	self:_Notificar("Nueva actividad: responde antes de que termine el tiempo.", "info", 5)
	if self:_Presente() then
		if not self.abierto then
			self:Abrir({ Pestana = "Actividad", Automatico = true })
		else
			if self.minimizado then
				self:Minimizar(false)
			end
			self:_MostrarPestana("Actividad")
		end
	end
end

function ClassroomController:_AlRespuesta(datos)
	local registro = datos.Respuesta
	if typeof(registro) ~= "table" then
		return
	end
	if self.actividadDocente and self.actividadDocente.Id ~= datos.ActividadId then
		return
	end
	local reemplazada = false
	for i, existente in ipairs(self.respuestas) do
		if existente.UserId == registro.UserId then
			self.respuestas[i] = registro
			reemplazada = true
			break
		end
	end
	if not reemplazada then
		table.insert(self.respuestas, registro)
	end
	if self.actividadDocente then
		self.actividadDocente.Respuestas = tonumber(datos.Total) or #self.respuestas
	end
end

function ClassroomController:_NotificarResultado(datos)
	if datos.Automatico then
		if datos.Correcta then
			self:_Notificar("¡Respuesta correcta!", "exito")
		else
			local correcta = datos.RespuestaCorrecta and (" La correcta era: " .. tostring(datos.RespuestaCorrecta)) or ""
			self:_Notificar("Respuesta incorrecta." .. correcta, "aviso", 6)
		end
	elseif datos.Puntos ~= nil then
		self:_Notificar(string.format("Recibiste una nota: %s / 10.", tostring(datos.Puntos)), "exito", 6)
	end
end

function ClassroomController:_AlResultado(datos)
	local existente = nil
	for _, resultado in ipairs(self.resultados) do
		if resultado.ActividadId == datos.ActividadId then
			existente = resultado
			break
		end
	end
	if not existente then
		existente = { ActividadId = datos.ActividadId }
		table.insert(self.resultados, existente)
	end
	existente.Prompt = datos.Prompt or existente.Prompt
	if datos.Automatico then
		existente.Correcta = datos.Correcta == true
		existente.RespuestaCorrecta = datos.RespuestaCorrecta
	end
	if datos.Puntos ~= nil then
		existente.Puntos = datos.Puntos
		existente.Comentario = datos.Comentario
	end
	self:_NotificarResultado(datos)
end

function ClassroomController:_AlInvitacion(datos)
	if self:_SoyDocenteDeSesion() then
		if datos.Pendiente then
			self.invitacionDocente = { UserId = datos.UserId, Nombre = datos.Nombre, Expira = datos.Expira }
			if typeof(datos.Manos) == "table" then
				self.manos = datos.Manos
			end
		else
			self.invitacionDocente = nil
			if datos.Rechazada then
				self:_Notificar(tostring(datos.Nombre) .. " rechazó la invitación al tablero.", "info")
			elseif datos.Caducada then
				self:_Notificar("La invitación a " .. tostring(datos.Nombre) .. " caducó.", "info")
			end
		end
		return
	end
	if datos.Caducada then
		if self.invitacion then
			self:_Notificar(datos.Revocada and "El docente retiró la invitación al tablero." or "La invitación al tablero caducó.", "info")
		end
		self.invitacion = nil
		return
	end
	self.invitacion = { Expira = tonumber(datos.Expira) or (ahoraServidor() + 20), Docente = datos.Docente }
	self:_Notificar(tostring(datos.Docente or "El docente") .. " te invita al tablero. Acepta en la pestaña Clase.", "info", 6)
	if not self.abierto then
		self:Abrir({ Pestana = "Clase", Automatico = true })
	else
		if self.minimizado then
			self:Minimizar(false)
		end
		self:_MostrarPestana("Clase")
	end
end

function ClassroomController:_AlTurno(datos)
	if datos.Fin then
		if self.turno and self.turno.UserId == player.UserId then
			self:_Notificar("Terminó tu turno en el tablero.", "info")
		end
		self.turno = nil
		return
	end
	self.turno = { UserId = datos.UserId, Nombre = datos.Nombre, Hasta = tonumber(datos.Hasta) }
	self.invitacion = nil
	self.invitacionDocente = nil
	if datos.UserId == player.UserId then
		self:_Notificar(string.format("¡Tu turno en el tablero! Tienes %s.", Format.Duracion(datos.Segundos or 90)), "exito", 6)
		self:_VerTablero()
	end
end

-- Aplica un snapshot completo (ConsultarEstado / StateSnapshot / Sub "Estado").
function ClassroomController:_AplicarEstado(datos)
	if typeof(datos) ~= "table" then
		return
	end
	local sesionPropia = datos.SesionAbierta == true and datos.DocenteUserId == player.UserId
	if datos.RoomId ~= nil and self.sala ~= nil and datos.RoomId ~= self.sala then
		-- El docente con sesión en otra aula cambia de sala.
		if not sesionPropia then
			return
		end
	end
	if sesionPropia and typeof(datos.RoomId) == "string" and datos.RoomId ~= self.sala then
		-- Cambio de sala antes de aplicar: así _RecalcularSala no reinicia (borra) el estado recién recibido.
		self.sala = datos.RoomId
		self:_ReiniciarEstadoSala()
	end
	self.estado = datos
	if datos.Rol == "Docente" then
		self.actividadDocente = datos.ActividadActiva or datos.ActividadRespuestas
		self.respuestas = typeof(datos.Respuestas) == "table" and datos.Respuestas or {}
		self.manos = typeof(datos.Manos) == "table" and datos.Manos or {}
		self.ocupacion = datos.Ocupacion
		self.invitacionDocente = datos.Invitacion
		self.turno = datos.TurnoTablero
	elseif datos.SesionAbierta then
		local activa = datos.ActividadActiva
		self.actividad = activa
		self.miRespuesta = activa and activa.MiRespuesta or nil
		self.resultados = typeof(datos.MisResultados) == "table" and datos.MisResultados or {}
		self.mano = datos.ManoLevantada == true
		self.invitacion = datos.Invitacion
		self.turno = datos.TurnoTablero
	end
	self:_RecalcularSala()
	self:_RenderOpciones()
	self:_RefrescarTodo()
end

---------------------------------------------------------------------------------------------------
-- Construcción: Cuaderno (todos los modos)
---------------------------------------------------------------------------------------------------
function ClassroomController:_ConstruirCuaderno(pagina)
	local orden = 0
	local function siguiente()
		orden = orden + 1
		return orden
	end
	self.ui.CuadernoTitulo = UIBuilder.Subtitulo(pagina, "Mi cuaderno", { LayoutOrder = siguiente(), Color = Colores.TextoPrincipal })

	local opcionesPagina = {}
	for i = 1, self.MaxPaginas do
		table.insert(opcionesPagina, { Valor = i, Texto = "Página " .. i })
	end
	self.ui.SelectorPagina = UIBuilder.Selector(pagina, "Página", opcionesPagina, self.paginaActual, function(valor)
		self:_CambiarPagina(valor)
	end, { LayoutOrder = siguiente(), AnchoGrupo = 190 })

	local opcionesMateria = {}
	for _, codigo in ipairs(TimetableDefinitions.OrdenMaterias or {}) do
		table.insert(opcionesMateria, { Valor = codigo, Texto = TimetableDefinitions.NombreMateria(codigo) })
	end
	self.ui.SelectorMateria = UIBuilder.Selector(pagina, "Materia", opcionesMateria, "MAT", function(valor)
		if self._cargandoTexto then
			return
		end
		local local_ = self:_PaginaLocal(self.paginaActual)
		if local_ and local_.Materia ~= valor then
			local_.Materia = valor
			self.pendientes[self.paginaActual] = true
			self:_RefrescarEstadoCuaderno()
		end
	end, { LayoutOrder = siguiente(), AnchoGrupo = 190 })

	self.ui.EntradaCuaderno = UIBuilder.Entrada(pagina, "Escribe aquí tus apuntes…", {
		Multilinea = true, Max = self.MaxCaracteres, Alto = 220, LayoutOrder = siguiente(), Nombre = "TextoCuaderno",
		AlCambiar = function(texto)
			if self._cargandoTexto then
				return
			end
			local local_ = self:_PaginaLocal(self.paginaActual)
			if local_ and local_.Texto ~= texto then
				local_.Texto = texto
				self.pendientes[self.paginaActual] = true
				self:_RefrescarEstadoCuaderno()
			end
		end,
	})

	local filaEstado = UIBuilder.Marco(pagina, { Alto = 20, LayoutOrder = siguiente(), Nombre = "EstadoCuaderno" })
	self.ui.ContadorCuaderno = UIBuilder.Texto(filaEstado, "0 / " .. self.MaxCaracteres, {
		Tamano = "Pequeno", Color = Colores.TextoApagado, AutoAlto = false, Size = UDim2.new(0.5, 0, 1, 0),
	})
	self.ui.EstadoGuardado = UIBuilder.Texto(filaEstado, "", {
		Tamano = "Pequeno", Color = Colores.Verde, AutoAlto = false, Alineacion = Enum.TextXAlignment.Right,
		Size = UDim2.new(0.5, 0, 1, 0), Position = UDim2.new(0.5, 0, 0, 0),
	})

	local fila = UIBuilder.Fila(pagina, { LayoutOrder = siguiente(), Espaciado = 6 })
	self.ui.BotonGuardar = UIBuilder.Boton(fila, "Guardar", function()
		self:_GuardarAhora()
	end, { Estilo = "Primario", Ancho = 110, LayoutOrder = 1, Tamano = "Pequeno" })
	self.ui.BotonCompartir = UIBuilder.Boton(fila, "Compartir", function()
		self:_Compartir()
	end, { Estilo = "Secundario", Ancho = 150, LayoutOrder = 2, Tamano = "Pequeno" })
	self.ui.BotonVaciar = UIBuilder.Boton(fila, "Vaciar", function()
		self:_ConfirmarVaciar()
	end, { Estilo = "Peligro", Ancho = 100, LayoutOrder = 3, Tamano = "Pequeno" })
	UIBuilder.Encadenar({ self.ui.BotonGuardar, self.ui.BotonCompartir, self.ui.BotonVaciar }, true)

	UIBuilder.Texto(pagina, "Se guarda solo cada " .. self.AutoguardadoSeg .. " s. Las páginas compartidas las puede revisar tu docente durante la clase (con el texto filtrado).", {
		Tamano = "Pequeno", Color = Colores.TextoApagado, LayoutOrder = siguiente(),
	})
end

---------------------------------------------------------------------------------------------------
-- Construcción: estudiante
---------------------------------------------------------------------------------------------------
function ClassroomController:_ConstruirActividadAlumno(pagina)
	local orden = 0
	local function siguiente()
		orden = orden + 1
		return orden
	end
	self.ui.ActTitulo = UIBuilder.Subtitulo(pagina, "Actividad", { LayoutOrder = siguiente(), Color = Colores.TextoPrincipal })
	self.ui.ActPregunta = UIBuilder.Texto(pagina, "No hay ninguna actividad activa.", { LayoutOrder = siguiente() })
	self.ui.ActTiempo = UIBuilder.Texto(pagina, "", { LayoutOrder = siguiente(), Tamano = "Pequeno", Color = Colores.Amarillo })
	local opciones = UIBuilder.Marco(pagina, { AutoAlto = true, LayoutOrder = siguiente(), Nombre = "Opciones" })
	UIBuilder.Disposicion(opciones, { Espaciado = 6 })
	self.ui.ActOpciones = opciones
	self.ui.EntradaRespuesta = UIBuilder.Entrada(pagina, "Escribe tu respuesta…", {
		Multilinea = true, Max = self.MaxRespuesta, Alto = 96, LayoutOrder = siguiente(), Nombre = "Respuesta",
	})
	self.ui.BotonResponder = UIBuilder.Boton(pagina, "Enviar respuesta", function()
		self:_ResponderTexto()
	end, { Estilo = "Primario", LayoutOrder = siguiente(), Size = UDim2.new(1, 0, 0, UIBuilder.AltoBoton()) })
	self.ui.ActEstado = UIBuilder.Texto(pagina, "", { LayoutOrder = siguiente(), Tamano = "Pequeno", Color = Colores.Verde })

	UIBuilder.Separador(pagina, { LayoutOrder = siguiente() })
	UIBuilder.Subtitulo(pagina, "Mis resultados (privados)", { LayoutOrder = siguiente() })
	local resultados = UIBuilder.Marco(pagina, { AutoAlto = true, LayoutOrder = siguiente(), Nombre = "Resultados" })
	UIBuilder.Disposicion(resultados, { Espaciado = 4 })
	self.ui.ActResultados = resultados
	UIBuilder.Subtitulo(pagina, "Resultados de la clase (anónimos)", { LayoutOrder = siguiente() })
	local resumen = UIBuilder.Marco(pagina, { AutoAlto = true, LayoutOrder = siguiente(), Nombre = "Resumen" })
	UIBuilder.Disposicion(resumen, { Espaciado = 4 })
	self.ui.ActResumen = resumen
	self:_RenderOpciones()
end

function ClassroomController:_ConstruirClase(pagina)
	local orden = 0
	local function siguiente()
		orden = orden + 1
		return orden
	end
	self.ui.ClaseTitulo = UIBuilder.Subtitulo(pagina, "Clase", { LayoutOrder = siguiente(), Color = Colores.TextoPrincipal })
	self.ui.ClaseInfo = UIBuilder.Texto(pagina, "", { LayoutOrder = siguiente() })
	self.ui.ClaseTema = UIBuilder.Texto(pagina, "", { LayoutOrder = siguiente(), Color = Colores.Amarillo })
	self.ui.BotonMano = UIBuilder.Boton(pagina, "✋  Levantar la mano", function()
		self:_AlternarMano()
	end, { Estilo = "Primario", LayoutOrder = siguiente(), Size = UDim2.new(1, 0, 0, UIBuilder.AltoBoton()) })
	self.ui.BotonTableroAlumno = UIBuilder.Boton(pagina, "Ver tablero", function()
		self:_VerTablero()
	end, { Estilo = "Secundario", LayoutOrder = siguiente(), Size = UDim2.new(1, 0, 0, UIBuilder.AltoBoton()) })

	local caja = UIBuilder.Marco(pagina, { AutoAlto = true, LayoutOrder = siguiente(), Nombre = "Invitacion", Color = Colores.Gris, Transparencia = 0.2 })
	UIBuilder.Esquinas(caja, UITheme.RadioPequeno)
	UIBuilder.Relleno(caja, 8, 8, 10, 10)
	UIBuilder.Disposicion(caja, { Espaciado = 6 })
	self.ui.InvTexto = UIBuilder.Texto(caja, "", { LayoutOrder = 1, Color = Colores.TextoPrincipal })
	local fila = UIBuilder.Fila(caja, { LayoutOrder = 2, Espaciado = 6 })
	self.ui.BotonAceptar = UIBuilder.Boton(fila, "Aceptar", function()
		self:_ResponderInvitacion(true)
	end, { Estilo = "Exito", Ancho = 120, LayoutOrder = 1 })
	self.ui.BotonRechazar = UIBuilder.Boton(fila, "Rechazar", function()
		self:_ResponderInvitacion(false)
	end, { Estilo = "Secundario", Ancho = 120, LayoutOrder = 2 })
	UIBuilder.Encadenar({ self.ui.BotonAceptar, self.ui.BotonRechazar }, true)
	caja.Visible = false
	self.ui.InvCaja = caja

	self.ui.ClaseTurno = UIBuilder.Texto(pagina, "", { LayoutOrder = siguiente(), Tamano = "Pequeno", Color = Colores.TextoSecundario })
	self.ui.ClaseAsistencia = UIBuilder.Texto(pagina, "", { LayoutOrder = siguiente(), Tamano = "Pequeno", Color = Colores.Verde })
	self.ui.ClaseAviso = UIBuilder.Texto(pagina, "", { LayoutOrder = siguiente(), Tamano = "Pequeno", Color = Colores.TextoApagado })
end

---------------------------------------------------------------------------------------------------
-- Construcción: docente
---------------------------------------------------------------------------------------------------
function ClassroomController:_ConstruirSesionDocente(pagina)
	local orden = 0
	local function siguiente()
		orden = orden + 1
		return orden
	end
	UIBuilder.Subtitulo(pagina, "Sesión de clase", { LayoutOrder = siguiente(), Color = Colores.TextoPrincipal })
	self.ui.SesAula = UIBuilder.Texto(pagina, "", { LayoutOrder = siguiente() })
	self.ui.SesEstado = UIBuilder.Texto(pagina, "", { LayoutOrder = siguiente(), Tamano = "Pequeno", Color = Colores.TextoSecundario })
	local fila = UIBuilder.Fila(pagina, { LayoutOrder = siguiente(), Espaciado = 6 })
	self.ui.BotonAbrirSesion = UIBuilder.Boton(fila, "Abrir sesión", function()
		self:_AbrirSesion()
	end, { Estilo = "Exito", Ancho = 150, LayoutOrder = 1 })
	self.ui.BotonCerrarSesion = UIBuilder.Boton(fila, "Cerrar sesión", function()
		UIBuilder.Confirmar("Cerrar sesión", "Se cerrará la clase para todos los estudiantes del aula. ¿Continuar?", function()
			self:_Accion("CerrarSesion", {}, function()
				self:_Notificar("Sesión cerrada.", "exito")
			end)
		end, "Cerrar sesión", "Peligro")
	end, { Estilo = "Peligro", Ancho = 150, LayoutOrder = 2 })
	UIBuilder.Encadenar({ self.ui.BotonAbrirSesion, self.ui.BotonCerrarSesion }, true)

	UIBuilder.Separador(pagina, { LayoutOrder = siguiente() })
	self.ui.EntradaTema = UIBuilder.Entrada(pagina, "Tema de la clase (máx. " .. self.MaxTema .. ")", {
		Max = self.MaxTema, LayoutOrder = siguiente(), Nombre = "Tema",
	})
	self.ui.BotonTema = UIBuilder.Boton(pagina, "Fijar tema", function()
		local tema = recortar(self.ui.EntradaTema.Text)
		if tema == "" then
			self:_Notificar("Escribe el tema primero.", "aviso")
			return
		end
		self:_Accion("FijarTema", { Tema = tema }, function()
			self:_Notificar("Tema actualizado.", "exito")
		end)
	end, { Estilo = "Secundario", LayoutOrder = siguiente(), Size = UDim2.new(1, 0, 0, UIBuilder.AltoBoton()) })
	self.ui.EntradaAviso = UIBuilder.Entrada(pagina, "Aviso para el aula (máx. " .. self.MaxAviso .. ")", {
		Max = self.MaxAviso, LayoutOrder = siguiente(), Nombre = "Aviso",
	})
	self.ui.BotonAviso = UIBuilder.Boton(pagina, "Enviar aviso al aula", function()
		local texto = recortar(self.ui.EntradaAviso.Text)
		if texto == "" then
			self:_Notificar("Escribe el aviso primero.", "aviso")
			return
		end
		self:_Accion("EnviarAviso", { Texto = texto }, function(d)
			self.ui.EntradaAviso.Text = ""
			self:_Notificar(string.format("Aviso enviado a %d jugador(es) del aula.", tonumber(d.Destinatarios) or 0), "exito")
		end)
	end, { Estilo = "Secundario", LayoutOrder = siguiente(), Size = UDim2.new(1, 0, 0, UIBuilder.AltoBoton()) })
	UIBuilder.Separador(pagina, { LayoutOrder = siguiente() })
	self.ui.BotonTableroDocente = UIBuilder.Boton(pagina, "Ver tablero", function()
		self:_VerTablero()
	end, { Estilo = "Secundario", LayoutOrder = siguiente(), Size = UDim2.new(1, 0, 0, UIBuilder.AltoBoton()) })
	self.ui.SesAyuda = UIBuilder.Texto(pagina, "Abre la sesión dentro de tu aula durante un periodo de clase. Solo los estudiantes presentes reciben las actividades.", {
		LayoutOrder = siguiente(), Tamano = "Pequeno", Color = Colores.TextoApagado,
	})
end

function ClassroomController:_ConstruirActividadDocente(pagina)
	local orden = 0
	local function siguiente()
		orden = orden + 1
		return orden
	end
	UIBuilder.Subtitulo(pagina, "Nueva actividad", { LayoutOrder = siguiente(), Color = Colores.TextoPrincipal })
	self.ui.SelectorTipo = UIBuilder.Selector(pagina, "Tipo", {
		{ Valor = "Opciones", Texto = "Opciones" }, { Valor = "Texto", Texto = "Respuesta libre" },
	}, "Opciones", function()
		self:_RefrescarFormularioActividad()
	end, { LayoutOrder = siguiente(), AnchoGrupo = 200 })
	self.ui.EntradaPregunta = UIBuilder.Entrada(pagina, "Pregunta (máx. 200)", {
		Multilinea = true, Max = 200, Alto = 72, LayoutOrder = siguiente(), Nombre = "Pregunta",
	})
	local marcoOpciones = UIBuilder.Marco(pagina, { AutoAlto = true, LayoutOrder = siguiente(), Nombre = "OpcionesActividad" })
	UIBuilder.Disposicion(marcoOpciones, { Espaciado = 6 })
	self.ui.MarcoOpciones = marcoOpciones
	self.ui.EntradasOpcion = {}
	for i = 1, 4 do
		self.ui.EntradasOpcion[i] = UIBuilder.Entrada(marcoOpciones, "Opción " .. LETRAS[i] .. (i <= 2 and "" or " (opcional)"), {
			Max = 60, LayoutOrder = i, Nombre = "Opcion" .. i,
		})
	end
	local opcionesCorrecta = { { Valor = 0, Texto = "Sin corrección" } }
	for i = 1, 4 do
		table.insert(opcionesCorrecta, { Valor = i, Texto = "Opción " .. LETRAS[i] })
	end
	self.ui.SelectorCorrecta = UIBuilder.Selector(marcoOpciones, "Correcta", opcionesCorrecta, 0, nil, { LayoutOrder = 5, AnchoGrupo = 200 })
	self.ui.SelectorTiempo = UIBuilder.Selector(pagina, "Tiempo", TIEMPOS, 120, nil, { LayoutOrder = siguiente(), AnchoGrupo = 200 })
	self.ui.BotonCrear = UIBuilder.Boton(pagina, "Crear actividad", function()
		self:_CrearActividad()
	end, { Estilo = "Primario", LayoutOrder = siguiente(), Size = UDim2.new(1, 0, 0, UIBuilder.AltoBoton()) })

	UIBuilder.Separador(pagina, { LayoutOrder = siguiente() })
	UIBuilder.Subtitulo(pagina, "Actividad en curso", { LayoutOrder = siguiente() })
	self.ui.DocActInfo = UIBuilder.Texto(pagina, "Ninguna.", { LayoutOrder = siguiente() })
	self.ui.DocActTiempo = UIBuilder.Texto(pagina, "", { LayoutOrder = siguiente(), Tamano = "Pequeno", Color = Colores.Amarillo })
	local fila = UIBuilder.Fila(pagina, { LayoutOrder = siguiente(), Espaciado = 6 })
	self.ui.BotonCerrarAct = UIBuilder.Boton(fila, "Cerrar actividad", function()
		local id = self.actividadDocente and self.actividadDocente.Id or nil
		self:_Accion("CerrarActividad", { ActividadId = id }, function(d)
			if typeof(d.Actividad) == "table" then
				self.actividadDocente = d.Actividad
			end
			if typeof(d.Respuestas) == "table" then
				self.respuestas = d.Respuestas
			end
		end)
	end, { Estilo = "Peligro", Ancho = 160, LayoutOrder = 1, Tamano = "Pequeno" })
	self.ui.BotonPublicar = UIBuilder.Boton(fila, "Publicar resultados", function()
		local id = self.actividadDocente and self.actividadDocente.Id or nil
		self:_Accion("PublicarResultados", { ActividadId = id }, function(d)
			self.resumen = d
			self:_Notificar("Resultados publicados (anónimos) para la clase.", "exito")
		end)
	end, { Estilo = "Secundario", Ancho = 180, LayoutOrder = 2, Tamano = "Pequeno" })
	UIBuilder.Encadenar({ self.ui.BotonCerrarAct, self.ui.BotonPublicar }, true)
	UIBuilder.Subtitulo(pagina, "Último resumen publicado", { LayoutOrder = siguiente() })
	local resumen = UIBuilder.Marco(pagina, { AutoAlto = true, LayoutOrder = siguiente(), Nombre = "Resumen" })
	UIBuilder.Disposicion(resumen, { Espaciado = 4 })
	self.ui.DocResumen = resumen
	self:_RefrescarFormularioActividad()
end

function ClassroomController:_ConstruirRespuestas(pagina)
	UIBuilder.Subtitulo(pagina, "Respuestas", { LayoutOrder = 1, Color = Colores.TextoPrincipal })
	self.ui.RespTitulo = UIBuilder.Texto(pagina, "", { LayoutOrder = 2, Tamano = "Pequeno", Color = Colores.TextoSecundario })
	local lista = UIBuilder.Marco(pagina, { AutoAlto = true, LayoutOrder = 3, Nombre = "ListaRespuestas" })
	UIBuilder.Disposicion(lista, { Espaciado = 6 })
	self.ui.RespLista = lista
	UIBuilder.Texto(pagina, "Solo tú ves las respuestas. La nota y el comentario llegan en privado a cada estudiante.", {
		LayoutOrder = 4, Tamano = "Pequeno", Color = Colores.TextoApagado,
	})
end

function ClassroomController:_ConstruirAlumnos(pagina)
	local orden = 0
	local function siguiente()
		orden = orden + 1
		return orden
	end
	UIBuilder.Subtitulo(pagina, "Alumnos y tablero", { LayoutOrder = siguiente(), Color = Colores.TextoPrincipal })
	local fila = UIBuilder.Fila(pagina, { LayoutOrder = siguiente(), Espaciado = 6 })
	self.ui.BotonAsistencia = UIBuilder.Boton(fila, "Tomar asistencia", function()
		self:_Accion("TomarAsistencia", {}, function(d)
			self.asistencia = d
			self.ocupacion = { Sentados = d.Sentados or {}, DePie = d.DePie or {}, Capacidad = d.Capacidad, Total = d.Total }
			self:_Notificar(string.format("Asistencia: %d presentes.", tonumber(d.Total) or 0), "exito")
		end)
	end, { Estilo = "Primario", Ancho = 170, LayoutOrder = 1, Tamano = "Pequeno" })
	self.ui.BotonRevocar = UIBuilder.Boton(fila, "Revocar tablero", function()
		self:_Accion("RevocarTablero", {}, function()
			self.turno = nil
			self.invitacionDocente = nil
			self:_Notificar("Turno del tablero revocado.", "info")
		end)
	end, { Estilo = "Peligro", Ancho = 160, LayoutOrder = 2, Tamano = "Pequeno" })
	UIBuilder.Encadenar({ self.ui.BotonAsistencia, self.ui.BotonRevocar }, true)
	self.ui.AlTurno = UIBuilder.Texto(pagina, "", { LayoutOrder = siguiente(), Tamano = "Pequeno", Color = Colores.Amarillo })
	self.ui.AlAsistencia = UIBuilder.Texto(pagina, "", { LayoutOrder = siguiente(), Tamano = "Pequeno", Color = Colores.TextoSecundario })

	self.ui.TituloManos = UIBuilder.Subtitulo(pagina, "Manos levantadas", { LayoutOrder = siguiente() })
	local manos = UIBuilder.Marco(pagina, { AutoAlto = true, LayoutOrder = siguiente(), Nombre = "Manos" })
	UIBuilder.Disposicion(manos, { Espaciado = 4 })
	self.ui.AlManos = manos
	self.ui.TituloSentados = UIBuilder.Subtitulo(pagina, "Sentados", { LayoutOrder = siguiente() })
	local sentados = UIBuilder.Marco(pagina, { AutoAlto = true, LayoutOrder = siguiente(), Nombre = "Sentados" })
	UIBuilder.Disposicion(sentados, { Espaciado = 4 })
	self.ui.AlSentados = sentados
	self.ui.TituloDePie = UIBuilder.Subtitulo(pagina, "De pie", { LayoutOrder = siguiente() })
	local dePie = UIBuilder.Marco(pagina, { AutoAlto = true, LayoutOrder = siguiente(), Nombre = "DePie" })
	UIBuilder.Disposicion(dePie, { Espaciado = 4 })
	self.ui.AlDePie = dePie
end

---------------------------------------------------------------------------------------------------
-- Filas reutilizables de las listas
---------------------------------------------------------------------------------------------------
function ClassroomController:_Fila(parent, texto, orden, botones, color)
	local fila = Instance.new("Frame")
	fila.Name = "Fila"
	fila.BackgroundColor3 = color or Colores.Gris
	fila.BackgroundTransparency = 0.35
	fila.BorderSizePixel = 0
	fila.Size = UDim2.new(1, 0, 0, 0)
	fila.AutomaticSize = Enum.AutomaticSize.Y
	fila.LayoutOrder = orden or 0
	UIBuilder.Esquinas(fila, UITheme.RadioPequeno)
	UIBuilder.Relleno(fila, 6, 6, 10, 6)
	UIBuilder.Disposicion(fila, { Espaciado = 4 })
	UIBuilder.Texto(fila, texto, { LayoutOrder = 1, Tamano = "Pequeno" })
	if typeof(botones) == "table" and #botones > 0 then
		local filaBotones = UIBuilder.Fila(fila, { LayoutOrder = 2, Espaciado = 6 })
		local creados = {}
		for i, def in ipairs(botones) do
			local boton = UIBuilder.Boton(filaBotones, def.Texto, def.Accion, {
				Estilo = def.Estilo or "Secundario", Ancho = def.Ancho or 130, LayoutOrder = i, Tamano = "Pequeno",
				Desactivado = def.Desactivado == true,
			})
			table.insert(creados, boton)
		end
		UIBuilder.Encadenar(creados, true)
	end
	fila.Parent = parent
	return fila
end

local function textoVacio(parent, texto)
	UIBuilder.Texto(parent, texto, { Tamano = "Pequeno", Color = Colores.TextoApagado, LayoutOrder = 0 })
end

---------------------------------------------------------------------------------------------------
-- Render dinámico
---------------------------------------------------------------------------------------------------

-- Botones de opción de la actividad del estudiante (solo se rehacen al cambiar de actividad o de estado).
function ClassroomController:_RenderOpciones()
	local marco = self.ui and self.ui.ActOpciones
	if not marco or marco.Parent == nil then
		return
	end
	limpiarHijos(marco)
	local act = self.actividad
	if not act or act.Type ~= "Opciones" or typeof(act.Options) ~= "table" then
		return
	end
	local enClase = self:_EnClase()
	local puede = act.Estado == "Abierta" and self.miRespuesta == nil and enClase and self:_Presente()
		and ahoraServidor() <= (tonumber(act.DueAt) or 0)
	local creados = {}
	for i, texto in ipairs(act.Options) do
		local elegido = self.miRespuesta and self.miRespuesta.Indice == i
		local boton = UIBuilder.Boton(marco, (LETRAS[i] or tostring(i)) .. ")  " .. tostring(texto), function()
			self:_ResponderOpcion(i)
		end, {
			Estilo = elegido and "Primario" or "Secundario", LayoutOrder = i, Size = UDim2.new(1, 0, 0, UIBuilder.AltoBoton()),
			Alineacion = Enum.TextXAlignment.Left, Desactivado = not puede and not elegido,
		})
		if elegido then
			boton:SetAttribute("Desactivado", false)
		end
		table.insert(creados, boton)
	end
	UIBuilder.Encadenar(creados, false)
end

function ClassroomController:_RenderResumen(marco, resumen)
	if not marco or marco.Parent == nil then
		return
	end
	limpiarHijos(marco)
	if typeof(resumen) ~= "table" then
		textoVacio(marco, "Aún no hay resultados publicados.")
		return
	end
	local orden = 0
	local function siguiente()
		orden = orden + 1
		return orden
	end
	UIBuilder.Texto(marco, tostring(resumen.Prompt or ""), { LayoutOrder = siguiente(), Tamano = "Pequeno" })
	local total = tonumber(resumen.Total) or 0
	UIBuilder.Texto(marco, string.format("%d respuesta(s) · %d presente(s)", total, tonumber(resumen.Presentes) or 0), {
		LayoutOrder = siguiente(), Tamano = "Pequeno", Color = Colores.TextoSecundario,
	})
	if typeof(resumen.Opciones) == "table" then
		for i, opcion in ipairs(resumen.Opciones) do
			local marca = opcion.EsCorrecta and "  ✓" or ""
			UIBuilder.Texto(marco, string.format("%s) %s — %d voto(s)%s", LETRAS[i] or tostring(i), tostring(opcion.Texto), tonumber(opcion.Votos) or 0, marca), {
				LayoutOrder = siguiente(), Tamano = "Pequeno", Color = opcion.EsCorrecta and Colores.Verde or Colores.TextoPrincipal,
			})
			local fraccion = 0
			if total > 0 then
				fraccion = (tonumber(opcion.Votos) or 0) / total
			end
			UIBuilder.Barra(marco, fraccion, { LayoutOrder = siguiente(), Color = opcion.EsCorrecta and Colores.Verde or Colores.Azul })
		end
	end
	if resumen.Correctas ~= nil then
		UIBuilder.Texto(marco, string.format("Aciertos: %d (%s)", tonumber(resumen.Correctas) or 0, Format.Porcentaje(resumen.PorcentajeCorrectas or 0)), {
			LayoutOrder = siguiente(), Tamano = "Pequeno", Color = Colores.Verde,
		})
	end
	if resumen.Promedio ~= nil then
		UIBuilder.Texto(marco, string.format("Nota media: %s / 10 (%d calificada(s))", tostring(resumen.Promedio), tonumber(resumen.Calificadas) or 0), {
			LayoutOrder = siguiente(), Tamano = "Pequeno", Color = Colores.TextoSecundario,
		})
	end
end

function ClassroomController:_RenderResultados()
	local marco = self.ui.ActResultados
	if not marco or marco.Parent == nil then
		return
	end
	limpiarHijos(marco)
	if #self.resultados == 0 then
		textoVacio(marco, "Todavía no tienes resultados en esta clase.")
		return
	end
	for i, resultado in ipairs(self.resultados) do
		local partes = { tostring(resultado.Prompt or "Actividad") }
		if resultado.Correcta ~= nil then
			table.insert(partes, resultado.Correcta and "✓ Correcta" or "✗ Incorrecta")
		end
		if resultado.RespuestaCorrecta and resultado.Correcta == false then
			table.insert(partes, "Correcta: " .. tostring(resultado.RespuestaCorrecta))
		end
		if resultado.Puntos ~= nil then
			table.insert(partes, "Nota: " .. tostring(resultado.Puntos) .. " / 10")
		end
		if typeof(resultado.Comentario) == "string" and resultado.Comentario ~= "" then
			table.insert(partes, "“" .. resultado.Comentario .. "”")
		end
		self:_Fila(marco, table.concat(partes, "\n"), i, nil, resultado.Correcta == false and Colores.RojoOscuro or nil)
	end
end

function ClassroomController:_RenderRespuestas()
	local marco = self.ui.RespLista
	if not marco or marco.Parent == nil then
		return
	end
	limpiarHijos(marco)
	local act = self.actividadDocente
	if self.ui.RespTitulo then
		if act then
			self.ui.RespTitulo.Text = string.format("%s · %s · %d respuesta(s)", tostring(act.Prompt), act.Estado == "Abierta" and "abierta" or "cerrada", #self.respuestas)
		else
			self.ui.RespTitulo.Text = "Crea una actividad para recibir respuestas."
		end
	end
	if #self.respuestas == 0 then
		textoVacio(marco, "Sin respuestas todavía.")
		return
	end
	for i, registro in ipairs(self.respuestas) do
		local partes = { tostring(registro.Nombre) .. ": " .. tostring(registro.Respuesta or "") }
		if registro.Correcta ~= nil then
			table.insert(partes, registro.Correcta and "✓ Correcta" or "✗ Incorrecta")
		end
		if registro.Puntos ~= nil then
			local comentario = ""
			if typeof(registro.Comentario) == "string" and registro.Comentario ~= "" then
				comentario = " · “" .. registro.Comentario .. "”"
			end
			table.insert(partes, "Nota: " .. tostring(registro.Puntos) .. " / 10" .. comentario)
		end
		local copia = registro
		self:_Fila(marco, table.concat(partes, "\n"), i, {
			{ Texto = registro.Puntos ~= nil and "Cambiar nota" or "Calificar", Estilo = "Primario", Ancho = 140, Accion = function()
				self:_AbrirCalificar(copia)
			end },
		})
	end
end

function ClassroomController:_RenderAlumnos()
	if not self.ui.AlManos or self.ui.AlManos.Parent == nil then
		return
	end
	local enSesion = self:_SoyDocenteDeSesion()
	local enClase = self:_EnClase()
	limpiarHijos(self.ui.AlManos)
	if #self.manos == 0 then
		textoVacio(self.ui.AlManos, "Nadie tiene la mano levantada.")
	else
		for i, mano in ipairs(self.manos) do
			local id = mano.UserId
			self:_Fila(self.ui.AlManos, "✋  " .. tostring(mano.Nombre), i, {
				{ Texto = "Invitar al tablero", Estilo = "Primario", Ancho = 170, Desactivado = not (enSesion and enClase), Accion = function()
					self:_Invitar(id, mano.Nombre)
				end },
			}, Colores.Azul)
		end
	end
	if self.ui.TituloManos then
		self.ui.TituloManos.Text = "Manos levantadas (" .. #self.manos .. ")"
	end

	local ocupacion = self.ocupacion or { Sentados = {}, DePie = {} }
	local function rellenar(marco, lista, titulo, etiqueta)
		limpiarHijos(marco)
		if titulo then
			titulo.Text = etiqueta .. " (" .. #lista .. ")"
		end
		if #lista == 0 then
			textoVacio(marco, "Nadie.")
			return
		end
		for i, alumno in ipairs(lista) do
			local id = alumno.UserId
			local nombre = alumno.Nombre
			self:_Fila(marco, tostring(nombre), i, {
				{ Texto = "Ver cuaderno", Ancho = 130, Desactivado = not enSesion, Accion = function()
					self:_VerCuadernoDe(id, nombre)
				end },
				{ Texto = "Invitar", Ancho = 100, Desactivado = not (enSesion and enClase), Accion = function()
					self:_Invitar(id, nombre)
				end },
			})
		end
	end
	rellenar(self.ui.AlSentados, ocupacion.Sentados or {}, self.ui.TituloSentados, "Sentados")
	rellenar(self.ui.AlDePie, ocupacion.DePie or {}, self.ui.TituloDePie, "De pie")
end

---------------------------------------------------------------------------------------------------
-- Refresco general
---------------------------------------------------------------------------------------------------
function ClassroomController:_RefrescarTodo()
	if not self.ui or not self.ui.Info or self.ui.Info.Parent == nil then
		return
	end
	local enClase, motivo = self:_EnClase()
	local bannerVisible = (not enClase) and self.modo ~= "Personal"
	if self.ui.Banner.Visible ~= bannerVisible then
		self.ui.Banner.Visible = bannerVisible
		self:_Reubicar()
	end
	self.ui.Banner.Text = motivo or ""

	-- Título e información de cabecera.
	if self.ui.Titulo then
		if self.modo == "Personal" then
			self.ui.Titulo.Text = "Mi cuaderno"
		elseif self.sala then
			self.ui.Titulo.Text = "Aula " .. self.sala .. " · " .. nombreAula(self.sala)
		else
			self.ui.Titulo.Text = "Aula"
		end
	end
	self.ui.Info.Text = self:_TextoInfo()

	if self.modo == "Docente" then
		self:_RefrescarDocente(enClase)
	elseif self.modo == "Estudiante" then
		self:_RefrescarAlumno(enClase)
	end
	self:_RefrescarEstadoCuaderno()
	self:_RefrescarTemporizadores()
end

function ClassroomController:_TextoInfo()
	if self.modo == "Personal" then
		return "Tus apuntes se guardan en tu perfil."
	end
	if not self.sala then
		return "No tienes un aula asignada y no estás en ninguna aula."
	end
	local partes = {}
	if self.aulaActual == self.sala then
		table.insert(partes, "Estás en el aula")
	elseif self.aulaActual then
		table.insert(partes, "Estás en " .. self.aulaActual .. " (no es tu aula)")
	else
		table.insert(partes, "Fuera del aula")
	end
	local estado = self.estado
	if estado and estado.SesionAbierta then
		local clase = "Clase abierta"
		if estado.NombreMateria then
			clase = clase .. " de " .. estado.NombreMateria
		end
		if estado.Docente and estado.DocenteUserId ~= player.UserId then
			clase = clase .. " con " .. estado.Docente
		end
		table.insert(partes, clase)
		if typeof(estado.Tema) == "string" and estado.Tema ~= "" then
			table.insert(partes, "Tema: " .. estado.Tema)
		end
	elseif estado then
		table.insert(partes, "Sin clase en curso")
	else
		table.insert(partes, "Consultando…")
	end
	return table.concat(partes, " · ")
end

function ClassroomController:_RefrescarDocente(enClase)
	local estado = self.estado
	local propia = self:_SoyDocenteDeSesion()
	local otraPersona = estado and estado.SesionAbierta and not propia
	if self.ui.SesAula then
		self.ui.SesAula.Text = self.sala and ("Aula: " .. self.sala .. " — " .. nombreAula(self.sala)) or "Aula: entra en tu aula para dirigir la clase."
	end
	if self.ui.SesEstado then
		if propia then
			local presentes = self.ocupacion and tonumber(self.ocupacion.Total) or 0
			self.ui.SesEstado.Text = string.format("Sesión abierta desde las %s · %d estudiante(s) en el aula%s",
				horaLocal(estado.StartedAt), presentes, estado.NombreMateria and (" · " .. estado.NombreMateria) or "")
			self.ui.SesEstado.TextColor3 = Colores.Verde
		elseif otraPersona then
			self.ui.SesEstado.Text = "Esta aula tiene una sesión abierta por " .. tostring(estado.Docente) .. "."
			self.ui.SesEstado.TextColor3 = Colores.Amarillo
		else
			self.ui.SesEstado.Text = "Sesión cerrada."
			self.ui.SesEstado.TextColor3 = Colores.TextoSecundario
		end
	end
	local puedeAbrir = (not propia) and (not otraPersona) and enClase and self.sala ~= nil
	UIBuilder.Habilitar(self.ui.BotonAbrirSesion, puedeAbrir)
	UIBuilder.Habilitar(self.ui.BotonCerrarSesion, propia)
	UIBuilder.Habilitar(self.ui.BotonTema, propia)
	UIBuilder.Habilitar(self.ui.BotonAviso, propia)
	UIBuilder.Habilitar(self.ui.BotonTableroDocente, self.sala ~= nil)
	UIBuilder.Habilitar(self.ui.BotonCrear, propia and enClase)
	local act = self.actividadDocente
	UIBuilder.Habilitar(self.ui.BotonCerrarAct, propia and act ~= nil and act.Estado == "Abierta")
	UIBuilder.Habilitar(self.ui.BotonPublicar, propia and act ~= nil)
	UIBuilder.Habilitar(self.ui.BotonAsistencia, propia)
	UIBuilder.Habilitar(self.ui.BotonRevocar, propia and (self.turno ~= nil or self.invitacionDocente ~= nil))
	if self.ui.DocActInfo then
		if act then
			self.ui.DocActInfo.Text = string.format("%s\n%s · %d respuesta(s)", tostring(act.Prompt),
				act.Estado == "Abierta" and "Abierta" or "Cerrada", tonumber(act.Respuestas) or #self.respuestas)
		else
			self.ui.DocActInfo.Text = "Ninguna."
		end
	end
	if self.ui.AlAsistencia then
		if self.asistencia then
			self.ui.AlAsistencia.Text = string.format("Última asistencia: %d presente(s) de %d asiento(s).",
				tonumber(self.asistencia.Total) or 0, tonumber(self.asistencia.Capacidad) or 0)
		else
			self.ui.AlAsistencia.Text = "Pulsa «Tomar asistencia» para registrar a los presentes."
		end
	end
	self:_RenderResumen(self.ui.DocResumen, self.resumen)
	self:_RenderRespuestas()
	self:_RenderAlumnos()
end

function ClassroomController:_RefrescarAlumno(enClase)
	local estado = self.estado
	local abierta = self:_SesionAbierta()
	local presente = self:_Presente()
	local act = self.actividad

	-- Actividad
	if self.ui.ActPregunta then
		if act then
			self.ui.ActPregunta.Text = tostring(act.Prompt)
		elseif abierta then
			self.ui.ActPregunta.Text = "No hay ninguna actividad activa. Espera a que el docente publique una."
		else
			self.ui.ActPregunta.Text = "No hay una clase abierta en esta aula."
		end
	end
	local esTexto = act ~= nil and act.Type == "Texto"
	local puedeResponder = act ~= nil and act.Estado == "Abierta" and self.miRespuesta == nil and enClase and presente
		and ahoraServidor() <= (tonumber(act.DueAt) or 0) and not self.enviandoRespuesta
	if self.ui.EntradaRespuesta then
		self.ui.EntradaRespuesta.Visible = esTexto
		self.ui.EntradaRespuesta.TextEditable = puedeResponder
	end
	if self.ui.BotonResponder then
		self.ui.BotonResponder.Visible = esTexto
		UIBuilder.Habilitar(self.ui.BotonResponder, puedeResponder)
	end
	if self.ui.ActEstado then
		if self.miRespuesta then
			self.ui.ActEstado.Text = "Respuesta enviada ✓  (" .. tostring(self.miRespuesta.Respuesta or "") .. ")"
			self.ui.ActEstado.TextColor3 = Colores.Verde
		elseif act and not presente then
			self.ui.ActEstado.Text = "Debes estar dentro del aula para responder."
			self.ui.ActEstado.TextColor3 = Colores.Amarillo
		elseif act and act.Estado ~= "Abierta" then
			self.ui.ActEstado.Text = "La actividad está cerrada."
			self.ui.ActEstado.TextColor3 = Colores.TextoSecundario
		else
			self.ui.ActEstado.Text = ""
		end
	end
	self:_RenderOpciones()
	self:_RenderResultados()
	self:_RenderResumen(self.ui.ActResumen, self.resumen)

	-- Clase
	if self.ui.ClaseInfo then
		if abierta then
			self.ui.ClaseInfo.Text = string.format("Docente: %s%s", tostring(estado.Docente or "—"),
				estado.NombreMateria and ("\nMateria: " .. estado.NombreMateria) or "")
		elseif self.sala then
			self.ui.ClaseInfo.Text = "No hay una clase abierta en " .. self.sala .. "."
		else
			self.ui.ClaseInfo.Text = "No tienes un aula asignada."
		end
	end
	if self.ui.ClaseTema then
		local tema = abierta and estado.Tema or nil
		self.ui.ClaseTema.Text = (typeof(tema) == "string" and tema ~= "") and ("Tema: " .. tema) or ""
		self.ui.ClaseTema.Visible = self.ui.ClaseTema.Text ~= ""
	end
	if self.ui.BotonMano then
		UIBuilder.TextoBoton(self.ui.BotonMano, self.mano and "✋  Bajar la mano" or "✋  Levantar la mano")
		UIBuilder.Habilitar(self.ui.BotonMano, abierta and presente and enClase)
	end
	UIBuilder.Habilitar(self.ui.BotonTableroAlumno, self.sala ~= nil)
	if self.ui.InvCaja then
		self.ui.InvCaja.Visible = self.invitacion ~= nil
		UIBuilder.Habilitar(self.ui.BotonAceptar, self.invitacion ~= nil and enClase and presente)
	end
	if self.ui.ClaseAsistencia then
		self.ui.ClaseAsistencia.Text = self.asistenciaPropia and "Asistencia registrada: presente ✓" or ""
		self.ui.ClaseAsistencia.Visible = self.asistenciaPropia
	end
	if self.ui.ClaseAviso then
		local aviso = ""
		if self.sala and not presente and abierta then
			aviso = "Dirígete al aula " .. self.sala .. " para participar."
		end
		self.ui.ClaseAviso.Text = aviso
		self.ui.ClaseAviso.Visible = aviso ~= ""
	end
end

-- Temporizadores (actividad, invitación, turno). Se llama desde el bucle de 1 Hz.
function ClassroomController:_RefrescarTemporizadores()
	local ahora = ahoraServidor()
	local act = self.actividad
	if self.ui.ActTiempo then
		if act and act.Estado == "Abierta" then
			local restante = (tonumber(act.DueAt) or ahora) - ahora
			if restante > 0 then
				self.ui.ActTiempo.Text = "Tiempo restante: " .. Format.Tiempo(restante)
			else
				self.ui.ActTiempo.Text = "Tiempo agotado."
				if not self._agotadoRender then
					self._agotadoRender = true
					self:_RenderOpciones()
					if self.ui.BotonResponder then
						UIBuilder.Habilitar(self.ui.BotonResponder, false)
					end
				end
			end
		else
			self.ui.ActTiempo.Text = ""
			self._agotadoRender = false
		end
	end
	local actDoc = self.actividadDocente
	if self.ui.DocActTiempo then
		if actDoc and actDoc.Estado == "Abierta" then
			self.ui.DocActTiempo.Text = "Tiempo restante: " .. Format.Tiempo((tonumber(actDoc.DueAt) or ahora) - ahora)
		else
			self.ui.DocActTiempo.Text = ""
		end
	end
	if self.ui.InvTexto and self.invitacion then
		local restante = (tonumber(self.invitacion.Expira) or ahora) - ahora
		if restante <= 0 then
			self.invitacion = nil
			if self.ui.InvCaja then
				self.ui.InvCaja.Visible = false
			end
		else
			self.ui.InvTexto.Text = string.format("%s te invita al tablero. Responde en %d s.",
				tostring(self.invitacion.Docente or "El docente"), math.ceil(restante))
		end
	end
	local textoTurno = ""
	if self.turno and self.turno.Hasta then
		local restante = self.turno.Hasta - ahora
		if restante > 0 then
			local quien = self.turno.UserId == player.UserId and "Tú" or tostring(self.turno.Nombre)
			textoTurno = "Turno del tablero: " .. quien .. " (" .. Format.Tiempo(restante) .. ")"
		else
			self.turno = nil
		end
	end
	if textoTurno == "" and self.invitacionDocente then
		local restante = (tonumber(self.invitacionDocente.Expira) or ahora) - ahora
		if restante > 0 then
			textoTurno = string.format("Invitación pendiente: %s (%d s)", tostring(self.invitacionDocente.Nombre), math.ceil(restante))
		else
			self.invitacionDocente = nil
		end
	end
	if self.ui.ClaseTurno then
		self.ui.ClaseTurno.Text = textoTurno
		self.ui.ClaseTurno.Visible = textoTurno ~= ""
	end
	if self.ui.AlTurno then
		self.ui.AlTurno.Text = textoTurno ~= "" and textoTurno or "Tablero: sin turno de estudiantes."
	end
end

function ClassroomController:_RefrescarFormularioActividad()
	if not self.ui.SelectorTipo or not self.ui.MarcoOpciones then
		return
	end
	self.ui.MarcoOpciones.Visible = self.ui.SelectorTipo:Valor() == "Opciones"
end

---------------------------------------------------------------------------------------------------
-- Acciones del docente
---------------------------------------------------------------------------------------------------
function ClassroomController:_AbrirSesion()
	local sala = self.aulaActual or self.sala
	if not sala then
		self:_Notificar("Entra en tu aula para abrir la sesión.", "aviso")
		return
	end
	local tema = self.ui.EntradaTema and recortar(self.ui.EntradaTema.Text) or ""
	local datos = {}
	if tema ~= "" then
		datos.Tema = tema
	end
	self:_Accion("AbrirSesion", datos, function(d)
		self:_Notificar("Sesión abierta en " .. tostring(d.RoomId or sala) .. ".", "exito")
		self:_AplicarEstado(d)
	end, { Sala = sala })
end

function ClassroomController:_CrearActividad()
	local tipo = self.ui.SelectorTipo:Valor()
	local pregunta = recortar(self.ui.EntradaPregunta.Text)
	if pregunta == "" then
		self:_Notificar("Escribe la pregunta de la actividad.", "aviso")
		return
	end
	local datos = { Type = tipo, Prompt = pregunta, Segundos = self.ui.SelectorTiempo:Valor() }
	if tipo == "Opciones" then
		local opciones = {}
		local mapa = {}
		for i, entrada in ipairs(self.ui.EntradasOpcion) do
			local texto = recortar(entrada.Text)
			if texto ~= "" then
				table.insert(opciones, texto)
				mapa[i] = #opciones
			end
		end
		if #opciones < 2 then
			self:_Notificar("Escribe al menos dos opciones.", "aviso")
			return
		end
		datos.Options = opciones
		local correcta = self.ui.SelectorCorrecta:Valor()
		if correcta and correcta > 0 then
			if not mapa[correcta] then
				self:_Notificar("La opción marcada como correcta está vacía.", "aviso")
				return
			end
			datos.Correcta = mapa[correcta]
		end
	end
	UIBuilder.Habilitar(self.ui.BotonCrear, false)
	self:_Accion("CrearActividad", datos, function(d)
		if typeof(d.Actividad) == "table" then
			self.actividadDocente = d.Actividad
		end
		self.respuestas = {}
		self.ui.EntradaPregunta.Text = ""
		for _, entrada in ipairs(self.ui.EntradasOpcion) do
			entrada.Text = ""
		end
		self.ui.SelectorCorrecta:Fijar(0, true)
	end)
end

function ClassroomController:_Invitar(userId, nombre)
	self:_Accion("InvitarTablero", { ObjetivoUserId = userId }, function(d)
		self.invitacionDocente = { UserId = userId, Nombre = d.Invitado or nombre, Expira = d.Expira }
		self:_Notificar("Invitación al tablero enviada a " .. tostring(d.Invitado or nombre) .. ".", "exito")
	end)
end

function ClassroomController:_AbrirCalificar(registro)
	local actividadId = self.actividadDocente and self.actividadDocente.Id or nil
	local selector, entrada = nil, nil
	UIBuilder.Modal("Calificar a " .. tostring(registro.Nombre), function(cuerpo)
		UIBuilder.Texto(cuerpo, "Respuesta: " .. tostring(registro.Respuesta or "—"), { LayoutOrder = 1, Tamano = "Pequeno", Color = Colores.TextoSecundario })
		local opciones = {}
		for i = 0, 10 do
			table.insert(opciones, { Valor = i, Texto = tostring(i) })
		end
		local inicial = tonumber(registro.Puntos)
		if inicial then
			inicial = math.floor(inicial + 0.5)
		elseif registro.Correcta == true then
			inicial = 10
		elseif registro.Correcta == false then
			inicial = 0
		else
			inicial = 7
		end
		selector = UIBuilder.Selector(cuerpo, "Nota (0–10)", opciones, inicial, nil, { LayoutOrder = 2, AnchoGrupo = 170 })
		entrada = UIBuilder.Entrada(cuerpo, "Comentario privado (opcional, máx. 120)", {
			Max = 120, LayoutOrder = 3, Texto = typeof(registro.Comentario) == "string" and registro.Comentario or "",
		})
	end, {
		{ Texto = "Cancelar", Estilo = "Secundario" },
		{ Texto = "Guardar nota", Estilo = "Primario", Accion = function()
			local datos = { ActividadId = actividadId, ObjetivoUserId = registro.UserId, Puntos = selector and selector:Valor() or 0 }
			local comentario = entrada and recortar(entrada.Text) or ""
			if comentario ~= "" then
				datos.Comentario = comentario
			end
			self:_Accion("Calificar", datos, function(d)
				registro.Puntos = d.Puntos
				registro.Comentario = d.Comentario
				self:_Notificar("Nota enviada en privado a " .. tostring(registro.Nombre) .. ".", "exito")
			end)
		end },
	}, { Ancho = 400 })
end

function ClassroomController:_VerCuadernoDe(userId, nombre)
	task.spawn(function()
		local ok, respuesta = Net.Invocar("NotebookUpdate", { Accion = "Ver", ObjetivoUserId = userId })
		if not ok then
			self:_Notificar(mensajeDe(respuesta), "error")
			return
		end
		local d = respuesta.datos or {}
		UIBuilder.Modal("Cuaderno de " .. tostring(d.Nombre or nombre), function(cuerpo)
			local paginas = typeof(d.Paginas) == "table" and d.Paginas or {}
			if #paginas == 0 then
				UIBuilder.Texto(cuerpo, "Este estudiante no ha compartido páginas.", { LayoutOrder = 1, Color = Colores.TextoSecundario })
				return
			end
			local lista = UIBuilder.Lista(cuerpo, { Espaciado = 6 })
			lista.LayoutOrder = 1
			lista.Size = UDim2.new(1, 0, 0, math.min(360, math.max(160, UIBuilder.AltoUI() * 0.5)))
			for i, pagina in ipairs(paginas) do
				self:_Fila(lista, string.format("Página %d · %s\n%s", tonumber(pagina.Pagina) or i,
					TimetableDefinitions.NombreMateria(pagina.Materia), tostring(pagina.Texto or "")), i)
			end
		end, { { Texto = "Cerrar", Estilo = "Primario" } }, { Ancho = 520 })
	end)
end

---------------------------------------------------------------------------------------------------
-- Acciones del estudiante
---------------------------------------------------------------------------------------------------
function ClassroomController:_ResponderOpcion(indice)
	local act = self.actividad
	if not act or self.miRespuesta or self.enviandoRespuesta then
		return
	end
	self.enviandoRespuesta = true
	self:_Accion("Responder", { ActividadId = act.Id, Indice = indice }, function(d)
		self.miRespuesta = { Indice = indice, Respuesta = act.Options and act.Options[indice] or "", T = d.T }
		self.enviandoRespuesta = false
		self:_Notificar("Respuesta enviada.", "exito", 3)
		self:_RenderOpciones()
	end, { AlFallar = function()
		self.enviandoRespuesta = false
	end })
end

function ClassroomController:_ResponderTexto()
	local act = self.actividad
	if not act or self.miRespuesta or self.enviandoRespuesta or not self.ui.EntradaRespuesta then
		return
	end
	local texto = recortar(self.ui.EntradaRespuesta.Text)
	if texto == "" then
		self:_Notificar("Escribe tu respuesta primero.", "aviso")
		return
	end
	self.enviandoRespuesta = true
	self:_Accion("Responder", { ActividadId = act.Id, Respuesta = texto }, function(d)
		self.miRespuesta = { Respuesta = texto, T = d.T }
		self.enviandoRespuesta = false
		self:_Notificar("Respuesta enviada.", "exito", 3)
	end, { AlFallar = function()
		self.enviandoRespuesta = false
	end })
end

function ClassroomController:_AlternarMano()
	local levantar = not self.mano
	self:_Accion("LevantarMano", { Levantar = levantar }, function(d)
		self.mano = d.Levantada == true
		self:_Notificar(self.mano and "Levantaste la mano." or "Bajaste la mano.", "info", 2)
	end)
end

function ClassroomController:_ResponderInvitacion(aceptar)
	if not self.invitacion then
		return
	end
	self:_Accion("AceptarInvitacion", { Aceptar = aceptar }, function(d)
		self.invitacion = nil
		if d.Aceptada then
			self.turno = { UserId = player.UserId, Nombre = player.DisplayName, Hasta = tonumber(d.Hasta) }
		end
	end, { AlFallar = function()
		self.invitacion = nil
	end })
end

---------------------------------------------------------------------------------------------------
-- Cuaderno
---------------------------------------------------------------------------------------------------
function ClassroomController:_HayPendientes()
	return next(self.pendientes) ~= nil
end

-- Página local n (crea las intermedias vacías como hace el servidor al guardar).
function ClassroomController:_PaginaLocal(n)
	if not self.cuaderno then
		return nil
	end
	local paginas = self.cuaderno.Paginas
	while #paginas < n do
		local materia = (self.jornada and TimetableDefinitions.MateriaDe(self.jornada.Estado)) or "MAT"
		table.insert(paginas, { Pagina = #paginas + 1, Materia = materia, Texto = "", Actualizado = 0, Compartida = false })
	end
	return paginas[n]
end

function ClassroomController:_CargarCuaderno()
	if self.cargandoCuaderno then
		return
	end
	self.cargandoCuaderno = true
	task.spawn(function()
		local ok, respuesta = Net.Invocar("NotebookUpdate", { Accion = "Cargar" })
		self.cargandoCuaderno = false
		if not ok or typeof(respuesta.datos) ~= "table" then
			self:_Notificar(mensajeDe(respuesta), "error")
			return
		end
		local d = respuesta.datos
		local paginas = {}
		for i, pagina in ipairs(d.Paginas or {}) do
			paginas[i] = {
				Pagina = i, Materia = pagina.Materia or "MAT", Texto = tostring(pagina.Texto or ""),
				Actualizado = pagina.Actualizado or 0, Compartida = pagina.Compartida == true,
			}
		end
		-- Conserva los borradores locales que aún no se guardaron.
		if self.cuaderno then
			for n in pairs(self.pendientes) do
				local local_ = self.cuaderno.Paginas[n]
				if local_ then
					paginas[n] = local_
				end
			end
		end
		-- Sin huecos: un borrador más allá de las páginas del servidor deja intermedias vacías (como el servidor).
		local ultima = 0
		for n in pairs(paginas) do
			if typeof(n) == "number" and n > ultima then
				ultima = n
			end
		end
		for n = 1, ultima do
			if paginas[n] == nil then
				paginas[n] = { Pagina = n, Materia = "MAT", Texto = "", Actualizado = 0, Compartida = false }
			end
		end
		self.cuaderno = { Titulo = d.Titulo or "Mi cuaderno", Paginas = paginas }
		if tonumber(d.MaxPaginas) then
			self.MaxPaginas = tonumber(d.MaxPaginas)
		end
		if tonumber(d.EsperaGuardado) and d.EsperaGuardado > 0 then
			self.ultimoGuardado = os.clock() - self.MinIntervaloGuardado + d.EsperaGuardado
		end
		if self.paginaActual > self.MaxPaginas then
			self.paginaActual = 1
		end
		self:_MostrarPaginaCuaderno()
	end)
end

function ClassroomController:_MostrarPaginaCuaderno()
	if not self.cuaderno or not self.ui.EntradaCuaderno then
		return
	end
	local pagina = self:_PaginaLocal(self.paginaActual)
	self._cargandoTexto = true
	self.ui.EntradaCuaderno.Text = pagina.Texto or ""
	if self.ui.SelectorPagina then
		self.ui.SelectorPagina:Fijar(self.paginaActual, true)
	end
	if self.ui.SelectorMateria and TimetableDefinitions.ExisteMateria(pagina.Materia) then
		self.ui.SelectorMateria:Fijar(pagina.Materia, true)
	end
	self._cargandoTexto = false
	if self.ui.CuadernoTitulo then
		self.ui.CuadernoTitulo.Text = tostring(self.cuaderno.Titulo or "Mi cuaderno")
	end
	self:_RefrescarEstadoCuaderno()
end

function ClassroomController:_CambiarPagina(n)
	if not self.cuaderno then
		return
	end
	if self.pendientes[self.paginaActual] then
		self.guardarPronto = true
	end
	self.paginaActual = math.clamp(math.floor(tonumber(n) or 1), 1, self.MaxPaginas)
	self:_MostrarPaginaCuaderno()
end

function ClassroomController:_RefrescarEstadoCuaderno()
	if not self.ui.EstadoGuardado or self.ui.EstadoGuardado.Parent == nil then
		return
	end
	local pagina = self.cuaderno and self.cuaderno.Paginas[self.paginaActual] or nil
	if self.ui.ContadorCuaderno then
		local n = pagina and (utf8.len(pagina.Texto or "") or 0) or 0
		self.ui.ContadorCuaderno.Text = n .. " / " .. self.MaxCaracteres
	end
	local texto, color
	if not self.cuaderno then
		texto, color = "Cargando…", Colores.TextoSecundario
	elseif self.guardando then
		texto, color = "Guardando…", Colores.TextoSecundario
	elseif self:_HayPendientes() then
		texto, color = "Sin guardar", Colores.Amarillo
	else
		texto, color = "Guardado ✓", Colores.Verde
	end
	if pagina and pagina.Compartida then
		texto = texto .. " · Compartida"
	end
	self.ui.EstadoGuardado.Text = texto
	self.ui.EstadoGuardado.TextColor3 = color
	if self.ui.BotonCompartir then
		UIBuilder.TextoBoton(self.ui.BotonCompartir, (pagina and pagina.Compartida) and "Dejar de compartir" or "Compartir")
		UIBuilder.Habilitar(self.ui.BotonCompartir, self.cuaderno ~= nil)
	end
	UIBuilder.Habilitar(self.ui.BotonGuardar, self.cuaderno ~= nil)
	UIBuilder.Habilitar(self.ui.BotonVaciar, self.cuaderno ~= nil)
end

-- Cola de guardado: respeta el mínimo del servidor (1 guardado / 10 s) y el autoguardado periódico.
function ClassroomController:_ProcesarGuardado(forzar)
	if self.guardando or not self.cuaderno or not self:_HayPendientes() then
		return
	end
	local ahora = os.clock()
	if ahora - self.ultimoGuardado < self.MinIntervaloGuardado + 0.25 then
		return
	end
	if not forzar and not self.guardarPronto then
		if ahora - self.ultimoAutoguardado < self.AutoguardadoSeg then
			return
		end
	end
	local numero = nil
	if self.pendientes[self.paginaActual] then
		numero = self.paginaActual
	else
		for n in pairs(self.pendientes) do
			if numero == nil or n < numero then
				numero = n
			end
		end
	end
	if numero then
		self.ultimoAutoguardado = ahora
		self:_Guardar(numero)
	end
end

function ClassroomController:_Guardar(numero)
	local pagina = self.cuaderno and self.cuaderno.Paginas[numero]
	if not pagina then
		self.pendientes[numero] = nil
		return
	end
	self.guardando = true
	self:_RefrescarEstadoCuaderno()
	local textoEnviado = pagina.Texto or ""
	local materiaEnviada = pagina.Materia
	task.spawn(function()
		local datos = { Accion = "Guardar", Pagina = numero, Texto = textoEnviado }
		if TimetableDefinitions.ExisteMateria(materiaEnviada) then
			datos.Materia = materiaEnviada
		end
		local ok, respuesta = Net.Invocar("NotebookUpdate", datos)
		self.guardando = false
		if ok then
			self.ultimoGuardado = os.clock()
			local d = respuesta.datos or {}
			pagina.Actualizado = d.Actualizado or pagina.Actualizado
			pagina.Compartida = d.Compartida == true
			if pagina.Texto == textoEnviado and pagina.Materia == materiaEnviada then
				self.pendientes[numero] = nil
			end
			if not self:_HayPendientes() then
				self.guardarPronto = false
			end
			if typeof(d.Aviso) == "string" then
				self:_Notificar(d.Aviso, "aviso")
			end
		else
			local reintentar = typeof(respuesta.datos) == "table" and tonumber(respuesta.datos.Reintentar) or nil
			if reintentar then
				self.ultimoGuardado = os.clock() - self.MinIntervaloGuardado + reintentar
			else
				self.ultimoGuardado = os.clock()
				if os.clock() - self.ultimoErrorGuardado > 30 then
					self.ultimoErrorGuardado = os.clock()
					self:_Notificar("No se pudo guardar el cuaderno: " .. mensajeDe(respuesta), "error")
				end
			end
		end
		self:_RefrescarEstadoCuaderno()
	end)
end

function ClassroomController:_GuardarAhora()
	if not self.cuaderno then
		return
	end
	if not self:_HayPendientes() then
		self:_Notificar("No hay cambios por guardar.", "info", 2)
		return
	end
	self.guardarPronto = true
	local restante = self.MinIntervaloGuardado + 0.25 - (os.clock() - self.ultimoGuardado)
	if restante > 0 and not self.guardando then
		self:_Notificar(string.format("Se guardará en %d s (máximo un guardado cada %d s).", math.ceil(restante), self.MinIntervaloGuardado), "info", 3)
	end
	self:_ProcesarGuardado(true)
end

function ClassroomController:_Compartir()
	if not self.cuaderno then
		return
	end
	local numero = self.paginaActual
	if self.pendientes[numero] then
		self.guardarPronto = true
		self:_ProcesarGuardado(true)
		self:_Notificar("Guarda la página antes de compartirla (se guardará en unos segundos).", "aviso")
		return
	end
	task.spawn(function()
		local ok, respuesta = Net.Invocar("NotebookUpdate", { Accion = "Compartir", Pagina = numero })
		if not ok then
			self:_Notificar(mensajeDe(respuesta), "error")
			return
		end
		local d = respuesta.datos or {}
		local pagina = self.cuaderno and self.cuaderno.Paginas[numero]
		if pagina then
			pagina.Compartida = d.Compartida == true
		end
		self:_Notificar(d.Compartida and "Página compartida con tu docente." or "La página ya no está compartida.", "exito", 3)
		self:_RefrescarEstadoCuaderno()
	end)
end

function ClassroomController:_ConfirmarVaciar()
	if not self.cuaderno then
		return
	end
	local numero = self.paginaActual
	UIBuilder.Confirmar("Vaciar página", "Se borrará el texto de la página " .. numero .. ". Esta acción no se puede deshacer.", function()
		task.spawn(function()
			local ok, respuesta = Net.Invocar("NotebookUpdate", { Accion = "Vaciar", Pagina = numero })
			if not ok then
				self:_Notificar(mensajeDe(respuesta), "error")
				return
			end
			local pagina = self:_PaginaLocal(numero)
			if pagina then
				pagina.Texto = ""
				pagina.Compartida = false
			end
			self.pendientes[numero] = nil
			if numero == self.paginaActual then
				self:_MostrarPaginaCuaderno()
			end
			self:_Notificar("Página vaciada.", "info", 2)
		end)
	end, "Vaciar", "Peligro")
end

return ClassroomController
