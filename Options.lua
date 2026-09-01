local _, ns = ...

if not ns.active then
    return
end

local sizeRange = { min = 8, max = 72, step = 1 }

-- Offsets are UIParent units, so how far the sliders have to reach depends on the screen they
-- land on: an ultrawide at a low UI scale is several thousand units across, where a fixed range
-- strands the display near the middle. Half the screen in each direction puts every on-screen
-- position within reach without allowing one so far out it can't be seen. Measured when the
-- options are built rather than at load, so a UI scale another addon sets is already applied.
local offsetRanges

local function MeasureOffsetRanges()
    -- Never narrower than the range this shipped with, so nobody's existing position falls
    -- outside the slider on a screen whose half-width is smaller than that.
    local function Range(extent)
        local limit = math.max(600, math.ceil(extent / 2))

        return { min = -limit, max = limit, step = 1 }
    end

    offsetRanges = {
        x = Range(UIParent:GetWidth()),
        y = Range(UIParent:GetHeight()),
    }
end

local function Slider(category, setting, range)
    local options = Settings.CreateSliderOptions(range.min, range.max, range.step)
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
    Settings.CreateSlider(category, setting, options)
end

-- Settings writes straight into the table it's given, so pointing it at the DB subtable means
-- saving is handled for us; the callback only has to push the change onto the live frames.
local function Register(category, key, variableKey, variableType, name)
    local setting = Settings.RegisterAddOnSetting(category,
        ("ARCANESOULHELPER_%s_%s"):format(key:upper(), variableKey:upper()),
        variableKey, ns.db[key], variableType, name, ns.defaults[key][variableKey])

    setting:SetValueChangedCallback(ns.Apply)

    return setting
end

-- labels overrides the default wording per module, since an icon-based one means something
-- different by "size" and "colour" than a text-based one does.
local function AddModule(category, layout, key, title, labels)
    local defaults = ns.defaults[key]
    labels = labels or {}

    local function Add(variableKey, variableType, name)
        return Register(category, key, variableKey, variableType, name)
    end

    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(title))

    Settings.CreateCheckbox(category, Add("enabled", Settings.VarType.Boolean, "Enabled"))

    if defaults.showCount ~= nil then
        Settings.CreateCheckbox(category,
            Add("showCount", Settings.VarType.Boolean, "Show remaining count"),
            "Turn off to show only the final cast warning. The count depends on predicting"
                .. " exactly when Arcane Soul begins, so it can occasionally be off by one.")
    end

    Settings.CreateColorSwatch(category,
        Add("color", Settings.VarType.String, labels.color or "Colour"))

    if defaults.showReady ~= nil then
        Settings.CreateCheckbox(category,
            Add("showReady", Settings.VarType.Boolean, "Recolour when safe to queue"),
            "Turn the countdown a different colour once the global cooldown you are serving"
                .. " ends inside the Soul window, so a Barrage queued now lands after it opens.")

        Settings.CreateColorSwatch(category,
            Add("readyColor", Settings.VarType.String, "Colour when safe to queue"))
    end

    if defaults.lastColor then
        Settings.CreateColorSwatch(category,
            Add("lastColor", Settings.VarType.String, "Colour on last cast"))
    end

    Slider(category, Add("size", Settings.VarType.Number, labels.size or "Font size"), sizeRange)

    if defaults.fontSize then
        Slider(category, Add("fontSize", Settings.VarType.Number, "Font size"), sizeRange)
    end

    Slider(category, Add("x", Settings.VarType.Number, "Horizontal offset"), offsetRanges.x)
    Slider(category, Add("y", Settings.VarType.Number, "Vertical offset"), offsetRanges.y)
end

local function GetFontOptions()
    local container = Settings.CreateControlTextContainer()
    local fonts = ns.sharedMedia:List(ns.sharedMedia.MediaType.FONT)
    local selected = ns.db.appearance.font
    local selectedFound = false

    for _, font in ipairs(fonts) do
        container:Add(font, font)

        if font == selected then
            selectedFound = true
        end
    end

    -- Preserve a choice supplied by a media pack that has since been disabled. The live text
    -- uses SharedMedia's fallback until that pack returns, while the dropdown explains why.
    if not selectedFound then
        container:Add(selected, selected .. " (unavailable)")
    end

    return container:GetData()
