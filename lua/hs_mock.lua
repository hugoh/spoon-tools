-- A mock of the Hammerspoon `hs` global for testing Spoons under busted.
-- See README.md ("hs_mock") for usage.

local fnutils = require("hs_mock.fnutils")

local M = {}

local LOG_LEVELS = { nothing = 0, error = 1, warning = 2, info = 3, debug = 4, verbose = 5 }

local function strict(path, t)
	return setmetatable(t, {
		__index = function(_, key) error(("hs_mock: %s.%s is not mocked"):format(path, tostring(key)), 0) end,
	})
end

local function deepcopy(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, val in pairs(v) do
		out[deepcopy(k)] = deepcopy(val)
	end
	return out
end

local function toLogLevel(level)
	if type(level) == "number" then return level end
	return LOG_LEVELS[level] or error("hs_mock: unknown log level " .. tostring(level), 2)
end

local function packed(...)
	local parts = table.pack(...)
	for i = 1, parts.n do
		parts[i] = tostring(parts[i])
	end
	return table.concat(parts, " ", 1, parts.n)
end

local Task = {}
Task.__index = Task

local Menubar = {}
Menubar.__index = Menubar

local Notification = {}
Notification.__index = Notification

local Watcher = {}
Watcher.__index = Watcher

local Hotkey = {}
Hotkey.__index = Hotkey

function Watcher:start()
	self._running = true
	return self
end

function Watcher:stop()
	self._running = false
	return self
end

function Watcher:isRunning() return self._running end

function Hotkey:enable()
	self.enabled = true
	return self
end

function Hotkey:disable()
	self.enabled = false
	return self
end

function Hotkey:delete()
	self.enabled = false
	self.deleted = true
end

function Menubar:setTitle(title)
	self._title = title
	return self
end

function Menubar:title() return self._title end

function Menubar:setIcon(icon, template)
	self._icon = icon
	self._iconTemplate = template
	return self
end

function Menubar:setMenu(menu)
	self._menu = menu
	return self
end

function Menubar:setTooltip(tooltip)
	self._tooltip = tooltip
	return self
end

function Menubar:setClickCallback(fn)
	self._clickCallback = fn
	return self
end

function Menubar:autosaveName(name)
	if name == nil then return self._autosaveName end
	self._autosaveName = name
	return self
end

function Menubar:frame() return { x = 0, y = 0, w = 22, h = 22 } end

function Menubar:isInMenuBar() return self._inMenuBar end

function Menubar:removeFromMenuBar()
	self._inMenuBar = false
	return self
end

function Menubar:returnToMenuBar()
	self._inMenuBar = true
	return self
end

function Menubar:delete() self._deleted = true end

function Menubar:_click()
	if self._clickCallback then return self._clickCallback({}) end
end

function Notification:send()
	self._sent = true
	return self
end

function Notification:withdraw()
	self._withdrawn = true
	return self
end

function Notification:activationType() return self._activationType or 0 end

function M.new()
	local ctl = {
		now = 0,
		logs = {},
		tasks = {},
		menubars = {},
		notifications = {},
		hotkeys = {},
		apps = {},
		files = {},
		dirs = {},
		caffeinateWatchers = {},
		appWatchers = {},
		onTask = nil,
	}
	local timers = {}
	local seq = 0

	local function schedule(timer, delay)
		seq = seq + 1
		timer._due = ctl.now + delay
		timer._seq = seq
		timer._running = true
	end

	local function nextDue(limit, eligible)
		local best
		for _, t in ipairs(timers) do
			if
				t._running
				and t._due <= limit
				and (not eligible or eligible[t])
				and (not best or t._due < best._due or (t._due == best._due and t._seq < best._seq))
			then
				best = t
			end
		end
		return best
	end

	local function fire(timer)
		ctl.now = math.max(ctl.now, timer._due)
		if timer._repeats then
			schedule(timer, timer._interval)
		else
			timer._running = false
		end
		timer._fn()
	end

	-- Timer methods are per new() so they see this instance's clock.
	local timerMethods = {
		start = function(self)
			schedule(self, self._interval)
			return self
		end,
		stop = function(self)
			self._running = false
			return self
		end,
		running = function(self) return self._running end,
		fire = function(self)
			self._fn()
			return self
		end,
		nextTrigger = function(self) return self._due - ctl.now end,
	}
	local timerMeta = { __index = timerMethods }

	local function newTimer(interval, fn, repeats)
		if repeats and not (interval > 0) then error("hs_mock: repeating timer interval must be > 0", 3) end
		local timer = setmetatable({ _interval = interval, _fn = fn, _repeats = repeats, _running = false }, timerMeta)
		table.insert(timers, timer)
		return timer
	end

	function ctl.advance(seconds)
		local target = ctl.now + seconds
		local firings = 0
		for timer in function() return nextDue(target) end do
			firings = firings + 1
			if firings > 100000 then error("hs_mock: runaway timers in ctl.advance", 2) end
			fire(timer)
		end
		ctl.now = target
	end

	function ctl.flush()
		local pending = {}
		for _, t in ipairs(timers) do
			if t._running and not t._repeats then pending[t] = true end
		end
		for timer in function() return nextDue(math.huge, pending) end do
			pending[timer] = nil
			fire(timer)
		end
	end

	function ctl.timers()
		local live = {}
		for _, t in ipairs(timers) do
			if t._running then table.insert(live, t) end
		end
		return live
	end

	function ctl.logged(level)
		local messages = {}
		for _, entry in ipairs(ctl.logs) do
			if entry.level == level then table.insert(messages, entry.message) end
		end
		return messages
	end

	function ctl.activate(notification, activationType)
		notification._activationType = activationType
		if notification._callback then notification._callback(notification) end
	end

	function ctl.caffeinate(event)
		for _, w in ipairs(ctl.caffeinateWatchers) do
			if w._running then w._fn(event) end
		end
	end

	function ctl.appEvent(name, event, app)
		for _, w in ipairs(ctl.appWatchers) do
			if w._running then w._fn(name, event, app) end
		end
	end

	local function newWatcher(list)
		return function(fn)
			local w = setmetatable({ _fn = fn, _running = false }, Watcher)
			table.insert(list, w)
			return w
		end
	end

	local function record(id, level, message) table.insert(ctl.logs, { logger = id, level = level, message = message }) end

	local hs = strict("hs", {
		fnutils = fnutils,

		logger = strict("hs.logger", {
			new = function(id, level)
				local current = toLogLevel(level or "warning")
				local log = {
					setLogLevel = function(l) current = toLogLevel(l) end,
					getLogLevel = function() return current end,
				}
				for plain, name in pairs({ e = "error", w = "warning", i = "info", d = "debug", v = "verbose" }) do
					log[plain] = function(...) record(id, name, packed(...)) end
				end
				for formatted, name in pairs({ ef = "error", wf = "warning", f = "info", df = "debug", vf = "verbose" }) do
					log[formatted] = function(fmt, ...) record(id, name, fmt:format(...)) end
				end
				return log
			end,
		}),

		timer = strict("hs.timer", {
			secondsSinceEpoch = function() return ctl.now end,
			absoluteTime = function() return math.floor(ctl.now * 1e9 + 0.5) end,
			new = function(interval, fn) return newTimer(interval, fn, true) end,
			doAfter = function(delay, fn) return newTimer(delay, fn, false):start() end,
			doEvery = function(interval, fn) return newTimer(interval, fn, true):start() end,
		}),

		task = strict("hs.task", {
			new = function(path, callback, streamOrArgs, args)
				local task = setmetatable({
					_path = path,
					_callback = callback,
					_streamCallback = type(streamOrArgs) == "function" and streamOrArgs or nil,
					_args = type(streamOrArgs) == "table" and streamOrArgs or args or {},
					_running = false,
					_pid = 1000 + #ctl.tasks,
					_ctl = ctl,
				}, Task)
				table.insert(ctl.tasks, task)
				return task
			end,
		}),

		menubar = strict("hs.menubar", {
			new = function(inMenuBar, autosaveName)
				local bar = setmetatable({ _inMenuBar = inMenuBar ~= false, _autosaveName = autosaveName }, Menubar)
				table.insert(ctl.menubars, bar)
				return bar
			end,
		}),

		notify = strict("hs.notify", {
			activationTypes = {
				none = 0,
				contentsClicked = 1,
				actionButtonClicked = 2,
				replied = 3,
				additionalActionClicked = 4,
			},
			new = function(fnOrAttributes, attributes)
				local callback = type(fnOrAttributes) == "function" and fnOrAttributes or nil
				local note = setmetatable({
					_callback = callback,
					_attributes = (callback and attributes or fnOrAttributes) or {},
				}, Notification)
				table.insert(ctl.notifications, note)
				return note
			end,
		}),

		caffeinate = strict("hs.caffeinate", {
			watcher = strict("hs.caffeinate.watcher", {
				systemDidWake = 0,
				systemWillSleep = 1,
				systemWillPowerOff = 2,
				screensDidSleep = 3,
				screensDidWake = 4,
				sessionDidResignActive = 5,
				sessionDidBecomeActive = 6,
				screensaverDidStart = 7,
				screensaverWillStop = 8,
				screensaverDidStop = 9,
				screensDidLock = 10,
				screensDidUnlock = 11,
				new = newWatcher(ctl.caffeinateWatchers),
			}),
		}),

		application = strict("hs.application", {
			find = function(hint) return ctl.apps[hint] end,
			get = function(hint) return ctl.apps[hint] end,
			watcher = strict("hs.application.watcher", {
				launching = 0,
				launched = 1,
				terminated = 2,
				hidden = 3,
				unhidden = 4,
				activated = 5,
				deactivated = 6,
				new = newWatcher(ctl.appWatchers),
			}),
		}),

		hotkey = strict("hs.hotkey", {
			bind = function(mods, key, message, pressed, released, repeated)
				if type(message) == "function" then
					message, pressed, released, repeated = nil, message, pressed, released
				end
				local hotkey = setmetatable({
					mods = mods,
					key = key,
					message = message,
					pressed = pressed,
					released = released,
					repeated = repeated,
					enabled = true,
					deleted = false,
				}, Hotkey)
				table.insert(ctl.hotkeys, hotkey)
				return hotkey
			end,
		}),

		json = strict("hs.json", {
			read = function(path)
				local content = ctl.files[path]
				if type(content) ~= "table" then return nil end
				return deepcopy(content)
			end,
			write = function(data, path, _prettyPrint, replace)
				if ctl.files[path] ~= nil and not replace then return false end
				ctl.files[path] = deepcopy(data)
				return true
			end,
		}),

		fs = strict("hs.fs", {
			attributes = function(path, name)
				local attrs
				if ctl.files[path] ~= nil then
					attrs = { mode = "file" }
				elseif ctl.dirs[path] then
					attrs = { mode = "directory" }
				else
					return nil
				end
				if name then return attrs[name] end
				return attrs
			end,
			mkdir = function(path)
				ctl.dirs[path] = true
				return true
			end,
		}),
	})

	return hs, ctl
end

function Task:start()
	self._running = true
	local onTask = self._ctl.onTask
	if onTask then
		local code, stdout, stderr = onTask(self)
		if code ~= nil then self:complete(code, stdout, stderr) end
	end
	return self
end

function Task:complete(exitCode, stdout, stderr)
	self._running = false
	if self._callback then self._callback(exitCode, stdout or "", stderr or "") end
end

function Task:terminate()
	self._running = false
	self._terminated = true
	return self
end

function Task:isRunning() return self._running end

function Task:pid() return self._pid end

function Task:closeInput() return self end

return M
