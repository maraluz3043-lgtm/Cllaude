"""gui_preview.py — rasteriza una SurfaceGui (Frames / TextLabels / UICorner) de un Ctx a PNG.

Sirve para REVISAR diseños planos (afiches, carátulas, carteleras) que render_ctx no muestra
(render_ctx sólo dibuja las cajas de las parts). Aproxima el comportamiento de Roblox:
  * Position/Size UDim2 (escala + offset) relativos al lienzo = cara de la part * PixelsPerStud.
  * Rotation en grados, sentido horario, alrededor del centro del elemento.
  * UICorner (radio en escala/offset) → esquinas redondeadas (escala 1 = círculo/elipse).
  * TextScaled: ajusta el tamaño de fuente al cuadro (con salto de línea por palabras).
  * Orden de dibujo: ZIndex ascendente y, a igual ZIndex, orden de creación.
Uso:  from gui_preview import render_gui;  render_gui(ctx, gui_idx, '../out/x.png', scale=1.0)
"""
import math
from PIL import Image, ImageDraw, ImageFont

_FONT = '/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf'


def _font(sz):
    try:
        return ImageFont.truetype(_FONT, max(6, int(sz)))
    except Exception:
        return ImageFont.load_default(size=max(6, int(sz)))


def _udim2(val, W, H):
    xs, xo, ys, yo = val
    return xs * W + xo, ys * H + yo


def _rgb(c):
    return tuple(int(round(x * 255)) for x in c)


def _wrap(text, font, maxw, dr):
    out = []
    for para in text.split('\n'):
        words = para.split(' ')
        line = ''
        for w in words:
            cand = (line + ' ' + w).strip()
            if dr.textlength(cand, font=font) <= maxw or not line:
                line = cand
            else:
                out.append(line)
                line = w
        out.append(line)
    return out


