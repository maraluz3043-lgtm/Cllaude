-- Modelo de instancias de Roblox para el simulador: jerarquía, propiedades con tipos y valores por defecto,
-- atributos, tags, señales perezosas, clases con comportamiento (BasePart, Model, Seat, Humanoid, GUI...).
--
-- Política de miembros desconocidos (para detectar errores reales sin falsos positivos excesivos):
--   · Leer un miembro inexistente y nunca escrito -> error al estilo Roblox ("X is not a valid member of ...").
--   · Escribir una propiedad no declarada -> se acepta y se anota como AVISO "propiedad no declarada" para
--     revisarla (puede ser una propiedad real que el simulador no modela, o un error tipográfico del juego).

local P = require("planificador")
local T = require("tipos")
local Vector3, Vector2, CFrame, Color3, UDim, UDim2, Enum = T.Vector3, T.Vector2, T.CFrame, T.Color3, T.UDim, T.UDim2, T.Enum
local typeof = T.typeof

local I = {}
I.avisosPropiedades = {}   -- "Clase.Prop" -> contador
I.pantalla = Vector2.new(1280, 720)
local NIL = {}             -- centinela para propiedades con valor nil explícito
I.NIL = NIL
local contadorId = 0

---------------------------------------------------------------------------- definición de clases
local Clases = {}
I.Clases = Clases

local EVENTOS = {}
for _, n in ipairs({
	"ChildAdded", "ChildRemoved", "DescendantAdded", "DescendantRemoving", "AncestryChanged", "Changed", "AttributeChanged", "Destroying",
	"Touched", "TouchEnded", "MouseButton1Click", "MouseButton1Down", "MouseButton1Up", "MouseButton2Click", "MouseButton2Down", "MouseButton2Up",
	"Activated", "MouseEnter", "MouseLeave", "MouseMoved", "MouseWheelForward", "MouseWheelBackward", "InputBegan", "InputEnded", "InputChanged",
	"SelectionGained", "SelectionLost", "FocusLost", "Focused", "ReturnPressedFromOnScreenKeyboard", "TouchTap", "TouchLongPress", "TouchPan", "TouchPinch", "TouchSwipe", "TouchRotate",
	"Triggered", "TriggerEnded", "PromptButtonHoldBegan", "PromptButtonHoldEnded", "PromptShown", "PromptHidden",
	"OnServerEvent", "OnClientEvent", "Event", "Completed", "DidLoop", "Ended", "Played", "Paused", "Resumed", "Stopped", "Loaded",
	"CharacterAdded", "CharacterRemoving", "CharacterAppearanceLoaded", "Chatted", "Idled", "OnTeleport",
	"Died", "Seated", "StateChanged", "Running", "HealthChanged", "Jumping", "MoveToFinished", "AnimationPlayed", "FreeFalling", "GettingUp", "Climbing", "Swimming", "PlatformStanding", "FallingDown", "Ragdoll", "StateEnabledChanged",
	"MouseClick", "RightMouseClick", "MouseHoverEnter", "MouseHoverLeave",
	"Equipped", "Unequipped", "Deactivated",
	"MessageReceived", "ShouldDeliverCallback", "OnIncomingMessage", "SendingMessage", "MessageReceived",
	"ReachedTarget", "KeyframeReached",
}) do EVENTOS[n] = true end
I.EVENTOS = EVENTOS

local function definir(nombre, padre, def)
	def = def or {}
	def.nombre = nombre
	def.padre = padre
	def.props = def.props or {}
	def.metodos = def.metodos or {}
	def.calc = def.calc or {}      -- propiedades calculadas: nombre -> { get = f(inst), set = f(inst, v) | nil }
	def.ro = def.ro or {}          -- propiedades de solo lectura
	def.eventos = def.eventos or {}
	Clases[nombre] = def
	return def
end
I.definir = definir

