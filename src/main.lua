-- ShipShape: grid-snaps crop placement in Windrose.
-- The placement transform travels as UR5BuildingCommand_PreConstruct.Transform
-- (a reflected UPROPERTY), wrapped in opaque GAS target data. We catch the
-- command object on creation and snap its transform in the
-- MakePreConstructRequest pre-hook - before the ability validates/serializes
-- it, so the server receives the snapped position (client-side only in MP).
-- ponytail: no per-plant footprint - the game has none (crops may overlap
-- freely); spacing is taste, so it's a live-tunable grid instead.
local gridSize = 40.0 -- UU per cell; Alt+Up / Alt+Down tunes in 10uu steps
local snapEnabled = true

local function Snap(v) return math.floor(v / gridSize + 0.5) * gridSize end
local function log(fmt, ...) print(("[ShipShape] " .. fmt .. "\n"):format(...)) end

-- Structural farming pieces (plots, beds, stations) keep the game's native
-- edge snapping; grid-snapping them tears them apart.
local EXCLUDE = { "Soil", "Seedbed", "Flowerbed", "Craftstation", "Trellis" }

local function isCropName(name)
    if not name:find("_BI_Farming_") then return false end
    for _, ex in ipairs(EXCLUDE) do
        if name:find(ex) then return false end
    end
    return true
end

local function isCrop(cmd)
    local ok, res = pcall(function()
        local item = cmd.BuildingItem
        return item:IsValid() and isCropName(item:GetFullName())
    end)
    return ok and res
end

local pendingCmd = nil
NotifyOnNewObject("/Script/R5.R5BuildingCommand_PreConstruct", function(cmd)
    pendingCmd = cmd
end)

RegisterHook("/Script/R5.R5Ability_Building_MakeConstructCommand:MakePreConstructRequest",
    function(_Ability, _Handle)
        local cmd = pendingCmd
        pendingCmd = nil
        if not snapEnabled or not cmd or not cmd:IsValid() then return end
        local ok, err = pcall(function()
            if not isCrop(cmd) then return end
            local t = cmd.Transform
            local loc = t.Translation
            loc.X = Snap(loc.X)
            loc.Y = Snap(loc.Y)
            t.Translation = loc
            cmd.Transform = t
        end)
        if not ok then log("snap error: %s", tostring(err)) end
    end)

-- On-screen messages: a bare UTextBlock added via UGameViewportSubsystem
-- (UE5.2+), top-center, auto-hidden after 2s. No game-UI dependencies.
local msgWidget = nil
local msgGen = 0

local function makeText(s)
    if type(FText) == "function" then return FText(s) end
    return StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
        :Conv_StringToText(s)
end

local function viewportSubsystem()
    local vps = FindFirstOf("GameViewportSubsystem")
    if vps:IsValid() then return vps end
    -- engine subsystems can be missed by FindFirstOf; ask the BP library
    local cls = StaticFindObject("/Script/UMG.GameViewportSubsystem")
    return StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary")
        :GetEngineSubsystem(cls)
end

local function showMessageImpl(text)
    local ok, err = pcall(function()
        local vps = viewportSubsystem()
        if not vps:IsValid() then
            log("msg error: no GameViewportSubsystem")
            return
        end
        if not (msgWidget and msgWidget:IsValid()) then
            -- outer must resolve GetWorld() or AddWidget refuses the widget;
            -- the GameInstance does, and lives for the whole session
            local gi = FindFirstOf("GameInstance")
            if not gi:IsValid() then
                log("msg error: no GameInstance")
                return
            end
            -- nothing strong-references the widget, so GC may collect it;
            -- the IsValid check above recreates it when that happens
            msgWidget = StaticConstructObject(
                StaticFindObject("/Script/UMG.TextBlock"), gi,
                FName("ShipShapeMsg"), 0)
            pcall(function() msgWidget:SetJustification(1) end) -- center
        end
        msgWidget:SetText(makeText(text))
        if not vps:IsWidgetAdded(msgWidget) then
            vps:AddWidget(msgWidget, {
                Anchors = { Minimum = { X = 0.5, Y = 0.0 }, Maximum = { X = 0.5, Y = 0.0 } },
                -- point anchors: Left/Top position the box, Right/Bottom SIZE it
                Offsets = { Left = 0, Top = 120, Right = 600, Bottom = 50 },
                Alignment = { X = 0.5, Y = 0.0 },
                ZOrder = 1000,
                bAutoRemoveOnWorldRemoved = true,
            })
        end
        msgGen = msgGen + 1
        local gen = msgGen
        ExecuteWithDelay(2000, function()
            if gen ~= msgGen then return end -- a newer message extended the timer
            ExecuteInGameThread(function()
                pcall(function()
                    local v = FindFirstOf("GameViewportSubsystem")
                    if msgWidget and msgWidget:IsValid() and v:IsValid() then
                        v:RemoveWidget(msgWidget)
                    end
                end)
            end)
        end)
    end)
    if not ok then log("msg error: %s", tostring(err)) end
