-- Tipos de datos de Roblox implementados en Lua 5.3 para el simulador.
-- Vector3, Vector2, CFrame, Color3, BrickColor, UDim, UDim2, Enum, NumberRange, NumberSequence,
-- ColorSequence, TweenInfo, PhysicalProperties, Ray, RaycastParams, OverlapParams, Rect, Random,
-- DateTime, Font, Region3. Cada valor lleva el campo de metatabla __tipo para typeof().

local T = {}

local function nuevoTipo(nombre)
	local mt = { __tipo = nombre }
	return mt
end

local function aprox(a, b) return math.abs(a - b) < 1e-5 end

local function fmt(n)
	if n == math.floor(n) and math.abs(n) < 1e15 then return string.format("%d", math.floor(n)) end
	return string.format("%.4g", n)
end

---------------------------------------------------------------------------- Vector3
local V3 = nuevoTipo("Vector3")
local Vector3 = {}
local function v3(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3) end
Vector3.new = function(x, y, z) return v3(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0) end
Vector3.zero = v3(0, 0, 0)
Vector3.one = v3(1, 1, 1)
Vector3.xAxis = v3(1, 0, 0)
Vector3.yAxis = v3(0, 1, 0)
Vector3.zAxis = v3(0, 0, 1)
Vector3.FromNormalId = function(n)
	local m = { Right = v3(1, 0, 0), Left = v3(-1, 0, 0), Top = v3(0, 1, 0), Bottom = v3(0, -1, 0), Back = v3(0, 0, 1), Front = v3(0, 0, -1) }
	return m[n.Name] or v3(0, 0, -1)
end
local metV3 = {}
function metV3.Dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
function metV3.Cross(a, b) return v3(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X) end
function metV3.Lerp(a, b, t) return v3(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t) end
function metV3.FuzzyEq(a, b, eps) eps = eps or 1e-5 return math.abs(a.X - b.X) <= eps and math.abs(a.Y - b.Y) <= eps and math.abs(a.Z - b.Z) <= eps end
function metV3.Abs(a) return v3(math.abs(a.X), math.abs(a.Y), math.abs(a.Z)) end
function metV3.Floor(a) return v3(math.floor(a.X), math.floor(a.Y), math.floor(a.Z)) end
function metV3.Ceil(a) return v3(math.ceil(a.X), math.ceil(a.Y), math.ceil(a.Z)) end
function metV3.Sign(a) local function s(n) return n > 0 and 1 or (n < 0 and -1 or 0) end return v3(s(a.X), s(a.Y), s(a.Z)) end
function metV3.Min(a, ...) local r = a for _, b in ipairs({ ... }) do r = v3(math.min(r.X, b.X), math.min(r.Y, b.Y), math.min(r.Z, b.Z)) end return r end
function metV3.Max(a, ...) local r = a for _, b in ipairs({ ... }) do r = v3(math.max(r.X, b.X), math.max(r.Y, b.Y), math.max(r.Z, b.Z)) end return r end
function metV3.Angle(a, b, eje)
	local d = metV3.Dot(a, b) / (math.sqrt(metV3.Dot(a, a) * metV3.Dot(b, b)) + 1e-12)
	return math.acos(math.max(-1, math.min(1, d)))
end
V3.__index = function(v, k)
	if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
	if k == "Unit" then
		local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
		if m == 0 then return v3(0 / 0, 0 / 0, 0 / 0) end
		return v3(v.X / m, v.Y / m, v.Z / m)
	end
	local f = metV3[k]
	if f then return f end
	error("simulador: " .. tostring(k) .. " no es un miembro válido de Vector3", 2)
