local _, ns = ...

if not ns.active then
    return
end

local arcaneSurgeId = 365350
local savorTheMomentId = 449412
local spellfireSphereId = 448604
local baseSurgeDuration = 15
local sphereDurationBonus = 0.8
local maxSpheres = 3
local threshold = 3
local updateInterval = 0.1
local template = "Soul in %.1fs"

local arcaneSpecId = 62

local sunfuryTreeId = 39

local hasSavorTheMoment = false
local sphereCount = 0
local isSupported = false

-- Spec and hero talents both change mid-session, so this is re-evaluated on the same events
-- as the talent check rather than gating at load time the way the class check does.
local function IsSupportedBuild()
    local index = C_SpecializationInfo.GetSpecialization()

    if not index then
        return false
    end

    if C_SpecializationInfo.GetSpecializationInfo(index) ~= arcaneSpecId then
        return false
    end

    return C_ClassTalents.GetActiveHeroTalentSpec() == sunfuryTreeId
end

-- Events can in principle arrive before ADDON_LOADED has populated the DB, so every read goes
-- through here rather than indexing ns.db directly.
local function IsEnabled(key)
    return isSupported and ns.db and ns.db[key].enabled
end

-- Savor the Moment extends Arcane Surge by 0.8s per Spellfire Sphere held when it goes off,
-- so 3 spheres gives the familiar 17.4s. Called at cast time rather than cached, so a talent
-- swap or a sphere gained between casts is picked up without disturbing a running countdown.
local function SurgeDuration()
    if not hasSavorTheMoment then
        return baseSurgeDuration
    end

    return baseSurgeDuration + sphereDurationBonus * sphereCount
end

-- Returns true/false, or nil when the trait config isn't readable yet (early login, mid
-- spec swap) so the caller can retry instead of guessing at a duration.
local function IsTalentSelected(spellId)
    local configId = C_ClassTalents.GetActiveConfigID()

    if not configId then
        return nil
    end

    local configInfo = C_Traits.GetConfigInfo(configId)

    if not configInfo or not configInfo.treeIDs then
        return nil
    end

    for _, treeId in ipairs(configInfo.treeIDs) do
        -- GetTreeNodes covers every spec and hero tree, so an unselected node is only ruled
        -- out by activeRank -- which also keeps unchosen hero subtrees from matching.
        for _, nodeId in ipairs(C_Traits.GetTreeNodes(treeId) or {}) do
            local nodeInfo = C_Traits.GetNodeInfo(configId, nodeId)

            if nodeInfo and nodeInfo.activeRank > 0 and nodeInfo.activeEntry then
                local entryInfo = C_Traits.GetEntryInfo(configId, nodeInfo.activeEntry.entryID)
                local definitionInfo = entryInfo and entryInfo.definitionID
                    and C_Traits.GetDefinitionInfo(entryInfo.definitionID)

                if definitionInfo and (definitionInfo.spellID == spellId
                        or definitionInfo.overriddenSpellID == spellId) then
                    return true
                end
            end
        end
    end

    return false
end

-- Bumped per event so a burst of them at login leaves exactly one retry chain alive.
local refreshGeneration = 0

local function RefreshTalent(generation, attempt)
    if generation ~= refreshGeneration then
        return
    end

    isSupported = IsSupportedBuild()

    local talented = IsTalentSelected(savorTheMomentId)

    if talented == nil then
        if attempt < 10 then
            C_Timer.After(0.5, function() RefreshTalent(generation, attempt + 1) end)
        end

        return
    end

    hasSavorTheMoment = talented
end

local talentFrame = CreateFrame("Frame")
talentFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
talentFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
talentFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
talentFrame:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
talentFrame:SetScript("OnEvent", function()
    refreshGeneration = refreshGeneration + 1
    RefreshTalent(refreshGeneration, 1)
end)

-- Spellfire Sphere is ContextuallySecret: the aura is readable out of combat but goes secret
-- the moment you pull. The opener is the case worth getting right -- pulling before the
-- spheres have regenerated -- and it's covered by the last out-of-combat reading. Every later
-- cast is assumed full, since Surge can't come back up faster than the spheres do.
local function ReadSphereAura()
    local aura = C_UnitAuras.GetPlayerAuraBySpellID(spellfireSphereId)

    if not aura then
        return 0
    end

    local applications = aura.applications

    -- Only trust a plain number; anything secret leaves the tracked count as it was.
    if issecretvalue and issecretvalue(applications) then
        return nil
    end

    return applications or 0
