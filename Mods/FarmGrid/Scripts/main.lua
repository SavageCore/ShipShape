-- FarmGrid: grid-snaps crop placement in Windrose.
-- The placement transform travels as UR5BuildingCommand_PreConstruct.Transform
-- (a reflected UPROPERTY), wrapped in opaque GAS target data. We catch the
-- command object on creation and snap its transform in the
-- MakePreConstructRequest pre-hook — before the ability validates/serializes
-- it, so the server receives the snapped position (client-side only in MP).
-- ponytail: no per-plant footprint — the game has none (crops may overlap
-- freely); spacing is taste, so it's a live-tunable grid instead.
local gridSize = 40.0     -- UU per cell; Alt+Up / Alt+Down tunes in 10uu steps
local snapEnabled = true

local function Snap(v) return math.floor(v / gridSize + 0.5) * gridSize end
local function log(fmt, ...) print(("[FarmGrid] " .. fmt .. "\n"):format(...)) end

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
        if not item:IsValid() then return false end
        local name = item:GetFullName()
        local crop = isCropName(name)
        log("%s %s type=%s", crop and "item" or "skipping",
            name:match("[^%.]+$") or name, tostring(item.WorldActorType))
        return crop
    end)
    return ok and res
end

local pendingCmd = nil
NotifyOnNewObject("/Script/R5.R5BuildingCommand_PreConstruct", function(cmd)
    pendingCmd = cmd
end)

RegisterHook("/Script/R5.R5Ability_Building_MakeConstructCommand:MakePreConstructRequest",
    function(Ability, Handle)
        local cmd = pendingCmd
        pendingCmd = nil
        if not snapEnabled or not cmd or not cmd:IsValid() then return end
        local ok, err = pcall(function()
            if not isCrop(cmd) then return end
            local t = cmd.Transform
            local loc = t.Translation
            local bx, by = loc.X, loc.Y
            loc.X = Snap(loc.X)
            loc.Y = Snap(loc.Y)
            t.Translation = loc
            cmd.Transform = t
            log("grid=%.0f snapped (%.0f, %.0f) -> (%.0f, %.0f)", gridSize, bx, by, loc.X, loc.Y)
        end)
        if not ok then log("snap error: %s", tostring(err)) end
    end)

RegisterKeyBind(Key.G, { ModifierKey.ALT }, function()
    snapEnabled = not snapEnabled
    log("snapping %s", snapEnabled and "ON" or "OFF")
end)

RegisterKeyBind(Key.UP_ARROW, { ModifierKey.ALT }, function()
    gridSize = gridSize + 10
    log("grid size %.0f", gridSize)
end)

RegisterKeyBind(Key.DOWN_ARROW, { ModifierKey.ALT }, function()
    gridSize = math.max(10, gridSize - 10)
    log("grid size %.0f", gridSize)
end)

-- Ghost preview: the game rewrites the preview ACTOR transform natively every
-- tick after our queued writes run, so moving the actor never sticks. It never
-- touches the preview MESH components though — so we offset those by
-- (snapped - raw) instead; nothing races against it.
-- ponytail: yaw-only rotation math; previews don't pitch/roll on farmland.
-- DEBUG: once-per-second diag lines while a crop preview is active.
local preview = nil
local meshBase = nil        -- [i] = original mesh relative location
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

local function updatePreview()
    if not preview:IsValid() then
        preview = nil
        return
    end
    local brush = preview.BuildingBrush
    if not brush:IsValid() then return end
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
        return
    end
    local loc = preview:K2_GetActorLocation()
    local dx, dy = Snap(loc.X) - loc.X, Snap(loc.Y) - loc.Y
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
LoopAsync(33, function()
    if preview then
        ExecuteInGameThread(function()
            local ok, err = pcall(updatePreview)
            if not ok then diag("preview error: %s", tostring(err)) end
        end)
    end
    return false
end)

log("loaded — grid %.0fuu | Alt+G toggle | Alt+Up/Down adjust", gridSize)
