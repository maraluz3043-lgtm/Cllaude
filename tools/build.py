"""Builder library for new Roblox geometry in the building's local frame.

LOCAL FRAME (u, y, v):
  u = along the facade, increasing to the RIGHT when standing in the courtyard looking at the facade.
      u = 0 at the centre of the first ground-floor column.
  y = world up (world Y). Sidewalk/finished floor top is y = 0.42.
  v = depth INTO the building (perpendicular to the facade). v = 0 at the facade column centre line,
      facade wall occupies v 0.40..1.40, the interior of a ground-floor hall starts at v = 1.40.
Sizes: size=(w, h, d): w along u, h along y, d along v (when yaw=0).
yaw (degrees): rotation about the vertical axis. For yaw=90 the part's width axis points along +v.
pitch (deg): rotation about the part's own width axis; roll (deg): rotation about the part's own depth axis.
Cylinders: Roblox cylinders have their axis along the part's X (width) axis -> use cylinder(..., axis='y') helper.
"""
import math, os, sys
import numpy as np
from rbxm import write_rbxm, read_rbxm

# ---- building frame (derived from the uploaded model's walls) ----
F = np.array([-0.021994, 0.0, 0.999754])       # +u direction (world)
Yv = np.array([0.0, 1.0, 0.0])
D = np.array([0.999756, 0.0, 0.021996])        # +v direction (world)
W_ = -D                                        # right-handed third axis for (u, y, w=-v)
ORG = np.array([36.71701431274414, 0.0, -1485.35107421875])
B = np.column_stack([F, Yv, W_])               # world <- local(u,y,w)

MAT = {'Plastic':256,'SmoothPlastic':272,'Neon':288,'Wood':512,'WoodPlanks':528,'Marble':784,'Basalt':788,
       'Slate':800,'CrackedLava':804,'Concrete':816,'Limestone':820,'Granite':832,'Pavement':836,'Brick':848,
       'Pebble':864,'Cobblestone':880,'Rock':896,'Sandstone':912,'CorrodedMetal':1040,'DiamondPlate':1056,
       'Foil':1072,'Metal':1088,'Grass':1280,'LeafyGrass':1284,'Sand':1296,'Fabric':1312,'Snow':1328,
       'Mud':1344,'Ground':1360,'Asphalt':1376,'Salt':1392,'Ice':1536,'Glacier':1552,'Glass':1568,
       'ForceField':1584,'Cardboard':2304,'Carpet':2305,'CeramicTiles':2306,'ClayRoofTiles':2307,
       'Leather':2308,'Plaster':2309,'Rubber':2310,'RoofShingles':2311}
SHAPE = {'Ball':0,'Block':1,'Cylinder':2,'Wedge':3,'CornerWedge':4}
FACE = {'Right':0,'Top':1,'Back':2,'Left':3,'Bottom':4,'Front':5}
FONT_GOTHAM = ('rbxasset://fonts/families/GothamSSm.json', 700, 0, '')
FONT_SOURCE = ('rbxasset://fonts/families/SourceSansPro.json', 400, 0, '')
FONT_FREDOKA = ('rbxasset://fonts/families/FredokaOne.json', 400, 0, '')
FONT_BANGERS = ('rbxasset://fonts/families/Bangers.json', 400, 0, '')
FONT_PERMANENT = ('rbxasset://fonts/families/PermanentMarker.json', 400, 0, '')

def rot_matrix(yaw=0.0, pitch=0.0, roll=0.0):
    t, p, r = math.radians(yaw), math.radians(pitch), math.radians(roll)
    Ry = np.array([[math.cos(t),0,math.sin(t)],[0,1,0],[-math.sin(t),0,math.cos(t)]])
    Rx = np.array([[1,0,0],[0,math.cos(p),-math.sin(p)],[0,math.sin(p),math.cos(p)]])
    Rz = np.array([[math.cos(r),-math.sin(r),0],[math.sin(r),math.cos(r),0],[0,0,1]])
    return Ry @ Rx @ Rz

def local_to_world(u, y, v):
    return ORG + u*F + y*Yv + v*D

def world_to_local(p):
    d = np.array(p) - ORG
    return float(d @ F), float(d[1]), float(d @ D)

def cframe(u, y, v, yaw=0.0, pitch=0.0, roll=0.0):
    R = B @ rot_matrix(yaw, pitch, roll)
    pos = local_to_world(u, y, v)
    rot = tuple(float(x) for x in R.reshape(-1))
    return ((float(pos[0]), float(pos[1]), float(pos[2])), rot)

