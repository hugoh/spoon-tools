local hs_mock = require("hs_mock")

local hs, ctl

before_each(function()
	hs, ctl = hs_mock.new()
end)

describe("initial state flags", function()
	it("start as false, so is_false assertions work before anything happens", function()
		local bar = hs.menubar.new()
		assert.is_false(bar._deleted)
		local note = hs.notify.new({})
		assert.is_false(note._sent)
		assert.is_false(note._withdrawn)
		local task = hs.task.new("/bin/true", function() end, {})
		assert.is_false(task._terminated)
	end)
end)

describe("strictness", function()
	it("raises on an unmocked module", function()
		assert.has_error(function() return hs.midi end, "hs_mock: hs.midi is not mocked")
	end)

	it("raises on an unmocked function in a mocked module", function()
		assert.has_error(function() return hs.timer.doAt end, "hs_mock: hs.timer.doAt is not mocked")
	end)

	it("lets tests add their own modules and functions", function()
		hs.midi = { devices = function() return "home" end }
		hs.timer.doAt = function() return "custom" end
		assert.equal("home", hs.midi.devices())
		assert.equal("custom", hs.timer.doAt())
	end)

	it("gives every new() its own state", function()
		hs.extra = {}
		local hs2, ctl2 = hs_mock.new()
		assert.has_error(function() return hs2.extra end)
		ctl.onTask = function() return 1 end
		ctl2.onTask = function() return 2 end
		local code
		hs.task.new("/bin/a", function(c) code = c end, {}):start()
		assert.equal(1, code)
		hs2.timer.doAfter(1, function() end)
		assert.same({}, ctl.timers())
	end)
end)

describe("hs.logger", function()
	it("records every level, formatted, with the logger name", function()
		local log = hs.logger.new("Spoon", "warning")
		log.i("hello")
		log.f("n=%d", 3)
		log.wf("w %s", "x")
		log.e("boom")
		log.d("dbg")
		log.vf("v%d", 1)
		assert.same({ "hello", "n=3" }, ctl.logged("info"))
		assert.same({ "w x" }, ctl.logged("warning"))
		assert.same({ "boom" }, ctl.logged("error"))
		assert.same({ "dbg" }, ctl.logged("debug"))
		assert.same({ "v1" }, ctl.logged("verbose"))
		assert.equal("Spoon", ctl.logs[1].logger)
	end)

	it("joins plain-call arguments with spaces", function()
		hs.logger.new("Spoon").i("a", 1, nil)
		assert.same({ "a 1 nil" }, ctl.logged("info"))
	end)

	it("tracks the log level as a number, like Hammerspoon", function()
		local log = hs.logger.new("Spoon", "info")
		assert.equal(3, log.getLogLevel())
		log.setLogLevel("debug")
		assert.equal(4, log.getLogLevel())
		log.setLogLevel(1)
		assert.equal(1, log.getLogLevel())
		assert.equal(2, hs.logger.new("Default").getLogLevel())
	end)
end)

describe("hs.timer clock", function()
	it("drives secondsSinceEpoch and absoluteTime (nanoseconds) from ctl.now", function()
		ctl.now = 100
		assert.equal(100, hs.timer.secondsSinceEpoch())
		assert.equal(100 * 1e9, hs.timer.absoluteTime())
		ctl.advance(2.5)
		assert.equal(102.5, hs.timer.secondsSinceEpoch())
	end)

	it("returns absoluteTime as integer nanoseconds, so deltas are exact", function()
		ctl.now = 0.05
		ctl.advance(0.15)
		assert.equal("integer", math.type(hs.timer.absoluteTime()))
		assert.equal(200000000, hs.timer.absoluteTime())
	end)
end)