local function cadena(def)
	local lista = {}
	local d = def
	while d do
		lista[#lista + 1] = d
		d = d.padre and Clases[d.padre]
	end
	return lista
end

local function miembros(def)
	if def._miembros then return def._miembros end
	local m = {}
	local lista = cadena(def)
	for i = #lista, 1, -1 do
		local d = lista[i]
		for k, v in pairs(d.props) do m[k] = { t = "p", def = v, ro = d.ro[k] } end
		for k, v in pairs(d.calc) do m[k] = { t = "c", get = v.get, set = v.set } end
		for k, v in pairs(d.metodos) do m[k] = { t = "m", f = v } end
		for k in pairs(d.eventos) do m[k] = { t = "e" } end
	end
	def._miembros = m
	return m
end

function I.esClase(nombreClase, nombreBuscado)
	local d = Clases[nombreClase]
	while d do
		if d.nombre == nombreBuscado then return true end
		d = d.padre and Clases[d.padre]
	end
	return false
end

---------------------------------------------------------------------------- metatabla de instancias
local InstMT = { __tipo = "Instance" }
I.InstMT = InstMT
local function esInstancia(x) return getmetatable(x) == InstMT end
I.esInstancia = esInstancia

local function senal(inst, clave)
	local s = inst._senales
	if not s then s = {} rawset(inst, "_senales", s) end
	local x = s[clave]
	if not x then x = P.nuevaSenal(clave) s[clave] = x end
	return x
end
I.senal = senal
local function senalSiExiste(inst, clave)
	local s = inst._senales
	return s and s[clave]
end
I.senalSiExiste = senalSiExiste

local function buscarHijo(inst, nombre)
	for _, h in ipairs(inst._hijos) do
		if h._p.Name == nombre then return h end
	end
	return nil
end
I.buscarHijo = buscarHijo

function I.ruta(inst)
	local partes = {}
	local cur = inst
	while cur and cur._c.nombre ~= "DataModel" do
		table.insert(partes, 1, cur._p.Name)
		cur = cur._padre
	end
	return table.concat(partes, ".")
end

local function notificarCambio(inst, prop)
	if not inst._senales then return end
	local s = inst._senales["prop:" .. prop]
	if s then P.disparar(s, nil) end
	local c = inst._senales.Changed
	if c then
		if inst._c.esValor and prop == "Value" then
			P.disparar(c, nil, inst._p.Value ~= NIL and inst._p.Value or nil)
		else
			P.disparar(c, nil, prop)
		end
	end
end
I.notificarCambio = notificarCambio

-- tipos esperados por propiedad (inferidos del valor por defecto si no se declaran)
local function tipoEsperado(defecto)
	if defecto == NIL then return nil end
	local t = typeof(defecto)
	if t == "EnumItem" then return "EnumItem:" .. defecto.EnumType._nombre end
	return t
end

local function coaccionar(inst, prop, v, defecto)
	local esperado = tipoEsperado(defecto)
	if not esperado then return v end
	if v == nil then
		if esperado == "Instance" then return v end
		error(string.format("Unable to assign property %s. %s expected, got nil", prop, esperado), 3)
	end
	local tv = typeof(v)
	if esperado == tv then return v end
	if esperado == "number" and tv == "string" and tonumber(v) then return tonumber(v) end
	if esperado == "string" and tv == "number" then return tostring(v) end
	if esperado:sub(1, 9) == "EnumItem:" then
		local nombreEnum = esperado:sub(10)
		if tv == "EnumItem" then
			if v.EnumType._nombre == nombreEnum then return v end
		elseif tv == "string" then
			return Enum[nombreEnum][v]
		elseif tv == "number" then
			local e = Enum[nombreEnum]:FromValue(v)
			if e then return e end
		end
		error(string.format("Unable to assign property %s. Expected Enum.%s, got %s", prop, nombreEnum, tostring(v)), 3)
	end
	if esperado == "boolean" then
		error(string.format("Unable to assign property %s. bool expected, got %s", prop, tv), 3)
	end
	error(string.format("Unable to assign property %s. %s expected, got %s", prop, esperado, tv), 3)
end

local function establecerPadre(inst, nuevo)
	if inst._destruido then
		error(string.format("The Parent property of %s is locked, current parent: NULL, new parent %s", inst._p.Name, nuevo and nuevo._p.Name or "NULL"), 3)
	end
	if nuevo ~= nil and not esInstancia(nuevo) then error("Unable to assign property Parent. Instance expected, got " .. typeof(nuevo), 3) end
	local viejo = inst._padre
	if viejo == nuevo then return end
	if nuevo then
		local cur = nuevo
		while cur do
			if cur == inst then error("Attempt to set " .. inst._p.Name .. " as its own parent", 3) end
			cur = cur._padre
		end
	end
	if viejo then
		-- DescendantRemoving en los ancestros
		local anc = viejo
		while anc do
			local s = senalSiExiste(anc, "DescendantRemoving")
			if s then P.disparar(s, nil, inst) end
			anc = anc._padre
		end
		local hijos = viejo._hijos
		for i = #hijos, 1, -1 do
			if hijos[i] == inst then table.remove(hijos, i) break end
		end
		local s = senalSiExiste(viejo, "ChildRemoved")
		if s then P.disparar(s, nil, inst) end
	end
	rawset(inst, "_padre", nuevo)
	inst._p.Parent = nuevo or NIL
	if nuevo then
		table.insert(nuevo._hijos, inst)
		if I.alEntrar then I.alEntrar(inst, nuevo) end
		local s = senalSiExiste(nuevo, "ChildAdded")
		if s then P.disparar(s, nil, inst) end
		local anc = nuevo
		while anc do
			local sd = senalSiExiste(anc, "DescendantAdded")
			if sd then
				P.disparar(sd, nil, inst)
				for _, d in ipairs(inst:GetDescendants()) do P.disparar(sd, nil, d) end
			end
			anc = anc._padre
		end
	end
	local sa = senalSiExiste(inst, "AncestryChanged")
	if sa then P.disparar(sa, nil, inst, nuevo) end
	notificarCambio(inst, "Parent")
end

local INTERNOS = {}
for _, n in ipairs({ "_c", "_p", "_hijos", "_id", "_senales", "_padre", "_attrs", "_tags", "_destruido", "_celdas", "_dueno", "_archivo", "_foco", "_estado", "_version", "_objeto", "_info", "_metas", "_texto", "_nombreDS", "_pendientes" }) do INTERNOS[n] = true end
I.INTERNOS = INTERNOS

InstMT.__index = function(inst, k)
	if INTERNOS[k] then return nil end
	local def = rawget(inst, "_c")
	local m = miembros(def)[k]
	if m then
		local t = m.t
		if t == "p" then
			local v = inst._p[k]
			if v == nil then
				v = m.def
				if type(v) == "function" then v = v(inst) inst._p[k] = v end
			end
			if v == NIL then return nil end
			return v
		elseif t == "m" then
			return m.f
		elseif t == "c" then
			return m.get(inst)
		elseif t == "e" then
			return senal(inst, k)
		end
	end
	local v = inst._p[k]
	if v ~= nil then
		if v == NIL then return nil end
		return v
	end
	local h = buscarHijo(inst, k)
	if h then return h end
	if EVENTOS[k] then return senal(inst, k) end
	error(string.format("%s is not a valid member of %s \"%s\"", tostring(k), def.nombre, I.ruta(inst)), 2)
end

InstMT.__newindex = function(inst, k, v)
	if INTERNOS[k] then rawset(inst, k, v) return end
	local def = inst._c
	if k == "Parent" then return establecerPadre(inst, v) end
	local m = miembros(def)[k]
	if m then
		if m.t == "p" then
			if m.ro then error("Unable to assign property " .. k .. ". Property is read only", 2) end
			local defecto = m.def
			if type(defecto) == "function" then defecto = defecto(inst) end
			v = coaccionar(inst, k, v, defecto)
			local viejo = inst._p[k]
			if v == nil then inst._p[k] = NIL else inst._p[k] = v end
			if viejo ~= inst._p[k] then
				-- el manejador alCambiar más específico de la cadena de herencia
				local lista = cadena(def)
				for i = 1, #lista do
					local d = lista[i]
					if d.alCambiar and d.alCambiar[k] then d.alCambiar[k](inst, v, viejo) break end
				end
				notificarCambio(inst, k)
			end
			return
		elseif m.t == "c" then
			if not m.set then error("Unable to assign property " .. k .. ". Property is read only", 2) end
			m.set(inst, v)
			return
		else
			error("Unable to assign property " .. k .. ". It is not a property", 2)
		end
	end
	-- propiedad no declarada: se acepta y se registra como aviso
	local clave = def.nombre .. "." .. tostring(k)
	I.avisosPropiedades[clave] = (I.avisosPropiedades[clave] or 0) + 1
	local viejo = inst._p[k]
	if v == nil then inst._p[k] = NIL else inst._p[k] = v end
	if viejo ~= inst._p[k] then notificarCambio(inst, k) end
end

InstMT.__tostring = function(inst) return inst._p.Name end
InstMT.__eq = function(a, b) return rawequal(a, b) end

function I.nuevo(clase, padre)
	local def = Clases[clase]
	if not def or def.noCreable then error(string.format("Unable to create an Instance of type \"%s\"", tostring(clase)), 2) end
	contadorId = contadorId + 1
	local inst = setmetatable({ _c = def, _p = { Name = clase }, _hijos = {}, _id = contadorId }, InstMT)
	if def.alCrear then def.alCrear(inst) end
	local lista = cadena(def)
	for i = #lista, 2, -1 do
		if lista[i].alCrearBase then lista[i].alCrearBase(inst) end
	end
	if def.alCrearBase then def.alCrearBase(inst) end
	if padre then inst.Parent = padre end
	return inst
end

---------------------------------------------------------------------------- Instance (base)
local base = definir("Instance", nil, {
	props = { Name = "Instance", Archivable = true, Parent = NIL },
	ro = {},
})
base.calc.ClassName = { get = function(inst) return inst._c.nombre end }
local M = base.metodos

function M.GetChildren(inst)
	local r = {}
	for i, h in ipairs(inst._hijos) do r[i] = h end
	return r
end
function M.GetDescendants(inst)
	local r = {}
	local pila = { inst }
	local n = 0
	while #pila > 0 do
		local x = table.remove(pila)
		local hijos = x._hijos
		for i = #hijos, 1, -1 do pila[#pila + 1] = hijos[i] end
		if x ~= inst then n = n + 1 r[n] = x end
	end
	return r
end
function M.FindFirstChild(inst, nombre, recursivo)
	if type(nombre) ~= "string" then error("Argument 1 missing or nil", 2) end
	local h = buscarHijo(inst, nombre)
	if h or not recursivo then return h end
	for _, d in ipairs(inst:GetDescendants()) do
		if d._p.Name == nombre then return d end
	end
	return nil
end
function M.FindFirstDescendant(inst, nombre) return M.FindFirstChild(inst, nombre, true) end
function M.FindFirstChildOfClass(inst, clase)
	for _, h in ipairs(inst._hijos) do if h._c.nombre == clase then return h end end
	return nil
end
function M.FindFirstChildWhichIsA(inst, clase, recursivo)
	local lista = recursivo and inst:GetDescendants() or inst._hijos
	for _, h in ipairs(lista) do if I.esClase(h._c.nombre, clase) then return h end end
	return nil
end
function M.FindFirstAncestor(inst, nombre)
	local cur = inst._padre
	while cur do if cur._p.Name == nombre then return cur end cur = cur._padre end
	return nil
end
function M.FindFirstAncestorOfClass(inst, clase)
	local cur = inst._padre
	while cur do if cur._c.nombre == clase then return cur end cur = cur._padre end
	return nil
end
function M.FindFirstAncestorWhichIsA(inst, clase)
	local cur = inst._padre
	while cur do if I.esClase(cur._c.nombre, clase) then return cur end cur = cur._padre end
	return nil
end
function M.WaitForChild(inst, nombre, plazo)
	local h = buscarHijo(inst, nombre)
	if h then return h end
	local inicio = P.ahora
	local avisado = false
	while true do
		P.ceder(0.1)
		h = buscarHijo(inst, nombre)
		if h then return h end
		if plazo and P.ahora - inicio >= plazo then return nil end
		if not plazo and not avisado and P.ahora - inicio >= 5 then
			avisado = true
			table.insert(P.avisos, { t = P.ahora, mensaje = "Infinite yield possible on '" .. I.ruta(inst) .. ":WaitForChild(\"" .. nombre .. "\")'" })
		end
		if not plazo and P.ahora - inicio >= 600 then return nil end
	end
end
function M.IsA(inst, clase) return I.esClase(inst._c.nombre, clase) end
function M.IsDescendantOf(inst, otro)
	local cur = inst._padre
	while cur do if cur == otro then return true end cur = cur._padre end
	return false
end
function M.IsAncestorOf(inst, otro) return M.IsDescendantOf(otro, inst) end
function M.GetFullName(inst) return I.ruta(inst) end
function M.GetDebugId(inst) return tostring(inst._id) end
function M.GetActor() return nil end
function M.ClearAllChildren(inst)
	local hijos = inst:GetChildren()
	for _, h in ipairs(hijos) do h:Destroy() end
end
function M.Destroy(inst)
	if inst._destruido then return end
	local s = senalSiExiste(inst, "Destroying")
	if s then P.disparar(s, nil) end
	local hijos = inst:GetChildren()
	for _, h in ipairs(hijos) do M.Destroy(h) end
	if inst._padre then establecerPadre(inst, nil) end
	rawset(inst, "_destruido", true)
	if inst._senales then
		for _, sx in pairs(inst._senales) do P.desconectarTodo(sx) end
	end
	if inst._tags then
		for tag in pairs(inst._tags) do if I.alQuitarTag then I.alQuitarTag(inst, tag) end end
	end
	if inst._c.alDestruir then inst._c.alDestruir(inst) end
end
M.Remove = function(inst) inst.Parent = nil end
function M.Clone(inst)
	if inst._p.Archivable == false then return nil end
	local copia = I.nuevo(inst._c.nombre)
	for k, v in pairs(inst._p) do
		if k ~= "Parent" then copia._p[k] = v end
	end
	if inst._attrs then
		local a = {}
		for k, v in pairs(inst._attrs) do a[k] = v end
		rawset(copia, "_attrs", a)
	end
	if inst._tags then
		for tag in pairs(inst._tags) do copia:AddTag(tag) end
	end
	if inst._c.alClonar then inst._c.alClonar(inst, copia) end
	for _, h in ipairs(inst._hijos) do
		local hc = M.Clone(h)
		if hc then hc.Parent = copia end
	end
	return copia
end
local tiposAtributo = { boolean = true, number = true, string = true, Vector3 = true, Vector2 = true, Color3 = true, UDim = true, UDim2 = true, CFrame = true, BrickColor = true, NumberRange = true, NumberSequence = true, ColorSequence = true, Rect = true, EnumItem = true, Font = true }
function M.SetAttribute(inst, nombre, valor)
	if type(nombre) ~= "string" or #nombre == 0 or #nombre > 100 then error("Attribute name is invalid", 2) end
	if valor ~= nil and not tiposAtributo[typeof(valor)] then
		error(typeof(valor) .. " is not a supported attribute type", 2)
	end
	local a = inst._attrs
	if not a then a = {} rawset(inst, "_attrs", a) end
	if a[nombre] == valor then return end
	a[nombre] = valor
	local s = senalSiExiste(inst, "attr:" .. nombre)
	if s then P.disparar(s, nil) end
	local s2 = senalSiExiste(inst, "AttributeChanged")
	if s2 then P.disparar(s2, nil, nombre) end
end
function M.GetAttribute(inst, nombre)
	local a = inst._attrs
	return a and a[nombre]
end
function M.GetAttributes(inst)
	local r = {}
	if inst._attrs then for k, v in pairs(inst._attrs) do r[k] = v end end
	return r
end
function M.GetAttributeChangedSignal(inst, nombre) return senal(inst, "attr:" .. nombre) end
function M.GetPropertyChangedSignal(inst, prop)
	local m = miembros(inst._c)[prop]
	if not m and inst._p[prop] == nil then
		error(string.format("%s is not a valid property name.", tostring(prop)), 2)
	end
	return senal(inst, "prop:" .. prop)
end
function M.AddTag(inst, tag)
	local t = inst._tags
	if not t then t = {} rawset(inst, "_tags", t) end
	if t[tag] then return end
	t[tag] = true
	if I.alPonerTag then I.alPonerTag(inst, tag) end
end
function M.RemoveTag(inst, tag)
	if inst._tags and inst._tags[tag] then
		inst._tags[tag] = nil
		if I.alQuitarTag then I.alQuitarTag(inst, tag) end
	end
end
function M.HasTag(inst, tag) return inst._tags ~= nil and inst._tags[tag] == true end
function M.GetTags(inst)
	local r = {}
	if inst._tags then for t in pairs(inst._tags) do r[#r + 1] = t end end
	return r
end
function M.IsPropertyModified() return false end
function M.ResetPropertyToDefault(inst, prop) inst._p[prop] = nil end

---------------------------------------------------------------------------- utilidades geométricas
local function cfDe(inst) return inst._p.CFrame or CFrame.identity end
local function aabb(part)
	local c = cfDe(part)
	local s = part._p.Size or Vector3.new(4, 1, 2)
	local hx, hy, hz = s.X / 2, s.Y / 2, s.Z / 2
	local ex = math.abs(c[4]) * hx + math.abs(c[5]) * hy + math.abs(c[6]) * hz
	local ey = math.abs(c[7]) * hx + math.abs(c[8]) * hy + math.abs(c[9]) * hz
	local ez = math.abs(c[10]) * hx + math.abs(c[11]) * hy + math.abs(c[12]) * hz
	return c[1] - ex, c[2] - ey, c[3] - ez, c[1] + ex, c[2] + ey, c[3] + ez
end
I.aabb = aabb

---------------------------------------------------------------------------- PVInstance / BasePart / Model
definir("PVInstance", "Instance", {})
local pv = Clases.PVInstance
pv.metodos.GetPivot = function(inst)
	if inst:IsA("BasePart") then return cfDe(inst) end
	return inst:GetBoundingBox()
end
pv.metodos.PivotTo = function(inst, destino)
	if inst:IsA("BasePart") then inst.CFrame = destino return end
	local actual = inst:GetPivot()
	local delta = destino * actual:Inverse()
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then d.CFrame = delta * cfDe(d) end
	end
	if inst._p.WorldPivot then inst._p.WorldPivot = destino end
end

local basePart = definir("BasePart", "PVInstance", {
	noCreable = true,
	props = {
		Anchored = false, CanCollide = true, CanQuery = true, CanTouch = true, CastShadow = true, Locked = false, Massless = false,
		Transparency = 0, Reflectance = 0, LocalTransparencyModifier = 0,
		Material = Enum.Material.Plastic, MaterialVariant = "", Color = Color3.fromRGB(163, 162, 165),
		Size = Vector3.new(4, 1, 2), CFrame = CFrame.identity,
		AssemblyLinearVelocity = Vector3.zero, AssemblyAngularVelocity = Vector3.zero, Velocity = Vector3.zero, RotVelocity = Vector3.zero,
		CollisionGroup = "Default", CollisionGroupId = 0, CustomPhysicalProperties = NIL, RootPriority = 0,
		TopSurface = Enum.SurfaceType.Smooth, BottomSurface = Enum.SurfaceType.Smooth, FrontSurface = Enum.SurfaceType.Smooth,
		BackSurface = Enum.SurfaceType.Smooth, LeftSurface = Enum.SurfaceType.Smooth, RightSurface = Enum.SurfaceType.Smooth,
		EnableFluidForces = true, AudioCanCollide = true, PivotOffset = CFrame.identity,
	},
})
basePart.calc.Position = {
	get = function(inst) return cfDe(inst).Position end,
	set = function(inst, v)
		local c = cfDe(inst)
		inst.CFrame = CFrame.new(v.X, v.Y, v.Z, c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12])
	end,
}
basePart.calc.Orientation = {
	get = function(inst) local rx, ry, rz = cfDe(inst):ToOrientation() return Vector3.new(math.deg(rx), math.deg(ry), math.deg(rz)) end,
	set = function(inst, v) local p = cfDe(inst).Position inst.CFrame = CFrame.new(p) * CFrame.fromOrientation(math.rad(v.X), math.rad(v.Y), math.rad(v.Z)) end,
}
basePart.calc.Rotation = basePart.calc.Orientation
basePart.calc.BrickColor = {
	get = function(inst) return T.BrickColor.new(inst._p.Color or Color3.fromRGB(163, 162, 165)) end,
	set = function(inst, v) inst.Color = v.Color end,
}
basePart.calc.AssemblyMass = { get = function(inst) local s = inst._p.Size or Vector3.new(4, 1, 2) return s.X * s.Y * s.Z * 0.7 end }
basePart.calc.Mass = basePart.calc.AssemblyMass
basePart.calc.AssemblyRootPart = { get = function(inst) return inst end }
basePart.calc.ExtentsSize = { get = function(inst) return inst._p.Size end }
basePart.calc.ResizeIncrement = { get = function() return 1 end }
basePart.calc.CurrentPhysicalProperties = { get = function(inst) return inst._p.CustomPhysicalProperties ~= NIL and inst._p.CustomPhysicalProperties or T.PhysicalProperties.new(0.7, 0.3, 0.5) end }
basePart.alCambiar = {
	CFrame = function(inst) notificarCambio(inst, "Position") notificarCambio(inst, "Orientation") if I.alMoverParte then I.alMoverParte(inst) end end,
	Size = function(inst) if I.alMoverParte then I.alMoverParte(inst) end end,
	Anchored = function(inst) if I.alCambiarAnclaje then I.alCambiarAnclaje(inst) end end,
	Color = function(inst) notificarCambio(inst, "BrickColor") end,
}
local BM = basePart.metodos
function BM.GetMass(inst) return inst.AssemblyMass end
function BM.GetConnectedParts() return {} end
function BM.GetJoints() return {} end
function BM.GetTouchingParts() return {} end
function BM.GetNetworkOwner(inst) return inst._dueno end
function BM.SetNetworkOwner(inst, jugador)
	if jugador ~= nil and not (esInstancia(jugador) and jugador:IsA("Player")) then error("SetNetworkOwner: Player expected", 2) end
	if inst._p.Anchored then error("Network Ownership API cannot be called on Anchored parts or parts welded to Anchored parts.", 2) end
	rawset(inst, "_dueno", jugador)
end
function BM.SetNetworkOwnershipAuto(inst) rawset(inst, "_dueno", nil) end
function BM.CanSetNetworkOwnership(inst) return not inst._p.Anchored end
function BM.ApplyImpulse(inst, impulso)
	local masa = inst.AssemblyMass
	if masa <= 0 then masa = 1 end
	inst.AssemblyLinearVelocity = inst.AssemblyLinearVelocity + impulso / masa
end
function BM.ApplyImpulseAtPosition(inst, impulso) BM.ApplyImpulse(inst, impulso) end
function BM.ApplyAngularImpulse() end
function BM.GetVelocityAtPosition(inst) return inst.AssemblyLinearVelocity end
function BM.BreakJoints() end
function BM.MakeJoints() end
function BM.Resize() return true end
function BM.SubtractAsync() error("simulador: SubtractAsync no soportado", 2) end
function BM.UnionAsync() error("simulador: UnionAsync no soportado", 2) end
function BM.GetClosestPointOnSurface(inst, p) return p end
function BM.GetRootPart(inst) return inst end
function BM.IsGrounded(inst) return inst._p.Anchored == true end
function BM.AngularAccelerationToTorque() return Vector3.zero end
function BM.TorqueToAngularAcceleration() return Vector3.zero end

definir("FormFactorPart", "BasePart", { noCreable = true })
definir("Part", "FormFactorPart", { props = { Shape = Enum.PartType.Block } })
definir("WedgePart", "FormFactorPart", {})
definir("CornerWedgePart", "BasePart", {})
definir("TrussPart", "BasePart", { props = { Style = Enum.Style.AlternatingSupports } })
definir("TriangleMeshPart", "BasePart", { noCreable = true })
definir("MeshPart", "TriangleMeshPart", { props = { MeshId = "", TextureID = "", DoubleSided = false, RenderFidelity = Enum.RenderFidelity.Automatic, CollisionFidelity = Enum.CollisionFidelity.Default } })
definir("PartOperation", "TriangleMeshPart", { props = { UsePartColor = false, RenderFidelity = Enum.RenderFidelity.Automatic, CollisionFidelity = Enum.CollisionFidelity.Default, SmoothingAngle = 0 } })
definir("UnionOperation", "PartOperation", {})
definir("NegateOperation", "PartOperation", {})
definir("IntersectOperation", "PartOperation", {})
definir("SpawnLocation", "Part", { props = { Enabled = true, Neutral = true, AllowTeamChangeOnTouch = false, Duration = 10, TeamColor = T.BrickColor.new("Medium stone grey") } })
definir("Terrain", "BasePart", { props = { WaterColor = Color3.fromRGB(12, 84, 92), WaterReflectance = 1, WaterTransparency = 0.3, WaterWaveSize = 0.15, WaterWaveSpeed = 10, Decoration = false } })
Clases.Terrain.metodos.FillBlock = function() end
Clases.Terrain.metodos.FillBall = function() end
Clases.Terrain.metodos.Clear = function() end
Clases.Terrain.metodos.ReadVoxels = function() return {}, {} end

-- Seat / VehicleSeat
local function sentar(seat, humanoide)
	if not humanoide or not esInstancia(humanoide) or not humanoide:IsA("Humanoid") then error("Sit: Humanoid expected", 3) end
	if seat._p.Disabled then return end
	if seat._p.Occupant and seat._p.Occupant ~= NIL then return end
	if humanoide._p.SeatPart and humanoide._p.SeatPart ~= NIL then I.levantar(humanoide) end
	seat._p.Occupant = humanoide
	humanoide._p.SeatPart = seat
	humanoide._p.Sit = true
	notificarCambio(seat, "Occupant")
	notificarCambio(humanoide, "SeatPart")
	notificarCambio(humanoide, "Sit")
	local s = senalSiExiste(humanoide, "Seated")
	if s then P.disparar(s, nil, true, seat) end
end
function I.levantar(humanoide)
	local seat = humanoide._p.SeatPart
	if not seat or seat == NIL then return end
	seat._p.Occupant = NIL
	humanoide._p.SeatPart = NIL
	humanoide._p.Sit = false
	notificarCambio(seat, "Occupant")
	notificarCambio(humanoide, "SeatPart")
	notificarCambio(humanoide, "Sit")
	local s = senalSiExiste(humanoide, "Seated")
	if s then P.disparar(s, nil, false, nil) end
end
definir("Seat", "Part", { props = { Disabled = false, Occupant = NIL }, ro = { Occupant = true }, metodos = { Sit = sentar } })
definir("VehicleSeat", "BasePart", { props = { Disabled = false, Occupant = NIL, MaxSpeed = 25, Torque = 10, TurnSpeed = 1, Throttle = 0, Steer = 0, HeadsUpDisplay = true }, ro = { Occupant = true }, metodos = { Sit = sentar } })

-- Model / Workspace
local function cajaModelo(inst)
	local x0, y0, z0, x1, y1, z1 = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
	local hay = false
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			local a, b, c, e, f, g = aabb(d)
			x0, y0, z0 = math.min(x0, a), math.min(y0, b), math.min(z0, c)
			x1, y1, z1 = math.max(x1, e), math.max(y1, f), math.max(z1, g)
			hay = true
		end
	end
	if not hay then return CFrame.identity, Vector3.zero end
	return CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), Vector3.new(x1 - x0, y1 - y0, z1 - z0)
