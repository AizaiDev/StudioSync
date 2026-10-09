--!strict

const HttpService = game:GetService("HttpService")

const Config = require(script.Parent.Config)
const GitHub = require(script.Parent.GitHub)

const PLACE_LIST_FILE = Config.PLACE_LIST_FILE

export type Entry = {
	label: string,
	project: string,
}

export type Parsed = {
	places: { [number]: Entry },
	problem: string?,
}

const Places = {}

--- Reads a game's studio-sync.json, already decoded: { places = { ["<placeId>"] = { label, project } } }.
--- Entries that are not a place id with a string label and project are skipped and named in problem.
function Places.Parse(document: unknown): Parsed
	const parsed: Parsed = { places = {}, problem = nil }
	if type(document) ~= "table" or type((document :: any).places) ~= "table" then
		parsed.problem = `{PLACE_LIST_FILE} has no places table`
		return parsed
	end
	const skipped: { string } = {}
	for key, value in (document :: any).places do
		const placeId = tonumber(key)
		if placeId and type(value) == "table" and type(value.label) == "string" and type(value.project) == "string" then
			parsed.places[placeId] = { label = value.label, project = value.project }
		else
			table.insert(skipped, tostring(key))
		end
	end
	if #skipped > 0 then
		table.sort(skipped)
		parsed.problem = `{PLACE_LIST_FILE} has entries without a label and project: {table.concat(skipped, ", ")}`
	end
	return parsed
end

--- Reads the place list on a game's branch head. A head with no studio-sync.json lists no places.
function Places.Read(client: GitHub.Client, branch: string): Parsed
	const tree = client:Tree(client:HeadSha(branch))
	for _, file in tree.files do
		if file.path == PLACE_LIST_FILE then
			const ok, document = pcall(HttpService.JSONDecode, HttpService, client:Blob(file.sha))
			if not ok then
				return { places = {}, problem = `{PLACE_LIST_FILE} is not valid JSON: {document}` }
			end
			return Places.Parse(document)
		end
	end
	return { places = {} }
end

return Places
