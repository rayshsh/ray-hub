----------------------------------------------------------------------
-- Services
----------------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local env = (getgenv and getgenv()) or _G

-- Clean up a previous instance if the script is executed twice
if env.AutumnDice and env.AutumnDice.Unload then
	pcall(env.AutumnDice.Unload)
end

----------------------------------------------------------------------
-- Config
----------------------------------------------------------------------
local CONFIG = {
	DiceLocation = Vector3.new(-3065.865234375, 224.5791015625, 5659.744140625),
	DefaultHotkey = Enum.KeyCode.LeftControl,

	-- Auto Roll
	RollAmount = 5,           -- argument passed to LeafDiceService.RF.Roll
	RollDelay = 1,            -- seconds to wait AFTER a roll finishes, before the next one
	MaxRollErrors = 5,        -- consecutive failed rolls before the loop stops itself
	RollErrorDelay = 3,       -- seconds to wait after a failed roll before trying again

	RemoteWaitTimeout = 10,
	InvokeTimeout = 15,
	StepDelay = 1,
	TeleportSettle = 2,

	ArriveDistance = 8,
	MoveAttempts = 5,

	-- Auto Tower
	TowerRestartCooldown = 3, -- minimum seconds between tower start attempts
	TowerTickInterval = 1,    -- seconds between tower checks
	-- Best Leaf Tower: which eligible tower to pick. An eligible tower is unlocked AND its floor 1
	-- can be defeated by the best owned unit.
	--   "MostAdvanced" = the last eligible section in progression order
	--   "First"        = the first eligible section in progression order
	BestTowerPreference = "MostAdvanced",
	BestReevalInterval = 30,  -- when run state is unknown: hold the choice this long after a start
	EquipDelay = 1,           -- seconds to wait after firing EquipBestTowerTeam, before starting the tower
	EquipOnProbe = false,     -- when run state is unknown, also equip on "is it still running?" retries

	-- Optional: set this to your game's own "is a tower run active?" check.
	-- It must return true (run active) or false (no run). Leave nil to use auto-detection.
	--   IsRunActive = function() return SomeController.inRun() end,
	IsRunActive = nil,

	-- Optional: the GUI's "Floors Cleared / Best Floor / floor N" need the current floor of the run.
	-- Set GetFloor to your game's own check (must return a number), or leave nil to auto-detect
	-- through the TowerController functions listed below (only those that exist are tried).
	--   GetFloor = function() return SomeController.currentFloor() end,
	GetFloor = nil,

	-- Auto Execute: where to reload THIS script from after a rejoin. Set ONE of the two.
	--   ScriptUrl  = "https://raw.githubusercontent.com/you/repo/main/script.lua"
	--   ScriptFile = "AutumnDice.lua"   (a file saved in your executor's workspace folder)
	ScriptUrl = nil,
	ScriptFile = "AutumnDice.lua", -- default: save this script as AutumnDice.lua in your executor's workspace folder
	SettingsFile = "AutumnDice_Settings.json", -- toggle states are saved here for the restore after rejoin
	-- Small gated loader written while Auto Execute is ON (deleted when it is turned OFF). Your autoexec
	-- "Dice" loader runs every .txt in Dice/CustomLoadings on each join, which re-launches the script.
	LoaderStub = "Dice/CustomLoadings/AutumnDice.txt",

	-- Auto Reconnect
	ReconnectFile = "AutumnDice_Server.json", -- remembers the server (PlaceId/JobId) to rejoin
	ReconnectMaxAttempts = 5,
	ReconnectDelay = 5,       -- seconds before the first attempt
	ReconnectBackoff = 1.5,   -- the delay is multiplied by this after every failed attempt
	FloorCandidates = { "getFloor", "getCurrentFloor", "currentFloor", "getFloorNumber" },
	-- Auto-detection looks for these functions on TowerController (only if they exist).
	RunActiveCandidates = { "isInTower", "isRunning", "isInRun", "hasActiveRun" },
}

local TOWER_MODES = { "Single", "Best Leaf Tower" }

----------------------------------------------------------------------
-- State (single source of truth; GUI listens to it)
----------------------------------------------------------------------
local State = {
	Features = {
		AutoDice = false, AutoTower = false, AutoEquipBest = false,
		-- Miscellaneous (GUI placeholders only, no logic attached yet)
		AntiAfk = false, AutoReconnect = false, AutoExecute = false,
	},
	Status = "Idle",
	Detail = "Enable \"Auto Roll Autumn Dice\" to start.",
	Hotkey = CONFIG.DefaultHotkey,
	Rolls = 0,

	TowerMode = "Best Leaf Tower",
	SelectedTower = nil,
	TowerStatus = "Off",
	TowerDetail = "Auto Tower is disabled.",

	TowerStats = {
		Runs = 0,          -- successful tower starts made by Auto Tower
		Floors = 0,        -- floors cleared since the script started
		Best = 0,          -- best floor seen
		Floor = nil,       -- current floor (nil = unknown)
		LastFloor = nil,   -- internal: previous floor reading
		Tracking = false,  -- true once a floor reading has worked
	},

	-- Session reward collection: totals accumulate across every tower run
	Rewards = {
		totals = {},       -- [rewardName] = accumulated amount
		order = {},        -- reward names in the order they were first earned
	},
}

local listeners = {}
local function onChange(fn) table.insert(listeners, fn) end
local function notify()
	for _, fn in ipairs(listeners) do
		pcall(fn)
	end
end

-- Auto Roll statuses
local STATUS = {
	Idle             = { text = "Idle",               color = Color3.fromRGB(150, 150, 160) },
	Initializing     = { text = "Initializing",       color = Color3.fromRGB(120, 170, 255) },
	Teleporting      = { text = "Teleporting",        color = Color3.fromRGB(120, 170, 255) },
	Syncing          = { text = "Syncing",            color = Color3.fromRGB(120, 170, 255) },
	Moving           = { text = "Moving",             color = Color3.fromRGB(120, 170, 255) },
	Rolling          = { text = "Rolling",            color = Color3.fromRGB(255, 200, 80) },
	AutoRollEnabled  = { text = "Auto Roll Enabled",  color = Color3.fromRGB(90, 215, 120) },
	AutoRollDisabled = { text = "Auto Roll Disabled", color = Color3.fromRGB(255, 150, 70) },
	Error            = { text = "Error",              color = Color3.fromRGB(240, 85, 85) },
}

local DEFAULT_DETAIL = {
	Idle = "Enable \"Auto Roll Autumn Dice\" to start.",
	Initializing = "Preparing Autumn Dice automation.",
	Teleporting = "Traveling to Autumn World.",
	Syncing = "Synchronizing player data.",
	Moving = "Traveling to the Dice Location.",
	Rolling = "Rolling Autumn Dice.",
	AutoRollEnabled = "The custom rolling loop is active.",
	AutoRollDisabled = "The rolling loop has stopped.",
	Error = "An issue occurred while attempting to roll.",
}

local function SetStatus(key, detail)
	State.Status = key
	State.Detail = detail or DEFAULT_DETAIL[key] or ""
	notify()
end

-- Auto Tower statuses
local BLUE = Color3.fromRGB(120, 170, 255)
local GREEN = Color3.fromRGB(90, 215, 120)
local YELLOW = Color3.fromRGB(255, 200, 80)
local ORANGE = Color3.fromRGB(255, 150, 70)
local GRAY = Color3.fromRGB(150, 150, 160)
local RED = Color3.fromRGB(240, 85, 85)

local TOWER_STATUS = {
	Off             = { text = "Auto Tower: Off",                         color = GRAY },
	WaitingData     = { text = "Waiting for Player Data",                 color = GRAY },
	SingleStarting  = { text = "Single: Starting Selected Tower",         color = BLUE },
	SingleProgress  = { text = "Single: Tower In Progress",               color = YELLOW },
	SingleLocked    = { text = "Single: Tower Locked",                    color = ORANGE },
	BestSearching   = { text = "Best Leaf Tower: Searching",              color = BLUE },
	BestSelected    = { text = "Best Leaf Tower: Tower Selected",         color = BLUE },
	BestProgress    = { text = "Best Leaf Tower: Tower In Progress",      color = YELLOW },
	NoUnit          = { text = "No Unit Available",                       color = ORANGE },
	NoTowers        = { text = "No Suitable Tower",                       color = ORANGE },
	Error           = { text = "Error",                                   color = RED },
}

local function SetTowerStatus(key, detail)
	if State.TowerStatus == key and State.TowerDetail == (detail or "") then
		return
	end
	State.TowerStatus = key
	State.TowerDetail = detail or ""
	notify()
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function getRemote(path, timeout)
	local node = ReplicatedStorage
	for _, name in ipairs(path) do
		node = node:WaitForChild(name, timeout)
		if not node then
			return nil
		end
	end
	return node
end

local function pathString(path)
	return "ReplicatedStorage." .. table.concat(path, ".")
end

-- InvokeServer with a timeout. `inFlight` stays set until the server really answers,
-- so a new call on the same remote is never started while an old one is pending.
local inFlight = {}
local function invoke(remote, ...)
	local args = table.pack(...)
	local done, ok, result = false, false, nil

	local waited = os.clock()
	while inFlight[remote] do
		if os.clock() - waited > CONFIG.InvokeTimeout then
			return false, "previous call still pending"
		end
		task.wait(0.1)
	end

	inFlight[remote] = true
	task.spawn(function()
		ok, result = pcall(function()
			return remote:InvokeServer(table.unpack(args, 1, args.n))
		end)
		done = true
		inFlight[remote] = nil
	end)

	local t0 = os.clock()
	while not done do
		if os.clock() - t0 > CONFIG.InvokeTimeout then
			return false, "timed out"
		end
		task.wait(0.05)
	end
	return ok, result
end

local function getHRP(timeout)
	local deadline = os.clock() + (timeout or 0)
	repeat
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hrp and hum and hum.Health > 0 then
			return hrp
		end
		if timeout then task.wait(0.2) end
	until not timeout or os.clock() > deadline
	return nil
end

----------------------------------------------------------------------
-- AUTO ROLL
----------------------------------------------------------------------
local runId = 0               -- bumped on every start/stop; stale workers exit
local workerActive = false    -- true while a roll worker exists (guarantees a single loop)

local function alive(id)
	return runId == id and State.Features.AutoDice
end

local function sleep(id, seconds)
	local t0 = os.clock()
	while os.clock() - t0 < seconds do
		if not alive(id) then return false end
		task.wait(0.05)
	end
	return alive(id)
end

local function failAndStop(id, message)
	warn("[AutumnDice] " .. message)
	if runId == id then
		State.Features.AutoDice = false
		runId += 1
		SetStatus("Error", message)
	end
	return false
end

local function moveTo(id, target)
	local hrp = getHRP(15)
	if not hrp then return false, "Character not found." end

	for _ = 1, CONFIG.MoveAttempts do
		if not alive(id) then return false, "Cancelled." end
		hrp = getHRP(5)
		local char = player.Character
		if not hrp or not char then return false, "Character lost while moving." end
		if (hrp.Position - target).Magnitude <= CONFIG.ArriveDistance then break end

		char:PivotTo(CFrame.new(target))
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
		task.wait(0.4)
	end

	hrp = getHRP(5)
	if not hrp then return false, "Character lost while moving." end
	local finalDist = (hrp.Position - target).Magnitude
	if finalDist > CONFIG.ArriveDistance + 5 then
		return false, ("Could not reach the dice location (%.0f studs away)."):format(finalDist)
	end
	return true
end

local function runSetup(id)
	SetStatus("Initializing")
	local paths = {
		travel = { "Network", "AutumnService", "RF", "Travel" },
		sync = { "Network", "AppleService", "RF", "Sync" },
		roll = { "Network", "LeafDiceService", "RF", "Roll" },
	}
	local remotes = {}
	for key, path in pairs(paths) do
		remotes[key] = getRemote(path, CONFIG.RemoteWaitTimeout)
		if not alive(id) then return nil end
		if not remotes[key] then
			return failAndStop(id, "Remote not found: " .. pathString(path)) and nil
		end
	end
	if not sleep(id, CONFIG.StepDelay) then return nil end

	-- 1. Teleport to Autumn World
	SetStatus("Teleporting")
	local charBefore = player.Character
	local hrpBefore = getHRP()
	local posBefore = hrpBefore and hrpBefore.Position
	local ok, res = invoke(remotes.travel, "Autumn")
	if not alive(id) then return nil end
	if not ok or res == false then
		return failAndStop(id, "Travel failed: " .. tostring(res)) and nil
	end
	local t0 = os.clock()
	while alive(id) and os.clock() - t0 < 10 do
		local hrp = getHRP()
		if player.Character ~= charBefore then break end
		if hrp and posBefore and (hrp.Position - posBefore).Magnitude > 100 then break end
		task.wait(0.25)
	end
	if not alive(id) then return nil end
	if not getHRP(15) then
		return failAndStop(id, "Character did not load after teleport.") and nil
	end
	if not sleep(id, CONFIG.TeleportSettle) then return nil end

	-- 2. Sync the player
	SetStatus("Syncing")
	ok, res = invoke(remotes.sync)
	if not alive(id) then return nil end
	if not ok or res == false then
		return failAndStop(id, "Sync failed: " .. tostring(res)) and nil
	end
	if not sleep(id, CONFIG.StepDelay) then return nil end

	-- 3. Move to the dice location
	SetStatus("Moving")
	local moved, err = moveTo(id, CONFIG.DiceLocation)
	if not alive(id) then return nil end
	if not moved then
		return failAndStop(id, err or "Movement failed.") and nil
	end
	if not sleep(id, CONFIG.StepDelay) then return nil end

	return remotes.roll
end

local function rollLoop(id, rollRemote)
	local consecutiveErrors = 0
	State.Rolls = 0

	while alive(id) do
		SetStatus("Rolling", ("Rolling Autumn Dice. Rolls completed: %d"):format(State.Rolls))
		local ok, res = invoke(rollRemote, CONFIG.RollAmount)

		-- the toggle may have been turned off during the roll: it finishes, nothing new starts
		if not alive(id) then return end

		if ok and res ~= false then
			consecutiveErrors = 0
			State.Rolls += 1
			SetStatus("AutoRollEnabled", ("The custom rolling loop is active. Rolls completed: %d"):format(State.Rolls))
			if not sleep(id, CONFIG.RollDelay) then return end
		else
			consecutiveErrors += 1
			local msg = ("Roll failed (%d/%d): %s"):format(consecutiveErrors, CONFIG.MaxRollErrors, tostring(res))
			warn("[AutumnDice] " .. msg)
			if consecutiveErrors >= CONFIG.MaxRollErrors then
				failAndStop(id, msg .. " Auto Roll stopped.")
				return
			end
			SetStatus("Error", msg)
			if not sleep(id, CONFIG.RollErrorDelay) then return end
		end
	end
end

local function worker(id)
	while workerActive do
		if not alive(id) then return end
		task.wait(0.05)
	end
	if not alive(id) then return end

	workerActive = true
	local ok, err = pcall(function()
		local rollRemote = runSetup(id)
		if rollRemote and alive(id) then
			rollLoop(id, rollRemote)
		end
	end)
	workerActive = false

	if not ok then
		failAndStop(id, "Unexpected error: " .. tostring(err))
	end
end

----------------------------------------------------------------------
-- AUTO TOWER
----------------------------------------------------------------------
-- Existing references (loaded lazily so a missing module shows an Error instead of crashing)
local TurkeyTowers, TowerController, DataController, BuffController, EntryRegistry
local RESTART_COOLDOWN = CONFIG.TowerRestartCooldown

local Tower = {
	loaded = false,
	lastLoadTry = -math.huge,
	loadError = nil,

	names = {},               -- current tower names from TurkeyTowers.Sections
	activeName = nil,         -- tower the monitor is currently handling
	lastStarted = false,      -- last start attempt for activeName succeeded / run assumed active
	lockedSince = 0,          -- time of the last successful start (holds the Best Leaf Tower choice)
	bestExtra = nil,          -- detail text of the current Best Leaf Tower choice (best unit)

	selectionEpoch = 0,       -- bumped when mode / tower / Auto Tower changes (cancels a pending start)
	startInFlight = false,    -- prevents duplicate start attempts
	workerActive = false,     -- prevents duplicate monitoring loops
	wake = false,             -- ask the loop to re-evaluate right away (mode / tower changed)
}

local towerRunId = 0
local lastAttemptTime = 0

local function towerAlive(id)
	return towerRunId == id and State.Features.AutoTower
end

local function loadTowerModules()
	if Tower.loaded then return true end
	if os.clock() - Tower.lastLoadTry < 3 then return false end
	Tower.lastLoadTry = os.clock()

	local ok, err = pcall(function()
		local features = ReplicatedStorage.Framework.Features
		local tt = require(features.Autumn.TurkeyTowers)
		local tc = require(features.Towers.TowerController)
		local dc = require(features.Data.DataController)
		local bc = require(features.Buffs.BuffController)
		local er = require(features.Inventory.EntryRegistry)
		TurkeyTowers, TowerController, DataController, BuffController, EntryRegistry = tt, tc, dc, bc, er
	end)

	if not ok then
		Tower.loadError = tostring(err)
		return false
	end
	Tower.loaded = true
	Tower.loadError = nil
	return true
end

-- --------------------------------------------------------------------------
-- Data helpers (reused)
-- --------------------------------------------------------------------------

local function getMilestones()
	if not DataController then return nil end
	local ok, result = pcall(function()
		return DataController.Autumn.Milestones()
	end)

	if ok and type(result) == "table" then
		return result
	end

	return nil
end

local function findSectionByName(name)
	if not TurkeyTowers then return nil end
	for index, section in ipairs(TurkeyTowers.Sections) do
		if section.name == name then
			return section, index
		end
	end
	return nil
end

-- --------------------------------------------------------------------------
-- Combat calculation (best owned unit vs. a tower floor)
-- --------------------------------------------------------------------------

-- Finds the player's best unit (highest damage), mirroring the server's
-- EquipBestTowerTeam ranking logic.
-- Returns { key, name, damage, health }, or nil + reason:
--   "unavailable" = inventory / registry not readable yet, "none" = no units owned
local function getBestUnit()
	if not DataController or not EntryRegistry then
		return nil, "unavailable"
	end

	local ok, best = pcall(function()
		local found = nil

		for key in DataController.Inventory() do
			local entry = DataController.Inventory[key]()
			if entry then
				local config = EntryRegistry.getEntryConfig(entry.name)
				if config and config.kind == "Unit" then
					local damage = config.damage(entry.attributes)

					if type(damage) == "number" and (not found or damage > found.damage) then
						found = {
							key = key,
							name = entry.name,
							damage = damage,
							health = config.health(entry.attributes),
						}
					end
				end
			end
		end

		return found
	end)

	if not ok then
		return nil, "unavailable"
	end
	if best then
		return best
	end
	return nil, "none"
end

-- Buff multiplier with a safe default (a missing buff counts as x1)
local function getBuff(name)
	local ok, value = pcall(function()
		return BuffController.GetBuff(name)
	end)
	if ok and type(value) == "number" then
		return value
	end
	return 1
end

-- Simulates one floor fight using the game's combat rules (TowerClass.completeFloor):
-- the unit strikes first; if the enemy survives, it hits back. Repeats until the enemy
-- dies or the unit runs out of health.
local function canDefeatFloor(section, floor, unit)
	local ok, enemyHealth, enemyDamage = pcall(function()
		return TurkeyTowers.EnemyHealth(section, floor), TurkeyTowers.EnemyDamage(section, floor)
	end)
	if not ok or type(enemyHealth) ~= "number" or type(enemyDamage) ~= "number" then
		return false
	end

	-- Effective stats, same as the server computes them
	local damage = unit.damage * getBuff("Damage Multiplier")
	local health = (unit.health or 0) * getBuff("Health Multiplier")

	if damage <= 0 then
		return false -- unit can never kill the enemy
	end

	-- Turns needed to bring the enemy to 0 HP. The unit always strikes first, so it only
	-- takes damage on the turns where the enemy is still alive afterwards.
	local turnsNeeded = math.ceil(enemyHealth / damage)
	local damageTaken = (turnsNeeded - 1) * enemyDamage

	return health > damageTaken
end

-- Convenience: can the player's best unit clear floor 1 (every run starts at floor 1)?
local function canBestUnitDefeatFloor(section, floor)
	local bestUnit = getBestUnit()
	if not bestUnit then
		return false
	end

	return canDefeatFloor(section, floor or 1, bestUnit)
end

-- --------------------------------------------------------------------------
-- Selection logic - two separate modes
-- --------------------------------------------------------------------------

local isRunActive -- defined in "Tower control" below

-- Best Leaf Tower: walks TurkeyTowers.Sections in progression order and keeps the unlocked
-- sections whose floor 1 the best unit can defeat. Tower progress (TurkeyBest / 100/100)
-- is NOT used here.
-- Returns: section, unit  |  nil, reason ("unavailable" | "nounit" | "none")
local function findNextSection()
	local milestones = getMilestones()
	if not milestones then
		return nil, "unavailable"
	end

	local unit, unitReason = getBestUnit()
	if not unit then
		return nil, (unitReason == "none") and "nounit" or "unavailable"
	end

	local pick = nil
	for index, section in ipairs(TurkeyTowers.Sections) do
		local okU, unlocked = pcall(TurkeyTowers.IsUnlocked, milestones, index)
		if okU and unlocked and canDefeatFloor(section, 1, unit) then
			pick = section
			if CONFIG.BestTowerPreference == "First" then
				break
			end
		end
	end

	if pick then
		return pick, unit
	end
	return nil, "none"
end

-- While a run is in progress the current Best Leaf Tower choice is kept (no recalculation,
-- no switching). With unknown run state it is held for CONFIG.BestReevalInterval seconds
-- after a successful start.
local function currentRunLocked()
	if not Tower.activeName then
		return false
	end

	local active = isRunActive()
	if active == true then
		return true
	end
	if active == nil and Tower.lastStarted and os.clock() - Tower.lockedSince < CONFIG.BestReevalInterval then
		return true
	end
	return false
end

-- Returns: section, nil, extraDetail  |  nil, statusKey, detail
local function selectBest()
	if currentRunLocked() then
		local locked = findSectionByName(Tower.activeName)
		if locked then
			return locked, nil, Tower.bestExtra
		end
	end

	local section, unitOrReason = findNextSection()
	if section then
		Tower.bestExtra = ("best unit: %s"):format(tostring(unitOrReason.name))
		return section, nil, Tower.bestExtra
	end

	if unitOrReason == "unavailable" then
		return nil, "WaitingData", "Player data is not loaded yet."
	elseif unitOrReason == "nounit" then
		return nil, "NoUnit", "You don't own any units."
	end
	return nil, "NoTowers", "The best unit cannot defeat floor 1 of any unlocked tower."
end

-- Single: the tower chosen in the "Select Tower" dropdown.
-- Only checks that the tower exists and is unlocked. Completion (100/100) is NEVER used here.
local function selectSingle(milestones)
	local name = State.SelectedTower
	if type(name) ~= "string" or name == "" then
		return nil, "Error", "No tower selected."
	end

	local section, index = findSectionByName(name)
	if not section then
		return nil, "Error", ("\"%s\" is not an available tower."):format(name)
	end

	local okU, unlocked = pcall(TurkeyTowers.IsUnlocked, milestones, index)
	if not okU then
		return nil, "Error", "Could not check whether the tower is unlocked."
	end
	if not unlocked then
		return nil, "SingleLocked", ("%s is locked."):format(name)
	end

	return section
end

-- --------------------------------------------------------------------------
-- Tower control (shared by both modes)
-- --------------------------------------------------------------------------

-- true = a run is active, false = no run, nil = cannot tell
function isRunActive()
	if CONFIG.IsRunActive then
		local ok, result = pcall(CONFIG.IsRunActive)
		if ok and type(result) == "boolean" then
			return result
		end
		return nil
	end

	if TowerController then
		for _, fnName in ipairs(CONFIG.RunActiveCandidates) do
			local fn = TowerController[fnName]
			if type(fn) == "function" then
				local ok, result = pcall(fn)
				if ok and type(result) == "boolean" then
					return result
				end
			end
		end
	end

	return nil
end

-- Auto Equip Best Unit: fires Towers.EquipBestTowerTeam (signal is created once and cached)
local Equip = { signal = nil }

local function getEquipSignal()
	if Equip.signal then
		return Equip.signal
	end

	local ok, result = pcall(function()
		local Network = require(ReplicatedStorage.Packages.Network)
		local comm = Network.ClientComm.new(ReplicatedStorage.Network, false, "Towers")
		return comm:GetSignal("EquipBestTowerTeam")
	end)

	if ok and result then
		Equip.signal = result
		return result
	end
	return nil, tostring(result)
end

local function equipBestTeam()
	local signal, err = getEquipSignal()
	if not signal then
		return false, err or "EquipBestTowerTeam signal not found"
	end

	local ok, fireErr = pcall(function()
		signal:Fire()
	end)
	if not ok then
		return false, tostring(fireErr)
	end
	return true
end

-- Returns: started(boolean), reason ("cooldown" | "busy" | "cancelled" | "declined" | "equip failed: ..." | "error: ...")
-- doEquip: equip the best team first (only ever done here, i.e. once per start attempt)
local function tryStartTower(section, doEquip)
	if Tower.startInFlight then
		return false, "busy"
	end

	local now = os.clock()
	if now - lastAttemptTime < RESTART_COOLDOWN then
		return false, "cooldown"
	end

	lastAttemptTime = now
	Tower.startInFlight = true

	if doEquip then
		local epoch = Tower.selectionEpoch
		local equipped, equipErr = equipBestTeam()
		if not equipped then
			Tower.startInFlight = false
			return false, "equip failed: " .. tostring(equipErr)
		end

		-- give the equip change time to be processed before entering the tower
		task.wait(CONFIG.EquipDelay)

		-- Auto Tower was turned off, or the mode / tower changed, while waiting: do not start
		if not State.Features.AutoTower or Tower.selectionEpoch ~= epoch then
			Tower.startInFlight = false
			return false, "cancelled"
		end
	end

	local ok, result = pcall(TowerController.startTower, section.name)
	Tower.startInFlight = false

	if ok and result == true then
		return true
	end
	if ok then
		return false, "declined"
	end
	return false, "error: " .. tostring(result)
end

-- Starts (or keeps monitoring) the given tower. Used by BOTH modes.
-- `extra` is optional detail text shown after the tower name (e.g. the best unit).
local function driveTower(mode, section, extra)
	local single = (mode == "Single")
	local progressKey = single and "SingleProgress" or "BestProgress"
	local startKey = single and "SingleStarting" or "BestSelected"
	local detail = extra and (section.name .. " - " .. extra) or section.name

	if Tower.activeName ~= section.name then
		Tower.activeName = section.name
		Tower.lastStarted = false
	end

	-- never start another tower while a run is active
	local active = isRunActive()
	if active == true then
		Tower.lastStarted = true
		SetTowerStatus(progressKey, detail)
		return
	end

	-- still inside the restart cooldown: keep showing the right state, do nothing else
	if Tower.startInFlight or os.clock() - lastAttemptTime < RESTART_COOLDOWN then
		SetTowerStatus(Tower.lastStarted and progressKey or startKey, detail)
		return
	end

	-- Equip the best team before this start attempt. If a run is known to be idle, always equip.
	-- If run state is unknown and a run is assumed active, this attempt is only a "probe"
	-- (startTower declines while a run is active), so it does not re-equip (see CONFIG.EquipOnProbe).
	local wasRunning = Tower.lastStarted
	local doEquip = State.Features.AutoEquipBest
		and (active == false or not wasRunning or CONFIG.EquipOnProbe)

	Tower.lastStarted = false
	SetTowerStatus(startKey, doEquip and (detail .. " - equipping best team") or detail)

	local started, reason = tryStartTower(section, doEquip)
	if started then
		Tower.lastStarted = true
		Tower.lockedSince = os.clock()
		local S = State.TowerStats
		S.Runs += 1
		S.LastFloor = nil
		S.Floor = nil
		notify()
		SetTowerStatus(progressKey, detail)
	elseif reason == "cooldown" or reason == "busy" or reason == "cancelled" then
		-- nothing to do
	elseif reason == "declined" then
		if active == false then
			SetTowerStatus("Error", ("%s: the game declined to start the tower."):format(section.name))
		else
			-- cannot tell whether a run is active; a declined start usually means one is
			Tower.lastStarted = true
			SetTowerStatus(progressKey, detail .. " (start declined, run likely active)")
		end
	else
		SetTowerStatus("Error", ("%s: %s"):format(section.name, reason))
	end
end

local function readFloor()
	if CONFIG.GetFloor then
		local ok, result = pcall(CONFIG.GetFloor)
		return (ok and type(result) == "number") and result or nil
	end
	if TowerController then
		for _, fnName in ipairs(CONFIG.FloorCandidates) do
			local fn = TowerController[fnName]
			if type(fn) == "function" then
				local ok, result = pcall(fn)
				if ok and type(result) == "number" then
					return result
				end
			end
		end
	end
	return nil
end

local function trackFloor()
	local S = State.TowerStats
	local floor = readFloor()
	if not floor or isRunActive() == false then return end

	S.Tracking = true
	local changed = (S.Floor ~= floor)
	if S.LastFloor and floor > S.LastFloor then
		S.Floors += floor - S.LastFloor
	end
	S.LastFloor = floor
	S.Floor = floor
	if floor > S.Best then S.Best = floor end
	if changed then notify() end
end

local function towerTick()
	if not loadTowerModules() then
		if not Tower.loaded then
			SetTowerStatus("Error", "Tower modules unavailable: " .. tostring(Tower.loadError or "retrying..."))
		end
		return
	end

	pcall(trackFloor)

	local mode = State.TowerMode
	local section, key, detail

	if mode == "Single" then
		-- Single mode only needs the unlock data; completion and unit strength are never consulted
		local milestones = getMilestones()
		if not milestones then
			Tower.activeName = nil
			SetTowerStatus("WaitingData", "Player data is not loaded yet.")
			return
		end
		section, key, detail = selectSingle(milestones)
	else
		-- Best Leaf Tower mode: best unit vs. floor 1 (see findNextSection)
		mode = "Best Leaf Tower"
		section, key, detail = selectBest()
	end

	if not section then
		Tower.activeName = nil
		SetTowerStatus(key, detail)
		return
	end

	-- on success, `detail` is optional extra text (Best Leaf Tower: the best unit); nil in Single
	driveTower(mode, section, detail)
end

-- The one and only monitoring loop
local function towerWorker(id)
	while Tower.workerActive do
		if not towerAlive(id) then return end
		task.wait(0.05)
	end
	if not towerAlive(id) then return end

	Tower.workerActive = true
	while towerAlive(id) do
		local ok, err = pcall(towerTick)
		if not ok then
			warn("[AutumnDice] Tower error: " .. tostring(err))
			SetTowerStatus("Error", tostring(err))
		end

		-- wait for the next tick, but react immediately to a mode / tower change
		local t0 = os.clock()
		while towerAlive(id) and not Tower.wake and os.clock() - t0 < CONFIG.TowerTickInterval do
			task.wait(0.05)
		end
		Tower.wake = false
	end
	Tower.workerActive = false
end

local function resetTowerRuntime()
	Tower.selectionEpoch += 1
	Tower.activeName = nil
	Tower.lastStarted = false
	Tower.lockedSince = 0
	Tower.bestExtra = nil
	Tower.wake = true
end

local function SetTowerMode(mode)
	if not table.find(TOWER_MODES, mode) or State.TowerMode == mode then return end
	State.TowerMode = mode
	resetTowerRuntime()
	if State.Features.AutoTower then
		SetTowerStatus(mode == "Single" and "SingleStarting" or "BestSearching", "Mode changed to " .. mode .. ".")
	end
	notify()
end

local function SetSelectedTower(name)
	if type(name) ~= "string" or not table.find(Tower.names, name) or State.SelectedTower == name then return end
	State.SelectedTower = name
	Tower.selectionEpoch += 1
	Tower.activeName = nil
	Tower.lastStarted = false
	Tower.wake = true
	notify()
end

----------------------------------------------------------------------
-- Feature control (used by the GUI and by other scripts)
----------------------------------------------------------------------
----------------------------------------------------------------------
-- ANTI AFK
-- Event driven: Roblox fires Player.Idled after ~2 minutes without input, and
-- VirtualUser input resets the idle timer. While disabled there is no connection
-- and no loop, so it costs nothing.
----------------------------------------------------------------------
local AntiAfk = { conn = nil }

local function setAntiAfk(enabled)
	if not enabled then
		if AntiAfk.conn then
			AntiAfk.conn:Disconnect()
			AntiAfk.conn = nil
		end
		return
	end
	if AntiAfk.conn then return end

	local ok, VirtualUser = pcall(function() return game:GetService("VirtualUser") end)
	if not ok or not VirtualUser then
		warn("[AutumnDice] Anti AFK unavailable: VirtualUser service not found")
		State.Features.AntiAfk = false -- keep the toggle truthful
		return
	end

	AntiAfk.conn = player.Idled:Connect(function()
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
	end)
end

----------------------------------------------------------------------
-- AUTO EXECUTE
-- Roblox kills the whole Lua VM on a rejoin, so the script is re-run through the
-- executor's queue_on_teleport. The queued loader only runs when the saved settings
-- file still says AutoExecute = true, which is how turning the toggle off cancels it
-- (a queued teleport script cannot be removed). Toggle states are saved to the
-- settings file and restored by the new instance.
----------------------------------------------------------------------
local HttpService = game:GetService("HttpService")
local GuiService = game:GetService("GuiService")

local AutoExec = { queued = false, saveScheduled = false, lastJson = nil, conns = {}, disconnected = false }

local function getQueueFn()
	return queue_on_teleport or queueonteleport
		or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport)
