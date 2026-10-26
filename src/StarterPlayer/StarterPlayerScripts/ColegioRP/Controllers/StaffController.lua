--[[
	Ruta en el Explorer: StarterPlayer.StarterPlayerScripts.ColegioRP.Controllers.StaffController
	Tipo: ModuleScript
	Panel de cargo del personal (docs/ARQUITECTURA.md §7): una ScreenGui "ColegioRP_Staff" con pestañas según el
	cargo del jugador (atributo Cargo, se reconstruye al cambiar). Dirección (jornada, anuncios, personal,
	eventos, auditoría, métricas, reportes), coordinación académica (horario, aulas, sesiones), convivencia,
	orientación, enfermería, secretaría, finanzas, recepción/seguridad, limpieza y moderación básica. Se abre
	desde el HUD ("Panel de cargo") o con la tecla P; cierra con Escape / botón B. Solo envía peticiones
	(StaffAction, JornadaControl, AnnouncementBroadcast, ModerationAction, CafeteriaManage) y renderiza: el
	servidor valida todo. Las acciones críticas de moderación y cargos usan confirmación en dos pasos.
	Además oculta localmente los prompts "Limpiar" a quien no es personal de limpieza.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

local StaffController = {}
StaffController.Nombre = "StaffController"
StaffController.TagTarea = "ColegioRP_TareaLimpieza" -- Igual que StaffService.TagTarea.
StaffController.TeclaPanel = Enum.KeyCode.P
StaffController.CacheDireccionSeg = 20 -- Validez de los datos de PanelDirector antes de volver a pedirlos.

local UIBuilder, UITheme, Net, Maid, Format, RoleDefinitions, TimetableDefinitions, MapaLogico, Config, RemoteContracts, Signal
local Colores

local player = Players.LocalPlayer
local LOG = "[ColegioRP][StaffController] "

---------------------------------------------------------------------------------------------------
-- Definición de pestañas
---------------------------------------------------------------------------------------------------
local PESTANAS = {
	Jornada = { Titulo = "Jornada", Metodo = "_TabJornada" },
	Anuncios = { Titulo = "Anuncios", Metodo = "_TabAnuncios" },
	Personal = { Titulo = "Personal", Metodo = "_TabPersonal" },
	Eventos = { Titulo = "Eventos", Metodo = "_TabEventos" },
	Auditoria = { Titulo = "Auditoría", Metodo = "_TabAuditoria" },
	Metricas = { Titulo = "Métricas", Metodo = "_TabMetricas" },
	Reportes = { Titulo = "Reportes", Metodo = "_TabReportes" },
	Horario = { Titulo = "Horario", Metodo = "_TabHorario" },
	Aulas = { Titulo = "Aulas", Metodo = "_TabAulas" },
	Sesiones = { Titulo = "Sesiones", Metodo = "_TabSesiones" },
	Convivencia = { Titulo = "Convivencia", Metodo = "_TabConvivencia" },
	Orientacion = { Titulo = "Agenda", Metodo = "_TabOrientacion" },
	Enfermeria = { Titulo = "Enfermería", Metodo = "_TabEnfermeria" },
	Secretaria = { Titulo = "Secretaría", Metodo = "_TabSecretaria" },
	Finanzas = { Titulo = "Finanzas", Metodo = "_TabFinanzas" },
	Seguridad = { Titulo = "Accesos", Metodo = "_TabSeguridad" },
	Limpieza = { Titulo = "Tareas", Metodo = "_TabLimpieza" },
	Moderacion = { Titulo = "Moderación", Metodo = "_TabModeracion" },
	Info = { Titulo = "Mi cargo", Metodo = "_TabInfo" },
}

local DIRECCION = { "Jornada", "Anuncios", "Personal", "Eventos", "Auditoria", "Metricas", "Reportes" }
local PESTANAS_POR_CARGO = {
	Director = DIRECCION,
	Subdirector = DIRECCION,
	CoordinadorAcademico = { "Horario", "Aulas", "Sesiones", "Jornada", "Anuncios" },
	CoordinadorConvivencia = { "Convivencia", "Reportes", "Anuncios" },
	Orientador = { "Orientacion" },
	Enfermero = { "Enfermeria" },
	Secretario = { "Secretaria", "Reportes" },
	AdministradorFinanciero = { "Finanzas" },
	Recepcionista = { "Seguridad" },
	Seguridad = { "Seguridad" },
	Limpieza = { "Limpieza" },
	ProfesorTitular = { "Info" },
	Tutor = { "Info" },
	ProfesorApoyo = { "Info" },
	Cocinero = { "Info" },
	VendedorCafeteria = { "Info" },
}

-- Eventos escolares (mismos tipos que StaffService.Eventos).
local EVENTOS = {
	{ Tipo = "Deporte", Nombre = "Jornada deportiva", Texto = "Abre la cancha para partidos durante 10 minutos." },
	{ Tipo = "Recreo", Nombre = "Recreo especial", Texto = "Tiempo libre en los patios durante 10 minutos." },
	{ Tipo = "Asamblea", Nombre = "Asamblea general", Texto = "Reúne a todo el colegio en el auditorio." },
}

-- Conceptos de gasto de respaldo (el servidor envía los suyos con el presupuesto).
local CONCEPTOS_RESPALDO = {
	{ Id = "LIMPIEZA", Nombre = "Insumos de limpieza", Precio = 40 },
	{ Id = "PAPELERIA", Nombre = "Papelería y material escolar", Precio = 60 },
	{ Id = "COCINA", Nombre = "Insumos de cocina", Precio = 80 },
	{ Id = "MANTENIMIENTO", Nombre = "Mantenimiento de instalaciones", Precio = 100 },
	{ Id = "DEPORTE", Nombre = "Material deportivo", Precio = 50 },
}

local TEXTOS_JORNADA = {
	Iniciar = "Jornada iniciada.", Pausar = "Jornada en pausa.", Reanudar = "Jornada reanudada.",
	Saltar = "Se pasó al siguiente periodo.", Reiniciar = "Jornada reiniciada.", Configurar = "Configuración aplicada.",
}

local DURACIONES_MODERACION = {
	{ Valor = 60, Texto = "1 minuto" },
	{ Valor = 300, Texto = "5 minutos" },
	{ Valor = 900, Texto = "15 minutos" },
	{ Valor = 1800, Texto = "30 minutos" },
	{ Valor = 3600, Texto = "1 hora" },
}

local AYUDA_CARGO = {
	ProfesorTitular = "Tus herramientas de clase están en el aula: siéntate en el puesto docente o entra en tu salón para abrir la sesión, tomar asistencia, crear actividades y usar el tablero.",
	Tutor = "Acompañas a tu grupo: abre la sesión en tu aula, toma asistencia y envía avisos al aula desde el panel de clase.",
	ProfesorApoyo = "Apoyas al aula adaptada y a otros docentes: usa el panel de clase en el aula donde estés colaborando.",
	Cocinero = "Ve a la cocina y usa las estaciones (preparación, cocción, emplatado) para preparar las raciones del comedor. Reponer raciones también se hace desde la cocina.",
	VendedorCafeteria = "Atiende la tienda escolar desde el mostrador: abre o cierra el puesto, repón productos y haz el cierre de caja.",
}

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

local function contiene(lista, valor)
	for _, v in ipairs(lista) do
		if v == valor then
			return true
		end
	end
	return false
end

local function copiar(tabla)
	local copia = {}
	if typeof(tabla) == "table" then
		for clave, valor in pairs(tabla) do
			copia[clave] = valor
		end
	end
	return copia
end

local function ordenador(inicio)
	local n = inicio or 0
	return function()
		n = n + 1
		return n
	end
end

local function nombreMostrado(p)
	if typeof(p) ~= "Instance" or not p:IsA("Player") then
		return "—"
	end
	local ok, nombre = pcall(function()
		return p.DisplayName
	end)
	if ok and typeof(nombre) == "string" and nombre ~= "" then
		return nombre
	end
	return p.Name
end

local function posicionDe(p)
	local personaje = p and p.Character
	local raiz = personaje and personaje:FindFirstChild("HumanoidRootPart")
	if raiz and raiz:IsA("BasePart") then
		return raiz.Position
	end
	return nil
end

local function distanciaA(p)
	local propia = posicionDe(player)
	local otra = posicionDe(p)
	if propia and otra then
		return (propia - otra).Magnitude
	end
	return nil
end

local function distanciaPunto(punto)
	local propia = posicionDe(player)
	if propia and typeof(punto) == "Vector3" then
		return (propia - punto).Magnitude
	end
	return nil
end

local function textoDistancia(d)
	if d == nil then
		return "sin posición"
	end
	return "a " .. math.floor(d + 0.5) .. " studs"
end

local function ahoraServidor()
	local ok, t = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if ok and typeof(t) == "number" then
		return t
	end
	return os.time()
end

local function horaDe(t)
	local n = tonumber(t)
	if not n then
		return "--:--"
	end
	local ok, texto = pcall(os.date, "%H:%M", math.floor(n))
	if ok and typeof(texto) == "string" then
		return texto
	end
	return "--:--"
end

local function texto(valor)
	if valor == nil then
		return ""
	end
	return tostring(valor)
end

local function anchoTexto(contenido, minimo)
	local n = utf8.len(contenido) or #contenido
	return math.clamp(n * 9 + 36, minimo or 100, 280)
end

local function nombreZona(id)
	local zona = MapaLogico and MapaLogico.Zonas and MapaLogico.Zonas[id]
	if zona and typeof(zona.Nombre) == "string" then
		return zona.Nombre
	end
	return texto(id)
end

-- Destruye los GuiObject hijos (conserva layouts y rellenos).
local function vaciar(contenedor)
	if typeof(contenedor) ~= "Instance" then
		return
	end
	for _, hijo in ipairs(contenedor:GetChildren()) do
		if hijo:IsA("GuiObject") then
			hijo:Destroy()
		end
	end
end

local function linea(parent, contenido, orden, color, props)
	local p = props or {}
	p.LayoutOrder = orden
	p.Tamano = p.Tamano or "Pequeno"
	p.Color = color or p.Color or Colores.TextoPrincipal
	return UIBuilder.Texto(parent, contenido, p)
end

local function seccion(parent, titulo, orden, descripcion)
	local marco = UIBuilder.Marco(parent, { Nombre = "Seccion", AutoAlto = true, LayoutOrder = orden, Color = Colores.Gris, Transparencia = 0.65 })
	UIBuilder.Esquinas(marco, UITheme.RadioPequeno)
	UIBuilder.Relleno(marco, 8, 10, 10, 10)
	UIBuilder.Disposicion(marco, { Espaciado = 6 })
	UIBuilder.Texto(marco, titulo, { Fuente = "Titulo", Tamano = "Subtitulo", LayoutOrder = 1, Nombre = "TituloSeccion" })
	if descripcion then
		UIBuilder.Texto(marco, descripcion, { Tamano = "Pequeno", Color = Colores.TextoApagado, LayoutOrder = 2, Nombre = "Descripcion" })
	end
	return marco
end

-- Fila de botones que salta de línea en pantallas estrechas.
local function botonera(parent, orden)
	local marco = UIBuilder.Marco(parent, { Nombre = "Botonera", AutoAlto = true, LayoutOrder = orden })
	UIBuilder.Disposicion(marco, { Horizontal = true, Espaciado = 6, Wraps = true })
	return marco
end

local function boton(parent, contenido, fn, estilo, orden, ancho)
	return UIBuilder.Boton(parent, contenido, fn, { Estilo = estilo or "Secundario", Ancho = ancho or anchoTexto(contenido), LayoutOrder = orden })
end

-- Fila con texto a la izquierda y un botón a la derecha. Devuelve fila, etiqueta, botón.
local function filaTextoBoton(parent, contenido, textoBoton, fn, orden, estilo, color)
	local fila = UIBuilder.Fila(parent, { LayoutOrder = orden, Nombre = "FilaAccion" })
	local ancho = anchoTexto(textoBoton, 96)
	local etiqueta = UIBuilder.Texto(fila, contenido, {
		Tamano = "Pequeno", Color = color or Colores.TextoPrincipal, AutoAlto = false, Truncar = true,
		AlineacionY = Enum.TextYAlignment.Center, Size = UDim2.new(1, -(ancho + 8), 1, 0), LayoutOrder = 1,
	})
	local b = UIBuilder.Boton(fila, textoBoton, fn, { Estilo = estilo or "Secundario", Ancho = ancho, LayoutOrder = 2 })
	return fila, etiqueta, b
end

local function formatoValor(valor)
	local tipo = typeof(valor)
	if tipo == "number" then
		if math.floor(valor) == valor then
			return Format.Numero(valor)
		end
		return Format.Decimal(valor, 2)
	elseif tipo == "boolean" then
		return valor and "sí" or "no"
	elseif tipo == "Vector3" then
		return string.format("(%d, %d, %d)", math.floor(valor.X), math.floor(valor.Y), math.floor(valor.Z))
	end
	return Format.Truncar(texto(valor), 120)
end

local function clavesOrdenadas(tabla)
	local claves = {}
	for clave in pairs(tabla) do
		table.insert(claves, clave)
	end
	table.sort(claves, function(a, b)
		local na, nb = tonumber(a), tonumber(b)
		if na and nb then
			return na < nb
		end
		return tostring(a) < tostring(b)
	end)
	return claves
end

-- Muestra una tabla genérica como líneas "Clave: valor" (hasta 2 niveles y 40 líneas).
local function renderTabla(caja, oo, tabla, profundidad, cupo)
	profundidad = profundidad or 0
	cupo = cupo or { n = 0 }
	if typeof(tabla) ~= "table" then
		return
	end
	local sangria = string.rep("   ", profundidad)
	for _, clave in ipairs(clavesOrdenadas(tabla)) do
		if cupo.n >= 40 then
			linea(caja, sangria .. "…", oo(), Colores.TextoApagado)
			return
		end
		local valor = tabla[clave]
		cupo.n = cupo.n + 1
		if typeof(valor) == "table" then
			local n = 0
			for _ in pairs(valor) do
				n = n + 1
			end
			if profundidad < 1 and n > 0 and n <= 16 then
				linea(caja, sangria .. tostring(clave) .. ":", oo(), Colores.TextoSecundario)
				renderTabla(caja, oo, valor, profundidad + 1, cupo)
			else
				linea(caja, sangria .. tostring(clave) .. ": " .. n .. " elementos", oo(), Colores.TextoSecundario)
			end
		else
			linea(caja, sangria .. tostring(clave) .. ": " .. formatoValor(valor), oo())
		end
	end
end

-- Texto de una fila genérica (reporte, transacción, venta) con los campos habituales.
local function resumenFila(fila)
	if typeof(fila) ~= "table" then
		return formatoValor(fila)
	end
	local partes = {}
	local hora = fila.T or fila.Fecha or fila.Tiempo
	if tonumber(hora) then
		table.insert(partes, horaDe(hora))
	end
	for _, clave in ipairs({ "Categoria", "Tipo", "Jugador", "Nombre", "Autor", "Ubicacion", "Producto", "Detalle", "Descripcion", "Texto", "Motivo" }) do
		local valor = fila[clave]
		if typeof(valor) == "string" and valor ~= "" then
			table.insert(partes, Format.Truncar(valor, 90))
		end
	end
	local monto = tonumber(fila.Monto) or tonumber(fila.Total) or tonumber(fila.Importe)
	if monto then
		table.insert(partes, Format.Moneda(monto))
	end
	if #partes == 0 then
		for _, clave in ipairs(clavesOrdenadas(fila)) do
			if #partes < 5 and typeof(fila[clave]) ~= "table" then
				table.insert(partes, tostring(clave) .. "=" .. formatoValor(fila[clave]))
			end
		end
	end
	return table.concat(partes, " · ")
end

local function listaDe(valor)
	if typeof(valor) ~= "table" then
		return {}
	end
	if #valor > 0 then
		return valor
	end
	local lista = {}
	for _, clave in ipairs(clavesOrdenadas(valor)) do
		table.insert(lista, valor[clave])
	end
	return lista
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function StaffController:Init(registro)
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
	RemoteContracts = requerir(Shared, "RemoteContracts")
	Net = requerir(Util, "Net")
	Maid = requerir(Util, "Maid")
	Format = requerir(Util, "Format")
	Signal = requerir(Util, "Signal")
	Colores = UITheme.Colores

	self.Abierto = Signal.new()
	self.Cerrado = Signal.new()
	self.maid = Maid.new()
	self.maidPanel = Maid.new()
	self.maidTab = Maid.new()
	self.activo = false
	self.abierto = false
	self.cargo = player:GetAttribute("Cargo")
	self.pestanas = {}
	self.tabActual = nil
	self.tokenTab = 0
	self.refrescos = {}
	self.ui = {}
	-- Cachés de datos del servidor
	self.jornada = nil
	self.evento = nil
	self.propuesta = nil
	self.tareas = {}
	self.limpieza = nil
	self.atendidos = nil
	self.visitas = nil
	self.citas = nil
	self.casos = nil
	self.certificados = nil
	self.director = nil
	self.directorT = -math.huge
	self.accionLimpieza = false
	self.accionPanel = false
end

function StaffController:Start()
	if self.activo then
		return
	end
	self.activo = true

	-- Cargo del jugador (atributo replicado por RoleService).
	self.maid:GiveTask(player:GetAttributeChangedSignal("Cargo"):Connect(function()
		self:_AlCambiarCargo(player:GetAttribute("Cargo"))
	end))

	-- Tecla P (no mientras se escribe ni si el juego ya procesó la tecla).
	self.maid:GiveTask(UserInputService.InputBegan:Connect(function(entrada, procesado)
		if procesado or entrada.KeyCode ~= self.TeclaPanel then
			return
		end
		if UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		self:Alternar()
	end))

	-- Prompts de limpieza: solo visibles para quien puede limpiar (ajuste local).
	self.maid:GiveTask(CollectionService:GetInstanceAddedSignal(self.TagTarea):Connect(function(parte)
		self:_AjustarPromptLimpieza(parte)
	end))
	for _, parte in ipairs(CollectionService:GetTagged(self.TagTarea)) do
		self:_AjustarPromptLimpieza(parte)
	end

	-- Canal servidor -> cliente.
	task.spawn(function()
		local remoto = Net.Evento("EventoCliente")
		if not remoto then
			warn(LOG .. "EventoCliente no disponible; el panel de cargo no recibirá actualizaciones.")
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
			if carga.Tipo == "Personal" then
				ok, err = pcall(self._AlPersonal, self, datos)
			elseif carga.Tipo == "Jornada" then
				ok, err = pcall(self._AlJornada, self, datos)
			elseif carga.Tipo == "Moderacion" then
				ok, err = pcall(self._AlModeracion, self, datos)
			end
			if not ok then
				warn(LOG .. tostring(err))
			end
		end))
	end)

	-- Estado inicial: jornada del HUD y estado personal del servidor (si el cargo tiene panel).
	task.spawn(function()
		local HUD = self.registro.Get("HUDController")
		if HUD and typeof(HUD.Snapshot) == "function" then
			local ok, snapshot = pcall(HUD.Snapshot, HUD)
			if ok and typeof(snapshot) == "table" then
				if typeof(snapshot.Jornada) == "table" then
					self.jornada = snapshot.Jornada
				end
				if typeof(snapshot.Personal) == "table" then
					self:_AplicarEstado(snapshot.Personal)
				end
			end
		end
		task.wait(3)
		if self.activo and self:_EsPersonal() then
			self:_PedirEstado()
		end
	end)

	self:_AlCambiarCargo(self.cargo, true)
