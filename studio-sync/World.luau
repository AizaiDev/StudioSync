--!strict

const Sha1 = require(script.Parent.Sha1)
const SyncPlan = require(script.Parent.SyncPlan)

export type Resolved = { status: "Missing" } | { status: "Ambiguous" } | { status: "Found", instance: Instance }

type SourceHashes = {
	source: string,
	blobs: { string },
}

export type World = SyncPlan.World & {
	Resolve: (path: { string }, classes: { string }) -> Resolved,
}

const sourceHashes = setmetatable({} :: { [Instance]: SourceHashes }, { __mode = "k" })

const World = {}

function World.SourceOf(instance: Instance): string?
	if instance:IsA("ModuleScript") then
		return instance.Source
	elseif instance:IsA("Script") then
		return instance.Source
	end
	return nil
end

local function BlobsFor(instance: Instance): { string }
	const source = World.SourceOf(instance)
	if source == nil then
		return {}
	end
	const cached = sourceHashes[instance]
	if cached and cached.source == source then
		return cached.blobs
	end
	const blobs = { Sha1.GitBlob(source) }
	const normalized = string.gsub(source, "\r\n", "\n")
	if normalized ~= source then
		table.insert(blobs, Sha1.GitBlob(normalized))
	end
	sourceHashes[instance] = { source = source, blobs = blobs }
	return blobs
end

local function ReadProperty(instance: Instance, name: string): any
	const ok, value = pcall(function()
		-- any: meta.json names the property, so the index is only known at runtime
		return (instance :: any)[name]
	end)
	return if ok then value else nil
end

function World.New(services: { [string]: string }): World
	local function Resolve(path: { string }, classes: { string }): Resolved
		const serviceClass = services[path[1]]
		if not serviceClass then
			return { status = "Missing" }
		end
		const ok, service = pcall(game.GetService, game, serviceClass)
		if not ok or not service then
			return { status = "Missing" }
		end

		local current: Instance = service
		for depth = 2, #path do
			const candidates: { Instance } = {}
			const candidateClasses: { string } = {}
			for _, child in current:GetChildren() do
				if child.Name == path[depth] then
					table.insert(candidates, child)
					table.insert(candidateClasses, child.ClassName)
				end
			end
			const pick = SyncPlan.Pick(candidateClasses, classes[depth])
			if pick.status == "Missing" then
				return { status = "Missing" }
			elseif pick.status == "Ambiguous" then
				return { status = "Ambiguous" }
			end
			current = candidates[pick.index]
		end
		return { status = "Found", instance = current }
	end

	local function Lookup(
		path: { string },
		classes: { string },
		propertyNames: { string },
		attributeNames: { string }
	): SyncPlan.Lookup
		const resolved = Resolve(path, classes)
		if resolved.status == "Missing" then
			return { status = "Missing" }
		elseif resolved.status == "Ambiguous" then
			return { status = "Ambiguous" }
		end
		const instance = resolved.instance
		const properties = {}
		for _, name in propertyNames do
			properties[name] = ReadProperty(instance, name)
		end
		const attributes = {}
		for _, name in attributeNames do
			attributes[name] = instance:GetAttribute(name)
		end
		return {
			status = "Found",
			className = instance.ClassName,
			sourceBlobs = BlobsFor(instance),
			properties = properties,
			attributes = attributes,
		}
	end

	local function Children(path: { string }, classes: { string }): { SyncPlan.Child }?
		const resolved = Resolve(path, classes)
		if resolved.status ~= "Found" then
			return nil
		end
		const children: { SyncPlan.Child } = {}
		for _, child in resolved.instance:GetChildren() do
			table.insert(children, { name = child.Name, className = child.ClassName })
		end
		return children
	end

	return { Resolve = Resolve, Lookup = Lookup, Children = Children }
end

return World
