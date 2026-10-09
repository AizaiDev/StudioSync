--!strict

const Config = require(script.Parent.Config)
const ProjectMap = require(script.Parent.ProjectMap)

type Entry = ProjectMap.Entry
type Mapping = ProjectMap.Mapping
type Problem = ProjectMap.Problem

export type Lookup =
	{ status: "Missing" }
	| { status: "Ambiguous" }
	| {
		status: "Found",
		className: string,
		sourceBlobs: { string },
		properties: { [string]: any },
		attributes: { [string]: any },
	}

export type Child = {
	name: string,
	className: string,
}

--- Children returns nil unless exactly one instance matches the path and classes.
export type World = {
	Lookup: (path: { string }, classes: { string }, propertyNames: { string }, attributeNames: { string }) -> Lookup,
	Children: (path: { string }, classes: { string }) -> { Child }?,
}

--- An instance git removed that a sync kept because it still held other instances. Main stores the
--- list in a ServerStorage attribute, so every later sync reports it until it is gone.
export type Kept = {
	path: { string },
	classes: { string },
}

export type Pick = { status: "Missing" } | { status: "Ambiguous" } | { status: "Found", index: number }

export type Op =
	{ kind: "Create", entry: Entry }
	| { kind: "Update", entry: Entry }
	| { kind: "Replace", entry: Entry, fromClass: string }
	| {
		kind: "SetProperties",
		entry: Entry,
		properties: { [string]: any },
		reset: { string },
		attributes: { [string]: any },
		clear: { string },
	}
	| { kind: "Delete", entry: Entry }

--- Main holds a sync for a person while unrecorded, twins, retyped or leftovers is not empty; the
--- ops already carry what Sync now applies for each.
export type Plan = {
	ops: { Op },
	problems: { Problem },
	counts: { created: number, updated: number, replaced: number, deleted: number },
	unrecorded: { string },
	twins: { string },
	retyped: { string },
	leftovers: { string },
}

const SCRIPT_CLASSES = { ModuleScript = true, Script = true, LocalScript = true }
const FOLDER_CLASS = "Folder"

const SyncPlan = {}

function SyncPlan.IsScriptClass(className: string): boolean
	return SCRIPT_CLASSES[className] == true
end

function SyncPlan.IsReplaceable(className: string): boolean
	return className == FOLDER_CLASS or SyncPlan.IsScriptClass(className)
end

function SyncPlan.Pick(candidateClasses: { string }, wantedClass: string): Pick
	local exact: number? = nil
	local replaceable: number? = nil
	local replaceableCount = 0
	for index, className in candidateClasses do
		if className == wantedClass then
			if exact then
				return { status = "Ambiguous" }
			end
			exact = index
		elseif SyncPlan.IsReplaceable(className) and SyncPlan.IsReplaceable(wantedClass) then
			replaceable = index
			replaceableCount += 1
		end
	end
	if exact then
		return { status = "Found", index = exact }
	elseif replaceableCount > 1 then
		return { status = "Ambiguous" }
	elseif replaceable then
		return { status = "Found", index = replaceable }
	end
	return { status = "Missing" }
end

type Values = { [string]: any }

local function SortedNames(values: Values): { string }
	const names = {}
	for name in values do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

local function Changed(wanted: Values, current: Values): Values?
	local changed: Values? = nil
	for name, value in wanted do
		if current[name] ~= value then
			changed = changed or {}
			assert(changed)[name] = value
		end
	end
	return changed
end

local function Dropped(entry: Entry, previousEntry: Entry?, field: "properties" | "attributes"): { string }
	const dropped = {}
	if previousEntry and previousEntry.className == entry.className then
		for name in previousEntry[field] do
			if entry[field][name] == nil then
				table.insert(dropped, name)
			end
		end
	end
	table.sort(dropped)
	return dropped
end