end

-- Guarded on combat because the aura reads as absent rather than secret once you pull, which
-- is indistinguishable from zero spheres and would overwrite a perfectly good reading.
local function RefreshFromAura()
    if not isSupported or InCombatLockdown() then
        return
    end

    local count = ReadSphereAura()

    if count then
        sphereCount = count
    end
end

local sphereFrame = CreateFrame("Frame")
sphereFrame:RegisterUnitEvent("UNIT_AURA", "player")
sphereFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
sphereFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
sphereFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
sphereFrame:SetScript("OnEvent", function(_, event, _, _, spellId)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- Surge's cooldown is far longer than the spheres take to come back, so every cast
        -- after the opener is at full regardless of how early the pull was. Deferred a frame
        -- so both display frames handling this same cast still see the pre-Surge count.
        if spellId == arcaneSurgeId then
            C_Timer.After(0, function() sphereCount = maxSpheres end)
        end

        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        -- Lockdown can still read true during the event itself, so let it lift first.
        C_Timer.After(0, RefreshFromAura)
        return
    end

    RefreshFromAura()
end)

local frame = CreateFrame("Frame", nil, UIParent)
frame:SetSize(1, 1)
frame.timer = nil
frame.ticker = nil
frame.text = frame:CreateFontString(nil, "OVERLAY", "GameTooltipText")
frame.text:SetPoint("CENTER", frame)
local fontPath = frame.text:GetFont()
frame:Hide()

function frame:Stop()
    if self.timer then
        self.timer:Cancel()
        self.timer = nil
    end

    if self.ticker then
        self.ticker:Cancel()
        self.ticker = nil
    end

    self:Hide()
end

local previewRemaining = 2.4

local function ShowSoulPreview()
    frame:Stop()

    if not ns.db.soulTimer.enabled then
        return
    end

    frame.text:SetText(template:format(previewRemaining))
    frame:Show()
end

ns.OnPreview(function(enabled)
    if enabled then
        ShowSoulPreview()
    elseif not frame.timer and not frame.ticker then
        frame:Stop()
    end
end)

ns.OnApply(function()
    local settings = ns.db.soulTimer

    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", settings.x, settings.y)
    frame.text:SetFont(fontPath, settings.size, "OUTLINE")
    frame.text:SetTextColor(ns.UnpackColor(settings.color))

    -- Turning the module off mid-countdown has to tear down what's already running.
    if not settings.enabled then
        frame:Stop()
    end

    if ns.previewing then
        ShowSoulPreview()
    end
end)

frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
frame:RegisterEvent("PLAYER_DEAD")
frame:SetScript("OnEvent", function(self, event, _, _, spellId)
    if event == "PLAYER_DEAD" then
        self:Stop()
        return
    end

    if spellId ~= arcaneSurgeId then
        return
    end

    -- An actual cast outranks the preview, whichever modules happen to be enabled.
    ns.SetPreview(false)

    if not IsEnabled("soulTimer") then
        return
    end

    self:Stop()

    local duration = SurgeDuration()
    local ending = GetTime() + duration

    self.timer = C_Timer.NewTimer(duration - threshold, function()
        self.timer = nil

        local function Update()
            local remaining = ending - GetTime()

            if remaining <= 0 then
                self:Stop()
                return
            end

            self.text:SetText(template:format(remaining))
        end

        Update()
        self:Show()

        self.ticker = C_Timer.NewTicker(updateInterval, Update,
            math.ceil(threshold / updateInterval) + 2)
    end)
end)

local arcaneBarrageId = 44425
local arcaneSoulDuration = 4
-- Sanity bounds on the reported GCD: the game floors it at 0.75 and it can't exceed 1.5.
local baseGcd = 1.5
local minGcd = 0.7
local gcdSpellId = 61304

local soulFrame = CreateFrame("Frame", nil, UIParent)
soulFrame:SetSize(1, 1)
soulFrame.text = soulFrame:CreateFontString(nil, "OVERLAY", "GameTooltipText")
soulFrame.text:SetPoint("CENTER", soulFrame)
soulFrame:Hide()

soulFrame.windowTimer = nil
soulFrame.expirationTime = nil

function soulFrame:Stop()
    if self.windowTimer then
        self.windowTimer:Cancel()
        self.windowTimer = nil
    end

    if self.ticker then
        self.ticker:Cancel()
        self.ticker = nil
    end

    self.expirationTime = nil
    self:Hide()
