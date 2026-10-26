--[[
	Ruta en el Explorer: StarterPlayer.StarterPlayerScripts.ColegioRP.Controllers.InteractionController
	Tipo: ModuleScript
	Interacciones físicas del cliente (docs/ARQUITECTURA.md §7, prueba P10). Solo pide y renderiza: los
	ProximityPrompt los crea y los resuelve el servidor (Triggered llega al servidor con el jugador).
	- Ayuda contextual: al mostrarse un prompt de Colegio RP (atributo RPTipo) añade en el HUD la acción con su tecla
	  (HUDController:AccionContextual); en táctil no añade botones (los prompts ya son táctiles).
	- Tecla F: abre/cierra la puerta más cercana con prompt (DoorAction Abrir/Cerrar según el atributo Estado).
	- Filtros locales: el prompt de bloqueo solo se habilita para cargos autorizados (RPCargos / RPPermiso) y el de
	  privacidad solo dentro del baño (RPPunto / RPNormal / RPReferencia). El servidor vuelve a validarlo todo.
	- EventoCliente: "Puerta" (toasts de bloqueo y mensajes), "PC" AbrirEscritorio -> PCController:Abrir,
	  "Cafeteria" AbrirPanel -> CafeteriaController:Abrir, "Comida" Abrir* -> FoodController (delegación tolerante).
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

local InteractionController = {}
InteractionController.Nombre = "InteractionController"
InteractionController.TeclaPuerta = Enum.KeyCode.F -- Atajo de teclado para la puerta más cercana.
InteractionController.DistanciaTecla = 10 -- Studs máximos para la tecla F (el servidor admite 14).
InteractionController.IntervaloTeclaSeg = 0.4 -- Pulsaciones de F más rápidas se ignoran (respeta el cooldown).
InteractionController.IntervaloFiltroSeg = 0.5 -- Revisión de los prompts de privacidad (dentro/fuera).
InteractionController.IntervaloAvisoSinPuertaSeg = 4
InteractionController.TagPrompt = "ColegioRP_PromptPuerta"
InteractionController.TagPromptBloqueo = "ColegioRP_PromptBloqueo"
InteractionController.TagPromptPrivacidad = "ColegioRP_PromptPrivacidad"

local UIBuilder, UITheme, Net, Maid, Format, RoleDefinitions, Zones, Config

local player = Players.LocalPlayer

-- Delegación de aperturas de panel: Tipo de EventoCliente -> { Sub -> { Controlador, Metodo } }.
local DELEGACIONES = {
	PC = {
		AbrirEscritorio = { "PCController", "Abrir" },
	},
	Cafeteria = {
		AbrirPanel = { "CafeteriaController", "Abrir" },
		AbrirVenta = { "CafeteriaController", "Abrir" },
	},
	Comida = {
		AbrirPanel = { "FoodController", "Abrir" },
		AbrirReclamo = { "FoodController", "Abrir" },
		AbrirCocina = { "FoodController", "AbrirCocina", "Abrir" },
	},
}

local NOMBRE_FUNCION = {
	PCController = "El escritorio escolar",
	CafeteriaController = "La tienda escolar",
	FoodController = "El comedor",
}

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

local function plano(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function posicionPropia()
	local personaje = player.Character
	local raiz = personaje and personaje:FindFirstChild("HumanoidRootPart")
	if raiz and raiz:IsA("BasePart") then
		return raiz.Position
	end
	return nil
end

-- Posición en el mundo de un prompt (padre Attachment, BasePart o Model).
local function posicionPrompt(prompt)
	local padre = prompt.Parent
	if not padre then
		return nil
	end
	if padre:IsA("Attachment") then
		return padre.WorldPosition
	end
	if padre:IsA("BasePart") then
		return padre.Position
	end
	if padre:IsA("Model") then
		local ok, cf = pcall(function()
			return padre:GetPivot()
		end)
		if ok and typeof(cf) == "CFrame" then
			return cf.Position
		end
	end
	return nil
end

local function esPromptRP(prompt)
	return typeof(prompt) == "Instance" and prompt:IsA("ProximityPrompt") and typeof(prompt:GetAttribute("RPTipo")) == "string"
end

local function nombreTecla(codigo)
	if typeof(codigo) ~= "EnumItem" then
		return "E"
	end
	local nombre = codigo.Name
	local sinBoton = string.match(nombre, "^Button(.+)$")
	if sinBoton then
		return sinBoton
	end
	return nombre
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function InteractionController:Init(registro)
	self.registro = registro
	Config = registro.Config
	UIBuilder = registro.UIBuilder
	local Shared = registro.Shared
	local Util = Shared:FindFirstChild("Util") or Shared:WaitForChild("Util", 10)
	UITheme = requerir(Shared, "UITheme")
	RoleDefinitions = requerir(Shared, "RoleDefinitions")
	Net = requerir(Util, "Net")
	Maid = requerir(Util, "Maid")
	Format = requerir(Util, "Format")
	Zones = requerir(Util, "Zones")

	self.maid = Maid.new()
	self.activo = true
	self.visibles = {} -- prompt -> true (prompts RP mostrados ahora)
	self.actual = nil -- prompt elegido para la ayuda contextual
	self.etiquetaHUD = nil -- texto de la acción contextual publicada en el HUD
	self.promptsPuerta = {} -- prompt -> true
	self.promptsBloqueo = {} -- prompt -> true
	self.promptsPrivacidad = {} -- prompt -> true
	self.estados = {} -- puertaId -> último { Estado, Bloqueada, ... } recibido
	self.enCurso = {} -- puertaId -> true mientras hay una petición DoorAction en vuelo
	self.ultimaTecla = 0
	self.ultimoAvisoSinPuerta = 0
	self.avisosDelegacion = {}
	self.gui = nil
	self.etiquetaAyuda = nil
end

function InteractionController:Start()
	-- Prompts mostrados / ocultos / activados (cliente).
	self.maid:GiveTask(ProximityPromptService.PromptShown:Connect(function(prompt)
		if esPromptRP(prompt) then
			self.visibles[prompt] = true
			self:_ElegirActual()
		end
	end))
	self.maid:GiveTask(ProximityPromptService.PromptHidden:Connect(function(prompt)
		if self.visibles[prompt] then
			self.visibles[prompt] = nil
			if self.actual == prompt then
				self:_ElegirActual()
			end
		end
	end))
	self.maid:GiveTask(ProximityPromptService.PromptTriggered:Connect(function(prompt)
		if esPromptRP(prompt) and UIBuilder then
			pcall(UIBuilder.Sonar)
		end
	end))

	-- Atajo F (solo teclado; se ignora mientras se escribe o si el juego ya procesó la tecla).
	self.maid:GiveTask(UserInputService.InputBegan:Connect(function(entrada, procesado)
		if procesado or entrada.KeyCode ~= self.TeclaPuerta then
			return
		end
		if UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		local ok, err = pcall(self._AlPulsarTeclaPuerta, self)
		if not ok then
			warn("[ColegioRP] InteractionController: " .. tostring(err))
		end
	end))

	-- Registro de prompts de puerta por tag (replicados desde el servidor).
	self:_SeguirTag(self.TagPrompt, self.promptsPuerta, nil)
	self:_SeguirTag(self.TagPromptBloqueo, self.promptsBloqueo, function(prompt)
		self:_FiltrarBloqueo(prompt)
	end)
	self:_SeguirTag(self.TagPromptPrivacidad, self.promptsPrivacidad, function(prompt)
		self:_FiltrarPrivacidad(prompt, posicionPropia())
	end)
	self.maid:GiveTask(player:GetAttributeChangedSignal("Cargo"):Connect(function()
		for prompt in pairs(self.promptsBloqueo) do
			self:_FiltrarBloqueo(prompt)
		end
	end))

	-- Al reaparecer se limpia la ayuda (los prompts se vuelven a mostrar solos).
	self.maid:GiveTask(player.CharacterAdded:Connect(function()
		table.clear(self.visibles)
		self:_ElegirActual()
	end))

	-- Revisión periódica de los prompts de privacidad (solo hay unos pocos; nada por fotograma).
	self.maid:GiveTask(task.spawn(function()
		while self.activo do
			task.wait(self.IntervaloFiltroSeg)
			if next(self.promptsPrivacidad) ~= nil then
				local pos = posicionPropia()
				for prompt in pairs(self.promptsPrivacidad) do
					pcall(self._FiltrarPrivacidad, self, prompt, pos)
				end
			end
		end
	end))

	-- Canal servidor -> cliente.
	task.spawn(function()
		local remoto = Net.Evento("EventoCliente")
		if not remoto then
			warn("[ColegioRP] InteractionController: EventoCliente no disponible; no habrá avisos de puertas.")
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
			if carga.Tipo == "Puerta" then
				ok, err = pcall(self._AlEventoPuerta, self, datos)
			elseif DELEGACIONES[carga.Tipo] then
				ok, err = pcall(self._Delegar, self, carga.Tipo, datos)
			end
			if not ok then
				warn("[ColegioRP] InteractionController: " .. tostring(err))
			end
		end))
	end)
end

-- Libera conexiones, la ayuda del HUD y la pantalla propia (si se creó).
function InteractionController:Destruir()
	self.activo = false
	self:_PublicarAyuda(nil)
	if self.maid then
		self.maid:DoCleaning()
	end
	if self.gui and UIBuilder then
		UIBuilder.Destruir(self.gui)
	end
	self.gui = nil
end

---------------------------------------------------------------------------------------------------
-- Registro por tags y filtros locales
---------------------------------------------------------------------------------------------------
function InteractionController:_SeguirTag(tag, tabla, alAgregar)
	local function agregar(instancia)
		if typeof(instancia) == "Instance" and instancia:IsA("ProximityPrompt") then
			tabla[instancia] = true
			if alAgregar then
				pcall(alAgregar, instancia)
			end
		end
	end
	local ok, lista = pcall(CollectionService.GetTagged, CollectionService, tag)
	if ok and typeof(lista) == "table" then
		for _, instancia in ipairs(lista) do
			agregar(instancia)
		end
	end
	local okA, senalA = pcall(CollectionService.GetInstanceAddedSignal, CollectionService, tag)
	if okA and senalA then
		self.maid:GiveTask(senalA:Connect(agregar))
	end
	local okR, senalR = pcall(CollectionService.GetInstanceRemovedSignal, CollectionService, tag)
	if okR and senalR then
		self.maid:GiveTask(senalR:Connect(function(instancia)
			tabla[instancia] = nil
			if self.visibles[instancia] then
				self.visibles[instancia] = nil
				self:_ElegirActual()
			end
		end))
	end
end

-- Prompt de bloqueo: visible solo para cargos de RPCargos o con el permiso RPPermiso (cambio local).
function InteractionController:_FiltrarBloqueo(prompt)
	local cargo = player:GetAttribute("Cargo")
	local permitido = false
	if typeof(cargo) == "string" and cargo ~= "" then
		local cargos = prompt:GetAttribute("RPCargos")
		if typeof(cargos) == "string" then
			for nombre in string.gmatch(cargos, "[^,]+") do
				if nombre == cargo then
					permitido = true
				end
			end
		end
		local permiso = prompt:GetAttribute("RPPermiso")
		if not permitido and typeof(permiso) == "string" and permiso ~= "" then
			local ok, tiene = pcall(RoleDefinitions.Tiene, cargo, permiso)
			permitido = ok and tiene == true
		end
	end
	if prompt.Enabled ~= permitido then
		prompt.Enabled = permitido
	end
end

-- ¿La posición está dentro del cubículo/baño? Misma regla que DoorService (lado del plano de la hoja).
function InteractionController:_DentroPrivacidad(prompt, pos)
	if typeof(pos) ~= "Vector3" then
		return false
	end
	local punto = prompt:GetAttribute("RPPunto")
	local normal = prompt:GetAttribute("RPNormal")
	local referencia = prompt:GetAttribute("RPReferencia")
	if typeof(punto) == "Vector3" and typeof(normal) == "Vector3" and typeof(referencia) == "Vector3" then
		local n = plano(normal)
		if n.Magnitude > 0.01 then
			n = n.Unit
			local dp = plano(pos - punto):Dot(n)
			local dr = plano(referencia - punto):Dot(n)
			if math.abs(dp) < 0.75 then
				return plano(pos - punto).Magnitude < 4
			end
			if math.abs(dr) >= 0.5 then
				return (dp > 0) == (dr > 0)
			end
		end
	end
	local zona = prompt:GetAttribute("RPZona")
	if typeof(zona) == "string" and zona ~= "" then
		return Zones.Contiene(zona, pos)
	end
	return true
end

function InteractionController:_FiltrarPrivacidad(prompt, pos)
	if prompt.Parent == nil then
		return
	end
	local dentro = self:_DentroPrivacidad(prompt, pos)
	if prompt.Enabled ~= dentro then
		prompt.Enabled = dentro
	end
end

---------------------------------------------------------------------------------------------------
-- Ayuda contextual (HUD o, si no hay HUD, una etiqueta propia)
---------------------------------------------------------------------------------------------------
function InteractionController:_ElegirActual()
	local pos = posicionPropia()
	local mejor, mejorDist = nil, math.huge
	for prompt in pairs(self.visibles) do
		if prompt.Parent ~= nil and prompt.Enabled then
			local p = posicionPrompt(prompt)
			local d = math.huge
			if pos and p then
				d = (p - pos).Magnitude
			end
			if mejor == nil or d < mejorDist then
				mejor, mejorDist = prompt, d
			end
		else
			self.visibles[prompt] = nil
		end
	end
	if mejor ~= self.actual then
		self.actual = mejor
		self.maid.TextoActual = nil
		if mejor then
			-- Si el servidor cambia el texto (Abrir -> Cerrar), se actualiza la ayuda.
			self.maid.TextoActual = mejor:GetPropertyChangedSignal("ActionText"):Connect(function()
				if self.actual == mejor then
					self:_PublicarAyuda(mejor)
				end
			end)
		end
	end
	self:_PublicarAyuda(mejor)
end

function InteractionController:_EsPuerta(prompt)
	return prompt:GetAttribute("RPTipo") == "Puerta" and prompt:GetAttribute("RPAccion") == "Alternar"
end

function InteractionController:_TextoAyuda(prompt)
	local accion = tostring(prompt.ActionText or "")
	local objeto = tostring(prompt.ObjectText or "")
	local tecla
	local mando = UIBuilder and UIBuilder.EsMando() or false
	if mando then
		tecla = nombreTecla(prompt.GamepadKeyCode)
	elseif self:_EsPuerta(prompt) then
		tecla = nombreTecla(self.TeclaPuerta)
	else
		tecla = nombreTecla(prompt.KeyboardKeyCode)
	end
	local texto = accion
	if objeto ~= "" then
		texto = accion .. " · " .. Format.Truncar(objeto, 18)
	end
	return texto .. " [" .. tecla .. "]"
end

-- Publica (prompt) o retira (nil) la acción contextual. En táctil nunca añade botones.
function InteractionController:_PublicarAyuda(prompt)
	local HUD = self.registro and self.registro.Get("HUDController")
	local texto = nil
	if prompt and prompt.Parent ~= nil and not (UIBuilder and UIBuilder.EsTactil()) then
		texto = self:_TextoAyuda(prompt)
	end
	if texto == self.etiquetaHUD then
		return
	end
	local usaHUD = HUD and typeof(HUD.AccionContextual) == "function"
	if self.etiquetaHUD and usaHUD then
		pcall(HUD.AccionContextual, HUD, self.etiquetaHUD, nil)
	end
	self.etiquetaHUD = texto
	if texto == nil then
		self:_AyudaPropia(nil)
		return
	end
	if usaHUD then
		local objetivo = prompt
		local ok = pcall(HUD.AccionContextual, HUD, texto, function()
			self:_EjecutarPrompt(objetivo)
		end)
		if ok then
			self:_AyudaPropia(nil)
			return
		end
	end
	self:_AyudaPropia(texto)
end

-- Respaldo sin HUD: etiqueta inferior centrada en una ScreenGui propia (DisplayOrder del HUD).
function InteractionController:_AyudaPropia(texto)
	if texto == nil then
		if self.etiquetaAyuda and self.etiquetaAyuda.Parent then
			self.etiquetaAyuda.Visible = false
		end
		return
	end
	if not self:_AsegurarPantalla() then
		return
	end
	self.etiquetaAyuda.Text = texto
	self.etiquetaAyuda.Visible = true
end

-- Crea (una sola vez) la ScreenGui propia "ColegioRP_Interaccion" con la etiqueta de ayuda. Devuelve true si existe.
function InteractionController:_AsegurarPantalla()
	if not UIBuilder then
		return false
	end
	if not self.gui or self.gui.Parent == nil or not self.etiquetaAyuda or self.etiquetaAyuda.Parent == nil then
		local capa = (UITheme.Capas and UITheme.Capas.HUD) or 10
		local gui = UIBuilder.Pantalla("Interaccion", capa)
		self.gui = gui
		local etiqueta = UIBuilder.Texto(gui, "", {
			Nombre = "Ayuda",
			Alineacion = Enum.TextXAlignment.Center,
			AlineacionY = Enum.TextYAlignment.Center,
			AutoAlto = false,
			Size = UDim2.new(0, 320, 0, 36),
			Position = UDim2.new(0.5, 0, 1, -(24 + UIBuilder.MargenInferiorTactil())),
			AnchorPoint = Vector2.new(0.5, 1),
			Truncar = true,
		})
		etiqueta.BackgroundTransparency = UITheme.Transparencias and UITheme.Transparencias.Fondo or 0.35
		etiqueta.BackgroundColor3 = (UITheme.Colores and UITheme.Colores.GrisPanel) or Color3.fromRGB(24, 25, 28)
		UIBuilder.Esquinas(etiqueta, UITheme.Radio)
		etiqueta.Visible = false
		self.etiquetaAyuda = etiqueta
	end
	return true
end

-- Ejecuta la acción de un prompt desde el botón del HUD: puertas por DoorAction; el resto simulando la pulsación.
function InteractionController:_EjecutarPrompt(prompt)
	if not prompt or prompt.Parent == nil or not prompt.Enabled then
		return
	end
	if self:_EsPuerta(prompt) then
		self:AccionPuerta(prompt)
		return
	end
	local espera = math.max(0, tonumber(prompt.HoldDuration) or 0) + 0.05
	local ok = pcall(function()
		prompt:InputHoldBegin()
	end)
	if ok then
		task.delay(espera, function()
			pcall(function()
				prompt:InputHoldEnd()
			end)
		end)
	end
end

---------------------------------------------------------------------------------------------------
-- Puertas
---------------------------------------------------------------------------------------------------

-- Prompt de puerta más cercano: primero los que se ven ahora, después los registrados a <= DistanciaTecla.
function InteractionController:_PuertaMasCercana()
	local pos = posicionPropia()
	if not pos then
		return nil
	end
	local mejor, mejorDist = nil, self.DistanciaTecla
	local function considerar(prompt)
		if prompt.Parent ~= nil and self:_EsPuerta(prompt) then
			local p = posicionPrompt(prompt)
			if p then
				local d = (p - pos).Magnitude
				if d <= mejorDist then
					mejor, mejorDist = prompt, d
				end
			end
		end
	end
	for prompt in pairs(self.visibles) do
		considerar(prompt)
	end
	if mejor then
		return mejor
	end
	for prompt in pairs(self.promptsPuerta) do
		considerar(prompt)
	end
	return mejor
end

function InteractionController:_AlPulsarTeclaPuerta()
	local ahora = os.clock()
	if ahora - self.ultimaTecla < self.IntervaloTeclaSeg then
		return
	end
	self.ultimaTecla = ahora
	local prompt = self:_PuertaMasCercana()
	if not prompt then
		if ahora - self.ultimoAvisoSinPuerta >= self.IntervaloAvisoSinPuertaSeg then
			self.ultimoAvisoSinPuerta = ahora
			self:_Notificar("No hay ninguna puerta cerca.", "info", 2)
		end
		return
	end
	self:AccionPuerta(prompt)
end

-- Estado conocido de la puerta del prompt: atributo del prompt > atributo de la hoja > último evento.
function InteractionController:_EstadoDe(prompt, puertaId)
	local estado = prompt:GetAttribute("Estado")
	if typeof(estado) == "string" then
		return estado
	end
	local actual = prompt.Parent
	for _ = 1, 3 do
		if not actual then
			break
		end
		local valor = actual:GetAttribute("Estado")
		if typeof(valor) == "string" then
			return valor
		end
		actual = actual.Parent
	end
	local cache = self.estados[puertaId]
	if cache and typeof(cache.Estado) == "string" then
		return cache.Estado
	end
	if prompt.ActionText == "Cerrar" then
		return "Abierta"
	end
	return "Cerrada"
end

-- Abre o cierra la puerta del prompt pidiéndolo al servidor (DoorAction). Devuelve true si se envió.
function InteractionController:AccionPuerta(prompt)
	if not prompt or prompt.Parent == nil then
		return false
	end
	local puertaId = prompt:GetAttribute("RPId")
	if typeof(puertaId) ~= "string" or puertaId == "" then
		return false
	end
	if self.enCurso[puertaId] then
		return false
	end
	local accion = "Abrir"
	if self:_EstadoDe(prompt, puertaId) == "Abierta" then
		accion = "Cerrar"
	end
	self.enCurso[puertaId] = true
	task.spawn(function()
		local ok, respuesta = Net.Invocar("DoorAction", { PuertaId = puertaId, Accion = accion })
		self.enCurso[puertaId] = nil
		if not ok then
			local texto = respuesta and respuesta.error
			if UIBuilder then
				texto = UIBuilder.MensajeError(texto)
			end
			self:_Notificar(texto or "No se pudo usar la puerta.", "aviso")
		end
	end)
	return true
end

-- Evento "Puerta": mensajes dirigidos y avisos de bloqueo para quien está en la zona (no para el autor).
function InteractionController:_AlEventoPuerta(datos)
	local sub = datos.Sub
	if sub == "Mensaje" then
		if typeof(datos.Texto) == "string" and datos.Texto ~= "" then
			self:_Notificar(datos.Texto, datos.Nivel or "info")
		end
		return
	end
	if sub ~= "Estado" or typeof(datos.PuertaId) ~= "string" then
		return
	end
	self.estados[datos.PuertaId] = datos
	if datos.ActorUserId == player.UserId then
		return
	end
	local accion = datos.Accion
	if accion == "Bloquear" then
		if datos.Fijada then
			self:_Notificar("El personal dejó la puerta fijada abierta.", "info", 3)
		else
			self:_Notificar("El personal bloqueó la puerta: desde dentro siempre se puede salir.", "info", 4)
		end
	elseif accion == "Desbloquear" then
		self:_Notificar("La puerta se desbloqueó.", "info", 3)
	elseif accion == "AbrirTodas" then
		self:_Notificar("Todas las puertas se abrieron.", "aviso", 4)
	end
end

-- Estado de puerta conocido por el cliente (último evento) o nil.
function InteractionController:EstadoPuerta(puertaId)
	return self.estados[puertaId]
end

---------------------------------------------------------------------------------------------------
-- Delegación de paneles y notificaciones
---------------------------------------------------------------------------------------------------
function InteractionController:_Delegar(tipo, datos)
	local tabla = DELEGACIONES[tipo]
	local def = tabla and typeof(datos.Sub) == "string" and tabla[datos.Sub] or nil
	if not def then
		return
	end
	local nombreControlador = def[1]
	local controlador = self.registro and self.registro.Get(nombreControlador)
	-- Un controlador que ya atiende su propio evento lo declara para no abrir el panel dos veces.
	if controlador and controlador.ManejaAperturaPropia == true then
		return
	end
	local metodo = nil
	if controlador then
		for i = 2, #def do
			if typeof(controlador[def[i]]) == "function" then
				metodo = controlador[def[i]]
				break
			end
		end
	end
	if metodo then
		local ok, err = pcall(metodo, controlador, datos)
		if not ok then
			warn("[ColegioRP] InteractionController: " .. nombreControlador .. " falló al abrir: " .. tostring(err))
			self:_Notificar("No se pudo abrir el panel. Inténtalo de nuevo.", "error")
		end
		return
	end
	if not self.avisosDelegacion[nombreControlador] then
		self.avisosDelegacion[nombreControlador] = true
		self:_Notificar((NOMBRE_FUNCION[nombreControlador] or "Esta función") .. " todavía no está disponible.", "aviso")
	end
end

function InteractionController:_Notificar(texto, nivel, duracion)
	if typeof(texto) ~= "string" or texto == "" then
		return
	end
	local Notificaciones = self.registro and self.registro.Get("NotificationController")
	if Notificaciones and typeof(Notificaciones.Notificar) == "function" then
		local ok = pcall(Notificaciones.Notificar, Notificaciones, texto, nivel, duracion)
		if ok then
			return
		end
	end
	-- Respaldo sin NotificationController: toast en la pantalla propia.
	if self:_AsegurarPantalla() then
		local nivelToast = "Info"
		if nivel == "aviso" then
			nivelToast = "Aviso"
		elseif nivel == "error" then
			nivelToast = "Error"
		elseif nivel == "exito" then
			nivelToast = "Exito"
		end
		local contenedor = self.gui:FindFirstChild("Toasts")
		if not contenedor then
			contenedor = Instance.new("Frame")
			contenedor.Name = "Toasts"
			contenedor.BackgroundTransparency = 1
			contenedor.Size = UDim2.new(0, 360, 0, 0)
			contenedor.AutomaticSize = Enum.AutomaticSize.Y
			contenedor.AnchorPoint = Vector2.new(0.5, 0)
			contenedor.Position = UDim2.new(0.5, 0, 0, UIBuilder.InsetSuperior() + 8)
			local lista = Instance.new("UIListLayout")
			lista.Padding = UDim.new(0, 6)
			lista.SortOrder = Enum.SortOrder.LayoutOrder
			lista.Parent = contenedor
			contenedor.Parent = self.gui
		end
		pcall(UIBuilder.Toast, contenedor, Format.Truncar(texto, 160), nivelToast, tonumber(duracion) or 4)
	end
end

return InteractionController
