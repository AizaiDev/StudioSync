--!strict

const Config = require(script.Parent.Config)
const Sha1 = require(script.Parent.Sha1)

export type ScriptClass = "ModuleScript" | "Script" | "LocalScript"

export type TreeFile = {
	path: string,
	sha: string,
}

export type Entry = {
	path: { string },
	classes: { string },
	key: string,
	className: string,
	file: string?,
	blob: string?,
	source: string?,
	properties: { [string]: any },
	attributes: { [string]: any },
	studioOwned: boolean?,
}

export type Problem = {
	path: string,
	reason: string,
}

export type Container = {
	path: { string },
	classes: { string },
}

--- exclusiveContainers are the instances whose unknown children a Rojo serve deletes, because no
--- meta.json or project node sets ignoreUnknownInstances on them. SyncPlan sweeps them on a first sync.
export type Mapping = {
	entries: { Entry },
	byKey: { [string]: Entry },
	services: { [string]: string },
	problems: { Problem },
	exclusiveContainers: { Container },
}

export type Documents = { [string]: string }

export type Decode = (text: string) -> (boolean, any)

type Directory = {
	files: { [string]: TreeFile },
	directories: { [string]: boolean },
}

type ScriptSuffix = {
	suffix: string,
	className: ScriptClass,
}

type FileKind =
	{ kind: "Script", name: string, className: ScriptClass }
	| { kind: "Model", name: string }
	| { kind: "JsonModule", name: string }
	| { kind: "Meta" }
	| { kind: "Unsupported" }
	| { kind: "Ignored" }

type Values = { [string]: any }

const SCRIPT_SUFFIXES: { ScriptSuffix } = {
	{ suffix = ".server.luau", className = "Script" },
	{ suffix = ".server.lua", className = "Script" },
	{ suffix = ".client.luau", className = "LocalScript" },
	{ suffix = ".client.lua", className = "LocalScript" },
	{ suffix = ".luau", className = "ModuleScript" },
	{ suffix = ".lua", className = "ModuleScript" },
}

const UNSUPPORTED_SUFFIXES = {
	".legacy.luau",
	".local.luau",
	".plugin.luau",
	".legacy.lua",
	".local.lua",
	".project.json",
	".rbxm",
	".rbxmx",
	".txt",
	".csv",
	".toml",
	".yaml",
	".yml",
}
const META_SUFFIX = ".meta.json"
const MODEL_SUFFIX = ".model.json"
const JSON_SUFFIX = ".json"
const INIT_NAME = "init"
const KEY_SEPARATOR = "/"
const SUPPORTED_VALUE_TYPES = { boolean = true, number = true, string = true }

const ProjectMap = {}

function ProjectMap.Key(path: { string }): string
	return table.concat(path, KEY_SEPARATOR)
end

local function EndsWith(text: string, suffix: string): boolean
	return #text >= #suffix and string.sub(text, -#suffix) == suffix
end