end

-- The counter alternates between a number and the red LAST, so the preview cycles through
-- both rather than picking one -- otherwise half the colour settings can't be judged.
local previewCount = 3
local previewCycle = 1.5
local previewTicker
local previewShowsLast = false

local function DrawBarragePreview()
    -- With the count switched off there's only one state left to preview, so don't cycle
    -- through a number that will never appear in play.
    if previewShowsLast or not ns.db.barrage.showCount then
        soulFrame.text:SetText("LAST")
        soulFrame.text:SetTextColor(ns.UnpackColor(ns.db.barrage.lastColor))
    else
        soulFrame.text:SetText(tostring(previewCount))
        soulFrame.text:SetTextColor(ns.UnpackColor(ns.db.barrage.color))
    end

    soulFrame:Show()
end

local function StopBarragePreview()
    if previewTicker then
        previewTicker:Cancel()
        previewTicker = nil
    end

    -- Never tear down a real window. A Surge cast switches the preview off, and this frame
    -- may already have been armed for that same cast depending on which frame the event
    -- reached first -- without this guard the counter would silently never appear.
    if not soulFrame.expirationTime and not soulFrame.windowTimer then
        soulFrame:Stop()
    end
end

local function StartBarragePreview()
    StopBarragePreview()

    if not ns.db.barrage.enabled then
        return
    end

    DrawBarragePreview()

    previewTicker = C_Timer.NewTicker(previewCycle, function()
        previewShowsLast = not previewShowsLast
        DrawBarragePreview()
    end)
end

ns.OnPreview(function(enabled)
    if enabled then
        StartBarragePreview()
    else
        StopBarragePreview()
    end
end)

-- Colour is set per state in Recalc rather than here, since it alternates with the count.
ns.OnApply(function()
    local settings = ns.db.barrage

    soulFrame:ClearAllPoints()
    soulFrame:SetPoint("CENTER", UIParent, "CENTER", settings.x, settings.y)
    soulFrame.text:SetFont(fontPath, settings.size, "OUTLINE")

    if not settings.enabled then
        soulFrame:Stop()
    end

    -- Redraw rather than restart, so a colour tweak lands immediately instead of waiting
    -- out the rest of the current cycle.
    if ns.previewing then
        if previewTicker then
            DrawBarragePreview()
        else
            StartBarragePreview()
        end
    end
end)

-- The GCD is client-predicted: the client starts it on your keypress without waiting for the
-- server, so its length and end time are local values with no network jitter in them at all.
-- Everything here used to be inferred from the gaps between cast events, which could only ever
-- be as steady as packet arrival -- about 35ms of scatter either side of the truth.
--
-- Returns the GCD's length and the moment it ends, or nothing while none is running. Knowing
-- the end matters as much as the length: a window opening part-way through some other cast's
-- cooldown is waiting out the remainder, not a whole one.
local lastKnownGcd

local function ReadGcd()
    local info = C_Spell.GetSpellCooldown(gcdSpellId)

    -- duration is only meaningful while the cooldown is running; idle it reports zero.
    if info and info.isActive then
        local duration, startTime = info.duration, info.startTime

        -- Cooldown secrecy is contextual, so guard on the values rather than trusting a flag.
        local readable = duration and startTime
            and not (issecretvalue and (issecretvalue(duration) or issecretvalue(startTime)))

        if readable and duration >= minGcd and duration <= baseGcd then
            lastKnownGcd = duration
            return duration, startTime + duration
        end
    end

    -- Nothing running to report an end time for, but the length still stands: it only moves
    -- when haste does. Without this the counter would go blank the moment a queue is missed,
    -- which is exactly when it needs to keep recounting.
    return lastKnownGcd
end

