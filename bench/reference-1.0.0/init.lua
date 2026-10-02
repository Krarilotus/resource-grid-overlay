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
--   Four patch points, all located by pattern scan, all valid for the plain and the
--   Extreme executable:
--
--   * The one `call renderMap` site. The detour sits on the absolute `mov eax, [...]`
--     five bytes past the floater pass that follows it, so it runs once per frame with
--     the terrain, the buildings and the map overlays already on the map surface. That
--     call site is only reached when `isInGameScreen` says the player is on the map, so
--     the detour never fires in a menu.
--
--   * `PencilRenderCore::drawLine`, the game's own line drawer, plus the global pencil
--     object it uses. Writing 1 into the pencil's `surfaceTarget` aims it at the map
--     surface, which is exactly what the game does for the letterbox lines at the end
--     of `renderMap`. Lines are drawn twice, one pixel apart, for the two-pixel width.
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
--   `setupPencil` does not clip a line, it clamps each coordinate independently, which
--   bends any line that leaves the surface. Every line is therefore clipped here first,
--   in screen space, and dropped when nothing of it is left.
--
--   The lines lie on one height, because a flat grid has to. The one they lie on is the
--   height `renderMap` levels every tile to in its flattened view - the one the editor's
--   spacebar turns on - which is the map's normal ground, so the grid sits on ordinary
--   flat terrain and matches the flattened view exactly. That height is read out of the
--   instruction that sets it rather than hardcoded.

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
-- many to push through one lua call each, so the loop that emits them is assembly: it
-- walks the visible blocks, works each corner out by adding a constant step, and calls
-- the game's line drawer directly. A block whose marker is not wholly inside the clip
-- box is skipped rather than clipped, which costs a marker at the very edge of the
-- screen and saves clipping arithmetic on every one of them.
local MINE_FOOTPRINT = 4
local MARKER_PARAMETER_COUNT = 17

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

-- The map surface is 0x1FB0 bytes (4056 pixels) per line, and `setupPencil` clamps x to
-- exactly that range; y it clamps to the map clip window instead, which this module sets
-- itself. Two pixels are left spare at the bottom for the second row of the line.
local SURFACE_WIDTH = 4056
local SURFACE_HEIGHT = 4056
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

-- Window/graphics struct: the 16 bit pixel layout DirectDraw handed the game.
local COLOR_BIT_MODE_IN_STRUCT = 0x54
local SUPPORTED_RESOLUTIONS_IN_STRUCT = 0x68
local COLOR_MODE_565 = 0x565

-- PencilRenderCore field offset: 0 draws on the menu surface, 1 on the map surface.
local PENCIL_SURFACE_TARGET = 0x0C
local RENDER_TARGET_MAP = 1
local RENDER_TARGET_MENU = 0

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

---------------------------------------------------------------------------------------
-- Patterns
---------------------------------------------------------------------------------------

-- The single `call renderMap` site and the floater pass behind it:
--   mov [DAT], ebp / call renderMap / call renderFloaters / mov eax, [...] /
--   mov ecx, [...] / push eax / push ecx / mov ecx, viewport / call ...
local RENDER_MAP_CALL_AOB = "89 2D ? ? ? ? E8 ? ? ? ? E8 ? ? ? ? A1 ? ? ? ? 8B 0D ? ? ? ? "
    .. "50 51 B9 ? ? ? ? E8 ? ? ? ?"
local OFFSET_AFTER_RENDER = 16      -- the absolute `mov eax, [...]`, safe to detour
local SIZE_AFTER_RENDER = 5
local OFFSET_VIEWPORT = 30          -- operand of `mov ecx, viewport`

-- Head of `focusOnTile`, which picks its block of `screenPointToTileNumber` from the map
-- orientation the same way `renderMap` does:
--   mov eax,[mapOrientation] / test eax,eax / push ebx,ebp,esi,edi / mov ebp,ecx /
--   mov edi,8 / je / cmp eax,6 / jne / mov edi,0x13A18 / ...
local MAP_ORIENTATION_AOB = "A1 ? ? ? ? 85 C0 53 55 56 57 8B E9 BF 08 00 00 00 74 22 "
    .. "83 F8 06 75 07 BF 18 3A 01 00 EB 16 83 F8 04 75 07 BF 28 74 02 00"