end

local function showMessage(text)
    -- widget/slate work must happen on the game thread; keybind context isn't
    -- guaranteed to be it
    ExecuteInGameThread(function() showMessageImpl(text) end)
end

local function notify(fmt, ...)
    showMessage("ShipShape: " .. fmt:format(...))
end

RegisterKeyBind(Key.F, { ModifierKey.ALT }, function()
    snapEnabled = not snapEnabled
    notify("snapping %s", snapEnabled and "ON" or "OFF")
end)

RegisterKeyBind(Key.UP_ARROW, { ModifierKey.ALT }, function()
    gridSize = gridSize + 10
    notify("grid size %.0f", gridSize)
end)

RegisterKeyBind(Key.DOWN_ARROW, { ModifierKey.ALT }, function()
    gridSize = math.max(10, gridSize - 10)
    notify("grid size %.0f", gridSize)
end)

-- Ghost preview: the game rewrites the preview ACTOR transform natively every
-- tick after our queued writes run, so moving the actor never sticks. It never
-- touches the preview MESH components though - so we offset those by
-- (snapped - raw) instead; nothing races against it.
-- ponytail: yaw-only rotation math; previews don't pitch/roll on farmland.
local preview = nil
local meshBase = nil -- [i] = original mesh relative location
local offsetApplied = false
local lastBrush = ""
local lastDiag = 0.0

NotifyOnNewObject("/Script/R5.R5BuildingConstructTargetPreview", function(p)
    preview = p
    meshBase = nil
    offsetApplied = false
end)

local function diag(fmt, ...)
    if os.clock() - lastDiag < 1.0 then return end
    lastDiag = os.clock()
    log(fmt, ...)
end

local function eachMesh(fn)
    local meshes = preview.PreviewMeshes
    for i = 1, #meshes do
        local m = meshes[i]
        if m:IsValid() then fn(i, m) end
    end
end

local function restoreMeshes()
    if not offsetApplied then return end
    eachMesh(function(i, m)
        if meshBase and meshBase[i] then
            m:K2_SetRelativeLocation(meshBase[i], false, {}, true)
        end
    end)
    offsetApplied = false
end

-- Valheim-style grid overlay while placing. DrawDebugLine is compiled out of
-- this shipping build and no HUD blueprint implements ReceiveDrawHUD, so the
-- grid is thin Image widgets reprojected to screen space every preview tick.
-- ponytail: flat plane at preview Z, no terrain conforming - add per-vertex
-- line traces if slopes make it useless.
local GRID_CELLS = 4
local NUM_LINES = (GRID_CELLS + 1) * 2
local gridWidgets = nil
local gridVisible = false
local layoutLib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")

local function ensureGridWidgets()
    -- nothing strong-references these widgets, so GC (e.g. the pass the game
    -- runs on alt-tab focus loss) collects them; passing a dangling pointer
    -- to IsWidgetAdded crashed in FObjectKey's weak-ptr ctor. Validate every
    -- tick and rebuild the pool after a collection, like msgWidget does.
    if gridWidgets and gridWidgets[1]:IsValid() then return true end
    local gi = FindFirstOf("GameInstance")
    if not gi:IsValid() then return false end
    local imgClass = StaticFindObject("/Script/UMG.Image")
    gridWidgets = {}
    for i = 1, NUM_LINES do
        local w = StaticConstructObject(imgClass, gi, FName("ShipShapeGrid" .. i), 0)
        w:SetColorAndOpacity({ R = 0.8, G = 0.8, B = 0.8, A = 0.55 })
        w:SetVisibility(3) -- HitTestInvisible
        gridWidgets[i] = w
    end
    return true
end

local function hideGrid()
    if not gridVisible then return end
    gridVisible = false
    local vps = viewportSubsystem()
    if not vps:IsValid() then return end
    for _, w in ipairs(gridWidgets) do
        if w:IsValid() and vps:IsWidgetAdded(w) then vps:RemoveWidget(w) end
    end
end

