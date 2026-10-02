-- Resource Grid Overlay
--
-- Draws the grid the AI uses to pick resource-gathering spots over the terrain, toggled
-- with Alt + G. It belongs in the map editor, but the "also outside the map editor"
-- option lets it run in a normal game as well, which is how the lines get checked
-- against real terrain.
--
-- What is on screen
--
--   * The resource grid itself. `AIVState` carries `HeatMap heatMaps[80][80]`, one
--     record per 5 x 5 block of tiles - `incrementStructureHeatMapTile` divides both
--     tile coordinates by 5 before indexing it - and every "where does a quarry / iron
--     mine / woodcutter's hut go" decision (`findAppropriateGridLocationForResourceType
--     Building`, `findAppropriateWoodCutterGridLocation`, `recomputeAIAvailableGridTiles`)
--     counts boulders, iron, oil and trees per block. So the block edges, every fifth
--     tile boundary in both map axes, are what a mapper needs to see.
--
--   * The keep rotation boundaries. `setKeepOffsetAndOrientation` takes the direction
--     from the keep to the map centre (200, 200), rounds it down to an even one of the
--     eight compass directions and swaps east with west, which leaves four regions.
--     A keep placed in each of them has its whole AIV built at a different rotation.
--     The four boundaries meet at the centre tile and run out to the map edge at a 1:2
--     slope; the real boundary is a staircase that wanders up to about one tile either
--     side of the straight line drawn here.
--
-- How it is drawn
--
--   Three patch points, all located by pattern scan, all valid for the plain and the
--   Extreme executable:
--
--   * The one `call renderMap` site. The absolute `mov eax, [...]` five bytes past the
--     floater pass that follows it is replaced by a jump into this module's assembly,
--     which runs it again on the way back, so the hook runs once per frame with the
--     terrain, the buildings and the map overlays already on the map surface. That call
--     site is only reached when `isInGameScreen` says the player is on the map, so the
--     hook never runs in a menu.
--
--   * The WM_SYSKEYDOWN branch of the window procedure. Alt + letter never reaches the
--     ordinary WM_KEYDOWN key table, it arrives as WM_SYSKEYDOWN and goes through a
--     second, much smaller jump table. G sits on the do-nothing case there in both
--     executables, so Alt + G is free and nothing has to be suppressed.
--
--   * `requestScreenChange`, three bytes in, where EBP already holds the screen the
--     game is about to move to. Leaving the map puts the overlay away. This one is
--     optional: `resolution-based-zoom` can hold the same six bytes, and whichever
--     module scans first wins while the other logs a warning and does without.
--
--   The lines lie on one height, because a flat grid has to. The one they lie on is the
--   height `renderMap` levels every tile to in its flattened view - the one the editor's
--   spacebar turns on - which is the map's normal ground, so the grid sits on ordinary
--   flat terrain and matches the flattened view exactly. That height is read out of the
--   instruction that sets it rather than hardcoded.
--
-- Keeping it cheap
--
--   The frame hook is assembly and only calls into lua when there is something new to
--   work out. Switched off, the overlay costs one compare a frame. Switched on, the hook
--   checks the same things the lua used to - map editor, flattened view, V view - and
--   then compares the few values the picture depends on (map rotation, zoom level,
--   camera, rendered area, pixel format) with the ones it last drew for. Only when one of
--   them has changed does it call lua, which clips every line to the new view and writes
--   what is left into a short list. Every other frame the assembly replays that list.
--
--   The pixels are put down by the module's own line loop, straight into the map surface.
--   It is Bresenham with the same start point, error term and tie-break as
--   `PencilRenderCore::drawLine`, so it sets exactly the pixels the game's drawer would,
--   and it does both rows of the two-pixel line in the same pass. The game's drawer calls
--   a plot function for every pixel and works the address out again each time, and at a
--   wide resolution zoomed out that was most of what the overlay cost.
--
--   Nothing reaches the surface unclipped: the lines are clipped in lua to the part of
--   the surface this frame redrew, and a mine marker whose corners leave that box is
--   dropped. Nothing is clamped, so nothing gets bent.

---------------------------------------------------------------------------------------
-- Map and surface geometry
---------------------------------------------------------------------------------------

-- The AI's resource grid: one cell per 5 x 5 tiles, 80 x 80 cells on a 400 x 400 map.
local GRID_STEP = 5
local MAP_TILES = 400

-- Where an iron mine lands inside a block. `aiPlaceIronMine` asks
-- `findAppropriateGridLocationForResourceTypeBuilding` for a block and then places the
-- mine at tile (5*gridX, 5*gridY) flat - no candidate offsets, unlike the quarry, which
-- walks a ring of nine - so the footprint always sits flush in the low corner of the
-- block and leaves the last row and column of the block empty.
--
-- Only the two far edges are drawn, meeting at the footprint's far corner: the other two
-- are the grid lines themselves, so together they close the box.
--
-- These have to be real per-block segments rather than lines running the width of the
-- map - a continuous lattice is a different picture, it joins every block to the next.
-- That is thousands of short segments a frame at a wide resolution zoomed out, far too
-- many to push through lua one at a time, so the loop that emits them is assembly: it
-- walks the visible blocks, works each corner out by adding a constant step, and draws
-- the two edges. A block whose marker is not wholly inside the clip box is skipped
-- rather than clipped, which costs a marker at the very edge of the screen and saves
-- clipping arithmetic on every one of them.
local MINE_FOOTPRINT = 4

-- A "400 x 400" map holds 80400 tiles, laid out as a diamond inside the 400 x 400
-- coordinate square: row y runs from x = 199-y to x = 200+y and back again. In terms of
-- d = x - y and s = x + y that diamond is exactly the rectangle
-- d in [-200, 200], s in [199, 599] (401 * 200 + 400 * 201 = 80400 tiles), and the
-- corners of those tiles reach one step further out.
local CORNER_D_MIN, CORNER_D_MAX = -201, 201
local CORNER_S_MIN, CORNER_S_MAX = 199, 601

-- Where `renderMap` puts a tile on the map surface. It starts every row at x = 0x46
-- (+0x10 on every other row), steps 0x20 per tile along the row and 8 down per row, and
-- starts from the grid cell (viewportX/32, viewportY/16).
--
-- **Which way the map is turned matters.** That loop is identical whichever way it is;
-- what changes is which of the four blocks of `screenPointToTileNumber` it walks, and
-- each block lays the diamond along a different pair of axes - the rows of block 0 are
-- lines of constant s, of block 1 lines of constant d, and so on round the four
-- quarter turns. Writing d = x-y and s = x+y, and unrolling the loop for each block,
-- the point the four tiles around corner (cx, cy) share comes out as
--   P.x = (constX - 32*cameraCell)              + xd*d + xs*s
--   P.y = (rowBias + 8 + constY - 16*cameraRow) + yd*d + ys*s
-- with the coefficients in ORIENTATIONS below. Every one of them is linear in d and s,
-- so a straight line in tile space stays a straight line on screen at any rotation and
-- only its two endpoints have to be transformed.
--
-- Getting this wrong is not always obvious: the grid is its own mirror image, so it
-- still looks plausible at 180 degrees while the keep rotation boundaries, which are
-- not symmetric, come out visibly wrong.
--
-- **Zoomed out** (`[vp+0x90] != 0`) the tile loop is unchanged - same 0x20 per tile, same
-- 8 per row - and the halving happens in the blitter instead: it lands the tile at
-- `surface + (drawX & ~1) + (drawY >> 1)*0x1FB0`, i.e. at pixel `(drawX/2, drawY/2)`,
-- and the viewport asks for twice as many tiles and rows to fill the screen. Every
-- number above is even, so the whole transform survives being divided by two exactly;
-- that is the only difference, and getting it wrong makes the grid keep its zoomed-in
-- size and scroll at twice the speed of the map.
-- Verified against a re-simulation of the table builder and both render loops: the four
-- blocks each come out a permutation of all 80400 tiles, and the transform matches every
-- tile the game places, at every rotation and both zoom levels.
local ORIENTATIONS = {
  [0] = { constX = 3350, xd = 16, xs = 0, constY = -1592, yd = 0, ys = 8 },
  [6] = { constX = 9750, xd = 0, xs = -16, constY = 1608, yd = 8, ys = 0 },
  [4] = { constX = 3350, xd = -16, xs = 0, constY = 4808, yd = 0, ys = -8 },
  [2] = { constX = -3050, xd = 0, xs = 16, constY = 1608, yd = -8, ys = 0 },
}
local DEFAULT_ORIENTATION = 0

local ROW_PITCH = 8
local TILE_PITCH = 32
local FIRST_TILE_SURFACE_X = 0x46
local ZOOMED_OUT_DIVISOR = 2

-- Terrain height. The blitter puts each tile at `rowY - heightOffset[tileHeight]`, so a
-- flat overlay has to choose a height to lie at. `renderMap`'s flattened branch - the one
-- the editor's spacebar turns on - forces that offset to a single constant for every
-- tile, and that constant is the normal ground the whole map is levelled to, so it is
-- exactly the height the lines want. It is read out of the instruction that sets it
-- rather than hardcoded, and only used as a fallback here.
local DEFAULT_GROUND_HEIGHT = 8

-- The map surface is 0x1FB0 bytes (4056 pixels) per line, and the game's pencil only
-- ever draws inside that; the clip box below keeps to the same range. Two pixels are left
-- spare at the bottom for the second row of the line.
local SURFACE_WIDTH = 4056
local SURFACE_HEIGHT = 4056
local SURFACE_PITCH = 0x1FB0
local LINE_THICKNESS_SPARE = 2

-- `renderMap` renders `[viewport+0x8C] + 0x2A` rows minus the first-row bias, and
-- `[viewport+0x88]` (+1 on the longer rows) tiles per row. Anything outside that is
-- surface the frame did not touch.
local EXTRA_RENDERED_ROWS = 0x2A

-- Viewport (ViewportRenderState) field offsets.
local VIEWPORT_X = 0x78
local VIEWPORT_Y = 0x7C
local VIEWPORT_TILES_PER_ROW = 0x88
local VIEWPORT_ROW_COUNT = 0x8C
local VIEWPORT_ZOOMED_OUT = 0x90
local VIEWPORT_ROW_BIAS_ACTIVE = 0x94

-- Window/graphics struct: the 16 bit pixel layout DirectDraw handed the game, and the
-- map surface pointer, which the pencil reads from +0xD8.
local COLOR_BIT_MODE_IN_STRUCT = 0x54
local COLOR_MODE_565 = 0x565
local MAP_SURFACE_POINTER_IN_STRUCT = 0xD8

-- `GameMode2`. 1 is the map editor.
local GAME_MODE_EDITOR = 1

-- Screen ids that still count as "on the map" for the purpose of keeping the overlay
-- switched on: the three `isInGameScreen` accepts, plus the map editor's own properties
-- screen, which the editor steps through without leaving the map behind.
local MAP_EDITOR_PROPERTIES_SCREEN = 0x11

-- The four keep rotation boundaries, in tile-corner coordinates. They start at the four
-- corners of the centre tile (200, 200) and end where the staircase they approximate
-- runs off the map. Moving the origin translates all four.
local ROTATION_ORIGIN = 200

-- Where they are actually drawn. `setKeepOffsetAndOrientation` compares the keep against
-- tile (200, 200), and that is genuinely the centre of the playable area at every map
-- size, but on the map the boundaries line up three tiles further out, so that is what
-- gets drawn. This offset is measured against the game rather than derived: the likely
-- reason is that the coordinate the game compares is the keep's own anchor tile while
-- what a mapper lines a keep up by is its middle, which for a keep's footprint is about
-- three tiles along both axes.
local DEFAULT_ROTATION_ORIGIN = 203
local ROTATION_BOUNDARIES = {
  { 201, 201, 267, 333 },  -- north / east
  { 200, 201, 67, 267 },   -- north / west
  { 201, 200, 334, 134 },  -- east / south
  { 200, 200, 134, 66 },   -- south / west
}

-- Line styles, which index the colour table the assembly reads.
local STYLE_GRID = 1
local STYLE_ROTATION = 2
local STYLE_MINE = 3

---------------------------------------------------------------------------------------
-- Shared state between lua and the assembly
---------------------------------------------------------------------------------------

-- One block of memory holds everything both sides read. The lua writes the switches once,
-- flips `shown` from the key and screen hooks, and fills in the colours, the line list
-- and the marker parameters whenever the frame hook asks it to; the assembly keeps the
-- view values it last drew for, so it can tell when to ask.
local SHOWN = 0
local CACHE_VALID = 4            -- 0 makes the next frame work everything out again
local EDITOR_ONLY = 8
local FLATTENED_ONLY = 12
local HIDE_IN_V_VIEW = 16
local VIEW_KEY = 20              -- the eight values below, in this order
local VIEW_KEY_ORIENTATION = 20
local VIEW_KEY_ZOOMED_OUT = 24
local VIEW_KEY_ROW_BIAS = 28
local VIEW_KEY_VIEWPORT_X = 32
local VIEW_KEY_VIEWPORT_Y = 36
local VIEW_KEY_TILES_PER_ROW = 40
local VIEW_KEY_ROW_COUNT = 44
local VIEW_KEY_COLOUR_MODE = 48
local SEGMENT_COUNT = 52
local STYLE_COLOURS = 56         -- one int per style index, 0 unused
local MARKER_BLOCK = 72          -- the marker parameters, see buildDrawer
local MARKER_PARAMETER_COUNT = 17
-- Read in place of a flag whose scan failed.
local ALWAYS_ZERO = MARKER_BLOCK + 4 * MARKER_PARAMETER_COUNT
-- Two ints per line, see writeSegments; the block ends with it.
local SEGMENT_LIST = ALWAYS_ZERO + 4

-- A clipped line is packed into two ints for the assembly, x in the low 12 bits and y
-- in the next 12 - the clip box keeps both inside 0..4055 - and the style in the top
-- byte of the first.
local COORDINATE_RANGE = 0x1000
local STYLE_SHIFT = 0x1000000

---------------------------------------------------------------------------------------
-- Patterns
---------------------------------------------------------------------------------------

-- The single `call renderMap` site and the floater pass behind it:
--   mov [DAT], ebp / call renderMap / call renderFloaters / mov eax, [...] /
--   mov ecx, [...] / push eax / push ecx / mov ecx, viewport / call ...
local RENDER_MAP_CALL_AOB = "89 2D ? ? ? ? E8 ? ? ? ? E8 ? ? ? ? A1 ? ? ? ? 8B 0D ? ? ? ? "
    .. "50 51 B9 ? ? ? ? E8 ? ? ? ?"
local OFFSET_AFTER_RENDER = 16      -- the absolute `mov eax, [...]`, jumped out of
local OPCODE_MOV_EAX_ABSOLUTE = 0xA1
local SIZE_AFTER_RENDER = 5
local OFFSET_VIEWPORT = 30          -- operand of `mov ecx, viewport`

-- Head of `focusOnTile`, which picks its block of `screenPointToTileNumber` from the map
-- orientation the same way `renderMap` does:
--   mov eax,[mapOrientation] / test eax,eax / push ebx,ebp,esi,edi / mov ebp,ecx /
--   mov edi,8 / je / cmp eax,6 / jne / mov edi,0x13A18 / ...
local MAP_ORIENTATION_AOB = "A1 ? ? ? ? 85 C0 53 55 56 57 8B E9 BF 08 00 00 00 74 22 "
    .. "83 F8 06 75 07 BF 18 3A 01 00 EB 16 83 F8 04 75 07 BF 28 74 02 00"
local OFFSET_MAP_ORIENTATION = 1

-- `PencilRenderCore::setupPencilSurface`: picks the map surface when surfaceTarget is
-- set, and with it the 0x1FB0 byte pitch. Its first operand is the map surface pointer,
-- which sits at +0xD8 in the window/graphics struct.
local PENCIL_SURFACE_AOB = "8B 41 0C 85 C0 8B 15 ? ? ? ? 75 06 8B 15 ? ? ? ? 85 C0 "
    .. "89 51 04 74 08 C7 41 08 B0 1F 00 00"
local OFFSET_MAP_SURFACE_POINTER = 7

-- `GameMode2 == 1` guard in the "is the player looking at the map" helper:
--   cmp [gameMode2],1 / jne / push 4 / mov ecx,... / call / ret
local GAME_MODE_AOB = "83 3D ? ? ? ? 01 75 0D 6A 04 B9 ? ? ? ? E8 ? ? ? ? C3"
local OFFSET_GAME_MODE = 2

-- `renderMap`'s prologue, where the two flags that together mean "the map is being shown
-- flattened" are tested:
--   cmp [flattenA],edi / je / cmp [flattenB],edi / je / mov dword [esp+0x24],1
local FLATTENED_AOB = "39 3D ? ? ? ? 74 10 39 3D ? ? ? ? 74 08 C7 44 24 24 01 00 00 00"
local OFFSET_FLATTEN_A = 2
local OFFSET_FLATTEN_B = 10

-- The flattened branch of the tile loop, which forces every tile's height offset to the
-- single ground level the whole map is levelled to:
--   cmp [viewport+0xBC],esi / mov dword [tileHeightOffset],8 / je / mov .. / mov ..
local GROUND_HEIGHT_AOB = "39 B3 BC 00 00 00 C7 05 ? ? ? ? 08 00 00 00 74 11 "
    .. "89 35 ? ? ? ? 89 35 ? ? ? ?"
local OFFSET_GROUND_HEIGHT = 12

-- The map editor's other view, the one the V key turns on. The key handler only queues
-- the mode on the command object; the flag the renderer actually reads is a field of that
-- object at +0x5548C4 (VAN 0x1FE7ACC / EXT 0x2A7AFCC), which `renderMap` consults eleven
-- times. Take the object from the handler:
--   push 3 / mov ecx, commandObject / call / mov [DAT], ebp / jmp tail
--
-- **It reads the other way round to what the name suggests.** Every one of those eleven
-- tests is `cmp [flag], 0 / je skip` guarding the work that draws the things standing on
-- the map, so **non-zero is the ordinary view and zero is the stripped-down one**. Read
-- it the wrong way and the overlay disappears everywhere, because the flag is non-zero
-- almost all the time.
local VIEW_MODE_AOB = "6A 03 B9 ? ? ? ? E8 ? ? ? ? 89 2D ? ? ? ? E9"
local OFFSET_COMMAND_OBJECT = 3
local VIEW_FLAG_IN_COMMAND_OBJECT = 0x5548C4

-- The WM_SYSKEYDOWN arm of the window procedure. ESI is the virtual-key code and ECX is
-- still the lParam the procedure loaded on entry:
--   mov esi,[esp+0x64] / lea eax,[esi-0xD] / cmp eax,0xD1 / mov ebp,1 / mov [DAT],ebp /
--   ja tail / movzx eax, byte [eax+caseTable] / jmp dword [eax*4+addressTable]
local SYS_KEY_DISPATCH_AOB = "8B 74 24 64 8D 46 F3 3D D1 00 00 00 BD 01 00 00 00 "
    .. "89 2D ? ? ? ? 0F 87 ? ? ? ? 0F B6 80 ? ? ? ? FF 24 85 ? ? ? ?"
local OFFSET_SYS_KEY_JUMP = 36
local SIZE_SYS_KEY_JUMP = 7

-- `isInGameScreen`: the three immediates are the screen ids that mean "on the map".
local IN_GAME_SCREEN_AOB = "8B 41 0C 83 F8 0C 74 0D 83 F8 0E 74 08 83 F8 10 74 03 "
    .. "33 C0 C3"
local OFFSETS_IN_GAME_SCREEN_IDS = { 5, 10, 15 }

-- `requestScreenChange`, three bytes in, where EBP already holds the screen the game is
-- about to move to and nothing has been written yet.
local SCREEN_CHANGE_AOB = "83 FD 17 56 8B F1 75 05 BD 29 00 00 00 8B 44 24 10 53 57 "
    .. "89 6E 18"
local SIZE_SCREEN_CHANGE_HOOK = 6

---------------------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------------------

-- Virtual-key code per choice name. Only keys that land on the do-nothing case of the
-- WM_SYSKEYDOWN table in both executables are offered, so Alt plus any of them has no
-- meaning of its own to take away.
local VIRTUAL_KEY_CODES = {
  letter_a = 0x41, letter_b = 0x42, letter_f = 0x46, letter_g = 0x47,
  letter_i = 0x49, letter_j = 0x4A, letter_l = 0x4C, letter_m = 0x4D,
  letter_n = 0x4E, letter_o = 0x4F, letter_p = 0x50, letter_s = 0x53,
  letter_w = 0x57, letter_y = 0x59, letter_z = 0x5A,
  f1 = 0x70, f2 = 0x71, f3 = 0x72, f4 = 0x73, f5 = 0x74, f6 = 0x75,
  f7 = 0x76, f8 = 0x77, f9 = 0x78,
  numpad_multiply = 0x6A, numpad_add = 0x6B, numpad_subtract = 0x6D,
  numpad_decimal = 0x6E, numpad_divide = 0x6F,
  insert = 0x2D, delete_key = 0x2E, home = 0x24, end_key = 0x23,
  page_up = 0x21, page_down = 0x22, caps_lock = 0x14,
}
local DEFAULT_KEY = "letter_g"

-- Colours as 8 bit per channel, resolved to the surface's own 16 bit layout at draw
-- time because the graphics replacer can be configured either way.
local COLOURS = {
  white = { 255, 255, 255 },
  red = { 255, 32, 32 },
  yellow = { 255, 224, 0 },
  cyan = { 0, 255, 255 },
  green = { 0, 255, 64 },
  magenta = { 255, 0, 255 },
  orange = { 255, 144, 0 },
  black = { 0, 0, 0 },
}
local DEFAULT_GRID_COLOUR = "white"
-- The mine footprint takes red, so the keep rotation boundaries move to cyan; two reds
-- on the same picture would be unreadable. Both are still free to change.
local DEFAULT_ROTATION_COLOUR = "cyan"
local DEFAULT_MINE_COLOUR = "red"

---------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------

-- Looked up once; the rebuild calls them a few hundred times.
local readInteger = core.readInteger
local writeInteger = core.writeInteger
local floor = math.floor
local min = math.min
local max = math.max

---Scan for an AOB the module can manage without. Other modules patch game code before
---this one runs, so a pattern that has been overwritten must disable the feature that
---needs it rather than take the game down at launch.
---@param pattern string
---@param purpose string what the address is for, for the log line
---@return number|nil address
local function scanOptional(pattern, purpose)
  local found, address = pcall(core.AOBScan, pattern)
  if not found or address == nil then
    log(WARNING, "resource-grid-overlay: could not find " .. purpose
      .. "; that part is disabled. Another module has probably patched it.")
    return nil
  end
  return address
end

---Read a pointer-sized value as the unsigned address it is.
---@param address number
---@return number
local function readAddress(address)
  return readInteger(address) & 0xFFFFFFFF
end

---Bit 30 of lParam is set when a key-down message is a hold-down auto-repeat.
---@param lParam number the ECX value at the dispatch site
---@return boolean
local function isAutoRepeat(lParam)
  if lParam < 0 then
    lParam = lParam + 0x100000000
  end
  return floor(lParam / 0x40000000) % 2 == 1
end

---Integer division that rounds towards zero, which is what the game's `cdq / and / sar`
---sequences do and what the viewport-to-grid-cell arithmetic has to match.
---@param value number
---@param divisor number
---@return number
local function truncatedDivide(value, divisor)
  if value < 0 then
    return -floor(-value / divisor)
  end
  return floor(value / divisor)
end

---Pack an 8 bit per channel colour into the surface's 16 bit layout.
---@param channels number[] red, green, blue in 0..255
---@param is565 boolean true for RGB 5-6-5, false for (A)RGB 1-5-5-5
---@return number
local function packColour(channels, is565)
  local red, green, blue = channels[1], channels[2], channels[3]
  if is565 then
    return floor(red / 8) * 0x800 + floor(green / 4) * 0x20
      + floor(blue / 8)
  end
  return floor(red / 8) * 0x400 + floor(green / 8) * 0x20
    + floor(blue / 8)
end

---Resolve a configured choice name against a table, falling back to a default.
---@param name string|nil
---@param table_ table
---@param defaultName string
---@param what string for the log line
---@return any
local function resolveChoice(name, table_, defaultName, what)
  local value = table_[name]
  if value == nil then
    if name ~= nil then
      log(WARNING, string.format(
        "resource-grid-overlay: unknown %s '%s', using '%s'.",
        what, tostring(name), defaultName))
    end
    value = table_[defaultName]
  end
  return value
end

---Assemble one script into an allocation of its own. UCP hands fasm a fixed 64 KB for
---the source, the symbols and the output together, and a script dense with labels uses
---a lot of it, so the drawing code is split into small scripts that reach each other by
---address, and each goes in without indentation, comments or constants it never uses.
---@param script string
---@param values table every constant any of the scripts uses
---@return number address of the script's first instruction
local function assemble(script, values)
  local lines = {}
  for rawLine in script:gmatch("[^\n]+") do
    local line = (rawLine:gsub(";.*", "")):match("^%s*(.-)%s*$")
    if line ~= "" then
      lines[#lines + 1] = line
    end
  end
  local body = table.concat(lines, "\n") .. "\n"
  local used = {}
  for name, value in pairs(values) do
    if body:find("%f[%w_]" .. name .. "%f[^%w_]") then
      used[name] = value
    end
  end
  return core.allocateAssembly(body, used)
end

-- `drawSegment(x1, y1, x2, y2, colour)`, cdecl, keeps ebx, esi, edi and ebp.
--
-- `PencilRenderCore::drawLine` unrolled for the map surface: the same Bresenham, stepping
-- from (x1, y1), taking the diagonal step only when the error term is above zero, with y
-- as the major axis exactly when dy > dx, as the game's own test has it. The game's
-- separate horizontal and vertical loops put down the same pixels as this one does with a
-- zero minor step, just in the other order, which one colour cannot show. Each step
-- writes the pixel and the one below it, which is the second line the two-pixel width
-- used to take.
local SEGMENT_SCRIPT = [[
  drawSegment:
    push ebp
    push ebx
    push esi
    push edi

    mov eax, dword [esp + 24]
    imul edi, eax, SURFACE_PITCH_VALUE
    add edi, dword [SURFACE_POINTER_ADDRESS]
    mov eax, dword [esp + 20]
    add edi, eax
    add edi, eax

    mov eax, dword [esp + 28]
    sub eax, dword [esp + 20]
    mov ebx, 2
    jge segmentRightward
    neg eax
    mov ebx, -2
  segmentRightward:
    mov ecx, dword [esp + 32]
    sub ecx, dword [esp + 24]
    mov edx, SURFACE_PITCH_VALUE
    jge segmentDownward
    neg ecx
    mov edx, -SURFACE_PITCH_VALUE
  segmentDownward:
    cmp ecx, eax
    jg segmentSteep

    lea esi, [ecx + ecx]
    mov ebp, esi
    sub ebp, eax
    push esi
    sub dword [esp], eax
    sub dword [esp], eax
    mov ecx, eax
    add edx, ebx
    jmp segmentStart

  segmentSteep:
    lea esi, [eax + eax]
    mov ebp, esi
    sub ebp, ecx
    push esi
    sub dword [esp], ecx
    sub dword [esp], ecx
    xchg ebx, edx
    add edx, ebx

  segmentStart:
    mov eax, esi
    movzx esi, word [esp + 40]
  segmentPixel:
    mov word [edi], si
    mov word [edi + SURFACE_PITCH_VALUE], si
    test ebp, ebp
    jle segmentStraight
    add edi, edx
    add ebp, dword [esp]
    sub ecx, 1
    jge segmentPixel
    jmp segmentEnd
  segmentStraight:
    add edi, ebx
    add ebp, eax
    sub ecx, 1
    jge segmentPixel
  segmentEnd:

    add esp, 4
    pop edi
    pop esi
    pop ebx
    pop ebp
    ret
]]

-- `drawSegmentList()`: every line lua left in the list, unpacked and drawn in order.
local SEGMENT_LIST_SCRIPT = [[
  drawSegmentList:
    push ebx
    push esi
    push edi
    mov esi, SEGMENT_LIST_ADDRESS
    mov edi, dword [SEGMENT_COUNT_ADDRESS]
  segmentsNext:
    test edi, edi
    jle segmentsDone
    mov eax, dword [esi]
    mov edx, dword [esi + 4]
    mov ecx, eax
    shr ecx, 24
    push dword [STYLE_COLOURS_ADDRESS + ecx*4]
    mov ecx, edx
    shr ecx, 12
    and ecx, 0xFFF
    push ecx
    and edx, 0xFFF
    push edx
    mov ecx, eax
    shr ecx, 12
    and ecx, 0xFFF
    push ecx
    and eax, 0xFFF
    push eax
    call DRAW_SEGMENT
    add esp, 20
    add esi, 8
    sub edi, 1
    jmp segmentsNext
  segmentsDone:
    pop edi
    pop esi
    pop ebx
    ret
]]

-- `drawMarkers()`: one "V" per block, the two far edges of the iron mine footprint.
-- Parameter block, by byte offset from MARKER_PARAMETERS:
--   0 countX      4 countY       8 originX     12 originY
--  16 stepX x    20 stepX y     24 stepY x     28 stepY y
--  32 far-cx x   36 far-cx y    40 far-cy x    44 far-cy y
--  48 clip left  52 clip right  56 clip top    60 clip bottom
--  64 colour
local MARKER_SCRIPT = [[
  drawMarkers:
    push ebp
    mov ebp, esp
    sub esp, 48
    push ebx
    push esi
    push edi

    mov ebx, MARKER_PARAMETERS
    mov eax, dword [ebx + 8]
    mov dword [ebp - 4], eax
    mov eax, dword [ebx + 12]
    mov dword [ebp - 8], eax
    mov eax, dword [ebx + 4]
    mov dword [ebp - 12], eax

  markerRow:
    cmp dword [ebp - 12], 0
    jle markersDone
    mov eax, dword [ebp - 4]
    mov dword [ebp - 16], eax
    mov eax, dword [ebp - 8]
    mov dword [ebp - 20], eax
    mov eax, dword [ebx]
    mov dword [ebp - 24], eax

  markerColumn:
    cmp dword [ebp - 24], 0
    jle markerRowNext
    mov esi, dword [ebp - 16]
    mov edi, dword [ebp - 20]

    mov eax, esi
    add eax, dword [ebx + 32]
    mov dword [ebp - 28], eax
    mov eax, edi
    add eax, dword [ebx + 36]
    mov dword [ebp - 32], eax

    mov eax, esi
    add eax, dword [ebx + 40]
    mov dword [ebp - 36], eax
    mov eax, edi
    add eax, dword [ebx + 44]
    mov dword [ebp - 40], eax

    mov eax, dword [ebp - 28]
    add eax, dword [ebx + 40]
    mov dword [ebp - 44], eax
    mov eax, dword [ebp - 32]
    add eax, dword [ebx + 44]
    mov dword [ebp - 48], eax

    mov eax, dword [ebx + 48]
    cmp dword [ebp - 28], eax
    jl markerSkip
    cmp dword [ebp - 36], eax
    jl markerSkip
    cmp dword [ebp - 44], eax
    jl markerSkip
    mov eax, dword [ebx + 52]
    cmp dword [ebp - 28], eax
    jg markerSkip
    cmp dword [ebp - 36], eax
    jg markerSkip
    cmp dword [ebp - 44], eax
    jg markerSkip
    mov eax, dword [ebx + 56]
    cmp dword [ebp - 32], eax
    jl markerSkip
    cmp dword [ebp - 40], eax
    jl markerSkip
    cmp dword [ebp - 48], eax
    jl markerSkip
    mov eax, dword [ebx + 60]
    cmp dword [ebp - 32], eax
    jg markerSkip
    cmp dword [ebp - 40], eax
    jg markerSkip
    cmp dword [ebp - 48], eax
    jg markerSkip

    push dword [ebx + 64]
    push dword [ebp - 48]
    push dword [ebp - 44]
    push dword [ebp - 32]
    push dword [ebp - 28]
    call DRAW_SEGMENT
    add esp, 20

    push dword [ebx + 64]
    push dword [ebp - 48]
    push dword [ebp - 44]
    push dword [ebp - 40]
    push dword [ebp - 36]
    call DRAW_SEGMENT
    add esp, 20

  markerSkip:
    mov eax, dword [ebp - 16]
    add eax, dword [ebx + 16]
    mov dword [ebp - 16], eax
    mov eax, dword [ebp - 20]
    add eax, dword [ebx + 20]
    mov dword [ebp - 20], eax
    sub dword [ebp - 24], 1
    jmp markerColumn

  markerRowNext:
    mov eax, dword [ebp - 4]
    add eax, dword [ebx + 24]
    mov dword [ebp - 4], eax
    mov eax, dword [ebp - 8]
    add eax, dword [ebx + 28]
    mov dword [ebp - 8], eax
    sub dword [ebp - 12], 1
    jmp markerRow

  markersDone:
    pop edi
    pop esi
    pop ebx
    mov esp, ebp
    pop ebp
    ret
]]

-- The frame hook, entered by a jump from the render call site. It leaves by running the
-- `mov eax, [ORIGINAL_OPERAND]` that jump replaced and jumping back behind it. All
-- registers are preserved; flags are not, and nothing after the call site reads them.
local FRAME_HOOK_SCRIPT = [[
  frameHook:
    cmp dword [OVERLAY_SHOWN], 0
    jne frameActive
  frameOriginal:
    mov eax, dword [ORIGINAL_OPERAND]
    jmp RETURN_ADDRESS

  frameActive:
    pushad

    cmp dword [OVERLAY_EDITOR_ONLY], 0
    je frameInPlace
    cmp dword [GAME_MODE_ADDRESS], GAME_MODE_EDITOR_VALUE
    je frameInPlace
    mov dword [OVERLAY_SHOWN], 0
    jmp frameDone

  frameInPlace:
    cmp dword [OVERLAY_FLATTENED_ONLY], 0
    je frameFlatOk
    cmp dword [FLATTEN_A_ADDRESS], 0
    je frameDone
    cmp dword [FLATTEN_B_ADDRESS], 0
    je frameDone
  frameFlatOk:
    cmp dword [OVERLAY_HIDE_IN_V_VIEW], 0
    je frameViewOk
    cmp dword [VIEW_FLAG_ADDRESS], 0
    je frameDone
  frameViewOk:

    ; The picture only depends on these eight values. Keep each one and note whether it
    ; moved; any change, or a cache that was never filled, means asking lua again.
    mov ebx, dword [CACHE_VALID_ADDRESS]
    mov esi, SOURCE_TABLE
    mov edi, VIEW_KEY_ADDRESS
    mov ecx, 8
  frameKeyNext:
    mov edx, dword [esi]
    mov eax, dword [edx]
    cmp eax, dword [edi]
    je frameKeySame
    mov dword [edi], eax
    xor ebx, ebx
  frameKeySame:
    add esi, 4
    add edi, 4
    sub ecx, 1
    jne frameKeyNext

    test ebx, ebx
    jne frameDraw
    call REBUILD_ADDRESS

  frameDraw:
    cmp dword [SURFACE_POINTER_ADDRESS], 0
    je frameDone
    call DRAW_SEGMENT_LIST
    call DRAW_MARKERS

  frameDone:
    popad
    jmp frameOriginal
]]

---Build the frame hook and the routines it draws with, callees first so each script can
---be handed the address of the ones it calls.
---@param values table the addresses and constants the scripts refer to
---@return number address of the frame hook
local function buildDrawer(values)
  values.DRAW_SEGMENT = assemble(SEGMENT_SCRIPT, values)
  values.DRAW_SEGMENT_LIST = assemble(SEGMENT_LIST_SCRIPT, values)
  values.DRAW_MARKERS = assemble(MARKER_SCRIPT, values)
  return assemble(FRAME_HOOK_SCRIPT, values)
end

---------------------------------------------------------------------------------------
-- The line list
---------------------------------------------------------------------------------------

---Screen offset, relative to the corner lattice origin, of the tile corner (cx, cy),
---for one map rotation. Every coefficient is even, so the zoomed-out halving is exact.
---@param cornerX number
---@param cornerY number
---@param transform table one entry of ORIENTATIONS
---@param divisor number 1 zoomed in, 2 zoomed out
---@return number offsetX, number offsetY
local function cornerOffset(cornerX, cornerY, transform, divisor)
  local d, s = cornerX - cornerY, cornerX + cornerY
  return (transform.xd * d + transform.xs * s) // divisor,
    (transform.yd * d + transform.ys * s) // divisor
end

---Every line the overlay can draw, as screen offsets from the corner lattice origin
---plus a style index. Built once per rotation and zoom level; only the origin moves as
---the camera scrolls.
---@param tune table the fine tuning settings
---@param transform table one entry of ORIENTATIONS
---@param divisor number 1 zoomed in, 2 zoomed out
---@return table[] lines each { offsetX1, offsetY1, offsetX2, offsetY2, style }
local function buildLines(tune, transform, divisor)
  local lines = {}

  local function add(x1, y1, x2, y2, style)
    local offsetX1, offsetY1 = cornerOffset(x1, y1, transform, divisor)
    local offsetX2, offsetY2 = cornerOffset(x2, y2, transform, divisor)
    lines[#lines + 1] = { offsetX1, offsetY1, offsetX2, offsetY2, style }
  end

  -- A grid line at a constant tile x runs along constant cx in the corner lattice, so
  -- d = cx - cy falls and s = cx + cy rises as cy grows. Clipping cy against the map's
  -- d and s bounds gives the part of the line that is over the map at all; lines whose
  -- range comes out empty sit entirely off the diamond and are left out.
  for cx = 0, MAP_TILES, GRID_STEP do
    local low = max(cx - CORNER_D_MAX, CORNER_S_MIN - cx)
    local high = min(cx - CORNER_D_MIN, CORNER_S_MAX - cx)
    if low < high then
      add(cx, low, cx, high, STYLE_GRID)
    end
  end

  for cy = 0, MAP_TILES, GRID_STEP do
    local low = max(cy + CORNER_D_MIN, CORNER_S_MIN - cy)
    local high = min(cy + CORNER_D_MAX, CORNER_S_MAX - cy)
    if low < high then
      add(low, cy, high, cy, STYLE_GRID)
    end
  end

  -- The four boundaries are a rigid cross, so moving the origin just translates them.
  if tune.withRotation then
    local shiftX = tune.originX - ROTATION_ORIGIN
    local shiftY = tune.originY - ROTATION_ORIGIN
    for _, boundary in ipairs(ROTATION_BOUNDARIES) do
      add(boundary[1] + shiftX, boundary[2] + shiftY,
        boundary[3] + shiftX, boundary[4] + shiftY, STYLE_ROTATION)
    end
  end

  return lines
end

---------------------------------------------------------------------------------------
-- Working the picture out for a view
---------------------------------------------------------------------------------------

---@class OverlayState
---@field control number address of the block shared with the assembly
---@field groundHeight number pixels the flattened map's ground sits above the row line
---@field tune table the fine tuning settings
---@field lines table<number, table[][]> line lists by orientation, then by zoom divisor
---@field nudgeX number[] screen nudge per style index
---@field nudgeY number[]
---@field palette table<boolean, number[]> packed colours per style, by "is 565"

---Clip every line to the box and write the survivors into the list the assembly draws.
---@param state OverlayState
---@param lines table[] the line list for the rotation and zoom level in effect
---@return number how many were written
local function writeSegments(state, lines, originX, originY,
    clipLeft, clipRight, clipTop, clipBottom)
  local list = state.control + SEGMENT_LIST
  local nudgeX, nudgeY = state.nudgeX, state.nudgeY
  local count = 0

  for index = 1, #lines do
    local line = lines[index]
    local style = line[5]
    local baseX = originX + nudgeX[style]
    local baseY = originY + nudgeY[style]
    local x1 = baseX + line[1]
    local y1 = baseY + line[2]
    local x2 = baseX + line[3]
    local y2 = baseY + line[4]
    local deltaX = x2 - x1
    local deltaY = y2 - y1

    -- Liang-Barsky, unrolled over the four edges. `enter` and `leave` are the fraction
    -- of the line that survives; `alive` goes false as soon as the two cross.
    local enter, leave, alive = 0.0, 1.0, true

    for edge = 1, 4 do
      local p, q
      if edge == 1 then
        p, q = -deltaX, x1 - clipLeft
      elseif edge == 2 then
        p, q = deltaX, clipRight - x1
      elseif edge == 3 then
        p, q = -deltaY, y1 - clipTop
      else
        p, q = deltaY, clipBottom - y1
      end

      if p == 0 then
        if q < 0 then
          alive = false
          break
        end
      else
        local ratio = q / p
        if p < 0 then
          if ratio > leave then
            alive = false
            break
          end
          if ratio > enter then
            enter = ratio
          end
        else
          if ratio < enter then
            alive = false
            break
          end
          if ratio < leave then
            leave = ratio
          end
        end
      end
    end

    if alive then
      local startX = floor(x1 + enter * deltaX + 0.5)
      local startY = floor(y1 + enter * deltaY + 0.5)
      local endX = floor(x1 + leave * deltaX + 0.5)
      local endY = floor(y1 + leave * deltaY + 0.5)
      -- The clip box already keeps every end inside the surface; this only guards the
      -- packing, which has twelve bits per coordinate.
      if startX >= 0 and startX < COORDINATE_RANGE and startY >= 0
          and startY < COORDINATE_RANGE and endX >= 0 and endX < COORDINATE_RANGE
          and endY >= 0 and endY < COORDINATE_RANGE then
        local slot = list + count * 8
        writeInteger(slot, startX + startY * COORDINATE_RANGE + style * STYLE_SHIFT)
        writeInteger(slot + 4, endX + endY * COORDINATE_RANGE)
        count = count + 1
      end
    end
  end

  return count
end

---Screen position of the tile corner (cx, cy) for one rotation and zoom level.
---@return number x, number y
local function cornerScreen(transform, divisor, originX, originY, cornerX, cornerY)
  local d, s = cornerX - cornerY, cornerX + cornerY
  return originX + (transform.xd * d + transform.xs * s) // divisor,
    originY + (transform.yd * d + transform.ys * s) // divisor
end

---Tile corner a screen point sits on, the inverse of the above. Exactly one of the two
---coefficients on each screen axis is non-zero, so each axis yields one of d and s.
---@return number cornerX, number cornerY
local function screenCorner(transform, divisor, originX, originY, x, y)
  local d, s
  if transform.xd ~= 0 then
    d = (x - originX) * divisor / transform.xd
  else
    s = (x - originX) * divisor / transform.xs
  end
  if transform.yd ~= 0 then
    d = (y - originY) * divisor / transform.yd
  else
    s = (y - originY) * divisor / transform.ys
  end
  return (s + d) / 2, (s - d) / 2
end

-- The map's four extreme corners and the clip box's four corners, walked by index so
-- the rebuild allocates nothing.
local MAP_CORNER_D = { CORNER_D_MIN, CORNER_D_MAX, CORNER_D_MIN, CORNER_D_MAX }
local MAP_CORNER_S = { CORNER_S_MIN, CORNER_S_MIN, CORNER_S_MAX, CORNER_S_MAX }

---Fill in the marker parameter block for this view, or leave it empty.
---@param state OverlayState
---@param transform table one entry of ORIENTATIONS
---@param divisor number 1 zoomed in, 2 zoomed out
---@param originX number corner lattice origin
---@param originY number
---@param colour number packed 16 bit colour
local function writeMarkers(state, transform, divisor, originX, originY,
    clipLeft, clipRight, clipTop, clipBottom, colour)
  local size = state.tune.mineSize

  -- One block step and the two footprint edges, in screen pixels. Every coefficient is
  -- even, so these divide exactly at both zoom levels.
  local stepXx = GRID_STEP * (transform.xd + transform.xs) // divisor
  local stepXy = GRID_STEP * (transform.yd + transform.ys) // divisor
  local stepYx = GRID_STEP * (transform.xs - transform.xd) // divisor
  local stepYy = GRID_STEP * (transform.ys - transform.yd) // divisor
  local farX = size * (transform.xd + transform.xs) // divisor
  local farY = size * (transform.yd + transform.ys) // divisor
  local sideX = size * (transform.xs - transform.xd) // divisor
  local sideY = size * (transform.ys - transform.yd) // divisor

  -- Only blocks over the map are worth walking. The map is a rectangle on screen, so
  -- intersecting the clip box with its four extreme corners is the whole test.
  local mapLeft, mapRight, mapTop, mapBottom
  for corner = 1, 4 do
    local d, s = MAP_CORNER_D[corner], MAP_CORNER_S[corner]
    local x = originX + (transform.xd * d + transform.xs * s) // divisor
    local y = originY + (transform.yd * d + transform.ys * s) // divisor
    mapLeft = mapLeft and min(mapLeft, x) or x
    mapRight = mapRight and max(mapRight, x) or x
    mapTop = mapTop and min(mapTop, y) or y
    mapBottom = mapBottom and max(mapBottom, y) or y
  end

  local left = max(clipLeft, mapLeft)
  local right = min(clipRight, mapRight)
  local top = max(clipTop, mapTop)
  local bottom = min(clipBottom, mapBottom)
  if right <= left or bottom <= top then
    return
  end

  -- Block range covering that box. The corners of a screen rectangle map to a turned
  -- rectangle in block space, so this over-covers; the loop's own test drops the rest.
  local lowX, highX, lowY, highY
  for corner = 1, 4 do
    local pointX = (corner == 1 or corner == 3) and left or right
    local pointY = corner <= 2 and top or bottom
    local cornerX, cornerY = screenCorner(
      transform, divisor, originX, originY, pointX, pointY)
    local blockX = floor(cornerX / GRID_STEP)
    local blockY = floor(cornerY / GRID_STEP)
    lowX = lowX and min(lowX, blockX) or blockX
    highX = highX and max(highX, blockX) or blockX
    lowY = lowY and min(lowY, blockY) or blockY
    highY = highY and max(highY, blockY) or blockY
  end

  local blocks = MAP_TILES // GRID_STEP
  lowX = max(lowX - 1, -1)
  lowY = max(lowY - 1, -1)
  highX = min(highX + 1, blocks)
  highY = min(highY + 1, blocks)
  if highX < lowX or highY < lowY then
    return
  end

  local anchorX, anchorY = cornerScreen(transform, divisor, originX, originY,
    GRID_STEP * lowX, GRID_STEP * lowY)

  -- The counts go last, so the block never holds a count with stale steps behind it.
  local parameters = state.control + MARKER_BLOCK
  writeInteger(parameters + 8, anchorX)
  writeInteger(parameters + 12, anchorY)
  writeInteger(parameters + 16, stepXx)
  writeInteger(parameters + 20, stepXy)
  writeInteger(parameters + 24, stepYx)
  writeInteger(parameters + 28, stepYy)
  writeInteger(parameters + 32, farX)
  writeInteger(parameters + 36, farY)
  writeInteger(parameters + 40, sideX)
  writeInteger(parameters + 44, sideY)
  writeInteger(parameters + 48, clipLeft)
  writeInteger(parameters + 52, clipRight)
  writeInteger(parameters + 56, clipTop)
  writeInteger(parameters + 60, clipBottom - LINE_THICKNESS_SPARE)
  writeInteger(parameters + 64, colour)
  writeInteger(parameters + 4, highY - lowY + 1)
  writeInteger(parameters, highX - lowX + 1)
end

---Work out what the overlay looks like for the view the frame hook just recorded, and
---leave it where the assembly draws it from. Called only when that view has changed.
---@param state OverlayState
local function rebuild(state)
  local control = state.control

  -- Empty first, so that anything going wrong part way leaves nothing half drawn.
  writeInteger(control + SEGMENT_COUNT, 0)
  writeInteger(control + MARKER_BLOCK, 0)
  writeInteger(control + MARKER_BLOCK + 4, 0)

  local zoomedOut = readInteger(control + VIEW_KEY_ZOOMED_OUT) ~= 0
  local divisor = zoomedOut and ZOOMED_OUT_DIVISOR or 1

  local orientation = readInteger(control + VIEW_KEY_ORIENTATION)
  local transform = ORIENTATIONS[orientation]
  if transform == nil then
    orientation = DEFAULT_ORIENTATION
    transform = ORIENTATIONS[orientation]
  end

  local colours = state.palette[
    readInteger(control + VIEW_KEY_COLOUR_MODE) == COLOR_MODE_565]
  writeInteger(control + STYLE_COLOURS + 4 * STYLE_GRID, colours[STYLE_GRID])
  writeInteger(control + STYLE_COLOURS + 4 * STYLE_ROTATION, colours[STYLE_ROTATION])
  writeInteger(control + STYLE_COLOURS + 4 * STYLE_MINE, colours[STYLE_MINE])

  -- Reproduce the row bias `renderMap` picks, because the whole vertical placement and
  -- the number of rows it renders hang off it.
  local rowBias = 0
  local firstRow = 0
  if readInteger(control + VIEW_KEY_ROW_BIAS) ~= 0 then
    if zoomedOut then
      rowBias, firstRow = 0x80, 0x10
    else
      rowBias, firstRow = 0x40, 8
    end
  end

  local cameraCell = truncatedDivide(
    readInteger(control + VIEW_KEY_VIEWPORT_X), TILE_PITCH)
  local cameraRow = truncatedDivide(
    readInteger(control + VIEW_KEY_VIEWPORT_Y) + rowBias, 2 * ROW_PITCH)

  -- Every term is even, so the zoomed-out halving is exact rather than a rounding. The
  -- ground height is part of the same pixel scale, so it halves with the rest; the
  -- boundary nudges are in finished screen pixels and are added afterwards.
  local originX = (transform.constX - TILE_PITCH * cameraCell) // divisor
  local originY = (rowBias + ROW_PITCH + transform.constY
    - 2 * ROW_PITCH * cameraRow - state.groundHeight) // divisor

  -- The clip box is the part of the map surface this frame actually redrew: rows
  -- `rowBias` to `rowBias + 8*rendered`, columns from the first tile of a row to the
  -- last. Anything wider is surface the frame never touched.
  local tilesPerRow = readInteger(control + VIEW_KEY_TILES_PER_ROW)
  local renderedRows = readInteger(control + VIEW_KEY_ROW_COUNT)
    + EXTRA_RENDERED_ROWS - firstRow

  local clipLeft = FIRST_TILE_SURFACE_X // divisor
  local clipRight = min(
    (FIRST_TILE_SURFACE_X + TILE_PITCH * (tilesPerRow + 2)) // divisor,
    SURFACE_WIDTH - 1)
  local clipTop = max(rowBias // divisor, 0)
  local clipBottom = min(
    (rowBias + ROW_PITCH + ROW_PITCH * renderedRows) // divisor, SURFACE_HEIGHT - 1)

  if clipRight <= clipLeft or clipBottom - LINE_THICKNESS_SPARE <= clipTop then
    return
  end

  writeInteger(control + SEGMENT_COUNT, writeSegments(state,
    state.lines[orientation][divisor], originX, originY,
    clipLeft, clipRight, clipTop, clipBottom - LINE_THICKNESS_SPARE))

  if state.tune.mineBoxes then
    writeMarkers(state, transform, divisor, originX, originY,
      clipLeft, clipRight, clipTop, clipBottom, colours[STYLE_MINE])
  end
end

---------------------------------------------------------------------------------------
-- Module
---------------------------------------------------------------------------------------

return {

  enable = function(self, config)
    config = config or {}
    local overlayConfig = config.overlay or {}

    local hotkey = resolveChoice(
      overlayConfig.key, VIRTUAL_KEY_CODES, DEFAULT_KEY, "hotkey")
    local gridChannels = resolveChoice(
      overlayConfig.grid_colour, COLOURS, DEFAULT_GRID_COLOUR, "grid colour")
    local rotationChannels = resolveChoice(
      overlayConfig.rotation_colour, COLOURS, DEFAULT_ROTATION_COLOUR,
      "rotation colour")
    local mineChannels = resolveChoice(
      overlayConfig.mine_colour, COLOURS, DEFAULT_MINE_COLOUR, "mine colour")
    local withRotation = overlayConfig.rotation_lines ~= false
    -- Default on, so the overlay is usable for checking alignment against a real map
    -- even when the config file has not been written yet.
    local editorOnly = overlayConfig.outside_editor == false
    -- Default on: the lines lie on one height, so they only tell the whole truth in the
    -- flattened view. Turn it off to see them over real terrain as well.
    local flattenedOnly = overlayConfig.flattened_only ~= false
    -- Kept as its own switch, and separate from the flattened gate, so that if this one
    -- ever reads the wrong thing it can be turned off without losing the other.
    local hideInVView = overlayConfig.hide_in_v_view ~= false

    -- Nothing here has a setting in the GUI any more: every position is either worked
    -- out from the game's own numbers or, for the keep rotation origin, measured once
    -- and fixed. The reads stay so that a hand-edited ucp-config.yml can still override
    -- them, and so the settings can be put back without unpicking the draw path.
    local tuneConfig = config.tune or {}
    local function number(value, fallback)
      return type(value) == "number" and floor(value) or fallback
    end
    local tune = {
      withRotation = withRotation,
      mineBoxes = overlayConfig.mine_boxes ~= false,
      mineSize = number(tuneConfig.mine_size, MINE_FOOTPRINT),
      originX = number(tuneConfig.origin_x, DEFAULT_ROTATION_ORIGIN),
      originY = number(tuneConfig.origin_y, DEFAULT_ROTATION_ORIGIN),
      boundaryX = number(tuneConfig.boundary_x, 0),
      boundaryY = number(tuneConfig.boundary_y, 0),
    }

    local renderSite = scanOptional(RENDER_MAP_CALL_AOB, "the map render call site")
    local surfaceSite = scanOptional(PENCIL_SURFACE_AOB, "the map surface pointer")
    local gameModeSite = scanOptional(GAME_MODE_AOB, "the game mode flag")
    local dispatchSite = scanOptional(SYS_KEY_DISPATCH_AOB, "the Alt key dispatcher")
    local orientationSite = scanOptional(MAP_ORIENTATION_AOB, "the map orientation")
    local flattenSite = scanOptional(FLATTENED_AOB, "the flattened view flags")
    local groundSite = scanOptional(GROUND_HEIGHT_AOB, "the ground height")
    local viewModeSite = scanOptional(VIEW_MODE_AOB, "the V view flag")

    if renderSite == nil or surfaceSite == nil or gameModeSite == nil
        or dispatchSite == nil or orientationSite == nil
        or core.readByte(renderSite + OFFSET_AFTER_RENDER) ~= OPCODE_MOV_EAX_ABSOLUTE then
      log(WARNING, "resource-grid-overlay: disabled, the game code it needs was not "
        .. "found.")
      return
    end

    local hookSite = renderSite + OFFSET_AFTER_RENDER
    local viewport = readAddress(renderSite + OFFSET_VIEWPORT)
    local surfacePointer = readAddress(surfaceSite + OFFSET_MAP_SURFACE_POINTER)
    local windowStruct = surfacePointer - MAP_SURFACE_POINTER_IN_STRUCT
    local gameMode = readAddress(gameModeSite + OFFSET_GAME_MODE)

    local state = {
      -- The height the game levels the whole map to in its flattened view, read from the
      -- instruction that sets it. Lines sit on that height, so they follow ordinary flat
      -- ground and match the flattened view exactly.
      groundHeight = groundSite ~= nil
        and readInteger(groundSite + OFFSET_GROUND_HEIGHT)
        or DEFAULT_GROUND_HEIGHT,
      tune = tune,
      -- One list per rotation per zoom level, indexed by orientation and then by the
      -- divisor the rebuild works out. Eight small lists, built once.
      lines = {},
      -- Only the keep rotation boundaries take a nudge.
      nudgeX = { 0, tune.boundaryX, 0 },
      nudgeY = { 0, tune.boundaryY, 0 },
      -- Colours per pixel layout, worked out once for each so the rebuild only picks.
      palette = {
        [false] = { packColour(gridChannels, false), packColour(rotationChannels, false),
          packColour(mineChannels, false) },
        [true] = { packColour(gridChannels, true), packColour(rotationChannels, true),
          packColour(mineChannels, true) },
      },
    }

    local longest = 0
    for orientation, transform in pairs(ORIENTATIONS) do
      state.lines[orientation] = {
        buildLines(tune, transform, 1),
        buildLines(tune, transform, ZOOMED_OUT_DIVISOR),
      }
      longest = max(longest, #state.lines[orientation][1],
        #state.lines[orientation][ZOOMED_OUT_DIVISOR])
    end
    -- The block is sized once the longest line list is known; no view can clip in more
    -- lines than a list holds.
    local control = core.allocate(SEGMENT_LIST + 8 * longest, true)
    state.control = control

    -- Both nil when the scan failed; the gate then stays off.
    local flattenA = flattenSite ~= nil
      and readAddress(flattenSite + OFFSET_FLATTEN_A) or nil
    local flattenB = flattenSite ~= nil
      and readAddress(flattenSite + OFFSET_FLATTEN_B) or nil
    local viewFlag = viewModeSite ~= nil
      and readAddress(viewModeSite + OFFSET_COMMAND_OBJECT)
        + VIEW_FLAG_IN_COMMAND_OBJECT or nil
    if flattenedOnly and flattenA == nil then
      log(WARNING, "resource-grid-overlay: the flattened view flags were not found, "
        .. "so the overlay shows in every view.")
    end

    writeInteger(control + EDITOR_ONLY, editorOnly and 1 or 0)
    writeInteger(control + FLATTENED_ONLY, (flattenedOnly and flattenA ~= nil) and 1 or 0)
    writeInteger(control + HIDE_IN_V_VIEW, (hideInVView and viewFlag ~= nil) and 1 or 0)

    -- The frame hook reads the view values through this table, in VIEW_KEY order.
    local zero = control + ALWAYS_ZERO
    local sources = {
      readAddress(orientationSite + OFFSET_MAP_ORIENTATION),
      viewport + VIEWPORT_ZOOMED_OUT,
      viewport + VIEWPORT_ROW_BIAS_ACTIVE,
      viewport + VIEWPORT_X,
      viewport + VIEWPORT_Y,
      viewport + VIEWPORT_TILES_PER_ROW,
      viewport + VIEWPORT_ROW_COUNT,
      windowStruct + COLOR_BIT_MODE_IN_STRUCT,
    }
    local sourceTable = core.allocate(4 * #sources, true)
    for index, address in ipairs(sources) do
      writeInteger(sourceTable + 4 * (index - 1), address)
    end

    -- The rebuild is reached from the assembly through a detour on a pad of its own.
    local rebuildFailed = false
    local rebuildPad = core.allocateCode({ 0x90, 0x90, 0x90, 0x90, 0x90, 0xC3 })
    core.detourCode(function(registers)
      local ok, err = pcall(rebuild, state)
      if not ok then
        writeInteger(control + SEGMENT_COUNT, 0)
        writeInteger(control + MARKER_BLOCK, 0)
        writeInteger(control + MARKER_BLOCK + 4, 0)
        if not rebuildFailed then
          rebuildFailed = true
          log(WARNING, "resource-grid-overlay: could not work out the overlay: "
            .. tostring(err))
        end
      end
      -- Marked valid either way: a failure is not retried until the view changes.
      writeInteger(control + CACHE_VALID, 1)
      return registers
    end, rebuildPad, 5)

    local hook = buildDrawer({
      OVERLAY_SHOWN = control + SHOWN,
      OVERLAY_EDITOR_ONLY = control + EDITOR_ONLY,
      OVERLAY_FLATTENED_ONLY = control + FLATTENED_ONLY,
      OVERLAY_HIDE_IN_V_VIEW = control + HIDE_IN_V_VIEW,
      CACHE_VALID_ADDRESS = control + CACHE_VALID,
      VIEW_KEY_ADDRESS = control + VIEW_KEY,
      SEGMENT_COUNT_ADDRESS = control + SEGMENT_COUNT,
      SEGMENT_LIST_ADDRESS = control + SEGMENT_LIST,
      STYLE_COLOURS_ADDRESS = control + STYLE_COLOURS,
      MARKER_PARAMETERS = control + MARKER_BLOCK,
      SOURCE_TABLE = sourceTable,
      GAME_MODE_ADDRESS = gameMode,
      GAME_MODE_EDITOR_VALUE = GAME_MODE_EDITOR,
      FLATTEN_A_ADDRESS = flattenA or zero,
      FLATTEN_B_ADDRESS = flattenB or zero,
      VIEW_FLAG_ADDRESS = viewFlag or zero,
      SURFACE_POINTER_ADDRESS = surfacePointer,
      SURFACE_PITCH_VALUE = SURFACE_PITCH,
      REBUILD_ADDRESS = rebuildPad,
      ORIGINAL_OPERAND = readAddress(hookSite + 1),
      RETURN_ADDRESS = hookSite + SIZE_AFTER_RENDER,
    })

    local relative = (hook - (hookSite + SIZE_AFTER_RENDER)) & 0xFFFFFFFF
    core.writeCodeBytes(hookSite, { 0xE9, relative & 0xFF, (relative >> 8) & 0xFF,
      (relative >> 16) & 0xFF, (relative >> 24) & 0xFF })

    ---Whether the overlay is allowed where the game currently is. Normally that means
    ---the map editor; with the "outside the map editor" option on it means anywhere the
    ---map is drawn, which is what you want when checking the lines against real terrain.
    ---The frame hook makes the same test on its own.
    ---@return boolean
    local function allowedHere()
      return not editorOnly or readInteger(gameMode) == GAME_MODE_EDITOR
    end

    -- Alt plus the hotkey. WM_SYSKEYDOWN is the only message Alt combinations arrive
    -- on, so no separate modifier test is needed, and the key is on the do-nothing case
    -- of that table so nothing has to be suppressed either.
    core.detourCode(function(registers)
      if registers.ESI == hotkey and not isAutoRepeat(registers.ECX)
          and allowedHere() then
        writeInteger(control + SHOWN, readInteger(control + SHOWN) == 0 and 1 or 0)
      end
      return registers
    end, dispatchSite + OFFSET_SYS_KEY_JUMP, SIZE_SYS_KEY_JUMP)

    -- Leaving the map puts the overlay away, so coming back into the editor always
    -- starts with it off. Moving between the editor's own screens keeps it.
    local mapScreens = { [MAP_EDITOR_PROPERTIES_SCREEN] = true }
    local inGameScreenSite = scanOptional(
      IN_GAME_SCREEN_AOB, "the on-the-map screen ids")
    if inGameScreenSite ~= nil then
      for _, offset in ipairs(OFFSETS_IN_GAME_SCREEN_IDS) do
        mapScreens[core.readByte(inGameScreenSite + offset)] = true
      end
      local screenChangeSite = scanOptional(
        SCREEN_CHANGE_AOB, "the screen change function")
      if screenChangeSite ~= nil then
        core.detourCode(function(registers)
          if not mapScreens[registers.EBP] then
            writeInteger(control + SHOWN, 0)
          end
          return registers
        end, screenChangeSite, SIZE_SCREEN_CHANGE_HOOK)
      end
    end

    log(INFO, string.format(
      "resource-grid-overlay: Alt + key 0x%02X, %d lines, rotation boundaries %s, %s.",
      hotkey, #state.lines[DEFAULT_ORIENTATION][1], withRotation and "on" or "off",
      editorOnly and "map editor only" or "on every map"))
  end,

  disable = function(self, config) end,

}
