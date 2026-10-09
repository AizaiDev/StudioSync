--!strict
local fs = require("@lune/fs")
local process = require("@lune/process")

local specs = {}
for _, name in fs.readDir("tests") do
	if name:match("%.spec%.luau$") then
		table.insert(specs, name)
	end
end
table.sort(specs)

local failed = {}
for _, name in specs do
	local result = process.exec("lune", { "run", "tests/" .. name })
	print(`== {name}`)
	if result.stdout ~= "" then
		print(result.stdout)
	end
	if not result.ok then
		print(result.stderr)
		table.insert(failed, name)
	end
end

print(`{#specs - #failed}/{#specs} spec files passed`)
if #failed > 0 then
	print("FAILED: " .. table.concat(failed, ", "))
	process.exit(1)
end