end
V3.__newindex = function() error("No se puede asignar a un Vector3 (es inmutable)", 2) end
V3.__add = function(a, b) return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V3.__sub = function(a, b) return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V3.__mul = function(a, b)
	if type(a) == "number" then return v3(b.X * a, b.Y * a, b.Z * a) end
	if type(b) == "number" then return v3(a.X * b, a.Y * b, a.Z * b) end
	return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V3.__div = function(a, b)
	if type(b) == "number" then return v3(a.X / b, a.Y / b, a.Z / b) end
	if type(a) == "number" then return v3(a / b.X, a / b.Y, a / b.Z) end
	return v3(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
V3.__unm = function(a) return v3(-a.X, -a.Y, -a.Z) end
V3.__eq = function(a, b) if getmetatable(a) ~= V3 or getmetatable(b) ~= V3 then return false end return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
V3.__tostring = function(a) return fmt(a.X) .. ", " .. fmt(a.Y) .. ", " .. fmt(a.Z) end
T.Vector3 = Vector3
T.v3 = v3

---------------------------------------------------------------------------- Vector2
local V2 = nuevoTipo("Vector2")
local Vector2 = {}
local function v2(x, y) return setmetatable({ X = x or 0, Y = y or 0 }, V2) end
Vector2.new = function(x, y) return v2(tonumber(x) or 0, tonumber(y) or 0) end
Vector2.zero = v2(0, 0)
Vector2.one = v2(1, 1)
Vector2.xAxis = v2(1, 0)
Vector2.yAxis = v2(0, 1)
local metV2 = {}
function metV2.Dot(a, b) return a.X * b.X + a.Y * b.Y end
function metV2.Cross(a, b) return a.X * b.Y - a.Y * b.X end
function metV2.Lerp(a, b, t) return v2(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t) end
function metV2.Min(a, b) return v2(math.min(a.X, b.X), math.min(a.Y, b.Y)) end
function metV2.Max(a, b) return v2(math.max(a.X, b.X), math.max(a.Y, b.Y)) end
function metV2.Abs(a) return v2(math.abs(a.X), math.abs(a.Y)) end
function metV2.FuzzyEq(a, b, e) e = e or 1e-5 return math.abs(a.X - b.X) <= e and math.abs(a.Y - b.Y) <= e end
V2.__index = function(v, k)
	if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y) end
	if k == "Unit" then local m = math.sqrt(v.X * v.X + v.Y * v.Y) if m == 0 then return v2(0 / 0, 0 / 0) end return v2(v.X / m, v.Y / m) end
	local f = metV2[k]
	if f then return f end
	error("simulador: " .. tostring(k) .. " no es un miembro válido de Vector2", 2)
end
V2.__newindex = function() error("No se puede asignar a un Vector2", 2) end
V2.__add = function(a, b) return v2(a.X + b.X, a.Y + b.Y) end
V2.__sub = function(a, b) return v2(a.X - b.X, a.Y - b.Y) end
V2.__mul = function(a, b)
	if type(a) == "number" then return v2(b.X * a, b.Y * a) end
	if type(b) == "number" then return v2(a.X * b, a.Y * b) end
	return v2(a.X * b.X, a.Y * b.Y)
end
V2.__div = function(a, b)
	if type(b) == "number" then return v2(a.X / b, a.Y / b) end
	return v2(a.X / b.X, a.Y / b.Y)
end
V2.__unm = function(a) return v2(-a.X, -a.Y) end
V2.__eq = function(a, b) if getmetatable(a) ~= V2 or getmetatable(b) ~= V2 then return false end return a.X == b.X and a.Y == b.Y end
V2.__tostring = function(a) return fmt(a.X) .. ", " .. fmt(a.Y) end
T.Vector2 = Vector2

---------------------------------------------------------------------------- CFrame
-- Representación: { x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 } (filas de la matriz de rotación)
local CF = nuevoTipo("CFrame")
local CFrame = {}
local function cf(x, y, z, a, b, c, d, e, f, g, h, i)
	return setmetatable({ x, y, z, a, b, c, d, e, f, g, h, i }, CF)
end
local function ortonormal(rx, ry, rz)
	-- columnas rx, ry, rz -> filas
	return rx.X, ry.X, rz.X, rx.Y, ry.Y, rz.Y, rx.Z, ry.Z, rz.Z
end
CFrame.identity = cf(0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)
CFrame.new = function(...)
	local n = select("#", ...)
	local a = { ... }
	if n == 0 then return cf(0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1) end
	if n == 1 then
		local p = a[1]
		return cf(p.X, p.Y, p.Z, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	end
	if n == 2 and type(a[1]) == "table" then
		return CFrame.lookAt(a[1], a[2])
	end
	if n == 3 then return cf(a[1], a[2], a[3], 1, 0, 0, 0, 1, 0, 0, 0, 1) end
	if n == 7 then
		-- posición + cuaternión (qx, qy, qz, qw)
		local qx, qy, qz, qw = a[4], a[5], a[6], a[7]
		return cf(a[1], a[2], a[3],
			1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw),
			2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw),
			2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy))
	end
	if n == 12 then return cf(a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12]) end
	error("simulador: firma de CFrame.new no soportada con " .. n .. " argumentos", 2)
end
CFrame.lookAt = function(at, objetivo, arriba)
	arriba = arriba or Vector3.yAxis
	local f = objetivo - at
	if f.Magnitude < 1e-9 then return cf(at.X, at.Y, at.Z, 1, 0, 0, 0, 1, 0, 0, 0, 1) end
	f = f.Unit
	local derecha = metV3.Cross(f, arriba)
	if derecha.Magnitude < 1e-6 then
		derecha = metV3.Cross(f, Vector3.zAxis)
		if derecha.Magnitude < 1e-6 then derecha = metV3.Cross(f, Vector3.xAxis) end
	end
	derecha = derecha.Unit
	local up = metV3.Cross(derecha, f).Unit
	local back = -f
	local a, b, c, d, e, ff, g, h, i = ortonormal(derecha, up, back)
	return cf(at.X, at.Y, at.Z, a, b, c, d, e, ff, g, h, i)
