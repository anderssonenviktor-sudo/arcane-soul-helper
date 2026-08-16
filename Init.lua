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
-- Each damaging cast has a 12% chance to generate a sphere. In combat the aura is secret and
-- the combat log is closed to addons, so this is carried as an expectation rather than a
-- count: 0.12 per cast is never exactly right, but it is never far wrong either. Incrementing
-- by whole spheres every ~8 casts would be confidently wrong a third of the time instead.
local sphereChance = 0.12
-- Below this the estimate is a coin flip wearing a number. In practice only two states clear
-- it: freshly read out of combat, or enough casts to be sure the count saturated.
local sphereConfidence = 0.9
local threshold = 3
local updateInterval = 0.1
local template = "Soul in %.1fs"

local arcaneSpecId = 62

local sunfuryTreeId = 39

local hasSavorTheMoment = false
local sphereCount = 0
local castsSinceSync = 0
-- The count at the last moment it was actually known, which the probability is measured from.
local syncedSpheres = 0
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

    -- Rounded to a whole sphere, so the result is always one the game can actually produce:
    -- 15.0, 15.8, 16.6 or 17.4. Using the fractional estimate directly would land between
    -- them and be guaranteed wrong every time, where rounding is exactly right most of the
    -- time and a full sphere out occasionally.
    --
    -- Assuming the maximum trades that for predictability: never surprising mid-fight, but
    -- always wrong when you pull before the spheres have come back.
    local spheres = math.floor(sphereCount + 0.5)

    if ns.db and ns.db.timing.sphereMode == "max" then
        spheres = maxSpheres
    end

    return baseSurgeDuration + sphereDurationBonus * spheres
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
        syncedSpheres = count
        castsSinceSync = 0
    end
end

-- Blind once combat starts, so accumulate what the casts are worth. Without this the last
-- out-of-combat reading stands for the whole fight, which is why a pack pulled before the
-- spheres refilled reported Soul arriving early -- the reading was stale-low, and stale-low
-- is the only direction it can be wrong in.
-- Odds of exactly this many procs in that many casts. Terms are built from the previous one
-- rather than from factorials, which keeps the numbers small on long fights.
local function ProcChance(procs, casts)
    if procs > casts then
        return 0
    end

    local miss = 1 - sphereChance
    local chance = miss ^ casts

    for step = 1, procs do
        chance = chance * (casts - step + 1) / step * sphereChance / miss
    end

    return chance
end

-- How likely the rounded estimate is to be the true count -- which is a different question from
-- how close the estimate is. In practice it only clears a high bar in two places: within a cast
-- or so of a sync, where nothing has had time to change, and once enough casts have passed to
-- be sure the count saturated. The long middle stretch is a coin flip whatever the estimate says.
local function ConfidenceInEstimate()
    -- The one genuine certainty: synced at the cap, where nothing can add to the count and
    -- only Surge takes it away -- and Surge resyncs. Anything below the cap is a claim about
    -- how many procs have happened since, including the claim that none have.
    if syncedSpheres >= maxSpheres then
        return 1
    end

    local estimate = math.floor(sphereCount + 0.5)
    local needed = math.max(0, estimate - syncedSpheres)

    -- At the cap every outcome at or above the shortfall gives the same answer, so they all
    -- count as correct. Below it only the exact number does -- zero included, which is the
    -- case that used to be mistaken for certainty.
    if estimate < maxSpheres then
        return ProcChance(needed, castsSinceSync)
    end

    local below = 0

    for procs = 0, needed - 1 do
        below = below + ProcChance(procs, castsSinceSync)
    end

    return 1 - below
end

-- Only meaningful while predicting. Assuming the maximum is a stated preference rather than a
-- guess, so it never reports uncertainty even when it happens to be wrong.
local function IsUncertain()
    if not ns.db or ns.db.timing.sphereMode ~= "predict" then
        return false
    end

    return ConfidenceInEstimate() < sphereConfidence
end

local function AccumulateSphere()
    sphereCount = math.min(maxSpheres, sphereCount + sphereChance)
    castsSinceSync = castsSinceSync + 1
end

-- Sanity bounds on the reported GCD: the game floors it at 0.75 and it can't exceed 1.5.
local baseGcd = 1.5
local minGcd = 0.7
local gcdSpellId = 61304

-- The GCD is client-predicted: the client starts it on your keypress without waiting for the
-- server, so its length and end time are local values with no network jitter in them at all.
-- Everything here used to be inferred from the gaps between cast events, which could only ever
-- be as steady as packet arrival -- about 35ms of scatter either side of the truth.
--
-- Returns the GCD's length and the moment it ends, or nothing while none is running. Knowing
-- the end matters as much as the length: a window opening part-way through some other cast's
-- cooldown is waiting out the remainder, not a whole one, and the soul timer needs it to say
-- whether the GCD you are currently serving will carry you into the window.
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

