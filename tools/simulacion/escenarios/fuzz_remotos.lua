-- Escenario P14: intentos maliciosos contra TODOS los remotos cliente→servidor del contrato.
-- Las cargas se generan a partir de los esquemas reales (Shared/RemoteContracts + Util/Validate):
-- tipos erróneos, campos inventados, textos gigantes, números extremos/NaN/inf, enums inválidos,
-- anidación profunda, Vector3 enormes y ráfagas que superan el límite de frecuencia.
-- Criterio: el servidor nunca falla (sin errores del juego) y responde { ok = false, error = ... }.
local Sim = require("arnes")
local T = Sim.T
local Vector3 = T.Vector3

local function valorValido(desc)
	if desc == nil then return nil end
	local t = desc.tipo
	if t == "string" then
		local lista = desc.enum or desc.valores
		if lista and lista[1] ~= nil then return lista[1] end
		return string.rep("a", math.max(1, desc.min or 1))
	elseif t == "number" then
		local v = desc.min or 1
		if desc.max and v > desc.max then v = desc.max end
		if desc.entero then v = math.floor(v) end
		return v
	elseif t == "boolean" then return true
	elseif t == "enum" then return desc.valores and desc.valores[1]
	elseif t == "Vector3" then return Vector3.new(0, 0, math.min(1, desc.magnitud or 1))
	elseif t == "table" then
		if desc.campos then
			local campos = desc.campos.campos or desc.campos
			local r = {}
			for k, d in pairs(campos) do if type(d) == "table" and not d.opcional then r[k] = valorValido(d) end end
			return r
		end
		return {}
	elseif t == "array" then return {}
	elseif t == "any" then return "a" end
	return nil
end

local function base(esquema)
	local r = {}
	for k, d in pairs(esquema.campos or {}) do
		if not d.opcional then r[k] = valorValido(d) end
	end
	return r
end

local function copia(t) local r = {} for k, v in pairs(t) do r[k] = v end return r end

local function anidado(n) local t = { x = 1 } for _ = 1, n do t = { x = t } end return t end

-- Genera la lista de casos maliciosos { nombre, args = {...} (argumentos crudos) }
local function casos(esquema)
	local lista = {
		{ "nil", { nil } }, { "número", { 42 } }, { "texto", { "hola" } }, { "booleano", { true } },
		{ "campo inventado", { { CampoInventado = 1 } } },
		{ "anidación 50 niveles", { { Datos = anidado(50), Texto = anidado(50) } } },
		{ "tabla con clave no texto", { { [Vector3.new(1, 2, 3)] = 1, [1] = "x" } } },
		{ "dos argumentos", { {}, { extra = true } } },
	}
	local b = base(esquema)
	for campo, d in pairs(esquema.campos or {}) do
		local t = d.tipo
		local function caso(nombre, v)
			local x = copia(b)
			x[campo] = v
			table.insert(lista, { campo .. ": " .. nombre, { x } })
		end
		if t == "string" then
			caso("texto de 10000", string.rep("x", 10000))
			caso("número en lugar de texto", 12345)
			caso("tabla en lugar de texto", { "a" })
			if d.enum or d.valores then caso("enum inválido", "NO_EXISTE_" .. campo) end
		elseif t == "number" then
			caso("1e308", 1e308)
			caso("-1e308", -1e308)
			caso("NaN", 0 / 0)
			caso("infinito", math.huge)
			caso("texto en lugar de número", "1; DROP")
			if d.entero then caso("no entero", 1.5) end
		elseif t == "enum" then
			caso("enum inválido", "NO_EXISTE")
			caso("enum numérico", 99999)
		elseif t == "Vector3" then
			caso("magnitud 1e9", Vector3.new(1e9, 1e9, 1e9))
			caso("NaN", Vector3.new(0 / 0, 0, 0))
		elseif t == "boolean" then
			caso("texto en lugar de booleano", "true")
		elseif t == "table" then
			caso("anidación 50", anidado(50))
			caso("texto en lugar de tabla", "x")
		elseif t == "array" then
			local grande = {}
			for i = 1, 5000 do grande[i] = i end
			caso("5000 elementos", grande)
			caso("texto en lugar de lista", "x")
		end
	end
	return lista
end

