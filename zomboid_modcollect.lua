local env = require("env")
local zomboidMods = [[F:\SteamLibrary\steamapps\workshop\content\108600]]
local zomboidModlist = env.get("HOMEDRIVE") .. env.get("HOMEPATH") .. [[\Zomboid\Lua\saved_modlists.txt]]
local wantedList = "b42"

------------------------------------------------
local path, fs = require("path"), require("fs")

local modListStr = [[
b42:LWBetterElectronics;StandaloneTowels;damnlib;67gt500;69camaro;70dodge;70barracuda;76chevyKseries;78amgeneralM35A2;78amgeneralM35A2extra;78amgeneralM49A2C;78amgeneralM50A3;78amgeneralM62;82jeepJ10;82jeepJ10t;83amgeneralM923;83amgeneralM923extra;84merc;86fordE150;86fordE150expanded;86fordE150dnd;86fordE150mm;86fordE150pd;86oshkoshP19A;87buickRegal;87fordB700;87chevySuburban;87toyotaMR2;88chevyS10;89dodgeCaravan;89trooper;89fordBronco;89volvo200;90bmwE30;90fordF350ambulance;90pierceArrow;91fordLTD;91geoMetro;91range;92amgeneralM998;92amgeneralM998extra;92fordCVPI;92nissanGTR;93chevySuburban;93chevySuburbanExpanded;93fordF350;93mustangSSP;93fordTaurus;93townCar;UBPropFix;ReducedWoodWeight2x41;50%metalweight;AMMS_Standalone;Advanced_Trajectorys_Realistic_Overhaul;ammomaker;AnimeFigures;ArmoredVests;ArmoredVestsPatch;Authentic Z - Current;Bigsalt;Bigsalt_Bigitem;Bigsalt_DriedFood;SM4BootsExpandedB42;BCGRareWeapons;CombatText;ComfySleeping;darkPatches;Disassemble Container With Items;DRAW_ON_MAP;Drive90s;Drive90sRealNames;LazoloDynamicBackpackUpgrades;EGNHInuman;ETKI;2925034918/EasyLaundry;IMWSEnergyDrinksNEW;EverythingHasAName;ExpRecovery;ExtraBooks;FWOFitnessWorkoutOverhaul;FWOBenchPress&Treadmill;FeverishFellow;FBR;JCD_FIPS;2940908294/firegastrail;FirstAidVHSTapes;FH;FunctionalAppliances2;GenRange;GydeTraitMags;HandCrankFlashlights;P4HasBeenRead;herbalist;CWAX Herbs;NoLighterNeeded;BarricadedStartb42;LIF;ImmersiveLore;Improved_Fire_And_Smoke_Ffects;InsectIngredients;KillCount;KnownAndCollected;Ladders;LongStandingMetalConstructions;MakePaths;manageContainers;MapLegendUI;MapSymbolSizeSlider;MarLibrary;MarTraits;MarOccupations;P4MedicalMeister;NamedSkillVHSTapes;NepBatteryColor;NepEngineColor;NepNearbyTraps;OffroadGoBrrr;P4OnTheDoor;ProperVehicleInjuriesMP;ProximityInventory;RainCleansBlood;SimpleReadWhileWalking41;ReloadAllMagazines;REORDER_THE_HOTBAR;RebalancedPropMoving;RepairAnyClothes;StarlitLibrary;RepairableWindows;FixingMetal;ReplaceBandage;RespectLevelUp;simpleLockpicking;SimpleOverhaulTraitsAndOccupations;SpnCloth;SpnOpenCloth;BeautifyingTime;ClearingTime;SoulFilchersDrinkingTime;ExploringTime;SmokingSoundsOverhaul;stack_all_41;BB_StairsAlert;P4TidyUpMeister;TraitTagFramework;TrueMusicRadio;AlicesMultiWearVanilla;VehicleRepairOverhaul;VehicleSalvageOverhaulB42;WakeThemUp;YakiHSBasegameTextureB42;YakiHS;VanillaOpenAmmoWalk;ezPatches;Simplesling;fhqMotoriousZone;fhqMotoriousZoneUSDM;fhqMotoriousZoneExotics;fhqMotoriousZoneImports;fhqMotoriousZoneRealNames;fhqMotoriousPosters;UnifiedCarryWeightFramework;1299328280/ToadTraits;1299328280/ToadTraitsDynamic;BB_CommonSense;
]]

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