local function IsAtOrUnder(key: string, ancestorKey: string): boolean
	return key == ancestorKey or string.sub(key, 1, #ancestorKey + 1) == ancestorKey .. "/"
end

local function AncestorKey(path: { string }, depth: number): string
	return ProjectMap.Key(table.move(path, 1, depth, 1, {}))
end

local function Without(list: { string }): { string }
	return table.move(list, 1, #list - 1, 1, {})
end

local function WithLast(classes: { string }, className: string): { string }
	const replaced = table.clone(classes)
	replaced[#replaced] = className
	return replaced
end

local function Extended(list: { string }, item: string): { string }
	const extended = table.clone(list)
	table.insert(extended, item)
	return extended
end

local function BareEntry(path: { string }, classes: { string }): Entry
	return {
		path = path,
		classes = classes,
		key = ProjectMap.Key(path),
		className = classes[#classes],
		properties = {},
		attributes = {},
	}
end

function SyncPlan.Build(desired: Mapping, previous: Mapping?, world: World): Plan
	const plan: Plan = {
		ops = {},
		problems = table.clone(desired.problems),
		counts = { created = 0, updated = 0, replaced = 0, deleted = 0 },
		unrecorded = {},
		twins = {},
		retyped = {},
		leftovers = {},
	}
	const blocked: { string } = {}
	for _, problem in desired.problems do
		table.insert(blocked, problem.path)
	end
	const retypedFrom: { [string]: string } = {}

	local function Block(entry: Entry, reason: string)
		table.insert(plan.problems, { path = entry.key, reason = reason })
		table.insert(blocked, entry.key)
	end

	local function IsBlocked(key: string): boolean
		for _, blockedKey in blocked do
			if IsAtOrUnder(key, blockedKey) then
				return true
			end
		end
		return false
	end

	local function ClassesBeforeRetype(path: { string }, classes: { string }): { string }
		local before = classes
		for depth = 2, #path - 1 do
			const oldClass = retypedFrom[AncestorKey(path, depth)]
			if oldClass then
				before = if before == classes then table.clone(classes) else before
				before[depth] = oldClass
			end
		end
		return before
	end

	local function ClassesAfterRetype(path: { string }, classes: { string }): { string }
		local after = classes
		for depth = 2, #path - 1 do
			const ancestorKey = AncestorKey(path, depth)
			if retypedFrom[ancestorKey] then
				after = if after == classes then table.clone(classes) else after
				after[depth] = desired.byKey[ancestorKey].className
			end
		end
		return after
	end

	const ambiguousReason =
		`more than one instance of this class has this name, so {Config.NAME} cannot tell which one git means`

	local function IsStudioOwned(path: { string }): boolean
		for depth = 1, #path do
			const owner = desired.byKey[AncestorKey(path, depth)]
			if owner and owner.studioOwned then
				return true
			end
		end
		return false
	end

	for _, entry in desired.entries do
		if IsBlocked(entry.key) then
			continue
		end
		const lookupClasses = ClassesBeforeRetype(entry.path, entry.classes)
		if entry.studioOwned then
			const owned = world.Lookup(entry.path, lookupClasses, {}, {})
			if owned.status == "Missing" then
				Block(
					entry,
					`Studio has no {entry.className} here, and {Config.NAME} cannot build {entry.file} because it sets values only Rojo can apply; make it in Studio`
				)
			elseif owned.status == "Ambiguous" then
				Block(entry, ambiguousReason)
			elseif owned.className ~= entry.className then
				Block(
					entry,
					`Studio has a {owned.className} with this name where {entry.file} describes a {entry.className}; fix it in Studio`
				)
			end
			continue
		end
		const lookup =
			world.Lookup(entry.path, lookupClasses, SortedNames(entry.properties), SortedNames(entry.attributes))
		if lookup.status == "Ambiguous" then
			Block(entry, ambiguousReason)
			continue
		end

		const previousEntry = if previous then previous.byKey[entry.key] else nil
		if lookup.status == "Missing" then
			const oldClass = if previousEntry and previousEntry.className ~= entry.className
				then previousEntry.className
				else nil
			const old = if oldClass then world.Lookup(entry.path, WithLast(lookupClasses, oldClass), {}, {}) else nil
			if old and old.status == "Ambiguous" then
				Block(entry, ambiguousReason)
				continue
			end
			if oldClass and old and old.status == "Found" and old.className == oldClass then
				retypedFrom[entry.key] = oldClass
				table.insert(plan.retyped, `{entry.key} ({oldClass} to {entry.className})`)
				table.insert(plan.ops, { kind = "Replace", entry = entry, fromClass = oldClass })
				plan.counts.replaced += 1
				continue
			end
			if not previous then
				const siblings: { Child } = world.Children(Without(entry.path), Without(lookupClasses)) or {}
				for _, sibling in siblings do
					if sibling.name == entry.path[#entry.path] then
						table.insert(plan.twins, `{entry.key} (Studio has a {sibling.className})`)
					end
				end
			end
			table.insert(plan.ops, { kind = "Create", entry = entry })
			plan.counts.created += 1
			continue
		end

		if lookup.className ~= entry.className then
			if not previous then
				table.insert(plan.unrecorded, entry.key)
			elseif not previousEntry or previousEntry.className ~= lookup.className then
				Block(
					entry,
					`Studio has a {lookup.className} with this name that git did not own, so it was left alone`
				)
				continue
			end
			const replace: Op = { kind = "Replace", entry = entry, fromClass = lookup.className :: string }
			table.insert(plan.ops, replace)
			plan.counts.replaced += 1
			continue
		end
		if entry.blob and not table.find(lookup.sourceBlobs, entry.blob) then
			table.insert(plan.ops, { kind = "Update", entry = entry })
			plan.counts.updated += 1
		end

		const changed = Changed(entry.properties, lookup.properties)
		const dropped = Dropped(entry, previousEntry, "properties")
		const changedAttributes = Changed(entry.attributes, lookup.attributes)
		const droppedAttributes = Dropped(entry, previousEntry, "attributes")
		if changed or #dropped > 0 or changedAttributes or #droppedAttributes > 0 then
			table.insert(plan.ops, {
				kind = "SetProperties",
				entry = entry,
				properties = changed or {},
				reset = dropped,
				attributes = changedAttributes or {},
				clear = droppedAttributes,
			})
		end
	end

	if previous then
		const removed = {}
		for _, entry in previous.entries do
			if
				not desired.byKey[entry.key]
				and not entry.studioOwned
				and not IsBlocked(entry.key)
				and not IsStudioOwned(entry.path)
			then
				table.insert(removed, entry)
			end
		end
		table.sort(removed, function(a, b)
			return #a.path > #b.path
		end)
		for _, entry in removed do
			const lookup = world.Lookup(entry.path, entry.classes, {}, {})
			if lookup.status ~= "Found" or lookup.className ~= entry.className then
				continue
			end
			const applyClasses = ClassesAfterRetype(entry.path, entry.classes)
			const target = if applyClasses == entry.classes then entry else BareEntry(entry.path, applyClasses)
			table.insert(plan.ops, { kind = "Delete", entry = target })
			plan.counts.deleted += 1
		end
	else
		const leftovers: { Entry } = {}
		const seen: { [string]: boolean } = {}
		local function Sweep(path: { string }, classes: { string })
			const children = world.Children(path, classes)
			if not children then
				return
			end
			for _, child in children do
				const childPath = Extended(path, child.name)
				const key = ProjectMap.Key(childPath)
				const isScript = SyncPlan.IsScriptClass(child.className)
				if desired.byKey[key] or IsBlocked(key) then
					continue
				elseif not isScript and child.className ~= FOLDER_CLASS then
					continue
				end
				const childClasses = Extended(classes, child.className)
				if isScript then
					table.insert(leftovers, BareEntry(childPath, childClasses))
				end
				const classKey = `{key}|{child.className}`
				if not seen[classKey] then
					seen[classKey] = true
					Sweep(childPath, childClasses)
				end
			end
		end
		for _, container in desired.exclusiveContainers do
			if not IsBlocked(ProjectMap.Key(container.path)) then
				Sweep(container.path, container.classes)
			end
		end
		table.sort(leftovers, function(a, b)
			return if #a.path == #b.path then a.key < b.key else #a.path > #b.path
		end)
		const planned: { [string]: boolean } = {}
		for _, entry in leftovers do
			table.insert(plan.leftovers, entry.key)
			const classKey = `{entry.key}|{entry.className}`
			if not planned[classKey] then
				planned[classKey] = true
				table.insert(plan.ops, { kind = "Delete", entry = entry })
				plan.counts.deleted += 1
			end
		end
	end

	return plan
end

--- The plan with only its script source updates, for a recheck of a place already at main's head.
function SyncPlan.SourcesOnly(plan: Plan): Plan
	const sources: Plan = {
		ops = {},
		problems = plan.problems,
		counts = { created = 0, updated = 0, replaced = 0, deleted = 0 },
		unrecorded = {},
		twins = {},
		retyped = {},
		leftovers = {},
	}
	for _, op in plan.ops do
		if op.kind == "Update" then
			table.insert(sources.ops, op)
			sources.counts.updated += 1
		end
	end
	return sources
end

--- The kept list read back from its attribute's decoded JSON, without anything malformed.
function SyncPlan.ReadKept(decoded: any): { Kept }
	const kept: { Kept } = {}
	if type(decoded) ~= "table" then
		return kept
	end
	for _, item in decoded do
		if type(item) ~= "table" or type(item.path) ~= "table" or type(item.classes) ~= "table" then
			continue
		end
		if #item.path == 0 or #item.path ~= #item.classes then
			continue
		end
		local valid = true
		for index = 1, #item.path do
			if type(item.path[index]) ~= "string" or type(item.classes[index]) ~= "string" then
				valid = false
			end
		end
		if valid then
			table.insert(kept, { path = item.path, classes = item.classes })
		end
	end
	return kept
end

--- The kept instances that are still in Studio and that git has not mapped again, each once, with
--- the problem every sync reports for it.
function SyncPlan.StillKept(kept: { Kept }, desired: Mapping, world: World): ({ Kept }, { Problem })
	const remaining: { Kept } = {}
	const problems: { Problem } = {}
	const seen: { [string]: boolean } = {}
	for _, item in kept do
		const key = ProjectMap.Key(item.path)
		if seen[key] or desired.byKey[key] then
			continue
		end
		const children = world.Children(item.path, item.classes)
		if not children then
			continue
		end
		seen[key] = true
		table.insert(remaining, item)
		const reason = if #children > 0
			then `git removed it, but it still holds {#children} instance(s), so it was kept`
			else "git removed it, and it was kept while it held other instances; it holds none now, so delete it by hand"
		table.insert(problems, { path = key, reason = reason })
	end
	return remaining, problems
end

return SyncPlan
