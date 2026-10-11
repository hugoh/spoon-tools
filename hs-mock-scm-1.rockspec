package = "hs-mock"
version = "scm-1"
source = { url = "git+https://github.com/hugoh/spoon-tools" }
description = {
	summary = "Mock of the Hammerspoon hs global for testing Spoons under busted",
	homepage = "https://github.com/hugoh/spoon-tools#hs_mock",
	license = "MIT",
}
dependencies = { "lua >= 5.4" }
build = {
	type = "builtin",
	modules = {
		hs_mock = "lua/hs_mock.lua",
		["hs_mock.fnutils"] = "lua/hs_mock/fnutils.lua",
	},
}
