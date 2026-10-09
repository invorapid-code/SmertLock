--[[
	SmertLock v2  —  hood utility
	file   : SmertLock_hood_v2.lua
	target : Roblox (R6 / R15) — executor with CoreGui + file API

	changelog vs previous build
	  * Advanced page removed, Silent Aim removed (config + __namecall hook + hitbox preview)
	  * tracer engine rewritten: pooled line frames, one draw path for tracer + skeleton,
	    viewport-space math, origin modes, rainbow, per-target end point
	  * fixed the coordinate-space bug — the old ScreenGui used IgnoreGuiInset = true while
	    every ESP position came from WorldToViewportPoint, so the whole overlay (tracer
	    included) was drawn 36 px off and the FOV/trigger ray used the wrong mouse space
	  * ESP / tracer now render for every player, not only for hand-picked ones
	    ("Selected only" is the opt-in filter now, off by default)
	  * menu rebuilt juju-style: grouped rail, multi-column checkbox cards, keybind badges
	  * added: skeleton ESP, hit marker, damage numbers, head dot, health colouring,
	    panic key, anti-AFK, notifications, watermark, profiles, keybind capture
]]

-- ============================================================================
--  AC BYPASS  (ported from the matcha.cc header)
--  matcha only matched args[1], so a dedicated remote named "BANREMOTE" that takes a
--  player as its first argument went straight through, and it filtered every namecall
--  instead of only remote sends. This checks the remote's own name AND the action
--  string, and only ever touches Remote* FireServer / InvokeServer.
--  The list is widened for the hood family and then auto-extended by scanning
--  ReplicatedStorage for remote names that look like anti-cheat plumbing.
-- ============================================================================

-- Scoped on purpose: every local in here dies at the `end`, so the main chunk stays
-- under Luau's 200-locals-per-function ceiling. The loop talks to this through _G.AC.
do

local AC = {
	blocked = 0,
	log = {},
	discovered = {},
	review = {},
	installed = false,
	method = nil,
	original = nil,
	wrapped = nil,
	aggressive = true,
	tracing = false,
	traced = {},
}

local AC_NAMES = {}
for _, name in ipairs({
	-- verbatim from the matcha header
	"TeleportDetect", "CHECKER_1", "CHECKER", "GUI_CHECK", "OneMoreTime",
	"checkingSPEED", "BANREMOTE", "PERMAIDBAN", "KICKREMOTE", "BR_KICKPC", "BR_KICKMOBILE",
	-- hood-family siblings
	"CHECKER_2", "CHECKER_3", "GUI_CHECK_2", "PERMABAN", "PERMABANREMOTE",
	"ACBAN", "ANTICHEATBAN", "SPEEDCHECK", "CHECKSPEED", "SPEEDCHECKER",
	"TELEPORTDETECTION", "DETECTED", "DETECTION",
}) do
	AC_NAMES[string.upper(name)] = true
end

local AC_PATTERNS = {
	"^BAN", "^KICK", "^PERMA", "CHECKER", "SPEEDCHECK", "CHECKSPEED",
	"TELEPORTDETECT", "ANTICHEAT", "^AC_", "DETECT",
}

-- auto-added by the scan: names that can only be anti-cheat plumbing
local AC_HARD = { "CHECKER", "SPEEDCHECK", "CHECKSPEED", "TELEPORTDETECT", "ANTICHEAT", "PERMABAN", "BANREMOTE", "KICKREMOTE", "GUI_CHECK" }
-- reported only: a "BanHammer" tool remote must not be swallowed
local AC_SOFT = { "^BAN", "^KICK", "^AC", "DETECT", "CHECK" }

local function ac_count()
	local n = 0
	for _ in pairs(AC_NAMES) do n += 1 end
	return n
end

local function ac_readback()
	local ok, value = pcall(function()
		local mt = getrawmetatable(game)
		return mt and mt.__namecall
	end)
	if ok then return value end
	return nil
end

local function ac_match(key)
	if key == nil or key == "" then return false end
	key = string.upper(key)
	if AC_NAMES[key] then return true end
	if AC.aggressive then
		for _, pattern in ipairs(AC_PATTERNS) do
			if string.find(key, pattern) then return true end
		end
	end
	return false
end

local function ac_block(remote_name, action, reason, method)
	AC.blocked += 1
	local entry = { remote = remote_name, action = action, reason = reason, method = method, at = os.clock() }
	table.insert(AC.log, entry)
	if #AC.log > 200 then table.remove(AC.log, 1) end
	AC.last = entry
	_G.AC_BYPASS_BLOCKED = AC.blocked
	_G.AC_BYPASS_LAST = entry
	-- the anti-cheat just tried to report: calm the rage side down as well
	if typeof(_G.RAGE_SUSPEND) == "function" then
		pcall(_G.RAGE_SUSPEND, tonumber(_G.AC_SUSPEND) or 15)
	end
end

-- hot path: runs on every instance namecall, so it filters on the method name first
-- and never builds an args table
local function ac_hook(self, ...)
	local method = getnamecallmethod()
	if method == "FireServer" or method == "InvokeServer" then
		local class = typeof(self) == "Instance" and self.ClassName or nil
		if class == "RemoteEvent" or class == "RemoteFunction" or class == "UnreliableRemoteEvent" then
			local first = ...
			local action = typeof(first) == "string" and first or nil

			if AC.tracing then
				AC.traced[tostring(self.Name) .. " -> " .. tostring(action)] = true
			end

			if ac_match(self.Name) then
				ac_block(self.Name, action, "remote", method)
				return nil
			elseif action and ac_match(action) then
				ac_block(self.Name, action, "action", method)
				return nil
			end
		end
	end
	return AC.original(self, ...)
end

local function ac_install()
	if AC.installed then return true end

	if typeof(hookmetamethod) == "function" then
		local ok, old = pcall(function()
			return hookmetamethod(game, "__namecall", ac_hook)
		end)
		if ok and old ~= nil then
			AC.original, AC.installed, AC.method = old, true, "hookmetamethod"
			AC.wrapped = ac_readback()
			return true
		end
	end

	if typeof(getrawmetatable) ~= "function" then return false end

	local ok = pcall(function()
		local mt = getrawmetatable(game)
		if not mt then error("no metatable") end
		setreadonly(mt, false)
		AC.original = mt.__namecall
		AC.wrapped = typeof(newcclosure) == "function" and newcclosure(ac_hook) or ac_hook
		mt.__namecall = AC.wrapped
	end)

	if ok and AC.original then
		AC.installed, AC.method = true, "getrawmetatable"
		return true
	end
	return false
end

local function ac_discover()
	local scanned = 0
	local function walk(node, level)
		for _, inst in ipairs(node:GetChildren()) do
			scanned += 1
			if scanned > 6000 then return end
			local class = inst.ClassName
			if class == "RemoteEvent" or class == "RemoteFunction" or class == "UnreliableRemoteEvent" then
				local key = string.upper(inst.Name)
				local hard = false
				for _, pattern in ipairs(AC_HARD) do
					if string.find(key, pattern) then hard = true break end
				end
				if hard and not AC_NAMES[key] then
					AC_NAMES[key] = true
					table.insert(AC.discovered, inst:GetFullName())
				elseif not hard then
					for _, pattern in ipairs(AC_SOFT) do
						if string.find(key, pattern) then
							table.insert(AC.review, inst:GetFullName())
							break
						end
					end
				end
			elseif level < 3 and (inst:IsA("Folder") or inst:IsA("Configuration")) then
				walk(inst, level + 1)
			end
		end
	end
	pcall(function() walk(game:GetService("ReplicatedStorage"), 1) end)
end

function AC.report()
	print("===== AC bypass =====")
	print("  hook    : " .. tostring(AC.installed) .. " via " .. tostring(AC.method))
	print("  names   : " .. ac_count() .. (AC.aggressive and " (patterns ON)" or " (patterns off)"))
	print("  blocked : " .. AC.blocked)
	if AC.last then
		print(string.format("  last    : %s -> %s (%s)",
			tostring(AC.last.remote), tostring(AC.last.action), tostring(AC.last.reason)))
	end
	for _, path in ipairs(AC.discovered) do print("  auto-added: " .. path) end
	for _, path in ipairs(AC.review) do print("  review    : " .. path) end
	print("=====================")
end

function AC.add(name)
	if type(name) == "string" and name ~= "" then AC_NAMES[string.upper(name)] = true end
end

function AC.trace_all(on)
	AC.tracing = on == true
	AC.traced = {}
end

function AC.trace()
	print("---- FireServer actions seen ----")
	for key in pairs(AC.traced) do print("  " .. key) end
	print("---------------------------------")
end

_G.AC = AC
_G.AC_SUSPEND = 15

