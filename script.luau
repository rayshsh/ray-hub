----------------------------------------------------------------------
-- Services
----------------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

----------------------------------------------------------------------
-- Startup gate: do NOTHING until the game has fully loaded.
-- After a rejoin / server hop the script can be executed while the game is still starting,
-- and touching its modules, remotes or UI that early can break the game's own loading.
----------------------------------------------------------------------
local STARTUP_DELAY = 6   -- extra seconds of grace once everything below is ready
do
	if not game:IsLoaded() then game.Loaded:Wait() end

	local lp = Players.LocalPlayer
	while not lp do
		task.wait(0.25)
		lp = Players.LocalPlayer
	end

	lp:WaitForChild("PlayerGui")
	ReplicatedStorage:WaitForChild("Framework", 60) -- the game's own controllers live here

	local deadline = os.clock() + 30
	while not lp.Character and os.clock() < deadline do
		task.wait(0.25)
	end
	local char = lp.Character
	if char then
		char:WaitForChild("HumanoidRootPart", 15)
	end

	task.wait(STARTUP_DELAY)
end

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

	-- Auto Reconnect
	ReconnectFile = "AutumnDice_Server.json", -- remembers the server (PlaceId/JobId) to rejoin
	ReconnectMaxAttempts = 5,
	ReconnectDelay = 5,       -- seconds before the first attempt
	ReconnectBackoff = 1.5,   -- the delay is multiplied by this after every failed attempt
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
		-- Miscellaneous
		AntiAfk = false, AutoReconnect = false, AutoClaimQuest = false,
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
		Runs = 0,          -- tower runs started (any start, via TowerController.startTower)
		Floors = 0,        -- floors cleared since the script started
		Best = 0,          -- highest floor seen
		Floor = nil,       -- current floor of the run (nil = no data yet)
		LastFloor = nil,   -- internal: previous floor shown by the game's Floor label
		Tracking = false,  -- true once the Floor label has been read
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

local AutumnTravel = { travelRemote = nil, traveling = false, movementOwner = nil, questRequested = false }

local function canContinue(shouldContinue)
	return not shouldContinue or shouldContinue()
end

function AutumnTravel.acquire(owner, shouldContinue)
	local deadline = os.clock() + 90
	while ((AutumnTravel.movementOwner and AutumnTravel.movementOwner ~= owner) or (AutumnTravel.rollRemote and inFlight[AutumnTravel.rollRemote])) and canContinue(shouldContinue) and os.clock() < deadline do
		task.wait(0.1)
	end
	if not canContinue(shouldContinue) or os.clock() >= deadline then return false end
	AutumnTravel.movementOwner = owner
	return true
end

function AutumnTravel.release(owner)
	if AutumnTravel.movementOwner == owner then AutumnTravel.movementOwner = nil end
end
function AutumnTravel.findZone(zoneName)
	if type(zoneName) ~= "string" or zoneName == "" then return nil end
	local zones = workspace:FindFirstChild("Zones")
	local zone = zones and zones:FindFirstChild(zoneName)
	return zone and (zone:IsA("BasePart") or zone:IsA("Model")) and zone or nil
end

function AutumnTravel.isInAutumnWorld()
	local zone = AutumnTravel.findZone("AutumnWorld")
	local root = getHRP()
	if not zone or not root then return false end
	local frame, size
	if zone:IsA("Model") then
		frame, size = zone:GetBoundingBox()
	else
		frame, size = zone.CFrame, zone.Size
	end
	local position = frame:PointToObjectSpace(root.Position)
	local half = size / 2
	return math.abs(position.X) <= half.X and math.abs(position.Y) <= half.Y and math.abs(position.Z) <= half.Z
end

function AutumnTravel.ensureInAutumnWorld(shouldContinue)
	local characterDeadline = os.clock() + 15
	while canContinue(shouldContinue) and not getHRP() and os.clock() < characterDeadline do
		task.wait(0.2)
	end
	if not canContinue(shouldContinue) then return false, "Cancelled." end
	if not getHRP() then return false, "Character not found." end
	if AutumnTravel.isInAutumnWorld() then return true end

	local waitDeadline = os.clock() + CONFIG.InvokeTimeout * 2
	while AutumnTravel.traveling and canContinue(shouldContinue) and os.clock() < waitDeadline do
		if AutumnTravel.isInAutumnWorld() then return true end
		task.wait(0.1)
	end
	if not canContinue(shouldContinue) then return false, "Cancelled." end
	if AutumnTravel.isInAutumnWorld() then return true end
	if AutumnTravel.traveling then return false, "Travel is still in progress." end

	AutumnTravel.traveling = true
	local function finish(success, reason)
		AutumnTravel.traveling = false
		return success, reason
	end

	local found, remote = pcall(function()
		return AutumnTravel.travelRemote or getRemote({ "Network", "AutumnService", "RF", "Travel" }, CONFIG.RemoteWaitTimeout)
	end)
	if not found or not remote then return finish(false, "Travel remote not found.") end
	AutumnTravel.travelRemote = remote

	local called, ok, result = pcall(invoke, remote, "Autumn")
	if not called then return finish(false, tostring(ok)) end
	if not canContinue(shouldContinue) then return finish(false, "Cancelled.") end
	if not ok or result == false then return finish(false, "Travel failed: " .. tostring(result)) end

	local deadline = os.clock() + 15
	while canContinue(shouldContinue) and not AutumnTravel.isInAutumnWorld() and os.clock() < deadline do
		task.wait(0.25)
	end
	if not canContinue(shouldContinue) then return finish(false, "Cancelled.") end
	if not AutumnTravel.isInAutumnWorld() then return finish(false, "Timed out waiting for Autumn World.") end
	return finish(true)
end
local function stopWalking(humanoid)
	if not humanoid then return end
	pcall(function()
		local root = humanoid.RootPart
		if root then humanoid:MoveTo(root.Position) end
		humanoid:Move(Vector3.zero)
	end)