end

local function hasFileApi()
	return type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
end

-- Where to reload the script from: URL if set, otherwise a workspace file
-- (CONFIG.ScriptFile, falling back to "AutumnDice.lua" so an old/unedited config still works)
local function resolveSource()
	if CONFIG.ScriptUrl then
		return "url", CONFIG.ScriptUrl
	end
	return "file", CONFIG.ScriptFile or "AutumnDice.lua"
end

local function buildLoader()
	local kind, value = resolveSource()
	local load
	if kind == "url" then
		load = ("loadstring(game:HttpGet(%q))()"):format(value)
	else
		load = ("loadstring(readfile(%q))()"):format(value)
	end
	return ([[
local env = (getgenv and getgenv()) or _G
if env.AutumnDice or env.AutumnDice_Booting then return end -- already running/starting: never start a second instance
local okS, saved = pcall(function()
	return game:GetService("HttpService"):JSONDecode(readfile(%q))
end)
if not (okS and type(saved) == "table" and type(saved.Features) == "table" and saved.Features.AutoExecute == true) then return end
if not game:IsLoaded() then game.Loaded:Wait() end
local Players = game:GetService("Players")
while not Players.LocalPlayer do task.wait() end
env.AutumnDice_Booting = true
Players.LocalPlayer:WaitForChild("PlayerGui")
task.wait(3)
if env.AutumnDice then env.AutumnDice_Booting = nil return end
env.AutumnDice_AutoExecBoot = true
local okL, errL = pcall(function()
	%s
end)
env.AutumnDice_Booting = nil
if not okL then warn("[AutumnDice] Auto Execute failed to start: " .. tostring(errL)) end
]]):format(CONFIG.SettingsFile, load)
end

