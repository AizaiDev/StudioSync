--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")

local failures = {}

local function check(name: string, ok: boolean, detail: string?)
	if not ok then
		table.insert(failures, name .. (if detail then " - " .. detail else ""))
	end
end

local modules: { [string]: any } = {}
local function load(name: string): any
	local path = `studio-sync/{name}.luau`
	local source = fs.readFile(path):gsub("%f[%a]const%s+", "local ")
	local module = luau.load(source, {
		debugName = path,
		environment = {
			script = {
				Parent = {
					Config = "Config",
					GitHub = "GitHub",
					ProjectMap = "ProjectMap",
					Sha1 = "Sha1",
					SyncPlan = "SyncPlan",
				},
			},
			require = function(moduleName: string)
				return assert(modules[moduleName], `{moduleName} is not loaded`)
			end,
			game = {
				GetService = function()
					return {}
				end,
			},
		},
		injectGlobals = true,
	})()
	modules[name] = module
	return module
end

local Config = load("Config")
local Sha1 = load("Sha1")
local ProjectMap = load("ProjectMap")
local SyncPlan = load("SyncPlan")
local GitHub = load("GitHub")
local Places = load("Places")

local function git(args: { string }): string
	local result = process.exec("git", args)
	assert(result.ok, result.stderr)
	return result.stdout
end