describe("hs.timer.doAfter", function()
	it("fires once the clock reaches its delay", function()
		local fired = 0
		hs.timer.doAfter(5, function() fired = fired + 1 end)
		ctl.advance(4.9)
		assert.equal(0, fired)
		ctl.advance(0.1)
		assert.equal(1, fired)
		ctl.advance(100)
		assert.equal(1, fired)
	end)

	it("sees the clock at its due time while firing", function()
		local seen
		hs.timer.doAfter(3, function() seen = hs.timer.secondsSinceEpoch() end)
		ctl.advance(10)
		assert.equal(3, seen)
		assert.equal(10, ctl.now)
	end)

	it("fires in due-time order, ties in scheduling order", function()
		local order = {}
		hs.timer.doAfter(2, function() table.insert(order, "b") end)
		hs.timer.doAfter(1, function() table.insert(order, "a") end)
		hs.timer.doAfter(2, function() table.insert(order, "c") end)
		ctl.advance(2)
		assert.same({ "a", "b", "c" }, order)
	end)

	it("fires timers scheduled by a callback if they fall in the window", function()
		local order = {}
		hs.timer.doAfter(1, function()
			table.insert(order, "first")
			hs.timer.doAfter(1, function() table.insert(order, "second") end)
		end)
		ctl.advance(1.5)
		assert.same({ "first" }, order)
		ctl.advance(0.5)
		assert.same({ "first", "second" }, order)
	end)

	it("does not fire when stopped", function()
		local fired = false
		local t = hs.timer.doAfter(1, function() fired = true end)
		assert.is_true(t:running())
		t:stop()
		assert.is_false(t:running())
		ctl.advance(5)
		assert.is_false(fired)
	end)

	it("reports seconds until it fires", function()
		local t = hs.timer.doAfter(10, function() end)
		ctl.advance(4)
		assert.equal(6, t:nextTrigger())
	end)
end)

describe("hs.timer.doEvery", function()
	it("re-arms after each firing", function()
		local ticks = {}
		hs.timer.doEvery(10, function() table.insert(ticks, ctl.now) end)
		ctl.advance(35)
		assert.same({ 10, 20, 30 }, ticks)
	end)

	it("stops re-arming when stopped from its own callback", function()
		local ticks = 0
		local t
		t = hs.timer.doEvery(1, function()
			ticks = ticks + 1
			if ticks == 2 then t:stop() end
		end)
		ctl.advance(10)
		assert.equal(2, ticks)
	end)

	it("rejects a non-positive interval instead of looping forever", function()
		assert.has_error(function()
			hs.timer.doEvery(0, function() end)
		end)
	end)

	it("errors instead of hanging when timers keep re-arming", function()
		hs.timer.doEvery(1e-6, function() end)
		assert.has_error(function() ctl.advance(1) end, "hs_mock: runaway timers in ctl.advance")
	end)
end)

describe("hs.timer.new", function()
	it("is idle until started, then repeats", function()
		local ticks = 0
		local t = hs.timer.new(5, function() ticks = ticks + 1 end)
		assert.is_false(t:running())
		ctl.advance(20)
		assert.equal(0, ticks)
		assert.equal(t, t:start())
		ctl.advance(10)
		assert.equal(2, ticks)
	end)

	it("fire() runs the callback now without rescheduling", function()
		local ticks = 0
		local t = hs.timer.new(5, function() ticks = ticks + 1 end):start()
		t:fire()
		assert.equal(1, ticks)
		ctl.advance(5)
		assert.equal(2, ticks)
	end)
end)

describe("ctl.flush", function()
	it("fires pending one-shots regardless of delay, advancing the clock to each", function()
		local seen = {}
		hs.timer.doAfter(300, function() table.insert(seen, ctl.now) end)
		hs.timer.doAfter(60, function() table.insert(seen, ctl.now) end)
		ctl.flush()
		assert.same({ 60, 300 }, seen)
	end)

	it("leaves repeating timers and newly scheduled one-shots alone", function()
		local every, later = 0, false
		hs.timer.doEvery(1, function() every = every + 1 end)
		hs.timer.doAfter(1, function()
			hs.timer.doAfter(1, function() later = true end)
		end)
		ctl.flush()
		assert.equal(0, every)
		assert.is_false(later)
		ctl.flush()
		assert.is_true(later)
	end)
end)

describe("ctl.timers", function()
	it("lists running timers only", function()
		local a = hs.timer.doAfter(1, function() end)
		local b = hs.timer.doEvery(1, function() end)
		hs.timer.new(1, function() end)
		a:stop()
		assert.same({ b }, ctl.timers())
	end)
end)