end
function AutumnTravel.walkToZone(zoneName, shouldContinue)
	local PathfindingService = game:GetService("PathfindingService")
	local function positionOf(zone)
		return zone:GetPivot().Position
	end

	local zone = AutumnTravel.findZone(zoneName)
	if not zone then return false, "Zone not found: " .. tostring(zoneName) end
	local characterDeadline = os.clock() + 15
	while canContinue(shouldContinue) and not getHRP() and os.clock() < characterDeadline do task.wait(0.2) end
	if not canContinue(shouldContinue) then return false, "Cancelled." end
	if not getHRP() then return false, "Character not found." end

	local deadline = os.clock() + 30
	local movingHumanoid
	while canContinue(shouldContinue) and os.clock() < deadline do
		zone = AutumnTravel.findZone(zoneName)
		if not zone then
			stopWalking(movingHumanoid)
			return false, "Zone not found: " .. tostring(zoneName)
		end

		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local target = positionOf(zone)
		if humanoid and root and humanoid.Health > 0 then
			if (root.Position - target).Magnitude <= CONFIG.ArriveDistance then
				stopWalking(humanoid)
				return true
			end

			local path = PathfindingService:CreatePath()
			local computed = pcall(function() path:ComputeAsync(root.Position, target) end)
			local waypoints = computed and path.Status == Enum.PathStatus.Success and path:GetWaypoints() or {{ Position = target }}
			local blockedAt, currentWaypoint = nil, 1
			local blockedConnection = path.Blocked:Connect(function(index)
				if index >= currentWaypoint then blockedAt = index end
			end)
			local replan = false

			for index, waypoint in ipairs(waypoints) do
				currentWaypoint = index
				if not canContinue(shouldContinue) then
					blockedConnection:Disconnect()
					stopWalking(humanoid)
					return false, "Cancelled."
				end
				if player.Character ~= character or humanoid.Health <= 0 then
					replan = true
					break
				end
				if blockedAt then
					replan = true
					break
				end

				if waypoint.Action == Enum.PathWaypointAction.Jump then humanoid.Jump = true end
				local moved = pcall(function() humanoid:MoveTo(waypoint.Position) end)
				if not moved then
					blockedConnection:Disconnect()
					stopWalking(humanoid)
					return false, "Could not move to zone: " .. tostring(zoneName)
				end
				movingHumanoid = humanoid

				local lastPosition, lastProgress = root.Position, os.clock()
				while canContinue(shouldContinue) and os.clock() < deadline do
					if player.Character ~= character or humanoid.Health <= 0 or blockedAt then
						replan = true
						break
					end
					local currentRoot = character:FindFirstChild("HumanoidRootPart")
					if not currentRoot then
						replan = true
						break
					end
					if (currentRoot.Position - waypoint.Position).Magnitude <= 3 then break end
					if (currentRoot.Position - lastPosition).Magnitude >= 1 then
						lastPosition, lastProgress = currentRoot.Position, os.clock()
					elseif os.clock() - lastProgress >= 3 then
						replan = true
						break
					end
					task.wait(0.2)
				end
				if not canContinue(shouldContinue) then
					blockedConnection:Disconnect()
					stopWalking(humanoid)
					return false, "Cancelled."
				end
				if replan or os.clock() >= deadline then break end
			end

			blockedConnection:Disconnect()
			if not replan then
				local currentRoot = character:FindFirstChild("HumanoidRootPart")
				if currentRoot and (currentRoot.Position - positionOf(zone)).Magnitude <= CONFIG.ArriveDistance then
					stopWalking(humanoid)
					return true
				end
			end
			stopWalking(humanoid)
			if player.Character == character and not replan then task.wait(0.2) end
		end
	end

	stopWalking(movingHumanoid)
	if not canContinue(shouldContinue) then return false, "Cancelled." end
	return false, "Timed out or could not find a clear path to zone: " .. tostring(zoneName)
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