local function queueAutoExecute()
	if AutoExec.queued then return true end
	local queue, loader = getQueueFn(), buildLoader()
	if not queue or not loader then return false end
	if pcall(queue, loader) then
		AutoExec.queued = true
		return true
	end
	return false
end

local function writeStub()
	if type(makefolder) ~= "function" then return false end
	local loader = buildLoader()
	if not loader then return false end
	pcall(makefolder, "Dice")
	pcall(makefolder, "Dice/CustomLoadings")
	return pcall(writefile, CONFIG.LoaderStub, loader)
end

local function removeStub()
	if type(delfile) == "function" and type(isfile) == "function" and isfile(CONFIG.LoaderStub) then
		pcall(delfile, CONFIG.LoaderStub)
	end
end

local function snapshotSettings()
	local features = {}
	for name, value in pairs(State.Features) do features[name] = value end
	local totals, order = {}, {}
	for name, amount in pairs(State.Rewards.totals) do totals[name] = amount end
	for i, name in ipairs(State.Rewards.order) do order[i] = name end
	return {
		Features = features,
		TowerMode = State.TowerMode,
		SelectedTower = State.SelectedTower,
		Hotkey = State.Hotkey.Name,
		Rewards = { totals = totals, order = order },
	}
end

local function saveSettings(force)
	if not hasFileApi() then return end
	if not (State.Features.AutoExecute or force) then return end
	local ok, json = pcall(function() return HttpService:JSONEncode(snapshotSettings()) end)
	if not ok or json == AutoExec.lastJson then return end
	if pcall(writefile, CONFIG.SettingsFile, json) then
		AutoExec.lastJson = json
	end