end
local model = definir("Model", "PVInstance", {
	props = { PrimaryPart = NIL, WorldPivot = NIL, LevelOfDetail = Enum.ModelLevelOfDetail.Automatic, ModelStreamingMode = Enum.ModelStreamingMode.Default },
})
model.metodos.GetBoundingBox = function(inst)
	local c, s = cajaModelo(inst)
	return c, s
end
model.metodos.GetExtentsSize = function(inst) local _, s = cajaModelo(inst) return s end
model.metodos.GetPivot = function(inst)
	local pp = inst._p.PrimaryPart
	if pp and pp ~= NIL then return cfDe(pp) end
	local wp = inst._p.WorldPivot
	if wp and wp ~= NIL then return wp end
	local c = cajaModelo(inst)
	return c
end
model.metodos.GetPrimaryPartCFrame = function(inst) local pp = inst._p.PrimaryPart if pp and pp ~= NIL then return cfDe(pp) end error("Model:GetPrimaryPartCFrame() failed because no PrimaryPart has been set", 2) end
model.metodos.SetPrimaryPartCFrame = function(inst, c) Clases.PVInstance.metodos.PivotTo(inst, c) end
model.metodos.MoveTo = function(inst, pos) local actual = inst:GetPivot() Clases.PVInstance.metodos.PivotTo(inst, actual - actual.Position + pos) end
model.metodos.TranslateBy = function(inst, delta) Clases.PVInstance.metodos.PivotTo(inst, inst:GetPivot() + delta) end
model.metodos.GetScale = function() return 1 end
model.metodos.ScaleTo = function() end
model.metodos.BreakJoints = function() end
model.metodos.MakeJoints = function() end
model.metodos.GetModelCFrame = function(inst) return (cajaModelo(inst)) end
model.metodos.GetModelSize = function(inst) local _, s = cajaModelo(inst) return s end
model.metodos.AddPersistentPlayer = function() end
model.metodos.RemovePersistentPlayer = function() end

