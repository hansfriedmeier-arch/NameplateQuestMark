local addonName, ns = ...

-- Shows a "!" next to enemy nameplates whose unit belongs to an active quest.
-- Default Forever nameplates: anchored to UnitFrame.HealthBarsContainer.healthBar.
-- BetterNamePlates: anchored to its own plate view (basePlate.BetterNamePlatesView), which
-- replaces the Blizzard health bar and uses its own scale.
--
-- Low overhead:
-- * visible plates are tracked from NAME_PLATE_UNIT_ADDED/REMOVED (no 1..40 scans)
-- * marks are only touched when their state or anchor changes
-- * quest events are merged into one update
-- * the relation of a new unit is not always known when its plate appears: new plates are
--   re-checked after 0.5, 1.5 and 3 s, then plates without a mark every 3 s; the timer stops
--   when there is nothing left to check

local MARK_TEXT = "!"
local MARK_SIZE = 20
local MARK_COLOR = { 1, 0.82, 0 }

local TICK = 0.5                     -- timer interval while checks are pending
local RETRY_DELAYS = { 0.5, 1.5, 3 } -- re-checks after a plate appears (seconds after it appeared)
local SWEEP_DELAY = 3                -- then: re-check plates without a mark this often
local QUEST_DELAY = 0.2              -- merge quest events that arrive together

local GetTime = GetTime
local UnitIsDead = UnitIsDead
local UnitCanAttack = UnitCanAttack
local GetNamePlateForUnit = C_NamePlate.GetNamePlateForUnit
local UnitIsRelatedToActiveQuest = C_QuestLog.UnitIsRelatedToActiveQuest
local issecretvalue = issecretvalue or function() return false end

local marks = {}     -- nameplate -> mark frame (nameplates are pooled, so marks are reused)
local active = {}    -- unit token -> nameplate, for every visible nameplate
local shown = {}     -- unit token -> true while its mark is shown
local nextCheck = {} -- unit token -> GetTime() of its next timed re-check
local tries = {}     -- unit token -> timed re-checks done so far

local function GetAnchor(plate)
	local view = plate.BetterNamePlatesView
	if view and view:IsShown() then
		return view.healthForeground or view.health or view
	end
	local unitFrame = plate.UnitFrame
	if unitFrame and not unitFrame:IsForbidden() then
		local container = unitFrame.HealthBarsContainer
		return (container and container.healthBar) or unitFrame.healthBar or unitFrame
	end
	return plate
end

local function GetMark(plate)
	local mark = marks[plate]
	if not mark then
		mark = CreateFrame("Frame", nil, plate)
		mark:SetSize(MARK_SIZE, MARK_SIZE)
		mark.text = mark:CreateFontString(nil, "OVERLAY")
		mark.text:SetFont(STANDARD_TEXT_FONT, MARK_SIZE, "THICKOUTLINE")
		mark.text:SetTextColor(MARK_COLOR[1], MARK_COLOR[2], MARK_COLOR[3])
		mark.text:SetText(MARK_TEXT)
		mark.text:SetPoint("CENTER")
		mark:Hide()
		marks[plate] = mark
	end
	return mark
end

-- plain booleans only: a secret answer counts as "unknown" and shows nothing
local function IsTrue(value)
	return value == true and not issecretvalue(value)
end

local function IsQuestEnemy(unit)
	if UnitIsDead(unit) or not IsTrue(UnitCanAttack("player", unit)) then
		return false
	end
	return IsTrue(UnitIsRelatedToActiveQuest(unit))
end

local function HideMark(unit)
	if shown[unit] then
		shown[unit] = nil
		local mark = marks[active[unit]]
		if mark then
			mark:Hide()
		end
	end
end

local function ShowMark(unit, plate)
	local mark = GetMark(plate)
	local anchor = GetAnchor(plate)
	if mark.anchor ~= anchor then
		mark.anchor = anchor
		mark:SetParent(anchor)
		mark:SetFrameLevel(anchor:GetFrameLevel() + 10)
		mark:ClearAllPoints()
		mark:SetPoint("RIGHT", anchor, "LEFT", -2, 0)
	end
	if not shown[unit] then
		shown[unit] = true
		mark:Show()
	end
end

local function UpdateUnit(unit)
	local plate = active[unit]
	if not plate then
		return
	end
	if plate:IsForbidden() or not IsQuestEnemy(unit) then
		HideMark(unit)
	else
		ShowMark(unit, plate)
	end
end

local function UpdateAll()
	for unit in pairs(active) do
		UpdateUnit(unit)
	end
end

-- timed re-checks: one timer for all plates, only running while something is pending
local ticker