check("a GitHub refusal reads as a request error", GitHub.IsRequestError("GitHub refused the token (404 for /x)"))
check("a code error does not read as a request error", not GitHub.IsRequestError("Main.luau:12: attempt to index nil"))
check("a non-string error does not read as a request error", not GitHub.IsRequestError({}))
check("sha1 of empty", Sha1.Hex("") == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
for _, file in { "default.project.json", "tests/run.luau", "studio-sync/Main.luau" } do
	local expected = git({ "hash-object", file }):gsub("%s", "")
	check(`git blob sha of {file}`, Sha1.GitBlob(fs.readFile(file)) == expected)
end

local function Decode(text: string): (boolean, any)
	return pcall(serde.decode, "json", text)
end

local function Encoded(documents: { [string]: any }): { [string]: string }
	local texts = {}
	for path, document in documents do
		texts[path] = if type(document) == "string" then document else serde.encode("json", document)
	end
	return texts
end

local function Build(project: any, files: { any }, documents: { [string]: any }): any
	return ProjectMap.Build(project, files, Encoded(documents), Decode)
end

do
	local project = {
		tree = {
			["$className"] = "DataModel",
			ServerScriptService = {
				["$className"] = "ServerScriptService",
				["$path"] = "src/Server",
				Extra = { ["$path"] = "extra/Extra" },
			},
			ReplicatedStorage = { ["$className"] = "ReplicatedStorage", ["$path"] = "src/Shared" },
		},
	}
	local files = {
		{ path = "src/Server/Freecam/init.meta.json", sha = "1" },
		{ path = "src/Server/Freecam/FreecamScript.client.luau", sha = "2" },
		{ path = "src/Shared/Day.model.json", sha = "3" },
		{ path = "src/Shared/Region.model.json", sha = "4" },
		{ path = "src/Shared/Relay.model.json", sha = "5" },
		{ path = "src/Shared/Greeting.json", sha = "6" },
		{ path = "extra/Extra/init.server.luau", sha = "7" },
		{ path = "extra/Extra/Config.luau", sha = "8" },
	}
	local greetingText = '{ "start": "hello" }'
	local mapping = Build(project, files, {
		["src/Server/Freecam/init.meta.json"] = { className = "ScreenGui", properties = { ResetOnSpawn = false } },
		["src/Shared/Day.model.json"] = {
			className = "BoolValue",
			properties = { Value = true },
			attributes = { Set = false },
		},
		["src/Shared/Region.model.json"] = {
			className = "Folder",
			children = { { name = "Obtained", className = "BoolValue" } },
		},
		["src/Shared/Relay.model.json"] = { ClassName = "RemoteEvent" },
		["src/Shared/Greeting.json"] = greetingText,
	})
	check("fixture project maps without problems", #mapping.problems == 0, serde.encode("json", mapping.problems))

	local freecam = mapping.byKey["ServerScriptService/Freecam"]
	check("init.meta.json className makes the folder that class", freecam ~= nil and freecam.className == "ScreenGui")
	check("meta properties are read", freecam ~= nil and freecam.properties.ResetOnSpawn == false)
	local script = mapping.byKey["ServerScriptService/Freecam/FreecamScript"]
	check(
		"entries carry each level's class",
		script ~= nil and table.concat(script.classes, ",") == "ServerScriptService,ScreenGui,LocalScript"
	)
	check("services keep their class", mapping.services.ReplicatedStorage == "ReplicatedStorage")

	local day = mapping.byKey["ReplicatedStorage/Day"]
	check("a model.json gives its class", day ~= nil and day.className == "BoolValue")
	check("a model.json gives its properties", day ~= nil and day.properties.Value == true)
	check("a model.json gives its attributes", day ~= nil and day.attributes.Set == false)
	check("a model.json carries no source", day ~= nil and day.blob == nil)
	local obtained = mapping.byKey["ReplicatedStorage/Region/Obtained"]
	check("a model.json child is mapped", obtained ~= nil and obtained.className == "BoolValue")
	local relay = mapping.byKey["ReplicatedStorage/Relay"]
	check("a model.json may spell ClassName in Pascal case", relay ~= nil and relay.className == "RemoteEvent")

	local greeting = mapping.byKey["ReplicatedStorage/Greeting"]
	check("a .json file is a ModuleScript", greeting ~= nil and greeting.className == "ModuleScript")
	check(
		"a JSON module's source is generated",
		greeting ~= nil and greeting.source == ProjectMap.JsonModuleSource(greetingText)
	)
	check(
		"a JSON module is compared by its generated source",
		greeting ~= nil and greeting.blob == Sha1.GitBlob(greeting.source)
	)

	local extra = mapping.byKey["ServerScriptService/Extra"]
	check(
		"a nested project node with an init script becomes that script",
		extra ~= nil and extra.className == "Script" and extra.file == "extra/Extra/init.server.luau"
	)
	local config = mapping.byKey["ServerScriptService/Extra/Config"]
	check(
		"a nested project node's children carry its class",
		config ~= nil and table.concat(config.classes, ",") == "ServerScriptService,Script,ModuleScript"
	)
end

do
	local project = {
		tree = {
			["$className"] = "DataModel",
			ReplicatedStorage = {
				["$className"] = "ReplicatedStorage",
				["$path"] = "x",
				["$ignoreUnknownInstances"] = true,
				Modules = { ["$path"] = "x/Modules" },
			},
		},
	}
	local files = {
		{ path = "x/Races/init.luau", sha = "1" },
		{ path = "x/Races/init.meta.json", sha = "2" },
		{ path = "x/Assets/init.meta.json", sha = "3" },
		{ path = "x/Plain/A.luau", sha = "4" },
		{ path = "x/Modules/B.luau", sha = "5" },
	}
	local mapping = Build(project, files, {
		["x/Races/init.meta.json"] = { ignoreUnknownInstances = true },
		["x/Assets/init.meta.json"] = { ignoreUnknownInstances = true },
	})
	local exclusive = {}
	for _, container in mapping.exclusiveContainers do
		exclusive[table.concat(container.path, "/")] = true
	end
	check("a service that ignores unknown instances is not swept", not exclusive.ReplicatedStorage)
	check(
		"a script whose meta ignores unknown instances is not swept",
		mapping.byKey["ReplicatedStorage/Races"] ~= nil and not exclusive["ReplicatedStorage/Races"]
	)
	check(
		"a folder whose meta ignores unknown instances is not swept",
		mapping.byKey["ReplicatedStorage/Assets"] ~= nil and not exclusive["ReplicatedStorage/Assets"]
	)
	check("a plain git folder is swept", exclusive["ReplicatedStorage/Plain"] == true)
	check(
		"a project node that a file or folder beside it also maps is reported once",
		#mapping.problems == 1 and mapping.problems[1].path == "ReplicatedStorage/Modules",
		serde.encode("json", mapping.problems)
	)
end

do
	local project =
		{ tree = { ["$className"] = "DataModel", Root = { ["$className"] = "ReplicatedStorage", ["$path"] = "x" } } }
	local files = {
		{ path = "x/WindLine.model.json", sha = "1" },
		{ path = "x/Plain.model.json", sha = "2" },
	}
	local mapping = Build(project, files, {
		["x/WindLine.model.json"] = {
			className = "Part",
			properties = { Anchored = true, Size = { 1, 1, 1 } },
			children = { { name = "a0", className = "Attachment" } },
		},
		["x/Plain.model.json"] = { className = "Folder", children = { { name = "Flag", className = "BoolValue" } } },
	})
	local wind = mapping.byKey["Root/WindLine"]
	check(
		"a model.json with a value Studio Sync cannot apply is left to Studio",
		wind ~= nil and wind.studioOwned == true
	)
	check("a Studio-owned model maps none of its children", mapping.byKey["Root/WindLine/a0"] == nil)
	check("a Studio-owned model is not a problem", #mapping.problems == 0, serde.encode("json", mapping.problems))
	check("a model with plain values is built", mapping.byKey["Root/Plain/Flag"] ~= nil)
end

do
	check("the plugin lists no places of its own", Config.PLACES == nil)
	local parsed = Places.Parse({
		places = {
			["123"] = { label = "Testing", project = "default.project.json" },
			["456"] = { label = "Broken" },
			notAnId = { label = "x", project = "y" },
		},
	})
	check("a listed place is read", parsed.places[123] ~= nil and parsed.places[123].project == "default.project.json")
	check("an entry without a project is skipped", parsed.places[456] == nil)
	check(
		"skipped entries are named",
		parsed.problem ~= nil and parsed.problem:find("456, notAnId", 1, true) ~= nil,
		parsed.problem
	)
	check("a file without places is a problem", Places.Parse({}).problem ~= nil)
	local prefixes = {}
	for _, gameEntry in Config.GAMES do
		check(`{gameEntry.name} names an owner/repo`, gameEntry.repository:match("^[^/]+/[^/]+$") ~= nil)
		check(`{gameEntry.name} has its own attribute prefix`, not prefixes[gameEntry.attributePrefix])
		prefixes[gameEntry.attributePrefix] = true
		local attributes = Config.AttributesFor(gameEntry)
		check(
			`{gameEntry.name}'s attributes start with its prefix`,
			attributes.commit == gameEntry.attributePrefix .. "Commit"
				and attributes.seenPrefix == gameEntry.attributePrefix .. "Seen_"
		)
	end
	check("an owner is read from owner/repo", Config.OwnerOf("ExZeret/Flooded") == "ExZeret")
	for name, setting in Config.SETTINGS do
		check(`setting {name} is namespaced`, setting:sub(1, #"StudioSync_") == "StudioSync_")
	end
end

do
	local text = '{ "a": [[1]], "b": "]=]" }'
	local fakeGame = {
		GetService = function(_, name: string)
			assert(name == "HttpService")
			return {
				JSONDecode = function(_, json: string)
					return serde.decode("json", json)
				end,
			}
		end,
	}
	local decoded =
		luau.load(ProjectMap.JsonModuleSource(text), { environment = { game = fakeGame }, injectGlobals = true })()
	check("a JSON module decodes the file's text", decoded.a[1][1] == 1 and decoded.b == "]=]")
end

do
	local project =
		{ tree = { ["$className"] = "DataModel", Root = { ["$className"] = "ReplicatedStorage", ["$path"] = "x" } } }
	local files = {
		{ path = "x/A.luau", sha = "1" },
		{ path = "x/A.server.luau", sha = "2" },
		{ path = "x/B.legacy.luau", sha = "3" },
		{ path = "x/C/init.client.luau", sha = "4" },
		{ path = "x/C/D.luau", sha = "5" },
		{ path = "x/E.meta.json", sha = "6" },
		{ path = "x/E.luau", sha = "7" },
		{ path = "x/F/init.luau", sha = "8" },
		{ path = "x/F/init.meta.json", sha = "9" },
		{ path = "x/NOTES.md", sha = "10" },
		{ path = "x/G.model.json", sha = "11" },
	}
	local mapping = Build(project, files, {
		["x/E.meta.json"] = { className = "Tool" },
		["x/F/init.meta.json"] = { className = "ScreenGui" },
		["x/G.model.json"] = { className = "Folder", children = { { name = "H" }, { name = "I", className = "Part" } } },
	})
	check("name clash is reported", #mapping.problems == 5, serde.encode("json", mapping.problems))
	check("name clash maps neither file", mapping.byKey["Root/A"] == nil)
	check("init script makes the directory a script", mapping.byKey["Root/C"].className == "LocalScript")
	check("children of an init script are mapped", mapping.byKey["Root/C/D"].className == "ModuleScript")
	check("meta className beside a script is refused", mapping.byKey["Root/E"] == nil)
	check("meta className beside an init script is refused", mapping.byKey["Root/F"] == nil)
	check("a file type rojo ignores is not mapped or reported", mapping.byKey["Root/NOTES.md"] == nil)
	check("a model child with no className is refused", mapping.byKey["Root/G/H"] == nil)
	check("a model child beside a refused one is mapped", mapping.byKey["Root/G/I"].className == "Part")
end

do
	local project =
		{ tree = { ["$className"] = "DataModel", Root = { ["$className"] = "ReplicatedStorage", ["$path"] = "x" } } }
	local files = {
		{ path = "x/Explicit.luau", sha = "1" },
		{ path = "x/Explicit.meta.json", sha = "2" },
		{ path = "x/Tagged.luau", sha = "3" },
		{ path = "x/Tagged.meta.json", sha = "4" },
		{ path = "x/Attributed.luau", sha = "5" },
		{ path = "x/Attributed.meta.json", sha = "6" },
		{ path = "x/Broken.luau", sha = "7" },
		{ path = "x/Broken.meta.json", sha = "8" },
	}
	local mapping = Build(project, files, {
		["x/Explicit.meta.json"] = { properties = { Disabled = { Bool = true } } },
		["x/Tagged.meta.json"] = { properties = { Tags = { "Grabbable" } } },
		["x/Attributed.meta.json"] = { attributes = { Holster = "Back" } },
		["x/Broken.meta.json"] = "{ not json",
	})
	check("explicit property values are unwrapped", mapping.byKey["Root/Explicit"].properties.Disabled == true)
	check("a list property is refused, not unwrapped", mapping.byKey["Root/Tagged"] == nil)
	check("meta attributes are read", mapping.byKey["Root/Attributed"].attributes.Holster == "Back")
	check("an unreadable meta is refused", mapping.byKey["Root/Broken"] == nil)
	check("each refusal is reported", #mapping.problems == 2, serde.encode("json", mapping.problems))
end

type FakeNode = {
	className: string,
	source: string?,
	properties: { [string]: any }?,
	attributes: { [string]: any }?,
	children: { [string]: { FakeNode } }?,
}

local function FakeWorld(root: { [string]: { FakeNode } })
	local function Resolve(path: { string }, classes: { string }): (string, FakeNode?)
		local siblings = root
		local node: FakeNode? = nil
		for depth, name in path do
			local matches = siblings[name] or {}
			local matchClasses = {}
			for _, match in matches do
				table.insert(matchClasses, match.className)
			end
			local pick = SyncPlan.Pick(matchClasses, classes[depth])
			if pick.status ~= "Found" then
				return pick.status, nil
			end
			node = matches[pick.index]
			if depth < #path then
				siblings = (node :: FakeNode).children or {}
			end
		end
		return "Found", node
	end
	return {
		Children = function(path: { string }, classes: { string })
			local status, node = Resolve(path, classes)
			if status ~= "Found" then
				return nil
			end
			local children = {}
			for name, nodes in (node :: FakeNode).children or {} do
				for _, child in nodes do
					table.insert(children, { name = name, className = child.className })
				end
			end
			table.sort(children, function(a, b)
				return a.name < b.name
			end)
			return children
		end,
		Lookup = function(path: { string }, classes: { string }, propertyNames: { string }, attributeNames: { string })
			local status, node = Resolve(path, classes)
			if status ~= "Found" then
				return { status = status }
			end
			local found = node :: FakeNode
			local properties = {}
			for _, name in propertyNames do
				properties[name] = (found.properties or {})[name]
			end
			local attributes = {}
			for _, name in attributeNames do
				attributes[name] = (found.attributes or {})[name]
			end
			return {
				status = "Found",
				className = found.className,
				sourceBlobs = if found.source then { found.source } else {},
				properties = properties,
				attributes = attributes,
			}
		end,
	}
end

local function Entry(
	path: { string },
	classes: { string },
	blob: string?,
	properties: { [string]: any }?,
	attributes: { [string]: any }?
): any
	return {
		path = path,
		classes = classes,
		key = table.concat(path, "/"),
		className = classes[#classes],
		file = if blob then "file" else nil,
		blob = blob,
		properties = properties or {},
		attributes = attributes or {},
	}
end

local function MappingOf(entries: { any }, exclusiveContainers: { any }?): any
	local byKey = {}
	for _, entry in entries do
		byKey[entry.key] = entry
	end
	return {
		entries = entries,
		byKey = byKey,
		services = {},
		problems = {},
		exclusiveContainers = exclusiveContainers or {},
	}
end

local function Kinds(plan: any): string
	local kinds = {}
	for _, op in plan.ops do
		table.insert(kinds, `{op.kind}:{op.entry.key}`)
	end
	return table.concat(kinds, " ")
end

check("pick prefers the exact class", SyncPlan.Pick({ "Model", "ModuleScript" }, "ModuleScript").index == 2)
check("pick ignores assets that share the name", SyncPlan.Pick({ "Model", "Part" }, "Folder").status == "Missing")
check("pick replaces a lone script of another class", SyncPlan.Pick({ "Model", "Script" }, "ModuleScript").index == 2)
check("pick refuses twins", SyncPlan.Pick({ "Folder", "Folder" }, "Folder").status == "Ambiguous")
check(
	"pick refuses two replaceable candidates",
	SyncPlan.Pick({ "Script", "Folder" }, "ModuleScript").status == "Ambiguous"
)
check("pick never replaces a service child", SyncPlan.Pick({ "Folder" }, "StarterPlayerScripts").status == "Missing")

do
	local RS = "ReplicatedStorage"
	local world = FakeWorld({
		S = {
			{
				className = RS,
				children = {
					Same = { { className = "ModuleScript", source = "a" } },
					Changed = { { className = "ModuleScript", source = "old" } },
					Moved = { { className = "ModuleScript", source = "m" } },
					Model = { { className = "Model" } },
					Twin = { { className = "Folder" }, { className = "Folder" } },
					Toggle = { { className = "Script", source = "t", properties = { Disabled = false } } },
					Gone = { { className = "Script", source = "g" } },
					Asset = { { className = "Model" } },
					Stray = { { className = "Folder" } },
					Reenabled = { { className = "Script", source = "r", properties = { Disabled = true } } },
				},
			},
		},
	})
	local desired = MappingOf({
		Entry({ "S", "Same" }, { RS, "ModuleScript" }, "a"),
		Entry({ "S", "Changed" }, { RS, "ModuleScript" }, "new"),
		Entry({ "S", "Moved" }, { RS, "Script" }, "m"),
		Entry({ "S", "Model" }, { RS, "ModuleScript" }, "x"),
		Entry({ "S", "Model", "Inside" }, { RS, "ModuleScript", "ModuleScript" }, "y"),
		Entry({ "S", "Twin" }, { RS, "Folder" }),
		Entry({ "S", "Twin", "Child" }, { RS, "Folder", "ModuleScript" }, "z"),
		Entry({ "S", "Toggle" }, { RS, "Script" }, "t", { Disabled = true }),
		Entry({ "S", "New" }, { RS, "Folder" }),
		Entry({ "S", "New", "Leaf" }, { RS, "Folder", "LocalScript" }, "l"),
		Entry({ "S", "Stray" }, { RS, "ModuleScript" }, "s"),
		Entry({ "S", "Reenabled" }, { RS, "Script" }, "r"),
	})
	local previous = MappingOf({
		Entry({ "S", "Same" }, { RS, "ModuleScript" }, "a"),
		Entry({ "S", "Gone" }, { RS, "Script" }, "g"),
		Entry({ "S", "Asset" }, { RS, "ModuleScript" }, "q"),
		Entry({ "S", "Never" }, { RS, "ModuleScript" }, "n"),
		Entry({ "S", "Moved" }, { RS, "ModuleScript" }, "m"),
		Entry({ "S", "Reenabled" }, { RS, "Script" }, "r", { Disabled = true }),
	})

	local plan = SyncPlan.Build(desired, previous, world)
	check(
		"plan ops",
		Kinds(plan)
			== "Update:S/Changed Replace:S/Moved Create:S/Model Create:S/Model/Inside SetProperties:S/Toggle Create:S/New Create:S/New/Leaf SetProperties:S/Reenabled Delete:S/Gone",
		Kinds(plan)
	)
	check(
		"twins and a folder git never owned are skipped",
		#plan.problems == 2 and plan.problems[1].path == "S/Twin" and plan.problems[2].path == "S/Stray",
		serde.encode("json", plan.problems)
	)
	check("counts", plan.counts.created == 4 and plan.counts.updated == 1 and plan.counts.deleted == 1)
	local reset = {}
	for _, op in plan.ops do
		if op.kind == "SetProperties" then
			reset[op.entry.key] = table.concat(op.reset, ",")
		end
	end
	check("a property the meta dropped is reset", reset["S/Reenabled"] == "Disabled", serde.encode("json", reset))
	check("a property the meta still sets is not reset", reset["S/Toggle"] == "", serde.encode("json", reset))

	local fresh = SyncPlan.Build(desired, nil, world)
	check("no previous sync means no deletes", not Kinds(fresh):find("Delete"), Kinds(fresh))
	check(
		"no previous sync counts class changes as unrecorded",
		table.concat(fresh.unrecorded, ",") == "S/Moved,S/Stray" and Kinds(fresh):find("Replace:S/Stray") ~= nil,
		Kinds(fresh)
	)
	check("a recorded plan has no unrecorded class changes", #plan.unrecorded == 0)
	check(
		"a first sync lists a new instance beside a same-named Studio instance of another class",
		table.concat(fresh.twins, ",") == "S/Model (Studio has a Model)" and Kinds(fresh):find("Create:S/Model") ~= nil,
		table.concat(fresh.twins, ",")
	)
	check("a sync after the first lists no twins", #plan.twins == 0, table.concat(plan.twins, ","))

	local sources = SyncPlan.SourcesOnly(plan)
	check(
		"a recheck keeps only the script source repairs",
		Kinds(sources) == "Update:S/Changed"
			and sources.counts.updated == 1
			and sources.counts.created == 0
			and sources.counts.deleted == 0,
		Kinds(sources)
	)

	local atHead = SyncPlan.Build(desired, desired, world)
	check(
		"a sync at the recorded head leaves a Studio-only folder alone",
		not Kinds(atHead):find("Replace") and #atHead.unrecorded == 0,
		Kinds(atHead)
	)

	local retyped = MappingOf({ Entry({ "S", "Reenabled" }, { RS, "ModuleScript" }, "r") })
	local retypedWorld = FakeWorld({
		S = { { className = RS, children = { Reenabled = { { className = "ModuleScript", source = "r" } } } } },
	})
	check(
		"a property is not reset across a class change",
		Kinds(SyncPlan.Build(retyped, previous, retypedWorld)) == "",
		Kinds(SyncPlan.Build(retyped, previous, retypedWorld))
	)

	local withProblem = MappingOf({ Entry({ "S", "Same" }, { RS, "ModuleScript" }, "a") })
	withProblem.problems = { { path = "S/Gone", reason = "test" } }
	check(
		"a mapping problem never turns into a delete",
		not Kinds(SyncPlan.Build(withProblem, previous, world)):find("Delete:S/Gone"),
		Kinds(SyncPlan.Build(withProblem, previous, world))
	)
end

do
	local RS = "ReplicatedStorage"
	local world = FakeWorld({
		S = {
			{
				className = RS,
				children = {
					Day = {
						{
							className = "BoolValue",
							properties = { Value = true },
							attributes = { Set = true, Old = 1 },
						},
					},
					Remote = { { className = "RemoteEvent" } },
					Stale = { { className = "RemoteEvent" } },
				},
			},
		},
	})
	local desired = MappingOf({
		Entry({ "S", "Day" }, { RS, "BoolValue" }, nil, { Value = true }, { Set = false }),
		Entry({ "S", "Remote" }, { RS, "RemoteEvent" }),
		Entry({ "S", "Added" }, { RS, "RemoteFunction" }),
	})
	local previous = MappingOf({
		Entry({ "S", "Day" }, { RS, "BoolValue" }, nil, { Value = true }, { Set = false, Old = 1 }),
		Entry({ "S", "Remote" }, { RS, "RemoteEvent" }),
		Entry({ "S", "Stale" }, { RS, "RemoteEvent" }),
	})
	local plan = SyncPlan.Build(desired, previous, world)
	check(
		"a model's instances are planned like scripts",
		Kinds(plan) == "SetProperties:S/Day Create:S/Added Delete:S/Stale",
		Kinds(plan)
	)
	local op = plan.ops[1]
	check("a changed attribute is set", op.attributes.Set == false and op.attributes.Old == nil)
	check("an attribute the model dropped is cleared", table.concat(op.clear, ",") == "Old")
	check("an unchanged property is not set", next(op.properties) == nil)
end

do
	local function Run(id: number, status: string, conclusion: string?, name: string?): any
		return { id = id, name = name or "ci", status = status, conclusion = conclusion }
	end
	local function Judge(runs: { any }): string
		local summary = GitHub.Summarize(runs)
		return `{summary.total}|{table.concat(summary.pending, ",")}|{table.concat(summary.failed, ",")}`
	end
	check(
		"a cancelled run that a later run passed does not hold CI",
		Judge({ Run(1, "completed", "cancelled"), Run(2, "completed", "success") }) == "1||",
		Judge({ Run(1, "completed", "cancelled"), Run(2, "completed", "success") })
	)
	check(
		"an older failure that a later run passed does not fail CI",
		Judge({ Run(5, "completed", "success"), Run(3, "completed", "failure") }) == "1||"
	)
	check(
		"a newer failure fails CI",
		Judge({ Run(3, "completed", "success"), Run(5, "completed", "failure") }) == "1||ci (failure)"
	)
	check(
		"a newer run still going is pending",
		Judge({ Run(3, "completed", "success"), Run(4, "in_progress", nil) }) == "1|ci|"
	)
	check("a lone cancelled run is pending", Judge({ Run(1, "completed", "cancelled") }) == "1|ci|")
	check(
		"other workflows are not counted",
		Judge({ Run(9, "completed", "failure", "land"), Run(2, "completed", "success") }) == "1||"
	)
	check("no ci run means nothing to judge", Judge({}) == "0||")
end

do
	local RS = "ReplicatedStorage"
	local world = FakeWorld({
		S = {
			{
				className = RS,
				children = {
					Remote = { { className = "RemoteEvent" } },
					Gui = {
						{
							className = "ScreenGui",
							children = {
								Code = { { className = "LocalScript", source = "c" } },
								Gone = { { className = "ModuleScript", source = "g" } },
								Frame = { { className = "Frame" } },
							},
						},
					},
					Asset = { { className = "Model" } },
				},
			},
		},
	})
	local previous = MappingOf({
		Entry({ "S", "Remote" }, { RS, "RemoteEvent" }),
		Entry({ "S", "Gui" }, { RS, "ScreenGui" }),
		Entry({ "S", "Gui", "Code" }, { RS, "ScreenGui", "LocalScript" }, "c"),
		Entry({ "S", "Gui", "Gone" }, { RS, "ScreenGui", "ModuleScript" }, "g"),
	})
	local desired = MappingOf({
		Entry({ "S", "Remote" }, { RS, "UnreliableRemoteEvent" }),
		Entry({ "S", "Gui" }, { RS, "Model" }),
		Entry({ "S", "Gui", "Code" }, { RS, "Model", "LocalScript" }, "c"),
		Entry({ "S", "Gui", "New" }, { RS, "Model", "ModuleScript" }, "n"),
		Entry({ "S", "Asset" }, { RS, "RemoteEvent" }),
	})
	local plan = SyncPlan.Build(desired, previous, world)
	check(
		"a class change Studio cannot convert replaces the instance git owned instead of adding a twin",
		Kinds(plan) == "Replace:S/Remote Replace:S/Gui Create:S/Gui/New Create:S/Asset Delete:S/Gui/Gone",
		Kinds(plan)
	)
	check(
		"such a class change is listed with both classes for the hold",
		table.concat(plan.retyped, ",") == "S/Remote (RemoteEvent to UnreliableRemoteEvent),S/Gui (ScreenGui to Model)",
		table.concat(plan.retyped, ",")
	)
	check("a retyped instance is replaced from its old class", plan.ops[1].fromClass == "RemoteEvent")
	local delete = plan.ops[#plan.ops]
	check(
		"a delete under a retyped container finds it under its new class",
		table.concat(delete.entry.classes, ",") == "ReplicatedStorage,Model,ModuleScript",
		table.concat(delete.entry.classes, ",")
	)
	check("a Studio asset sharing the name of a new git instance is still left alone", #plan.problems == 0)

	local fresh = SyncPlan.Build(desired, nil, world)
	check(
		"a first sync, with no record of what git owned, holds a class change it cannot convert as a twin",
		#fresh.retyped == 0
			and Kinds(fresh):find("Create:S/Remote") ~= nil
			and table.concat(fresh.twins, ",")
				== "S/Remote (Studio has a RemoteEvent),S/Gui (Studio has a ScreenGui),S/Asset (Studio has a Model)",
		table.concat(fresh.twins, ",")
	)
end

do
	local RS = "ReplicatedStorage"
	local world = FakeWorld({
		S = {
			{
				className = RS,
				children = {
					Kept = { { className = "Script", children = { Part = { { className = "Part" } } } } },
					Emptied = { { className = "Script" } },
					Gone = {},
					Back = { { className = "Script", children = { Part = { { className = "Part" } } } } },
				},
			},
		},
	})
	local kept = SyncPlan.ReadKept({
		{ path = { "S", "Kept" }, classes = { RS, "Script" } },
		{ path = { "S", "Kept" }, classes = { RS, "Script" } },
		{ path = { "S", "Emptied" }, classes = { RS, "Script" } },
		{ path = { "S", "Gone" }, classes = { RS, "Script" } },
		{ path = { "S", "Back" }, classes = { RS, "Script" } },
		{ path = { "S", "Broken" }, classes = { RS } },
		"not a kept item",
	})
	check("a malformed kept item is dropped when read", #kept == 5, tostring(#kept))
	check("a kept list that is not a list reads as empty", #SyncPlan.ReadKept("x") == 0)
	local desired = MappingOf({ Entry({ "S", "Back" }, { RS, "Script" }, "b") })
	local remaining, problems = SyncPlan.StillKept(kept, desired, world)
	local keys = {}
	for _, item in remaining do
		table.insert(keys, table.concat(item.path, "/"))
	end
	check(
		"a kept instance stays listed until it is gone or git maps it again",
		table.concat(keys, ",") == "S/Kept,S/Emptied",
		table.concat(keys, ",")
	)
	check(
		"every sync reports each kept instance once",
		#problems == 2 and problems[1].path == "S/Kept" and problems[1].reason:find("holds 1 instance") ~= nil,
		serde.encode("json", problems)
	)
end

do
	local RS = "ReplicatedStorage"
	local world = FakeWorld({
		S = {
			{
				className = RS,
				children = {
					Owned = {
						{
							className = "Folder",
							children = {
								Live = { { className = "ModuleScript", source = "l" } },
								Stale = { { className = "Script", source = "s" } },
								Twin = {
									{ className = "Script", source = "t1" },
									{ className = "Script", source = "t2" },
								},
								Prop = { { className = "Part" } },
								Old = {
									{
										className = "Folder",
										children = { Inner = { { className = "LocalScript", source = "i" } } },
									},
								},
								Broken = { { className = "ModuleScript", source = "b" } },
							},
						},
					},
					Shared = {
						{
							className = "Folder",
							children = { StudioOnly = { { className = "Script", source = "x" } } },
						},
					},
				},
			},
		},
	})
	local owned = Entry({ "S", "Owned" }, { RS, "Folder" })
	local desired = MappingOf({
		owned,
		Entry({ "S", "Owned", "Live" }, { RS, "Folder", "ModuleScript" }, "l"),
		Entry({ "S", "Shared" }, { RS, "Folder" }),
	}, { { path = owned.path, classes = owned.classes } })
	desired.problems = { { path = "S/Owned/Broken", reason = "test" } }
	local fresh = SyncPlan.Build(desired, nil, world)
	check(
		"a first sync deletes the scripts git no longer has under a container git owns outright, deepest first",
		Kinds(fresh) == "Delete:S/Owned/Old/Inner Delete:S/Owned/Stale Delete:S/Owned/Twin",
		Kinds(fresh)
	)
	check(
		"a first sync lists those scripts for its hold",
		table.concat(fresh.leftovers, ",") == "S/Owned/Old/Inner,S/Owned/Stale,S/Owned/Twin,S/Owned/Twin",
		table.concat(fresh.leftovers, ",")
	)
	check("leftovers count as deletes, once per name and class", fresh.counts.deleted == 3)
	local recorded = SyncPlan.Build(desired, desired, world)
	check("a sync after the first looks for no leftovers", #recorded.leftovers == 0, Kinds(recorded))
end

do
	local project = {
		tree = {
			["$className"] = "DataModel",
			Root = {
				["$className"] = "ReplicatedStorage",
				["$path"] = "x",
				["$ignoreUnknownInstances"] = true,
				Nested = { ["$path"] = "y", ["$ignoreUnknownInstances"] = true },
			},
			Plain = { ["$className"] = "ServerScriptService", ["$path"] = "z" },
		},
	}
	local files = {
		{ path = "x/Owned/A.luau", sha = "1" },
		{ path = "x/Shared/init.meta.json", sha = "2" },
		{ path = "x/Shared/B.luau", sha = "3" },
		{ path = "x/Tagged.luau", sha = "4" },
		{ path = "x/Tagged.meta.json", sha = "5" },
		{ path = "x/Remote.model.json", sha = "6" },
		{ path = "y/C.luau", sha = "7" },
		{ path = "z/D.luau", sha = "8" },
	}
	local mapping = Build(project, files, {
		["x/Shared/init.meta.json"] = { ignoreUnknownInstances = true },
		["x/Tagged.meta.json"] = { ignoreUnknownInstances = true },
		["x/Remote.model.json"] = { className = "RemoteEvent" },
	})
	local exclusive = {}
	for _, container in mapping.exclusiveContainers do
		table.insert(exclusive, table.concat(container.path, "/"))
	end
	table.sort(exclusive)
	check(
		"containers whose unknown children rojo would delete are the ones a first sync sweeps",
		table.concat(exclusive, ",") == "Plain,Plain/D,Root/Nested/C,Root/Owned,Root/Owned/A,Root/Shared/B",
		table.concat(exclusive, ",")
	)
end

do
	local RS = "ReplicatedStorage"
	local withWind = FakeWorld({
		R = {
			{
				className = RS,
				children = { Wind = { { className = "Part", children = { a0 = { { className = "Attachment" } } } } } },
			},
		},
	})
	local studioOwned = Entry({ "R", "Wind" }, { RS, "Part" })
	studioOwned.studioOwned = true
	local missing = SyncPlan.Build(MappingOf({ studioOwned }), nil, FakeWorld({ R = { { className = RS } } }))
	check("a missing Studio-owned model is reported, not created", #missing.ops == 0 and #missing.problems == 1)
	local present = SyncPlan.Build(MappingOf({ studioOwned }), nil, withWind)
	check("a Studio-owned model that exists is left alone", #present.ops == 0 and #present.problems == 0)
	local wrongClass = SyncPlan.Build(
		MappingOf({ studioOwned }),
		nil,
		FakeWorld({ R = { { className = RS, children = { Wind = { { className = "Folder" } } } } } })
	)
	check("a Studio-owned model of the wrong class is reported", #wrongClass.ops == 0 and #wrongClass.problems == 1)
	local wasBuilt = MappingOf({
		Entry({ "R", "Wind" }, { RS, "Part" }),
		Entry({ "R", "Wind", "a0" }, { RS, "Part", "Attachment" }),
	})
	local turnedOwned = SyncPlan.Build(MappingOf({ studioOwned }), wasBuilt, withWind)
	check("a model that became Studio-owned keeps its children", Kinds(turnedOwned) == "", Kinds(turnedOwned))
end

do
	local enginePattern = fs.readFile("studio-sync/Main.luau"):match('ENGINE_FILE_PATTERN = "(.-)"\n')
	check("Main.luau names the files a self-update loads", enginePattern ~= nil)
	for _, entry in fs.readDir("studio-sync") do
		check(
			`studio-sync/{entry} can be loaded by a self-update`,
			fs.isFile(`studio-sync/{entry}`) and enginePattern ~= nil and entry:match(enginePattern) ~= nil
		)
	end
end

if #failures > 0 then
	for _, failure in failures do
		print("FAIL " .. failure)
	end
	process.exit(1)
end
print("studio-sync: ok")