---------------------------------------------------------------------------- contenedores y valores
definir("Folder", "Instance", {})
definir("Configuration", "Instance", {})
definir("Actor", "Model", {})
definir("WorldModel", "Model", {})
local valores = {
	StringValue = "", BoolValue = false, NumberValue = 0, IntValue = 0, ObjectValue = NIL,
	Color3Value = Color3.new(), Vector3Value = Vector3.zero, CFrameValue = CFrame.identity,
	BrickColorValue = T.BrickColor.new("Medium stone grey"), RayValue = NIL,
}
definir("ValueBase", "Instance", { noCreable = true })
for clase, defecto in pairs(valores) do
	local d = definir(clase, "ValueBase", { props = { Value = defecto } })
	d.esValor = true
end
Clases.IntValue.alCambiar = { Value = function(inst, v) if type(v) == "number" then inst._p.Value = math.floor(v) end end }

---------------------------------------------------------------------------- remotos y bindables
definir("RemoteEvent", "Instance", { eventos = { OnServerEvent = true, OnClientEvent = true } })
definir("UnreliableRemoteEvent", "RemoteEvent", {})
definir("RemoteFunction", "Instance", {})
definir("BindableEvent", "Instance", { eventos = { Event = true } })
definir("BindableFunction", "Instance", {})
-- (los métodos FireServer, InvokeServer, etc. los añade servicios.lua porque dependen de jugadores/contextos)

---------------------------------------------------------------------------- scripts
definir("LuaSourceContainer", "Instance", { noCreable = true, props = { Source = "" } })
definir("BaseScript", "LuaSourceContainer", { noCreable = true, props = { Disabled = false, Enabled = true, RunContext = Enum.RunContext.Legacy } })
Clases.BaseScript.alCambiar = {
	Disabled = function(inst, v) inst._p.Enabled = not v end,
	Enabled = function(inst, v) inst._p.Disabled = not v end,
}
definir("Script", "BaseScript", {})
definir("LocalScript", "Script", {})
definir("ModuleScript", "LuaSourceContainer", {})

---------------------------------------------------------------------------- humanoides y personajes
local hum = definir("Humanoid", "Instance", {
	props = {
		Health = 100, MaxHealth = 100, WalkSpeed = 16, JumpPower = 50, JumpHeight = 7.2, UseJumpPower = false, HipHeight = 2,
		DisplayName = "", DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer, NameDisplayDistance = 100, HealthDisplayDistance = 100,
		HealthDisplayType = Enum.HumanoidHealthDisplayType.DisplayWhenDamaged, NameOcclusion = Enum.NameOcclusion.OccludeAll,
		Sit = false, SeatPart = NIL, Jump = false, PlatformStand = false, AutoRotate = true, AutoJumpEnabled = true,
		MoveDirection = Vector3.zero, WalkToPoint = Vector3.zero, WalkToPart = NIL, TargetPoint = Vector3.zero,
		RigType = Enum.HumanoidRigType.R15, RequiresNeck = true, BreakJointsOnDeath = true, EvaluateStateMachine = true,
		FloorMaterial = Enum.Material.Plastic, MaxSlopeAngle = 89, CameraOffset = Vector3.zero, UseJumpPower2 = false,
	},
	ro = { SeatPart = true, FloorMaterial = true, MoveDirection = true },
	eventos = { Died = true, Seated = true, StateChanged = true, Running = true, HealthChanged = true, Jumping = true, MoveToFinished = true, AnimationPlayed = true },
})
hum.calc.RootPart = { get = function(inst) local m = inst._padre return m and buscarHijo(m, "HumanoidRootPart") end }
hum.alCambiar = {
	Health = function(inst, v, viejo)
		local s = senalSiExiste(inst, "HealthChanged")
		if s then P.disparar(s, nil, v) end
		if v <= 0 and (viejo == nil or viejo > 0) then
			inst._estado = Enum.HumanoidStateType.Dead
			local d = senalSiExiste(inst, "Died")
			if d then P.disparar(d, nil) end
			if I.alMorir then I.alMorir(inst) end
		end
	end,
	Sit = function(inst, v) if not v then I.levantar(inst) end end,
	Jump = function(inst, v) if v then I.levantar(inst) inst._p.Jump = false end end,
}
local HM = hum.metodos
function HM.TakeDamage(inst, d) inst.Health = math.max(0, inst.Health - d) end
function HM.ChangeState(inst, e)
	rawset(inst, "_estado", e)
	local s = senalSiExiste(inst, "StateChanged")
	if s then P.disparar(s, nil, nil, e) end
	if e == Enum.HumanoidStateType.Dead then inst.Health = 0 end
