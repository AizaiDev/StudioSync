--!nocheck
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")

local engineDir = process.args[1]
assert(
	engineDir and #process.args >= 2,
	"usage: lune run <StudioSync>/scripts/check-game-parity <StudioSync>/studio-sync <project.json>..."
)
local modules = {}
local function load(name)
	local path = `{engineDir}/{name}.luau`
	local source = fs.readFile(path):gsub("%f[%a]const%s+", "local ")
	local module = luau.load(source, {
		debugName = path,
		environment = {
			script = { Parent = { Config = "Config", ProjectMap = "ProjectMap", Sha1 = "Sha1", SyncPlan = "SyncPlan" } },
			require = function(n)
				return assert(modules[n], n)
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
load("Config")
load("Sha1")
local ProjectMap = load("ProjectMap")

local function git(args)
	local r = process.exec("git", args)
	assert(r.ok, r.stderr)
	return r.stdout
end
local tracked = {}
for line in git({ "ls-files", "-s" }):gmatch("[^\n]+") do
	local sha, path = line:match("^%d+ (%x+) %d+\t(.+)$")
	if sha then
		table.insert(tracked, { path = path, sha = sha })
	end
end
local function Decode(t)
	return pcall(serde.decode, "json", t)
end
local function ScriptFile(p)
	return if p and p:match("%.luau?$") then p else ""
end
local function ContainerKeys(project)
	local keys = { [""] = true }
	local function Visit(node, path)
		if type(node["$className"]) == "string" then
			keys[table.concat(path, "/")] = true
		end
		for k, c in node do
			if k:sub(1, 1) ~= "$" and type(c) == "table" then
				local p = table.clone(path)
				table.insert(p, k)
				Visit(c, p)
			end
		end
	end
	Visit(project.tree, {})
	return keys
end
local mismatches = 0
for i = 2, #process.args do
	local projectFile = process.args[i]
	local project = serde.decode("json", fs.readFile(projectFile))
	local docs = {}
	for _, f in ProjectMap.DocumentPaths(project, tracked) do
		docs[f.path] = fs.readFile(f.path)
	end
	local mapping = ProjectMap.Build(project, tracked, docs, Decode)
	print(`== {projectFile}: {#mapping.entries} entries, {#mapping.problems} problems`)
	for _, p in mapping.problems do
		print("  problem: " .. p.path .. " - " .. p.reason)
	end
	local ours = {}
	local owned = {}
	for _, e in mapping.entries do
		ours[`{e.key}|{e.className}|{ScriptFile(e.file)}`] = true
		if e.studioOwned then
			table.insert(owned, e.key .. "/")
			print("  studio-owned: " .. e.key)
		end
	end
	local sm = process.exec("rojo", { "sourcemap", "--include-non-scripts", projectFile })
	if not sm.ok then
		print("  rojo failed: " .. sm.stderr)
		continue
	end
	local containers = ContainerKeys(project)
	local rojos = {}
	local function Walk(node, path)
		local key = table.concat(path, "/")
		local under = false
		for _, o in owned do
			if key:sub(1, #o) == o then
				under = true
			end
		end
		if not containers[key] and not under then
			local sf = ""
			for _, fp in node.filePaths or {} do
				if ScriptFile(fp) ~= "" then
					sf = fp
				end
			end
			rojos[`{key}|{node.className}|{sf}`] = true
		end
		for _, c in node.children or {} do
			local p = table.clone(path)
			table.insert(p, c.name)
			Walk(c, p)
		end
	end
	Walk(serde.decode("json", sm.stdout), {})
	local n = 0
	for k in rojos do
		if not ours[k] then
			n += 1
			if n <= 15 then
				print("  missing: " .. k)
			end
		end
	end
	mismatches += n + #mapping.problems
	print(`  missing total {n}`)
	n = 0
	for k in ours do
		if not rojos[k] then
			n += 1
			if n <= 15 then
				print("  extra: " .. k)
			end
		end
	end
	mismatches += n
	print(`  extra total {n}`)
end
if mismatches > 0 then
	process.exit(1)
end
