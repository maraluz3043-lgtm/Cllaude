--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.AuditLogService
	Tipo: ModuleScript
	Registro de auditoría del servidor: buffer circular (Config.Auditoria.TamanoBuffer) con entradas
	{ Id, T, Categoria, UserId, Jugador, Accion, Detalle }. Categorías: Remoto, Cargo, Moderacion,
	Economia, Clase, Sistema. Otros servicios lo consultan con Listar(n) y se suscriben a Registrado.
]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))

local AuditLogService = {}
AuditLogService.Nombre = "AuditLogService"

-- Categorías conocidas (docs/ARQUITECTURA.md §6). Una categoría desconocida se guarda como "Sistema".
AuditLogService.Categorias = { "Remoto", "Cargo", "Moderacion", "Economia", "Clase", "Sistema" }
-- Categorías que además se imprimen en la salida del servidor (las demás solo se guardan).
AuditLogService.CategoriasImpresas = { Sistema = true, Moderacion = true, Cargo = true }
-- Longitud máxima del detalle guardado.
AuditLogService.MaxDetalleCaracteres = 400

local setCategorias = {}
for _, categoria in ipairs(AuditLogService.Categorias) do
	setCategorias[categoria] = true
end

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------

-- Convierte cualquier valor en un texto corto y seguro para el registro.
local function aTexto(valor, profundidad)
	local tipo = typeof(valor)
	if valor == nil then
		return ""
	elseif tipo == "string" then
		return valor
	elseif tipo == "number" or tipo == "boolean" then
		return tostring(valor)
	elseif tipo == "Instance" then
		return valor:GetFullName()
	elseif tipo == "table" then
		if (profundidad or 0) >= 2 then
			return "{...}"
		end
		local partes = {}
		local n = 0
		for clave, v in pairs(valor) do
			n = n + 1
			if n > 12 then
				table.insert(partes, "...")
				break
			end
			table.insert(partes, tostring(clave) .. "=" .. aTexto(v, (profundidad or 0) + 1))
		end
		return "{" .. table.concat(partes, ", ") .. "}"
	end
	return tostring(valor)
end

local function recortar(texto, max)
	if typeof(texto) ~= "string" then
		return ""
	end
	texto = string.gsub(texto, "[\r\n]+", " ")
	local n = utf8.len(texto)
	if n == nil then
		return string.sub(texto, 1, max)
	end
	if n <= max then
		return texto
	end
	local corte = utf8.offset(texto, max + 1)
	if corte == nil then
		return texto
	end
	return string.sub(texto, 1, corte - 1) .. "…"
end

-- Resuelve el jugador (Player, userId o nil) a UserId y nombre.
local function resolverJugador(player)
	if typeof(player) == "Instance" and player:IsA("Player") then
		return player.UserId, player.Name
	elseif typeof(player) == "number" then
		local instancia = Players:GetPlayerByUserId(player)
		if instancia then
			return player, instancia.Name
		end
		return player, tostring(player)
	end
	return nil, nil
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function AuditLogService:Init(registro)
	self.registro = registro
	self.Tamano = math.max(10, (Config.Auditoria and Config.Auditoria.TamanoBuffer) or 500)
	self.Buffer = table.create(self.Tamano)
	self.Indice = 0 -- posición del último escrito (1..Tamano); 0 = vacío
	self.Total = 0 -- entradas registradas desde el arranque (también sirve de Id)
	self.PorCategoria = {}
	for _, categoria in ipairs(self.Categorias) do
		self.PorCategoria[categoria] = 0
	end
	self.Registrado = Signal.new()
	self.InicioClock = os.clock()
end

function AuditLogService:Start()
	self:Registrar("Sistema", nil, "Arranque", "AuditLogService activo · buffer de " .. self.Tamano .. " entradas")
end

---------------------------------------------------------------------------------------------------
-- Registro
---------------------------------------------------------------------------------------------------

-- Registra una entrada. categoria: string; player: Player | userId | nil; accion: string; detalle: cualquier valor.
-- Devuelve la entrada creada.
function AuditLogService:Registrar(categoria, player, accion, detalle)
	if typeof(categoria) ~= "string" or not setCategorias[categoria] then
		detalle = "[" .. tostring(categoria) .. "] " .. aTexto(detalle)
		categoria = "Sistema"
	end
	local userId, nombre = resolverJugador(player)
	self.Total = self.Total + 1
	local entrada = {
		Id = self.Total,
		T = os.time(),
		Reloj = os.clock() - self.InicioClock,
		Categoria = categoria,
		UserId = userId,
		Jugador = nombre,
		Accion = recortar(aTexto(accion), 64),
		Detalle = recortar(aTexto(detalle), self.MaxDetalleCaracteres),
	}

	self.Indice = self.Indice + 1
	if self.Indice > self.Tamano then
		self.Indice = 1
	end
	self.Buffer[self.Indice] = entrada
	self.PorCategoria[categoria] = (self.PorCategoria[categoria] or 0) + 1

	if self.CategoriasImpresas[categoria] then
		print("[ColegioRP][Auditoría] " .. self:Formatear(entrada))
	end

	self.Registrado:Fire(entrada)
	return entrada