end
function HM.GetState(inst) return inst._estado or Enum.HumanoidStateType.Running end
function HM.SetStateEnabled() end
function HM.GetStateEnabled() return true end
function HM.MoveTo(inst, pos) inst._p.WalkToPoint = pos end
function HM.Move(inst, dir) inst._p.MoveDirection = dir end
function HM.UnequipTools() end
function HM.EquipTool(inst, tool) if tool then tool.Parent = inst._padre end end
function HM.GetAccessories() return {} end
function HM.AddAccessory(inst, acc) acc.Parent = inst._padre end
function HM.RemoveAccessories() end
function HM.ApplyDescription() end
function HM.ApplyDescriptionReset() end
function HM.GetAppliedDescription() return I.nuevo("HumanoidDescription") end
function HM.BuildRigFromAttachments() end
function HM.GetPlayingAnimationTracks() return {} end
function HM.GetLimb() return Enum.Limb.Unknown end
function HM.GetBodyPartR15() return Enum.BodyPartR15.Unknown end
function HM.GetMoveVelocity() return Vector3.zero end
function HM.ReplaceBodyPartR15() return true end
local function pista()
	local t = { Length = 1, IsPlaying = false, Speed = 1, Looped = false, Priority = Enum.AnimationPriority.Action, TimePosition = 0, WeightCurrent = 0, WeightTarget = 1 }
	t.Stopped = P.nuevaSenal("Stopped")
	t.Ended = P.nuevaSenal("Ended")
	t.DidLoop = P.nuevaSenal("DidLoop")
	t.KeyframeReached = P.nuevaSenal("KeyframeReached")
	function t:Play() self.IsPlaying = true end
	function t:Stop() self.IsPlaying = false P.disparar(self.Stopped, nil) end
	function t:AdjustSpeed(s) self.Speed = s end
	function t:AdjustWeight() end
	function t:GetMarkerReachedSignal() return P.nuevaSenal("Marker") end
	function t:GetTimeOfKeyframe() return 0 end
	function t:Destroy() end
	return t
end
function HM.LoadAnimation() return pista() end
definir("Animator", "Instance", { metodos = { LoadAnimation = function() return pista() end, GetPlayingAnimationTracks = function() return {} end, ApplyJointVelocities = function() end, StepAnimations = function() end } })
definir("AnimationController", "Instance", { metodos = { LoadAnimation = function() return pista() end, GetPlayingAnimationTracks = function() return {} end } })
definir("Animation", "Instance", { props = { AnimationId = "" } })
definir("HumanoidDescription", "Instance", { props = { Shirt = 0, Pants = 0, GraphicTShirt = 0, Face = 0, Head = 0, BodyTypeScale = 0, HeightScale = 1, WidthScale = 1, DepthScale = 1, HeadScale = 1, ProportionScale = 0 } })
definir("Clothing", "Instance", { noCreable = true, props = { Color3 = Color3.new(1, 1, 1) } })
definir("Shirt", "Clothing", { props = { ShirtTemplate = "" } })
definir("Pants", "Clothing", { props = { PantsTemplate = "" } })
definir("ShirtGraphic", "Instance", { props = { Graphic = "", Color3 = Color3.new(1, 1, 1) } })
definir("BodyColors", "Instance", { props = { HeadColor3 = Color3.new(1, 1, 1), TorsoColor3 = Color3.new(1, 1, 1), LeftArmColor3 = Color3.new(1, 1, 1), RightArmColor3 = Color3.new(1, 1, 1), LeftLegColor3 = Color3.new(1, 1, 1), RightLegColor3 = Color3.new(1, 1, 1) } })
definir("Accoutrement", "Instance", { noCreable = true, props = { AttachmentPoint = CFrame.identity } })
definir("Accessory", "Accoutrement", { props = { AccessoryType = Enum.AccessoryType.Unknown } })
definir("Hat", "Accoutrement", {})
definir("BackpackItem", "Instance", { noCreable = true, props = { TextureId = "" } })
definir("Tool", "BackpackItem", { props = { CanBeDropped = true, Enabled = true, ManualActivationOnly = false, RequiresHandle = true, ToolTip = "", Grip = CFrame.identity }, metodos = { Activate = function() end, Deactivate = function() end }, eventos = { Activated = true, Deactivated = true, Equipped = true, Unequipped = true } })
definir("Backpack", "Instance", {})
definir("StarterGear", "Instance", {})
definir("PlayerScripts", "Instance", {})
definir("PlayerGui", "Instance", { props = { SelectionImageObject = NIL, ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor }, metodos = { GetTopbarTransparency = function() return 0 end, SetTopbarTransparency = function() end } })
definir("Camera", "PVInstance", {
	props = { CFrame = CFrame.new(0, 20, 20), Focus = CFrame.identity, FieldOfView = 70, CameraType = Enum.CameraType.Custom, CameraSubject = NIL, HeadLocked = true, HeadScale = 1, DiagonalFieldOfView = 88, MaxAxisFieldOfView = 70 },
})
Clases.Camera.calc.ViewportSize = { get = function() return I.pantalla end }
Clases.Camera.calc.NearPlaneZ = { get = function() return -0.1 end }
Clases.Camera.metodos.WorldToViewportPoint = function(cam, p)
	local local_ = cfDe(cam):PointToObjectSpace(p)
	local enPantalla = local_.Z < 0
	return Vector3.new(I.pantalla.X / 2 + local_.X * 10, I.pantalla.Y / 2 - local_.Y * 10, -local_.Z), enPantalla
end
Clases.Camera.metodos.WorldToScreenPoint = Clases.Camera.metodos.WorldToViewportPoint
Clases.Camera.metodos.ViewportPointToRay = function(cam, x, y) return T.Ray.new(cfDe(cam).Position, cfDe(cam).LookVector) end
Clases.Camera.metodos.ScreenPointToRay = Clases.Camera.metodos.ViewportPointToRay
Clases.Camera.metodos.GetPartsObscuringTarget = function() return {} end
Clases.Camera.metodos.Interpolate = function() end
Clases.Camera.metodos.ZoomToExtents = function() end

---------------------------------------------------------------------------- uniones, restricciones, efectos, luces, sonido
definir("Attachment", "Instance", { props = { CFrame = CFrame.identity, Visible = false, Axis = Vector3.xAxis, SecondaryAxis = Vector3.yAxis } })
Clases.Attachment.calc.Position = { get = function(i) return cfDe(i).Position end, set = function(i, v) i.CFrame = CFrame.new(v) end }
Clases.Attachment.calc.WorldPosition = { get = function(i) local p = i._padre if p and p:IsA("BasePart") then return cfDe(p) * cfDe(i).Position end return cfDe(i).Position end }
Clases.Attachment.calc.WorldCFrame = { get = function(i) local p = i._padre if p and p:IsA("BasePart") then return cfDe(p) * cfDe(i) end return cfDe(i) end }
definir("Bone", "Attachment", { props = { Transform = CFrame.identity } })
definir("JointInstance", "Instance", { noCreable = true, props = { Part0 = NIL, Part1 = NIL, C0 = CFrame.identity, C1 = CFrame.identity, Enabled = true } })
definir("Weld", "JointInstance", {})
definir("ManualWeld", "JointInstance", {})
definir("Snap", "JointInstance", {})
definir("Motor6D", "JointInstance", { props = { Transform = CFrame.identity, MaxVelocity = 0.1, DesiredAngle = 0, CurrentAngle = 0 } })
definir("WeldConstraint", "Instance", { props = { Part0 = NIL, Part1 = NIL, Enabled = true }, calc = { Active = { get = function() return true end } } })
definir("NoCollisionConstraint", "Instance", { props = { Part0 = NIL, Part1 = NIL, Enabled = true } })
definir("Constraint", "Instance", { noCreable = true, props = { Attachment0 = NIL, Attachment1 = NIL, Enabled = true, Visible = false, Color = T.BrickColor.new("Medium stone grey") } })
for _, c in ipairs({ "HingeConstraint", "RopeConstraint", "RodConstraint", "SpringConstraint", "BallSocketConstraint", "PrismaticConstraint", "AlignPosition", "AlignOrientation", "LinearVelocity", "AngularVelocity", "VectorForce", "Torque", "LineForce", "PlaneConstraint", "CylindricalConstraint", "UniversalConstraint", "WeldConstraintDummy" }) do
	definir(c, "Constraint", {})