return function()
	Sim.grupo("P14 · Fuzzing de remotos")
	Sim.nuevo({ mapa = true, studio = true })
	Sim.avanzar(8)
	local RC, err = Sim.requerirServidor("ReplicatedStorage/ColegioRP/Shared/RemoteContracts")
	if not RC then
		Sim.prueba("Cargar RemoteContracts", function() Sim.afirmar(false, tostring(err)) end)
		return
	end
	local jug = Sim.jugador("Atacante")
	Sim.avanzar(3)

	local totalCasos, aceptados, erroresLlamada = 0, {}, {}
	for _, nombre in ipairs(RC.Nombres) do
		local def = RC.Remotos[nombre]
		if def.Direccion == "C2S" then
			Sim.prueba(nombre .. " rechaza cargas maliciosas", function()
				Sim.toleraErrores()
				local erroresAntes = #Sim.P.errores
				local ventana = (def.Limite and def.Limite.VentanaSeg or 1) + 0.5
				local listaCasos = casos(def.Esquema or { campos = {} })
				local fallos = {}
				for _, c in ipairs(listaCasos) do
					totalCasos = totalCasos + 1
					local okLlamada, resp
					if def.Tipo == "RemoteFunction" then
						okLlamada, resp = jug:invocarCrudo(nombre, table.unpack(c[2], 1, 2))
						if okLlamada and type(resp) == "table" and type(resp.error) == "string" and resp.error:find("limite", 1, true) then
							Sim.avanzar(ventana, 0.5)
							okLlamada, resp = jug:invocarCrudo(nombre, table.unpack(c[2], 1, 2))
						end
						if not okLlamada then
							fallos[#fallos + 1] = c[1] .. " → la llamada lanzó error: " .. tostring(resp)
						elseif type(resp) ~= "table" then
							fallos[#fallos + 1] = c[1] .. " → respuesta no tabla: " .. tostring(resp)
						elseif resp.ok ~= false then
							aceptados[#aceptados + 1] = nombre .. " / " .. c[1]
							fallos[#fallos + 1] = c[1] .. " → ACEPTADO (ok=" .. tostring(resp.ok) .. ")"
						end
					else
						okLlamada, resp = jug:disparar(nombre, table.unpack(c[2], 1, 2))
						if not okLlamada then fallos[#fallos + 1] = c[1] .. " → FireServer lanzó: " .. tostring(resp) end
					end
				end
				local nuevos = 0
				for i = erroresAntes + 1, #Sim.P.errores do
					if Sim.P.errores[i].clase == "JUEGO" then nuevos = nuevos + 1 end
				end
				Sim.afirmar(nuevos == 0, nuevos .. " error(es) del servidor provocados por las cargas")
				Sim.afirmar(#fallos == 0, table.concat(fallos, "; "))
				Sim.nota(#listaCasos .. " casos")
				Sim.avanzar(ventana, 0.5)
			end)
		end
	end

	Sim.prueba("Ráfaga: el límite de frecuencia rechaza el exceso", function()
		local rechazosLimite = 0
		for _ = 1, 30 do
			local ok, resp = jug:invocarCrudo("StateSnapshot", {})
			if ok and type(resp) == "table" and type(resp.error) == "string" and resp.error:find("limite", 1, true) then rechazosLimite = rechazosLimite + 1 end
		end
		Sim.afirmar(rechazosLimite > 0, "30 StateSnapshot seguidos sin ningún rechazo por límite")
		Sim.nota(rechazosLimite .. "/30 rechazados por límite")
	end)

	Sim.prueba("Los rechazos quedan en la auditoría y marcan al jugador como sospechoso", function()
		local AL = Sim.servicio("AuditLogService")
		if not AL then Sim.omitir("AuditLogService no disponible") end
		local ok, lista = Sim.enServidor(function() return AL:Listar(500) end)
		Sim.afirmar(ok and type(lista) == "table" and #lista > 0, "AuditLog vacío tras los ataques")
		if ok and type(lista) == "table" then Sim.nota(#lista .. " entradas en AuditLog") end
		Sim.afirmar(jug.inst:GetAttribute("Sospechoso") == true, "el atacante no quedó marcado como Sospechoso")
	end)

	print(string.format("  · %d casos maliciosos enviados", totalCasos))
	if #aceptados > 0 then
		print("  · CARGAS ACEPTADAS POR EL SERVIDOR (revisar):")
		for _, a in ipairs(aceptados) do print("      " .. a) end
	end
end