end

function StaffController:Destruir()
	self:Cerrar()
	self.activo = false
	self.maidTab:DoCleaning()
	self.maidPanel:DoCleaning()
	self.maid:DoCleaning()
	UIBuilder.Destruir(self.ui.Gui)
	self.ui = {}
end

---------------------------------------------------------------------------------------------------
-- Cargo y pestañas
---------------------------------------------------------------------------------------------------
function StaffController:_Tiene(permiso)
	return RoleDefinitions.Tiene(self.cargo, permiso)
end

function StaffController:_EsDireccion()
	return self:_Tiene("jornada.control") and self:_Tiene("auditoria.ver")
end

function StaffController:_EsPersonal()
	return RoleDefinitions.Existe(self.cargo) and self.cargo ~= "Estudiante"
end

function StaffController:_PestanasPara(cargo)
	local lista = {}
	if not RoleDefinitions.Existe(cargo) or cargo == "Estudiante" then
		return lista
	end
	for _, id in ipairs(PESTANAS_POR_CARGO[cargo] or {}) do
		if PESTANAS[id] and not contiene(lista, id) then
			table.insert(lista, id)
		end
	end
	if RoleDefinitions.Tiene(cargo, "moderacion.basica") and not contiene(lista, "Moderacion") then
		table.insert(lista, "Moderacion")
	end
	if #lista == 0 then
		table.insert(lista, "Info")
	end
	return lista
end

function StaffController:_AlCambiarCargo(cargo, inicial)
	self.cargo = cargo
	self.pestanas = self:_PestanasPara(cargo)
	self.director = nil
	self.directorT = -math.huge
	if not inicial then
		self.tareas = {}
		self.limpieza = nil
		self.atendidos = nil
		self.visitas = nil
		self.citas = nil
		self.casos = nil
		self.certificados = nil
		self.propuesta = nil
	end
	-- Prompts de limpieza según el nuevo cargo.
	for _, parte in ipairs(CollectionService:GetTagged(self.TagTarea)) do
		self:_AjustarPromptLimpieza(parte)
	end
	self:_ActualizarAccionLimpieza()
	self:_ActualizarAccionPanel()
	if self.abierto then
		if #self.pestanas == 0 then
			self:Cerrar()
		else
			self:_PintarCabecera()
			self:_PintarPestanas()
			self:_MostrarTab(self.pestanas[1])
		end
	end
	if not inicial and self:_EsPersonal() then
		task.delay(1, function()
			if self.activo and self.cargo == cargo then
				self:_PedirEstado()
			end
		end)
	end
end

-- El HUD tiene su propio botón "Panel de cargo"; si no lo tuviera se añade como acción contextual.
function StaffController:_ActualizarAccionPanel()
	local HUD = self.registro.Get("HUDController")
	if not HUD or typeof(HUD.AccionContextual) ~= "function" then
		return
	end
	if HUD.botonPanel ~= nil then
		return
	end
	local mostrar = self:_EsPersonal()
	if mostrar ~= self.accionPanel then
		self.accionPanel = mostrar
		pcall(HUD.AccionContextual, HUD, "Panel de cargo", mostrar and function()
			self:Alternar()
		end or nil)
	end
end

-- Acción contextual del HUD con las tareas de limpieza pendientes.
function StaffController:_ActualizarAccionLimpieza()
	local HUD = self.registro.Get("HUDController")
	if not HUD or typeof(HUD.AccionContextual) ~= "function" then
		return
	end
	local mostrar = self:_Tiene("limpieza.tareas") and #self.tareas > 0
	if mostrar ~= self.accionLimpieza then
		self.accionLimpieza = mostrar
		pcall(HUD.AccionContextual, HUD, "Tareas de limpieza", mostrar and function()
			self:Abrir("Limpieza")
		end or nil)
	end
end

function StaffController:_AjustarPromptLimpieza(parte)
	if typeof(parte) ~= "Instance" then
		return
	end
	local puede = self:_Tiene("limpieza.tareas")
	local function ajustar(objeto)
		if objeto:IsA("ProximityPrompt") then
			objeto.Enabled = puede
		end
	end
	for _, descendiente in ipairs(parte:GetDescendants()) do
		ajustar(descendiente)
	end
	if not parte:GetAttribute("ColegioRP_Vigilado") then
		parte:SetAttribute("ColegioRP_Vigilado", true)
		parte.DescendantAdded:Connect(function(objeto)
			if objeto:IsA("ProximityPrompt") then
				objeto.Enabled = self:_Tiene("limpieza.tareas")
			end
		end)
	end
end

---------------------------------------------------------------------------------------------------
-- Eventos del servidor
---------------------------------------------------------------------------------------------------
function StaffController:_AplicarEstado(datos)
	if typeof(datos) ~= "table" then
		return
	end
	self.evento = typeof(datos.EventoActivo) == "table" and datos.EventoActivo or nil
	if typeof(datos.Limpieza) == "table" then
		self.limpieza = datos.Limpieza
		self.tareas = listaDe(datos.Limpieza.Tareas)
	elseif typeof(datos.Tareas) == "table" then
		self.tareas = listaDe(datos.Tareas)
	end
	if typeof(datos.Visitas) == "table" then
		self.visitas = listaDe(datos.Visitas)
	end
	if typeof(datos.Atendidos) == "table" then
		self.atendidos = listaDe(datos.Atendidos)
	end
	if typeof(datos.Citas) == "table" then
		self.citas = listaDe(datos.Citas)
	end
	self:_ActualizarAccionLimpieza()
	for _, clave in ipairs({ "Evento", "Tareas", "Visitas", "Atendidos", "Citas" }) do
		self:_Refrescar(clave)
	end
end

function StaffController:_PedirEstado()
	task.spawn(function()
		local ok, respuesta = Net.Invocar("StaffAction", { Accion = "MiEstado", Datos = {} })
		if ok and typeof(respuesta.datos) == "table" then
			self:_AplicarEstado(respuesta.datos)
		end
	end)
end

function StaffController:_AlJornada(datos)
	if typeof(datos.Estado) ~= "string" then
		return
	end
	self.jornada = datos
	self:_Refrescar("Jornada")
end

function StaffController:_AlPersonal(datos)
	local sub = datos.Sub
	if sub == "Tareas" then
		self.tareas = listaDe(datos.Tareas)
		self.limpieza = datos
		self:_ActualizarAccionLimpieza()
		self:_Refrescar("Tareas")
	elseif sub == "Evento" then
		self.evento = typeof(datos.Evento) == "table" and datos.Evento or nil
		self:_Refrescar("Evento")
	elseif sub == "Atendido" then
		if typeof(datos.Atendidos) == "table" then
			self.atendidos = listaDe(datos.Atendidos)
			self:_Refrescar("Atendidos")
		end
	elseif sub == "Visita" then
		if typeof(datos.Visitas) == "table" then
			self.visitas = listaDe(datos.Visitas)
			self:_Refrescar("Visitas")
		end
	elseif sub == "Cita" then
		if typeof(datos.Citas) == "table" then
			self.citas = listaDe(datos.Citas)
			self:_Refrescar("Citas")
		end
	elseif sub == "Horario" then
		self.propuesta = typeof(datos.Propuesta) == "table" and datos.Propuesta or nil
		self:_Refrescar("Propuesta")
	elseif sub == "Convivencia" then
		if typeof(datos.Casos) == "table" then
			self.casos = listaDe(datos.Casos)
			self:_Refrescar("Casos")
		end
	elseif sub == "Certificado" then
		if typeof(datos.Certificado) == "table" then
			-- Certificado propio (matrícula): el servidor ya lo notifica; queda en un atributo local para el HUD.
			local c = datos.Certificado
			self.miCertificado = c
			pcall(function()
				Players.LocalPlayer:SetAttribute("CertificadoLocal", "Certificado " .. tostring(c.Id or "?") .. (c.Aula and (" · aula " .. tostring(c.Aula)) or ""))
			end)
		end
		if typeof(datos.Certificados) == "table" then
			self.certificados = listaDe(datos.Certificados)
			self:_Refrescar("Certificados")
		end
	end
end

-- Avisos del canal Moderacion para el personal: reportes nuevos (ReportService) y jugadores marcados como
-- sospechosos (RemoteService). Silencios y advertencias ya llegan al implicado como Notificacion.
function StaffController:_AlModeracion(datos)
	if datos.Sub == "Reporte" and typeof(datos.Reporte) == "table" then
		if not (self:_Tiene("reportes.ver") or self:_Tiene("convivencia.gestionar")) then
			return
		end
		local r = datos.Reporte
		local partes = { "Nuevo reporte" }
		local categoria = texto(r.CategoriaNombre or r.Categoria)
		if categoria ~= "" then
			table.insert(partes, categoria)
		end
		local ubicacion = texto(r.Ubicacion)
		if ubicacion ~= "" then
			table.insert(partes, Format.Truncar(ubicacion, 40))
		end
		self:_Toast(table.concat(partes, " · ") .. ": " .. Format.Truncar(texto(r.Descripcion), 100), "aviso")
	elseif datos.Tipo == "Sospechoso" then
		if not self:_Tiene("moderacion.basica") then
			return
		end
		self:_Toast("Moderación: " .. texto(datos.Nombre) .. " acumula " .. texto(datos.Rechazos)
			.. " peticiones rechazadas. Revisa su registro en el panel de cargo.", "aviso")
	end
end

---------------------------------------------------------------------------------------------------
-- Construcción del panel
---------------------------------------------------------------------------------------------------
function StaffController:_Construir()
	local gui = UIBuilder.Pantalla("Staff", (UITheme.Capas and UITheme.Capas.Panel) or 50)
	self.ui.Gui = gui
	local contenedor = UIBuilder.Contenedor(gui, { Nombre = "Contenido" })
	local panel, cuerpo = UIBuilder.Panel(contenedor, {
		Nombre = "PanelCargo",
		Titulo = "Panel de cargo",
		AlCerrar = function()
			self:Cerrar()
		end,
		Size = UDim2.new(1, 0, 1, 0),
	})
	local limite = Instance.new("UISizeConstraint")
	limite.MaxSize = Vector2.new(800, 700)
	limite.Parent = panel
	pcall(function()
		panel.SelectionGroup = true
	end)
	panel.Visible = false
	self.ui.Panel = panel
	local cabecera = panel:FindFirstChild("Cabecera")
	self.ui.Titulo = cabecera and cabecera:FindFirstChild("Titulo") or nil

	local altoPestanas = UIBuilder.AltoBoton() + 8
	local altoEstado = 40
	local barra = UIBuilder.Lista(cuerpo, {
		Horizontal = true, Espaciado = 6, Relleno = false, Nombre = "Pestanas",
		Size = UDim2.new(1, 0, 0, altoPestanas),
	})
	barra.ScrollBarThickness = 4
	self.ui.Barra = barra

	local contenido = UIBuilder.Lista(cuerpo, {
		Espaciado = 8, Nombre = "Contenido",
		Position = UDim2.new(0, 0, 0, altoPestanas + 6),
		Size = UDim2.new(1, 0, 1, -(altoPestanas + altoEstado + 14)),
	})
	self.ui.Contenido = contenido

	self.ui.Estado = UIBuilder.Texto(cuerpo, "", {
		Nombre = "Estado", Tamano = "Pequeno", Color = Colores.TextoSecundario, AutoAlto = false,
		AlineacionY = Enum.TextYAlignment.Center, Size = UDim2.new(1, 0, 0, altoEstado),
		Position = UDim2.new(0, 0, 1, -altoEstado),
	})
end

function StaffController:_AsegurarUI()
	if not self.ui.Gui or self.ui.Gui.Parent == nil or not self.ui.Panel or self.ui.Panel.Parent == nil then
		self:_Construir()
	end
end

function StaffController:_PintarCabecera()
	if self.ui.Titulo then
		local nombre = RoleDefinitions.Existe(self.cargo) and RoleDefinitions.Nombre(self.cargo) or "Sin cargo"
		self.ui.Titulo.Text = "Panel de cargo · " .. nombre
	end
end

function StaffController:_PintarPestanas()
	local barra = self.ui.Barra
	if not barra then
		return
	end
	vaciar(barra)
	self.ui.BotonesPestana = {}
	local lista = {}
	for i, id in ipairs(self.pestanas) do
		local def = PESTANAS[id]
		local titulo = def.Titulo
		if id == "Seguridad" and self.cargo == "Recepcionista" then
			titulo = "Recepción"
		end
		local b = UIBuilder.Boton(barra, titulo, function()
			self:_MostrarTab(id)
		end, {
			Estilo = (id == self.tabActual) and "Primario" or "Secundario", Ancho = anchoTexto(titulo, 96),
			LayoutOrder = i, Nombre = "Pestana_" .. id,
		})
		self.ui.BotonesPestana[id] = b
		table.insert(lista, b)
	end
	UIBuilder.Encadenar(lista, true)
end

function StaffController:_MarcarPestana()
	for id, b in pairs(self.ui.BotonesPestana or {}) do
		if b.Parent ~= nil then
			b:SetAttribute("Estilo", (id == self.tabActual) and "Primario" or "Secundario")
			UIBuilder.Habilitar(b, true)
		end
	end
end

