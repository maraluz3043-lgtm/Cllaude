--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.NotebookService
	Tipo: ModuleScript
	Cuaderno personal (docs/ARQUITECTURA.md §4 y §6, prueba P6). Vive en Perfil.Cuaderno (DataService) con
	páginas { Materia, Texto, Actualizado, Compartida, TextoFiltrado }. Handler de NotebookUpdate:
	Guardar (página 1..MaxPaginas, texto <= MaxCaracteresPagina, materia válida, máx. 1 guardado cada 10 s por
	jugador), Cargar (cuaderno completo), Compartir (alterna; al compartir filtra el texto con TextService para
	terceros y guarda TextoFiltrado), Vaciar (página o cuaderno) y Ver (solo el docente con sesión abierta, sobre
	un alumno presente en su aula y una página compartida; devuelve solo TextoFiltrado). AgregarEntrada lo usa
	PCService (procesador de texto). Sin DataService, el cuaderno vive solo en memoria de la sesión.
]]

local Players = game:GetService("Players")
local TextService = game:GetService("TextService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local TimetableDefinitions = require(Shared:WaitForChild("TimetableDefinitions"))
local Util = Shared:WaitForChild("Util")
local Signal = require(Util:WaitForChild("Signal"))
local Maid = require(Util:WaitForChild("Maid"))

local NotebookService = {}
NotebookService.Nombre = "NotebookService"

local PREFIJO = "[ColegioRP][NotebookService]"
local CUADERNO = Config.Cuaderno or {}

NotebookService.MaxPaginas = tonumber(CUADERNO.MaxPaginas) or 20
NotebookService.MaxCaracteresPagina = tonumber(CUADERNO.MaxCaracteresPagina) or 1200
NotebookService.AutoguardadoSeg = tonumber(CUADERNO.AutoguardadoSeg) or 45
NotebookService.MinIntervaloGuardadoSeg = tonumber(CUADERNO.MinIntervaloGuardadoSeg) or 10
NotebookService.CooldownCompartirSeg = 3
NotebookService.CooldownVaciarSeg = 2
NotebookService.EsperaPerfilSeg = 5 -- Espera máxima al perfil en "Cargar" (el perfil puede estar cargando).
NotebookService.MateriaPorDefecto = "MAT"
NotebookService.TituloPorDefecto = "Mi cuaderno"

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function esJugador(valor)
	return typeof(valor) == "Instance" and valor:IsA("Player")
end

-- Quita caracteres de control (conserva saltos de línea; tabulador -> espacio) y recorta a 'maximo' caracteres.
local function sanearTexto(texto, maximo)
	if typeof(texto) ~= "string" or utf8.len(texto) == nil then
		return nil
	end
	local limpio = string.gsub(texto, "%c", function(c)
		if c == "\n" then
			return "\n"
		end
		if c == "\t" then
			return " "
		end
		return ""
	end)
	local n = utf8.len(limpio)
	if n == nil then
		return nil
	end
	if n > maximo then
		local corte = utf8.offset(limpio, maximo + 1)
		if corte then
			limpio = string.sub(limpio, 1, corte - 1)
		end
	end
	return limpio
end

local function recortar(texto)
	local resultado = string.gsub(texto or "", "^%s+", "")
	resultado = string.gsub(resultado, "%s+$", "")
	return resultado
end

local function longitud(texto)
	return utf8.len(texto or "") or #(texto or "")
end

-- Filtra con TextService para terceros (broadcast) o para un usuario concreto. Devuelve texto | nil.
local function filtrar(texto, deUserId, paraUserId)
	local okFiltro, resultado = pcall(function()
		return TextService:FilterStringAsync(texto, deUserId, Enum.TextFilterContext.PublicChat)
	end)
	if not okFiltro or resultado == nil then
		return nil
	end
	local okTexto, filtrado = pcall(function()
		if paraUserId then
			return resultado:GetNonChatStringForUserAsync(paraUserId)
		end
		return resultado:GetNonChatStringForBroadcastAsync()
	end)
	if not okTexto or typeof(filtrado) ~= "string" then
		return nil
	end
	return filtrado
end

local function rechazo(codigo, mensaje, extra)
	return { ok = false, error = "rechazado:" .. tostring(codigo), mensaje = mensaje, datos = extra }
end

local function exito(datos)
	return { ok = true, datos = datos or {} }
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function NotebookService:Init(registro)
	self.registro = registro
	self.UltimoGuardado = {} -- userId -> os.clock() del último "Guardar" aceptado
	self.UltimaAccion = {} -- userId -> { accion -> os.clock() }
	self.Memoria = {} -- userId -> cuaderno (solo si no hay DataService)
	self.CuadernoActualizado = Signal.new() -- (player, pagina|nil)
	self.maid = Maid.new()
end

function NotebookService:Start()
	local RemoteService = self.registro.Get("RemoteService")
	if RemoteService and typeof(RemoteService.Registrar) == "function" then
		RemoteService:Registrar("NotebookUpdate", function(player, datos)
			return self:Manejar(player, datos)
		end)
	else
		warn(PREFIJO .. " RemoteService no disponible: NotebookUpdate no tendrá handler.")
	end
	if not self.registro.Get("DataService") then
		warn(PREFIJO .. " DataService no disponible: los cuadernos solo se guardan en memoria durante la sesión.")
	end
	self.maid:GiveTask(Players.PlayerRemoving:Connect(function(player)
		local userId = player.UserId
		self.UltimoGuardado[userId] = nil
		self.UltimaAccion[userId] = nil
		self.Memoria[userId] = nil
	end))
end

---------------------------------------------------------------------------------------------------
-- Acceso a otros servicios
---------------------------------------------------------------------------------------------------
function NotebookService:Llamar(nombre, metodo, ...)
	local servicio = self.registro and self.registro.Get(nombre)
	if not servicio or typeof(servicio[metodo]) ~= "function" then
		return false
	end
	local resultado = table.pack(pcall(servicio[metodo], servicio, ...))
	if not resultado[1] then
		warn(PREFIJO .. " " .. nombre .. ":" .. metodo .. " falló: " .. tostring(resultado[2]))
		return false
	end
	return true, resultado[2], resultado[3]
end

function NotebookService:Auditar(player, accion, detalle)
	self:Llamar("AuditLogService", "Registrar", "Clase", player, accion, detalle)
end

function NotebookService:Enviar(player, tipo, datos)
	local RemoteService = self.registro.Get("RemoteService")
	if RemoteService and esJugador(player) then
		return RemoteService:Enviar(player, tipo, datos)
	end
	return false
end

function NotebookService:MateriaActual()
	local ok, snapshot = self:Llamar("SchoolDayService", "Snapshot")
	if ok and typeof(snapshot) == "table" and TimetableDefinitions.ExisteMateria(snapshot.Materia) then
		return snapshot.Materia
	end
	return nil
end

function NotebookService:EsperaRestante(player, accion, segundos)
	local porJugador = self.UltimaAccion[player.UserId]
	local ultimo = porJugador and porJugador[accion]
	if not ultimo then
		return 0
	end
	return math.max(0, segundos - (os.clock() - ultimo))
end

function NotebookService:MarcarAccion(player, accion)
	local porJugador = self.UltimaAccion[player.UserId]
	if not porJugador then
		porJugador = {}
		self.UltimaAccion[player.UserId] = porJugador
	end
	porJugador[accion] = os.clock()
end

---------------------------------------------------------------------------------------------------
-- Cuaderno del jugador
---------------------------------------------------------------------------------------------------
local function cuadernoNuevo(materia)
	return {
		Titulo = NotebookService.TituloPorDefecto,
		Paginas = { { Materia = materia or NotebookService.MateriaPorDefecto, Texto = "", Actualizado = 0 } },
	}
end

-- Garantiza la estructura mínima (título y al menos una página válida; páginas contiguas).
function NotebookService:Asegurar(cuaderno)
	if typeof(cuaderno.Titulo) ~= "string" or cuaderno.Titulo == "" then
		cuaderno.Titulo = self.TituloPorDefecto
	end
	if typeof(cuaderno.Paginas) ~= "table" then
		cuaderno.Paginas = {}
	end
	local limpias = {}
	for i = 1, math.min(#cuaderno.Paginas, self.MaxPaginas) do
		local pagina = cuaderno.Paginas[i]
		if typeof(pagina) == "table" then
			if typeof(pagina.Texto) ~= "string" then
				pagina.Texto = ""
			end
			if not TimetableDefinitions.ExisteMateria(pagina.Materia) then
				pagina.Materia = self.MateriaPorDefecto
			end
			pagina.Actualizado = tonumber(pagina.Actualizado) or 0
			table.insert(limpias, pagina)
		end
	end
	if #limpias == 0 then
		table.insert(limpias, { Materia = self:MateriaActual() or self.MateriaPorDefecto, Texto = "", Actualizado = 0 })
	end
	cuaderno.Paginas = limpias
	return cuaderno
end

-- Devuelve el cuaderno (tabla viva del perfil) o nil si el perfil aún no está cargado.
function NotebookService:Cuaderno(player, esperar)
	if not esJugador(player) then
		return nil
	end
	local DataService = self.registro.Get("DataService")
	if not DataService then
		local enMemoria = self.Memoria[player.UserId]
		if not enMemoria then
			enMemoria = cuadernoNuevo(self:MateriaActual())
			self.Memoria[player.UserId] = enMemoria
		end
		return self:Asegurar(enMemoria)
	end
	local ok, perfil = self:Llamar("DataService", "Obtener", player)
	if (not ok or typeof(perfil) ~= "table") and esperar then
		ok, perfil = self:Llamar("DataService", "EsperarPerfil", player, self.EsperaPerfilSeg)
	end
	if not ok or typeof(perfil) ~= "table" then
		return nil
	end
	if typeof(perfil.Cuaderno) ~= "table" then
		perfil.Cuaderno = cuadernoNuevo(self:MateriaActual())
	end
	return self:Asegurar(perfil.Cuaderno)
end

function NotebookService:Marcar(player)
	self:Llamar("DataService", "Marcar", player)
end

-- Crea páginas vacías hasta 'numero' (las páginas deben ser contiguas para el saneamiento del perfil).
function NotebookService:AsegurarPaginas(cuaderno, numero, materia)
	while #cuaderno.Paginas < numero do
		table.insert(cuaderno.Paginas, { Materia = materia or self.MateriaPorDefecto, Texto = "", Actualizado = 0 })
	end
	return cuaderno.Paginas[numero]
end

-- Representación para el propio dueño (sin TextoFiltrado).
function NotebookService:Exportar(cuaderno, player)
	local paginas = {}
	for i, pagina in ipairs(cuaderno.Paginas) do
		table.insert(paginas, {
			Pagina = i,
			Materia = pagina.Materia,
			Texto = pagina.Texto,
			Actualizado = pagina.Actualizado,
			Compartida = pagina.Compartida == true,
		})
	end
	local espera = 0
	if player then
		local ultimo = self.UltimoGuardado[player.UserId]
		if ultimo then
			espera = math.max(0, self.MinIntervaloGuardadoSeg - (os.clock() - ultimo))
		end
	end
	return {
		Titulo = cuaderno.Titulo,
		Paginas = paginas,
		MaxPaginas = self.MaxPaginas,
		MaxCaracteres = self.MaxCaracteresPagina,
		AutoguardadoSeg = self.AutoguardadoSeg,
		MinIntervaloGuardadoSeg = self.MinIntervaloGuardadoSeg,
		EsperaGuardado = espera,
		MateriaActual = self:MateriaActual(),
	}
end

---------------------------------------------------------------------------------------------------
-- Entrada del remoto
---------------------------------------------------------------------------------------------------
function NotebookService:Manejar(player, datos)
	if not esJugador(player) or typeof(datos) ~= "table" then
		return rechazo("datos", "Petición inválida.")
	end
	local accion = datos.Accion
	if accion == "Guardar" then
		return self:Guardar(player, datos)
	elseif accion == "Cargar" then
		return self:Cargar(player)
	elseif accion == "Compartir" then
		return self:Compartir(player, datos)
	elseif accion == "Vaciar" then
		return self:Vaciar(player, datos)
	elseif accion == "Ver" then
		return self:Ver(player, datos)
	end
	return rechazo("accion_desconocida", "Acción de cuaderno desconocida.")
end

function NotebookService:Guardar(player, d)
	local userId = player.UserId
	local ultimo = self.UltimoGuardado[userId]
	if ultimo then
		local restante = self.MinIntervaloGuardadoSeg - (os.clock() - ultimo)
		if restante > 0 then
			return rechazo("cooldown", string.format("Espera %d s para volver a guardar.", math.ceil(restante)),
				{ Reintentar = restante })
		end
	end
	local numero = tonumber(d.Pagina) or 1
	if numero < 1 or numero > self.MaxPaginas or math.floor(numero) ~= numero then
		return rechazo("pagina", "La página debe estar entre 1 y " .. self.MaxPaginas .. ".")
	end
	if d.Texto == nil then
		return rechazo("texto", "Falta el texto de la página.")
	end
	local texto = sanearTexto(d.Texto, self.MaxCaracteresPagina)
	if texto == nil then
		return rechazo("texto", "El texto contiene caracteres no válidos.")
	end
	local materia = nil
	if d.Materia ~= nil then
		if not TimetableDefinitions.ExisteMateria(d.Materia) then
			return rechazo("materia", "Materia desconocida.")
		end
		materia = d.Materia
	end
	local cuaderno = self:Cuaderno(player, false)
	if not cuaderno then
		return rechazo("sin_perfil", "Tu cuaderno aún se está cargando; inténtalo en unos segundos.")
	end

	-- El intervalo cuenta desde ahora (antes de cualquier espera por filtrado).
	self.UltimoGuardado[userId] = os.clock()
	local pagina = self:AsegurarPaginas(cuaderno, numero, materia or self:MateriaActual())
	local cambio = pagina.Texto ~= texto
	pagina.Texto = texto
	if materia then
		pagina.Materia = materia
	end
	local t = os.time()
	pagina.Actualizado = t

	-- Una página compartida que cambia se vuelve a filtrar; si no se puede, deja de estar compartida.
	local avisoCompartida = nil
	if pagina.Compartida and cambio then
		if recortar(texto) == "" then
			pagina.Compartida = false
			pagina.TextoFiltrado = nil
			avisoCompartida = "La página quedó vacía y dejó de estar compartida."
		else
			local filtrado = filtrar(texto, userId, nil)
			if filtrado and pagina.Texto == texto then
				pagina.TextoFiltrado = filtrado
			elseif not filtrado then
				pagina.Compartida = false
				pagina.TextoFiltrado = nil
				avisoCompartida = "No se pudo filtrar la página modificada; dejó de estar compartida."
			end
		end
	end
	self:Marcar(player)
	self.CuadernoActualizado:Fire(player, numero)
	return exito({
		Guardado = true,
		Actualizado = t,
		Pagina = numero,
		Materia = pagina.Materia,
		Compartida = pagina.Compartida == true,
		Paginas = #cuaderno.Paginas,
		Aviso = avisoCompartida,
		ProximoGuardadoSeg = self.MinIntervaloGuardadoSeg,
	})
end

function NotebookService:Cargar(player)
	local cuaderno = self:Cuaderno(player, true)
	if not cuaderno then
		return rechazo("sin_perfil", "Tu cuaderno aún se está cargando; inténtalo en unos segundos.")
	end
	return exito(self:Exportar(cuaderno, player))
end

function NotebookService:Compartir(player, d)
	local espera = self:EsperaRestante(player, "Compartir", self.CooldownCompartirSeg)
	if espera > 0 then
		return rechazo("cooldown", string.format("Espera %d s.", math.ceil(espera)))
	end
	local numero = tonumber(d.Pagina) or 1
	local cuaderno = self:Cuaderno(player, false)
	if not cuaderno then
		return rechazo("sin_perfil", "Tu cuaderno aún se está cargando.")
	end
	local pagina = cuaderno.Paginas[numero]
	if not pagina then
		return rechazo("pagina", "Esa página no existe todavía. Escribe y guarda primero.")
	end
	self:MarcarAccion(player, "Compartir")
	if pagina.Compartida then
		pagina.Compartida = false
		pagina.TextoFiltrado = nil
		self:Marcar(player)
		return exito({ Compartida = false, Pagina = numero })
	end
	local texto = pagina.Texto or ""
	if recortar(texto) == "" then
		return rechazo("vacia", "La página está vacía; escribe algo antes de compartirla.")
	end
	local filtrado = filtrar(texto, player.UserId, nil)
	if not filtrado then
		return rechazo("filtro", "No se pudo filtrar la página; no se compartió. Inténtalo de nuevo.")
	end
	if pagina.Texto ~= texto then
		return rechazo("cambio", "La página cambió mientras se compartía; inténtalo de nuevo.")
	end
	pagina.Compartida = true
	pagina.TextoFiltrado = filtrado
	self:Marcar(player)
	self:Auditar(player, "CompartirCuaderno", "página " .. numero)
	return exito({ Compartida = true, Pagina = numero })
end

function NotebookService:Vaciar(player, d)
	local espera = self:EsperaRestante(player, "Vaciar", self.CooldownVaciarSeg)
	if espera > 0 then
		return rechazo("cooldown", string.format("Espera %d s.", math.ceil(espera)))
	end
	local cuaderno = self:Cuaderno(player, false)
	if not cuaderno then
		return rechazo("sin_perfil", "Tu cuaderno aún se está cargando.")
	end
	self:MarcarAccion(player, "Vaciar")
	local t = os.time()
	local numero = tonumber(d.Pagina)
	if numero then
		local pagina = cuaderno.Paginas[numero]
		if not pagina then
			return rechazo("pagina", "Esa página no existe.")
		end
		pagina.Texto = ""
		pagina.Compartida = false
		pagina.TextoFiltrado = nil
		pagina.Actualizado = t
	else
		cuaderno.Paginas = { { Materia = self:MateriaActual() or self.MateriaPorDefecto, Texto = "", Actualizado = t } }
	end
	self:Marcar(player)
	self.CuadernoActualizado:Fire(player, numero)
	return exito({ Vaciado = true, Pagina = numero, Paginas = #cuaderno.Paginas, Actualizado = t })
end

-- "Ver": solo el docente con sesión abierta, sobre un alumno presente en su aula y páginas compartidas.
function NotebookService:Ver(player, d)
	local objetivoId = tonumber(d.ObjetivoUserId)
	local objetivo = objetivoId and Players:GetPlayerByUserId(objetivoId) or nil
	if not objetivo or objetivo == player then
		return rechazo("objetivo", "Elige a un estudiante conectado.")
	end
	local ClassroomService = self.registro.Get("ClassroomService")
	local sesion = nil
	if ClassroomService and typeof(ClassroomService.SesionDeJugador) == "function" then
		local ok, resultado = pcall(ClassroomService.SesionDeJugador, ClassroomService, player)
		if ok and typeof(resultado) == "table" then
			sesion = resultado
		end
	end
	if not sesion or sesion.TeacherUserId ~= player.UserId or sesion.State ~= "Abierta" then
		self:Auditar(player, "Rechazo:VerCuaderno", "sin sesión propia · objetivo " .. tostring(objetivoId))
		return rechazo("sin_sesion", "Necesitas una sesión de clase abierta para revisar cuadernos.")
	end
	local presente = false
	local ok, esta = self:Llamar("RoomService", "EstaEn", objetivo, sesion.RoomId)
	if ok then
		presente = esta == true
	elseif ClassroomService and typeof(ClassroomService.EstaEnAula) == "function" then
		local okAula, estaAula = pcall(ClassroomService.EstaEnAula, ClassroomService, objetivo, sesion.RoomId)
		presente = okAula and estaAula == true
	end
	if not presente then
		self:Auditar(player, "Rechazo:VerCuaderno", "alumno ausente · " .. objetivo.Name .. " · " .. sesion.RoomId)
		return rechazo("ausente", objetivo.DisplayName .. " no está en tu aula.")
	end
	local cuaderno = self:Cuaderno(objetivo, false)
	if not cuaderno then
		return rechazo("sin_perfil", "El cuaderno de " .. objetivo.DisplayName .. " aún se está cargando.")
	end

	local numero = tonumber(d.Pagina)
	local candidatas = {}
	if numero then
		local pagina = cuaderno.Paginas[numero]
		if not pagina or not pagina.Compartida then
			self:Auditar(player, "Rechazo:VerCuaderno", "página no compartida · " .. objetivo.Name .. " · " .. tostring(numero))
			return rechazo("no_compartida", "Esa página no está compartida.")
		end
		table.insert(candidatas, numero)
	else
		for i, pagina in ipairs(cuaderno.Paginas) do
			if pagina.Compartida then
				table.insert(candidatas, i)
			end
		end
	end

	local paginas = {}
	local modificado = false
	for _, i in ipairs(candidatas) do
		local pagina = cuaderno.Paginas[i]
		local texto = pagina.TextoFiltrado
		if typeof(texto) ~= "string" then
			-- Tras recargar el perfil TextoFiltrado no se conserva: se filtra de nuevo (nunca se muestra sin filtrar).
			local original = pagina.Texto or ""
			texto = filtrar(original, objetivo.UserId, nil)
			-- El filtrado cede: solo se guarda en caché si la página no cambió ni dejó de compartirse mientras tanto.
			if texto and pagina.Texto == original and pagina.Compartida then
				pagina.TextoFiltrado = texto
				modificado = true
			end
		end
		if texto then
			table.insert(paginas, { Pagina = i, Materia = pagina.Materia, Texto = texto, Actualizado = pagina.Actualizado })
		end
	end
	if modificado then
		self:Marcar(objetivo)
	end
	if #paginas > 0 then
		self:Enviar(objetivo, "Notificacion", {
			Texto = "Tu docente revisó tu cuaderno compartido.", Nivel = "info", Duracion = 4,
		})
	end
	self:Auditar(player, "VerCuaderno", objetivo.Name .. " · " .. #paginas .. " páginas · " .. sesion.RoomId)
	return exito({
		ObjetivoUserId = objetivo.UserId,
		Nombre = objetivo.DisplayName,
		Titulo = cuaderno.Titulo,
		Paginas = paginas,
		SinCompartidas = #paginas == 0,
	})
end

---------------------------------------------------------------------------------------------------
-- API para otros servicios
---------------------------------------------------------------------------------------------------

-- Cuaderno completo del jugador (mismo formato que "Cargar") o nil si el perfil no está listo.
function NotebookService:Snapshot(player)
	local cuaderno = self:Cuaderno(player, false)
	if not cuaderno then
		return nil
	end
	return self:Exportar(cuaderno, player)
end

-- Añade texto al cuaderno (p. ej. desde el procesador del PC). Usa la última página si es de la misma materia
-- y cabe; si no, la primera vacía o una nueva. Devuelve true, numeroDePagina | false, motivo.
function NotebookService:AgregarEntrada(player, materia, texto)
	local cuaderno = self:Cuaderno(player, false)
	if not cuaderno then
		return false, "sin_perfil"
	end
	local limpio = sanearTexto(texto, self.MaxCaracteresPagina)
	if not limpio or recortar(limpio) == "" then
		return false, "texto_vacio"
	end
	limpio = recortar(limpio)
	if not TimetableDefinitions.ExisteMateria(materia) then
		materia = self:MateriaActual() or "TEC"
	end

	local numero = nil
	local ultima = cuaderno.Paginas[#cuaderno.Paginas]
	if ultima and ultima.Materia == materia and ultima.Texto ~= ""
		and longitud(ultima.Texto) + 2 + longitud(limpio) <= self.MaxCaracteresPagina then
		numero = #cuaderno.Paginas
	end
	if not numero then
		for i, pagina in ipairs(cuaderno.Paginas) do
			if recortar(pagina.Texto or "") == "" then
				numero = i
				break
			end
		end
	end
	if not numero then
		if #cuaderno.Paginas >= self.MaxPaginas then
			return false, "cuaderno_lleno"
		end
		numero = #cuaderno.Paginas + 1
	end
	local pagina = self:AsegurarPaginas(cuaderno, numero, materia)
	if recortar(pagina.Texto or "") == "" then
		pagina.Texto = limpio
		pagina.Materia = materia
	else
		pagina.Texto = sanearTexto(pagina.Texto .. "\n\n" .. limpio, self.MaxCaracteresPagina) or pagina.Texto
	end
	pagina.Actualizado = os.time()
	local dejoDeCompartirse = false
	if pagina.Compartida then
		pagina.Compartida = false
		pagina.TextoFiltrado = nil
		dejoDeCompartirse = true
	end
	self:Marcar(player)
	self.CuadernoActualizado:Fire(player, numero)
	self:Enviar(player, "Aula", { Sub = "Cuaderno", Pagina = numero, Actualizado = pagina.Actualizado, Origen = "PC" })
	local aviso = "Se guardó en tu cuaderno (página " .. numero .. ")."
	if dejoDeCompartirse then
		aviso = aviso .. " La página dejó de estar compartida."
	end
	self:Enviar(player, "Notificacion", { Texto = aviso, Nivel = "exito", Duracion = 4 })
	return true, numero
end

return NotebookService