def _draw_text(layer, text, w, h, color, scaled, text_size, xalign, yalign, stroke):
    dr = ImageDraw.Draw(layer)
    if scaled:
        sz = max(6, int(h))
        while sz > 6:
            f = _font(sz)
            lines = _wrap(text, f, w, dr)
            lh = sz * 1.15
            if len(lines) * lh <= h and all(dr.textlength(l, font=f) <= w for l in lines):
                break
            sz -= max(1, sz // 12)
    else:
        sz = text_size
        f = _font(sz)
        lines = _wrap(text, f, w, dr)
        lh = sz * 1.15
    f = _font(sz)
    total = len(lines) * lh
    y0 = {0: 0.0, 1: (h - total) / 2, 2: h - total}.get(yalign, (h - total) / 2)
    for i, l in enumerate(lines):
        tw = dr.textlength(l, font=f)
        x0 = {0: 0.0, 1: w - tw, 2: (w - tw) / 2}.get(xalign, (w - tw) / 2)
        y = y0 + i * lh
        if stroke is not None:
            dr.text((x0, y), l, font=f, fill=color, stroke_width=max(1, int(sz / 12)), stroke_fill=stroke)
        else:
            dr.text((x0, y), l, font=f, fill=color)


def render_gui(ctx, gui_idx, out, scale=1.0, bg=(70, 70, 80)):
    gui = ctx.insts[gui_idx]
    part = ctx.insts[gui['parent']]
    size = part['props']['size'][1]
    face = gui['props']['Face'][1]
    pps = gui['props']['PixelsPerStud'][1]
    if face in (0, 3):
        fw, fh = size[2], size[1]
    elif face in (1, 4):
        fw, fh = size[0], size[2]
    else:
        fw, fh = size[0], size[1]
    W, H = max(1, int(fw * pps * scale)), max(1, int(fh * pps * scale))
    img = Image.new('RGBA', (W, H), tuple(bg) + (255,))
    kids = {}
    for i, inst in enumerate(ctx.insts):
        kids.setdefault(inst['parent'], []).append(i)
    # aplanar: (zindex, orden, idx, x, y, w, h) con posiciones absolutas (los hijos se colocan dentro del padre)
    items = []
    order = [0]

    def walk(parent_idx, ox, oy, pw, ph):
        for c in kids.get(parent_idx, []):
            inst = ctx.insts[c]
            if inst['cls'] not in ('Frame', 'TextLabel'):
                continue
            p = inst['props']
            # los offsets son píxeles del lienzo Roblox: escalarlos
            xs, xo, ys, yo = p['Position'][1]
            x = xs * pw + xo * scale; y = ys * ph + yo * scale
            xs, xo, ys, yo = p['Size'][1]
            w = xs * pw + xo * scale; h = ys * ph + yo * scale
            items.append((p.get('ZIndex', (0, 1))[1], order[0], c, ox + x, oy + y, w, h))
            order[0] += 1
            walk(c, ox + x, oy + y, w, h)

    walk(gui_idx, 0.0, 0.0, W, H)
    items.sort(key=lambda t: (t[0], t[1]))
    for z, _, c, x, y, w, h in items:
        inst = ctx.insts[c]; p = inst['props']
        if w <= 0 or h <= 0:
            continue
        wi, hi = max(1, int(round(w))), max(1, int(round(h)))
        layer = Image.new('RGBA', (wi, hi), (0, 0, 0, 0))
        dr = ImageDraw.Draw(layer)
        bt = p.get('BackgroundTransparency', (0, 0.0))[1]
        bc = _rgb(p['BackgroundColor3'][1]) + (int(round(255 * (1 - bt))),)
        corner = None
        for cc in kids.get(c, []):
            if ctx.insts[cc]['cls'] == 'UICorner':
                cs, co = ctx.insts[cc]['props']['CornerRadius'][1]
                corner = cs * min(wi, hi) + co * scale
        if bt < 1.0:
            if corner is not None and corner > 0:
                dr.rounded_rectangle([0, 0, wi - 1, hi - 1], radius=min(corner, min(wi, hi) / 2), fill=bc)
            else:
                dr.rectangle([0, 0, wi - 1, hi - 1], fill=bc)
        if inst['cls'] == 'TextLabel':
            txt = p['Text'][1].decode('utf-8', 'replace')
            col = _rgb(p['TextColor3'][1])
            stroke = _rgb(p['TextStrokeColor3'][1]) if 'TextStrokeColor3' in p else None
            _draw_text(layer, txt, wi, hi, col, p.get('TextScaled', (0, True))[1], p.get('TextSize', (0, 24))[1] * scale,
                       p.get('TextXAlignment', (0, 2))[1], p.get('TextYAlignment', (0, 1))[1], stroke)
        rot = p.get('Rotation', (0, 0.0))[1]
        cx, cy = x + w / 2, y + h / 2
        if abs(rot) > 1e-6:
            layer = layer.rotate(-rot, expand=True, resample=Image.BICUBIC)   # PIL: antihorario; Roblox: horario
        img.alpha_composite(layer, (int(round(cx - layer.width / 2)), int(round(cy - layer.height / 2))))
    img.convert('RGB').save(out)
    return W, H


def render_guis_grid(ctx, gui_idxs, out, scale=1.0, cols=4, gap=12, bg=(20, 20, 24)):
    """Varias SurfaceGui en una sola imagen (mosaico)."""
    import os, tempfile
    ims = []
    for g in gui_idxs:
        tmp = os.path.join(tempfile.gettempdir(), f'_gui_{g}.png')
        render_gui(ctx, g, tmp, scale=scale)
        ims.append(Image.open(tmp).convert('RGB'))
    cols = max(1, min(cols, len(ims)))
    rows = (len(ims) + cols - 1) // cols
    cw = [0] * cols; rh = [0] * rows
    for k, im in enumerate(ims):
        cw[k % cols] = max(cw[k % cols], im.width); rh[k // cols] = max(rh[k // cols], im.height)
    Wt = sum(cw) + gap * (cols + 1); Ht = sum(rh) + gap * (rows + 1)
    big = Image.new('RGB', (Wt, Ht), bg)
    for k, im in enumerate(ims):
        r, c = k // cols, k % cols
        x = gap + sum(cw[:c]) + gap * c; y = gap + sum(rh[:r]) + gap * r
        big.paste(im, (x, y))
    big.save(out)
    return big.size
