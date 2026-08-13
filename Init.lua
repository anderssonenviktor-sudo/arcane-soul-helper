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

local hasSavorTheMoment = false
local sphereCount = 0

-- Events can in principle arrive before ADDON_LOADED has populated the DB, so every read goes
-- through here rather than indexing ns.db directly.
local function IsEnabled(key)
    return ns.db and ns.db[key].enabled
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
    if InCombatLockdown() then
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
local baseGcd = 1.5
-- Just under the game's 0.75 hard floor, so a duplicated cast event can't be mistaken for an
-- absurdly short GCD. The old lower bound of "greater than zero" would have accepted it.
local minGcd = 0.7
local gcdFloor = 0.75
local gcdSpellId = 61304

local soulFrame = CreateFrame("Frame", nil, UIParent)
soulFrame:SetSize(1, 1)
soulFrame.text = soulFrame:CreateFontString(nil, "OVERLAY", "GameTooltipText")
soulFrame.text:SetPoint("CENTER", soulFrame)
soulFrame:Hide()

soulFrame.windowTimer = nil
soulFrame.expirationTime = nil
soulFrame.gcd = nil
soulFrame.gcdIsClean = false
soulFrame.lastCastTime = nil

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
    if previewShowsLast then
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

-- The gap between two casts is only a clean GCD reading if the GCD never lapsed between them.
-- If it did, the gap contains idle time and overstates the GCD, which is what makes the
-- counter say LAST while another Barrage still fits. A GCD that never drops is itself the
-- proof that queueing held, so watching spell 61304 for a lapse sorts good samples from bad.
--
-- isActive is the field to use: startTime and duration are SecretWhenCooldownsRestricted, but
-- isActive is flagged NeverSecret.
local gcdWatcher = CreateFrame("Frame")
gcdWatcher:Hide()

gcdWatcher:SetScript("OnUpdate", function(self)
    local info = C_Spell.GetSpellCooldown(gcdSpellId)

    if info and info.isActive then
        self.sawActive = true
        return
    end

    -- The GCD takes a frame or two to register after the cast, so only a lapse seen after
    -- it was actually running counts. Either way the verdict is in, so stop polling.
    if self.sawActive or GetTime() - self.startedAt > baseGcd then
        self.lapsed = true
        self:Hide()
    end
end)

local function WatchGcd()
    gcdWatcher.startedAt = GetTime()
    gcdWatcher.sawActive = false
    gcdWatcher.lapsed = false
    gcdWatcher:Show()
end

-- Haste is read live on every recalculation rather than cached, so Bloodlust, trinket procs
-- and potions are all reflected on the very next press. Whether it's readable depends on the
-- context, so a secret value falls back to the gap measured between casts -- less accurate,
-- since that gap includes reaction time, but always available.
local function CurrentGcd(measured)
    local haste = UnitSpellHaste("player")

    if not haste or (issecretvalue and issecretvalue(haste)) then
        return measured
    end

    return math.max(gcdFloor, baseGcd / (1 + haste / 100))
end

-- updateDisplay is false for the idle ticker (only watches for window expiry) and true
-- when a Barrage cast (or the window opening) should refresh the frozen prediction, so the
-- number holding steady between presses actually means something instead of drifting.
function soulFrame:Recalc(updateDisplay)
    local gcd = CurrentGcd(self.gcd)

    if not self.expirationTime or not gcd then
        return
    end

    local remaining = self.expirationTime - GetTime()

    if remaining <= 0 then
        self:Stop()
        return
    end

    if not updateDisplay then
        return
    end

    -- Number of further presses that still fit after the one that just triggered this.
    -- 0 means none are coming at all, so there's nothing left to decide -> hide.
    -- 1 means the next press is the only (and therefore last) one coming.
    --
    -- ceil-minus-one rather than floor: a press landing exactly as the window closes doesn't
    -- land, and floor would count it.
    local moreFits = math.ceil(remaining / gcd) - 1

    if moreFits <= 0 then
        self:Hide()
        return
    elseif moreFits == 1 then
        self.text:SetText("LAST")
        self.text:SetTextColor(ns.UnpackColor(ns.db.barrage.lastColor))
    else
        self.text:SetText(tostring(moreFits))
        self.text:SetTextColor(ns.UnpackColor(ns.db.barrage.color))
    end

    self:Show()
end

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

    local now = GetTime()

    if self.lastCastTime then
        local delta = now - self.lastCastTime
        local clean = not gcdWatcher.lapsed

        -- A dirty sample is only taken when there's nothing better yet, so the counter still
        -- has something to work with before the first cleanly queued press of the session.
        if delta >= minGcd and delta <= baseGcd and (clean or not self.gcdIsClean) then
            self.gcd = delta
            self.gcdIsClean = clean
        end
    end

    self.lastCastTime = now
    WatchGcd()

    if self.expirationTime then
        self:Recalc(true)
    end
end)