function StaffController:_MostrarTab(id)
	if not contiene(self.pestanas, id) then
		id = self.pestanas[1]
	end
	if not id then
		return
	end
	self.tabActual = id
	self.tokenTab = self.tokenTab + 1
	self.maidTab:DoCleaning()
	self.refrescos = {}
	self:_MarcarPestana()
	self:_Estado("", "Info")
	local contenido = self.ui.Contenido
	vaciar(contenido)
	pcall(function()
		contenido.CanvasPosition = Vector2.new(0, 0)
	end)
	local def = PESTANAS[id]
	local metodo = self[def.Metodo]
	if typeof(metodo) ~= "function" then
		linea(contenido, "Esta sección no está disponible.", 1, Colores.TextoApagado)
		return
	end
	local ok, err = pcall(metodo, self, contenido, ordenador(0))
	if not ok then
		warn(LOG .. "Error al construir la pestaña " .. id .. ": " .. tostring(err))
		linea(contenido, "No se pudo mostrar esta sección: " .. tostring(err), 999, Colores.Error)
	end
end

-- ¿Sigue vigente la pestaña construida con 'token'?
function StaffController:_Vigente(token)
	return self.abierto and token == self.tokenTab
end

-- Registra una zona que se reconstruye con datos nuevos sin tocar el resto de la pestaña.
function StaffController:_Dinamico(parent, orden, clave, construir)
	local caja = UIBuilder.Marco(parent, { Nombre = "Dinamico_" .. clave, AutoAlto = true, LayoutOrder = orden })
	UIBuilder.Disposicion(caja, { Espaciado = 4 })
	local function refrescar()
		if caja.Parent == nil then
			return
		end
		vaciar(caja)
		local ok, err = pcall(construir, caja, ordenador(0))
		if not ok then
			warn(LOG .. "Error al refrescar " .. clave .. ": " .. tostring(err))
			linea(caja, "No se pudo mostrar: " .. tostring(err), 999, Colores.Error)
		end
	end
	self.refrescos[clave] = refrescar
	refrescar()
	return caja, refrescar
end

function StaffController:_Refrescar(clave)
	local fn = self.refrescos and self.refrescos[clave]
	if fn and self.abierto then
		local ok, err = pcall(fn)
		if not ok then
			warn(LOG .. tostring(err))
		end
	end
end

local COLORES_ESTADO = nil
function StaffController:_Estado(contenido, nivel)
	if not COLORES_ESTADO then
		COLORES_ESTADO = { Info = Colores.TextoSecundario, Exito = Colores.Verde, Error = Colores.Rojo, Aviso = Colores.Amarillo }
	end
	local etiqueta = self.ui.Estado
	if etiqueta and etiqueta.Parent ~= nil then
		etiqueta.Text = texto(contenido)
		etiqueta.TextColor3 = COLORES_ESTADO[nivel] or Colores.TextoSecundario
	end
end

function StaffController:_Toast(contenido, nivel)
	local Notificaciones = self.registro.Get("NotificationController")
	if Notificaciones and typeof(Notificaciones.Notificar) == "function" then
		pcall(Notificaciones.Notificar, Notificaciones, contenido, nivel or "info")
	end
end

---------------------------------------------------------------------------------------------------
-- Peticiones al servidor
---------------------------------------------------------------------------------------------------
-- Invoca un remoto en un hilo aparte. alTerminar(ok, datos, respuesta, vigente).
-- opciones: { Boton, Texto (mientras espera), Exito (texto o fn(datos)), Toast (bool), Silencioso (bool) }.
function StaffController:_Pedir(remoto, datos, alTerminar, opciones)
	opciones = opciones or {}
	local token = self.tokenTab
	local b = opciones.Boton
	if b then
		UIBuilder.Habilitar(b, false)
	end
	if not opciones.Silencioso then
		self:_Estado(opciones.Texto or "Enviando…", "Info")
	end
	task.spawn(function()
		local ok, respuesta = Net.Invocar(remoto, datos)
		if b and b.Parent ~= nil then
			UIBuilder.Habilitar(b, true)
		end
		local vigente = self:_Vigente(token)
		local cuerpo = (typeof(respuesta) == "table" and typeof(respuesta.datos) == "table") and respuesta.datos or {}
		if ok then
			local mensaje = opciones.Exito
			if typeof(mensaje) == "function" then
				local okMensaje, resultado = pcall(mensaje, cuerpo)
				mensaje = okMensaje and resultado or nil
			end
			if vigente and not opciones.Silencioso then
				self:_Estado(mensaje or "Listo.", "Exito")
			end
			if opciones.Toast and typeof(mensaje) == "string" and mensaje ~= "" then
				self:_Toast(mensaje, "exito")
			end
		else
			local err = typeof(respuesta) == "table" and respuesta.error or nil
			if not (typeof(err) == "string" and string.sub(err, 1, 8) == "delegar:") then
				local mensaje = UIBuilder.MensajeError(err)
				if vigente then
					self:_Estado(mensaje, "Error")
				else
					self:_Toast(mensaje, "error")
				end
			end
		end
		if typeof(alTerminar) == "function" then
			local okCb, errCb = pcall(alTerminar, ok, cuerpo, respuesta, vigente)
			if not okCb then
				warn(LOG .. tostring(errCb))
			end
		end
	end)
end

function StaffController:_Staff(accion, datos, alTerminar, opciones)
	self:_Pedir("StaffAction", { Accion = accion, Datos = datos or {} }, alTerminar, opciones)
end

-- Datos de PanelDirector con caché breve. alListo(datos) solo si llegan datos.
function StaffController:_DatosDirector(forzar, alListo)
	if not forzar and self.director and os.clock() - self.directorT < self.CacheDireccionSeg then
		if alListo then
			alListo(self.director)
		end
		return
	end
	if self.pidiendoDirector then
		return
	end
	self.pidiendoDirector = true
	self:_Staff("PanelDirector", {}, function(ok, datos)
		self.pidiendoDirector = false
		if not ok then
			return
		end
		self.director = datos
		self.directorT = os.clock()
		if typeof(datos.Jornada) == "table" then
			self.jornada = datos.Jornada
		end
		self.evento = typeof(datos.EventoActivo) == "table" and datos.EventoActivo or nil
		self.propuesta = typeof(datos.Propuesta) == "table" and datos.Propuesta or nil
		if alListo then
			alListo(datos)
		end
	end, { Texto = "Cargando datos de dirección…", Exito = "Datos de dirección actualizados." })
end

-- Acción de moderación o de cargos con confirmación en dos pasos: confirmación local y, si el servidor
-- emite un Token, confirmación final con ConfirmarAccion.
function StaffController:_Moderar(accion, objetivoId, motivo, extra, etiqueta, alTerminar)
	local objetivo = Players:GetPlayerByUserId(objetivoId)
	local nombre = objetivo and nombreMostrado(objetivo) or ("usuario " .. tostring(objetivoId))
	local datos = { Accion = accion, ObjetivoUserId = objetivoId, Motivo = motivo }
	for clave, valor in pairs(extra or {}) do
		datos[clave] = valor
	end
	-- Mismas acciones críticas que ModerationService.Criticas (el servidor emite Token solo para ellas).
	local critica = accion == "Expulsar" or accion == "BloquearTemporal" or accion == "RevocarCargo"
	local mensaje = etiqueta .. " a " .. nombre .. ".\nMotivo: " .. motivo
	if critica then
		mensaje = "Paso 1 de 2 · " .. mensaje
	end
	UIBuilder.Confirmar("Confirmar acción", mensaje, function()
		self:_Pedir("ModerationAction", datos, function(ok, cuerpo)
			if not ok then
				return
			end
			local token = cuerpo.Token
			if typeof(token) ~= "string" and typeof(cuerpo.Confirmacion) == "table" then
				token = cuerpo.Confirmacion.Token
			end
			if typeof(token) == "string" and token ~= "" then
				local textoFinal = cuerpo.Mensaje or cuerpo.Texto
				if typeof(textoFinal) ~= "string" or textoFinal == "" then
					textoFinal = "Paso 2 de 2 · Confirma definitivamente: " .. etiqueta .. " a " .. nombre .. "."
				end
				self:_Estado("Pendiente de confirmación final…", "Aviso")
				UIBuilder.Modal("Confirmación final", textoFinal, {
					{ Texto = "Cancelar", Estilo = "Secundario", Accion = function()
						self:_Estado("Acción cancelada.", "Info")
					end },
					{ Texto = "Confirmar", Estilo = "Peligro", Accion = function()
						local confirmar = copiar(datos)
						confirmar.Accion = "ConfirmarAccion"
						confirmar.Token = token
						self:_Pedir("ModerationAction", confirmar, function(okFinal, cuerpoFinal)
							if alTerminar then
								alTerminar(okFinal, cuerpoFinal)
							end
						end, { Texto = "Confirmando…", Exito = etiqueta .. " aplicado: " .. nombre .. ".", Toast = true })
					end },
				}, { Cerrable = true })
			else
				self:_Estado(etiqueta .. " aplicado: " .. nombre .. ".", "Exito")
				self:_Toast(etiqueta .. " aplicado: " .. nombre .. ".", "exito")
				if alTerminar then
					alTerminar(true, cuerpo)
				end
			end
		end, { Texto = "Enviando…", Silencioso = false, Exito = "Respuesta recibida." })
	end, critica and "Continuar" or "Aplicar", critica and "Peligro" or "Primario")
end

---------------------------------------------------------------------------------------------------
-- Selector de jugadores (lista con búsqueda; nombre mostrado, @usuario, cargo y distancia)
---------------------------------------------------------------------------------------------------
-- props: Alto, Filtro(p) -> bool, IncluirPropio, Multiple, Max, Distancia, PorDistancia, MostrarSalon,
-- Vacio (texto), AlCambiar(control). Devuelve control { Valor(), Valores(), Jugador(), Limpiar(), Refrescar() }.
function StaffController:_SelectorJugadores(parent, orden, props)
	props = props or {}
	local contenedor = UIBuilder.Marco(parent, { Nombre = "SelectorJugadores", AutoAlto = true, LayoutOrder = orden })
	UIBuilder.Disposicion(contenedor, { Espaciado = 4 })
	local control = { Seleccion = {}, Filas = {}, Busqueda = "" }
	local buscador = UIBuilder.Entrada(contenedor, "Buscar por nombre…", {
		Max = 24, LayoutOrder = 1, Nombre = "Buscar",
		AlCambiar = function(valor)
			control.Busqueda = string.lower(Format.Recortar(valor or ""))
			control:Refrescar()
		end,
	})
	local marco = UIBuilder.Marco(contenedor, { Nombre = "ListaJugadores", Alto = props.Alto or 180, LayoutOrder = 2, Color = Colores.Fondo, Transparencia = 0.45 })
	UIBuilder.Esquinas(marco, UITheme.RadioPequeno)
	local lista = UIBuilder.Lista(marco, { Espaciado = 4 })
	local resumen = linea(contenedor, "Nadie seleccionado.", 3, Colores.TextoApagado)
	local multiple = props.Multiple == true
	local maximo = props.Max or 4

	local function textoFila(p)
		local partes = { nombreMostrado(p) .. " (@" .. p.Name .. ")" }
		local cargo = p:GetAttribute("Cargo")
		if RoleDefinitions.Existe(cargo) then
			table.insert(partes, RoleDefinitions.Nombre(cargo))
		end
		if props.MostrarSalon then
			local salon = p:GetAttribute("Salon")
			if typeof(salon) == "string" and salon ~= "" then
				table.insert(partes, "Aula " .. salon)
			else
				table.insert(partes, "sin aula")
			end
		end
		if p:GetAttribute("Atendido") == true and props.MostrarAtendido then
			table.insert(partes, "atendido/a")
		end
		if props.Distancia then
			table.insert(partes, textoDistancia(distanciaA(p)))
		end
		return table.concat(partes, " · ")
	end

	local function pintar()
		local nombres = {}
		for userId, fila in pairs(control.Filas) do
			local seleccionado = control.Seleccion[userId] == true
			if fila.Parent ~= nil then
				fila:SetAttribute("Estilo", seleccionado and "Primario" or "Secundario")
				UIBuilder.Habilitar(fila, true)
			end
		end
		for userId in pairs(control.Seleccion) do
			local p = Players:GetPlayerByUserId(userId)
			if p then
				table.insert(nombres, nombreMostrado(p))
			end
		end
		table.sort(nombres)
		if resumen.Parent ~= nil then
			if #nombres == 0 then
				resumen.Text = multiple and ("Nadie seleccionado (máx. " .. maximo .. ").") or "Nadie seleccionado."
			else
				resumen.Text = "Seleccionado: " .. table.concat(nombres, ", ")
			end
		end
	end

	local function alternar(userId)
		if control.Seleccion[userId] then
			control.Seleccion[userId] = nil
		else
			if not multiple then
				control.Seleccion = {}
			else
				local n = 0
				for _ in pairs(control.Seleccion) do
					n = n + 1
				end
				if n >= maximo then
					self:_Estado("Máximo " .. maximo .. " personas.", "Aviso")
					return
				end
			end
			control.Seleccion[userId] = true
		end
		pintar()
		if typeof(props.AlCambiar) == "function" then
			pcall(props.AlCambiar, control)
		end
	end

	function control:Valor()
		for userId in pairs(self.Seleccion) do
			return userId
		end
		return nil
	end

	function control:Valores()
		local ids = {}
		for userId in pairs(self.Seleccion) do
			table.insert(ids, userId)
		end
		table.sort(ids)
		return ids
	end

	function control:Jugador()
		local userId = self:Valor()
		return userId and Players:GetPlayerByUserId(userId) or nil
	end

	function control:Limpiar()
		self.Seleccion = {}
		pintar()
	end

	function control:Refrescar()
		if marco.Parent == nil then
			return
		end
		vaciar(lista)
		self.Filas = {}
		local jugadores = {}
		for _, p in ipairs(Players:GetPlayers()) do
			local valido = props.IncluirPropio == true or p ~= player
			if valido and typeof(props.Filtro) == "function" then
				local ok, resultado = pcall(props.Filtro, p)
				valido = ok and resultado == true
			end
			if valido and self.Busqueda ~= "" then
				local nombre = string.lower(nombreMostrado(p) .. " " .. p.Name)
				valido = string.find(nombre, self.Busqueda, 1, true) ~= nil
			end
			if valido then
				table.insert(jugadores, p)
			end
		end
		if props.PorDistancia then
			table.sort(jugadores, function(a, b)
				return (distanciaA(a) or math.huge) < (distanciaA(b) or math.huge)
			end)
		else
			table.sort(jugadores, function(a, b)
				return string.lower(nombreMostrado(a)) < string.lower(nombreMostrado(b))
			end)
		end
		-- La selección de jugadores que se fueron se descarta.
		for userId in pairs(self.Seleccion) do
			if not Players:GetPlayerByUserId(userId) then
				self.Seleccion[userId] = nil
			end
		end
		for i, p in ipairs(jugadores) do
			local userId = p.UserId
			local fila = UIBuilder.Boton(lista, textoFila(p), function()
				alternar(userId)
			end, {
				Estilo = self.Seleccion[userId] and "Primario" or "Secundario", Alineacion = Enum.TextXAlignment.Left,
				Size = UDim2.new(1, -6, 0, UIBuilder.AltoBoton()), LayoutOrder = i, Nombre = "J_" .. userId, Tamano = "Pequeno",
			})
			self.Filas[userId] = fila
		end
		if #jugadores == 0 then
			linea(lista, props.Vacio or "No hay jugadores disponibles.", 1, Colores.TextoApagado)
		end
		pintar()
	end

	function control:ActualizarTextos()
		for userId, fila in pairs(self.Filas) do
			local p = Players:GetPlayerByUserId(userId)
			if p and fila.Parent ~= nil then
				fila.Text = textoFila(p)
			end
		end
	end

	control:Refrescar()
	self.maidTab:GiveTask(Players.PlayerAdded:Connect(function()
		control:Refrescar()
	end))
	self.maidTab:GiveTask(Players.PlayerRemoving:Connect(function()
		task.defer(function()
			control:Refrescar()
		end)
	end))
	if props.Distancia or props.MostrarSalon then
		self.maidTab:GiveTask(task.spawn(function()
			while marco.Parent ~= nil do
				task.wait(2)
				if marco.Parent == nil then
					break
				end
				control:ActualizarTextos()
			end
		end))
	end
	control.Buscador = buscador
	return control
end

