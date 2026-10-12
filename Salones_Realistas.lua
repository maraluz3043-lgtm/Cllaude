--[[
=====================================================================================
  SALONES 6B y 7B — Recreación realista en Roblox Studio (Command Bar, modo edición)
=====================================================================================
  Pegar completo en la Command Bar de Roblox Studio (Vista > Command Bar) y pulsar Enter.

  * Crea el modelo  workspace.Salones_Realistas  con Salon_1_6B, Salon_2_7B, Estructura y Corredor.
  * Es idempotente: si ya existe un modelo generado por este script lo reemplaza.
    Nunca borra objetos ajenos (se identifica por un atributo propio).
  * Si ocurre un error o se supera el límite de 1000 BaseParts, elimina la construcción
    parcial y lo informa en Output.
  * Unidad de trabajo: METROS (medidas tomadas de las fotos) -> studs mediante ESCALA.

  SISTEMA DE COORDENADAS (fijo durante toda la construcción):
    Observador de pie en el corredor, mirando la fachada de frente.
    +X  = DERECHA del observador          (6B queda a la IZQUIERDA, 7B a la DERECHA)
    -Z  = hacia el INTERIOR de los salones (la fachada está en Z = 0, los salones en Z < 0)
    +Z  = CORREDOR / EXTERIOR
    +Y  = arriba. El piso terminado está en Y = ORIGEN.Y
=====================================================================================
]]

-------------------------------------------------------------------------------
-- ETAPA 0 · CONFIGURACIÓN
-------------------------------------------------------------------------------
local LIMITE_PARTS   = 1000
local ESCALA         = 4                       -- studs por metro (puerta 0.95 m = 3.8 studs; avatar R15 pasa cómodo)
local ORIGEN         = Vector3.new(0, 0.1, 0)  -- esquina exterior IZQUIERDA de la fachada, a nivel de piso terminado (studs)
local NOMBRE_MODELO  = "Salones_Realistas"
local ATRIBUTO_MARCA = "GeneradoPorScriptSalones"

-- Dimensiones generales (metros)
local T   = 0.15   -- espesor de muros
local L   = 7.50   -- largo interior de cada salón (a lo largo de la fachada, eje X)
local D   = 6.50   -- fondo interior de cada salón (eje Z)
local H   = 3.00   -- altura libre piso-losa
local LOSA = 0.25  -- espesor de la losa de cubierta
local CORREDOR = 2.20 -- ancho del corredor cubierto (no visible completo en la foto: valor por defecto)
local ANCHO_TOTAL = 2 * L + 3 * T   -- 15.45 m: muro izq + 6B + medianera + 7B + muro der

-------------------------------------------------------------------------------
-- Servicios
-------------------------------------------------------------------------------
local Workspace = game:GetService("Workspace")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

-------------------------------------------------------------------------------
-- Paleta de colores y materiales (aproximados a las fotos)
-------------------------------------------------------------------------------
local C = {
	blancoFachada   = Color3.fromRGB(232, 232, 226),
	grisInterior    = Color3.fromRGB(160, 162, 162),
	grisLosa        = Color3.fromRGB(196, 196, 190),
	grisViga        = Color3.fromRGB(178, 180, 176),
	pisoInterior    = Color3.fromRGB(178, 76, 52),
	baldosaCorredor = Color3.fromRGB(150, 75, 55),
	cementoGris     = Color3.fromRGB(128, 126, 120),
	calado          = Color3.fromRGB(228, 228, 222),
	marcoRojo       = Color3.fromRGB(118, 30, 36),
	maderaClara     = Color3.fromRGB(168, 118, 66),
	vidrio          = Color3.fromRGB(224, 232, 232),
	verdePuerta     = Color3.fromRGB(80, 160, 70),
	blancoMarco     = Color3.fromRGB(236, 236, 232),
	puertaMetal     = Color3.fromRGB(222, 225, 229),
	metalClaro      = Color3.fromRGB(190, 190, 195),
	moradoLapiz     = Color3.fromRGB(70, 40, 90),
	amarilloPalido  = Color3.fromRGB(236, 230, 140),
	naranja         = Color3.fromRGB(235, 120, 35),
	verdeAzulado    = Color3.fromRGB(85, 150, 110),
	crema           = Color3.fromRGB(235, 215, 190),
	grafito         = Color3.fromRGB(60, 60, 60),
	verdeSenal      = Color3.fromRGB(0, 100, 60),
	conducto        = Color3.fromRGB(78, 88, 78),
	blanco          = Color3.fromRGB(240, 240, 240),
	neon            = Color3.fromRGB(255, 250, 235),
	azulSilla       = Color3.fromRGB(28, 60, 215),
	negroMetal      = Color3.fromRGB(28, 28, 30),
	negroTablet     = Color3.fromRGB(38, 38, 40),
	maderaMesa      = Color3.fromRGB(190, 125, 55),
	tablero         = Color3.fromRGB(242, 242, 242),
	aluminio        = Color3.fromRGB(110, 115, 120),
	posterAmarillo  = Color3.fromRGB(235, 200, 40),
	posterBlanco    = Color3.fromRGB(236, 236, 236),
	posterCeleste   = Color3.fromRGB(195, 220, 230),
	posterRojo      = Color3.fromRGB(215, 50, 60),
	posterOcre      = Color3.fromRGB(240, 180, 50),
	posterVerde     = Color3.fromRGB(40, 160, 110),
	azulMarino      = Color3.fromRGB(25, 45, 110),
}

-------------------------------------------------------------------------------
-- ETAPA 1 · Utilidades de construcción y sistema de coordenadas
-------------------------------------------------------------------------------
local contadorParts = 0
local advertencias  = {}

local function advertir(msg)
	table.insert(advertencias, msg)
end

-- metros -> studs
local function mt(x) return x * ESCALA end
-- punto en metros (coordenadas del edificio) -> Vector3 en studs (mundo)
local function P(x, y, z) return Vector3.new(x * ESCALA, y * ESCALA, z * ESCALA) + ORIGEN end
-- tamaño en metros -> studs
local function S(w, h, d) return Vector3.new(w * ESCALA, h * ESCALA, d * ESCALA) end

-- Crea una Part con propiedades comunes. size y cf ya en studs.
local function nuevaPart(nombre, size, cf, props, parent)
	props = props or {}
	local p = Instance.new("Part")
	p.Name = nombre
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if props.Shape then p.Shape = props.Shape end
	p.Size = size
	p.CFrame = cf
	p.Material = props.Material or Enum.Material.SmoothPlastic
	p.Color = props.Color or Color3.fromRGB(200, 200, 200)
	if props.Transparency then p.Transparency = props.Transparency end
	if props.Reflectance then p.Reflectance = props.Reflectance end
	if props.CanCollide ~= nil then p.CanCollide = props.CanCollide end
	if props.CastShadow ~= nil then p.CastShadow = props.CastShadow end
	p.Parent = parent
	contadorParts = contadorParts + 1
	return p
end