describe("hs.task", function()
	it("records tasks and completes them on demand", function()
		local result
		local task = hs.task.new("/bin/ps", function(...) result = { ... } end, { "-A" })
		assert.equal(task, task:start())
		assert.is_true(task:isRunning())
		assert.same({ "-A" }, task._args)
		assert.equal(task, ctl.tasks[1])
		task:complete(0, "out")
		assert.same({ 0, "out", "" }, result)
		assert.is_false(task:isRunning())
	end)

	it("accepts a stream callback before the arguments", function()
		local task = hs.task.new("/bin/echo", function() end, function() return true end, { "hi" })
		assert.same({ "hi" }, task._args)
	end)

	it("auto-completes through ctl.onTask when it returns an exit code", function()
		ctl.onTask = function(t) return 3, t._path .. " " .. table.concat(t._args, " "), "err" end
		local result
		hs.task.new("/bin/ls", function(...) result = { ... } end, { "-l" }):start()
		assert.same({ 3, "/bin/ls -l", "err" }, result)
	end)

	it("stays running when ctl.onTask returns nothing", function()
		ctl.onTask = function() end
		local task = hs.task.new("/bin/sleep", function() end, { "1" }):start()
		assert.is_true(task:isRunning())
	end)

	it("terminate stops it without calling back", function()
		local called = false
		local task = hs.task.new("/bin/sleep", function() called = true end, {}):start()
		task:terminate()
		assert.is_false(task:isRunning())
		assert.is_false(called)
	end)

	it("gives each task its own pid and chains closeInput", function()
		local a = hs.task.new("/bin/a", function() end, {})
		local b = hs.task.new("/bin/b", function() end, {})
		assert.are_not.equal(a:pid(), b:pid())
		assert.equal(a, a:closeInput())
	end)
end)

describe("hs.menubar", function()
	it("records state set through its methods", function()
		local bar = hs.menubar.new():autosaveName("Spoon")
		bar:setTitle("T")
		bar:setIcon("icon", true)
		bar:setMenu({ { title = "x" } })
		bar:setTooltip("tip")
		assert.equal(bar, ctl.menubars[1])
		assert.equal("T", bar:title())
		assert.equal("T", bar._title)
		assert.equal("icon", bar._icon)
		assert.same({ { title = "x" } }, bar._menu)
		assert.equal("tip", bar._tooltip)
		assert.equal("Spoon", bar._autosaveName)
		bar:delete()
		assert.is_true(bar._deleted)
	end)

	it("can be clicked", function()
		local clicked = false
		hs.menubar.new():setClickCallback(function() clicked = true end)
		ctl.menubars[1]:_click()
		assert.is_true(clicked)
	end)

	it("tracks menu bar presence and has a frame", function()
		local hidden = hs.menubar.new(false)
		assert.is_false(hidden:isInMenuBar())
		local bar = hs.menubar.new()
		assert.is_true(bar:isInMenuBar())
		assert.equal(bar, bar:removeFromMenuBar())
		assert.is_false(bar:isInMenuBar())
		bar:returnToMenuBar()
		assert.is_true(bar:isInMenuBar())
		assert.same({ x = 0, y = 0, w = 22, h = 22 }, bar:frame())
	end)

	it("returns the autosave name when called without one", function()
		local bar = hs.menubar.new(true, "Saved")
		assert.equal("Saved", bar:autosaveName())
	end)
end)

describe("hs.notify", function()
	it(
		"exposes the real activation type values",
		function()
			assert.same({
				none = 0,
				contentsClicked = 1,
				actionButtonClicked = 2,
				replied = 3,
				additionalActionClicked = 4,
			}, hs.notify.activationTypes)
		end
	)

	it("records sent and withdrawn notifications", function()
		local note = hs.notify.new({ title = "Hi" }):send()
		assert.equal(note, ctl.notifications[1])
		assert.equal("Hi", note._attributes.title)
		assert.is_true(note._sent)
		note:withdraw()
		assert.is_true(note._withdrawn)
	end)

	it("activates with a type and calls back", function()
		local got
		local note = hs.notify.new(function(n) got = n:activationType() end, { title = "Hi" })
		note:send()
		ctl.activate(note, hs.notify.activationTypes.contentsClicked)
		assert.equal(1, got)
	end)
end)