do
	if ac_install() then
		ac_discover()
		print(string.format("[AC bypass] hooked via %s — %d names, %d auto-added, %d to review (AC.report())",
			tostring(AC.method), ac_count(), #AC.discovered, #AC.review))
	else
		warn("[AC bypass] executor has neither hookmetamethod nor getrawmetatable — running unblocked")
	end

	-- watchdog: if something re-patches __namecall, put ours back
	task.spawn(function()
		while true do
			task.wait(3)
			if AC.installed and AC.wrapped and typeof(getrawmetatable) == "function" then
				local current = ac_readback()
				if current and current ~= AC.wrapped then
					AC.installed = false
					ac_install()
				end
			end
		end
	end)
end

end

local Players            = game:GetService("Players")
local UserInputService   = game:GetService("UserInputService")
local RunService         = game:GetService("RunService")
local CoreGui            = game:GetService("CoreGui")
local Workspace          = game:GetService("Workspace")
local Stats              = game:GetService("Stats")
local GuiService         = game:GetService("GuiService")
local HttpService        = game:GetService("HttpService")
local TweenService       = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer

-- camera can be swapped by the game at any time — the old build cached it once and kept
-- projecting through a dead camera after the first respawn wave
local Camera = Workspace.CurrentCamera
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if Workspace.CurrentCamera then
		Camera = Workspace.CurrentCamera
	end
end)

-- ============================================================================
--  CONFIG
-- ============================================================================

local Config = {
	-- menu
	MenuKey        = "Right Alt",
	UITheme        = "Void",
	UIScale        = 1.0,
	ProfileName    = "default",
	Visible        = true,
	Watermark      = true,
	ShowFPS        = true,
	ShowPing       = true,
	Notifications  = true,

	-- combat
	Enabled          = true,
	WallCheck        = true,
	TeamCheck        = false,
	Smoothness       = 0.450,
	Prediction       = 0.100,
	AutoPrediction   = false,
	PredictionMultiplier = 0.0020,
	ReacquireDelay   = 0.05,
	FOVEnabled       = true,
	FOVRadius        = 120,
	FOVFilled        = false,
	FOVThickness     = 2,
	TargetPriority   = "Mouse Distance",
	TargetPart       = "HumanoidRootPart",
	ActivationMode   = "Right Mouse Click",
	TargetInfo       = true,

	-- trigger
	TriggerbotEnabled     = false,
	TriggerbotDelay       = 0.010,
	TriggerbotMaxDistance = 1000,
	RapidFireEnabled      = false,
	RapidFireDelay        = 0.060,
	RapidFireOnlyWhenHolding = false,

	-- visuals
	ESPEnabled       = true,
	ESPSelectedOnly  = false,
	ESPBox           = true,
	ESPBoxFilled     = false,
	ESPChams         = true,
	ESPTracer        = true,
	ESPSkeleton      = false,
	ESPHeadDot       = false,
	ESPName          = true,
	ESPDistance      = true,
	ESPHealth        = true,
	ESPHealthBar     = true,
	ESPWeapon        = false,
	ESPShowKO        = true,
	ESPMaxDistance   = 1000,
	ESPTeamColor     = false,
	ESPHealthColor   = false,
	ESPColorMode     = "Crimson",
	ESPCustomColor   = Color3.fromRGB(205, 35, 45),
	ESPBoxThickness       = 1,
	ESPFillTransparency   = 0.88,
	ESPChamsTransparency  = 0.72,
	ESPChamsOutlineTransparency = 0,
	ESPTracerThickness    = 2,
	ESPTracerTransparency = 0,
	ESPTracerColorMode    = "Match ESP",
	ESPTracerOrigin       = "Bottom",
	ESPTracerEnd          = "Box",
	ESPTracerRainbow      = false,
	ESPSkeletonThickness  = 1,

	-- utility
	FlyEnabled       = false,
	FlySpeed         = 55,
	FlyVerticalSpeed = 45,
	FlyBind          = "None",
	HitMarker        = true,
	DamageNumbers    = true,
	AntiAFK          = false,
	PanicBind        = "None",

	-- rage — kill aura
	KillAura          = false,
	KillAuraRange     = 200,
	KillAuraDelay     = 0.10,
	KillAuraMaxCPS    = 12,
	KillAuraCooldown  = true,      -- read the gun's own cooldown, never write to it
	KillAuraAmmo      = true,      -- refuse to fire a gun with Ammo == 0
	KillAuraWall      = true,
	KillAuraFace      = false,
	KillAuraTeam      = true,
	KillAuraFriends   = false,
	KillAuraPredict   = 0.02,

	-- rage — stomp
	StompAuto         = false,
	StompAura         = false,
	StompRange        = 200,
	StompRate         = 0.25,
	StompMaxDistance  = 20,        -- teleport range: 20 is melee-ish, 100+ is how people eat bans
	StompOffset       = 3,
	StompKey          = "Right Mouse Click",

	-- rage — defense / utility
	AntiStomp         = false,
	AntiStompParts    = false,
	Flashback         = false,
	AntiVoid          = false,
	AutoReload        = false,

	-- rage — wiring
	ShotFormat        = "Auto",    -- Auto | ShootGun | Shoot
	AcPreset          = "boomhood",
	AcSuspend         = 15,

	-- runtime state (never serialised)
	Target           = nil,
	IsHolding        = false,
	SelectedPlayers  = {},
	Binds = {
		camlock    = "None",
		fly        = "None",
		panic      = "None",
		killaura   = "None",
		autostomp  = "None",
		stompaura  = "None",
		antistomp  = "None",
	},
}

-- ============================================================================
--  THEME  (Void is the juju-style default: near-black, hairline strokes, pale accent)
-- ============================================================================

local THEMES = {
	Void = {
		Background = Color3.fromRGB(7, 7, 9),
		Panel      = Color3.fromRGB(13, 13, 16),
		Panel2     = Color3.fromRGB(20, 20, 24),
		Panel3     = Color3.fromRGB(28, 28, 33),
		Hover      = Color3.fromRGB(26, 26, 31),
		Text       = Color3.fromRGB(238, 238, 244),
		Muted      = Color3.fromRGB(126, 126, 138),
		Dim        = Color3.fromRGB(78, 78, 88),
		Accent     = Color3.fromRGB(230, 230, 240),
		Stroke     = Color3.fromRGB(34, 34, 40),
	},
	Crimson = {
		Background = Color3.fromRGB(9, 8, 10),
		Panel      = Color3.fromRGB(17, 15, 18),
		Panel2     = Color3.fromRGB(25, 21, 25),
		Panel3     = Color3.fromRGB(34, 28, 33),
		Hover      = Color3.fromRGB(31, 25, 30),
		Text       = Color3.fromRGB(245, 240, 242),
		Muted      = Color3.fromRGB(150, 130, 138),
		Dim        = Color3.fromRGB(92, 76, 84),
		Accent     = Color3.fromRGB(229, 62, 76),
		Stroke     = Color3.fromRGB(52, 34, 40),
	},
	Midnight = {
		Background = Color3.fromRGB(7, 9, 14),
		Panel      = Color3.fromRGB(13, 16, 24),
		Panel2     = Color3.fromRGB(19, 23, 34),
		Panel3     = Color3.fromRGB(26, 32, 46),
		Hover      = Color3.fromRGB(24, 29, 42),
		Text       = Color3.fromRGB(238, 242, 252),
		Muted      = Color3.fromRGB(126, 138, 165),
		Dim        = Color3.fromRGB(74, 84, 106),
		Accent     = Color3.fromRGB(88, 140, 255),
		Stroke     = Color3.fromRGB(34, 42, 60),
	},
	Emerald = {
		Background = Color3.fromRGB(7, 11, 10),
		Panel      = Color3.fromRGB(12, 18, 16),
		Panel2     = Color3.fromRGB(18, 26, 23),
		Panel3     = Color3.fromRGB(25, 35, 31),
		Hover      = Color3.fromRGB(22, 32, 28),
		Text       = Color3.fromRGB(238, 250, 245),
		Muted      = Color3.fromRGB(122, 150, 140),
		Dim        = Color3.fromRGB(70, 92, 84),
		Accent     = Color3.fromRGB(46, 205, 140),
		Stroke     = Color3.fromRGB(32, 48, 42),
	},
}

local T = THEMES[Config.UITheme] or THEMES.Void

local KEYMAP = {
	["Right Mouse Click"] = Enum.UserInputType.MouseButton2,
	["Left Mouse Click"]  = Enum.UserInputType.MouseButton1,
	["The Letter F"] = Enum.KeyCode.F,
	["The Letter E"] = Enum.KeyCode.E,
	["The Letter Q"] = Enum.KeyCode.Q,
	["The Letter R"] = Enum.KeyCode.R,
	["The Letter T"] = Enum.KeyCode.T,
	["The Letter G"] = Enum.KeyCode.G,
	["The Letter H"] = Enum.KeyCode.H,
	["The Letter J"] = Enum.KeyCode.J,
	["The Letter X"] = Enum.KeyCode.X,
	["The Letter C"] = Enum.KeyCode.C,
	["The Letter V"] = Enum.KeyCode.V,
	["The Letter Z"] = Enum.KeyCode.Z,
	["The Letter B"] = Enum.KeyCode.B,
}

local MENUKEYS = {
	["Right Alt"]        = Enum.KeyCode.RightAlt,
	["Right Control"]    = Enum.KeyCode.RightControl,
	["The Letter Insert"] = Enum.KeyCode.Insert,
	["The Letter F8"]    = Enum.KeyCode.F8,
}

-- ============================================================================
--  SHARED STATE
-- ============================================================================

local GUI_INSET   = GuiService:GetGuiInset()
local SCREEN_GUI
local ESP_SCREEN_GUI
local MainFrame
local Scale
local Content
local ESPFolder
local OverlayFolder
local FOVFrame, FOVStroke
local TargetInfo, TargetName, TargetState, TargetHealth, TargetDistance, TargetWeapon
local HitMarker, DamageLayer, ToastLayer, Watermark
local pages, pageCards, navItems = {}, {}, {}
local registry, refreshables = {}, {}
local BIND_ROWS, BIND_ACTIONS = {}, {}

local esps = {}
local toasts = {}
local damage_numbers = {}

local dragging, dragStart, startPos
local sliding_slider
local capturing
local saveStatus = "ready"
local lastTrigger, lastAcquire = 0, 0
local lastRapidFire = 0
local cachedPing, lastPingUpdate = 0, 0
local fpsFrames, fpsClock, fpsValue = 0, os.clock(), 0
local hitmarkerUntil = 0
local cachedCharacter, cachedHumanoid, cachedRoot
local FlyVelocity, FlyGyro
local stopFly

local notify      -- forward decls used by widgets / input
local refreshESPList
local applyTheme
local updatePlayerList
local select_page
local panic_now
local current_page_name = "Combat"

-- ============================================================================
--  MATH / SCREEN HELPERS
-- ============================================================================

-- GetMouseLocation() is screen space (top of the window). Everything else here —
-- WorldToViewportPoint, ViewportPointToRay, Camera.ViewportSize — is viewport space.
-- GUI_INSET is the bridge; the old build skipped it, which is why aim and overlay drifted.
local function mouse_pos()
	return UserInputService:GetMouseLocation() - Vector2.new(0, GUI_INSET.Y)
end

local function safeCall(fn, ...)
	local ok, result = pcall(fn, ...)
	if ok then return result end
	return nil
end

local function round(value, step)
	step = step or 1
	return math.floor(value / step + 0.5) * step
end

local function fmt(value, pattern)
	return string.format(pattern or "%.3f", value)
end

local function short_key(name)
	if not name or name == "None" then return "None" end
	name = name:gsub("MouseButton", "M"):gsub("KeyCode", "")
	return name
end

local function is_activating(input)
	local goal = KEYMAP[Config.ActivationMode]
	if typeof(goal) ~= "EnumItem" then return false end
	if goal.EnumType == Enum.UserInputType then
		return input.UserInputType == goal
	end
	if goal.EnumType == Enum.KeyCode then
		return input.KeyCode == goal
	end
	return false
end

local function key_or_input_matches(bind, input)
	local goal = KEYMAP[bind]
	if typeof(goal) ~= "EnumItem" then return false end
	if goal.EnumType == Enum.UserInputType then
		return input.UserInputType == goal
	end
	if goal.EnumType == Enum.KeyCode then
		return input.KeyCode == goal
	end
	return false
end

local function get_menu_key()
	return MENUKEYS[Config.MenuKey] or Enum.KeyCode.RightAlt
end

-- ============================================================================
--  CHARACTER HELPERS
-- ============================================================================

local function get_character_state(player)
	if not player or player == LocalPlayer then
		return "Invalid", nil, nil, nil
	end
	local char = player.Character
	if not char then
		return "Dead", nil, nil, nil
	end
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	local body = char:FindFirstChild("BodyEffects")

	if humanoid and humanoid.Health <= 0 then
		return "Dead", char, humanoid, root
	end

	if body then
		local ko = body:FindFirstChild("K.O") or body:FindFirstChild("KO")
		if ko and ko:IsA("BoolValue") and ko.Value then
			return "KO", char, humanoid, root
		end
		local grabbed = body:FindFirstChild("Grabbed")
		if grabbed and grabbed:IsA("BoolValue") and grabbed.Value then
			return "KO", char, humanoid, root
		end
	end

	if char:FindFirstChild("GRABBING_CONSTRAINT") then
		return "KO", char, humanoid, root
	end

	if not humanoid or not root then
		return "Invalid", char, humanoid, root
	end
	return "Alive", char, humanoid, root
end

local function is_valid_target(player)
	if not player or player == LocalPlayer then return false end
	if Config.TeamCheck and player.Team ~= nil and LocalPlayer.Team ~= nil and player.Team == LocalPlayer.Team then
		return false
	end
	local state = get_character_state(player)
	return state == "Alive"
end

local function get_weapon_name(player)
	if not player or not player.Character then return "None" end
	local tool = player.Character:FindFirstChildOfClass("Tool")
	if tool then return tool.Name end
	return "None"
end

local function get_ping()
	local value = safeCall(function()
		local item = Stats.Network.ServerStatsItem["Data Ping"]
		if item then
			return tonumber(string.match(item:GetValueString(), "%d+%.?%d*")) or 0
		end
		return 0
	end)
	return tonumber(value) or 0
end

local function get_prediction()
	if not Config.AutoPrediction then
		return Config.Prediction
	end
	local now = os.clock()
	if now - lastPingUpdate >= 0.5 then
		cachedPing = get_ping()
		lastPingUpdate = now
	end
	return math.clamp(Config.Prediction + cachedPing * Config.PredictionMultiplier, 0.01, 0.8)
end

local function get_target_part(char)
	if not char then return nil end
	if Config.TargetPart == "Legs" then
		return char:FindFirstChild("LeftLowerLeg")
			or char:FindFirstChild("RightLowerLeg")
			or char:FindFirstChild("Left Leg")
			or char:FindFirstChild("Right Leg")
			or char:FindFirstChild("HumanoidRootPart")
	end
	return char:FindFirstChild(Config.TargetPart)
end

-- ============================================================================
--  SCREEN PROJECTION
-- ============================================================================

local PROJECT_PAD = 96

local function project(part)
	if not part then return nil end
	local pos, on_screen = Camera:WorldToViewportPoint(part.Position)
	if pos.Z <= 0.5 or not on_screen then return nil end
	-- WorldToViewportPoint returns finite but wild numbers for geometry beside or
	-- behind the camera. Feeding those into a Frame produced the lines that shot
	-- across the whole screen. Anything outside the padded rect is dropped instead.
	local vp = Camera.ViewportSize
	if pos.X < -PROJECT_PAD or pos.Y < -PROJECT_PAD
		or pos.X > vp.X + PROJECT_PAD or pos.Y > vp.Y + PROJECT_PAD then
		return nil
	end
	return Vector2.new(pos.X, pos.Y)
end

-- Body parts are resolved once per character (re-checked twice a second so a rig
-- swap or a late-loading limb cannot leave a stale, nil or flung reference behind).
local BODY_PARTS = {
	R15 = {
		"Head", "UpperTorso", "LowerTorso", "HumanoidRootPart",
		"LeftUpperArm", "LeftLowerArm", "LeftHand",
		"RightUpperArm", "RightLowerArm", "RightHand",
		"LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
		"RightUpperLeg", "RightLowerLeg", "RightFoot",
	},
	R6 = {
		"Head", "Torso", "HumanoidRootPart",
		"Left Arm", "Right Arm", "Left Leg", "Right Leg",
	},
}

local function rig_parts(rec, char)
	local now = os.clock()
	if rec.rig_char == char and rec.rig_clock and now - rec.rig_clock < 0.5 then
		return rec.rig, rec.parts
	end

	rec.rig_char = char
	rec.rig_clock = now
	local rig = char:FindFirstChild("UpperTorso") and "R15" or "R6"
	rec.rig = rig

	local parts = {}
	for _, name in ipairs(BODY_PARTS[rig]) do
		parts[name] = char:FindFirstChild(name)
	end
	rec.parts = parts
	return rig, parts
end

-- Bounds from the body parts, not Model:GetBoundingBox(). An AABB swallows welded
-- junk (a tossed accessory, a ragdoll constraint) and one bad corner stretches the
-- box, its health bar and every line attached to it across the screen.
local function char_bounds(rec, char)
	local rig, parts = rig_parts(rec, char)
	local vp = Camera.ViewportSize
	local min_x, min_y = math.huge, math.huge
	local max_x, max_y = -math.huge, -math.huge
	local hits = 0

	for _, name in ipairs(BODY_PARTS[rig]) do
		local screen = project(parts[name])
		if screen then
			hits += 1
			if screen.X < min_x then min_x = screen.X end
			if screen.Y < min_y then min_y = screen.Y end
			if screen.X > max_x then max_x = screen.X end
			if screen.Y > max_y then max_y = screen.Y end
		end
	end

	if hits < 2 then return nil end

	local w, h = max_x - min_x, max_y - min_y
	if w > vp.X * 1.2 or h > vp.Y * 1.5 then return nil end

	return {
		x = min_x,
		y = min_y,
		w = math.max(3, w),
		h = math.max(6, h),
	}
end

-- ============================================================================
--  ESP COLOR
-- ============================================================================

local PALETTE = {
	Crimson = Color3.fromRGB(255, 70, 85),
	Blue    = Color3.fromRGB(70, 140, 255),
	Cyan    = Color3.fromRGB(60, 230, 255),
	Purple  = Color3.fromRGB(175, 80, 255),
	Pink    = Color3.fromRGB(255, 90, 190),
	Green   = Color3.fromRGB(70, 230, 120),
	Lime    = Color3.fromRGB(170, 255, 70),
	Yellow  = Color3.fromRGB(255, 225, 70),
	Orange  = Color3.fromRGB(255, 145, 55),
	White   = Color3.fromRGB(245, 245, 245),
}

local function esp_color(player, state, humanoid)
	if state == "KO" then
		return Color3.fromRGB(255, 170, 40)
	end
	if Config.ESPHealthColor and humanoid and humanoid.MaxHealth > 0 then
		local ratio = math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
		return Color3.fromRGB(math.floor(255 * (1 - ratio)), math.floor(255 * ratio), 70)
	end
	if Config.ESPTeamColor and player.Team then
		return player.Team.TeamColor.Color
	end
	if Config.ESPColorMode == "Custom" then
		return Config.ESPCustomColor
	end
	if Config.ESPColorMode == "Rainbow" then
		return Color3.fromHSV((os.clock() * 0.18) % 1, 0.9, 1)
	end
	return PALETTE[Config.ESPColorMode] or T.Accent
end

-- ============================================================================
--  UI PRIMITIVES
-- ============================================================================

local function reg(obj, kind, slot)
	table.insert(registry, { obj = obj, kind = kind, slot = slot })
	return obj
end

local function corner(obj, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 6)
	c.Parent = obj
	return c
end

local function stroke(obj, slot, thickness)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness or 1
	s.Color = T[slot or "Stroke"]
	s.Transparency = 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = obj
	return reg(s, "stroke", slot or "Stroke")
end

local function label(parent, text, size, position, textSize, slot, font)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = size
	l.Position = position or UDim2.new()
	l.Text = text
	l.TextSize = textSize or 12
	l.Font = font or Enum.Font.GothamMedium
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextColor3 = T[slot or "Text"]
	l.Parent = parent
	return reg(l, "text", slot or "Text")
end

-- ============================================================================
--  SCREEN GUI + WINDOW SHELL
-- ============================================================================

SCREEN_GUI = Instance.new("ScreenGui")
SCREEN_GUI.Name = "SmertLock"
SCREEN_GUI.ResetOnSpawn = false
SCREEN_GUI.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
SCREEN_GUI.DisplayOrder = 100
-- GUI space now equals viewport space, so WorldToViewportPoint coordinates land exactly
-- where they should. IgnoreGuiInset = true was the 36 px overlay drift.
SCREEN_GUI.IgnoreGuiInset = false
local gui_parent = CoreGui
if typeof(gethui) == "function" then
	gui_parent = safeCall(gethui) or CoreGui
end
SCREEN_GUI.Parent = gui_parent

-- ESP uses WorldToViewportPoint coordinates. Give it its own ScreenGui on a higher
-- DisplayOrder so it never shares a render layer with the menu — but keep
-- IgnoreGuiInset = false, because viewport space starts below the topbar (the GUI
-- inset). With IgnoreGuiInset = true every box and tracer would sit 36 px high.
ESP_SCREEN_GUI = Instance.new("ScreenGui")
ESP_SCREEN_GUI.Name = "SmertLock_ESP_Overlay"
ESP_SCREEN_GUI.ResetOnSpawn = false
ESP_SCREEN_GUI.IgnoreGuiInset = false
ESP_SCREEN_GUI.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ESP_SCREEN_GUI.DisplayOrder = 101
ESP_SCREEN_GUI.Parent = gui_parent

MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.new(0, 840, 0, 520)
MainFrame.Position = UDim2.new(0.5, -420, 0.5, -260)
MainFrame.BackgroundColor3 = T.Background
MainFrame.BorderSizePixel = 0
MainFrame.ClipsDescendants = true
MainFrame.Parent = SCREEN_GUI
corner(MainFrame, 12)
reg(MainFrame, "bg", "Background")
stroke(MainFrame, "Stroke")

Scale = Instance.new("UIScale")
Scale.Scale = Config.UIScale
Scale.Parent = MainFrame

-- ---------------------------------------------------------------- rail ------
local Rail = Instance.new("Frame")
Rail.Name = "Rail"
Rail.Size = UDim2.new(0, 178, 1, 0)
Rail.BackgroundColor3 = T.Panel
Rail.BorderSizePixel = 0
Rail.Parent = MainFrame
corner(Rail, 12)
reg(Rail, "bg", "Panel")

-- rail right seam
local RailSeam = Instance.new("Frame")
RailSeam.Size = UDim2.new(0, 1, 1, -16)
RailSeam.Position = UDim2.new(1, -1, 0, 8)
RailSeam.BackgroundColor3 = T.Stroke
RailSeam.BorderSizePixel = 0
RailSeam.Parent = Rail
reg(RailSeam, "bg", "Stroke")

-- ------------------------------------------------------------- logotype -----
local Logobox = Instance.new("Frame")
Logobox.Size = UDim2.new(1, -20, 0, 54)
Logobox.Position = UDim2.new(0, 10, 0, 10)
Logobox.BackgroundTransparency = 1
Logobox.Parent = Rail

local Mark = Instance.new("Frame")
Mark.Size = UDim2.new(0, 30, 0, 30)
Mark.Position = UDim2.new(0, 4, 0, 12)
Mark.BackgroundColor3 = T.Background
Mark.BorderSizePixel = 0
Mark.Parent = Logobox
corner(Mark, 15)
reg(Mark, "bg", "Background")
stroke(Mark, "Accent", 1)

local MarkDot = Instance.new("Frame")
MarkDot.Size = UDim2.new(0, 3, 0, 3)
MarkDot.AnchorPoint = Vector2.new(0.5, 0.5)
MarkDot.Position = UDim2.new(0.5, 0, 0.5, 0)
MarkDot.BackgroundColor3 = T.Accent
MarkDot.BorderSizePixel = 0
MarkDot.Parent = Mark
corner(MarkDot, 2)
reg(MarkDot, "bg", "Accent")

for _, axis in ipairs({ "x", "y" }) do
	for _, side in ipairs({ -1, 1 }) do
		local tick = Instance.new("Frame")
		tick.AnchorPoint = Vector2.new(0.5, 0.5)
		if axis == "x" then
			tick.Size = UDim2.new(0, 9, 0, 1)
			tick.Position = UDim2.new(0.5, 20 * side, 0.5, 0)
		else
			tick.Size = UDim2.new(0, 1, 0, 9)
			tick.Position = UDim2.new(0.5, 0, 0.5, 20 * side)
		end
		tick.BackgroundColor3 = T.Accent
		tick.BorderSizePixel = 0
		tick.Parent = Mark
		reg(tick, "bg", "Accent")
	end
end

local Wordmark = label(Logobox, "SMERTLOCK", UDim2.new(1, -50, 0, 18), UDim2.new(0, 44, 0, 12), 15, "Text", Enum.Font.GothamBold)
local Submark = label(Logobox, "v2  ·  hood utility", UDim2.new(1, -50, 0, 14), UDim2.new(0, 44, 0, 29), 10, "Muted", Enum.Font.Gotham)

local RailDivider = Instance.new("Frame")
RailDivider.Size = UDim2.new(1, -20, 0, 1)
RailDivider.Position = UDim2.new(0, 10, 0, 70)
RailDivider.BackgroundColor3 = T.Stroke
RailDivider.BorderSizePixel = 0
RailDivider.Parent = Rail
reg(RailDivider, "bg", "Stroke")

-- ---------------------------------------------------------------- nav -------
local NavHolder = Instance.new("Frame")
NavHolder.Size = UDim2.new(1, -16, 1, -136)
NavHolder.Position = UDim2.new(0, 8, 0, 82)
NavHolder.BackgroundTransparency = 1
NavHolder.Parent = Rail

local NavLayout = Instance.new("UIListLayout")
NavLayout.Padding = UDim.new(0, 2)
NavLayout.SortOrder = Enum.SortOrder.LayoutOrder
NavLayout.Parent = NavHolder

local nav_order = 0
local function add_nav_group(title)
	nav_order += 1
	local spacer = Instance.new("Frame")
	spacer.Size = UDim2.new(1, 0, 0, 22)
	spacer.BackgroundTransparency = 1
	spacer.LayoutOrder = nav_order
	spacer.Parent = NavHolder
	local lbl = label(spacer, string.upper(title), UDim2.new(1, -8, 0, 14), UDim2.new(0, 6, 0, 8), 10, "Dim", Enum.Font.GothamBold)
	lbl.TextXAlignment = Enum.TextXAlignment.Left
end

local function add_nav_item(page_name, display)
	nav_order += 1
	local button = Instance.new("TextButton")
	button.Size = UDim2.new(1, 0, 0, 30)
	button.BackgroundColor3 = T.Panel
	button.BackgroundTransparency = 1
	button.Text = ""
	button.AutoButtonColor = false
	button.LayoutOrder = nav_order
	button.Parent = NavHolder
	corner(button, 6)

	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(0, 2, 0, 14)
	bar.Position = UDim2.new(0, 0, 0.5, -7)
	bar.BackgroundColor3 = T.Accent
	bar.BorderSizePixel = 0
	bar.Visible = false
	bar.Parent = button
	corner(bar, 1)
	reg(bar, "bg", "Accent")

	local txt = label(button, display, UDim2.new(1, -22, 1, 0), UDim2.new(0, 14, 0, 0), 12, "Muted")
	txt.TextYAlignment = Enum.TextYAlignment.Center

	button.MouseEnter:Connect(function()
		if pages[page_name] and pages[page_name].Visible then return end
		button.BackgroundTransparency = 0
		button.BackgroundColor3 = T.Hover
	end)
	button.MouseLeave:Connect(function()
		if pages[page_name] and pages[page_name].Visible then return end
		button.BackgroundTransparency = 1
	end)
	button.MouseButton1Click:Connect(function()
		if select_page then select_page(page_name) end
	end)

	table.insert(navItems, { name = page_name, button = button, bar = bar, text = txt })
	return button
end

-- ------------------------------------------------------------- content ------
Content = Instance.new("Frame")
Content.Size = UDim2.new(1, -178, 1, 0)
Content.Position = UDim2.new(0, 178, 0, 0)
Content.BackgroundTransparency = 1
Content.Parent = MainFrame

local PageTitle = label(Content, "Combat", UDim2.new(1, -40, 0, 26), UDim2.new(0, 20, 0, 16), 19, "Text", Enum.Font.GothamBold)
local PageSubtitle = label(Content, "", UDim2.new(1, -40, 0, 16), UDim2.new(0, 20, 0, 42), 11, "Muted")

local PageHost = Instance.new("Frame")
PageHost.Size = UDim2.new(1, -20, 1, -78)
PageHost.Position = UDim2.new(0, 10, 0, 70)
PageHost.BackgroundTransparency = 1
PageHost.Parent = Content

-- ------------------------------------------------------------- toast --------
ToastLayer = Instance.new("Frame")
ToastLayer.Size = UDim2.new(0, 260, 1, -40)
ToastLayer.Position = UDim2.new(1, -276, 0, 20)
ToastLayer.BackgroundTransparency = 1
ToastLayer.Parent = SCREEN_GUI

local ToastLayout = Instance.new("UIListLayout")
ToastLayout.Padding = UDim.new(0, 6)
ToastLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
ToastLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
ToastLayout.SortOrder = Enum.SortOrder.LayoutOrder
ToastLayout.Parent = ToastLayer

notify = function(title, body)
	if not Config.Notifications then return end
	local card = Instance.new("Frame")
	card.Size = UDim2.new(1, 0, 0, 44)
	card.BackgroundColor3 = T.Panel
	card.BorderSizePixel = 0
	card.BackgroundTransparency = 0.05
	card.LayoutOrder = #toasts + 1
	card.Parent = ToastLayer
	corner(card, 8)
	stroke(card, "Stroke")

	local accent = Instance.new("Frame")
	accent.Size = UDim2.new(0, 2, 1, -16)
	accent.Position = UDim2.new(0, 0, 0, 8)
	accent.BackgroundColor3 = T.Accent
	accent.BorderSizePixel = 0
	accent.Parent = card
	corner(accent, 1)

	local t = label(card, title, UDim2.new(1, -24, 0, 16), UDim2.new(0, 12, 0, 6), 11, "Text", Enum.Font.GothamBold)
	t.TextYAlignment = Enum.TextYAlignment.Center
	local b = label(card, body or "", UDim2.new(1, -24, 0, 14), UDim2.new(0, 12, 0, 23), 10, "Muted")
	b.TextYAlignment = Enum.TextYAlignment.Center

	table.insert(toasts, { frame = card, born = os.clock() })
end

-- ------------------------------------------------------------ watermark -----
Watermark = Instance.new("Frame")
Watermark.Size = UDim2.new(0, 210, 0, 26)
Watermark.Position = UDim2.new(0, 14, 0, 14)
Watermark.BackgroundColor3 = T.Panel
Watermark.BackgroundTransparency = 0.12
Watermark.BorderSizePixel = 0
Watermark.Parent = SCREEN_GUI
corner(Watermark, 6)
stroke(Watermark, "Stroke")
reg(Watermark, "bg", "Panel")

local WmBar = Instance.new("Frame")
WmBar.Size = UDim2.new(0, 2, 1, -12)
WmBar.Position = UDim2.new(0, 0, 0, 6)
WmBar.BackgroundColor3 = T.Accent
WmBar.BorderSizePixel = 0
WmBar.Parent = Watermark
corner(WmBar, 1)
reg(WmBar, "bg", "Accent")

local WmText = label(Watermark, "SMERTLOCK v2", UDim2.new(1, -14, 1, 0), UDim2.new(0, 10, 0, 0), 11, "Text", Enum.Font.GothamBold)
WmText.TextYAlignment = Enum.TextYAlignment.Center

-- ============================================================================
--  WIDGETS
-- ============================================================================

local function cursor_add(cur, height)
	local y = cur.y
	cur.y = cur.y + height + 4
	return y
end

local function make_card(page_name, column, title)
	local page = pages[page_name]
	local card = Instance.new("Frame")
	card.Name = "card_" .. tostring(title)
	card.BackgroundColor3 = T.Panel
	card.BorderSizePixel = 0
	card.Parent = page
	corner(card, 9)
	stroke(card, "Stroke")
	reg(card, "bg", "Panel")

	local header = label(card, string.upper(title), UDim2.new(1, -20, 0, 16), UDim2.new(0, 12, 0, 10), 11, "Muted", Enum.Font.GothamBold)

	local cur = { frame = card, y = 32, page = page_name, column = column }
	table.insert(pageCards[page_name][column], cur)
	return cur
end

local function hoverable(frame, base_slot)
	local base = base_slot or "Panel2"
	frame.BackgroundColor3 = T[base]
	frame.BackgroundTransparency = 1
	frame.MouseEnter:Connect(function()
		frame.BackgroundTransparency = 0
		frame.BackgroundColor3 = T.Hover
	end)
	frame.MouseLeave:Connect(function()
		frame.BackgroundTransparency = 1
	end)
end

local function ui_check(cur, text, get, set, bind_id)
	local y = cursor_add(cur, 28)

	local row = Instance.new("TextButton")
	row.Size = UDim2.new(1, -16, 0, 28)
	row.Position = UDim2.new(0, 8, 0, y)
	row.BackgroundColor3 = T.Hover
	row.BackgroundTransparency = 1
	row.Text = ""
	row.AutoButtonColor = false
	row.Parent = cur.frame
	corner(row, 6)
	hoverable(row)

	local mark = label(row, "", UDim2.new(0, 16, 0, 16), UDim2.new(0, 6, 0, 6), 13, "Accent", Enum.Font.GothamBold)
	mark.TextXAlignment = Enum.TextXAlignment.Center

	local name = label(row, text, UDim2.new(0.6, 0, 1, 0), UDim2.new(0, 26, 0, 0), 12, "Muted")
	name.TextYAlignment = Enum.TextYAlignment.Center

	local badge = Instance.new("TextButton")
	badge.Size = UDim2.new(0, 34, 0, 18)
	badge.Position = UDim2.new(1, -40, 0, 5)
	badge.BackgroundColor3 = T.Panel3
	badge.BackgroundTransparency = 0.4
	badge.Text = ""
	badge.AutoButtonColor = false
	badge.TextSize = 10
	badge.Font = Enum.Font.GothamBold
	badge.TextColor3 = T.Dim
	badge.Parent = row
	corner(badge, 4)
	reg(badge, "bg", "Panel3")
	reg(badge, "text", "Dim")

	local function refresh()
		local on = get()
		mark.Text = on and "✓" or ""
		name.TextColor3 = on and T.Text or T.Muted
		if bind_id then
			local key = Config.Binds[bind_id]
			if key and key ~= "None" then
				badge.Text = short_key(key)
				badge.TextColor3 = T.Accent
			else
				badge.Text = "✦"
				badge.TextColor3 = T.Dim
			end
		else
			badge.Visible = false
		end
	end

	row.MouseButton1Click:Connect(function()
		set(not get())
		refresh()
	end)

	if bind_id then
		badge.MouseButton1Click:Connect(function()
			capturing = { id = bind_id, refresh = refresh }
			notify("Keybind", "Press a key — Backspace clears")
		end)
		BIND_ROWS[bind_id] = refresh
		BIND_ACTIONS[bind_id] = function()
			set(not get())
			refresh()
		end
	end

	refresh()
	table.insert(refreshables, refresh)
	return refresh
end

local function ui_slider(cur, text, min, max, get, set, pattern, step)
	local y = cursor_add(cur, 40)

	local holder = Instance.new("Frame")
	holder.Size = UDim2.new(1, -16, 0, 40)
	holder.Position = UDim2.new(0, 8, 0, y)
	holder.BackgroundTransparency = 1
	holder.Parent = cur.frame

	local name = label(holder, text, UDim2.new(1, -70, 0, 16), UDim2.new(0, 2, 0, 2), 12, "Muted")
	local value = label(holder, "", UDim2.new(0, 66, 0, 16), UDim2.new(1, -68, 0, 2), 11, "Text")
	value.TextXAlignment = Enum.TextXAlignment.Right

	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(1, -4, 0, 5)
	bar.Position = UDim2.new(0, 2, 0, 28)
	bar.BackgroundColor3 = T.Panel3
	bar.BorderSizePixel = 0
	bar.Parent = holder
	corner(bar, 3)
	reg(bar, "bg", "Panel3")

	-- a 5 px bar is a miserable grab target — this transparent plate widens the hit area
	local grab = Instance.new("Frame")
	grab.Size = UDim2.new(1, -4, 0, 18)
	grab.Position = UDim2.new(0, 2, 0, 21)
	grab.BackgroundTransparency = 1
	grab.Active = true
	grab.Parent = holder

	local fill = Instance.new("Frame")
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = T.Accent
	fill.BorderSizePixel = 0
	fill.Parent = bar
	corner(fill, 3)
	reg(fill, "bg", "Accent")

	local knob = Instance.new("Frame")
	knob.Size = UDim2.new(0, 11, 0, 11)
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.BackgroundColor3 = T.Text
	knob.BorderSizePixel = 0
	knob.Parent = bar
	corner(knob, 6)
	reg(knob, "bg", "Text")

	local function refresh()
		local v = get()
		local pct = math.clamp((v - min) / (max - min), 0, 1)
		fill.Size = UDim2.new(pct, 0, 1, 0)
		knob.Position = UDim2.new(pct, 0, 0.5, 0)
		value.Text = fmt(v, pattern)
	end

	grab.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			sliding_slider = { bar = bar, min = min, max = max, set = set, refresh = refresh, step = step }
		end
	end)

	refresh()
	table.insert(refreshables, refresh)
	return refresh
