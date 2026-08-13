if select(3, UnitClass("player")) ~= Constants.UICharacterClasses.Mage then
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
frame:SetPoint("CENTER", UIParent, "CENTER", 0, -70)
frame.timer = nil
frame.ticker = nil
frame.text = frame:CreateFontString(nil, "OVERLAY", "GameTooltipText")
frame.text:SetPoint("CENTER", frame)
local fontPath = frame.text:GetFont()
frame.text:SetFont(fontPath, 26, "OUTLINE")
frame.text:SetTextColor(0.75, 0.45, 0.95)
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

local soulFrame = CreateFrame("Frame", nil, UIParent)
soulFrame:SetSize(1, 1)
soulFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -80)
soulFrame.text = soulFrame:CreateFontString(nil, "OVERLAY", "GameTooltipText")
soulFrame.text:SetPoint("CENTER", soulFrame)
soulFrame.text:SetFont(fontPath, 26, "OUTLINE")
soulFrame.text:SetTextColor(0.75, 0.45, 0.95)
soulFrame:Hide()

soulFrame.windowTimer = nil
soulFrame.expirationTime = nil
soulFrame.gcd = nil
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

local normalColor = { 0.75, 0.45, 0.95 }
local lastColor = { 1, 0.2, 0.2 }

-- updateDisplay is false for the idle ticker (only watches for window expiry) and true
-- when a Barrage cast (or the window opening) should refresh the frozen prediction, so the
-- number holding steady between presses actually means something instead of drifting.
function soulFrame:Recalc(updateDisplay)
    if not self.expirationTime or not self.gcd then
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
    local moreFits = math.floor(remaining / self.gcd)

    if moreFits <= 0 then
        self:Hide()
        return
    elseif moreFits == 1 then
        self.text:SetText("LAST")
        self.text:SetTextColor(unpack(lastColor))
    else
        self.text:SetText(tostring(moreFits))
        self.text:SetTextColor(unpack(normalColor))
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

    -- Cooldown APIs return tainted "secret" values now, so the GCD is measured from the
    -- gap between queued casts instead. Spell queueing means back-to-back presses land
    -- right on the GCD edge, so this gap is the real haste-adjusted GCD.
    local now = GetTime()

    if self.lastCastTime then
        local delta = now - self.lastCastTime

        if delta > 0 and delta <= baseGcd then
            self.gcd = delta
        end
    end

    self.lastCastTime = now

    if self.expirationTime then
        self:Recalc(true)
    end
end)