local OFFSET_MAP_ORIENTATION = 1

-- `PencilRenderCore::drawLine(x1, y1, x2, y2, color)`, thiscall, ret 0x14:
--   push esi / mov esi,ecx / call setupPencilSurface / ... / call setupPencil / ...
local DRAW_LINE_AOB = "56 8B F1 E8 ? ? ? ? 8B 44 24 18 8B 4C 24 14 8B 54 24 10 50 "
    .. "8B 44 24 10 51 8B 4C 24 10 52 50 51 8B CE E8 ? ? ? ? 85 C0 74 38"

-- The game's own use of the pencil on the map surface, at the tail of `renderMap`:
--   push 0x1A / push 0x2CC / push 0xFD8 / push 0x2CC / push ebp /
--   mov ecx, pencil / mov dword [pencil+0xC], 1
local PENCIL_AOB = "6A 1A 68 CC 02 00 00 68 D8 0F 00 00 68 CC 02 00 00 55 B9 ? ? ? ? "
    .. "C7 05 ? ? ? ? 01 00 00 00"
local OFFSET_PENCIL = 19

-- `PencilRenderCore::setupPencilSurface`: picks the map surface when surfaceTarget is
-- set, and with it the 0x1FB0 byte pitch. Its first operand is the map surface pointer,
-- which sits at +0xD8 in the window/graphics struct.
local PENCIL_SURFACE_AOB = "8B 41 0C 85 C0 8B 15 ? ? ? ? 75 06 8B 15 ? ? ? ? 85 C0 "
    .. "89 51 04 74 08 C7 41 08 B0 1F 00 00"
local OFFSET_MAP_SURFACE_POINTER = 7
local MAP_SURFACE_POINTER_IN_STRUCT = 0xD8

-- Head of the terrain tile blitter, where the draw row is compared against the map clip
-- window: mov eax,[shade] / sub eax,[height] / add eax,[rowY] / cmp eax,[clipBottom] /
-- mov [ebp-4],eax / jge skip / cmp eax,[clipTop]
local MAP_CLIP_AOB = "A1 ? ? ? ? 2B 05 ? ? ? ? 03 05 ? ? ? ? 3B 05 ? ? ? ? 89 45 FC "
    .. "0F 8D ? ? ? ? 3B 05 ? ? ? ?"
local OFFSET_CLIP_BOTTOM = 19
local OFFSET_CLIP_TOP = 34

-- `GameMode2 == 1` guard in the "is the player looking at the map" helper:
--   cmp [gameMode2],1 / jne / push 4 / mov ecx,... / call / ret
local GAME_MODE_AOB = "83 3D ? ? ? ? 01 75 0D 6A 04 B9 ? ? ? ? E8 ? ? ? ? C3"

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
local OFFSET_GAME_MODE = 2

-- The WM_SYSKEYDOWN arm of the window procedure. ESI is the virtual-key code and ECX is
-- still the lParam the procedure loaded on entry:
--   mov esi,[esp+0x64] / lea eax,[esi-0xD] / cmp eax,0xD1 / mov ebp,1 / mov [DAT],ebp /
--   ja tail / movzx eax, byte [eax+caseTable] / jmp dword [eax*4+addressTable]
local SYS_KEY_DISPATCH_AOB = "8B 74 24 64 8D 46 F3 3D D1 00 00 00 BD 01 00 00 00 "
    .. "89 2D ? ? ? ? 0F 87 ? ? ? ? 0F B6 80 ? ? ? ? FF 24 85 ? ? ? ?"
local OFFSET_SYS_KEY_JUMP = 36
local SIZE_SYS_KEY_JUMP = 7

-- Body of the video options "next resolution" case; its supported-resolution operand is
-- the only short way to the window/graphics struct that does not go through a surface
-- pointer. Kept as a fallback for the pixel format when the pencil surface scan fails.
local RESOLUTION_STATE_AOB = "A1 ? ? ? ? 83 F8 01 75 07 B8 0F 00 00 00 EB 31 83 F8 0F "
    .. "75 07 B8 02 00 00 00 EB 25 83 F8 04 75 07 B8 0E 00 00 00 EB 19 83 F8 0E 75 07 "
    .. "B8 05 00 00 00 EB 0D 83 C0 01 83 F8 0E 75 05 B8 01 00 00 00 83 3C 85 ? ? ? ? 00"