-- Selector cíclico de aulas (opcionalmente con "Automática" primero).
local function selectorAula(parent, orden, textoEtiqueta, conAutomatica)
	local opciones = {}
	if conAutomatica then
		table.insert(opciones, { Valor = "AUTO", Texto = "Automática" })
	end
	for _, id in ipairs(MapaLogico.Aulas or {}) do
		table.insert(opciones, { Valor = id, Texto = id .. " · " .. nombreZona(id) })
	end
	return UIBuilder.Selector(parent, textoEtiqueta, opciones, opciones[1] and opciones[1].Valor, nil, { LayoutOrder = orden, AnchoGrupo = 250 })
end

local function motivoValido(caja, minimo)
	local valor = Format.Recortar(caja and caja.Text or "")
	if Format.Longitud(valor) < (minimo or 3) then
		return nil
	end
	return valor
end

---------------------------------------------------------------------------------------------------
-- Pestaña: Jornada (Dirección y Coordinación académica)
---------------------------------------------------------------------------------------------------
function StaffController:_TabJornada(cuerpo, o)
	local estado = seccion(cuerpo, "Estado de la jornada", o())
	self:_Dinamico(estado, 10, "Jornada", function(caja, oo)
		local j = self.jornada
		if typeof(j) ~= "table" or typeof(j.Estado) ~= "string" then
			linea(caja, "Esperando datos de la jornada…", oo(), Colores.TextoApagado)
			return
		end
		local nombre = typeof(j.Nombre) == "string" and j.Nombre or TimetableDefinitions.Nombre(j.Estado)
		linea(caja, "Periodo: " .. nombre .. " (" .. j.Estado .. ")", oo())
		if typeof(j.Materia) == "string" and j.Materia ~= "" then
			linea(caja, "Materia: " .. TimetableDefinitions.NombreMateria(j.Materia), oo())
		end
		local modo = j.Modo == "Manual" and "Manual" or "Automática"
		linea(caja, "Modo: " .. modo .. " · " .. (j.Pausada == true and "En pausa" or "En curso"), oo(), j.Pausada == true and Colores.Amarillo or nil)
		if typeof(j.ProximoNombre) == "string" and j.ProximoNombre ~= "" then
			linea(caja, "Siguiente: " .. j.ProximoNombre, oo(), Colores.TextoSecundario)
		end
	end)

	local control = seccion(cuerpo, "Control", o(), "Las órdenes las valida el servidor (permiso de control de jornada).")
	local fila = botonera(control, 10)
	local function enviar(accion, datos, b)
		local peticion = { Accion = accion }
		if datos then
			peticion.Datos = datos
		end
		self:_Pedir("JornadaControl", peticion, nil, { Boton = b, Exito = TEXTOS_JORNADA[accion], Toast = false })
	end
	for i, accion in ipairs({ "Iniciar", "Pausar", "Reanudar", "Saltar" }) do
		local etiquetas = { Iniciar = "Iniciar", Pausar = "Pausar", Reanudar = "Reanudar", Saltar = "Saltar periodo" }
		boton(fila, etiquetas[accion], function(b)
			enviar(accion, nil, b)
		end, accion == "Iniciar" and "Primario" or "Secundario", i, 130)
	end
	boton(fila, "Reiniciar", function()
		UIBuilder.Confirmar("Reiniciar jornada", "La jornada vuelve al inicio y se cierran las sesiones abiertas. ¿Continuar?", function()
			enviar("Reiniciar")
		end, "Reiniciar", "Peligro")
	end, "Peligro", 5, 130)

	local modoActual = (typeof(self.jornada) == "table" and self.jornada.Modo == "Manual") and "Manual" or "Automatica"
	local selectorModo = UIBuilder.Selector(control, "Modo de la jornada", {
		{ Valor = "Automatica", Texto = "Automática" }, { Valor = "Manual", Texto = "Manual" },
	}, modoActual, nil, { LayoutOrder = 11 })
	local filaModo = botonera(control, 12)
	boton(filaModo, "Aplicar modo", function(b)
		enviar("Configurar", { Modo = selectorModo:Valor() }, b)
	end, "Secundario", 1, 150)

	if self:_EsDireccion() then
		local propuesta = seccion(cuerpo, "Propuesta de horario", o(), "Cambios propuestos por coordinación académica pendientes de aprobación.")
		self:_Dinamico(propuesta, 10, "Propuesta", function(caja, oo)
			local p = self.propuesta
			if typeof(p) ~= "table" then
				linea(caja, "No hay propuestas pendientes.", oo(), Colores.TextoApagado)
				return
			end
			linea(caja, "Propone: " .. texto(p.PorNombre) .. " · " .. horaDe(p.T), oo(), Colores.TextoSecundario)
			linea(caja, texto(p.Descripcion), oo())
			local acciones = botonera(caja, oo())
			boton(acciones, "Aprobar", function(b)
				self:_Staff("AprobarHorario", { Aprobar = true, Id = p.Id }, function(ok)
					if ok then
						self.propuesta = nil
						self:_Refrescar("Propuesta")
					end
				end, { Boton = b, Exito = "Horario aprobado y aplicado.", Toast = true })
			end, "Exito", 1, 130)
			boton(acciones, "Rechazar", function(b)
				self:_Staff("AprobarHorario", { Aprobar = false, Id = p.Id }, function(ok)
					if ok then
						self.propuesta = nil
						self:_Refrescar("Propuesta")
					end
				end, { Boton = b, Exito = "Propuesta rechazada." })
			end, "Peligro", 2, 130)
		end)
		if self:_Tiene("horario.editar") then
			self:_Staff("HorarioActual", {}, function(ok, datos, _, vigente)
				if ok then
					self.propuesta = typeof(datos.Propuesta) == "table" and datos.Propuesta or nil
					if vigente then
						self:_Refrescar("Propuesta")
					end
				end
			end, { Silencioso = true })
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Pestaña: Anuncios
---------------------------------------------------------------------------------------------------
function StaffController:_TabAnuncios(cuerpo, o)
	local maximo = (Config.Limites and Config.Limites.MaxAvisoCaracteres) or 160
	local sec = seccion(cuerpo, "Publicar anuncio oficial", o(), "El texto se filtra en el servidor y aparece en el HUD de todos (o solo de tu aula). Máximo 2 anuncios cada 30 s.")
	local contador = nil
	local entrada = UIBuilder.Entrada(sec, "Escribe el anuncio…", {
		Max = maximo, Multilinea = true, Alto = 84, LayoutOrder = 10, Nombre = "TextoAnuncio",
		AlCambiar = function(valor)
			if contador and contador.Parent ~= nil then
				contador.Text = Format.Longitud(valor) .. " / " .. maximo
			end
		end,
	})
	contador = linea(sec, "0 / " .. maximo, 11, Colores.TextoApagado, { Alineacion = Enum.TextXAlignment.Right })
	local alcances = {}
	if self:_Tiene("anuncios.global") then
		table.insert(alcances, { Valor = "Global", Texto = "Todo el colegio" })
	end
	if self:_Tiene("anuncios.aula") then
		table.insert(alcances, { Valor = "Aula", Texto = "Mi aula" })
	end
	if #alcances == 0 then
		linea(sec, "Tu cargo no puede publicar anuncios.", 12, Colores.Amarillo)
		return
	end
	local selector = UIBuilder.Selector(sec, "Alcance", alcances, alcances[1].Valor, nil, { LayoutOrder = 12 })
	local fila = botonera(sec, 13)
	boton(fila, "Publicar anuncio", function(b)
		local valor = Format.Recortar(entrada.Text)
		if Format.Longitud(valor) < 1 then
			self:_Estado("Escribe el texto del anuncio.", "Error")
			return
		end
		self:_Pedir("AnnouncementBroadcast", { Texto = valor, Alcance = selector:Valor() }, function(ok, _, _, vigente)
			if ok and vigente and entrada.Parent ~= nil then
				entrada.Text = ""
			end
		end, { Boton = b, Exito = "Anuncio publicado.", Toast = true })
	end, "Primario", 1, 190)
end