local function Tick()
	local now = GetTime()
	local pending = false
	for unit, at in pairs(nextCheck) do
		if now >= at then
			UpdateUnit(unit)
			local n = (tries[unit] or 0) + 1
			tries[unit] = n
			local delay = RETRY_DELAYS[n + 1]
			if delay then
				nextCheck[unit] = at + delay - RETRY_DELAYS[n]
			elseif shown[unit] then
				nextCheck[unit] = nil -- marked: quest events take care of it from now on
			else
				nextCheck[unit] = now + SWEEP_DELAY
			end
		end
		if nextCheck[unit] then
			pending = true
		end
	end
	if not pending and ticker then
		ticker:Cancel()
		ticker = nil
	end
end

local function Schedule(unit, at)
	nextCheck[unit] = at
	if not ticker then
		ticker = C_Timer.NewTicker(TICK, Tick)
	end
end

-- after a quest change, plates that lost their mark go back to the slow sweep
local function RescheduleUnmarked()
	local at = GetTime() + SWEEP_DELAY
	for unit in pairs(active) do
		if not shown[unit] and not nextCheck[unit] then
			Schedule(unit, at)
		end
	end
end

local questPending = false
local function QuestFlush()
	questPending = false
	UpdateAll()
	RescheduleUnmarked()
end

local function QuestChanged()
	if not questPending then
		questPending = true
		C_Timer.After(QUEST_DELAY, QuestFlush)
	end
end

local function AddUnit(unit)
	local plate = GetNamePlateForUnit(unit)
	if not plate then
		return
	end
	active[unit] = plate
	shown[unit] = nil
	local mark = marks[plate]
	if mark then
		mark:Hide()
		mark.anchor = nil -- BetterNamePlates may have swapped the view of this pooled plate
	end
	tries[unit] = 0
	UpdateUnit(unit)
	Schedule(unit, GetTime() + RETRY_DELAYS[1])
end

local function RemoveUnit(unit)
	HideMark(unit)
	active[unit] = nil
	nextCheck[unit] = nil
	tries[unit] = nil
end

local frame = CreateFrame("Frame")
local handlers = {}

function handlers.NAME_PLATE_UNIT_ADDED(unit)
	AddUnit(unit)
	-- BetterNamePlates builds its plate view for the same event: anchor again next frame
	C_Timer.After(0, function() UpdateUnit(unit) end)
end

handlers.NAME_PLATE_UNIT_REMOVED = RemoveUnit

-- fires for every unit in the game; only a shown mark needs it (hide when the unit dies)
function handlers.UNIT_HEALTH(unit)
	if shown[unit] and UnitIsDead(unit) then
		HideMark(unit)
	end
end

-- attackable state changed (e.g. a neutral mob turned hostile)
function handlers.UNIT_FLAGS(unit)
	if active[unit] then
		UpdateUnit(unit)
	end
end

handlers.QUEST_LOG_UPDATE = QuestChanged
handlers.QUEST_ACCEPTED = QuestChanged
handlers.QUEST_REMOVED = QuestChanged
handlers.QUEST_TURNED_IN = QuestChanged

function handlers.UNIT_QUEST_LOG_CHANGED(unit)
	if unit == "player" then
		QuestChanged()
	end
end

function handlers.PLAYER_ENTERING_WORLD()
	for unit in pairs(active) do
		RemoveUnit(unit)
	end
	for i = 1, 40 do
		local unit = "nameplate" .. i
		if UnitExists(unit) then
			AddUnit(unit)
		end
	end
end

frame:SetScript("OnEvent", function(_, event, ...)
	handlers[event](...)
end)
for event in pairs(handlers) do
	frame:RegisterEvent(event)
end

-- /nqm prints what the game reports for every visible nameplate
SLASH_NAMEPLATEQUESTMARK1 = "/nqm"
SlashCmdList.NAMEPLATEQUESTMARK = function()
	local count = 0
	for unit in pairs(active) do
		count = count + 1
		local related = UnitIsRelatedToActiveQuest(unit)
		local attack = UnitCanAttack("player", unit)
		local name = UnitName(unit)
		print(("NQM %s: %s | attackable=%s | quest=%s | mark=%s | next check=%s"):format(unit,
			issecretvalue(name) and "?" or tostring(name),
			issecretvalue(attack) and "secret" or tostring(attack),
			issecretvalue(related) and "secret" or tostring(related),
			tostring(shown[unit] or false),
			nextCheck[unit] and ("%.1fs"):format(nextCheck[unit] - GetTime()) or "-"))
	end
	print(("NQM: %d nameplates, timer %s"):format(count, ticker and "running" or "stopped"))
end

ns.UpdateAll = UpdateAll