local function fillMaps(modRoot, mod)
	-- see if the mod has any maps (@ /steamapps/workshop/[modID]/mods/[modName]/media/maps)
	local mapFolder = path.join(modRoot, "media", "maps")

	if not fs.existsSync(mapFolder) then return end
	
	mod.maps = {}

	for mapName, typ in fs.scandirSync(mapFolder) do
		if typ == "directory" then
			table.insert(mod.maps, mapName)

			if fs.existsSync(path.join(mapFolder, mapName, "spawnpoints.lua")) then
				-- luvit try not to be cringe challenge (impossible)
				-- https://nodejs.org/api/path.html#windows-vs-posix
				-- the way to get the specific OS you want in the path package is SUPER ASS
				mod.spawnpoint = path.join("media/maps", mapName, "spawnpoints.lua"):gsub("\\", "/")
			end
		end
	end
end

local function fillModData(modRoot, wsid)
	-- version (42.15/mod.info) > Common (Common/mod.info) > root (./mod.info)
	local modInfo
	local folders = fs.readdirSync(modRoot)

	local maxVerFolder, maxVer
	for _, fn in pairs(folders) do
		-- can be 42.123 or 42
		local maj, min = fn:match("(%d+)%.?(%d?)")

		if not maj then
			goto cont
		end

		if not maxVer then
			maxVerFolder = fn
			maxVer = fn
		else
			local maxMaj, maxMin = maxVer:match("(%d+)%.?(%d?)")

			if maj > maxMaj or (maj == maxMaj and (not maxMin or min > maxMin)) then
				maxVerFolder = fn
				maxVer = fn
			end
		end

		::cont::
	end

	if maxVerFolder then
		modInfo = fs.readFileSync(path.join(modRoot, maxVerFolder, "mod.info"))
	end

	if not modInfo then
		-- try reading from Common, apparently you can put mod.info there too
		modInfo = fs.readFileSync(path.join(modRoot, "Common", "mod.info"))
			or fs.readFileSync(path.join(modRoot, "mod.info"))
	end

	if not modInfo then
		print(("[!] Didn't find mod.info in %s!"):format(modRoot))
		return
	end

	local modName = modInfo:match("\nid%s*=%s*([^\r\n]+)") -- lua's weaknesses are starting to show ngl
		or modInfo:match("^id%s*=%s*([^\r\n]+)")
	local mod = mods[modName]
	if not mod then return end -- this mod isn't present in the modlist; ignore

	mod.wsid = wsid
	mod.name = modName
	fillMaps(modRoot, mod)
end

for wsid, typ in fs.scandirSync(zomboidMods) do
	if typ ~= "directory" then goto nextDir end

	local modDir = path.join(zomboidMods, wsid, "mods")

	for dir, typ in fs.scandirSync(modDir) do
		if typ ~= "directory" then goto nextMod end

		-- modroot = /steamapps/workshop/[modID]/mods/[modName]
		local modRoot = path.join(modDir, dir)
		fillModData(modRoot, wsid)
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
local mapsConfig = "Map=%s"

local function collect(fmt, key, asTable)
	local modArr, arr, dedupeMap = {}, {}, {}

	for _, mod in pairs(modLists[wantedList]) do
		local v = mod[key]

		if v and not dedupeMap[v] then
			dedupeMap[v] = true
			table.insert(arr, v)
			table.insert(modArr, mod)
		end
	end

	-- map mods go first, otherwise there may be conflicts
	table.sort(arr, function(a, b)
		return a.maps and not b.maps
	end)

	if asTable then
		return arr, modArr
	else
		return fmt:format(table.concat(arr, ";"))
	end
end

-- print mod list (server.ini)
print(collect(modnameConfig, "modName"))
print("")
print(collect(workshopConfig, "wsid"))

-- print maps (server.ini)
local function collectMaps(fmt)
	local arr, dedupeMap = {}, {}

	for _, mod in pairs(modLists[wantedList]) do
		local v = mod.maps

		if not v then goto nextMap end

		for _, mapName in pairs(v) do
			if not dedupeMap[mapName] then
				dedupeMap[v] = true
				table.insert(arr, mapName)
			end
		end

		::nextMap::
	end

	-- add the vanilla map; it usually goes last so mods overwrite it
	table.insert(arr, "Muldraugh, KY")

	return fmt:format(table.concat(arr, ";"))
end

print("")
print(collectMaps(mapsConfig))

-- print spawnpoints (_spawnregions.lua)
print("")
local _, mapMods = collect(workshopConfig, "spawnpoint", true)
for k,v in pairs(mapMods) do
	print(("\t\t{ name = \"%s\", file = \"%s\" },"):format(v.name, v.spawnpoint))
end