local OFFSET_SUPPORTED_RESOLUTIONS = 0x45

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

---Bit 30 of lParam is set when a key-down message is a hold-down auto-repeat.
---@param lParam number the ECX value at the dispatch site
---@return boolean
local function isAutoRepeat(lParam)
  if lParam < 0 then
    lParam = lParam + 0x100000000
  end
  return math.floor(lParam / 0x40000000) % 2 == 1
end

---Integer division that rounds towards zero, which is what the game's `cdq / and / sar`
---sequences do and what the viewport-to-grid-cell arithmetic has to match.
---@param value number
---@param divisor number
---@return number
local function truncatedDivide(value, divisor)
  if value < 0 then
    return -math.floor(-value / divisor)
  end
  return math.floor(value / divisor)
end

---Pack an 8 bit per channel colour into the surface's 16 bit layout.
---@param channels number[] red, green, blue in 0..255
---@param is565 boolean true for RGB 5-6-5, false for (A)RGB 1-5-5-5
---@return number
local function packColour(channels, is565)
  local red, green, blue = channels[1], channels[2], channels[3]
  if is565 then
    return math.floor(red / 8) * 0x800 + math.floor(green / 4) * 0x20
      + math.floor(blue / 8)
  end
  return math.floor(red / 8) * 0x400 + math.floor(green / 8) * 0x20
    + math.floor(blue / 8)
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

---Build a cdecl wrapper that draws one two-pixel-wide line on the map surface, so a
---whole line costs a single call out of lua instead of two.
---@param pencil number address of the global PencilRenderCore
---@param drawLine number address of PencilRenderCore::drawLine
---@return number address of the wrapper
local function buildLineWriter(pencil, drawLine)
  return core.allocateAssembly([[
    push ebp
    mov ebp, esp
    push ebx
    push esi
    push edi

    mov dword [PENCIL_TARGET], TARGET_MAP
    push dword [ebp + 24]
    push dword [ebp + 20]
    push dword [ebp + 16]
    push dword [ebp + 12]
    push dword [ebp + 8]
    mov ecx, PENCIL
    call DRAW_LINE

    mov eax, dword [ebp + 20]
    add eax, 1
    mov edx, dword [ebp + 12]
    add edx, 1
    mov dword [PENCIL_TARGET], TARGET_MAP
    push dword [ebp + 24]
    push eax
    push dword [ebp + 16]
    push edx
    push dword [ebp + 8]
    mov ecx, PENCIL
    call DRAW_LINE

    mov dword [PENCIL_TARGET], TARGET_MENU

    pop edi
    pop esi
    pop ebx
    pop ebp
    ret
  ]], {
    PENCIL = pencil,
    PENCIL_TARGET = pencil + PENCIL_SURFACE_TARGET,
    TARGET_MAP = RENDER_TARGET_MAP,
    TARGET_MENU = RENDER_TARGET_MENU,
    DRAW_LINE = drawLine,
  })
end

