local env = require("env")
local zomboidMods = [[D:\SteamLibrary\steamapps\workshop\content\108600]]
local zomboidModlist = env.get("HOMEDRIVE") .. env.get("HOMEPATH") .. [[\Zomboid\Lua\saved_modlists.txt]]
local wantedList = "MyModPresetName"

------------------------------------------------
local path, fs = require("path"), require("fs")

local modListStr = fs.readFileSync(zomboidModlist)
local modLists = {}
local mods = {}

if not modListStr then
	print(("No modlist file found in `%s`; exiting.")
		:format(zomboidModlist))
	return
end

-- 1. collect mod names from every modlist
for str in modListStr:gmatch("[^\r\n]+") do
	local name, modsStr = str:match("^([^:]+):(.+)")
	if not name then goto nextLine end

	modLists[name] = {}

	for mod in modsStr:gmatch("[^;]+") do
		mods[mod] = mods[mod] or {
			modName = mod,
			lists = {},
			wsid = nil,
		}

		table.insert(modLists[name], mods[mod])
		table.insert(mods[mod].lists, name)
	end

	::nextLine::
end

if not modLists[wantedList] then
	print(("No modlist named `%s` detected; exiting. Make sure you created a modlist preset with that name!")
		:format(wantedList))
	return
end

-- 2. map mod names to workshop IDs
-- the mod ID is the one contained in `mod.info`
for wsid, typ in fs.scandirSync(zomboidMods) do
	if typ ~= "directory" then goto nextDir end

	local modDir = path.join(zomboidMods, wsid, "mods")

	for dir, typ in fs.scandirSync(modDir) do
		if typ ~= "directory" then goto nextMod end

		local modInfo = fs.readFileSync(path.join(modDir, dir, "mod.info"))
		if not modInfo then
			print(("[!] Didn't find mod.info in %s!"):format(path.join(modDir, dir)))
			goto nextMod
		end

		local modName = modInfo:match("id%s*=%s*([^\r\n]+)")
		if not mods[modName] then goto nextMod end

		mods[modName].wsid = wsid
		::nextMod::
	end

	::nextDir::
end

-- 3. check that every mod got mapped to an ID
for _, mod in pairs(modLists[wantedList]) do
	if not mod.wsid and mod.modName ~= "ModTemplate" then
		print(("!!! Didn't find WorkshopID for mod %s!"):format(mod.modName))
	end
end

-- 4. build the server.ini vars
local workshopConfig = "WorkshopItems=%s"
local modnameConfig = "Mods=%s"

local function collect(fmt, key)
	local arr = {}
	for _, mod in pairs(modLists[wantedList]) do
		table.insert(arr, mod[key])
	end

	return fmt:format(table.concat(arr, ";"))
end

print(collect(modnameConfig, "modName"))
print("")
print(collect(workshopConfig, "wsid"))