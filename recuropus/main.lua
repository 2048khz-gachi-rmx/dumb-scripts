local uv = require("uv")
local path = require("path")

local function exec(ffmpegPath, opusPath)
	local utilArgs = require("./args")

	local toConv = {
		[".wav"] = true,
		[".mp3"] = true,
		[".flac"] = true,
	}

	local argParser = utilArgs.ArgParser:new()

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

	argParser
		:AddValue("--bitrate", {value = 160, type = "number", aliases = { "-b" }})
		:AddValue("--maxjobs", {value = 6, type = "number", aliases = { "-j" }})

		:AddValue("--outdir",  {value = "./output", type = "string", aliases = { "-o", "--output" }})
		:AddValue("--indir",   {value = uv.cwd(), type = "string", aliases = { "-i", "--indir" }})

		:AddValue("--directorypattern", {value = nil, type = patternValidator, aliases = { "-dp", "--dirpattern" }})
		:AddValue("--filepattern", {value = nil, type = patternValidator, aliases = { "-fp" }})
		:AddValue("--fullpattern", {value = nil, type = patternValidator, aliases = { "-p" }})

	argParser
		:AddFlag("--dryrun", { aliases = { "-d" } })
		:AddFlag("--flatten", { aliases = { "-f" } })
		:AddFlag("--nocopy", { aliases = { "--convertonly", "-nc" } })
		:AddFlag("--verbose", { aliases = { "-v" } })
		:AddFlag("--quiet", { aliases = { "-q" }})
		:AddFlag("--case-insensitive", { aliases = { "-ip" }})

	-- todo: these should be in a `common` lib
	local function vprint(fmt, ...)
		if not argParser:GetValue("--verbose") then return end
		print(fmt:format(...))
	end

	local function qprint(fmt, ...)
		if argParser:GetValue("--quiet") then return end
		print(fmt:format(...))
	end

	local function errprint(fmt, ...)
		process.stderr:write(fmt:format(...) .. "\n")
		print(fmt:format(...))
	end

	-- check that `str` doesn't contain patterns with uppercase negations (like %D)
	local function hasUnescapedUppercasePattern(str)
		if not str then return false end

		for perc in str:gmatch("(%%+)%u") do
			if #perc % 2 == 1 then -- uneven number of %'s; there's an unescaped %
				return true
			end
		end

		return false
	end

	do
		local ok, err = argParser:Parse(args)

		if not ok then
			errprint(err)
			return
		end
	end

	local inputRoot = path.normalize(path.resolve(uv.cwd(), argParser:GetValue("--indir")) .. "/")
	local outputRoot = path.normalize(path.resolve(uv.cwd(), argParser:GetValue("--outdir")) .. "/")

	local DRY_RUN = argParser:GetValue("--dryrun")
	local maxJobs = argParser:GetValue("--maxjobs")
	local opus_bitrate = argParser:GetValue("--bitrate")
	local flatten = argParser:GetValue("--flatten")
	local convOnly = argParser:GetValue("--convertonly")
	local filePattern, dirPattern = argParser:GetValue("--filepattern"), argParser:GetValue("--directorypattern")
	local fullPattern = argParser:GetValue("--fullpattern")
	local caseInsensitive = argParser:GetValue("--case-insensitive")

	do
		if fullPattern then
			if filePattern or dirPattern then
				local which = filePattern and dirPattern and "file & directory"
					or filePattern and "file"
					or dirPattern and "directory"

				qprint(("WARNING: Overriding %s patterns with the full pattern!"):format(which))
			end

			-- All file/dir patterns should pass; fullpatterns are matched separately on the whole path
			filePattern, dirPattern = nil, nil
		end
	end


	if caseInsensitive and (
		hasUnescapedUppercasePattern(filePattern)
		or hasUnescapedUppercasePattern(dirPattern)
		or hasUnescapedUppercasePattern(fullPattern)) then

		errprint("case-insensitivity with patterns using uppercase negations is not supported (sorry!)")
		errprint("consider using the group-negation alternative (%A -> [^%a])")
		return
	end

	qprint("Converting from `%s`", inputRoot)
	qprint("Converting to %dkbps (%d simultaneous jobs)", opus_bitrate, maxJobs)
	qprint("Output will be placed in `%s`\n", outputRoot)

	--//==============//--
	--//==============//--

	local fs = require("fs")
	local cp = require("childprocess")

	-- i put patterns in your patterns so you can match patterns so you don't accidentally match a pattern
	local patternPattern = "([" .. ("%^$().[]*+-?"):gsub(".", "%%%1") .. "])"
	function string.EscapePatterns(s) return s:gsub(patternPattern, "%%%1") end

	local escapedRoot = inputRoot:EscapePatterns()

	local function trimRoot(s)
		return s:gsub("^" .. escapedRoot .. "/?", "", 1)
	end

	-- Constructs a table like { "-metadata", "comment=", "-metadata", "purl=", ... }
	-- It gets passed to ffmpeg's args to trim out metadata, cause that's how you do it, apparently
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
		if err then
			errprint("Error: %s", err)
			os.exit()
		end
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

		local ffmpeg = cp.spawn(ffmpegPath, ffmpegArgs)

		local opusenc = cp.spawn(opusPath, {
			"--music",
			"--framesize", "20",
			"--bitrate", tostring(opus_bitrate),
			"--quiet", -- silence wench
			"-",
			to,
		})

		ffmpeg:on("error", function(s) errprint("step 1.1 (ffmpeg/flac) error: %s (@ %s)", s, pt) end)
		ffmpeg.stderr:on("data", function(s) errprint("step 1.2 (ffmpeg/flac) error: %s", s) end)

		ffmpeg.stdout:on("data", function(d)
			opusenc.stdin:write(d)
		end)


		-- uh, really? :_end()?
		-- emitting "close" and "end" does nothing;
		-- calling :destroy() or :shutdown() (as per net.Socket) closes prematurely and not all data goes through;
		-- only _end() works correctly... SURELY there's a proper public method!?!?!?
		ffmpeg.stdout:on("end", function() opusenc.stdin:_end() end)
		ffmpeg:on("exit", function() opusenc.stdin:_end() end)

		opusenc:on("exit", function()
			currentJobs = currentJobs - 1

			if coroutine.status(coro) == "suspended" then
				local ok, err = coroutine.resume(coro)
				checkErr(err)
			end
		end)

		opusenc.stderr:on("data", function(s) errprint("step 2 (opusenc/opus) error: %s", s) end)

		currentJobs = currentJobs + 1
		if currentJobs >= argParser:GetValue("--maxjobs") then
			coroutine.yield()
		end
	end

	function copy(pt, to)
		if convOnly or DRY_RUN then return end

		local newFd = fs.openSync(to, "w")
		local oldFd = fs.openSync(pt, "r")

		fs.sendfile(newFd, oldFd, 0, 10e9, checkErr)
	end

	local function caseMatch(str, pattern)
		if caseInsensitive then
			str = str:lower()
			pattern = pattern:lower()
		end

		local matched = str:match(pattern)
		vprint(matched and "+ matched: %s"
		                or "- ignored: %s", trimRoot(str))

		return str:match(pattern)
	end

	function handleFile(pt)
		local newDest

		local fn = path.basename(pt)

		if filePattern and not caseMatch(fn, filePattern) then return end
		if fullPattern and not caseMatch(pt, fullPattern) then return end

		if not flatten then
			newDest = pt:gsub(escapedRoot, outputRoot)
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

		if dirPattern and not caseMatch(fullPath, dirPattern) then return end

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
			if err then errprint("%s", err) return end

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
		qprint("Total: ", #convQueue)

		for k,v in pairs(convQueue) do
			qprint(("%d/%d: %s"):format(k, #convQueue, v[1]))
			convert(unpack(v))
		end
	end))
end

require("luvit")(function()
	-- luvi removes the temp folders right after the callback ends
	-- https://github.com/luvit/luvi/blob/master/src/lua/luvibundle.lua#L314-L330

	local exeNames = {
		["Windows"] = {"ffmpeg.exe", "opusenc.exe"},
		-- ? todo
	}

	local osNames = exeNames[jit.os] or errorf("unsupported OS %s", jit.os)

	local ffmpegExecutable = osNames[1]
	local opusencExecutable = osNames[2]

	module:action(ffmpegExecutable, function(ffmpegPath)
		module:action(opusencExecutable, function(opusPath)
			print(ffmpegPath, opusPath)
			exec(ffmpegPath, opusPath)
			uv.run()
		end)
	end)
end, ...)