end
CFrame.lookAlong = function(at, dir, arriba) return CFrame.lookAt(at, at + dir, arriba) end
local function rotX(t) local c, s = math.cos(t), math.sin(t) return cf(0, 0, 0, 1, 0, 0, 0, c, -s, 0, s, c) end
local function rotY(t) local c, s = math.cos(t), math.sin(t) return cf(0, 0, 0, c, 0, s, 0, 1, 0, -s, 0, c) end
local function rotZ(t) local c, s = math.cos(t), math.sin(t) return cf(0, 0, 0, c, -s, 0, s, c, 0, 0, 0, 1) end
CFrame.fromEulerAnglesXYZ = function(rx, ry, rz) return rotX(rx or 0) * rotY(ry or 0) * rotZ(rz or 0) end
CFrame.Angles = CFrame.fromEulerAnglesXYZ
CFrame.fromEulerAnglesYXZ = function(rx, ry, rz) return rotY(ry or 0) * rotX(rx or 0) * rotZ(rz or 0) end
CFrame.fromOrientation = CFrame.fromEulerAnglesYXZ
CFrame.fromEulerAngles = function(rx, ry, rz) return CFrame.fromEulerAnglesXYZ(rx, ry, rz) end
CFrame.fromAxisAngle = function(eje, ang)
	local u = eje.Unit
	local c, s, t = math.cos(ang), math.sin(ang), 1 - math.cos(ang)
	local x, y, z = u.X, u.Y, u.Z
	return cf(0, 0, 0,
		t * x * x + c, t * x * y - s * z, t * x * z + s * y,
		t * x * y + s * z, t * y * y + c, t * y * z - s * x,
		t * x * z - s * y, t * y * z + s * x, t * z * z + c)
end
CFrame.fromMatrix = function(pos, vx, vy, vz)
	vz = vz or metV3.Cross(vx, vy)
	local a, b, c, d, e, f, g, h, i = ortonormal(vx, vy, vz)
	return cf(pos.X, pos.Y, pos.Z, a, b, c, d, e, f, g, h, i)
end
local metCF = {}
function metCF.Inverse(m)
	local x, y, z = m[1], m[2], m[3]
	local a, b, c, d, e, f, g, h, i = m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12]
	-- transpuesta
	local ta, tb, tc, td, te, tf, tg, th, ti = a, d, g, b, e, h, c, f, i
	return cf(-(ta * x + tb * y + tc * z), -(td * x + te * y + tf * z), -(tg * x + th * y + ti * z), ta, tb, tc, td, te, tf, tg, th, ti)
end
function metCF.GetComponents(m) return m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12] end
metCF.components = metCF.GetComponents
function metCF.ToWorldSpace(m, o) return m * o end
function metCF.ToObjectSpace(m, o) return metCF.Inverse(m) * o end
function metCF.PointToWorldSpace(m, v) return m * v end
function metCF.PointToObjectSpace(m, v) return metCF.Inverse(m) * v end
function metCF.VectorToWorldSpace(m, v)
	return v3(m[4] * v.X + m[5] * v.Y + m[6] * v.Z, m[7] * v.X + m[8] * v.Y + m[9] * v.Z, m[10] * v.X + m[11] * v.Y + m[12] * v.Z)
end
function metCF.VectorToObjectSpace(m, v)
	return v3(m[4] * v.X + m[7] * v.Y + m[10] * v.Z, m[5] * v.X + m[8] * v.Y + m[11] * v.Z, m[6] * v.X + m[9] * v.Y + m[12] * v.Z)
end
function metCF.ToEulerAnglesXYZ(m)
	local r02 = math.max(-1, math.min(1, m[6]))
	local ry = math.asin(r02)
	local rx, rz
	if math.abs(r02) < 0.99999 then
		rx = math.atan(-m[9], m[12])
		rz = math.atan(-m[5], m[4])
	else
		rx = math.atan(m[11], m[8])
		rz = 0
	end
	return rx, ry, rz
end
metCF.toEulerAnglesXYZ = metCF.ToEulerAnglesXYZ
function metCF.ToEulerAnglesYXZ(m)
	local r12 = math.max(-1, math.min(1, m[9]))
	local rx = math.asin(-r12)
	local ry, rz
	if math.abs(r12) < 0.99999 then
		ry = math.atan(m[6], m[12])
		rz = math.atan(m[7], m[8])
	else
		ry = math.atan(-m[10], m[4])
		rz = 0
	end
	return rx, ry, rz
end
metCF.ToOrientation = metCF.ToEulerAnglesYXZ
function metCF.ToAxisAngle(m)
	local traza = m[4] + m[8] + m[12]
	local ang = math.acos(math.max(-1, math.min(1, (traza - 1) / 2)))
	local eje = v3(m[11] - m[9], m[6] - m[10], m[7] - m[5])
	if eje.Magnitude < 1e-9 then return Vector3.xAxis, 0 end
	return eje.Unit, ang
