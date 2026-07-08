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

local function isCrop(cmd)
    local ok, res = pcall(function()
        local item = cmd.BuildingItem
        if not item:IsValid() then return false end
        local name = item:GetFullName()
        if not name:find("_BI_Farming_") then return false end
        for _, ex in ipairs(EXCLUDE) do
            if name:find(ex) then
                log("skipping %s (structural)", name:match("[^%.]+$") or name)
                return false
            end
        end
        log("item %s type=%s", name:match("[^%.]+$") or name, tostring(item.WorldActorType))
        return true
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

-- Confirms the server accepted the placement; silence after a "snapped"
-- line means the position was rejected (likely too close to another crop).
NotifyOnNewObject("/Script/R5.R5BuildingBlock_Crop", function(crop)
    if crop:GetFullName():find("Default__") then return end
    ExecuteWithDelay(300, function()
        ExecuteInGameThread(function()
            pcall(function()
                if not crop:IsValid() then return end
                local loc = crop:K2_GetActorLocation()
                log("crop landed at (%.0f, %.0f)", loc.X, loc.Y)
            end)
        end)
    end)
end)

log("loaded — grid %.0fuu | Alt+G toggle | Alt+Up/Down adjust", gridSize)