local function runSetup(id)
	SetStatus("Initializing")
	local paths = {
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

	-- 1. Ensure arrival in Autumn World
	SetStatus("Teleporting")
	local traveled, travelErr = AutumnTravel.ensureInAutumnWorld(function() return alive(id) end)
	if not alive(id) then return nil end
	if not traveled then
		return failAndStop(id, travelErr or "Travel failed.") and nil
	end
	if not sleep(id, CONFIG.TeleportSettle) then return nil end

	
	-- 2. Sync the player
	SetStatus("Syncing")
	local ok, res = invoke(remotes.sync)
	if not alive(id) then return nil end
	if not ok or res == false then
		return failAndStop(id, "Sync failed: " .. tostring(res)) and nil
	end
	if not sleep(id, CONFIG.StepDelay) then return nil end

	-- 3. Walk to the LeafDice zone
	SetStatus("Moving")
	local moved, err = AutumnTravel.walkToZone("LeafDice", function() return alive(id) and not AutumnTravel.questRequested end)
	if not alive(id) then return nil end
	if not moved then
		return failAndStop(id, err or "Movement failed.") and nil
	end
	if not sleep(id, CONFIG.StepDelay) then return nil end

	return remotes.roll
end

local function isAtLeafDice()
	local zone, root = AutumnTravel.findZone("LeafDice"), getHRP()
	return zone ~= nil and root ~= nil and (root.Position - zone:GetPivot().Position).Magnitude <= CONFIG.ArriveDistance
end

local function rollLoop(id, rollRemote)
	local consecutiveErrors = 0
	State.Rolls = 0

	while alive(id) do
		if AutumnTravel.questRequested then
			task.wait(0.1)
		else
			local owner = {}
			if AutumnTravel.acquire(owner, function() return alive(id) end) then
				if not alive(id) then
					AutumnTravel.release(owner)
					return
				end

				local moved, err = true, nil
				if not isAtLeafDice() then
					SetStatus("Moving", "Returning to the LeafDice zone before rolling.")
					moved, err = AutumnTravel.walkToZone("LeafDice", function() return alive(id) and not AutumnTravel.questRequested end)
				end
				if not moved or not isAtLeafDice() then
					AutumnTravel.release(owner)
					if not AutumnTravel.questRequested then
						if alive(id) then failAndStop(id, err or "Could not verify arrival at LeafDice.") end
						return
					end
				end

				if AutumnTravel.questRequested or not alive(id) then
					AutumnTravel.release(owner)
				else
					SetStatus("Rolling", ("Rolling Autumn Dice. Rolls completed: %d"):format(State.Rolls))
					local called, ok, result = pcall(invoke, rollRemote, CONFIG.RollAmount)
					AutumnTravel.release(owner)
					if not called then ok, result = false, ok end
					if not alive(id) then return end

					if ok and result ~= false then
						consecutiveErrors = 0
						State.Rolls += 1
						SetStatus("AutoRollEnabled", ("The custom rolling loop is active. Rolls completed: %d"):format(State.Rolls))
						if not sleep(id, CONFIG.RollDelay) then return end
					else
						consecutiveErrors += 1
						local msg = ("Roll failed (%d/%d): %s"):format(consecutiveErrors, CONFIG.MaxRollErrors, tostring(result))
						warn("[AutumnDice] " .. msg)
						if consecutiveErrors >= CONFIG.MaxRollErrors then
							failAndStop(id, msg .. " Auto Roll stopped.")
							return
						end
						SetStatus("Error", msg)
						if not sleep(id, CONFIG.RollErrorDelay) then return end
					end
				end
			else
				task.wait(0.1)
			end
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
	local owner = {}
	local locked = AutumnTravel.acquire(owner, function() return alive(id) end)
	local setupStarted = locked
	local ok, err = pcall(function()
		if locked and alive(id) then
			local rollRemote = runSetup(id)
			AutumnTravel.rollRemote = rollRemote
			AutumnTravel.release(owner)
			locked = false
			if rollRemote and alive(id) then rollLoop(id, rollRemote) end
		end
	end)
	if locked then AutumnTravel.release(owner) end
	workerActive = false

	if not setupStarted and alive(id) then
		failAndStop(id, "Could not acquire movement lock.")
	elseif not ok then
		failAndStop(id, "Unexpected error: " .. tostring(err))
	end
end

----------------------------------------------------------------------
-- AUTO TOWER
----------------------------------------------------------------------
-- Existing references (loaded lazily so a missing module shows an Error instead of crashing)
local TurkeyTowers, Towers, TowerController, DataController, BuffController, EntryRegistry
local RESTART_COOLDOWN = CONFIG.TowerRestartCooldown

local Tower = {
	loaded = false,
	lastLoadTry = -math.huge,
	loadError = nil,

	names = {},               -- current tower names from Towers.GetAll()
	options = {},
	displayByName = {},
	optionToName = {},
	catalog = {},
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
		local towers = require(features.Towers.Towers)
		local tc = require(features.Towers.TowerController)
		local dc = require(features.Data.DataController)
		local bc = require(features.Buffs.BuffController)
		local er = require(features.Inventory.EntryRegistry)
		TurkeyTowers, Towers, TowerController, DataController, BuffController, EntryRegistry = tt, towers, tc, dc, bc, er
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
	if section then
		if not milestones then
			return nil, "WaitingData", "Player data is not loaded yet."
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

	if Towers and Tower.catalog[name] then
		return Tower.catalog[name]
	end
	return nil, "Error", ("\"%s\" is not an available tower."):format(name)
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

local function towerTick()
	if not loadTowerModules() then
		if not Tower.loaded then
			SetTowerStatus("Error", "Tower modules unavailable: " .. tostring(Tower.loadError or "retrying..."))
		end
		return
	end

	local mode = State.TowerMode
	local section, key, detail

	if mode == "Single" then
		section, key, detail = selectSingle(getMilestones())
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
	if type(name) ~= "string" then return end
	name = Tower.optionToName[name] or name
	if not table.find(Tower.names, name) or State.SelectedTower == name then return end
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

	local lp = Players.LocalPlayer
	if not lp then
		warn("[AutumnDice] Anti AFK unavailable: LocalPlayer not ready")
		State.Features.AntiAfk = false -- keep the toggle truthful
		return
	end

	AntiAfk.conn = lp.Idled:Connect(function(timeIdled)
		-- simulate a right-click hold to reset the internal idle timer
		pcall(function()
			local camera = workspace.CurrentCamera
			local cf = camera and camera.CFrame or CFrame.new()
			VirtualUser:Button2Down(Vector2.new(0, 0), cf)
			task.wait(1)
			VirtualUser:Button2Up(Vector2.new(0, 0), cf)
			print("[AutumnDice] Anti-AFK triggered: prevented disconnect after " .. tostring(timeIdled) .. " seconds.")
		end)
	end)
end

local HttpService = game:GetService("HttpService")
local GuiService = game:GetService("GuiService")

local function hasFileApi()
	return type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
end

----------------------------------------------------------------------
-- AUTO RECONNECT
-- While enabled, a disconnect / error prompt starts a retry loop that teleports back to the
-- server saved when the toggle was turned on (or a fresh server if it can't be rejoined).
-- While disabled there are no connections and no loops.
----------------------------------------------------------------------
local TeleportService = game:GetService("TeleportService")
local Reconnect = { conns = {}, token = 0, running = false, gaveUp = false, failed = false }

local function watchDisconnect(cb)
	local conns = {}
	local ok, signal = pcall(function() return GuiService.ErrorMessageChanged end)
	if ok and signal then
		local connected, conn = pcall(function()
			return signal:Connect(function(message)
				if type(message) == "string" and message ~= "" then cb(message) end
			end)
		end)
		if connected and conn then table.insert(conns, conn) end
	end

	pcall(function()
		local coreGui = game:GetService("CoreGui")
		local promptGui = coreGui:FindFirstChild("RobloxPromptGui")
		local overlay = promptGui and promptGui:FindFirstChild("promptOverlay")
		if not overlay then return end
		local function inspect(child)
			if child.Name == "ErrorPrompt" then cb("error prompt") end
		end
		for _, child in ipairs(overlay:GetChildren()) do inspect(child) end
		table.insert(conns, overlay.ChildAdded:Connect(inspect))
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
	local maxAttempts, currentAttempt = CONFIG.ReconnectMaxAttempts, 1
	local delayTime = CONFIG.ReconnectDelay
	local targetPlaceId, targetJobId = game.PlaceId, game.JobId

	if hasFileApi() and isfile(CONFIG.ReconnectFile) then
		pcall(function()
			local saved = HttpService:JSONDecode(readfile(CONFIG.ReconnectFile))
			if saved and saved.PlaceId == game.PlaceId and type(saved.JobId) == "string" then
				targetJobId = saved.JobId
			end
		end)
	end

	local failConn
	pcall(function()
		failConn = TeleportService.TeleportInitFailed:Connect(function(failedPlayer)
			if failedPlayer == player then Reconnect.failed = true end
		end)
	end)

	local connected = false
	while currentAttempt <= maxAttempts do
		task.wait(delayTime)
		if token ~= Reconnect.token then break end

		Reconnect.failed = false
		local success, err = pcall(function()
			if targetJobId and targetJobId ~= "" then
				TeleportService:TeleportToPlaceInstance(targetPlaceId, targetJobId, player)
			else
				TeleportService:Teleport(targetPlaceId, player)
			end
		end)

		if success then
			for _ = 1, 20 do
				task.wait(0.5)
				if Reconnect.failed or token ~= Reconnect.token then break end
			end
			if token ~= Reconnect.token then break end
			if not Reconnect.failed then
				connected = true
				break
			end
			err = "Teleport failed to start"
		end

		warn(("[AutumnDice] Reconnect attempt %d/%d failed: %s"):format(currentAttempt, maxAttempts, tostring(err)))
		if targetJobId and targetJobId ~= "" then targetJobId = nil end
		currentAttempt += 1
		delayTime *= CONFIG.ReconnectBackoff
	end

	if failConn then failConn:Disconnect() end
	if token ~= Reconnect.token then return end
	Reconnect.running = false
	if not connected then
		Reconnect.gaveUp = true
		warn("[AutumnDice] Auto Reconnect gave up after " .. maxAttempts .. " attempts.")
	end
end

local function onReconnectNeeded(reason)
	if Reconnect.running or Reconnect.gaveUp or not State.Features.AutoReconnect then return end
	Reconnect.running = true
	warn("[AutumnDice] Disconnected (" .. tostring(reason) .. "). Reconnecting...")
	task.spawn(function()
		local ok, err = pcall(reconnectLoop, Reconnect.token)
		if not ok then
			Reconnect.running = false
			warn("[AutumnDice] Auto Reconnect error: " .. tostring(err))
		end
	end)
end

local function setAutoReconnect(enabled)
	Reconnect.token += 1
	Reconnect.running = false
	for _, conn in ipairs(Reconnect.conns) do pcall(function() conn:Disconnect() end) end
	Reconnect.conns = {}
	if not enabled then return end

	Reconnect.gaveUp = false
	saveServer()
	Reconnect.conns = watchDisconnect(onReconnectNeeded)
end
local setAutoClaim

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
	elseif name == "AutoReconnect" then
		setAutoReconnect(value)
		notify()
	elseif name == "AutoClaimQuest" then
		setAutoClaim(value)
		notify()
	else
		notify()
	end
end

local function GetFeature(name)
	return State.Features[name]
end

----------------------------------------------------------------------
-- TOWER STATS (Runs / Floors Cleared / Best Floor)
-- Floors come from the game's own Floor label ("Floor N"): every increase counts as cleared
-- floors, a drop means a new run began. Runs are counted by wrapping
-- TowerController.startTower (successful starts only, manual ones included).
----------------------------------------------------------------------
local FloorTracker = { label = nil, labelConn = nil, original = nil, wrapped = false, alive = true }

local function readFloorText(text)
	return tonumber(tostring(text):match("Floor%s+(%d+)"))
end

local function updateFloor()
	local label = FloorTracker.label
	if not label then return end
	local floor = readFloorText(label.Text)
	if not floor then return end

	local S = State.TowerStats
	if S.LastFloor then
		if floor > S.LastFloor then
			S.Floors += floor - S.LastFloor
		elseif floor < S.LastFloor then
			S.LastFloor = nil -- the floor counter reset: a new run began
		end
	end
	S.Best = math.max(S.Best, floor)
	S.LastFloor = floor
	S.Floor = floor
	S.Tracking = true
	notify()
end

local function connectFloorLabel()
	if FloorTracker.label then return true end
	local ok, label = pcall(function()
		local features = ReplicatedStorage.Framework.Features
		local UIReferences = require(features.UI.UIReferences)
		return UIReferences.Root.Tower.Screen.Floor
	end)
	if not ok or typeof(label) ~= "Instance" then return false end

	FloorTracker.label = label
	FloorTracker.labelConn = label:GetPropertyChangedSignal("Text"):Connect(updateFloor)
	updateFloor()
	return true
end

local function wrapStartTower()
	if FloorTracker.wrapped then return true end
	if not loadTowerModules() or not TowerController then return false end
	local original = TowerController.startTower
	if type(original) ~= "function" then return false end

	FloorTracker.original = original
	TowerController.startTower = function(...)
		local result = table.pack(original(...))
		if result[1] then
			local S = State.TowerStats
			S.Runs += 1
			S.LastFloor = nil
			S.Floor = nil
			notify()
		end
		return table.unpack(result, 1, result.n)
	end
	FloorTracker.wrapped = true
	return true
end

local function uninstallFloorHook()
	FloorTracker.alive = false
	if FloorTracker.labelConn then
		FloorTracker.labelConn:Disconnect()
		FloorTracker.labelConn = nil
	end
	if FloorTracker.wrapped and TowerController and FloorTracker.original then
		pcall(function() TowerController.startTower = FloorTracker.original end)
		FloorTracker.wrapped = false
	end
end

-- the game's modules / UI may not exist yet: keep trying until both are hooked
task.spawn(function()
	while FloorTracker.alive do
		local labelOk = connectFloorLabel()
		local wrapOk = wrapStartTower()
		if labelOk and wrapOk then break end
		task.wait(2)
	end
end)

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

-- V-shaped chevron drawn from two bars; Rotation = 180 turns it upside down
local function makeChevron(parent, position, color)
	local box = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = position,
		Size = UDim2.fromOffset(12, 12),
		BackgroundTransparency = 1,
		Parent = parent,
	})
	for _, spec in ipairs({ { 45, 3.75 }, { -45, 8.25 } }) do
		create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(spec[2], 5.75),
			Size = UDim2.fromOffset(7, 2),
			Rotation = spec[1],
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Parent = box,
		}, { create("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	end
	return box
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

local main = create("Frame", {
	Name = "Main",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(380, 460), -- real size comes from applyLayout() (screen based)
	BackgroundColor3 = THEME.bg,
	BorderSizePixel = 0,
	Parent = gui,
}, {
	corner(16),
	stroke(THEME.stroke),
	pad(8, 6, 8, 8),
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
	Text = "",
	AutoButtonColor = true,
	Parent = titleBar,
}, { corner(8) })
for _, rot in ipairs({ 45, -45 }) do
	create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(10, 2),
		Rotation = rot,
		BackgroundColor3 = THEME.subtext,
		BorderSizePixel = 0,
		Parent = closeBtn,
	}, { create("UICorner", { CornerRadius = UDim.new(1, 0) }) })
end

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

-- Layout: side navigation (left) + one page per tab (right) ----------------
local SIDEBAR_GAP = 8

-- fills the space between the title bar (top) and the footer (bottom)
local bodyRow = create("Frame", {
	Position = UDim2.fromOffset(0, 26),
	Size = UDim2.new(1, 0, 1, -52),
	BackgroundTransparency = 1,
	Parent = main,
})

local sidebar = create("ScrollingFrame", {
	Size = UDim2.new(0, 208, 1, 0),
	BackgroundColor3 = THEME.card,
	BorderSizePixel = 0,
	ScrollBarThickness = 0,
	ScrollingDirection = Enum.ScrollingDirection.Y,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(),
	Parent = bodyRow,
}, { corner(10), stroke(THEME.stroke), pad(6, 6, 6, 6), vlist(4) })

-- the tab pages live in here; it scrolls whenever a page is taller than the window
local content = create("ScrollingFrame", {
	Position = UDim2.fromOffset(208 + SIDEBAR_GAP, 0),
	Size = UDim2.new(1, -(208 + SIDEBAR_GAP), 1, 0),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 3,
	ScrollBarImageColor3 = THEME.accent,
	ScrollingDirection = Enum.ScrollingDirection.Y,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(),
	Parent = bodyRow,
}, { pad(0, 0, 6, 0) })
content:GetPropertyChangedSignal("CanvasPosition"):Connect(closeDropdowns)

-- Two-column container: two equal columns side by side on wide windows, stacked on narrow ones.
-- Equal widths come from 0.5 scale minus half the gap, so the columns stay even and aligned.
local COLUMN_GAP = 10
local twoColumnMode = false
local columnSets = {}

local function columnSize(two)
	return two and UDim2.new(0.5, -COLUMN_GAP / 2, 0, 0) or UDim2.new(1, 0, 0, 0)
end

local function makeColumns(parent, order)
	local layout = create("UIListLayout", {
		FillDirection = twoColumnMode and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical,
		Padding = UDim.new(0, twoColumnMode and COLUMN_GAP or 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = Enum.VerticalAlignment.Top,
	})
	local container = create("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = parent,
	}, { layout })

	local function column(columnOrder)
		return create("Frame", {
			LayoutOrder = columnOrder,
			Size = columnSize(twoColumnMode),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Parent = container,
		}, { vlist(8) })
	end

	local set = { layout = layout, left = column(1), right = column(2) }
	table.insert(columnSets, set)
	return set
end

-- Two equal columns when the window is wide enough (a lone card keeps its half width);
-- stacked into one column otherwise
local function layoutColumnSet(set)
	local two = twoColumnMode
	set.layout.FillDirection = two and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical
	set.layout.Padding = UDim.new(0, two and COLUMN_GAP or 8)
	set.left.Size = columnSize(two)
	set.right.Size = columnSize(two)
end

local function refreshColumns()
	for _, set in ipairs(columnSets) do layoutColumnSet(set) end
end

local function setColumnMode(two)
	twoColumnMode = two
	refreshColumns()
end

-- Responsive window: sized from the screen, never from the content
local function applyLayout()
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
	local w = math.min(math.clamp(math.floor(vp.X * 0.5), 320, 640), vp.X - 16)
	local h = math.min(math.clamp(math.floor(vp.Y * 0.75), 220, 580), vp.Y - 16)
	local sideW = (w >= 340) and 208 or 176

	-- two cards side by side only when each card would still be wide enough to read
	local contentW = w - 16 - (sideW + SIDEBAR_GAP) - 6
	setColumnMode(contentW >= 380)

	main.Size = UDim2.fromOffset(w, h)
	sidebar.Size = UDim2.new(0, sideW, 1, 0)
	content.Position = UDim2.fromOffset(sideW + SIDEBAR_GAP, 0)
	content.Size = UDim2.new(1, -(sideW + SIDEBAR_GAP), 1, 0)
	closeDropdowns()

	-- if the new size pushed the window off screen, put it back in the middle
	task.delay(0.1, function()
		if not main.Parent then return end
		local pos, size = main.AbsolutePosition, main.AbsoluteSize
		if pos.X < 0 or pos.Y < 0 or pos.X + size.X > vp.X or pos.Y + size.Y > vp.Y then
			main.Position = UDim2.fromScale(0.5, 0.5)
		end
	end)
end
applyLayout()

local cameraConn
local function watchCamera()
	if cameraConn then cameraConn:Disconnect() cameraConn = nil end
	local cam = workspace.CurrentCamera
	if cam then
		cameraConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(applyLayout)
		table.insert(connections, cameraConn)
	end
end
watchCamera()
table.insert(connections, workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	watchCamera()
	applyLayout()
end))

