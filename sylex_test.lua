--[[
	Sylex UI
	Roblox UI library: windows, tabs, elements, notifications, themes and config saving.
]]

local Library = {
	Flags = {},
	Options = {},
	Unloaded = false,
	ConfigFolder = "Sylex/configs",
}
local SaveTheme = {}
local themeListeners = {}
local connections = {}
local unloadCallbacks = {}
local popups = {}
local keybindRegistry = {}
local flagListeners = {}
local tierListeners = {}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local TextService = game:GetService("TextService")
local UIS = game:GetService("UserInputService")
local Tw = game:GetService("TweenService")
local LocalPlayer = Players.LocalPlayer

local addToTheme, getColorFromPath, gl, tw, changecanvas, gs, jc, jcf, lak, click, background, addDropdownSelect, addTooltip

-- Debug mode: Library:SetDebug(true) prints flag changes, config activity, locks and full error tracebacks
local function describe(v)
	if type(v) == "table" then
		local ok, json = pcall(function()
			return game:GetService("HttpService"):JSONEncode(v)
		end)
		return ok and json or tostring(v)
	end
	return tostring(v)
end

local function debugLog(...)
	if Library.Debug then
		local parts = {}
		for i = 1, select("#", ...) do
			parts[i] = describe((select(i, ...)))
		end
		print("[Sylex debug] " .. table.concat(parts, " "))
	end
end

function Library:SetDebug(enabled)
	self.Debug = enabled == true
	print("[Sylex] debug mode " .. (self.Debug and "on" or "off"))
end

local function safeCall(fn, ...)
	if Library.Unloaded or type(fn) ~= "function" then
		return
	end
	if Library.Debug then
		local args = table.pack(...)
		local ok, err = xpcall(function()
			return fn(table.unpack(args, 1, args.n))
		end, debug.traceback)
		if not ok then
			warn("[Sylex] callback error: " .. tostring(err))
		end
		return
	end
	local ok, err = pcall(fn, ...)
	if not ok then
		warn("[Sylex] callback error: " .. tostring(err))
	end
end

local function track(conn)
	table.insert(connections, conn)
	return conn
end

local function proxySignal(signal)
	return {
		Connect = function(_, fn)
			return track(signal:Connect(fn))
		end,
	}
end

-- UserInputService proxy: every connection made through it is tracked so Library:Unload() can disconnect it
local U = setmetatable({
	InputBegan = proxySignal(UIS.InputBegan),
	InputChanged = proxySignal(UIS.InputChanged),
	InputEnded = proxySignal(UIS.InputEnded),
}, {
	__index = function(_, k)
		local v = UIS[k]
		if type(v) == "function" then
			return function(_, ...)
				return v(UIS, ...)
			end
		end
		return v
	end,
})
local RenderStepped = proxySignal(RunService.RenderStepped)

-- File helpers (executor file API; everything degrades gracefully without it)
local hasFiles = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"

local function ensureFolder(path)
	if type(makefolder) ~= "function" then
		return
	end
	local current = ""
	for part in string.gmatch(path, "[^/]+") do
		current = current == "" and part or current .. "/" .. part
		local exists = type(isfolder) == "function" and select(2, pcall(isfolder, current))
		if not exists then
			pcall(makefolder, current)
		end
	end
end

local function writeFile(path, data)
	if not hasFiles then
		return false
	end
	local folder = path:match("^(.*)/[^/]+$")
	if folder then
		ensureFolder(folder)
	end
	return (pcall(writefile, path, data))
end

local function readFile(path)
	if not hasFiles then
		return nil
	end
	local ok, exists = pcall(isfile, path)
	if not ok or not exists then
		return nil
	end
	local ok2, data = pcall(readfile, path)
	return ok2 and data or nil
end

-- The Sylex logo for the open button: downloaded once, cached, loaded with getcustomasset
local LOGO_URL = "https://raw.githubusercontent.com/Realestkai/uilib/refs/heads/main/assets/sylex-logo.png"
local LOGO_PATH = "Sylex/assets/sylex-logo.png"
local function loadLogo()
	local getasset = getcustomasset or getsynasset
	if type(getasset) ~= "function" or not hasFiles then
		return nil
	end
	local data = readFile(LOGO_PATH)
	if not data or data:sub(2, 4) ~= "PNG" then
		local ok, body = pcall(game.HttpGet, game, LOGO_URL)
		if not ok or type(body) ~= "string" or body:sub(2, 4) ~= "PNG" then
			return nil
		end
		if not writeFile(LOGO_PATH, body) then
			return nil
		end
	end
	local ok, id = pcall(getasset, LOGO_PATH)
	return ok and type(id) == "string" and id or nil
end

local function setFlag(flag, value)
	if not flag then
		return
	end
	Library.Flags[flag] = value
	debugLog("flag", flag, "=", value)
	if Library._autosave then
		Library._autosave()
	end
	for _, fn in ipairs(flagListeners[flag] or {}) do
		safeCall(fn, value)
	end
end

-- Runs fn(value) whenever the flag changes; returns a function that stops listening
function Library:OnFlagChanged(flag, fn)
	flagListeners[flag] = flagListeners[flag] or {}
	table.insert(flagListeners[flag], fn)
	return function()
		local list = flagListeners[flag]
		local i = list and table.find(list, fn)
		if i then
			table.remove(list, i)
		end
	end
end

--// Freemium / Premium

Library.Premium = false

-- Premium = true unlocks every element made with Premium = true and updates the profile card
function Library:SetPremium(enabled)
	self.Premium = enabled == true
	debugLog("tier =", self.Premium and "Premium" or "Freemium")
	for _, fn in ipairs(tierListeners) do
		safeCall(fn, self.Premium)
	end
end

function Library:IsPremium()
	return self.Premium == true
end

function Library:GetTier()
	return self.Premium and "Premium" or "Freemium"
end

-- Asks a tier server (e.g. the Sylex Premium worker) whether this player is Premium.
-- Expects GET <url>?userId=<id> to return { "premium": true/false }. Yields; returns the result.
function Library:CheckPremium(url)
	local userId = game:GetService("Players").LocalPlayer.UserId
	local sep = string.find(url, "?", 1, true) and "&" or "?"
	local ok, body = pcall(game.HttpGet, game, url .. sep .. "userId=" .. tostring(userId))
	if not ok then
		debugLog("premium check failed:", body)
		return self.Premium
	end
	local decoded, data = pcall(function()
		return game:GetService("HttpService"):JSONDecode(body)
	end)
	if not decoded or type(data) ~= "table" then
		debugLog("premium check returned something that isn't JSON")
		return self.Premium
	end
	self:SetPremium(data.premium == true)
	return self.Premium
end

local function onTheme(fn)
	table.insert(themeListeners, fn)
end

local function registerPopup(close)
	table.insert(popups, close)
	return close
end

local function closePopups(except)
	for _, close in ipairs(popups) do
		if close ~= except then
			pcall(close)
		end
	end
end

local function applyVisibility(root)
	-- while a tab search is active, collapsed sections are searched too
	root.Visible = not root:GetAttribute("SylexHidden")
		and not root:GetAttribute("SylexDependency")
		and not root:GetAttribute("SylexFiltered")
		and (root:GetAttribute("SylexSearching") or not root:GetAttribute("SylexCollapsed"))
end

-- Shared methods every element gets: SetVisible, Destroy, Set (alias), flag registration, tooltip
local function attachCommon(obj, root, p, kind)
	p = p or {}
	obj.Type = kind
	obj.Instance = root
	root:SetAttribute("SylexSearch", string.lower(tostring(p.Title or "") .. " " .. tostring(p.Desc or "")))
	function obj:SetVisible(v)
		root:SetAttribute("SylexHidden", not v)
		applyVisibility(root)
	end
	function obj:Destroy()
		if obj._cleanup then
			pcall(obj._cleanup)
		end
		if obj.Flag then
			Library.Options[obj.Flag] = nil
			Library.Flags[obj.Flag] = nil
		end
		root:Destroy()
	end
	if obj.SetValue and not obj.Set then
		function obj:Set(...)
			return obj:SetValue(...)
		end
	end
	if p.Flag then
		if Library.Options[p.Flag] then
			warn("[Sylex] two elements use the flag '" .. tostring(p.Flag) .. "'; the newer one replaces the older in configs")
		end
		obj.Flag = p.Flag
		Library.Options[p.Flag] = obj
		if obj.Get then
			Library.Flags[p.Flag] = obj:Get()
			for _, fn in ipairs(flagListeners[p.Flag] or {}) do
				safeCall(fn, Library.Flags[p.Flag])
			end
		end
	end
	if p.Tooltip and addTooltip then
		addTooltip(root, p.Tooltip)
	end

	-- Locking: an element can be locked by its Premium tier, by code (Lock) or by DependsOn.
	-- A locked element is greyed out, ignores clicks and shows the reason; Premium wins over the others.
	local lockReasons = {}
	local lockOrder = { "premium", "manual", "dependency" }
	local lockOverlay, lockLabel, lockIcon
	local cleanups = {}

	local function setIcon(name)
		local icon = gl(name)
		lockIcon.Image = icon.Image
		lockIcon.ImageRectSize = icon.ImageRectSize or Vector2.zero
		lockIcon.ImageRectOffset = icon.ImageRectPosition or Vector2.zero
	end

	local function buildOverlay()
		lockOverlay = Instance.new("TextButton")
		lockOverlay.Name = "SylexLock"
		lockOverlay.AutoButtonColor = false
		lockOverlay.Text = ""
		lockOverlay.BackgroundColor3 = Color3.new(0, 0, 0)
		lockOverlay.BackgroundTransparency = 0.45
		lockOverlay.BorderSizePixel = 0
		lockOverlay.Size = UDim2.new(1, 0, 1, 0)
		lockOverlay.ZIndex = 20
		Instance.new("UICorner").Parent = lockOverlay

		lockIcon = Instance.new("ImageLabel")
		lockIcon.BackgroundTransparency = 1
		lockIcon.AnchorPoint = Vector2.new(1, 0.5)
		lockIcon.Position = UDim2.new(1, -12, 0.5, 0)
		lockIcon.Size = UDim2.new(0, 14, 0, 14)
		lockIcon.ZIndex = 21
		lockIcon.Parent = lockOverlay

		lockLabel = Instance.new("TextLabel")
		lockLabel.BackgroundTransparency = 1
		lockLabel.AnchorPoint = Vector2.new(1, 0.5)
		lockLabel.Position = UDim2.new(1, -32, 0.5, 0)
		lockLabel.Size = UDim2.new(0.6, 0, 1, 0)
		lockLabel.Font = Enum.Font.GothamBold
		lockLabel.TextSize = 11
		lockLabel.TextXAlignment = Enum.TextXAlignment.Right
		lockLabel.TextTruncate = Enum.TextTruncate.AtEnd
		lockLabel.ZIndex = 21
		lockLabel.Parent = lockOverlay

		lockOverlay.Parent = root
	end

	local function refreshLock()
		local source
		for _, s in ipairs(lockOrder) do
			if lockReasons[s] then
				source = s
				break
			end
		end
		local wasLocked = obj.Locked
		obj.Locked = source ~= nil
		obj.LockedBy = source
		if source then
			if not lockOverlay then
				buildOverlay()
			end
			local premium = source == "premium"
			local color = premium and Color3.fromRGB(255, 196, 64) or Color3.new(1, 1, 1)
			setIcon(premium and "crown" or "lock")
			lockIcon.ImageColor3 = color
			lockLabel.TextColor3 = color
			lockLabel.Text = lockReasons[source]
			lockOverlay.Visible = true
		elseif lockOverlay then
			lockOverlay.Visible = false
		end
		if wasLocked ~= obj.Locked then
			debugLog(kind, tostring(p.Title or p.Flag or ""), obj.Locked and ("locked (" .. source .. ")") or "unlocked")
		end
	end

	function obj:Lock(reason)
		lockReasons.manual = tostring(reason or "Locked")
		refreshLock()
	end

	-- Unlock only removes a Lock() from code; Premium and DependsOn locks stay until their condition is met
	function obj:Unlock()
		lockReasons.manual = nil
		refreshLock()
	end

	function obj:IsLocked()
		return obj.Locked == true
	end

	if p.Locked then
		obj:Lock(p.LockReason)
	end

	-- Premium = true: locked for Freemium users
	if p.Premium then
		obj.Premium = true
		local function updateTier(isPremium)
			lockReasons.premium = (not isPremium) and tostring(p.PremiumReason or "Premium only") or nil
			refreshLock()
		end
		table.insert(tierListeners, updateTier)
		table.insert(cleanups, function()
			local i = table.find(tierListeners, updateTier)
			if i then
				table.remove(tierListeners, i)
			end
		end)
		updateTier(Library.Premium)
	end

	-- DependsOn: only show (or unlock) this element while another flag has the right value
	if p.DependsOn then
		local dep = type(p.DependsOn) == "table" and p.DependsOn or { Flag = p.DependsOn }
		local function met(v)
			if type(dep.Value) == "function" then
				return dep.Value(v) == true
			elseif dep.Value ~= nil then
				return v == dep.Value
			elseif type(v) == "table" then
				return next(v) ~= nil
			end
			return v ~= nil and v ~= false and v ~= ""
		end
		local function update(v)
			local ok = met(v)
			if dep.Lock then
				lockReasons.dependency = (not ok) and tostring(dep.Reason or ("Requires " .. tostring(dep.Flag))) or nil
				refreshLock()
			else
				root:SetAttribute("SylexDependency", not ok)
				applyVisibility(root)
			end
		end
		table.insert(cleanups, Library:OnFlagChanged(dep.Flag, update))
		update(Library.Flags[dep.Flag])
		task.delay(2, function()
			if Library.Options[dep.Flag] == nil and not Library.Unloaded then
				debugLog("warning:", tostring(p.Title or kind), "depends on flag", dep.Flag, "but no element has that flag")
			end
		end)
	end

	if #cleanups > 0 then
		local prev = obj._cleanup
		obj._cleanup = function()
			for _, fn in ipairs(cleanups) do
				pcall(fn)
			end
			if prev then
				prev()
			end
		end
	end
	return obj
end

-- Builds a full theme from a small palette, so every theme stays consistent
local function makeTheme(c)
	local function on()
		return { ['Toggle Background'] = c.AccentDim, ['Toggle Value'] = c.Accent }
	end
	local function off()
		return { ['Toggle Background'] = c.Input, ['Toggle Value'] = c.Hover }
	end
	local function field()
		return { ['Background'] = c.Element, ['Value Background'] = c.Page, ['Value Stroke'] = c.Text }
	end
	local dropdown = field()
	dropdown['Dropdown Select'] = { ['Background'] = c.Page, ['Search'] = c.Input, ['Item Background'] = c.Hover }
	local slider = field()
	slider['Slider Bar'] = c.AccentDim
	slider['Slider Bar Value'] = c.Accent
	slider['Circle Value'] = Color3.fromRGB(255, 255, 255)
	local keybind = field()
	keybind['True'] = on()
	keybind['False'] = off()
	return {
		['Shadow'] = c.Shadow,
		['Background'] = c.Background,
		['Background Gradient'] = ColorSequence.new(c.Background),
		['Page'] = c.Page,
		['Main'] = c.Accent,
		['Text & Icon'] = c.Text,
		['Function'] = {
			['Toggle'] = { ['Background'] = c.Element, ['True'] = on(), ['False'] = off() },
			['Label'] = { ['Background'] = c.Element },
			['Dropdown'] = dropdown,
			['Slider'] = slider,
			['Code'] = {
				['Background'] = ColorSequence.new(c.Element),
				['Background Code'] = c.Hover,
				['Background Code Value'] = c.Input,
				['ScrollingFrame Code'] = c.Accent:Lerp(c.Text, 0.35),
			},
			['Button'] = { ['Background'] = c.Element, ['Click'] = c.Text },
			['Textbox'] = field(),
			['Keybind'] = keybind,
			['Color Picker'] = {
				['Background'] = c.Element,
				['Color Select'] = { ['Background'] = c.Page, ['UIStroke'] = c.Text },
			},
		},
	}
end

local rgb = Color3.fromRGB
local palettes = {
	-- name, shadow, background, page, element, input, hover, accent, accent dim, text
	{'Midnight', rgb(4, 6, 14), rgb(12, 17, 40), rgb(8, 11, 27), rgb(16, 22, 50), rgb(20, 26, 56), rgb(30, 38, 76), rgb(72, 104, 214), rgb(30, 46, 110), rgb(235, 238, 255)},
	{'Onyx', rgb(0, 0, 0), rgb(10, 10, 10), rgb(5, 5, 5), rgb(17, 17, 17), rgb(21, 21, 21), rgb(36, 36, 36), rgb(205, 205, 205), rgb(62, 62, 62), rgb(240, 240, 240)},
	{'Slate', rgb(10, 12, 16), rgb(24, 28, 36), rgb(17, 20, 26), rgb(30, 35, 45), rgb(36, 41, 52), rgb(50, 57, 72), rgb(122, 152, 194), rgb(52, 64, 84), rgb(225, 230, 240)},
	{'Ocean', rgb(3, 10, 14), rgb(10, 24, 34), rgb(6, 16, 24), rgb(14, 32, 44), rgb(18, 38, 52), rgb(28, 52, 70), rgb(40, 170, 200), rgb(18, 74, 92), rgb(225, 245, 250)},
	{'Emerald', rgb(4, 10, 8), rgb(12, 26, 20), rgb(7, 17, 13), rgb(16, 34, 26), rgb(20, 40, 31), rgb(30, 56, 44), rgb(46, 190, 120), rgb(22, 82, 54), rgb(225, 245, 235)},
	{'Crimson', rgb(12, 4, 5), rgb(30, 12, 14), rgb(20, 7, 9), rgb(40, 16, 19), rgb(46, 20, 23), rgb(66, 30, 34), rgb(214, 58, 72), rgb(96, 28, 34), rgb(250, 232, 234)},
	{'Rose', rgb(12, 6, 10), rgb(32, 16, 26), rgb(21, 10, 17), rgb(42, 21, 34), rgb(48, 25, 39), rgb(68, 36, 55), rgb(236, 110, 160), rgb(104, 46, 72), rgb(252, 234, 242)},
	{'Amber', rgb(12, 8, 3), rgb(30, 22, 10), rgb(20, 14, 6), rgb(40, 29, 14), rgb(46, 34, 17), rgb(66, 49, 25), rgb(236, 160, 48), rgb(104, 70, 22), rgb(252, 242, 226)},
	{'Mocha', rgb(12, 9, 8), rgb(30, 24, 22), rgb(21, 16, 15), rgb(40, 32, 29), rgb(46, 37, 34), rgb(64, 52, 47), rgb(196, 150, 112), rgb(88, 66, 50), rgb(240, 230, 222)},
}

local themes = {
	index = {'Midnight', 'Dark'},
	Dark = {
		['Shadow'] = Color3.fromRGB(15, 15, 15),
		['Background'] = Color3.fromRGB(20, 20, 20),
		['Background Gradient'] = ColorSequence.new(Color3.fromRGB(20, 20, 20)),
		['Page'] = Color3.fromRGB(18, 18, 18),
		['Main'] = Color3.fromRGB(50, 50, 50),
		['Text & Icon'] = Color3.fromRGB(230, 230, 230),
		['Function'] = {
			['Toggle'] = {
				['Background'] = Color3.fromRGB(25, 25, 25),
				['True'] = {
					['Toggle Background'] = Color3.fromRGB(40, 40, 40),
					['Toggle Value'] = Color3.fromRGB(70, 130, 180),
				},
				['False'] = {
					['Toggle Background'] = Color3.fromRGB(30, 30, 30),
					['Toggle Value'] = Color3.fromRGB(40, 40, 40),
				}
			},
			['Label'] = {
				['Background'] = Color3.fromRGB(25, 25, 25),
			},
			['Dropdown'] = {
				['Background'] = Color3.fromRGB(25, 25, 25),
				['Value Background'] = Color3.fromRGB(20, 20, 20),
				['Value Stroke'] = Color3.fromRGB(230, 230, 230),
				['Dropdown Select'] = {
					['Background'] = Color3.fromRGB(20, 20, 20),
					['Search'] = Color3.fromRGB(30, 30, 30),
					['Item Background'] = Color3.fromRGB(30, 30, 30),
				}
			},
			['Slider'] = {
				['Background'] = Color3.fromRGB(25, 25, 25),
				['Value Background'] = Color3.fromRGB(20, 20, 20),
				['Value Stroke'] = Color3.fromRGB(230, 230, 230),
				['Slider Bar'] = Color3.fromRGB(40, 40, 40),
				['Slider Bar Value'] = Color3.fromRGB(70, 130, 180),
				['Circle Value'] = Color3.fromRGB(255, 255, 255)
			},
			['Code'] = {
				['Background'] = ColorSequence.new{ColorSequenceKeypoint.new(0, Color3.fromRGB(25, 25, 25)), ColorSequenceKeypoint.new(1, Color3.fromRGB(25, 25, 25))},
				['Background Code'] = Color3.fromRGB(35, 35, 35),
				['Background Code Value'] = Color3.fromRGB(28, 28, 28),
				['ScrollingFrame Code'] = Color3.fromRGB(150, 150, 150)
			},
			['Button'] = {
				['Background'] = Color3.fromRGB(25, 25, 25),
				['Click'] = Color3.fromRGB(230, 230, 230)
			},
			['Textbox'] = {
				['Background'] = Color3.fromRGB(25, 25, 25),
				['Value Background'] = Color3.fromRGB(20, 20, 20),
				['Value Stroke'] = Color3.fromRGB(230, 230, 230),
			},
			['Keybind'] = {
				['Background'] = Color3.fromRGB(25, 25, 25),
				['Value Background'] = Color3.fromRGB(20, 20, 20),
				['Value Stroke'] = Color3.fromRGB(230, 230, 230),
				['True'] = {
					['Toggle Background'] = Color3.fromRGB(40, 40, 40),
					['Toggle Value'] = Color3.fromRGB(70, 130, 180),
				},
				['False'] = {
					['Toggle Background'] = Color3.fromRGB(30, 30, 30),
					['Toggle Value'] = Color3.fromRGB(40, 40, 40),
				}
			},
			['Color Picker'] = {
				['Background'] = Color3.fromRGB(25, 25, 25),
				['Color Select'] = {
					['Background'] = Color3.fromRGB(20, 20, 20),
					['UIStroke'] = Color3.fromRGB(230, 230, 230),
				}
			}
		}
	},
}

for _, c in ipairs(palettes) do
	local name = c[1]
	themes[name] = makeTheme({
		Shadow = c[2], Background = c[3], Page = c[4], Element = c[5], Input = c[6],
		Hover = c[7], Accent = c[8], AccentDim = c[9], Text = c[10],
	})
	if not table.find(themes.index, name) then
		table.insert(themes.index, name)
	end
end

local GUI_NAME = "Sylex"
local env = (type(getgenv) == "function" and getgenv()) or _G

-- Re-executing the script cleanly replaces the previous copy
if env.__SylexLibrary and env.__SylexLibrary ~= Library then
	pcall(function()
		env.__SylexLibrary:Unload()
	end)
end
env.__SylexLibrary = Library

local function getGuiParent()
	if RunService:IsStudio() then
		return LocalPlayer:WaitForChild("PlayerGui")
	end
	local ok, hui = pcall(function()
		return gethui()
	end)
	if ok and typeof(hui) == "Instance" then
		return hui
	end
	return game:GetService("CoreGui")
end

local guiParent = getGuiParent()
local existingGui = guiParent:FindFirstChild(GUI_NAME)
if existingGui then
	existingGui:Destroy()
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = GUI_NAME
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.ResetOnSpawn = false
ScreenGui.DisplayOrder = 999
if type(syn) == "table" and type(syn.protect_gui) == "function" then
	pcall(syn.protect_gui, ScreenGui)
end
ScreenGui.Parent = guiParent

function Library:OnUnload(fn)
	table.insert(unloadCallbacks, fn)
end

function Library:Unload()
	if self.Unloaded then
		return
	end
	for _, fn in ipairs(unloadCallbacks) do
		pcall(fn)
	end
	if self._saveWindowState then
		pcall(self._saveWindowState)
	end
	self.Unloaded = true
	for _, conn in ipairs(connections) do
		pcall(function()
			conn:Disconnect()
		end)
	end
	table.clear(connections)
	ScreenGui:Destroy()
	if env.__SylexLibrary == Library then
		env.__SylexLibrary = nil
	end
end

--// Config saving

local function serializeOption(obj)
	local v = obj:Get()
	if obj.Type == "Keybind" then
		return { Key = v.Key.Name, Value = v.Value }
	elseif obj.Type == "ColorPicker" then
		return "#" .. v:ToHex()
	end
	return v
end

local function configPath(name)
	-- keep names to plain characters so a config name can't point outside the folder
	local clean = tostring(name or "default"):gsub("[^%w%-_ ]", "")
	if clean == "" then
		clean = "default"
	end
	return Library.ConfigFolder .. "/" .. clean .. ".json"
end

function Library:Notify(p)
	if self._window then
		self._window:Notify(p)
	end
end

local function collectConfig()
	local data = {}
	for flag, obj in pairs(Library.Options) do
		if obj.Get and not obj.NoSave then
			local ok, value = pcall(serializeOption, obj)
			if ok then
				data[flag] = value
			end
		end
	end
	return data
end

local function applyConfig(data)
	Library._loading = true
	for flag, value in pairs(data) do
		local obj = Library.Options[flag]
		-- a Freemium user can't switch on Premium features by loading someone else's config
		if obj and obj.Set and obj.LockedBy ~= "premium" then
			pcall(obj.Set, obj, value)
		end
	end
	Library._loading = false
end

function Library:SaveConfig(name)
	self._autosaveArmed = true
	debugLog("save config", configPath(name))
	return writeFile(configPath(name), HttpService:JSONEncode(collectConfig()))
end

-- Config codes: the current settings as one line of text players can share
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local CODE_PREFIX = "SYLEX1:"

