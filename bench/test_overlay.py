"""The overlay, frame by frame, on both executables.

`reference-1.0.0/` is the module as 1.0.0 shipped it: lua clipped every line each frame and
the game's own `PencilRenderCore::drawLine` drew them. Since then the frame hook is assembly,
the lines are only worked out again when the view changes, and the module writes the pixels
itself. The picture must not have changed, so every scenario here draws a frame both ways and
the map surface has to come out byte for byte the same - which also keeps the reference as
the definition of "right" for any later rewrite. On top of that the build under test must
leave every register as it found it, must not write outside the surface, the stack and its own
allocations, and must only enter lua when the view it last drew for has actually changed."""
import sys, time
from host import *

OLD = REFERENCE
NEW = MODULE

SMALL = {'view+88': 14, 'view+8c': 34}
SMALL_OUT = {'view+90': 1, 'view+88': 22, 'view+8c': 52}


def rt(base, **extra):
    d = dict(base)
    for k, v in extra.items():
        d[k.replace('_', '+', 1) if k.startswith(('view_', 'win_')) else k] = v
    return d


SCENARIOS = [
    ('zoomed in', rt(SMALL), None, None),
    ('zoomed out', rt(SMALL_OUT), None, None),
    ('zoomed out + row bias', rt(SMALL_OUT, view_94=1), None, None),
    ('zoomed in + row bias', rt(SMALL, view_94=1), None, None),
    ('zoomed out, far left', rt(SMALL_OUT, view_78=0, view_7c=0), None, None),
    ('rotation 6', rt(SMALL, orient=6), None, None),
    ('rotation 4', rt(SMALL, orient=4), None, None),
    ('rotation 2', rt(SMALL, orient=2), None, None),
    ('rotation 6 zoomed out', rt(SMALL_OUT, orient=6), None, None),
    ('rotation 2 zoomed out', rt(SMALL_OUT, orient=2), None, None),
    ('bogus rotation', rt(SMALL, orient=3), None, None),
    ('565 pixel format', rt(SMALL, win_54=0x565), None, None),
    ('camera at origin', rt(SMALL, view_78=0, view_7c=0), None, None),
    ('camera off the map', rt(SMALL, view_78=12000, view_7c=3000), None, None),
    ('negative camera', rt(SMALL, view_78=-100, view_7c=-40), None, None),
    ('bottom edge of map', rt(SMALL, view_78=3200, view_7c=6200), None, None),
    ('right edge of map', rt(SMALL, view_78=6300, view_7c=3000), None, None),
    ('odd camera values', rt(SMALL, view_78=3217, view_7c=811), None, None),
    ('normal game allowed', rt(SMALL, gm=3), {'outside_editor': True}, None),
    ('normal game editor-only', rt(SMALL, gm=3), {'outside_editor': False}, None),
    ('editor, editor-only', rt(SMALL), {'outside_editor': False}, None),
    ('no rotation lines', rt(SMALL), {'rotation_lines': False}, None),
    ('nonsense config', rt(SMALL), {'key': 'letter_q', 'grid_colour': 'puce'}, None),
    ('normal view hides', rt(SMALL, flatA=0), None, None),
    ('normal view (B) hides', rt(SMALL, flatB=0), None, None),
    ('V view hides', rt(SMALL, vflag=0), None, None),
    ('V view, gate off', rt(SMALL, vflag=0), {'hide_in_v_view': False}, None),
    ('normal view, gate off', rt(SMALL, flatA=0), {'flattened_only': False}, None),
    ('mine boxes off', rt(SMALL), {'mine_boxes': False}, None),
    ('mine footprint 3', rt(SMALL), None, {'mine_size': 3}),
    ('mine footprint 5', rt(SMALL_OUT), None, {'mine_size': 5}),
    ('colours changed', rt(SMALL), {'grid_colour': 'black', 'rotation_colour': 'red',
                                    'mine_colour': 'white'}, None),
    ('origin override 150,250', rt(SMALL), None, {'origin_x': 150, 'origin_y': 250}),
    ('boundary nudge', rt(SMALL), None, {'boundary_x': 12, 'boundary_y': -9}),
    ('boundary nudge zoomed out', rt(SMALL_OUT), None, {'boundary_x': 12, 'boundary_y': -9}),
    ('junk tune values', rt(SMALL), None, {'origin_x': 'nope', 'boundary_y': None}),
    ('tiny render area', rt(SMALL, view_88=1, view_8c=1), None, None),
    ('empty render area', rt(SMALL, view_88=-3, view_8c=-60), None, None),
]