---Build the marker loop: one two-pixel "V" per block, the two far edges of the iron mine
---footprint meeting at its far corner. Everything it needs arrives in one parameter
---block, so lua writes seventeen integers a frame and makes a single call.
---
---Parameter block, by byte offset:
---  0 countX      4 countY       8 originX     12 originY
--- 16 stepX x    20 stepX y     24 stepY x     28 stepY y
--- 32 far-cx x   36 far-cx y    40 far-cy x    44 far-cy y
--- 48 clip left  52 clip right  56 clip top    60 clip bottom
--- 64 colour
---@param pencil number address of the global PencilRenderCore
---@param drawLine number address of PencilRenderCore::drawLine
---@return number address of the routine
local function buildMarkerWriter(pencil, drawLine)
  return core.allocateAssembly([[
    push ebp
    mov ebp, esp
    sub esp, 48
    push ebx
    push esi
    push edi

    mov ebx, dword [ebp + 8]
    mov eax, dword [ebx + 8]
    mov dword [ebp - 4], eax
    mov eax, dword [ebx + 12]
    mov dword [ebp - 8], eax
    mov eax, dword [ebx + 4]
    mov dword [ebp - 12], eax

  rowLoop:
    cmp dword [ebp - 12], 0
    jle done
    mov ebx, dword [ebp + 8]
    mov eax, dword [ebp - 4]
    mov dword [ebp - 16], eax
    mov eax, dword [ebp - 8]
    mov dword [ebp - 20], eax
    mov eax, dword [ebx]
    mov dword [ebp - 24], eax

  colLoop:
    cmp dword [ebp - 24], 0
    jle rowNext
    mov ebx, dword [ebp + 8]
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
    jl skip
    cmp dword [ebp - 36], eax
    jl skip
    cmp dword [ebp - 44], eax
    jl skip
    mov eax, dword [ebx + 52]
    cmp dword [ebp - 28], eax
    jg skip
    cmp dword [ebp - 36], eax
    jg skip
    cmp dword [ebp - 44], eax
    jg skip
    mov eax, dword [ebx + 56]
    cmp dword [ebp - 32], eax
    jl skip
    cmp dword [ebp - 40], eax
    jl skip
    cmp dword [ebp - 48], eax
    jl skip
    mov eax, dword [ebx + 60]
    cmp dword [ebp - 32], eax
    jg skip
    cmp dword [ebp - 40], eax
    jg skip
    cmp dword [ebp - 48], eax
    jg skip

    mov dword [PENCIL_TARGET], TARGET_MAP
    push dword [ebx + 64]
    push dword [ebp - 48]
    push dword [ebp - 44]
    push dword [ebp - 32]
    push dword [ebp - 28]
    mov ecx, PENCIL
    call DRAW_LINE

    mov ebx, dword [ebp + 8]
    mov eax, dword [ebp - 48]
    add eax, 1
    mov edx, dword [ebp - 32]
    add edx, 1
    mov dword [PENCIL_TARGET], TARGET_MAP
    push dword [ebx + 64]
    push eax
    push dword [ebp - 44]
    push edx
    push dword [ebp - 28]
    mov ecx, PENCIL
    call DRAW_LINE

    mov ebx, dword [ebp + 8]
    mov dword [PENCIL_TARGET], TARGET_MAP
    push dword [ebx + 64]
    push dword [ebp - 48]
    push dword [ebp - 44]
    push dword [ebp - 40]
    push dword [ebp - 36]
    mov ecx, PENCIL
    call DRAW_LINE

    mov ebx, dword [ebp + 8]
    mov eax, dword [ebp - 48]
    add eax, 1
    mov edx, dword [ebp - 40]
    add edx, 1
    mov dword [PENCIL_TARGET], TARGET_MAP
    push dword [ebx + 64]
    push eax
    push dword [ebp - 44]
    push edx
    push dword [ebp - 36]
    mov ecx, PENCIL
    call DRAW_LINE

  skip:
    mov ebx, dword [ebp + 8]
    mov eax, dword [ebp - 16]
    add eax, dword [ebx + 16]
    mov dword [ebp - 16], eax
    mov eax, dword [ebp - 20]
    add eax, dword [ebx + 20]
    mov dword [ebp - 20], eax
    sub dword [ebp - 24], 1
    jmp colLoop

  rowNext:
    mov ebx, dword [ebp + 8]
    mov eax, dword [ebp - 4]
    add eax, dword [ebx + 24]
    mov dword [ebp - 4], eax
    mov eax, dword [ebp - 8]
    add eax, dword [ebx + 28]
    mov dword [ebp - 8], eax
    sub dword [ebp - 12], 1
    jmp rowLoop

  done:
    mov dword [PENCIL_TARGET], TARGET_MENU
    pop edi
    pop esi
    pop ebx
    mov esp, ebp
    pop ebp
    ret
  ]], {
    PENCIL = pencil,
    PENCIL_TARGET = pencil + PENCIL_SURFACE_TARGET,
    TARGET_MAP = RENDER_TARGET_MAP,
    TARGET_MENU = RENDER_TARGET_MENU,
    DRAW_LINE = drawLine,
  })
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
    local low = math.max(cx - CORNER_D_MAX, CORNER_S_MIN - cx)
    local high = math.min(cx - CORNER_D_MIN, CORNER_S_MAX - cx)
    if low < high then
      add(cx, low, cx, high, 1)
    end
  end

  for cy = 0, MAP_TILES, GRID_STEP do
    local low = math.max(cy + CORNER_D_MIN, CORNER_S_MIN - cy)
    local high = math.min(cy + CORNER_D_MAX, CORNER_S_MAX - cy)
    if low < high then
      add(low, cy, high, cy, 1)
    end
  end

  -- The four boundaries are a rigid cross, so moving the origin just translates them.
  if tune.withRotation then
    local shiftX = tune.originX - ROTATION_ORIGIN
    local shiftY = tune.originY - ROTATION_ORIGIN
    for _, boundary in ipairs(ROTATION_BOUNDARIES) do
      add(boundary[1] + shiftX, boundary[2] + shiftY,
        boundary[3] + shiftX, boundary[4] + shiftY, 2)
    end
  end

  return lines