describe("hs.caffeinate.watcher", function()
	it("uses the real event values", function()
		local w = hs.caffeinate.watcher
		assert.equal(0, w.systemDidWake)
		assert.equal(1, w.systemWillSleep)
		assert.equal(11, w.screensDidUnlock)
	end)

	it("delivers events to started watchers only", function()
		local events = {}
		local w = hs.caffeinate.watcher.new(function(e) table.insert(events, e) end)
		ctl.caffeinate(hs.caffeinate.watcher.systemWillSleep)
		assert.equal(w, w:start())
		ctl.caffeinate(hs.caffeinate.watcher.systemDidWake)
		w:stop()
		ctl.caffeinate(hs.caffeinate.watcher.screensDidLock)
		assert.same({ 0 }, events)
	end)

	it("reports whether it is running", function()
		local w = hs.caffeinate.watcher.new(function() end)
		assert.is_false(w:isRunning())
		w:start()
		assert.is_true(w:isRunning())
	end)
end)

describe("hs.application", function()
	it("uses the real watcher event values", function()
		local w = hs.application.watcher
		assert.equal(0, w.launching)
		assert.equal(1, w.launched)
		assert.equal(2, w.terminated)
		assert.equal(5, w.activated)
	end)

	it("delivers app events to started watchers", function()
		local got
		hs.application.watcher.new(function(...) got = { ... } end):start()
		local app = {}
		ctl.appEvent("Slack", hs.application.watcher.launched, app)
		assert.same({ "Slack", 1, app }, got)
	end)

	it("finds and gets apps registered in ctl.apps", function()
		local slack = {}
		ctl.apps["Slack"] = slack
		assert.equal(slack, hs.application.find("Slack"))
		assert.equal(slack, hs.application.get("Slack"))
		assert.is_nil(hs.application.get("Zoom"))
	end)
end)

describe("hs.hotkey.bind", function()
	it("records bindings with and without a message", function()
		local pressed = function() end
		hs.hotkey.bind({ "cmd" }, "a", pressed)
		hs.hotkey.bind({ "cmd" }, "b", "Launch", pressed)
		assert.same({ "cmd" }, ctl.hotkeys[1].mods)
		assert.equal("a", ctl.hotkeys[1].key)
		assert.equal(pressed, ctl.hotkeys[1].pressed)
		assert.equal("Launch", ctl.hotkeys[2].message)
		assert.equal(pressed, ctl.hotkeys[2].pressed)
	end)

	it("tracks enable, disable and delete", function()
		local hk = hs.hotkey.bind({}, "x", function() end)
		hk:disable()
		assert.is_false(ctl.hotkeys[1].enabled)
		hk:enable()
		assert.is_true(ctl.hotkeys[1].enabled)
		hk:delete()
		assert.is_true(ctl.hotkeys[1].deleted)
	end)
end)

describe("hs.json and hs.fs", function()
	it("round-trips through ctl.files as a copy, like real serialization", function()
		local data = { a = { 1, 2 } }
		assert.is_true(hs.json.write(data, "/c.json"))
		data.a[1] = 99
		local read = hs.json.read("/c.json")
		assert.same({ a = { 1, 2 } }, read)
		read.a[2] = 99
		assert.same({ a = { 1, 2 } }, hs.json.read("/c.json"))
	end)

	it("refuses to overwrite unless replace is set", function()
		hs.json.write({ v = 1 }, "/c.json")
		assert.is_false(hs.json.write({ v = 2 }, "/c.json"))
		assert.is_true(hs.json.write({ v = 2 }, "/c.json", true, true))
		assert.same({ v = 2 }, hs.json.read("/c.json"))
	end)

	it("treats a non-table file as malformed JSON that still exists", function()
		ctl.files["/bad.json"] = "{not json"
		assert.is_nil(hs.json.read("/bad.json"))
		assert.equal("file", hs.fs.attributes("/bad.json").mode)
	end)

	it("reports missing paths as nil and directories from mkdir", function()
		assert.is_nil(hs.json.read("/missing.json"))
		assert.is_nil(hs.fs.attributes("/missing.json"))
		assert.is_true(hs.fs.mkdir("/d"))
		assert.equal("directory", hs.fs.attributes("/d").mode)
	end)

	it("returns a single attribute when named", function()
		hs.fs.mkdir("/d")
		assert.equal("directory", hs.fs.attributes("/d", "mode"))
		assert.is_nil(hs.fs.attributes("/missing", "mode"))
	end)
end)

