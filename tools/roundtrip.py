import sys, time
from rbxm import read_rbxm, write_rbxm
src = sys.argv[1]; dst = sys.argv[2]
d = read_rbxm(src)
I = d['insts']
refs = sorted(I)
idx = {r: i for i, r in enumerate(refs)}
insts = []
for r in refs:
    inst = I[r]
    props = {}
    for pn, (tid, val) in inst['props'].items():
        if tid == 0x13:
            val = idx.get(val, -1) if val != -1 else -1
        props[pn] = (tid, val)
    insts.append({'cls': inst['cls'], 'props': props, 'parent': idx[inst['parent']] if inst['parent'] not in (None, -1) else -1})
t = time.time(); n = write_rbxm(insts, dst, sstr=d['sstr']); print('wrote', n, 'bytes in %.1fs' % (time.time()-t))
d2 = read_rbxm(dst)
I2 = d2['insts']
assert len(I2) == len(I), (len(I2), len(I))
bad = 0
for r in refs:
    a = I[r]; b = I2[idx[r]]
    assert a['cls'] == b['cls']
    pa = (idx[a['parent']] if a['parent'] not in (None,-1) else -1); 
    if b['parent'] != pa and not (b['parent'] in (None,-1) and pa == -1): bad += 1; print('parent mismatch', r)
    for pn, (tid, val) in a['props'].items():
        if pn not in b['props']: bad += 1; print('missing', pn); continue
        tid2, val2 = b['props'][pn]
        if tid == 0x13:
            val = idx.get(val, -1) if val != -1 else -1
        if tid2 != tid or val2 != val:
            if tid in (0x04,) and abs(val2-val) < 1e-6: continue
            bad += 1
            if bad < 10: print('mismatch', r, a['cls'], pn, tid, val, val2)
print('mismatches:', bad)
