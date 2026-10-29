# Matriz de observaciones — Ronda 5 (oficio Afinia 20/10/2026)

Expediente **P22302026090028** · Carga **225 kVA** · Devolución del proyecto específico.
Oficio: `oficio_afinia_2026-10-20.pdf` · Diagrama de conexión: `../../referencias/diagrama_punto_conexion_P22302026090028.pdf`

Estado: `Pendiente` · `Decisión` (requiere definir diseño antes) · `Documental` · `Cálculo`

## Decisiones previas (condicionan varios ítems)

| Decisión | Afecta ítems |
|---|---|
| D1. Cómo cumplir "carga > 200 kVA → circuito trifásico": MT trifásica con los 4 CT monofásicos repartidos entre fases, o banco/transformador trifásico (secundario 208/120 V) | 7, 10, 15, 16, 13, 14, 8 |
| D2. Medida en **nivel 2 (13,2 kV)** en el punto de conexión (predio privado): equipo, TC/TP, caja y ubicación | 5, 8, 14, 1.4, 10.1 |
| D3. Proyecto reportado como **construido y energizado sin autorización** (diagrama de conexión) y sin acceso al predio en la visita: estrategia con el cliente | 11, 6.5, riesgo de sanción |

## Observaciones numeradas

| # | Observación de Afinia | Acción | Tipo | Estado |
|---|---|---|---|---|
| 1 | Memoria con expediente P22302025020027; punto de conexión con P22302026090028 | Cambiar expediente en memoria, planos, rótulos y anexos | Documental | Pendiente |
| 2 | Memoria 1.1.4.3 dice "2250 kVA" | Corregir a **225 kVA** (75 + 3×50). Revisar que coincida en todo el documento | Documental | Pendiente |
| 3 | Plano sin georreferenciar | Coordenadas MAGNA-SIRGAS (el punto C del diagrama es 10.2256, -75.4427) | Plano | Pendiente |
| 4 | Perfil y tipo de vías | Perfil transversal por vía, tipo de vía en planta y distancias de seguridad de apoyos (Ley 1228/2008) | Plano / cálculo | Pendiente |
| 5 | Predio privado: medida en nivel 2 en el punto de conexión | Medida en MT con TC/TP en el punto de conexión (CREG 038/2014) | Decisión D2 | Pendiente |
| 6 | Cantidad de cajas y de acometidas por caja | Tabla de cajas de medidores y acometidas por caja | Documental | Pendiente |
| 7 | Carga > 200 kVA: circuito trifásico | Rediseño según D1 | Decisión D1 | Pendiente |
| 8 | Unifilar completo desde el punto de conexión, con protecciones y medidas | Nuevo unifilar desde el apoyo 13891531 | Plano | Pendiente |
| 9 | Punto de conexión con los datos del operador | Apoyo **13891531**, tramo **21880847**, 123.3 AAAC 3F, circuito TERNERA 13, 13 200 V. Icc: 0,839 kA (3F) / 0,437 kA (1F) | Documental | Pendiente |
| 10 | Falta información técnica de transformadores | Completar tablas (tensiones, tipo, grupo, T aceite/devanados, BIL, Uz) de CT1 (75 kVA) y CT2–4 (50 kVA) con ficha del fabricante | Documental | Pendiente |
| 11 | Estudio de resistividad sin registro de campo | Tablas Wenner, datos reales y fotos de la medición. Ver D3 | Campo / cálculo | Pendiente |
| 12 | PAT calculada al límite normativo | Rediseñar con margen (más electrodos / malla / mejora del suelo) | Cálculo | Pendiente |
| 13 | Tensiones de paso y contacto incompletas | Cálculo definitivo con tiempo de despeje real (de la coordinación de protecciones) según RETIE | Cálculo | Pendiente |
| 14 | Coordinación de protecciones sin curvas TCC | Curvas TCC, selectividad y coordinación de fusibles con los datos de cortocircuito del operador | Cálculo | Pendiente |
| 15 | Corriente nominal de 50 kVA: valores distintos | Memoria usa **5,7 A** (selección de fusible) y **3,79 A** (50/13,2). 5,7 A corresponde al de 75 kVA. Corregir y **verificar que el fusible 3 A no queda por debajo de la nominal** | Cálculo | Pendiente |
| 16 | Tensión secundaria inconsistente | Memoria mezcla 208 V (VLL) y 240/120 V. Unificar según D1 | Documental | Pendiente |
| 17 | Firma de planos: la hoja de ubicación trae otro nombre | Rótulo TOP-1 con "Tony Gonzales Soto M.P. 01-18341"; unificar proyectista (Efraím Guerra, BL205-45418), firma y revisor | Plano | Pendiente |
| 18 | Errores de texto en memoria y planos | Revisión ortográfica y de consistencia completa | Documental | Pendiente |
| 19 | Estructuras "NC" en distancias de seguridad | Aclarar y corregir en cálculos mecánicos | Cálculo | Pendiente |
| 20 | Nemotecnia según norma Afinia | Renombrar apoyos, CT, tableros y circuitos | Plano | Pendiente |

## Ítems "NO CUMPLE" de la lista de chequeo que no aparecen en los 20 numerados

| Ítem | Qué pide | Observación relacionada |
|---|---|---|
| 1.2 | Planos completos y en **formato DWG** | Entregar DWG |
| 1.4 | Planos de gabinetes y tablas de medidas completas | 5, 6 |
| 1.5 | Plano constructivo | Nuevo |
| 1.7 | Correlación con el estudio de factibilidad | 1, 9, 7 |
| 2.2 | Cálculo de pérdidas (armónicos y factor de potencia) | Nuevo |
| 2.4 | Cortacircuitos o seccionadores en el punto de conexión | 8, 14 |
| 5.3 | Distancias de seguridad en subestaciones | 4, 19 |
| 6.3 | Cortocircuito, **arco eléctrico** y falla a tierra | 13, 14 (arco eléctrico no se menciona en los 20) |
| 6.5 | Evidencias fotográficas | 11 |
| 10.1 | Medición en el punto de medida (CREG 038/2014) | 5 |

Cumple: 2.1, 2.3, 3.1–3.3, 4.1, 4.2, 6.2, 7.1–7.3, 9.1. No aplica: 4.3, 5.4, 5.5, 7.4, 7.5, 8, 10.2, 11.

## Datos del punto de conexión (diagrama de Afinia, 9/09/2026)

| Dato | Valor |
|---|---|
| Subestación / circuito | TERNERA / TERNERA 13, 13 200 V |
| Apoyo existente | N° COD 13891531 · tramo 21880847 · 123.3 AAAC (3F), propiedad de Afinia |
| Coordenadas | 10.2256, -75.4427 |
| Cortocircuito trifásico | Scc 20,056 MVA · Icc 0,839 kA · R 5,897 Ω · X 8,621 Ω |
| Cortocircuito monofásico | Scc 3,483 MVA · Icc 0,437 kA · R0 9,392 Ω · X0 39,048 Ω |
| Vigencia factibilidad | 365 días desde 9/09/2026 (revalidar un mes antes) |
| Otras exigencias del diagrama | Cálculo mecánico del apoyo existente; permiso de planeación municipal para hincado; certificación plena RETIE; certificado de producto de cada material; metodología de ejecución en memorias |