describe("hs.audiodevice", function()
	it("lists devices added through ctl by direction", function()
		local speakers = ctl.addAudioDevice({ name = "Speakers" })
		local mic = ctl.addAudioDevice({ name = "Mic", input = true })
		assert.same({ speakers }, hs.audiodevice.allOutputDevices())
		assert.same({ mic }, hs.audiodevice.allInputDevices())
		assert.is_true(speakers:isOutputDevice())
		assert.is_true(mic:isInputDevice())
	end)

	it("exposes device attributes, defaulting uid to the name", function()
		local d =
			ctl.addAudioDevice({ name = "AirPods", uid = "U1", transport = "Bluetooth", volume = 40, inUse = true })
		assert.equal("AirPods", d:name())
		assert.equal("U1", d:uid())
		assert.equal("Bluetooth", d:transportType())
		assert.equal(40, d:volume())
		assert.is_false(d:muted())
		assert.is_true(d:inUse())
		assert.equal("Speakers", ctl.addAudioDevice({ name = "Speakers" }):uid())
	end)

	it("sets mute and volume", function()
		local d = ctl.addAudioDevice({ name = "Speakers" })
		assert.is_true(d:setMuted(true))
		assert.is_true(d:muted())
		assert.is_true(d:setVolume(25))
		assert.equal(25, d:volume())
	end)

	it("tracks the default devices, settable by tests and by the devices", function()
		local a = ctl.addAudioDevice({ name = "A" })
		local b = ctl.addAudioDevice({ name = "B" })
		local mic = ctl.addAudioDevice({ name = "Mic", input = true })
		assert.is_nil(hs.audiodevice.defaultOutputDevice())
		ctl.audio.defaultOutput = a
		assert.equal(a, hs.audiodevice.defaultOutputDevice())
		assert.is_true(b:setDefaultOutputDevice())
		assert.equal(b, hs.audiodevice.defaultOutputDevice())
		mic:setDefaultInputDevice()
		assert.equal(mic, hs.audiodevice.defaultInputDevice())
	end)

	it("delivers system events to the watcher only while it runs", function()
		local events = {}
		hs.audiodevice.watcher.setCallback(function(e) table.insert(events, e) end)
		ctl.audioEvent("dOut")
		hs.audiodevice.watcher.start()
		assert.is_true(hs.audiodevice.watcher.isRunning())
		ctl.audioEvent("dIn ")
		hs.audiodevice.watcher.stop()
		ctl.audioEvent("dev#")
		assert.same({ "dIn " }, events)
	end)

	it("delivers device events to a device's watcher only while it watches", function()
		local d = ctl.addAudioDevice({ name = "Speakers", uid = "S" })
		local got
		assert.equal(d, d:watcherCallback(function(...) got = { ... } end))
		ctl.deviceEvent(d, "mute", "outp", 0)
		assert.is_nil(got)
		assert.equal(d, d:watcherStart())
		assert.is_true(d:watcherIsRunning())
		ctl.deviceEvent(d, "mute", "outp", 0)
		assert.same({ "S", "mute", "outp", 0 }, got)
		d:watcherStop()
		assert.is_false(d:watcherIsRunning())
	end)
end)

describe("hs.image", function()
	it("returns registered images by name or file path, nil otherwise", function()
		local icon = {}
		ctl.images["NSStatusAvailable"] = icon
		ctl.images["/Applications/Slack.app"] = icon
		assert.equal(icon, hs.image.imageFromName("NSStatusAvailable"))
		assert.equal(icon, hs.image.iconForFile("/Applications/Slack.app"))
		assert.is_nil(hs.image.imageFromName("Nope"))
	end)
end)

describe("hs.inspect", function()
	it("is the real Hammerspoon implementation, callable directly or as .inspect", function()
		assert.equal("{\n  a = 2,\n  b = { 1 }\n}", hs.inspect({ a = 2, b = { 1 } }))
		assert.equal('{ "x" }', hs.inspect.inspect({ "x" }))
		assert.equal("{...}", hs.inspect({ {} }, { depth = 0 }))
	end)
end)

