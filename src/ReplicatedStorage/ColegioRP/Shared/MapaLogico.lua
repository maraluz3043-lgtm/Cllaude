-- GENERADO AUTOMÁTICAMENTE por tools/gen_mapa_logico.py a partir de mapa/zonas.json. No editar a mano.
-- Mapa lógico del lugar COLEGIO_JEAN_PIAGET.rbxl: zonas reales con coordenadas auditadas (studs).
local MapaLogico = {}
MapaLogico.Version = 1
MapaLogico.Pisos = {
	[0] = { SueloY = 0, SpawnY = 3 },
	[1] = { SueloY = 14, SpawnY = 17 },
}
MapaLogico.Zonas = {}
MapaLogico.OrdenZonas = {}
MapaLogico.Aulas = {}
MapaLogico.Zonas["ENTRADA"] = {
	Id = "ENTRADA",
	Nombre = "Entrada principal, portería y recepción",
	Tipo = "entrada",
	Piso = 0,
	Centro = Vector3.new(0, 6, -812),
	Tamano = Vector3.new(64, 16, 34),
	Spawn = { Punto = Vector3.new(0, 3, -812), Estado = "confirmado", Cargos = { "Recepcionista", "Seguridad", "Enfermero" } },
	Asientos = 0,
	Evidencia = {
		"Workspace/Porton_Blanco (-1,7,-794) 26x14x1 Hoja_Izquierda/Hoja_Derecha",
		"Workspace/Letrero 'INSTITUTO E. JEAN PIAGET' (-1,19,-792)",
		"Workspace/Pavimento_y_Umbrales (4,-1,-785) 112x1x69",
	},
	Notas = "Recepción/portería no tienen sala propia: punto provisional junto al portón. Enfermería no existe en el mapa: spawn provisional aquí (reportado como pendiente).",
}
table.insert(MapaLogico.OrdenZonas, "ENTRADA")
MapaLogico.Zonas["PATIO_ENTRADA"] = {
	Id = "PATIO_ENTRADA",
	Nombre = "Patio de entrada",
	Tipo = "patio",
	Piso = 0,
	Centro = Vector3.new(0, 6, -850),
	Tamano = Vector3.new(80, 16, 40),
	Asientos = 0,
	Evidencia = {
		"Workspace/Pavimento_y_Umbrales/Baldosa_Patio (153 baldosas)",
		"Workspace/Model (palmera en maceta, 607 parts) (15,2,-778)",
		"Workspace/Contenedor_Azul_Izquierda_y_Gris_Derecha (-24,3,-828)",
	},
	Notas = "Zona abierta de circulación entre el portón y los bloques de aulas/oficinas.",
}
table.insert(MapaLogico.OrdenZonas, "PATIO_ENTRADA")
MapaLogico.Zonas["ROBOTICA"] = {
	Id = "ROBOTICA",
	Nombre = "Sala de robótica",
	Tipo = "aula_especial",
	Piso = 0,
	Centro = Vector3.new(57.5, 6, -835.5),
	Tamano = Vector3.new(29, 16, 35),
	Spawn = { Punto = Vector3.new(47, 3, -848), Estado = "confirmado", Cargos = { "ProfesorTitular" } },
	Asientos = 24,
	Tablero = { Centro = Vector3.new(57, 5, -818), Normal = Vector3.new(0, 0, -1) },
	PuestoDocente = Vector3.new(57, 3, -823),
	EstacionesPC = { Vector3.new(54, 3, -845), Vector3.new(54, 3, -839), Vector3.new(54, 3, -833), Vector3.new(67, 3, -845), Vector3.new(67, 3, -838), Vector3.new(67, 3, -833) },
	Evidencia = {
		"TextLabel 'SALA DE ROBÓTICA' Workspace/Identificacion_robotica (41,10,-843)",
		"Workspace/Mesa_1_Estacion_1..3 y Mesa_2_Estacion_1..3 'ROBOT / TELEMETRÍA' (54/67,3,-833..-845)",
		"24 asientos Red Plastic Chair (50..71, 1.6, -827..-851)",
		"Workspace/Model/Pizarra (57,5,-818) 13x7",
		"Workspace/Puerta_Infantil 'Bienvenido personal' (42,4,-823)",
	},
	Notas = "Mesas de trabajo con portátiles (sin Seat propio). Las estaciones se usan como puestos de PC con pantalla pequeña.",
}
table.insert(MapaLogico.OrdenZonas, "ROBOTICA")
table.insert(MapaLogico.Aulas, "ROBOTICA")
MapaLogico.Zonas["DIRECCION"] = {
	Id = "DIRECCION",
	Nombre = "Dirección (Rectoría)",
	Tipo = "oficina",
	Piso = 0,
	Centro = Vector3.new(48.5, 6, -865),
	Tamano = Vector3.new(11, 16, 14),
	Spawn = { Punto = Vector3.new(45, 3, -860), Estado = "provisional", Cargos = { "Director", "Subdirector" } },
	Asientos = 3,
	PuestoDocente = Vector3.new(49, 3, -869),
	Evidencia = {
		"Workspace/Escritorio_ejecutivo (49,2,-866)",
		"Workspace/Senalizacion_y_avisos/Diploma_enmarcado 'RECTORIA' (54,6,-866)",
		"Workspace/Sillon_funcionario_frente_M/Seat (49.3,1.7,-869.2)",
		"Workspace/Visita_blanca_1/2/Seat (47.6/50.0, 1.4, -863.3)",
		"Workspace/Puesto_informatico (49,4,-866) 'INICIO AGENDA ARCHIVO INFORMES'",
	},
	Notas = "Oficina gemela de COORDINACION; identificada como Dirección por el diploma 'RECTORIA' y el escritorio ejecutivo. Punto de spawn en el pasillo de acceso (41..45) por estar el interior ocupado por mobiliario; verificar en Studio.",
}
table.insert(MapaLogico.OrdenZonas, "DIRECCION")
MapaLogico.Zonas["COORDINACION"] = {
	Id = "COORDINACION",
	Nombre = "Coordinación académica y de convivencia",
	Tipo = "oficina",
	Piso = 0,
	Centro = Vector3.new(61.5, 6, -865),
	Tamano = Vector3.new(13, 16, 14),
	Spawn = { Punto = Vector3.new(61, 3, -868), Estado = "confirmado", Cargos = { "CoordinadorAcademico", "CoordinadorConvivencia" } },
	Asientos = 3,
	PuestoDocente = Vector3.new(61, 3, -859),
	Evidencia = {
		"Workspace/COORDINACION (modelo, 127 parts) (61,4,-864)",
		"TextLabel 'COORDINACION' Workspace/COORDINACION/Senalizacion_y_avisos/Rotulo_oficina (62,8,-870)",
		"Workspace/COORDINACION/Escritorio_ejecutivo (61,2,-862)",
		"Workspace/COORDINACION/Sillon_funcionario_frente_M/Seat (61.2,1.9,-859.1)",
		"Workspace/COORDINACION/Archivo_y_biblioteca 'ARCHIVO COORDINACION'",
	},
	Notas = "Convivencia comparte la oficina (no hay sala propia).",
}
table.insert(MapaLogico.OrdenZonas, "COORDINACION")
MapaLogico.Zonas["LABORATORIO"] = {
	Id = "LABORATORIO",
	Nombre = "Laboratorio de ciencias",
	Tipo = "aula_especial",
	Piso = 0,
	Centro = Vector3.new(50, 6, -888.5),
	Tamano = Vector3.new(16, 16, 35),
	Spawn = { Punto = Vector3.new(52, 3, -902), Estado = "provisional", Cargos = { "ProfesorTitular" } },
	Asientos = 0,
	Tablero = { Centro = Vector3.new(49, 7, -905), Normal = Vector3.new(0, 0, 1) },
	PuestoDocente = Vector3.new(52, 3, -902),
	Evidencia = {
		"Workspace/01_Laboratorio_Electronica (608 parts) (50,5,-888) 15x10x34",
		"TextLabel 'LABORATORIO' Workspace/Identificacion_laboratorio (41,8,-889)",
		"Pizarra 'LABORATORIO DE CIENCIAS' (49,7,-905)",
		"Workspace/01_Laboratorio_Electronica/04_Taburetes_plasticos (24 taburetes sin Seat)",
	},
	Notas = "Taburetes sin objeto Seat: la ocupación se mide por presencia en la zona. Mesones a X≈46 y 50; pasillo lateral en X≈52..53.",
}
table.insert(MapaLogico.OrdenZonas, "LABORATORIO")
table.insert(MapaLogico.Aulas, "LABORATORIO")
MapaLogico.Zonas["BANOS_1"] = {
	Id = "BANOS_1",
	Nombre = "Baños bloque frontal (niños Z>-925, niñas Z<-925)",
	Tipo = "banos",
	Piso = 0,
	Centro = Vector3.new(48.5, 6, -925),
	Tamano = Vector3.new(15, 16, 30),
	Asientos = 0,
	Objetos = {
		Inodoros = { Vector3.new(52, 3, -919), Vector3.new(52, 3, -923), Vector3.new(52, 3, -928), Vector3.new(52, 3, -931) },
		Urinarios = { Vector3.new(46, 3, -912), Vector3.new(48, 3, -912) },
		Lavamanos = { Vector3.new(41, 3, -930), Vector3.new(41, 3, -927), Vector3.new(41, 4, -924), Vector3.new(41, 4, -922) },
	},
	Evidencia = {
		"TextLabel 'BAÑOS' Workspace/03_Accesorios/Cartel_banos_ninos (41,9,-917) y Cartel_banos_ninas (41,9,-933)",
		"Workspace/Bathroom Toilet x4 (52,3,-919..-931)",
		"Workspace/Urinario_1/2 (46/48,3,-912)",
		"Workspace/Lavamanos_bajo_* y Gabinete_alto_doble/Lavamanos_alto_* (41,3..4,-922..-930)",
		"Workspace/Arquitectura_interior/Tabique_central_completo (49,6,-925)",
	},
	Notas = "Los inodoros 'Bathroom Toilet' traen Seat + ClickDetector con sonido (script original conservado).",
}
table.insert(MapaLogico.OrdenZonas, "BANOS_1")
MapaLogico.Zonas["AULA_E1"] = {
	Id = "AULA_E1",
	Nombre = "Aula junto a baños (sin placa)",
	Tipo = "aula",
	Piso = 0,
	Centro = Vector3.new(52.5, 6, -958),
	Tamano = Vector3.new(19, 16, 34),
	Spawn = { Punto = Vector3.new(57, 3, -944), Estado = "provisional", Cargos = { "ProfesorTitular" } },
	Asientos = 13,
	Tablero = { Centro = Vector3.new(50, 5, -940), Normal = Vector3.new(0, 0, -1) },
	PuestoDocente = Vector3.new(57, 3, -944),
	Evidencia = {
		"13 sillas Workspace/School Chair con Seat (44..61, 2.4, -949..-971)",
		"Workspace/Model/Pizarra (50,5,-940) 8x5 en muro norte",
	},
	Notas = "Cada School Chair contiene dos Seat superpuestos (duplicado del modelo); el sistema cuenta una silla por posición.",
}
table.insert(MapaLogico.OrdenZonas, "AULA_E1")
table.insert(MapaLogico.Aulas, "AULA_E1")
MapaLogico.Zonas["TIENDA"] = {
	Id = "TIENDA",
	Nombre = "Tienda escolar (cafetería comercial)",
	Tipo = "cafeteria",
	Piso = 0,
	Centro = Vector3.new(52.5, 6, -996),
	Tamano = Vector3.new(19, 16, 40),
	Spawn = { Punto = Vector3.new(52, 3, -995), Estado = "confirmado", Cargos = { "VendedorCafeteria" } },
	Asientos = 0,
	Mostrador = { Centro = Vector3.new(45, 3, -987), Frente = Vector3.new(-1, 0, 0) },
	Evidencia = {
		"Workspace/empanada_01 x4 (45,6,-986..-988)",
		"Workspace/Model/Botellas_Respaldo_30_Piezas (58,5,-982)",
		"Workspace/Model/Fryer* (57,3,-1011)",
		"Workspace/Tapa_Abierta_100_Grados/Canastilla_Alambre_18_Barras (55,1,-978)",
		"Foto 03 anotada 'tienda'",
	},
	Notas = "Los estudiantes compran desde el patio (X≈41) frente a la vitrina de empanadas.",
}
table.insert(MapaLogico.OrdenZonas, "TIENDA")
MapaLogico.Zonas["A05"] = {
	Id = "A05",
	Nombre = "Aula 05",
	Tipo = "aula",
	Piso = 0,
	Centro = Vector3.new(-40.5, 6, -853),
	Tamano = Vector3.new(33, 16, 20),
	Spawn = { Punto = Vector3.new(-45, 3, -860), Estado = "confirmado", Cargos = { "ProfesorTitular" } },
	Asientos = 9,
	Tablero = { Centro = Vector3.new(-53, 5, -853), Normal = Vector3.new(1, 0, 0) },
	PuestoDocente = Vector3.new(-48, 3, -853),
	Evidencia = {
		"Placa 'AULA 05' Workspace/Equipamiento_y_Detalles/Placa_aula (-27,8,-860)",
		"Workspace/Puerta_Aula_05_Abierta (-28,4,-860)",
		"9 Workspace/School Chair/Seat (-29..-38, 2.3, -844..-855)",
		"Workspace/Model/Pizarra (-53,5,-853)",
	},
	Notas = "",
}
table.insert(MapaLogico.OrdenZonas, "A05")
table.insert(MapaLogico.Aulas, "A05")
MapaLogico.Zonas["A04"] = {
	Id = "A04",
	Nombre = "Aula 04",
	Tipo = "aula",
	Piso = 0,
	Centro = Vector3.new(-40.5, 6, -875),
	Tamano = Vector3.new(33, 16, 20),
	Spawn = { Punto = Vector3.new(-45, 3, -882), Estado = "provisional", Cargos = { "ProfesorTitular" } },
	Asientos = 9,
	Tablero = { Centro = Vector3.new(-53, 5, -875), Normal = Vector3.new(1, 0, 0) },
	PuestoDocente = Vector3.new(-48, 3, -875),
	Evidencia = {
		"Placa 'AULA 04' (-27,8,-882)",
		"Workspace/Puerta_Aula_04 'BIENVENIDOS' (-27,4,-882)",
		"9 School Chair/Seat (-29..-38, 2.3, -866..-877)",
		"Workspace/Model/Pizarra (-53,5,-875)",
	},
	Notas = "",
}
table.insert(MapaLogico.OrdenZonas, "A04")
table.insert(MapaLogico.Aulas, "A04")
MapaLogico.Zonas["A03"] = {
	Id = "A03",
	Nombre = "Aula 03",
	Tipo = "aula",
	Piso = 0,
	Centro = Vector3.new(-40.5, 6, -897),
	Tamano = Vector3.new(33, 16, 20),
	Spawn = { Punto = Vector3.new(-45, 3, -904), Estado = "provisional", Cargos = { "ProfesorTitular" } },
	Asientos = 9,
	Tablero = { Centro = Vector3.new(-53, 5, -897), Normal = Vector3.new(1, 0, 0) },
	PuestoDocente = Vector3.new(-48, 3, -897),
	Evidencia = {
		"Placa 'AULA 03' (-27,8,-905)",
		"Workspace/Puerta_Aula_Abierta (-28,4,-905)",
		"9 School Chair/Seat (-29..-38, 2.3, -888..-899)",
		"Workspace/Model/Pizarra (-53,5,-897)",
	},
	Notas = "",
}
table.insert(MapaLogico.OrdenZonas, "A03")
table.insert(MapaLogico.Aulas, "A03")
MapaLogico.Zonas["A02"] = {
	Id = "A02",
	Nombre = "Aula 02",
	Tipo = "aula",
	Piso = 0,
	Centro = Vector3.new(-40.5, 6, -919),
	Tamano = Vector3.new(33, 16, 20),
	Spawn = { Punto = Vector3.new(-45, 3, -926), Estado = "provisional", Cargos = { "ProfesorTitular" } },
	Asientos = 9,
	Tablero = { Centro = Vector3.new(-53, 5, -919), Normal = Vector3.new(1, 0, 0) },
	PuestoDocente = Vector3.new(-48, 3, -919),
	Evidencia = {
		"Placa 'AULA 02' (-27,8,-926)",
		"Workspace/Puerta_Infantil 'BIENVENIDOS' (-27,4,-926)",
		"9 School Chair/Seat (-29..-38, 2.3, -910..-921)",
		"Workspace/Model/Pizarra (-53,5,-919)",
	},
	Notas = "",
}
table.insert(MapaLogico.OrdenZonas, "A02")
table.insert(MapaLogico.Aulas, "A02")
MapaLogico.Zonas["A01"] = {
	Id = "A01",
	Nombre = "Aula 01",
	Tipo = "aula",
	Piso = 0,
	Centro = Vector3.new(-40.5, 6, -941),
	Tamano = Vector3.new(33, 16, 20),
	Spawn = { Punto = Vector3.new(-45, 3, -948), Estado = "provisional", Cargos = { "ProfesorTitular" } },
	Asientos = 9,
	Tablero = { Centro = Vector3.new(-53, 5, -942), Normal = Vector3.new(1, 0, 0) },
	PuestoDocente = Vector3.new(-48, 3, -942),
	Evidencia = {
		"Placa 'AULA 01' (-27,8,-948)",
		"Workspace/Puerta_Arcoiris 'BIENVENIDOS' (-27,4,-948)",
		"9 School Chair/Seat (-29..-38, 2.3, -933..-944)",
		"Workspace/Model/Pizarra (-53,5,-942)",
	},
	Notas = "",
}
table.insert(MapaLogico.OrdenZonas, "A01")
table.insert(MapaLogico.Aulas, "A01")
MapaLogico.Zonas["A06"] = {
	Id = "A06",
	Nombre = "Aula 06 (sin placa)",
	Tipo = "aula",
	Piso = 0,
	Centro = Vector3.new(-40.5, 6, -963),
	Tamano = Vector3.new(33, 16, 22),
	Spawn = { Punto = Vector3.new(-45, 3, -970), Estado = "provisional", Cargos = { "ProfesorTitular" } },
	Asientos = 9,
	Tablero = { Centro = Vector3.new(-53, 5, -964), Normal = Vector3.new(1, 0, 0) },
	PuestoDocente = Vector3.new(-48, 3, -964),
	Evidencia = {
		"9 Workspace/School Chair (18 Seat duplicados) (-29..-38, 2.4, -955..-966)",
		"Workspace/Model/Pizarra (-53,5,-964)",
	},
	Notas = "",
}
table.insert(MapaLogico.OrdenZonas, "A06")
table.insert(MapaLogico.Aulas, "A06")
MapaLogico.Zonas["JUEGOS"] = {
	Id = "JUEGOS",
	Nombre = "Zona de juegos (cubierta y cercada)",
	Tipo = "recreo",
	Piso = 0,
	Centro = Vector3.new(-38, 6, -1025),
	Tamano = Vector3.new(26, 16, 104),
	Asientos = 0,
	Evidencia = {
		"Workspace/Model (737 parts) con 03_Techo_acanalado_y_cerchas y 04_Cerca_de_malla_ciclonica (-27,3,-1024)",
		"Casita_de_juego_5.8 (-39,3,-1034) y Casita_de_juego_-21",
		"Mural pintado (Copa_pintada, Colina_verdosa_del_mural)",
		"Foto 05 anotada 'zona de juegos'",
	},
	Notas = "Uso en DESCANSO; sin lógica propia más allá de presencia.",
}
table.insert(MapaLogico.OrdenZonas, "JUEGOS")
MapaLogico.Zonas["AUDITORIO"] = {
	Id = "AUDITORIO",
	Nombre = "Auditorio (escenario, banderas y sillas)",
	Tipo = "auditorio",
	Piso = 0,
	Centro = Vector3.new(-44.5, 6, -1144),
	Tamano = Vector3.new(37, 16, 124),
	Spawn = { Punto = Vector3.new(-39, 3, -1130), Estado = "confirmado", Cargos = {  } },
	Asientos = 28,
	Escenario = Vector3.new(-39, 3, -1146),
	Evidencia = {
		"Workspace/Grupo_Tres_Banderas (-38,5,-1151)",
		"Telón, molduras doradas, paneles de mármol y altavoz (Workspace/Model/Altavoz_Derecho) alrededor de (-39,3,-1140)",
		"18 sillas Workspace/Model/School Chair (36 Seat duplicados) (-29..-55, 2.1, -1156..-1200)",
		"10 Red Plastic Chair (-47.4, 1.6, -1099..-1125)",
		"SpawnLocation original (-38.9,-0.4,-1140)",
		"Foto 05 anotada 'Auditorio'",
	},
	Notas = "El SpawnLocation original queda dentro de esta zona; se conserva (Neutral) como respaldo.",
}
table.insert(MapaLogico.OrdenZonas, "AUDITORIO")
MapaLogico.Zonas["INFORMATICA"] = {
	Id = "INFORMATICA",
	Nombre = "Sala de informática (Computer Science / Library)",
	Tipo = "aula_pc",
	Piso = 0,
	Centro = Vector3.new(-50, 6, -1227),
	Tamano = Vector3.new(32, 16, 46),
	Spawn = { Punto = Vector3.new(-60, 3, -1234), Estado = "provisional", Cargos = { "ProfesorTitular" } },
	Asientos = 18,
	Tablero = { Centro = Vector3.new(-65, 7, -1234), Normal = Vector3.new(1, 0, 0) },
	PuestoDocente = Vector3.new(-60, 3, -1234),
	PCs = { Vector3.new(-52, 5, -1240), Vector3.new(-40, 5, -1240), Vector3.new(-46, 5, -1240), Vector3.new(-57, 5, -1240), Vector3.new(-48, 5, -1230), Vector3.new(-53, 5, -1230), Vector3.new(-59, 5, -1230), Vector3.new(-58, 5, -1228), Vector3.new(-52, 5, -1228), Vector3.new(-47, 5, -1228), Vector3.new(-64, 5, -1222), Vector3.new(-38, 5, -1220), Vector3.new(-64, 5, -1216), Vector3.new(-38, 5, -1215), Vector3.new(-53, 5, -1210), Vector3.new(-60, 5, -1210), Vector3.new(-42, 5, -1210), Vector3.new(-46, 5, -1210) },
	Evidencia = {
		"18 Workspace/Model/Computer (monitor, teclado, torre) en (-64..-38, 5, -1210..-1240)",
		"18 Seat (36 duplicados) Workspace/Model/Model/Seat (-60..-41, 2.4, -1213..-1237)",
		"Workspace/Model/Letreros/Letrero_Computer Science y Letrero_Library 'JEAN PIAGET' (-30,11,-1225)",
		"Workspace/Model/Model/Pizarra (-65,7,-1234)",
		"Workspace/Model/Model/LogoYLema (-35,6,-1211)",
		"Foto 07 anotada 'Sala informática'",
	},
	Notas = "Las pantallas 'Computer Monitor 1' reciben una SurfaceGui de escritorio escolar. Cada PC se empareja con el Seat más cercano.",
}
table.insert(MapaLogico.OrdenZonas, "INFORMATICA")
table.insert(MapaLogico.Aulas, "INFORMATICA")
MapaLogico.Zonas["PATIO_CENTRAL"] = {
	Id = "PATIO_CENTRAL",
	Nombre = "Patio central (eje de circulación)",
	Tipo = "patio",
	Piso = 0,
	Centro = Vector3.new(4, 6, -1166),
	Tamano = Vector3.new(60, 16, 170),
	Spawn = { Punto = Vector3.new(0, 3, -1100), Estado = "confirmado", Cargos = { "Estudiante" } },
	Asientos = 0,
	Evidencia = {
		"Workspace/Piso_Patio_A, baldosas y zócalos alrededor de (10,2,-1100)",
		"Muro oriental con 'Pinturas deportivas' y letras (Workspace/Model 341 parts) (62,7,-1143)",
		"Foto 09 anotada 'Pasillo central y salones'",
	},
	Notas = "Spawn por defecto de estudiantes ('patio escolar'). ENTRADA queda a ~290 studs del centro; cambiable en Config.",
}
table.insert(MapaLogico.OrdenZonas, "PATIO_CENTRAL")
MapaLogico.Zonas["COMEDOR"] = {
	Id = "COMEDOR",
	Nombre = "Comedor (Dining Room, mesas de 4)",
	Tipo = "comedor",
	Piso = 0,
	Centro = Vector3.new(48.5, 6, -1280),
	Tamano = Vector3.new(27, 16, 60),
	Spawn = { Punto = Vector3.new(40, 3, -1300), Estado = "confirmado", Cargos = {  } },
	Asientos = 20,
	Evidencia = {
		"5 mesas Workspace/Model/Pluta_Table con 20 Red Plastic Chair/Seat (37..60, 1.3, -1255..-1305)",
		"Ventiladores de techo (49,20,-1271/-1293)",
		"Mural 'DINING ROOM' / 'COMEDOR' Workspace/Mural_rosa_DINING_ROOM (49,11,-1342)",
		"Foto 08 anotada 'Comedor'",
	},
	Notas = "Zona de consumo del comedor gratuito; la preparación y entrega ocurre en COCINA.",
}
table.insert(MapaLogico.OrdenZonas, "COMEDOR")
MapaLogico.Zonas["AULA_ADAPTADA"] = {
	Id = "AULA_ADAPTADA",
	Nombre = "Aula adaptada (Interior_Adaptado)",
	Tipo = "aula",
	Piso = 0,
	Centro = Vector3.new(-40.5, 6, -1311.5),
	Tamano = Vector3.new(33, 16, 27),
	Spawn = { Punto = Vector3.new(-50, 3, -1310), Estado = "provisional", Cargos = { "ProfesorApoyo", "Tutor" } },
	Asientos = 15,
	Tablero = { Centro = Vector3.new(-56, 6, -1312), Normal = Vector3.new(1, 0, 0) },
	PuestoDocente = Vector3.new(-52, 3, -1302),
	Evidencia = {
		"Workspace/Model/Interior_Adaptado/Pupitres/Pupitre_Madera x15 con Asiento (-32..-47, 1.8, -1300..-1321)",
		"Workspace/Model/Interior_Adaptado/Docente/Silla_Docente_Negra/Asiento (-54.4,1.8,-1302.3)",
		"Tablero_Acrilico 'Bienvenidos' (-56,6,-1312) y Letrero_Grado (-56,9,-1321)",
		"Puerta roja 'WELCOME' Workspace/Model/Model/Hoja_Roja (-25,4,-1321)",
	},
	Notas = "",
}
table.insert(MapaLogico.OrdenZonas, "AULA_ADAPTADA")
table.insert(MapaLogico.Aulas, "AULA_ADAPTADA")
MapaLogico.Zonas["OFICINA_ADMIN"] = {
	Id = "OFICINA_ADMIN",
	Nombre = "Oficina administrativa (Secretaría, Administración y Orientación)",
	Tipo = "oficina",
	Piso = 0,
	Centro = Vector3.new(-40.5, 6, -1338),
	Tamano = Vector3.new(33, 16, 24),
	Spawn = { Punto = Vector3.new(-46, 3, -1340), Estado = "confirmado", Cargos = { "Secretario", "AdministradorFinanciero", "Orientador" } },
	Asientos = 1,
	PuestoDocente = Vector3.new(-41, 3, -1338),
	Evidencia = {
		"Rótulo pequeño 'COORDINACIÓN' Workspace/Rotulo_pequeno_COORDINACION (-26,10,-1339)",
		"Aviso 'INFORMACIÓN' (-27,4,-1326)",
		"Puerta roja 'WELCOME' Workspace/03_Puerta_Roja_WELCOME_BRILLA (-27,4,-1351)",
		"PC de escritorio Workspace/ExterTech Asus ROG Predator D65 (-37,5,-1338) y Workspace/Modern Office Chair/Seat (-41,2.5,-1338.4)",
	},
	Notas = "El mapa no tiene secretaría, administración ni orientación propias: se asignan a esta oficina (rotulada 'COORDINACIÓN' en pequeño). Orientación funciona con agenda RP, sin tratamiento clínico.",
}
table.insert(MapaLogico.OrdenZonas, "OFICINA_ADMIN")
MapaLogico.Zonas["AULA_P1"] = {
	Id = "AULA_P1",
	Nombre = "Aula P1 (planta baja oeste, sin placa)",
	Tipo = "aula",
	Piso = 0,
	Centro = Vector3.new(-40.5, 6, -1386.5),
	Tamano = Vector3.new(33, 16, 43),
	Spawn = { Punto = Vector3.new(-42, 3, -1390), Estado = "confirmado", Cargos = { "ProfesorTitular" } },
	Asientos = 0,
	Tablero = { Centro = Vector3.new(-37, 6, -1408), Normal = Vector3.new(0, 0, 1) },
	PuestoDocente = Vector3.new(-49, 3, -1403),
	Evidencia = {
		"Workspace/Pupitre_02..19_azul / _tapizado / _gris (sin Seat) (-33..-49, 2, -1375..-1396)",
		"Workspace/Pizarra_pared_derecha_+X/Pizarra_blanca (-37,6,-1409) 20x6",
		"Workspace/Mesa_Profesor (-49,1,-1405)",
		"Avisos 'NORMAS DEL AULA' (-55,8,-1405) y 'PROHIBIDO FUMAR' (-55,8,-1380)",
	},
	Notas = "Pupitres sin objeto Seat: asistencia por presencia en zona (de pie).",
}
table.insert(MapaLogico.OrdenZonas, "AULA_P1")
table.insert(MapaLogico.Aulas, "AULA_P1")
MapaLogico.Zonas["6B"] = {
	Id = "6B",
	Nombre = "Aula 6B",
	Tipo = "aula",
	Piso = 0,
	Centro = Vector3.new(-40.5, 6, -1430),
	Tamano = Vector3.new(33, 16, 40),
	Spawn = { Punto = Vector3.new(-42, 3, -1430), Estado = "confirmado", Cargos = { "ProfesorTitular" } },
	Asientos = 0,
	Tablero = { Centro = Vector3.new(-39, 7, -1449), Normal = Vector3.new(0, 0, 1) },
	PuestoDocente = Vector3.new(-40, 3, -1443),
	Puertas = { "Puerta_6B" },
	Evidencia = {
		"Workspace/Puerta_6B (-23,3,-1445) con Hoja_transitable",
		"12 Workspace/Pupitre (sin Seat) (-46..-31, 2, -1427..-1440)",
		"Workspace/Model/Pizarra_blanca (-39,7,-1449) 13x6 + Marco_pizarra",
		"Workspace/Mesa_profesor (-40,2,-1445) y Silla_profesor (-40,2,-1447)",
		"Workspace/Luces_y_ventiladores (-38,12,-1434)",
		"Rótulo 'RUTA DE EVACUACIÓN' (-22,12,-1444)",
	},
	Notas = "Pupitres sin Seat. Sugerencia manual: duplicar 'Workspace/Pupitres/Pupitre_Azul' (con Asiento) del aula 6C si se desea ocupación por asiento.",
}
table.insert(MapaLogico.OrdenZonas, "6B")
table.insert(MapaLogico.Aulas, "6B")
MapaLogico.Zonas["7B"] = {
	Id = "7B",
	Nombre = "Aula 7B",
	Tipo = "aula",
	Piso = 0,
	Centro = Vector3.new(-40.5, 6, -1472),
	Tamano = Vector3.new(33, 16, 40),
	Spawn = { Punto = Vector3.new(-50, 3, -1470), Estado = "confirmado", Cargos = { "ProfesorTitular" } },
	Asientos = 0,
	Tablero = { Centro = Vector3.new(-36, 6, -1479), Normal = Vector3.new(0, 0, 1) },
	PuestoDocente = Vector3.new(-35, 3, -1458),
	Puertas = { "Puerta_7B" },
	Evidencia = {
		"Workspace/Puerta_7B (-22,5,-1453) con Hoja_transitable y rótulo '7B'",
		"15 Workspace/Model/Pupitre (sin Seat) (-40..-25, 2, -1459..-1476)",
		"Workspace/Model/Pizarra_blanca (-36,6,-1479) 13x6",
		"Workspace/Mesa_profesor (-35,2,-1456) y Silla_profesor (-35,2,-1452)",
		"Workspace/Luces_y_ventiladores (-38,12,-1464)",
		"Workspace/Puerta_metal_oscura_abierta (-22,5,-1491)",
	},
	Notas = "El tablero (Z=-1479) y el escritorio (Z=-1456) están en extremos opuestos; los pupitres miran al tablero.",
}
table.insert(MapaLogico.OrdenZonas, "7B")
table.insert(MapaLogico.Aulas, "7B")
MapaLogico.Zonas["BANOS_2"] = {
	Id = "BANOS_2",
	Nombre = "Baños bloque de dos plantas (GIRLS)",
	Tipo = "banos",
	Piso = 0,
	Centro = Vector3.new(-30, 6, -1505.5),
	Tamano = Vector3.new(22, 16, 23),
	Spawn = { Punto = Vector3.new(-30, 3, -1505), Estado = "confirmado", Cargos = { "Limpieza" } },
	Asientos = 0,
	Objetos = {
		Inodoros = { Vector3.new(-36, 3, -1497), Vector3.new(-33, 3, -1497), Vector3.new(-30, 3, -1497), Vector3.new(-27, 3, -1497), Vector3.new(-33, 3, -1514), Vector3.new(-24, 3, -1514) },
		Lavamanos = { Vector3.new(-28, 3, -1501), Vector3.new(-33, 3, -1501), Vector3.new(-22, 3, -1498) },
	},
	Puertas = { "Puerta_GIRLS_secundaria", "Puerta_GIRLS_abierta" },
	Evidencia = {
		"Workspace/Bathroom Toilet x6 (-36..-27, 3, -1497) y (-33/-24, 3, -1514)",
		"Workspace/04_Lavamanos_y_accesorios (-31,3,-1501) + Workspace/Lavamanos_delantero (-22,3,-1498)",
		"Workspace/Espejo (-31,7,-1500)",
		"Workspace/03_Puertas_de_madera/Puerta_GIRLS_secundaria (-34,4,-1509) y Puerta_GIRLS_abierta (-23,5,-1507)",
		"Rótulos 'SALIDA' (-41,10,-1504) e 'INFORMACION' (-41,8,-1505)",
		"Foto 10 anotada 'baños'",
	},
	Notas = "No existe cuarto de mantenimiento: el personal de limpieza aparece aquí (provisional) y sus misiones se reparten por zonas.",
}
table.insert(MapaLogico.OrdenZonas, "BANOS_2")
MapaLogico.Zonas["6C"] = {
	Id = "6C",
	Nombre = "Aula 6C",
	Tipo = "aula",
	Piso = 0,
	Centro = Vector3.new(48.5, 6, -1407),
	Tamano = Vector3.new(23, 16, 34),
	Spawn = { Punto = Vector3.new(45, 3, -1418), Estado = "provisional", Cargos = { "ProfesorTitular" } },
	Asientos = 20,
	Tablero = { Centro = Vector3.new(47, 6, -1423), Normal = Vector3.new(0, 0, 1) },
	PuestoDocente = Vector3.new(52, 3, -1419),
	Evidencia = {
		"Workspace/Pupitres (520 parts) con 20 Pupitre_Azul/Asiento (40..54, 2.1, -1395..-1413)",
		"Letrero_Grado '6C' Workspace/Tablero_y_Carteleras/Letrero_Grado/Placa (54,9,-1423)",
		"Tablero_Acrilico 'Bienvenidos' (47,6,-1423)",
		"Workspace/Docente (Mesa_Docente_Madera + Silla_Docente_Azul/Asiento) (52,3,-1420)",
		"Reloj_Pared (54,11,-1423), Botellon_Agua (38,3,-1420)",
	},
	Notas = "Las puertas de la fachada (X≈36..39) no llevan el rótulo 6C; la Puerta_Blanca_6C está frente al aula de Grado 5° (discrepancia de rotulación a revisar).",
}
table.insert(MapaLogico.OrdenZonas, "6C")
table.insert(MapaLogico.Aulas, "6C")
MapaLogico.Zonas["AULA_P2"] = {
	Id = "AULA_P2",
	Nombre = "Aula P2 (planta baja este, pupitres de madera)",
	Tipo = "aula",
	Piso = 0,
	Centro = Vector3.new(48.5, 6, -1437.5),
	Tamano = Vector3.new(23, 16, 23),
	Spawn = { Punto = Vector3.new(45, 3, -1437), Estado = "provisional", Cargos = { "ProfesorTitular" } },
	Asientos = 15,
	Tablero = { Centro = Vector3.new(57, 6, -1437), Normal = Vector3.new(-1, 0, 0) },
	PuestoDocente = Vector3.new(54, 3, -1442),
	Puertas = { "Puerta_Morada" },
	Evidencia = {
		"Workspace/Pupitres (390 parts) con 15 Pupitre_Madera/Asiento (41..50, 2.1, -1429..-1447)",
		"Tablero_Acrilico 'Bienvenidos' en muro este (57,6,-1437)",
		"Workspace/Docente (Mesa_Docente_Metal + Silla_Docente_Negra/Asiento) (55,2,-1445)",
		"Workspace/Puerta_Morada 'grado 5°' (37,5,-1446)",
	},
	Notas = "",
}
table.insert(MapaLogico.OrdenZonas, "AULA_P2")
table.insert(MapaLogico.Aulas, "AULA_P2")
MapaLogico.Zonas["5"] = {
	Id = "5",
	Nombre = "Aula Grado 5°",
	Tipo = "aula",
	Piso = 0,
	Centro = Vector3.new(48.5, 6, -1468.5),
	Tamano = Vector3.new(23, 16, 35),
	Spawn = { Punto = Vector3.new(45, 3, -1456), Estado = "provisional", Cargos = { "ProfesorTitular" } },
	Asientos = 20,
	Tablero = { Centro = Vector3.new(47, 6, -1450), Normal = Vector3.new(0, 0, -1) },
	PuestoDocente = Vector3.new(53, 3, -1457),
	Puertas = { "Puerta_Blanca_6C" },
	Evidencia = {
		"Workspace/Pupitres (520 parts) con 20 Pupitre_Azul/Asiento (42..56, 2.1, -1460..-1479)",
		"Letrero_Grado 'GRADO 5°' (55,9,-1450)",
		"Tablero_Acrilico 'Bienvenidos' (47,6,-1450)",
		"Workspace/Docente (Mesa_Docente_Madera + Silla_Docente_Azul/Asiento) (53,3,-1454)",
		"Workspace/Puerta_Blanca_6C '6C' (39,5,-1469)",
		"Workspace/Tablero_y_Carteleras (49,7,-1468)",
	},
	Notas = "",
}
table.insert(MapaLogico.OrdenZonas, "5")
table.insert(MapaLogico.Aulas, "5")
MapaLogico.Zonas["ALTO_O1"] = {
	Id = "ALTO_O1",
	Nombre = "Aula planta alta oeste 1",
	Tipo = "aula",
	Piso = 1,
	Centro = Vector3.new(-40.5, 21, -1378),
	Tamano = Vector3.new(33, 14, 44),
	Spawn = { Punto = Vector3.new(-42, 17, -1378), Estado = "confirmado", Cargos = { "ProfesorTitular" } },
	Asientos = 0,
	Tablero = { Centro = Vector3.new(-41, 20, -1399), Normal = Vector3.new(0, 0, 1) },
	PuestoDocente = Vector3.new(-49, 17, -1393),
	Evidencia = {
		"Workspace/Chair_01..21_* (sin Seat) (-27..-57, 15, -1359..-1396)",
		"Workspace/Pizarra_DERECHA x2 (-46/-39, 19..20, -1398..-1400) y Pared_DERECHA_pizarra (-41,20,-1399)",
		"Workspace/Mesa_Profesor (-49,15,-1394)",
		"Workspace/02_Piso_desgastado (-41,14,-1378)",
		"Workspace/04_Cielo_raso (-42,26,-1378) con luminarias",
	},
	Notas = "",
}
table.insert(MapaLogico.OrdenZonas, "ALTO_O1")
table.insert(MapaLogico.Aulas, "ALTO_O1")
MapaLogico.Zonas["ALTO_O2"] = {
	Id = "ALTO_O2",
	Nombre = "Aula planta alta oeste 2",
	Tipo = "aula",
	Piso = 1,
	Centro = Vector3.new(-40.5, 21, -1421),
	Tamano = Vector3.new(33, 14, 38),
	Spawn = { Punto = Vector3.new(-42, 17, -1421), Estado = "provisional", Cargos = { "ProfesorTitular" } },
	Asientos = 0,
	PuestoDocente = Vector3.new(-43, 17, -1409),
	Evidencia = {
		"Workspace/Chair_13/14/15_Fondo (sin Seat) (-30..-57, 15, -1413..-1432)",
		"Workspace/Mesa_Profesor (-43,15,-1407)",
	},
	Notas = "",
}
table.insert(MapaLogico.OrdenZonas, "ALTO_O2")
table.insert(MapaLogico.Aulas, "ALTO_O2")
MapaLogico.Zonas["ALTO_O3"] = {
	Id = "ALTO_O3",
	Nombre = "Aula planta alta oeste 3 (con proyector)",
	Tipo = "aula",
	Piso = 1,
	Centro = Vector3.new(-40.5, 21, -1467),
	Tamano = Vector3.new(33, 14, 50),
	Spawn = { Punto = Vector3.new(-42, 17, -1467), Estado = "provisional", Cargos = { "ProfesorTitular" } },
	Asientos = 0,
	Tablero = { Centro = Vector3.new(-40, 19, -1457), Normal = Vector3.new(0, 0, -1) },
	PuestoDocente = Vector3.new(-38, 17, -1462),
	Evidencia = {
		"Workspace/Chair_13/14/15_Fondo (sin Seat) (-29..-49, 15, -1469..-1487)",
		"Workspace/Mesa_Profesor (-38,15,-1464)",
		"Workspace/Projector (-39,23,-1471)",
		"Workspace/Pizarra_DERECHA (-40,19,-1457)",
	},
	Notas = "",
}
table.insert(MapaLogico.OrdenZonas, "ALTO_O3")
table.insert(MapaLogico.Aulas, "ALTO_O3")
MapaLogico.Zonas["7A"] = {
	Id = "7A",
	Nombre = "Aula 7A (planta alta este)",
	Tipo = "aula",
	Piso = 1,
	Centro = Vector3.new(55.5, 21, -1392),
	Tamano = Vector3.new(37, 14, 40),
	Spawn = { Punto = Vector3.new(55, 17, -1392), Estado = "confirmado", Cargos = { "ProfesorTitular" } },
	Asientos = 19,
	PuestoDocente = Vector3.new(38, 17, -1383),
	Puertas = { "07_Puerta_Grade_7A" },
	Evidencia = {
		"Workspace/07_Puerta_Grade_7A con rótulo '7A' (35,18,-1400)",
		"19 Workspace/Pupitre_01..19/Functional_seat (38..71, 16, -1378..-1409)",
		"Workspace/06_Equipamiento/MesaDocenteMetalCrema con monitor (38,16,-1380) y SillaDocenteAzul/Functional_seat (38.3,16,-1383.2)",
		"Workspace/02_CieloRaso (54,24,-1396), 05_Detalles, 03_Ventanas_Izquierda (73,21,-1395)",
	},
	Notas = "Pupitres en L (fila norte y fila este). Sin tablero identificado: usar pantalla del puesto docente.",
}
table.insert(MapaLogico.OrdenZonas, "7A")
table.insert(MapaLogico.Aulas, "7A")
MapaLogico.Zonas["8B"] = {
	Id = "8B",
	Nombre = "Aula 8B (planta alta este)",
	Tipo = "aula",
	Piso = 1,
	Centro = Vector3.new(55.5, 21, -1431),
	Tamano = Vector3.new(37, 14, 34),
	Spawn = { Punto = Vector3.new(50, 17, -1430), Estado = "provisional", Cargos = { "ProfesorTitular" } },
	Asientos = 0,
	Tablero = { Centro = Vector3.new(50, 20, -1415), Normal = Vector3.new(0, 0, -1) },
	PuestoDocente = Vector3.new(59, 17, -1423),
	Puertas = { "Puerta_Blanca_Abierta" },
	Evidencia = {
		"Aviso 'CUIDA TU SALON 8B' Workspace/Carteleras_Fondo/Aviso_Pequeno (68,21,-1417)",
		"Workspace/Tablero_y_Decoracion x2 (48/52, 20, -1414..-1416)",
		"Workspace/Pupitre_02/04/06 (sin Seat) (38/66, 16, -1432..-1438)",
		"Workspace/Mesa_Profesor (59,15,-1421) y Silla_Profesor (59,16,-1418)",
		"Workspace/Puerta_Blanca_Abierta 'Bienvenidos' (38,18,-1419)",
	},
	Notas = "",
}
table.insert(MapaLogico.OrdenZonas, "8B")
table.insert(MapaLogico.Aulas, "8B")
MapaLogico.Zonas["ALTO_E3"] = {
	Id = "ALTO_E3",
	Nombre = "Aula planta alta este 3",
	Tipo = "aula",
	Piso = 1,
	Centro = Vector3.new(55.5, 21, -1471),
	Tamano = Vector3.new(37, 14, 42),
	Spawn = { Punto = Vector3.new(50, 17, -1475), Estado = "provisional", Cargos = { "ProfesorTitular" } },
	Asientos = 0,
	Tablero = { Centro = Vector3.new(49, 19, -1459), Normal = Vector3.new(0, 0, -1) },
	PuestoDocente = Vector3.new(58, 17, -1466),
	Evidencia = {
		"Workspace/Pupitre_01..19 (85 parts, sin Seat) (39..62, 16, -1466..-1489)",
		"Workspace/MesaDocente (58,16,-1464) y Silla_Profesor (57,16,-1461)",
		"Workspace/Model/SuperficiePizarra (49,19,-1459) y ParedPizarra_Frente (59,19,-1459)",
		"Workspace/TechoPanelado (59,25,-1466)",
	},
	Notas = "",
}
table.insert(MapaLogico.OrdenZonas, "ALTO_E3")
table.insert(MapaLogico.Aulas, "ALTO_E3")
MapaLogico.Zonas["PASARELA"] = {
	Id = "PASARELA",
	Nombre = "Pasarela elevada entre bloques",
	Tipo = "circulacion",
	Piso = 1,
	Centro = Vector3.new(7, 19, -1398),
	Tamano = Vector3.new(50, 10, 12),
	Spawn = { Punto = Vector3.new(7, 17, -1398), Estado = "confirmado", Cargos = {  } },
	Asientos = 0,
	Evidencia = {
		"Workspace/PasarelaBarandaRoja (7,15,-1398) 44x4x9",
		"Workspace/Model (87 parts) techo (5,34,-1351) 128x15x24",
	},
	Notas = "",
}
table.insert(MapaLogico.OrdenZonas, "PASARELA")
MapaLogico.Zonas["CANCHA"] = {
	Id = "CANCHA",
	Nombre = "Cancha cubierta",
	Tipo = "cancha",
	Piso = 0,
	Centro = Vector3.new(-2, 6, -1570),
	Tamano = Vector3.new(96, 16, 58),
	Spawn = { Punto = Vector3.new(-2, 3, -1545), Estado = "confirmado", Cargos = {  } },
	Asientos = 0,
	Futbol = {
		Balon = Vector3.new(-2, 4, -1570),
		ArcoA = { Centro = Vector3.new(-47, 3, -1570), Tamano = Vector3.new(3, 7, 12) },
		ArcoB = { Centro = Vector3.new(43, 3, -1570), Tamano = Vector3.new(3, 7, 12) },
		Limites = { Min = Vector3.new(-56, -6, -1606), Max = Vector3.new(52, 45, -1534) },
	},
	Evidencia = {
		"Workspace/Lineas (65 parts) (-2,0,-1570) 92x0x54",
		"Workspace/Arcos (22 parts) (-2,4,-1570) 98x7x12",
		"Cubierta de láminas Workspace/Lamina (109 de ancho) (-1..-2, 23..31, -1568..-1603)",
		"Reja de acceso Workspace/03_Hoja_izquierda_abierta / 04_Hoja_derecha_abierta (17,4,-1522) y Workspace/02_Postes_y_marcos_de_apoyo",
		"Foto 11 anotada 'Cancha'",
	},
	Notas = "Cancha de baloncesto/fútbol de salón según líneas; los volúmenes de arco se dibujan en los extremos del modelo Arcos.",
}
table.insert(MapaLogico.OrdenZonas, "CANCHA")
MapaLogico.Zonas["COCINA"] = {
	Id = "COCINA",
	Nombre = "Cocina (preparación y entrega)",
	Tipo = "cocina",
	Piso = 0,
	Centro = Vector3.new(-13, 6, -1640),
	Tamano = Vector3.new(42, 16, 27),
	Spawn = { Punto = Vector3.new(-12, 3, -1640), Estado = "provisional", Cargos = { "Cocinero" } },
	Asientos = 0,
	Estaciones = { Preparacion = Vector3.new(-21, 3, -1621), Coccion = Vector3.new(-18, 3, -1612), Emplatado = Vector3.new(-8, 3, -1636), Entrega = Vector3.new(-15, 3, -1632), Reposicion = Vector3.new(5, 3, -1645) },
	Mostrador = { Centro = Vector3.new(-15, 3, -1636), Frente = Vector3.new(0, 0, 1) },
	FilaEstudiantes = { Centro = Vector3.new(-13, 6, -1620), Tamano = Vector3.new(26, 12, 14) },
	Evidencia = {
		"Workspace/Model/Piso_naranja_rombos (-1,0,-1639) 14x1x25 y Piso_beige_servicio (-20,0,-1639) 25x1x25",
		"Workspace/Model/Bano_maria_acero_con_vitrina (-15,3,-1636)",
		"Workspace/Model/Ventana_servicio_a_cocina x4 (-20..-10, 6, -1627)",
		"Workspace/Model/Mueble_lavaplatos_madera_oscura (-21,3,-1617), Freidora_de_mesada (-21,4,-1614), Licuadora (-21,5,-1616), Nevera_portatil_roja (-18,1,-1617)",
		"Workspace/Model/Congelador_horizontal_1..3 (8,2..5,-1646..-1649), Cilindro_azul_de_gas_1/2 (8,2,-1620..-1622)",
		"Foto 12 anotada 'hacer comida' / 'dar comida'",
	},
	Notas = "El mostrador (baño maría con vitrina) se atiende desde dentro; los estudiantes reclaman desde las ventanas de servicio (Z≈-1624).",
}
table.insert(MapaLogico.OrdenZonas, "COCINA")
MapaLogico.Zonas["COMEDOR_COCINA"] = {
	Id = "COMEDOR_COCINA",
	Nombre = "Salón de mesas plegables junto a la cocina",
	Tipo = "comedor",
	Piso = 0,
	Centro = Vector3.new(-13, 6, -1664),
	Tamano = Vector3.new(42, 16, 26),
	Spawn = { Punto = Vector3.new(-13, 3, -1664), Estado = "confirmado", Cargos = {  } },
	Asientos = 0,
	Evidencia = {
		"Workspace/Model/Piso_beige_salon (-13,0,-1664) 39x1x26",
		"Workspace/Model/Mesa_plegable_fondo_* x5 (-24..0, 2, -1656..-1668)",
		"Plafon_LED, Ventilador_oscilante, Ventana_lateral_salon",
	},
	Notas = "",
}
table.insert(MapaLogico.OrdenZonas, "COMEDOR_COCINA")
MapaLogico.Zonas["PATIO_COCINA"] = {
	Id = "PATIO_COCINA",
	Nombre = "Patio de la cocina y columpio",
	Tipo = "patio",
	Piso = 0,
	Centro = Vector3.new(32, 6, -1644),
	Tamano = Vector3.new(54, 16, 82),
	Asientos = 0,
	Evidencia = {
		"Workspace/Model/Patio_de_concreto_agrietado (32,0,-1644) 53x1x81",
		"Workspace/Model/Columpio_doble_de_tubo_negro (41,5,-1625)",
		"Workspace/Model/Techo_pabellon_* y Piso_pabellon (53,0,-1658)",
	},
	Notas = "",
}
table.insert(MapaLogico.OrdenZonas, "PATIO_COCINA")
MapaLogico.Puertas = {}
MapaLogico.OrdenPuertas = {}
MapaLogico.Puertas["Puerta_6B"] = { Id = "Puerta_6B", Ruta = "Workspace/Puerta_6B", Hoja = "Hoja_transitable", Centro = Vector3.new(-23, 3, -1445), Zona = "6B", Modo = "estado", CargosBloqueo = { "ProfesorTitular", "CoordinadorAcademico", "Director", "Subdirector" } }
table.insert(MapaLogico.OrdenPuertas, "Puerta_6B")
MapaLogico.Puertas["Puerta_7B"] = { Id = "Puerta_7B", Ruta = "Workspace/Puerta_7B", Hoja = "Hoja_transitable", Centro = Vector3.new(-22, 5, -1453), Zona = "7B", Modo = "estado", CargosBloqueo = { "ProfesorTitular", "CoordinadorAcademico", "Director", "Subdirector" } }
table.insert(MapaLogico.OrdenPuertas, "Puerta_7B")
MapaLogico.Puertas["Puerta_Morada"] = { Id = "Puerta_Morada", Ruta = "Workspace/Puerta_Morada", Hoja = "Hoja_Morada", Centro = Vector3.new(37, 5, -1446), Zona = "AULA_P2", Modo = "estado", CargosBloqueo = { "ProfesorTitular", "CoordinadorAcademico", "Director", "Subdirector" } }
table.insert(MapaLogico.OrdenPuertas, "Puerta_Morada")
MapaLogico.Puertas["Puerta_Blanca_6C"] = { Id = "Puerta_Blanca_6C", Ruta = "Workspace/Puerta_Blanca_6C", Hoja = "Hoja_Blanca", Centro = Vector3.new(39, 5, -1469), Zona = "5", Modo = "estado", CargosBloqueo = { "ProfesorTitular", "CoordinadorAcademico", "Director", "Subdirector" } }
table.insert(MapaLogico.OrdenPuertas, "Puerta_Blanca_6C")
MapaLogico.Puertas["Puerta_7A"] = { Id = "Puerta_7A", Ruta = "Workspace/07_Puerta_Grade_7A", Hoja = nil, Centro = Vector3.new(35, 18, -1400), Zona = "7A", Modo = "estado", CargosBloqueo = { "ProfesorTitular", "CoordinadorAcademico", "Director", "Subdirector" } }
table.insert(MapaLogico.OrdenPuertas, "Puerta_7A")
MapaLogico.Puertas["Puerta_8B"] = { Id = "Puerta_8B", Ruta = "Workspace/Puerta_Blanca_Abierta", Hoja = nil, Centro = Vector3.new(38, 18, -1419), Zona = "8B", Modo = "estado", CargosBloqueo = { "ProfesorTitular", "CoordinadorAcademico", "Director", "Subdirector" } }
table.insert(MapaLogico.OrdenPuertas, "Puerta_8B")
MapaLogico.Puertas["Puerta_Banos2_A"] = { Id = "Puerta_Banos2_A", Ruta = "Workspace/03_Puertas_de_madera/Puerta_GIRLS_secundaria", Hoja = nil, Centro = Vector3.new(-34, 4, -1509), Zona = "BANOS_2", Modo = "privacidad", CargosBloqueo = {  } }
table.insert(MapaLogico.OrdenPuertas, "Puerta_Banos2_A")
MapaLogico.Puertas["Puerta_Banos2_B"] = { Id = "Puerta_Banos2_B", Ruta = "Workspace/03_Puertas_de_madera/Puerta_GIRLS_abierta", Hoja = nil, Centro = Vector3.new(-23, 5, -1507), Zona = "BANOS_2", Modo = "privacidad", CargosBloqueo = {  } }
table.insert(MapaLogico.OrdenPuertas, "Puerta_Banos2_B")
MapaLogico.Puertas["Porton_Principal"] = { Id = "Porton_Principal", Ruta = "Workspace/Porton_Blanco", Hoja = nil, Centro = Vector3.new(-1, 7, -794), Zona = "ENTRADA", Modo = "estado", CargosBloqueo = { "Seguridad", "Recepcionista", "Director", "Subdirector" } }
table.insert(MapaLogico.OrdenPuertas, "Porton_Principal")
MapaLogico.Puertas["Puerta_Aula_05"] = { Id = "Puerta_Aula_05", Ruta = "Workspace/Puerta_Aula_05_Abierta", Hoja = nil, Centro = Vector3.new(-28, 4, -860), Zona = "A05", Modo = "estado", CargosBloqueo = { "ProfesorTitular", "CoordinadorAcademico", "Director", "Subdirector" } }
table.insert(MapaLogico.OrdenPuertas, "Puerta_Aula_05")
MapaLogico.Puertas["Puerta_Aula_04"] = { Id = "Puerta_Aula_04", Ruta = "Workspace/Puerta_Aula_04", Hoja = nil, Centro = Vector3.new(-27, 4, -882), Zona = "A04", Modo = "estado", CargosBloqueo = { "ProfesorTitular", "CoordinadorAcademico", "Director", "Subdirector" } }
table.insert(MapaLogico.OrdenPuertas, "Puerta_Aula_04")
MapaLogico.Puertas["Puerta_Aula_03"] = { Id = "Puerta_Aula_03", Ruta = "Workspace/Puerta_Aula_Abierta", Hoja = nil, Centro = Vector3.new(-28, 4, -905), Zona = "A03", Modo = "estado", CargosBloqueo = { "ProfesorTitular", "CoordinadorAcademico", "Director", "Subdirector" } }
table.insert(MapaLogico.OrdenPuertas, "Puerta_Aula_03")
MapaLogico.Puertas["Puerta_Aula_02"] = { Id = "Puerta_Aula_02", Ruta = "Workspace/Puerta_Infantil", Hoja = nil, Centro = Vector3.new(-27, 4, -926), Zona = "A02", Modo = "estado", CargosBloqueo = { "ProfesorTitular", "CoordinadorAcademico", "Director", "Subdirector" } }
table.insert(MapaLogico.OrdenPuertas, "Puerta_Aula_02")
MapaLogico.Puertas["Puerta_Aula_01"] = { Id = "Puerta_Aula_01", Ruta = "Workspace/Puerta_Arcoiris", Hoja = nil, Centro = Vector3.new(-27, 4, -948), Zona = "A01", Modo = "estado", CargosBloqueo = { "ProfesorTitular", "CoordinadorAcademico", "Director", "Subdirector" } }
table.insert(MapaLogico.OrdenPuertas, "Puerta_Aula_01")
MapaLogico.Puertas["Puerta_Laboratorio"] = { Id = "Puerta_Laboratorio", Ruta = "Workspace/Model/Puerta_Panel_Rojo_Laboratorio", Hoja = nil, Centro = Vector3.new(41, 5, -887), Zona = "LABORATORIO", Modo = "estado", CargosBloqueo = { "ProfesorTitular", "CoordinadorAcademico", "Director", "Subdirector" } }
table.insert(MapaLogico.OrdenPuertas, "Puerta_Laboratorio")
MapaLogico.SpawnOriginal = { Ruta = "Workspace/SpawnLocation", Posicion = Vector3.new(-38.9, -0.4, -1140), Neutral = true }

-- Utilidades mínimas (las completas están en Util/Zones)
function MapaLogico.Zona(id)
	return MapaLogico.Zonas[id]
end

function MapaLogico.ZonasPorTipo(tipo)
	local lista = {}
	for _, id in ipairs(MapaLogico.OrdenZonas) do
		local z = MapaLogico.Zonas[id]
		if z.Tipo == tipo then table.insert(lista, z) end
	end
	return lista
end

return MapaLogico