end
definir("BodyMover", "Instance", { noCreable = true })
for clase, props in pairs({
	BodyVelocity = { Velocity = Vector3.zero, MaxForce = Vector3.new(4000, 4000, 4000), P = 1250 },
	BodyGyro = { CFrame = CFrame.identity, MaxTorque = Vector3.new(400000, 0, 400000), D = 500, P = 3000 },
	BodyPosition = { Position = Vector3.zero, MaxForce = Vector3.new(4000, 4000, 4000), D = 1250, P = 10000 },
	BodyAngularVelocity = { AngularVelocity = Vector3.zero, MaxTorque = Vector3.new(4000, 4000, 4000), P = 1250 },
	BodyForce = { Force = Vector3.zero },
	BodyThrust = { Force = Vector3.zero, Location = Vector3.zero },
}) do definir(clase, "BodyMover", { props = props }) end

definir("Light", "Instance", { noCreable = true, props = { Brightness = 1, Color = Color3.new(1, 1, 1), Enabled = true, Shadows = false } })
definir("PointLight", "Light", { props = { Range = 8 } })
definir("SpotLight", "Light", { props = { Range = 16, Angle = 90, Face = Enum.NormalId.Front } })
definir("SurfaceLight", "Light", { props = { Range = 16, Angle = 90, Face = Enum.NormalId.Front } })
definir("ParticleEmitter", "Instance", { props = { Enabled = true, Rate = 20, Lifetime = T.NumberRange.new(5, 10), Speed = T.NumberRange.new(5), Color = T.ColorSequence.new(Color3.new(1, 1, 1)), Size = T.NumberSequence.new(1), Transparency = T.NumberSequence.new(0), Texture = "", LightEmission = 0, LightInfluence = 1, SpreadAngle = Vector2.zero, Rotation = T.NumberRange.new(0), RotSpeed = T.NumberRange.new(0), Acceleration = Vector3.zero, Drag = 0, EmissionDirection = Enum.NormalId.Top, LockedToPart = false, ZOffset = 0, TimeScale = 1, Brightness = 1, Orientation = Enum.ParticleOrientation.FacingCamera, Shape = Enum.ParticleEmitterShape.Box, Squash = T.NumberSequence.new(0) }, metodos = { Emit = function() end, Clear = function() end } })
definir("Beam", "Instance", { props = { Enabled = true, Attachment0 = NIL, Attachment1 = NIL, Color = T.ColorSequence.new(Color3.new(1, 1, 1)), Transparency = T.NumberSequence.new(0.5), Width0 = 1, Width1 = 1, Texture = "", FaceCamera = false, LightEmission = 0, LightInfluence = 0, Segments = 10, CurveSize0 = 0, CurveSize1 = 0, TextureSpeed = 1, TextureLength = 1, ZOffset = 0 } })
definir("Trail", "Instance", { props = { Enabled = true, Attachment0 = NIL, Attachment1 = NIL, Color = T.ColorSequence.new(Color3.new(1, 1, 1)), Transparency = T.NumberSequence.new(0.5), Lifetime = 2, MinLength = 0.1, MaxLength = 0, WidthScale = T.NumberSequence.new(1), FaceCamera = false, LightEmission = 0, LightInfluence = 0, Texture = "" }, metodos = { Clear = function() end } })
definir("Fire", "Instance", { props = { Enabled = true, Heat = 9, Size = 5, Color = Color3.fromRGB(236, 139, 70), SecondaryColor = Color3.fromRGB(139, 80, 55), TimeScale = 1 } })
definir("Smoke", "Instance", { props = { Enabled = true, Color = Color3.new(1, 1, 1), Opacity = 0.5, RiseVelocity = 1, Size = 1, TimeScale = 1 } })
definir("Sparkles", "Instance", { props = { Enabled = true, SparkleColor = Color3.fromRGB(144, 25, 255), TimeScale = 1 } })
definir("Explosion", "Instance", { props = { Position = Vector3.zero, BlastRadius = 4, BlastPressure = 500000, DestroyJointRadiusPercent = 1, ExplosionType = Enum.ExplosionType.Craters, Visible = true }, eventos = { Hit = true } })
definir("Highlight", "Instance", { props = { Adornee = NIL, Enabled = true, FillColor = Color3.new(1, 0, 0), FillTransparency = 0.5, OutlineColor = Color3.new(1, 1, 1), OutlineTransparency = 0, DepthMode = Enum.HighlightDepthMode.AlwaysOnTop } })
definir("SelectionBox", "Instance", { props = { Adornee = NIL, Color3 = Color3.new(0, 0.5, 1), LineThickness = 0.15, SurfaceColor3 = Color3.new(0, 0.5, 1), SurfaceTransparency = 1, Transparency = 0, Visible = true } })

local sonido = definir("Sound", "Instance", {
	props = { SoundId = "", Volume = 0.5, Looped = false, Playing = false, PlaybackSpeed = 1, TimePosition = 0, RollOffMaxDistance = 10000, RollOffMinDistance = 10, RollOffMode = Enum.RollOffMode.Inverse, SoundGroup = NIL, PlayOnRemove = false, Pitch = 1, EmitterSize = 10, MaxDistance = 10000 },
	eventos = { Played = true, Paused = true, Resumed = true, Stopped = true, Ended = true, DidLoop = true, Loaded = true },
})
sonido.calc.IsPlaying = { get = function(i) return i._p.Playing == true end }
sonido.calc.IsPaused = { get = function(i) return i._p.Playing ~= true end }
sonido.calc.IsLoaded = { get = function() return true end }
sonido.calc.TimeLength = { get = function() return 1 end }
sonido.calc.PlaybackLoudness = { get = function() return 0 end }
sonido.metodos.Play = function(i) i.Playing = true local s = senalSiExiste(i, "Played") if s then P.disparar(s, nil, i._p.SoundId) end if not i._p.Looped then P.task.delay(1, function() if not i._destruido then i._p.Playing = false local e = senalSiExiste(i, "Ended") if e then P.disparar(e, nil, i._p.SoundId) end end end) end end
sonido.metodos.Stop = function(i) i.Playing = false local s = senalSiExiste(i, "Stopped") if s then P.disparar(s, nil, i._p.SoundId) end end
sonido.metodos.Pause = function(i) i.Playing = false end
sonido.metodos.Resume = function(i) i.Playing = true end
definir("SoundGroup", "Instance", { props = { Volume = 0.5 } })
definir("SoundEffect", "Instance", { noCreable = true, props = { Enabled = true, Priority = 0 } })
for _, c in ipairs({ "ReverbSoundEffect", "EqualizerSoundEffect", "PitchShiftSoundEffect", "ChorusSoundEffect", "CompressorSoundEffect", "DistortionSoundEffect", "EchoSoundEffect", "FlangeSoundEffect", "TremoloSoundEffect" }) do definir(c, "SoundEffect", {}) end

definir("FaceInstance", "Instance", { noCreable = true, props = { Face = Enum.NormalId.Front } })
definir("Decal", "FaceInstance", { props = { Texture = "", Transparency = 0, Color3 = Color3.new(1, 1, 1), ZIndex = 1, LocalTransparencyModifier = 0 } })
definir("Texture", "Decal", { props = { StudsPerTileU = 2, StudsPerTileV = 2, OffsetStudsU = 0, OffsetStudsV = 0 } })
definir("SurfaceAppearance", "Instance", { props = { ColorMap = "", NormalMap = "", RoughnessMap = "", MetalnessMap = "", AlphaMode = Enum.AlphaMode.Overlay, Color = Color3.new(1, 1, 1) } })
definir("DataModelMesh", "Instance", { noCreable = true, props = { Scale = Vector3.one, Offset = Vector3.zero, VertexColor = Vector3.one } })
definir("SpecialMesh", "DataModelMesh", { props = { MeshId = "", TextureId = "", MeshType = Enum.MeshType.Head } })
definir("BlockMesh", "DataModelMesh", {})
definir("CylinderMesh", "DataModelMesh", {})

definir("ProximityPrompt", "Instance", {
	props = { ActionText = "Interact", ObjectText = "", Enabled = true, HoldDuration = 0, MaxActivationDistance = 10, RequiresLineOfSight = true, KeyboardKeyCode = Enum.KeyCode.E, GamepadKeyCode = Enum.KeyCode.ButtonX, ClickablePrompt = true, Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton, Style = Enum.ProximityPromptStyle.Default, UIOffset = Vector2.zero, AutoLocalize = true },
	eventos = { Triggered = true, TriggerEnded = true, PromptButtonHoldBegan = true, PromptButtonHoldEnded = true, PromptShown = true, PromptHidden = true },
	metodos = { InputHoldBegin = function() end, InputHoldEnd = function() end },
})
definir("ClickDetector", "Instance", { props = { MaxActivationDistance = 32, CursorIcon = "" }, eventos = { MouseClick = true, RightMouseClick = true, MouseHoverEnter = true, MouseHoverLeave = true } })