describe("hs.fnutils", function()
	it("is the real Hammerspoon implementation", function()
		assert.same({ 2, 4 }, hs.fnutils.imap({ 1, 2 }, function(v) return v * 2 end))
		assert.is_true(hs.fnutils.contains({ "a" }, "a"))
		assert.same({ 1, 2, 3 }, hs.fnutils.partial(function(...) return { ... } end, 1)(2, 3))
	end)
end)

describe("hs.execute and hs.open", function()
	it("records commands and answers through ctl.onExecute", function()
		assert.same({ "", true, "exit", 0 }, { hs.execute("true") })
		ctl.onExecute = function(cmd) return cmd .. "!", false, "exit", 2 end
		assert.same({ "ls!", false, "exit", 2 }, { hs.execute("ls", true) })
		assert.same({ "true", "ls" }, ctl.executed)
	end)

	it("records opened paths", function()
		assert.is_true(hs.open("/tmp/x"))
		assert.same({ "/tmp/x" }, ctl.opened)
	end)
end)

describe("hs.ipc", function()
	it("is present by default, like a loadable Hammerspoon module", function() assert.is_table(hs.ipc) end)
end)

describe("hs.alert", function()
	it("returns string ids and records text, style, and closing", function()
		local id = hs.alert.show("Hi", { textSize = 20 }, "screen", 3)
		assert.is_string(id)
		assert.equal("Hi", ctl.alerts[1].text)
		assert.same({ textSize = 20 }, ctl.alerts[1].style)
		assert.equal(3, ctl.alerts[1].seconds)
		hs.alert.closeSpecific(id)
		assert.is_true(ctl.alerts[1].closed)
		hs.alert.show("Again")
		hs.alert.closeAll()
		assert.is_true(ctl.alerts[2].closed)
	end)
end)

describe("hs.alert argument parsing", function()
	it("reads optional arguments by type, as Hammerspoon does", function()
		local screen = hs.screen.mainScreen()
		hs.alert.show("Seconds only", 8)
		hs.alert.show("Style and seconds", { textSize = 9 }, 2)
		hs.alert.show("Screen", screen)
		hs.alert.show("Nil placeholder", { fillColor = "red" }, nil, 1)
		assert.equal(1, ctl.alerts[4].seconds)
		assert.same({ seconds = 8 }, { style = ctl.alerts[1].style, seconds = ctl.alerts[1].seconds })
		assert.same({ textSize = 9 }, ctl.alerts[2].style)
		assert.equal(2, ctl.alerts[2].seconds)
		assert.equal(screen, ctl.alerts[3].screen)
		assert.is_nil(ctl.alerts[3].style)
	end)
end)

describe("hs.settings", function()
	it("stores values in ctl.settings", function()
		hs.settings.set("k", 1)
		assert.equal(1, hs.settings.get("k"))
		assert.equal(1, ctl.settings.k)
		hs.settings.clear("k")
		assert.is_nil(hs.settings.get("k"))
	end)
end)

describe("hs.screen and hs.mouse", function()
	it("reports the main screen frame from ctl.screenFrame, as a copy", function()
		local frame = hs.screen.mainScreen():frame()
		assert.same({ x = 0, y = 0, w = 1440, h = 900 }, frame)
		frame.w = 1
		assert.equal(1440, ctl.screenFrame.w)
	end)

	it("gets and sets the mouse position", function()
		assert.same({ x = 0, y = 0 }, hs.mouse.absolutePosition())
		hs.mouse.absolutePosition({ x = 5, y = 6 })
		assert.same({ x = 5, y = 6 }, ctl.mousePosition)
	end)
end)