def face_toward(yaw, direction, pitch=0.0, roll=0.0):
    """Return the Enum.NormalId value of the part face whose normal points most along `direction`
    given in local (du, dy, dv) coordinates, for a part with the given rotation."""
    R = B @ rot_matrix(yaw, pitch, roll)
    du, dy, dv = direction
    dworld = du*F + dy*Yv + dv*D
    best = None
    for name, idx, vec in (('Right',0,R[:,0]),('Left',3,-R[:,0]),('Top',1,R[:,1]),('Bottom',4,-R[:,1]),('Back',2,R[:,2]),('Front',5,-R[:,2])):
        s = float(vec @ dworld)
        if best is None or s > best[0]:
            best = (s, idx)
    return best[1]

class Ctx:
    """Collects instances. Each instance: {'cls', 'props': {name: (typeid, value)}, 'parent': idx}."""
    def __init__(self):
        self.insts = []
        self.sstr = []
    def _add(self, cls, props, parent):
        self.insts.append({'cls': cls, 'props': props, 'parent': parent})
        return len(self.insts) - 1
    def model(self, name, parent=-1):
        return self._add('Model', {'Name': (0x01, name.encode())}, parent)
    def folder(self, name, parent=-1):
        return self._add('Folder', {'Name': (0x01, name.encode())}, parent)
    def part(self, name, center, size, color=(200,200,200), material='SmoothPlastic', parent=-1,
             yaw=0.0, pitch=0.0, roll=0.0, transparency=0.0, shape='Block', reflectance=0.0,
             cancollide=True, cls='Part', castshadow=True, anchored=True):
        u, y, v = center
        w, h, d = size
        props = {
            'Name': (0x01, name.encode()),
            'Anchored': (0x02, bool(anchored)),
            'CanCollide': (0x02, bool(cancollide)),
            'CastShadow': (0x02, bool(castshadow)),
            'CFrame': (0x10, cframe(u, y, v, yaw, pitch, roll)),
            'size': (0x0E, (float(w), float(h), float(d))),
            'Color3uint8': (0x1A, (int(color[0]), int(color[1]), int(color[2]))),
            'Material': (0x12, MAT[material] if isinstance(material, str) else int(material)),
            'Transparency': (0x04, float(transparency)),
            'Reflectance': (0x04, float(reflectance)),
            'TopSurface': (0x12, 0), 'BottomSurface': (0x12, 0),
            'LeftSurface': (0x12, 0), 'RightSurface': (0x12, 0), 'FrontSurface': (0x12, 0), 'BackSurface': (0x12, 0),
        }
        if cls in ('Part', 'Seat'):
            props['shape'] = (0x12, SHAPE[shape])
        if cls == 'Seat':
            props['Disabled'] = (0x02, False)
        return self._add(cls, props, parent)
    def box(self, name, center, size, **kw):
        return self.part(name, center, size, **kw)
    def cylinder(self, name, center, length, diameter, axis='y', diameter2=None, **kw):
        """Cylinder whose axis is along local 'u', 'y' or 'v'. diameter2 lets you make elliptic cross-sections."""
        d2 = diameter if diameter2 is None else diameter2
        yaw = kw.pop('yaw', 0.0)
        if axis == 'u':
            return self.part(name, center, (length, diameter, d2), yaw=yaw, shape='Cylinder', **kw)
        if axis == 'y':
            return self.part(name, center, (length, diameter, d2), yaw=yaw, roll=90.0, shape='Cylinder', **kw)
        if axis == 'v':
            return self.part(name, center, (length, diameter, d2), yaw=yaw + 90.0, shape='Cylinder', **kw)
        raise ValueError(axis)
    def ball(self, name, center, diameter, **kw):
        return self.part(name, center, (diameter, diameter, diameter), shape='Ball', **kw)
    def wedge(self, name, center, size, **kw):
        """WedgePart: vertical face at the part's +depth side, slope descends toward -depth (toward the corridor for yaw=0)."""
        return self.part(name, center, size, cls='WedgePart', **kw)
    # ---- GUI helpers (0 parts) ----
    def surface_gui(self, part_idx, face, pixels_per_stud=50.0, name='SurfaceGui', light_influence=0.0, always_on_top=False):
        props = {'Name': (0x01, name.encode()), 'Face': (0x12, int(face)), 'SizingMode': (0x12, 1),
                 'PixelsPerStud': (0x04, float(pixels_per_stud)), 'LightInfluence': (0x04, float(light_influence)),
                 'AlwaysOnTop': (0x02, bool(always_on_top)), 'Enabled': (0x02, True), 'ClipsDescendants': (0x02, True),
                 'Brightness': (0x04, 1.0), 'ZOffset': (0x04, 0.0), 'MaxDistance': (0x04, 400.0), 'Active': (0x02, False),
                 'ResetOnSpawn': (0x02, False), 'CanvasSize': (0x0D, (800.0, 600.0))}
        return self._add('SurfaceGui', props, part_idx)
    def frame(self, parent, pos=(0,0,0,0), size=(1,0,1,0), color=(255,255,255), transparency=0.0, name='Frame', corner=None, rotation=0.0):
        props = {'Name': (0x01, name.encode()), 'Position': (0x07, tuple(float(x) if i%2==0 else int(x) for i,x in enumerate(pos))),
                 'Size': (0x07, tuple(float(x) if i%2==0 else int(x) for i,x in enumerate(size))),
                 'BackgroundColor3': (0x0C, (color[0]/255.0, color[1]/255.0, color[2]/255.0)),
                 'BackgroundTransparency': (0x04, float(transparency)), 'BorderSizePixel': (0x03, 0),
                 'Rotation': (0x04, float(rotation)), 'ZIndex': (0x03, 1), 'Visible': (0x02, True)}
        idx = self._add('Frame', props, parent)
        if corner is not None:
            cr = (float(corner[0]), int(corner[1]))
            self._add('UICorner', {'Name': (0x01, b'UICorner'), 'CornerRadius': (0x06, cr), 'TopLeftRadius': (0x06, cr),
                                   'TopRightRadius': (0x06, cr), 'BottomLeftRadius': (0x06, cr), 'BottomRightRadius': (0x06, cr)}, idx)
        return idx
    def text(self, parent, text, pos=(0,0,0,0), size=(1,0,1,0), color=(0,0,0), font=FONT_GOTHAM, scaled=True,
             text_size=24.0, bg_transparency=1.0, bg_color=(255,255,255), stroke=None, rotation=0.0, name='TextLabel',
             xalign=2, yalign=1):  # TextXAlignment: Left=0, Right=1, Center=2 ; TextYAlignment: Top=0, Center=1, Bottom=2
        props = {'Name': (0x01, name.encode()), 'Text': (0x01, text.encode('utf-8')),
                 'Position': (0x07, tuple(float(x) if i%2==0 else int(x) for i,x in enumerate(pos))),
                 'Size': (0x07, tuple(float(x) if i%2==0 else int(x) for i,x in enumerate(size))),
                 'TextColor3': (0x0C, (color[0]/255.0, color[1]/255.0, color[2]/255.0)),
                 'BackgroundTransparency': (0x04, float(bg_transparency)),
                 'BackgroundColor3': (0x0C, (bg_color[0]/255.0, bg_color[1]/255.0, bg_color[2]/255.0)),
                 'BorderSizePixel': (0x03, 0), 'TextScaled': (0x02, bool(scaled)), 'TextSize': (0x04, float(text_size)),
                 'FontFace': (0x20, font), 'TextWrapped': (0x02, True), 'Rotation': (0x04, float(rotation)),
                 'TextXAlignment': (0x12, int(xalign)), 'TextYAlignment': (0x12, int(yalign)), 'ZIndex': (0x03, 2),
                 'Visible': (0x02, True), 'RichText': (0x02, False)}
        if stroke is not None:
            props['TextStrokeColor3'] = (0x0C, (stroke[0]/255.0, stroke[1]/255.0, stroke[2]/255.0))
            props['TextStrokeTransparency'] = (0x04, 0.0)
        return self._add('TextLabel', props, parent)
    def label_on(self, part_idx, text, direction, yaw=0.0, color=(0,0,0), font=FONT_GOTHAM, pixels_per_stud=60.0,
                 pos=(0,0,0,0), size=(1,0,1,0), stroke=None, rotation=0.0, pitch=0.0, roll=0.0):
        """Convenience: SurfaceGui + TextLabel on the face of part pointing along local `direction` (du,dy,dv)."""
        g = self.surface_gui(part_idx, face_toward(yaw, direction, pitch, roll), pixels_per_stud)
        return self.text(g, text, pos=pos, size=size, color=color, font=font, stroke=stroke, rotation=rotation)
    def light(self, part_idx, kind='SurfaceLight', face=4, brightness=1.0, range_=16.0, color=(255,250,235), angle=140.0, shadows=False):
        props = {'Name': (0x01, kind.encode()), 'Brightness': (0x04, float(brightness)), 'Range': (0x04, float(range_)),
                 'Color': (0x0C, (color[0]/255.0, color[1]/255.0, color[2]/255.0)), 'Enabled': (0x02, True), 'Shadows': (0x02, bool(shadows))}
        if kind == 'SurfaceLight':
            props['Face'] = (0x12, int(face)); props['Angle'] = (0x04, float(angle))
        return self._add(kind, props, part_idx)
    def attribute_tag(self, idx, key, value):
        pass  # not needed
    # ---- queries ----
    def children(self, idx):
        return [i for i, inst in enumerate(self.insts) if inst['parent'] == idx]
    def descendants(self, idx):
        out = []
        stack = [idx]
        kids = {}
        for i, inst in enumerate(self.insts):
            kids.setdefault(inst['parent'], []).append(i)
        while stack:
            k = stack.pop()
            for c in kids.get(k, []):
                out.append(c); stack.append(c)
        return out
    def count_parts(self, idx=None):
        ids = range(len(self.insts)) if idx is None else self.descendants(idx)
        return sum(1 for i in ids if self.insts[i]['cls'] in ('Part','Seat','WedgePart','CornerWedgePart','MeshPart','TrussPart','UnionOperation'))
    def bbox(self, idx):
        """Axis-aligned bbox in local coords (u,y,v) of all parts under idx: returns (lo, hi) arrays."""
        los, his = [], []
        for i in self.descendants(idx):
            inst = self.insts[i]
            if 'CFrame' in inst['props'] and 'size' in inst['props']:
                lo, hi = part_aabb_local(inst['props']['CFrame'][1], inst['props']['size'][1])
                los.append(lo); his.append(hi)
        if not los: return None, None
        return np.min(los, axis=0), np.max(his, axis=0)
    # ---- cloning from a parsed source dom ----
    def clone(self, src, src_ref, parent, du=0.0, dy=0.0, dv=0.0, yaw=0.0, pivot=None, rename=None):
        """Deep-copy instance src_ref (and descendants) from a parsed dom `src` (rbxm.read_rbxm result),
        translating parts by (du,dy,dv) in local coords, optionally rotating by yaw about a vertical axis through
        local pivot (u,v) BEFORE translating. Returns new index of the root copy."""
        I = src['insts']
        mapping = {}
        order = []
        def walk(r):
            order.append(r)
            for c in I[r]['children']: walk(c)
        walk(src_ref)
        th = math.radians(yaw)
        Ry = np.array([[math.cos(th),0,math.sin(th)],[0,1,0],[-math.sin(th),0,math.cos(th)]])
        Rw = B @ Ry @ B.T   # rotation about vertical in world coords (yaw in local frame)
        pw = local_to_world(pivot[0], 0.0, pivot[1]) if pivot is not None else None
        delta = du*F + dy*Yv + dv*D
        def xform_cf(cf):
            (px,py,pz), rot = cf
            p = np.array([px,py,pz]); Rm = np.array(rot).reshape(3,3)
            if pivot is not None and yaw != 0.0:
                p = pw + Rw @ (p - pw); Rm = Rw @ Rm
            p = p + delta
            return ((float(p[0]),float(p[1]),float(p[2])), tuple(float(x) for x in Rm.reshape(-1)))
        for r in order:
            inst = I[r]
            props = {}
            for pn, (tid, val) in inst['props'].items():
                if pn in ('UniqueId','HistoryId','Tags','ModelMeshData','SlimHash','ModelMeshCFrame','ModelMeshSize','SourceAssetId'):
                    continue
                if tid == 0x1C:  # shared strings: skip
                    continue
                if tid == 0x10 and pn in ('CFrame','PivotOffset') and pn == 'CFrame':
                    val = xform_cf(val)
                if tid == 0x1E:  # OptionalCFrame (WorldPivotData)
                    val = xform_cf(val) if val is not None else None
                if tid == 0x13:  # referent
                    val = mapping.get(val, -1) if val != -1 else -1
                props[pn] = (tid, val)
            if rename and r == src_ref:
                props['Name'] = (0x01, rename.encode())
            par = parent if r == src_ref else mapping[inst['parent']]
            mapping[r] = self._add(inst['cls'], props, par)
        return mapping[src_ref]
    # ---- export ----
    def normalize(self):
        """Make UICorner instances carry both radius schemes consistently (old CornerRadius + per-corner radii),
        so that filling missing properties with defaults at write time never zeroes a radius."""
        for inst in self.insts:
            if inst['cls'] != 'UICorner':
                continue
            p = inst['props']
            corners = ['TopLeftRadius', 'TopRightRadius', 'BottomLeftRadius', 'BottomRightRadius']
            if 'CornerRadius' in p:
                val = p['CornerRadius'][1]
                for c in corners:
                    p.setdefault(c, (0x06, val))
            else:
                src = next((p[c][1] for c in corners if c in p), (0.0, 0))
                p['CornerRadius'] = (0x06, src)
                for c in corners:
                    p.setdefault(c, (0x06, src))
    def export(self, path_rbxm, roots=None, also_xml=True):
        """Write all instances (parents -1 are roots) to a binary .rbxm; optionally also .rbxmx."""
        self.normalize()
        n = write_rbxm(self.insts, path_rbxm, sstr=self.sstr)
        if also_xml:
            write_rbxmx(self.insts, os.path.splitext(path_rbxm)[0] + '.rbxmx')
        return n

