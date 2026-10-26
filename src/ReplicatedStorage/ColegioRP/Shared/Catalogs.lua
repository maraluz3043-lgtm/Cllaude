--[[
	Ruta en el Explorer: ReplicatedStorage.ColegioRP.Shared.Catalogs
	Tipo: ModuleScript
	Catálogos de contenido: productos de cafetería, recetas del comedor, plantillas del tablero,
	actividades de PC, ayuda, changelog, equipo, uniformes, tareas de limpieza, simulador, programación,
	cuestionarios y decoración pesada. Solo datos y funciones puras; el servidor valida todo resultado.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local Catalogs = {}

---------------------------------------------------------------------------------------------------
-- Cafetería (tienda escolar). Precios iniciales en monedas escolares; el servidor guarda el inventario.
---------------------------------------------------------------------------------------------------
Catalogs.CategoriasProducto = { "Comida", "Snack", "Bebida" }

Catalogs.Productos = {
	{ Id = "EMPANADA", Nombre = "Empanada", Precio = 8, Stock = 30, Categoria = "Comida", Descripcion = "Empanada de carne o pollo, recién frita." },
	{ Id = "SANDWICH", Nombre = "Sándwich", Precio = 10, Stock = 20, Categoria = "Comida", Descripcion = "Sándwich de jamón y queso." },
	{ Id = "FRUTA", Nombre = "Fruta", Precio = 4, Stock = 25, Categoria = "Comida", Descripcion = "Porción de fruta fresca del día." },
	{ Id = "GALLETAS", Nombre = "Galletas", Precio = 4, Stock = 40, Categoria = "Snack", Descripcion = "Paquete de galletas." },
	{ Id = "CHOCOLATINA", Nombre = "Chocolatina", Precio = 3, Stock = 40, Categoria = "Snack", Descripcion = "Chocolatina pequeña." },
	{ Id = "JUGO", Nombre = "Jugo", Precio = 5, Stock = 30, Categoria = "Bebida", Descripcion = "Jugo natural en caja." },
	{ Id = "GASEOSA", Nombre = "Gaseosa", Precio = 6, Stock = 30, Categoria = "Bebida", Descripcion = "Gaseosa personal." },
	{ Id = "AGUA", Nombre = "Agua", Precio = 3, Stock = 40, Categoria = "Bebida", Descripcion = "Botella de agua." },
}

local productosPorId = {}
for _, producto in ipairs(Catalogs.Productos) do
	productosPorId[producto.Id] = producto
end

-- Producto por id o nil.
function Catalogs.Producto(id)
	if typeof(id) ~= "string" then
		return nil
	end
	return productosPorId[id]
end

---------------------------------------------------------------------------------------------------
-- Comedor gratuito: recetas por pasos. Los pasos coinciden con las estaciones de MapaLogico (COCINA).
---------------------------------------------------------------------------------------------------
Catalogs.Recetas = {
	{ Id = "ALMUERZO_1", Nombre = "Arroz con pollo y jugo", Pasos = { "Preparacion", "Coccion", "Emplatado" }, SegPorPaso = 6, Raciones = 40, Descripcion = "Arroz, pollo guisado, ensalada y jugo de fruta." },
	{ Id = "ALMUERZO_2", Nombre = "Pasta con carne y ensalada", Pasos = { "Preparacion", "Coccion", "Emplatado" }, SegPorPaso = 6, Raciones = 40, Descripcion = "Pasta con salsa de carne, ensalada fresca y limonada." },
	{ Id = "ALMUERZO_3", Nombre = "Sopa de verduras con arepa", Pasos = { "Preparacion", "Coccion", "Emplatado" }, SegPorPaso = 6, Raciones = 40, Descripcion = "Sopa de verduras, arepa con queso y agua de panela." },
}

-- Nombres visibles de las estaciones de cocina (clave = nombre en MapaLogico.Zonas.COCINA.Estaciones).
Catalogs.Estaciones = {
	Preparacion = "Mesa de preparación",
	Coccion = "Estufa y freidora",
	Emplatado = "Mesa de emplatado",
	Entrega = "Mostrador de entrega",
	Reposicion = "Congeladores (reposición)",
}

local recetasPorId = {}
for _, receta in ipairs(Catalogs.Recetas) do
	recetasPorId[receta.Id] = receta
end

-- Receta por id o nil.
function Catalogs.Receta(id)
	if typeof(id) ~= "string" then
		return nil
	end
	return recetasPorId[id]
end

---------------------------------------------------------------------------------------------------
-- Tablero: plantillas rápidas (índice = Plantilla en BoardAction).
---------------------------------------------------------------------------------------------------
Catalogs.Plantillas = { "Tema del día:", "Tarea para casa:", "Pregunta:", "Objetivo de la clase:" }

---------------------------------------------------------------------------------------------------
-- Actividades del escritorio escolar (PCs de la sala de informática)
---------------------------------------------------------------------------------------------------
Catalogs.ActividadesPC = {
	{
		Id = "Procesador", Nombre = "Procesador de texto", Icono = "✎",
		Ayuda = "Escribe apuntes o la tarea de la clase. El texto se guarda en tu cuaderno (página de la materia actual) al pulsar Guardar. Máximo 1200 caracteres por página.",
	},
	{
		Id = "Cuestionario", Nombre = "Cuestionario", Icono = "?",
		Ayuda = "Responde las preguntas de opción múltiple de la actividad que el docente haya abierto o del cuestionario de la materia. Solo cuenta la primera respuesta enviada; el servidor corrige y te muestra tu puntaje en privado.",
	},
	{
		Id = "Simulador", Nombre = "Simulador educativo", Icono = "∿",
		Ayuda = "Experimenta con caída libre y péndulo: ajusta altura, masa o longitud y observa el tiempo o el periodo. El servidor comprueba tus resultados con las fórmulas de física.",
	},
	{
		Id = "Programacion", Nombre = "Programación básica", Icono = "⌨",
		Ayuda = "Guía al robot por una cuadrícula de 8×8 hasta la meta con los comandos AVANZAR, GIRAR_IZQ, GIRAR_DER y REPETIR n ... FIN (una instrucción por línea). Pulsa Ejecutar: el servidor corre tu programa y te devuelve la traza paso a paso.",
	},
}

local actividadesPorId = {}
for _, actividad in ipairs(Catalogs.ActividadesPC) do
	actividadesPorId[actividad.Id] = actividad
end

-- Actividad de PC por id o nil.
function Catalogs.ActividadPC(id)
	if typeof(id) ~= "string" then
		return nil
	end
	return actividadesPorId[id]
end

---------------------------------------------------------------------------------------------------
-- Controles por plataforma (HelpController los muestra según el dispositivo detectado)
---------------------------------------------------------------------------------------------------
Catalogs.Controles = {
	PC = {
		{ Accion = "Moverse", Control = "W, A, S, D" },
		{ Accion = "Saltar", Control = "Espacio" },
		{ Accion = "Interactuar (puertas, PCs, cocina, tienda, baños)", Control = "E al ver el letrero" },
		{ Accion = "Patear el balón", Control = "E cerca del balón en la cancha" },
		{ Accion = "Menú principal", Control = "Botón ☰ del HUD" },
		{ Accion = "Cuaderno", Control = "Botón Cuaderno del HUD" },
		{ Accion = "Cerrar panel", Control = "Botón ✕ o Esc" },
		{ Accion = "Chat", Control = "/ (barra)" },
	},
	Movil = {
		{ Accion = "Moverse", Control = "Joystick izquierdo" },
		{ Accion = "Saltar", Control = "Botón de salto (derecha)" },
		{ Accion = "Interactuar", Control = "Tocar el letrero que aparece junto al objeto" },
		{ Accion = "Patear el balón", Control = "Botón Patear (aparece en la cancha)" },
		{ Accion = "Menú principal", Control = "Botón ☰ (arriba)" },
		{ Accion = "Cuaderno", Control = "Botón Cuaderno del HUD" },
		{ Accion = "Cerrar panel", Control = "Botón ✕ del panel" },
	},
	Mando = {
		{ Accion = "Moverse", Control = "Stick izquierdo" },
		{ Accion = "Cámara", Control = "Stick derecho" },
		{ Accion = "Saltar", Control = "A / ✕" },
		{ Accion = "Interactuar", Control = "X / ▢ al ver el letrero" },
		{ Accion = "Navegar menús", Control = "D-pad o stick (foco) y A para confirmar" },
		{ Accion = "Menú principal", Control = "Botón Menú / Opciones" },
		{ Accion = "Cerrar panel", Control = "B / ○" },
	},
}

---------------------------------------------------------------------------------------------------
-- Ayuda (HelpController). Cada sección tiene Id, Titulo y Parrafos.
---------------------------------------------------------------------------------------------------
Catalogs.Ayuda = {
	{
		Id = "Navegacion", Titulo = "Navegación por el colegio",
		Parrafos = {
			"El colegio tiene dos bloques de aulas unidos por un patio central largo y una pasarela elevada. En la entrada (portón blanco) están recepción y portería; detrás, el patio de entrada, la sala de robótica, Dirección y Coordinación, el laboratorio, la tienda escolar y las aulas 01 a 06.",
			"Siguiendo el patio central encontrarás el auditorio, la sala de informática, el comedor, el aula adaptada, la oficina administrativa y las aulas 6B, 7B, P1, P2, 6C y Grado 5°. En la planta alta hay seis aulas más (7A, 8B y las aulas Oeste/Este). Al fondo están la cancha cubierta, la cocina y el salón de mesas.",
			"Tu aula asignada aparece en el HUD. Cuando empiece una clase recibirás el aviso 'Dirígete a tu salón'; la asistencia se toma comprobando que estés dentro del aula.",
		},
	},
	{
		Id = "Horarios", Titulo = "Horarios y jornada escolar",
		Parrafos = {
			"La jornada dura unos 25 minutos reales y recorre diez periodos: espera, entrada, 1ª clase, cambio de clase, descanso, 2ª clase, almuerzo, 3ª clase, salida y reinicio. El reloj escolar del HUD avanza de 06:45 a 13:00 en sincronía con esos periodos.",
			"Cada cambio de periodo suena un timbre (si está configurado) y aparece un subtítulo. En descanso y almuerzo el comedor reparte comida gratis y la cancha está activa; en las clases los docentes pueden abrir sesiones y actividades.",
			"La dirección y la coordinación académica pueden pausar, saltar o reiniciar la jornada y cambiar las materias de cada clase desde su panel.",
		},
	},
	{
		Id = "Cargos", Titulo = "Equipos y cargos",
		Parrafos = {
			"Hay seis equipos: Estudiantes, Equipo Directivo, Docentes, Bienestar, Administración y Servicios, con 17 cargos en total. Cada cargo tiene permisos propios comprobados por el servidor: un estudiante no puede abrir sesiones de clase ni un vendedor cambiar precios.",
			"Al entrar, en JUGAR verás la lista de cargos con su disponibilidad. Estudiante es libre; el resto requiere autorización (lista de usuarios, rango de grupo o administrador). En Studio todos están disponibles para probar.",
			"El cargo se mantiene al reaparecer y determina tu punto de aparición: los estudiantes aparecen en el patio central, los docentes en su aula, la dirección en Rectoría, etc.",
		},
	},
	{
		Id = "Controles", Titulo = "Controles en PC, móvil y mando",
		Parrafos = {
			"En PC te mueves con W, A, S, D y saltas con Espacio. Las interacciones (puertas, PCs, cocina, tienda, baños) muestran un letrero: pulsa E para usarlas. El menú se abre con el botón ☰ del HUD.",
			"En móvil y tableta usas el joystick y el botón de salto; los letreros de interacción se tocan directamente. Los paneles se adaptan al tamaño de pantalla y los botones tienen tamaño táctil.",
			"Con mando, los menús se navegan por foco (D-pad o stick) y se confirma con A. Todos los paneles pueden cerrarse con B.",
		},
	},
	{
		Id = "Clase", Titulo = "Cómo asistir a clase",
		Parrafos = {
			"Cuando empieza una clase, dirígete a tu aula asignada (la verás en el HUD). Tienes 60 segundos de tolerancia para contar como Presente; después se marca Tardanza y a los 3 minutos Ausencia. La asistencia da monedas escolares.",
			"Dentro del aula aparece el panel de estudiante: puedes abrir el cuaderno, ver el tablero, responder la actividad activa y levantar la mano. Siéntate en un pupitre si lo hay; si el aula no tiene asientos, basta con estar dentro.",
			"El docente abre la sesión, fija el tema, envía avisos, crea actividades de texto u opción múltiple, califica y publica resultados. Cada estudiante recibe su resultado en privado.",
		},
	},
	{
		Id = "Tablero", Titulo = "Tablero y cuaderno",
		Parrafos = {
			"El tablero de cada aula muestra texto y trazos escritos por el docente de la sesión. El docente puede invitar a un estudiante al tablero por un turno de 90 segundos; el invitado escribe o dibuja desde su panel.",
			"Tu cuaderno tiene hasta 20 páginas de 1200 caracteres, una por materia. Se guarda automáticamente cada 45 segundos y al cerrar. Puedes compartir una página con el docente de tu sesión actual, que podrá verla mientras estés presente.",
			"Todo texto visible por otros pasa por el filtro de Roblox. Si el filtro falla, el texto no se muestra a terceros.",
		},
	},
	{
		Id = "Comida", Titulo = "Comida y cafetería",
		Parrafos = {
			"El comedor es gratuito: en descanso y almuerzo acércate a las ventanas de servicio de la cocina y usa 'Reclamar almuerzo'. Hay un lote de raciones por receta y un tiempo de espera de 2 minutos entre reclamos.",
			"El cocinero prepara las recetas por pasos (preparación, cocción y emplatado) en las estaciones de la cocina. Si no hay cocinero conectado, el servicio repone las raciones automáticamente.",
			"La tienda escolar vende productos con monedas escolares. Ganas monedas asistiendo a clase, respondiendo bien, participando, limpiando y jugando partidos (máximo 300 al día). El vendedor abre y cierra la tienda y repone; el administrador financiero fija los precios.",
		},
	},
	{
		Id = "Futbol", Titulo = "Fútbol en la cancha",
		Parrafos = {
			"En la cancha cubierta hay un balón físico y dos arcos. Únete al equipo A o B desde el panel y patea con E (o el botón Patear) cuando estés a menos de 9 studs del balón: la dirección es la de tu cámara.",
			"Un docente o árbitro puede iniciar un partido de 5 minutos con marcador y reloj. Los goles se detectan al entrar el balón en el arco; tras cada gol el balón vuelve al centro.",
			"El balón se recoloca si sale de los límites o se comporta de forma anómala. Si nadie está en la cancha, el balón se queda quieto para ahorrar recursos.",
		},
	},
	{
		Id = "Reportes", Titulo = "Reportes y soporte",
		Parrafos = {
			"Desde SOPORTE puedes enviar un reporte de Bug, Abuso, Duda o Sugerencia con ubicación y descripción (máximo 300 caracteres, 2 reportes por minuto). Recibirás un id de confirmación.",
			"Los reportes los revisan la coordinación de convivencia y la dirección. No se muestran datos de otros jugadores en el formulario.",
		},
	},
	{
		Id = "Graficos", Titulo = "Gráficos y rendimiento",
		Parrafos = {
			"En AJUSTES puedes elegir modo Calidad, Bajos o Automático (Bajos en móvil o con calidad gráfica baja). Puedes desactivar partículas, decoración lejana, postprocesado, sonidos ambiente y animaciones cosméticas (ventiladores, espejo).",
			"También hay opciones de accesibilidad: escala de texto, movimiento reducido, subtítulos de timbre, formato de hora 12/24 y ocultar etiquetas sobre los jugadores. Los ajustes se guardan en tu perfil.",
			"Si el juego va lento en modo Calidad, el sistema te sugerirá cambiar a Bajos.",
		},
	},
	{
		Id = "FAQ", Titulo = "Preguntas frecuentes",
		Parrafos = {
			"Consulta la lista de preguntas frecuentes al final de esta ayuda. Si tu duda no aparece, envía un reporte de categoría Duda desde SOPORTE.",
		},
	},
}

-- Sección de ayuda por id o nil.
function Catalogs.SeccionAyuda(id)
	for _, seccion in ipairs(Catalogs.Ayuda) do
		if seccion.Id == id then
			return seccion
		end
	end
	return nil
end

---------------------------------------------------------------------------------------------------
-- Preguntas frecuentes
---------------------------------------------------------------------------------------------------
Catalogs.FAQ = {
	{ Pregunta = "¿Por qué no puedo elegir el cargo de Director/a?", Respuesta = "Los cargos del personal requieren autorización: estar en la lista de usuarios autorizados, tener rango en el grupo del colegio o ser administrador. Escribe a la dirección del servidor si crees que deberías tenerla." },
	{ Pregunta = "¿Dónde está mi aula?", Respuesta = "El HUD muestra el nombre de tu aula asignada. Las aulas 01-06 están tras el patio de entrada (lado oeste); 6B, 7B, P1, P2, 6C y Grado 5° al fondo del patio central; 7A, 8B y las aulas Oeste/Este en la planta alta (sube por las escaleras o la pasarela)." },
	{ Pregunta = "No me marcó asistencia.", Respuesta = "La asistencia se toma al inicio de cada clase con 60 segundos de tolerancia y exige estar dentro del aula. Si llegaste después queda como Tardanza; a los 3 minutos, Ausencia." },
	{ Pregunta = "¿La comida cuesta monedas?", Respuesta = "No. El comedor es gratuito en descanso y almuerzo (un reclamo cada 2 minutos). Solo la tienda escolar cobra monedas." },
	{ Pregunta = "Perdí mi cuaderno al reaparecer.", Respuesta = "El cuaderno vive en el servidor y se guarda en tu perfil; vuelve a abrirlo desde el HUD. Si una página no se guardó, es porque superó el límite de caracteres o el filtro la rechazó." },
	{ Pregunta = "¿Puedo escribir en el tablero?", Respuesta = "Solo el docente de la sesión o un estudiante invitado por él (turno de 90 segundos). Pide la invitación levantando la mano." },
	{ Pregunta = "El juego va lento en mi teléfono.", Respuesta = "Abre AJUSTES y elige modo Bajos: desactiva decoración lejana, ventiladores, espejo, partículas y postprocesado. Se guarda para la próxima vez." },
	{ Pregunta = "¿Cómo reporto a alguien?", Respuesta = "Abre SOPORTE, elige la categoría Abuso, indica dónde ocurrió y describe lo sucedido. La coordinación de convivencia revisa los reportes." },
}

---------------------------------------------------------------------------------------------------
-- Actualizaciones (MenuController > ACTUALIZACIONES). La primera entrada es la versión actual.
---------------------------------------------------------------------------------------------------
Catalogs.Changelog = {
	{
		Version = "2.0.0", Fecha = "2026-10-26",
		Resumen = {
			"Nuevo núcleo Colegio RP construido sobre el mapa real del Instituto Educativo Jean Piaget: 39 zonas y 15 puertas auditadas, sin modificar la geometría existente.",
			"Sistema de cargos con 17 roles en 6 equipos, permisos verificados en servidor, autorización por lista, grupo o administrador y aparición por cargo.",
			"Jornada escolar automática de 10 periodos con reloj escolar, timbres, asignación balanceada de aulas y asistencia (Presente, Tardanza, Ausente).",
			"Aulas con sesiones de clase, actividades de texto y opción múltiple, calificaciones privadas, tablero compartido por aula y cuaderno personal persistente.",
			"Comedor gratuito con cocina por pasos y reposición automática; tienda escolar con monedas escolares, recibos y administración del vendedor.",
			"Cancha con balón físico validado en servidor, equipos A/B, marcador y partidos; puertas y baños interactivos con cooldown.",
			"Sala de informática con escritorio escolar: procesador de texto, cuestionarios, simulador de física y programación de un robot en cuadrícula.",
			"Menú principal, pantalla de carga con intro Horizon Studios, ayuda, soporte con reportes, ajustes de gráficos y accesibilidad, moderación en dos pasos y auditoría.",
		},
	},
}

---------------------------------------------------------------------------------------------------
-- Equipo del proyecto (MenuController > EQUIPO). Editar nombres aquí.
---------------------------------------------------------------------------------------------------
Catalogs.Equipo = {
	{ Nombre = "Adrian", Rol = "Director del proyecto" },
	{ Nombre = "(editar en Catalogs)", Rol = "Scripter" },
	{ Nombre = "(editar en Catalogs)", Rol = "Constructor" },
	{ Nombre = "(editar en Catalogs)", Rol = "Diseño de interfaz" },
	{ Nombre = "(editar en Catalogs)", Rol = "Pruebas y comunidad" },
}

---------------------------------------------------------------------------------------------------
-- Uniformes. DEPENDENCIA: subir camisas/pantalones (Crear > Ropa) y pegar los ids; 0 = sin uniforme.
-- RoleService aplica el uniforme del cargo (RoleDefinitions.Roles[cargo].Uniforme) y, si está en 0,
-- el del grupo correspondiente de esta tabla.
---------------------------------------------------------------------------------------------------
Catalogs.Uniformes = {
	Estudiante = { Nombre = "Uniforme diario", Camisa = 0, Pantalon = 0, Descripcion = "Camisa blanca y pantalón o falda gris." },
	Deportivo = { Nombre = "Uniforme deportivo", Camisa = 0, Pantalon = 0, Descripcion = "Sudadera roja del colegio." },
	Docente = { Nombre = "Docentes y directivos", Camisa = 0, Pantalon = 0, Descripcion = "Camisa formal con escudo." },
	Administracion = { Nombre = "Administración y bienestar", Camisa = 0, Pantalon = 0, Descripcion = "Chaleco institucional." },
	Servicios = { Nombre = "Servicios generales", Camisa = 0, Pantalon = 0, Descripcion = "Overol gris." },
	Cocina = { Nombre = "Cocina", Camisa = 0, Pantalon = 0, Descripcion = "Delantal y gorro blancos." },
}

-- Grupo de uniforme por equipo de RoleDefinitions.
Catalogs.UniformePorEquipo = {
	["Estudiantes"] = "Estudiante",
	["Equipo Directivo"] = "Docente",
	["Docentes"] = "Docente",
	["Bienestar"] = "Administracion",
	["Administración"] = "Administracion",
	["Servicios"] = "Servicios",
}

---------------------------------------------------------------------------------------------------
-- Tareas de limpieza (StaffService las genera en DESCANSO/ALMUERZO con ProximityPrompt temporales)
---------------------------------------------------------------------------------------------------
local recompensaLimpieza = (Config.Economia and Config.Economia.Recompensas and Config.Economia.Recompensas.TareaLimpieza) or 8
local duracionLimpieza = (Config.Limpieza and Config.Limpieza.DuracionTareaSeg) or 5

Catalogs.TareasLimpieza = {
	{ Id = "LIMP_PATIO_CENTRAL", Zona = "PATIO_CENTRAL", Nombre = "Barrer el patio central", Recompensa = recompensaLimpieza, DuracionSeg = duracionLimpieza },
	{ Id = "LIMP_PATIO_ENTRADA", Zona = "PATIO_ENTRADA", Nombre = "Barrer el patio de entrada", Recompensa = recompensaLimpieza, DuracionSeg = duracionLimpieza },
	{ Id = "LIMP_COMEDOR", Zona = "COMEDOR", Nombre = "Limpiar las mesas del comedor", Recompensa = recompensaLimpieza, DuracionSeg = duracionLimpieza },
	{ Id = "LIMP_COMEDOR_COCINA", Zona = "COMEDOR_COCINA", Nombre = "Limpiar las mesas plegables", Recompensa = recompensaLimpieza, DuracionSeg = duracionLimpieza },
	{ Id = "LIMP_BANOS_1", Zona = "BANOS_1", Nombre = "Desinfectar los lavamanos del bloque frontal", Recompensa = recompensaLimpieza, DuracionSeg = duracionLimpieza },
	{ Id = "LIMP_BANOS_2", Zona = "BANOS_2", Nombre = "Reponer jabón y papel en los baños del bloque", Recompensa = recompensaLimpieza, DuracionSeg = duracionLimpieza },
	{ Id = "LIMP_CANCHA", Zona = "CANCHA", Nombre = "Recoger basura en la cancha", Recompensa = recompensaLimpieza, DuracionSeg = duracionLimpieza },
	{ Id = "LIMP_AUDITORIO", Zona = "AUDITORIO", Nombre = "Ordenar las sillas del auditorio", Recompensa = recompensaLimpieza, DuracionSeg = duracionLimpieza },
	{ Id = "LIMP_JUEGOS", Zona = "JUEGOS", Nombre = "Revisar la zona de juegos", Recompensa = recompensaLimpieza, DuracionSeg = duracionLimpieza },
	{ Id = "LIMP_PASARELA", Zona = "PASARELA", Nombre = "Trapear la pasarela", Recompensa = recompensaLimpieza, DuracionSeg = duracionLimpieza },
	{ Id = "LIMP_INFORMATICA", Zona = "INFORMATICA", Nombre = "Limpiar los teclados de la sala de informática", Recompensa = recompensaLimpieza, DuracionSeg = duracionLimpieza },
	{ Id = "LIMP_PATIO_COCINA", Zona = "PATIO_COCINA", Nombre = "Barrer el patio de la cocina", Recompensa = recompensaLimpieza, DuracionSeg = duracionLimpieza },
}

local tareasPorId = {}
for _, tarea in ipairs(Catalogs.TareasLimpieza) do
	tareasPorId[tarea.Id] = tarea
end

-- Tarea de limpieza por id o nil.
function Catalogs.TareaLimpieza(id)
	if typeof(id) ~= "string" then
		return nil
	end
	return tareasPorId[id]
end

---------------------------------------------------------------------------------------------------
-- Simulador educativo (PC > Simulador). El cliente calcula para mostrar; el servidor valida con Validar.
---------------------------------------------------------------------------------------------------
local Simulador = {}
Simulador.Gravedad = 9.81 -- m/s²
Simulador.ToleranciaRelativa = 0.05 -- 5 % de margen al validar resultados del cliente.
Simulador.Orden = { "CaidaLibre", "Pendulo" }
Simulador.Experimentos = {
	CaidaLibre = {
		Id = "CaidaLibre", Nombre = "Caída libre",
		Descripcion = "Un objeto se suelta desde una altura h sin velocidad inicial y sin resistencia del aire. La masa no cambia el tiempo de caída.",
		Formula = "t = √(2·h / g)   ·   v = √(2·g·h)   ·   E = m·g·h",
		Entradas = {
			{ Clave = "Altura", Nombre = "Altura (m)", Min = 0.5, Max = 200, Paso = 0.5, PorDefecto = 10 },
			{ Clave = "Masa", Nombre = "Masa (kg)", Min = 0.1, Max = 100, Paso = 0.1, PorDefecto = 1, Nota = "No afecta al tiempo ni a la velocidad." },
		},
		Salidas = {
			{ Clave = "Tiempo", Nombre = "Tiempo de caída", Unidad = "s" },
			{ Clave = "Velocidad", Nombre = "Velocidad al llegar al suelo", Unidad = "m/s" },
			{ Clave = "Energia", Nombre = "Energía potencial inicial", Unidad = "J" },
		},
	},
	Pendulo = {
		Id = "Pendulo", Nombre = "Péndulo simple",
		Descripcion = "Un péndulo de longitud L oscila con pequeñas amplitudes. Su periodo depende solo de la longitud y de la gravedad, no de la masa.",
		Formula = "T = 2π·√(L / g)   ·   f = 1 / T",
		Entradas = {
			{ Clave = "Longitud", Nombre = "Longitud del hilo (m)", Min = 0.1, Max = 20, Paso = 0.1, PorDefecto = 1 },
			{ Clave = "Masa", Nombre = "Masa (kg)", Min = 0.1, Max = 50, Paso = 0.1, PorDefecto = 0.5, Nota = "No afecta al periodo." },
		},
		Salidas = {
			{ Clave = "Periodo", Nombre = "Periodo de oscilación", Unidad = "s" },
			{ Clave = "Frecuencia", Nombre = "Frecuencia", Unidad = "Hz" },
		},
	},
}

local function numeroFinito(valor)
	local n = tonumber(valor)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return nil
	end
	return n
end

-- Calcula los resultados de un experimento. Devuelve { Entradas (saneadas), Salidas } o nil, error.
function Simulador.Calcular(id, entradas)
	local experimento = Simulador.Experimentos[id]
	if not experimento then
		return nil, "Experimento desconocido"
	end
	if typeof(entradas) ~= "table" then
		entradas = {}
	end
	local valores = {}
	for _, entrada in ipairs(experimento.Entradas) do
		local v = numeroFinito(entradas[entrada.Clave])
		if v == nil then
			v = entrada.PorDefecto
		end
		valores[entrada.Clave] = math.max(entrada.Min, math.min(entrada.Max, v))
	end
	local g = Simulador.Gravedad
	local salidas = {}
	if id == "CaidaLibre" then
		local h = valores.Altura
		salidas.Tiempo = math.sqrt(2 * h / g)
		salidas.Velocidad = math.sqrt(2 * g * h)
		salidas.Energia = valores.Masa * g * h
	elseif id == "Pendulo" then
		local L = valores.Longitud
		salidas.Periodo = 2 * math.pi * math.sqrt(L / g)
		salidas.Frecuencia = 1 / salidas.Periodo
	end
	return { Entradas = valores, Salidas = salidas }, nil
end

-- (Servidor) Comprueba los resultados enviados por el cliente. Devuelve ok, error, resultadoCorrecto.
function Simulador.Validar(id, entradas, salidasCliente)
	local resultado, err = Simulador.Calcular(id, entradas)
	if not resultado then
		return false, err, nil
	end
	if typeof(salidasCliente) ~= "table" then
		return false, "Faltan los resultados", resultado
	end
	for clave, esperado in pairs(resultado.Salidas) do
		local v = numeroFinito(salidasCliente[clave])
		if v == nil then
			return false, "Falta el resultado '" .. clave .. "'", resultado
		end
		local tolerancia = math.max(math.abs(esperado) * Simulador.ToleranciaRelativa, 0.01)
		if math.abs(v - esperado) > tolerancia then
			return false, "Resultado incorrecto en '" .. clave .. "'", resultado
		end
	end
	return true, nil, resultado
end

Catalogs.Simulador = Simulador

---------------------------------------------------------------------------------------------------
-- Programación básica (PC > Programacion): robot en cuadrícula 8×8.
-- Coordenadas: X 1..8 (columnas, de izquierda a derecha), Y 1..8 (filas, de arriba hacia abajo).
-- Direcciones: N (arriba), E (derecha), S (abajo), O (izquierda).
-- El intérprete es determinista y acotado; PCService lo ejecuta en el servidor con las líneas del jugador.
---------------------------------------------------------------------------------------------------
local Programacion = {}
Programacion.Cuadricula = 8
Programacion.Comandos = { "AVANZAR", "GIRAR_IZQ", "GIRAR_DER", "REPETIR", "FIN" }
Programacion.MaxLineas = 40 -- Líneas de programa aceptadas.
Programacion.MaxPasos = 200 -- Comandos ejecutados como máximo (evita bucles largos).
Programacion.MaxRepeticiones = 20 -- Valor máximo de n en REPETIR n.
Programacion.MaxAnidamiento = 3 -- Niveles de REPETIR anidados.
Programacion.MaxCaracteresLinea = 32
Programacion.Direcciones = { "N", "E", "S", "O" }
Programacion.Ayuda = {
	"AVANZAR: el robot avanza una casilla en la dirección en que mira.",
	"GIRAR_IZQ / GIRAR_DER: gira 90° a la izquierda o a la derecha sin moverse.",
	"REPETIR n ... FIN: repite n veces los comandos entre REPETIR y FIN (se pueden anidar hasta 3 niveles).",
	"Una instrucción por línea. Las líneas que empiezan por -- son comentarios.",
}

Programacion.Retos = {
	{
		Id = "RETO_1", Nombre = "Línea recta", Dificultad = 1,
		Descripcion = "El robot está en la casilla (1,4) mirando al Este. Llévalo hasta la meta en (6,4).",
		Inicio = { X = 1, Y = 4, Dir = "E" }, Meta = { X = 6, Y = 4 }, Obstaculos = {},
		Pista = "Necesitas avanzar 5 casillas. Prueba REPETIR 5 / AVANZAR / FIN.",
		SolucionEjemplo = { "REPETIR 5", "AVANZAR", "FIN" },
	},
	{
		Id = "RETO_2", Nombre = "La esquina", Dificultad = 2,
		Descripcion = "El robot está en (1,8) mirando al Este. La meta está en (4,5): tendrás que girar.",
		Inicio = { X = 1, Y = 8, Dir = "E" }, Meta = { X = 4, Y = 5 },
		Obstaculos = { { X = 2, Y = 7 }, { X = 3, Y = 7 }, { X = 5, Y = 6 }, { X = 5, Y = 5 } },
		Pista = "Avanza 3, gira a la izquierda (mirarás al Norte) y avanza 3.",
		SolucionEjemplo = { "REPETIR 3", "AVANZAR", "FIN", "GIRAR_IZQ", "REPETIR 3", "AVANZAR", "FIN" },
	},
	{
		Id = "RETO_3", Nombre = "Esquivar el muro", Dificultad = 3,
		Descripcion = "El robot está en (1,1) mirando al Sur. Un muro ocupa la columna 4 salvo la última fila. Llega a (8,8).",
		Inicio = { X = 1, Y = 1, Dir = "S" }, Meta = { X = 8, Y = 8 },
		Obstaculos = { { X = 4, Y = 1 }, { X = 4, Y = 2 }, { X = 4, Y = 3 }, { X = 4, Y = 4 }, { X = 4, Y = 5 }, { X = 4, Y = 6 }, { X = 4, Y = 7 } },
		Pista = "Baja hasta la fila 8, gira hacia el Este y recorre toda la fila.",
		SolucionEjemplo = { "REPETIR 7", "AVANZAR", "FIN", "GIRAR_IZQ", "REPETIR 7", "AVANZAR", "FIN" },
	},
}

local retosPorId = {}
for _, reto in ipairs(Programacion.Retos) do
	retosPorId[reto.Id] = reto
end

-- Reto por id o nil.
function Programacion.Reto(id)
	if typeof(id) ~= "string" then
		return nil
	end
	return retosPorId[id]
end

-- Convierte la entrada (string con saltos de línea o array de strings) en una lista de líneas acotada.
function Programacion.NormalizarLineas(entrada)
	local lineas = {}
	if typeof(entrada) == "string" then
		for linea in string.gmatch(entrada .. "\n", "([^\n]*)\n") do
			table.insert(lineas, linea)
		end
	elseif typeof(entrada) == "table" then
		for _, linea in ipairs(entrada) do
			if typeof(linea) == "string" then
				table.insert(lineas, linea)
			end
		end
	end
	local resultado = {}
	for i, linea in ipairs(lineas) do
		if i > Programacion.MaxLineas then
			break
		end
		table.insert(resultado, string.sub(linea, 1, Programacion.MaxCaracteresLinea))
	end
	return resultado
end

local DELTAS = { N = { 0, -1 }, E = { 1, 0 }, S = { 0, 1 }, O = { -1, 0 } }
local INDICE_DIR = { N = 1, E = 2, S = 3, O = 4 }

-- Analiza las líneas y construye el árbol de nodos. Devuelve nodos o nil, error.
local function analizar(lineas)
	local tokens = {}
	for i, linea in ipairs(lineas) do
		local limpia = string.gsub(linea, "^%s+", "")
		limpia = string.gsub(limpia, "%s+$", "")
		limpia = string.upper(limpia)
		if limpia ~= "" and not string.match(limpia, "^%-%-") then
			table.insert(tokens, { Texto = limpia, Linea = i })
		end
	end
	local pos = 1
	local function bloque(profundidad, dentroRepetir)
		local nodos = {}
		while pos <= #tokens do
			local token = tokens[pos]
			if token.Texto == "FIN" then
				if dentroRepetir then
					pos = pos + 1
					return nodos, nil
				end
				return nil, string.format("Línea %d: FIN sin REPETIR", token.Linea)
			end
			local veces = string.match(token.Texto, "^REPETIR%s+(%d+)$")
			if veces then
				if profundidad >= Programacion.MaxAnidamiento then
					return nil, string.format("Línea %d: demasiados REPETIR anidados (máximo %d)", token.Linea, Programacion.MaxAnidamiento)
				end
				veces = tonumber(veces)
				if veces < 1 or veces > Programacion.MaxRepeticiones then
					return nil, string.format("Línea %d: REPETIR admite de 1 a %d", token.Linea, Programacion.MaxRepeticiones)
				end
				pos = pos + 1
				local cuerpo, err = bloque(profundidad + 1, true)
				if not cuerpo then
					return nil, err
				end
				table.insert(nodos, { Tipo = "REP", Veces = veces, Cuerpo = cuerpo, Linea = token.Linea })
			elseif token.Texto == "AVANZAR" or token.Texto == "GIRAR_IZQ" or token.Texto == "GIRAR_DER" then
				table.insert(nodos, { Tipo = "CMD", Nombre = token.Texto, Linea = token.Linea })
				pos = pos + 1
			elseif string.match(token.Texto, "^REPETIR") then
				return nil, string.format("Línea %d: REPETIR necesita un número (REPETIR 3)", token.Linea)
			else
				return nil, string.format("Línea %d: comando desconocido '%s'", token.Linea, token.Texto)
			end
		end
		if dentroRepetir then
			return nil, "Falta un FIN para cerrar un REPETIR"
		end
		return nodos, nil
	end
	return bloque(0, false)
end

-- Ejecuta un programa sobre un reto (id o tabla). Devuelve
-- { Exito, Pasos, Traza = { {X, Y, Dir, Comando} }, Posicion = {X, Y, Dir}, Error }.
function Programacion.Ejecutar(retoOId, entrada)
	local reto = retoOId
	if typeof(retoOId) == "string" then
		reto = retosPorId[retoOId]
	end
	local resultado = { Exito = false, Pasos = 0, Traza = {}, Posicion = nil, Error = nil }
	if typeof(reto) ~= "table" or typeof(reto.Inicio) ~= "table" or typeof(reto.Meta) ~= "table" then
		resultado.Error = "Reto desconocido"
		return resultado
	end
	local lineas = Programacion.NormalizarLineas(entrada)
	if #lineas == 0 then
		resultado.Error = "El programa está vacío"
		return resultado
	end
	local nodos, errAnalisis = analizar(lineas)
	if not nodos then
		resultado.Error = errAnalisis
		return resultado
	end

	local obstaculos = {}
	for _, o in ipairs(reto.Obstaculos or {}) do
		obstaculos[o.X .. "," .. o.Y] = true
	end
	local n = Programacion.Cuadricula
	local estado = { X = reto.Inicio.X, Y = reto.Inicio.Y, Dir = INDICE_DIR[reto.Inicio.Dir] or 2, Pasos = 0 }

	local function registrar(comando)
		if #resultado.Traza < Programacion.MaxPasos then
			table.insert(resultado.Traza, { X = estado.X, Y = estado.Y, Dir = Programacion.Direcciones[estado.Dir], Comando = comando })
		end
	end

	local function ejecutarBloque(lista)
		for _, nodo in ipairs(lista) do
			if nodo.Tipo == "CMD" then
				estado.Pasos = estado.Pasos + 1
				if estado.Pasos > Programacion.MaxPasos then
					return false, string.format("El programa superó los %d pasos permitidos", Programacion.MaxPasos)
				end
				if nodo.Nombre == "AVANZAR" then
					local delta = DELTAS[Programacion.Direcciones[estado.Dir]]
					local nx, ny = estado.X + delta[1], estado.Y + delta[2]
					if nx < 1 or nx > n or ny < 1 or ny > n then
						return false, string.format("Línea %d: el robot chocó con el borde en (%d,%d)", nodo.Linea, estado.X, estado.Y)
					end
					if obstaculos[nx .. "," .. ny] then
						return false, string.format("Línea %d: el robot chocó con un obstáculo en (%d,%d)", nodo.Linea, nx, ny)
					end
					estado.X, estado.Y = nx, ny
				elseif nodo.Nombre == "GIRAR_IZQ" then
					estado.Dir = ((estado.Dir - 2) % 4) + 1
				elseif nodo.Nombre == "GIRAR_DER" then
					estado.Dir = (estado.Dir % 4) + 1
				end
				registrar(nodo.Nombre)
			elseif nodo.Tipo == "REP" then
				for _ = 1, nodo.Veces do
					local ok, err = ejecutarBloque(nodo.Cuerpo)
					if not ok then
						return false, err
					end
				end
			end
		end
		return true, nil
	end

	local ok, errEjecucion = ejecutarBloque(nodos)
	resultado.Pasos = estado.Pasos
	resultado.Posicion = { X = estado.X, Y = estado.Y, Dir = Programacion.Direcciones[estado.Dir] }
	if not ok then
		resultado.Error = errEjecucion
		return resultado
	end
	if estado.X == reto.Meta.X and estado.Y == reto.Meta.Y then
		resultado.Exito = true
	else
		resultado.Error = string.format("El robot terminó en (%d,%d) y la meta está en (%d,%d)", estado.X, estado.Y, reto.Meta.X, reto.Meta.Y)
	end
	return resultado
end

Catalogs.Programacion = Programacion

---------------------------------------------------------------------------------------------------
-- Cuestionarios por materia.
-- CuestionariosPublicos: preguntas y opciones (el cliente puede mostrarlas).
-- Las respuestas correctas y la corrección viven solo en el servidor:
-- ServerScriptService.ColegioRP.Datos.CuestionariosRespuestas (el cliente no puede leerlas).
---------------------------------------------------------------------------------------------------
Catalogs.CuestionariosPublicos = {
	{
		Id = "MAT_1", Materia = "MAT", Titulo = "Fracciones, operaciones y geometría",
		Preguntas = {
			{ Texto = "¿Cuánto es 3/4 + 1/4?", Opciones = { "1/2", "4/8", "1", "2" } },
			{ Texto = "¿Cuál es el resultado de 7 × 8?", Opciones = { "56", "54", "64", "48" } },
			{ Texto = "Un triángulo tiene ángulos de 90° y 45°. ¿Cuánto mide el tercero?", Opciones = { "35°", "90°", "55°", "45°" } },
			{ Texto = "¿Cuál es el perímetro de un cuadrado de 6 cm de lado?", Opciones = { "12 cm", "24 cm", "36 cm", "18 cm" } },
		},
	},
	{
		Id = "ESP_1", Materia = "ESP", Titulo = "Gramática y vocabulario",
		Preguntas = {
			{ Texto = "¿Cuál de estas palabras es un sustantivo?", Opciones = { "correr", "rápido", "escuela", "ayer" } },
			{ Texto = "¿Qué signo cierra una pregunta?", Opciones = { "!", "?", ".", "," } },
			{ Texto = "El plural de 'lápiz' es:", Opciones = { "lápices", "lápizes", "lapiz", "lápises" } },
			{ Texto = "¿Cuál es un sinónimo de 'alegre'?", Opciones = { "triste", "contento", "cansado", "serio" } },
		},
	},
	{
		Id = "CIE_1", Materia = "CIE", Titulo = "Ciencias naturales",
		Preguntas = {
			{ Texto = "¿Qué gas necesitamos respirar para vivir?", Opciones = { "Dióxido de carbono", "Oxígeno", "Nitrógeno", "Helio" } },
			{ Texto = "¿Cuál es el planeta más cercano al Sol?", Opciones = { "Venus", "Tierra", "Mercurio", "Marte" } },
			{ Texto = "¿Qué órgano bombea la sangre por el cuerpo?", Opciones = { "Corazón", "Pulmón", "Hígado", "Riñón" } },
			{ Texto = "¿En qué estado se encuentra el hielo?", Opciones = { "Líquido", "Gaseoso", "Sólido", "Plasma" } },
		},
	},
}

Catalogs.PuntosPorAcierto = (Config.Economia and Config.Economia.Recompensas and Config.Economia.Recompensas.Respuesta) or 5

local cuestionariosPorId = {}
for _, cuestionario in ipairs(Catalogs.CuestionariosPublicos) do
	cuestionariosPorId[cuestionario.Id] = cuestionario
end

-- Cuestionario público por id o nil.
function Catalogs.Cuestionario(id)
	if typeof(id) ~= "string" then
		return nil
	end
	return cuestionariosPorId[id]
end

-- Primer cuestionario público de una materia ("MAT") o nil.
function Catalogs.CuestionarioDeMateria(materia)
	for _, cuestionario in ipairs(Catalogs.CuestionariosPublicos) do
		if cuestionario.Materia == materia then
			return cuestionario
		end
	end
	return nil
end


---------------------------------------------------------------------------------------------------
-- Decoración pesada del mapa original. MapService pone el tag Config.Tags.Decoracion a las instancias
-- cuyo Name coincide (y a sus descendientes BasePart); SettingsController las oculta localmente en
-- modo Bajos o a más de Config.Graficos.DistanciaDecoracionLejana studs. Nunca se modifican.
---------------------------------------------------------------------------------------------------
Catalogs.DecoracionPesada = {
	{ Nombre = "(1992-1998) 42\" Six's Fan CO. Bradenton Ceiling Fan", Ruta = "Workspace/(1992-1998) 42\" Six's Fan CO. Bradenton Ceiling Fan", Tipo = "Ventilador de techo (x2, comedor)", Motivo = "Scripts de giro con wait() en bucle y BodyAngularVelocity." },
	{ Nombre = "Fan", Ruta = "Workspace/Model/Model/Fan", Tipo = "Ventilador de escritorio (x4)", Motivo = "Spin Script V 1.3.1: rota el CFrame cada frame con wait(0)." },
	{ Nombre = "Project Mirror", Ruta = "Workspace/Project Mirror", Tipo = "Espejo con ViewportFrame", Motivo = "Renderiza la escena una segunda vez en el espejo del baño." },
	{ Nombre = "Mirror", Ruta = "Workspace/Mirror", Tipo = "Superficie del espejo", Motivo = "Parte móvil del espejo (la mueve Project Mirror al iniciar)." },
	{ Nombre = "Tree_Optimized_04", Ruta = "Workspace/Tree_Optimized_04", Tipo = "Árbol", Motivo = "Malla de alto número de triángulos repetida en el patio." },
}

-- Conjunto de nombres para comprobación rápida (instancia.Name).
Catalogs.DecoracionPesadaNombres = {}
for _, entrada in ipairs(Catalogs.DecoracionPesada) do
	Catalogs.DecoracionPesadaNombres[entrada.Nombre] = true
end

-- ¿El nombre corresponde a decoración pesada?
function Catalogs.EsDecoracionPesada(nombre)
	return typeof(nombre) == "string" and Catalogs.DecoracionPesadaNombres[nombre] == true
end

return Catalogs