local function base64Encode(s)
	local out = {}
	for i = 1, #s, 3 do
		local a, b, c = s:byte(i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local chunk = {}
		for j = 3, 0, -1 do
			local idx = math.floor(n / 64 ^ j) % 64 + 1
			table.insert(chunk, B64:sub(idx, idx))
		end
		if not b then
			chunk[3], chunk[4] = "=", "="
		elseif not c then
			chunk[4] = "="
		end
		table.insert(out, table.concat(chunk))
	end
	return table.concat(out)
end

local function base64Decode(s)
	s = s:gsub("[^%w%+/=]", "")
	if #s % 4 ~= 0 then
		return nil
	end
	local out = {}
	for i = 1, #s, 4 do
		local n, pad = 0, 0
		for j = 0, 3 do
			local ch = s:sub(i + j, i + j)
			local idx
			if ch == "=" then
				pad = pad + 1
				idx = 1
			else
				idx = B64:find(ch, 1, true)
			end
			if not idx then
				return nil
			end
			n = n * 64 + (idx - 1)
		end
		local bytes = string.char(math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
		table.insert(out, bytes:sub(1, 3 - pad))
	end
	return table.concat(out)
end

-- Returns the code and copies it to the clipboard when the executor allows it
function Library:ExportConfig()
	local code = CODE_PREFIX .. base64Encode(HttpService:JSONEncode(collectConfig()))
	if type(setclipboard) == "function" then
		pcall(setclipboard, code)
	elseif type(toclipboard) == "function" then
		pcall(toclipboard, code)
	end
	debugLog("export config,", #code, "characters")
	return code
end

function Library:ImportConfig(code)
	code = tostring(code or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if code:sub(1, #CODE_PREFIX) ~= CODE_PREFIX then
		debugLog("import config failed: missing " .. CODE_PREFIX .. " prefix")
		return false
	end
	local json = base64Decode(code:sub(#CODE_PREFIX + 1))
	local ok, data = pcall(function()
		return HttpService:JSONDecode(json)
	end)
	if not json or not ok or type(data) ~= "table" then
		debugLog("import config failed: code is damaged")
		return false
	end
	self._autosaveArmed = true
	applyConfig(data)
	debugLog("import config ok")
	return true
end

function Library:LoadConfig(name)
	self._autosaveArmed = true
	if name == nil then
		-- no name: use the autoload config if one was set, otherwise "default"
		local autoload = readFile(self.ConfigFolder .. "/autoload.txt")
		name = autoload and autoload:gsub("%s+$", "") or "default"
	end
	local raw = readFile(configPath(name))
	if not raw then
		return false
	end
	local ok, data = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not ok or type(data) ~= "table" then
		debugLog("load config failed: invalid JSON in", configPath(name))
		return false
	end
	debugLog("load config", configPath(name))
	applyConfig(data)
	return true
end

function Library:DeleteConfig(name)
	if type(delfile) ~= "function" then
		return false
	end
	return (pcall(delfile, configPath(name)))
end

function Library:ListConfigs()
	local list = {}
	if type(listfiles) ~= "function" then
		return list
	end
	local ok, files = pcall(listfiles, self.ConfigFolder)
	if not ok or type(files) ~= "table" then
		return list
	end
	for _, file in ipairs(files) do
		local configName = file:gsub("\\", "/"):match("([^/]+)%.json$")
		if configName then
			table.insert(list, configName)
		end
	end
	table.sort(list)
	return list
end

--// Themes API

local function deepCopy(t)
	if type(t) ~= "table" then
		return t
	end
	local copy = {}
	for k, v in pairs(t) do
		copy[k] = deepCopy(v)
	end
	return copy
end

-- fills missing keys from defaults; copies tables so themes never share (and mutate) each other's colours
local function deepFill(target, defaults)
	for k, v in pairs(defaults) do
		if target[k] == nil then
			target[k] = deepCopy(v)
		elseif type(v) == "table" and type(target[k]) == "table" then
			deepFill(target[k], v)
		end
	end
	return target
end

function Library:AddTheme(name, theme)
	assert(type(name) == "string", "AddTheme: name must be a string")
	assert(type(theme) == "table", "AddTheme: theme must be a table")
	themes[name] = deepFill(theme, themes.Dark)
	if not table.find(themes.index, name) then
		table.insert(themes.index, name)
		for _, drop in ipairs(Library._themeDropdowns or {}) do
			pcall(drop.Add, drop, name)
		end
	end
end

function Library:GetThemes()
	return table.clone(themes.index)
end

do
	function addToTheme(name, obj)
		if not SaveTheme[name] then
			SaveTheme[name] = {}
		end
		table.insert(SaveTheme[name], obj)
	end
	function getColorFromPath(tbl, path)
		local result = tbl
		for _, part in ipairs(string.split(path, ".")) do
			result = result and result[part]
		end
		return result
	end
	function Library:setTheme(st)
		for name, objs in pairs(SaveTheme) do
			local color = getColorFromPath(st, name)
			if color then
				for i = #objs, 1, -1 do
					local obj = objs[i]
					if not obj.Parent then
						-- destroyed element: drop the reference
						table.remove(objs, i)
					elseif obj:IsA("Frame") or obj:IsA("CanvasGroup") then
						obj.BackgroundColor3 = color
					elseif obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
						obj.TextColor3 = color
					elseif obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
						obj.ImageColor3 = color
					elseif obj:IsA("ScrollingFrame") then
						obj.ScrollBarImageColor3 = color
					elseif obj:IsA("UIStroke") or obj:IsA("UIGradient") then
						obj.Color = color
					end
				end
			end
		end
		for _, fn in ipairs(themeListeners) do
			pcall(fn)
		end
	end

	-- Icon sheet: fetched once, cached to disk, and never allowed to break loading
	local ICON_URL = "https://raw.githubusercontent.com/Dummyrme/Library/refs/heads/main/Icon.lua"
	local ICON_CACHE = "Sylex/cache/icons.lua"
	local IconList = { Icons = {}, Spritesheets = {} }
	do
		local source
		local okHttp, body = pcall(function()
			return game:HttpGet(ICON_URL)
		end)
		if okHttp and type(body) == "string" and #body > 0 then
			source = body
			writeFile(ICON_CACHE, body)
		else
			source = readFile(ICON_CACHE)
		end
		if source then
			local okLoad, list = pcall(function()
				return loadstring(source)()
			end)
			if okLoad and type(list) == "table" and list.Icons then
				IconList = list
			end
		end
		if not next(IconList.Icons) then
			warn("[Sylex] icon sheet unavailable; named icons will be blank")
		end
	end
	function gl(i)
		local iconData = IconList.Icons[i]
		if iconData then
			local spriteSheet = IconList.Spritesheets[tostring(iconData.Image)]
			if spriteSheet then
				return {
					Image = spriteSheet,
					ImageRectSize = iconData.ImageRectSize,
					ImageRectPosition = iconData.ImageRectPosition,
				}
			end
		end
		local image = ""
		if type(i) == 'number' or (type(i) == 'string' and i:match("^%d+$")) then
			image = "rbxassetid://" .. i
		elseif type(i) == 'string' and (i:find("^rbxassetid://") or i:find("^rbxasset://") or i:find("^https?://")) then
			image = i
		end
		-- unknown icon names fall back to a blank image instead of a broken asset id
		return {
			Image = image,
			ImageRectSize = Vector2.new(0, 0),
			ImageRectPosition = Vector2.new(0, 0),
		}
	end
	function tw(info)
		return Tw:Create(info.v,TweenInfo.new(info.t, info.s, Enum.EasingDirection[info.d]),info.g)
	end
	function changecanvas(ScrollingFrame, UIListLayout, Plus)
		UIListLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
			ScrollingFrame.CanvasSize = UDim2.new(0, 0, 0, UIListLayout.AbsoluteContentSize.Y + (Plus or 5))
		end)
	end
	function gs(side, pl, pr)
		if not side then
			return pl
		end

		local sideLower = string.lower(tostring(side))
		if sideLower == "r" or sideLower == "right" or side == 2 then
			return pr
		elseif sideLower == "l" or sideLower == "left" or side == 1 then
			return pl
		else
			return pl
		end
	end
	function jc(c, p)
		local Mouse = game.Players.LocalPlayer:GetMouse()

		local relativeX = Mouse.X - c.AbsolutePosition.X
		local relativeY = Mouse.Y - c.AbsolutePosition.Y

		if relativeX < 0 or relativeY < 0 or relativeX > c.AbsoluteSize.X or relativeY > c.AbsoluteSize.Y then
			return
		end

		local ClickButtonCircle = Instance.new("Frame")
		ClickButtonCircle.Parent = p
		ClickButtonCircle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		ClickButtonCircle.BackgroundTransparency = 0.7
		ClickButtonCircle.BorderSizePixel = 0
		ClickButtonCircle.AnchorPoint = Vector2.new(0.5, 0.5)
		ClickButtonCircle.Position = UDim2.new(0, relativeX, 0, relativeY)
		ClickButtonCircle.Size = UDim2.new(0, 0, 0, 0)
		ClickButtonCircle.ZIndex = 10

		local UICorner = Instance.new("UICorner")
		UICorner.CornerRadius = UDim.new(1, 0)
		UICorner.Parent = ClickButtonCircle

		local tweenInfo = TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

		local goal = {
			Size = UDim2.new(0, c.AbsoluteSize.X * 1.5, 0, c.AbsoluteSize.X * 1.5),
			BackgroundTransparency = 1
		}

		local expandTween = game:GetService("TweenService"):Create(ClickButtonCircle, tweenInfo, goal)

		expandTween.Completed:Connect(function()
			ClickButtonCircle:Destroy()
		end)

		expandTween:Play()
	end
	function jcf(p, p2)
		local ClickButtonCircle = Instance.new("Frame")
		ClickButtonCircle.Parent = p
		ClickButtonCircle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		ClickButtonCircle.BackgroundTransparency = 0.7
		ClickButtonCircle.BorderSizePixel = 0
		ClickButtonCircle.AnchorPoint = Vector2.new(0.5, 0.5)
		ClickButtonCircle.Position = UDim2.new(0, p2.AbsolutePosition.X - p.AbsolutePosition.X + p2.AbsoluteSize.X / 2,
			0, p2.AbsolutePosition.Y - p.AbsolutePosition.Y + p2.AbsoluteSize.Y / 2)
		ClickButtonCircle.Size = UDim2.new(0, 0, 0, 0)
		ClickButtonCircle.ZIndex = 10

		local UICorner = Instance.new("UICorner")
		UICorner.CornerRadius = UDim.new(1, 0)
		UICorner.Parent = ClickButtonCircle

		local tweenInfo = TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

		local goal = {
			Size = UDim2.new(0, p2.AbsoluteSize.X * 5, 0, p2.AbsoluteSize.X * 5),
			BackgroundTransparency = 1
		}

		local expandTween = game:GetService("TweenService"):Create(ClickButtonCircle, tweenInfo, goal)

		expandTween.Completed:Connect(function()
			ClickButtonCircle:Destroy()
		end)

		expandTween:Play()
	end
	function lak(t, o, onStart, onEnd)
		local a, b, c, d
		local function u(i)
			local dt = i.Position - c
			tw({v = o, t = 0.05, s = Enum.EasingStyle.Linear, d = "InOut", g = {Position = UDim2.new(d.X.Scale, d.X.Offset + dt.X, d.Y.Scale, d.Y.Offset + dt.Y)}}):Play()
		end
		t.InputBegan:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
				a = true
				c = i.Position
				d = o.Position
				if onStart then onStart() end
				i.Changed:Connect(function()
					if i.UserInputState == Enum.UserInputState.End and a then
						a = false
						if onEnd then onEnd() end
					end
				end)
			end
		end)
		t.InputChanged:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch then b = i end end)
		U.InputChanged:Connect(function(i) if i == b and a then u(i) end end)
	end
	function click(p)
		local Click = Instance.new("TextButton")

		Click.Name = "Click"
		Click.Parent = p
		Click.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		Click.BackgroundTransparency = 1.000
		Click.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Click.BorderSizePixel = 0
		Click.Size = UDim2.new(1, 0, 1, 0)
		Click.Font = Enum.Font.SourceSans
		Click.Text = ""
		Click.TextColor3 = Color3.fromRGB(0, 0, 0)
		Click.TextSize = 14.000

		return Click
	end
	do
		local Mouse = LocalPlayer:GetMouse()
		local holder = Instance.new("Frame")
		local label = Instance.new("TextLabel")
		local stroke = Instance.new("UIStroke")

		holder.Name = "Tooltip"
		holder.Parent = ScreenGui
		holder.BackgroundColor3 = Color3.fromRGB(10, 12, 26)
		holder.BorderSizePixel = 0
		holder.Visible = false
		holder.ZIndex = 50
		Instance.new("UICorner", holder).CornerRadius = UDim.new(0, 4)

		stroke.Parent = holder
		stroke.Color = Color3.fromRGB(255, 255, 255)
		stroke.Transparency = 0.9

		label.Parent = holder
		label.BackgroundTransparency = 1
		label.Position = UDim2.fromOffset(7, 5)
		label.Size = UDim2.new(1, -14, 1, -10)
		label.Font = Enum.Font.GothamBold
		label.TextSize = 11
		label.TextColor3 = Color3.fromRGB(235, 238, 255)
		label.TextWrapped = true
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.ZIndex = 51

		addToTheme('Page', holder)
		addToTheme('Text & Icon', label)

		local current
		function addTooltip(target, text)
			target.MouseEnter:Connect(function()
				current = target
				local size = TextService:GetTextSize(tostring(text), 11, Enum.Font.GothamBold, Vector2.new(220, 1000))
				label.Text = tostring(text)
				holder.Size = UDim2.fromOffset(size.X + 14, size.Y + 10)
				holder.Position = UDim2.fromOffset(Mouse.X + 14, Mouse.Y + 10)
				holder.Visible = true
			end)
			target.MouseLeave:Connect(function()
				if current == target then
					current = nil
					holder.Visible = false
				end
			end)
		end

		Library._hideTooltip = function()
			current = nil
			holder.Visible = false
		end

		U.InputChanged:Connect(function(i)
			if holder.Visible and i.UserInputType == Enum.UserInputType.MouseMovement then
				holder.Position = UDim2.fromOffset(Mouse.X + 14, Mouse.Y + 10)
			end
		end)
	end
	function background(pl, t, d, i, ty)
		local RealBackground = Instance.new("Frame")
		local Background = Instance.new("Frame")
		local UICorner_1 = Instance.new("UICorner")
		local T_1 = Instance.new("Frame")
		local UIListLayout_2 = Instance.new("UIListLayout")
		local UIPadding_3 = Instance.new("UIPadding")
		local TextLabel_1 = Instance.new("TextLabel")
		local TextLabel_2 = Instance.new("TextLabel")

		RealBackground.Name = "Real Background"
		RealBackground.Parent = pl
		RealBackground.BackgroundTransparency = 1
		RealBackground.BorderColor3 = Color3.fromRGB(0,0,0)
		RealBackground.BorderSizePixel = 0
		RealBackground.Size = UDim2.new(1, 0,0, 35)
		RealBackground.ClipsDescendants = true

		Background.Name = "Background"
		Background.Parent = RealBackground
		Background.BackgroundColor3 = Color3.fromRGB(18,24,50)
		Background.BorderColor3 = Color3.fromRGB(0,0,0)
		Background.BorderSizePixel = 0
		Background.Size = UDim2.new(1, 0,1, 0)
		Background.ClipsDescendants = true

		addToTheme('Function.'..ty..'.Background', Background)

		UICorner_1.Parent = Background

		T_1.Name = "T"
		T_1.Parent = Background
		T_1.AnchorPoint = Vector2.new(0, 0.5)
		T_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
		T_1.BackgroundTransparency = 1
		T_1.BorderColor3 = Color3.fromRGB(0,0,0)
		T_1.BorderSizePixel = 0
		T_1.Position = UDim2.new(0, 0,0.5, 0)
		T_1.Size = UDim2.new(1, 0,1, 0)

		UIListLayout_2.Parent = T_1
		UIListLayout_2.SortOrder = Enum.SortOrder.LayoutOrder
		UIListLayout_2.VerticalAlignment = Enum.VerticalAlignment.Center

		UIPadding_3.Parent = T_1
		UIPadding_3.PaddingLeft = UDim.new(0,13)
		UIPadding_3.PaddingRight = UDim.new(0,70)

		TextLabel_1.Parent = T_1
		TextLabel_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
		TextLabel_1.BackgroundTransparency = 1
		TextLabel_1.BorderColor3 = Color3.fromRGB(0,0,0)
		TextLabel_1.BorderSizePixel = 0
		TextLabel_1.LayoutOrder = 1
		TextLabel_1.Size = UDim2.new(1, 0,0, 14)
		TextLabel_1.Font = Enum.Font.GothamBold
		TextLabel_1.RichText = true
		TextLabel_1.Text = tostring(d)
		TextLabel_1.TextColor3 = Color3.fromRGB(255,255,255)
		TextLabel_1.TextSize = 10
		TextLabel_1.TextTransparency = 0.699999988079071
		TextLabel_1.TextWrapped = true
		TextLabel_1.TextXAlignment = Enum.TextXAlignment.Left
		TextLabel_1.Visible = false
		TextLabel_1.AutomaticSize = Enum.AutomaticSize.Y
		TextLabel_1.Name = 'Desc'

		addToTheme('Text & Icon', TextLabel_1)

		TextLabel_2.Parent = T_1
		TextLabel_2.BackgroundColor3 = Color3.fromRGB(255,255,255)
		TextLabel_2.BackgroundTransparency = 1
		TextLabel_2.BorderColor3 = Color3.fromRGB(0,0,0)
		TextLabel_2.BorderSizePixel = 0
		TextLabel_2.Size = UDim2.new(1, 0,0, 14)
		TextLabel_2.Font = Enum.Font.GothamBold
		TextLabel_2.RichText = true
		TextLabel_2.Text = tostring(t)
		TextLabel_2.TextColor3 = Color3.fromRGB(255,255,255)
		TextLabel_2.TextSize = 12
		TextLabel_2.TextWrapped = true
		TextLabel_2.TextXAlignment = Enum.TextXAlignment.Left
		TextLabel_2.AutomaticSize = Enum.AutomaticSize.Y
		TextLabel_2.Name = 'Title'

		addToTheme('Text & Icon', TextLabel_2)

		if d and d ~= "" then
			TextLabel_1.Visible = true
		end

		if i and i ~= "" then
			UIPadding_3.PaddingLeft = UDim.new(0, 50)
			local Image = Instance.new("Frame")
			local Icon_1 = Instance.new("ImageLabel")
			local Frame_1 = Instance.new("Frame")

			Image.Name = "Image"
			Image.Parent = Background
			Image.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Image.BackgroundTransparency = 1
			Image.BorderColor3 = Color3.fromRGB(0,0,0)
			Image.BorderSizePixel = 0
			Image.Size = UDim2.new(0, 40,1, 0)

			Icon_1.Name = "Icon"
			Icon_1.Parent = Image
			Icon_1.AnchorPoint = Vector2.new(0.5, 0.5)
			Icon_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Icon_1.BackgroundTransparency = 1
			Icon_1.BorderColor3 = Color3.fromRGB(0,0,0)
			Icon_1.BorderSizePixel = 0
			Icon_1.Position = UDim2.new(0.5, 0,0.5, 0)
			Icon_1.Size = UDim2.new(0, 20,0, 20)
			Icon_1.Image = gl(i).Image
			Icon_1.ImageRectSize = gl(i).ImageRectSize
			Icon_1.ImageRectOffset = gl(i).ImageRectPosition
			Icon_1.ImageTransparency = 0.7

			Frame_1.Parent = Image
			Frame_1.AnchorPoint = Vector2.new(1, 0.5)
			Frame_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Frame_1.BackgroundTransparency = 0.8999999761581421
			Frame_1.BorderColor3 = Color3.fromRGB(0,0,0)
			Frame_1.BorderSizePixel = 0
			Frame_1.Position = UDim2.new(1, 0,0.5, 0)
			Frame_1.Size = UDim2.new(0, 1,0.699999988, 0)

			addToTheme('Text & Icon', Icon_1)

			addToTheme('Text & Icon', Frame_1)
		end

		local function updateSize()
			task.defer(function()
				local newSize = UIListLayout_2.AbsoluteContentSize.Y + 21
				if RealBackground.Size.Y.Offset ~= newSize then
					RealBackground.Size = UDim2.new(1, 0, 0, newSize)
				end
			end)
		end

		delay(.1, updateSize)

		UIListLayout_2:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateSize)

		local f = {}

		function f:SetTextTransparencyTitle(vs)
			tw({v = TextLabel_2, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out", g = {TextTransparency = vs}}):Play()
			if i and i ~= "" then
				tw({v = Background.Image.Icon, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out", g = {ImageTransparency = vs}}):Play()
			end
		end

		function f:SetSizeT(vs)
			UIPadding_3.PaddingRight = UDim.new(0, vs)
		end

		function f:SetTitle(vs)
			TextLabel_2.Text = tostring(vs)
		end

		function f:SetDesc(vs)
			TextLabel_1.Text = tostring(vs)
			if vs and vs ~= "" then
				TextLabel_1.Visible = true
			else
				TextLabel_1.Visible = false
			end
		end

		function f:SetVisibleDesc(vs)
			TextLabel_2.Visible = vs
		end

		return Background, f
	end
	function addDropdownSelect(p, p2, Multi, Callback, Value, List)
		local F = Instance.new("Frame")
		local UIListLayout_1 = Instance.new("UIListLayout")
		local UIPadding_1 = Instance.new("UIPadding")
		local DropdownValue = Instance.new("Frame")
		local UICorner_1 = Instance.new("UICorner")
		local UIStroke_1 = Instance.new("UIStroke")
		local TextLabelValue_1 = Instance.new("TextLabel")
		local UIPadding_2 = Instance.new("UIPadding")
		local ImageLabel_1 = Instance.new("ImageLabel")

		F.Name = "F"
		F.Parent = p
		F.AnchorPoint = Vector2.new(1, 0.5)
		F.BackgroundColor3 = Color3.fromRGB(255,255,255)
		F.BackgroundTransparency = 1
		F.BorderColor3 = Color3.fromRGB(0,0,0)
		F.BorderSizePixel = 0
		F.Position = UDim2.new(1, 0,0.5, 0)
		F.Size = UDim2.new(0, 120,0.800000012, 0)

		UIListLayout_1.Parent = F
		UIListLayout_1.Padding = UDim.new(0,15)
		UIListLayout_1.FillDirection = Enum.FillDirection.Horizontal
		UIListLayout_1.HorizontalAlignment = Enum.HorizontalAlignment.Right
		UIListLayout_1.SortOrder = Enum.SortOrder.LayoutOrder
		UIListLayout_1.VerticalAlignment = Enum.VerticalAlignment.Center

		UIPadding_1.Parent = F
		UIPadding_1.PaddingRight = UDim.new(0,13)

		DropdownValue.Parent = F
		DropdownValue.BackgroundColor3 = Color3.fromRGB(10,12,26)
		DropdownValue.BorderColor3 = Color3.fromRGB(0,0,0)
		DropdownValue.BorderSizePixel = 0
		DropdownValue.Size = UDim2.new(0, 100,0, 20)

		addToTheme('Function.Dropdown.Value Background', DropdownValue)

		UICorner_1.Parent = DropdownValue
		UICorner_1.CornerRadius = UDim.new(0,4)

		UIStroke_1.Parent = DropdownValue
		UIStroke_1.Color = Color3.fromRGB(255,255,255)
		UIStroke_1.Thickness = 1
		UIStroke_1.Transparency = 0.95

		addToTheme('Function.Dropdown.Value Stroke', UIStroke_1)

		TextLabelValue_1.Parent = DropdownValue
		TextLabelValue_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
		TextLabelValue_1.BackgroundTransparency = 1
		TextLabelValue_1.BorderColor3 = Color3.fromRGB(0,0,0)
		TextLabelValue_1.BorderSizePixel = 0
		TextLabelValue_1.Size = UDim2.new(0.8, 0,1, 0)
		TextLabelValue_1.Font = Enum.Font.GothamBold
		TextLabelValue_1.RichText = true
		TextLabelValue_1.Text = "--"
		TextLabelValue_1.TextColor3 = Color3.fromRGB(255,255,255)
		TextLabelValue_1.TextSize = 10
		TextLabelValue_1.TextTransparency = 0.3
		TextLabelValue_1.TextXAlignment = Enum.TextXAlignment.Left
		TextLabelValue_1.TextTruncate = Enum.TextTruncate.AtEnd

		addToTheme('Text & Icon', TextLabelValue_1)

		UIPadding_2.Parent = DropdownValue
		UIPadding_2.PaddingLeft = UDim.new(0,5)
		UIPadding_2.PaddingRight = UDim.new(0,5)

		ImageLabel_1.Parent = DropdownValue
		ImageLabel_1.AnchorPoint = Vector2.new(1, 0.5)
		ImageLabel_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
		ImageLabel_1.BackgroundTransparency = 1
		ImageLabel_1.BorderColor3 = Color3.fromRGB(0,0,0)
		ImageLabel_1.BorderSizePixel = 0
		ImageLabel_1.Position = UDim2.new(1, 0,0.5, 0)
		ImageLabel_1.Size = UDim2.new(0, 20,0, 20)
		ImageLabel_1.Image = "rbxassetid://14937709869"
		ImageLabel_1.ImageTransparency = 0.3

		addToTheme('Text & Icon', ImageLabel_1)

		local DropdownSelect = Instance.new("Frame")
		local UICorner_1 = Instance.new("UICorner")
		local UIStrokeDropdown_1 = Instance.new("UIStroke")
		local UIPadding_1 = Instance.new("UIPadding")
		local Search_1 = Instance.new("Frame")
		local UICorner_2 = Instance.new("UICorner")
		local TextBox_1 = Instance.new("TextBox")
		local Frame_1 = Instance.new("Frame")
		local Frame_2 = Instance.new("Frame")
		local Frame_3 = Instance.new("Frame")
		local UICorner_3 = Instance.new("UICorner")
		local ScrollingFrame_1 = Instance.new("ScrollingFrame")
		local UIListLayout_1 = Instance.new("UIListLayout")
		local UIPadding_2 = Instance.new("UIPadding")
		local UIPadding_3 = Instance.new("UIPadding")
		local UIPadding_4 = Instance.new("UIPadding")

		DropdownSelect.Parent = ScreenGui
		DropdownSelect.BackgroundColor3 = Color3.fromRGB(10,12,26)
		DropdownSelect.BorderColor3 = Color3.fromRGB(0,0,0)
		DropdownSelect.BorderSizePixel = 0
		DropdownSelect.Size = UDim2.new(0, 150,0, 0)
		DropdownSelect.ClipsDescendants = true

		addToTheme('Function.Dropdown.Dropdown Select.Background', DropdownSelect)

		DropdownSelect.Position = UDim2.new(0, DropdownValue.AbsolutePosition.X - DropdownSelect.Parent.AbsolutePosition.X + DropdownValue.Size.X.Offset - 119, 0, DropdownValue.AbsolutePosition.Y - DropdownSelect.Parent.AbsolutePosition.Y + DropdownValue.Size.Y.Offset - 25)

		UICorner_1.Parent = DropdownSelect
		UICorner_1.CornerRadius = UDim.new(0,4)

		UIStrokeDropdown_1.Parent = DropdownSelect
		UIStrokeDropdown_1.Color = Color3.fromRGB(255,255,255)
		UIStrokeDropdown_1.Thickness = 1
		UIStrokeDropdown_1.Transparency = 1

		UIPadding_1.Parent = DropdownSelect
		UIPadding_1.PaddingBottom = UDim.new(0,5)
		UIPadding_1.PaddingLeft = UDim.new(0,5)
		UIPadding_1.PaddingRight = UDim.new(0,5)
		UIPadding_1.PaddingTop = UDim.new(0,5)

		Search_1.Name = "Search"
		Search_1.Parent = DropdownSelect
		Search_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
		Search_1.BackgroundTransparency = 0.949999988079071
		Search_1.BorderColor3 = Color3.fromRGB(0,0,0)
		Search_1.BorderSizePixel = 0
		Search_1.Size = UDim2.new(1, 0,0, 20)

		addToTheme('Function.Dropdown.Dropdown Select.Search', Search_1)

		UICorner_2.Parent = Search_1
		UICorner_2.CornerRadius = UDim.new(0,4)

		TextBox_1.Parent = Search_1
		TextBox_1.Active = true
		TextBox_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
		TextBox_1.BackgroundTransparency = 1
		TextBox_1.BorderColor3 = Color3.fromRGB(0,0,0)
		TextBox_1.BorderSizePixel = 0
		TextBox_1.CursorPosition = -1
		TextBox_1.Size = UDim2.new(1, 0,1, 0)
		TextBox_1.Font = Enum.Font.Gotham
		TextBox_1.PlaceholderColor3 = Color3.fromRGB(178,178,178)
		TextBox_1.PlaceholderText = "Search . . ."
		TextBox_1.Text = ""
		TextBox_1.TextColor3 = Color3.fromRGB(255,255,255)
		TextBox_1.TextSize = 11

		addToTheme('Text & Icon', Search_1)

		addToTheme('Text & Icon', TextBox_1)

		Frame_1.Parent = Search_1
		Frame_1.AnchorPoint = Vector2.new(0, 1)
		Frame_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
		Frame_1.BackgroundTransparency = 0.8999999761581421
		Frame_1.BorderColor3 = Color3.fromRGB(0,0,0)
		Frame_1.BorderSizePixel = 0
		Frame_1.Position = UDim2.new(0, 0,1, 0)
		Frame_1.Size = UDim2.new(1, 0,0, 2)

		Frame_2.Parent = DropdownSelect
		Frame_2.BackgroundColor3 = Color3.fromRGB(255,255,255)
		Frame_2.BackgroundTransparency = 1
		Frame_2.BorderColor3 = Color3.fromRGB(0,0,0)
		Frame_2.BorderSizePixel = 0
		Frame_2.Size = UDim2.new(1, 0,1, 0)

		Frame_3.Parent = Frame_2
		Frame_3.BackgroundColor3 = Color3.fromRGB(255,255,255)
		Frame_3.BackgroundTransparency = 0.949999988079071
		Frame_3.BorderColor3 = Color3.fromRGB(0,0,0)
		Frame_3.BorderSizePixel = 0
		Frame_3.Size = UDim2.new(1, 0,1, 0)

		UICorner_3.Parent = Frame_3
		UICorner_3.CornerRadius = UDim.new(0,4)

		ScrollingFrame_1.Name = "ScrollingFrame"
		ScrollingFrame_1.Parent = Frame_3
		ScrollingFrame_1.Active = true
		ScrollingFrame_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
		ScrollingFrame_1.BackgroundTransparency = 1
		ScrollingFrame_1.BorderColor3 = Color3.fromRGB(0,0,0)
		ScrollingFrame_1.BorderSizePixel = 0
		ScrollingFrame_1.Size = UDim2.new(1, 0,1, 0)
		ScrollingFrame_1.ClipsDescendants = true
		ScrollingFrame_1.AutomaticCanvasSize = Enum.AutomaticSize.None
		ScrollingFrame_1.BottomImage = "rbxasset://textures/ui/Scroll/scroll-bottom.png"
		ScrollingFrame_1.CanvasPosition = Vector2.new(0, 0)
		ScrollingFrame_1.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
		ScrollingFrame_1.HorizontalScrollBarInset = Enum.ScrollBarInset.None
		ScrollingFrame_1.MidImage = "rbxasset://textures/ui/Scroll/scroll-middle.png"
		ScrollingFrame_1.ScrollBarImageColor3 = Color3.fromRGB(72,104,214)
		ScrollingFrame_1.ScrollBarImageTransparency = 0
		ScrollingFrame_1.ScrollBarThickness = 2
		ScrollingFrame_1.ScrollingDirection = Enum.ScrollingDirection.XY
		ScrollingFrame_1.TopImage = "rbxasset://textures/ui/Scroll/scroll-top.png"
		ScrollingFrame_1.VerticalScrollBarInset = Enum.ScrollBarInset.None
		ScrollingFrame_1.VerticalScrollBarPosition = Enum.VerticalScrollBarPosition.Right

		addToTheme('Main', ScrollingFrame_1)

		UIListLayout_1.Parent = ScrollingFrame_1
		UIListLayout_1.SortOrder = Enum.SortOrder.LayoutOrder
		UIListLayout_1.Padding = UDim.new(0, 3)

		UIPadding_2.Parent = ScrollingFrame_1
		UIPadding_2.PaddingRight = UDim.new(0,5)

		UIPadding_3.Parent = Frame_3
		UIPadding_3.PaddingBottom = UDim.new(0,5)
		UIPadding_3.PaddingLeft = UDim.new(0,5)
		UIPadding_3.PaddingRight = UDim.new(0,3)
		UIPadding_3.PaddingTop = UDim.new(0,5)

		UIPadding_4.Parent = Frame_2
		UIPadding_4.PaddingTop = UDim.new(0,25)

		local Click = click(p2)

		local isopen = false

		local function updateDropdownSize()
			if not isopen then return end

			local visibleCount = 0
			for i, v in pairs(ScrollingFrame_1:GetChildren()) do
				if v:IsA("Frame") and v.Visible then
					visibleCount = visibleCount + 1
				end
			end

			local contentHeight = (UIListLayout_1.AbsoluteContentSize.Y + 54)
			if contentHeight > 200 then
				contentHeight = 200
			end

			tw({v = DropdownSelect, t = 0.15, s = Enum.EasingStyle.Exponential, d = "Out", g = {Size = UDim2.new(0, 150, 0, contentHeight)}}):Play()
		end

		TextBox_1:GetPropertyChangedSignal("Text"):Connect(function()
			local SearchT = string.lower(TextBox_1.Text)
			for _, v in pairs(ScrollingFrame_1:GetChildren()) do
				if v:IsA("Frame") and v:FindFirstChild("TextLabel") then
					v.Visible = SearchT == "" or string.find(string.lower(v.TextLabel.Text), SearchT, 1, true) ~= nil
				end
			end
			updateDropdownSize()
		end)

		local close

		local function open()
			if isopen then
				return
			end
			closePopups(close)
			DropdownSelect.Visible = true
			local targetX = DropdownValue.AbsolutePosition.X - DropdownSelect.Parent.AbsolutePosition.X + DropdownValue.Size.X.Offset - 119
			local targetY = DropdownValue.AbsolutePosition.Y - DropdownSelect.Parent.AbsolutePosition.Y + DropdownValue.Size.Y.Offset - 25
			local contentHeight = math.min(UIListLayout_1.AbsoluteContentSize.Y + 54, 200)
			tw({v = DropdownSelect, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out", g = {Size = UDim2.new(0, 150, 0, contentHeight), Position = UDim2.new(0, targetX, 0, targetY)}}):Play()
			tw({v = UIStrokeDropdown_1, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out", g = {Transparency = 0.95}}):Play()
			isopen = true
		end

		close = function()
			if not isopen then
				return
			end
			isopen = false
			tw({v = UIStrokeDropdown_1, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out", g = {Transparency = 1}}):Play()
			local gf = tw({v = DropdownSelect, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out", g = {Size = UDim2.new(0, 150,0, 0)}})
			gf:Play()
			gf.Completed:Connect(function()
				if not isopen then
					DropdownSelect.Visible = false
				end
			end)
		end
		registerPopup(close)

		local Mouse = LocalPlayer:GetMouse()
		U.InputBegan:Connect(function(A)
			if A.UserInputType == Enum.UserInputType.MouseButton1 or A.UserInputType == Enum.UserInputType.Touch then
				local B, C = DropdownSelect.AbsolutePosition, DropdownSelect.AbsoluteSize
				if Mouse.X < B.X or Mouse.X > B.X + C.X or Mouse.Y < (B.Y - 20 - 1) or Mouse.Y > B.Y + C.Y then
					close()
				end
			end
		end)

		Click.MouseButton1Click:Connect(function()
			if not isopen then
				open()
			else
				close()
			end
		end)

		local itemslist = {}
		local selectedValues = {} -- multi: set of selected option names
		local order = {} -- multi: selection order, so callbacks get a stable list
		local touched = false
		local itemCount = 0

		local function eachItem(fn)
			for _, v in ipairs(ScrollingFrame_1:GetChildren()) do
				if v:IsA("Frame") and v:GetAttribute("Option") ~= nil then
					fn(v, v:GetAttribute("Option"))
				end
			end
		end

		local function isSelected(name)
			if Multi then
				return selectedValues[name] == true
			end
			return Value == name
		end

		local function paint()
			eachItem(function(v, name)
				tw({v = v.TextLabel, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out", g = {TextTransparency = isSelected(name) and 0 or 0.8}}):Play()
			end)
		end

		local function selectedList()
			local list = {}
			for _, name in ipairs(order) do
				if selectedValues[name] then
					table.insert(list, name)
				end
			end
			return list
		end

		local function refreshLabel()
			if Multi then
				local list = selectedList()
				TextLabelValue_1.Text = #list > 0 and table.concat(list, ", ") or "--"
			else
				TextLabelValue_1.Text = Value ~= nil and tostring(Value) or "--"
			end
		end

		local function fire()
			if Multi then
				safeCall(Callback, selectedList())
			else
				safeCall(Callback, Value)
			end
		end

		local function setMulti(list)
			selectedValues, order = {}, {}
			for k, v in pairs(list) do
				-- accepts { "A", "B" } and { A = true, B = true }
				local name = (type(k) ~= "number" and v == true) and k or v
				if name ~= nil and not selectedValues[name] then
					selectedValues[name] = true
					table.insert(order, name)
				end
			end
		end

		function itemslist:Get()
			if Multi then
				return selectedList()
			end
			return Value
		end

		function itemslist:GetOptions()
			local list = {}
			eachItem(function(v, name)
				table.insert(list, { name, v.LayoutOrder })
			end)
			table.sort(list, function(a, b)
				return a[2] < b[2]
			end)
			for i, entry in ipairs(list) do
				list[i] = entry[1]
			end
			return list
		end

		function itemslist:SetValue(value, silent)
			touched = true
			if Multi then
				if type(value) == "table" then
					setMulti(value)
				else
					setMulti(value ~= nil and { value } or {})
				end
			else
				if type(value) == "table" then
					value = value[1]
				end
				Value = value
			end
			refreshLabel()
			paint()
			if not silent then
				fire()
			end
		end

		-- Removes options. No argument removes all of them. Never fires the callback.
		function itemslist:Clear(a)
			eachItem(function(v, name)
				if a == nil or name == a or (type(a) == "table" and table.find(a, name)) then
					if Multi then
						selectedValues[name] = nil
					elseif Value == name then
						Value = nil
					end
					v:Destroy()
				end
			end)
			refreshLabel()
			updateDropdownSize()
		end

		function itemslist:Add(text)
			itemCount = itemCount + 1

			local Item_1 = Instance.new("Frame")
			local TextLabel_1 = Instance.new("TextLabel")

			Item_1.Name = "Item"
			Item_1.Parent = ScrollingFrame_1
			Item_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Item_1.BackgroundTransparency = 0.95
			Item_1.BorderColor3 = Color3.fromRGB(0,0,0)
			Item_1.BorderSizePixel = 0
			Item_1.LayoutOrder = itemCount
			Item_1.Size = UDim2.new(1, 0,0, 18)
			Item_1:SetAttribute("Option", text)

			TextLabel_1.Parent = Item_1
			TextLabel_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			TextLabel_1.BackgroundTransparency = 1
			TextLabel_1.BorderColor3 = Color3.fromRGB(0,0,0)
			TextLabel_1.BorderSizePixel = 0
			TextLabel_1.Size = UDim2.new(1, 0,1, 0)
			TextLabel_1.Font = Enum.Font.GothamBold
			TextLabel_1.Text = tostring(text)
			TextLabel_1.TextColor3 = Color3.fromRGB(255,255,255)
			TextLabel_1.TextSize = 12
			TextLabel_1.TextXAlignment = Enum.TextXAlignment.Left
			TextLabel_1.TextTruncate = Enum.TextTruncate.AtEnd
			TextLabel_1.TextTransparency = isSelected(text) and 0 or 0.8

			addToTheme('Function.Dropdown.Dropdown Select.Item Background', Item_1)
			addToTheme('Text & Icon', TextLabel_1)

			Instance.new("UICorner", Item_1).CornerRadius = UDim.new(0, 4)
			Instance.new("UIPadding", Item_1).PaddingLeft = UDim.new(0, 5)

			local ClickItem = click(Item_1)
			ClickItem.MouseButton1Click:Connect(function()
				touched = true
				if Multi then
					if selectedValues[text] then
						selectedValues[text] = nil
					else
						selectedValues[text] = true
						table.insert(order, text)
					end
				else
					Value = text
				end
				refreshLabel()
				paint()
				fire()
			end)

			updateDropdownSize()
		end

		-- Replaces the option list, keeping whatever is still selected
		function itemslist:Refresh(list)
			eachItem(function(v)
				v:Destroy()
			end)
			itemCount = 0
			local present = {}
			for _, name in ipairs(list or {}) do
				present[name] = true
				itemslist:Add(name)
			end
			local changed = false
			if Multi then
				for name in pairs(selectedValues) do
					if not present[name] then
						selectedValues[name] = nil
						changed = true
					end
				end
			elseif Value ~= nil and not present[Value] then
				Value = nil
				changed = true
			end
			refreshLabel()
			paint()
			if changed then
				fire()
			end
		end

		if Multi then
			if type(Value) == "table" then
				setMulti(Value)
			elseif Value ~= nil then
				setMulti({ Value })
			end
		end

		for _, v in ipairs(List) do
			itemslist:Add(v)
		end
		refreshLabel()

		task.delay(0, function()
			if touched then
				return
			end
			if (Multi and #selectedList() > 0) or (not Multi and Value ~= nil) then
				fire()
			end
		end)

		changecanvas(ScrollingFrame_1, UIListLayout_1, 5)

		return itemslist
	end
end

function Library:Window(p)
	p = p or {}
	p.Config = p.Config or {}
	p.CloseUIButton = p.CloseUIButton or { Enabled = false, Text = "Open" }

	local Title = p.Title or 'null'
	local Desc = p.Desc or ''
	-- The title always shows the Sylex logo; p.Icon is ignored
	local Icon = 'sylex'
	local Theme = themes[p.Theme] and p.Theme or 'Dark'
	local Keybind = p.Config.Keybind or Enum.KeyCode.LeftControl
	local Size = p.Config.Size or UDim2.new(0, 530,0, 400)
	local SearchEnabled = p.Search == true
	local ScaleSetting = p.Scale or "Auto"
	local SaveState = p.SaveWindowState ~= false
	local ConfigSaving = p.ConfigSaving or {}

	if p.Debug then
		Library:SetDebug(true)
	end
	if p.Premium ~= nil then
		Library:SetPremium(p.Premium)
	end
	-- PremiumCheck = url: ask the tier server in the background; Premium elements unlock when it answers
	if type(p.PremiumCheck) == "string" then
		task.spawn(function()
			Library:CheckPremium(p.PremiumCheck)
		end)
	end

	if ConfigSaving.Folder then
		Library.ConfigFolder = tostring(ConfigSaving.Folder)
	end
	local AutoSaveName = ConfigSaving.AutoSave and (ConfigSaving.FileName or "default") or nil
	if AutoSaveName then
		local pending = false
		Library._autosave = function()
			if not Library._autosaveArmed or Library._loading or pending then
				return
			end
			pending = true
			task.delay(1, function()
				pending = false
				if not Library.Unloaded then
					Library:SaveConfig(AutoSaveName)
				end
			end)
		end
	end

	local R, HAA = false, false
	local IsTheme = Theme

	local Shadow_1 = Instance.new("ImageLabel")
	local UIPadding_1 = Instance.new("UIPadding")
	local Background_1 = Instance.new("CanvasGroup")
	local UICorner_1 = Instance.new("UICorner")
	local Page_1 = Instance.new("Frame")
	local UIPadding_2 = Instance.new("UIPadding")

	Shadow_1.Name = "Shadow"
	Shadow_1.Parent = ScreenGui
	Shadow_1.AnchorPoint = Vector2.new(0.5, 0.5)
	Shadow_1.BackgroundColor3 = Color3.fromRGB(163,162,165)
	Shadow_1.BackgroundTransparency = 1
	Shadow_1.Position = UDim2.new(0.5, 0,0.5, 0)
	Shadow_1.Size = Size
	Shadow_1.Image = "rbxassetid://1316045217"
	Shadow_1.ImageColor3 = themes[Theme].Shadow
	Shadow_1.ImageTransparency = 0.8
	Shadow_1.ScaleType = Enum.ScaleType.Slice
	Shadow_1.SliceCenter = Rect.new(10, 10, 118, 118)
	Shadow_1.Visible = false

	addToTheme('Shadow', Shadow_1)

	-- Scale the window down on small screens (phones); "Auto", or a fixed number like 0.8
	local WindowScale = Instance.new("UIScale")
	WindowScale.Parent = Shadow_1
	local function updateScale()
		if type(ScaleSetting) == "number" then
			WindowScale.Scale = ScaleSetting
			return
		end
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		local viewport = camera.ViewportSize
		local w = Shadow_1.Size.X.Offset > 0 and Shadow_1.Size.X.Offset or 530
		local h = Shadow_1.Size.Y.Offset > 0 and Shadow_1.Size.Y.Offset or 400
		WindowScale.Scale = math.clamp(math.min((viewport.X - 20) / w, (viewport.Y - 20) / h), 0.55, 1)
	end
	updateScale()
	if workspace.CurrentCamera then
		track(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale))
	end

	UIPadding_1.Parent = Shadow_1
	UIPadding_1.PaddingBottom = UDim.new(0,8)
	UIPadding_1.PaddingLeft = UDim.new(0,8)
	UIPadding_1.PaddingRight = UDim.new(0,8)
	UIPadding_1.PaddingTop = UDim.new(0,8)

	Background_1.Name = "Background"
	Background_1.Parent = Shadow_1
	Background_1.AnchorPoint = Vector2.new(0.5, 0.5)
	Background_1.BackgroundColor3 = themes[Theme].Background
	Background_1.BorderColor3 = Color3.fromRGB(0,0,0)
	Background_1.BorderSizePixel = 0
	Background_1.Position = UDim2.new(0.5, 0,0.5, 0)
	Background_1.Size = UDim2.new(1, 0,1, 0)
	Background_1.ClipsDescendants = true
	Background_1.GroupTransparency = 1

	Shadow_1.Visible = true
	local org = Background_1.Size
	Background_1.Size = org - UDim2.fromOffset(5, 5)
	tw({
		v = Background_1,
		t = 0.15,
		s = Enum.EasingStyle.Linear,
		d = "InOut",
		g = {
			GroupTransparency = 0,
			Size = org
		}
	}):Play()

	addToTheme('Background', Background_1)

	UICorner_1.Parent = Background_1
	UICorner_1.CornerRadius = UDim.new(0,17)

	local Gradient_1 = Instance.new("Frame")
	local GradientCorner_1 = Instance.new("UICorner")
	local UIGradientBackground_1 = Instance.new("UIGradient")

	Gradient_1.Name = "Gradient"
	Gradient_1.Parent = Background_1
	Gradient_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
	Gradient_1.BorderSizePixel = 0
	Gradient_1.Size = UDim2.new(1, 0,1, 0)
	Gradient_1.ZIndex = 0

	GradientCorner_1.Parent = Gradient_1
	GradientCorner_1.CornerRadius = UDim.new(0,17)

	UIGradientBackground_1.Parent = Gradient_1
	UIGradientBackground_1.Rotation = 90
	UIGradientBackground_1.Color = themes[Theme]['Background Gradient']

	addToTheme('Background Gradient', UIGradientBackground_1)

	Page_1.Name = "Page"
	Page_1.Parent = Background_1
	Page_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
	Page_1.BackgroundTransparency = 1
	Page_1.BorderColor3 = Color3.fromRGB(0,0,0)
	Page_1.BorderSizePixel = 0
	Page_1.Size = UDim2.new(1, 0,1, 0)

	UIPadding_2.Parent = Page_1
	UIPadding_2.PaddingBottom = UDim.new(0,5)
	UIPadding_2.PaddingLeft = UDim.new(0,120)
	UIPadding_2.PaddingRight = UDim.new(0,5)
	UIPadding_2.PaddingTop = UDim.new(0,45)

	local Topbar_1 = Instance.new("Frame")
	local Frame_5 = Instance.new("Frame")
	local Ct_1 = Instance.new("Frame")
	local UIPadding_11 = Instance.new("UIPadding")
	local Minisize_1 = Instance.new("ImageButton")
	local UIListLayout_6 = Instance.new("UIListLayout")
	local Close_1 = Instance.new("ImageButton")
	local DropdownValue_1 = Instance.new("Frame")
	local Td_1 = Instance.new("Frame")
	local UIPadding_13 = Instance.new("UIPadding")
	local UIListLayout_7 = Instance.new("UIListLayout")
	local Icon_1 = Instance.new("ImageLabel")
	local Title_1 = Instance.new("Frame")
	local Desc_1 = Instance.new("TextLabel")
	local UIListLayout_8 = Instance.new("UIListLayout")
	local Title_2 = Instance.new("TextLabel")
	local ChSize_1 = Instance.new("ImageButton")

	Topbar_1.Name = "Topbar"
	Topbar_1.Parent = Background_1
	Topbar_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
	Topbar_1.BackgroundTransparency = 1
	Topbar_1.BorderColor3 = Color3.fromRGB(0,0,0)
	Topbar_1.BorderSizePixel = 0
	Topbar_1.Size = UDim2.new(1, 0,0, 42)

	Frame_5.Parent = Topbar_1
	Frame_5.AnchorPoint = Vector2.new(0, 1)
	Frame_5.BackgroundColor3 = themes[Theme].Page
	Frame_5.BorderColor3 = Color3.fromRGB(0,0,0)
	Frame_5.BorderSizePixel = 0
	Frame_5.Position = UDim2.new(0, 0,1, 0)
	Frame_5.Size = UDim2.new(1, 0,0, 2)

	addToTheme('Page', Frame_5)

	Ct_1.Name = "Ct"
	Ct_1.Parent = Topbar_1
	Ct_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
	Ct_1.BackgroundTransparency = 1
	Ct_1.BorderColor3 = Color3.fromRGB(0,0,0)
	Ct_1.BorderSizePixel = 0
	Ct_1.Size = UDim2.new(1, 0,1, 0)

	UIPadding_11.Parent = Ct_1
	UIPadding_11.PaddingBottom = UDim.new(0,5)
	UIPadding_11.PaddingLeft = UDim.new(0,10)
	UIPadding_11.PaddingRight = UDim.new(0,10)
	UIPadding_11.PaddingTop = UDim.new(0,5)

	Minisize_1.Name = "Minisize"
	Minisize_1.Parent = Ct_1
	Minisize_1.Active = true
	Minisize_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
	Minisize_1.BackgroundTransparency = 1
	Minisize_1.BorderColor3 = Color3.fromRGB(0,0,0)
	Minisize_1.BorderSizePixel = 0
	Minisize_1.LayoutOrder = 2
	Minisize_1.Size = UDim2.new(0, 16,0, 16)
	Minisize_1.Image = "rbxassetid://13857987062"
	Minisize_1.ImageTransparency = 0.5

	addToTheme('Text & Icon', Minisize_1)

	UIListLayout_6.Parent = Ct_1
	UIListLayout_6.Padding = UDim.new(0,10)
	UIListLayout_6.FillDirection = Enum.FillDirection.Horizontal
	UIListLayout_6.HorizontalAlignment = Enum.HorizontalAlignment.Right
	UIListLayout_6.SortOrder = Enum.SortOrder.LayoutOrder
	UIListLayout_6.VerticalAlignment = Enum.VerticalAlignment.Center

	Close_1.Name = "Close"
	Close_1.Parent = Ct_1
	Close_1.Active = true
	Close_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
	Close_1.BackgroundTransparency = 1
	Close_1.BorderColor3 = Color3.fromRGB(0,0,0)
	Close_1.BorderSizePixel = 0
	Close_1.LayoutOrder = 3
	Close_1.Size = UDim2.new(0, 16,0, 16)
	Close_1.Image = "rbxassetid://15082305656"

	ChSize_1.Name = "Size"
	ChSize_1.Parent = Ct_1
	ChSize_1.Active = true
	ChSize_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
	ChSize_1.BackgroundTransparency = 1
	ChSize_1.BorderColor3 = Color3.fromRGB(0,0,0)
	ChSize_1.BorderSizePixel = 0
	ChSize_1.LayoutOrder = 1
	ChSize_1.Size = UDim2.new(0, 16,0, 16)
	ChSize_1.Image = "rbxassetid://15082210525"
	ChSize_1.ImageTransparency = 0.5

	DropdownValue_1.Name = "DropdownValue"
	DropdownValue_1.Parent = Ct_1
	DropdownValue_1.AnchorPoint = Vector2.new(1, 0.5)
	DropdownValue_1.BackgroundColor3 = themes[Theme].Page
	DropdownValue_1.BorderColor3 = Color3.fromRGB(0,0,0)
	DropdownValue_1.BorderSizePixel = 0
	DropdownValue_1.Position = UDim2.new(1, 0,0.5, 0)
	DropdownValue_1.Size = UDim2.new(0, 120,0, 20)
	DropdownValue_1.Transparency = 1
	-- The theme is picked from the settings tab; this hidden dropdown still drives Window:SetTheme
	DropdownValue_1.Visible = false

	Td_1.Name = "Td"
	Td_1.Parent = Topbar_1
	Td_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
	Td_1.BackgroundTransparency = 1
	Td_1.BorderColor3 = Color3.fromRGB(0,0,0)
	Td_1.BorderSizePixel = 0
	Td_1.Size = UDim2.new(1, 0,1, 0)

	UIPadding_13.Parent = Td_1
	UIPadding_13.PaddingBottom = UDim.new(0,5)
	UIPadding_13.PaddingLeft = UDim.new(0,10)
	UIPadding_13.PaddingRight = UDim.new(0,10)
	UIPadding_13.PaddingTop = UDim.new(0,5)

	UIListLayout_7.Parent = Td_1
	UIListLayout_7.Padding = UDim.new(0,8)
	UIListLayout_7.FillDirection = Enum.FillDirection.Horizontal
	UIListLayout_7.SortOrder = Enum.SortOrder.LayoutOrder
	UIListLayout_7.VerticalAlignment = Enum.VerticalAlignment.Center

	Icon_1.Name = "Icon"
	Icon_1.Parent = Td_1
	Icon_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
	Icon_1.BackgroundTransparency = 1
	Icon_1.BorderColor3 = Color3.fromRGB(0,0,0)
	Icon_1.BorderSizePixel = 0
	Icon_1.Size = UDim2.new(0, 30,0, 30)
	-- "sylex" (the default) shows the Sylex logo; falls back to a plain icon if it can't load
	local LogoAsset = Icon == "sylex" and loadLogo() or nil
	if LogoAsset then
		Icon_1.Image = LogoAsset
		Icon_1.ScaleType = Enum.ScaleType.Fit
		Icon_1.Size = UDim2.new(0, 26,0, 26)
	else
		if Icon == "sylex" then
			Icon = 'door-open'
		end
		Icon_1.Image = gl(Icon).Image
		Icon_1.ImageRectSize = gl(Icon).ImageRectSize
		Icon_1.ImageRectOffset = gl(Icon).ImageRectPosition
	end

	addToTheme('Text & Icon', Icon_1)

	Title_1.Name = "Title"
	Title_1.Parent = Td_1
	Title_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
	Title_1.BackgroundTransparency = 4
	Title_1.BorderColor3 = Color3.fromRGB(0,0,0)
	Title_1.BorderSizePixel = 0
	Title_1.LayoutOrder = 1
	Title_1.Size = UDim2.new(0, 100,1, 0)

	Desc_1.Name = "Desc"
	Desc_1.Parent = Title_1
	Desc_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
	Desc_1.BackgroundTransparency = 1
	Desc_1.BorderColor3 = Color3.fromRGB(0,0,0)
	Desc_1.BorderSizePixel = 0
	Desc_1.LayoutOrder = 1
	Desc_1.Size = UDim2.new(1, 0,0, 13)
	Desc_1.Font = Enum.Font.GothamBold
	Desc_1.Text = Desc
	Desc_1.TextColor3 = Color3.fromRGB(255,255,255)
	Desc_1.TextSize = 10
	Desc_1.TextTransparency = 0.5
	Desc_1.TextXAlignment = Enum.TextXAlignment.Left
	Desc_1.Visible = false

	addToTheme('Text & Icon', Desc_1)

	if Desc and Desc ~= '' then
		Desc_1.Visible = true
	end

	UIListLayout_8.Parent = Title_1
	UIListLayout_8.SortOrder = Enum.SortOrder.LayoutOrder
	UIListLayout_8.VerticalAlignment = Enum.VerticalAlignment.Center

	Title_2.Name = "Title"
	Title_2.Parent = Title_1
	Title_2.BackgroundColor3 = Color3.fromRGB(255,255,255)
	Title_2.BackgroundTransparency = 1
	Title_2.BorderColor3 = Color3.fromRGB(0,0,0)
	Title_2.BorderSizePixel = 0
	Title_2.Size = UDim2.new(1, 0,0, 13)
	Title_2.Font = Enum.Font.GothamBold
	Title_2.Text = Title
	Title_2.TextColor3 = Color3.fromRGB(255,255,255)
	Title_2.TextSize = 12
	Title_2.TextXAlignment = Enum.TextXAlignment.Left

	addToTheme('Text & Icon', Title_2)

	local TabP_1 = Instance.new("Frame")
	local Frame_6 = Instance.new("Frame")
	local ScrollingFrame_2 = Instance.new("ScrollingFrame")
	local TabList_1 = Instance.new("Frame")
	local Select_1 = Instance.new("Frame")
	local UICorner_10 = Instance.new("UICorner")
	local UIStroke_3 = Instance.new("UIStroke")
	local UIPadding_16 = Instance.new("UIPadding")
	local UIPadding_17 = Instance.new("UIPadding")
	local UIListLayout_10 = Instance.new("UIListLayout")

	TabP_1.Name = "TabP"
	TabP_1.Parent = Background_1
	TabP_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
	TabP_1.BackgroundTransparency = 1
	TabP_1.BorderColor3 = Color3.fromRGB(0,0,0)
	TabP_1.BorderSizePixel = 0
	TabP_1.Size = UDim2.new(1, 0,1, 0)

	Frame_6.Parent = TabP_1
	Frame_6.BackgroundColor3 = Color3.fromRGB(255,255,255)
	Frame_6.BackgroundTransparency = 1
	Frame_6.BorderColor3 = Color3.fromRGB(0,0,0)
	Frame_6.BorderSizePixel = 0
	Frame_6.Size = UDim2.new(0, 110,1, 0)

	ScrollingFrame_2.Name = "ScrollingFrame"
	ScrollingFrame_2.Parent = Frame_6
	ScrollingFrame_2.Active = true
	ScrollingFrame_2.BackgroundColor3 = Color3.fromRGB(255,255,255)
	ScrollingFrame_2.BackgroundTransparency = 1
	ScrollingFrame_2.BorderColor3 = Color3.fromRGB(0,0,0)
	ScrollingFrame_2.BorderSizePixel = 0
	ScrollingFrame_2.Size = UDim2.new(1, 0,1, 0)
	ScrollingFrame_2.ClipsDescendants = true
	ScrollingFrame_2.AutomaticCanvasSize = Enum.AutomaticSize.None
	ScrollingFrame_2.BottomImage = "rbxasset://textures/ui/Scroll/scroll-bottom.png"
	ScrollingFrame_2.CanvasPosition = Vector2.new(0, 0)
	ScrollingFrame_2.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
	ScrollingFrame_2.HorizontalScrollBarInset = Enum.ScrollBarInset.None
	ScrollingFrame_2.MidImage = "rbxasset://textures/ui/Scroll/scroll-middle.png"
	ScrollingFrame_2.ScrollBarImageColor3 = themes[Theme].Main
	ScrollingFrame_2.ScrollBarImageTransparency = 0
	ScrollingFrame_2.ScrollBarThickness = 2
	ScrollingFrame_2.ScrollingDirection = Enum.ScrollingDirection.XY
	ScrollingFrame_2.TopImage = "rbxasset://textures/ui/Scroll/scroll-top.png"
	ScrollingFrame_2.VerticalScrollBarInset = Enum.ScrollBarInset.None
	ScrollingFrame_2.VerticalScrollBarPosition = Enum.VerticalScrollBarPosition.Right

	addToTheme('Main', ScrollingFrame_2)

	TabList_1.Name = "TabList"
	TabList_1.Parent = ScrollingFrame_2
	TabList_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
	TabList_1.BackgroundTransparency = 1
	TabList_1.BorderColor3 = Color3.fromRGB(0,0,0)
	TabList_1.BorderSizePixel = 0
	TabList_1.Size = UDim2.new(1, 0,1, 0)

	UIListLayout_10.Parent = TabList_1
	UIListLayout_10.SortOrder = Enum.SortOrder.LayoutOrder
	UIListLayout_10.HorizontalAlignment = Enum.HorizontalAlignment.Center

	Select_1.Name = "Select"
	Select_1.Parent = ScrollingFrame_2
	Select_1.BackgroundColor3 = themes[Theme].Main
	Select_1.BorderColor3 = Color3.fromRGB(0,0,0)
	Select_1.BorderSizePixel = 0
	Select_1.Position = UDim2.new(0, 0,0, 5)
	Select_1.Size = UDim2.new(0, 3,0, 18)

	addToTheme('Main', Select_1)

	UICorner_10.Parent = Select_1
	UICorner_10.CornerRadius = UDim.new(1,0)

	UIStroke_3.Parent = Select_1
	UIStroke_3.Color = themes[Theme].Page
	UIStroke_3.Thickness = 1
	UIStroke_3.Transparency = 0.9

	UIPadding_16.Parent = ScrollingFrame_2
	UIPadding_16.PaddingBottom = UDim.new(0,1)
	UIPadding_16.PaddingLeft = UDim.new(0,1)
	UIPadding_16.PaddingRight = UDim.new(0,1)
	UIPadding_16.PaddingTop = UDim.new(0,1)

	UIPadding_17.Parent = TabP_1
	UIPadding_17.PaddingBottom = UDim.new(0,5)
	UIPadding_17.PaddingLeft = UDim.new(0,3)
	UIPadding_17.PaddingTop = UDim.new(0,45)

	changecanvas(ScrollingFrame_2, UIListLayout_10, 5)

	-- Profile card at the bottom of the sidebar: avatar, display name and tier
	if p.Profile ~= false then
		ScrollingFrame_2.Size = UDim2.new(1, 0, 1, -50)

		local Card = Instance.new("Frame")
		Card.Name = "Profile"
		Card.AnchorPoint = Vector2.new(0, 1)
		Card.Position = UDim2.new(0, 2, 1, 0)
		Card.Size = UDim2.new(1, -6, 0, 44)
		Card.BackgroundColor3 = themes[Theme].Function.Label.Background
		Card.BorderSizePixel = 0
		Card.Parent = Frame_6
		Instance.new("UICorner", Card).CornerRadius = UDim.new(0, 8)
		addToTheme('Function.Label.Background', Card)

		local Avatar = Instance.new("ImageLabel")
		Avatar.Name = "Avatar"
		Avatar.AnchorPoint = Vector2.new(0, 0.5)
		Avatar.Position = UDim2.new(0, 7, 0.5, 0)
		Avatar.Size = UDim2.new(0, 28, 0, 28)
		Avatar.BackgroundColor3 = themes[Theme].Page
		Avatar.BorderSizePixel = 0
		Avatar.Image = "rbxthumb://type=AvatarHeadShot&id=" .. tostring(LocalPlayer.UserId) .. "&w=150&h=150"
		Avatar.Parent = Card
		Instance.new("UICorner", Avatar).CornerRadius = UDim.new(1, 0)
		-- background only: addToTheme would tint the headshot image itself
		onTheme(function()
			Avatar.BackgroundColor3 = themes[IsTheme].Page
		end)

		local Name = Instance.new("TextLabel")
		Name.Name = "DisplayName"
		Name.BackgroundTransparency = 1
		Name.Position = UDim2.new(0, 41, 0, 8)
		Name.Size = UDim2.new(1, -46, 0, 14)
		Name.Font = Enum.Font.GothamBold
		Name.Text = LocalPlayer.DisplayName
		Name.TextColor3 = themes[Theme]['Text & Icon']
		Name.TextSize = 11
		Name.TextXAlignment = Enum.TextXAlignment.Left
		Name.TextTruncate = Enum.TextTruncate.AtEnd
		Name.Parent = Card
		addToTheme('Text & Icon', Name)

		local Tier = Instance.new("TextLabel")
		Tier.Name = "Tier"
		Tier.BackgroundTransparency = 1
		Tier.Position = UDim2.new(0, 41, 0, 23)
		Tier.Size = UDim2.new(1, -46, 0, 12)
		Tier.Font = Enum.Font.GothamBold
		Tier.TextSize = 10
		Tier.TextXAlignment = Enum.TextXAlignment.Left
		Tier.Parent = Card

		local function updateTier()
			if Library.Premium then
				Tier.Text = "Premium"
				Tier.TextColor3 = Color3.fromRGB(255, 196, 64)
				Tier.TextTransparency = 0
			else
				Tier.Text = "Freemium"
				Tier.TextColor3 = themes[IsTheme]['Text & Icon']
				Tier.TextTransparency = 0.5
			end
		end
		table.insert(tierListeners, updateTier)
		onTheme(updateTier)
		updateTier()
	end

	local Tabs = {
		Value = false,
		List = {},
		DefaultIndex = 1
	}

	function Tabs:SelectTab(p)
		Tabs.DefaultIndex = p or 1
		-- after the window has loaded, switch straight away
		local entry = Tabs.Value and Tabs.List[Tabs.DefaultIndex]
		if entry and entry.Select then
			entry.Select()
		end
	end

	function Tabs:Line()
		local Frame = Instance.new("Frame")
		local Line = Instance.new("Frame")

		Frame.Parent = TabList_1
		Frame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		Frame.BackgroundTransparency = 1.000
		Frame.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Frame.BorderSizePixel = 0
		Frame.Size = UDim2.new(1, 0, 0, 5)
		Frame.Name = 'Line'

		Line.Name = "Line"
		Line.Parent = Frame
		Line.AnchorPoint = Vector2.new(0.5, 0.5)
		Line.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		Line.BackgroundTransparency = 0.900
		Line.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Line.BorderSizePixel = 0
		Line.Position = UDim2.new(0.5, 0, 0.5, 0)
		Line.Size = UDim2.new(0.85, 0, 0, 1)
	end

	function Tabs:Tab(p)
		p = p or {}
		local Title = p.Title or 'null'
		local Icon = p.Icon or 'house'
		local Tab_1 = Instance.new("Frame")
		local Title_3 = Instance.new("TextLabel")
		local UIListLayout_9 = Instance.new("UIListLayout")
		local ImageLabel_2 = Instance.new("ImageLabel")
		local UIPadding_14 = Instance.new("UIPadding")
		local UIStroke_2 = Instance.new("UIStroke")
		local Func = Instance.new("Frame")

		Tab_1.Name = "Tab"
		Tab_1.Parent = TabList_1
		Tab_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
		Tab_1.BackgroundTransparency = 1
		Tab_1.BorderColor3 = Color3.fromRGB(0,0,0)
		Tab_1.BorderSizePixel = 0
		Tab_1.Size = UDim2.new(1, 0,0, 30)

		Func.Name = "Func"
		Func.Parent = Tab_1
		Func.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		Func.BackgroundTransparency = 1.000
		Func.BorderColor3 = Color3.fromRGB(0, 0, 0)
		Func.BorderSizePixel = 0
		Func.Size = UDim2.new(1, 0, 1, 0)

		Title_3.Name = "Title"
		Title_3.Parent = Func
		Title_3.BackgroundColor3 = Color3.fromRGB(255,255,255)
		Title_3.BackgroundTransparency = 1
		Title_3.BorderColor3 = Color3.fromRGB(0,0,0)
		Title_3.BorderSizePixel = 0
		Title_3.LayoutOrder = 1
		Title_3.Size = UDim2.new(1, 0,1, 0)
		Title_3.Font = Enum.Font.GothamBold
		Title_3.Text = tostring(Title)
		Title_3.TextColor3 = Color3.fromRGB(255,255,255)
		Title_3.TextSize = 11
		Title_3.TextTransparency = 0.7
		Title_3.TextWrapped = true
		Title_3.TextXAlignment = Enum.TextXAlignment.Left

		addToTheme('Text & Icon', Title_3)

		UIListLayout_9.Parent = Func
		UIListLayout_9.Padding = UDim.new(0,8)
		UIListLayout_9.FillDirection = Enum.FillDirection.Horizontal
		UIListLayout_9.SortOrder = Enum.SortOrder.LayoutOrder
		UIListLayout_9.VerticalAlignment = Enum.VerticalAlignment.Center

		ImageLabel_2.Parent = Func
		ImageLabel_2.BackgroundColor3 = Color3.fromRGB(255,255,255)
		ImageLabel_2.BackgroundTransparency = 1
		ImageLabel_2.BorderColor3 = Color3.fromRGB(0,0,0)
		ImageLabel_2.BorderSizePixel = 0
		ImageLabel_2.Size = UDim2.new(0, 18,0, 18)
		ImageLabel_2.Image = gl(Icon).Image
		ImageLabel_2.ImageTransparency = 0.7
		ImageLabel_2.ImageRectSize = gl(Icon).ImageRectSize
		ImageLabel_2.ImageRectOffset = gl(Icon).ImageRectPosition

		addToTheme('Text & Icon', ImageLabel_2)

		UIPadding_14.Parent = Func
		UIPadding_14.PaddingLeft = UDim.new(0,8)

		UIStroke_2.Parent = Title_3
		UIStroke_2.Color = themes[IsTheme].Page
		UIStroke_2.Thickness = 1
		UIStroke_2.Transparency = 0.95

		local InPage_1 = Instance.new("Frame")
		local UICorner_2 = Instance.new("UICorner")
		local ScrollingFrame_1 = Instance.new("ScrollingFrame")
		local UIListLayout_1 = Instance.new("UIListLayout")
		local UIPadding_10 = Instance.new("UIPadding")

		InPage_1.Name = "InPage"
		InPage_1.Parent = Page_1
		InPage_1.AnchorPoint = Vector2.new(0.5 ,0.5)
		InPage_1.BackgroundColor3 = themes[IsTheme].Page
		InPage_1.BorderColor3 = Color3.fromRGB(0,0,0)
		InPage_1.BorderSizePixel = 0
		InPage_1.Size = UDim2.new(1, 0,1, 0)
		InPage_1.Position = UDim2.new(0.5, 0, 0.5, 0)
		InPage_1.Visible = false

		addToTheme('Page', InPage_1)

		UICorner_2.Parent = InPage_1
		UICorner_2.CornerRadius = UDim.new(0,17)

		ScrollingFrame_1.Name = "ScrollingFrame"
		ScrollingFrame_1.Parent = InPage_1
		ScrollingFrame_1.Active = true
		ScrollingFrame_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
		ScrollingFrame_1.BackgroundTransparency = 1
		ScrollingFrame_1.BorderColor3 = Color3.fromRGB(0,0,0)
		ScrollingFrame_1.BorderSizePixel = 0
		ScrollingFrame_1.Size = UDim2.new(1, 0,1, 0)
		ScrollingFrame_1.ClipsDescendants = true
		ScrollingFrame_1.AutomaticCanvasSize = Enum.AutomaticSize.None
		ScrollingFrame_1.BottomImage = "rbxasset://textures/ui/Scroll/scroll-bottom.png"
		ScrollingFrame_1.CanvasPosition = Vector2.new(0, 0)
		ScrollingFrame_1.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
		ScrollingFrame_1.HorizontalScrollBarInset = Enum.ScrollBarInset.None
		ScrollingFrame_1.MidImage = "rbxasset://textures/ui/Scroll/scroll-middle.png"
		ScrollingFrame_1.ScrollBarImageTransparency = 0
		ScrollingFrame_1.ScrollBarThickness = 0
		ScrollingFrame_1.ScrollingDirection = Enum.ScrollingDirection.XY
		ScrollingFrame_1.TopImage = "rbxasset://textures/ui/Scroll/scroll-top.png"
		ScrollingFrame_1.VerticalScrollBarInset = Enum.ScrollBarInset.None
		ScrollingFrame_1.VerticalScrollBarPosition = Enum.VerticalScrollBarPosition.Right

		UIListLayout_1.Parent = ScrollingFrame_1
		UIListLayout_1.Padding = UDim.new(0,5)
		UIListLayout_1.SortOrder = Enum.SortOrder.LayoutOrder

		UIPadding_10.Parent = InPage_1
		UIPadding_10.PaddingBottom = UDim.new(0,10)
		UIPadding_10.PaddingLeft = UDim.new(0,10)
		UIPadding_10.PaddingRight = UDim.new(0,10)
		UIPadding_10.PaddingTop = UDim.new(0,10)

		local Click = click(Tab_1)

		local listEntry = {
			Page = InPage_1,
			Button = Tab_1
		}
		table.insert(self.List, listEntry)
		local MyIndex = #self.List

		local function twSelect()
			local scrollingFrame = Select_1.Parent
			local tabScrollingFrame = Tab_1.Parent

			local tabCenterY = Tab_1.AbsolutePosition.Y + (Tab_1.AbsoluteSize.Y / 2)
			local selectOffset = Select_1.AbsoluteSize.Y / 2
			local relativeY = tabCenterY - tabScrollingFrame.AbsolutePosition.Y
			local offset = scrollingFrame.AbsolutePosition.Y - Select_1.Parent.AbsolutePosition.Y

			local targetY = relativeY + offset - selectOffset

			local pos = UDim2.new(0, Select_1.Position.X.Offset, 0, targetY)

			tw({
				v = Select_1,
				t = 0.5,
				s = Enum.EasingStyle.Exponential,
				d = "Out",
				g = {
					Position = pos
				}
			}):Play()
		end

		local function chg()
			closePopups()
			for _, v in pairs(self.List) do
				v.Page.Visible = false
			end
			InPage_1.Visible = true
			for _, v in pairs(ScrollingFrame_1:GetChildren()) do
				if v:IsA('Frame') and v:FindFirstChild('Background') then
					v.Background.Position = UDim2.new(0, 0, 0,0)
					v.Background.AnchorPoint = Vector2.new(1 ,0)
				end
			end
			task.spawn(function()
				for _, v in ipairs(ScrollingFrame_1:GetChildren()) do
					if v:IsA('Frame') and v:FindFirstChild('Background') then
						tw({
							v = v.Background,
							t = 0.3,
							s = Enum.EasingStyle.Exponential,
							d = "InOut",
							g = {AnchorPoint = Vector2.new(0 ,0)}
						}):Play()
						if v.Visible then
							task.wait(.05)
						end
					end
				end
			end)
			for i, v in pairs(TabList_1:GetChildren()) do
				if v:IsA('Frame') and v.Name ~= 'Line' then
					tw({
						v = v.Func.Title,
						t = 0.15,
						s = Enum.EasingStyle.Linear,
						d = "InOut",
						g = {TextTransparency = 0.7}
					}):Play()
					tw({
						v = v.Func.ImageLabel,
						t = 0.15,
						s = Enum.EasingStyle.Linear,
						d = "InOut",
						g = {ImageTransparency = 0.7}
					}):Play()
				end
			end
			tw({
				v = Title_3,
				t = 0.15,
				s = Enum.EasingStyle.Linear,
				d = "InOut",
				g = {TextTransparency = 0}
			}):Play()
			tw({
				v = ImageLabel_2,
				t = 0.15,
				s = Enum.EasingStyle.Linear,
				d = "InOut",
				g = {ImageTransparency = 0}
			}):Play()
			Page_1.Visible = true
			self.Current = MyIndex
			twSelect()
		end

		Click.MouseButton1Click:Connect(chg)
		listEntry.Select = chg

		changecanvas(ScrollingFrame_1, UIListLayout_1, 5)

		delay(.1, function()
			if not self.Value then
				local total = #self.List
				local index = self.DefaultIndex

				if type(index) ~= "number" or index < 1 or index > total then
					index = 1
				end

				if MyIndex == index then
					chg()
					self.Value = true
				end
			end
		end)

		--// Per-tab search box
		local SearchHolder
		if p.Search == true or (p.Search == nil and SearchEnabled) then
			local SearchBox = Instance.new("Frame")
			local SearchInput = Instance.new("TextBox")
			local SearchStroke = Instance.new("UIStroke")

			SearchHolder = Instance.new("Frame")
			SearchHolder.Name = "SylexSearch"
			SearchHolder.Parent = ScrollingFrame_1
			SearchHolder.BackgroundTransparency = 1
			SearchHolder.LayoutOrder = -1
			SearchHolder.Size = UDim2.new(1, 0, 0, 28)

			SearchBox.Parent = SearchHolder
			SearchBox.BackgroundColor3 = themes[IsTheme].Function.Textbox['Value Background']
			SearchBox.BorderSizePixel = 0
			SearchBox.Size = UDim2.new(1, 0, 1, 0)
			Instance.new("UICorner", SearchBox).CornerRadius = UDim.new(0, 6)

			addToTheme('Function.Textbox.Value Background', SearchBox)

			SearchStroke.Parent = SearchBox
			SearchStroke.Color = Color3.fromRGB(255, 255, 255)
			SearchStroke.Transparency = 0.95

			addToTheme('Function.Textbox.Value Stroke', SearchStroke)

			SearchInput.Parent = SearchBox
			SearchInput.BackgroundTransparency = 1
			SearchInput.Position = UDim2.new(0, 10, 0, 0)
			SearchInput.Size = UDim2.new(1, -20, 1, 0)
			SearchInput.ClearTextOnFocus = false
			SearchInput.Font = Enum.Font.GothamBold
			SearchInput.PlaceholderColor3 = Color3.fromRGB(150, 150, 160)
			SearchInput.PlaceholderText = "Search..."
			SearchInput.Text = ""
			SearchInput.TextColor3 = themes[IsTheme]['Text & Icon']
			SearchInput.TextSize = 11
			SearchInput.TextXAlignment = Enum.TextXAlignment.Left

			addToTheme('Text & Icon', SearchInput)

			SearchInput:GetPropertyChangedSignal("Text"):Connect(function()
				local query = string.lower(SearchInput.Text)
				local searching = query ~= ""
				for _, child in ipairs(ScrollingFrame_1:GetChildren()) do
					if child:IsA("GuiObject") and child ~= SearchHolder then
						local text = child:GetAttribute("SylexSearch")
						local filtered
						if child:GetAttribute("SylexSection") then
							filtered = searching
						else
							filtered = searching and not (text and string.find(text, query, 1, true))
						end
						child:SetAttribute("SylexSearching", searching)
						child:SetAttribute("SylexFiltered", filtered)
						applyVisibility(child)
					end
				end
			end)
		end

		--// Keep element order stable and track which section each element belongs to
		local elementIndex = 0
		local currentSection
		ScrollingFrame_1.ChildAdded:Connect(function(child)
			if not child:IsA("GuiObject") or child == SearchHolder then
				return
			end
			elementIndex = elementIndex + 1
			child.LayoutOrder = elementIndex
			if currentSection and not child:GetAttribute("SylexSection") then
				table.insert(currentSection.members, child)
				if currentSection.collapsed then
					child:SetAttribute("SylexCollapsed", true)
					applyVisibility(child)
				end
			end
		end)

		local Func = {}

		function Func:Select()
			chg()
		end

		function Func:SetTitle(t)
			Title_3.Text = tostring(t)
		end

		function Func:Section(p)
			p = p or {}
			local Title = p.Title or 'null'
			local Collapsible = p.Collapsible == true or p.Collapsed ~= nil
			local RealBackground = Instance.new("Frame")
			local Section = Instance.new("Frame")
			local Section_1 = Instance.new("TextLabel")
			local UIPadding_1 = Instance.new("UIPadding")

			local section = {
				root = RealBackground,
				members = {},
				collapsed = p.Collapsed == true,
			}

			-- mark it as a section before parenting, so ChildAdded doesn't file it under the previous section
			RealBackground:SetAttribute("SylexSection", true)
			RealBackground.Name = "Real Background"
			RealBackground.Parent = ScrollingFrame_1
			RealBackground.BackgroundTransparency = 1
			RealBackground.BorderColor3 = Color3.fromRGB(0,0,0)
			RealBackground.BorderSizePixel = 0
			RealBackground.Size = UDim2.new(1, 0,0, 20)
			RealBackground.ClipsDescendants = true

			Section.Name = "Background"
			Section.Parent = RealBackground
			Section.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Section.BackgroundTransparency = 1
			Section.BorderColor3 = Color3.fromRGB(0,0,0)
			Section.BorderSizePixel = 0
			Section.Size = UDim2.new(1, 0,0, 20)

			Section_1.Name = "Section"
			Section_1.Parent = Section
			Section_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Section_1.BackgroundTransparency = 1
			Section_1.BorderColor3 = Color3.fromRGB(0,0,0)
			Section_1.BorderSizePixel = 0
			Section_1.Size = UDim2.new(1, 0,0, 20)
			Section_1.Font = Enum.Font.GothamBold
			Section_1.Text = Title
			Section_1.TextColor3 = Color3.fromRGB(255,255,255)
			Section_1.TextSize = 12
			Section_1.TextXAlignment = Enum.TextXAlignment.Left

			addToTheme('Text & Icon', Section_1)

			UIPadding_1.Parent = Section
			UIPadding_1.PaddingLeft = UDim.new(0,5)
			UIPadding_1.PaddingRight = UDim.new(0,5)

			local New = {}

			local Arrow
			local function setCollapsed(v)
				section.collapsed = v
				for _, member in ipairs(section.members) do
					if member.Parent then
						member:SetAttribute("SylexCollapsed", v)
						applyVisibility(member)
					end
				end
				if Arrow then
					tw({v = Arrow, t = 0.15, s = Enum.EasingStyle.Quad, d = "Out", g = {Rotation = v and -90 or 0}}):Play()
				end
			end

			if Collapsible then
				Arrow = Instance.new("ImageLabel")
				Arrow.Name = "Arrow"
				Arrow.Parent = Section
				Arrow.AnchorPoint = Vector2.new(1, 0.5)
				Arrow.BackgroundTransparency = 1
				Arrow.Position = UDim2.new(1, 0, 0.5, 0)
				Arrow.Size = UDim2.new(0, 18, 0, 18)
				Arrow.Image = "rbxassetid://14937709869"
				Arrow.ImageTransparency = 0.3
				Arrow.Rotation = section.collapsed and -90 or 0

				addToTheme('Text & Icon', Arrow)

				click(Section).MouseButton1Click:Connect(function()
					setCollapsed(not section.collapsed)
				end)
			end

			currentSection = section

			function New:SetTitle(t)
				Section_1.Text = t
			end

			function New:SetCollapsed(v)
				setCollapsed(v == true)
			end

			function New:IsCollapsed()
				return section.collapsed
			end

			return attachCommon(New, RealBackground, p, "Section")
		end

		function Func:Toggle(p)
			p = p or {}
			local Value = p.Value or false
			local Image = p.Image or ''
			local Callback = p.Callback or function() end
			local Title = p.Title or 'null'
			local Desc = p.Desc or ''

			local Toggle, Config = background(ScrollingFrame_1, Title, Desc, Image, 'Toggle')

			local F_1 = Instance.new("Frame")
			local UIListLayout_1 = Instance.new("UIListLayout")
			local UIPadding_1 = Instance.new("UIPadding")
			local Frame_1 = Instance.new("Frame")
			local UICorner_2 = Instance.new("UICorner")
			local Frame_2 = Instance.new("Frame")
			local UICorner_3 = Instance.new("UICorner")
			local UIPadding_2 = Instance.new("UIPadding")

			F_1.Name = "F"
			F_1.Parent = Toggle
			F_1.AnchorPoint = Vector2.new(1, 0.5)
			F_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			F_1.BackgroundTransparency = 1
			F_1.BorderColor3 = Color3.fromRGB(0,0,0)
			F_1.BorderSizePixel = 0
			F_1.Position = UDim2.new(1, 0,0.5, 0)
			F_1.Size = UDim2.new(0, 100,0.800000012, 0)

			UIListLayout_1.Parent = F_1
			UIListLayout_1.HorizontalAlignment = Enum.HorizontalAlignment.Right
			UIListLayout_1.SortOrder = Enum.SortOrder.LayoutOrder
			UIListLayout_1.VerticalAlignment = Enum.VerticalAlignment.Center

			UIPadding_1.Parent = F_1
			UIPadding_1.PaddingRight = UDim.new(0,13)

			Frame_1.Parent = F_1
			Frame_1.BackgroundColor3 = themes[IsTheme].Function.Toggle.False['Toggle Background']
			Frame_1.BorderColor3 = Color3.fromRGB(0,0,0)
			Frame_1.BorderSizePixel = 0
			Frame_1.Size = UDim2.new(0, 34,0, 17)

			UICorner_2.Parent = Frame_1
			UICorner_2.CornerRadius = UDim.new(1,0)

			Frame_2.Parent = Frame_1
			Frame_2.AnchorPoint = Vector2.new(0, 0.5)
			Frame_2.BackgroundColor3 = themes[IsTheme].Function.Toggle.False['Toggle Value']
			Frame_2.BorderColor3 = Color3.fromRGB(0,0,0)
			Frame_2.BorderSizePixel = 0
			Frame_2.Position = UDim2.new(0, 0,0.5, 0)
			Frame_2.Size = UDim2.new(0, 13,0, 13)

			if Value then
				Frame_1.BackgroundColor3 = themes[IsTheme].Function.Toggle.True['Toggle Background']
				Frame_2.BackgroundColor3 = themes[IsTheme].Function.Toggle.True['Toggle Value']
			else
				Frame_1.BackgroundColor3 = themes[IsTheme].Function.Toggle.False['Toggle Background']
				Frame_2.BackgroundColor3 = themes[IsTheme].Function.Toggle.False['Toggle Value']
			end

			UICorner_3.Parent = Frame_2
			UICorner_3.CornerRadius = UDim.new(1,0)

			UIPadding_2.Parent = Frame_1
			UIPadding_2.PaddingLeft = UDim.new(0,2)
			UIPadding_2.PaddingRight = UDim.new(0,2)

			local Click = click(Toggle)
			local initialized = false

			local function set(v, silent)
				initialized = true
				Value = v == true
				if Value then
					Config:SetTextTransparencyTitle(0)
					tw({v = Frame_1, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out", g = {BackgroundColor3 = themes[IsTheme].Function.Toggle.True['Toggle Background']}}):Play()
					tw({v = Frame_2, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out",
						g = {
							BackgroundColor3 = themes[IsTheme].Function.Toggle.True['Toggle Value'],
							AnchorPoint = Vector2.new(1, 0.5),
							Position = UDim2.new(1, 0,0.5, 0)
						}}):Play()
				else
					Config:SetTextTransparencyTitle(0.7)
					tw({v = Frame_1, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out", g = {BackgroundColor3 = themes[IsTheme].Function.Toggle.False['Toggle Background']}}):Play()
					tw({v = Frame_2, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out",
						g = {
							BackgroundColor3 = themes[IsTheme].Function.Toggle.False['Toggle Value'],
							AnchorPoint = Vector2.new(0, 0.5),
							Position = UDim2.new(0, 0,0.5, 0)
						}}):Play()
				end
				setFlag(p.Flag, Value)
				if not silent then
					safeCall(Callback, Value)
				end
			end

			onTheme(function()
				local state = Value and 'True' or 'False'
				Frame_1.BackgroundColor3 = themes[IsTheme].Function.Toggle[state]['Toggle Background']
				Frame_2.BackgroundColor3 = themes[IsTheme].Function.Toggle[state]['Toggle Value']
			end)

			Click.MouseButton1Click:Connect(function()
				set(not Value)
			end)

			-- fire once with the starting value, unless something already set it (e.g. LoadConfig)
			delay(0.1, function()
				if not initialized then
					set(Value)
				end
			end)

			local New = {}

			function New:SetTitle(t)
				Config:SetTitle(t)
			end

			function New:SetDesc(t)
				Config:SetDesc(t)
			end

			function New:SetValue(t, silent)
				set(t, silent)
			end

			function New:Get()
				return Value
			end

			return attachCommon(New, Toggle.Parent, p, "Toggle")
		end

		function Func:Label(p)
			p = p or {}
			local Title = p.Title or 'null'
			local Desc = p.Desc or ''
			local Image = p.Image or ''

			local Label, Config = background(ScrollingFrame_1, Title, Desc, Image, 'Label')

			Config:SetTextTransparencyTitle(0)
			Config:SetSizeT(0)

			local New = {}

			function New:SetTitle(t)
				Config:SetTitle(t)
			end

			function New:SetDesc(t)
				Config:SetDesc(t)
			end

			return attachCommon(New, Label.Parent, p, "Label")
		end

		function Func:Paragraph(p)
			p = p or {}
			local Paragraph = Func:Label({
				Title = p.Title,
				Desc = p.Content or p.Desc or '',
				Image = p.Image,
				Tooltip = p.Tooltip,
			})
			Paragraph.Type = "Paragraph"
			function Paragraph:SetContent(t)
				Paragraph:SetDesc(t)
			end
			return Paragraph
		end

		function Func:Button(p)
			p = p or {}
			local Title = p.Title or 'null'
			local Desc = p.Desc or ''
			local Image = p.Image or ''
			local Callback = p.Callback or function() end


			local Button, Config = background(ScrollingFrame_1, Title, Desc, Image, 'Button')

			Config:SetTextTransparencyTitle(0)
			Config:SetSizeT(50)

			Button.ClipsDescendants = true

			local F = Instance.new("Frame")
			local UIListLayout_1 = Instance.new("UIListLayout")
			local UIPadding_1 = Instance.new("UIPadding")
			local Image_1 = Instance.new("ImageLabel")

			F.Name = "F"
			F.Parent = Button
			F.AnchorPoint = Vector2.new(1, 0.5)
			F.BackgroundColor3 = Color3.fromRGB(255,255,255)
			F.BackgroundTransparency = 1
			F.BorderColor3 = Color3.fromRGB(0,0,0)
			F.BorderSizePixel = 0
			F.Position = UDim2.new(1, 0,0.5, 0)
			F.Size = UDim2.new(0, 50,0.800000012, 0)

			UIListLayout_1.Parent = F
			UIListLayout_1.Padding = UDim.new(0,8)
			UIListLayout_1.FillDirection = Enum.FillDirection.Horizontal
			UIListLayout_1.HorizontalAlignment = Enum.HorizontalAlignment.Right
			UIListLayout_1.SortOrder = Enum.SortOrder.LayoutOrder
			UIListLayout_1.VerticalAlignment = Enum.VerticalAlignment.Center

			UIPadding_1.Parent = F
			UIPadding_1.PaddingRight = UDim.new(0,13)

			Image_1.Name = "Image"
			Image_1.Parent = F
			Image_1.AnchorPoint = Vector2.new(1, 0.5)
			Image_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Image_1.BackgroundTransparency = 1
			Image_1.BorderColor3 = Color3.fromRGB(0,0,0)
			Image_1.BorderSizePixel = 0
			Image_1.Position = UDim2.new(1, 0,0.5, 0)
			Image_1.Size = UDim2.new(0, 20,0, 20)
			Image_1.Image = "rbxassetid://14923748517"
			Image_1.ImageTransparency = 0.3

			local Click = click(Button)
			Click.MouseButton1Click:Connect(function()
				Button.AnchorPoint = Vector2.new(0.5, 0.5)
				Button.Position = UDim2.new(0.5, 0, 0.5,0)
				jc(Click, Button)
				tw({v = Button, t = 0.15, s = Enum.EasingStyle.Back, d = "Out", g = {Size = UDim2.new(.9, 0,.9, 0)}}):Play()
				delay(.06, function()
					tw({v = Button, t = 0.15, s = Enum.EasingStyle.Back, d = "Out", g = {Size = UDim2.new(1, 0,1, 0)}}):Play()
				end)
				safeCall(Callback)
			end)

			local New = {}

			function New:SetTitle(t)
				Config:SetTitle(t)
			end

			function New:SetDesc(t)
				Config:SetDesc(t)
			end

			function New:SetCallback(fn)
				Callback = fn or function() end
			end

			function New:Fire()
				safeCall(Callback)
			end

			return attachCommon(New, Button.Parent, p, "Button")
		end

		function Func:Slider(p)
			p = p or {}
			local Title = p.Title or 'null'
			local Desc = p.Desc or ''
			local Image = p.Image or ''
			local Min = p.Min or 0
			local Max = p.Max or 100
			local Value = p.Value or Min
			local Suffix = p.Suffix and (" " .. tostring(p.Suffix)) or ""
			local Rounding = p.Rounding or 2
			local Callback = p.Callback or function() end

			local Slider, Config = background(ScrollingFrame_1, Title, Desc, Image, 'Slider')

			Config:SetTextTransparencyTitle(0)
			Config:SetSizeT(200)

			local F = Instance.new("Frame")
			local UIListLayout_1 = Instance.new("UIListLayout")
			local UIPadding_1 = Instance.new("UIPadding")
			local FrameValueTextBox = Instance.new('Frame')
			local TextBox_1 = Instance.new("TextBox")
			local UICorner_1 = Instance.new("UICorner")
			local UIStroke_1 = Instance.new("UIStroke")
			local Frame_1 = Instance.new("Frame")
			local Frame_2 = Instance.new("Frame")
			local UICorner_2 = Instance.new("UICorner")
			local Frame_3 = Instance.new("Frame")
			local UICorner_3 = Instance.new("UICorner")
			local Frame_4 = Instance.new("Frame")
			local UICorner_4 = Instance.new("UICorner")
			local UIPadding_2 = Instance.new("UIPadding")

			F.Name = "F"
			F.Parent = Slider
			F.AnchorPoint = Vector2.new(1, 0.5)
			F.BackgroundColor3 = Color3.fromRGB(255,255,255)
			F.BackgroundTransparency = 1
			F.BorderColor3 = Color3.fromRGB(0,0,0)
			F.BorderSizePixel = 0
			F.Position = UDim2.new(1, 0,0.5, 0)
			F.Size = UDim2.new(0, 195,0.8, 0)

			UIListLayout_1.Parent = F
			UIListLayout_1.Padding = UDim.new(0,8)
			UIListLayout_1.FillDirection = Enum.FillDirection.Horizontal
			UIListLayout_1.HorizontalAlignment = Enum.HorizontalAlignment.Right
			UIListLayout_1.SortOrder = Enum.SortOrder.LayoutOrder
			UIListLayout_1.VerticalAlignment = Enum.VerticalAlignment.Center

			UIPadding_1.Parent = F
			UIPadding_1.PaddingRight = UDim.new(0,13)

			FrameValueTextBox.Parent = F
			FrameValueTextBox.Active = true
			FrameValueTextBox.BackgroundColor3 = themes[IsTheme].Function.Slider['Value Background']
			FrameValueTextBox.BorderColor3 = Color3.fromRGB(0,0,0)
			FrameValueTextBox.BorderSizePixel = 0
			FrameValueTextBox.Size = UDim2.new(0, 50,0, 20)
			FrameValueTextBox.LayoutOrder = 1

			addToTheme('Function.Slider.Value Background', FrameValueTextBox)

			TextBox_1.Parent = FrameValueTextBox
			TextBox_1.Active = true
			TextBox_1.BackgroundTransparency = 1
			TextBox_1.BorderColor3 = Color3.fromRGB(0,0,0)
			TextBox_1.BorderSizePixel = 0
			TextBox_1.Size = UDim2.new(1, 0,1, 0)
			TextBox_1.Font = Enum.Font.Cartoon
			TextBox_1.PlaceholderColor3 = Color3.fromRGB(178,178,178)
			TextBox_1.PlaceholderText = ""
			TextBox_1.Text = tonumber(Value)
			TextBox_1.TextColor3 = Color3.fromRGB(255,255,255)
			TextBox_1.TextSize = 12

			addToTheme('Text & Icon', TextBox_1)

			UICorner_1.Parent = FrameValueTextBox
			UICorner_1.CornerRadius = UDim.new(0,4)

			UIStroke_1.Parent = FrameValueTextBox
			UIStroke_1.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			UIStroke_1.Color = Color3.fromRGB(255,255,255)
			UIStroke_1.Thickness = 1
			UIStroke_1.Transparency = 0.95

			addToTheme('Function.Slider.Value Stroke', UIStroke_1)

			Frame_1.Parent = F
			Frame_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Frame_1.BackgroundTransparency = 1
			Frame_1.BorderColor3 = Color3.fromRGB(0,0,0)
			Frame_1.BorderSizePixel = 0
			Frame_1.Size = UDim2.new(0, 120,0, 20)

			Frame_2.Parent = Frame_1
			Frame_2.AnchorPoint = Vector2.new(0.5, 0.5)
			Frame_2.BackgroundColor3 = themes[IsTheme].Function.Slider['Slider Bar']
			Frame_2.BorderColor3 = Color3.fromRGB(0,0,0)
			Frame_2.BorderSizePixel = 0
			Frame_2.Position = UDim2.new(0.5, 0,0.5, 0)
			Frame_2.Size = UDim2.new(1, 0,0, 10)

			addToTheme('Function.Slider.Slider Bar', Frame_2)

			UICorner_2.Parent = Frame_2
			UICorner_2.CornerRadius = UDim.new(1,0)

			Frame_3.Parent = Frame_2
			Frame_3.AnchorPoint = Vector2.new(0, 0.5)
			Frame_3.BackgroundColor3 = themes[IsTheme].Function.Slider['Slider Bar Value']
			Frame_3.BorderColor3 = Color3.fromRGB(0,0,0)
			Frame_3.BorderSizePixel = 0
			Frame_3.Position = UDim2.new(0, 0,0.5, 0)
			Frame_3.Size = UDim2.new(0, 0,1, 0)

			addToTheme('Function.Slider.Slider Bar Value', Frame_3)

			UICorner_3.Parent = Frame_3
			UICorner_3.CornerRadius = UDim.new(1,0)

			Frame_4.Parent = Frame_3
			Frame_4.AnchorPoint = Vector2.new(1, 0.5)
			Frame_4.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Frame_4.BorderColor3 = Color3.fromRGB(0,0,0)
			Frame_4.BorderSizePixel = 0
			Frame_4.Position = UDim2.new(1, 0,0.5, 0)
			Frame_4.Size = UDim2.new(0, 13,0, 13)

			addToTheme('Function.Slider.Circle Value', Frame_4)

			UICorner_4.Parent = Frame_4
			UICorner_4.CornerRadius = UDim.new(1,0)

			UIPadding_2.Parent = Frame_2
			UIPadding_2.PaddingBottom = UDim.new(0,2)
			UIPadding_2.PaddingLeft = UDim.new(0,2)
			UIPadding_2.PaddingRight = UDim.new(0,2)
			UIPadding_2.PaddingTop = UDim.new(0,2)

			local Click = click(Frame_1)

			local function roundToDecimal(value, decimals)
				local factor = 10 ^ decimals
				return math.floor(value * factor + 0.5) / factor
			end

			local lastFired

			local function updateSlider(value, silent)
				value = tonumber(value) or Min
				value = math.clamp(value, Min, Max)
				value = roundToDecimal(value, Rounding)
				Value = value
				local va = Max > Min and (value - Min) / (Max - Min) or 1
				tw({v = Frame_3, t = 0.15, s = Enum.EasingStyle.Exponential, d = "Out", g = {Size = UDim2.new(math.clamp(va, 0.12, 1), 0, 1, 0)}}):Play()
				TextBox_1.Text = tostring(roundToDecimal(value, Rounding)) .. Suffix
				setFlag(p.Flag, value)
				-- dragging sends many events for the same value; only fire when it actually changes
				if not silent and value ~= lastFired then
					lastFired = value
					safeCall(Callback, value)
				end
			end

			updateSlider(Value or 0)

			TextBox_1.Focused:Connect(function()
				TextBox_1.Text = tostring(Value)
			end)

			TextBox_1.FocusLost:Connect(function()
				local value = tonumber(TextBox_1.Text) or Min
				updateSlider(value)
			end)

			local function move(input)
				local sliderBar = Frame_2
				local relativeX = math.clamp((input.Position.X - sliderBar.AbsolutePosition.X) / sliderBar.AbsoluteSize.X, 0, 1)
				local value = relativeX * (Max - Min) + Min
				updateSlider(value)
			end

			local dragging = false

			Click.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					dragging = true
					move(input)
				end
			end)

			Click.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					dragging = false
				end
			end)

			U.InputChanged:Connect(function(input)
				if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
					move(input)
				end
			end)

			local New = {}

			function New:SetTitle(t)
				Config:SetTitle(t)
			end

			function New:SetDesc(t)
				Config:SetDesc(t)
			end

			function New:SetValue(t, silent)
				updateSlider(t, silent)
			end

			function New:Get()
				return Value
			end

			function New:SetMin(t)
				Min = t
				updateSlider(math.max(Value, t))
			end

			function New:SetMax(t)
				Max = t
				updateSlider(math.min(Value, t))
			end

			return attachCommon(New, Slider.Parent, p, "Slider")
		end

		function Func:Code(p)
			p = p or {}
			local Title = p.Title or 'null'
			local CodeText = p.Code or '-- print("Hello World")'

			local RealBackground = Instance.new("Frame")
			local Code = Instance.new("Frame")
			local UICorner_1 = Instance.new("UICorner")
			local FF_1 = Instance.new("Frame")
			local UIPadding_1 = Instance.new("UIPadding")
			local F_1 = Instance.new("Frame")
			local UICorner_2 = Instance.new("UICorner")
			local Frame_1 = Instance.new("Frame")
			local UIPadding_2 = Instance.new("UIPadding")
			local Frame_2 = Instance.new("Frame")
			local UIPadding_3 = Instance.new("UIPadding")
			local TextBox_2 = Instance.new("TextLabel")
			local Top_1 = Instance.new("Frame")
			local Left_1 = Instance.new("Frame")
			local Whatisthis_1 = Instance.new("ImageLabel")
			local UIListLayout_1 = Instance.new("UIListLayout")
			local Frame_3 = Instance.new("Frame")
			local Frame_4 = Instance.new("Frame")
			local UICorner_3 = Instance.new("UICorner")
			local UIListLayout_2 = Instance.new("UIListLayout")
			local UIPadding_4 = Instance.new("UIPadding")
			local TextLabel_1 = Instance.new("TextLabel")
			local Right_1 = Instance.new("Frame")
			local UIListLayout_3 = Instance.new("UIListLayout")
			local Frame_5 = Instance.new("Frame")
			local TextButton_1 = Instance.new("TextButton")
			local UIPadding_5 = Instance.new("UIPadding")
			local ImageLabel_1 = Instance.new("ImageLabel")
			local UIGradient_1 = Instance.new("UIGradient")

			RealBackground.Name = "Real Background"
			RealBackground.Parent = ScrollingFrame_1
			RealBackground.BackgroundTransparency = 1
			RealBackground.BorderColor3 = Color3.fromRGB(0,0,0)
			RealBackground.BorderSizePixel = 0
			RealBackground.Size = UDim2.new(1, 0,0, 120)
			RealBackground.ClipsDescendants = true

			Code.Name = "Background"
			Code.Parent = RealBackground
			Code.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Code.BorderColor3 = Color3.fromRGB(0,0,0)
			Code.BorderSizePixel = 0
			Code.Size = UDim2.new(1, 0,1, 0)
			Code.ClipsDescendants = true

			UICorner_1.Parent = Code

			FF_1.Name = "FF"
			FF_1.Parent = Code
			FF_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			FF_1.BackgroundTransparency = 1
			FF_1.BorderColor3 = Color3.fromRGB(0,0,0)
			FF_1.BorderSizePixel = 0
			FF_1.Size = UDim2.new(1, 0,1, 0)

			UIPadding_1.Parent = FF_1
			UIPadding_1.PaddingBottom = UDim.new(0,8)
			UIPadding_1.PaddingLeft = UDim.new(0,8)
			UIPadding_1.PaddingRight = UDim.new(0,8)
			UIPadding_1.PaddingTop = UDim.new(0,8)

			F_1.Name = "F"
			F_1.Parent = FF_1
			F_1.AnchorPoint = Vector2.new(0, 0.5)
			F_1.BackgroundColor3 = themes[IsTheme].Function.Code['Background Code']
			F_1.BorderColor3 = Color3.fromRGB(0,0,0)
			F_1.BorderSizePixel = 0
			F_1.Position = UDim2.new(0, 0,0.5, 0)
			F_1.Size = UDim2.new(1, 0,1, 0)
			F_1.ClipsDescendants = true

			addToTheme('Function.Code.Background Code', F_1)

			UICorner_2.Parent = F_1

			Frame_1.Parent = F_1
			Frame_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Frame_1.BackgroundTransparency = 1
			Frame_1.BorderColor3 = Color3.fromRGB(0,0,0)
			Frame_1.BorderSizePixel = 0
			Frame_1.Size = UDim2.new(1, 0,1, 0)

			UIPadding_2.Parent = Frame_1
			UIPadding_2.PaddingTop = UDim.new(0,30)

			Frame_2.Parent = Frame_1
			Frame_2.BackgroundColor3 = themes[IsTheme].Function.Code['Background Code Value']
			Frame_2.BorderColor3 = Color3.fromRGB(0,0,0)
			Frame_2.BorderSizePixel = 0
			Frame_2.Size = UDim2.new(1, 0,1, 0)

			addToTheme('Function.Code.Background Code Value', Frame_2)

			Instance.new('UICorner', Frame_2)

			UIPadding_3.Parent = Frame_2
			UIPadding_3.PaddingBottom = UDim.new(0,5)
			UIPadding_3.PaddingLeft = UDim.new(0,8)
			UIPadding_3.PaddingRight = UDim.new(0,8)
			UIPadding_3.PaddingTop = UDim.new(0,8)

			local ScrollingFrame = Instance.new("ScrollingFrame")

			ScrollingFrame.Parent = Frame_2
			ScrollingFrame.Active = true
			ScrollingFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			ScrollingFrame.BackgroundTransparency = 1.000
			ScrollingFrame.BorderColor3 = Color3.fromRGB(0, 0, 0)
			ScrollingFrame.BorderSizePixel = 0
			ScrollingFrame.Size = UDim2.new(1, 0, 1, 0)
			ScrollingFrame.CanvasSize = UDim2.new(2, 0, 0, 0)
			ScrollingFrame.ScrollBarThickness = 4
			ScrollingFrame.ScrollBarImageColor3 = themes[IsTheme].Function.Code['ScrollingFrame Code']

			addToTheme('Function.Code.ScrollingFrame Code', ScrollingFrame)

			local Code_1 = Instance.new("Frame")
			local UIPaddingCode_1 = Instance.new("UIPadding")

			Code_1.Name = "Code"
			Code_1.Parent = ScrollingFrame
			Code_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Code_1.BackgroundTransparency = 1
			Code_1.BorderColor3 = Color3.fromRGB(0,0,0)
			Code_1.BorderSizePixel = 0
			Code_1.Size = UDim2.new(1, 0,1, 0)

			UIPaddingCode_1.Name = "UIPaddingCode"
			UIPaddingCode_1.Parent = Code_1
			UIPaddingCode_1.PaddingLeft = UDim.new(0,20)

			TextBox_2.Name = "TextBox"
			TextBox_2.Parent = Code_1
			TextBox_2.Active = true
			TextBox_2.BackgroundColor3 = Color3.fromRGB(255,255,255)
			TextBox_2.BackgroundTransparency = 1
			TextBox_2.BorderColor3 = Color3.fromRGB(0,0,0)
			TextBox_2.BorderSizePixel = 0
			TextBox_2.Size = UDim2.new(0, 0,0, 0)
			TextBox_2.Font = Enum.Font.Code
			TextBox_2.RichText = true
			TextBox_2.TextColor3 = Color3.fromRGB(255,255,255)
			TextBox_2.TextSize = 12
			TextBox_2.TextXAlignment = Enum.TextXAlignment.Left
			TextBox_2.TextYAlignment = Enum.TextYAlignment.Top
			TextBox_2.Text = CodeText
			TextBox_2.AutomaticSize = Enum.AutomaticSize.XY

			addToTheme('Text & Icon', TextBox_2)

			Top_1.Name = "Top"
			Top_1.Parent = F_1
			Top_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Top_1.BackgroundTransparency = 1
			Top_1.BorderColor3 = Color3.fromRGB(0,0,0)
			Top_1.BorderSizePixel = 0
			Top_1.Size = UDim2.new(1, 0,0, 30)

			Left_1.Name = "Left"
			Left_1.Parent = Top_1
			Left_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Left_1.BackgroundTransparency = 1
			Left_1.BorderColor3 = Color3.fromRGB(0,0,0)
			Left_1.BorderSizePixel = 0
			Left_1.Size = UDim2.new(1, 0,1, 0)

			Whatisthis_1.Name = "Whatisthis"
			Whatisthis_1.Parent = Left_1
			Whatisthis_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Whatisthis_1.BackgroundTransparency = 1
			Whatisthis_1.BorderColor3 = Color3.fromRGB(0,0,0)
			Whatisthis_1.BorderSizePixel = 0
			Whatisthis_1.Size = UDim2.new(0, 50,0, 13)
			Whatisthis_1.Image = "rbxassetid://81518443444327"
			Whatisthis_1.ScaleType = Enum.ScaleType.Fit

			UIListLayout_1.Parent = Left_1
			UIListLayout_1.Padding = UDim.new(0,5)
			UIListLayout_1.FillDirection = Enum.FillDirection.Horizontal
			UIListLayout_1.SortOrder = Enum.SortOrder.LayoutOrder
			UIListLayout_1.VerticalAlignment = Enum.VerticalAlignment.Center

			Frame_3.Parent = Left_1
			Frame_3.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Frame_3.BackgroundTransparency = 1
			Frame_3.BorderColor3 = Color3.fromRGB(0,0,0)
			Frame_3.BorderSizePixel = 0
			Frame_3.Size = UDim2.new(0, 100,0, 30)

			Frame_4.Parent = Frame_3
			Frame_4.BackgroundColor3 = themes[IsTheme].Function.Code['Background Code Value']
			Frame_4.BorderColor3 = Color3.fromRGB(0,0,0)
			Frame_4.BorderSizePixel = 0
			Frame_4.Position = UDim2.new(0, 0,0.15, 0)
			Frame_4.Size = UDim2.new(1, 0,0, 30)

			addToTheme('Function.Code.Background Code Value', Frame_4)

			addToTheme('Function.Code.Background Value', Frame_4)

			UICorner_3.Parent = Frame_4

			UIListLayout_2.Parent = Frame_4
			UIListLayout_2.Padding = UDim.new(0,5)
			UIListLayout_2.FillDirection = Enum.FillDirection.Horizontal
			UIListLayout_2.SortOrder = Enum.SortOrder.LayoutOrder

			UIPadding_4.Parent = Frame_4
			UIPadding_4.PaddingLeft = UDim.new(0,8)
			UIPadding_4.PaddingRight = UDim.new(0,8)

			TextLabel_1.Parent = Frame_4
			TextLabel_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			TextLabel_1.BackgroundTransparency = 1
			TextLabel_1.BorderColor3 = Color3.fromRGB(0,0,0)
			TextLabel_1.BorderSizePixel = 0
			TextLabel_1.Size = UDim2.new(1, 0,0, 25)
			TextLabel_1.Font = Enum.Font.GothamBold
			TextLabel_1.Text = tostring(Title)
			TextLabel_1.TextColor3 = Color3.fromRGB(255,255,255)
			TextLabel_1.TextSize = 11

			addToTheme('Text & Icon', TextLabel_1)

			Right_1.Name = "Right"
			Right_1.Parent = Top_1
			Right_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Right_1.BackgroundTransparency = 1
			Right_1.BorderColor3 = Color3.fromRGB(0,0,0)
			Right_1.BorderSizePixel = 0
			Right_1.Size = UDim2.new(1, 0,1, 0)

			UIListLayout_3.Parent = Right_1
			UIListLayout_3.Padding = UDim.new(0,5)
			UIListLayout_3.FillDirection = Enum.FillDirection.Horizontal
			UIListLayout_3.HorizontalAlignment = Enum.HorizontalAlignment.Right
			UIListLayout_3.SortOrder = Enum.SortOrder.LayoutOrder
			UIListLayout_3.VerticalAlignment = Enum.VerticalAlignment.Center

			Frame_5.Parent = Right_1
			Frame_5.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Frame_5.BackgroundTransparency = 1
			Frame_5.BorderColor3 = Color3.fromRGB(0,0,0)
			Frame_5.BorderSizePixel = 0
			Frame_5.Size = UDim2.new(0, 60,0, 30)

			TextButton_1.Parent = Frame_5
			TextButton_1.Active = true
			TextButton_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			TextButton_1.BackgroundTransparency = 1
			TextButton_1.BorderColor3 = Color3.fromRGB(0,0,0)
			TextButton_1.BorderSizePixel = 0
			TextButton_1.Size = UDim2.new(1, 0,1, 0)
			TextButton_1.Font = Enum.Font.GothamBold
			TextButton_1.Text = "Copy"
			TextButton_1.TextColor3 = Color3.fromRGB(255,255,255)
			TextButton_1.TextSize = 11
			TextButton_1.TextTransparency = 0.5
			TextButton_1.TextXAlignment = Enum.TextXAlignment.Right

			UIPadding_5.Parent = Frame_5
			UIPadding_5.PaddingRight = UDim.new(0,10)

			ImageLabel_1.Parent = Frame_5
			ImageLabel_1.AnchorPoint = Vector2.new(0, 0.5)
			ImageLabel_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			ImageLabel_1.BackgroundTransparency = 1
			ImageLabel_1.BorderColor3 = Color3.fromRGB(0,0,0)
			ImageLabel_1.BorderSizePixel = 0
			ImageLabel_1.Position = UDim2.new(0, 0,0.5, 0)
			ImageLabel_1.Size = UDim2.new(0, 16,0, 16)
			ImageLabel_1.Image = "rbxassetid://13847222481"
			ImageLabel_1.ImageTransparency = 0.5

			UIGradient_1.Parent = Code
			UIGradient_1.Color = themes[IsTheme].Function.Code.Background
			UIGradient_1.Rotation = 45

			addToTheme('Function.Code.Background', UIGradient_1)

			local Line = Instance.new("Frame")
			local LineText_1 = Instance.new("TextLabel")

			Line.Name = "Line"
			Line.Parent = ScrollingFrame
			Line.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Line.BackgroundTransparency = 1
			Line.BorderColor3 = Color3.fromRGB(0,0,0)
			Line.BorderSizePixel = 0
			Line.Size = UDim2.new(1, 0,1, 0)

			LineText_1.Name = "LineText"
			LineText_1.Parent = Line
			LineText_1.Active = true
			LineText_1.AutomaticSize = Enum.AutomaticSize.XY
			LineText_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			LineText_1.BackgroundTransparency = 1
			LineText_1.BorderColor3 = Color3.fromRGB(0,0,0)
			LineText_1.BorderSizePixel = 0
			LineText_1.Size = UDim2.new(0, 0,0, 0)
			LineText_1.Font = Enum.Font.RobotoMono
			LineText_1.RichText = true
			LineText_1.Text = ''
			LineText_1.TextColor3 = Color3.fromRGB(255,255,255)
			LineText_1.TextSize = 12
			LineText_1.TextXAlignment = Enum.TextXAlignment.Left
			LineText_1.TextYAlignment = Enum.TextYAlignment.Top
			LineText_1.TextWrapped = true

			local highlighter = {}

			do
				local keywords = {
					lua = {
						"and", "break", "or", "else", "elseif", "if", "then", "until", "repeat", "while", "do", "for", "in", "end",
						"local", "return", "function", "export"
					},
					rbx = {
						"game", "workspace", "script", "math", "string", "table", "task", "wait", "select", "next", "Enum",
						"error", "warn", "tick", "assert", "shared", "loadstring", "tonumber", "tostring", "type",
						"typeof", "unpack", "print", "Instance", "CFrame", "Vector3", "Vector2", "Color3", "UDim", "UDim2", "Ray", "BrickColor",
						"OverlapParams", "RaycastParams", "Axes", "Random", "Region3", "Rect", "TweenInfo",
						"collectgarbage", "not", "utf8", "pcall", "xpcall", "_G", "setmetatable", "getmetatable", "os", "pairs", "ipairs"
					},
					operators = {
						"#", "+", "-", "*", "%", "/", "^", "=", "~", "=", "<", ">",
					}
				}

				local colors = {
					numbers = Color3.fromHex("#79c0ff"),
					boolean = Color3.fromHex("#79c0ff"),
					operator = Color3.fromHex("#ff7b72"),
					lua = Color3.fromHex("#ff7b72"),
					rbx = Color3.fromHex("#7fcfef"), -- def
					str = Color3.fromHex("#a5d6ff"),
					comment = Color3.fromHex("#8b949e"),
					null = Color3.fromHex("#79c0ff"),
					call = Color3.fromHex("#d2a8ff"),
					self_call = Color3.fromHex("#d2a8ff"),
					local_property = Color3.fromHex("#ff7b72"),
				}

				local function createKeywordSet(keywords)
					local keywordSet = {}
					for _, keyword in ipairs(keywords) do
						keywordSet[keyword] = true
					end
					return keywordSet
				end

				local luaSet = createKeywordSet(keywords.lua)
				local rbxSet = createKeywordSet(keywords.rbx)
				local operatorsSet = createKeywordSet(keywords.operators)

				local function getHighlight(tokens, index)
					local token = tokens[index]

					if colors[token .. "_color"] then
						return colors[token .. "_color"]
					end

					if tonumber(token) then
						return colors.numbers
					elseif token == "nil" then
						return colors.null
					elseif token:sub(1, 2) == "--" then
						return colors.comment
					elseif operatorsSet[token] then
						return colors.operator
					elseif luaSet[token] then
						return colors.lua
					elseif rbxSet[token] then
						return colors.rbx
					elseif token:sub(1, 1) == "\"" or token:sub(1, 1) == "\'" then
						return colors.str
					elseif token == "true" or token == "false" then
						return colors.boolean
					else
					end

					if tokens[index + 1] == "(" then
						if tokens[index - 1] == ":" then
							return colors.self_call
						end

						return colors.call
					end

					if tokens[index - 1] == "." then
						if tokens[index - 2] == "Enum" then
							return colors.rbx
						end

						return colors.local_property
					end
				end

				function highlighter.run(source)
					local tokens = {}
					local multiStrings = {}
					local currentToken = ""

					local index = 1
					source = source:gsub("%[%[.-%]%]", function(str)
						local placeholder = "__MULTISTR_" .. index .. "__"
						multiStrings[placeholder] = str
						index = index + 1
						return placeholder
					end)

					local function escape(s)
						return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
					end

					local function restore(s)
						return (s:gsub("__MULTISTR_%d+__", function(ph)
							return multiStrings[ph] or ph
						end))
					end

					local inString = false
					local inComment = false
					local commentPersist = false

					local i = 1
					while i <= #source do
						local character = source:sub(i, i)

						if inComment then
							if character == "\n" and not commentPersist then
								table.insert(tokens, currentToken)
								table.insert(tokens, character)
								currentToken = ""
								inComment = false
							elseif source:sub(i - 1, i) == "]]" and commentPersist then
								currentToken = currentToken .. "]"
								table.insert(tokens, currentToken)
								currentToken = ""
								inComment = false
								commentPersist = false
							else
								currentToken = currentToken .. character
							end
						elseif inString then
							if character == inString and source:sub(i - 1, i - 1) ~= "\\" or character == "\n" then
								currentToken = currentToken .. character
								inString = false
							else
								currentToken = currentToken .. character
							end
						else
							local foundPlaceholder = source:sub(i):match("^__MULTISTR_%d+__")
							if foundPlaceholder then
								table.insert(tokens, currentToken)
								table.insert(tokens, foundPlaceholder)
								currentToken = ""
								i = i + #foundPlaceholder - 1
							elseif source:sub(i, i + 1) == "--" and source:sub(i + 2):match("^__MULTISTR_%d+__") then
								-- block comment --[[ ... ]]: the whole block is already a placeholder
								local ph = source:sub(i + 2):match("^__MULTISTR_%d+__")
								table.insert(tokens, currentToken)
								table.insert(tokens, "--" .. ph)
								currentToken = ""
								i = i + 1 + #ph
							elseif source:sub(i, i + 1) == "--" then
								table.insert(tokens, currentToken)
								currentToken = "-"
								inComment = true
								commentPersist = source:sub(i + 2, i + 3) == "[["
							elseif character == "\"" or character == "\'" then
								table.insert(tokens, currentToken)
								currentToken = character
								inString = character
							elseif operatorsSet[character] then
								table.insert(tokens, currentToken)
								table.insert(tokens, character)
								currentToken = ""
							elseif character:match("[%w_]") then
								currentToken = currentToken .. character
							else
								table.insert(tokens, currentToken)
								table.insert(tokens, character)
								currentToken = ""
							end
						end
						i = i + 1
					end

					table.insert(tokens, currentToken)

					local highlighted = {}

					for i, token in ipairs(tokens) do
						if token ~= "" then
							if multiStrings[token] then
								table.insert(highlighted, string.format('<font color = "#%s">%s</font>', colors.str:ToHex(), escape(multiStrings[token])))
							else
								local highlight = getHighlight(tokens, i)
								local text = escape(restore(token))
								if highlight then
									table.insert(highlighted, string.format('<font color = "#%s">%s</font>', highlight:ToHex(), text))
								else
									table.insert(highlighted, text)
								end
							end
						end
					end

					return table.concat(highlighted)
				end
			end

			local iscop = false

			TextButton_1.MouseButton1Click:Connect(function()
				if not iscop then
					local copy = setclipboard or toclipboard
					if type(copy) ~= "function" then
						warn("[Sylex] this executor has no clipboard function")
						return
					end
					pcall(copy, CodeText)
					TextButton_1.Text = "Copied"
					ImageLabel_1.Image = "rbxassetid://14939475472"
					Frame_5.Size = UDim2.new(0, 65,0, 30)
					iscop = true
					delay(1, function()
						TextButton_1.Text = "Copy"
						ImageLabel_1.Image = "rbxassetid://13847222481"
						Frame_5.Size = UDim2.new(0, 58,0, 30)
						iscop = false
					end)
				end
			end)

			TextBox_2.Text = highlighter.run(TextBox_2.Text)

			TextBox_2:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
				ScrollingFrame.CanvasSize = UDim2.new(0, TextBox_2.AbsoluteSize.X + 20, 0, 0)
			end)

			local function updateLineNumbers()
				tw({v = RealBackground, t = 0.15, s = Enum.EasingStyle.Exponential, d = "Out", g = {Size = UDim2.new(1, 0,0, TextBox_2.TextBounds.Y + 65)}}):Play()
				tw({v = Frame_3, t = 0.15, s = Enum.EasingStyle.Exponential, d = "Out", g = {Size = UDim2.new(0, TextLabel_1.TextBounds.X + 30,0, 30)}}):Play()

				local count = #TextBox_2.Text:split("\n")

				local str = ""
				for i = 1, count do
					str = str .. i .. "\n"
				end
				LineText_1.Text = str
			end

			updateLineNumbers()
			TextBox_2:GetPropertyChangedSignal("Text"):Connect(updateLineNumbers)

			local New = {}

			function New:SetTitle(t)
				TextLabel_1.Text = tostring(t)
			end

			function New:SetCode(t)
				TextBox_2.Text = highlighter.run(t)
				CodeText = t
			end

			function New:GetCode()
				return CodeText
			end

			return attachCommon(New, RealBackground, p, "Code")
		end

		function Func:Dropdown(p)
			p = p or {}
			local Title = p.Title or 'null'
			local Desc = p.Desc or ''
			local Image = p.Image or ''
			local List = p.List or {}
			local Multi = p.Multi or false
			local Value = p.Value
			if Value == nil and not Multi then
				Value = List[1]
			end
			local Callback = p.Callback or function() end

			local Dropdown, Config = background(ScrollingFrame_1, Title, Desc, Image, 'Dropdown')

			Config:SetTextTransparencyTitle(0)
			Config:SetSizeT(125)

			local DropdownSelect
			local function onChange(v)
				setFlag(p.Flag, v)
				Callback(v)
			end
			DropdownSelect = addDropdownSelect(Dropdown, Dropdown, Multi, onChange, Value, List)

			local New = {}

			function New:SetTitle(t)
				Config:SetTitle(t)
			end

			function New:SetDesc(t)
				Config:SetDesc(t)
			end

			function New:SetValue(t, silent)
				DropdownSelect:SetValue(t, silent)
				setFlag(p.Flag, DropdownSelect:Get())
			end

			function New:Get()
				return DropdownSelect:Get()
			end

			function New:GetOptions()
				return DropdownSelect:GetOptions()
			end

			function New:Add(t)
				DropdownSelect:Add(t)
			end

			function New:Clear(t)
				DropdownSelect:Clear(t)
				setFlag(p.Flag, DropdownSelect:Get())
			end

			function New:Refresh(list)
				DropdownSelect:Refresh(list)
				setFlag(p.Flag, DropdownSelect:Get())
			end

			return attachCommon(New, Dropdown.Parent, p, "Dropdown")
		end

		function Func:PlayerDropdown(p)
			p = p or {}
			local IncludeSelf = p.IncludeSelf ~= false

			local function names()
				local list = {}
				for _, plr in ipairs(Players:GetPlayers()) do
					if IncludeSelf or plr ~= LocalPlayer then
						table.insert(list, plr.Name)
					end
				end
				table.sort(list, function(a, b)
					return a:lower() < b:lower()
				end)
				return list
			end

			local options = table.clone(p)
			options.List = names()
			if options.Value == nil and not options.Multi then
				options.Value = IncludeSelf and LocalPlayer.Name or options.List[1]
			end

			local Drop = Func:Dropdown(options)
			Drop.Type = "PlayerDropdown"

			local added = track(Players.PlayerAdded:Connect(function()
				Drop:Refresh(names())
			end))
			local removing = track(Players.PlayerRemoving:Connect(function(plr)
				task.defer(function()
					Drop:Refresh(names())
				end)
			end))

			Drop._cleanup = function()
				added:Disconnect()
				removing:Disconnect()
			end

			return Drop
		end

		function Func:Keybind(p)
			p = p or {}
			local Title = p.Title or 'null'
			local Desc = p.Desc or ''
			local Image = p.Image or ''
			local Value = p.Value or false
			local Key = p.Key or Enum.KeyCode.E
			local Callback = p.Callback or function() end

			local Keybind, Config = background(ScrollingFrame_1, Title, Desc, Image, 'Keybind')

			Config:SetSizeT(100)

			local F = Instance.new("TextButton")
			local UIListLayout_1 = Instance.new("UIListLayout")
			local UIPadding_1 = Instance.new("UIPadding")
			local ToggleValue_1 = Instance.new("Frame")
			local UICorner_1 = Instance.new("UICorner")
			local Frame_1 = Instance.new("Frame")
			local UICorner_2 = Instance.new("UICorner")
			local UIPadding_2 = Instance.new("UIPadding")
			local KeybindValue_1 = Instance.new("Frame")
			local UICorner_3 = Instance.new("UICorner")
			local UIStroke_1 = Instance.new("UIStroke")
			local TextLabel_1 = Instance.new("TextLabel")
			local UIPadding_3 = Instance.new("UIPadding")

			F.Name = "F"
			F.Parent = Keybind
			F.AnchorPoint = Vector2.new(1, 0.5)
			F.BackgroundColor3 = Color3.fromRGB(255,255,255)
			F.BackgroundTransparency = 1
			F.BorderColor3 = Color3.fromRGB(0,0,0)
			F.BorderSizePixel = 0
			F.Position = UDim2.new(1, 0,0.5, 0)
			F.Size = UDim2.new(0, 100,0.800000012, 0)
			F.Text = ''

			UIListLayout_1.Parent = F
			UIListLayout_1.Padding = UDim.new(0,8)
			UIListLayout_1.FillDirection = Enum.FillDirection.Horizontal
			UIListLayout_1.HorizontalAlignment = Enum.HorizontalAlignment.Right
			UIListLayout_1.SortOrder = Enum.SortOrder.LayoutOrder
			UIListLayout_1.VerticalAlignment = Enum.VerticalAlignment.Center

			UIPadding_1.Parent = F
			UIPadding_1.PaddingRight = UDim.new(0,13)

			ToggleValue_1.Name = "ToggleValue"
			ToggleValue_1.Parent = F
			ToggleValue_1.BackgroundColor3 = themes[IsTheme].Function.Keybind.True['Toggle Background']
			ToggleValue_1.BorderColor3 = Color3.fromRGB(0,0,0)
			ToggleValue_1.BorderSizePixel = 0
			ToggleValue_1.LayoutOrder = 1
			ToggleValue_1.Size = UDim2.new(0, 34,0, 17)

			UICorner_1.Parent = ToggleValue_1
			UICorner_1.CornerRadius = UDim.new(1,0)

			Frame_1.Parent = ToggleValue_1
			Frame_1.AnchorPoint = Vector2.new(1, 0.5)
			Frame_1.BackgroundColor3 = themes[IsTheme].Function.Keybind.True['Toggle Value']
			Frame_1.BorderColor3 = Color3.fromRGB(0,0,0)
			Frame_1.BorderSizePixel = 0
			Frame_1.Position = UDim2.new(1, 0,0.5, 0)
			Frame_1.Size = UDim2.new(0, 13,0, 13)

			addToTheme('Main', Frame_1)

			UICorner_2.Parent = Frame_1
			UICorner_2.CornerRadius = UDim.new(1,0)

			UIPadding_2.Parent = ToggleValue_1
			UIPadding_2.PaddingLeft = UDim.new(0,2)
			UIPadding_2.PaddingRight = UDim.new(0,2)

			KeybindValue_1.Name = "KeybindValue"
			KeybindValue_1.Parent = F
			KeybindValue_1.BackgroundColor3 = themes[IsTheme].Function.Keybind['Value Background']
			KeybindValue_1.BorderColor3 = Color3.fromRGB(0,0,0)
			KeybindValue_1.BorderSizePixel = 0
			KeybindValue_1.Size = UDim2.new(0, 30,0, 20)

			addToTheme('Function.Keybind.Value Background', KeybindValue_1)

			UICorner_3.Parent = KeybindValue_1
			UICorner_3.CornerRadius = UDim.new(0,4)

			UIStroke_1.Parent = KeybindValue_1
			UIStroke_1.Color = Color3.fromRGB(255,255,255)
			UIStroke_1.Thickness = 1
			UIStroke_1.Transparency = 0.95

			addToTheme('Function.Keybind.Value Stroke', UIStroke_1)

			TextLabel_1.Parent = KeybindValue_1
			TextLabel_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			TextLabel_1.BackgroundTransparency = 1
			TextLabel_1.BorderColor3 = Color3.fromRGB(0,0,0)
			TextLabel_1.BorderSizePixel = 0
			TextLabel_1.Size = UDim2.new(1, 0,1, 0)
			TextLabel_1.Font = Enum.Font.GothamBold
			TextLabel_1.RichText = true
			TextLabel_1.Text = tostring(Key):gsub("Enum.KeyCode.", "")
			TextLabel_1.TextColor3 = Color3.fromRGB(255,255,255)
			TextLabel_1.TextSize = 10
			TextLabel_1.TextTransparency = 0.30000001192092896
			TextLabel_1.TextWrapped = true

			addToTheme('Text & Icon', TextLabel_1)

			UIPadding_3.Parent = KeybindValue_1
			UIPadding_3.PaddingLeft = UDim.new(0,5)
			UIPadding_3.PaddingRight = UDim.new(0,5)

			local Click = click(Keybind)
			KeybindValue_1.ZIndex = 2
			F.ZIndex = 2

			local PressMode = p.Mode == "Press"
			if PressMode then
				-- "Press" mode: no on/off switch, the callback just fires on each key press
				ToggleValue_1.Visible = false
			end

			local initialized = false

			local function keyName(k)
				return typeof(k) == "EnumItem" and k.Name or tostring(k)
			end

			local function paint()
				if Value then
					Config:SetTextTransparencyTitle(0)
					tw({v = ToggleValue_1, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out", g = {BackgroundColor3 = themes[IsTheme].Function.Keybind.True['Toggle Background']}}):Play()
					tw({v = Frame_1, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out",
						g = {
							BackgroundColor3 = themes[IsTheme].Function.Keybind.True['Toggle Value'],
							AnchorPoint = Vector2.new(1, 0.5),
							Position = UDim2.new(1, 0,0.5, 0)
						}}):Play()
				else
					Config:SetTextTransparencyTitle(PressMode and 0 or 0.7)
					tw({v = ToggleValue_1, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out", g = {BackgroundColor3 = themes[IsTheme].Function.Keybind.False['Toggle Background']}}):Play()
					tw({v = Frame_1, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out",
						g = {
							BackgroundColor3 = themes[IsTheme].Function.Keybind.False['Toggle Value'],
							AnchorPoint = Vector2.new(0, 0.5),
							Position = UDim2.new(0, 0,0.5, 0)
						}}):Play()
				end
			end

			local function sync(silent)
				setFlag(p.Flag, { Key = Key, Value = Value })
				if Library._refreshKeybindList then
					Library._refreshKeybindList()
				end
				if not silent then
					safeCall(Callback, Key, Value)
				end
			end

			local function set(v, silent)
				initialized = true
				if not PressMode then
					Value = v == true
				end
				paint()
				sync(silent)
			end

			Click.MouseButton1Click:Connect(function()
				set(not Value)
			end)

			delay(0.1, function()
				if not initialized then
					set(Value)
				end
			end)

			local changeing = false

			local function adjustBoxBindSize()
				local textSize = TextService:GetTextSize(TextLabel_1.Text, TextLabel_1.TextSize, TextLabel_1.Font, Vector2.new(1000, 1000))
				tw({v = KeybindValue_1, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out", g = {Size = UDim2.new(0, textSize.X + 20, 0, 20)}}):Play()
			end

			adjustBoxBindSize()

			local function changeKey()
				if changeing then
					return
				end
				changeing = true
				TextLabel_1.Text = "..."
				adjustBoxBindSize()
				local inputConnection
				inputConnection = U.InputBegan:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.Keyboard then
						inputConnection:Disconnect()
						-- Escape cancels rebinding
						if input.KeyCode ~= Enum.KeyCode.Escape then
							Key = input.KeyCode
						end
						TextLabel_1.Text = keyName(Key)
						adjustBoxBindSize()
						initialized = true
						sync()
						task.wait(.1)
						changeing = false
					end
				end)
			end

			local New = {}

			U.InputBegan:Connect(function(input, gameProcessed)
				-- ignore presses while typing in chat or a textbox
				if gameProcessed or U:GetFocusedTextBox() then
					return
				end
				-- a locked or dependency-hidden keybind ignores its key
				local root = Keybind.Parent
				if New.Locked or (root and root:GetAttribute("SylexDependency")) then
					return
				end
				if input.KeyCode == Key and not changeing then
					set(not Value)
				end
			end)

			onTheme(function()
				local state = Value and 'True' or 'False'
				ToggleValue_1.BackgroundColor3 = themes[IsTheme].Function.Keybind[state]['Toggle Background']
				Frame_1.BackgroundColor3 = themes[IsTheme].Function.Keybind[state]['Toggle Value']
			end)

			F.MouseButton1Click:Connect(changeKey)

			local entry = {
				Title = p.Title or 'null',
				Get = function()
					return Key, Value, PressMode
				end,
			}
			table.insert(keybindRegistry, entry)

			function New:SetTitle(t)
				Config:SetTitle(t)
				entry.Title = tostring(t)
			end

			function New:SetDesc(t)
				Config:SetDesc(t)
			end

			-- Accepts true/false, or a saved { Key = "E", Value = true } table
			function New:SetValue(t, silent)
				if type(t) == "table" then
					local k = t.Key
					if type(k) == "string" then
						local ok, code = pcall(function()
							return Enum.KeyCode[k]
						end)
						k = ok and code or nil
					end
					if typeof(k) == "EnumItem" then
						Key = k
						TextLabel_1.Text = keyName(Key)
						adjustBoxBindSize()
					end
					set(t.Value, silent)
				else
					set(t, silent)
				end
			end

			function New:SetKey(t)
				Key = t
				TextLabel_1.Text = keyName(Key)
				adjustBoxBindSize()
				initialized = true
				sync()
			end

			function New:Get()
				return { Key = Key, Value = Value }
			end

			New._cleanup = function()
				local index = table.find(keybindRegistry, entry)
				if index then
					table.remove(keybindRegistry, index)
				end
				if Library._refreshKeybindList then
					Library._refreshKeybindList()
				end
			end

			return attachCommon(New, Keybind.Parent, p, "Keybind")
		end

		function Func:ColorPicker(p)
			p = p or {}
			local Title = p.Title or 'null'
			local Desc = p.Desc or ''
			local Image = p.Image or ''
			local Value = p.Value or Color3.fromRGB(255, 255, 255)
			local Callback = p.Callback or function() end

			local ColorPicker, Config = background(ScrollingFrame_1, Title, Desc, Image, 'Color Picker')

			Config:SetTextTransparencyTitle(0)
			Config:SetSizeT(50)

			local ListFunctionColorPicker = Instance.new("Frame")
			local Picker_1 = Instance.new("Frame")
			local UICorner_1 = Instance.new("UICorner")
			local GlowDot_1 = Instance.new("ImageLabel")
			local Picker_2 = Instance.new("Frame")
			local UICorner_2 = Instance.new("UICorner")
			local UIPadding_1 = Instance.new("UIPadding")

			ListFunctionColorPicker.Name = "ListFunctionColorPicker"
			ListFunctionColorPicker.Parent = ColorPicker
			ListFunctionColorPicker.BackgroundColor3 = Color3.fromRGB(255,255,255)
			ListFunctionColorPicker.BackgroundTransparency = 1
			ListFunctionColorPicker.BorderColor3 = Color3.fromRGB(0,0,0)
			ListFunctionColorPicker.BorderSizePixel = 0
			ListFunctionColorPicker.Size = UDim2.new(1, 0,1, 0)

			Picker_1.Name = "Picker"
			Picker_1.Parent = ListFunctionColorPicker
			Picker_1.AnchorPoint = Vector2.new(1, 0.5)
			Picker_1.BackgroundColor3 = Value
			Picker_1.BorderColor3 = Color3.fromRGB(0,0,0)
			Picker_1.BorderSizePixel = 0
			Picker_1.Position = UDim2.new(1, 0,0.5, 0)
			Picker_1.Size = UDim2.new(0, 20,0, 20)

			UICorner_1.Parent = Picker_1
			UICorner_1.CornerRadius = UDim.new(1,0)

			GlowDot_1.Name = "GlowDot"
			GlowDot_1.Parent = Picker_1
			GlowDot_1.AnchorPoint = Vector2.new(0.5, 0.5)
			GlowDot_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			GlowDot_1.BackgroundTransparency = 1
			GlowDot_1.BorderColor3 = Color3.fromRGB(0,0,0)
			GlowDot_1.BorderSizePixel = 0
			GlowDot_1.Position = UDim2.new(0.5, 0,0.5, 0)
			GlowDot_1.Size = UDim2.new(1.5, 0,1.5, 0)
			GlowDot_1.Image = "rbxassetid://105506802034513"
			GlowDot_1.ImageColor3 = Value
			GlowDot_1.ImageTransparency = 0.2

			Picker_2.Name = "Picker"
			Picker_2.Parent = GlowDot_1
			Picker_2.AnchorPoint = Vector2.new(0.5, 0.5)
			Picker_2.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Picker_2.BorderColor3 = Color3.fromRGB(0,0,0)
			Picker_2.BorderSizePixel = 0
			Picker_2.Position = UDim2.new(0.5, 0,0.5, 0)
			Picker_2.Size = UDim2.new(0, 12,0, 12)

			UICorner_2.Parent = Picker_2
			UICorner_2.CornerRadius = UDim.new(1,0)

			UIPadding_1.Parent = ListFunctionColorPicker
			UIPadding_1.PaddingRight = UDim.new(0,10)

			local ColorpickBar = Instance.new("Frame")
			local UICorner_1 = Instance.new("UICorner")
			local UIStroke_1 = Instance.new("UIStroke")
			local UIPadding_1 = Instance.new("UIPadding")
			local Color_1 = Instance.new("ImageLabel")
			local ColorCorner_1 = Instance.new("UICorner")
			local ColorSelection_1 = Instance.new("ImageLabel")
			local Hue_1 = Instance.new("ImageLabel")
			local HueCorner_1 = Instance.new("UICorner")
			local HueGradient_1 = Instance.new("UIGradient")
			local HueSelection_1 = Instance.new("ImageLabel")

			ColorpickBar.Name = "ColorpickBar"
			ColorpickBar.Parent = ScreenGui
			ColorpickBar.BackgroundColor3 = themes[IsTheme].Function['Color Picker']['Color Select'].Background
			ColorpickBar.BorderColor3 = Color3.fromRGB(0,0,0)
			ColorpickBar.BorderSizePixel = 0
			ColorpickBar.Size = UDim2.new(0, 120,0, 0)
			ColorpickBar.ClipsDescendants = true
			local targetX = Picker_1.AbsolutePosition.X - ColorpickBar.Parent.AbsolutePosition.X + Picker_1.Size.X.Offset - 100
			local targetY = Picker_1.AbsolutePosition.Y - ColorpickBar.Parent.AbsolutePosition.Y + Picker_1.Size.Y.Offset - 20
			ColorpickBar.Position = UDim2.new(0, targetX, 0, targetY)

			addToTheme('Function.Color Picker.Color Select.Background', ColorpickBar)

			UICorner_1.Parent = ColorpickBar
			UICorner_1.CornerRadius = UDim.new(0, 6)

			UIStroke_1.Parent = ColorpickBar
			UIStroke_1.Thickness = 1
			UIStroke_1.Transparency = 1
			UIStroke_1.Color = Color3.fromRGB(255, 255, 255)
			UIStroke_1.Transparency = 0.95

			addToTheme('Function.Color Picker.Color Select.UIStroke', UIStroke_1)

			UIPadding_1.Parent = ColorpickBar
			UIPadding_1.PaddingBottom = UDim.new(0,5)
			UIPadding_1.PaddingLeft = UDim.new(0,10)
			UIPadding_1.PaddingRight = UDim.new(0,10)
			UIPadding_1.PaddingTop = UDim.new(0,5)

			Color_1.Name = "Color"
			Color_1.Parent = ColorpickBar
			Color_1.AnchorPoint = Vector2.new(0, 0)
			Color_1.BackgroundColor3 = Color3.fromRGB(39,39,39)
			Color_1.Position = UDim2.new(0, 0,0, 25)
			Color_1.Size = UDim2.new(0, 80,0, 80)
			Color_1.ZIndex = 10
			Color_1.Image = "rbxassetid://4155801252"

			ColorCorner_1.Name = "ColorCorner"
			ColorCorner_1.Parent = Color_1
			ColorCorner_1.CornerRadius = UDim.new(0,3)

			ColorSelection_1.Name = "ColorSelection"
			ColorSelection_1.Parent = Color_1
			ColorSelection_1.AnchorPoint = Vector2.new(0.5, 0.5)
			ColorSelection_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			ColorSelection_1.BackgroundTransparency = 1
			ColorSelection_1.Size = UDim2.new(0, 12,0, 12)
			ColorSelection_1.Image = "http://www.roblox.com/asset/?id=4805639000"
			ColorSelection_1.ScaleType = Enum.ScaleType.Fit

			Hue_1.Name = "Hue"
			Hue_1.Parent = ColorpickBar
			Hue_1.AnchorPoint = Vector2.new(0, 0)
			Hue_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Hue_1.Position = UDim2.new(0.47, 0,0, 25)
			Hue_1.Size = UDim2.new(0, 10,0, 80)

			HueCorner_1.Name = "HueCorner"
			HueCorner_1.Parent = Hue_1
			HueCorner_1.CornerRadius = UDim.new(1,0)

			HueGradient_1.Name = "HueGradient"
			HueGradient_1.Parent = Hue_1
			HueGradient_1.Color = ColorSequence.new{ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 4)), ColorSequenceKeypoint.new(0.2, Color3.fromRGB(234, 255, 0)), ColorSequenceKeypoint.new(0.4, Color3.fromRGB(21, 255, 0)), ColorSequenceKeypoint.new(0.6, Color3.fromRGB(0, 255, 255)), ColorSequenceKeypoint.new(0.8, Color3.fromRGB(0, 17, 255)), ColorSequenceKeypoint.new(0.9, Color3.fromRGB(255, 0, 251)), ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 0, 4))}
			HueGradient_1.Rotation = 270

			HueSelection_1.Name = "HueSelection"
			HueSelection_1.Parent = Hue_1
			HueSelection_1.AnchorPoint = Vector2.new(0.5, 0.5)
			HueSelection_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			HueSelection_1.BackgroundTransparency = 1
			HueSelection_1.Position = UDim2.new(0.5, 0,1, 0)
			HueSelection_1.Size = UDim2.new(0, 12,0, 12)
			HueSelection_1.Image = "http://www.roblox.com/asset/?id=4805639000"

			local TitleColorPicker = Instance.new("TextLabel")

			TitleColorPicker.Name = "TitleColorPicker"
			TitleColorPicker.Parent = ColorpickBar
			TitleColorPicker.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			TitleColorPicker.BackgroundTransparency = 1.000
			TitleColorPicker.BorderColor3 = Color3.fromRGB(0, 0, 0)
			TitleColorPicker.BorderSizePixel = 0
			TitleColorPicker.Size = UDim2.new(1, 0, 0, 27)
			TitleColorPicker.Font = Enum.Font.GothamBold
			TitleColorPicker.Text = Title
			TitleColorPicker.TextColor3 = Color3.fromRGB(0, 0, 0)
			TitleColorPicker.TextSize = 12.000
			TitleColorPicker.TextXAlignment = Enum.TextXAlignment.Left
			TitleColorPicker.TextColor3 = Color3.fromRGB(255, 255, 255)

			addToTheme('Text & Icon', TitleColorPicker)

			local BoxColor = Instance.new("Frame")
			local Hax_1 = Instance.new("Frame")
			local BarValueHax_1 = Instance.new("Frame")
			local UICorner_1 = Instance.new("UICorner")
			local UIStroke_11 = Instance.new("UIStroke")
			local TextLabel_1 = Instance.new("TextBox")
			local TextLabel_2 = Instance.new("TextLabel")
			local UIListLayoutBoxColor_1 = Instance.new("UIListLayout")
			local Red_1 = Instance.new("Frame")
			local BarValueRed_1 = Instance.new("Frame")
			local UICorner_2 = Instance.new("UICorner")
			local UIStroke_2 = Instance.new("UIStroke")
			local TextLabel_3 = Instance.new("TextBox")
			local TextLabel_4 = Instance.new("TextLabel")
			local Green_1 = Instance.new("Frame")
			local BarValueGreen_1 = Instance.new("Frame")
			local UICorner_3 = Instance.new("UICorner")
			local UIStroke_3 = Instance.new("UIStroke")
			local TextLabel_5 = Instance.new("TextBox")
			local TextLabel_6 = Instance.new("TextLabel")
			local Blue_1 = Instance.new("Frame")
			local BarValueBlue_1 = Instance.new("Frame")
			local UICorner_4 = Instance.new("UICorner")
			local UIStroke_4 = Instance.new("UIStroke")
			local TextLabel_7 = Instance.new("TextBox")
			local TextLabel_8 = Instance.new("TextLabel")

			BoxColor.Name = "BoxColor"
			BoxColor.Parent = ColorpickBar
			BoxColor.AnchorPoint = Vector2.new(1, 0)
			BoxColor.BackgroundColor3 = Color3.fromRGB(255,255,255)
			BoxColor.BackgroundTransparency = 1
			BoxColor.BorderColor3 = Color3.fromRGB(0,0,0)
			BoxColor.BorderSizePixel = 0
			BoxColor.Position = UDim2.new(1, 0,0, 25)
			BoxColor.Size = UDim2.new(0, 80,0, 80)

			Hax_1.Name = "Hax"
			Hax_1.Parent = BoxColor
			Hax_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Hax_1.BackgroundTransparency = 1
			Hax_1.BorderColor3 = Color3.fromRGB(0,0,0)
			Hax_1.BorderSizePixel = 0
			Hax_1.Size = UDim2.new(1, 0,0, 21)

			BarValueHax_1.Name = "BarValueHax"
			BarValueHax_1.Parent = Hax_1
			BarValueHax_1.AnchorPoint = Vector2.new(0, 0.5)
			BarValueHax_1.BackgroundColor3 = Color3.fromRGB(217,217,217)
			BarValueHax_1.BackgroundTransparency = 1
			BarValueHax_1.BorderColor3 = Color3.fromRGB(0,0,0)
			BarValueHax_1.BorderSizePixel = 0
			BarValueHax_1.Position = UDim2.new(0, 0,0.5, 0)
			BarValueHax_1.Size = UDim2.new(0.6, 0,0, 15)

			UICorner_1.Parent = BarValueHax_1
			UICorner_1.CornerRadius = UDim.new(1,0)

			UIStroke_11.Parent = BarValueHax_1
			UIStroke_11.Thickness = 1
			UIStroke_11.Color = Color3.fromRGB(255, 255, 255)
			UIStroke_11.Transparency = 0.95

			addToTheme('Function.Color Picker.Color Select.UIStroke', UIStroke_11)

			TextLabel_1.Name = "TextLabel"
			TextLabel_1.Parent = BarValueHax_1
			TextLabel_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			TextLabel_1.BackgroundTransparency = 1
			TextLabel_1.BorderColor3 = Color3.fromRGB(0,0,0)
			TextLabel_1.BorderSizePixel = 0
			TextLabel_1.Size = UDim2.new(1, 0,1, 0)
			TextLabel_1.Font = Enum.Font.Gotham
			TextLabel_1.PlaceholderColor3 = Color3.fromRGB(178,178,178)
			TextLabel_1.PlaceholderText = "#FFFFFF"
			TextLabel_1.Text = "#FFFFFF"
			TextLabel_1.TextSize = 9
			TextLabel_1.TextTruncate = Enum.TextTruncate.AtEnd
			TextLabel_1.TextColor3 = Color3.fromRGB(255, 255, 255)

			addToTheme('Text & Icon', TextLabel_1)

			TextLabel_2.Parent = Hax_1
			TextLabel_2.AnchorPoint = Vector2.new(1, 0.5)
			TextLabel_2.BackgroundColor3 = Color3.fromRGB(255,255,255)
			TextLabel_2.BackgroundTransparency = 1
			TextLabel_2.BorderColor3 = Color3.fromRGB(0,0,0)
			TextLabel_2.BorderSizePixel = 0
			TextLabel_2.Position = UDim2.new(0.980000019, 0,0.5, 0)
			TextLabel_2.Size = UDim2.new(0, 20,0, 20)
			TextLabel_2.Font = Enum.Font.Gotham
			TextLabel_2.Text = "Hax"
			TextLabel_2.TextSize = 9
			TextLabel_2.TextXAlignment = Enum.TextXAlignment.Left
			TextLabel_2.TextColor3 = Color3.fromRGB(255, 255, 255)

			addToTheme('Text & Icon', TextLabel_2)

			UIListLayoutBoxColor_1.Name = "UIListLayoutBoxColor"
			UIListLayoutBoxColor_1.Parent = BoxColor
			UIListLayoutBoxColor_1.SortOrder = Enum.SortOrder.LayoutOrder
			UIListLayoutBoxColor_1.VerticalAlignment = Enum.VerticalAlignment.Center

			Red_1.Name = "Red"
			Red_1.Parent = BoxColor
			Red_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Red_1.BackgroundTransparency = 1
			Red_1.BorderColor3 = Color3.fromRGB(0,0,0)
			Red_1.BorderSizePixel = 0
			Red_1.LayoutOrder = 1
			Red_1.Size = UDim2.new(1, 0,0, 21)

			BarValueRed_1.Name = "BarValueRed"
			BarValueRed_1.Parent = Red_1
			BarValueRed_1.AnchorPoint = Vector2.new(0, 0.5)
			BarValueRed_1.BackgroundColor3 = Color3.fromRGB(217,217,217)
			BarValueRed_1.BackgroundTransparency = 1
			BarValueRed_1.BorderColor3 = Color3.fromRGB(0,0,0)
			BarValueRed_1.BorderSizePixel = 0
			BarValueRed_1.Position = UDim2.new(0, 0,0.5, 0)
			BarValueRed_1.Size = UDim2.new(0.600000024, 0,0, 15)

			UICorner_2.Parent = BarValueRed_1
			UICorner_2.CornerRadius = UDim.new(1,0)

			UIStroke_2.Parent = BarValueRed_1
			UIStroke_2.Thickness = 1
			UIStroke_2.Color = Color3.fromRGB(255, 255, 255)
			UIStroke_2.Transparency = 0.95

			addToTheme('Function.Color Picker.Color Select.UIStroke', UIStroke_2)

			TextLabel_3.Name = "TextLabel"
			TextLabel_3.Parent = BarValueRed_1
			TextLabel_3.BackgroundColor3 = Color3.fromRGB(255,255,255)
			TextLabel_3.BackgroundTransparency = 1
			TextLabel_3.BorderColor3 = Color3.fromRGB(0,0,0)
			TextLabel_3.BorderSizePixel = 0
			TextLabel_3.Size = UDim2.new(1, 0,1, 0)
			TextLabel_3.Font = Enum.Font.Gotham
			TextLabel_3.PlaceholderColor3 = Color3.fromRGB(178,178,178)
			TextLabel_3.PlaceholderText = "255"
			TextLabel_3.Text = "255"
			TextLabel_3.TextSize = 9
			TextLabel_3.TextTruncate = Enum.TextTruncate.AtEnd
			TextLabel_3.TextColor3 = Color3.fromRGB(255, 255, 255)

			addToTheme('Text & Icon', TextLabel_3)

			TextLabel_4.Parent = Red_1
			TextLabel_4.AnchorPoint = Vector2.new(1, 0.5)
			TextLabel_4.BackgroundColor3 = Color3.fromRGB(255,255,255)
			TextLabel_4.BackgroundTransparency = 1
			TextLabel_4.BorderColor3 = Color3.fromRGB(0,0,0)
			TextLabel_4.BorderSizePixel = 0
			TextLabel_4.Position = UDim2.new(0.980000019, 0,0.5, 0)
			TextLabel_4.Size = UDim2.new(0, 20,0, 20)
			TextLabel_4.Font = Enum.Font.Gotham
			TextLabel_4.Text = "Red"
			TextLabel_4.TextSize = 9
			TextLabel_4.TextXAlignment = Enum.TextXAlignment.Left
			TextLabel_4.TextColor3 = Color3.fromRGB(255, 255, 255)

			addToTheme('Text & Icon', TextLabel_4)

			Green_1.Name = "Green"
			Green_1.Parent = BoxColor
			Green_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Green_1.BackgroundTransparency = 1
			Green_1.BorderColor3 = Color3.fromRGB(0,0,0)
			Green_1.BorderSizePixel = 0
			Green_1.LayoutOrder = 2
			Green_1.Size = UDim2.new(1, 0,0, 21)

			BarValueGreen_1.Name = "BarValueGreen"
			BarValueGreen_1.Parent = Green_1
			BarValueGreen_1.AnchorPoint = Vector2.new(0, 0.5)
			BarValueGreen_1.BackgroundColor3 = Color3.fromRGB(217,217,217)
			BarValueGreen_1.BackgroundTransparency = 1
			BarValueGreen_1.BorderColor3 = Color3.fromRGB(0,0,0)
			BarValueGreen_1.BorderSizePixel = 0
			BarValueGreen_1.Position = UDim2.new(0, 0,0.5, 0)
			BarValueGreen_1.Size = UDim2.new(0.600000024, 0,0, 15)

			UICorner_3.Parent = BarValueGreen_1
			UICorner_3.CornerRadius = UDim.new(1,0)

			UIStroke_3.Parent = BarValueGreen_1
			UIStroke_3.Thickness = 1
			UIStroke_3.Color = Color3.fromRGB(255, 255, 255)
			UIStroke_3.Transparency = 0.95

			addToTheme('Function.Color Picker.Color Select.UIStroke', UIStroke_3)

			TextLabel_5.Name = "TextLabel"
			TextLabel_5.Parent = BarValueGreen_1
			TextLabel_5.BackgroundColor3 = Color3.fromRGB(255,255,255)
			TextLabel_5.BackgroundTransparency = 1
			TextLabel_5.BorderColor3 = Color3.fromRGB(0,0,0)
			TextLabel_5.BorderSizePixel = 0
			TextLabel_5.Size = UDim2.new(1, 0,1, 0)
			TextLabel_5.Font = Enum.Font.Gotham
			TextLabel_5.PlaceholderColor3 = Color3.fromRGB(178,178,178)
			TextLabel_5.PlaceholderText = "255"
			TextLabel_5.Text = "255"
			TextLabel_5.TextSize = 9
			TextLabel_5.TextTruncate = Enum.TextTruncate.AtEnd
			TextLabel_5.TextColor3 = Color3.fromRGB(255, 255, 255)

			addToTheme('Text & Icon', TextLabel_5)

			TextLabel_6.Parent = Green_1
			TextLabel_6.AnchorPoint = Vector2.new(1, 0.5)
			TextLabel_6.BackgroundColor3 = Color3.fromRGB(255,255,255)
			TextLabel_6.BackgroundTransparency = 1
			TextLabel_6.BorderColor3 = Color3.fromRGB(0,0,0)
			TextLabel_6.BorderSizePixel = 0
			TextLabel_6.Position = UDim2.new(0.980000019, 0,0.5, 0)
			TextLabel_6.Size = UDim2.new(0, 20,0, 20)
			TextLabel_6.Font = Enum.Font.Gotham
			TextLabel_6.Text = "Green"
			TextLabel_6.TextSize = 9
			TextLabel_6.TextXAlignment = Enum.TextXAlignment.Left
			TextLabel_6.TextColor3 = Color3.fromRGB(255, 255, 255)

			addToTheme('Text & Icon', TextLabel_6)

			Blue_1.Name = "Blue"
			Blue_1.Parent = BoxColor
			Blue_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Blue_1.BackgroundTransparency = 1
			Blue_1.BorderColor3 = Color3.fromRGB(0,0,0)
			Blue_1.BorderSizePixel = 0
			Blue_1.LayoutOrder = 3
			Blue_1.Size = UDim2.new(1, 0,0, 21)

			BarValueBlue_1.Name = "BarValueBlue"
			BarValueBlue_1.Parent = Blue_1
			BarValueBlue_1.AnchorPoint = Vector2.new(0, 0.5)
			BarValueBlue_1.BackgroundColor3 = Color3.fromRGB(217,217,217)
			BarValueBlue_1.BackgroundTransparency = 1
			BarValueBlue_1.BorderColor3 = Color3.fromRGB(0,0,0)
			BarValueBlue_1.BorderSizePixel = 0
			BarValueBlue_1.Position = UDim2.new(0, 0,0.5, 0)
			BarValueBlue_1.Size = UDim2.new(0.600000024, 0,0, 15)

			UICorner_4.Parent = BarValueBlue_1
			UICorner_4.CornerRadius = UDim.new(1,0)

			UIStroke_4.Parent = BarValueBlue_1
			UIStroke_4.Thickness = 1
			UIStroke_4.Color = Color3.fromRGB(255, 255, 255)
			UIStroke_4.Transparency = 0.95

			addToTheme('Function.Color Picker.Color Select.UIStroke', UIStroke_4)

			TextLabel_7.Name = "TextLabel"
			TextLabel_7.Parent = BarValueBlue_1
			TextLabel_7.BackgroundColor3 = Color3.fromRGB(255,255,255)
			TextLabel_7.BackgroundTransparency = 1
			TextLabel_7.BorderColor3 = Color3.fromRGB(0,0,0)
			TextLabel_7.BorderSizePixel = 0
			TextLabel_7.Size = UDim2.new(1, 0,1, 0)
			TextLabel_7.Font = Enum.Font.Gotham
			TextLabel_7.PlaceholderColor3 = Color3.fromRGB(178,178,178)
			TextLabel_7.PlaceholderText = "255"
			TextLabel_7.Text = "255"
			TextLabel_7.TextSize = 9
			TextLabel_7.TextTruncate = Enum.TextTruncate.AtEnd
			TextLabel_7.TextColor3 = Color3.fromRGB(255, 255, 255)

			addToTheme('Text & Icon', TextLabel_7)

			TextLabel_8.Parent = Blue_1
			TextLabel_8.AnchorPoint = Vector2.new(1, 0.5)
			TextLabel_8.BackgroundColor3 = Color3.fromRGB(255,255,255)
			TextLabel_8.BackgroundTransparency = 1
			TextLabel_8.BorderColor3 = Color3.fromRGB(0,0,0)
			TextLabel_8.BorderSizePixel = 0
			TextLabel_8.Position = UDim2.new(0.980000019, 0,0.5, 0)
			TextLabel_8.Size = UDim2.new(0, 20,0, 20)
			TextLabel_8.Font = Enum.Font.Gotham
			TextLabel_8.Text = "Blue"
			TextLabel_8.TextSize = 9
			TextLabel_8.TextXAlignment = Enum.TextXAlignment.Left
			TextLabel_8.TextColor3 = Color3.fromRGB(255, 255, 255)

			addToTheme('Text & Icon', TextLabel_8)

			local Shower = Instance.new("Frame")
			local UICornerShow = Instance.new("UICorner")
			local GlowDotShow = Instance.new("ImageLabel")

			Shower.Name = "Shower"
			Shower.Parent = ColorpickBar
			Shower.AnchorPoint = Vector2.new(1, 0)
			Shower.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
			Shower.BorderColor3 = Color3.fromRGB(0, 0, 0)
			Shower.BorderSizePixel = 0
			Shower.Position = UDim2.new(1, 0, 0.0500000007, 0)
			Shower.Size = UDim2.new(0, 40, 0, 15)

			UICornerShow.CornerRadius = UDim.new(1, 0)
			UICornerShow.Name = "UICornerShow"
			UICornerShow.Parent = Shower

			GlowDotShow.Name = "GlowDotShow"
			GlowDotShow.Parent = Shower
			GlowDotShow.AnchorPoint = Vector2.new(0.5, 0.5)
			GlowDotShow.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			GlowDotShow.BackgroundTransparency = 1.000
			GlowDotShow.BorderColor3 = Color3.fromRGB(0, 0, 0)
			GlowDotShow.BorderSizePixel = 0
			GlowDotShow.Position = UDim2.new(0.5, 0, 0.5, 0)
			GlowDotShow.Size = UDim2.new(1.25, 0, 1.5, 0)
			GlowDotShow.Image = "rbxassetid://105506802034513"
			GlowDotShow.ImageColor3 = Color3.fromRGB(255, 0, 0)
			GlowDotShow.ImageTransparency = 0.200

			local Click = click(ColorPicker)
			local ClickColor = click(Color_1)
			local ClickHue = click(Hue_1)
			local isopen = false

			local ColorH, ColorS, ColorV = 1, 1, 1
			local lastColorH = -1
			local ColorInput = nil
			local HueInput = nil
			local Mouse = game:GetService("Players").LocalPlayer:GetMouse()
			local lastColor = nil
			local ColorInput = nil
			local HueInput = nil
			local isTouchDevice = U.TouchEnabled

			local close
			local function open()
				closePopups(close)
				local targetX = Picker_1.AbsolutePosition.X - ColorpickBar.Parent.AbsolutePosition.X + Picker_1.Size.X.Offset - 145
				local targetY = Picker_1.AbsolutePosition.Y - ColorpickBar.Parent.AbsolutePosition.Y + Picker_1.Size.Y.Offset - 50
				tw({v = ColorpickBar, t = 0.15, s = Enum.EasingStyle.Exponential, d = "Out", g = {Size = UDim2.new(0, 200,0, 125), Position = UDim2.new(0, targetX, 0, targetY)}}):Play()
				tw({v = UIStroke_1, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out", g = {Transparency = 0.95}}):Play()
			end
			close = function()
				isopen = false
				tw({v = ColorpickBar, t = 0.15, s = Enum.EasingStyle.Exponential, d = "Out", g = {Size = UDim2.new(0, 200,0, 0)}}):Play()
				tw({v = UIStroke_1, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out", g = {Transparency = 1}}):Play()
			end
			registerPopup(close)

			U.InputBegan:Connect(function(A)
				if A.UserInputType == Enum.UserInputType.MouseButton1 or A.UserInputType == Enum.UserInputType.Touch then
					local B, C = ColorpickBar.AbsolutePosition, ColorpickBar.AbsoluteSize
					if game:GetService "Players".LocalPlayer:GetMouse().X < B.X or game:GetService "Players".LocalPlayer:GetMouse().X > B.X + C.X or game:GetService "Players".LocalPlayer:GetMouse().Y < (B.Y - 20 - 1) or game:GetService "Players".LocalPlayer:GetMouse().Y > B.Y + C.Y then
						close()
					end
				end
			end)

			Click.MouseButton1Click:Connect(function()
				isopen = not isopen
				if isopen then
					open()
				else
					close()
				end
			end)

			local function UpdateColorPicker(nope)
				Picker_1.BackgroundColor3 = Color3.fromHSV(ColorH, ColorS, ColorV)
				GlowDot_1.ImageColor3 = Color3.fromHSV(ColorH, ColorS, ColorV)
				Color_1.BackgroundColor3 = Color3.fromHSV(ColorH, 1, 1)

				Shower.BackgroundColor3 = Color3.fromHSV(ColorH, ColorS, ColorV)
				GlowDotShow.ImageColor3 = Color3.fromHSV(ColorH, ColorS, ColorV)

				local r, g, b = Picker_1.BackgroundColor3.R * 255, Picker_1.BackgroundColor3.G * 255, Picker_1.BackgroundColor3.B * 255

				TextLabel_3.Text = tostring(math.floor(r))
				TextLabel_5.Text = tostring(math.floor(g))
				TextLabel_7.Text = tostring(math.floor(b))

				local hex = string.format("#%02X%02X%02X", math.floor(r), math.floor(g), math.floor(b))
				TextLabel_1.Text = hex

				ColorH, ColorS, ColorV = Color3.toHSV(Picker_1.BackgroundColor3)

				if ColorS ~= 0 and ColorV ~= 0 then
					tw({v = ColorSelection_1, t = 0.15, s = Enum.EasingStyle.Exponential, d = "Out", g = {Position = UDim2.new(ColorS, 0, 1 - ColorV, 0)}}):Play()
				end
				if lastColorH ~= ColorH and ColorS ~= 0 and ColorV ~= 0 and ColorS ~= 255 and ColorV ~= 255 then
					lastColorH = ColorH
					tw({v = HueSelection_1, t = 0.15, s = Enum.EasingStyle.Exponential, d = "Out", g = {Position = UDim2.new(0.5, 0, 1 - ColorH, 0)}}):Play()
				end

				if lastColor ~= Picker_1.BackgroundColor3 then
					lastColor = Picker_1.BackgroundColor3
					setFlag(p.Flag, Color3.fromRGB(math.floor(r), math.floor(g), math.floor(b)))
					safeCall(Callback, math.floor(r), math.floor(g), math.floor(b))
				end
			end

			local function HexToRGB(hex)
				if hex:sub(1, 1) == "#" then
					hex = hex:sub(2)
				end

				if #hex == 6 then
					local r = tonumber(hex:sub(1, 2), 16) / 255
					local g = tonumber(hex:sub(3, 4), 16) / 255
					local b = tonumber(hex:sub(5, 6), 16) / 255
					return r, g, b
				else
					return 0, 0, 0
				end
			end

			local function UpdateColorFromText()
				local hex = TextLabel_1.Text:match("^#[%x]+$")
				if hex then
					local r, g, b = HexToRGB(hex)
					r = math.clamp(r, 0, 1)
					g = math.clamp(g, 0, 1)
					b = math.clamp(b, 0, 1)

					local h, s, v = Color3.toHSV(Color3.new(r, g, b))
					ColorH, ColorS, ColorV = h, s, v
					UpdateColorPicker(true)
				else
					local r = tonumber(TextLabel_3.Text) or 0
					local g = tonumber(TextLabel_5.Text) or 0
					local b = tonumber(TextLabel_7.Text) or 0

					r = math.clamp(r, 0, 255) / 255
					g = math.clamp(g, 0, 255) / 255
					b = math.clamp(b, 0, 255) / 255

					local h, s, v = Color3.toHSV(Color3.new(r, g, b))
					ColorH, ColorS, ColorV = h, s, v
					UpdateColorPicker(true)
				end
			end

			TextLabel_3.FocusLost:Connect(UpdateColorFromText)
			TextLabel_5.FocusLost:Connect(UpdateColorFromText)
			TextLabel_7.FocusLost:Connect(UpdateColorFromText)
			TextLabel_1.FocusLost:Connect(UpdateColorFromText)


			ColorH = 1 - (math.clamp(HueSelection_1.AbsolutePosition.Y - Hue_1.AbsolutePosition.Y, 0, Hue_1.AbsoluteSize.Y) / Hue_1.AbsoluteSize.Y)
			ColorS = (math.clamp(ColorSelection_1.AbsolutePosition.X - Color_1.AbsolutePosition.X, 0, Color_1.AbsoluteSize.X) / Color_1.AbsoluteSize.X)
			ColorV = 1 - (math.clamp(ColorSelection_1.AbsolutePosition.Y - Color_1.AbsolutePosition.Y, 0, Color_1.AbsoluteSize.Y) / Color_1.AbsoluteSize.Y)

			Picker_1.BackgroundColor3 = Value
			Color_1.BackgroundColor3 = Value

			ClickColor.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					if ColorInput then
						ColorInput:Disconnect()
					end

					ColorInput = RenderStepped:Connect(function()
						local ColorX = (math.clamp(Mouse.X - Color_1.AbsolutePosition.X, 0, Color_1.AbsoluteSize.X) /Color_1.AbsoluteSize.X)
						local ColorY = (math.clamp(Mouse.Y - Color_1.AbsolutePosition.Y, 0, Color_1.AbsoluteSize.Y) /Color_1.AbsoluteSize.Y)

						tw({v = ColorSelection_1, t = 0.15, s = Enum.EasingStyle.Exponential, d = "Out", g = {Position = UDim2.new(ColorX, 0, ColorY, 0)}}):Play()
						ColorS = ColorX
						ColorV = 1 - ColorY

						UpdateColorPicker(true)
					end)
				end
			end)

			ClickColor.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					if ColorInput then
						ColorInput:Disconnect()
					end
				end
			end)

			ClickHue.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					if HueInput then
						HueInput:Disconnect()
					end

					HueInput = RenderStepped:Connect(function()
						local HueY = (math.clamp(Mouse.Y - Hue_1.AbsolutePosition.Y, 0, Hue_1.AbsoluteSize.Y) /Hue_1.AbsoluteSize.Y)
						tw({v = HueSelection_1, t = 0.15, s = Enum.EasingStyle.Exponential, d = "Out", g = {Position = UDim2.new(0.5, 0, HueY, 0)}}):Play()
						ColorH = 1 - HueY

						UpdateColorPicker(true)
					end)
				end
			end)

			ClickHue.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					if HueInput then
						HueInput:Disconnect()
					end
				end
			end)

			if isTouchDevice then
				Color_1.InputBegan:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.Touch then
						if ColorInput then
							ColorInput:Disconnect()
						end

						ColorInput = RenderStepped:Connect(function()
							local ColorX = (math.clamp(Mouse.X - Color_1.AbsolutePosition.X, 0, Color_1.AbsoluteSize.X) / Color_1.AbsoluteSize.X)
							local ColorY = (math.clamp(Mouse.Y - Color_1.AbsolutePosition.Y, 0, Color_1.AbsoluteSize.Y) / Color_1.AbsoluteSize.Y)

							ColorSelection_1.Position = UDim2.new(ColorX, 0, ColorY, 0)
							ColorS = ColorX
							ColorV = 1 - ColorY

							UpdateColorPicker(true)
						end)
					end
				end)

				Color_1.InputEnded:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.Touch then
						if ColorInput then
							ColorInput:Disconnect()
						end
					end
				end)

				Hue_1.InputBegan:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.Touch then
						if HueInput then
							HueInput:Disconnect()
						end

						HueInput = RenderStepped:Connect(function()
							local HueY = (math.clamp(Mouse.Y - Hue_1.AbsolutePosition.Y, 0, Hue_1.AbsoluteSize.Y) / Hue_1.AbsoluteSize.Y)

							HueSelection_1.Position = UDim2.new(0.48, 0, HueY, 0)
							ColorH = 1 - HueY

							UpdateColorPicker(true)
						end)
					end
				end)

				Hue_1.InputEnded:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.Touch then
						if HueInput then
							HueInput:Disconnect()
						end
					end
				end)
			end

			-- UpdateColorPicker fires the callback once, since lastColor starts empty
			delay(0,function()
				ColorH, ColorS, ColorV = Color3.toHSV(Picker_1.BackgroundColor3)
				UpdateColorPicker(true)
			end)

			local New = {}

			function New:SetTitle(t)
				Config:SetTitle(t)
			end

			function New:SetDesc(t)
				Config:SetDesc(t)
			end

			-- Accepts a Color3, a "#RRGGBB" string, or { R = 0-255, G = 0-255, B = 0-255 }
			function New:SetValue(value)
				local current = Picker_1.BackgroundColor3
				local newColor
				if typeof(value) == "Color3" then
					newColor = value
				elseif type(value) == "string" then
					local ok, c = pcall(Color3.fromHex, value)
					newColor = ok and c or nil
				elseif type(value) == "table" then
					local r = math.clamp(tonumber(value.R) or current.R * 255, 0, 255)
					local g = math.clamp(tonumber(value.G) or current.G * 255, 0, 255)
					local b = math.clamp(tonumber(value.B) or current.B * 255, 0, 255)
					newColor = Color3.fromRGB(r, g, b)
				end
				if not newColor then
					return
				end
				ColorH, ColorS, ColorV = Color3.toHSV(newColor)
				ColorSelection_1.Position = UDim2.new(ColorS, 0, 1 - ColorV, 0)
				HueSelection_1.Position = UDim2.new(0.5, 0, 1 - ColorH, 0)
				UpdateColorPicker(true)
			end

			function New:Get()
				return Picker_1.BackgroundColor3
			end

			New._cleanup = function()
				pcall(close)
				ColorpickBar:Destroy()
			end

			return attachCommon(New, ColorPicker.Parent, p, "ColorPicker")
		end

		function Func:Textbox(p)
			p = p or {}
			local Title = p.Title or 'null'
			local Desc = p.Desc or ''
			local Image = p.Image or ''
			local Value = p.Value or ''
			local Placeholder = p.Placeholder or 'Paste Your Text'
			local ClearText = p.ClearText or p.ClearTextOnFocus or false
			local Callback = p.Callback or function() end

			local Textbox, Config = background(ScrollingFrame_1, Title, Desc, Image, 'Textbox')

			Config:SetTextTransparencyTitle(0)
			Config:SetSizeT(145)

			local F = Instance.new("Frame")
			local UIListLayout_1 = Instance.new("UIListLayout")
			local UIPadding_1 = Instance.new("UIPadding")
			local Frame_1 = Instance.new("Frame")
			local UICorner_1 = Instance.new("UICorner")
			local UIStroke_1 = Instance.new("UIStroke")
			local UIPadding_2 = Instance.new("UIPadding")
			local ImageLabel_1 = Instance.new("ImageLabel")
			local TextLabel_1 = Instance.new("TextBox")
			local Frame_2 = Instance.new("Frame")

			F.Name = "F"
			F.Parent = Textbox
			F.AnchorPoint = Vector2.new(1, 0.5)
			F.BackgroundColor3 = Color3.fromRGB(255,255,255)
			F.BackgroundTransparency = 1
			F.BorderColor3 = Color3.fromRGB(0,0,0)
			F.BorderSizePixel = 0
			F.Position = UDim2.new(1, 0,0.5, 0)
			F.Size = UDim2.new(0, 150,0.800000012, 0)

			UIListLayout_1.Parent = F
			UIListLayout_1.Padding = UDim.new(0,15)
			UIListLayout_1.FillDirection = Enum.FillDirection.Horizontal
			UIListLayout_1.HorizontalAlignment = Enum.HorizontalAlignment.Right
			UIListLayout_1.SortOrder = Enum.SortOrder.LayoutOrder
			UIListLayout_1.VerticalAlignment = Enum.VerticalAlignment.Center

			UIPadding_1.Parent = F
			UIPadding_1.PaddingRight = UDim.new(0,13)

			Frame_1.Parent = F
			Frame_1.BackgroundColor3 = themes[IsTheme].Function.Textbox['Value Background']
			Frame_1.BorderColor3 = Color3.fromRGB(0,0,0)
			Frame_1.BorderSizePixel = 0
			Frame_1.Size = UDim2.new(0, 130,0, 25)

			addToTheme('Function.Textbox.Value Background', Frame_1)

			UICorner_1.Parent = Frame_1
			UICorner_1.CornerRadius = UDim.new(0,4)

			UIStroke_1.Parent = Frame_1
			UIStroke_1.Color = Color3.fromRGB(255,255,255)
			UIStroke_1.Thickness = 1
			UIStroke_1.Transparency = 0.95

			addToTheme('Function.Textbox.Value Stroke', UIStroke_1)

			UIPadding_2.Parent = Frame_1
			UIPadding_2.PaddingLeft = UDim.new(0,5)
			UIPadding_2.PaddingRight = UDim.new(0,5)

			ImageLabel_1.Parent = Frame_1
			ImageLabel_1.AnchorPoint = Vector2.new(1, 0.5)
			ImageLabel_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			ImageLabel_1.BackgroundTransparency = 1
			ImageLabel_1.BorderColor3 = Color3.fromRGB(0,0,0)
			ImageLabel_1.BorderSizePixel = 0
			ImageLabel_1.Position = UDim2.new(1, 0,0.5, 0)
			ImageLabel_1.Size = UDim2.new(0, 15,0, 15)
			ImageLabel_1.Image = "rbxassetid://13868675087"
			ImageLabel_1.ImageTransparency = 0.30000001192092896

			addToTheme('Text & Icon', ImageLabel_1)

			TextLabel_1.Name = "TextLabel"
			TextLabel_1.Parent = Frame_1
			TextLabel_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			TextLabel_1.BackgroundTransparency = 1
			TextLabel_1.BorderColor3 = Color3.fromRGB(0,0,0)
			TextLabel_1.BorderSizePixel = 0
			TextLabel_1.Size = UDim2.new(0.800000012, 0,1, 0)
			TextLabel_1.Font = Enum.Font.GothamBold
			TextLabel_1.PlaceholderColor3 = Color3.fromRGB(178,178,178)
			TextLabel_1.PlaceholderText = Placeholder
			TextLabel_1.RichText = true
			TextLabel_1.Text = Value
			TextLabel_1.TextColor3 = Color3.fromRGB(255,255,255)
			TextLabel_1.TextSize = 10
			TextLabel_1.TextTransparency = 0.30000001192092896
			TextLabel_1.TextWrapped = true
			TextLabel_1.TextXAlignment = Enum.TextXAlignment.Left
			TextLabel_1.ClearTextOnFocus = ClearText == true

			addToTheme('Text & Icon', TextLabel_1)

			Frame_2.Parent = Frame_1
			Frame_2.AnchorPoint = Vector2.new(0.5, 1)
			Frame_2.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Frame_2.BackgroundTransparency = 0.949999988079071
			Frame_2.BorderColor3 = Color3.fromRGB(0,0,0)
			Frame_2.BorderSizePixel = 0
			Frame_2.Position = UDim2.new(0.5, 0,1, 0)
			Frame_2.Size = UDim2.new(1.05, 0,0, 2)

			local Numeric = p.Numeric == true
			local lastText = TextLabel_1.Text

			local function readValue()
				if Numeric then
					return tonumber(TextLabel_1.Text)
				end
				return TextLabel_1.Text
			end

			local function o()
				local text = TextLabel_1.Text
				if Numeric and text ~= "" and not tonumber(text) then
					-- reject anything that is not a number
					TextLabel_1.Text = lastText
					return
				end
				lastText = text
				setFlag(p.Flag, readValue())
				if #text > 0 then
					safeCall(Callback, readValue())
				end
			end

			TextLabel_1.FocusLost:Connect(function()
				o()
			end)

			delay(0, o)

			local New = {}

			function New:SetTitle(t)
				Config:SetTitle(t)
			end

			function New:SetDesc(t)
				Config:SetDesc(t)
			end

			function New:SetValue(t, silent)
				TextLabel_1.Text = t ~= nil and tostring(t) or ""
				lastText = TextLabel_1.Text
				setFlag(p.Flag, readValue())
				if not silent and #TextLabel_1.Text > 0 then
					safeCall(Callback, readValue())
				end
			end

			function New:Get()
				return readValue()
			end

			function New:SetClearTextOnFocus(t)
				TextLabel_1.ClearTextOnFocus = t == true
			end

			function New:SetPlaceholderText(t)
				TextLabel_1.PlaceholderText = t
			end

			return attachCommon(New, Textbox.Parent, p, "Textbox")
		end

		function Func:Image(p)
			p = p or {}
			local Height = p.Height or 150

			local RealBackground = Instance.new("Frame")
			local Background = Instance.new("Frame")
			local ImageLogo = Instance.new("ImageLabel")
			local UICorner_1 = Instance.new("UICorner")

			RealBackground.Name = "Real Background"
			RealBackground.Parent = ScrollingFrame_1
			RealBackground.BackgroundTransparency = 1
			RealBackground.BorderSizePixel = 0
			RealBackground.Size = UDim2.new(1, 0, 0, Height)
			RealBackground.ClipsDescendants = true

			Background.Name = "Background"
			Background.Parent = RealBackground
			Background.BackgroundTransparency = 1
			Background.BorderSizePixel = 0
			Background.Size = UDim2.new(1, 0, 1, 0)

			local function apply(image)
				local data = gl(image)
				ImageLogo.Image = data.Image
				ImageLogo.ImageRectSize = data.ImageRectSize
				ImageLogo.ImageRectOffset = data.ImageRectPosition
			end

			ImageLogo.Name = "Im"
			ImageLogo.Parent = Background
			ImageLogo.BackgroundTransparency = 1
			ImageLogo.Size = UDim2.new(1, 0, 1, 0)
			ImageLogo.ScaleType = Enum.ScaleType[p.ScaleType or "Crop"]
			apply(p.Image or 'rbxassetid://111362591084511')

			UICorner_1.Parent = ImageLogo
			UICorner_1.CornerRadius = UDim.new(0, p.CornerRadius or 6)

			local New = {}

			function New:SetImage(image)
				apply(image)
			end

			function New:SetHeight(h)
				RealBackground.Size = UDim2.new(1, 0, 0, h)
			end

			return attachCommon(New, RealBackground, p, "Image")
		end

		function Func:Divider(p)
			p = p or {}

			local RealBackground = Instance.new("Frame")
			local Background = Instance.new("Frame")
			local Line = Instance.new("Frame")

			RealBackground.Name = "Real Background"
			RealBackground.Parent = ScrollingFrame_1
			RealBackground.BackgroundTransparency = 1
			RealBackground.BorderSizePixel = 0
			RealBackground.Size = UDim2.new(1, 0, 0, 9)

			Background.Name = "Background"
			Background.Parent = RealBackground
			Background.BackgroundTransparency = 1
			Background.BorderSizePixel = 0
			Background.Size = UDim2.new(1, 0, 1, 0)

			Line.Name = "Line"
			Line.Parent = Background
			Line.AnchorPoint = Vector2.new(0.5, 0.5)
			Line.BackgroundColor3 = themes[IsTheme]['Text & Icon']
			Line.BackgroundTransparency = 0.9
			Line.BorderSizePixel = 0
			Line.Position = UDim2.new(0.5, 0, 0.5, 0)
			Line.Size = UDim2.new(1, -10, 0, 1)

			addToTheme('Text & Icon', Line)

			return attachCommon({}, RealBackground, p, "Divider")
		end

		-- Shared right-hand layout for bar-style rows (ProgressBar, RangeSlider)
		local function barRow(row, labelWidth)
			local F = Instance.new("Frame")
			local Layout = Instance.new("UIListLayout")
			local Padding = Instance.new("UIPadding")
			local ValueLabel = Instance.new("TextLabel")
			local Track = Instance.new("Frame")
			local Bar = Instance.new("Frame")
			local Fill = Instance.new("Frame")

			F.Name = "F"
			F.Parent = row
			F.AnchorPoint = Vector2.new(1, 0.5)
			F.BackgroundTransparency = 1
			F.BorderSizePixel = 0
			F.Position = UDim2.new(1, 0, 0.5, 0)
			F.Size = UDim2.new(0, 195, 0.8, 0)

			Layout.Parent = F
			Layout.Padding = UDim.new(0, 8)
			Layout.FillDirection = Enum.FillDirection.Horizontal
			Layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
			Layout.SortOrder = Enum.SortOrder.LayoutOrder
			Layout.VerticalAlignment = Enum.VerticalAlignment.Center

			Padding.Parent = F
			Padding.PaddingRight = UDim.new(0, 13)

			ValueLabel.Parent = F
			ValueLabel.BackgroundTransparency = 1
			ValueLabel.LayoutOrder = 1
			ValueLabel.Size = UDim2.new(0, labelWidth, 0, 20)
			ValueLabel.Font = Enum.Font.GothamBold
			ValueLabel.TextColor3 = themes[IsTheme]['Text & Icon']
			ValueLabel.TextSize = 11
			ValueLabel.TextTransparency = 0.2
			ValueLabel.TextXAlignment = Enum.TextXAlignment.Right

			addToTheme('Text & Icon', ValueLabel)

			Track.Parent = F
			Track.BackgroundTransparency = 1
			Track.BorderSizePixel = 0
			Track.Size = UDim2.new(0, 120, 0, 20)

			Bar.Parent = Track
			Bar.AnchorPoint = Vector2.new(0, 0.5)
			Bar.BackgroundColor3 = themes[IsTheme].Function.Slider['Slider Bar']
			Bar.BorderSizePixel = 0
			Bar.Position = UDim2.new(0, 0, 0.5, 0)
			Bar.Size = UDim2.new(1, 0, 0, 10)
			Instance.new("UICorner", Bar).CornerRadius = UDim.new(1, 0)

			addToTheme('Function.Slider.Slider Bar', Bar)

			Fill.Parent = Bar
			Fill.BackgroundColor3 = themes[IsTheme].Function.Slider['Slider Bar Value']
			Fill.BorderSizePixel = 0
			Fill.Size = UDim2.new(0, 0, 1, 0)
			Instance.new("UICorner", Fill).CornerRadius = UDim.new(1, 0)

			addToTheme('Function.Slider.Slider Bar Value', Fill)

			return ValueLabel, Track, Bar, Fill
		end

		local function formatNumber(v, decimals)
			if decimals and decimals > 0 then
				return string.format("%." .. decimals .. "f", v)
			end
			return tostring(math.floor(v + 0.5))
		end

		function Func:ProgressBar(p)
			p = p or {}
			local Max = p.Max or 100
			local Value = 0
			local Suffix = p.Suffix

			local Row, Config = background(ScrollingFrame_1, p.Title or 'null', p.Desc or '', p.Image or '', 'Slider')
			Config:SetTextTransparencyTitle(0)
			Config:SetSizeT(200)

			local ValueLabel, _, _, Fill = barRow(Row, 50)

			local function set(v)
				Value = math.clamp(tonumber(v) or 0, 0, Max)
				local ratio = Max > 0 and Value / Max or 0
				tw({v = Fill, t = 0.25, s = Enum.EasingStyle.Quad, d = "Out", g = {Size = UDim2.new(ratio, 0, 1, 0)}}):Play()
				if Suffix then
					ValueLabel.Text = formatNumber(Value) .. " " .. tostring(Suffix)
				else
					ValueLabel.Text = math.floor(ratio * 100 + 0.5) .. "%"
				end
			end

			set(p.Value or 0)

			local New = { NoSave = true }

			function New:SetTitle(t)
				Config:SetTitle(t)
			end

			function New:SetDesc(t)
				Config:SetDesc(t)
			end

			function New:SetValue(v)
				set(v)
			end

			function New:Increment(n)
				set(Value + (n or 1))
			end

			function New:SetMax(m)
				Max = m
				set(Value)
			end

			function New:Get()
				return Value
			end

			return attachCommon(New, Row.Parent, p, "ProgressBar")
		end

		function Func:RangeSlider(p)
			p = p or {}
			local Min = p.Min or 0
			local Max = p.Max or 100
			local Rounding = p.Rounding or 0
			local Callback = p.Callback or function() end
			local low = (type(p.Value) == "table" and p.Value[1]) or Min
			local high = (type(p.Value) == "table" and p.Value[2]) or Max

			local Row, Config = background(ScrollingFrame_1, p.Title or 'null', p.Desc or '', p.Image or '', 'Slider')
			Config:SetTextTransparencyTitle(0)
			Config:SetSizeT(210)

			local ValueLabel, Track, Bar, Fill = barRow(Row, 60)

			local function knob()
				local k = Instance.new("Frame")
				k.Parent = Bar
				k.AnchorPoint = Vector2.new(0.5, 0.5)
				k.BackgroundColor3 = themes[IsTheme].Function.Slider['Circle Value']
				k.BorderSizePixel = 0
				k.Size = UDim2.new(0, 13, 0, 13)
				k.ZIndex = 2
				Instance.new("UICorner", k).CornerRadius = UDim.new(1, 0)
				addToTheme('Function.Slider.Circle Value', k)
				return k
			end
			local KnobLow, KnobHigh = knob(), knob()

			local function round(v)
				local factor = 10 ^ Rounding
				return math.floor(v * factor + 0.5) / factor
			end

			local function ratio(v)
				return Max > Min and (v - Min) / (Max - Min) or 0
			end

			local lastLow, lastHigh

			local function set(a, b, silent)
				a = round(math.clamp(tonumber(a) or Min, Min, Max))
				b = round(math.clamp(tonumber(b) or Max, Min, Max))
				if a > b then
					a, b = b, a
				end
				low, high = a, b
				local ra, rb = ratio(low), ratio(high)
				Fill.Position = UDim2.new(ra, 0, 0, 0)
				Fill.Size = UDim2.new(rb - ra, 0, 1, 0)
				KnobLow.Position = UDim2.new(ra, 0, 0.5, 0)
				KnobHigh.Position = UDim2.new(rb, 0, 0.5, 0)
				ValueLabel.Text = formatNumber(low, Rounding) .. " - " .. formatNumber(high, Rounding)
				setFlag(p.Flag, { low, high })
				if not silent and (low ~= lastLow or high ~= lastHigh) then
					lastLow, lastHigh = low, high
					safeCall(Callback, low, high)
				end
			end

			local dragging

			local function move(input)
				local rel = math.clamp((input.Position.X - Bar.AbsolutePosition.X) / Bar.AbsoluteSize.X, 0, 1)
				local v = Min + rel * (Max - Min)
				if dragging == "low" then
					set(math.min(v, high), high)
				else
					set(low, math.max(v, low))
				end
			end

			local Click = click(Track)
			Click.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					local rel = (input.Position.X - Bar.AbsolutePosition.X) / Bar.AbsoluteSize.X
					local v = Min + rel * (Max - Min)
					-- grab whichever handle is closer
					dragging = math.abs(v - low) <= math.abs(v - high) and "low" or "high"
					move(input)
				end
			end)

			U.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					dragging = nil
				end
			end)

			U.InputChanged:Connect(function(input)
				if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
					move(input)
				end
			end)

			set(low, high)

			local New = {}

			function New:SetTitle(t)
				Config:SetTitle(t)
			end

			function New:SetDesc(t)
				Config:SetDesc(t)
			end

			function New:SetValue(t, silent)
				if type(t) == "table" then
					set(t[1], t[2], silent)
				end
			end

			function New:Get()
				return { low, high }
			end

			function New:SetMin(m)
				Min = m
				set(low, high)
			end

			function New:SetMax(m)
				Max = m
				set(low, high)
			end

			return attachCommon(New, Row.Parent, p, "RangeSlider")
		end

		return Func

	end

	local Notification = Instance.new("Frame")
	local UIPaddingUIListLayoutNotification_1 = Instance.new("UIPadding")
	local UIListLayoutNotification_1 = Instance.new("UIListLayout")

	Notification.Name = "Notification"
	Notification.Parent = ScreenGui
	Notification.AnchorPoint = Vector2.new(1, 1)
	Notification.BackgroundColor3 = Color3.fromRGB(255,255,255)
	Notification.BackgroundTransparency = 1
	Notification.BorderColor3 = Color3.fromRGB(0,0,0)
	Notification.BorderSizePixel = 0
	Notification.Position = UDim2.new(1, 0,1, 0)
	Notification.Size = UDim2.new(0, 100,0, 100)

	UIPaddingUIListLayoutNotification_1.Parent = Notification
	UIPaddingUIListLayoutNotification_1.PaddingBottom = UDim.new(0,20)
	UIPaddingUIListLayoutNotification_1.PaddingRight = UDim.new(0,5)

	UIListLayoutNotification_1.Parent = Notification
	UIListLayoutNotification_1.HorizontalAlignment = Enum.HorizontalAlignment.Right
	UIListLayoutNotification_1.SortOrder = Enum.SortOrder.LayoutOrder
	UIListLayoutNotification_1.VerticalAlignment = Enum.VerticalAlignment.Bottom

	local NotifyColors = {
		Success = Color3.fromRGB(64, 192, 112),
		Warning = Color3.fromRGB(235, 170, 50),
		Error = Color3.fromRGB(225, 70, 70),
	}

	local function showNotify(p)
		local Title = p.Title or 'null'
		local Desc = p.Desc or p.Content or ''
		local Time = p.Time or 5
		local Accent = NotifyColors[p.Type] or themes[IsTheme].Main

		local Shadow = Instance.new("ImageLabel")
		local UIPadding_1 = Instance.new("UIPadding")
		local Background_1 = Instance.new("CanvasGroup")
		local UICorner_1 = Instance.new("UICorner")
		local Frame_1 = Instance.new("Frame")
		local Stripe = Instance.new("Frame")
		local Text_1 = Instance.new("Frame")
		local UIPadding_2 = Instance.new("UIPadding")
		local Title_1 = Instance.new("TextLabel")
		local UIListLayout_1 = Instance.new("UIListLayout")
		local Description_1 = Instance.new("TextLabel")
		local Frame_2 = Instance.new("Frame")
		local CloseButton = Instance.new("TextButton")

		Shadow.Name = "Shadow"
		Shadow.Parent = Notification
		Shadow.BackgroundTransparency = 1
		Shadow.Size = UDim2.new(0, 200,0, 0)
		Shadow.Image = "rbxassetid://1316045217"
		Shadow.ImageColor3 = themes[IsTheme].Shadow
		Shadow.ImageTransparency = 0.5
		Shadow.ScaleType = Enum.ScaleType.Slice
		Shadow.SliceCenter = Rect.new(10, 10, 118, 118)

		addToTheme('Shadow', Shadow)

		UIPadding_1.Parent = Shadow
		UIPadding_1.PaddingBottom = UDim.new(0,5)
		UIPadding_1.PaddingLeft = UDim.new(0,5)
		UIPadding_1.PaddingRight = UDim.new(0,5)
		UIPadding_1.PaddingTop = UDim.new(0,5)

		Background_1.Name = "Background"
		Background_1.Parent = Shadow
		Background_1.AnchorPoint = Vector2.new(0.5, 0.5)
		Background_1.BackgroundColor3 = themes[IsTheme].Background
		Background_1.BorderSizePixel = 0
		Background_1.Position = UDim2.new(0.5, 0,0.5, 0)
		Background_1.Size = UDim2.new(1, 0,1, 0) - UDim2.fromOffset(5, 5)
		Background_1.ClipsDescendants = true
		Background_1.GroupTransparency = 1

		addToTheme('Background', Background_1)

		UICorner_1.Parent = Background_1
		UICorner_1.CornerRadius = UDim.new(0,6)

		-- countdown bar along the bottom, in the notification's accent colour
		Frame_1.Parent = Background_1
		Frame_1.AnchorPoint = Vector2.new(0, 1)
		Frame_1.BackgroundColor3 = Accent
		Frame_1.BackgroundTransparency = 0.4
		Frame_1.BorderSizePixel = 0
		Frame_1.Position = UDim2.new(0, 0,1, 0)
		Frame_1.Size = UDim2.new(1, 0,0, 3)

		-- accent stripe on the left edge
		Stripe.Parent = Background_1
		Stripe.BackgroundColor3 = Accent
		Stripe.BorderSizePixel = 0
		Stripe.Size = UDim2.new(0, 3, 1, 0)

		Text_1.Name = "Text"
		Text_1.Parent = Background_1
		Text_1.BackgroundTransparency = 1
		Text_1.BorderSizePixel = 0
		Text_1.Size = UDim2.new(1, 0,1, 0)

		UIPadding_2.Parent = Text_1
		UIPadding_2.PaddingBottom = UDim.new(0,6)
		UIPadding_2.PaddingLeft = UDim.new(0,10)
		UIPadding_2.PaddingRight = UDim.new(0,22)
		UIPadding_2.PaddingTop = UDim.new(0,6)

		Title_1.Name = "Title"
		Title_1.Parent = Text_1
		Title_1.AutomaticSize = Enum.AutomaticSize.Y
		Title_1.BackgroundTransparency = 1
		Title_1.Size = UDim2.new(1, 0,0, 0)
		Title_1.Font = Enum.Font.GothamBold
		Title_1.Text = tostring(Title)
		Title_1.TextColor3 = themes[IsTheme]['Text & Icon']
		Title_1.TextSize = 12
		Title_1.TextWrapped = true
		Title_1.RichText = true
		Title_1.TextXAlignment = Enum.TextXAlignment.Left
		Title_1.TextYAlignment = Enum.TextYAlignment.Top

		addToTheme('Text & Icon', Title_1)

		UIListLayout_1.Parent = Text_1
		UIListLayout_1.Padding = UDim.new(0,3)
		UIListLayout_1.SortOrder = Enum.SortOrder.LayoutOrder

		Description_1.Name = "Description"
		Description_1.Parent = Text_1
		Description_1.AutomaticSize = Enum.AutomaticSize.Y
		Description_1.BackgroundTransparency = 1
		Description_1.LayoutOrder = 2
		Description_1.Size = UDim2.new(1, 0,0, 0)
		Description_1.Font = Enum.Font.GothamBold
		Description_1.Text = tostring(Desc)
		Description_1.TextColor3 = themes[IsTheme]['Text & Icon']
		Description_1.TextSize = 10
		Description_1.TextTransparency = 0.5
		Description_1.TextWrapped = true
		Description_1.RichText = true
		Description_1.TextXAlignment = Enum.TextXAlignment.Left
		Description_1.TextYAlignment = Enum.TextYAlignment.Top
		Description_1.Visible = Desc ~= ''

		addToTheme('Text & Icon', Description_1)

		Frame_2.Parent = Text_1
		Frame_2.BackgroundColor3 = themes[IsTheme]['Text & Icon']
		Frame_2.BackgroundTransparency = 0.9
		Frame_2.BorderSizePixel = 0
		Frame_2.LayoutOrder = 1
		Frame_2.Size = UDim2.new(1, 0,0, 1)
		Frame_2.Visible = Desc ~= ''

		addToTheme('Text & Icon', Frame_2)

		CloseButton.Name = "Close"
		CloseButton.Parent = Background_1
		CloseButton.AnchorPoint = Vector2.new(1, 0)
		CloseButton.BackgroundTransparency = 1
		CloseButton.Position = UDim2.new(1, -4, 0, 4)
		CloseButton.Size = UDim2.new(0, 16, 0, 16)
		CloseButton.Font = Enum.Font.GothamBold
		CloseButton.Text = "×"
		CloseButton.TextColor3 = themes[IsTheme]['Text & Icon']
		CloseButton.TextSize = 16
		CloseButton.TextTransparency = 0.5

		addToTheme('Text & Icon', CloseButton)

		local function updateSize()
			task.defer(function()
				local newSize = UIListLayout_1.AbsoluteContentSize.Y + 28
				if Shadow.Parent and Shadow.Size.Y.Offset ~= newSize then
					Shadow.Size = UDim2.new(0, 200, 0, newSize)
				end
			end)
		end

		UIListLayout_1:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateSize)

		local dismissed = false
		CloseButton.MouseButton1Click:Connect(function()
			dismissed = true
		end)

		local g = tw({
			v = Shadow,
			t = 0.15,
			s = Enum.EasingStyle.Exponential,
			d = "InOut",
			g = {
				Size = UDim2.new(0, 200,0, 55)
			}
		})
		g:Play()
		g.Completed:Wait()
		updateSize()
		tw({
			v = Background_1,
			t = 0.15,
			s = Enum.EasingStyle.Linear,
			d = "InOut",
			g = {
				Size = UDim2.new(1, 0,1, 0),
				GroupTransparency = 0.1
			}
		}):Play()

		-- count down, stopping early if the close button is pressed
		for i = Time, 1, -1 do
			if dismissed then
				break
			end
			tw({v = Frame_1, t = 0.15, s = Enum.EasingStyle.Exponential, d = "Out", g = {Size = UDim2.new(i / Time, 0,0, 3)}}):Play()
			local started = os.clock()
			while os.clock() - started < 1 and not dismissed do
				task.wait(0.05)
			end
		end

		local f = tw({
			v = Background_1,
			t = 0.15,
			s = Enum.EasingStyle.Linear,
			d = "InOut",
			g = {
				Size = UDim2.new(1, 0,1, 0) - UDim2.fromOffset(5, 5),
				GroupTransparency = 1
			}
		})
		f:Play()
		f.Completed:Wait()
		Shadow.ImageTransparency = 1
		local shrink = tw({
			v = Shadow,
			t = 0.15,
			s = Enum.EasingStyle.Exponential,
			d = "InOut",
			g = {
				Size = UDim2.new(0, 200,0, 0)
			}
		})
		shrink:Play()
		shrink.Completed:Wait()
		Shadow:Destroy()
	end

	-- Notify never yields: it shows the toast in its own thread
	function Tabs:Notify(p)
		p = p or {}
		task.spawn(function()
			local ok, err = pcall(showNotify, p)
			if not ok and not Library.Unloaded then
				warn("[Sylex] notification error: " .. tostring(err))
			end
		end)
	end

	function Tabs:Dialog(p)
		p = p or {}
		if Shadow_1:FindFirstChild('Dialog') then
			return
		end
		local Title = p.Title or 'null'
		local Content = p.Content or p.Desc

		-- Buttons = { { Title, Color, Callback }, ... }; Button1/Button2 still work
		local Buttons = p.Buttons
		if not Buttons then
			Buttons = {}
			if p.Button1 then
				table.insert(Buttons, { Title = p.Button1.Title, Color = p.Button1.Color or Color3.fromRGB(0, 188, 0), Callback = p.Button1.Callback })
			end
			if p.Button2 then
				table.insert(Buttons, { Title = p.Button2.Title, Color = p.Button2.Color or Color3.fromRGB(226, 39, 6), Callback = p.Button2.Callback })
			end
			if #Buttons == 0 then
				Buttons = { { Title = "OK" } }
			end
		end

		closePopups()

		local Dialog = Instance.new("CanvasGroup")
		local UICorner_1 = Instance.new("UICorner")
		local Frame_1 = Instance.new("Frame")
		local TextLabel_1 = Instance.new("TextLabel")
		local UIListLayout_1 = Instance.new("UIListLayout")
		local Frame_2 = Instance.new("Frame")
		local UIListLayout_2 = Instance.new("UIListLayout")

		Dialog.Name = "Dialog"
		Dialog.Parent = Shadow_1
		Dialog.BackgroundColor3 = Color3.fromRGB(0,0,0)
		Dialog.BackgroundTransparency = 0.3
		Dialog.BorderSizePixel = 0
		Dialog.Size = UDim2.new(1, 0,1, 0)
		Dialog.GroupTransparency = 1
		Dialog.ZIndex = 20

		UICorner_1.Parent = Dialog
		UICorner_1.CornerRadius = UDim.new(0,17)

		Frame_1.Parent = Dialog
		Frame_1.AnchorPoint = Vector2.new(0.5, 0.5)
		Frame_1.BackgroundTransparency = 1
		Frame_1.Position = UDim2.new(0.5, 0,0.5, 0)
		Frame_1.Size = UDim2.new(1, -40, 1, -40)

		UIListLayout_1.Parent = Frame_1
		UIListLayout_1.Padding = UDim.new(0, 10)
		UIListLayout_1.HorizontalAlignment = Enum.HorizontalAlignment.Center
		UIListLayout_1.SortOrder = Enum.SortOrder.LayoutOrder
		UIListLayout_1.VerticalAlignment = Enum.VerticalAlignment.Center

		TextLabel_1.Parent = Frame_1
		TextLabel_1.BackgroundTransparency = 1
		TextLabel_1.Size = UDim2.new(1, 0, 0, 30)
		TextLabel_1.AutomaticSize = Enum.AutomaticSize.Y
		TextLabel_1.Font = Enum.Font.GothamBold
		TextLabel_1.RichText = true
		TextLabel_1.Text = tostring(Title)
		TextLabel_1.TextColor3 = Color3.fromRGB(255,255,255)
		TextLabel_1.TextSize = 20
		TextLabel_1.TextWrapped = true

		if Content then
			local ContentLabel = Instance.new("TextLabel")
			ContentLabel.Parent = Frame_1
			ContentLabel.BackgroundTransparency = 1
			ContentLabel.LayoutOrder = 1
			ContentLabel.Size = UDim2.new(1, 0, 0, 0)
			ContentLabel.AutomaticSize = Enum.AutomaticSize.Y
			ContentLabel.Font = Enum.Font.GothamBold
			ContentLabel.RichText = true
			ContentLabel.Text = tostring(Content)
			ContentLabel.TextColor3 = Color3.fromRGB(255,255,255)
			ContentLabel.TextTransparency = 0.4
			ContentLabel.TextSize = 12
			ContentLabel.TextWrapped = true
		end

		local Input
		if p.Input then
			local InputFrame = Instance.new("Frame")
			local InputStroke = Instance.new("UIStroke")
			Input = Instance.new("TextBox")

			InputFrame.Parent = Frame_1
			InputFrame.LayoutOrder = 2
			InputFrame.BackgroundColor3 = themes[IsTheme].Page
			InputFrame.BorderSizePixel = 0
			InputFrame.Size = UDim2.new(0, 260, 0, 32)
			Instance.new("UICorner", InputFrame).CornerRadius = UDim.new(0, 8)

			InputStroke.Parent = InputFrame
			InputStroke.Color = Color3.fromRGB(255, 255, 255)
			InputStroke.Transparency = 0.9

			Input.Parent = InputFrame
			Input.BackgroundTransparency = 1
			Input.Position = UDim2.new(0, 10, 0, 0)
			Input.Size = UDim2.new(1, -20, 1, 0)
			Input.ClearTextOnFocus = false
			Input.Font = Enum.Font.GothamBold
			Input.PlaceholderColor3 = Color3.fromRGB(150, 150, 160)
			Input.PlaceholderText = tostring(p.Input.Placeholder or "")
			Input.Text = tostring(p.Input.Value or "")
			Input.TextColor3 = Color3.fromRGB(255, 255, 255)
			Input.TextSize = 13
			Input.TextXAlignment = Enum.TextXAlignment.Left
		end

		Frame_2.Parent = Frame_1
		Frame_2.BackgroundTransparency = 1
		Frame_2.LayoutOrder = 3
		Frame_2.Size = UDim2.new(1, 0,0, 50)

		UIListLayout_2.Parent = Frame_2
		UIListLayout_2.Padding = UDim.new(0,10)
		UIListLayout_2.FillDirection = Enum.FillDirection.Horizontal
		UIListLayout_2.HorizontalAlignment = Enum.HorizontalAlignment.Center
		UIListLayout_2.SortOrder = Enum.SortOrder.LayoutOrder
		UIListLayout_2.VerticalAlignment = Enum.VerticalAlignment.Center

		local closing = false
		local function closeDialog()
			if closing then
				return
			end
			closing = true
			local f = tw({v = Dialog, t = 0.25, s = Enum.EasingStyle.Linear, d = "Out", g = {GroupTransparency = 1}})
			f:Play()
			f.Completed:Wait()
			Dialog:Destroy()
		end

		local buttonWidth = math.clamp(math.floor((Shadow_1.AbsoluteSize.X - 80) / #Buttons) - 10, 80, 130)

		for index, info in ipairs(Buttons) do
			local Button = Instance.new("Frame")
			local Corner = Instance.new("UICorner")
			local Gradient = Instance.new("UIGradient")
			local Stroke = Instance.new("UIStroke")
			local StrokeGradient = Instance.new("UIGradient")
			local Label = Instance.new("TextLabel")
			local LabelStroke = Instance.new("UIStroke")

			Button.Name = "Button" .. index
			Button.Parent = Frame_2
			Button.LayoutOrder = index
			Button.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Button.BorderSizePixel = 0
			Button.Size = UDim2.new(0, buttonWidth,0, 40)

			Corner.Parent = Button
			Corner.CornerRadius = UDim.new(1,0)

			Gradient.Parent = Button
			Gradient.Color = ColorSequence.new{ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)), ColorSequenceKeypoint.new(1, Color3.fromRGB(124, 124, 124))}

			Stroke.Parent = Button
			Stroke.Color = Color3.fromRGB(255,255,255)
			Stroke.Thickness = 2

			StrokeGradient.Parent = Stroke
			StrokeGradient.Color = ColorSequence.new{ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)), ColorSequenceKeypoint.new(1, Color3.fromRGB(124, 124, 124))}
			StrokeGradient.Rotation = 180

			Label.Parent = Button
			Label.BackgroundTransparency = 1
			Label.Size = UDim2.new(1, 0,1, 0)
			Label.Font = Enum.Font.GothamBold
			Label.Text = tostring(info.Title or 'null')
			Label.TextColor3 = info.Color or Color3.fromRGB(40, 40, 40)
			Label.TextSize = 16
			Label.TextTruncate = Enum.TextTruncate.AtEnd

			LabelStroke.Parent = Label
			LabelStroke.Thickness = 1
			LabelStroke.Transparency = 0.95

			click(Button).MouseButton1Click:Connect(function()
				if closing then
					return
				end
				tw({v = Label, t = 0.15, s = Enum.EasingStyle.Back, d = "Out", g = {TextSize = 14}}):Play()
				delay(.06, function()
					tw({v = Label, t = 0.15, s = Enum.EasingStyle.Back, d = "Out", g = {TextSize = 16}}):Play()
				end)
				safeCall(info.Callback, Input and Input.Text or nil)
				closeDialog()
			end)
		end

		tw({v = Dialog, t = 0.25, s = Enum.EasingStyle.Linear, d = "Out", g = {GroupTransparency = 0}}):Play()

		return {
			Close = function()
				task.spawn(closeDialog)
			end,
		}
	end

	do
		local Size_1 = Instance.new("TextButton")

		Size_1.Name = "Size"
		Size_1.Parent = Background_1
		Size_1.Active = true
		Size_1.AnchorPoint = Vector2.new(1, 1)
		Size_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
		Size_1.BackgroundTransparency = 1
		Size_1.BorderColor3 = Color3.fromRGB(0,0,0)
		Size_1.BorderSizePixel = 0
		Size_1.Position = UDim2.new(1, 0,1, 0)
		Size_1.Size = UDim2.new(0, 20,0, 20)
		Size_1.Font = Enum.Font.SourceSans
		Size_1.Text = ""
		Size_1.TextSize = 14

		local SizeFrame = Instance.new("Frame")
		local ImageLabel_1 = Instance.new("ImageLabel")
		local UICorner_1 = Instance.new("UICorner")

		SizeFrame.Name = "SizeFrame"
		SizeFrame.Parent = Background_1
		SizeFrame.BackgroundColor3 = Color3.fromRGB(0,0,0)
		SizeFrame.BackgroundTransparency = 1
		SizeFrame.BorderColor3 = Color3.fromRGB(0,0,0)
		SizeFrame.BorderSizePixel = 0
		SizeFrame.Size = UDim2.new(1, 0,1, 0)

		ImageLabel_1.Parent = SizeFrame
		ImageLabel_1.AnchorPoint = Vector2.new(0.5, 0.5)
		ImageLabel_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
		ImageLabel_1.BackgroundTransparency = 1
		ImageLabel_1.BorderColor3 = Color3.fromRGB(0,0,0)
		ImageLabel_1.BorderSizePixel = 0
		ImageLabel_1.Position = UDim2.new(0.5, 0,0.5, 0)
		ImageLabel_1.Size = UDim2.new(0, 100,0, 100)
		ImageLabel_1.Image = "rbxassetid://13857987062"
		ImageLabel_1.ImageTransparency = 1

		UICorner_1.Parent = SizeFrame
		UICorner_1.CornerRadius = UDim.new(0,17)

		Size_1.MouseButton1Down:Connect(function()
			R = true
			closePopups()
		end)

		local isZ = false
		local originalSize, originalPosition

		Minisize_1.MouseButton1Click:Connect(function()
			closePopups()
			if not isZ then
				originalSize = Shadow_1.Size
				originalPosition = Shadow_1.Position
				tw({v = Shadow_1, t = 0.15, s = Enum.EasingStyle.Exponential, d = "Out", g = {
					Size = UDim2.new(1, 0, 1, 0),
					Position = UDim2.new(0, 0, 0, 0)
				}}):Play()
				Minisize_1.Image = "rbxassetid://13857981896"
			else
				Minisize_1.Image = "rbxassetid://13857987062"
				tw({v = Shadow_1, t = 0.15, s = Enum.EasingStyle.Exponential, d = "Out", g = {
					Size = originalSize,
					Position = originalPosition
				}}):Play()
			end
			isZ = not isZ
		end)

		if not HAA then
			local AP, PAZ = Shadow_1.AbsolutePosition, Shadow_1.Parent.AbsoluteSize
			local NP = UDim2.new((AP.X / PAZ.X),
				Shadow_1.Position.X.Offset,
				(AP.Y / PAZ.Y),
				Shadow_1.Position.Y.Offset)

			Shadow_1.AnchorPoint = Vector2.new(0, 0)
			Shadow_1.Position = NP
			HAA = true
		end

		--// Remember window position and size between runs
		local stateName = tostring(Title):gsub("<.->", ""):gsub("[^%w%-_ ]", ""):gsub("%s+", "_")
		local stateFile = "Sylex/windows/" .. (stateName ~= "" and stateName or "window") .. ".json"

		local function saveWindowState()
			if not SaveState or not hasFiles then
				return
			end
			local pos = isZ and originalPosition or Shadow_1.Position
			local size = isZ and originalSize or Shadow_1.Size
			writeFile(stateFile, HttpService:JSONEncode({
				pos = { pos.X.Scale, pos.X.Offset, pos.Y.Scale, pos.Y.Offset },
				size = { size.X.Offset, size.Y.Offset },
			}))
		end
		Library._saveWindowState = saveWindowState

		if SaveState then
			local raw = readFile(stateFile)
			local ok, data = pcall(function()
				return HttpService:JSONDecode(raw)
			end)
			if raw and ok and type(data) == "table" and type(data.pos) == "table" and type(data.size) == "table" then
				Shadow_1.Size = UDim2.new(0, math.max(450, tonumber(data.size[1]) or 530), 0, math.max(220, tonumber(data.size[2]) or 400))
				Shadow_1.Position = UDim2.new(tonumber(data.pos[1]) or 0, tonumber(data.pos[2]) or 0, tonumber(data.pos[3]) or 0, tonumber(data.pos[4]) or 0)
				updateScale()
				task.defer(function()
					-- pull the window back on screen if the saved spot is off the edge (e.g. a smaller monitor)
					local viewport = ScreenGui.AbsoluteSize
					local ap, as = Shadow_1.AbsolutePosition, Shadow_1.AbsoluteSize
					if ap.X < -as.X / 2 or ap.Y < -10 or ap.X > viewport.X - 60 or ap.Y > viewport.Y - 40 then
						Shadow_1.Position = UDim2.new(0.5, -as.X / 2, 0.5, -as.Y / 2)
					end
				end)
			end
		end

		U.InputEnded:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
				if R then
					R = false
					saveWindowState()
				end
				tw({v = SizeFrame, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out", g = {BackgroundTransparency = 1}}):Play()
				tw({v = ImageLabel_1, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out", g = {ImageTransparency = 1}}):Play()
			end
		end)

		U.InputChanged:Connect(function(i)
			if not isZ and R and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
				-- divide by the UI scale so resizing tracks the cursor on scaled-down screens
				local scale = WindowScale.Scale > 0 and WindowScale.Scale or 1
				local nW = math.max(450, (i.Position.X - Shadow_1.AbsolutePosition.X) / scale)
				local nH = math.max(220, (i.Position.Y - Shadow_1.AbsolutePosition.Y) / scale)
				local nZ = UDim2.new(0, nW, 0, nH)
				tw({v = Shadow_1, t = 0.05, s = Enum.EasingStyle.Exponential, d = "Out", g = {Size = nZ}}):Play()
				tw({v = SizeFrame, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out", g = {BackgroundTransparency = 0.6}}):Play()
				tw({v = ImageLabel_1, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out", g = {ImageTransparency = 0}}):Play()
				ImageLabel_1.Image = 'rbxassetid://13857987062'
			elseif isZ and R and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
				tw({v = SizeFrame, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out", g = {BackgroundTransparency = 0.6}}):Play()
				tw({v = ImageLabel_1, t = 0.15, s = Enum.EasingStyle.Linear, d = "Out", g = {ImageTransparency = 0}}):Play()
				ImageLabel_1.Image = 'rbxassetid://14906268026'
			end
		end)

		lak(Topbar_1, Shadow_1, closePopups, saveWindowState)

		local isopen = false
		local oSize
		local function closeui()
			isopen = not isopen
			closePopups()
			if Library._hideTooltip then
				Library._hideTooltip()
			end
			if isopen then
				oSize = Background_1.Size
				local close = tw({
					v = Background_1,
					t = 0.15,
					s = Enum.EasingStyle.Linear,
					d = "InOut",
					g = {
						GroupTransparency = 1,
						Size = oSize - UDim2.fromOffset(5, 5)
					}
				})
				close:Play()
				close.Completed:Wait()
				Shadow_1.Visible = false
			else
				Shadow_1.Visible = true
				local open = tw({
					v = Background_1,
					t = 0.15,
					s = Enum.EasingStyle.Linear,
					d = "InOut",
					g = {
						GroupTransparency = 0,
						Size = oSize
					}
				})
				open:Play()
			end
		end

		ChSize_1.MouseButton1Click:Connect(closeui)

		U.InputBegan:Connect(function(i)
			if i.KeyCode == Keybind then
				local focusedTextBox = U:GetFocusedTextBox()
				if not focusedTextBox then
					closeui()
				end
			end
		end)

		local CallTheme = function(v)
			if not themes[v] then
				return
			end
			IsTheme = v
			Library.Theme = v
			Library:setTheme(themes[v])
		end
		local ThemeDrop = addDropdownSelect(DropdownValue_1, DropdownValue_1, false, CallTheme, Theme, themes.index)
		Library._themeDropdowns = Library._themeDropdowns or {}
		table.insert(Library._themeDropdowns, ThemeDrop)
		Library.Theme = Theme

		Close_1.MouseButton1Click:Connect(function()
			Tabs:Dialog({
				Title = "Do you want to <font color='#FF0000'>close</font> the ui?",
				Button1 = {
					Title = 'Confirm',
					Color = Color3.fromRGB(0, 188, 0),
					Callback = function()
						Library:Unload()
					end,
				},
				Button2 = {
					Title = 'Cancel',
					Color = Color3.fromRGB(226, 39, 6),
				}
			})
		end)

		--// Window methods

		function Tabs:Toggle()
			task.spawn(closeui)
		end

		function Tabs:IsVisible()
			return not isopen
		end

		function Tabs:SetKeybind(key)
			if typeof(key) == "EnumItem" then
				Keybind = key
			end
		end

		function Tabs:GetKeybind()
			return Keybind
		end

		function Tabs:SetTheme(name)
			if themes[name] then
				ThemeDrop:SetValue(name)
			end
		end

		function Tabs:GetTheme()
			return IsTheme
		end

		-- Recolours the accent of the current theme (selected tab, sliders, toggles, scrollbars)
		function Tabs:SetAccent(color)
			if typeof(color) ~= "Color3" then
				return
			end
			local t = themes[IsTheme]
			local dark = color:Lerp(Color3.new(0, 0, 0), 0.5)
			t.Main = color
			t.Function.Slider['Slider Bar Value'] = color
			t.Function.Slider['Slider Bar'] = dark
			t.Function.Toggle.True['Toggle Value'] = color
			t.Function.Toggle.True['Toggle Background'] = dark
			t.Function.Keybind.True['Toggle Value'] = color
			t.Function.Keybind.True['Toggle Background'] = dark
			Library:setTheme(t)
		end

		function Tabs:Destroy()
			Library:Unload()
		end

		function Tabs:SaveConfig(name)
			return Library:SaveConfig(name)
		end

		function Tabs:LoadConfig(name)
			return Library:LoadConfig(name)
		end

		function Tabs:DeleteConfig(name)
			return Library:DeleteConfig(name)
		end

		function Tabs:ListConfigs()
			return Library:ListConfigs()
		end

		Library._window = Tabs

		--// Overlays

		local function overlayFrame(name, position)
			local Holder = Instance.new("Frame")
			local Stroke = Instance.new("UIStroke")

			Holder.Name = name
			Holder.Parent = ScreenGui
			Holder.BackgroundColor3 = themes[IsTheme].Background
			Holder.BorderSizePixel = 0
			Holder.Position = position
			Holder.ZIndex = 5
			Holder.Active = true
			Instance.new("UICorner", Holder).CornerRadius = UDim.new(0, 6)

			addToTheme('Background', Holder)

			Stroke.Parent = Holder
			Stroke.Color = Color3.fromRGB(255, 255, 255)
			Stroke.Transparency = 0.9

			lak(Holder, Holder)
			return Holder
		end

		local function overlayLabel(parent, text, size, transparency)
			local Label = Instance.new("TextLabel")
			Label.Parent = parent
			Label.BackgroundTransparency = 1
			Label.Font = Enum.Font.GothamBold
			Label.RichText = true
			Label.Text = text
			Label.TextColor3 = themes[IsTheme]['Text & Icon']
			Label.TextSize = size or 11
			Label.TextTransparency = transparency or 0
			Label.TextXAlignment = Enum.TextXAlignment.Left
			Label.ZIndex = 6
			addToTheme('Text & Icon', Label)
			return Label
		end

		-- Small draggable bar showing your title, FPS and ping
		function Tabs:Watermark(p)
			p = p or {}
			local Text = p.Text or Title
			local ShowFPS = p.FPS ~= false
			local ShowPing = p.Ping ~= false

			local Holder = overlayFrame("Watermark", p.Position or UDim2.new(0, 10, 0, 10))
			Holder.AutomaticSize = Enum.AutomaticSize.X
			Holder.Size = UDim2.new(0, 0, 0, 26)

			local Padding = Instance.new("UIPadding")
			Padding.Parent = Holder
			Padding.PaddingLeft = UDim.new(0, 10)
			Padding.PaddingRight = UDim.new(0, 10)

			local Label = overlayLabel(Holder, tostring(Text), 11)
			Label.AutomaticSize = Enum.AutomaticSize.X
			Label.Size = UDim2.new(0, 0, 1, 0)

			local frames = 0
			RenderStepped:Connect(function()
				frames = frames + 1
			end)

			task.spawn(function()
				while Holder.Parent and not Library.Unloaded do
					task.wait(0.5)
					local parts = { tostring(Text) }
					if ShowFPS then
						table.insert(parts, (frames * 2) .. " fps")
					end
					if ShowPing then
						local ok, ping = pcall(function()
							return LocalPlayer:GetNetworkPing()
						end)
						if ok and ping then
							table.insert(parts, math.floor(ping * 1000 + 0.5) .. " ms")
						end
					end
					frames = 0
					Label.Text = table.concat(parts, "  |  ")
				end
			end)

			local Object = {}
			function Object:SetText(t)
				Text = t
				Label.Text = tostring(t)
			end
			function Object:SetVisible(v)
				Holder.Visible = v
			end
			function Object:Destroy()
				Holder:Destroy()
			end
			return Object
		end

		-- Lists keybinds that are switched on (or all of them with ShowAll = true)
		function Tabs:KeybindList(p)
			p = p or {}

			local Holder = overlayFrame("KeybindList", p.Position or UDim2.new(0, 10, 0.35, 0))
			Holder.AutomaticSize = Enum.AutomaticSize.Y
			Holder.Size = UDim2.new(0, 180, 0, 0)

			local Padding = Instance.new("UIPadding")
			Padding.Parent = Holder
			Padding.PaddingTop = UDim.new(0, 8)
			Padding.PaddingBottom = UDim.new(0, 8)
			Padding.PaddingLeft = UDim.new(0, 10)
			Padding.PaddingRight = UDim.new(0, 10)

			local Layout = Instance.new("UIListLayout")
			Layout.Parent = Holder
			Layout.Padding = UDim.new(0, 4)
			Layout.SortOrder = Enum.SortOrder.LayoutOrder

			local Header = overlayLabel(Holder, p.Title or "Keybinds", 12)
			Header.Size = UDim2.new(1, 0, 0, 16)
			Header.LayoutOrder = 0

			local Line = Instance.new("Frame")
			Line.Parent = Holder
			Line.BackgroundColor3 = themes[IsTheme].Main
			Line.BorderSizePixel = 0
			Line.LayoutOrder = 1
			Line.Size = UDim2.new(1, 0, 0, 1)
			Line.ZIndex = 6
			addToTheme('Main', Line)

			local rows = {}

			local function refresh()
				for _, row in ipairs(rows) do
					row:Destroy()
				end
				table.clear(rows)
				for index, entry in ipairs(keybindRegistry) do
					local key, value, press = entry.Get()
					if p.ShowAll or (value and not press) then
						local Row = overlayLabel(Holder, entry.Title, 11, value and 0 or 0.5)
						Row.LayoutOrder = index + 1
						Row.Size = UDim2.new(1, 0, 0, 14)
						Row.TextTruncate = Enum.TextTruncate.AtEnd

						local KeyLabel = overlayLabel(Row, "[" .. (typeof(key) == "EnumItem" and key.Name or tostring(key)) .. "]", 11, 0.4)
						KeyLabel.Size = UDim2.new(1, 0, 1, 0)
						KeyLabel.TextXAlignment = Enum.TextXAlignment.Right

						table.insert(rows, Row)
					end
				end
			end

			Library._refreshKeybindList = refresh
			refresh()

			local Object = {}
			function Object:SetVisible(v)
				Holder.Visible = v
			end
			function Object:Refresh()
				refresh()
			end
			function Object:Destroy()
				Library._refreshKeybindList = nil
				Holder:Destroy()
			end
			return Object
		end

		--// Ready-made settings tab: theme, accent, menu key, configs, overlays, unload
		function Tabs:SettingsTab(p)
			p = p or {}
			local Settings = Tabs:Tab({ Title = p.Title or "Settings", Icon = p.Icon or "settings" })

			Settings:Section({ Title = "Interface" })

			Settings:Dropdown({
				Title = "Theme",
				List = Library:GetThemes(),
				Value = IsTheme,
				Flag = "SylexTheme",
				Callback = function(v)
					if v and v ~= IsTheme then
						Tabs:SetTheme(v)
					end
				end,
			})

			Settings:ColorPicker({
				Title = "Accent Color",
				Value = themes[IsTheme].Function.Toggle.True['Toggle Value'],
				Flag = "SylexAccent",
				Callback = function(r, g, b)
					local color = Color3.fromRGB(r, g, b)
					-- skip the initial callback, which just reports the theme's own accent
					if color:ToHex() ~= themes[IsTheme].Function.Toggle.True['Toggle Value']:ToHex() then
						Tabs:SetAccent(color)
					end
				end,
			})

			Settings:Keybind({
				Title = "Menu Keybind",
				Desc = "Hides and shows this window",
				Mode = "Press",
				Key = Keybind,
				Flag = "SylexMenuKey",
				Callback = function(key)
					Tabs:SetKeybind(key)
				end,
			})

			if p.Overlays ~= false then
				local watermark, keybindList

				Settings:Section({ Title = "Overlays" })

				Settings:Toggle({
					Title = "Watermark",
					Desc = "Title, FPS and ping in the corner",
					Value = false,
					Flag = "SylexWatermark",
					Callback = function(v)
						if v and not watermark then
							watermark = Tabs:Watermark()
						end
						if watermark then
							watermark:SetVisible(v)
						end
					end,
				})

				Settings:Toggle({
					Title = "Keybind List",
					Desc = "Shows which keybinds are on",
					Value = false,
					Flag = "SylexKeybindList",
					Callback = function(v)
						if v and not keybindList then
							keybindList = Tabs:KeybindList()
						end
						if keybindList then
							keybindList:SetVisible(v)
						end
					end,
				})
			end

			if hasFiles then
				local selected
				Settings:Section({ Title = "Configuration" })

				local NameBox = Settings:Textbox({
					Title = "Config Name",
					Placeholder = "default",
					ClearText = false,
				})

				local ConfigList = Settings:Dropdown({
					Title = "Saved Configs",
					List = Library:ListConfigs(),
					Value = nil,
					Callback = function(v)
						selected = v
					end,
				})

				local function chosenName()
					local typed = NameBox:Get()
					if typed and typed ~= "" then
						return typed
					end
					return selected or "default"
				end

				Settings:Button({
					Title = "Save Config",
					Callback = function()
						local name = chosenName()
						if Library:SaveConfig(name) then
							ConfigList:Refresh(Library:ListConfigs())
							Tabs:Notify({ Title = "Config saved", Desc = name, Type = "Success", Time = 3 })
						else
							Tabs:Notify({ Title = "Couldn't save config", Type = "Error", Time = 3 })
						end
					end,
				})

				Settings:Button({
					Title = "Load Config",
					Callback = function()
						local name = selected or chosenName()
						if Library:LoadConfig(name) then
							Tabs:Notify({ Title = "Config loaded", Desc = name, Type = "Success", Time = 3 })
						else
							Tabs:Notify({ Title = "Config not found", Desc = name, Type = "Warning", Time = 3 })
						end
					end,
				})

				Settings:Button({
					Title = "Set as Autoload",
					Desc = "LoadConfig() with no name loads this one",
					Callback = function()
						local name = selected or chosenName()
						writeFile(Library.ConfigFolder .. "/autoload.txt", name)
						Tabs:Notify({ Title = "Autoload set", Desc = name, Type = "Success", Time = 3 })
					end,
				})

				Settings:Button({
					Title = "Delete Config",
					Callback = function()
						local name = selected or chosenName()
						Tabs:Dialog({
							Title = "Delete config '" .. name .. "'?",
							Buttons = {
								{ Title = "Delete", Color = Color3.fromRGB(226, 39, 6), Callback = function()
									Library:DeleteConfig(name)
									selected = nil
									ConfigList:Refresh(Library:ListConfigs())
								end },
								{ Title = "Cancel" },
							},
						})
					end,
				})
			end

			Settings:Section({ Title = "Share" })

			Settings:Button({
				Title = "Copy Config Code",
				Desc = "Copies your current settings as one line of text",
				Callback = function()
					Library:ExportConfig()
					local copied = type(setclipboard) == "function" or type(toclipboard) == "function"
					Tabs:Notify({
						Title = copied and "Config code copied" or "Clipboard not supported",
						Desc = copied and "Send it to a friend so they can import it." or "",
						Type = copied and "Success" or "Warning",
						Time = 3,
					})
				end,
			})

			Settings:Button({
				Title = "Import Config Code",
				Desc = "Paste a code someone shared with you",
				Callback = function()
					Tabs:Dialog({
						Title = "Import config code",
						Input = { Placeholder = "SYLEX1:..." },
						Buttons = {
							{ Title = "Import", Color = Color3.fromRGB(0, 188, 0), Callback = function(code)
								if Library:ImportConfig(code) then
									Tabs:Notify({ Title = "Config imported", Type = "Success", Time = 3 })
								else
									Tabs:Notify({ Title = "That code isn't valid", Type = "Error", Time = 3 })
								end
							end },
							{ Title = "Cancel" },
						},
					})
				end,
			})

			Settings:Section({ Title = "Other" })

			Settings:Button({
				Title = "Unload UI",
				Desc = "Closes the window and stops all of its connections",
				Callback = function()
					Tabs:Dialog({
						Title = "Unload the UI?",
						Buttons = {
							{ Title = "Unload", Color = Color3.fromRGB(226, 39, 6), Callback = function()
								Library:Unload()
							end },
							{ Title = "Cancel" },
						},
					})
				end,
			})

			return Settings
		end

		do
			local CloseUI = p.CloseUIButton
			local CloseUIShadow = Instance.new("ImageLabel")
			local UIPaddingCloseUI_1 = Instance.new("UIPadding")
			local BackgroundCloseUI_1 = Instance.new("Frame")
			local UICornerCloseUI_1 = Instance.new("UICorner")
			local FrameCloseUI_1 = Instance.new("Frame")
			local Title_1 = Instance.new("TextLabel")

			CloseUIShadow.Name = "CloseUIShadow"
			CloseUIShadow.Parent = ScreenGui
			CloseUIShadow.BackgroundColor3 = Color3.fromRGB(163,162,165)
			CloseUIShadow.BackgroundTransparency = 1
			CloseUIShadow.Position = UDim2.new(0, 0,0.200000003, 0)
			CloseUIShadow.Size = UDim2.new(0, 70,0, 40)
			CloseUIShadow.Image = "rbxassetid://1316045217"
			CloseUIShadow.ImageColor3 = themes[Theme].Shadow
			CloseUIShadow.ImageTransparency = 0.5
			CloseUIShadow.ScaleType = Enum.ScaleType.Slice
			CloseUIShadow.SliceCenter = Rect.new(10, 10, 118, 118)
			CloseUIShadow.Visible = CloseUI.Enabled

			addToTheme('Shadow', CloseUIShadow)

			UIPaddingCloseUI_1.Name = "UIPaddingCloseUI"
			UIPaddingCloseUI_1.Parent = CloseUIShadow
			UIPaddingCloseUI_1.PaddingBottom = UDim.new(0,5)
			UIPaddingCloseUI_1.PaddingLeft = UDim.new(0,5)
			UIPaddingCloseUI_1.PaddingRight = UDim.new(0,5)
			UIPaddingCloseUI_1.PaddingTop = UDim.new(0,5)

			BackgroundCloseUI_1.Name = "BackgroundCloseUI"
			BackgroundCloseUI_1.Parent = CloseUIShadow
			BackgroundCloseUI_1.AnchorPoint = Vector2.new(0.5, 0.5)
			BackgroundCloseUI_1.BackgroundColor3 = themes[Theme].Background
			BackgroundCloseUI_1.BorderColor3 = Color3.fromRGB(0,0,0)
			BackgroundCloseUI_1.BorderSizePixel = 0
			BackgroundCloseUI_1.Position = UDim2.new(0.5, 0,0.5, 0)
			BackgroundCloseUI_1.Size = UDim2.new(1, 0,1, 0)
			BackgroundCloseUI_1.ClipsDescendants = true

			addToTheme('Background', BackgroundCloseUI_1)

			UICornerCloseUI_1.Name = "UICornerCloseUI"
			UICornerCloseUI_1.Parent = BackgroundCloseUI_1
			UICornerCloseUI_1.CornerRadius = UDim.new(0,6)

			FrameCloseUI_1.Name = "FrameCloseUI"
			FrameCloseUI_1.Parent = BackgroundCloseUI_1
			FrameCloseUI_1.AnchorPoint = Vector2.new(0, 1)
			FrameCloseUI_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			FrameCloseUI_1.BackgroundTransparency = 0.8999999761581421
			FrameCloseUI_1.BorderColor3 = Color3.fromRGB(0,0,0)
			FrameCloseUI_1.BorderSizePixel = 0
			FrameCloseUI_1.Position = UDim2.new(0, 0,1, 0)
			FrameCloseUI_1.Size = UDim2.new(1, 0,0, 4)

			Title_1.Name = "Title"
			Title_1.Parent = BackgroundCloseUI_1
			Title_1.AutomaticSize = Enum.AutomaticSize.Y
			Title_1.BackgroundColor3 = Color3.fromRGB(255,255,255)
			Title_1.BackgroundTransparency = 1
			Title_1.BorderColor3 = Color3.fromRGB(0,0,0)
			Title_1.BorderSizePixel = 0
			Title_1.Size = UDim2.new(1, 0,1, 0)
			Title_1.Font = Enum.Font.GothamBold
			Title_1.Text = tostring(CloseUI.Text or "Open")
			Title_1.TextColor3 = Color3.fromRGB(255,255,255)
			Title_1.TextSize = 12

			addToTheme('Text & Icon', Title_1)

			CloseUIShadow.Size = UDim2.new(0, Title_1.TextBounds.X + 40,0, 40)

			-- Always show the Sylex logo; the text is only a fallback when the logo can't load
			local LogoImage = CloseUI.Enabled and loadLogo() or nil
			local Logo
			if type(LogoImage) == "string" and LogoImage ~= "" then
				Title_1.Visible = false
				FrameCloseUI_1.Visible = false
				Logo = Instance.new("ImageLabel")
				Logo.Name = "Logo"
				Logo.Parent = BackgroundCloseUI_1
				Logo.AnchorPoint = Vector2.new(0.5, 0.5)
				Logo.BackgroundTransparency = 1
				Logo.Position = UDim2.new(0.5, 0, 0.5, -1)
				Logo.Size = UDim2.new(0, 26, 0, 26)
				Logo.Image = LogoImage
				Logo.ScaleType = Enum.ScaleType.Fit
				UICornerCloseUI_1.CornerRadius = UDim.new(0, 10)
				CloseUIShadow.Size = UDim2.new(0, 50, 0, 50)
			end

			local Click = click(CloseUIShadow)
			lak(Click, CloseUIShadow)
			Click.MouseButton1Click:Connect(function()
				if Logo then
					tw({v = Logo, t = 0.15, s = Enum.EasingStyle.Back, d = "Out", g = {Size = UDim2.new(0, 22, 0, 22)}}):Play()
					delay(.06, function()
						tw({v = Logo, t = 0.15, s = Enum.EasingStyle.Back, d = "Out", g = {Size = UDim2.new(0, 26, 0, 26)}}):Play()
					end)
				else
					tw({v = Title_1, t = 0.15, s = Enum.EasingStyle.Back, d = "Out", g = {TextSize = Title_1.TextSize - 2}}):Play()
					delay(.06, function()
						tw({v = Title_1, t = 0.15, s = Enum.EasingStyle.Back, d = "Out", g = {TextSize = 12}}):Play()
					end)
				end
				task.spawn(closeui)
			end)
		end
	end

	return Tabs
end

return Library
