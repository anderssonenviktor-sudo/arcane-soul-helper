local _, ns = ...

if not ns.active then
    return
end

local sizeRange = { min = 8, max = 72, step = 1 }
local offsetRange = { min = -600, max = 600, step = 1 }

local function Slider(category, setting, range)
    local options = Settings.CreateSliderOptions(range.min, range.max, range.step)
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
    Settings.CreateSlider(category, setting, options)
end

-- Settings writes straight into the table it's given, so pointing it at the DB subtable means
-- saving is handled for us; the callback only has to push the change onto the live frames.
local function Register(category, key, variableKey, variableType, name)
    local setting = Settings.RegisterAddOnSetting(category,
        ("AERYARCANE_%s_%s"):format(key:upper(), variableKey:upper()),
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

    if defaults.lastColor then
        Settings.CreateColorSwatch(category,
            Add("lastColor", Settings.VarType.String, "Colour on last cast"))
    end

    Slider(category, Add("size", Settings.VarType.Number, labels.size or "Font size"), sizeRange)

    if defaults.fontSize then
        Slider(category, Add("fontSize", Settings.VarType.Number, "Font size"), sizeRange)
    end

    Slider(category, Add("x", Settings.VarType.Number, "Horizontal offset"), offsetRange)
    Slider(category, Add("y", Settings.VarType.Number, "Vertical offset"), offsetRange)
end

local function AddTiming(category, layout)
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Surge Duration"))

    Settings.CreateCheckbox(category,
        Register(category, "timing", "assumeMaxSpheres", Settings.VarType.Boolean,
            "Always assume maximum spheres"),
        "Arcane Surge lasts 0.8s longer per Spellfire Sphere. The count can't be read in"
            .. " combat, so it is estimated from how much you have cast. Turn this on to always"
            .. " assume three instead: steadier, but wrong when you pull before they regenerate.")
end

-- Preview runs whenever our page is the one on screen, so both frames can be positioned and
-- coloured against something visible instead of guessing and closing the panel to check.
local function UpdatePreview()
    ns.SetPreview(SettingsPanel:IsShown()
        and SettingsPanel:GetCurrentCategory() == ns.optionsCategory)
end

function ns.BuildOptions()
    local category, layout = Settings.RegisterVerticalLayoutCategory("AeryArcane")

    AddModule(category, layout, "soulTimer", "Arcane Soul Timer")
    AddModule(category, layout, "barrage", "Barrage Counter")
    AddModule(category, layout, "spheres", "Sphere Warning", {
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

SLASH_AERYARCANE1 = "/aeryarcane"
SLASH_AERYARCANE2 = "/aa"
SLASH_AERYARCANE3 = "/soul"
SlashCmdList["AERYARCANE"] = function(msg)
    if msg == "log" then
        ns.logging = not ns.logging
        print(("|cffbb88ffAeryArcane|r: soul log %s"):format(ns.logging and "on" or "off"))
        return
    end

    if ns.optionsCategory then
        Settings.OpenToCategory(ns.optionsCategory:GetID())
    end
end