def part_aabb_local(cf, size):
    (px,py,pz), rot = cf
    Rm = np.array(rot).reshape(3,3)
    sx,sy,sz = size
    c = []
    for dx in (-1,1):
        for dy in (-1,1):
            for dz in (-1,1):
                world = np.array([px,py,pz]) + Rm @ np.array([dx*sx/2, dy*sy/2, dz*sz/2])
                c.append(world_to_local(world))
    c = np.array(c)
    return c.min(axis=0), c.max(axis=0)

# ---------------- XML writer (.rbxmx) ----------------
from xml.sax.saxutils import escape
ENUM_NAMES = {}
def _xml_value(tid, name, val, out):
    if tid == 0x01:
        out.append(f'<string name="{name}">{escape(val.decode("utf-8","replace"))}</string>')
    elif tid == 0x02:
        out.append(f'<bool name="{name}">{"true" if val else "false"}</bool>')
    elif tid == 0x03:
        out.append(f'<int name="{name}">{int(val)}</int>')
    elif tid == 0x04:
        out.append(f'<float name="{name}">{float(val):g}</float>')
    elif tid == 0x05:
        out.append(f'<double name="{name}">{float(val):g}</double>')
    elif tid == 0x06:
        out.append(f'<UDim name="{name}"><S>{val[0]:g}</S><O>{int(val[1])}</O></UDim>')
    elif tid == 0x07:
        out.append(f'<UDim2 name="{name}"><XS>{val[0]:g}</XS><XO>{int(val[1])}</XO><YS>{val[2]:g}</YS><YO>{int(val[3])}</YO></UDim2>')
    elif tid == 0x0C:
        r,g,b = val; out.append(f'<Color3 name="{name}"><R>{r:g}</R><G>{g:g}</G><B>{b:g}</B></Color3>')
    elif tid == 0x0D:
        out.append(f'<Vector2 name="{name}"><X>{val[0]:g}</X><Y>{val[1]:g}</Y></Vector2>')
    elif tid == 0x0E:
        out.append(f'<Vector3 name="{name}"><X>{val[0]:g}</X><Y>{val[1]:g}</Y><Z>{val[2]:g}</Z></Vector3>')
    elif tid == 0x10:
        (x,y,z), r = val
        out.append(f'<CoordinateFrame name="{name}"><X>{x:.6f}</X><Y>{y:.6f}</Y><Z>{z:.6f}</Z>' +
                   ''.join(f'<R{i//3}{i%3}>{r[i]:.7f}</R{i//3}{i%3}>' for i in range(9)) + '</CoordinateFrame>')
    elif tid == 0x12:
        out.append(f'<token name="{name}">{int(val)}</token>')
    elif tid == 0x1A:
        r,g,b = val; out.append(f'<Color3uint8 name="{name}">{(0xFF<<24)|(r<<16)|(g<<8)|b}</Color3uint8>')
    elif tid == 0x20:
        fam, w, s, cached = val
        out.append(f'<Font name="{name}"><Family><url>{escape(fam)}</url></Family><Weight>{int(w)}</Weight><Style>{"Normal" if s==0 else "Italic"}</Style></Font>')
    elif tid == 0x13:
        pass  # referents skipped in XML export (not needed for our content)
    else:
        pass

def write_rbxmx(insts, path):
    kids = {}
    for i, inst in enumerate(insts):
        kids.setdefault(inst['parent'], []).append(i)
    out = ['<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">',
           '<Meta name="ExplicitAutoJoints">true</Meta>']
    def emit(i):
        inst = insts[i]
        out.append(f'<Item class="{inst["cls"]}" referent="RBX{i}"><Properties>')
        for pn, (tid, val) in sorted(inst['props'].items()):
            _xml_value(tid, pn, val, out)
        out.append('</Properties>')
        for c in kids.get(i, []):
            emit(c)
        out.append('</Item>')
    for r in kids.get(-1, []):
        emit(r)
    out.append('</roblox>')
    open(path, 'w', encoding='utf-8').write('\n'.join(out))