end

-- Formatea una entrada en una línea legible.
function AuditLogService:Formatear(entrada)
	if typeof(entrada) ~= "table" then
		return ""
	end
	local okFecha, fecha = pcall(os.date, "%H:%M:%S", entrada.T or 0)
	if not okFecha then
		fecha = tostring(entrada.T)
	end
	local quien = ""
	if entrada.Jugador then
		quien = " " .. tostring(entrada.Jugador) .. "(" .. tostring(entrada.UserId) .. ")"
	end
	local detalle = ""
	if entrada.Detalle and entrada.Detalle ~= "" then
		detalle = " · " .. entrada.Detalle
	end
	return string.format("%s [%s]%s %s%s", fecha, tostring(entrada.Categoria), quien, tostring(entrada.Accion), detalle)
end

---------------------------------------------------------------------------------------------------
-- Consultas
---------------------------------------------------------------------------------------------------

-- Devuelve las últimas n entradas (la más reciente primero). filtro opcional: { Categoria, UserId, Accion }.
function AuditLogService:Listar(n, filtro)
	n = math.max(1, math.min(tonumber(n) or 50, self.Tamano))
	local resultado = {}
	local disponibles = math.min(self.Total, self.Tamano)
	local posicion = self.Indice
	local revisadas = 0
	while revisadas < disponibles and #resultado < n do
		local entrada = self.Buffer[posicion]
		if entrada then
			local pasa = true
			if typeof(filtro) == "table" then
				if filtro.Categoria ~= nil and entrada.Categoria ~= filtro.Categoria then
					pasa = false
				end
				if filtro.UserId ~= nil and entrada.UserId ~= filtro.UserId then
					pasa = false
				end
				if filtro.Accion ~= nil and entrada.Accion ~= filtro.Accion then
					pasa = false
				end
			end
			if pasa then
				table.insert(resultado, entrada)
			end
		end
		revisadas = revisadas + 1
		posicion = posicion - 1
		if posicion < 1 then
			posicion = self.Tamano
		end
	end
	return resultado
end

-- Últimas n entradas de una categoría.
function AuditLogService:ListarCategoria(categoria, n)
	return self:Listar(n, { Categoria = categoria })
end

-- Últimas n entradas de un jugador (Player o userId).
function AuditLogService:ListarJugador(player, n)
	local userId = resolverJugador(player)
	if not userId then
		return {}
	end
	return self:Listar(n, { UserId = userId })
end

-- Número total de entradas registradas desde el arranque.
function AuditLogService:Contar()
	return self.Total
end

-- Entradas actualmente guardadas en el buffer.
function AuditLogService:EnBuffer()
	return math.min(self.Total, self.Tamano)
end

-- Copia de los contadores por categoría.
function AuditLogService:Contadores()
	local copia = {}
	for categoria, cantidad in pairs(self.PorCategoria) do
		copia[categoria] = cantidad
	end
	copia.Total = self.Total
	return copia
end

-- Versión plana y segura de las últimas n entradas para enviar a un panel de cliente.
function AuditLogService:ParaCliente(n, filtro)
	local lista = {}
	for _, entrada in ipairs(self:Listar(n, filtro)) do
		table.insert(lista, {
			Id = entrada.Id,
			T = entrada.T,
			Categoria = entrada.Categoria,
			UserId = entrada.UserId,
			Jugador = entrada.Jugador,
			Accion = entrada.Accion,
			Detalle = entrada.Detalle,
		})
	end
	return lista
end

-- Texto multilínea con las últimas n entradas (para la salida del servidor).
function AuditLogService:Exportar(n, filtro)
	local lineas = {}
	for _, entrada in ipairs(self:Listar(n, filtro)) do
		table.insert(lineas, self:Formatear(entrada))
	end
	return table.concat(lineas, "\n")
end

-- Vacía el buffer (los contadores totales se conservan).
function AuditLogService:Limpiar()
	self.Buffer = table.create(self.Tamano)
	self.Indice = 0
	self:Registrar("Sistema", nil, "Limpiar", "Buffer de auditoría vaciado")
end

return AuditLogService
