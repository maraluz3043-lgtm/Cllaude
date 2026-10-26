#!/usr/bin/env python3
"""Lector del formato binario de Roblox (.rbxl / .rbxm) suficiente para auditar un lugar.

Uso:  python3 tools/rbxl_lector.py <archivo.rbxl> <salida.json>

Produce un JSON con la lista de instancias: id, clase, nombre, padre y propiedades
relevantes (Position/Size/CFrame de BaseParts, Source de scripts, textos de GUIs, etc.).
"""
import sys, os, struct, json, math
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "pylibs"))  # dependencias locales opcionales
import zstandard

ROTATION_IDS = {
    0x02: (1,0,0, 0,1,0, 0,0,1),
    0x03: (1,0,0, 0,0,-1, 0,1,0),
    0x05: (1,0,0, 0,-1,0, 0,0,-1),
    0x06: (1,0,0, 0,0,1, 0,-1,0),
    0x07: (0,1,0, 1,0,0, 0,0,-1),
    0x09: (0,0,1, 1,0,0, 0,1,0),
    0x0a: (0,-1,0, 1,0,0, 0,0,1),
    0x0c: (0,0,-1, 1,0,0, 0,-1,0),
    0x0d: (0,1,0, 0,0,1, 1,0,0),
    0x0e: (0,0,-1, 0,1,0, 1,0,0),
    0x10: (0,-1,0, 0,0,-1, 1,0,0),
    0x11: (0,0,1, 0,-1,0, 1,0,0),
    0x14: (-1,0,0, 0,1,0, 0,0,-1),
    0x15: (-1,0,0, 0,0,1, 0,1,0),
    0x17: (-1,0,0, 0,-1,0, 0,0,1),
    0x18: (-1,0,0, 0,0,-1, 0,-1,0),
    0x19: (0,1,0, -1,0,0, 0,0,1),
    0x1b: (0,0,-1, -1,0,0, 0,1,0),
    0x1c: (0,-1,0, -1,0,0, 0,0,-1),
    0x1e: (0,0,1, -1,0,0, 0,-1,0),
    0x1f: (0,1,0, 0,0,-1, -1,0,0),
    0x20: (0,0,1, 0,1,0, -1,0,0),
    0x22: (0,-1,0, 0,0,1, -1,0,0),
    0x23: (0,0,-1, 0,-1,0, -1,0,0),
}

class Reader:
    def __init__(self, data):
        self.d = data; self.o = 0
    def u8(self):
        v = self.d[self.o]; self.o += 1; return v
    def u16(self):
        v = struct.unpack_from('<H', self.d, self.o)[0]; self.o += 2; return v
    def i16(self):
        v = struct.unpack_from('<h', self.d, self.o)[0]; self.o += 2; return v
    def u32(self):
        v = struct.unpack_from('<I', self.d, self.o)[0]; self.o += 4; return v
    def i32(self):
        v = struct.unpack_from('<i', self.d, self.o)[0]; self.o += 4; return v
    def f32(self):
        v = struct.unpack_from('<f', self.d, self.o)[0]; self.o += 4; return v
    def f64(self):
        v = struct.unpack_from('<d', self.d, self.o)[0]; self.o += 8; return v
    def bytes(self, n):
        v = self.d[self.o:self.o+n]; self.o += n; return v
    def string(self):
        n = self.u32(); return self.bytes(n).decode('utf-8', 'replace')
    def remaining(self):
        return len(self.d) - self.o
    # arrays entrelazados
    def interleaved_u32(self, n):
        raw = self.bytes(4*n)
        out = []
        for i in range(n):
            out.append((raw[i] << 24) | (raw[n+i] << 16) | (raw[2*n+i] << 8) | raw[3*n+i])
        return out
    def interleaved_i32(self, n):
        return [((u >> 1) ^ -(u & 1)) for u in self.interleaved_u32(n)]
    def interleaved_f32(self, n):
        out = []
        for u in self.interleaved_u32(n):
            b = ((u >> 1) | ((u & 1) << 31)) & 0xFFFFFFFF
            out.append(struct.unpack('<f', struct.pack('<I', b))[0])
        return out
    def referents(self, n):
        vals = self.interleaved_i32(n)
        acc = 0; out = []
        for v in vals:
            acc += v; out.append(acc)
        return out
    def interleaved_i64(self, n):
        raw = self.bytes(8*n)
        out = []
        for i in range(n):
            u = 0
            for b in range(8):
                u = (u << 8) | raw[b*n + i]
            out.append((u >> 1) ^ -(u & 1))
        return out

