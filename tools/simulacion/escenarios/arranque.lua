-- Escenario: arranque del servidor con el mapa real, remotos creados, carpeta del mapa lógico, y arranque
-- de dos clientes (pantalla de carga, menú, sin GUIs duplicadas).
local Sim = require("arnes")
local T = Sim.T

return function()
	Sim.grupo("Arranque")
	local t0 = relojReal()
	Sim.nuevo({ mapa = true, studio = true })
	Sim.avanzar(10)
	print(string.format("  · Arranque: %.1f s reales (scripts), %.1f s virtuales", relojReal() - t0, Sim.ahora()))

	Sim.prueba("El servidor arranca sin errores del juego", function()
		Sim.afirmar(Sim.buscar("ReplicatedStorage/ColegioRP") ~= nil, "no existe ReplicatedStorage.ColegioRP")
	end)

	Sim.prueba("Existen todos los remotos del contrato con su tipo", function()
		local RC, err = Sim.requerirServidor("ReplicatedStorage/ColegioRP/Shared/RemoteContracts")
		if not RC then Sim.omitir("no se pudo cargar RemoteContracts: " .. tostring(err)) end
		local carpeta = Sim.buscar("ReplicatedStorage/ColegioRP/Remotes")
		Sim.afirmar(carpeta ~= nil, "no existe la carpeta Remotes")
		if not carpeta then return end
		local faltan, tipoMal = {}, {}
		for _, nombre in ipairs(RC.Nombres) do
			local def = RC.Remotos[nombre]
			local inst = carpeta:FindFirstChild(nombre)
			if not inst then faltan[#faltan + 1] = nombre
			elseif not inst:IsA(def.Tipo) then tipoMal[#tipoMal + 1] = nombre .. " (" .. inst.ClassName .. " ≠ " .. def.Tipo .. ")" end
		end
		Sim.afirmar(#faltan == 0, "faltan remotos: " .. table.concat(faltan, ", "))
		Sim.afirmar(#tipoMal == 0, "tipo incorrecto: " .. table.concat(tipoMal, ", "))
		Sim.nota(#RC.Nombres .. " remotos en el contrato")
	end)

	Sim.prueba("MapService construye Workspace.ColegioRP_Mapa", function()
		local mapa = Sim.buscar("Workspace/ColegioRP_Mapa")
		if not mapa and not Sim.servicio("MapService") then Sim.omitir("MapService aún no existe") end
		Sim.afirmar(mapa ~= nil, "no existe Workspace.ColegioRP_Mapa")
		if not mapa then return end
		for _, sub in ipairs({ "Zonas", "Spawns", "Aulas" }) do
			Sim.afirmar(mapa:FindFirstChild(sub) ~= nil, "falta ColegioRP_Mapa/" .. sub)
		end
		local MS = Sim.servicio("MapService")
		if MS and MS.ListaAulas then
			local ok, ids = Sim.enServidor(function() return MS:ListaAulas() end)
			local resumen, total = {}, 0
			if ok and type(ids) == "table" then
				for _, id in ipairs(ids) do
					local okA, aula = Sim.enServidor(function() return MS:Aula(id) end)
					local n = (okA and aula and aula.Seats) and #aula.Seats or 0
					total = total + n
					resumen[#resumen + 1] = id .. "=" .. n
				end
			end
			Sim.nota("asientos por aula (" .. total .. "): " .. table.concat(resumen, " "))
			Sim.afirmar(total > 100, "se esperaban más de 100 asientos detectados en las aulas, hay " .. total)
		end
	end)

	Sim.prueba("Inventario de MapService", function()
		local MS = Sim.servicio("MapService")
		if not MS then Sim.omitir("MapService aún no existe") end
		local ok, inv = Sim.enServidor(function() return MS:Inventario() end)
		Sim.afirmar(ok, "Inventario() falló: " .. tostring(inv))
		if ok and type(inv) == "table" and inv.Texto then print(inv.Texto) elseif ok and type(inv) == "string" then print(inv) end
	end)

	Sim.prueba("Dos clientes arrancan: carga, menú y sin GUIs duplicadas", function()
		local a = Sim.jugador("Ana", { cliente = true, dispositivo = "pc" })
		local b = Sim.jugador("Beto", { cliente = true, dispositivo = "movil" })
		Sim.avanzar(45)
		for _, j in ipairs({ a, b }) do
			local guis = j:guisColegio()
			local cuenta = {}
			for _, n in ipairs(guis) do cuenta[n] = (cuenta[n] or 0) + 1 end
			for n, c in pairs(cuenta) do Sim.afirmar(c == 1, j.nombre .. ": GUI duplicada " .. n .. " x" .. c) end
			Sim.nota(j.nombre .. ": " .. table.concat(guis, ", "))
			Sim.afirmar(j:gui("ColegioRP_Carga") == nil, j.nombre .. ": la pantalla de carga no terminó en 45 s")
		end
	end)
end
