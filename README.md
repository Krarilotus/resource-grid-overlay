# Resource Grid Overlay

A UCP3 module for Stronghold Crusader and Stronghold Crusader Extreme. It draws the grid the
AI reads when it looks for places to put its resource buildings - 5 x 5 blocks of tiles, not
single tiles - over the terrain in the map editor, together with the four lines where a keep's
rotation changes and the tiles an iron mine would cover in each block. **Alt + G** switches it
on and off.

What the module does, in plain English, is in `module/locale/description-en.md`.

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