def read_chunks(data):
    assert data[:8] == b'<roblox!'
    off = 32
    chunks = []
    dctx = zstandard.ZstdDecompressor()
    while off + 16 <= len(data):
        name = data[off:off+4]
        clen, ulen, _res = struct.unpack_from('<iii', data, off+4)
        off += 16
        if clen == 0:
            body = data[off:off+ulen]; off += ulen
        else:
            comp = data[off:off+clen]; off += clen
            if comp[:4] == b'\x28\xb5\x2f\xfd':
                body = dctx.decompress(comp, max_output_size=ulen)
            else:
                import lz4.block  # noqa
                body = lz4.block.decompress(comp, uncompressed_size=ulen)
        chunks.append((name.rstrip(b'\x00').decode(), body))
        if name == b'END\x00':
            break
    return chunks

def parse(path):
    data = open(path, 'rb').read()
    chunks = read_chunks(data)
    classes = {}      # classId -> {name, referents, service}
    instances = {}    # referent -> dict
    shared = []
    meta = {}
    skipped_types = {}
    for name, body in chunks:
        r = Reader(body)
        if name == 'META':
            n = r.u32()
            for _ in range(n):
                k = r.string(); v = r.string(); meta[k] = v
        elif name == 'SSTR':
            r.u32(); n = r.u32()
            for _ in range(n):
                r.bytes(16); shared.append(r.string())
        elif name == 'INST':
            cid = r.u32(); cname = r.string(); fmt = r.u8(); n = r.u32()
            refs = r.referents(n)
            classes[cid] = {'name': cname, 'refs': refs, 'service': fmt == 1}
            for ref in refs:
                instances[ref] = {'id': ref, 'class': cname, 'props': {}, 'parent': None, 'children': []}
        elif name == 'PROP':
            cid = r.u32(); pname = r.string(); t = r.u8()
            cls = classes[cid]; refs = cls['refs']; n = len(refs)
            vals = None
            try:
                if t == 0x01:
                    vals = [r.string() for _ in range(n)]
                elif t == 0x02:
                    vals = [bool(r.u8()) for _ in range(n)]
                elif t == 0x03:
                    vals = r.interleaved_i32(n)
                elif t == 0x04:
                    vals = r.interleaved_f32(n)
                elif t == 0x05:
                    vals = [r.f64() for _ in range(n)]
                elif t == 0x06:
                    s = r.interleaved_f32(n); o = r.interleaved_i32(n)
                    vals = [(s[i], o[i]) for i in range(n)]
                elif t == 0x07:
                    sx = r.interleaved_f32(n); sy = r.interleaved_f32(n); ox = r.interleaved_i32(n); oy = r.interleaved_i32(n)
                    vals = [((sx[i], ox[i]), (sy[i], oy[i])) for i in range(n)]
                elif t == 0x08:
                    vals = [[r.f32() for _ in range(6)] for _ in range(n)]
                elif t in (0x09, 0x0A):
                    vals = [r.u8() for _ in range(n)]
                elif t == 0x0B:
                    vals = r.interleaved_u32(n)
                elif t == 0x0C:
                    a = r.interleaved_f32(n); b = r.interleaved_f32(n); c = r.interleaved_f32(n)
                    vals = [(a[i], b[i], c[i]) for i in range(n)]
                elif t == 0x0D:
                    a = r.interleaved_f32(n); b = r.interleaved_f32(n)
                    vals = [(a[i], b[i]) for i in range(n)]
                elif t == 0x0E:
                    a = r.interleaved_f32(n); b = r.interleaved_f32(n); c = r.interleaved_f32(n)
                    vals = [(a[i], b[i], c[i]) for i in range(n)]
                elif t == 0x10:
                    rots = []
                    for _ in range(n):
                        rid = r.u8()
                        if rid == 0:
                            rots.append(tuple(r.f32() for _ in range(9)))
                        else:
                            rots.append(ROTATION_IDS.get(rid, (1,0,0,0,1,0,0,0,1)))
                    a = r.interleaved_f32(n); b = r.interleaved_f32(n); c = r.interleaved_f32(n)
                    vals = [{'pos': (a[i], b[i], c[i]), 'rot': rots[i]} for i in range(n)]
                elif t == 0x12:
                    vals = r.interleaved_u32(n)
                elif t == 0x13:
                    vals = r.referents(n)
                elif t == 0x14:
                    vals = [(r.i16(), r.i16(), r.i16()) for _ in range(n)]
                elif t == 0x15:
                    vals = []
                    for _ in range(n):
                        k = r.u32(); vals.append([(r.f32(), r.f32(), r.f32()) for _ in range(k)])
                elif t == 0x16:
                    vals = []
                    for _ in range(n):
                        k = r.u32(); vals.append([(r.f32(), r.f32(), r.f32(), r.f32(), r.f32()) for _ in range(k)])
                elif t == 0x17:
                    vals = [(r.f32(), r.f32()) for _ in range(n)]
                elif t == 0x18:
                    a = r.interleaved_f32(n); b = r.interleaved_f32(n); c = r.interleaved_f32(n); d = r.interleaved_f32(n)
                    vals = [((a[i], b[i]), (c[i], d[i])) for i in range(n)]
                elif t == 0x19:
                    vals = []
                    for _ in range(n):
                        custom = r.u8()
                        if custom:
                            vals.append(tuple(r.f32() for _ in range(5)))
                        else:
                            vals.append(None)
                elif t == 0x1A:
                    a = r.bytes(n); b = r.bytes(n); c = r.bytes(n)
                    vals = [(a[i], b[i], c[i]) for i in range(n)]
                elif t == 0x1B:
                    vals = r.interleaved_i64(n)
                elif t == 0x1C:
                    idx = r.interleaved_u32(n)
                    vals = [shared[i] if i < len(shared) else None for i in idx]
                elif t == 0x1D:
                    vals = [r.string() for _ in range(n)]
                elif t == 0x1E:
                    r.u8()
                    rots = []
                    for _ in range(n):
                        rid = r.u8()
                        if rid == 0:
                            rots.append(tuple(r.f32() for _ in range(9)))
                        else:
                            rots.append(ROTATION_IDS.get(rid, (1,0,0,0,1,0,0,0,1)))
                    a = r.interleaved_f32(n); b = r.interleaved_f32(n); c = r.interleaved_f32(n)
                    r.u8()
                    flags = [bool(r.u8()) for _ in range(n)]
                    vals = [({'pos': (a[i], b[i], c[i]), 'rot': rots[i]} if flags[i] else None) for i in range(n)]
                elif t == 0x1F:
                    r.bytes(16*n); vals = None
                elif t == 0x20:
                    vals = []
                    for _ in range(n):
                        fam = r.string(); w = r.u16(); st = r.u8(); cached = r.string()
                        vals.append((fam, w, st))
                elif t == 0x21:
                    r.bytes(8*n); vals = None
                elif t == 0x22:
                    # Content: tipos de fuente entrelazados, luego uris, luego referentes
                    types = r.interleaved_u32(n)
                    nuri = r.u32(); uris = [r.string() for _ in range(nuri)]
                    nobj = r.u32(); objs = r.referents(nobj) if nobj else []
                    vals = []; ui = 0; oi = 0
                    for tp in types:
                        if tp == 1:
                            vals.append(uris[ui] if ui < len(uris) else None); ui += 1
                        elif tp == 2:
                            vals.append(('ref', objs[oi] if oi < len(objs) else None)); oi += 1
                        else:
                            vals.append(None)
                else:
                    skipped_types[t] = skipped_types.get(t, 0) + 1
                    vals = None
            except Exception as e:  # tolerante: una propiedad mal leída no detiene la auditoría
                skipped_types[(t, pname)] = str(e)
                vals = None
            if vals is not None:
                for i, ref in enumerate(refs):
                    instances[ref]['props'][pname] = vals[i]
        elif name == 'PRNT':
            r.u8(); n = r.u32()
            ch = r.referents(n); pa = r.referents(n)
            for c, p in zip(ch, pa):
                if c in instances:
                    instances[c]['parent'] = p if p in instances else None
                    if p in instances:
                        instances[p]['children'].append(c)
    return meta, instances, skipped_types

def main():
    src, dst = sys.argv[1], sys.argv[2]
    meta, inst, skipped = parse(src)
    out = {'meta': meta, 'skipped': {str(k): v for k, v in skipped.items()}, 'instances': []}
    for ref, it in inst.items():
        props = {}
        for k, v in it['props'].items():
            props[k] = v
        out['instances'].append({'id': ref, 'class': it['class'], 'parent': it['parent'], 'props': props})
    with open(dst, 'w') as f:
        json.dump(out, f, ensure_ascii=False, default=lambda o: list(o) if isinstance(o, (bytes, bytearray)) else str(o))
    print('instancias:', len(inst), ' propiedades omitidas:', skipped)

if __name__ == '__main__':
    main()
