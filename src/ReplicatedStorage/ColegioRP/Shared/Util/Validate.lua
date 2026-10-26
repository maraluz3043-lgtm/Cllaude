--[[
	Ruta en el Explorer: ReplicatedStorage.ColegioRP.Shared.Util.Validate
	Tipo: ModuleScript
	Validación declarativa de datos (peticiones de remotos y cualquier tabla). Un esquema describe
	campos y tipos; Validate.Comprobar(esquema, valor) devuelve ok y un mensaje legible en español.
	Por defecto los esquemas son estrictos (rechazan claves desconocidas) y acotan tamaño y anidación.

	Descriptores de campo admitidos (todos aceptan opcional = true):
		{ tipo = "string",  min = n, max = n, enum = {...}, patron = "...", sinSaltos = true }
		{ tipo = "number",  min = n, max = n, entero = true }
		{ tipo = "boolean" }
		{ tipo = "enum",    valores = { ... } }               -- strings o números
		{ tipo = "Vector3", magnitud = n }                    -- magnitud máxima (con tolerancia)
		{ tipo = "table",   campos = { ... } | esquema, estricto = bool }  -- tabla con campos
		{ tipo = "table",   libre = true }                    -- tabla libre acotada (claves/valores simples)
		{ tipo = "array",   de = descriptor, maxItems = n, minItems = n }
		{ tipo = "any" }                                      -- valor simple o tabla libre acotada
	Atajos: Validate.Str(max, opcional, min), Int(min, max, opcional), Num(min, max, opcional), Bool(opcional),
		Enum(valores, opcional), V3(magnitud, opcional), Tabla(campos, opcional, estricto), TablaLibre(opcional),
		Array(de, maxItems, opcional), Cualquiera(opcional).
]]

local Validate = {}

-- Límites de seguridad globales (protegen al servidor de tablas enormes o muy anidadas).
Validate.ProfundidadMax = 6 -- Niveles de anidación permitidos.
Validate.ClavesMax = 256 -- Claves totales recorridas por comprobación.
Validate.ClaveMaxCaracteres = 48 -- Longitud máxima de una clave de tabla libre.
Validate.TextoLibreMax = 2000 -- Longitud por defecto de un texto sin max explícito.
Validate.ArrayLibreMax = 128 -- Elementos por defecto de una lista sin maxItems.
Validate.ToleranciaMagnitud = 0.001 -- Tolerancia al comparar magnitudes de Vector3.