end

-- keep the saved file current while Auto Execute is on (debounced, skips identical data)
onChange(function()
	if not State.Features.AutoExecute or AutoExec.saveScheduled then return end
	AutoExec.saveScheduled = true
	task.delay(1, function()
		AutoExec.saveScheduled = false
		saveSettings()
	end)
end)

local function onDisconnected(reason)
	if AutoExec.disconnected then return end
	AutoExec.disconnected = true
	saveSettings(true)      -- make sure the latest states are on disk
	queueAutoExecute()      -- (re)arm in case the queue was lost
	writeStub()
	warn("[AutumnDice] Disconnected (" .. tostring(reason) .. "). Script will re-execute after you rejoin.")
end

local function startDisconnectWatch()
	if #AutoExec.conns > 0 then return end
	AutoExec.disconnected = false
	table.insert(AutoExec.conns, GuiService.ErrorMessageChanged:Connect(function(msg)
		if type(msg) == "string" and msg ~= "" then onDisconnected(msg) end
	end))
	pcall(function()
		local overlay = game:GetService("CoreGui").RobloxPromptGui.promptOverlay
		table.insert(AutoExec.conns, overlay.ChildAdded:Connect(function(child)
			if child.Name == "ErrorPrompt" then onDisconnected("error prompt") end
		end))
	end)
