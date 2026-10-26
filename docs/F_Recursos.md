# F. Recursos audiovisuales

Regla del prompt maestro: solo se citan ids reales si están verificados. No se ha verificado ningún id de activo externo en esta entrega, por lo que **todos los ids configurables son 0** y el sistema tiene respaldos funcionales sin ellos.

## F.1 Activos propios incluidos en el repositorio

| Archivo | Uso | Cómo activarlo |
|---|---|---|
| `assets/logo_instituto_jean_piaget.png` (308×307, RGBA) | Logo real del colegio en pantalla de carga, menú principal, etiqueta sobre el avatar y tablero del HUD | Subir en Creator Hub como **Decal/Image**, copiar el id numérico y ponerlo en `Config.LogoAssetId`. Mientras sea 0 se dibuja un logo vectorial de respaldo (círculo rojo con "INSTITUTO EDUCATIVO · JEAN PIAGET · EDUCACIÓN INTEGRAL · CAMINO A LA EXCELENCIA"). |
| `mapa/plano_cenital.png`, `mapa/plano_cenital_etiquetado.png` | Referencia de desarrollo (no se usa en juego) | — |

## F.2 Activos del mapa que ya existen (verificados en el `.rbxl`)

| Tipo | Id / ruta | Dónde | Observación |
|---|---|---|---|
| Sonido cisterna | `rbxassetid://141523184` (`Workspace/Bathroom Toilet/Handle/Sound`) | Baños | Se reutiliza desde `BathroomService` (se reproduce el `Sound` existente del inodoro más cercano; no se añade otro) |
| Sonidos de ventilador | `rbxassetid://9111359910`, `4859386655`, `1330849332`, `8758439992` | Comedor, aires | Ya suenan; el ajuste "Sonidos ambientales" los silencia localmente |
| Texturas de puertas de madera | `rbxassetid://9920625290` ×30 | BANOS_2 | Decorativas |
| Imagen en `Workspace/Image Placer/SurfaceGui/ImageLabel` | `rbxassetid://136745334226894` | Patio central | Decorativa (no verificada su licencia; no se reutiliza) |
| Mural de banderas | `rbxassetid://84838307163353` (`Workspace/Model/Flag Changing image part/Decal`) | Fachada norte del bloque de dos plantas | Decorativa |
| Mallas de árboles | `rbxassetid://5547037928`, `5547037961` + `SurfaceAppearance` PBR | 9 árboles | Decoración pesada (modo bajos recursos la atenúa a distancia) |
| Sillas y computadores | `rbxassetid://2638248116` (silla roja), `839922430`/`839921888` (monitor), `5825248425`/`5825248462` (teclado), `475137829`/`474411435` (torre) | Comedor, robótica, informática | Se reutilizan como pantallas y asientos |
| Skybox | `rbxassetid://6444884337` (y `144933338` en un segundo `Sky`) | Lighting | Hay **dos** `Sky` en Lighting: Roblox usa uno; conviene eliminar el sobrante manualmente (no lo hace el sistema) |

## F.3 Sonidos configurables (ids = 0 por defecto)

`Config.Sonidos`: `Timbre`, `ClickUI`, `Puerta`, `Gol`, `Notificacion`. Mientras sean 0: silencio y subtítulo en pantalla ("🔔 Timbre: inicio de clase"). Para activarlos, buscar sonidos con licencia en el catálogo de audio de Creator Hub (Marketplace → Audio, filtrar por "Free to use") y pegar el id. El sistema los precarga en la pantalla de carga solo si son > 0.

## F.4 Fuentes y UI

- Fuentes de Roblox (sin licencias externas): `GothamBold` (títulos), `Gotham` (texto), `Code` (editor de programación).
- Iconos: texto y formas (`Frame` + `UICorner` + `UIStroke`); sin imágenes externas.
- Colores institucionales (del logo): rojo `(196, 30, 36)`, rojo oscuro `(150, 22, 28)`, blanco `(245, 245, 245)`, amarillo `(246, 196, 34)`, azul `(31, 78, 160)`.

## F.5 Pendientes reservados para el usuario (requisito 19)

1. Id del logo y, si existen, escudos/emblemas por cargo (hoy se usa la abreviatura del cargo sobre el avatar).
2. Uniformes (camisa/pantalón) por equipo (`Catalogs.Uniformes`).
3. Ids de sonidos con licencia.
4. Integrantes de Horizon Studios (`Catalogs.Equipo`) y texto de "Actualizaciones" futuras (`Catalogs.Changelog`).
5. Confirmar nombres oficiales de las aulas sin placa (A06, AULA_E1, AULA_P1, AULA_P2, ALTO_O1..O3, ALTO_E3) en `mapa/zonas.json` → regenerar `MapaLogico` con `python3 tools/gen_mapa_logico.py`.
