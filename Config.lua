local addonName, ns = ...

ns.active = select(3, UnitClass("player")) == Constants.UICharacterClasses.Mage

if not ns.active then
    return
end

-- These are the values the addon shipped with, kept as the defaults so an existing setup looks
-- identical on first load. Colours are AARRGGBB hex because that is the form the Settings
-- colour swatch reads and writes, so the DB stores exactly what the control hands back.
ns.defaults = {
    soulTimer = {
        enabled = true,
        color = "ffbf73f2",
        -- Recolours once the current global cooldown ends inside the Soul window, meaning a
        -- Barrage queued now will land after it opens.
        showReady = true,
        readyColor = "ff55dd55",
        size = 26,
        x = 0,
        y = -70,
    },
    -- White count on an untinted icon, so it reads as a copy of the buff rather than as another
    -- of the addon's own displays.
    spheres = {
        enabled = true,
        color = "ffffffff",
        -- Icon edge rather than a font height, so this wants to be larger than the text modules.
        size = 32,
        fontSize = 18,
        x = 0,
        y = -60,
    },
    -- Not a display module, so it has no section of the shared enabled/colour/size shape.
    timing = {
        sphereMode = "predict",
        hideUncertain = false,
        warnUncertain = true,
    },
    barrage = {
        enabled = true,
        showCount = true,
        color = "ffbf73f2",
        lastColor = "ffff3333",
        size = 26,
        x = 0,
        y = -80,
    },
}

local applyCallbacks = {}

function ns.OnApply(callback)
    table.insert(applyCallbacks, callback)
end

function ns.Apply()
    for _, callback in ipairs(applyCallbacks) do
        callback()
    end
end

local previewCallbacks = {}

-- Explicitly false rather than nil, so the first SetPreview(false) is a genuine no-op instead
-- of firing every teardown callback once.
ns.previewing = false

function ns.OnPreview(callback)
    table.insert(previewCallbacks, callback)
end

-- Ignoring no-op calls keeps the Barrage preview from restarting its cycle every time a
-- slider ticks, which would otherwise reset the colour it happens to be showing.
function ns.SetPreview(enabled)
    enabled = enabled and true or false

    if ns.previewing == enabled then
        return
    end

    ns.previewing = enabled

    for _, callback in ipairs(previewCallbacks) do
        callback(enabled)
    end
end

function ns.UnpackColor(hex)
    local color = CreateColorFromHexString(hex)

    if not color then
        return 1, 1, 1
    end

    return color:GetRGB()
end

-- Only fills in what's missing, so settings survive an addon update that adds new keys.
local function FillDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then
                target[key] = {}
            end

            FillDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
end

-- Saved variables aren't populated until ADDON_LOADED, so everything that reads the DB waits
-- for this rather than running at file scope.
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, loaded)
    if loaded ~= addonName then
        return
    end

    self:UnregisterEvent("ADDON_LOADED")

    ArcaneSoulHelperDB = ArcaneSoulHelperDB or {}
    FillDefaults(ArcaneSoulHelperDB, ns.defaults)
    ns.db = ArcaneSoulHelperDB

    -- The old boolean became a mode selector; carry anyone who had it switched on across.
    if ns.db.timing.assumeMaxSpheres then
        ns.db.timing.sphereMode = "max"
    end

    ns.db.timing.assumeMaxSpheres = nil

    ns.BuildOptions()
    ns.Apply()
end)
