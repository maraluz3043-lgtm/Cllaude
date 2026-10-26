-- Cargador: construye el DataModel del juego a partir de src/ (convención Rojo) y del mapa exportado,
-- y arranca el servidor y los clientes simulados.

local P = require("planificador")
local T = require("tipos")
local I = require("instancias")
local S = require("servicios")
local E = require("entorno")

local C = {}

local function claseDe(nombre)
	if nombre:sub(-11) == ".server.lua" then return "Script", nombre:sub(1, -12) end
	if nombre:sub(-11) == ".client.lua" then return "LocalScript", nombre:sub(1, -12) end
	if nombre:sub(-4) == ".lua" then return "ModuleScript", nombre:sub(1, -5) end
	return nil
end

-- Carga un directorio dentro de una instancia contenedora.
local function cargarDirectorio(ruta, rutaRel, contenedor)
	for _, e in ipairs(listarDirectorio(ruta)) do
		local rutaHijo = ruta .. "/" .. e.nombre
		local relHijo = rutaRel .. "/" .. e.nombre
		if e.esDirectorio then
			local existente = I.buscarHijo(contenedor, e.nombre)
			local carpeta = existente
			if not carpeta then
				carpeta = I.nuevo("Folder")
				carpeta._p.Name = e.nombre
				carpeta.Parent = contenedor
			end
			cargarDirectorio(rutaHijo, relHijo, carpeta)
		else
			local clase, nombre = claseDe(e.nombre)
			if clase then
				local fuente = leerArchivo(rutaHijo)
				local s = I.nuevo(clase)
				s._p.Name = nombre
				s._p.Source = fuente
				rawset(s, "_archivo", relHijo)
				s.Parent = contenedor
			end
		end
	end
end

-- Los clones de scripts conservan la ruta del archivo de origen (para trazas legibles).
I.Clases.LuaSourceContainer.alClonar = function(orig, copia) rawset(copia, "_archivo", rawget(orig, "_archivo")) end

function C.cargarSrc(game, raizSrc)
	local n = 0
	for _, e in ipairs(listarDirectorio(raizSrc)) do
		if e.esDirectorio then
			local servicio = game:GetService(e.nombre)
			cargarDirectorio(raizSrc .. "/" .. e.nombre, "src/" .. e.nombre, servicio)
			n = n + 1
		end
	end
	return n
end

-- Carga el mapa exportado (tools/exportar_mapa_sim.py) sin disparar eventos (rápido).
function C.cargarMapa(game, archivo)
	if not existeArchivo(archivo) then return false, "no existe " .. archivo end
	local t0 = relojReal()
	local fuente = leerArchivo(archivo)
	local f, err = load(fuente, "@mapa_rbxl.lua", "t", {})
	if not f then return false, err end
	local datos = f()
	local ws = game:GetService("Workspace")
	local porId = {}
	porId[datos.raiz] = ws
	local NIL = I.NIL
	local CF = T.CFrame.new
	local V3 = T.Vector3.new
	local n = 0
	for _, fila in ipairs(datos.nodos) do
		local id, padre, clase, nombre, props = fila[1], fila[2], fila[3], fila[4], fila[5]
		if id ~= datos.raiz then
			local def = I.Clases[clase]
			local inst
			if def and not def.noCreable then
				inst = I.nuevo(clase)
			elseif clase == "Terrain" then
				inst = I.nuevo("Folder")
			else
				inst = I.nuevo("Folder")
			end
			inst._p.Name = nombre
			if props then
				if props.p then
					local r = props.r
					if r then
						inst._p.CFrame = CF(props.p[1], props.p[2], props.p[3], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9])
					else
						inst._p.CFrame = CF(props.p[1], props.p[2], props.p[3])
					end
				end
				if props.s then inst._p.Size = V3(props.s[1], props.s[2], props.s[3]) end
				if props.t then inst._p.Transparency = props.t end
				if props.c == false then inst._p.CanCollide = false end
				if inst:IsA("BasePart") then inst._p.Anchored = props.a ~= false end
				if props.x then
					if clase == "TextLabel" then inst._p.Text = props.x elseif clase == "Sound" then inst._p.SoundId = props.x end
				end
			elseif inst:IsA("BasePart") then
				inst._p.Anchored = true
			end
			local p = porId[padre] or ws
			rawset(inst, "_padre", p)
			inst._p.Parent = p
			table.insert(p._hijos, inst)
			porId[id] = inst
			n = n + 1
		end
	end
	return true, string.format("%d instancias del mapa cargadas en %.1f s", n, relojReal() - t0)
end

-- Ejecuta los Scripts de servidor (ServerScriptService y Workspace).
function C.arrancarServidor(game)
	local lista = {}
	for _, raiz in ipairs({ game:GetService("ServerScriptService"), game:GetService("Workspace") }) do
		for _, d in ipairs(raiz:GetDescendants()) do
			if d._c.nombre == "Script" then lista[#lista + 1] = d end
		end
	end
	for _, s in ipairs(lista) do E.ejecutarScript(s, P.ctxServidor) end
	return #lista
end

S.contextosCliente = {}
-- Arranca un cliente para el jugador: LocalScripts de ReplicatedFirst y copia de StarterPlayerScripts.
function C.arrancarCliente(game, jugador, dispositivo)
	local ctx = E.nuevoContextoCliente(jugador, dispositivo)
	S.contextosCliente[jugador] = ctx
	local ps = jugador:FindFirstChild("PlayerScripts")
	local sp = game:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts")
	local sg = game:GetService("StarterGui")
	local pg = jugador:FindFirstChild("PlayerGui")
	for _, x in ipairs(sg:GetChildren()) do local c = x:Clone() if c then c.Parent = pg end end
	local scripts = {}
	for _, d in ipairs(game:GetService("ReplicatedFirst"):GetDescendants()) do
		if d._c.nombre == "LocalScript" then scripts[#scripts + 1] = d end
	end
	if sp then
		for _, x in ipairs(sp:GetChildren()) do
			local c = x:Clone()
			if c then
				c.Parent = ps
				if c._c.nombre == "LocalScript" then scripts[#scripts + 1] = c end
				for _, d in ipairs(c:GetDescendants()) do
					if d._c.nombre == "LocalScript" then scripts[#scripts + 1] = d end
				end
			end
		end
	end
	for _, s in ipairs(scripts) do E.ejecutarScript(s, ctx) end
	return ctx, #scripts
end

return C