end
function metCF.Lerp(a, b, t)
	local p = v3(a[1], a[2], a[3]):Lerp(v3(b[1], b[2], b[3]), t)
	local rows = {}
	for k = 4, 12 do rows[k] = a[k] + (b[k] - a[k]) * t end
	-- reortonormalizar
	local rx = v3(rows[4], rows[7], rows[10]).Unit
	local ry = v3(rows[5], rows[8], rows[11])
	local rz = metV3.Cross(rx, ry).Unit
	ry = metV3.Cross(rz, rx).Unit
	return CFrame.fromMatrix(p, rx, ry, rz)
end
function metCF.FuzzyEq(a, b, e)
	e = e or 1e-5
	for k = 1, 12 do if math.abs(a[k] - b[k]) > e then return false end end
	return true
end
function metCF.Orthonormalize(m)
	return CFrame.fromMatrix(v3(m[1], m[2], m[3]), v3(m[4], m[7], m[10]).Unit, v3(m[5], m[8], m[11]).Unit)
end
CF.__index = function(m, k)
	if k == "Position" or k == "p" then return v3(m[1], m[2], m[3]) end
	if k == "X" then return m[1] end
	if k == "Y" then return m[2] end
	if k == "Z" then return m[3] end
	if k == "LookVector" or k == "lookVector" then return v3(-m[6], -m[9], -m[12]) end
	if k == "RightVector" or k == "rightVector" then return v3(m[4], m[7], m[10]) end
	if k == "UpVector" or k == "upVector" then return v3(m[5], m[8], m[11]) end
	if k == "XVector" then return v3(m[4], m[7], m[10]) end
	if k == "YVector" then return v3(m[5], m[8], m[11]) end
	if k == "ZVector" then return v3(m[6], m[9], m[12]) end
	if k == "Rotation" then return cf(0, 0, 0, m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12]) end
	local f = metCF[k]
	if f then return f end
	error("simulador: " .. tostring(k) .. " no es un miembro válido de CFrame", 2)
end
CF.__newindex = function() error("No se puede asignar a un CFrame", 2) end
CF.__mul = function(a, b)
	local mb = getmetatable(b)
	if mb == CF then
		local x = a[4] * b[1] + a[5] * b[2] + a[6] * b[3] + a[1]
		local y = a[7] * b[1] + a[8] * b[2] + a[9] * b[3] + a[2]
		local z = a[10] * b[1] + a[11] * b[2] + a[12] * b[3] + a[3]
		return cf(x, y, z,
			a[4] * b[4] + a[5] * b[7] + a[6] * b[10], a[4] * b[5] + a[5] * b[8] + a[6] * b[11], a[4] * b[6] + a[5] * b[9] + a[6] * b[12],
			a[7] * b[4] + a[8] * b[7] + a[9] * b[10], a[7] * b[5] + a[8] * b[8] + a[9] * b[11], a[7] * b[6] + a[8] * b[9] + a[9] * b[12],
			a[10] * b[4] + a[11] * b[7] + a[12] * b[10], a[10] * b[5] + a[11] * b[8] + a[12] * b[11], a[10] * b[6] + a[11] * b[9] + a[12] * b[12])
	elseif mb == V3 then
		return v3(a[4] * b.X + a[5] * b.Y + a[6] * b.Z + a[1], a[7] * b.X + a[8] * b.Y + a[9] * b.Z + a[2], a[10] * b.X + a[11] * b.Y + a[12] * b.Z + a[3])
	end
	error("simulador: multiplicación de CFrame con " .. type(b) .. " no soportada", 2)
end
CF.__add = function(a, b) return cf(a[1] + b.X, a[2] + b.Y, a[3] + b.Z, a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12]) end
CF.__sub = function(a, b) return cf(a[1] - b.X, a[2] - b.Y, a[3] - b.Z, a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12]) end
CF.__eq = function(a, b) if getmetatable(a) ~= CF or getmetatable(b) ~= CF then return false end for k = 1, 12 do if a[k] ~= b[k] then return false end end return true end
CF.__tostring = function(m) local t = {} for k = 1, 12 do t[k] = fmt(m[k]) end return table.concat(t, ", ") end
T.CFrame = CFrame
T.esCFrame = function(x) return getmetatable(x) == CF end
T.esV3 = function(x) return getmetatable(x) == V3 end