local function project(pc, x, y, z)
    local out = {}
    if not layoutLib:ProjectWorldLocationToWidgetPosition(
            pc, { X = x, Y = y, Z = z }, out, false) then
        return nil
    end
    return out.X, out.Y
end

local function placeLine(vps, w, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local slot = {
        Anchors = { Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } },
        Offsets = { Left = (ax + bx) / 2, Top = (ay + by) / 2,
            Right = math.sqrt(dx * dx + dy * dy), Bottom = 2 },
        Alignment = { X = 0.5, Y = 0.5 },
        ZOrder = 999,
        bAutoRemoveOnWorldRemoved = true,
    }
    if vps:IsWidgetAdded(w) then vps:SetWidgetSlot(w, slot)
    else vps:AddWidget(w, slot) end
    w:SetRenderTransformAngle(math.deg(math.atan(dy, dx)))
end

local function drawGrid(cx, cy, z)
    if not ensureGridWidgets() then return end
    local vps = viewportSubsystem()
    local pc = statics:GetPlayerController(preview, 0)
    if not (vps:IsValid() and pc:IsValid()) then return end
    local half = GRID_CELLS / 2 * gridSize
    local n = 0
    for i = -GRID_CELLS / 2, GRID_CELLS / 2 do
        local o = i * gridSize
        for _, seg in ipairs({
            { cx - half, cy + o, cx + half, cy + o },
            { cx + o, cy - half, cx + o, cy + half },
        }) do
            n = n + 1
            local w = gridWidgets[n]
            local ax, ay = project(pc, seg[1], seg[2], z)
            local bx, by = project(pc, seg[3], seg[4], z)
            if ax and bx then placeLine(vps, w, ax, ay, bx, by)
            elseif vps:IsWidgetAdded(w) then vps:RemoveWidget(w) end
        end
    end
    gridVisible = true
end

local function updatePreview()
    -- two queued closures can race: the first nils a dead preview, the
    -- second then sees the nil upvalue
    if not preview then return end
    if not preview:IsValid() then
        preview = nil
        hideGrid()
        return
    end
    local brush = preview.BuildingBrush
    if not brush:IsValid() then
        hideGrid()
        return
    end
    local brushName = brush:GetFullName()
    if brushName ~= lastBrush then
        -- brush changed: the game may have rebuilt the preview meshes, so the
        -- cached relative locations no longer belong to these components
        lastBrush = brushName
        meshBase = nil
        offsetApplied = false
    end
    if not (snapEnabled and isCropName(brushName)) then
        restoreMeshes()
        hideGrid()
        return
    end
    local loc = preview:K2_GetActorLocation()
    local dx, dy = Snap(loc.X) - loc.X, Snap(loc.Y) - loc.Y
    drawGrid(Snap(loc.X), Snap(loc.Y), loc.Z + 2)
    -- world-space delta -> actor-local (undo the preview's yaw)
    local yaw = math.rad(preview:K2_GetActorRotation().Yaw)
    local c, s = math.cos(-yaw), math.sin(-yaw)
    local rdx, rdy = c * dx - s * dy, s * dx + c * dy
    meshBase = meshBase or {}
    eachMesh(function(i, m)
        if not meshBase[i] then
            local r = m.RelativeLocation
            meshBase[i] = { X = r.X, Y = r.Y, Z = r.Z }
        end
        local b = meshBase[i]
        m:K2_SetRelativeLocation({ X = b.X + rdx, Y = b.Y + rdy, Z = b.Z },
            false, {}, true)
    end)
    offsetApplied = true
end

-- 33ms and only dispatching while a preview is alive: the always-on 16ms
-- dispatch + object scans crashed inside UE4SS (access violation).
-- inFlight: never queue a second closure before the first ran. When the game
-- is unfocused (alt-tab) Proton throttles the game thread, queued closures
-- pile up and then execute in a burst inside one ProcessEvent - crashed with
-- an access violation on the game thread (crash_2026_07_08_11_25_39).
local inFlight = false
local inFlightSince = 0.0
LoopAsync(33, function()
    if preview and (not inFlight or os.clock() - inFlightSince > 2.0) then
        inFlight = true
        inFlightSince = os.clock()
        ExecuteInGameThread(function()
            local ok, err = pcall(updatePreview)
            inFlight = false
            if not ok then diag("preview error: %s", tostring(err)) end
        end)
    end
    return false
end)

log("loaded - grid %.0fuu | Alt+F toggle | Alt+Up/Down adjust", gridSize)