local tabs = {}

local function selectTab(name)
	closeDropdowns()
	content.CanvasPosition = Vector2.new(0, 0)
	for tabName, tab in pairs(tabs) do
		local on = (tabName == name)
		tab.page.Visible = on
		tab.bar.Visible = on
		tab.button.BackgroundTransparency = on and 0 or 1
		tab.label.TextColor3 = on and THEME.accent or THEME.body
	end
end

-- Adds a nav button + a page. Returns its two columns ({ left, right }) to put cards in.
local function addTab(order, name)
	local button = create("TextButton", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundColor3 = THEME.accentDim,
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Parent = sidebar,
	}, { corner(8) })
	local bar = create("Frame", {
		Size = UDim2.fromOffset(3, 14),
		Position = UDim2.new(0, 0, 0.5, -7),
		BackgroundColor3 = THEME.accent,
		BorderSizePixel = 0,
		Visible = false,
		Parent = button,
	}, { pill() })
	local label = create("TextLabel", {
		Size = UDim2.new(1, -14, 1, 0),
		Position = UDim2.fromOffset(10, 0),
		BackgroundTransparency = 1,
		Text = name,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextColor3 = THEME.body,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = button,
	})
	local page = create("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Visible = false,
		Parent = content,
	}, { vlist(8) })

	tabs[name] = { button = button, label = label, bar = bar, page = page }
	button.MouseButton1Click:Connect(function() selectTab(name) end)
	-- the page is a 2-column grid: build cards in .left and .right (they stack on narrow windows)
	return makeColumns(page, 1)