end

local function ui_dropdown(cur, text, options, get, set)
	local y = cursor_add(cur, 28)

	local row = Instance.new("TextButton")
	row.Size = UDim2.new(1, -16, 0, 28)
	row.Position = UDim2.new(0, 8, 0, y)
	row.BackgroundTransparency = 1
	row.BackgroundColor3 = T.Hover
	row.Text = ""
	row.AutoButtonColor = false
	row.Parent = cur.frame
	corner(row, 6)
	hoverable(row)

	local name = label(row, text, UDim2.new(0.55, 0, 1, 0), UDim2.new(0, 8, 0, 0), 12, "Muted")
	name.TextYAlignment = Enum.TextYAlignment.Center

	local value = label(row, "", UDim2.new(0.45, -10, 1, 0), UDim2.new(0.55, 0, 0, 0), 12, "Text")
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.TextYAlignment = Enum.TextYAlignment.Center

	local function refresh()
		value.Text = tostring(get())
	end

	row.MouseButton1Click:Connect(function()
		local current = get()
		local index = 1
		for i, option in ipairs(options) do
			if option == current then index = i break end
		end
		index = index % #options + 1
		set(options[index])
		refresh()
	end)

	refresh()
	table.insert(refreshables, refresh)
	return refresh
end

local function ui_button(cur, text, callback)
	local y = cursor_add(cur, 28)

	local button = Instance.new("TextButton")
	button.Size = UDim2.new(1, -16, 0, 28)
	button.Position = UDim2.new(0, 8, 0, y)
	button.BackgroundColor3 = T.Panel2
	button.Text = text
	button.TextSize = 12
	button.Font = Enum.Font.GothamMedium
	button.TextColor3 = T.Text
	button.AutoButtonColor = false
	button.Parent = cur.frame
	corner(button, 6)
	stroke(button, "Stroke")
	reg(button, "bg", "Panel2")
	reg(button, "text", "Text")

	button.MouseEnter:Connect(function() button.BackgroundColor3 = T.Panel3 end)
	button.MouseLeave:Connect(function() button.BackgroundColor3 = T.Panel2 end)
	button.MouseButton1Click:Connect(function() safeCall(callback) end)
	return button
end

local function ui_note(cur, text)
	local y = cursor_add(cur, 18)
	return label(cur.frame, text, UDim2.new(1, -16, 0, 18), UDim2.new(0, 10, 0, y), 10, "Dim")
end

local function ui_custom(cur, height)
	local y = cursor_add(cur, height)
	local holder = Instance.new("Frame")
	holder.Size = UDim2.new(1, -16, 0, height)
	holder.Position = UDim2.new(0, 8, 0, y)
	holder.BackgroundTransparency = 1
	holder.Parent = cur.frame
	return holder
end

-- ============================================================================
--  PAGES
-- ============================================================================