---------------------------------------------------------------------------------------------------
-- Utilidades internas
---------------------------------------------------------------------------------------------------
local function esFinito(n)
	return typeof(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function esEntero(n)
	return esFinito(n) and math.floor(n) == n
end

local function nombreRuta(ruta)
	if ruta == nil or ruta == "" then
		return "datos"
	end
	return ruta
end

local function unirRuta(ruta, clave)
	if ruta == nil or ruta == "" then
		return tostring(clave)
	end
	return ruta .. "." .. tostring(clave)
end

local function enLista(lista, valor)
	for _, v in ipairs(lista) do
		if v == valor then
			return true
		end
	end
	return false
end

local function listarValores(lista)
	local partes = {}
	for i, v in ipairs(lista) do
		if i > 8 then
			table.insert(partes, "...")
			break
		end
		table.insert(partes, tostring(v))
	end
	return table.concat(partes, ", ")
end

local comprobarDescriptor
local comprobarTablaLibre

-- Valor "libre": texto, número finito, booleano, Vector3/Vector2/Color3 o tabla libre acotada.
local function comprobarValorLibre(valor, ruta, ctx, profundidad)
	local tipo = typeof(valor)
	if tipo == "string" then
		local n = utf8.len(valor)
		if not n then
			return false, nombreRuta(ruta) .. " contiene texto inválido"
		end
		if n > Validate.TextoLibreMax then
			return false, string.format("%s supera los %d caracteres", nombreRuta(ruta), Validate.TextoLibreMax)
		end
		return true
	elseif tipo == "number" then
		if not esFinito(valor) then
			return false, nombreRuta(ruta) .. " no es un número finito"
		end
		return true
	elseif tipo == "boolean" or tipo == "Vector2" or tipo == "Color3" then
		return true
	elseif tipo == "Vector3" then
		if not (esFinito(valor.X) and esFinito(valor.Y) and esFinito(valor.Z)) then
			return false, nombreRuta(ruta) .. " tiene componentes no finitas"
		end
		return true
	elseif tipo == "table" then
		return comprobarTablaLibre(valor, ruta, ctx, profundidad)
	end
	return false, string.format("%s tiene un tipo no permitido (%s)", nombreRuta(ruta), tipo)
end

-- Tabla libre: claves string cortas o enteros; valores libres; tamaño y profundidad acotados.
function comprobarTablaLibre(valor, ruta, ctx, profundidad)
	if profundidad > Validate.ProfundidadMax then
		return false, nombreRuta(ruta) .. " está anidado en exceso"
	end
	for clave, v in pairs(valor) do
		ctx.claves = ctx.claves + 1
		if ctx.claves > Validate.ClavesMax then
			return false, "demasiados datos en la petición"
		end
		local tipoClave = typeof(clave)
		if tipoClave == "string" then
			if #clave > Validate.ClaveMaxCaracteres then
				return false, nombreRuta(ruta) .. " tiene una clave demasiado larga"
			end
		elseif tipoClave == "number" then
			if not esEntero(clave) then
				return false, nombreRuta(ruta) .. " tiene una clave numérica no entera"
			end
		else
			return false, nombreRuta(ruta) .. " tiene una clave de tipo no permitido (" .. tipoClave .. ")"
		end
		local ok, err = comprobarValorLibre(v, unirRuta(ruta, clave), ctx, profundidad + 1)
		if not ok then
			return false, err
		end
	end
	return true
end

-- Tabla con campos declarados.
local function comprobarCampos(campos, estricto, valor, ruta, ctx, profundidad)
	if profundidad > Validate.ProfundidadMax then
		return false, nombreRuta(ruta) .. " está anidado en exceso"
	end
	for nombre, descriptor in pairs(campos) do
		ctx.claves = ctx.claves + 1
		if ctx.claves > Validate.ClavesMax then
			return false, "demasiados datos en la petición"
		end
		local ok, err = comprobarDescriptor(descriptor, valor[nombre], unirRuta(ruta, nombre), ctx, profundidad)
		if not ok then
			return false, err
		end
	end
	local total = 0
	for clave in pairs(valor) do
		total = total + 1
		if total > Validate.ClavesMax then
			return false, "demasiados datos en la petición"
		end
		if estricto and (typeof(clave) ~= "string" or campos[clave] == nil) then
			return false, string.format("%s tiene una clave desconocida (%s)", nombreRuta(ruta), tostring(clave))
		end
	end
	return true
end

-- Comprueba un valor contra un descriptor de campo.
function comprobarDescriptor(descriptor, valor, ruta, ctx, profundidad)
	if typeof(descriptor) ~= "table" or typeof(descriptor.tipo) ~= "string" then
		return false, "esquema inválido en " .. nombreRuta(ruta)
	end
	if valor == nil then
		if descriptor.opcional then
			return true
		end
		return false, nombreRuta(ruta) .. " es obligatorio"
	end
	local tipo = descriptor.tipo

	if tipo == "string" then
		if typeof(valor) ~= "string" then
			return false, nombreRuta(ruta) .. " debe ser texto"
		end
		local n = utf8.len(valor)
		if not n then
			return false, nombreRuta(ruta) .. " contiene caracteres inválidos"
		end
		local min = descriptor.min or 0
		local max = descriptor.max or Validate.TextoLibreMax
		if n < min then
			return false, string.format("%s debe tener al menos %d caracteres", nombreRuta(ruta), min)
		end
		if n > max then
			return false, string.format("%s supera los %d caracteres", nombreRuta(ruta), max)
		end
		if descriptor.sinSaltos and string.find(valor, "\n", 1, true) then
			return false, nombreRuta(ruta) .. " no admite saltos de línea"
		end
		if descriptor.patron and not string.match(valor, descriptor.patron) then
			return false, nombreRuta(ruta) .. " tiene un formato inválido"
		end
		if descriptor.enum and not enLista(descriptor.enum, valor) then
			return false, string.format("%s debe ser uno de: %s", nombreRuta(ruta), listarValores(descriptor.enum))
		end
		return true

	elseif tipo == "number" then
		if typeof(valor) ~= "number" or not esFinito(valor) then
			return false, nombreRuta(ruta) .. " debe ser un número"
		end
		if descriptor.entero and math.floor(valor) ~= valor then
			return false, nombreRuta(ruta) .. " debe ser un número entero"
		end
		if descriptor.min ~= nil and valor < descriptor.min then
			return false, string.format("%s debe ser mayor o igual que %s", nombreRuta(ruta), tostring(descriptor.min))
		end
		if descriptor.max ~= nil and valor > descriptor.max then
			return false, string.format("%s debe ser menor o igual que %s", nombreRuta(ruta), tostring(descriptor.max))
		end
		return true

	elseif tipo == "boolean" then
		if typeof(valor) ~= "boolean" then
			return false, nombreRuta(ruta) .. " debe ser verdadero o falso"
		end
		return true

	elseif tipo == "enum" then
		local valores = descriptor.valores or descriptor.enum
		if typeof(valores) ~= "table" then
			return false, "esquema inválido (enum sin valores) en " .. nombreRuta(ruta)
		end
		local tv = typeof(valor)
		if tv ~= "string" and tv ~= "number" then
			return false, nombreRuta(ruta) .. " debe ser texto o número"
		end
		if not enLista(valores, valor) then
			return false, string.format("%s debe ser uno de: %s", nombreRuta(ruta), listarValores(valores))
		end
		return true

	elseif tipo == "Vector3" then
		if typeof(valor) ~= "Vector3" then
			return false, nombreRuta(ruta) .. " debe ser un Vector3"
		end
		if not (esFinito(valor.X) and esFinito(valor.Y) and esFinito(valor.Z)) then
			return false, nombreRuta(ruta) .. " tiene componentes no finitas"
		end
		if descriptor.magnitud ~= nil and valor.Magnitude > descriptor.magnitud + Validate.ToleranciaMagnitud then
			return false, string.format("%s supera la magnitud máxima (%s)", nombreRuta(ruta), tostring(descriptor.magnitud))
		end
		return true

	elseif tipo == "table" then
		if typeof(valor) ~= "table" then
			return false, nombreRuta(ruta) .. " debe ser una tabla"
		end
		if descriptor.libre or descriptor.campos == nil then
			return comprobarTablaLibre(valor, ruta, ctx, profundidad + 1)
		end
		local campos = descriptor.campos
		local estricto = descriptor.estricto
		if campos.__esquema then
			if estricto == nil then
				estricto = campos.estricto
			end
			campos = campos.campos
		end
		if estricto == nil then
			estricto = true
		end
		return comprobarCampos(campos, estricto, valor, ruta, ctx, profundidad + 1)

	elseif tipo == "array" then
		if typeof(valor) ~= "table" then
			return false, nombreRuta(ruta) .. " debe ser una lista"
		end
		if profundidad + 1 > Validate.ProfundidadMax then
			return false, nombreRuta(ruta) .. " está anidado en exceso"
		end
		local n = #valor
		local total = 0
		for _ in pairs(valor) do
			total = total + 1
			if total > Validate.ClavesMax then
				return false, "demasiados datos en la petición"
			end
		end
		if total ~= n then
			return false, nombreRuta(ruta) .. " no es una lista continua"
		end
		local maxItems = descriptor.maxItems or Validate.ArrayLibreMax
		if n > maxItems then
			return false, string.format("%s supera los %d elementos", nombreRuta(ruta), maxItems)
		end
		if descriptor.minItems ~= nil and n < descriptor.minItems then
			return false, string.format("%s debe tener al menos %d elementos", nombreRuta(ruta), descriptor.minItems)
		end
		ctx.claves = ctx.claves + n
		if ctx.claves > Validate.ClavesMax then
			return false, "demasiados datos en la petición"
		end
		for i = 1, n do
			local rutaElemento = nombreRuta(ruta) .. "[" .. i .. "]"
			local ok, err
			if descriptor.de then
				ok, err = comprobarDescriptor(descriptor.de, valor[i], rutaElemento, ctx, profundidad + 1)
			else
				ok, err = comprobarValorLibre(valor[i], rutaElemento, ctx, profundidad + 1)
			end
			if not ok then
				return false, err
			end
		end
		return true

	elseif tipo == "any" then
		return comprobarValorLibre(valor, ruta, ctx, profundidad + 1)
	end

	return false, string.format("esquema inválido (tipo %s) en %s", tostring(tipo), nombreRuta(ruta))
end

---------------------------------------------------------------------------------------------------
-- API pública
---------------------------------------------------------------------------------------------------

-- Construye un esquema a partir de una tabla { campo = descriptor }.
-- opciones.estricto = false permite claves no declaradas (por defecto se rechazan).
function Validate.Esquema(campos, opciones)
	assert(typeof(campos) == "table", "Validate.Esquema: campos debe ser una tabla")
	for nombre, descriptor in pairs(campos) do
		assert(typeof(nombre) == "string", "Validate.Esquema: los nombres de campo deben ser texto")
		assert(typeof(descriptor) == "table" and typeof(descriptor.tipo) == "string",
			"Validate.Esquema: descriptor inválido en el campo '" .. tostring(nombre) .. "'")
	end
	local estricto = true
	if typeof(opciones) == "table" and opciones.estricto == false then
		estricto = false
	end
	return { __esquema = true, campos = campos, estricto = estricto }
end

-- Comprueba si un valor es un esquema creado con Validate.Esquema.
function Validate.EsEsquema(valor)
	return typeof(valor) == "table" and valor.__esquema == true and typeof(valor.campos) == "table"
end

-- Comprueba una tabla contra un esquema. Devuelve ok (bool) y, si falla, un mensaje en español.
function Validate.Comprobar(esquema, valor)
	if typeof(esquema) ~= "table" then
		return false, "esquema inválido"
	end
	if typeof(valor) ~= "table" then
		return false, "los datos deben ser una tabla"
	end
	local campos, estricto = esquema, true
	if esquema.__esquema then
		campos = esquema.campos
		estricto = esquema.estricto
	end
	local ctx = { claves = 0 }
	local ok, err = comprobarCampos(campos, estricto, valor, "", ctx, 1)
	if not ok then
		return false, err
	end
	return true, nil
end

-- Comprueba un único valor contra un descriptor de campo (p. ej. Validate.Str(40)).
function Validate.ComprobarValor(descriptor, valor, nombre)
	local ctx = { claves = 0 }
	return comprobarDescriptor(descriptor, valor, nombre or "valor", ctx, 1)
end

-- Atajo: ¿es un texto válido (UTF-8) con longitud entre min y max?
function Validate.TextoOk(texto, max, min)
	local ok = comprobarDescriptor({ tipo = "string", max = max, min = min }, texto, "texto", { claves = 0 }, 1)
	return ok == true
end

Validate.EsFinito = esFinito
Validate.EsEntero = esEntero

---------------------------------------------------------------------------------------------------
-- Atajos para construir descriptores (notación de docs/ARQUITECTURA.md §5)
---------------------------------------------------------------------------------------------------
function Validate.Str(max, opcional, min)
	return { tipo = "string", max = max, min = min, opcional = opcional == true }
end

function Validate.Int(min, max, opcional)
	return { tipo = "number", entero = true, min = min, max = max, opcional = opcional == true }
end

function Validate.Num(min, max, opcional)
	return { tipo = "number", min = min, max = max, opcional = opcional == true }
end

function Validate.Bool(opcional)
	return { tipo = "boolean", opcional = opcional == true }
end

function Validate.Enum(valores, opcional)
	assert(typeof(valores) == "table" and #valores > 0, "Validate.Enum: lista de valores vacía")
	return { tipo = "enum", valores = valores, opcional = opcional == true }
end

function Validate.V3(magnitud, opcional)
	return { tipo = "Vector3", magnitud = magnitud, opcional = opcional == true }
end

function Validate.Tabla(campos, opcional, estricto)
	assert(typeof(campos) == "table", "Validate.Tabla: campos debe ser una tabla")
	return { tipo = "table", campos = campos, estricto = estricto ~= false, opcional = opcional == true }
end

function Validate.TablaLibre(opcional)
	return { tipo = "table", libre = true, opcional = opcional == true }
end

function Validate.Array(de, maxItems, opcional)
	return { tipo = "array", de = de, maxItems = maxItems, opcional = opcional == true }
end

function Validate.Cualquiera(opcional)
	return { tipo = "any", opcional = opcional == true }
end

return Validate