end

---------------------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------------------

---@class OverlayState
---@field viewport number address of the ViewportRenderState instance
---@field clipTop number address of the map clip window's first drawable row
---@field clipBottom number address of the row past the map clip window
---@field windowStruct number|nil address of the window/graphics struct
---@field gameMode number address of GameMode2
---@field mapOrientation number address of the map orientation
---@field groundHeight number pixels the flattened map's ground sits above the row line
---@field flattenA number|nil address of the first "showing the map flattened" flag
---@field flattenB number|nil address of the second one
---@field viewFlag number|nil address of the "the map's objects are being drawn" flag
---@field flattenedOnly boolean draw only while the map is shown flattened
---@field hideInPlainView boolean hide while the V key's stripped-down view is on
---@field tune table the fine tuning settings
---@field lines table<number, table[][]> line lists by orientation, then by zoom divisor
---@field writeMarkers fun(parameters:number) the native marker loop
---@field markerParameters number address of its parameter block
---@field writeLine fun(x1:number, y1:number, x2:number, y2:number, colour:number)

---Draw every line that survives the clip box.
---@param state OverlayState
---@param colours number[] one packed 16 bit colour per style index
---@param lines table[] the line list for the zoom level in effect
---@param originX number screen x of the corner lattice origin
---@param originY number screen y of the corner lattice origin
---@param clipLeft number
---@param clipRight number
---@param clipTop number
---@param clipBottom number
local function drawLines(state, colours, lines, nudgeX, nudgeY, originX, originY,
    clipLeft, clipRight, clipTop, clipBottom)
  local writeLine = state.writeLine

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
      writeLine(
        math.floor(x1 + enter * deltaX + 0.5),
        math.floor(y1 + enter * deltaY + 0.5),
        math.floor(x1 + leave * deltaX + 0.5),
        math.floor(y1 + leave * deltaY + 0.5),
        colours[style])
    end
  end
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

---Fill in the marker parameter block for this frame and draw them.
---@param state OverlayState
---@param transform table one entry of ORIENTATIONS
---@param divisor number 1 zoomed in, 2 zoomed out
---@param originX number corner lattice origin, already nudged
---@param originY number
---@param clip table clipLeft, clipRight, clipTop, clipBottom
---@param colour number packed 16 bit colour
local function drawMarkers(state, transform, divisor, originX, originY, clip, colour)
  local tune = state.tune
  local size = tune.mineSize

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
  for _, corner in ipairs({
      { CORNER_D_MIN, CORNER_S_MIN }, { CORNER_D_MAX, CORNER_S_MIN },
      { CORNER_D_MIN, CORNER_S_MAX }, { CORNER_D_MAX, CORNER_S_MAX } }) do
    local d, s = corner[1], corner[2]
    local x = originX + (transform.xd * d + transform.xs * s) // divisor
    local y = originY + (transform.yd * d + transform.ys * s) // divisor
    mapLeft = mapLeft and math.min(mapLeft, x) or x
    mapRight = mapRight and math.max(mapRight, x) or x
    mapTop = mapTop and math.min(mapTop, y) or y
    mapBottom = mapBottom and math.max(mapBottom, y) or y
  end

  local left = math.max(clip.left, mapLeft)
  local right = math.min(clip.right, mapRight)
  local top = math.max(clip.top, mapTop)
  local bottom = math.min(clip.bottom, mapBottom)
  if right <= left or bottom <= top then
    return
  end

  -- Block range covering that box. The corners of a screen rectangle map to a turned
  -- rectangle in block space, so this over-covers; the loop's own test drops the rest.
  local lowX, highX, lowY, highY
  for _, point in ipairs({ { left, top }, { right, top },
      { left, bottom }, { right, bottom } }) do
    local cornerX, cornerY = screenCorner(
      transform, divisor, originX, originY, point[1], point[2])
    local blockX = math.floor(cornerX / GRID_STEP)
    local blockY = math.floor(cornerY / GRID_STEP)
    lowX = lowX and math.min(lowX, blockX) or blockX
    highX = highX and math.max(highX, blockX) or blockX
    lowY = lowY and math.min(lowY, blockY) or blockY
    highY = highY and math.max(highY, blockY) or blockY
  end

  local blocks = MAP_TILES // GRID_STEP
  lowX = math.max(lowX - 1, -1)
  lowY = math.max(lowY - 1, -1)
  highX = math.min(highX + 1, blocks)
  highY = math.min(highY + 1, blocks)
  if highX < lowX or highY < lowY then
    return
  end

  local anchorX, anchorY = cornerScreen(transform, divisor, originX, originY,
    GRID_STEP * lowX, GRID_STEP * lowY)

  local parameters = state.markerParameters
  local values = {
    highX - lowX + 1, highY - lowY + 1, anchorX, anchorY,
    stepXx, stepXy, stepYx, stepYy,
    farX, farY, sideX, sideY,
    clip.left, clip.right, clip.top, clip.bottom - LINE_THICKNESS_SPARE,
    colour,
  }
  for index = 1, MARKER_PARAMETER_COUNT do
    core.writeInteger(parameters + (index - 1) * 4, values[index])
  end
  state.writeMarkers(parameters)