end

-- Collapsible card shown on a tab page: icon tile + title + chevron, then the body. Returns the body frame.
local function makeCard(parent, buildIcon, title, order)
	local card = create("Frame", {
		LayoutOrder = order or 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = THEME.card,
		BorderSizePixel = 0,
		Parent = parent,
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
	local chevron = makeChevron(header, UDim2.new(1, -10, 0.5, 0), THEME.subtext)

	local body = create("Frame", {
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = card,
	}, { vlist(8) })

	-- collapse / expand
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
		TextTruncate = Enum.TextTruncate.AtEnd,
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
	makeChevron(btn, UDim2.new(1, -14, 0.5, 0), THEME.body)

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
-- Tab: Auto Roll
----------------------------------------------------------------------
local rollBody = makeCard(addTab(1, "Roll").left, function(tile)
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
local leafBalance = makeLine(rollInfo, 2, 12, THEME.subtext)
local leafBalanceValue = 0
local leafBalanceHooked = false
task.spawn(function()
	while gui.Parent and not leafBalanceHooked do
		local ok = pcall(function()
			local features = ReplicatedStorage.Framework.Features
			local DataController = require(features.Data.DataController)
			local AutumnConfig = require(features.Autumn.AutumnConfig)
			local Leaves = AutumnConfig.Currencies.Leaves
			local inventory = DataController.Inventory[Leaves]
			local entry = inventory()
			leafBalanceValue = entry and entry.amount or 0
			inventory.Observe(function(entry)
				leafBalanceValue = entry and entry.amount or 0
			end)
		end)
		if ok then
			leafBalanceHooked = true
		else
			task.wait(1)
		end
	end
end)

----------------------------------------------------------------------
-- Tab: Auto Tower
----------------------------------------------------------------------
local towerTab = addTab(2, "Auto Tower")
local towerBody = makeCard(towerTab.left, function(tile)
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
end, "Auto Tower")

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

local statsLine = makeLine(towerInfo, 2, 10, THEME.subtext)
statsLine.TextWrapped = false
statsLine.TextTruncate = Enum.TextTruncate.AtEnd
----------------------------------------------------------------------
-- Tab: Miscellaneous
----------------------------------------------------------------------
local miscBody = makeCard(addTab(3, "Miscellaneous").left, function(tile)
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
end, "Miscellaneous")

makeToggle(miscBody, 1, "Anti AFK", "AntiAfk")
makeToggle(miscBody, 2, "Auto Reconnect", "AutoReconnect")

----------------------------------------------------------------------
-- Tab: Event -> Quest card (local player's Autumn quests, Daily + Hourly)
-- Data comes from DataController[period.dataKey]() and AutumnQuestConfig, the same way the
-- reference script reads them; the card re-renders whenever that data changes.
----------------------------------------------------------------------
local function questIcon(tile)
	-- "!" icon
	create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, -3),
		Size = UDim2.fromOffset(3, 10),
		BackgroundColor3 = THEME.accent,
		BorderSizePixel = 0,
		Parent = tile,
	}, { pill() })
	create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 7),
		Size = UDim2.fromOffset(3, 3),
		BackgroundColor3 = THEME.accent,
		BorderSizePixel = 0,
		Parent = tile,
	}, { pill() })
