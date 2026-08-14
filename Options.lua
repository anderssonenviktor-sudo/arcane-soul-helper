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
local function AddModule(category, layout, key, title)
    local db = ns.db[key]
    local defaults = ns.defaults[key]

    local function Register(variableKey, variableType, name)
        local setting = Settings.RegisterAddOnSetting(category,
            ("AERYARCANE_%s_%s"):format(key:upper(), variableKey:upper()),
            variableKey, db, variableType, name, defaults[variableKey])

        setting:SetValueChangedCallback(ns.Apply)

        return setting
    end

    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(title))

    Settings.CreateCheckbox(category, Register("enabled", Settings.VarType.Boolean, "Enabled"))

    if defaults.showCount ~= nil then
        Settings.CreateCheckbox(category,
            Register("showCount", Settings.VarType.Boolean, "Show remaining count"),
            "Turn off to show only the final cast warning. The count depends on predicting"
                .. " exactly when Arcane Soul begins, so it can occasionally be off by one.")
    end

    Settings.CreateColorSwatch(category, Register("color", Settings.VarType.String, "Colour"))

    if defaults.lastColor then
        Settings.CreateColorSwatch(category,
            Register("lastColor", Settings.VarType.String, "Colour on last cast"))
    end

    Slider(category, Register("size", Settings.VarType.Number, "Font size"), sizeRange)
    Slider(category, Register("x", Settings.VarType.Number, "Horizontal offset"), offsetRange)
    Slider(category, Register("y", Settings.VarType.Number, "Vertical offset"), offsetRange)
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
