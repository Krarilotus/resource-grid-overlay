# Resource Grid Overlay

Draws the AI's resource grid over the terrain in the map editor. **Alt + G** switches it
on and off.

## The resource grid

The AI does not pick a spot for a quarry, an iron mine, a pitch rig or a woodcutter's
hut tile by tile. It keeps an 80 x 80 array of records, one per **5 x 5 block of tiles**,
counting the boulders, iron, oil, trees, marsh, buildings and height spread inside each
block, and every resource-building decision it makes is a search over those blocks.

That is why the same amount of stone can be worth very different things to an AI
depending on how it lines up: a patch that sits inside one block gives that block a high
count, while the same patch spread across four block corners gives four mediocre ones.
The overlay draws every block edge as a two-pixel line so you can lay resources out
against the grid the AI actually reads.

## Keep rotation boundaries

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

## Iron mine footprint

Each block also gets its iron mine footprint marked in red. The AI asks for a block and
then puts the mine flat in that block's low corner - no shuffling about, unlike the
quarry, which tries nine positions around the corner - so the 4 x 4 footprint is always
in the same place in the block, and the last row and column of the block stay empty.

Only the two far edges are drawn, meeting at the footprint's far corner; the other two
are the grid lines themselves, so together they close the box. A marker whose corner
falls partly off the screen is left out rather than cut short, so one may be missing
right at the edge of the view.

The keep rotation boundaries are **cyan** by default so they do not clash with the red.

## Ground height

The lines lie on one height, because a flat grid has to. The height they use is the one
the game levels every tile to in its **flattened view** - what spacebar toggles in the
map editor - so they sit on ordinary flat ground, and in the flattened view they line up
everywhere. Over a hill or a dip the terrain is drawn above or below that plane, and the
lines stay where the ground would be if it were flat.

**Only in flattened view** is on by default, so the overlay appears in the flattened view
and stays hidden both in the normal view and in the view the V key turns on - the lines
only tell the whole truth where the ground is level. Turn it off to see them over real
terrain as well.

## Notes

* The overlay belongs in the map editor, but **Also outside the map editor** is on by
  default so the lines can be checked against a real map in a normal game. Turn it off
  to keep the overlay to the editor.
* It works at both zoom levels and at all four map rotations.
* Leaving the editor switches it off, so entering the editor always starts clean.
* Nothing is written to the map. The lines are drawn onto the frame after the terrain,
  the buildings and the map overlays, and are gone the moment you switch them off.
* The key can be changed in the settings. Every combination offered there does nothing
  in the game, so the overlay key never sets off a second action as well.