local function create_page(name, title, subtitle)
	local page = Instance.new("ScrollingFrame")
	page.Name = name
	page.Size = UDim2.new(1, 0, 1, 0)
	page.BackgroundTransparency = 1
	page.BorderSizePixel = 0
	page.ScrollBarThickness = 2
	page.ScrollBarImageColor3 = T.Accent
	page.CanvasSize = UDim2.new(0, 0, 0, 0)
	page.AutomaticCanvasSize = Enum.AutomaticSize.Y
	page.ScrollingDirection = Enum.ScrollingDirection.Y
	page.Visible = false
	page.Parent = PageHost

	pages[name] = page
	pageCards[name] = { [0] = {}, [1] = {}, [2] = {} }
	page:SetAttribute("Title", title)
	page:SetAttribute("Subtitle", subtitle or "")
	return page
end

-- cards are stacked per column after everything is measured, so a card can grow
-- while widgets are added without pushing the ones below it out of place
local function finish_page(name)
	for column = 0, 2 do
		local list = pageCards[name][column]
		if not list then continue end
		local y = 0
		for _, cur in ipairs(list) do
			local height = cur.y + 4
			cur.frame.Size = (column == 0)
				and UDim2.new(1, 0, 0, height)
				or UDim2.new(0.5, -6, 0, height)
			cur.frame.Position = (column == 0)
				and UDim2.new(0, 0, 0, y)
				or UDim2.new(column == 1 and 0 or 0.5, column == 1 and 0 or 6, 0, y)
			y = y + height + 10
		end
	end
end

select_page = function(name)
	current_page_name = name
	for page_name, page in pairs(pages) do
		page.Visible = (page_name == name)
	end
	local page = pages[name]
	if page then
		PageTitle.Text = page:GetAttribute("Title") or name
		PageSubtitle.Text = page:GetAttribute("Subtitle") or ""
	end
	for _, item in ipairs(navItems) do
		local active = item.name == name
		item.bar.Visible = active
		item.button.BackgroundTransparency = active and 0 or 1
		item.button.BackgroundColor3 = active and T.Panel2 or T.Panel
		item.text.TextColor3 = active and T.Text or T.Muted
	end
end

-- ============================================================================
--  PAGE — COMBAT
-- ============================================================================

create_page("Combat", "Combat", "camlock · triggerbot · acquisition")
do
	local c1 = make_card("Combat", 1, "general")
	ui_check(c1, "camlock", function() return Config.Enabled end, function(v) Config.Enabled = v end, "camlock")
	ui_check(c1, "wall check", function() return Config.WallCheck end, function(v) Config.WallCheck = v end)
	ui_check(c1, "team check", function() return Config.TeamCheck end, function(v) Config.TeamCheck = v end)
	ui_check(c1, "auto prediction", function() return Config.AutoPrediction end, function(v) Config.AutoPrediction = v end)
	ui_check(c1, "fov circle", function() return Config.FOVEnabled end, function(v) Config.FOVEnabled = v end)
	ui_check(c1, "filled fov", function() return Config.FOVFilled end, function(v) Config.FOVFilled = v end)
	ui_check(c1, "target info", function() return Config.TargetInfo end, function(v) Config.TargetInfo = v end)
	ui_dropdown(c1, "activation", { "Right Mouse Click", "Left Mouse Click", "The Letter F", "The Letter E", "The Letter Q" },
		function() return Config.ActivationMode end, function(v) Config.ActivationMode = v end)
	ui_dropdown(c1, "priority", { "Mouse Distance", "World Distance" },
		function() return Config.TargetPriority end, function(v) Config.TargetPriority = v end)
	ui_dropdown(c1, "target part", { "Head", "HumanoidRootPart", "Legs" },
		function() return Config.TargetPart end, function(v) Config.TargetPart = v end)
	ui_slider(c1, "smoothness", 0.01, 0.9, function() return Config.Smoothness end,
		function(v) Config.Smoothness = v end, "%.3f", 0.001)
	ui_slider(c1, "prediction", 0.00, 0.40, function() return Config.Prediction end,
		function(v) Config.Prediction = v end, "%.3f", 0.001)
	ui_slider(c1, "fov radius", 25, 500, function() return Config.FOVRadius end,
		function(v) Config.FOVRadius = math.floor(v + 0.5) end, "%d px", 1)
	ui_slider(c1, "fov thickness", 1, 4, function() return Config.FOVThickness end,
		function(v) Config.FOVThickness = math.floor(v + 0.5) end, "%d px", 1)

	local c2 = make_card("Combat", 2, "trigger")
	ui_check(c2, "triggerbot", function() return Config.TriggerbotEnabled end, function(v) Config.TriggerbotEnabled = v end)
	ui_check(c2, "rapid fire", function() return Config.RapidFireEnabled end, function(v) Config.RapidFireEnabled = v end)
	ui_check(c2, "only while aiming", function() return Config.RapidFireOnlyWhenHolding end, function(v) Config.RapidFireOnlyWhenHolding = v end)
	ui_check(c2, "hit marker", function() return Config.HitMarker end, function(v) Config.HitMarker = v end)
	ui_check(c2, "damage numbers", function() return Config.DamageNumbers end, function(v) Config.DamageNumbers = v end)
	ui_slider(c2, "trigger delay", 0, 0.20, function() return Config.TriggerbotDelay end,
		function(v) Config.TriggerbotDelay = v end, "%.3f s", 0.001)
	ui_slider(c2, "trigger range", 50, 2000, function() return Config.TriggerbotMaxDistance end,
		function(v) Config.TriggerbotMaxDistance = math.floor(v + 0.5) end, "%d studs", 10)
	ui_slider(c2, "fire delay", 0.02, 0.25, function() return Config.RapidFireDelay end,
		function(v) Config.RapidFireDelay = v end, "%.3f s", 0.005)
	ui_slider(c2, "reacquire", 0.00, 0.50, function() return Config.ReacquireDelay end,
		function(v) Config.ReacquireDelay = v end, "%.3f s", 0.005)
	ui_note(c2, "triggerbot re-uses the held tool — aim first, it fires on lock")
end

-- ============================================================================
--  PAGE — VISUALS
-- ============================================================================

create_page("Visuals", "Visuals", "esp · chams · tracer · skeleton")
do
	local c1 = make_card("Visuals", 1, "general")
	ui_check(c1, "esp master", function() return Config.ESPEnabled end, function(v) Config.ESPEnabled = v end)
	ui_check(c1, "selected only", function() return Config.ESPSelectedOnly end, function(v) Config.ESPSelectedOnly = v end)
	ui_check(c1, "names", function() return Config.ESPName end, function(v) Config.ESPName = v end)
	ui_check(c1, "distance", function() return Config.ESPDistance end, function(v) Config.ESPDistance = v end)
	ui_check(c1, "health text", function() return Config.ESPHealth end, function(v) Config.ESPHealth = v end)
	ui_check(c1, "health bar", function() return Config.ESPHealthBar end, function(v) Config.ESPHealthBar = v end)
	ui_check(c1, "weapon", function() return Config.ESPWeapon end, function(v) Config.ESPWeapon = v end)
	ui_check(c1, "show ko", function() return Config.ESPShowKO end, function(v) Config.ESPShowKO = v end)
	ui_check(c1, "team colors", function() return Config.ESPTeamColor end, function(v) Config.ESPTeamColor = v end)
	ui_check(c1, "health color", function() return Config.ESPHealthColor end, function(v) Config.ESPHealthColor = v end)
	ui_dropdown(c1, "color", { "Crimson", "Blue", "Cyan", "Purple", "Pink", "Green", "Lime", "Yellow", "Orange", "White", "Rainbow" },
		function() return Config.ESPColorMode end, function(v) Config.ESPColorMode = v end)
	ui_slider(c1, "max distance", 100, 5000, function() return Config.ESPMaxDistance end,
		function(v) Config.ESPMaxDistance = math.floor(v + 0.5) end, "%d studs", 10)

	local c2 = make_card("Visuals", 2, "visualization")
	ui_check(c2, "2d box", function() return Config.ESPBox end, function(v) Config.ESPBox = v end)
	ui_check(c2, "box fill", function() return Config.ESPBoxFilled end, function(v) Config.ESPBoxFilled = v end)
	ui_check(c2, "chams", function() return Config.ESPChams end, function(v) Config.ESPChams = v end)
	ui_check(c2, "tracer", function() return Config.ESPTracer end, function(v) Config.ESPTracer = v end)
	ui_check(c2, "tracer rainbow", function() return Config.ESPTracerRainbow end, function(v) Config.ESPTracerRainbow = v end)
	ui_dropdown(c2, "tracer color", { "Match ESP", "Crimson", "Blue", "Cyan", "Purple", "Pink", "Green", "Lime", "Yellow", "Orange", "White", "Rainbow" },
		function() return Config.ESPTracerColorMode end, function(v) Config.ESPTracerColorMode = v end)
	ui_check(c2, "skeleton", function() return Config.ESPSkeleton end, function(v) Config.ESPSkeleton = v end)
	ui_check(c2, "head dot", function() return Config.ESPHeadDot end, function(v) Config.ESPHeadDot = v end)
	ui_dropdown(c2, "tracer origin", { "Bottom", "Crosshair", "Top", "Mouse" },
		function() return Config.ESPTracerOrigin end, function(v) Config.ESPTracerOrigin = v end)
	ui_dropdown(c2, "tracer end", { "Box", "Head" },
		function() return Config.ESPTracerEnd end, function(v) Config.ESPTracerEnd = v end)
	ui_slider(c2, "box thickness", 1, 4, function() return Config.ESPBoxThickness end,
		function(v) Config.ESPBoxThickness = math.floor(v + 0.5) end, "%d px", 1)
	ui_slider(c2, "tracer thickness", 1, 6, function() return Config.ESPTracerThickness end,
		function(v) Config.ESPTracerThickness = math.floor(v + 0.5) end, "%d px", 1)
	ui_slider(c2, "tracer opacity", 0, 0.9, function() return Config.ESPTracerTransparency end,
		function(v) Config.ESPTracerTransparency = v end, "%.2f", 0.01)
	ui_slider(c2, "outline opacity", 0, 1, function() return Config.ESPChamsOutlineTransparency end,
		function(v) Config.ESPChamsOutlineTransparency = v end, "%.2f", 0.01)
	ui_slider(c2, "skeleton thickness", 1, 3, function() return Config.ESPSkeletonThickness end,
		function(v) Config.ESPSkeletonThickness = math.floor(v + 0.5) end, "%d px", 1)
	ui_slider(c2, "chams alpha", 0, 1, function() return Config.ESPChamsTransparency end,
		function(v) Config.ESPChamsTransparency = v end, "%.2f", 0.01)
	ui_slider(c2, "fill alpha", 0, 1, function() return Config.ESPFillTransparency end,
		function(v) Config.ESPFillTransparency = v end, "%.2f", 0.01)
end

-- ============================================================================
--  PAGE — PLAYERS
-- ============================================================================

create_page("Players", "Players", "target list · state · distance")
local player_rows_holder, player_search, player_sort
do
	local c0 = make_card("Players", 0, "targets")
	player_search = Instance.new("TextBox")
	player_search.Size = UDim2.new(1, 0, 0, 30)
	player_search.Position = UDim2.new(0, 0, 0, cursor_add(c0, 30))
	player_search.BackgroundColor3 = T.Panel2
	player_search.BorderSizePixel = 0
	player_search.PlaceholderText = "search by name…"
	player_search.Text = ""
	player_search.ClearTextOnFocus = false
	player_search.TextSize = 12
	player_search.Font = Enum.Font.Gotham
	player_search.TextColor3 = T.Text
	player_search.PlaceholderColor3 = T.Dim
	player_search.TextXAlignment = Enum.TextXAlignment.Left
	player_search.Parent = c0.frame
	corner(player_search, 6)
	stroke(player_search, "Stroke")
	reg(player_search, "bg", "Panel2")

	ui_dropdown(c0, "sort", { "Distance", "Name", "Health" },
		function() return player_sort or "Distance" end,
		function(v) player_sort = v end)

	player_rows_holder = ui_custom(c0, 320)
	local list = Instance.new("ScrollingFrame")
	list.Size = UDim2.new(1, 0, 1, 0)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 2
	list.ScrollBarImageColor3 = T.Accent
	list.CanvasSize = UDim2.new(0, 0, 0, 0)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.Parent = player_rows_holder
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	player_rows_holder = list

	local row_buttons = ui_custom(c0, 28)
	local function half(text, x, callback)
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0.5, -3, 1, 0)
		b.Position = UDim2.new(x, x > 0 and 6 or 0, 0, 0)
		b.BackgroundColor3 = T.Panel2
		b.Text = text
		b.TextSize = 11
		b.Font = Enum.Font.GothamBold
		b.TextColor3 = T.Text
		b.AutoButtonColor = false
		b.Parent = row_buttons
		corner(b, 5)
		stroke(b, "Stroke")
		reg(b, "bg", "Panel2")
		reg(b, "text", "Text")
		b.MouseEnter:Connect(function() b.BackgroundColor3 = T.Panel3 end)
		b.MouseLeave:Connect(function() b.BackgroundColor3 = T.Panel2 end)
		b.MouseButton1Click:Connect(function() safeCall(callback) end)
		return b
	end
	half("lock nearest", 0, function()
		local best, best_dist = nil, math.huge
		local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= LocalPlayer and is_valid_target(p) then
				local proot = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
				if root and proot then
					local d = (root.Position - proot.Position).Magnitude
					if d < best_dist then best, best_dist = p, d end
				end
			end
		end
		if best then
			Config.SelectedPlayers = { [best.UserId] = true }
			notify("Target", "locked " .. best.DisplayName)
		else
			notify("Target", "nobody alive in range")
		end
		updatePlayerList()
	end)
	half("clear list", 1, function()
		Config.SelectedPlayers = {}
		notify("Target", "list cleared")
		updatePlayerList()
	end)

	-- live search + a slow tick so hp / distance / state stay honest
	player_search:GetPropertyChangedSignal("Text"):Connect(function()
		updatePlayerList()
	end)
end

-- ============================================================================
--  PAGE — UTILITY
-- ============================================================================

create_page("Utility", "Utility", "movement · assists · interface assets")
do
	local c1 = make_card("Utility", 1, "movement")
	ui_check(c1, "fly", function() return Config.FlyEnabled end,
		function(v)
			Config.FlyEnabled = v
			if not v and stopFly then stopFly() end
		end, "fly")
	ui_dropdown(c1, "fly bind", { "None", "The Letter F", "The Letter G", "The Letter H", "The Letter J", "The Letter X", "The Letter C", "The Letter V" },
		function() return Config.FlyBind end, function(v) Config.FlyBind = v end)
	ui_slider(c1, "fly speed", 10, 250, function() return Config.FlySpeed end,
		function(v) Config.FlySpeed = math.floor(v + 0.5) end, "%d", 1)
	ui_slider(c1, "fly vertical", 10, 200, function() return Config.FlyVerticalSpeed end,
		function(v) Config.FlyVerticalSpeed = math.floor(v + 0.5) end, "%d", 1)
	ui_note(c1, "wasd to move · space / left-ctrl for altitude")

	local c2 = make_card("Utility", 2, "assists")
	ui_check(c2, "anti-afk", function() return Config.AntiAFK end, function(v) Config.AntiAFK = v end)
	ui_check(c2, "notifications", function() return Config.Notifications end, function(v) Config.Notifications = v end)
	ui_check(c2, "watermark", function() return Config.Watermark end, function(v) Config.Watermark = v end)
	ui_button(c2, "panic — drop everything", function()
		panic_now()
	end)
	ui_button(c2, "test notification", function()
		notify("SmertLock", "this is a toast")
	end)
	ui_note(c2, "panic key is bound from the settings page")
end

-- ============================================================================
--  PAGE — SETTINGS
-- ============================================================================