-- updateDisplay is false for the idle ticker and true when a Barrage cast or the window
-- opening should refresh the prediction. justCast marks the Barrage path specifically: the
-- GCD takes a frame or two to register, so the client can still report us off it right
-- after a press.
function soulFrame:Recalc(updateDisplay, justCast)
    local gcd, gcdEndsAt = ReadGcd()

    if not self.expirationTime or not gcd then
        return
    end

    local now = GetTime()
    local remaining = self.expirationTime - now

    if remaining <= 0 then
        self:Stop()
        return
    end

    local onGcd = gcdEndsAt ~= nil or justCast

    -- Frozen while on the GCD, because the earliest next press is pinned to the end of the
    -- current one and the answer can't change. Once it lapses the earliest press is "now",
    -- which slides with every tick, so a fumbled queue has to keep recounting.
    if not updateDisplay and onGcd then
        return
    end

    -- Everything hinges on when the next press can actually go off. The client's end time is
    -- exact, remainder and all, which matters most when the window opens part-way through some
    -- unrelated cast's cooldown. The other two branches only cover the frame or two after a
    -- press before the GCD registers, and standing idle with nothing running.
    local nextPress

    if gcdEndsAt then
        nextPress = gcdEndsAt
    elseif onGcd then
        nextPress = now + gcd
    else
        nextPress = now
    end

    -- Presses land at nextPress, +gcd, +2gcd ... and one arriving exactly as the window
    -- closes doesn't land, which is why this is ceil rather than floor.
    local moreFits = math.ceil((self.expirationTime - nextPress) / gcd)

    if ns.logging then
        print(("|cff88ccffsoul|r gcd %.3f  end %s  rem %.3f  next +%.3f  fits %d"):format(
            gcd,
            gcdEndsAt and ("+%.3f"):format(gcdEndsAt - now) or "idle",
            remaining,
            nextPress - now,
            moreFits))
    end

    if moreFits <= 0 then
        self:Hide()
        return
    end

    -- The final warning is always shown. Only the running count is optional: it needs the
    -- window's start predicted accurately, whereas "exactly one left" tolerates far more slop.
    if moreFits == 1 then
        self.text:SetText("LAST")
        self.text:SetTextColor(ns.UnpackColor(ns.db.barrage.lastColor))
    elseif ns.db.barrage.showCount then
        self.text:SetText(tostring(moreFits))
        self.text:SetTextColor(ns.UnpackColor(ns.db.barrage.color))
    else
        self:Hide()
        return
    end

    self:Show()
end

-- Live readout of the client's own GCD value.
local gcdDebug = CreateFrame("Frame", nil, UIParent)
gcdDebug:SetSize(1, 1)
gcdDebug:SetPoint("CENTER", UIParent, "CENTER", 0, -120)
gcdDebug.text = gcdDebug:CreateFontString(nil, "OVERLAY", "GameTooltipText")
gcdDebug.text:SetPoint("CENTER", gcdDebug)
gcdDebug.text:SetFont(fontPath, 14, "OUTLINE")
gcdDebug.text:SetTextColor(0.55, 0.9, 0.55)
gcdDebug:Hide()

function ns.ToggleGcdReadout()
    gcdDebug:SetShown(not gcdDebug:IsShown())
    return gcdDebug:IsShown()
end

-- Driven every frame off the client's own value, so it holds steady and only moves when haste
-- actually does. UNAVAILABLE would mean a cooldown is running that we're not allowed to read --
-- the contextual case that hasn't turned up yet, and the one that would need a fallback.
gcdDebug:SetScript("OnUpdate", function(self)
    local gcd, endsAt = ReadGcd()

    -- An end time only comes back from a live read, so it -- not the length, which is cached --
    -- is what says whether the client is still answering. A running cooldown we can't read is
    -- the contextual secrecy case; no cooldown at all is just idle.
    if endsAt then
        self.available = true
    else
        local info = C_Spell.GetSpellCooldown(gcdSpellId)

        if info and info.isActive then
            self.available = false
        end
    end

    self.text:SetText(("gcd %s %s   %s"):format(
        gcd and ("%.3f"):format(gcd) or "--",
        self.available and "exact" or "|cffff6666UNAVAILABLE|r",
        endsAt and ("ends in %.2f"):format(endsAt - GetTime()) or "idle"))
end)

soulFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
soulFrame:RegisterEvent("PLAYER_DEAD")
soulFrame:SetScript("OnEvent", function(self, event, _, _, spellId)
    if event == "PLAYER_DEAD" then
        self:Stop()
        return
    end

    if not IsEnabled("barrage") then
        return
    end

    if spellId == arcaneSurgeId then
        self:Stop()

        self.windowTimer = C_Timer.NewTimer(SurgeDuration(), function()
            self.windowTimer = nil
            self.expirationTime = GetTime() + arcaneSoulDuration
            self:Recalc(true)
            self.ticker = C_Timer.NewTicker(updateInterval, function() self:Recalc(false) end)
        end)

        return
    end

    if spellId ~= arcaneBarrageId then
        return
    end

    if self.expirationTime then
        self:Recalc(true, true)
    end
end)
