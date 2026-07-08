-- FarmGrid: grid-snaps crop placement in Windrose.
-- The placement transform travels as UR5BuildingCommand_PreConstruct.Transform
-- (a reflected UPROPERTY), wrapped in opaque GAS target data. We catch the
-- command object on creation and snap its transform in the
-- MakePreConstructRequest pre-hook — before the ability validates/serializes
-- it, so the server receives the snapped position (client-side only in MP).
local GRID_SIZE = 100.0   -- UU per cell
local snapEnabled = true

local function Snap(v) return math.floor(v / GRID_SIZE + 0.5) * GRID_SIZE end
local function log(fmt, ...) print(("[FarmGrid] " .. fmt .. "\n"):format(...)) end

local function isCrop(cmd)
    local ok, res = pcall(function()
        return cmd.BuildingItem:IsValid()
           and cmd.BuildingItem:GetFullName():find("_BI_Farming_") ~= nil
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
            local check = cmd.Transform.Translation
            log("snapped (%.0f, %.0f) -> (%.0f, %.0f) [readback %.0f, %.0f]",
                bx, by, Snap(bx), Snap(by), check.X, check.Y)
        end)
        if not ok then log("snap error: %s", tostring(err)) end
    end)

RegisterKeyBind(Key.G, { ModifierKey.ALT }, function()
    snapEnabled = not snapEnabled
    log("snapping %s", snapEnabled and "ON" or "OFF")
end)

-- debug: confirm where crops actually land
NotifyOnNewObject("/Script/R5.R5BuildingBlock_Crop", function(crop)
    if crop:GetFullName():find("Default__") then return end
    ExecuteWithDelay(300, function()
        ExecuteInGameThread(function()
            pcall(function()
                if not crop:IsValid() then return end
                local loc = crop:K2_GetActorLocation()
                log("crop landed at (%.0f, %.0f)%s", loc.X, loc.Y,
                    (loc.X == Snap(loc.X) and loc.Y == Snap(loc.Y)) and " [on grid]" or " [off grid]")
            end)
        end)
    end)
end)

log("loaded, grid=%.0f — Alt+G to toggle", GRID_SIZE)
