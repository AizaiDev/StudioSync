--!strict

const CollectionService = game:GetService("CollectionService")

const ProjectMap = require(script.Parent.ProjectMap)
const SyncPlan = require(script.Parent.SyncPlan)
const World = require(script.Parent.World)

export type Result = {
	created: number,
	updated: number,
	replaced: number,
	deleted: number,
	changes: { string },
	kept: { SyncPlan.Kept },
	problems: { ProjectMap.Problem },
}

type Blobs = { [string]: string }

local function WriteProperties(instance: Instance, properties: { [string]: any })
	for name, value in properties do
		const ok, problem = pcall(function()
			-- any: meta.json names the property, so the index is only known at runtime
			(instance :: any)[name] = value
		end)
		if not ok then
			error(`could not set {name} on {instance:GetFullName()}: {problem}`, 0)
		end
	end
end

local function WriteAttributes(instance: Instance, attributes: { [string]: any })
	for name, value in attributes do
		instance:SetAttribute(name, value)
	end
end

local function ClearAttributes(instance: Instance, names: { string })
	for _, name in names do
		instance:SetAttribute(name, nil)
	end
end

local function WriteSource(instance: Instance, source: string)
	if instance:IsA("ModuleScript") then
		instance.Source = source
		return
	end
	if instance:IsA("Script") then
		instance.Source = source
	end
end

local function SourceFor(entry: ProjectMap.Entry, blobs: Blobs): string?
	if entry.source then
		return entry.source
	elseif entry.blob == nil then
		return nil
	end
	return assert(blobs[entry.blob], `missing contents for {entry.file}`)
end

local function Build(entry: ProjectMap.Entry, blobs: Blobs): Instance
	const instance = Instance.new(entry.className)
	instance.Name = entry.path[#entry.path]
	const source = SourceFor(entry, blobs)
	if source then
		WriteSource(instance, source)
	end
	WriteProperties(instance, entry.properties)
	WriteAttributes(instance, entry.attributes)
	return instance
end

const defaultInstances: { [string]: Instance } = {}

local function DefaultValue(className: string, name: string): (boolean, any)
	local template = defaultInstances[className]
	if not template then
		template = Instance.new(className)
		defaultInstances[className] = template
	end
	return pcall(function()
		-- any: meta.json names the property, so the index is only known at runtime
		return (template :: any)[name]
	end)
end

local function ResetProperties(instance: Instance, names: { string })
	const defaults = {}
	for _, name in names do
		const ok, value = DefaultValue(instance.ClassName, name)
		if ok then
			defaults[name] = value
		end
	end
	WriteProperties(instance, defaults)
end

local function Without(list: { string }): { string }
	return table.move(list, 1, #list - 1, 1, {})
end

local function Extended(list: { string }, item: string): { string }
	const extended = table.clone(list)
	table.insert(extended, item)
	return extended
end

const Apply = {}

function Apply.Run(plan: SyncPlan.Plan, world: World.World, blobs: Blobs): Result
	const result: Result =
		{ created = 0, updated = 0, replaced = 0, deleted = 0, changes = {}, kept = {}, problems = {} }

	local function Found(path: { string }, classes: { string }): Instance
		const resolved = world.Resolve(path, classes)
		if resolved.status ~= "Found" then
			error(`{ProjectMap.Key(path)} is {string.lower(resolved.status)} in Studio`, 0)
		end
		return resolved.instance
	end

	local function Note(symbol: string, entry: ProjectMap.Entry, detail: string)
		table.insert(result.changes, `{symbol} {entry.key} ({detail})`)
	end

	for _, op in plan.ops do
		const entry = op.entry
		if op.kind == "Create" then
			if world.Resolve(entry.path, entry.classes).status ~= "Missing" then
				error(`{entry.key} appeared in Studio during the sync, so it was rolled back to retry`, 0)
			end
			const parent = Found(Without(entry.path), Without(entry.classes))
			Build(entry, blobs).Parent = parent
			result.created += 1
			Note("+", entry, entry.className)
		elseif op.kind == "Update" then
			WriteSource(Found(entry.path, entry.classes), assert(SourceFor(entry, blobs)))
			result.updated += 1
			Note("~", entry, entry.file or entry.className)
		elseif op.kind == "SetProperties" then
			const instance = Found(entry.path, entry.classes)
			WriteProperties(instance, op.properties)
			ResetProperties(instance, op.reset)
			WriteAttributes(instance, op.attributes)
			ClearAttributes(instance, op.clear)
			Note("~", entry, `properties from {entry.file or "its meta.json"}`)
		elseif op.kind == "Replace" then
			const old = Found(entry.path, Extended(Without(entry.classes), op.fromClass))
			const parent = old.Parent
			const replacement = Build(entry, blobs)
			for name, value in old:GetAttributes() do
				if entry.attributes[name] == nil then
					replacement:SetAttribute(name, value)
				end
			end
			for _, tag in CollectionService:GetTags(old) do
				CollectionService:AddTag(replacement, tag)
			end
			for _, child in old:GetChildren() do
				child.Parent = replacement
			end
			old.Parent = nil
			replacement.Parent = parent
			result.replaced += 1
			Note("*", entry, `{op.fromClass} became {entry.className}`)
		elseif op.kind == "Delete" then
			const resolved = world.Resolve(entry.path, entry.classes)
			if resolved.status == "Ambiguous" then
				table.insert(result.problems, {
					path = entry.key,
					reason = `more than one {entry.className} has this name, so none of them was deleted`,
				})
				continue
			elseif resolved.status ~= "Found" then
				continue
			end
			if #resolved.instance:GetChildren() > 0 then
				table.insert(result.kept, { path = entry.path, classes = entry.classes })
				continue
			end
			resolved.instance.Parent = nil
			result.deleted += 1
			Note("-", entry, entry.className)
		end
	end

	return result
end

return Apply
