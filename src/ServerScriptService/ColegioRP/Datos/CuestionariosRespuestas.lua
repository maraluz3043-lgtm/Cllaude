-- SOLO SERVIDOR: respuestas correctas de los cuestionarios de Catalogs.CuestionariosPublicos y su corrección.
-- Vive en ServerScriptService para que ningún cliente pueda leer las respuestas.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Catalogs = require(ReplicatedStorage:WaitForChild("ColegioRP"):WaitForChild("Shared"):WaitForChild("Catalogs"))

local CuestionariosRespuestas = {}

-- Índice (1..4) de la opción correcta de cada pregunta, por id de cuestionario.
CuestionariosRespuestas.Respuestas = {
	MAT_1 = { 3, 1, 4, 2 },
	ESP_1 = { 3, 2, 1, 2 },
	CIE_1 = { 2, 3, 1, 3 },
}

-- Corrige respuestas { [indicePregunta] = indiceOpcion }. Devuelve aciertos, total, detalle { bool... }.
function CuestionariosRespuestas.Corregir(id, respuestas)
	local cuestionario = Catalogs.Cuestionario(id)
	local correctas = CuestionariosRespuestas.Respuestas[id]
	if not cuestionario or not correctas then
		return 0, 0, {}
	end
	if typeof(respuestas) ~= "table" then
		respuestas = {}
	end
	local aciertos = 0
	local detalle = {}
	for i = 1, #cuestionario.Preguntas do
		local elegida = tonumber(respuestas[i])
		local acierto = elegida ~= nil and elegida == correctas[i]
		detalle[i] = acierto
		if acierto then
			aciertos = aciertos + 1
		end
	end
	return aciertos, #cuestionario.Preguntas, detalle
end

return CuestionariosRespuestas