class Pair:
    def __init__(self, exe_path, runtime=None, overlay=None, tune=None):
        self.old = Host(OLD, exe_path, runtime, overlay, tune)
        self.new = Host(NEW, exe_path, runtime, overlay, tune)
        self.control = None

    def put(self, key, value):
        self.old.put(key, value)
        self.new.put(key, value)

    def press(self, **kw):
        self.old.press(**kw)
        self.new.press(**kw)

    def screen(self, ebp):
        self.old.screen(ebp)
        self.new.screen(ebp)

    def frame(self):
        for h in (self.old, self.new):
            h.clear_surface()
        lua_before = self.new.lua_calls
        old_count = self.old.frame()
        log = self.new.m.write_log = []
        new_count = self.new.frame()
        self.new.m.write_log = None
        bad = [(a, n) for a, n in log if not allowed(self.new, a, n)]
        do, po = self.old.surface_digest()
        dn, pn = self.new.surface_digest()
        return {'same': do == dn, 'painted': po, 'old': old_count, 'new': new_count,
                'lua': self.new.lua_calls - lua_before, 'bad_writes': bad}


def allowed(host, address, size):
    if SURFACE <= address and address + size <= SURFACE + SURFACE_BYTES:
        return True
    if STACK_TOP - 0x10000 <= address and address + size <= STACK_TOP:
        return True
    if HEAP <= address < host.heap:          # the module's own allocations
        return True
    return False


failures = 0


def check(label, result, expect_painted=None, expect_lua=None):
    global failures
    ok = result['same'] and not result['bad_writes']
    if expect_painted is not None:
        ok = ok and ((result['painted'] > 0) == expect_painted)
    if expect_lua is not None:
        ok = ok and result['lua'] == expect_lua
    failures += not ok
    print('  %-4s %-34s px=%-6d old=%-8d new=%-7d lua=%d%s' % (
        'ok' if ok else 'FAIL', label, result['painted'], result['old'], result['new'],
        result['lua'], '' if not result['bad_writes'] else ' BAD WRITES %r' % result['bad_writes'][:3]))


def main():
    started = time.time()
    for exe_path, label in ((VAN_PATH, 'plain'), (EXT_PATH, 'extreme')):
        print('==', label)

        for name, runtime, overlay, tune in SCENARIOS:
            pair = Pair(exe_path, runtime, overlay, tune)
            pair.press()
            check(name, pair.frame())

        print('  -- one session, frame by frame')
        p = Pair(exe_path, rt(SMALL))
        check('off', p.frame(), False, 0)
        p.press(esi=0x48)
        check('other key', p.frame(), False, 0)
        p.press(ecx=0x40000000)
        check('auto-repeat', p.frame(), False, 0)
        p.press()
        check('on: first frame works it out', p.frame(), True, 1)
        check('on: static camera replays', p.frame(), True, 0)
        check('on: static again', p.frame(), True, 0)
        p.put('view+78', 3232)
        check('scrolled one tile', p.frame(), True, 1)
        check('scrolled, static', p.frame(), True, 0)
        p.put('view+7c', 840)
        check('scrolled down', p.frame(), True, 1)
        p.put('view+90', 1); p.put('view+88', 22); p.put('view+8c', 52)
        check('zoomed out', p.frame(), True, 1)
        p.put('orient', 6)
        check('rotated', p.frame(), True, 1)
        p.put('win+54', 0x565)
        check('pixel format changed', p.frame(), True, 1)
        p.put('view+94', 1)
        check('row bias on', p.frame(), True, 1)
        p.put('flatA', 0)
        check('left flattened view', p.frame(), False, 0)
        p.put('view+78', 3264)
        check('scrolled while hidden', p.frame(), False, 0)
        p.put('flatA', 1)
        check('back to flattened view', p.frame(), True, 1)
        check('flattened, static', p.frame(), True, 0)
        p.put('vflag', 0)
        check('V view', p.frame(), False, 0)
        p.put('vflag', 1)
        check('out of V view', p.frame(), True, 0)
        p.screen(0x0E)
        check('editor build menu keeps it', p.frame(), True, 0)
        p.screen(0x29)
        check('main menu turns it off', p.frame(), False, 0)
        p.press()
        check('on again, same view', p.frame(), True, 0)
        p.press()
        check('off again', p.frame(), False, 0)
        p.put('view+78', 3296)
        p.press()
        check('on again, moved while off', p.frame(), True, 1)

        print('  -- editor only')
        p = Pair(exe_path, rt(SMALL, gm=3), {'outside_editor': False})
        p.press()
        check('key ignored outside the editor', p.frame(), False, 0)
        p.put('gm', 1)
        p.press()
        check('key works in the editor', p.frame(), True, 1)
        p.put('gm', 3)
        check('left the editor', p.frame(), False, 0)
        p.put('gm', 1)
        check('back in, stays off', p.frame(), False, 0)

        print('  -- register and memory transparency with the overlay off')
        h = Host(NEW, exe_path, rt(SMALL))
        h.m.write_log = []
        n = h.frame()
        print('  %-4s off costs %d instructions, writes %d' % (
            'ok' if n == 5 and not h.m.write_log else 'FAIL', n, len(h.m.write_log)))
        failures += not (n == 5 and not h.m.write_log)

    print('\n%d failures, %.0fs' % (failures, time.time() - started))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
