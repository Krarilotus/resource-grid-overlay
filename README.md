# Resource Grid Overlay

> **This module now lives in Map Editor Improvements.** The resource grid, its options and the
> bench below moved into [Map Editor Improvements](https://github.com/Monsterfisch/MapEditorImprovements)
> (from version 1.0.65), as its "Resource grid" settings group, so one module owns the map
> editor's drawing and input. Proposed in [Map Editor Improvements PR #3](https://github.com/Monsterfisch/MapEditorImprovements/pull/3).
>
> - Use Map Editor Improvements instead of this module. While both are turned on, Map Editor
>   Improvements leaves the grid to this module and says so in the log.
> - Settings are not taken over: the options have new names there
>   (`map-editor-improvements.grid.*` instead of `resource-grid-overlay.overlay.*` and
>   `.tune.*`). If you changed them, set them again; the defaults are the same.
> - With a Custom Hotkeys version that lets modules register actions, the toggle can be rebound
>   there. Without it, Alt + G works as before.
>
> The code below stays as the last stand-alone release. Credits: Monsterfish (author), merged
> with Heroesflorian's agreement as co-author of Map Editor Improvements.

A UCP3 module for Stronghold Crusader and Stronghold Crusader Extreme. It draws the grid the
AI reads when it looks for places to put its resource buildings - 5 x 5 blocks of tiles, not
single tiles - over the terrain in the map editor, together with the four lines where a keep's
rotation changes and the tiles an iron mine would cover in each block. **Alt + G** switches it
on and off.

## What it does

Draws the AI's resource grid over the terrain in the map editor. **Alt + G** switches it
on and off.

### The resource grid

The AI does not pick a spot for a quarry, an iron mine, a pitch rig or a woodcutter's
hut tile by tile. It keeps an 80 x 80 array of records, one per **5 x 5 block of tiles**,
counting the boulders, iron, oil, trees, marsh, buildings and height spread inside each
block, and every resource-building decision it makes is a search over those blocks.

That is why the same amount of stone can be worth very different things to an AI
depending on how it lines up: a patch that sits inside one block gives that block a high
count, while the same patch spread across four block corners gives four mediocre ones.
The overlay draws every block edge as a two-pixel line so you can lay resources out
against the grid the AI actually reads.

### Keep rotation boundaries

The overlay also draws the four lines where the **keep rotation** changes. When an AI's
keep is placed, the game takes the direction from the keep to the centre of the map,
rounds it to one of four quarters, and builds the whole AIV turned to match. Move a keep
across one of these lines and the same AIV comes out facing a different way - walls,
gatehouses and industry all swing round with it.

The four lines meet near the centre of the map and run out to the edge at a 1 to 2
slope. The game's own boundary is a staircase that wanders up to about one tile either
side of the straight line drawn here, so a keep placed right on a line is a coin toss.

The game compares a keep against tile 200, 200, but the lines are drawn meeting at
203, 203, which is where they line up on the map. The likely reason is that the game
compares the keep's own anchor tile while what you line a keep up by is its middle.

They can be switched off, or given their own colour, in the settings.

### Iron mine footprint

Each block also gets its iron mine footprint marked in red. The AI asks for a block and
then puts the mine flat in that block's low corner - no shuffling about, unlike the
quarry, which tries nine positions around the corner - so the 4 x 4 footprint is always
in the same place in the block, and the last row and column of the block stay empty.

Only the two far edges are drawn, meeting at the footprint's far corner; the other two
are the grid lines themselves, so together they close the box. A marker whose corner
falls partly off the screen is left out rather than cut short, so one may be missing
right at the edge of the view.

The keep rotation boundaries are **cyan** by default so they do not clash with the red.

### Ground height

The lines lie on one height, because a flat grid has to. The height they use is the one
the game levels every tile to in its **flattened view** - what spacebar toggles in the
map editor - so they sit on ordinary flat ground, and in the flattened view they line up
everywhere. Over a hill or a dip the terrain is drawn above or below that plane, and the
lines stay where the ground would be if it were flat.

**Only in flattened view** is on by default, so the overlay appears in the flattened view
and stays hidden both in the normal view and in the view the V key turns on - the lines
only tell the whole truth where the ground is level. Turn it off to see them over real
terrain as well.

### Notes

* The overlay belongs in the map editor, but **Also outside the map editor** is on by
  default so the lines can be checked against a real map in a normal game. Turn it off
  to keep the overlay to the editor.
* It works at both zoom levels and at all four map rotations.
* Leaving the editor switches it off, so entering the editor always starts clean.
* Nothing is written to the map. The lines are drawn onto the frame after the terrain,
  the buildings and the map overlays, and are gone the moment you switch them off.
* Switched off, the overlay costs next to nothing. Switched on, the lines are only worked
  out again when the camera, zoom or rotation changes, and drawing them takes about a
  seventh of the work it did in 1.0.0, with exactly the same pixels on screen.
* The key can be changed in the settings. Every combination offered there does nothing
  in the game, so the overlay key never sets off a second action as well.
## What is in here

| Folder | |
|---|---|
| `module/` | the module itself - this is the source of truth, edited in place |
| `bench/` | the emulator bench: the module's own Lua runs against the real exe image, its assembly is assembled with UCP's own fasm.dll and then executed, together with the game's own line drawer |
| `bench/reference-1.0.0/` | the module as 1.0.0 shipped it, which drew through the game's pencil; the bench holds this build to the same pixels |
| `tools/publish.py` | copies `module/` into the game's module folder under a new version |
| `tools/package.py` | packs `module/` into `dist/<name>-<version>.zip`, the file a release is uploaded with |

## Working on it

1. Edit under `module/`.
2. Run the bench until it is green: `cd bench && python test_overlay.py` (every zoom level and
   map rotation, camera edges and off-map cameras, both pixel formats, each option and the
   hidden tuning values, and a frame-by-frame session: scrolling, zooming, rotating, the
   flattened and V views, leaving the editor, menus), on both executables. `python
   test_cost.py` prints what a frame costs at 1920x1080.
3. `python tools/publish.py --bump` - raises the last version slot and copies the module to
   `ucp/modules/resource-grid-overlay-<version>`, leaving the build before it installed and
   clearing anything older. Do this with the game closed.
4. In the UCP GUI press F5, then apply.
5. Commit and tag: `git commit -am "<version> - <what changed>" && git tag v<version>`.
6. `python tools/package.py`, then `gh release create v<version> dist/resource-grid-overlay-<version>.zip`.

The bench needs Python with `lupa`, `capstone`, `pefile` and `keystone-engine`, and a 32-bit
PowerShell for fasm.dll; it reads the executables from the game folder named in `bench/shc.py`.
It gives each script 57600 bytes rather than UCP's own 64000, so anything that assembles here
has a tenth of that budget spare.

## How it works

* **The grid.** `AIVState` holds one `HeatMap` record per 5 x 5 block, 80 x 80 of them, and
  every resource-building decision is a search over those blocks - so the block edges are what
  a mapper needs to see. A patch of stone inside one block is worth more to the AI than the
  same patch spread over four.
* **Keep rotation.** `setKeepOffsetAndOrientation` takes the direction from the keep to the map
  centre, rounds it to a quarter and builds the whole AIV turned to match, which leaves four
  regions. The boundaries are drawn where they line up on the map, three tiles out from tile
  200, 200 - the game compares the keep's own anchor tile, a mapper lines up its middle.
* **Iron mines.** The AI puts a mine flat in the low corner of the block it picked, with no
  candidate offsets, so the footprint is in the same place in every block. Only its two far
  edges are drawn; the grid lines close the box.
* **Where it sits on screen.** One linear transform per map rotation, derived from the tile
  loop and `screenPointToTileNumber` and halved exactly when zoomed out, so a straight line in
  tile space stays straight on screen and only its ends need transforming. The lines lie at the
  height the game levels the map to in its flattened view.
* **What it costs.** The frame hook is assembly: with the overlay off, a compare and a jump;
  with it on, it checks the gates and compares the values the picture depends on - rotation,
  zoom, camera, rendered area, pixel format - against the ones it last drew for, and only calls
  into lua when one has changed. Lua clips the lines and leaves a packed list behind, which the
  assembly replays every other frame. The pixels go into the map surface through the module's
  own Bresenham loop, which follows `PencilRenderCore::drawLine` rule for rule and does both
  rows of the two-pixel line in one pass, instead of the game's plot-per-pixel call.

Every address is found by pattern scan or read from the instruction that uses it, and a pattern
another module has already overwritten disables the part that needs it instead of taking the
game down.
