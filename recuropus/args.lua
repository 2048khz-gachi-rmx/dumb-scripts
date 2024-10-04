local Object = require("core").Object

local ArgParser = Object:extend()

local function chainAccessor(t, key, func)
	if not no_override or not t["Get" .. func] then
		t["Get" .. func] = function(self)
			return self[key]
		end
	end

	if not no_override or not t["Set" .. func] then
		t["Set" .. func] = function(self, val)
			self[key] = val
			return self
		end
	end
end

local function errorf(fmt, ...)
	return error(fmt:format(...))
end

function ArgParser:initialize()
	self._parsers = {}
	self._values = {}
	self._aliases = {}
	self._flags = {}

	self._parsed = false
end

chainAccessor(ArgParser, "_parsers", "Parsers")
chainAccessor(ArgParser, "_values", "Values")
chainAccessor(ArgParser, "_aliases", "Aliases")
chainAccessor(ArgParser, "_flags", "Flags")

--[[
	:AddValue("--value", {
		value = "default_value",
		type = "string",
		aliases = { "-v", "--val" },
		help = "User-friendly value description."
	})
]]

function ArgParser:AddValue(name, dat)
	-- the "type" key must either have a matching `toX` function in _G, or be a converter function itself
	local convFn = type(dat.type) == "function" and dat.type or _G["to" .. dat.type]
	if not convFn then
		errorf("invalid type in arg value %q (expected 'number', 'string' or a function)", dat.type)
		return
	end

	dat.convFn = convFn

	if dat.aliases then
		for _, aliasName in pairs(dat.aliases) do
			self._aliases[aliasName] = name
		end
	end

	self._values[name] = dat
	return self
end

-- :AddFlag("--flag", { aliases = { "-v", "--val" }, help = "User-friendly flag description." }
function ArgParser:AddFlag(flag, dat)
	self._flags[flag] = false

	if dat.aliases then
		for _, aliasName in pairs(dat.aliases) do
			self._aliases[aliasName] = flag
		end
	end

	return self
end

function ArgParser:Parse(args)
	local curFlag

	local values = self:GetValues()
	local parsers = self:GetParsers()
	local aliases = self:GetAliases()
	local flags = self:GetFlags()

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
				return false, ("Unknown flag: %s"):format(arg)
			end
		elseif curFlag then
			-- parsing a value
			local oldValue
			local valTbl = values[curFlag]
			local newFlag

			if valTbl then
				oldValue = valTbl.value
				local val, err = valTbl.convFn(arg)

				if val == nil then
					local reasonStr = err or ("can't convert `%s` to %s"):format(arg, valTbl.type)
					return false, ("invalid value for flag %s (%s)"):format(curFlag, reasonStr)
				end

				valTbl.value = val
			end

			if parsers[curFlag] then
				newFlag = parsers[curFlag] (arg, valTbl, oldValue)
			end

			curFlag = newFlag
		end
	end

	self._parsed = true

	if curFlag then
		return false, ("unfinished value (no value passed to `%s`)"):format(curFlag)
	end

	return true
end

function ArgParser:GetValue(name)
	local values = self:GetValues()
	local aliases = self:GetAliases()
	local flags = self:GetFlags()

	name = name:lower()
	name = aliases[name] or name

	if values[name] ~= nil then return values[name].value end
	if flags[name] ~= nil then return flags[name] end

	errorf("attempt to :GetValue an unregistered value/flag %q", name)
end

return {
	ArgParser = ArgParser
}