create_page("Settings", "Settings", "theme · binds · profiles")
local status_label
do
	local c1 = make_card("Settings", 1, "interface")
	ui_dropdown(c1, "theme", { "Void", "Crimson", "Midnight", "Emerald" },
		function() return Config.UITheme end,
		function(v)
			Config.UITheme = v
			T = THEMES[v] or THEMES.Void
			applyTheme()
		end)
	ui_dropdown(c1, "menu key", { "Right Alt", "Right Control", "The Letter Insert", "The Letter F8" },
		function() return Config.MenuKey end, function(v) Config.MenuKey = v end)
	ui_dropdown(c1, "ui scale", { "0.80", "0.90", "1.00", "1.10", "1.20" },
		function() return fmt(Config.UIScale, "%.2f") end,
		function(v)
			Config.UIScale = tonumber(v) or 1.0
			Scale.Scale = Config.UIScale
		end)
	ui_check(c1, "show fps", function() return Config.ShowFPS end, function(v) Config.ShowFPS = v end)
	ui_check(c1, "show ping", function() return Config.ShowPing end, function(v) Config.ShowPing = v end)
	ui_check(c1, "fps in watermark", function() return Config.Watermark end, function(v) Config.Watermark = v end)

	local c2 = make_card("Settings", 2, "profiles")
	ui_dropdown(c2, "profile", { "default", "rage", "legit", "visuals" },
		function() return Config.ProfileName or "default" end,
		function(v) Config.ProfileName = v end)
	ui_button(c2, "save profile", function()
		saveStatus = save_config() and ("saved " .. (Config.ProfileName or "default")) or "save unavailable"
		notify("Profile", saveStatus)
	end)
	ui_button(c2, "load profile", function()
		saveStatus = load_config() and ("loaded " .. (Config.ProfileName or "default")) or "load unavailable"
		notify("Profile", saveStatus)
	end)
	ui_button(c2, "reset target / camera", function()
		Config.Target = nil
		Config.IsHolding = false
		saveStatus = "target reset"
	end)
	status_label = ui_note(c2, "status: ready")
	ui_note(c2, "profiles write to SmertLock_v2_<profile>.json")
end

-- ============================================================================
--  PAGE — RAGE
-- ============================================================================

create_page("Rage", "Rage", "kill aura · stomp · defenses")
do
	local rage_status_label
	local c1 = make_card("Rage", 1, "kill aura")
	ui_check(c1, "kill aura", function() return Config.KillAura end, function(v) Config.KillAura = v end, "killaura")
	ui_check(c1, "respect gun cooldown", function() return Config.KillAuraCooldown end, function(v) Config.KillAuraCooldown = v end)
	ui_check(c1, "require ammo", function() return Config.KillAuraAmmo end, function(v) Config.KillAuraAmmo = v end)
	ui_check(c1, "wall check", function() return Config.KillAuraWall end, function(v) Config.KillAuraWall = v end)
	ui_check(c1, "face target", function() return Config.KillAuraFace end, function(v) Config.KillAuraFace = v end)
	ui_check(c1, "team check", function() return Config.KillAuraTeam end, function(v) Config.KillAuraTeam = v end)
	ui_check(c1, "skip friends", function() return Config.KillAuraFriends end, function(v) Config.KillAuraFriends = v end)
	ui_slider(c1, "range", 20, 500, function() return Config.KillAuraRange end,
		function(v) Config.KillAuraRange = math.floor(v + 0.5) end, "%d studs", 5)
	ui_slider(c1, "fire delay", 0.05, 0.50, function() return Config.KillAuraDelay end,
		function(v) Config.KillAuraDelay = v end, "%.2f s", 0.01)
	ui_slider(c1, "max shots / sec", 2, 20, function() return Config.KillAuraMaxCPS end,
		function(v) Config.KillAuraMaxCPS = math.floor(v + 0.5) end, "%d", 1)
	ui_slider(c1, "prediction", 0, 0.2, function() return Config.KillAuraPredict end,
		function(v) Config.KillAuraPredict = v end, "%.3f", 0.005)
	ui_note(c1, "cooldown is read from the gun, never zeroed — that is what bans people")

	local c2 = make_card("Rage", 2, "stomp")
	ui_check(c2, "auto stomp", function() return Config.StompAuto end, function(v) Config.StompAuto = v end, "autostomp")
	ui_check(c2, "stomp aura", function() return Config.StompAura end, function(v) Config.StompAura = v end, "stompaura")
	ui_dropdown(c2, "stomp key", { "Right Mouse Click", "None", "The Letter F", "The Letter G", "The Letter H", "The Letter J", "The Letter K", "The Letter L", "The Letter V", "The Letter X", "The Letter C", "The Letter B" },
		function() return Config.StompKey end, function(v) Config.StompKey = v end)
	ui_slider(c2, "range", 20, 500, function() return Config.StompRange end,
		function(v) Config.StompRange = math.floor(v + 0.5) end, "%d studs", 5)
	ui_slider(c2, "stomp rate", 0.10, 1.00, function() return Config.StompRate end,
		function(v) Config.StompRate = v end, "%.2f s", 0.05)
	ui_slider(c2, "max distance", 8, 120, function() return Config.StompMaxDistance end,
		function(v) Config.StompMaxDistance = math.floor(v + 0.5) end, "%d studs", 2)
	ui_slider(c2, "height offset", 0, 6, function() return Config.StompOffset end,
		function(v) Config.StompOffset = v end, "%.1f", 0.5)
	ui_note(c2, "max distance is teleport range — 20 is melee, 100+ is how people eat bans")

	local c3 = make_card("Rage", 1, "defense")
	ui_check(c3, "anti stomp", function() return Config.AntiStomp end, function(v) Config.AntiStomp = v end, "antistomp")
	ui_check(c3, "blank rig on ko", function() return Config.AntiStompParts end, function(v) Config.AntiStompParts = v end)
	ui_check(c3, "flashback", function() return Config.Flashback end, function(v) Config.Flashback = v end)
	ui_check(c3, "anti void", function() return Config.AntiVoid end, function(v) Config.AntiVoid = v end)
	ui_check(c3, "auto reload", function() return Config.AutoReload end, function(v) Config.AutoReload = v end)
	ui_note(c3, "anti stomp kills you the moment you are K.O — they lose the stomp")

	local c4 = make_card("Rage", 2, "bypass")
	ui_dropdown(c4, "shot format", { "Auto", "ShootGun", "Shoot" },
		function() return Config.ShotFormat end, function(v) Config.ShotFormat = v end)
	ui_slider(c4, "suspend on ac block", 0, 60, function() return Config.AcSuspend end,
		function(v)
			Config.AcSuspend = math.floor(v + 0.5)
			_G.AC_SUSPEND = Config.AcSuspend
		end, "%d s", 5)
	ui_check(c4, "block patterns", function() return _G.AC and _G.AC.aggressive end,
		function(v) Config.AcAggressive = v if _G.AC then _G.AC.aggressive = v end end)
	ui_check(c4, "trace remotes", function() return _G.AC and _G.AC.tracing end,
		function(v)
			Config.AcTrace = v
			if _G.AC and _G.AC.trace_all then
				_G.AC.trace_all(v)
				if v then notify("AC", "tracing every FireServer action") end
			end
		end)
	ui_button(c4, "ac report", function()
		if _G.AC and _G.AC.report then _G.AC.report() end
		if _G.AC and _G.AC.trace then _G.AC.trace() end
	end)
	ui_button(c4, "reset rage counters", function()
		if rage_stats then
			rage_stats.shots, rage_stats.stomps, rage_stats.denied = 0, 0, 0
		end
	end)
	rage_status_label = ui_note(c4, "status: idle")
	_G.RAGE_STATUS = rage_status_label
end

finish_page("Combat")
finish_page("Visuals")
finish_page("Players")
finish_page("Rage")
finish_page("Utility")
finish_page("Settings")

add_nav_group("main")
add_nav_item("Combat", "combat")
add_nav_item("Visuals", "visuals")
add_nav_item("Players", "players")
add_nav_item("Rage", "rage")
add_nav_group("misc")
add_nav_item("Utility", "utility")
add_nav_item("Settings", "settings")

-- ============================================================================
--  OVERLAYS  (fov · target info · hit marker · damage numbers)
-- ============================================================================

OverlayFolder = Instance.new("Folder")
OverlayFolder.Name = "SmertLock_Overlay"
OverlayFolder.Parent = SCREEN_GUI

FOVFrame = Instance.new("Frame")
FOVFrame.Name = "FOV"
FOVFrame.AnchorPoint = Vector2.new(0.5, 0.5)
FOVFrame.BackgroundTransparency = 1
FOVFrame.BackgroundColor3 = T.Accent
FOVFrame.BorderSizePixel = 0
FOVFrame.ZIndex = 5
FOVFrame.Parent = OverlayFolder
corner(FOVFrame, 999)
reg(FOVFrame, "bg", "Accent")

FOVStroke = stroke(FOVFrame, "Accent")
FOVStroke.Thickness = Config.FOVThickness

TargetInfo = Instance.new("Frame")
TargetInfo.Size = UDim2.new(0, 224, 0, 112)
TargetInfo.Position = UDim2.new(1, -240, 0, 74)
TargetInfo.BackgroundColor3 = T.Panel
TargetInfo.BackgroundTransparency = 0.08
TargetInfo.BorderSizePixel = 0
TargetInfo.Visible = false
TargetInfo.ZIndex = 6
TargetInfo.Parent = OverlayFolder
corner(TargetInfo, 9)
stroke(TargetInfo, "Stroke")
reg(TargetInfo, "bg", "Panel")

local TargetAccent = Instance.new("Frame")
TargetAccent.Size = UDim2.new(0, 2, 1, -16)
TargetAccent.Position = UDim2.new(0, 0, 0, 8)
TargetAccent.BackgroundColor3 = T.Accent
TargetAccent.BorderSizePixel = 0
TargetAccent.Parent = TargetInfo
corner(TargetAccent, 1)
reg(TargetAccent, "bg", "Accent")

TargetName     = label(TargetInfo, "no target", UDim2.new(1, -22, 0, 22), UDim2.new(0, 14, 0, 8), 13, "Text", Enum.Font.GothamBold)
TargetState    = label(TargetInfo, "state: —", UDim2.new(1, -22, 0, 16), UDim2.new(0, 14, 0, 33), 11, "Muted")
TargetHealth   = label(TargetInfo, "hp: —", UDim2.new(1, -22, 0, 16), UDim2.new(0, 14, 0, 51), 11, "Muted")
TargetDistance = label(TargetInfo, "distance: —", UDim2.new(1, -22, 0, 16), UDim2.new(0, 14, 0, 69), 11, "Muted")
TargetWeapon   = label(TargetInfo, "weapon: —", UDim2.new(1, -22, 0, 16), UDim2.new(0, 14, 0, 87), 11, "Muted")

-- hit marker: four diagonal ticks around the crosshair
HitMarker = Instance.new("Frame")
HitMarker.Size = UDim2.new(0, 26, 0, 26)
HitMarker.AnchorPoint = Vector2.new(0.5, 0.5)
HitMarker.BackgroundTransparency = 1
HitMarker.Visible = false
HitMarker.ZIndex = 20
HitMarker.Parent = OverlayFolder

local hit_ticks = {}
for i = 1, 4 do
	local tick = Instance.new("Frame")
	tick.Size = UDim2.new(0, 8, 0, 2)
	tick.AnchorPoint = Vector2.new(0.5, 0.5)
	tick.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	tick.BorderSizePixel = 0
	tick.Parent = HitMarker
	corner(tick, 1)
	local angle = (i - 1) * 90 + 45
	local rad = math.rad(angle)
	tick.Rotation = angle
	tick.Position = UDim2.new(0.5, math.cos(rad) * 8, 0.5, math.sin(rad) * 8)
	hit_ticks[i] = tick
end

DamageLayer = Instance.new("Folder")
DamageLayer.Name = "SmertLock_Damage"
DamageLayer.Parent = SCREEN_GUI

-- ============================================================================
--  ESP ENGINE
-- ============================================================================

ESPFolder = Instance.new("Folder")
ESPFolder.Name = "SmertLock_ESP"
ESPFolder.Parent = ESP_SCREEN_GUI

local R15_BONES = {
	{ "Head", "UpperTorso" },
	{ "UpperTorso", "LowerTorso" },
	{ "LowerTorso", "HumanoidRootPart" },
	{ "UpperTorso", "LeftUpperArm" },
	{ "LeftUpperArm", "LeftLowerArm" },
	{ "LeftLowerArm", "LeftHand" },
	{ "UpperTorso", "RightUpperArm" },
	{ "RightUpperArm", "RightLowerArm" },
	{ "RightLowerArm", "RightHand" },
	{ "LowerTorso", "LeftUpperLeg" },
	{ "LeftUpperLeg", "LeftLowerLeg" },
	{ "LeftLowerLeg", "LeftFoot" },
	{ "LowerTorso", "RightUpperLeg" },
	{ "RightUpperLeg", "RightLowerLeg" },
	{ "RightLowerLeg", "RightFoot" },
}

local R6_BONES = {
	{ "Head", "Torso" },
	{ "Torso", "HumanoidRootPart" },
	{ "Torso", "Left Arm" },
	{ "Torso", "Right Arm" },
	{ "Torso", "Left Leg" },
	{ "Torso", "Right Leg" },
}

local function new_frame(parent, z)
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundTransparency = 0
	f.Visible = false
	f.ZIndex = z or 2
	f.Parent = parent
	return f
end

local function new_text(parent, size, z)
	local l = Instance.new("TextLabel")
	l.Size = size
	l.BackgroundTransparency = 1
	l.TextColor3 = T.Text
	l.TextStrokeTransparency = 0.3
	l.Font = Enum.Font.GothamBold
	l.TextSize = 11
	l.TextXAlignment = Enum.TextXAlignment.Center
	l.Visible = false
	l.ZIndex = z or 8
	l.Parent = parent
	return l
end

-- one draw path for tracer and skeleton alike. Roblox rotates a GuiObject around its
-- centre, so the frame is placed on the segment midpoint; anchoring the left edge
-- while rotating is what makes a tracer drift off the target.
local function draw_line(frame, from_pos, to_pos, thickness)
	local delta = to_pos - from_pos
	local length = delta.Magnitude
	if length ~= length or length == math.huge or length < 1 then
		frame.Visible = false
		return
	end
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromOffset((from_pos.X + to_pos.X) * 0.5, (from_pos.Y + to_pos.Y) * 0.5)
	frame.Size = UDim2.fromOffset(length, math.max(1, thickness))
	frame.Rotation = math.deg(math.atan2(delta.Y, delta.X))
	frame.Visible = true
end

local function hide_esp(rec)
	rec.box_top.Visible = false
	rec.box_bottom.Visible = false
	rec.box_left.Visible = false
	rec.box_right.Visible = false
	rec.fill.Visible = false
	rec.tracer.Visible = false
	rec.name.Visible = false
	rec.info.Visible = false
	rec.hp_bg.Visible = false
	rec.hp_fill.Visible = false
	rec.dot.Visible = false
	for _, line in ipairs(rec.lines) do
		line.Visible = false
	end
	if rec.highlight then
		rec.highlight.Enabled = false
	end
end

local function destroy_esp(rec)
	if rec.conn then
		rec.conn:Disconnect()
		rec.conn = nil
	end
	if rec.highlight then
		rec.highlight:Destroy()
		rec.highlight = nil
	end
	if rec.root then
		rec.root:Destroy()
		rec.root = nil
	end
	esps[rec.user_id] = nil
end

local function ensure_line(rec, index)
	local line = rec.lines[index]
	if not line then
		line = new_frame(rec.root, 2)
		rec.lines[index] = line
	end
	return line
end

local function apply_highlight(rec, char, color)
	if not Config.ESPChams or not char then
		if rec.highlight then rec.highlight.Enabled = false end
		return
	end
	if not rec.highlight or rec.highlight.Parent ~= char then
		if rec.highlight then rec.highlight:Destroy() end
		rec.highlight = Instance.new("Highlight")
		rec.highlight.Name = "SmertLock_Chams"
		rec.highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		rec.highlight.Parent = char
	end
	rec.highlight.Enabled = true
	rec.highlight.FillColor = color
	rec.highlight.OutlineColor = color
	rec.highlight.FillTransparency = Config.ESPChamsTransparency
	rec.highlight.OutlineTransparency = math.clamp(Config.ESPChamsOutlineTransparency, 0, 1)
end

local function create_esp(player)
	local root = Instance.new("Folder")
	root.Name = "SL_" .. tostring(player.UserId)
	root.Parent = ESPFolder

	local rec = {
		user_id = player.UserId,
		player = player,
		root = root,
		lines = {},
		rig = nil,
		rig_char = nil,
		rig_clock = 0,
		parts = {},
		last_hp = nil,
	}

	rec.box_top    = new_frame(root, 3)
	rec.box_bottom = new_frame(root, 3)
	rec.box_left   = new_frame(root, 3)
	rec.box_right  = new_frame(root, 3)
	rec.fill       = new_frame(root, 1)
	rec.tracer     = new_frame(root, 4)
	rec.hp_bg      = new_frame(root, 1)
	rec.hp_fill    = new_frame(root, 2)
	rec.name       = new_text(root, UDim2.fromOffset(220, 16), 8)
	rec.info       = new_text(root, UDim2.fromOffset(260, 16), 8)

	rec.dot = Instance.new("Frame")
	rec.dot.AnchorPoint = Vector2.new(0.5, 0.5)
	rec.dot.Size = UDim2.fromOffset(6, 6)
	rec.dot.BackgroundColor3 = T.Accent
	rec.dot.BorderSizePixel = 0
	rec.dot.Visible = false
	rec.dot.ZIndex = 4
	rec.dot.Parent = root
	corner(rec.dot, 999)

	rec.conn = player.CharacterAdded:Connect(function()
		task.wait(0.15)
		rec.rig_char = nil
		rec.rig_clock = 0
		if Config.ESPChams then
			apply_highlight(rec, player.Character, T.Accent)
		end
	end)

	esps[player.UserId] = rec
	return rec