---------------------------------------------------------------------------- Color3
local C3 = nuevoTipo("Color3")
local Color3 = {}
local function c3(r, g, b) return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, C3) end
Color3.new = function(r, g, b) return c3(r or 0, g or 0, b or 0) end
Color3.fromRGB = function(r, g, b) return c3((r or 0) / 255, (g or 0) / 255, (b or 0) / 255) end
Color3.fromHSV = function(h, s, v)
	local i = math.floor(h * 6)
	local f = h * 6 - i
	local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
	i = i % 6
	if i == 0 then return c3(v, t, p) elseif i == 1 then return c3(q, v, p) elseif i == 2 then return c3(p, v, t)
	elseif i == 3 then return c3(p, q, v) elseif i == 4 then return c3(t, p, v) end
	return c3(v, p, q)
end
Color3.fromHex = function(hex)
	hex = tostring(hex):gsub("#", "")
	return Color3.fromRGB(tonumber(hex:sub(1, 2), 16) or 0, tonumber(hex:sub(3, 4), 16) or 0, tonumber(hex:sub(5, 6), 16) or 0)
end
Color3.toHSV = function(c)
	local r, g, b = c.R, c.G, c.B
	local mx, mn = math.max(r, g, b), math.min(r, g, b)
	local d = mx - mn
	local h = 0
	if d > 0 then
		if mx == r then h = ((g - b) / d) % 6 elseif mx == g then h = (b - r) / d + 2 else h = (r - g) / d + 4 end
		h = h / 6
	end
	return h, (mx == 0) and 0 or d / mx, mx
end
local metC3 = {}
function metC3.Lerp(a, b, t) return c3(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t) end
function metC3.ToHSV(c) return Color3.toHSV(c) end
function metC3.ToHex(c) return string.format("%02X%02X%02X", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5)) end
C3.__index = function(c, k)
	local f = metC3[k]
	if f then return f end
	error("simulador: " .. tostring(k) .. " no es un miembro válido de Color3", 2)
end
C3.__newindex = function() error("No se puede asignar a un Color3", 2) end
C3.__eq = function(a, b) if getmetatable(a) ~= C3 or getmetatable(b) ~= C3 then return false end return aprox(a.R, b.R) and aprox(a.G, b.G) and aprox(a.B, b.B) end
C3.__tostring = function(c) return fmt(c.R) .. ", " .. fmt(c.G) .. ", " .. fmt(c.B) end
T.Color3 = Color3

---------------------------------------------------------------------------- BrickColor
local BC = nuevoTipo("BrickColor")
local BrickColor = {}
local paleta = {
	["White"] = { 1, Color3.fromRGB(242, 243, 243) }, ["Medium stone grey"] = { 194, Color3.fromRGB(163, 162, 165) },
	["Bright red"] = { 21, Color3.fromRGB(196, 40, 28) }, ["Bright blue"] = { 23, Color3.fromRGB(13, 105, 172) },
	["Bright yellow"] = { 24, Color3.fromRGB(245, 205, 48) }, ["Bright green"] = { 37, Color3.fromRGB(75, 151, 75) },
	["Black"] = { 26, Color3.fromRGB(27, 42, 53) }, ["Really black"] = { 1003, Color3.fromRGB(17, 17, 17) },
	["Institutional white"] = { 1001, Color3.fromRGB(248, 248, 248) }, ["Really red"] = { 1004, Color3.fromRGB(255, 0, 0) },
	["Really blue"] = { 1010, Color3.fromRGB(0, 0, 255) }, ["Lime green"] = { 1020, Color3.fromRGB(0, 255, 0) },
	["Deep orange"] = { 1017, Color3.fromRGB(255, 176, 0) }, ["Royal purple"] = { 1031, Color3.fromRGB(98, 37, 209) },
	["Dark green"] = { 28, Color3.fromRGB(40, 127, 71) }, ["Teal"] = { 1018, Color3.fromRGB(18, 238, 212) },
	["Crimson"] = { 1327, Color3.fromRGB(151, 0, 0) }, ["Navy blue"] = { 1012, Color3.fromRGB(0, 32, 96) },
}
local function bc(nombre, numero, color) return setmetatable({ Name = nombre, Number = numero, Color = color, r = color.R, g = color.G, b = color.B }, BC) end
BrickColor.new = function(x, y, z)
	if type(x) == "string" then
		local p = paleta[x]
		if p then return bc(x, p[1], p[2]) end
		return bc(x, 194, Color3.fromRGB(163, 162, 165))
	elseif type(x) == "number" and y == nil then
		for nombre, p in pairs(paleta) do if p[1] == x then return bc(nombre, x, p[2]) end end
		return bc("Medium stone grey", 194, Color3.fromRGB(163, 162, 165))
	elseif getmetatable(x) == C3 then
		return bc("Personalizado", 0, x)
	elseif type(x) == "number" then
		return bc("Personalizado", 0, Color3.new(x, y, z))
	end
	return bc("Medium stone grey", 194, Color3.fromRGB(163, 162, 165))
