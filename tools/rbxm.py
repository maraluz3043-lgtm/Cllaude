"""Minimal Roblox binary model (.rbxm) reader/writer.

Instances: dict(ref, cls, props{name: (typeid, value)}, parent, children[])
"""
import struct, sys, json, math
import lz4.block

MAGIC = b"<roblox!\x89\xff\x0d\x0a\x1a\x0a"

NORMALS = [(1,0,0),(0,1,0),(0,0,1),(-1,0,0),(0,-1,0),(0,0,-1)]

def rot_from_id(rid):
    i = rid - 1
    X = NORMALS[i // 6]; Y = NORMALS[i % 6]
    Z = (X[1]*Y[2]-X[2]*Y[1], X[2]*Y[0]-X[0]*Y[2], X[0]*Y[1]-X[1]*Y[0])
    return (X[0],Y[0],Z[0], X[1],Y[1],Z[1], X[2],Y[2],Z[2])

# ---------------- reading helpers ----------------
class R:
    def __init__(self, data):
        self.d = data; self.p = 0
    def u8(self):
        v = self.d[self.p]; self.p += 1; return v
    def u16(self):
        v = struct.unpack_from('<H', self.d, self.p)[0]; self.p += 2; return v
    def u32(self):
        v = struct.unpack_from('<I', self.d, self.p)[0]; self.p += 4; return v
    def i32(self):
        v = struct.unpack_from('<i', self.d, self.p)[0]; self.p += 4; return v
    def f32(self):
        v = struct.unpack_from('<f', self.d, self.p)[0]; self.p += 4; return v
    def f64(self):
        v = struct.unpack_from('<d', self.d, self.p)[0]; self.p += 8; return v
    def bytes(self, n):
        v = self.d[self.p:self.p+n]; self.p += n; return v
    def string(self):
        n = self.u32(); return self.bytes(n).decode('utf-8', 'replace')
    def rawstring(self):
        n = self.u32(); return self.bytes(n)
    def interleaved_u32(self, n):
        raw = self.bytes(4*n)
        out = []
        for i in range(n):
            out.append((raw[i] << 24) | (raw[n+i] << 16) | (raw[2*n+i] << 8) | raw[3*n+i])
        return out
    def interleaved_i32(self, n):  # zigzag
        return [((v >> 1) ^ -(v & 1)) for v in self.interleaved_u32(n)]
    def interleaved_f32(self, n):
        out = []
        for v in self.interleaved_u32(n):
            bits = ((v >> 1) | ((v & 1) << 31)) & 0xFFFFFFFF
            out.append(struct.unpack('<f', struct.pack('<I', bits))[0])
        return out
    def interleaved_u64(self, n):
        raw = self.bytes(8*n)
        out = []
        for i in range(n):
            v = 0
            for b in range(8):
                v = (v << 8) | raw[b*n + i]
            out.append(v)
        return out
    def interleaved_i64(self, n):
        return [((v >> 1) ^ -(v & 1)) for v in self.interleaved_u64(n)]
    def referents(self, n):
        vals = self.interleaved_i32(n)
        acc = 0; out = []
        for v in vals:
            acc += v; out.append(acc)
        return out

def read_values(r, tid, n):
    """Return list of n python values for type id."""
    if tid == 0x01 or tid == 0x1D:
        return [r.rawstring() for _ in range(n)]
    if tid == 0x02:
        return [bool(r.u8()) for _ in range(n)]
    if tid == 0x03:
        return r.interleaved_i32(n)
    if tid == 0x04:
        return r.interleaved_f32(n)
    if tid == 0x05:
        return [r.f64() for _ in range(n)]
    if tid == 0x06:
        s = r.interleaved_f32(n); o = r.interleaved_i32(n)
        return list(zip(s, o))
    if tid == 0x07:
        sx = r.interleaved_f32(n); sy = r.interleaved_f32(n); ox = r.interleaved_i32(n); oy = r.interleaved_i32(n)
        return list(zip(sx, ox, sy, oy))
    if tid == 0x08:
        return [tuple(r.f32() for _ in range(6)) for _ in range(n)]
    if tid in (0x09, 0x0A):
        return [r.u8() for _ in range(n)]
    if tid == 0x0B:
        return r.interleaved_u32(n)
    if tid == 0x0C:
        a = r.interleaved_f32(n); b = r.interleaved_f32(n); c = r.interleaved_f32(n)
        return list(zip(a, b, c))
    if tid == 0x0D:
        a = r.interleaved_f32(n); b = r.interleaved_f32(n)
        return list(zip(a, b))
    if tid == 0x0E:
        a = r.interleaved_f32(n); b = r.interleaved_f32(n); c = r.interleaved_f32(n)
        return list(zip(a, b, c))
    if tid == 0x10:
        rots = []
        for _ in range(n):
            rid = r.u8()
            if rid == 0:
                rots.append(tuple(r.f32() for _ in range(9)))
            else:
                rots.append(rot_from_id(rid))
        a = r.interleaved_f32(n); b = r.interleaved_f32(n); c = r.interleaved_f32(n)
        return [((a[i], b[i], c[i]), rots[i]) for i in range(n)]
    if tid == 0x12:
        return r.interleaved_u32(n)
    if tid == 0x13:
        return r.referents(n)
    if tid == 0x14:
        return [struct.unpack('<hhh', r.bytes(6)) for _ in range(n)]
    if tid == 0x15:
        out = []
        for _ in range(n):
            k = r.u32(); out.append([tuple(r.f32() for _ in range(3)) for _ in range(k)])
        return out
    if tid == 0x16:
        out = []
        for _ in range(n):
            k = r.u32(); out.append([tuple(r.f32() for _ in range(5)) for _ in range(k)])
        return out
    if tid == 0x17:
        return [(r.f32(), r.f32()) for _ in range(n)]
    if tid == 0x18:
        a = r.interleaved_f32(n); b = r.interleaved_f32(n); c = r.interleaved_f32(n); d = r.interleaved_f32(n)
        return list(zip(a, b, c, d))
    if tid == 0x19:
        out = []
        for _ in range(n):
            f = r.u8()
            if f:
                out.append(tuple(r.f32() for _ in range(5)))
            else:
                out.append(None)
        return out
    if tid == 0x1A:
        a = r.bytes(n); b = r.bytes(n); c = r.bytes(n)
        return [(a[i], b[i], c[i]) for i in range(n)]
    if tid == 0x1B:
        return r.interleaved_i64(n)
    if tid == 0x1C:
        return r.interleaved_u32(n)
    if tid == 0x1E:
        inner = r.u8()
        cf = read_values(r, inner, n)
        inner2 = r.u8()
        flags = read_values(r, inner2, n)
        return [cf[i] if flags[i] else None for i in range(n)]
    if tid == 0x1F:
        raw = r.bytes(16*n)
        return [bytes(raw[b*n+i] for b in range(16)) for i in range(n)]
    if tid == 0x20:
        out = []
        for _ in range(n):
            fam = r.string(); w = r.u16(); s = r.u8(); cached = r.string()
            out.append((fam, w, s, cached))
        return out
    if tid == 0x21:
        return r.interleaved_u64(n)
    raise ValueError("unknown type id 0x%02x" % tid)

def read_rbxm(path):
    data = open(path, 'rb').read()
    assert data[:14] == MAGIC, data[:14]
    version = struct.unpack_from('<H', data, 14)[0]
    nclasses, ninst = struct.unpack_from('<ii', data, 16)
    p = 32
    classes = {}
    insts = {}
    meta = {}
    sstr = []
    while p < len(data):
        name = data[p:p+4]; clen, ulen = struct.unpack_from('<II', data, p+4); p += 16
        if clen == 0:
            payload = data[p:p+ulen]; p += ulen
        else:
            comp = data[p:p+clen]; p += clen
            if comp[:4] == b'\x28\xb5\x2f\xfd':
                import zstandard
                payload = zstandard.ZstdDecompressor().decompress(comp, max_output_size=ulen)
            else:
                payload = lz4.block.decompress(comp, uncompressed_size=ulen)
        r = R(payload)
        if name == b'META':
            k = r.u32()
            for _ in range(k):
                a = r.string(); b = r.string(); meta[a] = b
        elif name == b'SSTR':
            r.u32(); k = r.u32()
            for _ in range(k):
                r.bytes(16); sstr.append(r.rawstring())
        elif name == b'INST':
            cid = r.u32(); cname = r.string(); fmt = r.u8(); k = r.u32()
            refs = r.referents(k)
            if fmt == 1:
                r.bytes(k)
            classes[cid] = {'name': cname, 'refs': refs, 'service': fmt == 1}
            for ref in refs:
                insts[ref] = {'ref': ref, 'cls': cname, 'props': {}, 'parent': None, 'children': []}
        elif name == b'PROP':
            cid = r.u32(); pname = r.string(); tid = r.u8()
            c = classes[cid]; k = len(c['refs'])
            try:
                vals = read_values(r, tid, k)
            except Exception as e:
                print("WARN prop", c['name'], pname, hex(tid), e, file=sys.stderr); continue
            for ref, v in zip(c['refs'], vals):
                insts[ref]['props'][pname] = (tid, v)
        elif name == b'PRNT':
            r.u8(); k = r.u32(); ch = r.referents(k); pa = r.referents(k)
            for c_, p_ in zip(ch, pa):
                insts[c_]['parent'] = p_
                if p_ != -1:
                    insts[p_]['children'].append(c_)
        elif name == b'END\x00':
            break
    roots = [i['ref'] for i in insts.values() if i['parent'] == -1 or i['parent'] is None]
    return {'version': version, 'meta': meta, 'sstr': sstr, 'classes': classes, 'insts': insts, 'roots': roots}

# ---------------- writing ----------------
class W:
    def __init__(self):
        self.b = bytearray()
    def u8(self, v): self.b.append(v & 0xFF)
    def u16(self, v): self.b += struct.pack('<H', v)
    def u32(self, v): self.b += struct.pack('<I', v & 0xFFFFFFFF)
    def i32(self, v): self.b += struct.pack('<i', v)
    def f32(self, v): self.b += struct.pack('<f', v)
    def f64(self, v): self.b += struct.pack('<d', v)
    def raw(self, v): self.b += v
    def string(self, s):
        if isinstance(s, str): s = s.encode('utf-8')
        self.u32(len(s)); self.raw(s)
    def interleaved_u32(self, vals):
        n = len(vals); out = bytearray(4*n)
        for i, v in enumerate(vals):
            v &= 0xFFFFFFFF
            out[i] = v >> 24; out[n+i] = (v >> 16) & 0xFF; out[2*n+i] = (v >> 8) & 0xFF; out[3*n+i] = v & 0xFF
        self.raw(out)
    def interleaved_i32(self, vals):
        self.interleaved_u32([((v << 1) ^ (v >> 31)) & 0xFFFFFFFF for v in vals])
    def interleaved_f32(self, vals):
        out = []
        for v in vals:
            bits = struct.unpack('<I', struct.pack('<f', v))[0]
            out.append(((bits << 1) | (bits >> 31)) & 0xFFFFFFFF)
        self.interleaved_u32(out)
    def interleaved_u64(self, vals):
        n = len(vals); out = bytearray(8*n)
        for i, v in enumerate(vals):
            v &= 0xFFFFFFFFFFFFFFFF
            for b in range(8):
                out[b*n+i] = (v >> (8*(7-b))) & 0xFF
        self.raw(out)
    def interleaved_i64(self, vals):
        self.interleaved_u64([((v << 1) ^ (v >> 63)) for v in vals])
    def referents(self, vals):
        prev = 0; deltas = []
        for v in vals:
            deltas.append(v - prev); prev = v
        self.interleaved_i32(deltas)

def write_values(w, tid, vals):
    n = len(vals)
    if tid == 0x01 or tid == 0x1D:
        for v in vals: w.string(v)
    elif tid == 0x02:
        for v in vals: w.u8(1 if v else 0)
    elif tid == 0x03:
        w.interleaved_i32(vals)
    elif tid == 0x04:
        w.interleaved_f32(vals)
    elif tid == 0x05:
        for v in vals: w.f64(v)
    elif tid == 0x06:
        w.interleaved_f32([v[0] for v in vals]); w.interleaved_i32([v[1] for v in vals])
    elif tid == 0x07:
        w.interleaved_f32([v[0] for v in vals]); w.interleaved_f32([v[2] for v in vals])
        w.interleaved_i32([v[1] for v in vals]); w.interleaved_i32([v[3] for v in vals])
    elif tid == 0x08:
        for v in vals:
            for x in v: w.f32(x)
    elif tid in (0x09, 0x0A):
        for v in vals: w.u8(v)
    elif tid == 0x0B:
        w.interleaved_u32(vals)
    elif tid in (0x0C, 0x0E):
        for k in range(3): w.interleaved_f32([v[k] for v in vals])
    elif tid == 0x0D:
        for k in range(2): w.interleaved_f32([v[k] for v in vals])
    elif tid == 0x10:
        for pos, rot in vals:
            w.u8(0)
            for x in rot: w.f32(x)
        for k in range(3): w.interleaved_f32([v[0][k] for v in vals])
    elif tid == 0x12:
        w.interleaved_u32(vals)
    elif tid == 0x13:
        w.referents(vals)
    elif tid == 0x14:
        for v in vals: w.raw(struct.pack('<hhh', *v))
    elif tid == 0x15:
        for v in vals:
            w.u32(len(v))
            for kp in v:
                for x in kp: w.f32(x)
    elif tid == 0x16:
        for v in vals:
            w.u32(len(v))
            for kp in v:
                for x in kp: w.f32(x)
    elif tid == 0x17:
        for v in vals: w.f32(v[0]); w.f32(v[1])
    elif tid == 0x18:
        for k in range(4): w.interleaved_f32([v[k] for v in vals])
    elif tid == 0x19:
        for v in vals:
            if v is None: w.u8(0)
            else:
                w.u8(1)
                for x in v: w.f32(x)
    elif tid == 0x1A:
        for k in range(3): w.raw(bytes(int(v[k]) & 0xFF for v in vals))
    elif tid == 0x1B:
        w.interleaved_i64(vals)
    elif tid == 0x1C:
        w.interleaved_u32(vals)
    elif tid == 0x1E:
        w.u8(0x10)
        cfs = [v if v is not None else ((0.0,0.0,0.0),(1.0,0,0,0,1.0,0,0,0,1.0)) for v in vals]
        write_values(w, 0x10, cfs)
        w.u8(0x02)
        for v in vals: w.u8(0 if v is None else 1)
    elif tid == 0x1F:
        n = len(vals); out = bytearray(16*n)
        for i, v in enumerate(vals):
            for b in range(16): out[b*n+i] = v[b]
        w.raw(out)
    elif tid == 0x20:
        for fam, wt, st, cached in vals:
            w.string(fam); w.u16(wt); w.u8(st); w.string(cached)
    elif tid == 0x21:
        w.interleaved_u64(vals)
    else:
        raise ValueError("cannot write type 0x%02x" % tid)

def chunk(name, payload, compress=True):
    assert len(name) == 4
    out = bytearray(name)
    if compress and len(payload) > 0:
        comp = lz4.block.compress(bytes(payload), store_size=False, mode='high_compression')
        out += struct.pack('<III', len(comp), len(payload), 0); out += comp
    else:
        out += struct.pack('<III', 0, len(payload), 0); out += payload
    return out

def write_rbxm(insts, path, sstr=None, meta=None):
    """insts: list of dicts {cls, props{name:(tid,val)}, parent(index or -1)} ; index == referent."""
    sstr = sstr or []
    # group by class, preserving first-seen order
    order = []
    byclass = {}
    for i, inst in enumerate(insts):
        c = inst['cls']
        if c not in byclass:
            byclass[c] = []; order.append(c)
        byclass[c].append(i)
    out = bytearray(MAGIC); out += struct.pack('<H', 0); out += struct.pack('<ii', len(order), len(insts)); out += b'\0'*8
    # META
    w = W(); m = meta or {'ExplicitAutoJoints': 'true'}
    w.u32(len(m))
    for k, v in m.items(): w.string(k); w.string(v)
    out += chunk(b'META', w.b)
    if sstr:
        w = W(); w.u32(0); w.u32(len(sstr))
        for s in sstr:
            import hashlib
            w.raw(hashlib.md5(s).digest()); w.string(s)
        out += chunk(b'SSTR', w.b)
    for cid, cname in enumerate(order):
        refs = byclass[cname]
        w = W(); w.u32(cid); w.string(cname); w.u8(0); w.u32(len(refs)); w.referents(refs)
        out += chunk(b'INST', w.b)
    for cid, cname in enumerate(order):
        refs = byclass[cname]
        # collect prop names with types
        pnames = {}
        for r_ in refs:
            for pn, (tid, v) in insts[r_]['props'].items():
                pnames.setdefault(pn, tid)
        for pn, tid in pnames.items():
            vals = []
            ok = True
            for r_ in refs:
                pv = insts[r_]['props'].get(pn)
                if pv is None:
                    ok = False; break
                vals.append(pv[1])
            if not ok:
                # fill with defaults for missing
                vals = []
                for r_ in refs:
                    pv = insts[r_]['props'].get(pn)
                    vals.append(pv[1] if pv is not None else default_for(tid))
            w = W(); w.u32(cid); w.string(pn); w.u8(tid)
            write_values(w, tid, vals)
            out += chunk(b'PROP', w.b)
    w = W(); w.u8(0); w.u32(len(insts))
    w.referents(list(range(len(insts)))); w.referents([inst['parent'] for inst in insts])
    out += chunk(b'PRNT', w.b)
    out += chunk(b'END\0', b'</roblox>', compress=False)
    open(path, 'wb').write(out)
    return len(out)

def default_for(tid):
    return {0x01: b'', 0x02: False, 0x03: 0, 0x04: 0.0, 0x05: 0.0, 0x0C: (0.0,0.0,0.0), 0x0E: (0.0,0.0,0.0),
            0x10: ((0.0,0.0,0.0),(1.0,0,0,0,1.0,0,0,0,1.0)), 0x12: 0, 0x13: -1, 0x1A: (163,162,165), 0x19: None,
            0x1C: 0, 0x1B: 0, 0x06: (0.0,0), 0x07: (0.0,0,0.0,0), 0x1F: bytes(16), 0x0D: (0.0,0.0), 0x18:(0.0,0.0,0.0,0.0),
            0x21: 0, 0x20: ('rbxasset://fonts/families/SourceSansPro.json', 400, 0, ''), 0x15: [], 0x16: [], 0x17:(0.0,0.0),
            0x09: 0, 0x0A: 0, 0x0B: 194, 0x1E: None, 0x14:(0,0,0), 0x08:(0,0,0,0,0,0)}.get(tid, 0)

if __name__ == '__main__':
    d = read_rbxm(sys.argv[1])
    print("version", d['version'], "meta", d['meta'], "sstr", len(d['sstr']))
    from collections import Counter
    print(Counter(i['cls'] for i in d['insts'].values()))
    print("roots", [(d['insts'][r]['cls'], d['insts'][r]['props'].get('Name')) for r in d['roots']])
