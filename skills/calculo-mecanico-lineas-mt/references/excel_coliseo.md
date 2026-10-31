# Excel "Calculos Mecanicos M.T. - COLISEO DEL NORTE" (provisional) — mapa y observaciones

Flujo de hojas: Ingreso (apoyos, coordenadas, conductor, poste, trafos, terreno) → Car Apoyo (vanos, ángulos,
alturas, tensión, gravivano con catenaria y chequeo "Ahorc") → Mecanicos (cantones, vano regulador k·√(Σa³/Σa),
tabla de regulación) → Reg Vano (flechas por vano) → Eolovanos → Esf M.T. (esfuerzos vs rotura del poste, CS)
→ Tip Apoyo → Ciment → Retenidas.

Diferencias frente al Proyecto Tipo:
- Hipótesis del Excel: 10 °C+V, −5 °C, CHS 10 °C, EDS 20 °C, 20 °C+V, 50 °C, 75 °C; solo conductores 477, 266, 4/0 y 1/0.
- `Mecanicos1` contiene tensiones y flechas precalculadas (valores, no fórmulas) por vano entero; el resto del libro interpola linealmente.
- Esfuerzos: desequilibrio 8 % en alineación (AL/AG) y 100 % en FL; el Proyecto Tipo usa desequilibrio real/50 %, rotura de conductor, torsión y factores 2,5/1,5/1,2.
- Retenidas: tensión = esfuerzo/sen 30°; el Proyecto Tipo usa los coeficientes A, B, C y el pretensionado.
- Higiene: #N/A en filas vacías, celdas con valores fijos dentro de columnas de fórmulas (p. ej. Esf M.T. J7 y L7, Mecanicos D7),
  mezcla de Kg y daN con factor 1,02, hoja `Car Apoyo IMP` duplicada, título heredado "LOTES GERMAN CUESTA" en Ciment.
- Empotramiento: el Excel usa Le = 10 % L + 0,5 m (`Tip Apoyo`); la ficha Afinia ES.03396.TR indica H/10 + 0,6 m.
- `Esf M.T.!AC` marca «R» a todo FL sin comparar contra el poste (causa de que siempre pida retenida).
- Proyecto COLISEO DEL NORTE: área rural (Cartagena).