end

local eventTab = addTab(4, "Event")
local rollCard = rollBody.Parent
rollCard.Parent = eventTab.left
rollCard.LayoutOrder = 1
local questBody = makeCard(eventTab.right, questIcon, "Quest")
makeToggle(questBody, 1, "Auto Claim Quest", "AutoClaimQuest")
local questList = create("Frame", {
	LayoutOrder = 2,
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	Parent = questBody,
}, { vlist(4) })

local Quests = { loaded = false, hooked = {}, hooks = {}, signature = nil, dirty = true }

local QUEST_STATUS = {
	progress = { text = "In Progress", color = THEME.accent },
	complete = { text = "Complete", color = Color3.fromRGB(88, 204, 128) },
	claimed = { text = "Claimed", color = THEME.subtext },
}

local function loadQuestModules()
	if Quests.loaded then return true end
	local ok = pcall(function()
		local features = ReplicatedStorage.Framework.Features
		Quests.DataController = require(features.Data.DataController)
		Quests.Config = require(features.Autumn.AutumnQuestConfig)
	end)
	if not ok or not Quests.DataController or not Quests.Config then
		Quests.DataController, Quests.Config = nil, nil
		return false
	end
	Quests.loaded = true
	return true
end

-- Snapshot of every quest period, with progress clamped to 0..target
local function readQuestSections()
	if not Quests.loaded then
		return { { title = "Quests", quests = {}, message = "Waiting for the game's quest data..." } }
	end

	local sections = {}
	pcall(function()
		for _, period in Quests.Config.Periods do
			local title = tostring(period.title or period.dataKey)
			local section = { title = title, quests = {}, bonusClaimed = false }

			local okState, state = pcall(function() return Quests.DataController[period.dataKey]() end)
			if okState and type(state) == "table" and type(state.quests) == "table" and #state.quests > 0 then
				local progressMap = type(state.progress) == "table" and state.progress or {}
				local claimedMap = type(state.claimed) == "table" and state.claimed or {}

				for _, questId in ipairs(state.quests) do
					local okQ, quest = pcall(Quests.Config.GetQuest, questId)
					if okQ and type(quest) == "table" then
						local target = type(quest.target) == "number" and math.max(quest.target, 0) or 0
						local progress = progressMap[questId]
						progress = type(progress) == "number" and math.clamp(progress, 0, target) or 0
						local claimed = claimedMap[questId] == true
						table.insert(section.quests, {
							id = tostring(quest.id or questId),
							title = tostring(quest.title or questId),
							progress = progress,
							target = target,
							status = claimed and "claimed" or (progress >= target and "complete" or "progress"),
						})
					end
				end
				section.bonusClaimed = state.bonusClaimed == true
			end

			if #section.quests == 0 then
				section.message = "No " .. title .. " quests yet (still syncing or none rolled)"
			end
			table.insert(sections, section)
		end
	end)

	if #sections == 0 then
		sections = { { title = "Quests", quests = {}, message = "No quest periods found." } }
	end
	return sections
end

local function questSignature(sections)
	local parts = {}
	for _, sec in ipairs(sections) do
		table.insert(parts, ("%s|%s|%s"):format(sec.title, sec.message or "", tostring(sec.bonusClaimed)))
		for _, q in ipairs(sec.quests) do
			table.insert(parts, ("%s:%s:%s:%s:%s"):format(q.id, q.title, tostring(q.progress), tostring(q.target), q.status))
		end
	end
	return table.concat(parts, "\n")
end

local function buildQuestRow(parent, order, q)
	local info = QUEST_STATUS[q.status]
	local row = create("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = THEME.field,
		BorderSizePixel = 0,
		Parent = parent,
	}, { corner(6), pad(8, 6, 8, 6), vlist(4) })

	-- status column: progress while in progress, CLAIMED once claimed
	local statusText = info.text
	if q.status == "progress" then
		statusText = formatNumber(q.progress) .. "/" .. formatNumber(q.target)
	elseif q.status == "claimed" then
		statusText = "CLAIMED"
	end

	local top = create("Frame", {
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 16),
		BackgroundTransparency = 1,
		Parent = row,
	})
	create("TextLabel", {
		Size = UDim2.new(1, -72, 1, 0),
		BackgroundTransparency = 1,
		Text = q.title,
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextColor3 = THEME.text,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = top,
	})
	create("TextLabel", {
		Size = UDim2.new(0, 70, 1, 0),
		Position = UDim2.new(1, -70, 0, 0),
		BackgroundTransparency = 1,
		Text = statusText,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextColor3 = info.color,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = top,
	})

	local track = create("Frame", {
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 4),
		BackgroundColor3 = THEME.bg,
		BorderSizePixel = 0,
		Parent = row,
	}, { pill() })
	local ratio = q.target > 0 and (q.progress / q.target) or 1
	create("Frame", {
		Size = UDim2.fromScale(math.clamp(ratio, 0, 1), 1),
		BackgroundColor3 = info.color,
		BorderSizePixel = 0,
		Parent = track,
	}, { pill() })
end

