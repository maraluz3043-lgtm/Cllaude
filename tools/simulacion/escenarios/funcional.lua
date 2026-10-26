-- Escenario funcional (P3, P4, P6, P7, P8, P9, P14 de permisos): flujos de juego con jugadores simulados.
local Sim = require("arnes")
local V3 = Sim.T.Vector3

local function ok(r) return type(r) == "table" and r.ok == true end
local function txt(r) return type(r) == "table" and tostring(r.error) or tostring(r) end

return function()
	Sim.grupo("Funcional")
	Sim.nuevo({ mapa = true, studio = true })
	Sim.avanzar(8)
	local dir = Sim.jugador("Directora")
	local prof = Sim.jugador("Profe")
	local prof2 = Sim.jugador("Profe2")
	local est = Sim.jugador("Alumno")
	local est2 = Sim.jugador("Alumna")
	Sim.avanzar(5)

	Sim.prueba("P3 cargos: unirse y conservar el cargo al reaparecer", function()
		local _, r = dir:invocar("RequestJoinRole", { Cargo = "Director" })
		Sim.afirmar(ok(r), "Director: " .. txt(r))
		local _, r2 = prof:invocar("RequestJoinRole", { Cargo = "ProfesorTitular" })
		Sim.afirmar(ok(r2), "Profesor: " .. txt(r2))
		Sim.avanzar(6)
		local _, r3 = prof2:invocar("RequestJoinRole", { Cargo = "ProfesorTitular" })
		Sim.afirmar(ok(r3), "Profesor2: " .. txt(r3))
		Sim.afirmar(est:atributo("Cargo") == "Estudiante", "cargo por defecto: " .. tostring(est:atributo("Cargo")))
		est:morir()
		Sim.avanzar(8)
		Sim.afirmar(est:atributo("Cargo") == "Estudiante" and est:personaje() ~= nil, "no reapareció con su cargo")
		Sim.nota("salón docente: " .. tostring(prof:atributo("Salon")) .. " / " .. tostring(prof2:atributo("Salon")))
	end)

	Sim.prueba("P8 snapshot y jornada", function()
		local _, r = est:invocar("StateSnapshot", {})
		Sim.afirmar(ok(r) and r.datos and r.datos.Jornada, "StateSnapshot: " .. txt(r))
		local _, r2 = est:invocar("JornadaControl", { Accion = "Saltar" })
		Sim.afirmar(type(r2) == "table" and r2.ok == false, "un estudiante pudo controlar la jornada")
	end)

	Sim.prueba("P6 cuaderno: guardar, cargar y privacidad", function()
		local _, r = est:invocar("NotebookUpdate", { Accion = "Guardar", Pagina = 1, Materia = "MAT", Texto = "Apuntes de fracciones" })
		Sim.afirmar(ok(r), "Guardar: " .. txt(r))
		Sim.avanzar(11)
		local _, r2 = est:invocar("NotebookUpdate", { Accion = "Cargar" })
		Sim.afirmar(ok(r2), "Cargar: " .. txt(r2))
		local _, r3 = est2:invocar("NotebookUpdate", { Accion = "Ver", ObjetivoUserId = est.userId })
		Sim.afirmar(type(r3) == "table" and r3.ok == false, "otro alumno pudo ver el cuaderno")
	end)

	Sim.prueba("P4/P7 aulas paralelas, actividad, respuesta única y tablero", function()
		local s1, s2 = prof:atributo("Salon"), prof2:atributo("Salon")
		if not s1 or not s2 or s1 == s2 then Sim.omitir("los docentes no tienen aulas distintas: " .. tostring(s1) .. "/" .. tostring(s2)) end
		for _ = 1, 8 do
			local _, sn = est:invocar("StateSnapshot", {})
			local e = ok(sn) and sn.datos.Jornada and sn.datos.Jornada.Estado or ""
			if e:sub(1, 5) == "CLASE" then break end
			Sim.avanzar(6)
			dir:invocar("JornadaControl", { Accion = "Saltar" })
		end
		local _, a = prof:invocar("RequestClassAction", { Accion = "AbrirSesion", Salon = s1, Datos = {} })
		Sim.afirmar(ok(a), "AbrirSesion 1: " .. txt(a))
		local _, b = prof2:invocar("RequestClassAction", { Accion = "AbrirSesion", Salon = s2, Datos = {} })
		Sim.afirmar(ok(b), "AbrirSesion 2: " .. txt(b))
		local _, x = est:invocar("RequestClassAction", { Accion = "AbrirSesion", Salon = s1, Datos = {} })
		Sim.afirmar(type(x) == "table" and x.ok == false, "un estudiante abrió una sesión")
		local MS = Sim.servicio("MapService")
		local z = MS and MS:Zona(s1)
		if not z then Sim.omitir("sin zona del aula") end
		est:mover(z.Centro)
		est2:mover(MS:Zona(s2).Centro)
		Sim.avanzar(3)
		est:limpiarEventos() est2:limpiarEventos()
		local _, c = prof:invocar("RequestClassAction", { Accion = "CrearActividad", Salon = s1, Datos = { Tipo = "Opciones", Prompt = "2+2", Options = { "3", "4" }, Correcta = 2, Segundos = 60 } })
		Sim.afirmar(ok(c), "CrearActividad: " .. txt(c))
		Sim.avanzar(1)
		Sim.afirmar(#est:eventos("Aula") > 0, "el alumno del aula 1 no recibió la actividad")
		local fuga = false
		for _, e in ipairs(est2:eventos("Aula")) do if type(e.datos) == "table" and e.datos.Sub == "Actividad" then fuga = true end end
		Sim.afirmar(not fuga, "P4: la actividad del aula 1 llegó al aula 2")
		local act = c and c.datos and (c.datos.ActivityId or c.datos.Id or (c.datos.Actividad and c.datos.Actividad.ActivityId))
		local _, r1 = est:invocar("RequestClassAction", { Accion = "Responder", Salon = s1, Datos = { Indice = 2 } })
		Sim.afirmar(ok(r1), "Responder: " .. txt(r1))
		Sim.avanzar(1)
		local _, r2 = est:invocar("RequestClassAction", { Accion = "Responder", Salon = s1, Datos = { Indice = 2 } })
		Sim.afirmar(type(r2) == "table" and r2.ok == false, "P7: respondió dos veces")
		local _, r3 = est2:invocar("RequestClassAction", { Accion = "Responder", Salon = s1, Datos = { Indice = 1 } })
		Sim.afirmar(type(r3) == "table" and r3.ok == false, "P5: alumno de otra aula respondió")
		local _, w1 = prof:invocar("BoardAction", { Accion = "Escribir", Salon = s1, Texto = "Fracciones" })
		Sim.afirmar(ok(w1), "tablero docente: " .. txt(w1))
		local _, w2 = est:invocar("BoardAction", { Accion = "Escribir", Salon = s1, Texto = "hola" })
		Sim.afirmar(type(w2) == "table" and w2.ok == false, "alumno escribió en el tablero sin turno")
	end)

	Sim.prueba("P9 comida gratis y compra única", function()
		local _, s = dir:invocar("JornadaControl", { Accion = "Saltar" })
		for _ = 1, 6 do
			local _, sn = est:invocar("StateSnapshot", {})
			local e = ok(sn) and sn.datos.Jornada and sn.datos.Jornada.Estado
			if e == "DESCANSO" or e == "ALMUERZO" then break end
			Sim.avanzar(6)
			dir:invocar("JornadaControl", { Accion = "Saltar" })
		end
		local EC = Sim.servicio("EconomyService")
		local saldo0 = EC and EC:Saldo(est.inst)
		local MS = Sim.servicio("MapService")
		local coc = MS and MS:Cocina()
		if coc and coc.Reclamo then est:mover(coc.Reclamo.Position) end
		local _, f = est:invocar("FoodAction", { Accion = "Reclamar" })
		Sim.nota("reclamo: " .. (ok(f) and "ok" or txt(f)))
		Sim.afirmar(EC:Saldo(est.inst) == saldo0, "la comida cambió el saldo")
		local caf = MS and MS:Cafeteria()
		if caf and caf.Mostrador then est:mover(caf.Mostrador.Position) end
		Sim.avanzar(4)
		local s1 = EC:Saldo(est.inst)
		local _, p = est:invocar("CafeteriaPurchase", { ProductoId = "EMPANADA", Cantidad = 1 })
		Sim.afirmar(ok(p), "compra: " .. txt(p))
		local s2 = EC:Saldo(est.inst)
		Sim.nota("saldo " .. tostring(s1) .. " -> " .. tostring(s2))
		Sim.afirmar(s2 < s1, "la compra no descontó")
		Sim.avanzar(4)
		local _, q = est:invocar("CafeteriaPurchase", { ProductoId = "EMPANADA", Cantidad = 9999 })
		Sim.afirmar(type(q) == "table" and q.ok == false and EC:Saldo(est.inst) == s2, "compra inválida cobró")
	end)

	Sim.prueba("Moderación: un estudiante no puede expulsar", function()
		local _, r = est:invocar("ModerationAction", { Accion = "Expulsar", ObjetivoUserId = est2.userId, Motivo = "x" })
		Sim.afirmar(type(r) == "table" and r.ok == false, "un estudiante expulsó")
	end)

	Sim.prueba("Soporte: reporte válido con id", function()
		local _, r = est:invocar("ReportSubmit", { Categoria = "Bug", Ubicacion = "Patio", Descripcion = "La puerta no abre" })
		Sim.afirmar(ok(r), "reporte: " .. txt(r))
	end)

	Sim.prueba("Anuncios: director sí, estudiante no", function()
		Sim.avanzar(31)
		local _, a = dir:invocar("AnnouncementBroadcast", { Texto = "Bienvenidos a clase", Alcance = "Global" })
		Sim.afirmar(ok(a), "director: " .. txt(a))
		Sim.avanzar(1)
		Sim.afirmar(#est:eventos("Aviso") > 0, "el aviso no llegó a los jugadores")
		local _, b = est:invocar("AnnouncementBroadcast", { Texto = "hola", Alcance = "Global" })
		Sim.afirmar(type(b) == "table" and b.ok == false, "un estudiante anunció")
	end)

	Sim.prueba("Personal: panel del director y permisos", function()
		local _, a = dir:invocar("StaffAction", { Accion = "PanelDirector", Datos = {} })
		Sim.afirmar(ok(a), "panel director: " .. txt(a))
		local _, b = est:invocar("StaffAction", { Accion = "PanelDirector", Datos = {} })
		Sim.afirmar(type(b) == "table" and b.ok == false, "un estudiante abrió el panel del director")
	end)
end
