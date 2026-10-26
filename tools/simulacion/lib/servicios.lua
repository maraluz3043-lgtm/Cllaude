-- Servicios de Roblox para el simulador: DataModel (game), Players/Player/personajes, remotos con copia de
-- argumentos y contextos cliente/servidor, DataStoreService, TextService (filtro determinista), HttpService,
-- CollectionService, RunService, TweenService, TextChatService, consultas espaciales y física mínima.

local P = require("planificador")
local T = require("tipos")
local I = require("instancias")
local Vector3, Vector2, CFrame, Color3, UDim2, Enum = T.Vector3, T.Vector2, T.CFrame, T.Color3, T.UDim2, T.Enum
local NIL = I.NIL
local definir, Clases = I.definir, I.Clases
local typeof = T.typeof

local S = {}
S.config = {
	studio = true,             -- RunService:IsStudio()
	datastoreFalla = false,    -- todas las llamadas de DataStore fallan
	studioSinApi = false,      -- simula Studio sin acceso a API (GetDataStore falla)
	filtroFalla = false,       -- TextService:FilterStringAsync falla
	palabrasProhibidas = { "malapalabra", "groseria", "insulto" },
	rangosGrupo = {},          -- [userId] = { [groupId] = rango }
}
S.expulsiones = {}             -- { jugador, mensaje }
S.mensajesSistema = {}         -- DisplaySystemMessage capturados
S.datastores = {}              -- nombre -> { clave -> valor serializado }

---------------------------------------------------------------------------- copia de argumentos (remotos/bindables)
local function copiar(v, vistos)
	local tv = type(v)
	if tv == "function" or tv == "thread" or tv == "userdata" then return nil end
	if tv ~= "table" then return v end
	if I.esInstancia(v) then return v end
	local mt = getmetatable(v)
	if mt and mt.__tipo then return v end -- tipos de datos de Roblox (inmutables)
	vistos = vistos or {}
	if vistos[v] then return vistos[v] end
	local r = {}
	vistos[v] = r
	for k, x in pairs(v) do
		local kc = type(k) == "table" and nil or k
		if kc ~= nil then r[kc] = copiar(x, vistos) end
	end
	return r
end
S.copiar = copiar

local function copiarArgs(...)
	local n = select("#", ...)
	local a = { ... }
	local r = { n = n }
	for i = 1, n do r[i] = copiar(a[i]) end
	return r
end

---------------------------------------------------------------------------- DataModel y creación de servicios
definir("ServiceProvider", "Instance", { noCreable = true })
local dm = definir("DataModel", "ServiceProvider", { noCreable = true, props = { PlaceId = 0, GameId = 0, JobId = "sim-job", CreatorId = 0, CreatorType = Enum.CreatorType.User, PlaceVersion = 1, PrivateServerId = "", PrivateServerOwnerId = 0 } })

local constructores = {} -- nombreServicio -> function(inst)
local CLASES_SERVICIO = {}
local function servicio(nombre, def, constructor)
	def = def or {}
	def.noCreable = true
	definir(nombre, def.padreClase or "Instance", def)
	CLASES_SERVICIO[nombre] = true
	constructores[nombre] = constructor
end

local game
local function crearServicio(nombre)
	if not CLASES_SERVICIO[nombre] then return nil end
	for _, h in ipairs(game._hijos) do
		if h._c.nombre == nombre then return h end
	end
	local def = Clases[nombre]
	def.noCreable = false
	local inst = I.nuevo(nombre)
	def.noCreable = true
	inst._p.Name = nombre
	rawset(inst, "_padre", game)
	inst._p.Parent = game
	table.insert(game._hijos, inst)
	if constructores[nombre] then constructores[nombre](inst) end
	return inst
end
S.crearServicio = crearServicio

dm.metodos.GetService = function(g, nombre)
	local s = crearServicio(nombre)
	if not s then error(string.format("'%s' is not a valid Service name", tostring(nombre)), 2) end
	return s
end
dm.metodos.FindService = function(g, nombre)
	for _, h in ipairs(g._hijos) do if h._c.nombre == nombre then return h end end
	return nil
end
dm.metodos.BindToClose = function(g, f) table.insert(S.alCerrar, f) end
dm.metodos.IsLoaded = function() return true end
dm.metodos.GetJobsInfo = function() return {} end
dm.metodos.SetPlaceId = function() end
dm.eventos = { Loaded = true, Close = true }
dm.calc.Workspace = { get = function(g) return g:GetService("Workspace") end }
dm.calc.Lighting = { get = function(g) return g:GetService("Lighting") end }
S.alCerrar = {}

---------------------------------------------------------------------------- Workspace, consultas espaciales y física
servicio("Workspace", {
	padreClase = "Model",
	props = { Gravity = 196.2, FallenPartsDestroyHeight = -500, StreamingEnabled = false, FilteringEnabled = true, AirDensity = 0.0012, CurrentCamera = NIL, SignalBehavior = Enum.SignalBehavior.Default, Retargeting = Enum.AnimatorRetargetingMode.Default, StreamingTargetRadius = 1024, StreamingMinRadius = 64, ModelStreamingBehavior = Enum.ModelStreamingBehavior.Default, TouchesUseCollisionGroups = false, AllowThirdPartySales = false },
}, function(ws)
	local cam = I.nuevo("Camera")
	cam._p.Name = "Camera"
	cam.Parent = ws
	ws._p.CurrentCamera = cam
end)
local wsDef = Clases.Workspace
wsDef.calc.DistributedGameTime = { get = function() return P.ahora end }
wsDef.metodos.GetServerTimeNow = function() return P.unixBase + P.ahora end
wsDef.metodos.GetRealPhysicsFPS = function() return 60 end
wsDef.metodos.GetNumAwakeParts = function() return 0 end
wsDef.metodos.GetPhysicsThrottling = function() return 100 end
wsDef.metodos.PGSIsEnabled = function() return true end
wsDef.metodos.JoinToOutsiders = function() end
wsDef.metodos.UnjoinFromOutsiders = function() end
wsDef.metodos.FindPartsInRegion3 = function() return {} end
wsDef.metodos.FindPartsInRegion3WithIgnoreList = function() return {} end
wsDef.metodos.ArePartsTouchingOthers = function() return false end
wsDef.metodos.BulkMoveTo = function(ws, partes, cfs) for i, p in ipairs(partes) do p.CFrame = cfs[i] end end