end

---Draw the overlay onto the map surface for this frame.
---@param state OverlayState
---@param colours number[] one packed 16 bit colour per style index
local function drawOverlay(state, colours)
  local viewport = state.viewport

  -- Both flags have to be set for `renderMap` to take its flattened branch, so testing
  -- both is testing exactly what the game tests.
  if state.flattenedOnly
      and (core.readInteger(state.flattenA) == 0
        or core.readInteger(state.flattenB) == 0) then
    return
  end

  -- Zero means the game is leaving the things that stand on the map out of the picture,
  -- which is the view the V key gives. Non-zero is the ordinary view.
  if state.hideInPlainView and state.viewFlag ~= nil
      and core.readInteger(state.viewFlag) == 0 then
    return
  end

  -- Reproduce the row bias `renderMap` picks, because the whole vertical placement and
  -- the number of rows it renders hang off it.
  local zoomedOut = core.readInteger(viewport + VIEWPORT_ZOOMED_OUT) ~= 0
  local divisor = zoomedOut and ZOOMED_OUT_DIVISOR or 1

  local orientation = core.readInteger(state.mapOrientation)
  local transform = ORIENTATIONS[orientation]
  if transform == nil then
    orientation = DEFAULT_ORIENTATION
    transform = ORIENTATIONS[orientation]
  end

  local rowBias = 0
  local firstRow = 0
  if core.readInteger(viewport + VIEWPORT_ROW_BIAS_ACTIVE) ~= 0 then
    if zoomedOut then
      rowBias, firstRow = 0x80, 0x10
    else
      rowBias, firstRow = 0x40, 8
    end
  end

  local cameraCell = truncatedDivide(core.readInteger(viewport + VIEWPORT_X), TILE_PITCH)
  local cameraRow = truncatedDivide(
    core.readInteger(viewport + VIEWPORT_Y) + rowBias, 2 * ROW_PITCH)

  -- Every term is even, so the zoomed-out halving is exact rather than a rounding. The
  -- ground height is part of the same pixel scale, so it halves with the rest; the user's
  -- nudges are in finished screen pixels and are added afterwards.
  local tune = state.tune
  local originX = (transform.constX - TILE_PITCH * cameraCell) // divisor
  local originY = (rowBias + ROW_PITCH + transform.constY
    - 2 * ROW_PITCH * cameraRow - state.groundHeight) // divisor

  -- Only the keep rotation boundaries, style 2, take a nudge.
  local nudgeX = { 0, tune.boundaryX, 0 }
  local nudgeY = { 0, tune.boundaryY, 0 }

  -- The clip box is the part of the map surface this frame actually redrew: rows
  -- `rowBias` to `rowBias + 8*rendered`, columns from the first tile of a row to the
  -- last. Anything wider is surface the frame never touched.
  local tilesPerRow = core.readInteger(viewport + VIEWPORT_TILES_PER_ROW)
  local renderedRows = core.readInteger(viewport + VIEWPORT_ROW_COUNT)
    + EXTRA_RENDERED_ROWS - firstRow

  local clipLeft = FIRST_TILE_SURFACE_X // divisor
  local clipRight = math.min(
    (FIRST_TILE_SURFACE_X + TILE_PITCH * (tilesPerRow + 2)) // divisor,
    SURFACE_WIDTH - 1)
  local clipTop = math.max(rowBias // divisor, 0)
  local clipBottom = math.min(
    (rowBias + ROW_PITCH + ROW_PITCH * renderedRows) // divisor, SURFACE_HEIGHT - 1)

  if clipRight <= clipLeft or clipBottom - LINE_THICKNESS_SPARE <= clipTop then
    return
  end

  -- `setupPencil` clamps a line's ends into the map clip window rather than clipping
  -- it, which bends the line. The window is whatever the last thing to draw on the map
  -- left behind - `renderMap` sets it from the screen height, its building overlays set
  -- it to their own bounds - so rather than read it and hope, put the window where the
  -- lines are already clipped to and hand it straight back afterwards.
  local savedTop = core.readInteger(state.clipTop)
  local savedBottom = core.readInteger(state.clipBottom)
  core.writeInteger(state.clipTop, clipTop)
  core.writeInteger(state.clipBottom, clipBottom)

  local ok, err = pcall(function()
    drawLines(state, colours, state.lines[orientation][divisor], nudgeX, nudgeY,
      originX, originY,
      clipLeft, clipRight, clipTop, clipBottom - LINE_THICKNESS_SPARE)
    if state.tune.mineBoxes then
      drawMarkers(state, transform, divisor,
        originX, originY,
        { left = clipLeft, right = clipRight, top = clipTop, bottom = clipBottom },
        colours[3])
    end
  end)

  core.writeInteger(state.clipTop, savedTop)
  core.writeInteger(state.clipBottom, savedBottom)

  if not ok then
    error(err)
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
      return type(value) == "number" and math.floor(value) or fallback
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
    local drawLine = scanOptional(DRAW_LINE_AOB, "the line drawing function")
    local pencilSite = scanOptional(PENCIL_AOB, "the pencil render object")
    local clipSite = scanOptional(MAP_CLIP_AOB, "the map clip window")
    local gameModeSite = scanOptional(GAME_MODE_AOB, "the game mode flag")
    local dispatchSite = scanOptional(SYS_KEY_DISPATCH_AOB, "the Alt key dispatcher")
    local orientationSite = scanOptional(MAP_ORIENTATION_AOB, "the map orientation")
    local flattenSite = scanOptional(FLATTENED_AOB, "the flattened view flags")
    local groundSite = scanOptional(GROUND_HEIGHT_AOB, "the ground height")
    local viewModeSite = scanOptional(VIEW_MODE_AOB, "the V view flag")

    if renderSite == nil or drawLine == nil or pencilSite == nil or clipSite == nil
        or gameModeSite == nil or dispatchSite == nil or orientationSite == nil then
      log(WARNING, "resource-grid-overlay: disabled, the game code it needs was not "
        .. "found.")
      return
    end

    -- The pixel layout: preferred from the map surface pointer, which sits at a known
    -- offset in the window struct, and from the video options case body otherwise.
    local windowStruct = nil
    local surfaceSite = scanOptional(PENCIL_SURFACE_AOB, "the map surface pointer")
    if surfaceSite ~= nil then
      windowStruct = core.readInteger(surfaceSite + OFFSET_MAP_SURFACE_POINTER)
        - MAP_SURFACE_POINTER_IN_STRUCT
    else
      local resolutionSite = scanOptional(
        RESOLUTION_STATE_AOB, "the window and graphics struct")
      if resolutionSite ~= nil then
        windowStruct = core.readInteger(
          resolutionSite + OFFSET_SUPPORTED_RESOLUTIONS) - SUPPORTED_RESOLUTIONS_IN_STRUCT
      end
    end

    local state = {
      viewport = core.readInteger(renderSite + OFFSET_VIEWPORT),
      clipTop = core.readInteger(clipSite + OFFSET_CLIP_TOP),
      clipBottom = core.readInteger(clipSite + OFFSET_CLIP_BOTTOM),
      windowStruct = windowStruct,
      gameMode = core.readInteger(gameModeSite + OFFSET_GAME_MODE),
      mapOrientation = core.readInteger(orientationSite + OFFSET_MAP_ORIENTATION),
      -- The height the game levels the whole map to in its flattened view, read from the
      -- instruction that sets it, plus whatever the user adds. Lines sit on that height,
      -- so they follow ordinary flat ground and match the flattened view exactly.
      groundHeight = groundSite ~= nil
        and core.readInteger(groundSite + OFFSET_GROUND_HEIGHT)
        or DEFAULT_GROUND_HEIGHT,
      -- Both nil when the scan failed; the flattened-only gate then stays off.
      flattenA = flattenSite ~= nil
        and core.readInteger(flattenSite + OFFSET_FLATTEN_A) or nil,
      flattenB = flattenSite ~= nil
        and core.readInteger(flattenSite + OFFSET_FLATTEN_B) or nil,
      viewFlag = viewModeSite ~= nil
        and core.readInteger(viewModeSite + OFFSET_COMMAND_OBJECT)
          + VIEW_FLAG_IN_COMMAND_OBJECT or nil,
      tune = tune,
      -- One list per rotation per zoom level, indexed by orientation and then by the
      -- divisor the draw path works out. Eight small lists, built once.
      lines = {},
    }
    state.flattenedOnly = flattenedOnly and state.flattenA ~= nil
    if flattenedOnly and state.flattenA == nil then
      log(WARNING, "resource-grid-overlay: the flattened view flags were not found, "
        .. "so the overlay shows in every view.")
    end
    state.hideInPlainView = hideInVView and state.viewFlag ~= nil
    for orientation, transform in pairs(ORIENTATIONS) do
      state.lines[orientation] = {
        buildLines(tune, transform, 1),
        buildLines(tune, transform, ZOOMED_OUT_DIVISOR),
      }
    end
    local pencil = core.readInteger(pencilSite + OFFSET_PENCIL)
    state.writeLine = core.exposeCode(buildLineWriter(pencil, drawLine), 5, 0)
    state.writeMarkers = core.exposeCode(buildMarkerWriter(pencil, drawLine), 1, 0)
    state.markerParameters = core.allocate(MARKER_PARAMETER_COUNT * 4, true)

    -- Colours per pixel layout, worked out once for each so the draw path only picks.
    local palette = {
      [false] = { packColour(gridChannels, false), packColour(rotationChannels, false),
        packColour(mineChannels, false) },
      [true] = { packColour(gridChannels, true), packColour(rotationChannels, true),
        packColour(mineChannels, true) },
    }

    local shown = false

    ---Whether the overlay is allowed where the game currently is. Normally that means
    ---the map editor; with the "outside the map editor" option on it means anywhere the
    ---map is drawn, which is what you want when checking the lines against real terrain.
    ---@return boolean
    local function allowedHere()
      return not editorOnly or core.readInteger(state.gameMode) == GAME_MODE_EDITOR
    end

    -- Once per frame, with the terrain, the buildings and the map overlays already on
    -- the map surface. The call site behind this detour is only reached while the
    -- player is looking at the map, so leaving for a menu simply stops it.
    core.detourCode(function(registers)
      if shown then
        if not allowedHere() then
          shown = false
        else
          local is565 = state.windowStruct ~= nil
            and core.readInteger(state.windowStruct + COLOR_BIT_MODE_IN_STRUCT)
              == COLOR_MODE_565
          drawOverlay(state, palette[is565])
        end
      end
      return registers
    end, renderSite + OFFSET_AFTER_RENDER, SIZE_AFTER_RENDER)

    -- Alt plus the hotkey. WM_SYSKEYDOWN is the only message Alt combinations arrive
    -- on, so no separate modifier test is needed, and the key is on the do-nothing case
    -- of that table so nothing has to be suppressed either.
    core.detourCode(function(registers)
      if registers.ESI == hotkey and not isAutoRepeat(registers.ECX)
          and allowedHere() then
        shown = not shown
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
            shown = false
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
