#!/usr/bin/luvit

local uv = require("uv")
local path = require("path")

local toConv = {
	[".wav"] = true,
	[".mp3"] = true,
	[".flac"] = true,
}

-- I'd love to make this a "keepMetadata", but you cant specify what you want to *keep* in ffmpeg
-- and i'm not parsing ffprobe or whatever for the metadata, fuck that
local removeMetadata = {
	-- "artist", "date", "album", "title",
	"comment", "purl", "synopsis", "description", "encoder",
}

--[[
	Arg parsing
]]

local function patternValidator(pattern)
	-- Validate the pattern
	local ok = pcall(string.find, "", pattern)

	if not ok then
		return false, ("Invalid pattern: `%s`"):format(pattern)
	else
		return pattern
	end
end

local values = { -- { default, type }
	["--bitrate"] = {value = 160, type = "number"},
	["--maxjobs"] = {value = 6, type = "number"},

	["--outdir"] =  {value = "./output", type = "string"},
	["--indir"] =   {value = uv.cwd(), type = "string"},

	["--directorypattern"] = {value = ".", type = patternValidator},
	["--filepattern"] = {value = ".", type = patternValidator},
	["--fullpattern"] = {value = nil, type = patternValidator}
}

local aliases = {
	["-d"] = "--dryrun",
	["-f"] = "--flatten",
	["-c"] = "--convertonly",
	["-v"] = "--verbose",

	["-b"] = "--bitrate",
	["-j"] = "--maxjobs",

	["-o"] = "--outdir",
	["--output"] = "--outdir",
	["-i"] = "--indir",
	["--input"] = "--indir",

	["-p"] = "--fullpattern",
	["-fp"] = "--filepattern",
	["-dp"] = "--directorypattern",
	["--dirpattern"] = "--directorypattern",
	["-ip"] = "--case-insensitive",
}

local flags = {
	["--dryrun"] = false,
	["--flatten"] = false,
	["--convertonly"] = false,
	["--case-insensitive"] = false,
	["--verbose"] = false,
}

local function vprint(...)
	if not flags["--verbose"] then return end
	print(...)
end

local parsers = {
	-- ["--flag"] = function(arg, valueTable, oldValue) end
}

local function parseArgs(args)
	local curFlag

	for idx, arg in ipairs(args) do
		if arg:match("^-") and not curFlag then
			-- parsing an "--argument" or "-flag"
			arg = arg:lower()
			arg = aliases[arg] or arg

			if parsers[arg] or values[arg] then
				curFlag = arg
			elseif flags[arg] ~= nil then
				flags[arg] = true
			else
				print(("Unknown flag: %s"):format(arg))
				os.exit()
			end
		elseif curFlag then
			-- parsing a value
			local oldValue
			local valTbl = values[curFlag]
			local newFlag

			if valTbl then
				oldValue = valTbl.value
				local convFn = type(valTbl.type) == "function" and valTbl.type or _G["to" .. valTbl.type]
				if not convFn then error("invalid type in flag value: " .. valTbl.type) return end

				local val, err = convFn(arg)

				if val == nil then
					local reasonStr = err or ("can't convert `%s` to %s"):format(arg, valTbl.type)
					print(("invalid value for flag %s (%s)"):format(curFlag, reasonStr))
					os.exit()
					return
				end

				valTbl.value = val
			end

			if parsers[curFlag] then
				newFlag = parsers[curFlag] (arg, valTbl, oldValue)
			end

			curFlag = newFlag
		end
	end

	if curFlag then
		print(("unfinished value (no value passed to `%s`)"):format(curFlag))
		os.exit()
	end
end

parseArgs(args)


local inputRoot = path.normalize(path.resolve(uv.cwd(), values["--indir"].value) .. "/")
local outputRoot = path.normalize(path.resolve(uv.cwd(), values["--outdir"].value) .. "/")

local DRY_RUN = flags["--dryrun"]
local maxJobs = values["--maxjobs"].value    -- this feature was sponsored by me OOM'ing myself
local opus_bitrate = values["--bitrate"].value
local flatten = flags["--flatten"]
local convOnly = flags["--convertonly"]
local filePattern, dirPattern = values["--filepattern"].value, values["--directorypattern"].value
local fullPattern = values["--fullpattern"].value
local caseInsensitive = flags["--case-insensitive"]

do
	if fullPattern then
		local fpNotDefault, dpNotDefault = filePattern ~= ".", dirPattern ~= "."
		if fpNotDefault or dpNotDefault then
			local which = fpNotDefault and dpNotDefault and "file & directory"
				or fpNotDefault and "file"
				or dpNotDefault and "directory"

			print(("WARNING: Overriding %s patterns with the full pattern!"):format(which))
		end

		-- All file/dir patterns should pass; fullpatterns are matched separately on the whole path
		filePattern, dirPattern = ".", "."
	end
end

print(("Converting from `%s`."):format(inputRoot))
print(("Converting to %dkbps (%d simultaneous jobs)"):format(opus_bitrate, maxJobs))
print(("Output will be placed in `%s`."):format(outputRoot))

--//==============//--
--//==============//--

local fs = require("fs")
local cp = require("childprocess")