end
BrickColor.random = function() return BrickColor.new("Bright blue") end
BrickColor.palette = function(i) return BrickColor.new("White") end
for _, n in ipairs({ "White", "Gray", "DarkGray", "Black", "Red", "Yellow", "Green", "Blue" }) do
	BrickColor[n] = function() return BrickColor.new(({ Gray = "Medium stone grey", DarkGray = "Black", Red = "Bright red", Yellow = "Bright yellow", Green = "Bright green", Blue = "Bright blue" })[n] or n) end
end
BC.__eq = function(a, b) if getmetatable(a) ~= BC or getmetatable(b) ~= BC then return false end return a.Name == b.Name and a.Number == b.Number end
BC.__tostring = function(b) return b.Name end
BC.__index = function(_, k) error("simulador: " .. tostring(k) .. " no es un miembro válido de BrickColor", 2) end
T.BrickColor = BrickColor

---------------------------------------------------------------------------- UDim / UDim2
local UD = nuevoTipo("UDim")
local UDim = {}
local function ud(s, o) return setmetatable({ Scale = s or 0, Offset = o or 0 }, UD) end
UDim.new = function(s, o) return ud(tonumber(s) or 0, tonumber(o) or 0) end
UD.__add = function(a, b) return ud(a.Scale + b.Scale, a.Offset + b.Offset) end
UD.__sub = function(a, b) return ud(a.Scale - b.Scale, a.Offset - b.Offset) end
UD.__eq = function(a, b) if getmetatable(a) ~= UD or getmetatable(b) ~= UD then return false end return a.Scale == b.Scale and a.Offset == b.Offset end
UD.__tostring = function(a) return fmt(a.Scale) .. ", " .. fmt(a.Offset) end
UD.__index = function(_, k) error("simulador: " .. tostring(k) .. " no es un miembro válido de UDim", 2) end
T.UDim = UDim

local U2 = nuevoTipo("UDim2")
local UDim2 = {}
local function u2(xs, xo, ys, yo) return setmetatable({ X = ud(xs, xo), Y = ud(ys, yo) }, U2) end
UDim2.new = function(a, b, c, d)
	if getmetatable(a) == UD then return setmetatable({ X = a, Y = b }, U2) end
	return u2(tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0, tonumber(d) or 0)
end
UDim2.fromScale = function(x, y) return u2(x or 0, 0, y or 0, 0) end
UDim2.fromOffset = function(x, y) return u2(0, x or 0, 0, y or 0) end
local metU2 = {}
function metU2.Lerp(a, b, t)
	return u2(a.X.Scale + (b.X.Scale - a.X.Scale) * t, a.X.Offset + (b.X.Offset - a.X.Offset) * t, a.Y.Scale + (b.Y.Scale - a.Y.Scale) * t, a.Y.Offset + (b.Y.Offset - a.Y.Offset) * t)
end
U2.__index = function(u, k)
	if k == "Width" then return u.X end
	if k == "Height" then return u.Y end
	local f = metU2[k]
	if f then return f end
	error("simulador: " .. tostring(k) .. " no es un miembro válido de UDim2", 2)
end
U2.__add = function(a, b) return u2(a.X.Scale + b.X.Scale, a.X.Offset + b.X.Offset, a.Y.Scale + b.Y.Scale, a.Y.Offset + b.Y.Offset) end
U2.__sub = function(a, b) return u2(a.X.Scale - b.X.Scale, a.X.Offset - b.X.Offset, a.Y.Scale - b.Y.Scale, a.Y.Offset - b.Y.Offset) end
U2.__unm = function(a) return u2(-a.X.Scale, -a.X.Offset, -a.Y.Scale, -a.Y.Offset) end
U2.__eq = function(a, b) if getmetatable(a) ~= U2 or getmetatable(b) ~= U2 then return false end return a.X == b.X and a.Y == b.Y end
U2.__tostring = function(a) return "{" .. tostring(a.X) .. "}, {" .. tostring(a.Y) .. "}" end
T.UDim2 = UDim2

---------------------------------------------------------------------------- Enum
local EnumItemMT = { __tipo = "EnumItem" }
EnumItemMT.__tostring = function(e) return "Enum." .. e.EnumType._nombre .. "." .. e.Name end
EnumItemMT.__index = function(e, k)
	if k == "IsA" then return function(self, n) return n == self.EnumType._nombre end end
	error("simulador: " .. tostring(k) .. " no es un miembro válido de EnumItem", 2)