end

local function stopDisconnectWatch()
	for _, c in ipairs(AutoExec.conns) do pcall(function() c:Disconnect() end) end
	AutoExec.conns = {}
end

local function setAutoExecute(enabled)
	if not enabled then
		stopDisconnectWatch()
		removeStub()
		saveSettings(true) -- file now says AutoExecute = false, so any queued loader exits
		return
	end

	local problem
	if not hasFileApi() then
		problem = "readfile/writefile/isfile are not available in this executor"
	elseif not getQueueFn() and type(makefolder) ~= "function" then
		problem = "neither queue_on_teleport nor makefolder is available in this executor"
	elseif select(1, resolveSource()) == "file" and not isfile(select(2, resolveSource())) then
		problem = ('the script file "%s" was not found in the executor workspace. Save this script there under that name (or set CONFIG.ScriptUrl / CONFIG.ScriptFile)'):format(select(2, resolveSource()))
	else
		-- two independent routes; either one is enough (the loader's lock prevents a double start)
		local queued = queueAutoExecute()
		local stubbed = writeStub()
		if not (queued or stubbed) then
			problem = "could not queue or write the loader"
		end
	end
	if problem then
		warn("[AutumnDice] Auto Execute unavailable: " .. problem)
		State.Features.AutoExecute = false -- keep the toggle truthful
		return
	end

	saveSettings(true)
	startDisconnectWatch()
end

----------------------------------------------------------------------
-- AUTO RECONNECT
-- While enabled, a disconnect / error prompt starts a retry loop that teleports back to the
-- server saved when the toggle was turned on (or a fresh server if it can't be rejoined).
-- While disabled there are no connections and no loops.
----------------------------------------------------------------------
local TeleportService = game:GetService("TeleportService")
local Reconnect = { conns = {}, token = 0, running = false, gaveUp = false, failed = false }

-- Calls cb(reason) when the client shows a disconnect/kick prompt. Returns the connections.
local function watchDisconnect(cb)
	local conns = {}
	table.insert(conns, GuiService.ErrorMessageChanged:Connect(function(msg)
		if type(msg) == "string" and msg ~= "" then cb(msg) end
	end))
	pcall(function()
		local overlay = game:GetService("CoreGui").RobloxPromptGui.promptOverlay
		table.insert(conns, overlay.ChildAdded:Connect(function(child)
			if child.Name == "ErrorPrompt" then cb("error prompt") end
		end))
	end)
	return conns
end

local function saveServer()
	if not hasFileApi() then return end
	pcall(writefile, CONFIG.ReconnectFile, HttpService:JSONEncode({
		PlaceId = game.PlaceId,
		JobId = game.JobId,
	}))
end

local function reconnectLoop(token)
	local maxAttempts = CONFIG.ReconnectMaxAttempts
	local currentAttempt = 1
	local delayTime = CONFIG.ReconnectDelay

	local targetPlaceId = game.PlaceId
	local targetJobId = game.JobId

	if hasFileApi() and isfile(CONFIG.ReconnectFile) then
		pcall(function()
			local saved = HttpService:JSONDecode(readfile(CONFIG.ReconnectFile))
			if saved and saved.PlaceId == game.PlaceId then
				targetJobId = saved.JobId
			end
		end)
	end

	local failConn = TeleportService.TeleportInitFailed:Connect(function()
		Reconnect.failed = true
	end)

	local connected = false
	while currentAttempt <= maxAttempts do
		task.wait(delayTime)
		if token ~= Reconnect.token then break end -- toggled off in the meantime

		Reconnect.failed = false
		local success, err = pcall(function()
			if targetJobId and targetJobId ~= "" and #Players:GetPlayers() > 1 then
				TeleportService:TeleportToPlaceInstance(targetPlaceId, targetJobId, player)
			else
				TeleportService:Teleport(targetPlaceId, player)
			end
		end)

		if success then
			-- the call only starts the teleport: give TeleportInitFailed a few seconds to report a failure
			for _ = 1, 20 do
				task.wait(0.5)
				if Reconnect.failed or token ~= Reconnect.token then break end
			end
			if token ~= Reconnect.token then break end
			if not Reconnect.failed then
				connected = true
				break
			end
			err = "teleport failed to start"
		end

		warn(("[AutumnDice] Reconnect attempt %d/%d failed: %s"):format(currentAttempt, maxAttempts, tostring(err)))
		currentAttempt += 1
		delayTime = delayTime * CONFIG.ReconnectBackoff
	end

	failConn:Disconnect()
	if token ~= Reconnect.token then return end
	Reconnect.running = false
	if not connected then
		Reconnect.gaveUp = true -- stop retrying until the toggle is switched off and on again
		warn("[AutumnDice] Auto Reconnect gave up after " .. maxAttempts .. " attempts.")
	end
end

local function onReconnectNeeded(reason)
	if Reconnect.running or Reconnect.gaveUp or not State.Features.AutoReconnect then return end
	Reconnect.running = true
	warn("[AutumnDice] Disconnected (" .. tostring(reason) .. "). Reconnecting...")
	task.spawn(reconnectLoop, Reconnect.token)
end

local function setAutoReconnect(enabled)
	-- any loop in flight sees the new token and stops
	Reconnect.token += 1
	Reconnect.running = false
	for _, c in ipairs(Reconnect.conns) do pcall(function() c:Disconnect() end) end
	Reconnect.conns = {}
	if not enabled then return end

	Reconnect.gaveUp = false
	saveServer()
	Reconnect.conns = watchDisconnect(onReconnectNeeded)
end

local function SetFeature(name, value)
	if State.Features[name] == nil then return end
	value = value and true or false
	if State.Features[name] == value then return end
	State.Features[name] = value

	if name == "AutoDice" then
		runId += 1
		if value then
			local id = runId
			SetStatus("Initializing")
			task.spawn(worker, id)
		else
			-- any in-flight roll finishes on its own, but no new roll is started
			SetStatus("AutoRollDisabled")
		end
	elseif name == "AutoTower" then
		towerRunId += 1
		if value then
			local id = towerRunId
			resetTowerRuntime()
			SetTowerStatus(State.TowerMode == "Single" and "SingleStarting" or "BestSearching", "Starting Auto Tower.")
			task.spawn(towerWorker, id)
		else
			Tower.activeName = nil
			SetTowerStatus("Off", "Auto Tower is disabled.")
		end
		notify()
	elseif name == "AntiAfk" then
		setAntiAfk(value)
		notify()
	elseif name == "AutoExecute" then
		setAutoExecute(value)
		notify()
	elseif name == "AutoReconnect" then
		setAutoReconnect(value)
		notify()
	else
		notify()
	end
end

local function GetFeature(name)
	return State.Features[name]
end

----------------------------------------------------------------------
-- TOWER REWARDS (hooks Towers.CompleteTowerFloor; an "ended" action carries the run's rewards)
----------------------------------------------------------------------
local Rewards = {
	seen = setmetatable({}, { __mode = "k" }), -- result tables already counted (no double counting)
	restore = {},
}

local function recordRewards(result)
	if typeof(result) ~= "table" or Rewards.seen[result] then return end

	for _, action in ipairs(result) do
		if type(action) == "table" and action.action == "ended" then
			Rewards.seen[result] = true
			local earned = action.rewards
			if type(earned) == "table" then
				local R = State.Rewards
				for name, amount in pairs(earned) do
					if type(amount) == "number" and amount > 0 then
						local key = tostring(name)
						if R.totals[key] == nil then
							R.totals[key] = 0              -- new reward: create the entry once
							table.insert(R.order, key)
						end
						R.totals[key] += amount            -- existing reward: add to its total
					end
				end
			end
			notify()
			return
		end
	end
end

-- Wraps a CallFunction so the original result is returned untouched
local function wrapCall(original)
	return function(self, name, ...)
		local packed = table.pack(original(self, name, ...))
		if name == "CompleteTowerFloor" then
			pcall(recordRewards, packed[1])
		end
		return table.unpack(packed, 1, packed.n)
	end
end

local function installRewardHook()
	local ok, err = pcall(function()
		local Network = require(ReplicatedStorage.Packages.Network)

		-- class level: catches the game's own Towers comm (skipped if the class has no CallFunction)
		local cls = Network.ClientComm
		local clsOriginal = type(cls) == "table" and rawget(cls, "CallFunction")
		if type(clsOriginal) == "function" then
			cls.CallFunction = wrapCall(clsOriginal)
			table.insert(Rewards.restore, function() cls.CallFunction = clsOriginal end)
		end

		-- instance level (same pattern as the reference snippet)
		local comm = cls.new(ReplicatedStorage.Network, "Towers")
		local instRaw = rawget(comm, "CallFunction")
		local instOriginal = comm.CallFunction
		if type(instOriginal) == "function" then
			comm.CallFunction = wrapCall(instOriginal)
			table.insert(Rewards.restore, function() comm.CallFunction = instRaw end)
		end
	end)
	if not ok then
		warn("[AutumnDice] Reward hook failed: " .. tostring(err))
	end
end

local function uninstallRewardHook()
	for i = #Rewards.restore, 1, -1 do
		pcall(Rewards.restore[i])
	end
	Rewards.restore = {}
end

task.spawn(installRewardHook)

----------------------------------------------------------------------
-- GUI
----------------------------------------------------------------------
local TweenService = game:GetService("TweenService")

local function create(class, props, children)
	local inst = Instance.new(class)
	for k, v in pairs(props) do
		inst[k] = v
	end
	for _, child in ipairs(children or {}) do
		child.Parent = inst
	end
	return inst
end

local function corner(r) return create("UICorner", { CornerRadius = UDim.new(0, r or 6) }) end
local function pill() return create("UICorner", { CornerRadius = UDim.new(1, 0) }) end
local function stroke(color, thickness)
	return create("UIStroke", {
		Color = color,
		Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end
local function pad(l, t, r, b)
	return create("UIPadding", {
		PaddingLeft = UDim.new(0, l), PaddingTop = UDim.new(0, t),
		PaddingRight = UDim.new(0, r), PaddingBottom = UDim.new(0, b),
	})
end
local function vlist(gap)
	return create("UIListLayout", { Padding = UDim.new(0, gap or 8), SortOrder = Enum.SortOrder.LayoutOrder })
end

local function formatNumber(n)
	local s = (n % 1 == 0) and string.format("%d", n) or string.format("%.2f", n)
	local int, frac = s:match("^(%d+)(%.?%d*)$")
	if not int then return s end
	local r = int:reverse():gsub("(%d%d%d)", "%1,")
	r = r:reverse():gsub("^,", "")
	return r .. frac
end

local THEME = {
	bg = Color3.fromRGB(18, 19, 22),
	card = Color3.fromRGB(26, 27, 31),
	field = Color3.fromRGB(35, 36, 41),
	popup = Color3.fromRGB(40, 41, 47),
	stroke = Color3.fromRGB(46, 47, 54),
	text = Color3.fromRGB(240, 241, 245),
	body = Color3.fromRGB(196, 198, 208),
	subtext = Color3.fromRGB(128, 130, 142),
	accent = Color3.fromRGB(255, 132, 44),
	accentDim = Color3.fromRGB(62, 38, 26),
	off = Color3.fromRGB(62, 63, 71),
	knobOn = Color3.fromRGB(20, 20, 22),
	knobOff = Color3.fromRGB(150, 152, 162),
}

local function resolveParent()
	local ok, parent = pcall(function()
		if gethui then return gethui() end
		return game:GetService("CoreGui")
	end)
	if ok and parent then return parent end
	return player:WaitForChild("PlayerGui")
end

local gui = create("ScreenGui", {
	Name = "AutumnDiceAutoRoll",
	ResetOnSpawn = false,
	IgnoreGuiInset = true, -- keeps AbsolutePosition == Position (dropdown popups rely on it)
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
pcall(function() gui.Parent = resolveParent() end)
if not gui.Parent then gui.Parent = player:WaitForChild("PlayerGui") end

local connections = {}
local refreshers = {}

local WIDTH = 300

local main = create("Frame", {
	Name = "Main",
	Size = UDim2.fromOffset(WIDTH, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	Position = UDim2.new(0.5, -WIDTH / 2, 0.5, -230),
	BackgroundColor3 = THEME.bg,
	BorderSizePixel = 0,
	Parent = gui,
}, {
	corner(16),
	stroke(THEME.stroke),
	pad(8, 6, 8, 8),
	vlist(6),
})

-- Title bar (drag handle) ---------------------------------------------------
local titleBar = create("Frame", {
	LayoutOrder = 1,
	Size = UDim2.new(1, 0, 0, 20),
	BackgroundTransparency = 1,
	Parent = main,
})
create("TextLabel", {
	Size = UDim2.new(1, -36, 1, 0),
	Position = UDim2.fromOffset(4, 0),
	BackgroundTransparency = 1,
	Text = "Autumn Dice",
	Font = Enum.Font.GothamBold,
	TextSize = 11,
	TextColor3 = THEME.subtext,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = titleBar,
})
local closeBtn = create("TextButton", {
	Size = UDim2.fromOffset(20, 20),
	Position = UDim2.new(1, -20, 0.5, -10),
	BackgroundColor3 = THEME.field,
	Text = "✕",
	Font = Enum.Font.GothamBold,
	TextSize = 10,
	TextColor3 = THEME.subtext,
	AutoButtonColor = true,
	Parent = titleBar,
}, { corner(8) })

-- Dropdown popup infrastructure ---------------------------------------------
local openDropdown = nil

-- invisible layer behind an open list: clicking it closes the list
local catcher = create("TextButton", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Text = "",
	AutoButtonColor = false,
	Visible = false,
	ZIndex = 15,
	Parent = gui,
})

local function closeDropdowns()
	if openDropdown then
		openDropdown.list.Visible = false
		openDropdown = nil
	end
	catcher.Visible = false
end
catcher.MouseButton1Click:Connect(closeDropdowns)

-- Building blocks -------------------------------------------------------------

-- Collapsible card: icon tile + title + chevron. Returns the body frame.
local function makeCard(order, buildIcon, title, startCollapsed)
	local card = create("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = THEME.card,
		BorderSizePixel = 0,
		Parent = main,
	}, {
		corner(10),
		stroke(THEME.stroke),
		pad(10, 8, 10, 10),
		vlist(8),
	})

	local header = create("TextButton", {
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Parent = card,
	})
	local tile = create("Frame", {
		Size = UDim2.fromOffset(26, 26),
		BackgroundColor3 = THEME.accentDim,
		BorderSizePixel = 0,
		Parent = header,
	}, { corner(8) })
	buildIcon(tile)
	create("TextLabel", {
		Size = UDim2.new(1, -62, 1, 0),
		Position = UDim2.fromOffset(36, 0),
		BackgroundTransparency = 1,
		Text = title,
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = THEME.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = header,
	})
	local chevron = create("TextLabel", {
		Size = UDim2.new(0, 20, 1, 0),
		Position = UDim2.new(1, -20, 0, 0),
		BackgroundTransparency = 1,
		Text = "▾",
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextColor3 = THEME.subtext,
		Parent = header,
	})

	local body = create("Frame", {
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = card,
	}, { vlist(8) })

	if startCollapsed then
		body.Visible = false
		chevron.Rotation = 180
	end

	header.MouseButton1Click:Connect(function()
		closeDropdowns()
		body.Visible = not body.Visible
		chevron.Rotation = body.Visible and 0 or 180
	end)

	return body
end

-- Text line that wraps and grows downward
local function makeLine(parent, order, size, color, font)
	return create("TextLabel", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, size + 4),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Text = "",
		Font = font or Enum.Font.Gotham,
		TextSize = size,
		TextColor3 = color,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = parent,
	})
end

-- Switch row (label on the left, pill switch on the right)
local function makeToggle(parent, order, labelText, featureName)
	local row = create("TextButton", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Parent = parent,
	})
	create("TextLabel", {
		Size = UDim2.new(1, -46, 1, 0),
		BackgroundTransparency = 1,
		Text = labelText,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextColor3 = THEME.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = row,
	})
	local track = create("Frame", {
		Size = UDim2.fromOffset(36, 20),
		Position = UDim2.new(1, -36, 0.5, -10),
		BackgroundColor3 = THEME.off,
		BorderSizePixel = 0,
		Parent = row,
	}, { pill() })
	local knob = create("Frame", {
		Size = UDim2.fromOffset(14, 14),
		Position = UDim2.fromOffset(3, 3),
		BackgroundColor3 = THEME.knobOff,
		BorderSizePixel = 0,
		Parent = track,
	}, { pill() })

	row.MouseButton1Click:Connect(function()
		SetFeature(featureName, not GetFeature(featureName))
	end)

	local last = nil
	table.insert(refreshers, function()
		local on = GetFeature(featureName) and true or false
		if on == last then return end
		last = on
		local ti = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(track, ti, { BackgroundColor3 = on and THEME.accent or THEME.off }):Play()
		TweenService:Create(knob, ti, {
			Position = on and UDim2.fromOffset(19, 3) or UDim2.fromOffset(3, 3),
			BackgroundColor3 = on and THEME.knobOn or THEME.knobOff,
		}):Play()
	end)
end

-- Label on top, full-width select field below, popup list overlays everything
local function makeDropdown(parent, order, labelText, onSelect)
	local wrap = create("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = parent,
	}, { vlist(4) })
	create("TextLabel", {
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 16),
		BackgroundTransparency = 1,
		Text = labelText,
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextColor3 = THEME.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = wrap,
	})
	local btn = create("TextButton", {
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundColor3 = THEME.field,
		Text = "",
		AutoButtonColor = false,
		Parent = wrap,
	}, { corner(8), stroke(THEME.stroke) })
	local valueLabel = create("TextLabel", {
		Size = UDim2.new(1, -32, 1, 0),
		Position = UDim2.fromOffset(10, 0),
		BackgroundTransparency = 1,
		Text = "",
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextColor3 = THEME.text,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = btn,
	})
	create("TextLabel", {
		Size = UDim2.fromOffset(16, 30),
		Position = UDim2.new(1, -22, 0, 0),
		BackgroundTransparency = 1,
		Text = "▾",
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextColor3 = THEME.body,
		Parent = btn,
	})

	-- popup lives directly under the ScreenGui so the card layouts never move it
	local list = create("ScrollingFrame", {
		Size = UDim2.fromOffset(200, 30),
		BackgroundColor3 = THEME.popup,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = THEME.accent,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Visible = false,
		ZIndex = 20,
		Parent = gui,
	}, {
		corner(8),
		stroke(THEME.stroke),
		create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }),
	})

	local dd = { list = list, value = nil, options = {}, items = {} }

	local function paintItems()
		for name, item in pairs(dd.items) do
			item.TextColor3 = (name == dd.value) and THEME.accent or THEME.text
		end
	end

	function dd.SetValue(value)
		dd.value = value
		valueLabel.Text = value or "None"
		paintItems()
	end

	function dd.SetOptions(options)
		dd.options = options
		for _, item in pairs(dd.items) do item:Destroy() end
		dd.items = {}
		for _, child in ipairs(list:GetChildren()) do
			if child:IsA("TextLabel") then child:Destroy() end
		end

		if #options == 0 then
			create("TextLabel", {
				Size = UDim2.new(1, 0, 0, 26),
				BackgroundTransparency = 1,
				Text = "No towers found",
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextColor3 = THEME.subtext,
				ZIndex = 21,
				Parent = list,
			})
		end

		for i, optName in ipairs(options) do
			local item = create("TextButton", {
				Size = UDim2.new(1, 0, 0, 26),
				LayoutOrder = i,
				BackgroundTransparency = 1,
				Text = optName,
				Font = Enum.Font.GothamMedium,
				TextSize = 12,
				TextColor3 = THEME.text,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextXAlignment = Enum.TextXAlignment.Left,
				ZIndex = 21,
				Parent = list,
			}, { pad(10, 0, 6, 0) })
			item.MouseButton1Click:Connect(function()
				closeDropdowns()
				onSelect(optName)
			end)
			dd.items[optName] = item
		end
		paintItems()
	end

	function dd.SetDimmed(dimmed)
		valueLabel.TextTransparency = dimmed and 0.45 or 0
	end

	btn.MouseButton1Click:Connect(function()
		if openDropdown == dd then
			closeDropdowns()
			return
		end
		closeDropdowns()
		local pos, size = btn.AbsolutePosition, btn.AbsoluteSize
		list.Position = UDim2.fromOffset(pos.X, pos.Y + size.Y + 4)
		list.Size = UDim2.fromOffset(size.X, math.clamp(math.max(#dd.options, 1) * 26, 26, 130))
		openDropdown = dd
		list.Visible = true
		catcher.Visible = true
	end)

	return dd
end

----------------------------------------------------------------------
-- Card: Auto Roll
----------------------------------------------------------------------
local rollBody = makeCard(2, function(tile)
	create("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "🍂",
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		Parent = tile,
	})
end, "Auto Roll")

makeToggle(rollBody, 1, "Auto Roll Autumn Dice", "AutoDice")

local rollInfo = create("Frame", {
	LayoutOrder = 2,
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	Parent = rollBody,
}, { vlist(4) })

local rollCount = makeLine(rollInfo, 1, 12, THEME.subtext)

----------------------------------------------------------------------
-- Card: Auto Tower
----------------------------------------------------------------------
local towerBody = makeCard(3, function(tile)
	-- crossed swords, drawn with two rotated bars so no font/emoji is needed
	for _, rot in ipairs({ 45, -45 }) do
		create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(3, 17),
			Rotation = rot,
			BackgroundColor3 = THEME.accent,
			BorderSizePixel = 0,
			Parent = tile,
		}, { pill() })
	end
end, "Auto Tower", true)