local fuckoff = '(['..("%^$().[]*+-?"):gsub(".", "%%%1")..'])'
function string.EscapePatterns(s) return s:gsub(fuckoff, "%%%1") end
local function trimRoot(s) return s:gsub(inputRoot:EscapePatterns() .. "/?", "") end

function getMetadataFfmpeg()
	local t = {}
	for k,v in ipairs(removeMetadata) do
		t[#t + 1] = "-metadata"
		t[#t + 1] = ("%s="):format(v)
	end

	return t
end

function getOutputFn(inPath, inFn, inExt)
	local new = inFn:gsub("Topic %- ", "") .. ".opus"
	return new
end

function checkErr(err)
	if err then print("ERROR:", err) os.exit() end
end


local currentJobs = 0

local convQueue = {}
function convert(pt, to)
	local coro = coroutine.running()

	local ext = path.extname(to)
	local fn = path.basename(to):gsub(ext .. "$", "")

	to = path.join(path.dirname(to), getOutputFn(pt, fn, ext))

	if DRY_RUN then
		print(("Encoding `%s` -> `%s`"):format(trimRoot(pt), trimRoot(to)))
		return
	end

	local ffmpegArgs = {
		"-hide_banner",
		"-loglevel", "error",

		"-i", pt,
		"-map_metadata",  "0",
		{meta_flag = true},
		"-vsync", "0",
		"-c:v", "mjpeg",
		"-vf", "scale=-1:'min(iw,480)'",
		"-f", "flac",
		"-n",
		"pipe:1",
	}

	local metaReplaced = false

	for k,v in pairs(ffmpegArgs) do
		if v.meta_flag then
			local metaT = getMetadataFfmpeg()

			table.remove(ffmpegArgs, k)
			for i=#metaT, 1, -1 do
				table.insert(ffmpegArgs, k, metaT[i])
			end

			metaReplaced = true
			break
		end
	end

	assert(metaReplaced)

	local ffmpeg = cp.spawn("ffmpeg", ffmpegArgs)

	local opusenc = cp.spawn("opusenc", {
		"-",
		"--music",
		"--framesize", "20",
		"--bitrate", tostring(opus_bitrate),
		"--quiet", -- silence wench
		to,
	})

	ffmpeg:on("error", print)
	ffmpeg.stderr:on("data", print)
	ffmpeg.stdout:on("data", function(d)
		opusenc.stdin:write(d)
	end)

	ffmpeg.stdout:on("end", function()
		opusenc.stdin:_end()
	end)

	ffmpeg:on("exit", function()
		opusenc.stdin:_end()
	end)

	opusenc:on("exit", function()
		currentJobs = currentJobs - 1

		if coroutine.status(coro) == "suspended" then
			local ok, err = coroutine.resume(coro)
			checkErr(err)
		end
	end)

	opusenc.stderr:on("data", print)

	currentJobs = currentJobs + 1
	if currentJobs >= maxJobs then
		coroutine.yield()
	end
end

function copy(pt, to)
	if convOnly or DRY_RUN then return end

	local newFd, ab1 = fs.openSync(to, "w")
	local oldFd, ab2 = fs.openSync(pt, "r")

	fs.sendfile(newFd, oldFd, 0, 10e9, checkErr)
end

local function caseMatch(str, pattern)
	if caseInsensitive then
		str = str:lower()
		pattern = pattern:lower() -- i hope this works like i intend it to
	end

	local matched = str:match(pattern)
	vprint(matched and "Matched:" or "Ignored:", str)

	return str:match(pattern)
end

function handleFile(pt)
	local newDest

	local fn = path.basename(pt)

	if not caseMatch(fn, filePattern) then return end
	if fullPattern and not caseMatch(pt, fullPattern) then return end

	if not flatten then
		newDest = pt:gsub(inputRoot:EscapePatterns(), outputRoot)
	else
		newDest = path.join(outputRoot, fn)
	end

	if not DRY_RUN then
		fs.mkdirpSync(path.dirname(newDest))
	end

	if toConv[path.extname(pt):lower()] then
		convQueue[#convQueue + 1] = {pt, newDest}
	else
		copy(pt, newDest)
	end
end

local recurse

local function handleDirectory(fullPath, onRecursedCb)
	local isOutput = path.relative(fullPath, outputRoot) == ""
	if isOutput then return end

	local matches = fullPath:match(dirPattern)
	if not matches then return end

	recurse(fullPath, onRecursedCb)

	return true
end

function recurse(pt, onRecursedCb)
	local recs = 1 -- amt of currently enqueued scandirs, recursive

	local function decrCount()
		recs = recs - 1

		if recs == 0 and onRecursedCb then
			onRecursedCb()
		end
	end

	fs.scandir(pt, function(err, iter)
		if err then print(err) return end

		for fl, typ in iter do
			if typ == "file" then
				handleFile(path.join(pt, fl))
			elseif typ == "directory" then
				recs = recs + (handleDirectory(path.join(pt, fl), decrCount) and 1 or 0)
			end
		end

		decrCount()
	end)
end

recurse(inputRoot, coroutine.wrap(function()
	print("Total: ", #convQueue)

	for k,v in pairs(convQueue) do
		print(("%d/%d: %s"):format(k, #convQueue, v[1]))
		convert(unpack(v))
	end

	print("all converted")
	uv.run()
end))