-- Lighting: efectos
definir("PostEffect", "Instance", { noCreable = true, props = { Enabled = true } })
definir("BloomEffect", "PostEffect", { props = { Intensity = 0.4, Size = 24, Threshold = 0.95 } })
definir("BlurEffect", "PostEffect", { props = { Size = 24 } })
definir("ColorCorrectionEffect", "PostEffect", { props = { Brightness = 0, Contrast = 0, Saturation = 0, TintColor = Color3.new(1, 1, 1) } })
definir("DepthOfFieldEffect", "PostEffect", { props = { FarIntensity = 0.75, FocusDistance = 0.05, InFocusRadius = 10, NearIntensity = 0.75 } })
definir("SunRaysEffect", "PostEffect", { props = { Intensity = 0.25, Spread = 1 } })
definir("Atmosphere", "Instance", { props = { Density = 0.3, Offset = 0, Color = Color3.fromRGB(199, 170, 107), Decay = Color3.fromRGB(92, 60, 13), Glare = 0, Haze = 0 } })
definir("Sky", "Instance", { props = { SkyboxBk = "", SkyboxDn = "", SkyboxFt = "", SkyboxLf = "", SkyboxRt = "", SkyboxUp = "", CelestialBodiesShown = true, StarCount = 3000, SunAngularSize = 21, MoonAngularSize = 11, SunTextureId = "", MoonTextureId = "" } })
definir("Clouds", "Instance", { props = { Cover = 0.5, Density = 0.7, Color = Color3.new(1, 1, 1), Enabled = true } })

---------------------------------------------------------------------------- GUI
local function tamPadre(inst)
	local p = inst._padre
	if not p then return Vector2.zero end
	if p:IsA("GuiObject") then return p.AbsoluteSize end
	if p:IsA("ScreenGui") then return I.pantalla end
	if p:IsA("SurfaceGui") then
		local cs = p._p.CanvasSize
		if cs and cs ~= NIL then return cs end
		return Vector2.new(800, 600)
	end
	if p:IsA("BillboardGui") then
		local s = p._p.Size or UDim2.fromOffset(200, 50)
		return Vector2.new(s.X.Offset + s.X.Scale * 100, s.Y.Offset + s.Y.Scale * 100)
	end
	if p:IsA("LayerCollector") then return I.pantalla end
	return Vector2.zero
end
definir("GuiBase", "Instance", { noCreable = true })
local gb2 = definir("GuiBase2d", "GuiBase", { noCreable = true, props = { AutoLocalize = true, RootLocalizationTable = NIL, SelectionBehaviorDown = Enum.SelectionBehavior.Escape, SelectionBehaviorUp = Enum.SelectionBehavior.Escape, SelectionBehaviorLeft = Enum.SelectionBehavior.Escape, SelectionBehaviorRight = Enum.SelectionBehavior.Escape, SelectionGroup = false } })
gb2.calc.AbsoluteRotation = { get = function() return 0 end }
definir("LayerCollector", "GuiBase2d", { noCreable = true, props = { Enabled = true, ResetOnSpawn = true, ZIndexBehavior = Enum.ZIndexBehavior.Global } })
Clases.LayerCollector.calc.AbsoluteSize = { get = function(i) return I.pantalla end }
Clases.LayerCollector.calc.AbsolutePosition = { get = function() return Vector2.zero end }
Clases.LayerCollector.metodos.GetLayoutNodeTree = function() return {} end
definir("ScreenGui", "LayerCollector", { props = { DisplayOrder = 0, IgnoreGuiInset = false, ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets, SafeAreaCompatibility = Enum.SafeAreaCompatibility.FullscreenExtension, ClipToDeviceSafeArea = true } })
definir("SurfaceGuiBase", "LayerCollector", { noCreable = true, props = { Active = true, Adornee = NIL, Face = Enum.NormalId.Front } })
definir("SurfaceGui", "SurfaceGuiBase", { props = { AlwaysOnTop = false, Brightness = 1, CanvasSize = Vector2.new(800, 600), ClipsDescendants = true, LightInfluence = 1, MaxDistance = 1000, PixelsPerStud = 50, SizingMode = Enum.SurfaceGuiSizingMode.FixedSize, ToolPunchThroughDistance = 0, ZOffset = 0 } })
definir("BillboardGui", "LayerCollector", { props = { Active = false, Adornee = NIL, AlwaysOnTop = false, Brightness = 1, ClipsDescendants = false, DistanceLowerLimit = 0, DistanceStep = 0, DistanceUpperLimit = -1, ExtentsOffset = Vector3.zero, ExtentsOffsetWorldSpace = Vector3.zero, LightInfluence = 0, MaxDistance = math.huge, PlayerToHideFrom = NIL, Size = UDim2.new(), SizeOffset = Vector2.zero, StudsOffset = Vector3.zero, StudsOffsetWorldSpace = Vector3.zero } })

local guiObj = definir("GuiObject", "GuiBase2d", {
	noCreable = true,
	props = {
		Active = false, AnchorPoint = Vector2.zero, AutomaticSize = Enum.AutomaticSize.None, BackgroundColor3 = Color3.fromRGB(163, 162, 165),
		BackgroundTransparency = 0, BorderColor3 = Color3.fromRGB(27, 42, 53), BorderMode = Enum.BorderMode.Outline, BorderSizePixel = 1,
		ClipsDescendants = false, Interactable = true, LayoutOrder = 0, NextSelectionDown = NIL, NextSelectionLeft = NIL, NextSelectionRight = NIL,
		NextSelectionUp = NIL, Position = UDim2.new(), Rotation = 0, Selectable = false, SelectionImageObject = NIL, SelectionOrder = 0,
		Size = UDim2.new(0, 100, 0, 100), SizeConstraint = Enum.SizeConstraint.RelativeXY, Visible = true, ZIndex = 1, Transparency = 0,
	},
	eventos = { MouseEnter = true, MouseLeave = true, MouseMoved = true, InputBegan = true, InputEnded = true, InputChanged = true, SelectionGained = true, SelectionLost = true, TouchTap = true },
})
guiObj.calc.AbsoluteSize = {
	get = function(i)
		local ps = tamPadre(i)
		local s = i._p.Size or UDim2.new(0, 100, 0, 100)
		local w = ps.X * s.X.Scale + s.X.Offset
		local h = ps.Y * s.Y.Scale + s.Y.Offset
		local sc = i._p.SizeConstraint
		if sc == Enum.SizeConstraint.RelativeXX then h = ps.X * s.Y.Scale + s.Y.Offset elseif sc == Enum.SizeConstraint.RelativeYY then w = ps.Y * s.X.Scale + s.X.Offset end
		return Vector2.new(math.max(0, w), math.max(0, h))
	end,
}
guiObj.calc.AbsolutePosition = {
	get = function(i)
		local p = i._padre
		local base = Vector2.zero
		if p and p:IsA("GuiObject") then base = p.AbsolutePosition end
		local ps = tamPadre(i)
		local pos = i._p.Position or UDim2.new()
		local tam = i.AbsoluteSize
		local ap = i._p.AnchorPoint or Vector2.zero
		return Vector2.new(base.X + ps.X * pos.X.Scale + pos.X.Offset - tam.X * ap.X, base.Y + ps.Y * pos.Y.Scale + pos.Y.Offset - tam.Y * ap.Y)
	end,
}
guiObj.calc.GuiState = { get = function() return Enum.GuiState.Idle end }
local GM = guiObj.metodos
function GM.TweenPosition(i, pos, dir, est, t, sobre, cb) i.Position = pos if cb then P.task.spawn(cb, Enum.TweenStatus.Completed) end return true end
function GM.TweenSize(i, tam, dir, est, t, sobre, cb) i.Size = tam if cb then P.task.spawn(cb, Enum.TweenStatus.Completed) end return true end
function GM.TweenSizeAndPosition(i, tam, pos, dir, est, t, sobre, cb) i.Size = tam i.Position = pos if cb then P.task.spawn(cb, Enum.TweenStatus.Completed) end return true end