end

local function skeleton_parts(rec, char)
	return rig_parts(rec, char)
end

local function update_esp(rec)
	local player = rec.player
	local char = player.Character

	if not Config.ESPEnabled or not char then
		hide_esp(rec)
		return
	end
	if Config.ESPSelectedOnly and not Config.SelectedPlayers[player.UserId] then
		hide_esp(rec)
		return
	end

	local state, _, humanoid, root_part = get_character_state(player)
	if not root_part then
		hide_esp(rec)
		return
	end

	local my_root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
	local distance = my_root and (my_root.Position - root_part.Position).Magnitude or 0
	if distance > Config.ESPMaxDistance then
		hide_esp(rec)
		return
	end

	local bounds = char_bounds(rec, char)
	if not bounds then
		hide_esp(rec)
		return
	end

	local color = esp_color(player, state, humanoid)
	local x, y, w, h = bounds.x, bounds.y, bounds.w, bounds.h
	local viewport = Camera.ViewportSize
	local thickness = math.max(1, math.floor(Config.ESPBoxThickness + 0.5))

	apply_highlight(rec, char, color)

	-- box ------------------------------------------------------------------
	if Config.ESPBox then
		rec.box_top.Visible = true
		rec.box_bottom.Visible = true
		rec.box_left.Visible = true
		rec.box_right.Visible = true
		for _, piece in ipairs({ rec.box_top, rec.box_bottom, rec.box_left, rec.box_right }) do
			piece.BackgroundColor3 = color
		end
		rec.box_top.Position = UDim2.fromOffset(x, y)
		rec.box_top.Size = UDim2.fromOffset(w, thickness)
		rec.box_bottom.Position = UDim2.fromOffset(x, y + h - thickness)
		rec.box_bottom.Size = UDim2.fromOffset(w, thickness)
		rec.box_left.Position = UDim2.fromOffset(x, y)
		rec.box_left.Size = UDim2.fromOffset(thickness, h)
		rec.box_right.Position = UDim2.fromOffset(x + w - thickness, y)
		rec.box_right.Size = UDim2.fromOffset(thickness, h)
	else
		rec.box_top.Visible = false
		rec.box_bottom.Visible = false
		rec.box_left.Visible = false
		rec.box_right.Visible = false
	end

	if Config.ESPBoxFilled then
		rec.fill.Visible = true
		rec.fill.Position = UDim2.fromOffset(x, y)
		rec.fill.Size = UDim2.fromOffset(w, h)
		rec.fill.BackgroundColor3 = color
		rec.fill.BackgroundTransparency = Config.ESPFillTransparency
	else
		rec.fill.Visible = false
	end

	-- tracer ---------------------------------------------------------------
	if Config.ESPTracer then
		local origin
		local mode = Config.ESPTracerOrigin
		if mode == "Crosshair" then
			origin = Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
		elseif mode == "Top" then
			origin = Vector2.new(viewport.X * 0.5, 0)
		elseif mode == "Mouse" then
			origin = mouse_pos()
		else
			origin = Vector2.new(viewport.X * 0.5, viewport.Y)
		end
		origin = Vector2.new(
			math.clamp(origin.X, 0, viewport.X),
			math.clamp(origin.Y, 0, viewport.Y)
		)

		local finish
		if Config.ESPTracerEnd == "Head" then
			local _, parts = rig_parts(rec, char)
			finish = project(parts.Head) or Vector2.new(x + w * 0.5, y)
		else
			finish = Vector2.new(x + w * 0.5, y + h)
		end

		local tracer_mode = Config.ESPTracerColorMode
		local tracer_color = color
		if Config.ESPTracerRainbow or tracer_mode == "Rainbow" then
			tracer_color = Color3.fromHSV((os.clock() * 0.25) % 1, 0.85, 1)
		elseif tracer_mode ~= "Match ESP" then
			tracer_color = PALETTE[tracer_mode] or color
		end
		rec.tracer.BackgroundColor3 = tracer_color
		rec.tracer.BackgroundTransparency = math.clamp(Config.ESPTracerTransparency, 0, 0.95)
		draw_line(rec.tracer, origin, finish, math.max(1, math.floor(Config.ESPTracerThickness + 0.5)))
	else
		rec.tracer.Visible = false
	end

	-- skeleton -------------------------------------------------------------
	for _, line in ipairs(rec.lines) do
		line.Visible = false
	end

	if Config.ESPSkeleton then
		local rig, parts = skeleton_parts(rec, char)
		local bones = (rig == "R15") and R15_BONES or R6_BONES
		local index = 0
		for _, bone in ipairs(bones) do
			local a = project(parts[bone[1]])
			local b = project(parts[bone[2]])
			if a and b then
				index += 1
				local line = ensure_line(rec, index)
				line.BackgroundColor3 = color
				line.BackgroundTransparency = 0.1
				line.ZIndex = 2
				draw_line(line, a, b, math.max(1, math.floor(Config.ESPSkeletonThickness + 0.5)))
			end
		end
	end

	-- head dot -------------------------------------------------------------
	if Config.ESPHeadDot then
		local _, parts = rig_parts(rec, char)
		local head = project(parts.Head)
		if head then
			local dot_size = math.clamp(16 - distance / 120, 3, 8)
			rec.dot.Visible = true
			rec.dot.Position = UDim2.fromOffset(head.X, head.Y)
			rec.dot.Size = UDim2.fromOffset(dot_size, dot_size)
			rec.dot.BackgroundColor3 = color
		else
			rec.dot.Visible = false
		end
	else
		rec.dot.Visible = false
	end

	-- name -----------------------------------------------------------------
	if Config.ESPName then
		rec.name.Visible = true
		rec.name.Text = player.DisplayName
		rec.name.TextColor3 = color
		rec.name.Position = UDim2.fromOffset(x + w * 0.5 - 110, y - 18)
	else
		rec.name.Visible = false
	end

	-- info -----------------------------------------------------------------
	local parts = {}
	if Config.ESPHealth and humanoid then
		table.insert(parts, string.format("hp %d", math.max(0, math.floor(humanoid.Health))))
	end
	if Config.ESPDistance then
		table.insert(parts, string.format("%d studs", math.floor(distance)))
	end
	if Config.ESPWeapon then
		table.insert(parts, get_weapon_name(player))
	end
	if Config.ESPShowKO and state == "KO" then
		table.insert(parts, "ko")
	end
	if #parts > 0 then
		rec.info.Visible = true
		rec.info.Text = table.concat(parts, "  ·  ")
		rec.info.TextColor3 = color
		rec.info.Position = UDim2.fromOffset(x + w * 0.5 - 130, y + h + 2)
	else
		rec.info.Visible = false
	end

	-- health bar -----------------------------------------------------------
	if Config.ESPHealthBar and humanoid and humanoid.MaxHealth > 0 then
		local ratio = math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
		rec.hp_bg.Visible = true
		rec.hp_fill.Visible = true
		rec.hp_bg.BackgroundColor3 = Color3.fromRGB(18, 18, 20)
		rec.hp_bg.BackgroundTransparency = 0.2
		rec.hp_bg.Position = UDim2.fromOffset(x - 6, y)
		rec.hp_bg.Size = UDim2.fromOffset(3, h)
		rec.hp_fill.BackgroundColor3 = Color3.fromRGB(math.floor(255 * (1 - ratio)), math.floor(255 * ratio), 70)
		rec.hp_fill.Position = UDim2.fromOffset(x - 6, y + h * (1 - ratio))
		rec.hp_fill.Size = UDim2.fromOffset(3, h * ratio)
	else
		rec.hp_bg.Visible = false
		rec.hp_fill.Visible = false
	end
end

refreshESPList = function()
	local seen = {}
	local wanted = Config.ESPEnabled or Config.HitMarker or Config.DamageNumbers
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			seen[player.UserId] = true
			if not esps[player.UserId] and wanted then
				create_esp(player)
			end
		end
	end
	for user_id, rec in pairs(esps) do
		if not seen[user_id] then
			destroy_esp(rec)
		end
	end
end

-- ============================================================================
--  TARGETING
-- ============================================================================

local function find_target()
	local target, best = nil, math.huge
	local mouse = mouse_pos()
	local my_root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
	local pool = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if Config.ESPSelectedOnly or next(Config.SelectedPlayers) ~= nil then
			if Config.SelectedPlayers[player.UserId] then
				table.insert(pool, player)
			end
		else
			table.insert(pool, player)
		end
	end

	for _, player in ipairs(pool) do
		if is_valid_target(player) then
			local char = player.Character
			local part = get_target_part(char)
			local screen = part and project(part)
			if screen then
				local metric
				if Config.TargetPriority == "World Distance" and my_root then
					local proot = char:FindFirstChild("HumanoidRootPart")
					metric = proot and (my_root.Position - proot.Position).Magnitude or math.huge
				else
					metric = (screen - mouse).Magnitude
				end
				if Config.TargetPriority == "Mouse Distance" and Config.FOVEnabled and metric > Config.FOVRadius then
					continue
				end
				if metric < best then
					best = metric
					target = player
				end
			end
		end
	end
	return target
end

local function clear_invalid_target()
	if Config.Target and not is_valid_target(Config.Target) then
		Config.Target = nil
	end
end

-- ============================================================================
--  HIT MARKER / DAMAGE NUMBERS
-- ============================================================================

local function flash_hitmarker()
	if not Config.HitMarker then return end
	hitmarkerUntil = os.clock() + 0.22
	HitMarker.Visible = true
	for _, tick in ipairs(hit_ticks) do
		tick.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		tick.BackgroundTransparency = 0
		tick.Size = UDim2.new(0, 8, 0, 2)
	end
	HitMarker.Size = UDim2.fromOffset(26, 26)
	HitMarker.Position = UDim2.fromOffset(Camera.ViewportSize.X * 0.5, Camera.ViewportSize.Y * 0.5)
end

local function spawn_damage_number(amount, part)
	if not Config.DamageNumbers or not part then return end
	local screen = project(part)
	if not screen then return end
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Size = UDim2.fromOffset(90, 20)
	text.Position = UDim2.fromOffset(screen.X - 45, screen.Y - 10)
	text.Text = "-" .. tostring(math.floor(amount + 0.5))
	text.TextColor3 = Color3.fromRGB(255, 232, 120)
	text.TextStrokeTransparency = 0.4
	text.Font = Enum.Font.GothamBold
	text.TextSize = 15
	text.ZIndex = 30
	text.Parent = DamageLayer
	table.insert(damage_numbers, { label = text, born = os.clock(), x = screen.X, y = screen.Y })
end

local function update_damage_numbers()
	for i = #damage_numbers, 1, -1 do
		local entry = damage_numbers[i]
		local age = os.clock() - entry.born
		if age > 0.8 then
			entry.label:Destroy()
			table.remove(damage_numbers, i)
		else
			entry.label.Position = UDim2.fromOffset(entry.x - 45, entry.y - 10 - age * 34)
			entry.label.TextTransparency = math.clamp(age / 0.8, 0, 1)
			entry.label.TextStrokeTransparency = math.clamp(0.4 + age / 0.8, 0, 1)
		end
	end
end

local function watch_target_health()
	if not Config.Target or not Config.Target.Character then return end
	local humanoid = Config.Target.Character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	local rec = esps[Config.Target.UserId]
	if not rec then return end
	if rec.last_hp then
		local delta = rec.last_hp - humanoid.Health
		if delta > 0.5 and Config.IsHolding then
			flash_hitmarker()
			spawn_damage_number(delta, Config.Target.Character:FindFirstChild("Head") or Config.Target.Character:FindFirstChild("HumanoidRootPart"))
		end
	end
	rec.last_hp = humanoid.Health
end

-- ============================================================================
--  MOVEMENT
-- ============================================================================

local function fly_objects()
	local char = LocalPlayer.Character
	if char ~= cachedCharacter then
		cachedCharacter = char
		cachedHumanoid = char and char:FindFirstChildOfClass("Humanoid") or nil
		cachedRoot = char and char:FindFirstChild("HumanoidRootPart") or nil
	end
	return cachedCharacter, cachedHumanoid, cachedRoot
end

stopFly = function()
	if FlyVelocity then FlyVelocity:Destroy() FlyVelocity = nil end
	if FlyGyro then FlyGyro:Destroy() FlyGyro = nil end
	local _, humanoid = fly_objects()
	if humanoid then humanoid.PlatformStand = false end
end

local function start_fly(root, humanoid)
	if FlyVelocity and FlyVelocity.Parent == root then return end
	stopFly()
	FlyVelocity = Instance.new("BodyVelocity")
	FlyVelocity.Name = "SmertLock_Fly"
	FlyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
	FlyVelocity.P = 9000
	FlyVelocity.Velocity = Vector3.zero
	FlyVelocity.Parent = root

	FlyGyro = Instance.new("BodyGyro")
	FlyGyro.Name = "SmertLock_Gyro"
	FlyGyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
	FlyGyro.P = 9000
	FlyGyro.CFrame = Camera.CFrame
	FlyGyro.Parent = root

	humanoid.PlatformStand = true
end

local function update_movement()
	local char, humanoid, root = fly_objects()
	if not char or not humanoid or not root then
		if FlyVelocity or FlyGyro then stopFly() end
		return
	end
	if not Config.FlyEnabled then
		if FlyVelocity or FlyGyro then stopFly() end
		return
	end

	start_fly(root, humanoid)

	local cam = Camera.CFrame
	local forward = cam.LookVector
	local right = cam.RightVector
	local direction = Vector3.zero

	if UserInputService:IsKeyDown(Enum.KeyCode.W) then direction += forward end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then direction -= forward end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then direction += right end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then direction -= right end

	direction = Vector3.new(direction.X, 0, direction.Z)
	if direction.Magnitude > 0 then
		direction = direction.Unit * Config.FlySpeed
	end

	local vertical = 0
	if UserInputService:IsKeyDown(Enum.KeyCode.Space) then vertical += Config.FlyVerticalSpeed end
	if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then vertical -= Config.FlyVerticalSpeed end

	FlyVelocity.Velocity = Vector3.new(direction.X, vertical, direction.Z)
	FlyGyro.CFrame = CFrame.lookAt(root.Position, root.Position + cam.LookVector)
end

-- ============================================================================
--  TRIGGERBOT
-- ============================================================================

local EXCLUDE = safeCall(function() return Enum.RaycastFilterType.Exclude end)
	or Enum.RaycastFilterType.Blacklist

local function trigger_target()
	local mouse = mouse_pos()
	local ray = Camera:ViewportPointToRay(mouse.X, mouse.Y)
	local params = RaycastParams.new()
	params.FilterType = EXCLUDE
	params.FilterDescendantsInstances = { LocalPlayer.Character }

	local result = Workspace:Raycast(ray.Origin, ray.Direction * Config.TriggerbotMaxDistance, params)
	if not result or not result.Instance then return nil end
	local model = result.Instance:FindFirstAncestorOfClass("Model")
	if not model then return nil end
	local player = Players:GetPlayerFromCharacter(model)
	if not player or not is_valid_target(player) then return nil end

	local my_root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
	local their_root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if my_root and their_root and (my_root.Position - their_root.Position).Magnitude > Config.TriggerbotMaxDistance then
		return nil
	end
	return player
end

-- one fire path for the triggerbot and rapid fire alike. A synthetic click mirrors the
-- real input route; Tool:Activate() fires Tool.Activated directly, which is what the
-- gun's own LocalScript listens on. Both are attempted so neither route can silently
-- dead-end on a given tool.
local function fire_weapon()
	local fired = false
	if typeof(mouse1click) == "function" then
		fired = pcall(mouse1click) or fired
	end
	local tool = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Tool")
	if tool then
		fired = pcall(function() tool:Activate() end) or fired
	end
	return fired
end

local function fire_trigger()
	local now = os.clock()
	if now - lastTrigger < Config.TriggerbotDelay then return end
	if fire_weapon() then lastTrigger = now end
end

-- ============================================================================
--  PLAYER LIST
-- ============================================================================