-- Rebuilds the card only when the data actually changed
local function renderQuests()
	local sections = readQuestSections()
	local signature = questSignature(sections)
	if signature == Quests.signature then return end
	Quests.signature = signature

	for _, child in ipairs(questList:GetChildren()) do
		if child:IsA("GuiObject") then child:Destroy() end
	end

	for i, sec in ipairs(sections) do
		local block = create("Frame", {
			LayoutOrder = i,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Parent = questList,
		}, { vlist(4) })

		makeLine(block, 1, 12, THEME.text, Enum.Font.GothamBold).Text = sec.title
		if sec.message then
			makeLine(block, 2, 11, THEME.subtext).Text = sec.message
		end
		for j, q in ipairs(sec.quests) do
			buildQuestRow(block, 10 + j, q)
		end
		if #sec.quests > 0 then
			makeLine(block, 100, 11, THEME.subtext).Text = "Bonus claimed: " .. (sec.bonusClaimed and "Yes" or "No")
		end
	end
end

local function scheduleQuestRender()
	Quests.dirty = true
end
-- Re-render on any Daily/Hourly change: progress, claims, newly rolled quests
local function hookQuestChanges()
	if not Quests.loaded then return end
	for _, period in Quests.Config.Periods do
		local key = period.id or period.dataKey
		if not Quests.hooked[key] then
			local ok, conn = pcall(function()
				return Quests.DataController[period.dataKey].Changed(scheduleQuestRender)
			end)
			if ok then
				Quests.hooked[key] = true
				if conn ~= nil then table.insert(Quests.hooks, conn) end
			end
		end
	end
end
local function unhookQuests()
	for _, conn in ipairs(Quests.hooks) do
		pcall(function()
			if typeof(conn) == "RBXScriptConnection" then
				conn:Disconnect()
			elseif type(conn) == "table" and type(conn.Disconnect) == "function" then
				conn:Disconnect()
			elseif type(conn) == "function" then
				conn()
			end
		end)
	end
	Quests.hooks = {}
	Quests.hooked = {}
end

local AutoClaim = {
	loaded = false,
	token = 0,
	workerActive = false,
	claimInFlight = false,
	lastAttempt = {},
	lastSyncAttempt = 0,
}

local function loadAutoClaimModules()
	if AutoClaim.loaded then return true end
	if not loadQuestModules() then return false end

	local ok = pcall(function()
		local features = ReplicatedStorage.Framework.Features
		local Network = require(ReplicatedStorage.Packages.Network)
		local questComm = Network.ClientComm.new(ReplicatedStorage.Network, false, "AutumnQuestService")
		AutoClaim.AutumnConfig = require(features.Autumn.AutumnConfig)
		AutoClaim.claimQuest = questComm:GetFunction("Claim")
		AutoClaim.claimBonus = questComm:GetFunction("ClaimBonus")
		AutoClaim.sync = questComm:GetFunction("Sync")
	end)
	AutoClaim.loaded = ok
	return ok
end
local function autoClaimEnabled(token)
	return AutoClaim.token == token and State.Features.AutoClaimQuest
end

local function autoClaimActive(token)
	return autoClaimEnabled(token) and AutoClaim.AutumnConfig.ACTIVE == true
end

local function isAtQuestBoard()
	local zone = AutumnTravel.findZone("AutumnQuests")
	local root = getHRP()
	return zone ~= nil and root ~= nil and (root.Position - zone:GetPivot().Position).Magnitude < 8
end

local function ensureQuestBoard(token)
	local shouldContinue = function() return autoClaimActive(token) end
	local arrived, err = AutumnTravel.ensureInAutumnWorld(shouldContinue)
	if not arrived then return false, err end
	return AutumnTravel.walkToZone("AutumnQuests", shouldContinue)
end
local function readClaimState(period)
	local ok, raw = pcall(Quests.DataController[period.dataKey])
	if not ok or type(raw) ~= "table" or type(raw.quests) ~= "table" then return nil end
	return {
		quests = raw.quests,
		progress = type(raw.progress) == "table" and raw.progress or {},
		claimed = type(raw.claimed) == "table" and raw.claimed or {},
		bonusClaimed = raw.bonusClaimed == true,
	}
end

local function requestQuestClaim(token, key, callback, argument)
	if not autoClaimActive(token) or not AutumnTravel.isInAutumnWorld() or not isAtQuestBoard() then return false end
	local now = os.clock()
	if AutoClaim.claimInFlight or now - (AutoClaim.lastAttempt[key] or -math.huge) < 5 then return false end
	AutoClaim.claimInFlight = true
	local ok, result = pcall(callback, argument)
	AutoClaim.claimInFlight = false
	AutoClaim.lastAttempt[key] = os.clock()
	return ok and result ~= false
end

local function autoClaimPeriod(token, period)
	local state = readClaimState(period)
	if not state or #state.quests == 0 then return end

	for _, questId in state.quests do
		if not autoClaimActive(token) or not isAtQuestBoard() then return end
		if state.claimed[questId] ~= true then
			local ok, quest = pcall(Quests.Config.GetQuest, questId)
			local progress = state.progress[questId]
			progress = type(progress) == "number" and math.max(progress, 0) or 0
			if ok and type(quest) == "table" and type(quest.target) == "number" and progress >= quest.target then
				requestQuestClaim(token, "quest:" .. tostring(period.id) .. ":" .. tostring(questId), AutoClaim.claimQuest, questId)
			end
		end
	end

	state = readClaimState(period)
	if not state or state.bonusClaimed then return end
	for _, questId in state.quests do
		if state.claimed[questId] ~= true then return end
	end
	requestQuestClaim(token, "bonus:" .. tostring(period.id), AutoClaim.claimBonus, period.id)
end

local function hasClaimableQuest()
	for _, period in Quests.Config.Periods do
		local state = readClaimState(period)
		if state then
			local allClaimed = #state.quests > 0
			for _, questId in state.quests do
				if state.claimed[questId] ~= true then
					allClaimed = false
					local ok, quest = pcall(Quests.Config.GetQuest, questId)
					local progress = state.progress[questId]
					if ok and type(quest) == "table" and type(quest.target) == "number" and type(progress) == "number" and progress >= quest.target then
						return true
					end
				end
			end
			if allClaimed and not state.bonusClaimed then return true end
		end
	end
	return false
end

