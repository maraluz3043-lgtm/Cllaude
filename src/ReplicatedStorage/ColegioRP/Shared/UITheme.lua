--[[
	Ruta en el Explorer: ReplicatedStorage.ColegioRP.Shared.UITheme
	Tipo: ModuleScript
	Tema visual de la interfaz: colores institucionales (del logo), fuentes, tamaños, radios,
	espaciados, animaciones y detección de dispositivo para escalar el texto (PC 1, tableta 0.9, móvil 0.8).
	Es seguro requerirlo en el servidor (Escala() devuelve 1 y Dispositivo() "PC").
]]

local RunService = game:GetService("RunService")

local UITheme = {}

---------------------------------------------------------------------------------------------------
-- Colores
---------------------------------------------------------------------------------------------------
UITheme.Colores = {
	Rojo = Color3.fromRGB(196, 30, 36), -- Color principal institucional (botones primarios, acentos).
	RojoOscuro = Color3.fromRGB(150, 22, 28), -- Hover/pulsado del rojo y bordes de énfasis.
	Blanco = Color3.fromRGB(245, 245, 245), -- Texto sobre fondos oscuros y superficies claras.
	Gris = Color3.fromRGB(34, 36, 40), -- Fondo de paneles secundarios y botones neutros.
	GrisPanel = Color3.fromRGB(24, 25, 28), -- Fondo principal de paneles.
	Amarillo = Color3.fromRGB(246, 196, 34), -- Avisos, destacados, monedas.
	Azul = Color3.fromRGB(31, 78, 160), -- Información, enlaces, equipo Estudiantes.
	Verde = Color3.fromRGB(44, 160, 90), -- Éxito, confirmaciones, equipo Docentes.
	TextoPrincipal = Color3.fromRGB(245, 245, 245),
	TextoSecundario = Color3.fromRGB(190, 190, 195),
	TextoApagado = Color3.fromRGB(130, 132, 138), -- Texto deshabilitado o de ayuda.
	Fondo = Color3.fromRGB(10, 10, 12), -- Fondo de pantalla de carga y menú.
	Borde = Color3.fromRGB(60, 62, 68), -- Bordes (UIStroke) de paneles y entradas.
	Entrada = Color3.fromRGB(44, 46, 52), -- Fondo de TextBox.
	Desactivado = Color3.fromRGB(90, 92, 98), -- Botones deshabilitados.
	Sombra = Color3.fromRGB(0, 0, 0),
	Exito = Color3.fromRGB(44, 160, 90),
	Aviso = Color3.fromRGB(246, 196, 34),
	Error = Color3.fromRGB(196, 30, 36),
	Info = Color3.fromRGB(31, 78, 160),
}

-- Colores de estado para toasts y etiquetas (Tipo -> color).
UITheme.ColoresEstado = {
	Exito = UITheme.Colores.Exito,
	Aviso = UITheme.Colores.Aviso,
	Error = UITheme.Colores.Error,
	Info = UITheme.Colores.Info,
	Neutro = UITheme.Colores.Gris,
}

---------------------------------------------------------------------------------------------------
-- Tipografía
---------------------------------------------------------------------------------------------------
UITheme.Fuentes = {
	Titulo = Enum.Font.GothamBold,
	Subtitulo = Enum.Font.GothamMedium,
	Texto = Enum.Font.Gotham,
	Boton = Enum.Font.GothamMedium,
	Mono = Enum.Font.Code, -- Editor de programación y trazas.
}

-- Tamaños de texto base (se multiplican por Escala()).
UITheme.Tamanos = {
	TituloGrande = 30, -- Título del menú principal.
	Titulo = 24,
	Subtitulo = 18,
	Texto = 16,
	Boton = 16,
	Pequeno = 13,
	Etiqueta = 12, -- Etiquetas sobre la cabeza y pies de panel.
}

-- Escala de texto por dispositivo.
UITheme.EscalaTexto = { PC = 1, Tableta = 0.9, Movil = 0.8, Mando = 1 }

---------------------------------------------------------------------------------------------------
-- Geometría y animación
---------------------------------------------------------------------------------------------------
UITheme.Radio = 8 -- UICorner de paneles y botones.
UITheme.RadioPequeno = 4 -- UICorner de etiquetas y entradas.
UITheme.Espaciado = 8 -- Padding y separación estándar.
UITheme.EspaciadoGrande = 16
UITheme.GrosorBorde = 1 -- UIStroke.Thickness.
UITheme.TamanoMinimoTactil = 44 -- Alto/ancho mínimo (px) de un control táctil.
UITheme.AnchoPanel = 420 -- Ancho de referencia de paneles en PC (px).
UITheme.AnchoPanelAncho = 640
UITheme.Animacion = { Rapida = 0.15, Normal = 0.25, Lenta = 0.4 }
UITheme.Estilo = Enum.EasingStyle.Quad
UITheme.Direccion = Enum.EasingDirection.Out