local modeDropdown = makeDropdown(towerBody, 1, "Mode", function(choice)
	SetTowerMode(choice)
end)
modeDropdown.SetOptions(TOWER_MODES)

local towerDropdown = makeDropdown(towerBody, 2, "Tower", function(choice)
	SetSelectedTower(choice)
end)
towerDropdown.SetOptions({})

makeToggle(towerBody, 3, "Auto Equip Best Team", "AutoEquipBest")
makeToggle(towerBody, 4, "Auto Tower", "AutoTower")

local towerInfo = create("Frame", {
	LayoutOrder = 5,
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	Parent = towerBody,
}, { vlist(4) })

local towerLine = makeLine(towerInfo, 1, 12, THEME.body, Enum.Font.GothamMedium)

local statsRow = create("Frame", {
	LayoutOrder = 2,
	Size = UDim2.new(1, 0, 0, 16),
	BackgroundTransparency = 1,
	Parent = towerInfo,
}, {
	create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 12),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
})
local function statLabel(order)
	return create("TextLabel", {
		LayoutOrder = order,
		Size = UDim2.fromOffset(0, 16),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		Text = "",
		Font = Enum.Font.Gotham,
		TextSize = 11,
		TextColor3 = THEME.subtext,
		Parent = statsRow,
	})