local function autoClaimWorker(token)
	while AutoClaim.workerActive and autoClaimEnabled(token) do task.wait(0.1) end
	if not autoClaimEnabled(token) then return end
	AutoClaim.workerActive = true
	local lastCharacter, needsSync = nil, true

	while autoClaimEnabled(token) do
		if not loadAutoClaimModules() then
			task.wait(1)
		elseif not autoClaimActive(token) then
			task.wait(1)
		else
			if player.Character ~= lastCharacter then
				lastCharacter = player.Character
				needsSync = true
			end

			if not hasClaimableQuest() then
				task.wait(1)
			else
				local owner = {}
				AutumnTravel.questRequested = true
				if AutumnTravel.acquire(owner, function() return autoClaimEnabled(token) end) then
					local ok, err = pcall(function()
						if not AutumnTravel.isInAutumnWorld() or not isAtQuestBoard() then
							needsSync = true
							local arrived, travelErr = ensureQuestBoard(token)
							if not arrived then error(travelErr or "Could not reach Quest Board.") end
						end
						if not autoClaimActive(token) or not isAtQuestBoard() then return end

						if needsSync and os.clock() - AutoClaim.lastSyncAttempt >= 3 then
							AutoClaim.lastSyncAttempt = os.clock()
							local synced, result = pcall(AutoClaim.sync)
							if synced and result ~= false then
								needsSync = false
								task.wait(1)
							end
						end
						if not needsSync then
							for _, period in Quests.Config.Periods do
								if not autoClaimActive(token) or not isAtQuestBoard() then break end
								pcall(autoClaimPeriod, token, period)
							end
						end

						if State.Features.AutoDice and autoClaimEnabled(token) then
							local returned, returnErr = AutumnTravel.walkToZone("LeafDice", function() return autoClaimEnabled(token) end)
							if not returned or not isAtLeafDice() then error(returnErr or "Could not verify return to LeafDice.") end
						end
					end)
					AutumnTravel.release(owner)
					AutumnTravel.questRequested = false
					if not ok then task.wait(1) end
				else
					AutumnTravel.questRequested = false
				end
				task.wait(1)
			end
		end
	end

	AutoClaim.workerActive = false
end
setAutoClaim = function(enabled)
	AutoClaim.token += 1
	
end

task.spawn(function()
	while gui.Parent do
		if State.Features.AutoClaimQuest then
			local ok = pcall(autoClaimWorker, AutoClaim.token)
			AutoClaim.workerActive = false
			if not ok then task.wait(1) end
		else
			task.wait(0.1)
		end
	end
end)
-- Render once data loads, then refresh on changes with a slow safety-net pass.
task.spawn(function()
	local nextLoadTry, nextHookTry, lastRender = 0, 0, 0
	while gui.Parent do
		local now = os.clock()
		if not Quests.loaded and now >= nextLoadTry and not loadQuestModules() then
			nextLoadTry = now + 1
		end
		if Quests.loaded then
			if now >= nextHookTry then
				hookQuestChanges()
				nextHookTry = now + 3
			end
			if Quests.dirty or now - lastRender >= 3 then
				Quests.dirty = false
				pcall(renderQuests)
				lastRender = now
			end
		end
		task.wait(0.1)
	end
end)
refreshColumns()
selectTab("Roll")

----------------------------------------------------------------------
-- Footer: hotkey
----------------------------------------------------------------------
local hotkeyRow = create("Frame", {
	Position = UDim2.new(0, 0, 1, -22),
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

-- Keep the dropdown in sync with the configured tower catalog
local lastSignature = nil
local function refreshTowerOptions()
	if not loadTowerModules() then return end

	local ok, all = pcall(Towers.GetAll)
	if not ok or type(all) ~= "table" then return end

	local turkeyNames, catalog = {}, {}
	for _, section in ipairs(TurkeyTowers.Sections) do
		if type(section) == "table" and type(section.name) == "string" then
			turkeyNames[section.name] = true
		end
	end

	for key, tower in pairs(all) do
		local name = type(tower) == "table" and (tower.name or tower.Name) or tower
		name = type(name) == "string" and name or (type(key) == "string" and key or nil)
		if name then
			local order = type(tower) == "table" and tonumber(tower.order or tower.Order) or nil
			catalog[name] = { name = name, order = order or math.huge }
		end
	end

	local entries = {}
	for _, tower in pairs(catalog) do table.insert(entries, tower) end
	table.sort(entries, function(a, b)
		if a.order == b.order then return a.name < b.name end
		return a.order < b.order
	end)

	local names, options, displayByName, optionToName = {}, {}, {}, {}
	for _, tower in ipairs(entries) do
		local name = tower.name
		local display = turkeyNames[name] and ("Turkey · " .. name) or name
		table.insert(names, name)
		table.insert(options, display)
		displayByName[name] = display
		optionToName[display] = name
	end

	local signature = table.concat(options, "\n")
	if signature == lastSignature then return end
	lastSignature = signature

	Tower.names, Tower.options = names, options
	Tower.displayByName, Tower.optionToName, Tower.catalog = displayByName, optionToName, catalog
	towerDropdown.SetOptions(options)

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
	leafBalance.Text = ("Leaf Balance: %s"):format(formatNumber(leafBalanceValue))

	-- Auto Tower
	local S = State.TowerStats
	local floorText = S.Floor and (" floor " .. S.Floor) or ""
	towerLine.Text = Tower.activeName and ("Tower: " .. (Tower.displayByName[Tower.activeName] or Tower.activeName) .. floorText) or "Tower: -"
	statsLine.Text = ("%d Runs | %s Floors Cleared | Best Floor %s"):format(S.Runs, S.Tracking and tostring(S.Floors) or "-", (S.Tracking and S.Best > 0) and tostring(S.Best) or "-")

	modeDropdown.SetValue(State.TowerMode)
	towerDropdown.SetValue(Tower.displayByName[State.SelectedTower] or State.SelectedTower)
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
	setAntiAfk(false)
	setAutoReconnect(false)
	uninstallFloorHook()
	unhookQuests()
	setAutoClaim(false)
	State.Features.AutoClaimQuest = false
	State.Features.AutoDice = false
	State.Features.AutoTower = false
	runId += 1
	towerRunId += 1
	for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
	if gui then gui:Destroy() end
	env.AutumnDice = nil
end

closeBtn.MouseButton1Click:Connect(Unload)

env.AutumnDice = {
	SetFeature = SetFeature,
	GetFeature = GetFeature,
	SetTowerMode = SetTowerMode,
	SetSelectedTower = SetSelectedTower,
	GetStatus = function() return State.Status, State.Detail end,
	GetTowerStatus = function() return State.TowerStatus, State.TowerDetail end,
	SetHotkey = function(keyCode) State.Hotkey = keyCode notify() end,
	Unload = Unload,
	Travel = AutumnTravel,
}

----------------------------------------------------------------------
-- Defaults: Anti AFK, Auto Reconnect and Auto Roll start ON. SetFeature starts the real
-- behavior, and the toggles follow State.
----------------------------------------------------------------------
for _, name in ipairs({ "AntiAfk", "AutoReconnect", "AutoDice" }) do
	SetFeature(name, true)
end