function frame:Begin()
    if not IsEnabled("soulTimer") then
        return
    end

    self:Stop()

    local duration = SurgeDuration()
    local ending = GetTime() + duration

    self.timer = C_Timer.NewTimer(duration - threshold, function()
        self.timer = nil

        -- Tracked so the colour is only pushed on a transition. Nil to begin with, so the
        -- first update always paints rather than inheriting whatever the last countdown left.
        local wasReady

        local function Update()
            local remaining = ending - GetTime()

            if remaining <= 0 then
                self:Stop()
                return
            end

            self.text:SetText(template:format(remaining))

            -- Green once the GCD you are currently serving ends inside the window: a Barrage
            -- queued now fires after Soul begins. Idle doesn't count -- pressing with nothing
            -- running lands the cast immediately, which is before the window opens.
            local _, gcdEndsAt = ReadGcd()
            local ready = ns.db.soulTimer.showReady
                and gcdEndsAt ~= nil and gcdEndsAt >= ending

            if ready ~= wasReady then
                wasReady = ready

                local settings = ns.db.soulTimer

                self.text:SetTextColor(ns.UnpackColor(
                    ready and settings.readyColor or settings.color))
            end
        end

        Update()
        self:Show()

        self.ticker = C_Timer.NewTicker(updateInterval, Update,
            math.ceil(threshold / updateInterval) + 2)
    end)
end

local arcaneBarrageId = 44425
local arcaneSoulDuration = 4

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
    self.assumedGcdEnd = nil
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

    -- Everything hinges on when the next press can actually go off.
    local nextPress

    if justCast then
        -- The press that triggered this just started a GCD the client hasn't registered yet,
        -- so a live read still describes the previous one -- already part-spent and about to
        -- expire. Using it would place the next press early and count one too many.
        --
        -- Recorded rather than just used, so the rest of this GCD is judged the same way. The
        -- idle ticker consults the live read, which can call you free before our own deadline
        -- and contradict the count we just gave -- the display then flickers back after hiding.
        self.assumedGcdEnd = now + gcd
        nextPress = self.assumedGcdEnd
    elseif self.assumedGcdEnd and self.assumedGcdEnd > now then
        nextPress = self.assumedGcdEnd
    elseif gcdEndsAt then
        -- No press of ours is outstanding, so the client's end time is exact, remainder and
        -- all. This is what makes a window opening mid-cooldown count correctly.
        nextPress = gcdEndsAt
    else
        nextPress = now
    end

    -- On the GCD precisely when the next press is still ahead of us.
    local onGcd = nextPress > now

    -- Frozen while on the GCD, because the earliest next press is pinned and the answer can't
    -- change. Once it lapses the earliest press is "now", which slides with every tick, so a
    -- fumbled queue has to keep recounting.
    if not updateDisplay and onGcd then
        return
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

function soulFrame:Begin()
    if not IsEnabled("barrage") then
        return
    end

    self:Stop()

    self.windowTimer = C_Timer.NewTimer(SurgeDuration(), function()
        self.windowTimer = nil
        self.expirationTime = GetTime() + arcaneSoulDuration
        self:Recalc(true)
        self.ticker = C_Timer.NewTicker(updateInterval, function() self:Recalc(false) end)
    end)
end

-- Out of combat the sphere count is a real reading rather than an estimate, so this can warn
-- that a pull now would shorten the next Surge. Deliberately silent at maximum: "you are ready"
-- is the normal state and doesn't need saying.
-- Drawn as the buff itself -- icon plus stack count in the corner -- so it reads as "the thing
-- you are missing" rather than as another number to learn.
local previewSpheres = 1

local sphereDisplay = CreateFrame("Frame", nil, UIParent)
sphereDisplay:Hide()

sphereDisplay.icon = sphereDisplay:CreateTexture(nil, "ARTWORK")
sphereDisplay.icon:SetAllPoints(sphereDisplay)
-- Spell icons ship with a border baked into the outer few percent. Cropping it is what the
-- buff frame does; without it the art sits inset and looks muddy against the rest of the UI.
sphereDisplay.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

sphereDisplay.count = sphereDisplay:CreateFontString(nil, "OVERLAY", "GameTooltipText")
sphereDisplay.count:SetPoint("BOTTOMRIGHT", sphereDisplay, "BOTTOMRIGHT", 2, -1)

-- Texture is fetched here rather than once at load: spell data isn't reliably available by
-- ADDON_LOADED, and this only runs on an aura change, not per frame.
local function DrawSpheres(count)
    sphereDisplay.icon:SetTexture(C_Spell.GetSpellTexture(spellfireSphereId))
    -- Greyed at zero, where there is no buff to mirror and the absence is the whole point.
    sphereDisplay.icon:SetDesaturated(count == 0)
    sphereDisplay.count:SetText(count)
    sphereDisplay:Show()
end

function sphereDisplay:Refresh()
    -- In combat the count is secret and whatever we hold is an estimate, so there's nothing
    -- honest to show -- and by then it's too late to act on anyway.
    if not IsEnabled("spheres") or InCombatLockdown() then
        self:Hide()
        return
    end

    local count = math.floor(sphereCount + 0.5)

    if count >= maxSpheres then
        self:Hide()
        return
    end

    DrawSpheres(count)