definir("Frame", "GuiObject", { props = { Style = Enum.FrameStyle.Custom } })
definir("CanvasGroup", "GuiObject", { props = { GroupColor3 = Color3.new(1, 1, 1), GroupTransparency = 0 } })
definir("ScrollingFrame", "GuiObject", { props = {
	CanvasSize = UDim2.new(0, 0, 2, 0), CanvasPosition = Vector2.zero, ScrollBarThickness = 12, ScrollingDirection = Enum.ScrollingDirection.XY,
	AutomaticCanvasSize = Enum.AutomaticSize.None, ElasticBehavior = Enum.ElasticBehavior.WhenScrollable, ScrollBarImageColor3 = Color3.new(1, 1, 1),
	ScrollBarImageTransparency = 0, ScrollingEnabled = true, BottomImage = "", MidImage = "", TopImage = "", VerticalScrollBarInset = Enum.ScrollBarInset.None,
	HorizontalScrollBarInset = Enum.ScrollBarInset.None, VerticalScrollBarPosition = Enum.VerticalScrollBarPosition.Right,
} })
Clases.ScrollingFrame.calc.AbsoluteCanvasSize = { get = function(i) return i.AbsoluteSize end }
Clases.ScrollingFrame.calc.AbsoluteWindowSize = { get = function(i) return i.AbsoluteSize end }
definir("ViewportFrame", "GuiObject", { props = { CurrentCamera = NIL, Ambient = Color3.fromRGB(200, 200, 200), LightColor = Color3.fromRGB(140, 140, 140), LightDirection = Vector3.new(-1, -1, -1), ImageColor3 = Color3.new(1, 1, 1), ImageTransparency = 0 } })
definir("VideoFrame", "GuiObject", { props = { Video = "", Looped = false, Playing = false, Volume = 1 }, metodos = { Play = function(i) i.Playing = true end, Pause = function(i) i.Playing = false end } })
local textoProps = {
	Text = "Label", TextColor3 = Color3.fromRGB(27, 42, 53), TextSize = 14, TextScaled = false, TextWrapped = false, TextWrap = false,
	Font = Enum.Font.Legacy, FontFace = function() return T.Font.fromEnum(Enum.Font.Legacy) end, TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Center,
	RichText = false, TextTransparency = 0, TextStrokeTransparency = 1, TextStrokeColor3 = Color3.new(0, 0, 0), TextTruncate = Enum.TextTruncate.None,
	MaxVisibleGraphemes = -1, LineHeight = 1, TextDirection = Enum.TextDirection.Auto, OpenTypeFeatures = "",
}
local function calcTexto(def)
	def.calc.TextBounds = { get = function(i) local t = tostring(i._p.Text or "") local s = i._p.TextSize or 14 return Vector2.new(#t * s * 0.5, s) end }
	def.calc.TextFits = { get = function() return true end }
	def.calc.ContentText = { get = function(i) return (tostring(i._p.Text or "")):gsub("<[^>]->", "") end }
	def.calc.LocalizedText = { get = function(i) return i._p.Text end }
end
definir("TextLabel", "GuiObject", { props = textoProps })
calcTexto(Clases.TextLabel)
definir("GuiButton", "GuiObject", { noCreable = true, props = { AutoButtonColor = true, Modal = false, Selected = false, Style = Enum.ButtonStyle.Custom, HoverHapticEffect = NIL, PressHapticEffect = NIL },
	eventos = { MouseButton1Click = true, MouseButton1Down = true, MouseButton1Up = true, MouseButton2Click = true, MouseButton2Down = true, MouseButton2Up = true, Activated = true } })
definir("TextButton", "GuiButton", { props = textoProps })
Clases.TextButton.props.Text = "Button"
calcTexto(Clases.TextButton)
local caja = definir("TextBox", "GuiObject", { props = {}, eventos = { FocusLost = true, Focused = true, ReturnPressedFromOnScreenKeyboard = true } })
for k, v in pairs(textoProps) do caja.props[k] = v end
caja.props.Text = "TextBox"
caja.props.PlaceholderText = ""
caja.props.PlaceholderColor3 = Color3.fromRGB(178, 178, 178)
caja.props.ClearTextOnFocus = true
caja.props.MultiLine = false
caja.props.TextEditable = true
caja.props.CursorPosition = 1
caja.props.SelectionStart = -1
caja.props.ShowNativeInput = true
caja.metodos.CaptureFocus = function(i) rawset(i, "_foco", true) local s = senalSiExiste(i, "Focused") if s then P.disparar(s, nil) end end
caja.metodos.ReleaseFocus = function(i, enviado) rawset(i, "_foco", false) local s = senalSiExiste(i, "FocusLost") if s then P.disparar(s, nil, enviado == true, nil) end end
caja.metodos.IsFocused = function(i) return i._foco == true end
calcTexto(caja)
local imgProps = { Image = "", ImageColor3 = Color3.new(1, 1, 1), ImageTransparency = 0, ScaleType = Enum.ScaleType.Stretch, SliceCenter = T.Rect.new(0, 0, 0, 0), SliceScale = 1, TileSize = UDim2.new(1, 0, 1, 0), ImageRectOffset = Vector2.zero, ImageRectSize = Vector2.zero, ResampleMode = Enum.ResamplerMode.Default, ImageContent = "" }
definir("ImageLabel", "GuiObject", { props = imgProps })
Clases.ImageLabel.calc.IsLoaded = { get = function() return true end }
definir("ImageButton", "GuiButton", { props = {} })
for k, v in pairs(imgProps) do Clases.ImageButton.props[k] = v end
Clases.ImageButton.props.HoverImage = ""
Clases.ImageButton.props.PressedImage = ""
Clases.ImageButton.calc.IsLoaded = { get = function() return true end }

definir("UIBase", "Instance", { noCreable = true })
definir("UIComponent", "UIBase", { noCreable = true })
definir("UICorner", "UIComponent", { props = { CornerRadius = UDim.new(0, 8) } })
definir("UIStroke", "UIComponent", { props = { Color = Color3.new(0, 0, 0), Thickness = 1, Transparency = 0, Enabled = true, ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual, LineJoinMode = Enum.LineJoinMode.Round } })
definir("UIGradient", "UIComponent", { props = { Color = T.ColorSequence.new(Color3.new(1, 1, 1)), Transparency = T.NumberSequence.new(0), Rotation = 0, Offset = Vector2.zero, Enabled = true } })
definir("UIPadding", "UIComponent", { props = { PaddingTop = UDim.new(), PaddingBottom = UDim.new(), PaddingLeft = UDim.new(), PaddingRight = UDim.new() } })
definir("UIScale", "UIComponent", { props = { Scale = 1 } })
definir("UIFlexItem", "UIComponent", { props = { FlexMode = Enum.UIFlexMode.None, GrowRatio = 0, ShrinkRatio = 0, ItemLineAlignment = Enum.ItemLineAlignment.Automatic } })
definir("UIConstraint", "UIComponent", { noCreable = true })
definir("UIAspectRatioConstraint", "UIConstraint", { props = { AspectRatio = 1, AspectType = Enum.AspectType.FitWithinMaxSize, DominantAxis = Enum.DominantAxis.Width } })
definir("UISizeConstraint", "UIConstraint", { props = { MinSize = Vector2.zero, MaxSize = Vector2.new(math.huge, math.huge) } })
definir("UITextSizeConstraint", "UIConstraint", { props = { MinTextSize = 1, MaxTextSize = 100 } })
definir("UILayout", "UIComponent", { noCreable = true })
local gridStyle = definir("UIGridStyleLayout", "UILayout", { noCreable = true, props = { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Left, VerticalAlignment = Enum.VerticalAlignment.Top, SortOrder = Enum.SortOrder.Name } })
gridStyle.calc.AbsoluteContentSize = {
	get = function(i)
		local p = i._padre
		if not p then return Vector2.zero end
		local w, h = 0, 0
		local vertical = i._p.FillDirection == Enum.FillDirection.Vertical
		for _, x in ipairs(p._hijos) do
			if x:IsA("GuiObject") and x._p.Visible ~= false then
				local s = x.AbsoluteSize
				if vertical then h = h + s.Y w = math.max(w, s.X) else w = w + s.X h = math.max(h, s.Y) end
			end
		end
		return Vector2.new(w, h)
	end,
}
gridStyle.metodos.ApplyLayout = function() end
definir("UIListLayout", "UIGridStyleLayout", { props = { Padding = UDim.new(), Wraps = false, HorizontalFlex = Enum.UIFlexAlignment.None, VerticalFlex = Enum.UIFlexAlignment.None, ItemLineAlignment = Enum.ItemLineAlignment.Automatic } })
definir("UIGridLayout", "UIGridStyleLayout", { props = { CellPadding = UDim2.new(0, 5, 0, 5), CellSize = UDim2.new(0, 100, 0, 100), FillDirectionMaxCells = 0, StartCorner = Enum.StartCorner.TopLeft } })
definir("UIPageLayout", "UIGridStyleLayout", { props = { Animated = true, Circular = false, EasingDirection = Enum.EasingDirection.Out, EasingStyle = Enum.EasingStyle.Back, Padding = UDim.new(), TweenTime = 1, GamepadInputEnabled = true, ScrollWheelInputEnabled = true, TouchInputEnabled = true }, metodos = { JumpTo = function() end, JumpToIndex = function() end, Next = function() end, Previous = function() end } })
definir("UITableLayout", "UIGridStyleLayout", { props = { FillEmptySpaceColumns = false, FillEmptySpaceRows = false, MajorAxis = Enum.TableMajorAxis.RowMajor, Padding = UDim2.new() } })

---------------------------------------------------------------------------- chat y misc
definir("TextChannel", "Instance", { eventos = { MessageReceived = true, ShouldDeliverCallback = true } })
definir("TextSource", "Instance", { props = { UserId = 0, CanSend = true } })
definir("TextChatCommand", "Instance", { props = { PrimaryAlias = "", SecondaryAlias = "", AutocompleteVisible = true, Enabled = true }, eventos = { Triggered = true } })
definir("TextChatMessageProperties", "Instance", { props = { PrefixText = "", Text = "", Translation = "" } })
for _, c in ipairs({ "ChatWindowConfiguration", "ChatInputBarConfiguration", "BubbleChatConfiguration", "ChannelTabsConfiguration" }) do
	definir(c, "Instance", { props = { Enabled = true } })
end
definir("Team", "Instance", { props = { TeamColor = T.BrickColor.new("White"), AutoAssignable = true }, eventos = { PlayerAdded = true, PlayerRemoved = true } })
definir("Dialog", "Instance", { props = { InitialPrompt = "" } })
definir("LocalizationTable", "Instance", {})
definir("StarterPlayerScripts", "Instance", {})
definir("StarterCharacterScripts", "Instance", {})
definir("Tween", "Instance", { props = { PlaybackState = Enum.PlaybackState.Begin }, eventos = { Completed = true } })
definir("Message", "Instance", { props = { Text = "" } })
definir("Hint", "Message", {})
definir("Player", "Instance", {})  -- comportamiento en servicios.lua
definir("Mouse", "Instance", {})

return I
