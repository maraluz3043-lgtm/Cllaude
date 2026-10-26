-- Ejecuta todos los escenarios en orden (cada uno en un juego nuevo) e imprime el informe agregado.
-- Uso: node run.js escenarios/todos.lua [nombreEscenario ...]
package.path = RAIZ_SIM .. "/lib/?.lua;" .. RAIZ_SIM .. "/escenarios/?.lua;" .. package.path

local Sim = require("arnes")
local orden = { "arranque", "fuzz_remotos", "funcional" }
local elegidos = {}
if ARGS and #ARGS > 0 then
	for _, a in ipairs(ARGS) do elegidos[a] = true end
end
print("Simulador Colegio RP · fengari " .. _VERSION)
for _, nombre in ipairs(orden) do
	if (next(elegidos) == nil or elegidos[nombre]) and existeArchivo(RAIZ_SIM .. "/escenarios/" .. nombre .. ".lua") then
		-- cada escenario arranca un juego nuevo: se reinician los módulos del simulador
		for _, m in ipairs({ "arnes", "cargador", "entorno", "servicios", "instancias", "planificador", "tipos" }) do package.loaded[m] = nil end
		local SimN = require("arnes")
		local ok, err = pcall(function() require(nombre)() end)
		package.loaded[nombre] = nil
		if not ok then print("ESCENARIO " .. nombre .. " abortado: " .. tostring(err)) end
		local codigo = SimN.informe()
		if codigo ~= 0 then salir(1) end
	end
end
