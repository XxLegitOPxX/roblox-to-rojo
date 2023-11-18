-- roblox-to-rojo.luau
-- XxLegitOPxX
-- Created @ 12/10/2023

--[[
	TODO:
	- Helper script that solves missing properties
	- Scripts that have children should also be possible to disable
	- NPCHostility HostilityChance attribute didn't get saved?
	- Missing properties to account for in the helper script:
	  - MaterialService.Use2022Materials
	  - BasePart.MaterialVariant
	  - TriangleMeshPart.CollisionFidelity
	  - ScreenGui.IgnoreGuiInset
	  - TextLabel.Font
	- Support for more types (all in rojo sync details preferably)
]]

-- Modules
local fs = (require)("@lune/fs")
local roblox = (require)("@lune/roblox")
local net = (require)("@lune/net")
local stdio = (require)("@lune/stdio")
local process = (require)("@lune/process")
-- User-configurable constants
local PLACE_FILE_PATH = "game.rbxl"
local SRC_PATH = "src"
local PROJECT_JSON_PATH = "default.project.json"
local FORCE_SAVE_AS_MODEL = {}
local CONTAINER_SAVE_TYPES = { -- Except this one, its read-only
	[0] = "Properties",
	[1] = "Descendants",
	[2] = "Both",
}
local CONTAINERS = {
	Workspace = 2,
	Lighting = 2,
	MaterialService = 2,
	ReplicatedFirst = 2,
	ReplicatedStorage = 2,
	ServerScriptService = 2,
	ServerStorage = 2,
	StarterGui = 2,
	StarterPack = 2,
	StarterPlayer = 2,
	Teams = 2,
	SoundService = 2,
	TextChatService = 2,
	Chat = 2,

	Players = 0,
	HttpService = 0,
	VoiceChatService = 0,
	LocalizationService = 0,
	TestService = 0,
}
-- Script constants
local PROJECT_JSON_TEMPLATE = {
	["tree"] = {
		["$className"] = "DataModel",
		-- Services will automatically be appended here
	},
}
local META_JSON_TEMPLATE = {
	["ignoreUnknownInstances"] = true,
}
local DISABLED_SCRIPT_TEMPLATE = {
	["properties"] = {
		["Disabled"] = true,
	},
}
local API_DUMP_URL = "https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/roblox/Full-API-Dump.json"
local SCRIPT_EXTENSIONS = {
	["Script"] = ".server.lua",
	["LocalScript"] = ".client.lua",
	["ModuleScript"] = ".lua",
}
--[[
	Some property tags like NotScriptable are still... scriptable and necessary
	to convert such as StarterGui.RtlTextSupport and VirtualCursorMode
]]
local PROPERTY_TAGS_BLACKLIST = {
	"ReadOnly",
	"Hidden",
	"NotBrowsable",
	"Deprecated",
}
local PROPERTIES_BLACKLIST = {
	"Name", -- Not allowed with Rojo
	"Parent", -- Not allowed with Rojo
	"Archivable",
	"LoadCharacterLayeredClothing ", -- Don't know why this one has a space but yeah...
	"ClockTime", -- Gets set automatically anyway (from TimeOfDay)
	"CurrentCamera", -- Gets set automatically anyway
	"Pivot Offset", -- NotScriptable
	"Origin", -- NotScriptable
	"WorldPivot", -- Gets set automatically anyway (can't blacklist PrimaryPart though)
	"AssemblyLinearVelocity",
	"AssemblyAngularVelocity",
	"BrickColor", -- Gets set automatically anyway (from Color)
	"SelectionStart", -- Unnecessary
	"CursorPosition", -- Unnecessary
	"PrimaryPart", -- Ref
	"SoundGroup", -- Ref
	"EnableFluidForces", -- Beta feature

	-- We only want Gui-based rotation
	"BasePart.Rotation",

	-- For conversion testing
	"Use2022Materials",
	"MaterialVariant",
	"CollisionFidelity",
	"IgnoreGuiInset",
	"Font",
	"FontFace",
}
local PROPERTIES_REPLACEMENTS = {
	-- For conversion testing
	--FontFace = "Font",
}
local GET_PROPERTY_ERROR = "__GET_PROPERTY_ERROR__"
local SAVE_PROPERTY_ERROR = "__SAVE_PROPERTY_ERROR__"
local BOOL_VALUES = {
	["true"] = true,
	["false"] = false,
}
local NUMBER_TYPES = {
	"int",
	"int64",
	"float",
	"double",
}
local IGNORED_TYPES = {
	"BinaryString",
}
local ROJO_ATTRIBUTES_TYPE_NAMES = {
	["boolean"] = "Bool",
	["number"] = "Float64",
	["string"] = "String",
	["CFrame"] = "String", -- Rojo doesn't support CFrame attributes yet...
}
local ROJOIFY_VALUE_RETURNS = { -- Anything in here will get returned instantly by rojoifyValue
	["boolean"] = true,
	["number"] = true,
	["string"] = true,
}
-- Reference types
local Vector2 = roblox.Vector2
local Vector3 = roblox.Vector3
local Color3 = roblox.Color3
local Enum = roblox.Enum
local CFrame = roblox.CFrame
local UDim2 = roblox.UDim2
local UDim = roblox.UDim
local NumberRange = roblox.NumberRange
-- Variables
local db = roblox.getReflectionDatabase()
local apiDump

-- Here we load a file just like in the first example
local file = fs.readFile(PLACE_FILE_PATH)
local game = roblox.deserializePlace(file)

-- Make sure a directory exists to save our models in
fs.writeDir(SRC_PATH)

local function countDict(dict)
	local count = 0
	for _, _ in pairs(dict) do
		count += 1
	end
	return count
end

local function getApiDump()
	local response = net.request({ url = API_DUMP_URL })
	return net.jsonDecode(response.body)
end

local function getParentName()
	local cwd = process.cwd
	local cwdSplit = string.split(cwd, "\\")
	local parentName = cwdSplit[#cwdSplit - 1] -- trailing backslash
	return parentName
end

local function getScriptExtension(script)
	return SCRIPT_EXTENSIONS[script.ClassName]
end

local function setUniqueName(instance)
	local randomId = math.random(1, 1000000)
	instance.Name ..= "_" .. randomId
end

local function removePackageLinks(child)
	local count = 0
	for _, desc in child:GetDescendants() do
		if desc:IsA("PackageLink") then
			desc:Destroy()
			count += 1
		end
	end
	if count > 0 then
		print(`Removed {count} package links from {child.Name} in order to save it properly`)
	end
end

local function getSuperclassNames(className)
	local superclassNames = {}

	local function get(className)
		local class = db:GetClass(className)
		local superclassName = class.Superclass
		if superclassName == nil then
			return
		end
		table.insert(superclassNames, superclassName)
		get(superclassName)
	end

	get(className)
	return superclassNames
end

local function isPropertyBlacklisted(className, prop)
	local classNames = { className, unpack(getSuperclassNames(className)) }
	for _, propName in pairs(PROPERTIES_BLACKLIST) do
		local split = string.split(propName, ".")
		if #split == 2 then
			local classNameSplit, propNameSplit = split[1], split[2]
			--print(className, classNameSplit, prop.Name, propNameSplit)
			if table.find(classNames, classNameSplit) and prop.Name == propNameSplit then
				return true
			end
		else
			if prop.Name == propName then
				return true
			end
		end
	end
	for _, tag in pairs(prop.Tags) do
		if table.find(PROPERTY_TAGS_BLACKLIST, tag) then
			return true
		end
	end
	return false
end

local function getProperty(className, propName)
	local class = db:GetClass(className)
	for _, prop in class.Properties do
		if prop.Name == propName then
			return prop
		end
	end
	return nil
end

local function doesPropertyHaveReplacement(className, prop)
	for propName, replacementName in pairs(PROPERTIES_REPLACEMENTS) do
		if prop.Name == propName then
			local replacementProp = getProperty(className, replacementName)
			return true, replacementProp
		end
	end
	return false
end

--[[
	Gets all properties of the specific class name AND all super classes (so
	we can still get props like BasePart.Position from a Part)
]]
local function getPropertiesForClassName(className)
	local classNames = { className, unpack(getSuperclassNames(className)) }
	local properties = {}

	local function get(className)
		local class = db:GetClass(className)

		for _, prop in class.Properties do
			local hasReplacement, replacementProp = doesPropertyHaveReplacement(className, prop)
			if isPropertyBlacklisted(className, prop) == false and hasReplacement == false then
				table.insert(properties, prop)
			elseif isPropertyBlacklisted(className, prop) == false or hasReplacement == true then
				table.insert(properties, replacementProp)
			end
		end
	end

	for _, className in pairs(classNames) do
		get(className)
	end

	return properties
end

--[[
	Parses the provided string value into a specific type (e.g. bool, number
	Color3). Cannot parse implicitly.
]]
local function parseValue(value, typeCategory, typeName)
	if typeName == "bool" then
		return BOOL_VALUES[value]
	elseif table.find(NUMBER_TYPES, typeName) then
		return tonumber(value)
	elseif typeName == "string" or typeName == "Content" then
		return value
	elseif typeName == "Vector2" then
		local split = string.split(value, ", ")
		local X, Y = tonumber(split[1]), tonumber(split[2])
		return Vector2.new(X, Y)
	elseif typeName == "Vector3" then
		local split = string.split(value, ", ")
		local X, Y, Z = tonumber(split[1]), tonumber(split[2]), tonumber(split[3])
		return Vector3.new(X, Y, Z)
	elseif typeName == "Color3" then
		local split = string.split(value, ", ")
		local R, G, B = tonumber(split[1]), tonumber(split[2]), tonumber(split[3])
		return Color3.new(R, G, B)
	elseif typeCategory == "Enum" then
		return Enum[typeName][value]
	elseif typeName == "CFrame" then
		--[[
			I couldn't find any apidump props with a default CFrame val set so
			this type parsing isn't necessary but I'll do it anyway
		]]
		local split = string.split(value, ", ")
		local X, Y, Z, R00, R01, R02, R10, R11, R12, R20, R21, R22 =
			tonumber(split[1]),
			tonumber(split[2]),
			tonumber(split[3]),
			tonumber(split[4]),
			tonumber(split[5]),
			tonumber(split[6]),
			tonumber(split[7]),
			tonumber(split[8]),
			tonumber(split[9]),
			tonumber(split[10]),
			tonumber(split[11]),
			tonumber(split[12])
		return CFrame.new(X, Y, Z, R00, R01, R02, R10, R11, R12, R20, R21, R22)
	elseif typeName == "UDim2" then
		value = string.gsub(value, "[{}]", "")
		local split = string.split(value, ", ")
		local scaleX, offsetX, scaleY, offsetY =
			tonumber(split[1]), tonumber(split[2]), tonumber(split[3]), tonumber(split[4])
		return UDim2.new(UDim.new(scaleX, offsetX), UDim.new(scaleY, offsetY))
	elseif typeName == "NumberRange" then
		local split = string.split(value, " ")
		table.remove(split, 3) -- Trailing space
		local n1, n2 = tonumber(split[1]), tonumber(split[2])
		return NumberRange.new(n1, n2)
	elseif table.find(IGNORED_TYPES, typeName) then
		return nil
	else
		-- For debugging, just in case I missed some type of value
		-- stdio.write(stdio.color("yellow"))
		-- print("[parseValue - unknown type]", tostring(value), typeCategory, typeName)
		-- stdio.write(stdio.color("reset"))
		return nil
	end
end

--[[
	Converts a roblox value into a value that can be used by Rojo in any
	.json file (e.g. booleans stay booleans, Color3/Vector3 turns into a json
	array). Values are returned in implicit form by default, otherwise in
	explicit form.
]]
local function rojoifyValue(value, isAttribute)
	if ROJOIFY_VALUE_RETURNS[typeof(value)] then
		return value
	elseif typeof(value) == "Vector2" then
		local X, Y = value.X, value.Y
		return { X, Y }
	elseif typeof(value) == "Vector3" then
		local X, Y, Z = value.X, value.Y, value.Z
		return { X, Y, Z }
	elseif typeof(value) == "Color3" then
		local R, G, B = value.R, value.G, value.B
		return { R, G, B }
	elseif typeof(value) == "EnumItem" then
		return value.Name
	elseif typeof(value) == "CFrame" then
		--return table.pack(value:GetComponents())
		local X, Y, Z, R00, R01, R02, R10, R11, R12, R20, R21, R22 = value:GetComponents()
		if isAttribute then
			return tostring(value)
		else
			return {
				CFrame = {
					position = { X, Y, Z },
					orientation = { { R00, R01, R02 }, { R10, R11, R12 }, { R20, R21, R22 } },
				},
			}
		end
	elseif typeof(value) == "UDim2" then
		local scaleX, offsetX = value.X.Scale, value.X.Offset
		local scaleY, offsetY = value.Y.Scale, value.Y.Offset
		return { ["UDim2"] = { { scaleX, offsetX }, { scaleY, offsetY } } }
	elseif typeof(value) == "NumberRange" then
		local n1, n2 = value.Min, value.Max
		return { ["NumberRange"] = { n1, n2 } }
	else
		-- For debugging, just in case I missed some type of value
		stdio.write(stdio.color("yellow"))
		print("[rojoifyValue - unknown type]", tostring(value), typeof(value))
		stdio.write(stdio.color("reset"))
		return nil
	end
end

local function getDefaultValuesForClassName(className)
	local classNames = { className, unpack(getSuperclassNames(className)) }
	local defaultValues = {}

	local function get(className)
		local class = db:GetClass(className)
		-- selene: allow(manual_table_clone)
		for propName, defaultValue in class.DefaultProperties do
			defaultValues[propName] = defaultValue
		end
	end

	for _, className in pairs(classNames) do
		get(className)
	end

	return defaultValues
end

local function getDefaultValuesForClassNameFromApiDump(className)
	local classNames = { className, unpack(getSuperclassNames(className)) }
	local defaultValues = {}

	local function get(className)
		local targetClass
		for _, class in pairs(apiDump.Classes) do
			if class.Name == className then
				targetClass = class
			end
		end

		for _, member in pairs(targetClass.Members) do
			if member.MemberType == "Property" and not string.match(member.Default, "__api_dump") then
				local typeCategory = member.ValueType.Category
				local typeName = member.ValueType.Name
				local defaultValue = parseValue(member.Default, typeCategory, typeName)
				defaultValues[member.Name] = defaultValue
			end
		end
	end

	for _, className in pairs(classNames) do
		get(className)
	end

	return defaultValues
end

local function getDefaultValue(className, prop)
	local defaultValuesRefDb = getDefaultValuesForClassName(className)
	local defaultValuesApiDump = getDefaultValuesForClassNameFromApiDump(className)
	return defaultValuesRefDb[prop.Name] or defaultValuesApiDump[prop.Name]
end

--[[
	Lune errors when attempting to get a property value if it doesn't
	internally (in the reflection database) contain a default value.
]]
local function tryGetInstanceProp(instance, prop)
	local value = GET_PROPERTY_ERROR
	local success, result = pcall(function()
		return instance[prop.Name]
	end)
	if success then
		value = result
	end
	return value
end

local function checkPropVal(instance, className, prop)
	local skip = false
	local success, result = pcall(function() -- Just in case
		local value = tryGetInstanceProp(instance, prop)
		local defaultValue = getDefaultValue(className, prop)
		if value == GET_PROPERTY_ERROR then
			stdio.write(stdio.color("red"))
			error("could not get value")
		end
		if value == defaultValue then
			skip = true
		end
		return value
	end)
	return success, result, skip
end

-- "defaultValue" must've already been parsed using parseValue first
--[[
local function propValuePrompt(container, prop, defaultValue)
	local kind
	local kindVerbs = {
		[nil] = "Type in",
		text = "Type in",
		select = "Choose",
	}
	local defaultOrOptions
	local strDefaultOrOptions
	if typeof(defaultValue) == "boolean" then
		kind = "select"
		defaultOrOptions = { defaultValue, not defaultValue }
		strDefaultOrOptions = { `*{tostring(defaultOrOptions[1])}`, tostring(defaultOrOptions[2]) }
	elseif typeof(defaultValue) == "CFrame" then
		kind = "text"
	end
	local selection = stdio.prompt( -- Starts from 1, not 0
		kind,
		`{kindVerbs[kind]} a value for "{container}.{prop}":`,
		strDefaultOrOptions
	)
	return selection, defaultOrOptions
end
]]

local function saveAttributes(tree, instance, isMetaFile)
	local attributes = {}
	for name, value in pairs(instance:GetAttributes()) do
		local typeName = ROJO_ATTRIBUTES_TYPE_NAMES[typeof(value)] or typeof(value)
		attributes[name] = { [typeName] = rojoifyValue(value, true) }
	end
	if isMetaFile then
		tree["properties"]["Attributes"] = attributes
		--tree["properties"]["AttributesSerialized"] = { Attributes = attributes }
	else
		tree["$properties"]["Attributes"] = attributes
		--tree["$properties"]["AttributesSerialized"] = { Attributes = attributes }
	end
end

local function saveTags(tree, instance, isMetaFile)
	local tags = {}
	for _, name in pairs(instance:GetTags()) do
		table.insert(tags, name)
	end
	if isMetaFile then
		tree["properties"]["Tags"] = tags
	else
		tree["$properties"]["Tags"] = tags
	end
end

local function saveProperty(tree, instance, className, prop, isMetaFile)
	local success, result, skip = checkPropVal(instance, className, prop)
	if not success then
		result = tostring(result):split("\nstack traceback")[1] -- We don't need the stack traceback
		print(`An error occured while checking property "{prop.Name}" value for class "{className}": {result}`)
		stdio.write(stdio.color("reset"))
	end
	if not skip then
		local value
		if success then
			value = rojoifyValue(result)
		else
			value = SAVE_PROPERTY_ERROR
		end
		if isMetaFile then
			tree["properties"][prop.Name] = value
		else
			tree["$properties"][prop.Name] = value
		end
	end
end

local saveChildren

local function getInstancePath(instance, separator)
	local pattern = '[\\/:%*%?"<>|]' -- All characters not allowed in Windows file names
	local path = instance.Name
	path = string.gsub(path, pattern, "_")

	local function addComponent(instance)
		if instance == game then
			return
		end
		local componentName = instance.Name
		componentName = string.gsub(componentName, pattern, "_")
		path = componentName .. separator .. path
		addComponent(instance.Parent)
	end

	addComponent(instance.Parent)
	return path
end

local function getInstanceSavePath(parent, instance, extension)
	extension = extension or ""
	local path = getInstancePath(instance, "/")
	local savePath = SRC_PATH .. "/" .. path .. extension
	return savePath
end

local function serializeMetaFile(instance)
	local className = instance.ClassName
	local metaFile = table.clone(META_JSON_TEMPLATE)
	metaFile["className"] = className

	-- Save properties
	local properties = getPropertiesForClassName(className)
	metaFile["properties"] = {}
	saveAttributes(metaFile, instance, true)
	saveTags(metaFile, instance, true)
	for _, prop in pairs(properties) do
		saveProperty(metaFile, instance, className, prop, true)
	end
	-- If no properties were saved, erase the properties key itself (less clutter)
	if countDict(metaFile["properties"]["Attributes"]) == 0 then
		metaFile["properties"]["Attributes"] = nil
	end
	-- if countDict(metaFile["properties"]["AttributesSerialized"]["Attributes"]) == 0 then
	-- 	metaFile["properties"]["AttributesSerialized"] = nil -- No "Attributes" here is intentional
	-- end
	if countDict(metaFile["properties"]["Tags"]) == 0 then
		metaFile["properties"]["Tags"] = nil
	end
	if countDict(metaFile["properties"]) == 0 then
		metaFile["properties"] = nil
	end

	-- Re-encode json
	local encoded = net.jsonEncode(metaFile, true)
	return encoded
end

local function createDisabledScriptMetaFile(parent, instance)
	if (instance:IsA("Script") or instance:IsA("LocalScript")) and instance.Disabled == true then
		local savePath = getInstanceSavePath(parent, instance)
		local encoded = net.jsonEncode(DISABLED_SCRIPT_TEMPLATE, true)
		fs.writeFile(savePath .. ".meta.json", encoded)
	end
end

local function saveAs(parent, instance, extension, customSavePath)
	local savePath = customSavePath or getInstanceSavePath(parent, instance, extension)
	return savePath,
		pcall(function()
			local file
			if instance:IsA("LuaSourceContainer") then
				createDisabledScriptMetaFile(parent, instance)
				file = instance.Source
			elseif extension == ".meta.json" then
				file = serializeMetaFile(instance)
			else
				file = roblox.serializeModel({ instance })
			end
			fs.writeFile(savePath, file)
		end)
end

local function saveAsScript(parent, instance, customSavePath)
	local extension = getScriptExtension(instance)
	local savePath, success, result = saveAs(parent, instance, extension, customSavePath)
	--print(customSavePath, savePath)
	if not success then
		stdio.write(stdio.color("red"))
		print(`An error occured while saving "{savePath}"): {result}`)
		stdio.write(stdio.color("reset"))
	end
end

local function saveAsModel(parent, instance, customSavePath)
	local extension = ".rbxm"
	local savePath, success, result = saveAs(parent, instance, extension, customSavePath)
	if not success then
		stdio.write(stdio.color("red"))
		print(`An error occured while saving "{savePath}"): {result}`)
		stdio.write(stdio.color("reset"))
	end
end

local function saveAsMetaFile(parent, instance, customSavePath)
	local extension = ".meta.json"
	local savePath, success, result = saveAs(parent, instance, extension, customSavePath)
	if not success then
		stdio.write(stdio.color("red"))
		print(`An error occured while saving "{savePath}"): {result}`)
		stdio.write(stdio.color("reset"))
	end
end

--[[
	When we provide a customSavePath into any of the saveAs functions, the
	extension parameter is automatically ignored and we have to add it onto
	the custom save path ourselves.
]]
local function saveAsFolder(parent, instance)
	local savePath = getInstanceSavePath(parent, instance)
	if instance:IsA("LuaSourceContainer") then
		local extension = getScriptExtension(instance)
		fs.writeDir(savePath)
		savePath ..= "/init" .. extension
		saveAsScript(parent, instance, savePath)
		saveChildren(instance) -- Recursion... BEGIN!
	else
		local extension = ".meta.json"
		fs.writeDir(savePath)
		savePath ..= "/init" .. extension
		saveAsMetaFile(parent, instance, savePath)
		saveChildren(instance) -- Recursion... BEGIN!
	end
end

local function checkForceSaveAsModel(instance)
	local path = getInstancePath(instance, ".")
	for searchType, str in pairs(FORCE_SAVE_AS_MODEL) do
		if searchType == "Name" and str == instance.Name then
			return true
		elseif searchType == "Path" and str == path then
			return true
		end
	end
	return false
end

local function saveInstance(parent, instance)
	if checkForceSaveAsModel(instance) then
		saveAsModel(parent, instance)
		return
	end

	if instance:IsA("LuaSourceContainer") and #instance:GetChildren() == 0 then
		-- Script AND has no children
		saveAsScript(parent, instance)
	elseif
		(instance:IsA("LuaSourceContainer") and #instance:GetChildren() > 0)
		or (not instance:IsA("LuaSourceContainer") and instance:FindFirstChildWhichIsA("LuaSourceContainer", true))
	then
		-- Script AND has children / Not a script AND contains scripts (descendants)
		saveAsFolder(parent, instance)
	elseif
		not instance:IsA("LuaSourceContainer") and not instance:FindFirstChildWhichIsA("LuaSourceContainer", true)
	then
		-- Not a script AND doesn't contain any scripts (descendants)
		saveAsModel(parent, instance)
	end
end

function saveChildren(parent)
	local childrenProcessed = {}
	for _, child in pairs(parent:GetChildren()) do
		if childrenProcessed[child.Name] then
			setUniqueName(child)
		end
		removePackageLinks(child)
		childrenProcessed[child.Name] = true
		saveInstance(parent, child)
	end
end

local function getContainerSaveType(container)
	local value = CONTAINERS[container]
	return CONTAINER_SAVE_TYPES[value]
end

local function saveContainer(containerName)
	local container = game:GetService(containerName)
	if not container then
		print(`"{containerName}" is not a valid service`)
		return
	end
	local containerSaveType = getContainerSaveType(containerName)
	if containerSaveType == "Descendants" or containerSaveType == "Both" then
		fs.writeDir(`{SRC_PATH}/{containerName}`)
	end

	-- Create default project json if it doesn't exist yet
	if not fs.isFile(PROJECT_JSON_PATH) then
		local projectFile = table.clone(PROJECT_JSON_TEMPLATE)
		projectFile["name"] = getParentName()
		local encoded = net.jsonEncode(projectFile, true)
		fs.writeFile(PROJECT_JSON_PATH, encoded)
	end

	-- Save in most basic form
	local encoded = fs.readFile(PROJECT_JSON_PATH)
	local decoded = net.jsonDecode(encoded)
	decoded.tree[containerName] = {
		["$className"] = containerName,
		["$ignoreUnknownInstances"] = true,
	}
	local containerTree = decoded.tree[containerName]

	-- Save properties and descendants
	if containerSaveType == "Properties" or containerSaveType == "Both" then
		local properties = getPropertiesForClassName(containerName)
		containerTree["$properties"] = {}
		saveAttributes(containerTree, container)
		saveTags(containerTree, container)
		for _, prop in pairs(properties) do
			saveProperty(containerTree, container, containerName, prop)
		end
		-- If no properties were saved, erase the properties key itself (less clutter)
		if countDict(containerTree["$properties"]["Attributes"]) == 0 then
			containerTree["$properties"]["Attributes"] = nil
		end
		-- if countDict(containerTree["$properties"]["AttributesSerialized"]["Attributes"]) == 0 then
		-- 	containerTree["$properties"]["AttributesSerialized"] = nil -- No "Attributes" here is intentional
		-- end
		if countDict(containerTree["$properties"]["Tags"]) == 0 then
			containerTree["$properties"]["Tags"] = nil
		end
		if countDict(containerTree["$properties"]) == 0 then
			containerTree["$properties"] = nil
		end
	end

	if containerSaveType == "Descendants" or containerSaveType == "Both" then
		containerTree["$path"] = `{SRC_PATH}/{container}`
	end

	-- Re-encode json
	encoded = net.jsonEncode(decoded, true)
	fs.writeFile(PROJECT_JSON_PATH, encoded)

	-- Save children
	saveChildren(container)
end

local function main()
	apiDump = getApiDump()
	local count = 0
	local maxCount = countDict(CONTAINERS)
	local startTime = os.clock()

	for containerName, _ in pairs(CONTAINERS) do
		saveContainer(containerName)
		count += 1
		print(`Saved {containerName} ({count}/{maxCount})`)
	end

	local timeElapsed = os.clock() - startTime
	print("\nConversion complete.")
	print("Time taken:", timeElapsed, "seconds")
	print(`Containers saved: {count}/{maxCount}`)
end

main()
