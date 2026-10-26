--[[
	Ruta en el Explorer: ReplicatedStorage.ColegioRP.Shared.Util.Format
	Tipo: ModuleScript
	Formato de textos para la interfaz en español: horas (12/24 h), moneda escolar, duraciones,
	truncado seguro de UTF-8, fechas y números con separador de miles.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local Format = {}

Format.Elipsis = "…"
Format.SeparadorMiles = "."
Format.SeparadorDecimal = ","

local function aNumero(valor, porDefecto)
	local n = tonumber(valor)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return porDefecto
	end
	return n
end

-- Número entero con separador de miles ("1.250"). Los decimales se redondean.
function Format.Numero(n)
	n = aNumero(n, 0)
	local negativo = n < 0
	local entero = math.floor(math.abs(n) + 0.5)
	local texto = tostring(entero)
	local resultado = ""
	local contador = 0
	for i = #texto, 1, -1 do
		resultado = string.sub(texto, i, i) .. resultado
		contador = contador + 1
		if contador % 3 == 0 and i > 1 then
			resultado = Format.SeparadorMiles .. resultado
		end
	end
	if negativo then
		return "-" .. resultado
	end
	return resultado
end

-- Número con decimales fijos y coma decimal ("3,14").
function Format.Decimal(n, decimales)
	n = aNumero(n, 0)
	decimales = decimales or 2
	local texto = string.format("%." .. decimales .. "f", n)
	texto = string.gsub(texto, "%.", Format.SeparadorDecimal)
	return texto
end

-- Hora escolar a partir de segundos del día. formato12 = true -> "7:15 a. m."; si no -> "07:15".
function Format.HoraHHMM(segundosDia, formato12)
	local total = math.floor(aNumero(segundosDia, 0)) % 86400
	local h = math.floor(total / 3600)
	local m = math.floor((total % 3600) / 60)
	if formato12 then
		local sufijo = "a. m."
		if h >= 12 then
			sufijo = "p. m."
		end
		local h12 = h % 12
		if h12 == 0 then
			h12 = 12
		end
		return string.format("%d:%02d %s", h12, m, sufijo)
	end
	return string.format("%02d:%02d", h, m)
end

-- Convierte "HH:MM" a segundos del día (nil si el formato es inválido).
function Format.SegundosDeHHMM(texto)
	if typeof(texto) ~= "string" then
		return nil
	end
	local h, m = string.match(texto, "^(%d%d?):(%d%d)$")
	if not h then
		return nil
	end
	h, m = tonumber(h), tonumber(m)
	if h > 23 or m > 59 then
		return nil
	end
	return h * 3600 + m * 60
end

-- Importe en moneda escolar ("◎ 1.250"). conNombre = true añade el nombre de la moneda.
function Format.Moneda(n, conNombre)
	local simbolo = (Config.Economia and Config.Economia.MonedaSimbolo) or "◎"
	local texto = simbolo .. " " .. Format.Numero(n)
	if conNombre then
		local nombre = (Config.Economia and Config.Economia.MonedaNombre) or "Monedas"
		return texto .. " " .. string.lower(nombre)
	end
	return texto
end

-- Tiempo restante "mm:ss" (o "h:mm:ss" si supera una hora). Nunca negativo.
function Format.Tiempo(seg)
	local total = math.max(0, math.floor(aNumero(seg, 0) + 0.5))
	local h = math.floor(total / 3600)
	local m = math.floor((total % 3600) / 60)
	local s = total % 60
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, s)
	end
	return string.format("%02d:%02d", m, s)
end

-- Duración legible ("45 s", "5 min", "1 h 20 min").
function Format.Duracion(seg)
	local total = math.max(0, math.floor(aNumero(seg, 0) + 0.5))
	if total < 60 then
		return total .. " s"
	end
	local h = math.floor(total / 3600)
	local m = math.floor((total % 3600) / 60)
	if h > 0 then
		if m > 0 then
			return string.format("%d h %d min", h, m)
		end
		return h .. " h"
	end
	return m .. " min"
end

-- Longitud en caracteres (UTF-8); si el texto es inválido cuenta bytes.
function Format.Longitud(texto)
	if typeof(texto) ~= "string" then
		return 0
	end
	local n = utf8.len(texto)
	if n == nil then
		return #texto
	end
	return n
end

-- Recorta el texto a n caracteres (UTF-8) añadiendo "…" si hace falta.
function Format.Truncar(texto, n)
	if typeof(texto) ~= "string" then
		texto = tostring(texto or "")
	end
	n = math.max(1, math.floor(aNumero(n, 1)))
	local longitud = utf8.len(texto)
	if longitud == nil then
		-- UTF-8 inválido: recorte por bytes como último recurso.
		if #texto <= n then
			return texto
		end
		return string.sub(texto, 1, math.max(n - 1, 0)) .. Format.Elipsis
	end
	if longitud <= n then
		return texto
	end
	local caracteres = math.max(n - 1, 0)
	if caracteres == 0 then
		return Format.Elipsis
	end
	local corte = utf8.offset(texto, caracteres + 1)
	if corte == nil then
		return texto
	end
	return string.sub(texto, 1, corte - 1) .. Format.Elipsis
end

-- Fecha legible a partir de un tiempo Unix ("26/10/2026 14:05"); conHora = false omite la hora.
function Format.Fecha(unix, conHora)
	unix = math.floor(aNumero(unix, os.time()))
	local ok, t = pcall(os.date, "*t", unix)
	if not ok or typeof(t) ~= "table" then
		return "--/--/----"
	end
	local texto = string.format("%02d/%02d/%04d", t.day, t.month, t.year)
	if conHora == false then
		return texto
	end
	return texto .. string.format(" %02d:%02d", t.hour, t.min)
end

-- Fecha corta "AAAA-MM-DD" (clave de día para límites diarios).
function Format.ClaveDia(unix)
	unix = math.floor(aNumero(unix, os.time()))
	local ok, t = pcall(os.date, "!*t", unix)
	if not ok or typeof(t) ~= "table" then
		return "0000-00-00"
	end
	return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
end

-- Singular/plural según la cantidad ("1 página", "3 páginas").
function Format.Plural(n, singular, plural)
	n = aNumero(n, 0)
	if n == 1 then
		return Format.Numero(n) .. " " .. singular
	end
	return Format.Numero(n) .. " " .. (plural or (singular .. "s"))
end

-- Porcentaje entero ("75 %"); acepta fracción 0..1 o valor 0..100 (si esFraccion = true se multiplica).
function Format.Porcentaje(valor, esFraccion)
	valor = aNumero(valor, 0)
	if esFraccion then
		valor = valor * 100
	end
	return string.format("%d %%", math.floor(math.max(0, math.min(100, valor)) + 0.5))
end

-- Primera letra en mayúscula (sin tocar el resto).
function Format.Capitalizar(texto)
	if typeof(texto) ~= "string" or texto == "" then
		return ""
	end
	local primera = utf8.offset(texto, 2)
	if primera == nil then
		return string.upper(texto)
	end
	return string.upper(string.sub(texto, 1, primera - 1)) .. string.sub(texto, primera)
end

-- Elimina espacios al inicio y al final.
function Format.Recortar(texto)
	if typeof(texto) ~= "string" then
		return ""
	end
	local resultado = string.gsub(texto, "^%s+", "")
	resultado = string.gsub(resultado, "%s+$", "")
	return resultado
end

-- Nombre de equipo deportivo ("Equipo A").
function Format.Equipo(letra)
	return "Equipo " .. tostring(letra or "?")
end

-- Marcador "2 - 1".
function Format.Marcador(a, b)
	return string.format("%d - %d", math.floor(aNumero(a, 0)), math.floor(aNumero(b, 0)))
end

return Format
