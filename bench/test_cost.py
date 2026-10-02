"""What a frame with the overlay on costs, at a resolution people actually play at.

Counts instructions executed inside the hook, for the build under test and for 1.0.0, and
checks the two still draw the same pixels. 1.0.0 clipped every line in lua each frame and
handed each one to `PencilRenderCore::drawLine`, which calls a plot routine per pixel; this
build keeps the lines until the view changes and writes the pixels itself. The numbers are
instruction counts, not time - the real gap is wider, because the pencil's plot routine also
re-derives the address with a `mul` on every pixel.
"""
import sys, time
from host import EXT_PATH
from test_overlay import Pair

VIEWS = [
    # viewport fields as renderMap leaves them at 1920x1080: tiles per row and rendered rows
    ('1920x1080 zoomed in', {'view+88': 60, 'view+8c': 135}),
    ('1920x1080 zoomed out', {'view+90': 1, 'view+88': 130, 'view+8c': 336}),
]


def main():
    bad = 0
    for name, runtime in VIEWS:
        started = time.time()
        pair = Pair(EXT_PATH, runtime)
        pair.press()
        first = pair.frame()
        again = pair.frame()
        same = first['same'] and again['same']
        bad += not same
        print('%-22s same pixels=%-5s %d px | 1.0.0 %d instr, %d calls out of lua'
              ' | now %d instr first frame, %d static (lua calls %d then %d) | %.0fs'
              % (name, same, first['painted'], first['old'], pair.old.exposed_calls,
                 first['new'], again['new'], first['lua'], again['lua'],
                 time.time() - started), flush=True)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