-- índice espacial (rejilla XZ de 32 studs) construido de forma perezosa
local CELDA = 32
local indice = nil
local function clavesCeldas(x0, z0, x1, z1)
	local r = {}
	for cx = math.floor(x0 / CELDA), math.floor(x1 / CELDA) do
		for cz = math.floor(z0 / CELDA), math.floor(z1 / CELDA) do
			r[#r + 1] = cx .. "," .. cz
		end
	end
	return r
end
local function indexar(parte)
	if not indice then return end
	local viejas = rawget(parte, "_celdas")
	if viejas then
		for _, k in ipairs(viejas) do local c = indice[k] if c then c[parte] = nil end end
	end
	if parte._destruido then rawset(parte, "_celdas", nil) return end
	local ws = game and game:FindService("Workspace")
	if not ws or not parte:IsDescendantOf(ws) then rawset(parte, "_celdas", nil) return end
	local x0, _, z0, x1, _, z1 = I.aabb(parte)
	local ks = clavesCeldas(x0, z0, x1, z1)
	if #ks > 400 then ks = { "grande" } end
	for _, k in ipairs(ks) do
		local c = indice[k]
		if not c then c = {} indice[k] = c end
		c[parte] = true
	end
	rawset(parte, "_celdas", ks)
end
local function construirIndice()
	indice = { grande = {} }
	local ws = game:GetService("Workspace")
	for _, d in ipairs(ws:GetDescendants()) do
		if d:IsA("BasePart") then indexar(d) end
	end
end
local function consultaCaja(x0, y0, z0, x1, y1, z1, params)
	if not indice then construirIndice() end
	local vistos = {}
	local r = {}
	local filtro, incluir = nil, false
	if params and params.FilterDescendantsInstances and #params.FilterDescendantsInstances > 0 then
		filtro = params.FilterDescendantsInstances
		incluir = params.FilterType == Enum.RaycastFilterType.Include or params.FilterType == Enum.RaycastFilterType.Whitelist
	end
	local function pasaFiltro(p)
		if not filtro then return true end
		local dentro = false
		for _, f in ipairs(filtro) do
			if p == f or p:IsDescendantOf(f) then dentro = true break end
		end
		if incluir then return dentro end
		return not dentro
	end
	local celdas = clavesCeldas(x0, z0, x1, z1)
	celdas[#celdas + 1] = "grande"
	for _, k in ipairs(celdas) do
		local c = indice[k]
		if c then
			for p in pairs(c) do
				if not vistos[p] then
					vistos[p] = true
					if not p._destruido and p._p.CanQuery ~= false then
						local a, b, cc, d, e, f = I.aabb(p)
						if a <= x1 and d >= x0 and b <= y1 and e >= y0 and cc <= z1 and f >= z0 and pasaFiltro(p) then
							r[#r + 1] = p
							if params and params.MaxParts and params.MaxParts > 0 and #r >= params.MaxParts then return r end
						end
					end
				end
			end
		end
	end
	return r
end
S.consultaCaja = consultaCaja
wsDef.metodos.GetPartBoundsInBox = function(ws, cf, tam, params)
	local hx, hy, hz = tam.X / 2, tam.Y / 2, tam.Z / 2
	local ex = math.abs(cf[4]) * hx + math.abs(cf[5]) * hy + math.abs(cf[6]) * hz
	local ey = math.abs(cf[7]) * hx + math.abs(cf[8]) * hy + math.abs(cf[9]) * hz
	local ez = math.abs(cf[10]) * hx + math.abs(cf[11]) * hy + math.abs(cf[12]) * hz
	return consultaCaja(cf[1] - ex, cf[2] - ey, cf[3] - ez, cf[1] + ex, cf[2] + ey, cf[3] + ez, params)
end
wsDef.metodos.GetPartBoundsInRadius = function(ws, pos, r, params)
	return consultaCaja(pos.X - r, pos.Y - r, pos.Z - r, pos.X + r, pos.Y + r, pos.Z + r, params)
end
wsDef.metodos.GetPartsInPart = function(ws, parte, params)
	local a, b, c, d, e, f = I.aabb(parte)
	local r = {}
	for _, p in ipairs(consultaCaja(a, b, c, d, e, f, params)) do if p ~= parte then r[#r + 1] = p end end
	return r
end
local RRMT = { __tipo = "RaycastResult" }
RRMT.__index = function(_, k) error("simulador: " .. tostring(k) .. " no es miembro de RaycastResult", 2) end
wsDef.metodos.Raycast = function(ws, origen, dir, params)
	local fin = origen + dir
	local x0, y0, z0 = math.min(origen.X, fin.X), math.min(origen.Y, fin.Y), math.min(origen.Z, fin.Z)
	local x1, y1, z1 = math.max(origen.X, fin.X), math.max(origen.Y, fin.Y), math.max(origen.Z, fin.Z)
	local candidatos = consultaCaja(x0, y0, z0, x1, y1, z1, params)
	local mejor, mejorT, normal = nil, math.huge, Vector3.yAxis
	for _, p in ipairs(candidatos) do
		if not (params and params.RespectCanCollide and p._p.CanCollide == false) and p._p.Transparency ~= nil then
			local a, b, c, d, e, f = I.aabb(p)
			local tmin, tmax = 0, 1
			local n = Vector3.yAxis
			local ok = true
			local o = { origen.X, origen.Y, origen.Z }
			local dd = { dir.X, dir.Y, dir.Z }
			local mn = { a, b, c }
			local mx = { d, e, f }
			local ejes = { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis }
			for k = 1, 3 do
				if math.abs(dd[k]) < 1e-12 then
					if o[k] < mn[k] or o[k] > mx[k] then ok = false break end
				else
					local t1 = (mn[k] - o[k]) / dd[k]
					local t2 = (mx[k] - o[k]) / dd[k]
					local nn = -ejes[k] * (dd[k] > 0 and 1 or -1)
					if t1 > t2 then t1, t2 = t2, t1 end
					if t1 > tmin then tmin = t1 n = nn end
					if t2 < tmax then tmax = t2 end
					if tmin > tmax then ok = false break end
				end
			end
			if ok and tmin < mejorT then mejor, mejorT, normal = p, tmin, n end
		end
	end
	if not mejor then return nil end
	local pos = origen + dir * mejorT
	return setmetatable({ Instance = mejor, Position = pos, Normal = normal, Material = mejor._p.Material or Enum.Material.Plastic, Distance = (dir * mejorT).Magnitude }, RRMT)
end
wsDef.metodos.Blockcast = function() return nil end
wsDef.metodos.Spherecast = function() return nil end
wsDef.metodos.Shapecast = function() return nil end
wsDef.metodos.FindPartOnRay = function(ws, ray) local r = wsDef.metodos.Raycast(ws, ray.Origin, ray.Direction) if r then return r.Instance, r.Position, r.Normal, r.Material end return nil, ray.Origin + ray.Direction, Vector3.yAxis, Enum.Material.Air end
wsDef.metodos.FindPartOnRayWithIgnoreList = wsDef.metodos.FindPartOnRay
wsDef.metodos.FindPartOnRayWithWhitelist = wsDef.metodos.FindPartOnRay

-- partes dinámicas (desancladas por el juego en tiempo de ejecución)
local dinamicas = {}
I.alMoverParte = function(p) if indice then indexar(p) end end
local function marcarDinamica(p)
	if not p:IsA("BasePart") or p._p.Anchored then return end
	local ws = game and game:FindService("Workspace")
	if not ws or not p:IsDescendantOf(ws) then return end
	local m = p:FindFirstAncestorOfClass("Model")
	if m and m:FindFirstChildOfClass("Humanoid") then return end
	dinamicas[p] = true
end
I.alCambiarAnclaje = function(p)
	if p._p.Anchored then dinamicas[p] = nil return end
	marcarDinamica(p)
end
I.alEntrar = function(inst, padre)
	if inst:IsA("BasePart") then
		if indice then indexar(inst) end
		marcarDinamica(inst)
	end
	if #inst._hijos > 0 and (inst:IsA("Model") or inst:IsA("Folder")) then
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") then
				if indice then indexar(d) end
				marcarDinamica(d)
			end
		end
	end
end
table.insert(P.alPaso, function(dt)
	local ws = game and game:FindService("Workspace")
	if not ws then return end
	local g = ws._p.Gravity or 196.2
	for p in pairs(dinamicas) do
		if p._destruido or p._p.Anchored or not p:IsDescendantOf(ws) then
			dinamicas[p] = nil
		else
			local v = p._p.AssemblyLinearVelocity or Vector3.zero
			v = Vector3.new(v.X, v.Y - g * dt, v.Z)
			local c = p._p.CFrame
			local pos = c.Position + v * dt
			local mitad = (p._p.Size or Vector3.new(2, 2, 2)).Y / 2
			if pos.Y < mitad then
				pos = Vector3.new(pos.X, mitad, pos.Z)
				v = Vector3.new(v.X * 0.98, math.abs(v.Y) > 5 and -v.Y * 0.5 or 0, v.Z * 0.98)
			end
			p._p.AssemblyLinearVelocity = v
			p.CFrame = CFrame.new(pos.X, pos.Y, pos.Z, c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12])
			if pos.Y < (ws._p.FallenPartsDestroyHeight or -500) then p:Destroy() end
		end
	end
end)

---------------------------------------------------------------------------- servicios contenedores simples
servicio("ReplicatedStorage", {})
servicio("ReplicatedFirst", { metodos = { RemoveDefaultLoadingScreen = function() end, IsFinishedReplicating = function() return true end, SetDefaultLoadingGuiRemoved = function() end }, eventos = { FinishedReplicating = true } })
servicio("ServerScriptService", { props = { LoadStringEnabled = false } })
servicio("ServerStorage", {})
servicio("StarterPack", {})
servicio("Teams", { metodos = { GetTeams = function(t) local r = {} for _, h in ipairs(t._hijos) do if h:IsA("Team") then r[#r + 1] = h end end return r end } })
servicio("StarterPlayer", { props = { CharacterWalkSpeed = 16, CharacterJumpPower = 50, CharacterJumpHeight = 7.2, CharacterUseJumpPower = false, CameraMaxZoomDistance = 128, CameraMinZoomDistance = 0.5, CameraMode = Enum.CameraMode.Classic, EnableMouseLockOption = true, HealthDisplayDistance = 100, NameDisplayDistance = 100, LoadCharacterAppearance = true, AutoJumpEnabled = true, DevComputerMovementMode = Enum.DevComputerMovementMode.UserChoice, DevTouchMovementMode = Enum.DevTouchMovementMode.UserChoice, UserEmotesEnabled = true, CharacterMaxSlopeAngle = 89 } }, function(sp)
	local a = I.nuevo("StarterPlayerScripts") a._p.Name = "StarterPlayerScripts" a.Parent = sp
	local b = I.nuevo("StarterCharacterScripts") b._p.Name = "StarterCharacterScripts" b.Parent = sp
end)
servicio("StarterGui", { props = { ShowDevelopmentGui = true, ResetPlayerGuiOnSpawn = true, ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor }, metodos = {
	SetCore = function() end, GetCore = function(_, n) if n == "ChatActive" then return true end return nil end,
	SetCoreGuiEnabled = function() end, GetCoreGuiEnabled = function() return true end, RegisterSetCore = function() end, RegisterGetCore = function() end,
} })
servicio("Lighting", { props = {
	ClockTime = 14, TimeOfDay = "14:00:00", Brightness = 2, Ambient = Color3.fromRGB(70, 70, 70), OutdoorAmbient = Color3.fromRGB(128, 128, 128),
	GlobalShadows = true, Technology = Enum.Technology.Future, ShadowSoftness = 0.2, EnvironmentDiffuseScale = 1, EnvironmentSpecularScale = 1,
	ExposureCompensation = 0, FogColor = Color3.fromRGB(192, 192, 192), FogEnd = 100000, FogStart = 0, GeographicLatitude = 0,
	ColorShift_Top = Color3.new(), ColorShift_Bottom = Color3.new(), LightingStyle = Enum.LightingStyle.Realistic, PrioritizeLightingQuality = true,
}, metodos = {
	GetMinutesAfterMidnight = function(l) return (l._p.ClockTime or 14) * 60 end,
	SetMinutesAfterMidnight = function(l, m) l.ClockTime = m / 60 end,
	GetSunDirection = function() return Vector3.new(0, 1, 0) end,
	GetMoonDirection = function() return Vector3.new(0, -1, 0) end,
} })
servicio("SoundService", { props = { AmbientReverb = Enum.ReverbType.NoReverb, DistanceFactor = 3.33, DopplerScale = 1, RolloffScale = 1, RespectFilteringEnabled = true }, metodos = {
	PlayLocalSound = function() end, SetListener = function() end, GetListener = function() return Enum.ListenerType.Camera end,
} })
servicio("Chat", { props = { LoadDefaultChat = false, BubbleChatEnabled = true }, metodos = { Chat = function() end, FilterStringForBroadcast = function(_, s) return s end, FilterStringAsync = function(_, s) return s end, CanUserChatAsync = function() return true end } })
servicio("Debris", { props = { MaxItems = 1000 }, metodos = { AddItem = function(_, inst, t) P.task.delay(t or 10, function() if not inst._destruido then inst:Destroy() end end) end } })
servicio("ChangeHistoryService", { metodos = { SetWaypoint = function() end, TryBeginRecording = function() return "grabacion" end, FinishRecording = function() end, ResetWaypoints = function() end, SetEnabled = function() end, Undo = function() end, Redo = function() end } })
servicio("ContentProvider", { props = { BaseUrl = "https://www.roblox.com/" }, metodos = {
	PreloadAsync = function(_, lista, cb)
		if type(lista) ~= "table" then error("Unable to cast to Array", 2) end
		for _, a in ipairs(lista) do
			if cb then
				local id = type(a) == "string" and a or (I.esInstancia(a) and a._p.Name or tostring(a))
				local ok, err = pcall(cb, id, Enum.AssetFetchStatus.Success)
				if not ok then P.registrarError(err, coroutine.running()) end
			end
			P.ceder(0.01)
		end
	end,
	GetAssetFetchStatus = function() return Enum.AssetFetchStatus.Success end,
}, calc = { RequestQueueSize = { get = function() return 0 end } } })
servicio("Stats", { props = { DataReceiveKbps = 10, DataSendKbps = 5, HeartbeatTimeMs = 2, PhysicsStepTimeMs = 1, ContactsCount = 0, PhysicsReceiveKbps = 0, PhysicsSendKbps = 0 }, metodos = {
	GetTotalMemoryUsageMb = function() return 512 end, GetMemoryUsageMbForTag = function() return 10 end, GetMemoryUsageMbAllCategories = function() return {} end,
}, calc = { InstanceCount = { get = function() return 100000 end }, PrimitivesCount = { get = function() return 60000 end }, MovingPrimitivesCount = { get = function() return 1 end } } })
servicio("MarketplaceService", { props = { ProcessReceipt = NIL }, metodos = {
	PromptPurchase = function() end, PromptProductPurchase = function() end, PromptGamePassPurchase = function() end,
	UserOwnsGamePassAsync = function() return false end, PlayerOwnsAsset = function() return false end,
	GetProductInfo = function(_, id) return { Name = "Producto " .. tostring(id), PriceInRobux = 0, AssetId = id, IsForSale = false } end,
} })
servicio("MessagingService", { metodos = { PublishAsync = function() end, SubscribeAsync = function() return { Disconnect = function() end, Connected = true } end } })
servicio("GroupService", { metodos = { GetGroupInfoAsync = function(_, id) return { Id = id, Name = "Grupo", Roles = {} } end, GetGroupsAsync = function() return {} end, GetAlliesAsync = function() return {} end } })
servicio("LocalizationService", { props = { RobloxLocaleId = "es-es", SystemLocaleId = "es-es" }, metodos = {
	GetTranslatorForPlayerAsync = function() return { LocaleId = "es-es", Translate = function(_, _, s) return s end, FormatByKey = function(_, k) return k end } end,
	GetTranslatorForLocaleAsync = function() return { LocaleId = "es-es", Translate = function(_, _, s) return s end, FormatByKey = function(_, k) return k end } end,
	GetCountryRegionForPlayerAsync = function() return "CO" end,
} })
local gruposColision = { Default = true }
servicio("PhysicsService", { metodos = {
	RegisterCollisionGroup = function(_, n) gruposColision[n] = true end, CreateCollisionGroup = function(_, n) gruposColision[n] = true return 1 end,
	CollisionGroupSetCollidable = function() end, CollisionGroupsAreCollidable = function() return true end,
	IsCollisionGroupRegistered = function(_, n) return gruposColision[n] == true end, GetRegisteredCollisionGroups = function() local r = {} for n in pairs(gruposColision) do r[#r + 1] = { name = n, mask = 0 } end return r end,
	SetPartCollisionGroup = function(_, p, n) p.CollisionGroup = n end, UnregisterCollisionGroup = function(_, n) gruposColision[n] = nil end, RenameCollisionGroup = function() end,
	GetMaxCollisionGroups = function() return 32 end,
} })
servicio("ProximityPromptService", { props = { Enabled = true, MaxPromptsVisible = 16, MaxIndicatorsVisible = 0 }, eventos = { PromptTriggered = true, PromptTriggerEnded = true, PromptShown = true, PromptHidden = true, PromptButtonHoldBegan = true, PromptButtonHoldEnded = true } })
servicio("TeleportService", { metodos = { Teleport = function() error("simulador: TeleportService no disponible", 2) end, TeleportAsync = function() error("simulador: TeleportService no disponible", 2) end, GetLocalPlayerTeleportData = function() return nil end, SetTeleportGui = function() end } })
servicio("BadgeService", { metodos = { AwardBadge = function() return false end, UserHasBadgeAsync = function() return false end, GetBadgeInfoAsync = function() return {} end } })
servicio("PolicyService", { metodos = { GetPolicyInfoForPlayerAsync = function() return { AreAdsAllowed = false, ArePaidRandomItemsRestricted = false, AllowedExternalLinkReferences = {}, IsSubjectToChinaPolicies = false, IsPaidItemTradingAllowed = true, IsContentSharingAllowed = true, IsEligibleToPurchaseSubscription = true } end } })
servicio("VoiceChatService", { props = { EnableDefaultVoice = true }, metodos = { IsVoiceEnabledForUserIdAsync = function() return false end } })
servicio("SocialService", { metodos = { CanSendGameInviteAsync = function() return false end, PromptGameInvite = function() end } })
servicio("AvatarEditorService", {})
servicio("AssetService", { metodos = { CreateEditableImage = function() error("simulador: AssetService no disponible", 2) end } })
servicio("TestService", { metodos = { Check = function() end, Checkpoint = function() end, Message = function() end } })
servicio("InsertService", { metodos = { LoadAsset = function() error("simulador: InsertService no disponible", 2) end } })
servicio("CoreGui", {})
servicio("VRService", { props = { VREnabled = false } })
servicio("HapticService", { metodos = { IsVibrationSupported = function() return false end, SetMotor = function() end } })
servicio("TextChatService", {
	props = { ChatVersion = Enum.ChatVersion.TextChatService, CreateDefaultTextChannels = true, CreateDefaultCommands = true, ChatTranslationEnabled = false },
	eventos = { MessageReceived = true, SendingMessage = true, OnIncomingMessage = true, OnBubbleAdded = true, OnChatWindowAdded = true },
	metodos = { CanUserChatAsync = function() return true end, CanUsersChatAsync = function() return true end, CanUsersDirectChatAsync = function() return {} end, DisplayBubble = function() end },
}, function(tcs)
	local carpeta = I.nuevo("Folder") carpeta._p.Name = "TextChannels" carpeta.Parent = tcs
	for _, n in ipairs({ "RBXGeneral", "RBXSystem" }) do
		local c = I.nuevo("TextChannel") c._p.Name = n c.Parent = carpeta
	end
	local cmds = I.nuevo("Folder") cmds._p.Name = "TextChatCommands" cmds.Parent = tcs
end)
local canal = Clases.TextChannel
canal.metodos.AddUserAsync = function(c, userId)
	for _, h in ipairs(c._hijos) do if h:IsA("TextSource") and h._p.UserId == userId then return h, true end end
	local ts = I.nuevo("TextSource")
	ts._p.Name = tostring(userId)
	ts._p.UserId = userId
	ts.Parent = c
	return ts, true
end
canal.metodos.DisplaySystemMessage = function(c, texto, meta) table.insert(S.mensajesSistema, { canal = c._p.Name, texto = texto, contexto = P.contexto().nombre }) return I.nuevo("Folder") end
canal.metodos.SendAsync = function(c, texto) table.insert(S.mensajesSistema, { canal = c._p.Name, texto = texto, contexto = P.contexto().nombre, chat = true }) return I.nuevo("Folder") end
canal.metodos.SetDirectChatRequester = function() end

servicio("HttpService", { props = { HttpEnabled = false }, metodos = {
	GenerateGUID = function(_, llaves)
		local t = {}
		for i = 1, 32 do t[i] = string.format("%x", math.random(0, 15)) end
		local s = table.concat(t)
		s = s:sub(1, 8) .. "-" .. s:sub(9, 12) .. "-" .. s:sub(13, 16) .. "-" .. s:sub(17, 20) .. "-" .. s:sub(21, 32)
		s = s:upper()
		if llaves == false then return s end
		return "{" .. s .. "}"
	end,
	JSONEncode = function(_, v) return S.json(v) end,
	JSONDecode = function(_, s) return S.jsonDecode(s) end,
	UrlEncode = function(_, s) return (tostring(s):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", string.byte(c)) end)) end,
	GetAsync = function() error("Http requests are not enabled. Enable via game settings", 2) end,
	PostAsync = function() error("Http requests are not enabled. Enable via game settings", 2) end,
	RequestAsync = function() error("Http requests are not enabled. Enable via game settings", 2) end,
	GetSecret = function() error("simulador: secretos no disponibles", 2) end,
} })

-- JSON mínimo
function S.json(v)
	local tv = type(v)
	if v == nil then return "null" end
	if tv == "boolean" then return tostring(v) end
	if tv == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return "null" end
		if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", math.floor(v)) end
		return string.format("%.14g", v)
	end
	if tv == "string" then
		return '"' .. v:gsub('[%c"\\]', function(c)
			local m = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
			return m[c] or string.format("\\u%04x", string.byte(c))
		end) .. '"'
	end
	if tv == "table" then
		if I.esInstancia(v) or (getmetatable(v) and getmetatable(v).__tipo) then return "null" end
		local n = #v
		local esArray = n > 0 or next(v) == nil
		if esArray then
			for k in pairs(v) do if type(k) ~= "number" then esArray = false break end end
		end
		local partes = {}
		if esArray then
			for i = 1, n do partes[i] = S.json(v[i]) end
			return "[" .. table.concat(partes, ",") .. "]"
		end
		for k, x in pairs(v) do
			if type(x) ~= "function" then partes[#partes + 1] = S.json(tostring(k)) .. ":" .. S.json(x) end
		end
		table.sort(partes)
		return "{" .. table.concat(partes, ",") .. "}"
	end
	return "null"
end
function S.jsonDecode(s)
	local pos = 1
	local function ws() pos = s:find("[^%s]", pos) or #s + 1 end
	local valor
	local function cadena()
		pos = pos + 1
		local partes = {}
		while true do
			local c = s:sub(pos, pos)
			if c == "" then error("JSON inválido: cadena sin cerrar", 0) end
			if c == '"' then pos = pos + 1 break end
			if c == "\\" then
				local e = s:sub(pos + 1, pos + 1)
				local m = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
				if e == "u" then partes[#partes + 1] = utf8.char(tonumber(s:sub(pos + 2, pos + 5), 16)) pos = pos + 6
				else partes[#partes + 1] = m[e] or e pos = pos + 2 end
			else
				partes[#partes + 1] = c
				pos = pos + 1
			end
		end
		return table.concat(partes)
	end
	valor = function()
		ws()
		local c = s:sub(pos, pos)
		if c == "{" then
			pos = pos + 1
			local t = {}
			ws()
			if s:sub(pos, pos) == "}" then pos = pos + 1 return t end
			while true do
				ws()
				local k = cadena()
				ws()
				pos = pos + 1 -- :
				t[k] = valor()
				ws()
				local d = s:sub(pos, pos)
				pos = pos + 1
				if d == "}" then return t end
			end
		elseif c == "[" then
			pos = pos + 1
			local t = {}
			ws()
			if s:sub(pos, pos) == "]" then pos = pos + 1 return t end
			while true do
				t[#t + 1] = valor()
				ws()
				local d = s:sub(pos, pos)
				pos = pos + 1
				if d == "]" then return t end
			end
		elseif c == '"' then
			return cadena()
		elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
		elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
		elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil
		else
			local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
			if not num or num == "" then error("Can't parse JSON", 0) end
			pos = pos + #num
			return tonumber(num)
		end
	end
	local ok, r = pcall(valor)
	if not ok then error("Can't parse JSON", 2) end
	return r
end

---------------------------------------------------------------------------- CollectionService
local etiquetas = {} -- tag -> { inst = true }
local senalesTag = {} -- "add:tag"/"rem:tag" -> señal
local function senalTag(clave)
	local s = senalesTag[clave]
	if not s then s = P.nuevaSenal(clave) senalesTag[clave] = s end
	return s
end
I.alPonerTag = function(inst, tag)
	local t = etiquetas[tag]
	if not t then t = {} etiquetas[tag] = t end
	t[inst] = true
	local s = senalesTag["add:" .. tag]
	if s then P.disparar(s, nil, inst) end
end
I.alQuitarTag = function(inst, tag)
	local t = etiquetas[tag]
	if t then t[inst] = nil end
	local s = senalesTag["rem:" .. tag]
	if s then P.disparar(s, nil, inst) end
end
servicio("CollectionService", { metodos = {
	AddTag = function(_, inst, tag) inst:AddTag(tag) end,
	RemoveTag = function(_, inst, tag) inst:RemoveTag(tag) end,
	HasTag = function(_, inst, tag) return inst:HasTag(tag) end,
	GetTags = function(_, inst) return inst:GetTags() end,
	GetTagged = function(_, tag)
		local r = {}
		for inst in pairs(etiquetas[tag] or {}) do
			if not inst._destruido and inst:IsDescendantOf(game) then r[#r + 1] = inst end
		end
		table.sort(r, function(a, b) return a._id < b._id end)
		return r
	end,
	GetAllTags = function() local r = {} for t in pairs(etiquetas) do r[#r + 1] = t end return r end,
	GetInstanceAddedSignal = function(_, tag) return senalTag("add:" .. tag) end,
	GetInstanceRemovedSignal = function(_, tag) return senalTag("rem:" .. tag) end,
} })

---------------------------------------------------------------------------- RunService
local renderBinds = {}
servicio("RunService", {
	eventos = { Heartbeat = true, Stepped = true, RenderStepped = true, PreSimulation = true, PostSimulation = true, PreRender = true, PreAnimation = true },
	metodos = {
		IsStudio = function() return S.config.studio end,
		IsServer = function() return P.contexto().lado ~= "cliente" end,
		IsClient = function() return P.contexto().lado == "cliente" end,
		IsRunning = function() return true end,
		IsRunMode = function() return false end,
		IsEdit = function() return false end,
		BindToRenderStep = function(_, nombre, prio, f)
			if P.contexto().lado ~= "cliente" then error("BindToRenderStep can only be called from the client", 2) end
			renderBinds[nombre .. "@" .. tostring(P.contexto().nombre)] = { f = f, ctx = P.contexto() }
		end,
		UnbindFromRenderStep = function(_, nombre) renderBinds[nombre .. "@" .. tostring(P.contexto().nombre)] = nil end,
		Set3dRenderingEnabled = function() end,
		Pause = function() end, Run = function() end, Stop = function() end,
	},
})
table.insert(P.alPaso, function(dt)
	local rs = game and game:FindService("RunService")
	if not rs then return end
	local s = rs._senales
	if s then
		if s.Stepped then P.disparar(s.Stepped, nil, P.ahora, dt) end
		if s.PreSimulation then P.disparar(s.PreSimulation, nil, dt) end
		if s.PostSimulation then P.disparar(s.PostSimulation, nil, dt) end
		if s.Heartbeat then P.disparar(s.Heartbeat, nil, dt) end
		if s.PreAnimation then P.disparar(s.PreAnimation, function(c) return c._ctx.lado == "cliente" end, dt) end
		if s.PreRender then P.disparar(s.PreRender, function(c) return c._ctx.lado == "cliente" end, dt) end
		if s.RenderStepped then P.disparar(s.RenderStepped, function(c) return c._ctx.lado == "cliente" end, dt) end
	end
	for _, b in pairs(renderBinds) do
		P.ejecutar(b.f, b.ctx, dt)
	end
end)

---------------------------------------------------------------------------- TweenService
local tween = Clases.Tween
tween.metodos.Play = function(tw)
	if tw._p.PlaybackState == Enum.PlaybackState.Playing then return end
	tw._p.PlaybackState = Enum.PlaybackState.Playing
	local info = tw._info
	local total = (info.DelayTime or 0) + (info.Time or 0) * ((info.RepeatCount or 0) + 1) * (info.Reverses and 2 or 1)
	local version = (rawget(tw, "_version") or 0) + 1
	rawset(tw, "_version", version)
	P.task.delay(total, function()
		if rawget(tw, "_version") ~= version or tw._p.PlaybackState ~= Enum.PlaybackState.Playing then return end
		local obj = tw._objeto
		if obj and not obj._destruido then
			for k, v in pairs(tw._metas) do
				local ok, err = pcall(function() obj[k] = v end)
				if not ok then P.registrarError(err, coroutine.running()) end
			end
		end
		tw._p.PlaybackState = Enum.PlaybackState.Completed
		local s = I.senalSiExiste(tw, "Completed")
		if s then P.disparar(s, nil, Enum.PlaybackState.Completed) end
	end)
end
tween.metodos.Cancel = function(tw)
	rawset(tw, "_version", (rawget(tw, "_version") or 0) + 1)
	tw._p.PlaybackState = Enum.PlaybackState.Cancelled
	local s = I.senalSiExiste(tw, "Completed")
	if s then P.disparar(s, nil, Enum.PlaybackState.Cancelled) end
end
tween.metodos.Pause = function(tw)
	rawset(tw, "_version", (rawget(tw, "_version") or 0) + 1)
	tw._p.PlaybackState = Enum.PlaybackState.Paused
end
servicio("TweenService", { metodos = {
	Create = function(_, inst, info, metas)
		if not I.esInstancia(inst) then error("Unable to cast value to Object", 2) end
		if typeof(info) ~= "TweenInfo" then error("Unable to cast value to TweenInfo", 2) end
		for k, v in pairs(metas) do
			-- valida que la propiedad exista y sea interpolable
			local ok, actual = pcall(function() return inst[k] end)
			if not ok then error(string.format("TweenService:Create property named '%s' cannot be tweened due to type mismatch (property is a 'nil', but given type is '%s')", tostring(k), typeof(v)), 2) end
			if actual ~= nil and typeof(actual) ~= typeof(v) then error(string.format("TweenService:Create property named '%s' cannot be tweened due to type mismatch (property is a '%s', but given type is '%s')", tostring(k), typeof(actual), typeof(v)), 2) end
		end
		local tw = I.nuevo("Tween")
		rawset(tw, "_objeto", inst)
		rawset(tw, "_info", info)
		rawset(tw, "_metas", metas)
		return tw
	end,
	GetValue = function(_, a) return a end,
	SmoothDamp = function(_, actual, objetivo) return objetivo, 0 end,
} })

---------------------------------------------------------------------------- TextService
local filtroDef = definir("TextFilterResult", "Instance", { noCreable = true })
local function filtrar(texto)
	local r = texto
	for _, p in ipairs(S.config.palabrasProhibidas) do
		r = r:gsub(p, string.rep("#", #p))
		r = r:gsub(p:upper(), string.rep("#", #p))
	end
	return r
end
filtroDef.metodos.GetNonChatStringForBroadcastAsync = function(f) return filtrar(f._texto) end
filtroDef.metodos.GetNonChatStringForUserAsync = function(f, userId)
	if type(userId) ~= "number" then error("Argument 1 missing or nil", 2) end
	return filtrar(f._texto)
end
filtroDef.metodos.GetChatForUserAsync = function(f, userId)
	if type(userId) ~= "number" then error("Argument 1 missing or nil", 2) end
	return filtrar(f._texto)
end
servicio("TextService", { metodos = {
	FilterStringAsync = function(_, texto, desde, contexto)
		if type(texto) ~= "string" then error("Unable to cast to string", 2) end
		if type(desde) ~= "number" then error("Unable to cast to int64 (userId)", 2) end
		if S.config.filtroFalla then error("TextService: el filtro de texto no está disponible (simulado)", 2) end
		P.ceder(0.02)
		Clases.TextFilterResult.noCreable = false
		local f = I.nuevo("TextFilterResult")
		Clases.TextFilterResult.noCreable = true
		rawset(f, "_texto", texto)
		return f
	end,
	FilterAndTranslateStringAsync = function(_, texto) return { FilteredMessage = filtrar(texto) } end,
	GetTextSize = function(_, texto, tam, fuente, marco) return Vector2.new(#tostring(texto) * (tam or 14) * 0.5, tam or 14) end,
	GetTextBoundsAsync = function(_, params) return Vector2.new(#tostring(params.Text or "") * (params.Size or 14) * 0.5, params.Size or 14) end,
	GetFamilyInfoAsync = function() return { Name = "Fuente", Faces = {} } end,
} })
Clases.Instance.props = Clases.Instance.props -- (sin cambios)
local gtbp = definir("GetTextBoundsParams", "Instance", { props = { Text = "", Size = 14, Width = math.huge, Font = T.Font.fromEnum(Enum.Font.Gotham), RichText = false } })

---------------------------------------------------------------------------- DataStoreService
local function serializable(v, ruta, vistos)
	local tv = type(v)
	if v == nil or tv == "boolean" or tv == "string" then return true end
	if tv == "number" then
		if v ~= v then return false, "NaN en " .. ruta end
		return true
	end
	if tv == "table" then
		if I.esInstancia(v) then return false, "Instance en " .. ruta end
		local mt = getmetatable(v)
		if mt and mt.__tipo then return false, mt.__tipo .. " en " .. ruta end
		vistos = vistos or {}
		if vistos[v] then return false, "referencia cíclica en " .. ruta end
		vistos[v] = true
		local tieneNum, tieneStr = false, false
		for k, x in pairs(v) do
			if type(k) == "number" then tieneNum = true elseif type(k) == "string" then tieneStr = true else return false, "clave de tipo " .. type(k) .. " en " .. ruta end
			local ok, err = serializable(x, ruta .. "." .. tostring(k), vistos)
			if not ok then return false, err end
		end
		if tieneNum and tieneStr then return false, "tabla mixta (array + diccionario) en " .. ruta end
		if tieneNum then
			local n = #v
			for k in pairs(v) do if type(k) == "number" and (k < 1 or k > n or k ~= math.floor(k)) then return false, "array con huecos o índices no enteros en " .. ruta end end
		end
		return true
	end
	return false, tv .. " en " .. ruta
end
S.serializable = serializable
local dsDef = definir("GlobalDataStore", "Instance", { noCreable = true })
definir("DataStore", "GlobalDataStore", { noCreable = true })
definir("OrderedDataStore", "GlobalDataStore", { noCreable = true })
local function comprobarDS()
	if S.config.datastoreFalla then error("502: API Services rejected request with error. HTTP 0 (simulado)", 3) end
	P.ceder(0.05)
end
local function serializar(v) return S.json(v) end
local function deserializar(s) if s == nil then return nil end return S.jsonDecode(s) end
dsDef.metodos.GetAsync = function(ds, clave)
	comprobarDS()
	if type(clave) ~= "string" or #clave == 0 or #clave > 50 then error("Key name can't be empty or longer than 50 characters", 2) end
	local almacen = S.datastores[ds._nombreDS]
	local v = almacen[clave]
	return deserializar(v), { Version = "1", CreatedTime = 0, UpdatedTime = 0, GetUserIds = function() return {} end, GetMetadata = function() return {} end }
end
dsDef.metodos.SetAsync = function(ds, clave, valor)
	comprobarDS()
	if type(clave) ~= "string" or #clave == 0 or #clave > 50 then error("Key name can't be empty or longer than 50 characters", 2) end
	local ok, err = serializable(valor, "valor")
	if not ok then error("Cannot store value in data store: " .. err, 2) end
	local s = serializar(valor)
	if #s > 4194304 then error("Value is too large (4MB)", 2) end
	S.datastores[ds._nombreDS][clave] = s
	return "1"
end
dsDef.metodos.UpdateAsync = function(ds, clave, f)
	comprobarDS()
	if type(clave) ~= "string" or #clave == 0 or #clave > 50 then error("Key name can't be empty or longer than 50 characters", 2) end
	local almacen = S.datastores[ds._nombreDS]
	local viejo = deserializar(almacen[clave])
	local nuevo = f(viejo, { Version = "1", GetUserIds = function() return {} end, GetMetadata = function() return {} end })
	if nuevo == nil then return viejo end
	local ok, err = serializable(nuevo, "valor")
	if not ok then error("Cannot store value in data store: " .. err, 2) end
	almacen[clave] = serializar(nuevo)
	return nuevo
end
dsDef.metodos.RemoveAsync = function(ds, clave)
	comprobarDS()
	local almacen = S.datastores[ds._nombreDS]
	local v = almacen[clave]
	almacen[clave] = nil
	return deserializar(v)
end
dsDef.metodos.IncrementAsync = function(ds, clave, delta)
	comprobarDS()
	local almacen = S.datastores[ds._nombreDS]
	local v = (deserializar(almacen[clave]) or 0) + (delta or 1)
	almacen[clave] = serializar(v)
	return v
end
dsDef.metodos.ListKeysAsync = function() error("simulador: ListKeysAsync no soportado", 2) end
dsDef.metodos.GetSortedAsync = function() return { IsFinished = true, GetCurrentPage = function() return {} end, AdvanceToNextPageAsync = function() end } end
local function obtenerDS(clase, nombre, ambito)
	if S.config.studioSinApi then error("You must publish this place to the web to access DataStore. (StudioAccessToApisNotAllowed, simulado)", 3) end
	local clave = clase .. ":" .. tostring(nombre) .. ":" .. tostring(ambito or "global")
	if not S.datastores[clave] then S.datastores[clave] = {} end
	Clases[clase].noCreable = false
	local ds = I.nuevo(clase)
	Clases[clase].noCreable = true
	ds._p.Name = tostring(nombre)
	rawset(ds, "_nombreDS", clave)
	return ds
end
servicio("DataStoreService", { props = { AutomaticRetry = true }, metodos = {
	GetDataStore = function(_, nombre, ambito) return obtenerDS("DataStore", nombre, ambito) end,
	GetGlobalDataStore = function() return obtenerDS("DataStore", "global") end,
	GetOrderedDataStore = function(_, nombre, ambito) return obtenerDS("OrderedDataStore", nombre, ambito) end,
	GetRequestBudgetForRequestType = function() return S.config.datastoreFalla and 0 or 100 end,
	ListDataStoresAsync = function() error("simulador: ListDataStoresAsync no soportado", 2) end,
} })
servicio("MemoryStoreService", { metodos = { GetSortedMap = function() error("simulador: MemoryStoreService no soportado", 2) end, GetQueue = function() error("simulador: MemoryStoreService no soportado", 2) end, GetHashMap = function() error("simulador: MemoryStoreService no soportado", 2) end } })

---------------------------------------------------------------------------- UserInputService / GuiService / ContextActionService (dependen del contexto)
local function ctxDisp() return P.contexto().dispositivo or "pc" end
servicio("UserInputService", {
	props = { MouseBehavior = Enum.MouseBehavior.Default, MouseIconEnabled = true, MouseDeltaSensitivity = 1, ModalEnabled = false, OverrideMouseIconBehavior = Enum.OverrideMouseIconBehavior.None },
	calc = {
		TouchEnabled = { get = function() local d = ctxDisp() return d == "movil" or d == "tableta" end },
		KeyboardEnabled = { get = function() return ctxDisp() == "pc" end },
		MouseEnabled = { get = function() return ctxDisp() == "pc" end },
		GamepadEnabled = { get = function() return ctxDisp() == "consola" end },
		AccelerometerEnabled = { get = function() return false end },
		GyroscopeEnabled = { get = function() return false end },
		VREnabled = { get = function() return false end },
		OnScreenKeyboardVisible = { get = function() return false end },
		OnScreenKeyboardSize = { get = function() return Vector2.zero end },
		OnScreenKeyboardPosition = { get = function() return Vector2.zero end },
		PreferredInput = { get = function() local d = ctxDisp() if d == "movil" or d == "tableta" then return Enum.PreferredInput.Touch elseif d == "consola" then return Enum.PreferredInput.Gamepad end return Enum.PreferredInput.KeyboardAndMouse end },
	},
	eventos = { InputBegan = true, InputEnded = true, InputChanged = true, LastInputTypeChanged = true, TouchStarted = true, TouchEnded = true, TouchMoved = true, TouchTap = true, TouchLongPress = true, GamepadConnected = true, GamepadDisconnected = true, WindowFocused = true, WindowFocusReleased = true, TextBoxFocused = true, TextBoxFocusReleased = true, JumpRequest = true, DeviceAccelerationChanged = true },
	metodos = {
		GetLastInputType = function() local d = ctxDisp() if d == "movil" or d == "tableta" then return Enum.UserInputType.Touch elseif d == "consola" then return Enum.UserInputType.Gamepad1 end return Enum.UserInputType.MouseMovement end,
		GetFocusedTextBox = function() return nil end,
		IsKeyDown = function() return false end,
		IsMouseButtonPressed = function() return false end,
		IsGamepadButtonDown = function() return false end,
		GetMouseLocation = function() return Vector2.new(640, 360) end,
		GetMouseDelta = function() return Vector2.zero end,
		GetConnectedGamepads = function() if ctxDisp() == "consola" then return { Enum.UserInputType.Gamepad1 } end return {} end,
		GetGamepadConnected = function() return ctxDisp() == "consola" end,
		GetNavigationGamepads = function() return {} end,
		GetKeysPressed = function() return {} end,
		GetMouseButtonsPressed = function() return {} end,
		GetStringForKeyCode = function(_, k) return k.Name end,
		GetImageForKeyCode = function() return "" end,
		GetGamepadState = function() return {} end,
		GetSupportedGamepadKeyCodes = function() return {} end,
		GamepadSupports = function() return false end,
		GetDeviceType = function() local d = ctxDisp() if d == "movil" then return Enum.DeviceType.Phone elseif d == "tableta" then return Enum.DeviceType.Tablet end return Enum.DeviceType.Desktop end,
	},
})
servicio("GuiService", {
	props = { AutoSelectGuiEnabled = true, GuiNavigationEnabled = true, CoreGuiNavigationEnabled = true, TouchControlsEnabled = true, SelectedCoreObject = NIL, ReducedMotionEnabled = false, PreferredTextSize = Enum.PreferredTextSize.Medium },
	calc = {
		SelectedObject = { get = function() return P.contexto().seleccionado end, set = function(_, v) P.contexto().seleccionado = v end },
		MenuIsOpen = { get = function() return false end },
		IsModalDialog = { get = function() return false end },
		IsWindows = { get = function() return true end },
		TopbarInset = { get = function() return T.Rect.new(0, 0, 1280, 58) end },
		ViewportDisplaySize = { get = function() return Enum.DisplaySize.Medium end },
	},
	eventos = { MenuOpened = true, MenuClosed = true, UiMessageChanged = true },
	metodos = {
		GetGuiInset = function() return Vector2.new(0, 58), Vector2.new(0, 0) end,
		IsTenFootInterface = function() return ctxDisp() == "consola" end,
		AddSelectionParent = function() end, RemoveSelectionGroup = function() end, Select = function() end,
		InspectPlayerFromUserId = function() end, CloseInspectMenu = function() end, GetEmotesMenuOpen = function() return false end, SetEmotesMenuOpen = function() end,
		GetInspectMenuEnabled = function() return false end, SetInspectMenuEnabled = function() end,
	},
})
servicio("ContextActionService", { metodos = {
	BindAction = function() end, BindActionAtPriority = function() end, UnbindAction = function() end, UnbindAllActions = function() end,
	SetTitle = function() end, SetImage = function() end, SetPosition = function() end, SetDescription = function() end,
	GetButton = function() return nil end, GetAllBoundActionInfo = function() return {} end, GetBoundActionInfo = function() return {} end,
	BindCoreAction = function() end, UnbindCoreAction = function() end,
}, eventos = { LocalToolEquipped = true, LocalToolUnequipped = true } })
servicio("TouchInputService", {})
servicio("KeyframeSequenceProvider", {})

---------------------------------------------------------------------------- Players / Player / personajes
local jugadores = Clases.Player
jugadores.props = {
	UserId = 0, DisplayName = "", Character = NIL, Team = NIL, TeamColor = T.BrickColor.new("White"), Neutral = true,
	AccountAge = 365, MembershipType = Enum.MembershipType.None, LocaleId = "es-es", CameraMode = Enum.CameraMode.Classic,
	CameraMaxZoomDistance = 128, CameraMinZoomDistance = 0.5, DevEnableMouseLock = true, AutoJumpEnabled = true,
	CanLoadCharacterAppearance = true, CharacterAppearanceId = 0, FollowUserId = 0, GameplayPaused = false,
	HealthDisplayDistance = 100, NameDisplayDistance = 100, RespawnLocation = NIL, ReplicationFocus = NIL,
	DevComputerCameraMode = Enum.DevComputerCameraMovementMode.UserChoice, DevComputerMovementMode = Enum.DevComputerMovementMode.UserChoice,
	DevTouchCameraMode = Enum.DevTouchCameraMovementMode.UserChoice, DevTouchMovementMode = Enum.DevTouchMovementMode.UserChoice,
	DevCameraOcclusionMode = Enum.DevCameraOcclusionMode.Zoom, HasVerifiedBadge = false,
}
jugadores.ro = { UserId = true, AccountAge = true, MembershipType = true, LocaleId = true }
jugadores.eventos = { CharacterAdded = true, CharacterRemoving = true, CharacterAppearanceLoaded = true, Chatted = true, Idled = true, OnTeleport = true }
jugadores.noCreable = true
jugadores.alCambiar = {
	Team = function(pl, team)
		if team then pl._p.TeamColor = team._p.TeamColor or pl._p.TeamColor pl._p.Neutral = false else pl._p.Neutral = true end
	end,
}
local JM = jugadores.metodos
local function jugadorDe(personaje)
	local plrs = game:FindService("Players")
	if not plrs then return nil end
	for _, p in ipairs(plrs._hijos) do
		if p:IsA("Player") and p._p.Character == personaje then return p end
	end
	return nil
end
S.jugadorDe = jugadorDe
local function puntoAparicion()
	local ws = game:GetService("Workspace")
	for _, d in ipairs(ws._hijos) do
		if d:IsA("SpawnLocation") and d._p.Enabled ~= false then
			return d.Position + Vector3.new(0, 3, 0)
		end
	end
	return Vector3.new(0, 5, 0)
end
local function nuevaParte(clase, nombre, tam, cf, padre)
	local p = I.nuevo(clase)
	p._p.Name = nombre
	p._p.Size = tam
	p._p.CFrame = cf
	p._p.Anchored = true
	p.Parent = padre
	return p
end
function S.crearPersonaje(pl)
	local ws = game:GetService("Workspace")
	local viejo = pl._p.Character
	if viejo and viejo ~= NIL then
		local s = I.senalSiExiste(pl, "CharacterRemoving")
		if s then P.disparar(s, nil, viejo) end
		if not viejo._destruido then viejo:Destroy() end
	end
	local m = I.nuevo("Model")
	m._p.Name = pl._p.Name
	local pos = puntoAparicion()
	local hrp = nuevaParte("Part", "HumanoidRootPart", Vector3.new(2, 2, 1), CFrame.new(pos), m)
	hrp._p.Transparency = 1
	hrp._p.CanCollide = false
	nuevaParte("Part", "Head", Vector3.new(1.2, 1.2, 1.2), CFrame.new(pos + Vector3.new(0, 2, 0)), m)
	nuevaParte("Part", "UpperTorso", Vector3.new(2, 1.6, 1), CFrame.new(pos + Vector3.new(0, 0.5, 0)), m)
	nuevaParte("Part", "RightHand", Vector3.new(0.4, 0.4, 0.4), CFrame.new(pos + Vector3.new(1.5, -0.5, 0)), m)
	nuevaParte("Part", "LeftHand", Vector3.new(0.4, 0.4, 0.4), CFrame.new(pos + Vector3.new(-1.5, -0.5, 0)), m)
	local att = I.nuevo("Attachment") att._p.Name = "RightGripAttachment" att.Parent = m.RightHand
	m._p.PrimaryPart = hrp
	local h = I.nuevo("Humanoid")
	h._p.Name = "Humanoid"
	h._p.DisplayName = pl._p.DisplayName
	h.Parent = m
	local an = I.nuevo("Animator") an._p.Name = "Animator" an.Parent = h
	local sp = game:GetService("StarterPlayer")
	if sp:FindFirstChild("StarterCharacterScripts") then
		for _, x in ipairs(sp.StarterCharacterScripts._hijos) do local c = x:Clone() if c then c.Parent = m end end
	end
	m.Parent = ws
	pl.Character = m
	local s = I.senalSiExiste(pl, "CharacterAdded")
	if s then P.disparar(s, nil, m) end
	if S.alPersonaje then S.alPersonaje(pl, m) end
	return m
end
JM.LoadCharacter = function(pl) S.crearPersonaje(pl) end
JM.LoadCharacterAsync = JM.LoadCharacter
JM.Kick = function(pl, mensaje)
	table.insert(S.expulsiones, { jugador = pl._p.Name, userId = pl._p.UserId, mensaje = mensaje or "", t = P.ahora })
	S.quitarJugador(pl)
end
JM.GetRankInGroup = function(pl, gid)
	local r = S.config.rangosGrupo[pl._p.UserId]
	return (r and r[gid]) or 0
end
JM.GetRoleInGroup = function(pl, gid) local r = JM.GetRankInGroup(pl, gid) return r > 0 and "Miembro" or "Guest" end
JM.IsInGroup = function(pl, gid) return JM.GetRankInGroup(pl, gid) > 0 end
JM.GetNetworkPing = function() return 0.05 end
JM.IsFriendsWith = function() return false end
JM.GetFriendsOnline = function() return {} end
JM.GetJoinData = function() return {} end
JM.ClearCharacterAppearance = function() end
JM.HasAppearanceLoaded = function() return true end
JM.RequestStreamAroundAsync = function() end
JM.SetSuperSafeChat = function() end
JM.GetUnder13 = function() return false end
JM.DistanceFromCharacter = function(pl, punto)
	local c = pl._p.Character
	if not c or c == NIL then return 0 end
	local h = I.buscarHijo(c, "HumanoidRootPart")
	return h and (h.Position - punto).Magnitude or 0
end
JM.GetMouse = function(pl)
	return {
		Hit = CFrame.new(0, 0, 0), Target = nil, X = 640, Y = 360, UnitRay = T.Ray.new(Vector3.zero, Vector3.zAxis), Origin = CFrame.identity, Icon = "", TargetFilter = nil,
		Button1Down = P.nuevaSenal("Button1Down"), Button1Up = P.nuevaSenal("Button1Up"), Button2Down = P.nuevaSenal("Button2Down"), Button2Up = P.nuevaSenal("Button2Up"),
		Move = P.nuevaSenal("Move"), WheelForward = P.nuevaSenal("WheelForward"), WheelBackward = P.nuevaSenal("WheelBackward"), KeyDown = P.nuevaSenal("KeyDown"), KeyUp = P.nuevaSenal("KeyUp"),
	}
end
I.alMorir = function(h)
	local m = h._padre
	if not m then return end
	local pl = jugadorDe(m)
	if not pl then return end
	local plrs = game:GetService("Players")
	if plrs._p.CharacterAutoLoads == false then return end
	local t = plrs._p.RespawnTime or 5
	P.task.delay(t, function()
		if pl._padre and pl._p.Character == m then S.crearPersonaje(pl) end
	end)
end

servicio("Players", {
	props = { MaxPlayers = 60, PreferredPlayers = 60, RespawnTime = 5, CharacterAutoLoads = true, BubbleChat = true, ClassicChat = false, UseStrafingAnimations = false, BanningEnabled = true },
	eventos = { PlayerAdded = true, PlayerRemoving = true, PlayerMembershipChanged = true },
	calc = {
		LocalPlayer = { get = function() return P.contexto().jugador end },
		NumPlayers = { get = function(plrs) local n = 0 for _, h in ipairs(plrs._hijos) do if h:IsA("Player") then n = n + 1 end end return n end },
	},
	metodos = {
		GetPlayers = function(plrs) local r = {} for _, h in ipairs(plrs._hijos) do if h:IsA("Player") then r[#r + 1] = h end end return r end,
		GetPlayerByUserId = function(plrs, id) for _, h in ipairs(plrs._hijos) do if h:IsA("Player") and h._p.UserId == id then return h end end return nil end,
		GetPlayerFromCharacter = function(_, c) if not c then return nil end return jugadorDe(c) end,
		GetUserIdFromNameAsync = function() return 1 end,
		GetNameFromUserIdAsync = function(_, id) return "Usuario" .. tostring(id) end,
		GetHumanoidDescriptionFromUserId = function() return I.nuevo("HumanoidDescription") end,
		GetUserThumbnailAsync = function() return "rbxasset://textures/ui/GuiImagePlaceholder.png", true end,
		CreateHumanoidModelFromDescription = function() return I.nuevo("Model") end,
		BanAsync = function() end, UnbanAsync = function() end, GetBanHistoryAsync = function() return {} end,
		GetFriendsAsync = function() return { IsFinished = true, GetCurrentPage = function() return {} end, AdvanceToNextPageAsync = function() end } end,
	},
})

function S.crearJugador(nombre, userId, opciones)
	opciones = opciones or {}
	local plrs = game:GetService("Players")
	Clases.Player.noCreable = false
	local pl = I.nuevo("Player")
	Clases.Player.noCreable = true
	pl._p.Name = nombre
	pl._p.UserId = userId
	pl._p.DisplayName = opciones.displayName or nombre
	for _, c in ipairs({ { "Backpack", "Backpack" }, { "PlayerGui", "PlayerGui" }, { "PlayerScripts", "PlayerScripts" }, { "StarterGear", "StarterGear" } }) do
		local x = I.nuevo(c[1])
		x._p.Name = c[2]
		x.Parent = pl
	end
	pl.Parent = plrs
	-- TextSources en los canales por defecto
	local tcs = game:GetService("TextChatService")
	local canales = tcs:FindFirstChild("TextChannels")
	if canales then
		for _, c in ipairs(canales._hijos) do if c:IsA("TextChannel") then canal.metodos.AddUserAsync(c, userId) end end
	end
	local s = I.senalSiExiste(plrs, "PlayerAdded")
	if s then P.disparar(s, nil, pl) end
	if plrs._p.CharacterAutoLoads ~= false and opciones.sinPersonaje ~= true then
		P.task.defer(function() if pl._padre then S.crearPersonaje(pl) end end)
	end
	return pl
end

function S.quitarJugador(pl)
	if not pl._padre then return end
	local plrs = game:GetService("Players")
	local s = I.senalSiExiste(plrs, "PlayerRemoving")
	if s then P.disparar(s, nil, pl) end
	local c = pl._p.Character
	if c and c ~= NIL and not c._destruido then
		local s2 = I.senalSiExiste(pl, "CharacterRemoving")
		if s2 then P.disparar(s2, nil, c) end
		c:Destroy()
	end
	pl:Destroy()
end

---------------------------------------------------------------------------- remotos
local re = Clases.RemoteEvent
re.eventos.OnClientEvent = nil
local function exigirCliente(nombreMetodo)
	local ctx = P.contexto()
	if ctx.lado ~= "cliente" then error(nombreMetodo .. " can only be called from the client", 3) end
	return ctx
end
local function exigirServidor(nombreMetodo)
	local ctx = P.contexto()
	if ctx.lado == "cliente" then error(nombreMetodo .. " can only be called from the server", 3) end
	return ctx
end
local function senalCliente(remoto)
	local s = I.senal(remoto, "OnClientEvent")
	if not rawget(s, "_alConectar") then
		rawset(s, "_alConectar", function(con)
			local jug = con._ctx.jugador
			local pend = rawget(remoto, "_pendientes")
			if jug and pend and pend[jug] then
				local lista = pend[jug]
				pend[jug] = nil
				for _, args in ipairs(lista) do
					P.task.defer(function() P.disparar(s, function(c) return c._ctx.jugador == jug end, table.unpack(args, 1, args.n)) end)
				end
			end
		end)
	end
	return s
end
re.calc.OnClientEvent = { get = function(r) return senalCliente(r) end }
re.metodos.FireServer = function(r, ...)
	local ctx = exigirCliente("FireServer")
	local jug = ctx.jugador
	local args = copiarArgs(...)
	S.estadisticas.fireServer = S.estadisticas.fireServer + 1
	P.task.defer(function()
		local s = I.senalSiExiste(r, "OnServerEvent")
		if s and jug._padre then P.disparar(s, function(c) return c._ctx.lado ~= "cliente" end, jug, table.unpack(args, 1, args.n)) end
	end)
end
local function entregarACliente(r, jug, args)
	local s = senalCliente(r)
	local hay = false
	for _, c in ipairs(s._conexiones) do if c.Connected and c._ctx.jugador == jug then hay = true break end end
	if hay then
		P.task.defer(function() P.disparar(s, function(c) return c._ctx.jugador == jug end, table.unpack(args, 1, args.n)) end)
	else
		local pend = rawget(r, "_pendientes")
		if not pend then pend = {} rawset(r, "_pendientes", pend) end
		pend[jug] = pend[jug] or {}
		if #pend[jug] < 256 then table.insert(pend[jug], args) end
	end
	if S.alEnviarCliente then S.alEnviarCliente(r, jug, args) end
end
re.metodos.FireClient = function(r, jug, ...)
	exigirServidor("FireClient")
	if not (I.esInstancia(jug) and jug:IsA("Player")) then error("FireClient: player argument must be a Player object", 2) end
	S.estadisticas.fireClient = S.estadisticas.fireClient + 1
	entregarACliente(r, jug, copiarArgs(...))
end
re.metodos.FireAllClients = function(r, ...)
	exigirServidor("FireAllClients")
	local args = copiarArgs(...)
	for _, jug in ipairs(game:GetService("Players"):GetPlayers()) do
		S.estadisticas.fireClient = S.estadisticas.fireClient + 1
		entregarACliente(r, jug, args)
	end
end
S.estadisticas = { fireServer = 0, fireClient = 0, invokeServer = 0 }

local rf = Clases.RemoteFunction
rf.props = { OnServerInvoke = NIL, OnClientInvoke = NIL }
local function invocar(callback, ctxDestino, ...)
	local hecho, res = false, nil
	local args = copiarArgs(...)
	P.ejecutar(function()
		res = table.pack(pcall(callback, table.unpack(args, 1, args.n)))
		hecho = true
	end, ctxDestino)
	local inicio = P.ahora
	while not hecho do
		if P.ahora - inicio > 60 then error("simulador: la invocación remota no respondió en 60 s", 3) end
		P.ceder(0)
	end
	if not res[1] then error(tostring(res[2]), 0) end
	local r = {}
	for i = 2, res.n do r[i - 1] = copiar(res[i]) end
	return table.unpack(r, 1, res.n - 1)
end
rf.metodos.InvokeServer = function(r, ...)
	local ctx = exigirCliente("InvokeServer")
	S.estadisticas.invokeServer = S.estadisticas.invokeServer + 1
	local inicio = P.ahora
	while r._p.OnServerInvoke == nil or r._p.OnServerInvoke == NIL do
		if P.ahora - inicio > 30 then error("simulador: OnServerInvoke no asignado tras 30 s en " .. I.ruta(r), 2) end
		P.ceder(0.1)
	end
	return invocar(r._p.OnServerInvoke, P.ctxServidor, ctx.jugador, ...)
end
rf.metodos.InvokeClient = function(r, jug, ...)
	exigirServidor("InvokeClient")
	local ctxCliente = S.contextosCliente and S.contextosCliente[jug]
	if not ctxCliente then error("simulador: el jugador no tiene cliente simulado", 2) end
	local cb = r._p.OnClientInvoke
	if cb == nil or cb == NIL then error("OnClientInvoke no asignado", 2) end
	return invocar(cb, ctxCliente, ...)
end
local be = Clases.BindableEvent
be.metodos.Fire = function(b, ...)
	local args = copiarArgs(...)
	local s = I.senalSiExiste(b, "Event")
	if s then P.disparar(s, nil, table.unpack(args, 1, args.n)) end
end
local bf = Clases.BindableFunction
bf.props = { OnInvoke = NIL }
bf.metodos.Invoke = function(b, ...)
	local cb = b._p.OnInvoke
	if cb == nil or cb == NIL then error("BindableFunction: OnInvoke no asignado", 2) end
	local args = copiarArgs(...)
	local res = table.pack(cb(table.unpack(args, 1, args.n)))
	local r = {}
	for i = 1, res.n do r[i] = copiar(res[i]) end
	return table.unpack(r, 1, res.n)
end

---------------------------------------------------------------------------- Team
Clases.Team.metodos.GetPlayers = function(t)
	local r = {}
	for _, p in ipairs(game:GetService("Players"):GetPlayers()) do if p._p.Team == t then r[#r + 1] = p end end
	return r
end

---------------------------------------------------------------------------- arranque del DataModel
function S.crearJuego()
	Clases.DataModel.noCreable = false
	game = I.nuevo("DataModel")
	Clases.DataModel.noCreable = true
	game._p.Name = "Colegio RP (simulación)"
	S.game = game
	for _, n in ipairs({ "Workspace", "Players", "Lighting", "ReplicatedFirst", "ReplicatedStorage", "ServerScriptService", "ServerStorage", "StarterGui", "StarterPack", "StarterPlayer", "Teams", "SoundService", "TextChatService", "Chat" }) do
		crearServicio(n)
	end
	return game
end
function S.indiceEspacialListo() return indice ~= nil end
function S.reiniciarIndice() indice = nil end

return S