end
local EnumTipoMT = { __tipo = "Enum" }
local valoresConocidos = {
	-- valores numéricos reales de algunos enums (para comparaciones con números o FromValue)
	KeyCode = { E = 101, F = 102, M = 109, P = 112, Return = 13, Escape = 27, Space = 32, ButtonA = 1000, ButtonB = 1001, ButtonX = 1002, ButtonY = 1003, ButtonStart = 1012 },
}
EnumTipoMT.__index = function(et, nombre)
	if nombre == "GetEnumItems" then
		return function(self)
			local lista = {}
			for _, it in pairs(self._items) do lista[#lista + 1] = it end
			table.sort(lista, function(a, b) return a.Value < b.Value end)
			return lista
		end
	end
	if nombre == "FromName" then return function(self, n) return self[n] end end
	if nombre == "FromValue" then
		return function(self, v)
			for _, it in pairs(self._items) do if it.Value == v then return it end end
			return nil
		end
	end
	local conocidos = valoresConocidos[et._nombre]
	local valor = conocidos and conocidos[nombre]
	if not valor then
		et._contador = et._contador + 1
		valor = et._contador
	end
	local item = setmetatable({ Name = nombre, Value = valor, EnumType = et }, EnumItemMT)
	rawset(et, nombre, item)
	et._items[nombre] = item
	return item
end
EnumTipoMT.__tostring = function(et) return et._nombre end
local Enum = setmetatable({}, {
	__index = function(t, nombre)
		local et = setmetatable({ _nombre = nombre, _contador = 0, _items = {} }, EnumTipoMT)
		rawset(t, nombre, et)
		return et
	end,
	__tipo = "Enums",
})
T.Enum = Enum
T.esEnumItem = function(x) return getmetatable(x) == EnumItemMT end

---------------------------------------------------------------------------- tipos simples
local function tipoSimple(nombre, constructor)
	local mt = { __tipo = nombre }
	mt.__index = function(_, k) error("simulador: " .. tostring(k) .. " no es un miembro válido de " .. nombre, 2) end
	return mt, function(t) return setmetatable(t, mt) end
end

local NR, nr = tipoSimple("NumberRange")
T.NumberRange = { new = function(a, b) return nr({ Min = a or 0, Max = b or a or 0 }) end }

local NSK, nsk = tipoSimple("NumberSequenceKeypoint")
T.NumberSequenceKeypoint = { new = function(t, v, e) return nsk({ Time = t, Value = v, Envelope = e or 0 }) end }
local NS, ns = tipoSimple("NumberSequence")
T.NumberSequence = { new = function(a, b)
	if type(a) == "table" then return ns({ Keypoints = a }) end
	return ns({ Keypoints = { T.NumberSequenceKeypoint.new(0, a or 0), T.NumberSequenceKeypoint.new(1, b or a or 0) } })
end }
local CSK, csk = tipoSimple("ColorSequenceKeypoint")
T.ColorSequenceKeypoint = { new = function(t, c) return csk({ Time = t, Value = c }) end }
local CS, cs = tipoSimple("ColorSequence")
T.ColorSequence = { new = function(a, b)
	if getmetatable(a) == C3 then return cs({ Keypoints = { T.ColorSequenceKeypoint.new(0, a), T.ColorSequenceKeypoint.new(1, b or a) } }) end
	return cs({ Keypoints = a or {} })
end }

local TI, ti = tipoSimple("TweenInfo")
T.TweenInfo = { new = function(tiempo, estilo, dir, rep, rev, retraso)
	return ti({ Time = tiempo or 1, EasingStyle = estilo or Enum.EasingStyle.Quad, EasingDirection = dir or Enum.EasingDirection.Out, RepeatCount = rep or 0, Reverses = rev or false, DelayTime = retraso or 0 })
end }

local PP, pp = tipoSimple("PhysicalProperties")
T.PhysicalProperties = { new = function(d, f, e, fw, ew)
	if T.esEnumItem(d) then return pp({ Density = 0.7, Friction = 0.3, Elasticity = 0.5, FrictionWeight = 1, ElasticityWeight = 1 }) end
	return pp({ Density = d or 0.7, Friction = f or 0.3, Elasticity = e or 0.5, FrictionWeight = fw or 1, ElasticityWeight = ew or 1 })
end }

local RY, ry = tipoSimple("Ray")
T.Ray = { new = function(o, d) return ry({ Origin = o, Direction = d, Unit = nil }) end }

local RP_MT = { __tipo = "RaycastParams" }
RP_MT.__index = { AddToFilter = function(self, x) table.insert(self.FilterDescendantsInstances, x) end }
T.RaycastParams = { new = function() return setmetatable({ FilterDescendantsInstances = {}, FilterType = Enum.RaycastFilterType.Exclude, IgnoreWater = false, CollisionGroup = "Default", RespectCanCollide = false, BruteForceAllSlow = false }, RP_MT) end }
local OP_MT = { __tipo = "OverlapParams" }
OP_MT.__index = { AddToFilter = function(self, x) table.insert(self.FilterDescendantsInstances, x) end }
T.OverlapParams = { new = function() return setmetatable({ FilterDescendantsInstances = {}, FilterType = Enum.RaycastFilterType.Exclude, MaxParts = 0, CollisionGroup = "Default", RespectCanCollide = false, BruteForceAllSlow = false }, OP_MT) end }

local RC, rc = tipoSimple("Rect")
T.Rect = { new = function(a, b, c, d)
	if type(a) == "table" then return rc({ Min = a, Max = b, Width = b.X - a.X, Height = b.Y - a.Y }) end
	return rc({ Min = Vector2.new(a or 0, b or 0), Max = Vector2.new(c or 0, d or 0), Width = (c or 0) - (a or 0), Height = (d or 0) - (b or 0) })
end }

local R3, r3 = tipoSimple("Region3")
T.Region3 = { new = function(mn, mx) return r3({ CFrame = CFrame.new((mn + mx) / 2), Size = mx - mn }) end }

local FontMT = { __tipo = "Font" }
FontMT.__index = function(_, k) error("simulador: " .. tostring(k) .. " no es un miembro válido de Font", 2) end
T.Font = {
	new = function(familia, peso, estilo) return setmetatable({ Family = familia, Weight = peso or Enum.FontWeight.Regular, Style = estilo or Enum.FontStyle.Normal, Bold = false }, FontMT) end,
	fromEnum = function(e) return setmetatable({ Family = "rbxasset://fonts/families/" .. tostring(e and e.Name) .. ".json", Weight = Enum.FontWeight.Regular, Style = Enum.FontStyle.Normal, Bold = false }, FontMT) end,
	fromName = function(n, p, e) return setmetatable({ Family = "rbxasset://fonts/families/" .. tostring(n) .. ".json", Weight = p or Enum.FontWeight.Regular, Style = e or Enum.FontStyle.Normal, Bold = false }, FontMT) end,
	fromId = function(id, p, e) return setmetatable({ Family = "rbxassetid://" .. tostring(id), Weight = p or Enum.FontWeight.Regular, Style = e or Enum.FontStyle.Normal, Bold = false }, FontMT) end,
}

-- Random con generador congruencial determinista
local RandMT = { __tipo = "Random" }
local metRand = {}
function metRand.NextNumber(self, a, b)
	self._s = (self._s * 1103515245 + 12345) % 2147483648
	local r = self._s / 2147483648
	a = a or 0
	b = b or 1
	return a + (b - a) * r
end
function metRand.NextInteger(self, a, b) return math.floor(metRand.NextNumber(self, a, b + 1)) end
function metRand.NextUnitVector(self) return Vector3.new(metRand.NextNumber(self, -1, 1), metRand.NextNumber(self, -1, 1), metRand.NextNumber(self, -1, 1)).Unit end
function metRand.Shuffle(self, t) for i = #t, 2, -1 do local j = metRand.NextInteger(self, 1, i) t[i], t[j] = t[j], t[i] end end
function metRand.Clone(self) return setmetatable({ _s = self._s }, RandMT) end
RandMT.__index = function(_, k) local f = metRand[k] if f then return f end error("simulador: " .. tostring(k) .. " no es un miembro válido de Random", 2) end
T.Random = { new = function(semilla) return setmetatable({ _s = math.floor(math.abs(semilla or 12345)) % 2147483648 }, RandMT) end }

-- DateTime: se alimenta del reloj virtual mediante T.relojUnix (lo fija el planificador)
local DTMT = { __tipo = "DateTime" }
local metDT = {}
function metDT.FormatLocalTime(self, formato, locale) return os.date("%Y-%m-%d %H:%M:%S", math.floor(self.UnixTimestamp)) end
metDT.FormatUniversalTime = metDT.FormatLocalTime
function metDT.ToLocalTime(self)
	local t = os.date("*t", math.floor(self.UnixTimestamp))
	return { Year = t.year, Month = t.month, Day = t.day, Hour = t.hour, Minute = t.min, Second = t.sec, Millisecond = 0 }
end
metDT.ToUniversalTime = metDT.ToLocalTime
function metDT.ToIsoDate(self) return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(self.UnixTimestamp)) end
DTMT.__index = function(_, k) local f = metDT[k] if f then return f end error("simulador: " .. tostring(k) .. " no es un miembro válido de DateTime", 2) end
local function dt(seg) return setmetatable({ UnixTimestamp = seg, UnixTimestampMillis = math.floor(seg * 1000) }, DTMT) end
T.relojUnix = function() return os.time() end
T.DateTime = {
	now = function() return dt(T.relojUnix()) end,
	fromUnixTimestamp = function(s) return dt(s) end,
	fromUnixTimestampMillis = function(ms) return dt(ms / 1000) end,
	fromLocalTime = function(y, mo, d, h, mi, s) return dt(os.time({ year = y, month = mo, day = d, hour = h or 0, min = mi or 0, sec = s or 0 })) end,
}
T.DateTime.fromUniversalTime = T.DateTime.fromLocalTime

-- typeof
T.typeof = function(v)
	local tv = type(v)
	if tv == "table" or tv == "userdata" then
		local mt = getmetatable(v)
		if mt and mt.__tipo then return mt.__tipo end
	end
	return tv
end

return T