updatePlayerList = function()
	if not player_rows_holder then return end
	for _, child in ipairs(player_rows_holder:GetChildren()) do
		if child:IsA("TextButton") then child:Destroy() end
	end

	local query = player_search and player_search.Text:lower() or ""
	local my_root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
	local rows = {}

	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			local state, _, humanoid, root = get_character_state(player)
			local distance = 0
			if my_root and root then
				distance = (my_root.Position - root.Position).Magnitude
			end
			table.insert(rows, {
				player = player,
				state = state,
				hp = humanoid and math.max(0, math.floor(humanoid.Health)) or 0,
				distance = distance,
			})
		end
	end

	local sort = player_sort or "Distance"
	table.sort(rows, function(a, b)
		if sort == "Name" then
			return a.player.DisplayName:lower() < b.player.DisplayName:lower()
		elseif sort == "Health" then
			return a.hp < b.hp
		end
		return a.distance < b.distance
	end)

	local order = 0
	for _, row in ipairs(rows) do
		local player = row.player
		local name = player.DisplayName:lower()
		if query == "" or name:find(query, 1, true) or player.Name:lower():find(query, 1, true) then
			order += 1
			local selected = Config.SelectedPlayers[player.UserId] == true
			local button = Instance.new("TextButton")
			button.Size = UDim2.new(1, -6, 0, 30)
			button.BackgroundColor3 = selected and T.Panel3 or T.Panel2
			button.Text = ""
			button.AutoButtonColor = false
			button.LayoutOrder = order
			button.Parent = player_rows_holder
			corner(button, 6)
			stroke(button, "Stroke")
			if selected then reg(button, "bg", "Panel3") end

			local dot = Instance.new("Frame")
			dot.Size = UDim2.fromOffset(6, 6)
			dot.Position = UDim2.new(0, 10, 0.5, -3)
			dot.BackgroundColor3 = (row.state == "Alive") and Color3.fromRGB(90, 220, 130)
				or (row.state == "KO") and Color3.fromRGB(255, 175, 45)
				or Color3.fromRGB(120, 120, 130)
			dot.BorderSizePixel = 0
			dot.Parent = button
			corner(dot, 3)

			label(button, player.DisplayName, UDim2.new(0.5, -20, 1, 0), UDim2.new(0, 24, 0, 0), 12, selected and "Text" or "Muted").TextYAlignment = Enum.TextYAlignment.Center
			local right = label(button, string.format("%s · %d hp · %d m", row.state, row.hp, math.floor(row.distance)),
				UDim2.new(0.5, -10, 1, 0), UDim2.new(0.5, 0, 0, 0), 11, "Muted")
			right.TextXAlignment = Enum.TextXAlignment.Right
			right.TextYAlignment = Enum.TextYAlignment.Center

			button.MouseEnter:Connect(function() button.BackgroundColor3 = T.Hover end)
			button.MouseLeave:Connect(function()
				button.BackgroundColor3 = Config.SelectedPlayers[player.UserId] and T.Panel3 or T.Panel2
			end)
			button.MouseButton1Click:Connect(function()
				if Config.SelectedPlayers[player.UserId] then
					Config.SelectedPlayers[player.UserId] = nil
				else
					Config.SelectedPlayers[player.UserId] = true
				end
				updatePlayerList()
			end)
		end
	end
end

-- ============================================================================
--  CONFIG FILES
-- ============================================================================

local function profile_file()
	return "SmertLock_v2_" .. string.lower(Config.ProfileName or "default") .. ".json"
end

local function collect_config()
	local data = {}
	for key, value in pairs(Config) do
		local kind = typeof(value)
		-- JSONEncode chokes on Color3 / Instance / function — primitives only
		if (kind == "number" or kind == "string" or kind == "boolean")
			and key ~= "Target" and key ~= "IsHolding" then
			data[key] = value
		end
	end
	data.Binds = {}
	for id, key in pairs(Config.Binds) do
		data.Binds[id] = key
	end
	return data
end

local function save_config()
	return safeCall(function()
		if not writefile then error("no writefile") end
		writefile(profile_file(), HttpService:JSONEncode(collect_config()))
		return true
	end)
end

local function load_config()
	return safeCall(function()
		if not readfile then error("no readfile") end
		local raw = readfile(profile_file())
		if not raw then error("empty") end
		local data = HttpService:JSONDecode(raw)
		for key, value in pairs(data) do
			if key == "Binds" and type(value) == "table" then
				for id, bind in pairs(value) do
					Config.Binds[id] = bind
				end
			elseif Config[key] ~= nil and type(Config[key]) == type(value) then
				Config[key] = value
			end
		end
		T = THEMES[Config.UITheme] or THEMES.Void
		Scale.Scale = Config.UIScale
		applyTheme()
		for _, refresh in ipairs(refreshables) do safeCall(refresh) end
		updatePlayerList()
		return true
	end)
end

-- ============================================================================
--  THEME APPLICATION
-- ============================================================================

applyTheme = function()
	for _, entry in ipairs(registry) do
		local value = T[entry.slot]
		if value then
			if entry.kind == "bg" then
				entry.obj.BackgroundColor3 = value
			elseif entry.kind == "text" then
				entry.obj.TextColor3 = value
			elseif entry.kind == "stroke" then
				entry.obj.Color = value
			end
		end
	end
	MainFrame.BackgroundColor3 = T.Background
	FOVFrame.BackgroundColor3 = T.Accent
	FOVStroke.Color = T.Accent
	for _, page in pairs(pages) do
		page.ScrollBarImageColor3 = T.Accent
	end
	for _, refresh in ipairs(refreshables) do
		safeCall(refresh)
	end
	select_page(current_page_name or "Combat")
end

-- ============================================================================
--  PANIC
-- ============================================================================

-- one panic path: the keybind, the button, and any outside watcher (admin-detection
-- scripts call _G.SmertLock_panic()) all land here
panic_now = function()
	Config.Enabled = false
	Config.TriggerbotEnabled = false
	Config.RapidFireEnabled = false
	Config.KillAura = false
	Config.StompAuto = false
	Config.StompAura = false
	Config.Target = nil
	Config.IsHolding = false
	Config.Visible = false
	MainFrame.Visible = false
	for _, refresh in ipairs(refreshables) do safeCall(refresh) end
	-- keep the rage side quiet until you turn it back on
	if typeof(_G.RAGE_SUSPEND) == "function" then safeCall(_G.RAGE_SUSPEND, 9999) end
	if notify then notify("Panic", "combat off, menu hidden") end
	return true
end

_G.SmertLock_panic = panic_now

-- ============================================================================
--  DRAG / WINDOW
-- ============================================================================

local Header = Instance.new("Frame")
Header.Size = UDim2.new(1, 0, 0, 52)
Header.BackgroundTransparency = 1
Header.Active = true
Header.Parent = MainFrame

Header.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPos = MainFrame.Position
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local delta = input.Position - dragStart
		MainFrame.Position = UDim2.new(
			startPos.X.Scale, startPos.X.Offset + delta.X,
			startPos.Y.Scale, startPos.Y.Offset + delta.Y
		)
	end
	if sliding_slider and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local bar = sliding_slider.bar
		local mouse = mouse_pos()
		local width = math.max(1, bar.AbsoluteSize.X)
		local pct = math.clamp((mouse.X - bar.AbsolutePosition.X) / width, 0, 1)
		local raw = sliding_slider.min + (sliding_slider.max - sliding_slider.min) * pct
		sliding_slider.set(round(raw, sliding_slider.step or 0.001))
		safeCall(sliding_slider.refresh)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = false
		sliding_slider = nil
	end
end)

-- ============================================================================
--  INPUT
-- ============================================================================

UserInputService.InputBegan:Connect(function(input, processed)
	if capturing then
		if input.KeyCode == Enum.KeyCode.Escape then
			capturing = nil
			notify("Keybind", "cancelled")
			return
		elseif input.KeyCode == Enum.KeyCode.Backspace or input.KeyCode == Enum.KeyCode.Delete then
			Config.Binds[capturing.id] = "None"
		elseif input.KeyCode ~= Enum.KeyCode.Unknown then
			Config.Binds[capturing.id] = input.KeyCode.Name
		else
			return
		end
		safeCall(capturing.refresh)
		capturing = nil
		return
	end

	if processed then return end

	if input.KeyCode == get_menu_key() then
		Config.Visible = not Config.Visible
		MainFrame.Visible = Config.Visible
		Watermark.Visible = Config.Visible and Config.Watermark
		return
	end

	if input.KeyCode ~= Enum.KeyCode.Unknown then
		local key_name = input.KeyCode.Name
		for id, action in pairs(BIND_ACTIONS) do
			if Config.Binds[id] == key_name then
				action()
			end
		end
		if Config.Binds.panic ~= "None" and key_name == Config.Binds.panic then
			panic_now()
			return
		end
	end

	if Config.FlyBind ~= "None" and key_or_input_matches(Config.FlyBind, input) then
		Config.FlyEnabled = not Config.FlyEnabled
		if not Config.FlyEnabled then stopFly() end
		local refresh = BIND_ROWS.fly
		if refresh then safeCall(refresh) end
		return
	end

	if is_activating(input) then
		Config.Target = find_target()
		Config.IsHolding = true
		lastAcquire = os.clock()
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if is_activating(input) then
		Config.IsHolding = false
		Config.Target = nil
	end
end)

-- ============================================================================
--  ANTI-AFK
-- ============================================================================

LocalPlayer.Idled:Connect(function()
	if not Config.AntiAFK then return end
	safeCall(function()
		local vu = game:GetService("VirtualUser")
		vu:CaptureController()
		vu:ClickButton2(Vector2.new())
	end)
end)

-- ============================================================================
--  PLAYER EVENTS
-- ============================================================================

local function hook_player(player)
	if player == LocalPlayer then return end
	player.CharacterAdded:Connect(function()
		task.wait(0.2)
		local rec = esps[player.UserId]
		if rec then rec.rig_char = nil rec.last_hp = nil end
		updatePlayerList()
	end)
	player.CharacterRemoving:Connect(function()
		local rec = esps[player.UserId]
		if rec then
			rec.rig_char = nil
			rec.last_hp = nil
			if rec.highlight then rec.highlight:Destroy() rec.highlight = nil end
		end
	end)
end

Players.PlayerAdded:Connect(function(player)
	hook_player(player)
	updatePlayerList()
	refreshESPList()
end)

Players.PlayerRemoving:Connect(function(player)
	Config.SelectedPlayers[player.UserId] = nil
	local rec = esps[player.UserId]
	if rec then destroy_esp(rec) end
	updatePlayerList()
end)

for _, player in ipairs(Players:GetPlayers()) do
	hook_player(player)
end

LocalPlayer.CharacterAdded:Connect(function(char)
	cachedCharacter = char
	cachedHumanoid = char:WaitForChild("Humanoid", 5)
	cachedRoot = char:WaitForChild("HumanoidRootPart", 5)
	stopFly()
end)

-- ============================================================================
--  RAGE ENGINE  (kill aura / stomp / defenses — ported from the matcha combat side)
--
--  matcha fires ShootGun every frame with no checks at all. Every shot here passes a
--  gate first: alive, not K.O, gun equipped with a Handle, Ammo > 0, not reloading,
--  target alive and NOT knocked (you cannot shoot a downed player in this family),
--  no forcefield, in range, visible unless wall check is off. Then a minimum delay
--  AND a hard shots-per-second cap. The gun's own cooldown is read, never written.
-- ============================================================================

-- Scoped block: the ~25 locals below would otherwise sit on the chunk until the end
-- and blow the 200-local ceiling. Everything the main loop needs is exported to RAGE.
do

rage_stats = { shots = 0, stomps = 0, denied = 0 }

local RAGE_STOMP_BIND = "SmertLock_RageStomp"
local RAGE_EXCLUDE = safeCall(function() return Enum.RaycastFilterType.Exclude end)
	or Enum.RaycastFilterType.Blacklist

local Rage = {
	remote = nil,
	remote_name = nil,
	last_shot = 0,
	last_stomp = 0,
	last_reload = 0,
	shot_times = {},
	suspend_until = 0,
	suspend_reason = "",
	cooldown = {},
	friend_cache = {},
	flashback = nil,
	fall_height = nil,
	last_reason = "idle",
}

local last_ac_blocked = 0
local last_rage_status = 0

function _G.RAGE_SUSPEND(seconds)
	local value = tonumber(seconds) or Config.AcSuspend or 15
	Rage.suspend_until = math.max(Rage.suspend_until, os.clock() + value)
	Rage.suspend_reason = "ac block"
end

local function rage_suspended()
	return os.clock() < Rage.suspend_until
end

local function rage_remote()
	if Rage.remote and Rage.remote.Parent then return Rage.remote end

	local rs = game:GetService("ReplicatedStorage")
	local function as_remote(inst)
		if inst and (inst.ClassName == "RemoteEvent" or inst.ClassName == "RemoteFunction") then return inst end
		return nil
	end

	for _, name in ipairs({ "MainEvent", "MAINEVENT", "Remote", "Bullets" }) do
		local found = as_remote(rs:FindFirstChild(name))
		if found then
			Rage.remote, Rage.remote_name = found, found:GetFullName()
			return found
		end
	end

	local mainRemotes = rs:FindFirstChild("MainRemotes")
	local found = mainRemotes and as_remote(mainRemotes:FindFirstChild("MainRemoteEvent"))
	if found then
		Rage.remote, Rage.remote_name = found, found:GetFullName()
		return found
	end

	local packages = rs:FindFirstChild("Packages")
	local knit = packages and packages:FindFirstChild("Knit")
	local services = knit and knit:FindFirstChild("Services")
	local tool_service = services and services:FindFirstChild("ToolService")
	local re = tool_service and tool_service:FindFirstChild("RE")
	found = re and as_remote(re:FindFirstChild("UpdateAim"))
	if found then
		Rage.remote, Rage.remote_name = found, found:GetFullName()
		return found
	end

	return nil
end

local function rage_self()
	local char = LocalPlayer.Character
	if not char then return nil end
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	local body = char:FindFirstChild("BodyEffects")
	if not humanoid or not root then return nil end
	return char, humanoid, root, body
end

local function rage_flag(folder, name)
	if not folder then return nil end
	local value = folder:FindFirstChild(name)
	if value and value:IsA("BoolValue") then return value.Value end
	return nil
end

local function rage_ko(player)
	local char = player.Character
	if not char then return false end
	local body = char:FindFirstChild("BodyEffects")
	if body and (rage_flag(body, "K.O") or rage_flag(body, "KO")) then return true end
	if player ~= LocalPlayer and body then
		local grabbed = body:FindFirstChild("Grabbed")
		if grabbed and grabbed:IsA("ObjectValue") and grabbed.Value ~= nil then return true end
	end
	if char:FindFirstChild("GRABBING_CONSTRAINT") then return true end
	return false
end

local function rage_dead(player)
	local char = player.Character
	if not char then return true end
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return true end
	local body = char:FindFirstChild("BodyEffects")
	if body and rage_flag(body, "SDeath") then return true end
	return false
end

local function rage_friend(player)
	local cached = Rage.friend_cache[player.UserId]
	if cached and os.clock() - cached.at < 30 then return cached.value end
	local ok, value = pcall(function() return player:IsFriendsWith(LocalPlayer.UserId) end)
	value = ok and value == true
	Rage.friend_cache[player.UserId] = { at = os.clock(), value = value }
	return value
end

local function rage_gun()
	local char = LocalPlayer.Character
	if not char then return nil end
	local tool = char:FindFirstChildOfClass("Tool")
	if not tool or not tool:FindFirstChild("Handle") then return nil end
	return tool
end

local function rage_visible(part, char)
	local camera = Camera
	if not camera then return true end
	local params = RaycastParams.new()
	params.FilterType = RAGE_EXCLUDE
	params.FilterDescendantsInstances = { LocalPlayer.Character, char }
	local hit = Workspace:Raycast(camera.CFrame.Position, part.Position - camera.CFrame.Position, params)
	return hit == nil
end

-- reads the weapon's own fire delay. never writes to it — matcha's rapid fire zeroes
-- these upvalues, which is exactly the impossible state a server can flag.
local function rage_cooldown(tool)
	local cached = Rage.cooldown[tool]
	if cached and os.clock() - cached.at < 5 then return cached.value end

	local best
	for _, inst in ipairs(tool:GetDescendants()) do
		if inst:IsA("ValueBase") then
			local value = tonumber(inst.Value)
			local name = string.lower(inst.Name)
			if value and value > 0.01 and value < 2
				and (string.find(name, "cooldown") or string.find(name, "firerate") or string.find(name, "delay")) then
				if not best or value > best then best = value end
			end
		end
	end

	if not best and typeof(getconnections) == "function" and typeof(debug) == "table" and debug.getupvalue then
		safeCall(function()
			for _, conn in ipairs(getconnections(tool.Activated)) do
				local info = debug.getinfo(conn.Function)
				if info and info.nups then
					for i = 1, info.nups do
						local _, value = debug.getupvalue(conn.Function, i)
						if type(value) == "number" and value > 0.02 and value < 1.5 then
							if not best or value > best then best = value end
						end
					end
				end
			end
		end)
	end

	-- a bogus upvalue must never be able to kill the aura entirely
	if best then best = math.min(best, 0.35) end
	Rage.cooldown[tool] = { at = os.clock(), value = best }
	return best