end

local function ShowSpherePreview()
    if not ns.db.spheres.enabled then
        sphereDisplay:Hide()
        return
    end

    DrawSpheres(previewSpheres)
end

ns.OnPreview(function(enabled)
    if enabled then
        ShowSpherePreview()
    else
        sphereDisplay:Refresh()
    end
end)

ns.OnApply(function()
    local settings = ns.db.spheres

    -- Icon and text are sized independently here: size is the icon edge, fontSize the count
    -- sitting on top of it.
    sphereDisplay:SetSize(settings.size, settings.size)
    sphereDisplay:ClearAllPoints()
    sphereDisplay:SetPoint("CENTER", UIParent, "CENTER", settings.x, settings.y)
    -- Heavier outline than the text displays use: this one sits on top of icon art rather than
    -- on the background, so a thin edge disappears against the brighter parts.
    sphereDisplay.count:SetFont(fontPath, settings.fontSize, "THICKOUTLINE")
    sphereDisplay.count:SetTextColor(ns.UnpackColor(settings.color))

    if ns.previewing then
        ShowSpherePreview()
    else
        sphereDisplay:Refresh()
    end
end)

-- Shown as Arcane Surge goes out, when the sphere count its duration rests on isn't trustworthy.
-- Borrows the soul timer's position and size, which is safe because the two can never appear
-- together: this fires at the cast, the countdown only in the last seconds before Soul.
local warningMessage = "Spheres uncertain"
local warningColor = "ffffb840"
local warningDuration = 4

local warningFrame = CreateFrame("Frame", nil, UIParent)
warningFrame:SetSize(1, 1)
warningFrame.text = warningFrame:CreateFontString(nil, "OVERLAY", "GameTooltipText")
warningFrame.text:SetPoint("CENTER", warningFrame)
warningFrame.text:SetText(warningMessage)
warningFrame:Hide()

function warningFrame:Flash()
    if self.timer then
        self.timer:Cancel()
    end

    self:Show()

    self.timer = C_Timer.NewTimer(warningDuration, function()
        self.timer = nil
        self:Hide()
    end)
end

ns.OnApply(function()
    local settings = ns.db.soulTimer

    warningFrame:ClearAllPoints()
    warningFrame:SetPoint("CENTER", UIParent, "CENTER", settings.x, settings.y)
    warningFrame.text:SetFont(fontPath, settings.size, "OUTLINE")
    warningFrame.text:SetTextColor(ns.UnpackColor(warningColor))
end)

-- One handler for everything. Three frames used to register the same events and each re-check
-- the same spell ids, which meant the order of operations depended on which frame happened to
-- register first -- a silent dependency that broke the counter once already.
local events = CreateFrame("Frame")
events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
events:RegisterUnitEvent("UNIT_AURA", "player")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_DEAD")
events:SetScript("OnEvent", function(_, event, _, _, spellId)
    if event == "PLAYER_DEAD" then
        frame:Stop()
        soulFrame:Stop()
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        -- Lockdown can still read true during the event itself, so let it lift first.
        C_Timer.After(0, function()
            RefreshFromAura()
            sphereDisplay:Refresh()
        end)

        return
    end

    if event == "PLAYER_REGEN_DISABLED" then
        -- Nothing to read from here on, so take the warning down rather than leave a stale one.
        sphereDisplay:Refresh()
        return
    end

    if event ~= "UNIT_SPELLCAST_SUCCEEDED" then
        RefreshFromAura()
        sphereDisplay:Refresh()
        return
    end

    if spellId == arcaneSurgeId then
        -- An actual cast outranks the preview, whichever modules happen to be enabled.
        ns.SetPreview(false)

        local uncertain = IsUncertain()

        if ns.logging then
            print(("|cff88ccffsurge|r spheres %.2f -> %d (%d%%%s)  talent %s  ->  soul in %.1fs")
                :format(sphereCount, math.floor(sphereCount + 0.5),
                    ConfidenceInEstimate() * 100, uncertain and ", uncertain" or "",
                    tostring(hasSavorTheMoment), SurgeDuration()))
        end

        if uncertain and ns.db.timing.warnUncertain then
            warningFrame:Flash()
        end

        -- Both displays derive this Surge's duration from the pre-Surge sphere count, so they
        -- start before it is cleared. Ordering these explicitly is what lets the reset happen
        -- inline -- it used to need deferring by a frame to win a race between three handlers.
        --
        -- Neither starts at all when the count behind that duration is a guess: the whole
        -- window would be off by the same amount, so there's nothing worth showing.
        if not (uncertain and ns.db.timing.hideUncertain) then
            frame:Begin()
            soulFrame:Begin()
        end

        sphereCount = 0
        syncedSpheres = 0
        castsSinceSync = 0

        return
    end

    if InCombatLockdown() then
        AccumulateSphere()
    end

    if spellId == arcaneBarrageId and soulFrame.expirationTime then
        soulFrame:Recalc(true, true)
    end
end)
