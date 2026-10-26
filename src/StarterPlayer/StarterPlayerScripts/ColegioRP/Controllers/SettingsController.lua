--[[
	Ruta en el Explorer: StarterPlayer.StarterPlayerScripts.ColegioRP.Controllers.SettingsController
	Tipo: ModuleScript
	Panel de AJUSTES / OPTIMIZACIÓN: modo gráfico (Automático / Bajos recursos / Calidad) y opciones de
	rendimiento y accesibilidad aplicadas SOLO en este cliente (propiedades locales, nunca el mapa del
	servidor); medidor de FPS con aviso de rendimiento, métricas al servidor y guardado vía SettingsUpdate.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")

local TIMEOUT = 30
local function esperarHijo(padre, nombre)
	local hijo = nil
	if padre then
		hijo = padre:FindFirstChild(nombre) or padre:WaitForChild(nombre, TIMEOUT)
	end
	if not hijo then
		error("[ColegioRP][SettingsController] No apareció '" .. tostring(nombre) .. "' en " .. TIMEOUT .. " s")
	end
	return hijo
end

local RP = esperarHijo(ReplicatedStorage, "ColegioRP")
local Shared = esperarHijo(RP, "Shared")
local Util = esperarHijo(Shared, "Util")
local Config = require(esperarHijo(Shared, "Config"))
local UITheme = require(esperarHijo(Shared, "UITheme"))
local RemoteContracts = require(esperarHijo(Shared, "RemoteContracts"))
local Catalogs = require(esperarHijo(Shared, "Catalogs"))
local Net = require(esperarHijo(Util, "Net"))
local Signal = require(esperarHijo(Util, "Signal"))
local Maid = require(esperarHijo(Util, "Maid"))
local Validate = require(esperarHijo(Util, "Validate"))
local UIBuilder = require(esperarHijo(esperarHijo(script.Parent.Parent, "UI"), "UIBuilder"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = esperarHijo(LocalPlayer, "PlayerGui")
local Colores = UITheme.Colores

local SettingsController = {}
SettingsController.Nombre = "SettingsController"
-- Señales públicas para otros controladores (HUD: formato de hora; Notification: subtítulos; Nametag: etiquetas).
SettingsController.Cambiado = Signal.new() -- (copiaAjustes, claveCambiada | nil si cambian varias)
SettingsController.ModoCambiado = Signal.new() -- (modoEfectivo: "Calidad" | "Bajos")
SettingsController.Abierto = Signal.new()
SettingsController.Cerrado = Signal.new()

---------------------------------------------------------------------------------------------------
-- Constantes
---------------------------------------------------------------------------------------------------
local LOG = "[ColegioRP][SettingsController] "
local GRAFICOS = Config.Graficos or {}
local DISTANCIA_DECORACION = tonumber(GRAFICOS.DistanciaDecoracionLejana) or 350
local FPS_AVISO = tonumber(GRAFICOS.FPSAvisoBajos) or 25
local FPS_AVISO_SEG = tonumber(GRAFICOS.FPSAvisoSeg) or 10
local INTERVALO_REVISION = 2 -- Revisión de decoración lejana y de valores restaurados por el servidor (no por frame).
-- Envío de FPS (StaffAction "Metrica"); MetricsService acepta 1 cada 30 s por jugador.
local INTERVALO_METRICAS = math.max(INTERVALO_REVISION, tonumber(Config.Metricas and Config.Metricas.IntervaloClienteSeg) or 30)
local GRACIA_FPS_SEG = 15 -- Segundos iniciales sin evaluar el FPS (carga del mapa).
local TAG_DECORACION = (Config.Tags and Config.Tags.Decoracion) or "ColegioRP_Decoracion"
local PREFIJO = (Config.Nombres and Config.Nombres.PrefijoPantallas) or "ColegioRP_"
local NOMBRE_SENAL = (Config.Nombres and Config.Nombres.SenalCargaLista) or "ColegioRP_CargaLista"
-- Capa de paneles (50). MenuController oculta su fondo al delegar, así que el panel queda visible.
local ORDEN_PANTALLA = UITheme.Capas.Panel
local LIMITE_EFECTOS_MAX = 3
local ESCALA_MIN, ESCALA_MAX = 0.8, 1.4
local CUBETAS_FPS = 8 -- 8 cubetas de 0.25 s = media móvil de 2 s.
local DURACION_CUBETA = 0.25
local LOTE_ESCANEO = 4000 -- Instancias por frame en el recorrido inicial de Workspace.

-- Throttle del guardado: al menos 2 s y nunca más rápido que el límite de SettingsUpdate del servidor.
local THROTTLE_GUARDADO = 2
do
	local maximo, ventana = RemoteContracts.LimiteDe("SettingsUpdate")
	if maximo and ventana and maximo > 0 then
		THROTTLE_GUARDADO = math.max(2, ventana / maximo + 0.1)
	end
end

local MODOS_VALIDOS = {}
for _, modo in ipairs(RemoteContracts.ModosGraficos or { "Automatico", "Calidad", "Bajos" }) do
	MODOS_VALIDOS[modo] = true
end

-- Valores por defecto (mismos que Perfil.Ajustes de DataService, docs/ARQUITECTURA.md §4) + claves locales.
local PREDETERMINADOS = {
	ModoGraficos = MODOS_VALIDOS[GRAFICOS.ModoPorDefecto] and GRAFICOS.ModoPorDefecto or "Automatico",
	Particulas = true,
	DecoracionLejana = true,
	Postprocesado = true,
	Sombras = true,
	SonidosAmbiente = true,
	AnimacionesCosmeticas = true,
	LimiteEfectos = 2,
	EscalaTexto = 1,
	MovimientoReducido = false,
	Subtitulos = true,
	FormatoHora = 24,
	OcultarEtiquetas = false,
	IntroVista = false,
}
-- Claves que solo viven en este cliente (no existen en RemoteContracts.EsquemaAjustes: no se envían).
local CLAVES_LOCALES = { Sombras = true }
local CLAVES_SERVIDOR = RemoteContracts.ClavesAjustes or {}
local CAMPOS_AJUSTES = (RemoteContracts.EsquemaAjustes and RemoteContracts.EsquemaAjustes.campos) or {}

local CLASES_EFECTO = { ParticleEmitter = true, Beam = true, Trail = true, Fire = true, Smoke = true, Sparkles = true }
local CLASES_POST = { BloomEffect = true, SunRaysEffect = true, ColorCorrectionEffect = true, DepthOfFieldEffect = true, BlurEffect = true }

-- Decoración "cosmética" (animaciones: ventiladores con scripts, espejo) según Catalogs.DecoracionPesada.
local NOMBRES_COSMETICOS = {}
for _, entrada in ipairs(Catalogs.DecoracionPesada or {}) do
	local tipo = string.lower(tostring(entrada.Tipo or ""))
	if string.find(tipo, "ventilador", 1, true) or string.find(tipo, "espejo", 1, true) then
		NOMBRES_COSMETICOS[entrada.Nombre] = true
	end
end

local NOMBRES_DISPOSITIVO = { PC = "PC", Tableta = "Tableta", Movil = "Móvil", Mando = "Mando / consola" }
local NOMBRES_MODO = { Calidad = "Calidad", Bajos = "Bajos recursos", Automatico = "Automático" }

local OPCIONES_MODO = {
	{ Valor = "Automatico", Texto = "Automático" },
	{ Valor = "Bajos", Texto = "Bajos recursos" },
	{ Valor = "Calidad", Texto = "Calidad" },
}
local OPCIONES_LIMITE = {
	{ Valor = 0, Texto = "0 · ninguno" },
	{ Valor = 1, Texto = "1" },
	{ Valor = 2, Texto = "2" },
	{ Valor = 3, Texto = "3" },
}
local OPCIONES_ESCALA = {}
for n = 8, 14 do
	table.insert(OPCIONES_ESCALA, { Valor = n / 10, Texto = tostring(n * 10) .. " %" })
end
local OPCIONES_HORA = {
	{ Valor = 24, Texto = "24 h" },
	{ Valor = 12, Texto = "12 h (a. m. / p. m.)" },
}

---------------------------------------------------------------------------------------------------
-- Estado
---------------------------------------------------------------------------------------------------
local function copiar(tabla)
	local copia = {}
	for clave, valor in pairs(tabla) do
		copia[clave] = valor
	end
	return copia
end

local function clamp(valor, minimo, maximo)
	return math.max(minimo, math.min(maximo, valor))
end

local ajustes = copiar(PREDETERMINADOS)
local tocadas = {} -- Claves cambiadas por el jugador en esta sesión.
local efectivo = {} -- Valores efectivos (ajuste combinado con el modo).
local modoAnterior = nil
local snapshotCargado = false
local introMostrada = false
local activo = false
local abierto = false
local escaneoListo = false

local maid = Maid.new()
local maidPanel = Maid.new()
local ui = { Gui = nil, Panel = nil, Lista = nil, Estado = nil, Controles = {}, Aviso = nil }

-- Índices locales (tablas fuertes; se depuran al quitar instancias y en la revisión periódica).
local efectos = {} -- [efecto] = { Original = bool|nil, Transitorio = bool, Permitido = bool }
local transitorios = {} -- efectos transitorios en orden de llegada
local sonidos = {} -- [Sound] = { Original = number|nil }
local decoracion = {} -- [BasePart|Decal] = { Raiz = Instance, Cosmetica = bool, Oculto = bool }
local raicesDecoracion = {} -- [raiz] = cosmetica (bool)
local postEfectos = {} -- [PostEffect] = { Original = bool|nil }
local atmosferas = {} -- [Atmosphere] = { Original = number|nil }
local espejos = {} -- [ViewportFrame] = { Original = bool|nil }
local sombrasOriginal = nil

-- FPS (media móvil de 2 s).
local cubetasFrames = {}
local cubetasTiempo = {}
for i = 1, CUBETAS_FPS do
	cubetasFrames[i] = 0
	cubetasTiempo[i] = 0
end
local indiceCubeta = 1
local framesActual, tiempoActual = 0, 0
local fpsMedio = 60
local tiempoBajo = 0
local avisoMostrado = false
local ventanaEnFoco = true
local inicioReloj = os.clock()
local contadorCubetas = 0

-- Guardado.
local ultimoEnvio = -math.huge
local envioProgramado = false
local metricaPendiente = false

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function obtenerControlador(nombre)
	local registro = SettingsController.registro
	if typeof(registro) ~= "table" or typeof(registro.Get) ~= "function" then
		return nil
	end
	local ok, controlador = pcall(registro.Get, nombre)
	if ok and typeof(controlador) == "table" then
		return controlador
	end
	return nil
end

local function redondearEscala(valor)
	local n = math.floor((tonumber(valor) or 1) * 10 + 0.5)
	n = clamp(n, math.floor(ESCALA_MIN * 10 + 0.5), math.floor(ESCALA_MAX * 10 + 0.5))
	return n / 10
end

-- Valida un valor de ajuste con el descriptor de RemoteContracts.EsquemaAjustes. Devuelve el valor saneado o nil.
local function sanearValor(clave, valor)
	if valor == nil then
		return nil
	end
	local base = PREDETERMINADOS[clave]
	if base == nil then
		return nil
	end
	local descriptor = CAMPOS_AJUSTES[clave]
	if descriptor and not CLAVES_LOCALES[clave] then
		local ok = Validate.ComprobarValor(descriptor, valor, clave)
		if not ok then
			return nil
		end
	elseif typeof(valor) ~= typeof(base) then
		return nil
	end
	if clave == "LimiteEfectos" then
		return clamp(math.floor(valor + 0.5), 0, LIMITE_EFECTOS_MAX)
	elseif clave == "EscalaTexto" then
		return redondearEscala(valor)
	end
	return valor
end

local function esDePersonaje(inst)
	local modelo = inst:FindFirstAncestorOfClass("Model")
	local niveles = 0
	while modelo and niveles < 3 do
		if modelo:FindFirstChildOfClass("Humanoid") then
			return true
		end
		modelo = modelo:FindFirstAncestorOfClass("Model")
		niveles = niveles + 1
	end
	return false
end

local function posicionCamara()
	local camara = workspace.CurrentCamera
	if camara then
		return camara.CFrame.Position
	end
	return nil
end

local function fijar(inst, propiedad, valor)
	pcall(function()
		inst[propiedad] = valor
	end)
end

---------------------------------------------------------------------------------------------------
-- Modo y valores efectivos
---------------------------------------------------------------------------------------------------

-- Modo efectivo: "Calidad" | "Bajos". Automático = Bajos en móvil/tableta, Calidad en PC/mando.
function SettingsController.Modo()
	local modo = ajustes.ModoGraficos
	if modo == "Calidad" or modo == "Bajos" then
		return modo
	end
	local dispositivo = UITheme.Dispositivo()
	if dispositivo == "Movil" or dispositivo == "Tableta" then
		return "Bajos"
	end
	return "Calidad"
end

local function recalcularEfectivo()
	local modo = SettingsController.Modo()
	local bajos = modo == "Bajos"
	efectivo.Modo = modo
	efectivo.Bajos = bajos
	-- Bajos recursos fuerza a apagado las opciones de coste gráfico (los interruptores conservan su valor).
	efectivo.Particulas = ajustes.Particulas == true and not bajos
	efectivo.Postprocesado = ajustes.Postprocesado == true and not bajos
	efectivo.Sombras = ajustes.Sombras == true and not bajos
	efectivo.Cosmeticas = ajustes.AnimacionesCosmeticas == true and not bajos
	efectivo.OcultarTodaDecoracion = bajos or ajustes.DecoracionLejana ~= true
	efectivo.SonidosAmbiente = ajustes.SonidosAmbiente == true
	local limite = tonumber(ajustes.LimiteEfectos) or 2
	if bajos then
		limite = math.min(limite, 1)
	end
	efectivo.LimiteEfectos = limite
	efectivo.Espejo = ajustes.AnimacionesCosmeticas == true and not bajos
	efectivo.AtmosferaReducida = bajos
end

---------------------------------------------------------------------------------------------------
-- Aplicación local por categoría
---------------------------------------------------------------------------------------------------

-- Efectos (ParticleEmitter, Beam, Trail, Fire, Smoke, Sparkles): Enabled local, guardando el original.
local function quiereActivoEfecto(info)
	if not efectivo.Particulas then
		return false
	end
	if info.Transitorio and info.Permitido == false then
		return false
	end
	return true
end

local function aplicarEfecto(inst, info)
	if quiereActivoEfecto(info) then
		if info.Original ~= nil then
			fijar(inst, "Enabled", info.Original)
			info.Original = nil
		end
	elseif inst.Enabled then
		info.Original = true
		fijar(inst, "Enabled", false)
	elseif info.Original == nil then
		info.Original = false
	end
end

local function naturalActivo(inst, info)
	if info.Original ~= nil then
		return info.Original
	end
	return inst.Enabled == true
end

-- Los efectos transitorios (aparecidos tras la carga, fuera de personajes) se limitan a LimiteEfectos activos.
local function recalcularTransitorios()
	local limite = efectivo.LimiteEfectos or 0
	local activos = 0
	local i = 1
	while i <= #transitorios do
		local inst = transitorios[i]
		local info = efectos[inst]
		if info == nil or inst.Parent == nil then
			table.remove(transitorios, i)
			efectos[inst] = nil
		else
			local permitido = true
			if naturalActivo(inst, info) then
				if activos < limite then
					activos = activos + 1
				else
					permitido = false
				end
			end
			info.Permitido = permitido
			aplicarEfecto(inst, info)
			i = i + 1
		end
	end
end

local function registrarEfecto(inst, dinamico)
	if efectos[inst] then
		return
	end
	local info = { Original = nil, Transitorio = dinamico == true and not esDePersonaje(inst), Permitido = true }
	efectos[inst] = info
	if info.Transitorio then
		table.insert(transitorios, inst)
		recalcularTransitorios()
	else
		aplicarEfecto(inst, info)
	end
end

-- Sonidos en bucle de Workspace (ambiente): Volume local guardando el original.
local function aplicarSonido(sonido, info)
	local silenciar = (not efectivo.SonidosAmbiente) and sonido.Looped == true
	if silenciar then
		if sonido.Volume > 0 then
			info.Original = sonido.Volume
			fijar(sonido, "Volume", 0)
		elseif info.Original == nil then
			info.Original = 0
		end
	elseif info.Original ~= nil then
		fijar(sonido, "Volume", info.Original)
		info.Original = nil
	end
end

local function registrarSonido(sonido)
	if sonidos[sonido] or esDePersonaje(sonido) then
		return
	end
	local info = { Original = nil }
	sonidos[sonido] = info
	aplicarSonido(sonido, info)
end

-- Decoración pesada: LocalTransparencyModifier (nunca Transparency) en BaseParts y Decals.
local function posicionDe(inst)
	if inst:IsA("BasePart") then
		return inst.Position
	end
	local padre = inst.Parent
	if padre and padre:IsA("BasePart") then
		return padre.Position
	end
	return nil
end

local function aplicarDecoracion(inst, info, camPos)
	local ocultar = false
	if efectivo.OcultarTodaDecoracion then
		ocultar = true
	elseif info.Cosmetica and not efectivo.Cosmeticas then
		ocultar = true
	elseif camPos then
		local posicion = posicionDe(inst)
		if posicion and (posicion - camPos).Magnitude > DISTANCIA_DECORACION then
			ocultar = true
		end
	end
	if ocultar ~= info.Oculto then
		info.Oculto = ocultar
		if ocultar then
			fijar(inst, "LocalTransparencyModifier", 1)
		else
			fijar(inst, "LocalTransparencyModifier", 0)
		end
	end
end

local function esVisual(inst)
	return inst:IsA("BasePart") or inst:IsA("Decal")
end

local function esCosmetica(raiz)
	local actual = raiz
	while actual and actual ~= workspace and actual ~= game do
		if NOMBRES_COSMETICOS[actual.Name] then
			return true
		end
		actual = actual.Parent
	end
	return false
end

local function agregarParteDecoracion(inst, raiz, cosmetica, camPos)
	if decoracion[inst] then
		return
	end
	local info = { Raiz = raiz, Cosmetica = cosmetica == true, Oculto = false }
	decoracion[inst] = info
	aplicarDecoracion(inst, info, camPos)
end

local function registrarRaizDecoracion(raiz)
	if raicesDecoracion[raiz] ~= nil or not raiz:IsDescendantOf(workspace) then
		return
	end
	local cosmetica = esCosmetica(raiz)
	raicesDecoracion[raiz] = cosmetica
	local camPos = posicionCamara()
	if esVisual(raiz) then
		agregarParteDecoracion(raiz, raiz, cosmetica, camPos)
	end
	for _, descendiente in ipairs(raiz:GetDescendants()) do
		if esVisual(descendiente) then
			agregarParteDecoracion(descendiente, raiz, cosmetica, camPos)
		end
	end
end

-- Quita una raíz (p. ej. al retirar el tag) y restaura sus partes, salvo que siga siendo decoración por nombre.
local function quitarRaizDecoracion(raiz)
	if raicesDecoracion[raiz] == nil or Catalogs.EsDecoracionPesada(raiz.Name) then
		return
	end
	raicesDecoracion[raiz] = nil
	for inst, info in pairs(decoracion) do
		if info.Raiz == raiz then
			if info.Oculto then
				fijar(inst, "LocalTransparencyModifier", 0)
			end
			decoracion[inst] = nil
		end
	end
end

local function raizDecoracionDe(inst)
	local actual = inst.Parent
	while actual and actual ~= workspace and actual ~= game do
		if raicesDecoracion[actual] ~= nil then
			return actual
		end
		actual = actual.Parent
	end
	return nil
end

-- Postprocesado de Lighting / cámara: Enabled local.
local function aplicarPost(efecto, info)
	if efectivo.Postprocesado then
		if info.Original ~= nil then
			fijar(efecto, "Enabled", info.Original)
			info.Original = nil
		end
	elseif efecto.Enabled then
		info.Original = true
		fijar(efecto, "Enabled", false)
	elseif info.Original == nil then
		info.Original = false
	end
end

local function registrarPost(efecto)
	if postEfectos[efecto] or string.sub(efecto.Name, 1, #PREFIJO) == PREFIJO then
		return -- Los efectos propios de ColegioRP (desenfoque del menú, etc.) los gestiona su controlador.
	end
	local info = { Original = nil }
	postEfectos[efecto] = info
	aplicarPost(efecto, info)
end

-- Atmosphere.Density: -50 % en Bajos (guardando el original).
local function aplicarAtmosfera(atmosfera, info)
	if efectivo.AtmosferaReducida then
		if info.Original == nil then
			info.Original = atmosfera.Density
			fijar(atmosfera, "Density", info.Original * 0.5)
		end
	elseif info.Original ~= nil then
		fijar(atmosfera, "Density", info.Original)
		info.Original = nil
	end
end

local function registrarAtmosfera(atmosfera)
	if atmosferas[atmosfera] then
		return
	end
	local info = { Original = nil }
	atmosferas[atmosfera] = info
	aplicarAtmosfera(atmosfera, info)
end

-- Espejo (Project Mirror): ViewportFrame dentro de una SurfaceGui ajena (en PlayerGui o en el mapa).
local function aplicarEspejo(marco, info)
	if efectivo.Espejo then
		if info.Original ~= nil then
			fijar(marco, "Visible", info.Original)
			info.Original = nil
		end
	elseif marco.Visible then
		info.Original = true
		fijar(marco, "Visible", false)
	elseif info.Original == nil then
		info.Original = false
	end
end

local function registrarEspejo(marco)
	if espejos[marco] then
		return
	end
	local superficie = marco:FindFirstAncestorOfClass("SurfaceGui")
	if not superficie or string.sub(superficie.Name, 1, #PREFIJO) == PREFIJO then
		return
	end
	local info = { Original = nil }
	espejos[marco] = info
	aplicarEspejo(marco, info)
end

-- Sombras: Lighting.GlobalShadows local.
local function aplicarSombras()
	if efectivo.Sombras then
		if sombrasOriginal ~= nil then
			Lighting.GlobalShadows = sombrasOriginal
			sombrasOriginal = nil
		end
	elseif Lighting.GlobalShadows then
		if sombrasOriginal == nil then
			sombrasOriginal = true
		end
		Lighting.GlobalShadows = false
	end
end

-- Accesibilidad: UIScale de todas las pantallas ColegioRP_*, movimiento reducido y atributos locales.
local function aplicarAccesibilidad()
	UIBuilder.AplicarAjustes({ MovimientoReducido = ajustes.MovimientoReducido == true, EscalaTexto = ajustes.EscalaTexto })
	pcall(UIBuilder.EscalarPantallas)
	pcall(function()
		-- Atributos LOCALES del Player (no se replican): los leen UIBuilder.Tween, la pantalla de carga,
		-- el HUD (FormatoHora), las notificaciones (Subtitulos) y las etiquetas (OcultarEtiquetas).
		LocalPlayer:SetAttribute("MovimientoReducido", ajustes.MovimientoReducido == true)
		LocalPlayer:SetAttribute("EscalaTexto", ajustes.EscalaTexto)
		LocalPlayer:SetAttribute("Subtitulos", ajustes.Subtitulos == true)
		LocalPlayer:SetAttribute("FormatoHora", ajustes.FormatoHora)
		LocalPlayer:SetAttribute("OcultarEtiquetas", ajustes.OcultarEtiquetas == true)
	end)
end

local function aplicarTodo()
	recalcularEfectivo()
	local camPos = posicionCamara()
	for inst, info in pairs(efectos) do
		if not info.Transitorio then
			pcall(aplicarEfecto, inst, info)
		end
	end
	pcall(recalcularTransitorios)
	for sonido, info in pairs(sonidos) do
		pcall(aplicarSonido, sonido, info)
	end
	for inst, info in pairs(decoracion) do
		pcall(aplicarDecoracion, inst, info, camPos)
	end
	for efecto, info in pairs(postEfectos) do
		pcall(aplicarPost, efecto, info)
	end
	for atmosfera, info in pairs(atmosferas) do
		pcall(aplicarAtmosfera, atmosfera, info)
	end
	for marco, info in pairs(espejos) do
		pcall(aplicarEspejo, marco, info)
	end
	pcall(aplicarSombras)
	aplicarAccesibilidad()
	if efectivo.Modo ~= modoAnterior then
		modoAnterior = efectivo.Modo
		pcall(function()
			LocalPlayer:SetAttribute("ModoGraficos", efectivo.Modo)
		end)
		SettingsController.ModoCambiado:Fire(efectivo.Modo)
	end
end

---------------------------------------------------------------------------------------------------
-- Indexado de instancias (una pasada por Workspace + DescendantAdded)
---------------------------------------------------------------------------------------------------
local function clasificar(inst, dinamico)
	local clase = inst.ClassName
	if CLASES_EFECTO[clase] then
		registrarEfecto(inst, dinamico)
		return
	end
	if clase == "Sound" then
		registrarSonido(inst)
		return
	end
	if clase == "ViewportFrame" then
		registrarEspejo(inst)
		return
	end
	if CLASES_POST[clase] then
		registrarPost(inst) -- Efectos dentro de workspace.CurrentCamera.
		return
	end
	if Catalogs.EsDecoracionPesada(inst.Name) then
		registrarRaizDecoracion(inst)
	elseif dinamico and esVisual(inst) then
		local raiz = raizDecoracionDe(inst)
		if raiz then
			agregarParteDecoracion(inst, raiz, raicesDecoracion[raiz], posicionCamara())
		end
	end
end

local function olvidar(inst)
	if efectos[inst] then
		local info = efectos[inst]
		efectos[inst] = nil
		if info.Transitorio then
			recalcularTransitorios()
		end
	end
	sonidos[inst] = nil
	decoracion[inst] = nil
	raicesDecoracion[inst] = nil
	postEfectos[inst] = nil
	espejos[inst] = nil
	atmosferas[inst] = nil
end

local function escanearWorkspace()
	local lista = workspace:GetDescendants()
	for i = 1, #lista do
		pcall(clasificar, lista[i], false)
		if i % LOTE_ESCANEO == 0 then
			task.wait()
			if not activo then
				return
			end
		end
	end
	escaneoListo = true
	pcall(recalcularTransitorios)
end

local function escanearLighting()
	for _, hijo in ipairs(Lighting:GetChildren()) do
		if CLASES_POST[hijo.ClassName] then
			registrarPost(hijo)
		elseif hijo:IsA("Atmosphere") then
			registrarAtmosfera(hijo)
		end
	end
end

-- Revisión periódica (cada 2 s): decoración por distancia, depuración y valores reafirmados por el servidor.
local function revisar()
	if SettingsController.Modo() ~= efectivo.Modo then
		-- En Automático el dispositivo puede cambiar (mando conectado, rotación de tableta).
		aplicarTodo()
	end
	local camPos = posicionCamara()
	for inst, info in pairs(decoracion) do
		if inst.Parent == nil then
			decoracion[inst] = nil
		else
			aplicarDecoracion(inst, info, camPos)
		end
	end
	local depurar = false
	for inst, info in pairs(efectos) do
		if inst.Parent == nil then
			efectos[inst] = nil
			if info.Transitorio then
				depurar = true
			end
		elseif inst.Enabled and not quiereActivoEfecto(info) then
			aplicarEfecto(inst, info)
		end
	end
	if depurar then
		recalcularTransitorios()
	end
	for sonido, info in pairs(sonidos) do
		if sonido.Parent == nil then
			sonidos[sonido] = nil
		elseif not efectivo.SonidosAmbiente then
			aplicarSonido(sonido, info)
		end
	end
	for efecto, info in pairs(postEfectos) do
		if efecto.Parent == nil then
			postEfectos[efecto] = nil
		elseif not efectivo.Postprocesado and efecto.Enabled then
			aplicarPost(efecto, info)
		end
	end
	for marco, info in pairs(espejos) do
		if marco.Parent == nil then
			espejos[marco] = nil
		elseif not efectivo.Espejo and marco.Visible then
			aplicarEspejo(marco, info)
		end
	end
	if not efectivo.Sombras and Lighting.GlobalShadows then
		aplicarSombras()
	end
end

---------------------------------------------------------------------------------------------------
-- Persistencia (SettingsUpdate con throttle) y métricas
---------------------------------------------------------------------------------------------------
local function ajustesParaServidor()
	local datos = {}
	for _, clave in ipairs(CLAVES_SERVIDOR) do
		-- Sin snapshot no se conoce el perfil del servidor: solo se envían las claves que el jugador cambió.
		if snapshotCargado or tocadas[clave] then
			local valor = sanearValor(clave, ajustes[clave])
			if valor ~= nil then
				datos[clave] = valor
			end
		end
	end
	return datos
end

local function enviarAjustes()
	envioProgramado = false
	if not activo then
		return
	end
	local ajustesEnvio = ajustesParaServidor()
	if next(ajustesEnvio) == nil then
		return
	end
	local datos = { Ajustes = ajustesEnvio }
	local ok, err = RemoteContracts.Validar("SettingsUpdate", datos)
	if not ok then
		warn(LOG .. "Ajustes no válidos, no se envían: " .. tostring(err))
		return
	end
	ultimoEnvio = os.clock()
	Net.Disparar("SettingsUpdate", datos)
end

local function programarGuardado()
	if envioProgramado then
		return
	end
	envioProgramado = true
	local espera = math.max(0, THROTTLE_GUARDADO - (os.clock() - ultimoEnvio))
	task.delay(espera, enviarAjustes)
end

local function enviarMetrica()
	if metricaPendiente then
		return -- La anterior sigue en curso (p. ej. el servidor aún no tiene handler): no se acumulan.
	end
	metricaPendiente = true
	task.spawn(function()
		pcall(function()
			Net.Invocar("StaffAction", {
				Accion = "Metrica",
				Datos = {
					FPS = math.floor(fpsMedio + 0.5),
					Dispositivo = UITheme.Dispositivo(),
					ModoGraficos = SettingsController.Modo(),
				},
			})
		end)
		metricaPendiente = false
	end)
end

---------------------------------------------------------------------------------------------------
-- Interfaz
---------------------------------------------------------------------------------------------------
local cambiar -- (clave, valor) declarado más abajo.

local function emitirCambio(clave)
	SettingsController.Cambiado:Fire(copiar(ajustes), clave)
end

local function textoEstado()
	local dispositivo = UITheme.Dispositivo()
	local modo = SettingsController.Modo()
	local texto = "Modo activo: " .. (NOMBRES_MODO[modo] or modo)
	if ajustes.ModoGraficos == "Automatico" then
		texto = texto .. " (automático)"
	end
	return texto .. " · Dispositivo: " .. (NOMBRES_DISPOSITIVO[dispositivo] or dispositivo)
		.. " · FPS medio: " .. tostring(math.floor(fpsMedio + 0.5))
end

local function refrescarEstado()
	if ui.Estado and ui.Estado.Parent ~= nil then
		ui.Estado.Text = textoEstado()
	end
end

local function refrescarControles()
	for clave, control in pairs(ui.Controles) do
		if control and typeof(control.Fijar) == "function" then
			pcall(function()
				control:Fijar(ajustes[clave], true)
			end)
		end
	end
	refrescarEstado()
end

local function cerrarHermanos()
	for _, nombre in ipairs({ "HelpController", "SupportController" }) do
		local otro = obtenerControlador(nombre)
		if otro and typeof(otro.Cerrar) == "function" then
			local estaAbierto = true
			if typeof(otro.EstaAbierto) == "function" then
				local ok, valor = pcall(otro.EstaAbierto)
				estaAbierto = ok and valor == true
			end
			if estaAbierto then
				pcall(otro.Cerrar)
			end
		end
	end
end

local function construirUI()
	local gui = UIBuilder.Pantalla("Ajustes", ORDEN_PANTALLA)
	ui.Gui = gui
	ui.Controles = {}
	ui.Aviso = nil
	local contenedor = UIBuilder.Contenedor(gui)
	local panel, lista = UIBuilder.Panel(contenedor, {
		Nombre = "PanelAjustes",
		Titulo = "Ajustes y optimización",
		AlCerrar = function()
			SettingsController.Cerrar()
		end,
		Scroll = true,
		Espaciado = 6,
		Size = UDim2.new(1, 0, 1, 0),
	})
	local limite = Instance.new("UISizeConstraint")
	limite.MaxSize = Vector2.new(600, 720)
	limite.Parent = panel
	pcall(function()
		panel.SelectionGroup = true
	end)
	panel.Visible = false
	ui.Panel = panel
	ui.Lista = lista

	local orden = 0
	local function siguiente()
		orden = orden + 1
		return orden
	end
	local function interruptor(clave, texto, descripcion)
		ui.Controles[clave] = UIBuilder.Interruptor(lista, texto, ajustes[clave], function(valor)
			cambiar(clave, valor)
		end, { LayoutOrder = siguiente(), Nombre = clave, Descripcion = descripcion })
	end
	local function selector(clave, texto, opciones)
		ui.Controles[clave] = UIBuilder.Selector(lista, texto, opciones, ajustes[clave], function(valor)
			cambiar(clave, valor)
		end, { LayoutOrder = siguiente(), Nombre = clave, AnchoGrupo = 240 })
	end

	ui.Estado = UIBuilder.Texto(lista, textoEstado(), {
		Nombre = "Estado", Tamano = "Pequeno", Color = Colores.TextoSecundario, LayoutOrder = siguiente(),
	})
	UIBuilder.Subtitulo(lista, "Gráficos y rendimiento", { LayoutOrder = siguiente() })
	selector("ModoGraficos", "Modo gráfico", OPCIONES_MODO)
	UIBuilder.Texto(lista, "Automático usa Bajos recursos en móvil y tableta y Calidad en PC y consola. Bajos recursos apaga siempre partículas, postprocesado, sombras, decoración pesada, ventiladores y espejo, y reduce la niebla. Todo se aplica solo en tu dispositivo.", {
		Nombre = "NotaModo", Tamano = "Pequeno", Color = Colores.TextoApagado, LayoutOrder = siguiente(),
	})
	interruptor("Particulas", "Partículas", "Humo, chispas, fuego, rayos y estelas")
	interruptor("DecoracionLejana", "Decoración lejana", "Sí: oculta solo la lejana. No: oculta toda")
	interruptor("Postprocesado", "Postprocesado", "Resplandor, rayos de sol, color y desenfoque")
	interruptor("Sombras", "Sombras", "Sombras globales (se recuerda en esta sesión)")
	interruptor("SonidosAmbiente", "Sonidos ambientales", "Ventiladores, aires y sonidos en bucle")
	interruptor("AnimacionesCosmeticas", "Animaciones cosméticas", "Ventiladores giratorios y espejo del baño")
	selector("LimiteEfectos", "Efectos transitorios a la vez", OPCIONES_LIMITE)

	UIBuilder.Subtitulo(lista, "Accesibilidad", { LayoutOrder = siguiente() })
	selector("EscalaTexto", "Escala de texto", OPCIONES_ESCALA)
	interruptor("MovimientoReducido", "Movimiento reducido", "Sin animaciones de paneles ni partículas de carga")
	interruptor("Subtitulos", "Subtítulos", "Texto del timbre y de los avisos sonoros")
	selector("FormatoHora", "Formato de hora", OPCIONES_HORA)
	interruptor("OcultarEtiquetas", "Ocultar etiquetas", "Nombres y cargos sobre los jugadores")

	UIBuilder.Espacio(lista, 4, siguiente())
	local fila = UIBuilder.Fila(lista, { LayoutOrder = siguiente(), Nombre = "Acciones" })
	local confirmarHasta = 0
	local textoRestaurar = "Restaurar predeterminados"
	UIBuilder.Boton(fila, textoRestaurar, function(boton)
		if os.clock() < confirmarHasta then
			confirmarHasta = 0
			boton.Text = textoRestaurar
			SettingsController.Restaurar()
		else
			confirmarHasta = os.clock() + 4
			boton.Text = "¿Seguro? Pulsa otra vez"
			task.delay(4.1, function()
				if os.clock() >= confirmarHasta and boton.Parent ~= nil then
					boton.Text = textoRestaurar
				end
			end)
		end
	end, { Estilo = "Peligro", Ancho = 250, LayoutOrder = 1, Nombre = "Restaurar" })
	UIBuilder.Boton(fila, "Cerrar", function()
		SettingsController.Cerrar()
	end, { Estilo = "Secundario", Ancho = 120, LayoutOrder = 2, Nombre = "CerrarPanel" })
	UIBuilder.Texto(lista, "Los ajustes se guardan en tu perfil automáticamente.", {
		Nombre = "NotaGuardado", Tamano = "Pequeno", Color = Colores.TextoApagado, LayoutOrder = siguiente(),
	})
end

local function asegurarUI()
	if not ui.Gui or ui.Gui.Parent == nil or not ui.Panel or ui.Panel.Parent == nil then
		construirUI()
	end
end

local function cerrarAviso()
	if ui.Aviso then
		local aviso = ui.Aviso
		ui.Aviso = nil
		UIBuilder.Desenfocar(aviso)
		UIBuilder.Desaparecer(aviso, true)
	end
end

-- Aviso de rendimiento (una vez por sesión): "Rendimiento bajo: ¿cambiar a Bajos recursos?".
local function mostrarAvisoRendimiento()
	if avisoMostrado then
		return
	end
	avisoMostrado = true
	local ok, err = pcall(function()
		asegurarUI()
		cerrarAviso()
		local escala = math.max(0.5, UIBuilder.EscalaTotal())
		local ancho = math.min(460, math.max(260, UIBuilder.AnchoUI() - 24))
		local aviso, cuerpo = UIBuilder.Panel(ui.Gui, {
			Nombre = "AvisoRendimiento",
			Titulo = "Rendimiento bajo",
			AutoAlto = true,
			Size = UDim2.new(0, ancho, 0, 0),
			Position = UDim2.new(0.5, 0, 0, math.ceil(UIBuilder.InsetSuperior() / escala) + 10),
			AnchorPoint = Vector2.new(0.5, 0),
			AlCerrar = cerrarAviso,
			ZIndex = 5,
		})
		ui.Aviso = aviso
		UIBuilder.Texto(cuerpo, "Rendimiento bajo: ¿cambiar a Bajos recursos?", { LayoutOrder = 1, Fuente = "Subtitulo" })
		UIBuilder.Texto(cuerpo, "FPS medio por debajo de " .. FPS_AVISO .. " durante " .. FPS_AVISO_SEG .. " s en modo Calidad. Puedes volver a Calidad en AJUSTES.", {
			LayoutOrder = 2, Tamano = "Pequeno", Color = Colores.TextoSecundario,
		})
		local fila = UIBuilder.Fila(cuerpo, { LayoutOrder = 3, Nombre = "Botones", Alineacion = Enum.HorizontalAlignment.Right })
		UIBuilder.Boton(fila, "Ahora no", cerrarAviso, { Estilo = "Secundario", Ancho = 120, LayoutOrder = 1 })
		local aceptar = UIBuilder.Boton(fila, "Cambiar a Bajos", function()
			cerrarAviso()
			cambiar("ModoGraficos", "Bajos")
		end, { Estilo = "Primario", Ancho = 170, LayoutOrder = 2 })
		UIBuilder.Aparecer(aviso)
		UIBuilder.Enfocar(aceptar)
		task.delay(30, function()
			if ui.Aviso == aviso then
				cerrarAviso()
			end
		end)
	end)
	if not ok then
		warn(LOG .. "No se pudo mostrar el aviso de rendimiento: " .. tostring(err))
	end
end

---------------------------------------------------------------------------------------------------
-- Medidor de FPS (RenderStepped; media móvil de 2 s en cubetas de 0.25 s)
---------------------------------------------------------------------------------------------------
local function cerrarCubeta()
	cubetasFrames[indiceCubeta] = framesActual
	cubetasTiempo[indiceCubeta] = tiempoActual
	indiceCubeta = indiceCubeta % CUBETAS_FPS + 1
	local duracion = tiempoActual
	framesActual, tiempoActual = 0, 0
	local frames, tiempo = 0, 0
	for i = 1, CUBETAS_FPS do
		frames = frames + cubetasFrames[i]
		tiempo = tiempo + cubetasTiempo[i]
	end
	if tiempo > 0 then
		fpsMedio = frames / tiempo
	end
	contadorCubetas = contadorCubetas + 1
	if abierto and contadorCubetas % 2 == 0 then
		refrescarEstado()
	end
	-- Aviso de rendimiento (solo en Calidad, con la ventana en foco y pasada la carga inicial).
	if avisoMostrado then
		return
	end
	if efectivo.Modo ~= "Calidad" or not ventanaEnFoco or os.clock() - inicioReloj < GRACIA_FPS_SEG then
		tiempoBajo = 0
		return
	end
	if fpsMedio < FPS_AVISO then
		tiempoBajo = tiempoBajo + duracion
		if tiempoBajo >= FPS_AVISO_SEG then
			mostrarAvisoRendimiento()
		end
	else
		tiempoBajo = 0
	end
end

---------------------------------------------------------------------------------------------------
-- Cambios de ajustes
---------------------------------------------------------------------------------------------------
cambiar = function(clave, valor)
	local saneado = sanearValor(clave, valor)
	if saneado == nil or ajustes[clave] == saneado then
		return
	end
	ajustes[clave] = saneado
	tocadas[clave] = true
	aplicarTodo()
	if not CLAVES_LOCALES[clave] then
		programarGuardado()
	end
	local control = ui.Controles[clave]
	if control and typeof(control.Fijar) == "function" then
		pcall(function()
			control:Fijar(saneado, true)
		end)
	end
	refrescarEstado()
	emitirCambio(clave)
end

-- Mezcla los ajustes del servidor (snapshot) respetando lo que el jugador ya cambió en esta sesión.
local function fusionarRemotos(remotos)
	for _, clave in ipairs(CLAVES_SERVIDOR) do
		if not tocadas[clave] then
			local valor = sanearValor(clave, remotos[clave])
			if valor ~= nil then
				ajustes[clave] = valor
			end
		end
	end
	aplicarTodo()
	refrescarControles()
	emitirCambio(nil)
	if next(tocadas) ~= nil then
		programarGuardado() -- Ya se conoce el perfil: se envía el conjunto completo.
	end
end

-- Si la pantalla de carga mostró la intro y el perfil aún no lo recuerda, se guarda IntroVista = true.
local function comprobarIntro()
	if not snapshotCargado or ajustes.IntroVista == true then
		return
	end
	if not introMostrada then
		local senal = ReplicatedFirst:FindFirstChild(NOMBRE_SENAL)
		if senal and senal:GetAttribute("IntroMostrada") == true then
			introMostrada = true
		end
	end
	if introMostrada then
		ajustes.IntroVista = true
		tocadas.IntroVista = true
		programarGuardado()
		emitirCambio("IntroVista")
	end
end

local function vigilarSenalCarga()
	local senal = ReplicatedFirst:FindFirstChild(NOMBRE_SENAL) or ReplicatedFirst:WaitForChild(NOMBRE_SENAL, 60)
	if not senal or not activo then
		return
	end
	maid:GiveTask(senal:GetAttributeChangedSignal("IntroMostrada"):Connect(comprobarIntro))
	if senal:IsA("BindableEvent") then
		maid:GiveTask(senal.Event:Connect(function(info)
			if typeof(info) == "table" and info.IntroMostrada == true then
				introMostrada = true
			end
			comprobarIntro()
		end))
	end
	comprobarIntro()
end

-- Ajustes del snapshot ya obtenido por HUDController (evita gastar el límite de StateSnapshot), o nil.
local function ajustesDeSnapshotHUD()
	local HUD = obtenerControlador("HUDController")
	if not HUD or typeof(HUD.Snapshot) ~= "function" then
		return nil
	end
	local ok, datos = pcall(HUD.Snapshot, HUD)
	if ok and typeof(datos) == "table" and typeof(datos.Ajustes) == "table" then
		return datos.Ajustes
	end
	return nil
end

local function aplicarSnapshot(remotos)
	snapshotCargado = true
	if typeof(remotos) == "table" then
		fusionarRemotos(remotos)
	end
	comprobarIntro()
end

local function cargarSnapshot()
	-- Reintentos: StateSnapshot admite 2 peticiones / 5 s y también lo pide el HUD; primero se reutiliza el suyo.
	local esperas = { 1.5, 3, 6, 12 }
	for _, espera in ipairs(esperas) do
		task.wait(espera)
		if not activo then
			return
		end
		local delHUD = ajustesDeSnapshotHUD()
		if delHUD then
			aplicarSnapshot(delHUD)
			return
		end
		local ok, respuesta = Net.Invocar("StateSnapshot", {})
		if ok and typeof(respuesta) == "table" then
			local remotos = nil
			if typeof(respuesta.datos) == "table" and typeof(respuesta.datos.Ajustes) == "table" then
				remotos = respuesta.datos.Ajustes
			elseif typeof(respuesta.Ajustes) == "table" then
				remotos = respuesta.Ajustes
			end
			aplicarSnapshot(remotos)
			return
		end
	end
	warn(LOG .. "No se pudo obtener StateSnapshot; se usan los ajustes locales (solo se guardarán los cambios).")
end

---------------------------------------------------------------------------------------------------
-- API pública (admite llamada con punto o con dos puntos)
---------------------------------------------------------------------------------------------------
local function argumento(a, b)
	if a == SettingsController then
		return b
	end
	return a
end

function SettingsController.EstaAbierto()
	return abierto
end

function SettingsController.Abrir()
	if not activo then
		return
	end
	asegurarUI()
	if abierto then
		UIBuilder.EnfocarPrimero(ui.Panel)
		return
	end
	cerrarHermanos()
	abierto = true
	refrescarControles()
	ui.Gui.Enabled = true
	UIBuilder.Aparecer(ui.Panel)
	local conexion = UIBuilder.TeclaCerrar(function()
		SettingsController.Cerrar()
	end)
	if conexion then
		maidPanel:GiveTask(conexion)
	end
	task.delay(UITheme.Animacion.Rapida + 0.05, function()
		-- Evita que una animación de cierre previa deje el panel oculto.
		if abierto and ui.Panel and ui.Panel.Parent ~= nil then
			ui.Panel.Visible = true
		end
	end)
	task.defer(function()
		if abierto then
			UIBuilder.EnfocarPrimero(ui.Panel)
		end
	end)
	SettingsController.Abierto:Fire()
end

function SettingsController.Cerrar()
	if not abierto then
		return
	end
	abierto = false
	maidPanel:DoCleaning()
	if ui.Panel and ui.Panel.Parent ~= nil then
		UIBuilder.Desenfocar(ui.Panel)
		UIBuilder.Desaparecer(ui.Panel)
	end
	SettingsController.Cerrado:Fire()
end

function SettingsController.Alternar()
	if abierto then
		SettingsController.Cerrar()
	else
		SettingsController.Abrir()
	end
end

-- Copia de los ajustes actuales (incluye la clave local Sombras).
function SettingsController.Ajustes()
	return copiar(ajustes)
end

-- Copia de los valores efectivos (ajuste combinado con el modo).
function SettingsController.Efectivo()
	recalcularEfectivo()
	return copiar(efectivo)
end

-- Aplica una tabla parcial de ajustes (claves de Perfil.Ajustes y Sombras), la guarda y refresca el panel.
function SettingsController.Aplicar(a, b)
	local nuevos = argumento(a, b)
	if typeof(nuevos) ~= "table" then
		return false
	end
	local cambiados = 0
	local servidor = false
	for clave in pairs(PREDETERMINADOS) do
		local valor = sanearValor(clave, nuevos[clave])
		if valor ~= nil and ajustes[clave] ~= valor then
			ajustes[clave] = valor
			tocadas[clave] = true
			cambiados = cambiados + 1
			if not CLAVES_LOCALES[clave] then
				servidor = true
			end
		end
	end
	if cambiados == 0 then
		return true
	end
	aplicarTodo()
	refrescarControles()
	if servidor then
		programarGuardado()
	end
	emitirCambio(nil)
	return true
end

-- Vuelve a los valores predeterminados (conserva IntroVista).
function SettingsController.Restaurar()
	local introVista = ajustes.IntroVista
	local nuevos = copiar(PREDETERMINADOS)
	nuevos.IntroVista = introVista
	for clave, valor in pairs(nuevos) do
		if ajustes[clave] ~= valor then
			tocadas[clave] = true
		end
	end
	ajustes = nuevos
	aplicarTodo()
	refrescarControles()
	programarGuardado()
	emitirCambio(nil)
end

-- FPS medio de los últimos 2 s.
function SettingsController.FPS()
	return fpsMedio
end

-- ¿Puede otro controlador lanzar un efecto transitorio ahora? (partículas activas y bajo el límite).
function SettingsController.PermitirEfecto()
	recalcularEfectivo()
	if not efectivo.Particulas then
		return false
	end
	local activos = 0
	for _, inst in ipairs(transitorios) do
		local info = efectos[inst]
		if info and info.Permitido and inst.Parent ~= nil and naturalActivo(inst, info) then
			activos = activos + 1
		end
	end
	return activos < (efectivo.LimiteEfectos or 0)
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function SettingsController:Init(registro)
	self.registro = registro
	recalcularEfectivo()
end

function SettingsController:Start()
	if activo then
		return
	end
	activo = true
	inicioReloj = os.clock()
	recalcularEfectivo()

	local okUI, errUI = pcall(construirUI)
	if not okUI then
		warn(LOG .. "No se pudo construir el panel: " .. tostring(errUI))
	end

	-- Pantallas nuevas "ColegioRP_*": reciben la UIScale de accesibilidad; espejos de PlayerGui.
	maid:GiveTask(PlayerGui.ChildAdded:Connect(function(hijo)
		if hijo:IsA("ScreenGui") then
			task.defer(function()
				if UIBuilder.EsPantallaSistema(hijo) and hijo.Parent == PlayerGui then
					UIBuilder.Escalar(hijo)
				end
			end)
		end
	end))
	maid:GiveTask(PlayerGui.DescendantAdded:Connect(function(inst)
		if inst.ClassName == "ViewportFrame" then
			task.defer(function()
				if inst.Parent ~= nil then
					pcall(registrarEspejo, inst)
				end
			end)
		end
	end))
	for _, inst in ipairs(PlayerGui:GetDescendants()) do
		if inst.ClassName == "ViewportFrame" then
			pcall(registrarEspejo, inst)
		end
	end

	-- Workspace: altas y bajas (las bajas se confirman en diferido por si solo cambió de padre).
	maid:GiveTask(workspace.DescendantAdded:Connect(function(inst)
		pcall(clasificar, inst, escaneoListo)
	end))
	maid:GiveTask(workspace.DescendantRemoving:Connect(function(inst)
		task.defer(function()
			if not inst:IsDescendantOf(workspace) then
				pcall(olvidar, inst)
			end
		end)
	end))

	-- Decoración etiquetada por MapService (tag replicado).
	for _, inst in ipairs(CollectionService:GetTagged(TAG_DECORACION)) do
		pcall(registrarRaizDecoracion, inst)
	end
	maid:GiveTask(CollectionService:GetInstanceAddedSignal(TAG_DECORACION):Connect(function(inst)
		pcall(registrarRaizDecoracion, inst)
	end))
	maid:GiveTask(CollectionService:GetInstanceRemovedSignal(TAG_DECORACION):Connect(function(inst)
		pcall(quitarRaizDecoracion, inst)
	end))

	-- Lighting.
	pcall(escanearLighting)
	maid:GiveTask(Lighting.ChildAdded:Connect(function(hijo)
		if CLASES_POST[hijo.ClassName] then
			pcall(registrarPost, hijo)
		elseif hijo:IsA("Atmosphere") then
			pcall(registrarAtmosfera, hijo)
		end
	end))
	maid:GiveTask(Lighting.ChildRemoved:Connect(function(hijo)
		postEfectos[hijo] = nil
		atmosferas[hijo] = nil
	end))

	aplicarTodo()
	task.spawn(escanearWorkspace)

	-- Medidor de FPS.
	maid:GiveTask(RunService.RenderStepped:Connect(function(dt)
		framesActual = framesActual + 1
		tiempoActual = tiempoActual + dt
		if tiempoActual >= DURACION_CUBETA then
			cerrarCubeta()
		end
	end))
	pcall(function()
		maid:GiveTask(UserInputService.WindowFocusReleased:Connect(function()
			ventanaEnFoco = false
			tiempoBajo = 0
		end))
		maid:GiveTask(UserInputService.WindowFocused:Connect(function()
			ventanaEnFoco = true
			tiempoBajo = 0
		end))
	end)

	-- Revisión periódica (cada 2 s) y métricas (cada Config.Metricas.IntervaloClienteSeg).
	maid:GiveTask(task.spawn(function()
		local acumuladoMetricas = 0
		while activo do
			task.wait(INTERVALO_REVISION)
			if not activo then
				break
			end
			local ok, err = pcall(revisar)
			if not ok then
				warn(LOG .. "Error en la revisión periódica: " .. tostring(err))
			end
			acumuladoMetricas = acumuladoMetricas + INTERVALO_REVISION
			if acumuladoMetricas >= INTERVALO_METRICAS then
				acumuladoMetricas = 0
				enviarMetrica()
			end
		end
	end))

	task.spawn(cargarSnapshot)
	task.spawn(vigilarSenalCarga)
end

-- Detiene el controlador y restaura todo lo modificado localmente (útil en pruebas y al desinstalar).
function SettingsController:Stop()
	if not activo then
		return
	end
	SettingsController.Cerrar()
	activo = false
	maid:DoCleaning()
	maidPanel:DoCleaning()
	ajustes = copiar(PREDETERMINADOS)
	ajustes.ModoGraficos = "Calidad"
	ajustes.DecoracionLejana = true
	-- Restaura los originales: modo Calidad con todo activado y sin ocultar decoración.
	recalcularEfectivo()
	efectivo.OcultarTodaDecoracion = false
	for inst, info in pairs(decoracion) do
		if info.Oculto then
			fijar(inst, "LocalTransparencyModifier", 0)
		end
	end
	for inst, info in pairs(efectos) do
		info.Permitido = true
		pcall(aplicarEfecto, inst, info)
	end
	for sonido, info in pairs(sonidos) do
		pcall(aplicarSonido, sonido, info)
	end
	for efecto, info in pairs(postEfectos) do
		pcall(aplicarPost, efecto, info)
	end
	for atmosfera, info in pairs(atmosferas) do
		pcall(aplicarAtmosfera, atmosfera, info)
	end
	for marco, info in pairs(espejos) do
		pcall(aplicarEspejo, marco, info)
	end
	pcall(aplicarSombras)
	if ui.Gui then
		UIBuilder.Destruir(ui.Gui)
	end
	ui = { Gui = nil, Panel = nil, Lista = nil, Estado = nil, Controles = {}, Aviso = nil }
end

return SettingsController