end

local function rage_cps_ok()
	local list = Rage.shot_times
	local fresh = os.clock()
	while #list > 0 and fresh - list[1] > 1 do
		table.remove(list, 1)
	end
	return #list < Config.KillAuraMaxCPS
end

local function rage_fire(tool, part, aim)
	local remote = Rage.remote
	local handle = tool:FindFirstChild("Handle")
	if not remote or not handle then return false end

	local action = "ShootGun"
	if Config.ShotFormat == "Shoot" or (Config.ShotFormat == "Auto" and game.PlaceId == 9825515356) then
		action = "Shoot"
	end

	if action == "Shoot" then
		local function info()
			return { Instance = part, Normal = Vector3.new(0, 1, 0), Position = aim }
		end
		local function offset()
			return { thePart = part, theOffset = CFrame.new() }
		end
		return pcall(function()
			remote:FireServer("Shoot", { info(), info(), info(), info(), info() },
				{ offset(), offset(), offset(), offset(), offset() }, aim, aim, Workspace:GetServerTimeNow())
		end)
	end

	return pcall(function()
		remote:FireServer("ShootGun", handle, handle.Position, aim, part, Vector3.new(0, 0, 0))
	end)
end

local function rage_target(range, want_ko, wall_check)
	local _, _, root = rage_self()
	if not root then return nil end

	local best, best_part, best_dist
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			local skip = false
			if Config.KillAuraTeam and player.Team ~= nil and LocalPlayer.Team ~= nil
				and player.Team == LocalPlayer.Team then
				skip = true
			end
			if not skip and Config.KillAuraFriends and rage_friend(player) then skip = true end

			if not skip then
				local char = player.Character
				local humanoid = char and char:FindFirstChildOfClass("Humanoid")
				local proot = char and char:FindFirstChild("HumanoidRootPart")
				local head = char and char:FindFirstChild("Head")
				if humanoid and proot and head and humanoid.Health > 0
					and rage_ko(player) == want_ko and not rage_dead(player)
					and not char:FindFirstChild("ForceField") then
					local distance = (root.Position - proot.Position).Magnitude
					if distance <= range and (not best_dist or distance < best_dist) then
						local part = want_ko
							and (char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso") or proot)
							or head
						if part and (not wall_check or rage_visible(part, char)) then
							best, best_part, best_dist = player, part, distance
						end
					end
				end
			end
		end
	end
	return best, best_part, best_dist
end

local function rage_key_held(bind)
	local code = KEYMAP[bind]
	if typeof(code) ~= "EnumItem" then return false end
	if code.EnumType == Enum.UserInputType then
		return UserInputService:IsMouseButtonPressed(code)
	end
	return UserInputService:IsKeyDown(code)
end

local function rage_step_kill_aura()
	local char, humanoid, root, body = rage_self()
	if not char then return end
	if humanoid.Health <= 0 then Rage.last_reason = "dead" return end
	if rage_ko(LocalPlayer) then Rage.last_reason = "ko" return end
	if rage_flag(body, "Reload") then Rage.last_reason = "reloading" return end

	local tool = rage_gun()
	if not tool then Rage.last_reason = "no gun" return end

	if Config.KillAuraAmmo then
		local ammo = tool:FindFirstChild("Ammo")
		if ammo then
			local count = tonumber(ammo.Value)
			if count and count <= 0 then Rage.last_reason = "no ammo" return end
		end
	end

	local delay = Config.KillAuraDelay
	if Config.KillAuraCooldown then
		local cooldown = rage_cooldown(tool)
		if cooldown and cooldown > delay then delay = cooldown end
	end

	if os.clock() - Rage.last_shot < delay then return end
	if not rage_cps_ok() then Rage.last_reason = "cps cap" return end

	local target, part = rage_target(Config.KillAuraRange, false, Config.KillAuraWall)
	if not target or not part then Rage.last_reason = "no target" return end

	if Config.KillAuraFace then
		safeCall(function()
			root.CFrame = CFrame.lookAt(root.Position, Vector3.new(part.Position.X, root.Position.Y, part.Position.Z))
		end)
	end

	local aim = part.Position
	local velocity = part.AssemblyLinearVelocity
	if Config.KillAuraPredict > 0 and velocity then
		aim = aim + velocity * Config.KillAuraPredict
	end

	if rage_fire(tool, part, aim) then
		Rage.last_shot = os.clock()
		rage_stats.shots += 1
		table.insert(Rage.shot_times, os.clock())
		Rage.last_reason = "shooting " .. target.Name
	end
end

local function rage_do_stomp(root, torso)
	local saved = root.CFrame

	pcall(function()
		root.CFrame = CFrame.new(torso.Position + Vector3.new(0, Config.StompOffset, 0))
	end)

	local bound = pcall(function()
		RunService:BindToRenderStep(RAGE_STOMP_BIND, Enum.RenderPriority.Character.Value + 1, function()
			safeCall(function() RunService:UnbindFromRenderStep(RAGE_STOMP_BIND) end)
			local char = LocalPlayer.Character
			local current = char and char:FindFirstChild("HumanoidRootPart")
			if current then
				safeCall(function() current.CFrame = saved end)
			end
		end)
	end)

	if not bound then
		safeCall(function() root.CFrame = saved end)
	end

	return pcall(function() Rage.remote:FireServer("Stomp") end)
end

local function rage_step_stomp()
	local char, humanoid, root, body = rage_self()
	if not char then return end
	if humanoid.Health <= 0 or rage_ko(LocalPlayer) then return end
	if rage_flag(body, "Reload") then Rage.last_reason = "reloading" return end

	-- auto stomp follows your aim key, stomp aura acts on its own
	if Config.StompAuto and not Config.StompAura and not rage_key_held(Config.StompKey) then return end

	if os.clock() - Rage.last_stomp < Config.StompRate then return end
	if not rage_remote() then return end

	local target = rage_target(Config.StompRange, true, false)
	if not target then Rage.last_reason = "nobody down" return end

	local torso = target.Character:FindFirstChild("UpperTorso") or target.Character:FindFirstChild("Torso")
	if not torso then return end

	local distance = (root.Position - torso.Position).Magnitude
	if distance > Config.StompMaxDistance then
		Rage.last_reason = string.format("down %d studs away", math.floor(distance))
		return
	end

	rage_do_stomp(root, torso)
	Rage.last_stomp = os.clock()
	rage_stats.stomps += 1
	Rage.last_reason = "stomping " .. target.Name
end

local function rage_step_anti_stomp()
	local char, humanoid, root, body = rage_self()
	if not char or humanoid.Health <= 0 then return end
	if not rage_ko(LocalPlayer) then return end

	if Config.Flashback and root then
		Rage.flashback = root.CFrame
	end

	-- the stomp needs you alive and K.O'd: dying first takes the kill away from them
	safeCall(function() humanoid.Health = 0 end)
	rage_stats.denied += 1

	local tool = char:FindFirstChildOfClass("Tool")
	if tool and LocalPlayer.Backpack then
		safeCall(function() tool.Parent = LocalPlayer.Backpack end)
	end

	if Config.AntiStompParts then
		safeCall(function()
			for _, part in ipairs(char:GetChildren()) do
				if part:IsA("BasePart") then
					part.LocalTransparencyModifier = 1
				end
			end
		end)
	end
end

local function rage_step_anti_void()
	if Config.AntiVoid then
		if Rage.fall_height == nil then
			Rage.fall_height = Workspace.FallenPartsDestroyHeight
		end
		if Workspace.FallenPartsDestroyHeight > -1e9 then
			if not pcall(function() Workspace.FallenPartsDestroyHeight = -math.huge end) then
				pcall(function() Workspace.FallenPartsDestroyHeight = -1e9 end)
			end
		end
	elseif Rage.fall_height ~= nil then
		pcall(function() Workspace.FallenPartsDestroyHeight = Rage.fall_height end)
		Rage.fall_height = nil
	end
end

local function rage_step_auto_reload()
	if os.clock() - Rage.last_reload < 0.6 then return end
	local remote = rage_remote()
	local tool = rage_gun()
	if not remote or not tool then return end

	local ammo = tool:FindFirstChild("Ammo")
	if not ammo then return end
	local count = tonumber(ammo.Value)
	if count and count <= 0 then
		Rage.last_reload = os.clock()
		pcall(function() remote:FireServer("Reload", tool) end)
	end
end

LocalPlayer.CharacterAdded:Connect(function(char)
	if not Config.Flashback or not Rage.flashback then return end
	local saved = Rage.flashback
	Rage.flashback = nil
	task.spawn(function()
		local root = char:WaitForChild("HumanoidRootPart", 8)
		if not root then return end
		for _ = 1, 60 do
			if (root.Position - saved.Position).Magnitude > 6 then
				safeCall(function() root.CFrame = saved end)
			else
				return
			end
			task.wait(0.05)
		end
	end)
end)

-- everything the main loop needs, out of the block
RAGE = {
	state = Rage,
	stats = rage_stats,
	remote = rage_remote,
	suspended = rage_suspended,

	-- one entry point for all the per-frame work
	steps = function()
		rage_step_anti_void()
		if Config.AntiStomp then rage_step_anti_stomp() end
		if Config.AutoReload then rage_step_auto_reload() end
		if not rage_suspended() then
			if Config.KillAura then rage_step_kill_aura() end
			if Config.StompAuto or Config.StompAura then rage_step_stomp() end
		end
	end,

	-- anti-cheat activity feed + the live status line on the Rage page
	feed = function()
		if _G.AC and _G.AC.blocked ~= last_ac_blocked then
			local entry = _G.AC.last
			last_ac_blocked = _G.AC.blocked
			if entry then
				notify("AC blocked", tostring(entry.remote) .. " → " .. tostring(entry.action))
			end
		end

		local badge = _G.RAGE_STATUS
		if badge and os.clock() - last_rage_status > 0.25 then
			last_rage_status = os.clock()
			local mode
			if rage_suspended() then
				mode = string.format("suspended %.0fs", Rage.suspend_until - os.clock())
			else
				mode = tostring(Rage.last_reason or "idle")
			end
			badge.Text = string.format("status: %s  ·  %d shots · %d stomps · %d denied  ·  %s",
				mode, rage_stats.shots, rage_stats.stomps, rage_stats.denied,
				tostring(Rage.remote and Rage.remote.Name or "no remote"))
		end
	end,
}

end

-- ============================================================================
--  MAIN LOOP
-- ============================================================================

local ESP_INTERVAL = 1 / 60
local lastESP = 0
local lastPlayerListTick = 0

RunService.RenderStepped:Connect(function()
	update_movement()
	update_damage_numbers()

	-- fov circle ------------------------------------------------------------
	local mouse = mouse_pos()
	FOVFrame.Visible = Config.FOVEnabled and Config.Visible
	if FOVFrame.Visible then
		FOVFrame.Position = UDim2.fromOffset(mouse.X, mouse.Y)
		FOVFrame.Size = UDim2.fromOffset(Config.FOVRadius * 2, Config.FOVRadius * 2)
		FOVFrame.BackgroundTransparency = Config.FOVFilled and 0.88 or 1
		FOVStroke.Thickness = Config.FOVThickness
	end

	-- hit marker ------------------------------------------------------------
	if HitMarker.Visible and os.clock() > hitmarkerUntil then
		HitMarker.Visible = false
	end

	-- fps / ping ------------------------------------------------------------
	fpsFrames += 1
	if os.clock() - fpsClock >= 0.5 then
		fpsValue = math.floor(fpsFrames / (os.clock() - fpsClock))
		fpsFrames = 0
		fpsClock = os.clock()
	end
	if os.clock() - lastPingUpdate >= 0.5 then
		cachedPing = get_ping()
		lastPingUpdate = os.clock()
	end

	Watermark.Visible = Config.Visible and Config.Watermark
	if Config.Watermark then
		local bits = { "SMERTLOCK v2" }
		if Config.ShowFPS then table.insert(bits, fpsValue .. " fps") end
		if Config.ShowPing then table.insert(bits, math.floor(cachedPing) .. " ms") end
		if Config.Target then table.insert(bits, "→ " .. Config.Target.DisplayName) end
		WmText.Text = table.concat(bits, "   ·   ")
	end

	-- toasts ----------------------------------------------------------------
	if #toasts > 0 then
		for i = #toasts, 1, -1 do
			local toast = toasts[i]
			local age = os.clock() - toast.born
			if age > 3.5 then
				toast.frame:Destroy()
				table.remove(toasts, i)
			elseif age > 2.8 then
				toast.frame.BackgroundTransparency = 0.05 + (age - 2.8) / 0.7 * 0.9
				for _, child in ipairs(toast.frame:GetDescendants()) do
					if child:IsA("TextLabel") then
						child.TextTransparency = (age - 2.8) / 0.7
					end
				end
			end
		end
	end

	clear_invalid_target()

	-- camlock ---------------------------------------------------------------
	if Config.Enabled and Config.IsHolding then
		if not Config.Target and os.clock() - lastAcquire >= Config.ReacquireDelay then
			Config.Target = find_target()
			lastAcquire = os.clock()
		end
		if Config.Target and is_valid_target(Config.Target) then
			local char = Config.Target.Character
			local part = get_target_part(char)
			if part then
				local blocked = Config.WallCheck
					and #Camera:GetPartsObscuringTarget({ Camera.CFrame.Position, part.Position }, { LocalPlayer.Character, char }) > 0
				if not blocked then
					local prediction = get_prediction()
					Camera.CFrame = Camera.CFrame:Lerp(
						CFrame.new(Camera.CFrame.Position, part.Position + part.AssemblyLinearVelocity * prediction),
						Config.Smoothness
					)
				end
			end
		end
	end

	watch_target_health()

	-- rapid fire ------------------------------------------------------------
	if Config.RapidFireEnabled then
		local tool = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Tool")
		if tool and (not Config.RapidFireOnlyWhenHolding or Config.IsHolding) then
			local now = os.clock()
			if now - lastRapidFire >= Config.RapidFireDelay then
				lastRapidFire = now
				fire_weapon()
			end
		end
	end

	-- triggerbot ------------------------------------------------------------
	if Config.TriggerbotEnabled and trigger_target() then
		fire_trigger()
	end

	-- rage ------------------------------------------------------------------
	if RAGE then
		RAGE.steps()
		RAGE.feed()
	end

	-- target info -----------------------------------------------------------
	if Config.TargetInfo and Config.Target and Config.Target.Character then
		local state, _, humanoid, root = get_character_state(Config.Target)
		if root then
			TargetInfo.Visible = Config.Visible
			TargetName.Text = Config.Target.DisplayName
			TargetState.Text = "state: " .. state
			TargetHealth.Text = "hp: " .. tostring(humanoid and math.max(0, math.floor(humanoid.Health)) or 0)
			local my_root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
			TargetDistance.Text = "distance: " .. tostring(my_root and math.floor((my_root.Position - root.Position).Magnitude) or 0) .. " studs"
			TargetWeapon.Text = "weapon: " .. get_weapon_name(Config.Target)
		else
			TargetInfo.Visible = false
		end
	else
		TargetInfo.Visible = false
	end

	-- esp -------------------------------------------------------------------
	local now = os.clock()
	if now - lastESP >= ESP_INTERVAL then
		lastESP = now
		refreshESPList()
		for _, rec in pairs(esps) do
			update_esp(rec)
		end
	end

	if status_label then
		status_label.Text = "status: " .. saveStatus
	end

	-- slow player-list tick, and only while that page is actually open
	if pages.Players and pages.Players.Visible and os.clock() - lastPlayerListTick >= 0.75 then
		lastPlayerListTick = os.clock()
		updatePlayerList()
	end
end)

-- ============================================================================
--  BOOT
-- ============================================================================

select_page("Combat")
applyTheme()
refreshESPList()
updatePlayerList()

SCREEN_GUI.AncestryChanged:Connect(function(_, parent)
	if parent == nil then
		stopFly()
		for _, rec in pairs(esps) do destroy_esp(rec) end
	end
end)

notify("SmertLock", "v2 loaded — tracer rebuilt, advanced/silent aim removed")