end
local runsLabel = statLabel(1)
local floorsLabel = statLabel(2)
local bestLabel = statLabel(3)

local rewardsHeader = makeLine(towerInfo, 3, 12, THEME.body, Enum.Font.GothamMedium)
rewardsHeader.Text = "Tower Rewards"
local rewardsList = create("ScrollingFrame", {
	LayoutOrder = 4,
	Size = UDim2.new(1, 0, 0, 26),
	BackgroundColor3 = THEME.field,
	BorderSizePixel = 0,
	ScrollBarThickness = 3,
	ScrollBarImageColor3 = THEME.accent,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(),
	Parent = towerInfo,
}, { corner(6), pad(8, 4, 8, 4), vlist(1) })
local rewardsEmpty = create("TextLabel", {
	LayoutOrder = 0,
	Size = UDim2.new(1, 0, 0, 18),
	BackgroundTransparency = 1,
	Text = "No rewards yet",
	Font = Enum.Font.Gotham,
	TextSize = 12,
	TextColor3 = THEME.subtext,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = rewardsList,
})
local rewardRows = {}

create("Frame", {
	LayoutOrder = 5,
	Size = UDim2.new(1, 0, 0, 1),
	BackgroundColor3 = THEME.stroke,
	BorderSizePixel = 0,
	Parent = towerInfo,
})
local towerStatus = makeLine(towerInfo, 6, 12, THEME.subtext, Enum.Font.GothamBold)
local towerDetail = makeLine(towerInfo, 7, 11, THEME.subtext)

----------------------------------------------------------------------
-- Card: Miscellaneous (GUI only - toggles just flip their State.Features flag for now)
----------------------------------------------------------------------
local miscBody = makeCard(4, function(tile)
	-- settings icon: three stacked bars
	for i, w in ipairs({ 14, 9, 12 }) do
		create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0, 8 + (i - 1) * 5),
			Size = UDim2.fromOffset(w, 2),
			BackgroundColor3 = THEME.accent,
			BorderSizePixel = 0,
			Parent = tile,
		}, { pill() })
	end
end, "Miscellaneous", true)

makeToggle(miscBody, 1, "Anti AFK", "AntiAfk")
makeToggle(miscBody, 2, "Auto Reconnect", "AutoReconnect")
makeToggle(miscBody, 3, "Auto Execute", "AutoExecute")

