--[[
	HERRAMIENTA DE STUDIO · Auditoría del mapa (Command Bar, modo edición). No modifica nada.

	Pegar completo en la Command Bar y pulsar Enter. Imprime en Output:
	  · Inventario del lugar: instancias por clase, scripts (ruta y estado), asientos, SpawnLocations,
	    puertas, luces, sonidos, ProximityPrompts, Decals/Textures, modelos de nivel superior más grandes.
	  · Si Colegio RP está instalado: comprobación de cada zona de MapaLogico (asientos detectados, PCs,
	    puertas resueltas, spawns provisionales) y lista de dependencias pendientes.
	  · Recomendaciones de rendimiento (scripts con wait() en bucle, partes sin anclar, etc.).
	Guarda el texto de Output como registro de evidencias (docs/A_Diagnostico_Mapa.md tiene el de referencia).
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local lineas = {}
local function P(txt) table.insert(lineas, txt) end

local function ruta(inst)
	local partes = {}
	local cur = inst
	while cur and cur ~= game do
		table.insert(partes, 1, cur.Name)
		cur = cur.Parent
	end
	return table.concat(partes, "/")
end

local function fmtV3(v)
	return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
end

-- 1. Conteo por clase
local porClase = {}
local total = 0
local scripts, asientos, spawns, prompts, luces, sonidos, decals, sinAnclar, clicks = {}, {}, {}, {}, {}, {}, {}, 0, {}
for _, d in ipairs(game:GetDescendants()) do
	local ok, clase = pcall(function() return d.ClassName end)
	if ok then
		total = total + 1
		porClase[clase] = (porClase[clase] or 0) + 1
		if d:IsA("LuaSourceContainer") then table.insert(scripts, d) end
		if d:IsA("Seat") or d:IsA("VehicleSeat") then table.insert(asientos, d) end
		if d:IsA("SpawnLocation") then table.insert(spawns, d) end
		if d:IsA("ProximityPrompt") then table.insert(prompts, d) end
		if d:IsA("ClickDetector") then table.insert(clicks, d) end
		if d:IsA("Light") then table.insert(luces, d) end
		if d:IsA("Sound") then table.insert(sonidos, d) end
		if d:IsA("Decal") or d:IsA("Texture") then table.insert(decals, d) end
		if d:IsA("BasePart") and d:IsDescendantOf(Workspace) and not d.Anchored and not d:FindFirstAncestorOfClass("Model") then sinAnclar = sinAnclar + 1 end
	end
end

P("================ AUDITORÍA DEL MAPA · " .. game.Name .. " ================")
P("Instancias totales: " .. total)
local clases = {}
for c, n in pairs(porClase) do table.insert(clases, { c, n }) end
table.sort(clases, function(a, b) return a[2] > b[2] end)
for i = 1, math.min(25, #clases) do P(string.format("  %-26s %d", clases[i][1], clases[i][2])) end

-- 2. Modelos de nivel superior más grandes
P("")
P("---- Modelos de nivel superior de Workspace (por número de BaseParts) ----")
local tops = {}
for _, hijo in ipairs(Workspace:GetChildren()) do
	if hijo:IsA("Model") or hijo:IsA("Folder") then
		local n = 0
		for _, d in ipairs(hijo:GetDescendants()) do if d:IsA("BasePart") then n = n + 1 end end
		if n >= 20 then
			local okB, cf, tam = pcall(function() return hijo:GetBoundingBox() end)
			table.insert(tops, { hijo, n, okB and cf or nil, okB and tam or nil })
		end
	end
end
table.sort(tops, function(a, b) return a[2] > b[2] end)
for i = 1, math.min(40, #tops) do
	local t = tops[i]
	P(string.format("  %-45s parts=%-5d %s tam=%s", t[1].Name, t[2], t[3] and fmtV3(t[3].Position) or "-", t[4] and fmtV3(t[4]) or "-"))
end

-- 3. Scripts
P("")
P("---- Scripts (" .. #scripts .. ") ----")
for _, s in ipairs(scripts) do
	local estado = ""
	if s:IsA("BaseScript") then estado = s.Disabled and " [DESACTIVADO]" or "" end
	local fuente = ""
	local okS, src = pcall(function() return s.Source end)
	if okS and type(src) == "string" then
		if src:find("while%s+true") and src:find("wait%s*%(") then fuente = " · bucle con wait() (coste continuo)" end
	end
	P("  [" .. s.ClassName .. "] " .. ruta(s) .. estado .. fuente)
end

-- 4. Asientos y spawns
P("")
P("---- Asientos: " .. #asientos .. " · SpawnLocations: " .. #spawns .. " · ClickDetectors: " .. #clicks .. " · ProximityPrompts: " .. #prompts .. " · Luces: " .. #luces .. " · Sonidos: " .. #sonidos .. " · Decals/Textures: " .. #decals .. " ----")
for _, sp in ipairs(spawns) do P("  Spawn " .. ruta(sp) .. " " .. fmtV3(sp.Position) .. " Neutral=" .. tostring(sp.Neutral)) end
P("  BaseParts sueltas sin anclar en Workspace: " .. sinAnclar)

-- 5. Comprobación contra MapaLogico si está instalado
local rp = ReplicatedStorage:FindFirstChild("ColegioRP")
local mapa = rp and rp:FindFirstChild("Shared") and rp.Shared:FindFirstChild("MapaLogico")
if mapa then
	local okM, MapaLogico = pcall(require, mapa)
	if okM then
		P("")
		P("---- Comprobación de zonas (MapaLogico v" .. tostring(MapaLogico.Version) .. ") ----")
		local function dentro(zona, pos)
			local d = pos - zona.Centro
			local h = zona.Tamano / 2
			return math.abs(d.X) <= h.X and math.abs(d.Y) <= h.Y and math.abs(d.Z) <= h.Z
		end
		for _, id in ipairs(MapaLogico.OrdenZonas) do
			local z = MapaLogico.Zonas[id]
			local nSeats, nPCs = 0, 0
			for _, s in ipairs(asientos) do if dentro(z, s.Position) then nSeats = nSeats + 1 end end
			if z.PCs then
				for _, p in ipairs(z.PCs) do
					-- hay un monitor a menos de 3 studs?
					local hay = false
					for _, d in ipairs(Workspace:GetDescendants()) do
						if d:IsA("BasePart") and d.Name == "Computer Monitor 1" and (d.Position - p).Magnitude < 3 then hay = true break end
					end
					if hay then nPCs = nPCs + 1 end
				end
			end
			local spawnTxt = "-"
			if z.Spawn then spawnTxt = z.Spawn.Estado .. " " .. fmtV3(z.Spawn.Punto) end
			P(string.format("  %-16s %-48s piso=%d seats=%-3d%s spawn=%s", id, z.Nombre, z.Piso, nSeats, z.PCs and (" pcs=" .. nPCs .. "/" .. #z.PCs) or "", spawnTxt))
		end
		P("")
		P("---- Puertas de MapaLogico ----")
		for _, id in ipairs(MapaLogico.OrdenPuertas) do
			local cfg = MapaLogico.Puertas[id]
			local cur = game
			for seg in string.gmatch(cfg.Ruta, "[^/]+") do
				cur = cur and cur:FindFirstChild(seg)
			end
			P(string.format("  %-20s %-55s %s", id, cfg.Ruta, cur and "OK" or "NO ENCONTRADA"))
		end
		local okC, Config = pcall(require, rp.Shared.Config)
		if okC then
			P("")
			P("---- Dependencias pendientes ----")
			if Config.LogoAssetId == 0 then P("  · LogoAssetId = 0: subir assets/logo_instituto_jean_piaget.png como Decal y pegar el id en Config.") end
			for nombre, idSonido in pairs(Config.Sonidos or {}) do
				if idSonido == 0 then P("  · Sonido '" .. nombre .. "' sin id (silencio).") end
			end
			local nAut = 0
			for _ in pairs((Config.Autorizaciones or {}).PorUserId or {}) do nAut = nAut + 1 end
			if nAut == 0 then P("  · Autorizaciones.PorUserId vacío: fuera de Studio solo habrá Estudiantes (añade UserIds o un grupo).") end
		end
	end
else
	P("")
	P("Colegio RP no está instalado (ReplicatedStorage/ColegioRP no existe): solo se imprime el inventario.")
end

P("================ FIN DE LA AUDITORÍA (" .. #lineas .. " líneas) ================")
for _, l in ipairs(lineas) do print(l) end