end

local function AddAppearance(category, layout)
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Appearance"))

    Settings.CreateDropdown(category,
        Register(category, "appearance", "font", Settings.VarType.String, "Font"),
        GetFontOptions,
        "Choose from fonts registered with LibSharedMedia. Install a SharedMedia font pack"
            .. " to add more choices.")
end

local function GetSphereModeOptions()
    local container = Settings.CreateControlTextContainer()

    container:Add("predict", "Predictive",
        "Estimate the count from how much you have cast since it was last known. Accurate"
            .. " except shortly after pulling without a full set.")
    container:Add("max", "Always assume 3 spheres",
        "Never estimate. Correct unless you pull before the spheres have regenerated.")

    return container:GetData()
end

local function AddTiming(category, layout)
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Surge Duration"))

    local mode = Settings.CreateDropdown(category,
        Register(category, "timing", "sphereMode", Settings.VarType.String, "Sphere count"),
        GetSphereModeOptions,
        "Arcane Surge lasts 0.8s longer per Spellfire Sphere, and the count can't be read"
            .. " while in combat. This decides what to assume when it isn't known.")

    -- Both only mean anything while predicting, so they hang off the mode and vanish under
    -- "always assume 3", where there is no uncertainty to report.
    local function IsPredicting()
        return ns.db.timing.sphereMode == "predict"
    end

    local hide = Settings.CreateCheckbox(category,
        Register(category, "timing", "hideUncertain", Settings.VarType.Boolean,
            "Hide when uncertain"),
        "Show nothing at all when the sphere count is too uncertain to trust, rather than a"
            .. " countdown that may be a second out.")
    hide:SetParentInitializer(mode, IsPredicting)

    local warn = Settings.CreateCheckbox(category,
        Register(category, "timing", "warnUncertain", Settings.VarType.Boolean,
            "Warn when uncertain"),
        "Show a warning as Arcane Surge is cast when the sphere count isn't reliable.")
    warn:SetParentInitializer(mode, IsPredicting)
end

-- Preview runs whenever our page is the one on screen, so both frames can be positioned and
-- coloured against something visible instead of guessing and closing the panel to check.
local function UpdatePreview()
    ns.SetPreview(SettingsPanel:IsShown()
        and SettingsPanel:GetCurrentCategory() == ns.optionsCategory)
end

function ns.BuildOptions()
    MeasureOffsetRanges()

    local category, layout = Settings.RegisterVerticalLayoutCategory("ArcaneSoulHelper")

    AddAppearance(category, layout)
    AddModule(category, layout, "soulTimer", "Arcane Soul Timer")
    AddModule(category, layout, "barrage", "Barrage Counter")
    AddModule(category, layout, "spheres", "Sphere Display (out of combat)", {
        size = "Icon size",
        color = "Text colour",
    })
    AddTiming(category, layout)

    Settings.RegisterAddOnCategory(category)

    ns.optionsCategory = category

    -- Building the layout already required SettingsPanel, so it's safe to hook by now.
    SettingsPanel:HookScript("OnShow", UpdatePreview)
    SettingsPanel:HookScript("OnHide", UpdatePreview)
    hooksecurefunc(SettingsPanel, "SetCurrentCategory", UpdatePreview)
end

SLASH_ARCANESOULHELPER1 = "/arcanesoulhelper"
SLASH_ARCANESOULHELPER2 = "/ash"
SLASH_ARCANESOULHELPER3 = "/soul"
SlashCmdList["ARCANESOULHELPER"] = function(msg)
    if msg == "log" then
        ns.logging = not ns.logging
        print(("|cffbb88ffArcaneSoulHelper|r: soul log %s"):format(ns.logging and "on" or "off"))
        return
    end

    if ns.optionsCategory then
        Settings.OpenToCategory(ns.optionsCategory:GetID())
    end
end