----------------------------------------------------------------------
-- Footer: hotkey
----------------------------------------------------------------------
local hotkeyRow = create("Frame", {
	LayoutOrder = 5,
	Size = UDim2.new(1, 0, 0, 22),
	BackgroundTransparency = 1,
	Parent = main,
}, { pad(2, 0, 2, 0) })
create("TextLabel", {
	Size = UDim2.new(0.5, 0, 1, 0),
	BackgroundTransparency = 1,
	Text = "Show / hide GUI",
	Font = Enum.Font.Gotham,
	TextSize = 11,
	TextColor3 = THEME.subtext,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = hotkeyRow,
})
local hotkeyBtn = create("TextButton", {
	Size = UDim2.fromOffset(104, 20),
	Position = UDim2.new(1, -104, 0.5, -10),
	BackgroundColor3 = THEME.field,
	Text = "",
	Font = Enum.Font.GothamBold,
	TextSize = 11,
	TextColor3 = THEME.accent,
	AutoButtonColor = false,
	Parent = hotkeyRow,
}, { corner(8), stroke(THEME.stroke) })

local listeningForKey = false
local function refreshHotkey()
	hotkeyBtn.Text = listeningForKey and "Press a key..." or ("[ " .. State.Hotkey.Name .. " ]")
end

hotkeyBtn.MouseButton1Click:Connect(function()
	if listeningForKey then return end
	listeningForKey = true
	refreshHotkey()
	local conn
	conn = UserInputService.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
		conn:Disconnect()
		if input.KeyCode ~= Enum.KeyCode.Escape and input.KeyCode ~= Enum.KeyCode.Unknown then
			State.Hotkey = input.KeyCode
		end
		task.delay(0.15, function()
			listeningForKey = false
			refreshHotkey()
		end)
	end)
end)

table.insert(connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or listeningForKey then return end
	if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == State.Hotkey then
		main.Visible = not main.Visible
		if not main.Visible then closeDropdowns() end
	end
end))

-- Dragging
do
	local dragging, dragStart, startPos
	table.insert(connections, titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			closeDropdowns()
			dragging, dragStart, startPos = true, input.Position, main.Position
		end
	end))
	table.insert(connections, UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end))
	table.insert(connections, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
end

-- Keep the "Tower" dropdown in sync with TurkeyTowers.Sections
local lastSignature = nil
local function refreshTowerOptions()
	if not loadTowerModules() then return end

	local names = {}
	local ok = pcall(function()
		for _, section in ipairs(TurkeyTowers.Sections) do
			if type(section) == "table" and type(section.name) == "string" then
				table.insert(names, section.name)
			end
		end
	end)
	if not ok then return end

	local signature = table.concat(names, "\n")
	if signature == lastSignature then return end
	lastSignature = signature

	Tower.names = names
	towerDropdown.SetOptions(names)

	-- keep the selection valid when the list changes
	if not State.SelectedTower or not table.find(names, State.SelectedTower) then
		State.SelectedTower = names[1]
		Tower.activeName = nil
		Tower.lastStarted = false
	end
	Tower.wake = true
	notify()
end

-- GUI <- State sync
local function refreshGui()
	for _, fn in ipairs(refreshers) do fn() end

	-- Auto Roll
	-- each successful Roll call rolls CONFIG.RollAmount dice
	rollCount.Text = ("Rolls: %s"):format(formatNumber(State.Rolls * CONFIG.RollAmount))

	-- Auto Tower
	local S = State.TowerStats
	local floorText = S.Floor and (" floor " .. S.Floor) or ""
	towerLine.Text = Tower.activeName and ("Tower: " .. Tower.activeName .. floorText) or "Tower: -"
	runsLabel.Text = ("%d Runs"):format(S.Runs)
	floorsLabel.Text = (S.Tracking and tostring(S.Floors) or "-") .. " Floors Cleared"
	bestLabel.Text = "Best Floor " .. ((S.Tracking and S.Best > 0) and tostring(S.Best) or "-")

	-- Rewards: one row per reward, text updated in place (never duplicated or overwritten)
	local R = State.Rewards
	local count = #R.order
	rewardsEmpty.Visible = (count == 0)
	for i, name in ipairs(R.order) do
		local row = rewardRows[name]
		if not row then
			row = create("TextLabel", {
				LayoutOrder = i,
				Size = UDim2.new(1, 0, 0, 18),
				BackgroundTransparency = 1,
				Text = "",
				Font = Enum.Font.GothamMedium,
				TextSize = 12,
				TextColor3 = THEME.body,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = rewardsList,
			})
			rewardRows[name] = row
		end
		row.Text = formatNumber(R.totals[name]) .. " " .. name
	end
	rewardsList.Size = UDim2.new(1, 0, 0, math.clamp(math.max(count, 1) * 19 + 8, 26, 130))

	local tinfo = TOWER_STATUS[State.TowerStatus] or TOWER_STATUS.Off
	towerStatus.Text = tinfo.text
	towerStatus.TextColor3 = tinfo.color
	towerDetail.Text = State.TowerDetail

	modeDropdown.SetValue(State.TowerMode)
	towerDropdown.SetValue(State.SelectedTower)
	towerDropdown.SetDimmed(State.TowerMode ~= "Single") -- the Tower pick only applies in Single mode

	refreshHotkey()
end
onChange(refreshGui)
refreshGui()

-- Safety net: periodically re-sync the GUI and the tower list
local syncAlive = true
task.spawn(function()
	while syncAlive and gui.Parent do
		pcall(refreshTowerOptions)
		refreshGui()
		task.wait(0.5)
	end
end)

----------------------------------------------------------------------
-- Unload / public API
----------------------------------------------------------------------
local function Unload()
	syncAlive = false
	uninstallRewardHook()
	setAntiAfk(false)
	setAutoReconnect(false)
	stopDisconnectWatch()
	State.Features.AutoDice = false
	State.Features.AutoTower = false
	runId += 1
	towerRunId += 1
	for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
	if gui then gui:Destroy() end
	env.AutumnDice = nil
end

-- closing the GUI with X is a deliberate stop: also cancel the Auto Execute on rejoin
closeBtn.MouseButton1Click:Connect(function()
	if State.Features.AutoExecute then
		State.Features.AutoExecute = false
		setAutoExecute(false)
	end
	Unload()
end)

env.AutumnDice = {
	SetFeature = SetFeature,
	GetFeature = GetFeature,
	SetTowerMode = SetTowerMode,
	SetSelectedTower = SetSelectedTower,
	GetStatus = function() return State.Status, State.Detail end,
	GetTowerStatus = function() return State.TowerStatus, State.TowerDetail end,
	SetHotkey = function(keyCode) State.Hotkey = keyCode notify() end,
	GetRewards = function()
		local copy = {}
		for name, amount in pairs(State.Rewards.totals) do copy[name] = amount end
		return copy
	end,
	Unload = Unload,
}

----------------------------------------------------------------------
-- Defaults: these four (Anti AFK, Auto Reconnect, Auto Execute, Auto Roll) start ON on a normal (manual) launch. SetFeature starts the real
-- behavior, and the toggles follow State. After an Auto Execute relaunch the saved
-- states are restored instead (below), so a feature the user turned off stays off.
----------------------------------------------------------------------
if not env.AutumnDice_AutoExecBoot then
	for _, name in ipairs({ "AntiAfk", "AutoReconnect", "AutoExecute", "AutoDice" }) do
		SetFeature(name, true)
	end
end

----------------------------------------------------------------------
-- Restore after an Auto Execute relaunch
----------------------------------------------------------------------
if env.AutumnDice_AutoExecBoot then
	env.AutumnDice_AutoExecBoot = nil
	task.spawn(function()
		if not hasFileApi() or not isfile(CONFIG.SettingsFile) then return end
		local ok, saved = pcall(function() return HttpService:JSONDecode(readfile(CONFIG.SettingsFile)) end)
		if not ok or type(saved) ~= "table" or type(saved.Features) ~= "table" then return end
		local f = saved.Features

		-- session rewards carry over the reconnect
		local R = saved.Rewards
		if type(R) == "table" and type(R.totals) == "table" and type(R.order) == "table" then
			for _, name in ipairs(R.order) do
				local amount = R.totals[name]
				if type(name) == "string" and type(amount) == "number" and State.Rewards.totals[name] == nil then
					State.Rewards.totals[name] = amount
					table.insert(State.Rewards.order, name)
				end
			end
		end

		if type(saved.Hotkey) == "string" then
			local okKey, key = pcall(function() return Enum.KeyCode[saved.Hotkey] end)
			if okKey and key then State.Hotkey = key end
		end
		if type(saved.TowerMode) == "string" then SetTowerMode(saved.TowerMode) end
		notify()

		-- features that don't depend on the game's tower data
		for _, name in ipairs({ "AutoExecute", "AntiAfk", "AutoReconnect", "AutoEquipBest", "AutoDice" }) do
			if f[name] == true then SetFeature(name, true) end
		end

		-- tower selection needs the tower list to be loaded first (wait up to ~30s)
		if type(saved.SelectedTower) == "string" then
			for _ = 1, 60 do
				if table.find(Tower.names, saved.SelectedTower) then break end
				task.wait(0.5)
			end
			SetSelectedTower(saved.SelectedTower)
		end
		if f.AutoTower == true then SetFeature("AutoTower", true) end
	end)
end