local function Strip(text: string, suffix: string): string
	return string.sub(text, 1, #text - #suffix)
end

local function ClassifyFile(fileName: string): FileKind
	if EndsWith(fileName, META_SUFFIX) then
		return { kind = "Meta" }
	elseif EndsWith(fileName, MODEL_SUFFIX) then
		return { kind = "Model", name = Strip(fileName, MODEL_SUFFIX) }
	end
	for _, unsupported in UNSUPPORTED_SUFFIXES do
		if EndsWith(fileName, unsupported) then
			return { kind = "Unsupported" }
		end
	end
	for _, rule in SCRIPT_SUFFIXES do
		if EndsWith(fileName, rule.suffix) then
			return { kind = "Script", name = Strip(fileName, rule.suffix), className = rule.className }
		end
	end
	if EndsWith(fileName, JSON_SUFFIX) then
		return { kind = "JsonModule", name = Strip(fileName, JSON_SUFFIX) }
	end
	return { kind = "Ignored" }
end

--- The ModuleScript source a plain .json file becomes.
function ProjectMap.JsonModuleSource(text: string): string
	local equals = ""
	while string.find(text, `]{equals}]`, 1, true) do
		equals ..= "="
	end
	return `return game:GetService("HttpService"):JSONDecode([{equals}[\n{text}\n]{equals}])\n`
end

local function IndexDirectories(files: { TreeFile }): { [string]: Directory }
	const directories: { [string]: Directory } = {}
	local function Get(path: string): Directory
		local directory = directories[path]
		if not directory then
			directory = { files = {}, directories = {} }
			directories[path] = directory
		end
		return directory
	end

	for _, file in files do
		local parentPath, fileName = string.match(file.path, "^(.*)/([^/]+)$")
		if not parentPath or not fileName then
			continue
		end
		Get(parentPath).files[fileName] = file

		local childPath = parentPath
		while true do
			local grandparent, name = string.match(childPath, "^(.*)/([^/]+)$")
			if not grandparent or not name then
				break
			end
			const grandparentDirectory = Get(grandparent)
			if grandparentDirectory.directories[name] then
				break
			end
			grandparentDirectory.directories[name] = true
			childPath = grandparent
		end
	end
	return directories
end

local function UnwrapValue(value: any): any
	if type(value) ~= "table" then
		return value
	end
	const onlyKey, onlyValue = next(value)
	if type(onlyKey) == "string" and next(value, onlyKey) == nil then
		return onlyValue
	end
	return value
end

local function SortedKeys(map: { [string]: any }): { string }
	const keys = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local function Field(document: { [string]: any }, name: string): any
	const value = document[name]
	if value ~= nil then
		return value
	end
	return document[string.upper(string.sub(name, 1, 1)) .. string.sub(name, 2)]
end

--- Every .json file under a directory the project maps: the meta.json, model.json and JSON module
--- files whose text Build needs in its documents.
function ProjectMap.DocumentPaths(project: any, files: { TreeFile }): { TreeFile }
	const roots: { string } = {}
	local function CollectRoots(node: any)
		if type(node) ~= "table" then
			return
		end
		if type(node["$path"]) == "string" then
			table.insert(roots, node["$path"])
		end
		for key, child in node do
			if string.sub(key, 1, 1) ~= "$" then
				CollectRoots(child)
			end
		end
	end
	CollectRoots(project.tree)

	const documents = {}
	for _, file in files do
		if not EndsWith(file.path, JSON_SUFFIX) then
			continue
		end
		for _, root in roots do
			if file.path == root or string.sub(file.path, 1, #root + 1) == root .. "/" then
				table.insert(documents, file)
				break
			end
		end
	end
	return documents
end

function ProjectMap.Build(project: any, files: { TreeFile }, documents: Documents, Decode: Decode): Mapping
	const directories = IndexDirectories(files)
	const filesByPath: { [string]: TreeFile } = {}
	for _, file in files do
		filesByPath[file.path] = file
	end
	const mapping: Mapping = { entries = {}, byKey = {}, services = {}, problems = {}, exclusiveContainers = {} }
	const exclusiveByKey: { [string]: Container } = {}
	const exclusiveOrder: { string } = {}

	local function SetExclusive(path: { string }, classes: { string })
		const key = ProjectMap.Key(path)
		if not exclusiveByKey[key] then
			table.insert(exclusiveOrder, key)
		end
		exclusiveByKey[key] = { path = path, classes = classes }
	end

	local function ClearExclusive(path: { string })
		exclusiveByKey[ProjectMap.Key(path)] = nil
	end

	local function Report(path: { string }, reason: string)
		table.insert(mapping.problems, { path = ProjectMap.Key(path), reason = reason })
	end

	local function Extend(list: { string }, item: string): { string }
		const extended = table.clone(list)
		table.insert(extended, item)
		return extended
	end

	local function ReadDocument(path: { string }, documentPath: string): any
		const text = documents[documentPath]
		if text == nil then
			Report(path, `{documentPath} could not be read`)
			return nil
		end
		const ok, decoded = Decode(text)
		if not ok or type(decoded) ~= "table" then
			Report(path, `{documentPath} is not a JSON object`)
			return nil
		end
		return decoded
	end

	local function ReadValues(path: { string }, source: string, field: string, raw: any): Values?
		const values = {}
		if raw == nil then
			return values
		end
		if type(raw) ~= "table" then
			Report(path, `{source} sets {field} to something other than an object`)
			return nil
		end
		for name, value in raw do
			const unwrapped = UnwrapValue(value)
			if type(name) ~= "string" or not SUPPORTED_VALUE_TYPES[type(unwrapped)] then
				Report(path, `{source} sets {field} {name} to a value {Config.NAME} cannot apply`)
				return nil
			end
			values[name] = unwrapped
		end
		return values
	end

	type Meta = {
		className: string?,
		properties: Values,
		attributes: Values,
		ignoresUnknown: boolean,
	}

	local function ReadMeta(path: { string }, metaPath: string, allowClassName: boolean): Meta?
		if filesByPath[metaPath] == nil then
			return { className = nil, properties = {}, attributes = {}, ignoresUnknown = false }
		end
		const meta = ReadDocument(path, metaPath)
		if meta == nil then
			return nil
		end
		const className = meta.className
		if className ~= nil and (not allowClassName or type(className) ~= "string") then
			Report(path, `{metaPath} sets className where {Config.NAME} cannot apply it`)
			return nil
		end
		const properties = ReadValues(path, metaPath, "property", meta.properties)
		const attributes = ReadValues(path, metaPath, "attribute", meta.attributes)
		if not properties or not attributes then
			return nil
		end
		return {
			className = className,
			properties = properties,
			attributes = attributes,
			ignoresUnknown = meta.ignoreUnknownInstances == true,
		}
	end

	type Details = {
		file: TreeFile?,
		blob: string?,
		source: string?,
		properties: Values,
		attributes: Values,
		studioOwned: boolean?,
	}

	local function Add(path: { string }, classes: { string }, className: string, details: Details): boolean
		const key = ProjectMap.Key(path)
		if mapping.byKey[key] then
			Report(path, "a project node and a file or folder beside it map to this name")
			return false
		end
		const entry: Entry = {
			path = path,
			classes = Extend(classes, className),
			key = ProjectMap.Key(path),
			className = className,
			file = if details.file then details.file.path else nil,
			blob = if details.source then Sha1.GitBlob(details.source) else details.blob,
			source = details.source,
			properties = details.properties,
			attributes = details.attributes,
			studioOwned = details.studioOwned,
		}
		table.insert(mapping.entries, entry)
		mapping.byKey[entry.key] = entry
		return true
	end

	local function HasUnsupportedValues(model: any): boolean
		if type(model) ~= "table" then
			return false
		end
		for _, field in { "properties", "attributes" } do
			const values = Field(model, field)
			if type(values) == "table" then
				for _, value in values do
					if not SUPPORTED_VALUE_TYPES[type(UnwrapValue(value))] then
						return true
					end
				end
			end
		end
		const children = Field(model, "children")
		if type(children) == "table" then
			for _, child in children do
				if HasUnsupportedValues(child) then
					return true
				end
			end
		end
		return false
	end

	local function AddModel(path: { string }, classes: { string }, file: TreeFile, model: any)
		if type(model) ~= "table" then
			Report(path, `{file.path} describes this instance with something other than an object`)
			return
		end
		const className = Field(model, "className")
		if type(className) ~= "string" then
			Report(path, `{file.path} gives this instance no className`)
			return
		end
		if HasUnsupportedValues(model) then
			Add(path, classes, className, { file = file, properties = {}, attributes = {}, studioOwned = true })
			return
		end
		const properties = ReadValues(path, file.path, "property", Field(model, "properties"))
		const attributes = ReadValues(path, file.path, "attribute", Field(model, "attributes"))
		if not properties or not attributes then
			return
		end
		if not Add(path, classes, className, { file = file, properties = properties, attributes = attributes }) then
			return
		end

		const children = Field(model, "children")
		if children == nil then
			return
		end
		if type(children) ~= "table" then
			Report(path, `{file.path} lists children as something other than a list`)
			return
		end
		const childClasses = Extend(classes, className)
		const byName: { [string]: { any } } = {}
		for _, child in children do
			const name = if type(child) == "table" then Field(child, "name") else nil
			if type(name) ~= "string" then
				Report(path, `{file.path} has a child with no name`)
				continue
			end
			byName[name] = byName[name] or {}
			table.insert(byName[name], child)
		end
		for _, name in SortedKeys(byName) do
			const childPath = Extend(path, name)
			if #byName[name] > 1 then
				Report(childPath, `{file.path} has more than one child with this name`)
				continue
			end
			AddModel(childPath, childClasses, file, byName[name][1])
		end
	end

	local function AddFile(path: { string }, classes: { string }, file: TreeFile, kind: FileKind, metaPath: string)
		if kind.kind == "Script" then
			const meta = ReadMeta(path, metaPath, false)
			if
				meta
				and Add(
					path,
					classes,
					kind.className,
					{ file = file, blob = file.sha, properties = meta.properties, attributes = meta.attributes }
				)
			then
				if not meta.ignoresUnknown then
					SetExclusive(path, Extend(classes, kind.className))
				end
			end
		elseif kind.kind == "JsonModule" then
			const text = documents[file.path]
			if text == nil then
				Report(path, `{file.path} could not be read`)
				return
			end
			const meta = ReadMeta(path, metaPath, false)
			if
				meta
				and Add(path, classes, "ModuleScript", {
					file = file,
					source = ProjectMap.JsonModuleSource(text),
					properties = meta.properties,
					attributes = meta.attributes,
				})
			then
				if not meta.ignoresUnknown then
					SetExclusive(path, Extend(classes, "ModuleScript"))
				end
			end
		elseif kind.kind == "Model" then
			const model = ReadDocument(path, file.path)
			if model ~= nil then
				AddModel(path, classes, file, model)
			end
		end
	end

	local MapDirectory: (directoryPath: string, instancePath: { string }, classes: { string }) -> ()

	local function MapSubdirectory(directoryPath: string, path: { string }, classes: { string }): string?
		const directory = directories[directoryPath]
		local initFile: TreeFile? = nil
		local initClass: ScriptClass? = nil
		if directory then
			for fileName, file in directory.files do
				const kind = ClassifyFile(fileName)
				if kind.kind == "Script" and kind.name == INIT_NAME then
					if initFile then
						Report(path, `{directoryPath} has more than one init script`)
						return nil
					end
					initFile = file
					initClass = kind.className
				end
			end
		end
		const meta = ReadMeta(path, `{directoryPath}/{INIT_NAME}{META_SUFFIX}`, initFile == nil)
		if not meta then
			return nil
		end
		const className = initClass or meta.className or "Folder"
		if
			not Add(path, classes, className, {
				file = initFile,
				blob = if initFile then initFile.sha else nil,
				properties = meta.properties,
				attributes = meta.attributes,
			})
		then
			return nil
		end
		if not meta.ignoresUnknown then
			SetExclusive(path, Extend(classes, className))
		end
		MapDirectory(directoryPath, path, Extend(classes, className))
		return className
	end

	MapDirectory = function(directoryPath: string, instancePath: { string }, classes: { string })
		const directory = directories[directoryPath]
		if not directory then
			return
		end

		const claimed: { [string]: string } = {}
		local function Claim(name: string, source: string): boolean
			if claimed[name] then
				Report(Extend(instancePath, name), `both {claimed[name]} and {source} map to this name`)
				claimed[name] = "conflict"
				return false
			end
			claimed[name] = source
			return true
		end

		const named: { [string]: { file: TreeFile, kind: FileKind } } = {}
		for _, fileName in SortedKeys(directory.files) do
			const file = directory.files[fileName]
			const kind = ClassifyFile(fileName)
			if kind.kind == "Meta" or kind.kind == "Ignored" then
				continue
			elseif kind.kind == "Unsupported" then
				Report(Extend(instancePath, fileName), `{file.path} is a file type {Config.NAME} leaves alone`)
				continue
			elseif kind.kind == "Script" and kind.name == INIT_NAME then
				continue
			end
			const name = (kind :: any).name :: string
			if Claim(name, file.path) then
				named[name] = { file = file, kind = kind }
			end
		end
		for _, name in SortedKeys(directory.directories) do
			Claim(name, `{directoryPath}/{name}/`)
		end

		for _, name in SortedKeys(claimed) do
			if claimed[name] == "conflict" then
				continue
			end
			const path = Extend(instancePath, name)
			const file = named[name]
			if file then
				AddFile(path, classes, file.file, file.kind, `{directoryPath}/{name}{META_SUFFIX}`)
			else
				MapSubdirectory(`{directoryPath}/{name}`, path, classes)
			end
		end
	end

	local function MapPath(nodePath: string, path: { string }, classes: { string }): string?
		if directories[nodePath] then
			return MapSubdirectory(nodePath, path, classes)
		end
		const file = filesByPath[nodePath]
		if not file then
			Report(path, `{nodePath} is not in git`)
			return nil
		end
		const fileName = string.match(nodePath, "([^/]+)$") or nodePath
		const kind = ClassifyFile(fileName)
		if kind.kind ~= "Script" and kind.kind ~= "JsonModule" and kind.kind ~= "Model" then
			Report(path, `{nodePath} is a file type {Config.NAME} leaves alone`)
			return nil
		end
		const before = #mapping.entries
		AddFile(path, classes, file, kind, `{Strip(nodePath, fileName)}{(kind :: any).name}{META_SUFFIX}`)
		return if #mapping.entries > before then mapping.entries[before + 1].className else nil
	end

	local function MapNode(node: any, instancePath: { string }, parentClasses: { string }, isService: boolean)
		const nodeClass = node["$className"]
		const nodePath = node["$path"]
		const ignoreUnknown = node["$ignoreUnknownInstances"]
		local classes: { string }
		if isService or type(nodeClass) == "string" then
			classes = Extend(parentClasses, if type(nodeClass) == "string" then nodeClass else "Folder")
			if type(nodePath) == "string" then
				MapDirectory(nodePath, instancePath, classes)
			end
			if ignoreUnknown == false or (ignoreUnknown == nil and type(nodePath) == "string") then
				SetExclusive(instancePath, classes)
			end
		elseif type(nodePath) == "string" then
			const className = MapPath(nodePath, instancePath, parentClasses)
			if not className then
				return
			end
			classes = Extend(parentClasses, className)
			if ignoreUnknown == true then
				ClearExclusive(instancePath)
			elseif ignoreUnknown == false then
				SetExclusive(instancePath, classes)
			end
		else
			Report(instancePath, `the project gives this node neither $className nor $path`)
			return
		end
		for _, key in SortedKeys(node) do
			const child = node[key]
			if string.sub(key, 1, 1) == "$" or type(child) ~= "table" then
				continue
			end
			MapNode(child, Extend(instancePath, key), classes, false)
		end
	end

	for _, serviceName in SortedKeys(project.tree) do
		const node = project.tree[serviceName]
		if string.sub(serviceName, 1, 1) == "$" or type(node) ~= "table" then
			continue
		end
		mapping.services[serviceName] = if type(node["$className"]) == "string" then node["$className"] else serviceName
		MapNode(node, { serviceName }, {}, true)
	end

	for _, key in exclusiveOrder do
		const container = exclusiveByKey[key]
		if container then
			table.insert(mapping.exclusiveContainers, container)
		end
	end
	return mapping
end

return ProjectMap