describe("hs.eventtap", function()
	it("records keystrokes and clicks", function()
		local app = {}
		hs.eventtap.keyStroke({ "cmd" }, "m", 0, app)
		hs.eventtap.leftClick({ x = 1, y = 2 })
		assert.same({ { mods = { "cmd" }, key = "m", delay = 0, app = app } }, ctl.keyStrokes)
		assert.same({ { x = 1, y = 2 } }, ctl.clicks)
	end)

	it("uses the real CoreGraphics event type values", function()
		local types = hs.eventtap.event.types
		assert.equal(10, types.keyDown)
		assert.equal(11, types.keyUp)
		assert.equal(12, types.flagsChanged)
		assert.equal(14, types.systemDefined)
	end)

	it("builds and posts system key events", function()
		local e = hs.eventtap.event.newSystemKeyEvent("SOUND_UP", true)
		assert.equal(hs.eventtap.event.types.systemDefined, e:getType())
		assert.same({ key = "SOUND_UP", down = true }, e:systemKey())
		assert.equal(e, e:setFlags({ alt = true }))
		assert.same({ alt = true }, e:getFlags())
		assert.equal(e, e:post())
		assert.same({ e }, ctl.posted)
	end)

	it("delivers events of matching types to enabled taps and returns their answer", function()
		local seen = {}
		local tap = hs.eventtap.new({ hs.eventtap.event.types.systemDefined }, function(e)
			table.insert(seen, e)
			return true
		end)
		local e =
			ctl.newEvent({ type = hs.eventtap.event.types.systemDefined, systemKey = { key = "MUTE", down = true } })
		assert.is_nil(ctl.tapEvent(e))
		assert.equal(tap, tap:start())
		assert.is_true(tap:isEnabled())
		assert.is_true(ctl.tapEvent(e))
		assert.is_nil(ctl.tapEvent(ctl.newEvent({ type = hs.eventtap.event.types.keyDown })))
		tap:stop()
		assert.is_false(tap:isEnabled())
		assert.same({ e }, seen)
	end)
end)

describe("hs.websocket", function()
	it("records sends and delivers events from ctl", function()
		local got = {}
		local ws = hs.websocket.new("ws://x", function(event, message) table.insert(got, { event, message }) end)
		assert.equal(ws, ctl.websockets[1])
		assert.equal("ws://x", ws._url)
		ws:send("hello")
		assert.same({ "hello" }, ws._sent)
		ctl.websocketEvent(ws, "received", "msg")
		assert.same({ { "received", "msg" } }, got)
		ws:close()
		assert.is_true(ws._closed)
		assert.equal("closed", ws:status())
	end)
end)

describe("hs.wifi, hs.host and hs.distributednotifications", function()
	it("reports the current network and notifies running wifi watchers", function()
		ctl.wifiNetwork = "home"
		assert.equal("home", hs.wifi.currentNetwork())
		local got
		local w = hs.wifi.watcher.new(function(...) got = { ... } end)
		ctl.wifiEvent()
		assert.is_nil(got)
		w:start()
		ctl.wifiEvent()
		assert.same({ w, "SSIDChange", "en0" }, got)
	end)

	it("reports the interface style as macOS does: nil when light", function()
		assert.is_nil(hs.host.interfaceStyle())
		ctl.interfaceStyle = "Dark"
		assert.equal("Dark", hs.host.interfaceStyle())
	end)

	it("delivers distributed notifications to running watchers matching the name", function()
		local got = {}
		hs.distributednotifications.new(function(name) table.insert(got, name) end, "a"):start()
		hs.distributednotifications.new(function(name) table.insert(got, "any:" .. name) end):start()
		ctl.distributedNotification("a")
		ctl.distributedNotification("b", "obj", {})
		assert.same({ "a", "any:a", "any:b" }, got)
	end)
end)

describe("hs.spoons", function()
	it(
		"returns the resource path unchanged",
		function() assert.equal("icon.png", hs.spoons.resourcePath("icon.png")) end
	)
end)

describe("hs.application launching and lookup", function()
	it("records launches by name and bundle id", function()
		assert.is_true(hs.application.launchOrFocus("Slack"))
		assert.is_true(hs.application.launchOrFocusByBundleID("com.tinyspeck.slackmacgap"))
		assert.same({ "Slack", "com.tinyspeck.slackmacgap" }, ctl.launched)
	end)

	it("reports the frontmost app from ctl.frontmost", function()
		local app = {}
		ctl.frontmost = app
		assert.equal(app, hs.application.frontmostApplication())
	end)

	it("finds apps by key, then by bundle id among ctl.apps and the frontmost app", function()
		local function app(bid)
			return { bundleID = function() return bid end }
		end
		local teams, notes = app("com.microsoft.teams2"), app("com.apple.Notes")
		ctl.apps.Teams = teams
		ctl.frontmost = notes
		assert.equal(teams, hs.application.get("Teams"))
		assert.equal(teams, hs.application.get("com.microsoft.teams2"))
		assert.equal(notes, hs.application.find("com.apple.Notes"))
		assert.is_nil(hs.application.get("com.example.none"))
	end)
end)
