-- ShipShape: grid-snaps crop placement in Windrose (client-side).
local VERSION = "0.0.0"
local gridSize = 40.0 -- UU per cell; Alt+Up / Alt+Down tunes in 10uu steps
local snapEnabled = true

local function Snap(v) return math.floor(v / gridSize + 0.5) * gridSize end
local function log(fmt, ...) print(("[ShipShape] " .. fmt .. "\n"):format(...)) end

-- these keep native edge snapping;
local EXCLUDE = { "Seedbed" }

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

-- On-screen messages
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
            -- outer must resolve GetWorld() or AddWidget refuses; GameInstance lives all session
            local gi = FindFirstOf("GameInstance")
            if not gi:IsValid() then
                log("msg error: no GameInstance")
                return
            end
            -- GC can collect the widget; IsValid check above recreates it
            msgWidget = StaticConstructObject(
                StaticFindObject("/Script/UMG.TextBlock"), gi,
                FName("ShipShapeMsg"), 0)
            pcall(function() msgWidget:SetJustification(1) end) -- center
        end
        msgWidget:SetText(makeText(text))
        if not vps:IsWidgetAdded(msgWidget) then
            vps:AddWidget(msgWidget, {
                Anchors = { Minimum = { X = 0.5, Y = 0.0 }, Maximum = { X = 0.5, Y = 0.0 } },
                -- point anchors: Left/Top position, Right/Bottom size
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
    -- widget work must run on the game thread
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

-- Ghost preview: the game rewrites the preview actor transform every tick,
-- so offset the mesh components instead
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

-- Grid overlay while placing: Image widgets reprojected to screen space
-- (DrawDebugLine is compiled out of this build)
local GRID_CELLS = 4
local NUM_LINES = (GRID_CELLS + 1) * 2
local gridWidgets = nil
local gridVisible = false
local layoutLib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")

local function ensureGridWidgets()
    -- GC collects unreferenced widgets; a dangling pointer to IsWidgetAdded
    -- crashes, so validate and rebuild each tick
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
        Offsets = {
            Left = (ax + bx) / 2,
            Top = (ay + by) / 2,
            Right = math.sqrt(dx * dx + dy * dy),
            Bottom = 2
        },
        Alignment = { X = 0.5, Y = 0.5 },
        ZOrder = 999,
        bAutoRemoveOnWorldRemoved = true,
    }
    if vps:IsWidgetAdded(w) then
        vps:SetWidgetSlot(w, slot)
    else
        vps:AddWidget(w, slot)
    end
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
            { cx - half, cy + o,    cx + half, cy + o },
            { cx + o,    cy - half, cx + o,    cy + half },
        }) do
            n = n + 1
            local w = gridWidgets[n]
            local ax, ay = project(pc, seg[1], seg[2], z)
            local bx, by = project(pc, seg[3], seg[4], z)
            if ax and bx then
                placeLine(vps, w, ax, ay, bx, by)
            elseif vps:IsWidgetAdded(w) then
                vps:RemoveWidget(w)
            end
        end
    end
    gridVisible = true
end

local function updatePreview()
    -- queued closures can race; the first may have nil'd a dead preview
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
        -- brush change may rebuild the preview meshes; drop cached locations
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

-- 33ms + preview-gated: faster always-on dispatch crashed UE4SS.
-- inFlight: queued closures pile up when Proton throttles an unfocused game, then crash.
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

log("v%s loaded - grid %.0fuu | Alt+F toggle | Alt+Up/Down adjust", VERSION, gridSize)