---------------------------------------------------------------------------------------------------
-- Pestaña: Personal (asignar / revocar cargos)
---------------------------------------------------------------------------------------------------
function StaffController:_TabPersonal(cuerpo, o)
	local resumen = seccion(cuerpo, "Personal conectado", o())
	self:_Dinamico(resumen, 10, "ResumenPersonal", function(caja, oo)
		local porEquipo = {}
		for _, p in ipairs(Players:GetPlayers()) do
			local equipo = RoleDefinitions.Equipo(p:GetAttribute("Cargo")) or "Sin cargo"
			porEquipo[equipo] = (porEquipo[equipo] or 0) + 1
		end
		local partes = {}
		for _, equipo in ipairs(RoleDefinitions.OrdenEquipos or {}) do
			if porEquipo[equipo] then
				table.insert(partes, equipo .. ": " .. porEquipo[equipo])
			end
		end
		if porEquipo["Sin cargo"] then
			table.insert(partes, "Sin cargo: " .. porEquipo["Sin cargo"])
		end
		linea(caja, #Players:GetPlayers() .. " jugadores · " .. table.concat(partes, " · "), oo())
	end)
	self.maidTab:GiveTask(Players.PlayerAdded:Connect(function()
		self:_Refrescar("ResumenPersonal")
	end))

	local gestion = seccion(cuerpo, "Asignar o revocar cargo", o(), "Asignar pide confirmación; revocar, confirmación en dos pasos. Ambas quedan auditadas.")
	local selector = self:_SelectorJugadores(gestion, 10, { Alto = 200, MostrarSalon = true })
	local opciones = {}
	for _, rol in ipairs(RoleDefinitions.Lista()) do
		if RoleDefinitions.PuedeAsignar(self.cargo, rol.Id) then
			table.insert(opciones, { Valor = rol.Id, Texto = rol.Nombre })
		end
	end
	local selectorCargo = nil
	if #opciones > 0 then
		selectorCargo = UIBuilder.Selector(gestion, "Cargo a asignar", opciones, opciones[1].Valor, nil, { LayoutOrder = 11, AnchoGrupo = 260 })
	end
	local motivo = UIBuilder.Entrada(gestion, "Motivo (opcional)", { Max = 120, LayoutOrder = 12 })
	local fila = botonera(gestion, 13)
	local function motivoOPorDefecto(porDefecto)
		local valor = Format.Recortar(motivo.Text)
		if Format.Longitud(valor) < 3 then
			return porDefecto
		end
		return valor
	end
	if self:_Tiene("cargos.asignar") and selectorCargo then
		boton(fila, "Asignar cargo", function()
			local userId = selector:Valor()
			if not userId then
				self:_Estado("Selecciona a una persona.", "Error")
				return
			end
			local cargo = selectorCargo:Valor()
			self:_Moderar("AsignarCargo", userId, motivoOPorDefecto("Asignación desde el panel de dirección"), { Cargo = cargo },
				"Asignar el cargo «" .. RoleDefinitions.Nombre(cargo) .. "»", function(ok)
					if ok then
						selector:Refrescar()
						self:_Refrescar("ResumenPersonal")
					end
				end)
		end, "Primario", 1, 160)
	end
	if self:_Tiene("cargos.revocar") then
		boton(fila, "Revocar cargo", function()
			local userId = selector:Valor()
			if not userId then
				self:_Estado("Selecciona a una persona.", "Error")
				return
			end
			self:_Moderar("RevocarCargo", userId, motivoOPorDefecto("Revocación desde el panel de dirección"), nil, "Revocar el cargo", function(ok)
				if ok then
					selector:Refrescar()
					self:_Refrescar("ResumenPersonal")
				end
			end)
		end, "Peligro", 2, 160)
	end
end

---------------------------------------------------------------------------------------------------
-- Pestaña: Eventos
---------------------------------------------------------------------------------------------------
function StaffController:_TabEventos(cuerpo, o)
	local estado = seccion(cuerpo, "Evento activo", o())
	local etiquetaRestante = nil
	self:_Dinamico(estado, 10, "Evento", function(caja, oo)
		etiquetaRestante = nil
		local evento = self.evento
		if typeof(evento) ~= "table" then
			linea(caja, "No hay ningún evento activo.", oo(), Colores.TextoApagado)
			return
		end
		linea(caja, texto(evento.Nombre) .. " · " .. texto(evento.ZonaNombre or evento.Zona), oo(), Colores.Amarillo)
		etiquetaRestante = linea(caja, "", oo(), Colores.TextoSecundario)
		if self:_Tiene("eventos.activar") then
			local fila = botonera(caja, oo())
			boton(fila, "Finalizar evento", function(b)
				self:_Staff("DesactivarEvento", {}, function(ok)
					if ok then
						self.evento = nil
						self:_Refrescar("Evento")
					end
				end, { Boton = b, Exito = "Evento finalizado." })
			end, "Peligro", 1, 170)
		end
	end)
	self.maidTab:GiveTask(task.spawn(function()
		while self.abierto do
			if etiquetaRestante and etiquetaRestante.Parent ~= nil and typeof(self.evento) == "table" then
				local restante = (tonumber(self.evento.Hasta) or 0) - ahoraServidor()
				etiquetaRestante.Text = "Termina en " .. Format.Tiempo(math.max(0, restante)) .. (texto(self.evento.PorNombre) ~= "" and (" · activado por " .. texto(self.evento.PorNombre)) or "")
			end
			task.wait(1)
		end
	end))

	local activar = seccion(cuerpo, "Activar evento escolar", o(), "Cada evento dura 10 minutos, se anuncia a todo el colegio y queda consultable por los demás sistemas.")
	for i, def in ipairs(EVENTOS) do
		filaTextoBoton(activar, def.Nombre .. " — " .. def.Texto, "Activar", function(b)
			self:_Staff("ActivarEvento", { Tipo = def.Tipo }, function(ok, datos)
				if ok then
					self.evento = typeof(datos.Evento) == "table" and datos.Evento or nil
					self:_Refrescar("Evento")
				end
			end, { Boton = b, Exito = def.Nombre .. " activado.", Toast = true })
		end, 10 + i, "Primario")
	end
	if not self.evento then
		self:_Staff("MiEstado", {}, function(ok, datos, _, vigente)
			if ok then
				self.evento = typeof(datos.EventoActivo) == "table" and datos.EventoActivo or nil
				if vigente then
					self:_Refrescar("Evento")
				end
			end
		end, { Silencioso = true })
	end
end

---------------------------------------------------------------------------------------------------
-- Pestañas: Auditoría y Métricas (PanelDirector)
---------------------------------------------------------------------------------------------------
function StaffController:_TabAuditoria(cuerpo, o)
	local sec = seccion(cuerpo, "Registro de auditoría", o(), "Últimas 30 entradas (rechazos de remotos, cargos, moderación, economía y sistema).")
	local fila = botonera(sec, 10)
	boton(fila, "Actualizar", function()
		self:_DatosDirector(true, function()
			self:_Refrescar("Auditoria")
		end)
	end, "Secundario", 1, 130)
	self:_Dinamico(sec, 11, "Auditoria", function(caja, oo)
		local datos = self.director
		if typeof(datos) ~= "table" then
			linea(caja, "Cargando…", oo(), Colores.TextoApagado)
			return
		end
		local entradas = listaDe(datos.Auditoria)
		if #entradas == 0 then
			linea(caja, "Sin entradas.", oo(), Colores.TextoApagado)
			return
		end
		for _, entrada in ipairs(entradas) do
			if typeof(entrada) == "table" then
				local color = nil
				if entrada.Categoria == "Remoto" then
					color = Colores.Amarillo
				elseif entrada.Categoria == "Moderacion" then
					color = Colores.Rojo
				end
				local quien = texto(entrada.Jugador)
				local partes = { horaDe(entrada.T), "[" .. texto(entrada.Categoria) .. "]" }
				if quien ~= "" then
					table.insert(partes, quien)
				end
				table.insert(partes, texto(entrada.Accion))
				local detalle = texto(entrada.Detalle)
				if detalle ~= "" then
					table.insert(partes, "· " .. Format.Truncar(detalle, 140))
				end
				linea(caja, table.concat(partes, " "), oo(), color)
			end
		end
	end)
	self:_DatosDirector(false, function()
		self:_Refrescar("Auditoria")
	end)
end

function StaffController:_TabMetricas(cuerpo, o)
	local sec = seccion(cuerpo, "Métricas del servidor", o(), "Jugadores, FPS reportados por los clientes, rechazos de remotos, memoria y tiempos de respuesta.")
	local fila = botonera(sec, 10)
	boton(fila, "Actualizar", function()
		self:_DatosDirector(true, function()
			self:_Refrescar("Metricas")
		end)
	end, "Secundario", 1, 130)
	self:_Dinamico(sec, 11, "Metricas", function(caja, oo)
		local datos = self.director
		if typeof(datos) ~= "table" then
			linea(caja, "Cargando…", oo(), Colores.TextoApagado)
			return
		end
		if typeof(datos.Resumen) == "table" then
			linea(caja, "Resumen del personal", oo(), Colores.Amarillo, { Fuente = "Subtitulo" })
			renderTabla(caja, oo, datos.Resumen)
		end
		if typeof(datos.Estadisticas) == "table" then
			linea(caja, "Jornada", oo(), Colores.Amarillo, { Fuente = "Subtitulo" })
			renderTabla(caja, oo, datos.Estadisticas)
		end
		if typeof(datos.Metricas) == "table" then
			linea(caja, "Rendimiento", oo(), Colores.Amarillo, { Fuente = "Subtitulo" })
			renderTabla(caja, oo, datos.Metricas)
		else
			linea(caja, "El servicio de métricas no está disponible.", oo(), Colores.TextoApagado)
		end
	end)
	self:_DatosDirector(false, function()
		self:_Refrescar("Metricas")
	end)
end

---------------------------------------------------------------------------------------------------
-- Pestaña: Reportes (dirección, secretaría y convivencia)
---------------------------------------------------------------------------------------------------
function StaffController:_TabReportes(cuerpo, o)
	local sec = seccion(cuerpo, "Reportes de soporte", o(), "Últimos reportes enviados por los jugadores (sin datos personales).")
	local datosReportes = nil
	local fila = botonera(sec, 10)
	local function cargar(b)
		self:_Staff("VerReportes", {}, function(ok, datos, _, vigente)
			if ok then
				datosReportes = datos
				if typeof(datos.Casos) == "table" then
					self.casos = listaDe(datos.Casos)
				end
				if vigente then
					self:_Refrescar("Reportes")
				end
			end
		end, { Boton = b, Texto = "Cargando reportes…", Exito = "Reportes actualizados." })
	end
	boton(fila, "Actualizar", function(b)
		cargar(b)
	end, "Secundario", 1, 130)
	self:_Dinamico(sec, 11, "Reportes", function(caja, oo)
		if typeof(datosReportes) ~= "table" then
			linea(caja, "Cargando…", oo(), Colores.TextoApagado)
			return
		end
		local reportes = listaDe(datosReportes.Reportes)
		if #reportes == 0 then
			linea(caja, "No hay reportes.", oo(), Colores.TextoApagado)
		end
		for _, reporte in ipairs(reportes) do
			linea(caja, "• " .. resumenFila(reporte), oo())
		end
		local incidencias = listaDe(datosReportes.Incidencias)
		if #incidencias > 0 then
			linea(caja, "Incidencias de seguridad", oo(), Colores.Amarillo, { Fuente = "Subtitulo" })
			for _, incidencia in ipairs(incidencias) do
				linea(caja, "• " .. resumenFila(incidencia), oo())
			end
		end
	end)
	cargar(nil)
end

---------------------------------------------------------------------------------------------------
-- Pestañas de coordinación académica: Horario, Aulas, Sesiones
---------------------------------------------------------------------------------------------------
function StaffController:_TabHorario(cuerpo, o)
	local sec = seccion(cuerpo, "Horario de la jornada", o(), "Duración real de cada periodo (15–900 s) y materia de cada clase. Sin dirección conectada puedes aplicarlo directamente.")
	local formulario = { Entradas = {}, Materias = {}, Min = 15, Max = 900 }
	local zonaAplicar = nil
	local function enviar(aplicar, b)
		local duraciones, materias = {}, {}
		local cambios = 0
		for estado, item in pairs(formulario.Entradas) do
			local valor = tonumber(Format.Recortar(item.Caja.Text))
			if valor == nil or math.floor(valor) ~= valor then
				self:_Estado("La duración de " .. TimetableDefinitions.Nombre(estado) .. " debe ser un número entero.", "Error")
				return
			end
			if valor < formulario.Min or valor > formulario.Max then
				self:_Estado("La duración de " .. TimetableDefinitions.Nombre(estado) .. " debe estar entre " .. formulario.Min .. " y " .. formulario.Max .. " s.", "Error")
				return
			end
			if valor ~= item.Original then
				duraciones[estado] = valor
				cambios = cambios + 1
			end
		end
		for estado, item in pairs(formulario.Materias) do
			local codigo = item.Control:Valor()
			if codigo ~= item.Original then
				materias[estado] = codigo
				cambios = cambios + 1
			end
		end
		if cambios == 0 then
			self:_Estado("No hay cambios que guardar.", "Aviso")
			return
		end
		local datos = {}
		if next(duraciones) ~= nil then
			datos.Duraciones = duraciones
		end
		if next(materias) ~= nil then
			datos.Materias = materias
		end
		if aplicar then
			datos.Aplicar = true
		end
		self:_Staff("EditarHorario", datos, function(ok, respuesta, _, vigente)
			if not ok or not vigente then
				return
			end
			if respuesta.Aplicado then
				for estado, valor in pairs(duraciones) do
					formulario.Entradas[estado].Original = valor
				end
				for estado, codigo in pairs(materias) do
					formulario.Materias[estado].Original = codigo
				end
			end
			if zonaAplicar and zonaAplicar.Parent ~= nil then
				vaciar(zonaAplicar)
				if respuesta.Pendiente and respuesta.SinDireccion then
					linea(zonaAplicar, "No hay dirección conectada: puedes aplicar los cambios directamente.", 1, Colores.Amarillo)
					boton(zonaAplicar, "Aplicar sin dirección", function(b2)
						enviar(true, b2)
					end, "Primario", 2, 200)
				end
			end
		end, {
			Boton = b, Texto = "Guardando horario…",
			Exito = function(respuesta)
				if respuesta.Aplicado then
					return "Horario aplicado."
				end
				return "Propuesta enviada a la dirección."
			end,
			Toast = true,
		})
	end

	self:_Dinamico(sec, 10, "Horario", function(caja, oo)
		if typeof(formulario.Periodos) ~= "table" then
			linea(caja, "Cargando horario…", oo(), Colores.TextoApagado)
			return
		end
		formulario.Entradas = {}
		formulario.Materias = {}
		for _, periodo in ipairs(formulario.Periodos) do
			if typeof(periodo) == "table" and typeof(periodo.Estado) == "string" then
				local fila = UIBuilder.Fila(caja, { LayoutOrder = oo(), Nombre = "Periodo_" .. periodo.Estado })
				UIBuilder.Texto(fila, texto(periodo.HoraEscolar) .. " · " .. texto(periodo.Nombre), {
					Tamano = "Pequeno", AutoAlto = false, Truncar = true, AlineacionY = Enum.TextYAlignment.Center,
					Size = UDim2.new(1, -170, 1, 0), LayoutOrder = 1,
				})
				local cajaDuracion = UIBuilder.Entrada(fila, "seg", {
					Max = 3, Texto = tostring(math.floor(tonumber(periodo.Duracion) or 0)), Size = UDim2.new(0, 90, 1, 0), LayoutOrder = 2,
				})
				UIBuilder.Texto(fila, "s", { Tamano = "Pequeno", AutoAlto = false, AlineacionY = Enum.TextYAlignment.Center, Size = UDim2.new(0, 20, 1, 0), LayoutOrder = 3 })
				formulario.Entradas[periodo.Estado] = { Caja = cajaDuracion, Original = math.floor(tonumber(periodo.Duracion) or 0) }
				if periodo.EsClase then
					local opciones = {}
					for _, codigo in ipairs(TimetableDefinitions.OrdenMaterias or {}) do
						table.insert(opciones, { Valor = codigo, Texto = TimetableDefinitions.NombreMateria(codigo) })
					end
					local materia = periodo.Materia or (opciones[1] and opciones[1].Valor)
					local control = UIBuilder.Selector(caja, "Materia · " .. texto(periodo.Nombre), opciones, materia, nil, { LayoutOrder = oo(), AnchoGrupo = 230 })
					formulario.Materias[periodo.Estado] = { Control = control, Original = materia }
				end
			end
		end
		local acciones = botonera(caja, oo())
		boton(acciones, "Guardar cambios", function(b)
			enviar(false, b)
		end, "Primario", 1, 180)
		zonaAplicar = botonera(caja, oo())
	end)

	local propuesta = seccion(cuerpo, "Propuesta pendiente", o())
	self:_Dinamico(propuesta, 10, "Propuesta", function(caja, oo)
		local p = self.propuesta
		if typeof(p) ~= "table" then
			linea(caja, "No hay propuestas pendientes de aprobación.", oo(), Colores.TextoApagado)
			return
		end
		linea(caja, texto(p.Descripcion), oo())
		linea(caja, "Enviada por " .. texto(p.PorNombre) .. " a las " .. horaDe(p.T), oo(), Colores.TextoSecundario)
	end)

	self:_Staff("HorarioActual", {}, function(ok, datos, _, vigente)
		if not ok then
			return
		end
		formulario.Periodos = listaDe(datos.Periodos)
		formulario.Min = tonumber(datos.Min) or 15
		formulario.Max = tonumber(datos.Max) or 900
		self.propuesta = typeof(datos.Propuesta) == "table" and datos.Propuesta or nil
		if vigente then
			self:_Refrescar("Horario")
			self:_Refrescar("Propuesta")
		end
	end, { Texto = "Cargando horario…", Exito = "Horario cargado." })
end

function StaffController:_TabAulas(cuerpo, o)
	local sec = seccion(cuerpo, "Asignar aula", o(), "Estudiantes y docentes conectados. «Reparto automático» usa el reparto equilibrado de la jornada.")
	local selector = self:_SelectorJugadores(sec, 10, {
		Alto = 200, MostrarSalon = true,
		Filtro = function(p)
			local cargo = p:GetAttribute("Cargo")
			return cargo == "Estudiante" or RoleDefinitions.EsDocente(cargo)
		end,
		Vacio = "No hay estudiantes ni docentes conectados.",
		IncluirPropio = self:_Tiene("aula.docente"),
	})
	local aula = selectorAula(sec, 11, "Aula", false)
	local fila = botonera(sec, 12)
	boton(fila, "Asignar aula", function(b)
		local userId = selector:Valor()
		if not userId then
			self:_Estado("Selecciona a una persona.", "Error")
			return
		end
		self:_Staff("AsignarAulaA", { ObjetivoUserId = userId, RoomId = aula:Valor() }, function(ok)
			if ok then
				selector:ActualizarTextos()
			end
		end, {
			Boton = b, Texto = "Asignando aula…", Toast = true,
			Exito = function(datos)
				return texto(datos.Nombre) .. " → aula " .. texto(datos.Aula) .. "."
			end,
		})
	end, "Primario", 1, 150)
	boton(fila, "Reparto automático", function(b)
		local userId = selector:Valor()
		if not userId then
			self:_Estado("Selecciona a una persona.", "Error")
			return
		end
		self:_Staff("ResolverConflicto", { ObjetivoUserId = userId }, function(ok)
			if ok then
				selector:ActualizarTextos()
			end
		end, {
			Boton = b, Texto = "Reasignando…",
			Exito = function(datos)
				return texto(datos.Nombre) .. " → aula " .. texto(datos.Aula) .. "."
			end,
		})
	end, "Secundario", 2, 190)
end

function StaffController:_TabSesiones(cuerpo, o)
	local datosSesiones = nil
	local sec = seccion(cuerpo, "Sesiones y conflictos", o(), "Estado de cada aula: docente, sesión abierta, presentes y ocupación. Los conflictos se pueden reasignar.")
	local function cargar(b)
		self:_Staff("VerSesiones", {}, function(ok, datos, _, vigente)
			if ok then
				datosSesiones = datos
				if vigente then
					self:_Refrescar("Sesiones")
				end
			end
		end, { Boton = b, Texto = "Consultando aulas…", Exito = "Aulas actualizadas." })
	end
	local fila = botonera(sec, 10)
	boton(fila, "Actualizar", function(b)
		cargar(b)
	end, "Secundario", 1, 130)
	self:_Dinamico(sec, 11, "Sesiones", function(caja, oo)
		if typeof(datosSesiones) ~= "table" then
			linea(caja, "Cargando…", oo(), Colores.TextoApagado)
			return
		end
		local conflictos = listaDe(datosSesiones.Conflictos)
		linea(caja, "Conflictos (" .. #conflictos .. ")", oo(), #conflictos > 0 and Colores.Amarillo or Colores.Verde, { Fuente = "Subtitulo" })
		if #conflictos == 0 then
			linea(caja, "Sin conflictos de asignación.", oo(), Colores.TextoApagado)
		end
		for _, conflicto in ipairs(conflictos) do
			if typeof(conflicto) == "table" and tonumber(conflicto.UserId) then
				filaTextoBoton(caja, texto(conflicto.Texto), "Reasignar", function(b)
					self:_Staff("ResolverConflicto", { ObjetivoUserId = tonumber(conflicto.UserId) }, nil, {
						Boton = b, Texto = "Reasignando…",
						Exito = function(datos)
							return texto(datos.Nombre) .. " → aula " .. texto(datos.Aula) .. ". Pulsa «Actualizar» para revisar."
						end,
					})
				end, oo(), "Secundario")
			end
		end
		local aulas = listaDe(datosSesiones.Aulas)
		local vacias = 0
		linea(caja, "Aulas", oo(), Colores.Amarillo, { Fuente = "Subtitulo" })
		for _, a in ipairs(aulas) do
			if typeof(a) == "table" then
				local docentes = listaDe(a.Docentes)
				local conActividad = typeof(a.Sesion) == "table" or (tonumber(a.Estudiantes) or 0) > 0 or #docentes > 0 or (tonumber(a.Sentados) or 0) > 0
				if conActividad then
					local partes = { texto(a.RoomId) .. " · " .. texto(a.Nombre) }
					table.insert(partes, "Docente: " .. (#docentes > 0 and table.concat(docentes, ", ") or "—"))
					table.insert(partes, "Asignados: " .. texto(a.Estudiantes or 0))
					if tonumber(a.Sentados) then
						local capacidad = tonumber(a.Capacidad)
						table.insert(partes, "Sentados: " .. a.Sentados .. (capacidad and ("/" .. capacidad) or "") .. " · De pie: " .. texto(a.DePie or 0))
					end
					if typeof(a.Sesion) == "table" then
						local s = a.Sesion
						table.insert(partes, "Sesión " .. string.lower(texto(s.Estado)) .. " (" .. texto(s.Docente) .. ", " .. texto(s.Presentes or 0) .. " presentes" .. (s.Tema and (", tema: " .. texto(s.Tema)) or "") .. ")")
					else
						table.insert(partes, "Sin sesión")
					end
					if a.Activa == false then
						table.insert(partes, "aula inactiva")
					end
					linea(caja, table.concat(partes, " · "), oo())
				else
					vacias = vacias + 1
				end
			end
		end
		if vacias > 0 then
			linea(caja, vacias .. " aulas sin actividad.", oo(), Colores.TextoApagado)
		end
	end)
	cargar(nil)
end

---------------------------------------------------------------------------------------------------
-- Pestaña: Convivencia
---------------------------------------------------------------------------------------------------
function StaffController:_TabConvivencia(cuerpo, o)
	local caso = seccion(cuerpo, "Registrar caso de convivencia", o(), "Escala por jornada: 1.º aviso verbal, 2.º nota, 3.º citación. Nunca hay castigos automáticos permanentes.")
	local selectorCaso = self:_SelectorJugadores(caso, 10, { Alto = 170, Distancia = true })
	local motivo = UIBuilder.Entrada(caso, "Motivo (mín. 3 caracteres)", { Max = 120, LayoutOrder = 11 })
	local filaCaso = botonera(caso, 12)
	boton(filaCaso, "Registrar caso", function(b)
		local userId = selectorCaso:Valor()
		if not userId then
			self:_Estado("Selecciona a la persona implicada.", "Error")
			return
		end
		local valor = motivoValido(motivo, 3)
		if not valor then
			self:_Estado("Escribe un motivo de al menos 3 caracteres.", "Error")
			return
		end
		self:_Staff("ReporteConvivencia", { ObjetivoUserId = userId, Motivo = valor }, function(ok, _, _, vigente)
			if ok and vigente and motivo.Parent ~= nil then
				motivo.Text = ""
			end
		end, {
			Boton = b, Texto = "Registrando…", Toast = true,
			Exito = function(datos)
				return texto(datos.Nombre) .. ": " .. texto(datos.NivelNombre) .. " (" .. texto(datos.Cantidad) .. ".º caso de la jornada)."
			end,
		})
	end, "Primario", 1, 170)

	local mediacion = seccion(cuerpo, "Mediación", o(), "Selecciona de 2 a 4 participantes. Se les notifica la convocatoria y queda registrada.")
	local selectorMediacion = self:_SelectorJugadores(mediacion, 10, { Alto = 150, Multiple = true, Max = 4 })
	local nota = UIBuilder.Entrada(mediacion, "Nota de la mediación (opcional)", { Max = 160, LayoutOrder = 11 })
	local filaMediacion = botonera(mediacion, 12)
	boton(filaMediacion, "Registrar mediación", function(b)
		local ids = selectorMediacion:Valores()
		if #ids < 2 then
			self:_Estado("Selecciona al menos dos participantes.", "Error")
			return
		end
		self:_Staff("Mediacion", { Participantes = ids, Nota = Format.Recortar(nota.Text) }, function(ok, _, _, vigente)
			if ok and vigente then
				selectorMediacion:Limpiar()
				if nota.Parent ~= nil then
					nota.Text = ""
				end
			end
		end, { Boton = b, Texto = "Registrando mediación…", Exito = "Mediación registrada.", Toast = true })
	end, "Primario", 1, 200)

	local casos = seccion(cuerpo, "Casos de la jornada", o())
	local filaCasos = botonera(casos, 10)
	local function cargar(b)
		self:_Staff("VerReportes", {}, function(ok, datos, _, vigente)
			if ok then
				self.casos = listaDe(datos.Casos)
				self.mediaciones = listaDe(datos.Mediaciones)
				if vigente then
					self:_Refrescar("Casos")
				end
			end
		end, { Boton = b, Texto = "Cargando casos…", Exito = "Casos actualizados." })
	end
	boton(filaCasos, "Actualizar", function(b)
		cargar(b)
	end, "Secundario", 1, 130)
	self:_Dinamico(casos, 11, "Casos", function(caja, oo)
		local lista = self.casos
		if typeof(lista) ~= "table" then
			linea(caja, "Pulsa «Actualizar» para ver los casos.", oo(), Colores.TextoApagado)
			return
		end
		if #lista == 0 then
			linea(caja, "Sin casos registrados en esta jornada.", oo(), Colores.TextoApagado)
		end
		for _, registro in ipairs(lista) do
			if typeof(registro) == "table" then
				local color = registro.Nivel == "Citación" and Colores.Rojo or (registro.Nivel == "Nota de convivencia" and Colores.Amarillo or nil)
				linea(caja, "• " .. texto(registro.Nombre) .. " · " .. texto(registro.Cantidad) .. " caso(s) · " .. texto(registro.Nivel) .. " · último: " .. Format.Truncar(texto(registro.Ultimo), 80) .. (registro.Conectado == false and " (desconectado)" or ""), oo(), color)
			end
		end
		local mediaciones = self.mediaciones or {}
		if #mediaciones > 0 then
			linea(caja, "Mediaciones", oo(), Colores.Amarillo, { Fuente = "Subtitulo" })
			for _, m in ipairs(mediaciones) do
				if typeof(m) == "table" then
					linea(caja, "• " .. texto(m.Hora) .. " · " .. table.concat(listaDe(m.Participantes), ", ") .. (texto(m.Nota) ~= "" and (" · " .. texto(m.Nota)) or ""), oo())
				end
			end
		end
	end)
end

---------------------------------------------------------------------------------------------------
-- Pestaña: Orientación (agenda y recursos)
---------------------------------------------------------------------------------------------------
function StaffController:_TabOrientacion(cuerpo, o)
	local nueva = seccion(cuerpo, "Nueva cita", o(), "Citas de orientación RP (sin tratamiento clínico). La hora es la hora escolar; vacía = ahora.")
	local selector = self:_SelectorJugadores(nueva, 10, { Alto = 160 })
	local motivo = UIBuilder.Entrada(nueva, "Motivo de la cita (opcional)", { Max = 120, LayoutOrder = 11 })
	local hora = UIBuilder.Entrada(nueva, "Hora escolar HH:MM (opcional)", { Max = 5, LayoutOrder = 12 })
	local filaNueva = botonera(nueva, 13)
	boton(filaNueva, "Agendar cita", function(b)
		local userId = selector:Valor()
		if not userId then
			self:_Estado("Selecciona a la persona de la cita.", "Error")
			return
		end
		local datos = { Sub = "Crear", ObjetivoUserId = userId, Motivo = Format.Recortar(motivo.Text) }
		local valorHora = Format.Recortar(hora.Text)
		if valorHora ~= "" then
			if Format.SegundosDeHHMM(valorHora) == nil then
				self:_Estado("La hora debe tener el formato HH:MM.", "Error")
				return
			end
			datos.Hora = valorHora
		end
		self:_Staff("Cita", datos, function(ok, respuesta, _, vigente)
			if ok then
				self.citas = listaDe(respuesta.Citas)
				if vigente then
					motivo.Text = ""
					hora.Text = ""
					selector:Limpiar()
					self:_Refrescar("Citas")
				end
			end
		end, {
			Boton = b, Texto = "Agendando…", Toast = true,
			Exito = function(respuesta)
				local cita = respuesta.Cita or {}
				return "Cita con " .. texto(cita.Nombre) .. " a las " .. texto(cita.Hora) .. "."
			end,
		})
	end, "Primario", 1, 160)

	local agenda = seccion(cuerpo, "Agenda de la jornada", o())
	self:_Dinamico(agenda, 10, "Citas", function(caja, oo)
		local citas = self.citas
		if typeof(citas) ~= "table" then
			linea(caja, "Cargando agenda…", oo(), Colores.TextoApagado)
			return
		end
		if #citas == 0 then
			linea(caja, "No hay citas en esta jornada.", oo(), Colores.TextoApagado)
			return
		end
		for _, cita in ipairs(citas) do
			if typeof(cita) == "table" then
				local descripcion = texto(cita.Hora) .. " · " .. texto(cita.Nombre) .. " · " .. Format.Truncar(texto(cita.Motivo), 60) .. " · " .. texto(cita.Estado)
				if cita.Estado == "Pendiente" then
					local fila = UIBuilder.Marco(caja, { Nombre = "Cita", AutoAlto = true, LayoutOrder = oo() })
					UIBuilder.Disposicion(fila, { Espaciado = 4 })
					linea(fila, descripcion .. (cita.Conectado == false and " (desconectado/a)" or ""), 1)
					local acciones = botonera(fila, 2)
					boton(acciones, "Completar", function(b)
						self:_Staff("Cita", { Sub = "Completar", CitaId = cita.Id }, function(ok, respuesta)
							if ok then
								self.citas = listaDe(respuesta.Citas)
								self:_Refrescar("Citas")
							end
						end, { Boton = b, Exito = "Cita completada." })
					end, "Exito", 1, 130)
					boton(acciones, "Cancelar", function(b)
						self:_Staff("Cita", { Sub = "Cancelar", CitaId = cita.Id }, function(ok, respuesta)
							if ok then
								self.citas = listaDe(respuesta.Citas)
								self:_Refrescar("Citas")
							end
						end, { Boton = b, Exito = "Cita cancelada." })
					end, "Peligro", 2, 130)
				else
					linea(caja, descripcion, oo(), Colores.TextoApagado)
				end
			end
		end
	end)

	local recursos = seccion(cuerpo, "Recursos de bienestar", o(), "Textos orientativos para compartir en la conversación.")
	local datosRecursos = nil
	local filaRecursos = botonera(recursos, 10)
	boton(filaRecursos, "Mostrar recursos", function(b)
		self:_Staff("RecursosBienestar", {}, function(ok, datos, _, vigente)
			if ok then
				datosRecursos = datos
				if vigente then
					self:_Refrescar("Recursos")
				end
			end
		end, { Boton = b, Texto = "Cargando recursos…", Exito = "Recursos cargados." })
	end, "Secundario", 1, 170)
	self:_Dinamico(recursos, 11, "Recursos", function(caja, oo)
		if typeof(datosRecursos) ~= "table" then
			return
		end
		for _, recurso in ipairs(listaDe(datosRecursos.Recursos)) do
			if typeof(recurso) == "table" then
				linea(caja, texto(recurso.Titulo), oo(), Colores.Amarillo, { Fuente = "Subtitulo" })
				linea(caja, texto(recurso.Texto), oo())
			end
		end
		if typeof(datosRecursos.Nota) == "string" then
			linea(caja, datosRecursos.Nota, oo(), Colores.TextoApagado)
		end
	end)

	self:_Staff("Cita", { Sub = "Listar" }, function(ok, datos, _, vigente)
		if ok then
			self.citas = listaDe(datos.Citas)
			if vigente then
				self:_Refrescar("Citas")
			end
		end
	end, { Silencioso = true })
end

---------------------------------------------------------------------------------------------------
-- Pestaña: Enfermería
---------------------------------------------------------------------------------------------------
function StaffController:_TabEnfermeria(cuerpo, o)
	local atender = seccion(cuerpo, "Atender", o(), "La persona debe estar a 10 studs o menos (o ambos en la entrada, donde está la enfermería). Aforo máximo de 4 personas a la vez.")
	local selector = self:_SelectorJugadores(atender, 10, { Alto = 170, Distancia = true, PorDistancia = true, MostrarAtendido = true })
	local fila = botonera(atender, 11)
	boton(fila, "Atender", function(b)
		local userId = selector:Valor()
		if not userId then
			self:_Estado("Selecciona a la persona que vas a atender.", "Error")
			return
		end
		self:_Staff("Atender", { ObjetivoUserId = userId }, function(ok, datos)
			if ok then
				self.atendidos = listaDe(datos.Atendidos)
				self:_Refrescar("Atendidos")
				selector:ActualizarTextos()
			end
		end, {
			Boton = b, Texto = "Atendiendo…", Toast = true,
			Exito = function(datos)
				return texto(datos.Nombre) .. (datos.Renovado and " sigue en atención." or " ha sido atendido/a.")
			end,
		})
	end, "Primario", 1, 140)
	boton(fila, "Ordenar por cercanía", function()
		selector:Refrescar()
	end, "Secundario", 2, 210)

	local actuales = seccion(cuerpo, "En atención ahora", o())
	self:_Dinamico(actuales, 10, "Atendidos", function(caja, oo)
		local lista = self.atendidos
		if typeof(lista) ~= "table" then
			linea(caja, "Cargando…", oo(), Colores.TextoApagado)
			return
		end
		local aforo = (Config.Enfermeria and Config.Enfermeria.AforoMax) or 4
		linea(caja, "Aforo: " .. #lista .. " / " .. aforo, oo(), #lista >= aforo and Colores.Amarillo or Colores.TextoSecundario)
		for _, item in ipairs(lista) do
			if typeof(item) == "table" then
				local restante = (tonumber(item.Hasta) or 0) - ahoraServidor()
				filaTextoBoton(caja, texto(item.Nombre) .. " · quedan " .. Format.Tiempo(math.max(0, restante)), "Dar de alta", function(b)
					self:_Staff("AltaAtendido", { ObjetivoUserId = item.UserId }, function(ok, datos)
						if ok then
							self.atendidos = listaDe(datos.Atendidos)
							self:_Refrescar("Atendidos")
						end
					end, { Boton = b, Exito = "Alta registrada." })
				end, oo(), "Secundario")
			end
		end
	end)
	self.maidTab:GiveTask(task.spawn(function()
		while self.abierto do
			task.wait(5)
			if self.tabActual ~= "Enfermeria" then
				break
			end
			self:_Refrescar("Atendidos")
		end
	end))

	local botiquin = seccion(cuerpo, "Botiquín", o(), "Insumos ficticios de enfermería. Reponer descuenta un gasto del presupuesto del colegio.")
	local datosBotiquin = nil
	local filaBotiquin = botonera(botiquin, 10)
	local function aplicarBotiquin(ok, datos, _, vigente)
		if ok then
			datosBotiquin = listaDe(datos.Botiquin)
			if vigente then
				self:_Refrescar("Botiquin")
			end
		end
	end
	boton(filaBotiquin, "Ver botiquín", function(b)
		self:_Staff("Botiquin", { Sub = "Ver" }, aplicarBotiquin, { Boton = b, Exito = "Botiquín actualizado." })
	end, "Secundario", 1, 150)
	boton(filaBotiquin, "Reponer botiquín", function(b)
		self:_Staff("Botiquin", { Sub = "Reponer" }, aplicarBotiquin, {
			Boton = b, Exito = function(datos)
				return "Botiquín repuesto (" .. texto(datos.Repuesto) .. " unidades)."
			end,
		})
	end, "Primario", 2, 180)
	self:_Dinamico(botiquin, 11, "Botiquin", function(caja, oo)
		if typeof(datosBotiquin) ~= "table" then
			return
		end
		for _, insumo in ipairs(datosBotiquin) do
			if typeof(insumo) == "table" then
				local stock = tonumber(insumo.Stock) or 0
				filaTextoBoton(caja, texto(insumo.Nombre) .. " · " .. stock .. " / " .. texto(insumo.Max), "Usar", function(b)
					self:_Staff("Botiquin", { Sub = "Usar", InsumoId = insumo.Id }, aplicarBotiquin, {
						Boton = b, Exito = "Usado: " .. texto(insumo.Nombre) .. ".",
					})
				end, oo(), "Secundario", stock == 0 and Colores.Rojo or nil)
			end
		end
	end)

	self:_Staff("ListaAtendidos", {}, function(ok, datos, _, vigente)
		if ok then
			self.atendidos = listaDe(datos.Atendidos)
			if vigente then
				self:_Refrescar("Atendidos")
			end
		end
	end, { Silencioso = true })
end

---------------------------------------------------------------------------------------------------
-- Pestaña: Secretaría
---------------------------------------------------------------------------------------------------
function StaffController:_TabSecretaria(cuerpo, o)
	local matricula = seccion(cuerpo, "Matrícula", o(), "Asigna aula a un estudiante y emite su certificado RP (solo nombre mostrado y aula; nunca datos personales).")
	local selector = self:_SelectorJugadores(matricula, 10, {
		Alto = 170, MostrarSalon = true, Vacio = "No hay estudiantes conectados.",
		Filtro = function(p)
			return p:GetAttribute("Cargo") == "Estudiante"
		end,
	})
	local aula = selectorAula(matricula, 11, "Aula", true)
	local resultado = nil
	local fila = botonera(matricula, 12)
	local function mostrarCertificado(certificado)
		if not resultado or resultado.Parent == nil or typeof(certificado) ~= "table" then
			return
		end
		vaciar(resultado)
		linea(resultado, "Certificado " .. texto(certificado.Id) .. " · " .. texto(certificado.Tipo), 1, Colores.Amarillo, { Fuente = "Subtitulo" })
		linea(resultado, texto(certificado.Colegio or Config.NombreColegio), 2, Colores.TextoSecundario)
		linea(resultado, "Se certifica que " .. texto(certificado.Nombre) .. " está inscrito/a en el aula " .. texto(certificado.Aula or "—") .. " (" .. texto(certificado.AulaNombre) .. ").", 3)
		linea(resultado, "Emitido por " .. texto(certificado.Emisor) .. " · hora escolar " .. texto(certificado.Hora), 4, Colores.TextoApagado)
	end
	boton(fila, "Matricular", function(b)
		local userId = selector:Valor()
		if not userId then
			self:_Estado("Selecciona a un estudiante.", "Error")
			return
		end
		local datos = { ObjetivoUserId = userId }
		if aula:Valor() ~= "AUTO" then
			datos.RoomId = aula:Valor()
		end
		self:_Staff("Matricular", datos, function(ok, respuesta, _, vigente)
			if ok and vigente then
				mostrarCertificado(respuesta.Certificado)
				selector:ActualizarTextos()
			end
		end, { Boton = b, Texto = "Matriculando…", Exito = "Matrícula completada.", Toast = true })
	end, "Primario", 1, 150)
	boton(fila, "Emitir constancia", function(b)
		local userId = selector:Valor()
		if not userId then
			self:_Estado("Selecciona a un estudiante.", "Error")
			return
		end
		self:_Staff("Certificado", { Sub = "Emitir", ObjetivoUserId = userId }, function(ok, respuesta, _, vigente)
			if ok then
				self.certificados = listaDe(respuesta.Certificados)
				if vigente then
					mostrarCertificado(respuesta.Certificado)
					self:_Refrescar("Certificados")
				end
			end
		end, { Boton = b, Texto = "Emitiendo…", Exito = "Constancia emitida." })
	end, "Secundario", 2, 180)
	resultado = UIBuilder.Marco(matricula, { Nombre = "Certificado", AutoAlto = true, LayoutOrder = 13 })
	UIBuilder.Disposicion(resultado, { Espaciado = 2 })

	local certificados = seccion(cuerpo, "Certificados emitidos", o())
	local filaCert = botonera(certificados, 10)
	boton(filaCert, "Actualizar", function(b)
		self:_Staff("Certificado", { Sub = "Listar" }, function(ok, respuesta, _, vigente)
			if ok then
				self.certificados = listaDe(respuesta.Certificados)
				if vigente then
					self:_Refrescar("Certificados")
				end
			end
		end, { Boton = b, Exito = "Lista actualizada." })
	end, "Secundario", 1, 130)
	self:_Dinamico(certificados, 11, "Certificados", function(caja, oo)
		local lista = self.certificados
		if typeof(lista) ~= "table" then
			linea(caja, "Pulsa «Actualizar» para ver los certificados de la jornada.", oo(), Colores.TextoApagado)
			return
		end
		if #lista == 0 then
			linea(caja, "Sin certificados en esta jornada.", oo(), Colores.TextoApagado)
		end
		for i = #lista, 1, -1 do
			local c = lista[i]
			if typeof(c) == "table" then
				linea(caja, "• " .. texto(c.Id) .. " · " .. texto(c.Nombre) .. " · " .. texto(c.Tipo) .. " · aula " .. texto(c.Aula or "—") .. " · " .. texto(c.Hora), oo())
			end
		end
	end)

	local asistencia = seccion(cuerpo, "Asistencia por aula", o(), "Estado de asistencia de la clase en curso según la jornada escolar.")
	local aulaAsistencia = selectorAula(asistencia, 10, "Aula", false)
	local datosAsistencia = nil
	local filaAsistencia = botonera(asistencia, 11)
	boton(filaAsistencia, "Consultar asistencia", function(b)
		self:_Staff("Asistencia", { RoomId = aulaAsistencia:Valor() }, function(ok, respuesta, _, vigente)
			if ok then
				datosAsistencia = respuesta
				if vigente then
					self:_Refrescar("Asistencia")
				end
			end
		end, { Boton = b, Texto = "Consultando…", Exito = "Asistencia cargada." })
	end, "Secundario", 1, 200)
	self:_Dinamico(asistencia, 12, "Asistencia", function(caja, oo)
		if typeof(datosAsistencia) ~= "table" then
			return
		end
		linea(caja, "Aula " .. texto(datosAsistencia.RoomId) .. " · " .. texto(datosAsistencia.AulaNombre), oo(), Colores.Amarillo, { Fuente = "Subtitulo" })
		if typeof(datosAsistencia.Clase) == "string" then
			linea(caja, datosAsistencia.Clase .. (typeof(datosAsistencia.Materia) == "string" and (" · " .. datosAsistencia.Materia) or "") .. (datosAsistencia.Activa and " · en curso" or " · cerrada"), oo(), Colores.TextoSecundario)
		end
		local resumen = {}
		for estado, n in pairs(datosAsistencia.Resumen or {}) do
			table.insert(resumen, tostring(estado) .. ": " .. tostring(n))
		end
		table.sort(resumen)
		if #resumen > 0 then
			linea(caja, table.concat(resumen, " · "), oo(), Colores.TextoSecundario)
		end
		local lista = listaDe(datosAsistencia.Lista)
		if #lista == 0 then
			linea(caja, "Sin registros de asistencia para esta aula.", oo(), Colores.TextoApagado)
		end
		for _, registro in ipairs(lista) do
			if typeof(registro) == "table" then
				local color = nil
				if registro.Estado == "Ausente" then
					color = Colores.Rojo
				elseif registro.Estado == "Tardanza" then
					color = Colores.Amarillo
				end
				linea(caja, "• " .. texto(registro.Nombre) .. " — " .. texto(registro.Estado), oo(), color)
			end
		end
	end)
end

---------------------------------------------------------------------------------------------------
-- Pestaña: Finanzas
---------------------------------------------------------------------------------------------------
function StaffController:_TabFinanzas(cuerpo, o)
	local datosPresupuesto = nil
	local presupuesto = seccion(cuerpo, "Presupuesto del colegio", o(), "Presupuesto virtual: ingresos por ventas de la cafetería y gastos ficticios de insumos.")
	self:_Dinamico(presupuesto, 10, "Presupuesto", function(caja, oo)
		local d = datosPresupuesto
		if typeof(d) ~= "table" then
			linea(caja, "Cargando presupuesto…", oo(), Colores.TextoApagado)
			return
		end
		linea(caja, "Inicial: " .. Format.Moneda(d.Inicial) .. " · Ingresos: " .. Format.Moneda(d.Ingresos) .. " (" .. texto(d.Ventas or 0) .. " ventas)", oo())
		linea(caja, "Gastos: " .. Format.Moneda(d.Gastos) .. " · Saldo: " .. Format.Moneda(d.Saldo), oo(), (tonumber(d.Saldo) or 0) < 0 and Colores.Rojo or Colores.Verde, { Fuente = "Subtitulo" })
		if d.CafeteriaDisponible == false then
			linea(caja, "La cafetería no está disponible: los ingresos pueden estar incompletos.", oo(), Colores.Amarillo)
		end
		local gastos = listaDe(d.DetalleGastos)
		if #gastos > 0 then
			linea(caja, "Últimos gastos", oo(), Colores.TextoSecundario)
			for _, g in ipairs(gastos) do
				if typeof(g) == "table" then
					linea(caja, "• " .. horaDe(g.T) .. " · " .. texto(g.Nombre) .. " x" .. texto(g.Cantidad) .. " · " .. Format.Moneda(g.Monto) .. " · " .. texto(g.Por), oo())
				end
			end
		end
	end)
	local function aplicar(ok, datos, _, vigente)
		if ok then
			datosPresupuesto = datos
			if vigente then
				self:_Refrescar("Presupuesto")
			end
		end
	end

	local gasto = seccion(cuerpo, "Registrar gasto", o())
	local opcionesConcepto = {}
	for _, concepto in ipairs(CONCEPTOS_RESPALDO) do
		table.insert(opcionesConcepto, { Valor = concepto.Id, Texto = concepto.Nombre .. " (" .. Format.Moneda(concepto.Precio) .. ")" })
	end
	local selectorConcepto = UIBuilder.Selector(gasto, "Concepto", opcionesConcepto, opcionesConcepto[1].Valor, nil, { LayoutOrder = 10, AnchoGrupo = 300 })
	local cantidades = {}
	for i = 1, 5 do
		table.insert(cantidades, { Valor = i, Texto = tostring(i) })
	end
	local selectorCantidad = UIBuilder.Selector(gasto, "Cantidad", cantidades, 1, nil, { LayoutOrder = 11 })
	local filaGasto = botonera(gasto, 12)
	boton(filaGasto, "Registrar gasto", function(b)
		self:_Staff("Presupuesto", { Sub = "Gasto", Concepto = selectorConcepto:Valor(), Cantidad = selectorCantidad:Valor() }, aplicar, {
			Boton = b, Texto = "Registrando…",
			Exito = function(datos)
				return "Gasto registrado: " .. texto(datos.Registrado) .. "."
			end,
		})
	end, "Primario", 1, 170)
	boton(filaGasto, "Actualizar", function(b)
		self:_Staff("Presupuesto", { Sub = "Ver" }, aplicar, { Boton = b, Exito = "Presupuesto actualizado." })
	end, "Secundario", 2, 130)

	local auditoria = seccion(cuerpo, "Auditoría económica", o(), "Movimientos recientes de monedas, ventas de cafetería y estado del comedor.")
	local datosAuditoria = nil
	local filaAuditoria = botonera(auditoria, 10)
	if self:_Tiene("economia.auditar") then
		boton(filaAuditoria, "Ver movimientos", function(b)
			self:_Staff("AuditoriaEconomia", {}, function(ok, datos, _, vigente)
				if ok then
					datosAuditoria = datos
					if vigente then
						self:_Refrescar("AuditoriaEconomia")
					end
				end
			end, { Boton = b, Texto = "Cargando movimientos…", Exito = "Movimientos cargados." })
		end, "Secundario", 1, 170)
	end
	self:_Dinamico(auditoria, 11, "AuditoriaEconomia", function(caja, oo)
		local d = datosAuditoria
		if typeof(d) ~= "table" then
			return
		end
		if typeof(d.Aviso) == "string" then
			linea(caja, d.Aviso, oo(), Colores.Amarillo)
		end
		if typeof(d.Resumen) == "table" then
			linea(caja, "Resumen global", oo(), Colores.TextoSecundario, { Fuente = "Subtitulo" })
			renderTabla(caja, oo, d.Resumen)
		end
		local transacciones = listaDe(d.Transacciones)
		if #transacciones > 0 then
			linea(caja, "Transacciones", oo(), Colores.TextoSecundario, { Fuente = "Subtitulo" })
			for i, t in ipairs(transacciones) do
				if i <= 30 then
					linea(caja, "• " .. resumenFila(t), oo())
				end
			end
		end
		local ventas = listaDe(d.VentasCafeteria)
		if #ventas > 0 then
			linea(caja, "Ventas de cafetería", oo(), Colores.TextoSecundario, { Fuente = "Subtitulo" })
			for _, v in ipairs(ventas) do
				linea(caja, "• " .. resumenFila(v), oo())
			end
		end
		if typeof(d.Comedor) == "table" then
			linea(caja, "Comedor", oo(), Colores.TextoSecundario, { Fuente = "Subtitulo" })
			renderTabla(caja, oo, d.Comedor)
		end
	end)

	if self:_Tiene("cafeteria.precios") then
		local precios = seccion(cuerpo, "Precios de la cafetería", o())
		local datosPrecios = nil
		local filaPrecios = botonera(precios, 10)
		local function cargarPrecios(b)
			self:_Staff("PrecioCafeteria", { Sub = "Ver" }, function(ok, datos, _, vigente)
				if ok then
					datosPrecios = datos
					if vigente then
						self:_Refrescar("Precios")
					end
				end
			end, { Boton = b, Texto = "Cargando precios…", Exito = "Precios cargados." })
		end
		boton(filaPrecios, "Ver precios", function(b)
			cargarPrecios(b)
		end, "Secundario", 1, 140)
		self:_Dinamico(precios, 11, "Precios", function(caja, oo)
			local d = datosPrecios
			if typeof(d) ~= "table" then
				return
			end
			local minimo = tonumber(d.Min) or 1
			local maximo = tonumber(d.Max) or 200
			linea(caja, "Rango permitido: " .. Format.Moneda(minimo) .. " – " .. Format.Moneda(maximo), oo(), Colores.TextoSecundario)
			for _, producto in ipairs(listaDe(d.Productos)) do
				if typeof(producto) == "table" and typeof(producto.Id) == "string" then
					local fila = UIBuilder.Fila(caja, { LayoutOrder = oo(), Nombre = "Producto_" .. producto.Id })
					UIBuilder.Texto(fila, texto(producto.Nombre) .. " · " .. Format.Moneda(producto.Precio) .. (tonumber(producto.Stock) and (" · stock " .. producto.Stock) or ""), {
						Tamano = "Pequeno", AutoAlto = false, Truncar = true, AlineacionY = Enum.TextYAlignment.Center,
						Size = UDim2.new(1, -200, 1, 0), LayoutOrder = 1,
					})
					local cajaPrecio = UIBuilder.Entrada(fila, "Precio", { Max = 4, Texto = tostring(producto.Precio or ""), Size = UDim2.new(0, 80, 1, 0), LayoutOrder = 2 })
					UIBuilder.Boton(fila, "Fijar", function(b)
						local valor = tonumber(Format.Recortar(cajaPrecio.Text))
						if valor == nil or math.floor(valor) ~= valor or valor < minimo or valor > maximo then
							self:_Estado("El precio debe ser un entero entre " .. minimo .. " y " .. maximo .. ".", "Error")
							return
						end
						self:_Staff("PrecioCafeteria", { Sub = "Fijar", ProductoId = producto.Id, Precio = valor }, function(ok, datos, respuesta, vigente)
							if ok then
								datosPrecios = { Productos = datos.Productos, Min = datos.Min, Max = datos.Max }
								if vigente then
									self:_Refrescar("Precios")
								end
								return
							end
							-- Sin método en CafeteriaService: se delega en CafeteriaManage (permiso cafeteria.precios).
							local err = typeof(respuesta) == "table" and respuesta.error or nil
							if err == "delegar:CafeteriaManage" then
								self:_Pedir("CafeteriaManage", { Accion = "Precio", ProductoId = producto.Id, Valor = valor }, function(ok2)
									if ok2 then
										cargarPrecios(nil)
									end
								end, { Boton = b, Texto = "Aplicando en la cafetería…", Exito = texto(producto.Nombre) .. " = " .. Format.Moneda(valor) .. "." })
							end
						end, { Boton = b, Texto = "Fijando precio…", Exito = texto(producto.Nombre) .. " = " .. Format.Moneda(valor) .. "." })
					end, { Estilo = "Primario", Ancho = 100, LayoutOrder = 3 })
				end
			end
		end)
	end

	self:_Staff("Presupuesto", { Sub = "Ver" }, aplicar, { Silencioso = true })
end

---------------------------------------------------------------------------------------------------
-- Pestaña: Recepción / Seguridad
---------------------------------------------------------------------------------------------------
function StaffController:_TabSeguridad(cuerpo, o)
	local visitas = seccion(cuerpo, "Registro de visitas", o(), "Registra a quien llega como visita (nombre mostrado y motivo filtrado). La lista dura la jornada.")
	local selector = self:_SelectorJugadores(visitas, 10, { Alto = 170, Distancia = true, PorDistancia = true })
	local motivo = UIBuilder.Entrada(visitas, "Motivo de la visita (mín. 3 caracteres)", { Max = 80, LayoutOrder = 11 })
	local fila = botonera(visitas, 12)
	boton(fila, "Registrar visita", function(b)
		local userId = selector:Valor()
		if not userId then
			self:_Estado("Selecciona a la persona que llega.", "Error")
			return
		end
		local valor = motivoValido(motivo, 3)
		if not valor then
			self:_Estado("Escribe el motivo de la visita.", "Error")
			return
		end
		self:_Staff("RegistrarVisita", { ObjetivoUserId = userId, Motivo = valor }, function(ok, datos, _, vigente)
			if ok then
				self.visitas = listaDe(datos.Visitas)
				if vigente then
					motivo.Text = ""
					self:_Refrescar("Visitas")
				end
			end
		end, { Boton = b, Texto = "Registrando…", Exito = "Visita registrada.", Toast = true })
	end, "Primario", 1, 170)
	self:_Dinamico(visitas, 13, "Visitas", function(caja, oo)
		local lista = self.visitas
		if typeof(lista) ~= "table" then
			linea(caja, "Cargando visitas…", oo(), Colores.TextoApagado)
			return
		end
		if #lista == 0 then
			linea(caja, "Sin visitas registradas en esta jornada.", oo(), Colores.TextoApagado)
		end
		for i, v in ipairs(lista) do
			if typeof(v) == "table" and i <= 25 then
				linea(caja, "• " .. texto(v.Hora) .. " · " .. texto(v.Nombre) .. " · " .. texto(v.Motivo) .. " · registró " .. texto(v.Registro), oo())
			end
		end
	end)

	local incidencia = seccion(cuerpo, "Aviso de incidencia a moderación", o(), "Se avisa al personal con moderación y queda registrada. Opcional: incluye a la persona seleccionada arriba como implicada.")
	local descripcion = UIBuilder.Entrada(incidencia, "¿Qué ocurre? (mín. 3 caracteres)", { Max = 160, Multilinea = true, Alto = 70, LayoutOrder = 10 })
	local incluir = UIBuilder.Interruptor(incidencia, "Incluir a la persona seleccionada", false, nil, { LayoutOrder = 11 })
	local filaIncidencia = botonera(incidencia, 12)
	boton(filaIncidencia, "Avisar a moderación", function(b)
		local valor = motivoValido(descripcion, 3)
		if not valor then
			self:_Estado("Describe la incidencia.", "Error")
			return
		end
		local datos = { Descripcion = valor }
		if incluir:Valor() then
			local userId = selector:Valor()
			if not userId then
				self:_Estado("Selecciona a la persona implicada o desactiva la opción.", "Error")
				return
			end
			datos.ObjetivoUserId = userId
		end
		self:_Staff("Incidencia", datos, function(ok, _, _, vigente)
			if ok and vigente then
				descripcion.Text = ""
			end
		end, {
			Boton = b, Texto = "Enviando aviso…", Toast = true,
			Exito = function(respuesta)
				local n = tonumber(respuesta.Avisados) or 0
				if n == 0 then
					return "Incidencia registrada (no hay moderadores conectados)."
				end
				return "Incidencia enviada a " .. n .. " moderador(es)."
			end,
		})
	end, "Peligro", 1, 200)

	local porton = seccion(cuerpo, "Portón principal", o(), "Bloquea o desbloquea el portón de la entrada. Debes estar junto al portón para operarlo.")
	local estadoPorton = linea(porton, "Estado: desconocido", 10, Colores.TextoSecundario)
	local defPorton = MapaLogico.Puertas and MapaLogico.Puertas.Porton_Principal
	local maxPuerta = (Config.Distancias and Config.Distancias.Puerta) or 14
	local distanciaPorton = linea(porton, "", 9, Colores.TextoApagado)
	local function actualizarDistanciaPorton()
		if distanciaPorton.Parent == nil then
			return
		end
		local d = defPorton and distanciaPunto(defPorton.Centro) or nil
		if d == nil then
			distanciaPorton.Text = "Distancia al portón: desconocida."
		else
			distanciaPorton.Text = "Estás " .. textoDistancia(d) .. " del portón (máx. " .. maxPuerta .. ")."
			distanciaPorton.TextColor3 = d <= maxPuerta and Colores.Verde or Colores.TextoApagado
		end
	end
	actualizarDistanciaPorton()
	self.maidTab:GiveTask(task.spawn(function()
		while distanciaPorton.Parent ~= nil do
			task.wait(2)
			actualizarDistanciaPorton()
		end
	end))
	local function mostrarEstado(datos)
		if estadoPorton.Parent == nil then
			return
		end
		local estado = datos.Estado
		local textoEstado = "desconocido"
		if typeof(estado) == "table" then
			textoEstado = texto(estado.Estado or estado.Modo or (estado.Bloqueada and "Bloqueada") or "—")
		elseif typeof(estado) == "string" then
			textoEstado = estado
		elseif datos.Bloqueado ~= nil then
			textoEstado = datos.Bloqueado and "Bloqueado" or "Desbloqueado"
		end
		estadoPorton.Text = "Estado: " .. textoEstado
	end
	local filaPorton = botonera(porton, 11)
	boton(filaPorton, "Bloquear", function(b)
		self:_Staff("Porton", { Bloquear = true }, function(ok, datos, _, vigente)
			if ok and vigente then
				mostrarEstado(datos)
			end
		end, { Boton = b, Exito = "Portón bloqueado." })
	end, "Peligro", 1, 130)
	boton(filaPorton, "Desbloquear", function(b)
		self:_Staff("Porton", { Bloquear = false }, function(ok, datos, _, vigente)
			if ok and vigente then
				mostrarEstado(datos)
			end
		end, { Boton = b, Exito = "Portón desbloqueado." })
	end, "Exito", 2, 150)
	boton(filaPorton, "Consultar", function(b)
		self:_Staff("Porton", {}, function(ok, datos, _, vigente)
			if ok and vigente then
				mostrarEstado(datos)
			end
		end, { Boton = b, Exito = "Estado consultado." })
	end, "Secundario", 3, 130)

	if typeof(self.visitas) ~= "table" then
		self:_Staff("ListaVisitas", {}, function(ok, datos, _, vigente)
			if ok then
				self.visitas = listaDe(datos.Visitas)
				if vigente then
					self:_Refrescar("Visitas")
				end
			end
		end, { Silencioso = true })
	end
end

---------------------------------------------------------------------------------------------------
-- Pestaña: Limpieza
---------------------------------------------------------------------------------------------------
function StaffController:_TabLimpieza(cuerpo, o)
	local sec = seccion(cuerpo, "Tareas de limpieza", o(), "Aparecen en el descanso y el almuerzo (máx. 6 a la vez). Ve al marcador y mantén pulsado «Limpiar» (E, toque o botón del mando).")
	local etiquetasDistancia = {}
	self:_Dinamico(sec, 10, "Tareas", function(caja, oo)
		etiquetasDistancia = {}
		local info = self.limpieza
		if typeof(info) == "table" then
			local periodo = info.PeriodoNombre or (info.Activo and "En curso" or nil)
			local cabecera = periodo and ("Periodo: " .. texto(periodo)) or "Fuera del descanso y el almuerzo"
			cabecera = cabecera .. " · Completadas por ti: " .. texto(info.Completadas or 0) .. " / " .. texto(info.Maximo or 3)
			linea(caja, cabecera, oo(), Colores.TextoSecundario)
		end
		local tareas = {}
		for _, tarea in ipairs(self.tareas or {}) do
			if typeof(tarea) == "table" then
				table.insert(tareas, tarea)
			end
		end
		table.sort(tareas, function(a, b)
			return (distanciaPunto(a.Posicion) or math.huge) < (distanciaPunto(b.Posicion) or math.huge)
		end)
		if #tareas == 0 then
			linea(caja, "No hay tareas pendientes ahora. Se generan al empezar el descanso y el almuerzo.", oo(), Colores.TextoApagado)
			return
		end
		for _, tarea in ipairs(tareas) do
			local fila = UIBuilder.Marco(caja, { Nombre = "Tarea", AutoAlto = true, LayoutOrder = oo(), Color = Colores.Fondo, Transparencia = 0.5 })
			UIBuilder.Esquinas(fila, UITheme.RadioPequeno)
			UIBuilder.Relleno(fila, 6, 6, 8, 8)
			UIBuilder.Disposicion(fila, { Espaciado = 2 })
			linea(fila, texto(tarea.Nombre) .. " · +" .. Format.Moneda(tarea.Recompensa), 1, nil, { Fuente = "Subtitulo" })
			local etiqueta = linea(fila, texto(tarea.ZonaNombre or tarea.Zona) .. " · " .. textoDistancia(distanciaPunto(tarea.Posicion)), 2, Colores.TextoSecundario)
			table.insert(etiquetasDistancia, { Etiqueta = etiqueta, Tarea = tarea })
		end
	end)
	self.maidTab:GiveTask(task.spawn(function()
		while self.abierto do
			task.wait(1)
			for _, item in ipairs(etiquetasDistancia) do
				if item.Etiqueta.Parent ~= nil then
					item.Etiqueta.Text = texto(item.Tarea.ZonaNombre or item.Tarea.Zona) .. " · " .. textoDistancia(distanciaPunto(item.Tarea.Posicion))
				end
			end
		end
	end))
	local fila = botonera(sec, 11)
	boton(fila, "Actualizar", function(b)
		self:_Staff("TareasPendientes", {}, function(ok, datos, _, vigente)
			if ok then
				self.limpieza = datos
				self.tareas = listaDe(datos.Tareas)
				self:_ActualizarAccionLimpieza()
				if vigente then
					self:_Refrescar("Tareas")
				end
			end
		end, { Boton = b, Exito = "Tareas actualizadas." })
	end, "Secundario", 1, 130)
end

---------------------------------------------------------------------------------------------------
-- Pestaña: Moderación básica
---------------------------------------------------------------------------------------------------
function StaffController:_TabModeracion(cuerpo, o)
	local sec = seccion(cuerpo, "Moderación", o(), "Lista de jugadores con nombre mostrado. Cada acción pide confirmación y queda auditada. El motivo es obligatorio.")
	local selector = self:_SelectorJugadores(sec, 10, { Alto = 190 })
	local motivo = UIBuilder.Entrada(sec, "Motivo (mín. 3 caracteres)", { Max = (Config.Limites and Config.Limites.MaxMotivoCaracteres) or 120, LayoutOrder = 11 })
	local porDefecto = (Config.Moderacion and Config.Moderacion.DuracionMuteSeg) or 300
	local duracion = UIBuilder.Selector(sec, "Duración (silencio / bloqueo)", DURACIONES_MODERACION, porDefecto, nil, { LayoutOrder = 12, AnchoGrupo = 220 })
	local fila = botonera(sec, 13)
	local function ejecutar(accion, etiqueta, conDuracion)
		local userId = selector:Valor()
		if not userId then
			self:_Estado("Selecciona a un jugador.", "Error")
			return
		end
		local valor = motivoValido(motivo, 3)
		if not valor then
			self:_Estado("Escribe un motivo de al menos 3 caracteres.", "Error")
			return
		end
		local extra = nil
		if conDuracion then
			extra = { DuracionSeg = duracion:Valor() }
		end
		self:_Moderar(accion, userId, valor, extra, etiqueta, function(ok)
			if ok and motivo.Parent ~= nil then
				motivo.Text = ""
			end
		end)
	end
	if self:_Tiene("moderacion.basica") then
		boton(fila, "Advertir", function()
			ejecutar("Advertir", "Advertir", false)
		end, "Secundario", 1, 120)
		boton(fila, "Silenciar", function()
			ejecutar("Silenciar", "Silenciar", true)
		end, "Secundario", 2, 120)
		boton(fila, "Quitar silencio", function()
			ejecutar("QuitarSilencio", "Quitar el silencio", false)
		end, "Secundario", 3, 160)
	end
	if self:_Tiene("moderacion.avanzada") then
		boton(fila, "Expulsar", function()
			ejecutar("Expulsar", "Expulsar del servidor", false)
		end, "Peligro", 4, 120)
		boton(fila, "Bloqueo temporal", function()
			ejecutar("BloquearTemporal", "Bloquear temporalmente", true)
		end, "Peligro", 5, 170)
	end

	local registro = seccion(cuerpo, "Registro de moderación", o())
	local datosRegistro = nil
	local filaRegistro = botonera(registro, 10)
	boton(filaRegistro, "Ver registro", function(b)
		local datos = { Accion = "VerRegistro" }
		local userId = selector:Valor()
		if userId then
			datos.ObjetivoUserId = userId
		end
		self:_Pedir("ModerationAction", datos, function(ok, respuesta, _, vigente)
			if ok then
				datosRegistro = respuesta
				if vigente then
					self:_Refrescar("RegistroModeracion")
				end
			end
		end, { Boton = b, Texto = "Cargando registro…", Exito = "Registro cargado." })
	end, "Secundario", 1, 150)
	self:_Dinamico(registro, 11, "RegistroModeracion", function(caja, oo)
		if typeof(datosRegistro) ~= "table" then
			linea(caja, "Selecciona a un jugador (opcional) y pulsa «Ver registro».", oo(), Colores.TextoApagado)
			return
		end
		local entradas = listaDe(datosRegistro.Registro or datosRegistro.Entradas or datosRegistro.Lista or datosRegistro)
		if #entradas == 0 then
			linea(caja, "Sin entradas.", oo(), Colores.TextoApagado)
		end
		for i, entrada in ipairs(entradas) do
			if i <= 30 then
				linea(caja, "• " .. resumenFila(entrada), oo())
			end
		end
	end)
end

---------------------------------------------------------------------------------------------------
-- Pestaña: Mi cargo (docentes y servicios sin funciones aquí)
---------------------------------------------------------------------------------------------------
function StaffController:_TabInfo(cuerpo, o)
	local rol = RoleDefinitions.Obtener(self.cargo)
	local sec = seccion(cuerpo, rol and rol.Nombre or "Mi cargo", o(), rol and rol.Descripcion or nil)
	linea(sec, AYUDA_CARGO[self.cargo] or "Tu cargo no tiene funciones de panel; usa las interacciones del mapa.", 10)
	local permisos = {}
	for _, permiso in ipairs(RoleDefinitions.PermisosConocidos or {}) do
		if RoleDefinitions.Tiene(self.cargo, permiso) then
			table.insert(permisos, permiso)
		end
	end
	if #permisos > 0 then
		linea(sec, "Permisos: " .. table.concat(permisos, ", "), 11, Colores.TextoApagado)
	end
	local fila = botonera(sec, 12)
	local candidatos = {
		{ Controlador = "ClassroomController", Metodos = { "AbrirPanel", "Abrir" }, Texto = "Abrir panel de clase", Permiso = "aula.docente" },
		{ Controlador = "FoodController", Metodos = { "AbrirCocina", "Abrir" }, Texto = "Abrir cocina", Permiso = "cocina.operar" },
		{ Controlador = "CafeteriaController", Metodos = { "AbrirAdministracion", "Abrir" }, Texto = "Abrir tienda", Permiso = "cafeteria.vender" },
	}
	local orden = 0
	for _, candidato in ipairs(candidatos) do
		if self:_Tiene(candidato.Permiso) then
			local controlador = self.registro.Get(candidato.Controlador)
			local metodo = nil
			if controlador then
				for _, nombre in ipairs(candidato.Metodos) do
					if metodo == nil and typeof(controlador[nombre]) == "function" then
						metodo = nombre
					end
				end
			end
			if metodo then
				orden = orden + 1
				boton(fila, candidato.Texto, function()
					self:Cerrar()
					local ok, err = pcall(controlador[metodo], controlador)
					if not ok then
						warn(LOG .. tostring(err))
					end
				end, "Primario", orden, 200)
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- API pública
---------------------------------------------------------------------------------------------------
function StaffController:EstaAbierto()
	return self.abierto == true
end

-- Abre el panel (opcionalmente en una pestaña: "Limpieza", "Enfermeria", ...).
function StaffController:Abrir(pestana)
	if not self.activo then
		return
	end
	self.pestanas = self:_PestanasPara(self.cargo)
	if #self.pestanas == 0 then
		self:_Toast("Tu cargo no tiene panel de personal. Elige un cargo del colegio en el menú.", "info")
		return
	end
	local ok, err = pcall(self._AsegurarUI, self)
	if not ok then
		warn(LOG .. "No se pudo construir el panel: " .. tostring(err))
		return
	end
	local yaAbierto = self.abierto
	self.abierto = true
	self.ui.Gui.Enabled = true
	self:_PintarCabecera()
	self:_PintarPestanas()
	local destino = pestana
	if typeof(destino) ~= "string" or not contiene(self.pestanas, destino) then
		if yaAbierto and contiene(self.pestanas, self.tabActual) then
			destino = self.tabActual
		else
			destino = (contiene(self.pestanas, self.tabActual) and self.tabActual) or self.pestanas[1]
		end
	end
	if not yaAbierto then
		UIBuilder.Aparecer(self.ui.Panel)
		local conexion = UIBuilder.TeclaCerrar(function()
			self:Cerrar()
		end)
		if conexion then
			self.maidPanel:GiveTask(conexion)
		end
	end
	self:_MostrarTab(destino)
	task.defer(function()
		if self.abierto and self.ui.Panel then
			local primero = self.ui.BotonesPestana and self.ui.BotonesPestana[self.tabActual]
			if primero then
				UIBuilder.Enfocar(primero)
			else
				UIBuilder.EnfocarPrimero(self.ui.Panel)
			end
		end
	end)
	if not yaAbierto then
		self.Abierto:Fire()
	end
end

function StaffController:Cerrar()
	if not self.abierto then
		return
	end
	self.abierto = false
	self.tokenTab = self.tokenTab + 1
	self.maidPanel:DoCleaning()
	self.maidTab:DoCleaning()
	self.refrescos = {}
	local panel = self.ui.Panel
	if panel and panel.Parent ~= nil then
		for _, descendiente in ipairs(panel:GetDescendants()) do
			if descendiente:IsA("TextBox") then
				pcall(function()
					descendiente:ReleaseFocus()
				end)
			end
		end
		UIBuilder.Desenfocar(panel)
		UIBuilder.Desaparecer(panel)
	end
	self.Cerrado:Fire()
end

function StaffController:Alternar(pestana)
	if self.abierto and (pestana == nil or pestana == self.tabActual) then
		self:Cerrar()
	else
		self:Abrir(pestana)
	end
end

-- Pestañas disponibles para el cargo actual (ids).
function StaffController:Pestanas()
	return copiar(self.pestanas)
end

-- Tareas de limpieza conocidas por el cliente (copia).
function StaffController:Tareas()
	return copiar(self.tareas)
end

return StaffController