-- Caja alineada a los ejes definida por sus límites en METROS.
local function caja(nombre, x0, x1, y0, y1, z0, z1, props, parent)
	if x0 > x1 then x0, x1 = x1, x0 end
	if y0 > y1 then y0, y1 = y1, y0 end
	if z0 > z1 then z0, z1 = z1, z0 end
	local size = S(x1 - x0, y1 - y0, z1 - z0)
	local cf = CFrame.new(P((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2))
	return nuevaPart(nombre, size, cf, props, parent)
end

-- Cilindro entre dos puntos (metros) con diámetro (metros). El eje X de la Part sigue la dirección.
local function cilindro(nombre, a, b, diametro, props, parent)
	props = props or {}
	props.Shape = Enum.PartType.Cylinder
	local pa, pb = P(a.X, a.Y, a.Z), P(b.X, b.Y, b.Z)
	local dirv = pb - pa
	local largo = dirv.Magnitude
	local mid = (pa + pb) / 2
	local cf
	if math.abs(dirv.Unit.Y) > 0.999 then
		cf = CFrame.new(mid) * CFrame.Angles(0, 0, math.rad(90))           -- vertical
	else
		cf = CFrame.lookAt(mid, mid + dirv) * CFrame.Angles(0, math.rad(90), 0) -- eje X alineado con la dirección
	end
	return nuevaPart(nombre, Vector3.new(largo, mt(diametro), mt(diametro)), cf, props, parent)
end

-- Placa cuyo lado FRONT (Enum.NormalId.Front) mira hacia 'normal'. centro en metros, ancho/alto/espesor en metros.
local function placa(nombre, centro, ancho, alto, espesor, normal, props, parent)
	local pos = P(centro.X, centro.Y, centro.Z)
	local cf = CFrame.lookAt(pos, pos + normal)
	return nuevaPart(nombre, S(ancho, alto, espesor), cf, props, parent)
end

-- Texto sobre la cara Front de una Part (0 Parts: SurfaceGui + TextLabel).
local function texto(part, txt, color, opts)
	opts = opts or {}
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Etiqueta"
	gui.Face = opts.Face or Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 100
	gui.LightInfluence = 1
	gui.AlwaysOnTop = false
	local lbl = Instance.new("TextLabel")
	lbl.Name = "Texto"
	lbl.BackgroundTransparency = 1
	lbl.BorderSizePixel = 0
	lbl.Size = opts.Size or UDim2.new(1, 0, 1, 0)
	lbl.Position = opts.Position or UDim2.new(0, 0, 0, 0)
	lbl.Text = txt
	lbl.TextColor3 = color
	lbl.TextScaled = true
	lbl.Font = opts.Font or Enum.Font.GothamBold
	lbl.RichText = opts.RichText == true
	lbl.TextXAlignment = opts.XAlign or Enum.TextXAlignment.Center
	if opts.Stroke then
		lbl.TextStrokeTransparency = 0
		lbl.TextStrokeColor3 = opts.Stroke
	end
	lbl.Parent = gui
	gui.Parent = part
	return gui
end

local function nuevoModelo(nombre, parent)
	local m = Instance.new("Model")
	m.Name = nombre
	m.Parent = parent
	return m
end

-- Descompone un rectángulo de muro (plano XY, en metros) menos una lista de huecos {x0,x1,y0,y1}
-- en el menor número razonable de rectángulos sólidos (bandas horizontales + fusión vertical).
local function piezasDeMuro(x0, x1, y0, y1, huecos)
	local ys = { y0, y1 }
	for _, h in ipairs(huecos) do
		if h.y0 > y0 and h.y0 < y1 then table.insert(ys, h.y0) end
		if h.y1 > y0 and h.y1 < y1 then table.insert(ys, h.y1) end
	end
	table.sort(ys)
	local niveles = {}
	for _, y in ipairs(ys) do
		if #niveles == 0 or y - niveles[#niveles] > 1e-6 then table.insert(niveles, y) end
	end
	local piezas = {}
	for i = 1, #niveles - 1 do
		local by0, by1 = niveles[i], niveles[i + 1]
		local mid = (by0 + by1) / 2
		local bloqueos = {}
		for _, h in ipairs(huecos) do
			if h.y0 <= mid and h.y1 >= mid then
				table.insert(bloqueos, { math.max(h.x0, x0), math.min(h.x1, x1) })
			end
		end
		table.sort(bloqueos, function(a, b) return a[1] < b[1] end)
		local cursor = x0
		for _, b in ipairs(bloqueos) do
			if b[1] > cursor + 1e-6 then
				table.insert(piezas, { x0 = cursor, x1 = b[1], y0 = by0, y1 = by1 })
			end
			if b[2] > cursor then cursor = b[2] end
		end
		if x1 > cursor + 1e-6 then
			table.insert(piezas, { x0 = cursor, x1 = x1, y0 = by0, y1 = by1 })
		end
	end
	-- fusión de piezas verticalmente adyacentes con el mismo rango X
	local fusionado = true
	while fusionado do
		fusionado = false
		for i = 1, #piezas do
			for j = 1, #piezas do
				if i ~= j then
					local a, b = piezas[i], piezas[j]
					if math.abs(a.x0 - b.x0) < 1e-6 and math.abs(a.x1 - b.x1) < 1e-6 and math.abs(a.y1 - b.y0) < 1e-6 then
						a.y1 = b.y1
						table.remove(piezas, j)
						fusionado = true
						break
					end
				end
			end
			if fusionado then break end
		end
	end
	return piezas
end

-- Muro paralelo a la fachada (plano XY) con huecos, entre z0 y z1.
local function muroConHuecos(nombre, x0, x1, y0, y1, z0, z1, huecos, props, parent)
	local piezas = piezasDeMuro(x0, x1, y0, y1, huecos)
	for i, pz in ipairs(piezas) do
		caja(nombre .. "_" .. i, pz.x0, pz.x1, pz.y0, pz.y1, z0, z1, props, parent)
	end
	return #piezas
end

-------------------------------------------------------------------------------
-- Definición de los dos salones (coordenadas LOCALES de salón, en metros):
--   x local = 0 en la cara exterior del muro de fondo del salón (el extremo opuesto a la medianera)
--   x local crece hacia la medianera, donde está la puerta.  Interior: [T, T+L]
--   Para 7B la transformación tx() refleja x respecto al centro del edificio, de modo que
--   su puerta queda junto a la medianera, al lado de la de 6B (como en la foto de la fachada).
-------------------------------------------------------------------------------
local SALONES = {
	{
		nombre = "Salon_1_6B", etiqueta = "6B", dir = 1,
		tx = function(x) return x end,
		anchoPuerta = 0.90,      -- la hoja verde se ve algo más estrecha (0.80 m) que la metálica
		desfaseVentana = 0,      -- ventana y calado exactamente donde los muestra la foto
	},
	{
		nombre = "Salon_2_7B", etiqueta = "7B", dir = -1,
		tx = function(x) return ANCHO_TOTAL - x end,
		anchoPuerta = 0.96,      -- hoja metálica de 0.86 m
		desfaseVentana = -0.36,  -- no visible en la foto: la ventana se aleja 0.36 m más de la puerta
		                         -- (la foto muestra ~0.7 m de muro liso a la derecha de la puerta 7B)
	},
}

-- helpers en coordenadas locales de salón
local function rcaja(sal, nombre, x0, x1, y0, y1, z0, z1, props, parent)
	return caja(nombre, sal.tx(x0), sal.tx(x1), y0, y1, z0, z1, props, parent)
end
local function rpunto(sal, x, y, z) return Vector3.new(sal.tx(x), y, z) end
local function rnormal(sal, dx, dz) return Vector3.new(dx * sal.dir, 0, dz) end

-- Posiciones locales (metros) comunes a ambos salones
local X_INT0, X_INT1 = T, T + L               -- 0.15 .. 7.65 interior
local Z_INT0, Z_INT1 = -T - D, -T             -- -6.65+0.15 = -6.50 .. -0.15 interior
local PUERTA_X1 = X_INT1 - 0.14      -- 7.51: borde del hueco de puerta junto a la columna de la medianera
local PUERTA_H = 2.15
local MARCO = 0.05

-------------------------------------------------------------------------------
-- CONSTRUCTORES DE MOBILIARIO (coordenadas locales del objeto: adelante = -Z, derecha = +X)
-------------------------------------------------------------------------------
-- Silla universitaria con paleta (brazo de escritura a la DERECHA del estudiante) y rejilla portalibros.
-- pos: punto en metros sobre el piso bajo el centro del asiento. mirar: Vector3 horizontal (hacia dónde mira el estudiante)
local function sillaUniversitaria(parent, pos, mirar, opciones)
	opciones = opciones or {}
	local conPaleta = opciones.paleta ~= false
	local colorAsiento = opciones.color or C.azulSilla
	local colorMarco = C.negroMetal
	local base = CFrame.lookAt(P(pos.X, pos.Y, pos.Z), P(pos.X, pos.Y, pos.Z) + mirar)
	local m = nuevoModelo(opciones.nombre or "Silla_Universitaria", parent)
	local function pieza(nombre, w, h, d, lx, ly, lz, props, rot)
		local cf = base * CFrame.new(mt(lx), mt(ly), mt(lz))
		if rot then cf = cf * rot end
		return nuevaPart(nombre, S(w, h, d), cf, props, m)
	end
	local metal = { Material = Enum.Material.Metal, Color = colorMarco }
	local metalFino = { Material = Enum.Material.Metal, Color = colorMarco, CanCollide = false, CastShadow = false }
	-- asiento y espaldar (acolchados)
	pieza("Asiento", 0.46, 0.06, 0.44, 0, 0.44, 0, { Material = Enum.Material.Fabric, Color = colorAsiento })
	pieza("Espaldar", 0.46, 0.38, 0.04, 0, 0.76, 0.21, { Material = Enum.Material.Fabric, Color = colorAsiento }, CFrame.Angles(math.rad(10), 0, 0))
	-- patas traseras (suben hasta el espaldar) y delanteras
	pieza("Pata_TrasIzq", 0.03, 0.95, 0.03, -0.20, 0.475, 0.20, metal)
	pieza("Pata_TrasDer", 0.03, 0.95, 0.03, 0.20, 0.475, 0.20, metal)
	pieza("Pata_DelIzq", 0.03, 0.42, 0.03, -0.20, 0.21, -0.19, metal)
	pieza("Pata_DelDer", 0.03, 0.42, 0.03, 0.20, 0.21, -0.19, metal)
	-- travesaño delantero bajo el asiento
	pieza("Travesano", 0.43, 0.025, 0.025, 0, 0.40, -0.19, metalFino)
	-- rejilla portalibros (lámina semitransparente + borde frontal)
	pieza("Rejilla", 0.40, 0.015, 0.34, 0, 0.27, 0.0, { Material = Enum.Material.Metal, Color = C.negroMetal, Transparency = 0.3, CanCollide = false, CastShadow = false })
	pieza("Rejilla_Borde", 0.40, 0.06, 0.015, 0, 0.30, -0.17, metalFino)
	if conPaleta then
		-- paleta de escritura a la derecha + soporte inclinado desde la pata delantera derecha
		pieza("Paleta", 0.30, 0.02, 0.56, 0.37, 0.70, -0.06, { Material = Enum.Material.SmoothPlastic, Color = C.negroTablet })
		pieza("Soporte_Paleta", 0.03, 0.32, 0.03, 0.285, 0.555, -0.19, metalFino, CFrame.Angles(0, 0, math.rad(-32)))
	end
	return m
end

-- Escritorio del profesor: tablero de madera y estructura tubular negra (dos montantes, pies en T y travesaño).
-- centro: punto en metros sobre el piso bajo el centro del tablero. El lado largo queda a lo largo del eje X.
local function escritorioProfesor(parent, centro)
	local m = nuevoModelo("Escritorio_Profesor", parent)
	local cx, cz = centro.X, centro.Z
	local madera = { Material = Enum.Material.Wood, Color = C.maderaMesa }
	local metal = { Material = Enum.Material.Metal, Color = C.negroMetal }
	caja("Tablero", cx - 0.75, cx + 0.75, 0.72, 0.76, cz - 0.375, cz + 0.375, madera, m)
	for _, sx in ipairs({ -0.58, 0.58 }) do
		cilindro("Montante", Vector3.new(cx + sx, 0.04, cz), Vector3.new(cx + sx, 0.72, cz), 0.05, metal, m)
		cilindro("Pie", Vector3.new(cx + sx, 0.025, cz - 0.32), Vector3.new(cx + sx, 0.025, cz + 0.32), 0.05, metal, m)
	end
	cilindro("Travesano", Vector3.new(cx - 0.58, 0.34, cz), Vector3.new(cx + 0.58, 0.34, cz), 0.04, metal, m)
	return m
end

-- Lámpara fluorescente colgante: carcasa blanca + panel luminoso + dos varillas hasta la cota yTecho.
local function lamparaFluorescente(parent, cx, cz, yTecho)
	local m = nuevoModelo("Lampara_Fluorescente", parent)
	local yTop = 2.58
	caja("Carcasa", cx - 0.60, cx + 0.60, yTop - 0.08, yTop, cz - 0.15, cz + 0.15, { Material = Enum.Material.SmoothPlastic, Color = C.blanco, CanCollide = false }, m)
	caja("Tubo_Luz", cx - 0.58, cx + 0.58, yTop - 0.10, yTop - 0.08, cz - 0.13, cz + 0.13, { Material = Enum.Material.Neon, Color = C.neon, CanCollide = false, CastShadow = false }, m)
	for _, sx in ipairs({ -0.40, 0.40 }) do -- separadas de las vigas transversales
		caja("Varilla", cx + sx - 0.01, cx + sx + 0.01, yTop, yTecho, cz - 0.01, cz + 0.01, { Material = Enum.Material.Metal, Color = C.metalClaro, CanCollide = false, CastShadow = false }, m)
	end
	return m
end

-- Ventilador de jaula (tipo pedestal) colgado de la losa con un soporte, inclinado ~25° hacia abajo.
-- mirar: dirección horizontal hacia la que sopla.
local function ventiladorJaula(parent, cx, cz, yLosa, mirar)
	local m = nuevoModelo("Ventilador_Jaula", parent)
	local gris = { Material = Enum.Material.Metal, Color = C.metalClaro, CanCollide = false, CastShadow = false }
	cilindro("Soporte", Vector3.new(cx, 2.35, cz), Vector3.new(cx, yLosa, cz), 0.03, gris, m)
	local centro = P(cx, 2.22, cz)
	-- eje del ventilador: horizontal hacia 'mirar', inclinado 25° hacia abajo
	local base = CFrame.lookAt(centro, centro + mirar) * CFrame.Angles(math.rad(-25), 0, 0)
	-- motor (cilindro con eje a lo largo de la mirada = -Z local -> rotar el eje X del cilindro)
	nuevaPart("Motor", Vector3.new(mt(0.18), mt(0.16), mt(0.16)), base * CFrame.new(0, 0, mt(0.12)) * CFrame.Angles(0, math.rad(90), 0),
		{ Shape = Enum.PartType.Cylinder, Material = Enum.Material.SmoothPlastic, Color = C.blanco, CanCollide = false, CastShadow = false }, m)
	-- jaula: disco semitransparente
	nuevaPart("Jaula", Vector3.new(mt(0.08), mt(0.46), mt(0.46)), base * CFrame.Angles(0, math.rad(90), 0),
		{ Shape = Enum.PartType.Cylinder, Material = Enum.Material.Metal, Color = C.metalClaro, Transparency = 0.55, CanCollide = false, CastShadow = false }, m)
	-- cubo central de las aspas
	nuevaPart("Cubo", Vector3.new(mt(0.05), mt(0.12), mt(0.12)), base * CFrame.new(0, 0, mt(0.01)) * CFrame.Angles(0, math.rad(90), 0),
		{ Shape = Enum.PartType.Cylinder, Material = Enum.Material.SmoothPlastic, Color = C.blanco, CanCollide = false, CastShadow = false }, m)
	return m
end

-------------------------------------------------------------------------------
-- CONSTRUCCIÓN PRINCIPAL (todo dentro de una función para poder deshacer en caso de error)
-------------------------------------------------------------------------------
local raiz -- modelo principal

local function construir()
	raiz = Instance.new("Model")
	raiz.Name = NOMBRE_MODELO
	raiz:SetAttribute(ATRIBUTO_MARCA, true)

	local mEstructura = nuevoModelo("Estructura", raiz)
	local mCorredor   = nuevoModelo("Corredor", raiz)

	---------------------------------------------------------------------------
	-- ETAPA 2 · Suelo y base estructural
	---------------------------------------------------------------------------
	-- Piso interior continuo bajo los dos salones (terracota lisa, como en el render interior)
	caja("Piso_Interior", 0, ANCHO_TOTAL, -0.30, 0, -T - D - T, 0, { Material = Enum.Material.SmoothPlastic, Color = C.pisoInterior }, mEstructura)
	-- Corredor: franja de cemento gris junto al muro + piso de baldosa terracota
	caja("Piso_Corredor_Franja", 0, ANCHO_TOTAL, -0.30, 0, 0, 0.20, { Material = Enum.Material.Concrete, Color = C.cementoGris }, mCorredor)
	caja("Piso_Corredor_Baldosa", 0, ANCHO_TOTAL, -0.30, 0, 0.20, CORREDOR, { Material = Enum.Material.CeramicTiles, Color = C.baldosaCorredor }, mCorredor)

	---------------------------------------------------------------------------
	-- ETAPA 3 · Muros exteriores (muros ciegos compartidos; la fachada se hace por salón en la etapa 4)
	---------------------------------------------------------------------------
	local gris = { Material = Enum.Material.Concrete, Color = C.grisInterior }
	local blanco = { Material = Enum.Material.Concrete, Color = C.blancoFachada }
	-- Cada muro ciego = capa interior gris (0.10 m) + piel exterior blanca (0.05 m). Las pieles blancas
	-- forman un anillo continuo y las capas grises quedan dentro, sin caras coplanares de distinto color.
	local PIEL = 0.05
	-- Muro de fondo (opuesto a la fachada)
	caja("Muro_Fondo_Interior", PIEL, ANCHO_TOTAL - PIEL, 0, H, Z_INT0 - 0.10, Z_INT0, gris, mEstructura)
	caja("Muro_Fondo_Exterior", 0, ANCHO_TOTAL, 0, H, Z_INT0 - T, Z_INT0 - 0.10, blanco, mEstructura)
	-- Muro extremo izquierdo (6B) y derecho (7B)
	caja("Muro_Izquierdo_Interior", PIEL, T, 0, H, Z_INT0 - 0.10, -PIEL, gris, mEstructura)
	caja("Muro_Izquierdo_Exterior", 0, PIEL, 0, H, Z_INT0 - 0.10, -PIEL, blanco, mEstructura)
	caja("Muro_Derecho_Interior", ANCHO_TOTAL - T, ANCHO_TOTAL - PIEL, 0, H, Z_INT0 - 0.10, -PIEL, gris, mEstructura)
	caja("Muro_Derecho_Exterior", ANCHO_TOTAL - PIEL, ANCHO_TOTAL, 0, H, Z_INT0 - 0.10, -PIEL, blanco, mEstructura)
	-- Muro medianero entre 6B y 7B (gris por ambas caras); su extremo en la fachada queda cubierto por la columna
	caja("Muro_Medianero", T + L, T + L + T, 0, H, Z_INT0 - 0.10, 0, gris, mEstructura)

	---------------------------------------------------------------------------
	-- ETAPA 5 (parte compartida) · Cubierta, columna y detalles exteriores
	---------------------------------------------------------------------------
	-- Losa de cubierta sobre salones y corredor (su cara inferior es el cielo raso de concreto)
	caja("Losa_Cubierta", 0, ANCHO_TOTAL, H, H + LOSA, Z_INT0 - T, CORREDOR, { Material = Enum.Material.Concrete, Color = C.grisLosa }, mEstructura)
	-- Columna entre las dos puertas (sobresale 10 cm hacia el corredor), alineada con la medianera
	local xMed = T + L + T / 2
	caja("Columna_Entre_Puertas", xMed - 0.14, xMed + 0.14, 0, H, 0, 0.10, blanco, mCorredor)
	-- Canaleta eléctrica a lo largo de la fachada bajo la losa (se interrumpe en la columna); en tres tramos
	-- para no atravesar la viga del corredor (x 5.78..5.98) ni la caja eléctrica de la ventana (x 6.11..6.21)
	local canProps = { Material = Enum.Material.Metal, Color = C.conducto, CanCollide = false, CastShadow = false }
	cilindro("Canaleta_Electrica", Vector3.new(0.05, 2.85, 0.03), Vector3.new(5.77, 2.85, 0.03), 0.03, canProps, mCorredor)
	cilindro("Canaleta_Electrica", Vector3.new(5.99, 2.85, 0.03), Vector3.new(6.10, 2.85, 0.03), 0.03, canProps, mCorredor)
	cilindro("Canaleta_Electrica", Vector3.new(6.22, 2.85, 0.03), Vector3.new(xMed - 0.15, 2.85, 0.03), 0.03, canProps, mCorredor)

	---------------------------------------------------------------------------
	-- ETAPAS 4 a 7 por salón
	---------------------------------------------------------------------------
	for _, sal in ipairs(SALONES) do
		local mSalon = nuevoModelo(sal.nombre, raiz)
		local mFachada = nuevoModelo("Fachada", mSalon)
		local mPuerta = nuevoModelo("Puerta_" .. sal.etiqueta, mFachada)
		local mVentana = nuevoModelo("Ventana", mFachada)
		local mCalado = nuevoModelo("Calado", mFachada)
		local mTecho = nuevoModelo("Techo", mSalon)
		local mMuros = nuevoModelo("Acabados_Interiores", mSalon)
		local mMob = nuevoModelo("Mobiliario", mSalon)

		local dv = sal.desfaseVentana
		local PUERTA_X0 = PUERTA_X1 - sal.anchoPuerta
		local HOJA_X0, HOJA_X1 = PUERTA_X0 + MARCO, PUERTA_X1 - MARCO
		-- Huecos de la fachada en coordenadas locales (metros)
		local VENT_X0, VENT_X1 = 4.97 + dv, 6.11 + dv      -- marco exterior de la ventana 1.14 x 1.20
		local VENT_Y0, VENT_Y1 = 1.65, 2.85
		local CAL_X0, CAL_X1 = 4.51 + dv, 5.76 + dv        -- panel de calado 1.25 x 1.05 (5 x 4 bloques)
		local CAL_Y0, CAL_Y1 = 0.45, 1.50
		local huecos = {
			{ x0 = sal.tx(PUERTA_X0), x1 = sal.tx(PUERTA_X1), y0 = 0, y1 = PUERTA_H },
			{ x0 = sal.tx(VENT_X0), x1 = sal.tx(VENT_X1), y0 = VENT_Y0, y1 = VENT_Y1 },
			{ x0 = sal.tx(CAL_X0), x1 = sal.tx(CAL_X1), y0 = CAL_Y0, y1 = CAL_Y1 },
		}
		for _, h in ipairs(huecos) do
			if h.x0 > h.x1 then h.x0, h.x1 = h.x1, h.x0 end
		end

		-----------------------------------------------------------------------
		-- ETAPA 4 · Fachada con aberturas (capa exterior blanca + capa interior gris)
		-----------------------------------------------------------------------
		-- piel exterior blanca: cubre también el canto del muro extremo (desde la esquina exterior hasta la medianera)
		local ex0, ex1 = sal.tx(0), sal.tx(X_INT1)
		if ex0 > ex1 then ex0, ex1 = ex1, ex0 end
		muroConHuecos("Fachada_Exterior", ex0, ex1, 0, H, -0.05, 0, huecos, blanco, mFachada)
		-- capa interior gris: sólo entre las caras interiores de los muros extremos
		local fx0, fx1 = sal.tx(X_INT0), sal.tx(X_INT1)
		if fx0 > fx1 then fx0, fx1 = fx1, fx0 end
		muroConHuecos("Fachada_Interior", fx0, fx1, 0, H, -T, -0.05, huecos, gris, mFachada)

		-- Marco de puerta (jambas + dintel, blanco, todo el espesor del muro)
		local marcoProps = { Material = Enum.Material.SmoothPlastic, Color = C.blancoMarco }
		rcaja(sal, "Marco_Jamba_A", PUERTA_X0, PUERTA_X0 + MARCO, 0, PUERTA_H, -T, 0, marcoProps, mPuerta)
		rcaja(sal, "Marco_Jamba_B", PUERTA_X1 - MARCO, PUERTA_X1, 0, PUERTA_H, -T, 0, marcoProps, mPuerta)
		rcaja(sal, "Marco_Dintel", HOJA_X0, HOJA_X1, PUERTA_H - MARCO, PUERTA_H, -T, 0, marcoProps, mPuerta)

		local hojaCX = sal.tx((HOJA_X0 + HOJA_X1) / 2)
		local hojaAncho = HOJA_X1 - HOJA_X0  -- 0.80 (6B) / 0.86 (7B)
		local normalExterior = Vector3.new(0, 0, 1)

		if sal.etiqueta == "6B" then
			-- Hoja verde lisa (hueco 0.90 m: hoja 0.80 x 2.09)
			local hoja = placa("Hoja_Puerta_6B", Vector3.new(hojaCX, 0.01 + 2.09 / 2, -0.04), hojaAncho, 2.09, 0.04, normalExterior,
				{ Material = Enum.Material.SmoothPlastic, Color = C.verdePuerta }, mPuerta)
			-- Rótulo "6B": "6" casi negro y "B" verde azulado, centrado; texto pequeño azul marino debajo
			texto(hoja, '<font color="#141E14">6</font><font color="#286E5F">B</font>', Color3.fromRGB(20, 30, 20),
				{ RichText = true, Font = Enum.Font.FredokaOne, Size = UDim2.new(1, 0, 0.16, 0), Position = UDim2.new(0, 0, 0.30, 0) })
			texto(hoja, "MISS LICETH", C.azulMarino,
				{ Font = Enum.Font.GothamBold, Size = UDim2.new(0.5, 0, 0.032, 0), Position = UDim2.new(0.22, 0, 0.472, 0) })
			-- Cuatro lápices colgando del borde superior, punta hacia abajo (naranja, verde azulado, naranja, verde azulado)
			local coloresLapiz = { C.naranja, C.verdeAzulado, C.naranja, C.verdeAzulado }
			local offsets = { 0.13, 0.28, 0.43, 0.59 }
			local yTope = 0.01 + 2.09
			for i = 1, 4 do
				local lx = sal.tx(HOJA_X0 + offsets[i])
				local deco = { Material = Enum.Material.SmoothPlastic, Color = coloresLapiz[i], CanCollide = false, CastShadow = false }
				caja("Lapiz_Cuerpo", lx - 0.045, lx + 0.045, yTope - 0.23, yTope, -0.02, -0.012, deco, mPuerta)
				caja("Lapiz_Punta", lx - 0.03, lx + 0.03, yTope - 0.30, yTope - 0.23, -0.02, -0.013, { Material = Enum.Material.SmoothPlastic, Color = C.crema, CanCollide = false, CastShadow = false }, mPuerta)
				caja("Lapiz_Grafito", lx - 0.012, lx + 0.012, yTope - 0.33, yTope - 0.30, -0.02, -0.014, { Material = Enum.Material.SmoothPlastic, Color = C.grafito, CanCollide = false, CastShadow = false }, mPuerta)
			end
			-- Cerradura/pomo pequeño en el borde izquierdo de la hoja (visto desde el corredor)
			local xCerr = sal.tx(HOJA_X0 + 0.07)
			cilindro("Pomo", Vector3.new(xCerr, 1.05, -0.02), Vector3.new(xCerr, 1.05, 0.02), 0.05, { Material = Enum.Material.Metal, Color = C.metalClaro, CanCollide = false }, mPuerta)
			-- Pegatina naranja pequeña abajo a la derecha de la "B"
			local xSt = sal.tx(HOJA_X1 - 0.12)
			caja("Pegatina_Naranja", xSt - 0.025, xSt + 0.025, 0.925, 0.975, -0.02, -0.015, { Material = Enum.Material.SmoothPlastic, Color = C.naranja, CanCollide = false, CastShadow = false }, mPuerta)
		else
			-- Puerta 7B: lámina metálica blanca con 3 x 7 paneles cuadrados estampados, sobre un pequeño umbral de cemento
			rcaja(sal, "Umbral_Cemento", HOJA_X0, HOJA_X1, 0, 0.05, -T, 0.12, { Material = Enum.Material.Concrete, Color = C.cementoGris }, mPuerta)
			local hoja = placa("Hoja_Puerta_7B", Vector3.new(hojaCX, 0.06 + 2.04 / 2, -0.05), hojaAncho, 2.04, 0.04, normalExterior,
				{ Material = Enum.Material.Metal, Color = C.puertaMetal }, mPuerta)
			local panelProps = { Material = Enum.Material.Metal, Color = C.puertaMetal, CanCollide = false, CastShadow = false }
			local filas = { 0.22, 0.49, 0.76, 1.03, 1.30, 1.57, 1.84 }
			local cols = { HOJA_X0 + hojaAncho * (0.5 / 3), HOJA_X0 + hojaAncho * (1.5 / 3), HOJA_X0 + hojaAncho * (2.5 / 3) }
			for _, fy in ipairs(filas) do
				for _, cxl in ipairs(cols) do
					local cx = sal.tx(cxl)
					caja("Panel_Ext", cx - 0.095, cx + 0.095, fy - 0.095, fy + 0.095, -0.03, -0.02, panelProps, mPuerta)
					caja("Panel_Int", cx - 0.045, cx + 0.045, fy - 0.045, fy + 0.045, -0.02, -0.012, panelProps, mPuerta)
				end
			end
			-- Rótulo "7B": lápiz morado horizontal con letras amarillo pálido y punta crema hacia la derecha
			local rot = placa("Rotulo_7B", Vector3.new(hojaCX - 0.03, 1.42, -0.014), 0.26, 0.13, 0.012, normalExterior,
				{ Material = Enum.Material.SmoothPlastic, Color = C.moradoLapiz, CanCollide = false, CastShadow = false }, mPuerta)
			texto(rot, "7B", C.amarilloPalido, { Font = Enum.Font.FredokaOne, Size = UDim2.new(0.8, 0, 0.9, 0), Position = UDim2.new(0.1, 0, 0.05, 0) })
			local xTip = hojaCX + 0.10
			caja("Rotulo_Punta", xTip, xTip + 0.07, 1.385, 1.455, -0.020, -0.012, { Material = Enum.Material.SmoothPlastic, Color = C.crema, CanCollide = false, CastShadow = false }, mPuerta)
			caja("Rotulo_Grafito", xTip + 0.07, xTip + 0.10, 1.405, 1.435, -0.020, -0.013, { Material = Enum.Material.SmoothPlastic, Color = C.grafito, CanCollide = false, CastShadow = false }, mPuerta)
			-- Manija corta y chapa en el borde DERECHO de la hoja visto desde el corredor: en coordenadas locales de 7B
			-- (reflejadas) ese borde es HOJA_X0, el lado alejado de la medianera
			local xMan = sal.tx(HOJA_X0 + 0.08)
			caja("Manija", xMan - 0.045, xMan + 0.045, 1.09, 1.115, -0.03, 0.015, { Material = Enum.Material.Metal, Color = C.metalClaro, CanCollide = false }, mPuerta)
			caja("Chapa", xMan - 0.03, xMan + 0.03, 1.00, 1.06, -0.03, -0.008, { Material = Enum.Material.Metal, Color = C.metalClaro, CanCollide = false, CastShadow = false }, mPuerta)
			-- Señal "Ruta de evacuación" sobre el tercio derecho de la puerta 7B, flecha hacia la izquierda
			-- (los bordes del hueco se pasan a MUNDO antes de aplicar los desfases: en 7B lo local está reflejado)
			local dx0, dx1 = sal.tx(PUERTA_X0), sal.tx(PUERTA_X1)
			if dx0 > dx1 then dx0, dx1 = dx1, dx0 end
			local xS0, xS1 = dx0 + 0.68, dx1 + 0.07
			local senal = placa("Senal_Evacuacion", Vector3.new((xS0 + xS1) / 2, 2.40, 0.006), xS1 - xS0, 0.14, 0.012, normalExterior,
				{ Material = Enum.Material.SmoothPlastic, Color = C.verdeSenal, CanCollide = false, CastShadow = false }, mFachada)
			texto(senal, "←", Color3.fromRGB(255, 255, 255), { Font = Enum.Font.GothamBold, Size = UDim2.new(0.32, 0, 0.9, 0), Position = UDim2.new(0.02, 0, 0.05, 0) })
			texto(senal, "RUTA DE\nEVACUACIÓN", Color3.fromRGB(255, 255, 255), { Font = Enum.Font.GothamBold, Size = UDim2.new(0.62, 0, 0.8, 0), Position = UDim2.new(0.36, 0, 0.1, 0) })
		end

		-- Ventana con marco exterior de madera rojo oscuro, marco interior de madera clara y panel de vidrio opaco
		-- (en la foto no se ve nada a través de él; Glass opaco evita el fallo de render de Glass semitransparente)
		do
			local rojo = { Material = Enum.Material.Wood, Color = C.marcoRojo }
			local clara = { Material = Enum.Material.Wood, Color = C.maderaClara }
			local MO = 0.07 -- marco exterior
			local MI = 0.05 -- marco interior
			rcaja(sal, "Marco_Ext_Izq", VENT_X0, VENT_X0 + MO, VENT_Y0, VENT_Y1, -T, 0, rojo, mVentana)
			rcaja(sal, "Marco_Ext_Der", VENT_X1 - MO, VENT_X1, VENT_Y0, VENT_Y1, -T, 0, rojo, mVentana)
			rcaja(sal, "Marco_Ext_Inf", VENT_X0 + MO, VENT_X1 - MO, VENT_Y0, VENT_Y0 + MO, -T, 0, rojo, mVentana)
			rcaja(sal, "Marco_Ext_Sup", VENT_X0 + MO, VENT_X1 - MO, VENT_Y1 - MO, VENT_Y1, -T, 0, rojo, mVentana)
			local ix0, ix1, iy0, iy1 = VENT_X0 + MO, VENT_X1 - MO, VENT_Y0 + MO, VENT_Y1 - MO
			rcaja(sal, "Marco_Int_Izq", ix0, ix0 + MI, iy0, iy1, -0.12, -0.03, clara, mVentana)
			rcaja(sal, "Marco_Int_Der", ix1 - MI, ix1, iy0, iy1, -0.12, -0.03, clara, mVentana)
			rcaja(sal, "Marco_Int_Inf", ix0 + MI, ix1 - MI, iy0, iy0 + MI, -0.12, -0.03, clara, mVentana)
			rcaja(sal, "Marco_Int_Sup", ix0 + MI, ix1 - MI, iy1 - MI, iy1, -0.12, -0.03, clara, mVentana)
			rcaja(sal, "Vidrio", ix0 + MI, ix1 - MI, iy0 + MI, iy1 - MI, -0.08, -0.07,
				{ Material = Enum.Material.Glass, Color = C.vidrio, Transparency = 0, Reflectance = 0.08 }, mVentana)
		end

		-- Calado (bloques decorativos de ventilación): rejilla de 5 x 4 bloques; cada bloque con cruz central = 4 aberturas
		do
			local props = { Material = Enum.Material.Concrete, Color = C.calado }
			local nCols, nFilas = 5, 4
			local pasoX = (CAL_X1 - CAL_X0) / nCols
			local pasoY = (CAL_Y1 - CAL_Y0) / nFilas
			local grueso, fino = 0.035, 0.022
			-- barras gruesas de la retícula; las de borde quedan completamente dentro del hueco
			for i = 0, nCols do
				local x = CAL_X0 + i * pasoX
				local bx0, bx1 = x - grueso / 2, x + grueso / 2
				if i == 0 then bx0, bx1 = CAL_X0, CAL_X0 + grueso end
				if i == nCols then bx0, bx1 = CAL_X1 - grueso, CAL_X1 end
				rcaja(sal, "Calado_Barra_V", bx0, bx1, CAL_Y0, CAL_Y1, -0.135, -0.015, props, mCalado)
			end
			for j = 0, nFilas do
				local y = CAL_Y0 + j * pasoY
				local by0, by1 = y - grueso / 2, y + grueso / 2
				if j == 0 then by0, by1 = CAL_Y0, CAL_Y0 + grueso end
				if j == nFilas then by0, by1 = CAL_Y1 - grueso, CAL_Y1 end
				rcaja(sal, "Calado_Barra_H", CAL_X0 + grueso, CAL_X1 - grueso, by0, by1, -0.135, -0.015, props, mCalado)
			end
			for i = 0, nCols - 1 do
				local x = CAL_X0 + (i + 0.5) * pasoX
				rcaja(sal, "Calado_Cruz_V", x - fino / 2, x + fino / 2, CAL_Y0, CAL_Y1, -0.10, -0.05, props, mCalado)
			end
			for j = 0, nFilas - 1 do
				local y = CAL_Y0 + (j + 0.5) * pasoY
				rcaja(sal, "Calado_Cruz_H", CAL_X0, CAL_X1, y - fino / 2, y + fino / 2, -0.10, -0.05, props, mCalado)
			end
		end

		-- Detalle eléctrico exterior junto a la esquina superior de la ventana (cajita blanca con tubo corto) y viga del corredor
		do
			local xCaja = sal.tx(VENT_X1 + 0.05)
			caja("Caja_Electrica", xCaja - 0.05, xCaja + 0.05, 2.63, 2.88, 0, 0.06, { Material = Enum.Material.SmoothPlastic, Color = C.blanco, CanCollide = false }, mFachada)
			rcaja(sal, "Tubo_Corto", VENT_X1 - 0.13, VENT_X1 + 0.05, 2.735, 2.765, 0.03, 0.06, { Material = Enum.Material.SmoothPlastic, Color = C.blanco, CanCollide = false, CastShadow = false }, mFachada)
			rcaja(sal, "Viga_Corredor", CAL_X1 + 0.02, CAL_X1 + 0.22, H - 0.30, H, 0, CORREDOR, { Material = Enum.Material.Concrete, Color = C.grisLosa }, mCorredor)
		end

		-----------------------------------------------------------------------
		-- ETAPA 5 (interior) · Vigas de concreto a la vista en retícula
		-----------------------------------------------------------------------
		local vigaProps = { Material = Enum.Material.Concrete, Color = C.grisViga }
		local Y_VIGA = H - 0.30
		local vigasZ = { -1.42, -2.69, -3.96, -5.23 }                 -- vigas longitudinales (paralelas a la fachada), paso ~1.27 m
		local vigasX = { 1.22, 2.29, 3.36, 4.43, 5.50, 6.57 }       -- vigas transversales (fachada -> fondo), paso ~1.07 m
		for _, z in ipairs(vigasZ) do
			rcaja(sal, "Viga_Longitudinal", X_INT0, X_INT1, Y_VIGA, H, z - 0.10, z + 0.10, vigaProps, mTecho)
		end
		for _, x in ipairs(vigasX) do
			rcaja(sal, "Viga_Transversal", x - 0.10, x + 0.10, Y_VIGA, H, Z_INT0, Z_INT1, vigaProps, mTecho)
		end

		-----------------------------------------------------------------------
		-- ETAPA 6 · Interior: iluminación, ventiladores, aire acondicionado, tablero, carteles, instalaciones
		-----------------------------------------------------------------------
		-- Lámparas fluorescentes colgantes bajo las vigas: 3 líneas (cerca de la fachada, centro, cerca del fondo) x 3
		for _, z in ipairs({ -0.78, -3.33, -5.86 }) do
			for _, x in ipairs({ 1.50, 3.90, 6.30 }) do
				lamparaFluorescente(mTecho, sal.tx(x), z, H) -- varillas hasta la cara inferior de la losa
			end
		end
		-- Luminarias redondas planas adosadas a la losa, en las bandas intermedias
		for _, z in ipairs({ -2.05, -4.60 }) do
			for _, x in ipairs({ 2.70, 5.10 }) do
				local xw = sal.tx(x)
				cilindro("Luminaria_Redonda", Vector3.new(xw, H - 0.05, z), Vector3.new(xw, H, z), 0.30, { Material = Enum.Material.Neon, Color = C.neon, CanCollide = false, CastShadow = false }, mTecho)
			end
		end
		-- Dos ventiladores de jaula colgados de la losa en la banda central, soplando hacia el fondo del salón (lado de los carteles)
		ventiladorJaula(mTecho, sal.tx(2.70), -3.33, H, rnormal(sal, -1, 0))
		ventiladorJaula(mTecho, sal.tx(5.10), -3.33, H, rnormal(sal, -1, 0))

		-- Aire acondicionado split en la cara interior de la fachada, más allá de la ventana (lado opuesto a la puerta)
		local AC_X0, AC_X1 = 3.45 + dv, 4.35 + dv
		rcaja(sal, "Aire_Acondicionado", AC_X0, AC_X1, 2.30, 2.62, -T - 0.22, -T, { Material = Enum.Material.SmoothPlastic, Color = C.blanco }, mMuros)
		rcaja(sal, "AC_Rejilla", AC_X0 + 0.05, AC_X1 - 0.05, 2.31, 2.35, -T - 0.225, -T - 0.21, { Material = Enum.Material.SmoothPlastic, Color = C.metalClaro, CanCollide = false, CastShadow = false }, mMuros)
		cilindro("AC_Tuberia", rpunto(sal, AC_X1 - 0.03, 1.45, -T - 0.02), rpunto(sal, AC_X1 - 0.03, 2.30, -T - 0.02), 0.025, { Material = Enum.Material.SmoothPlastic, Color = C.blanco, CanCollide = false, CastShadow = false }, mMuros)
		-- Interruptor bajo el aire acondicionado, sobre muro macizo (a la izquierda del calado)
		rcaja(sal, "Interruptor", 4.10 + dv, 4.20 + dv, 1.30, 1.40, -T - 0.02, -T, { Material = Enum.Material.SmoothPlastic, Color = C.blanco, CanCollide = false, CastShadow = false }, mMuros)

		-- Tablero acrílico blanco con marco de aluminio y bandeja, en la MEDIANERA (pared del frente de la clase,
		-- la misma de la puerta), empezando a 0.10 m de la esquina trasera, como en la imagen del escritorio
		do
			local TB_Z0, TB_Z1 = Z_INT0 + 0.10, Z_INT0 + 2.50        -- 2.4 m de ancho
			rcaja(sal, "Tablero_Marco", X_INT1 - 0.02, X_INT1, 0.92, 2.18, TB_Z0 - 0.03, TB_Z1 + 0.03, { Material = Enum.Material.Metal, Color = C.aluminio }, mMuros)
			rcaja(sal, "Tablero_Blanco", X_INT1 - 0.03, X_INT1 - 0.02, 0.95, 2.15, TB_Z0, TB_Z1, { Material = Enum.Material.SmoothPlastic, Color = C.tablero, Reflectance = 0.04 }, mMuros)
			rcaja(sal, "Tablero_Bandeja", X_INT1 - 0.08, X_INT1, 0.90, 0.93, TB_Z0 + 0.2, TB_Z1 - 0.2, { Material = Enum.Material.Metal, Color = C.aluminio, CanCollide = false }, mMuros)
		end

		-- Carteles de colores colgados de un riel blanco en el MURO EXTREMO (opuesto a la medianera) + cartel pequeño con borde rojo
		do
			local xCara = X_INT0
			-- riel blanco con rótulos pequeños, de 1.5 m a 4.5 m de la fachada; 5 hojas A3 a paso 0.6 m debajo
			local riel = placa("Riel_Carteles", rpunto(sal, xCara + 0.015, 2.37, -3.00), 3.00, 0.12, 0.03, rnormal(sal, 1, 0),
				{ Material = Enum.Material.SmoothPlastic, Color = C.blanco, CanCollide = false }, mMuros)
			texto(riel, "·  LECTURA   ·   MATEMÁTICAS   ·   CIENCIAS   ·   SOCIALES   ·   VALORES  ·", C.grafito, { Font = Enum.Font.Gotham, Size = UDim2.new(1, 0, 0.5, 0), Position = UDim2.new(0, 0, 0.25, 0) })
			local colores = { C.posterAmarillo, C.posterCeleste, C.posterRojo, C.posterAmarillo, C.posterVerde }
			for i, col in ipairs(colores) do
				local zc = -(1.90 + (i - 1) * 0.60)
				local cartel = placa("Cartel_" .. i, rpunto(sal, xCara + 0.012, 1.70, zc), 0.30, 0.42, 0.01, rnormal(sal, 1, 0),
					{ Material = Enum.Material.SmoothPlastic, Color = col, CanCollide = false, CastShadow = false }, mMuros)
				texto(cartel, "▬▬▬▬\n▬▬▬▬▬▬\n▬▬▬▬▬", C.grafito, { Font = Enum.Font.Gotham, Size = UDim2.new(0.6, 0, 0.22, 0), Position = UDim2.new(0.2, 0, 0.42, 0) })
			end
			-- cartel pequeño blanco con borde rojo, a ~1 m de la fachada
			placa("Cartel_Pequeno_Borde", rpunto(sal, xCara + 0.012, 1.68, -1.00), 0.36, 0.40, 0.01, rnormal(sal, 1, 0),
				{ Material = Enum.Material.SmoothPlastic, Color = C.posterRojo, CanCollide = false, CastShadow = false }, mMuros)
			local cp = placa("Cartel_Pequeno", rpunto(sal, xCara + 0.021, 1.68, -1.00), 0.33, 0.37, 0.006, rnormal(sal, 1, 0),
				{ Material = Enum.Material.SmoothPlastic, Color = C.posterBlanco, CanCollide = false, CastShadow = false }, mMuros)
			texto(cp, "▬▬▬▬", C.posterRojo, { Font = Enum.Font.Gotham, Size = UDim2.new(0.7, 0, 0.1, 0), Position = UDim2.new(0.15, 0, 0.82, 0) })
		end

		-- Canaleta blanca a ras de piso en el muro extremo y en el muro de fondo (visible en los renders)
		rcaja(sal, "Canaleta_Piso_Extremo", X_INT0, X_INT0 + 0.025, 0.13, 0.155, Z_INT0, Z_INT1, { Material = Enum.Material.SmoothPlastic, Color = C.blanco, CanCollide = false, CastShadow = false }, mMuros)
		rcaja(sal, "Canaleta_Piso_Fondo", X_INT0 + 0.025, X_INT1, 0.13, 0.155, Z_INT0, Z_INT0 + 0.025, { Material = Enum.Material.SmoothPlastic, Color = C.blanco, CanCollide = false, CastShadow = false }, mMuros)

		-----------------------------------------------------------------------
		-- ETAPA 7 · Mobiliario
		-----------------------------------------------------------------------
		-- Escritorio del profesor en la esquina trasera junto a la medianera (delante del tablero, lado largo
		-- paralelo al muro de fondo, a 0.5 m de la medianera); silla negra (silla universitaria sin paleta)
		-- entre el escritorio y el muro de fondo, mirando hacia la clase. Reproduce la esquina de la imagen 1.
		escritorioProfesor(mMob, rpunto(sal, X_INT1 - 0.50 - 0.75, 0, -5.72))
		sillaUniversitaria(mMob, rpunto(sal, X_INT1 - 1.25, 0, -6.27), Vector3.new(0, 0, 1), { paleta = false, color = C.negroMetal, nombre = "Silla_Profesor" })

		-- 20 sillas universitarias azules en 4 filas x 5, mirando hacia la medianera (lado de la puerta),
		-- con una ligera irregularidad determinista (±8°, ±0.10 m) como en el render de referencia
		local filasX = { 1.70, 3.00, 4.30, 5.60 }
		local colsZ = { -0.80, -1.82, -2.84, -3.86, -4.88 }
		local semilla = 7
		local function ruido() -- generador Park-Miller: exacto en doubles, idéntico en cada ejecución
			semilla = (semilla * 16807) % 2147483647
			return (semilla / 2147483647) * 2 - 1
		end
		for _, x in ipairs(filasX) do
			for _, z in ipairs(colsZ) do
				local ang = math.rad(ruido() * 8)
				local dx, dz = ruido() * 0.10, ruido() * 0.10
				local mirar = Vector3.new(math.cos(ang) * sal.dir, 0, -math.sin(ang))
				sillaUniversitaria(mMob, rpunto(sal, x + dx, 0, z + dz), mirar)
			end
		end
	end

	---------------------------------------------------------------------------
	-- ETAPA 8 · Verificación de orientaciones, colisiones y posiciones
	---------------------------------------------------------------------------
	local chequeos = {}
	local function esperar(cond, msg) if not cond then table.insert(chequeos, msg) end end
	-- Semiextensión de una Part en los ejes del mundo (caja envolvente alineada), en studs
	local function extension(part)
		local cf, s = part.CFrame, part.Size / 2
		local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
		return Vector3.new(
			math.abs(r.X) * s.X + math.abs(u.X) * s.Y + math.abs(l.X) * s.Z,
			math.abs(r.Y) * s.X + math.abs(u.Y) * s.Y + math.abs(l.Y) * s.Z,
			math.abs(r.Z) * s.X + math.abs(u.Z) * s.Y + math.abs(l.Z) * s.Z)
	end
	local puerta6B = raiz:FindFirstChild("Hoja_Puerta_6B", true)
	local puerta7B = raiz:FindFirstChild("Hoja_Puerta_7B", true)
	esperar(puerta6B and puerta7B, "Faltan hojas de puerta")
	if puerta6B and puerta7B then
		esperar(puerta6B.Position.X < puerta7B.Position.X, "La puerta 6B debería quedar a la IZQUIERDA (menor X) que la 7B")
		esperar(puerta6B.CFrame.LookVector.Z > 0.99 and puerta7B.CFrame.LookVector.Z > 0.99, "Las hojas deben mirar hacia el corredor (+Z)")
		esperar(math.abs(puerta7B.Position.X - puerta6B.Position.X) < mt(1.6), "Las puertas deberían estar juntas, separadas por la columna")
	end
	-- Tablero sobre la medianera de cada salón
	for _, sal in ipairs(SALONES) do
		local mSalon = raiz:FindFirstChild(sal.nombre)
		local tb = mSalon and mSalon:FindFirstChild("Tablero_Blanco", true)
		esperar(tb ~= nil, sal.nombre .. ": falta el tablero")
		if tb then
			esperar(math.abs(tb.Position.X - (ORIGEN.X + mt(sal.tx(X_INT1 - 0.025)))) < 0.05, sal.nombre .. ": el tablero no está sobre la medianera")
		end
	end
	-- Ninguna pieza de mobiliario fuera del interior de su salón ni atravesando la fachada / el fondo
	for _, sal in ipairs(SALONES) do
		local mSalon = raiz:FindFirstChild(sal.nombre)
		local mob = mSalon and mSalon:FindFirstChild("Mobiliario")
		if mob then
			local xa, xb = sal.tx(X_INT0), sal.tx(X_INT1)
			if xa > xb then xa, xb = xb, xa end
			local minX, maxX = ORIGEN.X + mt(xa), ORIGEN.X + mt(xb)
			local minZ, maxZ = ORIGEN.Z + mt(Z_INT0), ORIGEN.Z + mt(Z_INT1)
			for _, d in ipairs(mob:GetDescendants()) do
				if d:IsA("BasePart") then
					local p = d.Position
					local e = extension(d)
					esperar(p.X - e.X > minX - 0.05 and p.X + e.X < maxX + 0.05 and p.Z - e.Z > minZ - 0.05 and p.Z + e.Z < maxZ + 0.05 and p.Y - e.Y > ORIGEN.Y - 0.05,
						sal.nombre .. ": " .. d:GetFullName() .. " sale del interior del salón")
				end
			end
		end
	end
	-- Las sillas de 6B miran a +X y las de 7B a -X (hacia la medianera, donde está cada puerta)
	for _, sal in ipairs(SALONES) do
		local mSalon = raiz:FindFirstChild(sal.nombre)
		local mob = mSalon and mSalon:FindFirstChild("Mobiliario")
		if mob then
			for _, s in ipairs(mob:GetChildren()) do
				if s.Name == "Silla_Universitaria" then
					local asiento = s:FindFirstChild("Asiento")
					esperar(asiento and asiento.CFrame.LookVector.X * sal.dir > 0.95, sal.nombre .. ": silla con orientación incorrecta")
				end
			end
		end
	end
	for _, msg in ipairs(chequeos) do advertir("Verificación: " .. msg) end

	---------------------------------------------------------------------------
	-- ETAPA 9 · Presupuesto de Parts
	---------------------------------------------------------------------------
	local total = 0
	for _, d in ipairs(raiz:GetDescendants()) do
		if d:IsA("BasePart") then total = total + 1 end
	end
	if total > LIMITE_PARTS then
		error(string.format("Se generaron %d BaseParts, por encima del límite de %d. Construcción cancelada.", total, LIMITE_PARTS))
	end
	return total
end

-------------------------------------------------------------------------------
-- EJECUCIÓN: reemplazo seguro del modelo anterior, construcción protegida y resumen
-------------------------------------------------------------------------------
ChangeHistoryService:SetWaypoint("Antes de generar " .. NOMBRE_MODELO)

-- Solo se elimina un modelo previo si fue generado por este mismo script (atributo de marca)
for _, obj in ipairs(Workspace:GetChildren()) do
	if obj.Name == NOMBRE_MODELO then
		if obj:IsA("Model") and obj:GetAttribute(ATRIBUTO_MARCA) == true then
			obj:Destroy()
		else
			advertir("Existe un objeto ajeno llamado " .. NOMBRE_MODELO .. " en Workspace; no se tocó.")
		end
	end
end

local ok, resultado = pcall(construir)
if not ok then
	if raiz then raiz:Destroy() end
	error("[" .. NOMBRE_MODELO .. "] Error durante la construcción; se eliminó la construcción parcial.\n" .. tostring(resultado), 0)
end

raiz.Parent = Workspace
ChangeHistoryService:SetWaypoint("Generar " .. NOMBRE_MODELO)

---------------------------------------------------------------------------
-- ETAPA 10 · Resumen en Output
---------------------------------------------------------------------------
local totalParts = resultado
local numSalones = 0
local porModelo = {}
for _, hijo in ipairs(raiz:GetChildren()) do
	local n = 0
	for _, d in ipairs(hijo:GetDescendants()) do
		if d:IsA("BasePart") then n = n + 1 end
	end
	porModelo[hijo.Name] = n
	if hijo.Name:sub(1, 6) == "Salon_" then numSalones = numSalones + 1 end
end

print("==============================================")
print(" " .. NOMBRE_MODELO .. " generado correctamente")
print(string.format(" Salones construidos : %d (6B izquierda, 7B derecha)", numSalones))
print(string.format(" BaseParts totales   : %d / %d", totalParts, LIMITE_PARTS))
for _, nombre in ipairs({ "Estructura", "Corredor", "Salon_1_6B", "Salon_2_7B" }) do
	print(string.format("   - %-12s %4d parts", nombre, porModelo[nombre] or 0))
end
print(string.format(" Escala: %d studs = 1 m · Origen: (%.1f, %.1f, %.1f)", ESCALA, ORIGEN.X, ORIGEN.Y, ORIGEN.Z))
print(" Orientación: fachada en Z=0 mirando a +Z (corredor); 6B en X menor (izquierda), 7B en X mayor (derecha)")
if #advertencias == 0 then
	print(" Advertencias        : ninguna")
else
	print(string.format(" Advertencias        : %d", #advertencias))
	for _, a in ipairs(advertencias) do warn("  · " .. a) end
end
print("==============================================")