-- DisplayOrder de cada capa de ScreenGui (docs/ARQUITECTURA.md §7).
UITheme.Capas = { Carga = 100, Menu = 90, Modal = 80, Panel = 50, HUD = 10 }

-- Transparencias estándar.
UITheme.Transparencias = { Panel = 0.05, Fondo = 0.35, Hover = 0.1, Desactivado = 0.5, Sombra = 0.6 }

---------------------------------------------------------------------------------------------------
-- Funciones
---------------------------------------------------------------------------------------------------

-- Color por nombre ("Rojo", "Exito", ...). Si no existe, devuelve TextoPrincipal y avisa una vez.
local avisados = {}
function UITheme.Color(nombre)
	local color = UITheme.Colores[nombre]
	if color then
		return color
	end
	if not avisados[tostring(nombre)] then
		avisados[tostring(nombre)] = true
		warn("[ColegioRP][UITheme] Color desconocido: " .. tostring(nombre))
	end
	return UITheme.Colores.TextoPrincipal
end

-- Fuente por nombre ("Titulo", "Texto", ...), con respaldo a Texto.
function UITheme.Fuente(nombre)
	return UITheme.Fuentes[nombre] or UITheme.Fuentes.Texto
end

-- Mezcla el color hacia blanco (factor 0..1).
function UITheme.Aclarar(color, factor)
	return color:Lerp(Color3.new(1, 1, 1), math.max(0, math.min(1, factor or 0.15)))
end

-- Mezcla el color hacia negro (factor 0..1).
function UITheme.Oscurecer(color, factor)
	return color:Lerp(Color3.new(0, 0, 0), math.max(0, math.min(1, factor or 0.15)))
end

-- Color de texto legible (blanco o gris oscuro) sobre un fondo dado.
function UITheme.TextoSobre(fondo)
	local luminancia = 0.299 * fondo.R + 0.587 * fondo.G + 0.114 * fondo.B
	if luminancia > 0.6 then
		return UITheme.Colores.GrisPanel
	end
	return UITheme.Colores.TextoPrincipal
end

-- Detecta el dispositivo: "PC" | "Tableta" | "Movil" | "Mando". En servidor devuelve "PC".
-- Se recalcula en cada llamada (el jugador puede conectar un mando o teclado durante la sesión).
function UITheme.Dispositivo()
	if not RunService:IsClient() then
		return "PC"
	end
	local ok, resultado = pcall(function()
		local UserInputService = game:GetService("UserInputService")
		local GuiService = game:GetService("GuiService")
		if GuiService:IsTenFootInterface() then
			return "Mando"
		end
		local tactil = UserInputService.TouchEnabled
		local teclado = UserInputService.KeyboardEnabled
		local raton = UserInputService.MouseEnabled
		if tactil and not teclado and not raton then
			local camara = workspace.CurrentCamera
			local tamano = camara and camara.ViewportSize or Vector2.new(0, 0)
			if math.min(tamano.X, tamano.Y) >= 600 then
				return "Tableta"
			end
			return "Movil"
		end
		if UserInputService.GamepadEnabled and not teclado and not raton and not tactil then
			return "Mando"
		end
		return "PC"
	end)
	if ok and typeof(resultado) == "string" then
		return resultado
	end
	return "PC"
end

-- Escala de texto según el dispositivo (1 PC, 0.9 tableta, 0.8 móvil).
function UITheme.Escala()
	return UITheme.EscalaTexto[UITheme.Dispositivo()] or 1
end

-- ¿La entrada principal es táctil?
function UITheme.EsTactil()
	local dispositivo = UITheme.Dispositivo()
	return dispositivo == "Movil" or dispositivo == "Tableta"
end

-- ¿Se navega con mando (foco)?
function UITheme.EsMando()
	return UITheme.Dispositivo() == "Mando"
end

-- Tamaño de texto escalado y redondeado (nombre de UITheme.Tamanos o número).
function UITheme.Tamano(nombreOValor, escalaUsuario)
	local base = UITheme.Tamanos[nombreOValor] or tonumber(nombreOValor) or UITheme.Tamanos.Texto
	local escala = UITheme.Escala() * (tonumber(escalaUsuario) or 1)
	return math.max(8, math.floor(base * escala + 0.5))
end

-- TweenInfo estándar ("Rapida" | "Normal" | "Lenta" o segundos). Con movimientoReducido dura 0.
function UITheme.TweenInfo(velocidad, movimientoReducido)
	local duracion = UITheme.Animacion[velocidad] or tonumber(velocidad) or UITheme.Animacion.Normal
	if movimientoReducido then
		duracion = 0
	end
	return TweenInfo.new(duracion, UITheme.Estilo, UITheme.Direccion)
end

return UITheme
