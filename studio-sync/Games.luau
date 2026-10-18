--!strict

const Config = require(script.Parent.Config)

const REPOSITORY_PATTERN = "^%w[%w%-]*/[%w%-%._]+$"
const WORD_PATTERN = "[%w]+"
const PREFIX_SUFFIX = "Sync"
const DEFAULT_BRANCH = "main"
const ATTRIBUTE_NAME_LIMIT = 100
const USER_ID_DIGITS = 12
const MAX_PREFIX_LENGTH = ATTRIBUTE_NAME_LIMIT - #"Status_" - USER_ID_DIGITS

export type Added =
	{
		ok: true,
		game: Config.Game,
		repositories: { string },
		isNew: boolean,
	}
	| { ok: false, problem: string }

export type Removed = { repositories: { string }, removed: Config.Game? }

const Games = {}

--- Whether text is a GitHub repository written as owner/repo.
function Games.IsRepository(text: string): boolean
	return string.match(text, REPOSITORY_PATTERN) ~= nil
end

--- The attribute prefix of a game added from the plugin: its repository's name in lower case with
--- each word capitalised and the separators dropped, then Sync, so owner/My-Game reads MyGameSync
--- however it was typed.
function Games.PrefixFor(repository: string): string
	const name = string.lower(string.match(repository, "[^/]+$") or repository)
	const words: { string } = {}
	for word in string.gmatch(name, WORD_PATTERN) do
		table.insert(words, string.upper(string.sub(word, 1, 1)) .. string.sub(word, 2))
	end
	return table.concat(words) .. PREFIX_SUFFIX
end

local function EncodeSeparator(separator: string): string
	return string.format("_%02x", string.byte(separator))
end

local function FromRepository(repository: string): Config.Game
	const canonical = string.lower(repository)
	return {
		name = string.match(repository, "[^/]+$") or repository,
		repository = canonical,
		branch = DEFAULT_BRANCH,
		attributePrefix = Games.PrefixFor(canonical),
		tokenSetting = Config.SETTINGS.tokenPrefix .. (string.gsub(canonical, "[^%w]", EncodeSeparator)),
	}
end

local function ProblemWith(repository: string): string?
	if not Games.IsRepository(repository) then
		return `{repository} is not a repository written as owner/repo`
	end
	const prefix = Games.PrefixFor(repository)
	if prefix == PREFIX_SUFFIX then
		return `{repository} has no letters or digits in its name`
	end
	if #prefix > MAX_PREFIX_LENGTH then
		return `{repository} has too long a name for Roblox attribute names`
	end
	return nil
end

local function SavedRepositories(saved: unknown): { string }
	const repositories: { string } = {}
	if type(saved) ~= "table" then
		return repositories
	end
	for _, repository in saved :: { unknown } do
		if type(repository) == "string" and ProblemWith(repository) == nil then
			table.insert(repositories, string.lower(repository))
		end
	end
	return repositories
end

local function FindByRepository(games: { Config.Game }, repository: string): Config.Game?
	const wanted = string.lower(repository)
	for _, gameInfo in games do
		if string.lower(gameInfo.repository) == wanted then
			return gameInfo
		end
	end
	return nil
end

--- The games this computer syncs: the built-in ones in Config.GAMES, then the repositories saved
--- in its plugin settings, skipping any that repeats a game or an attribute prefix already listed.
function Games.All(saved: unknown): { Config.Game }
	const games = table.clone(Config.GAMES)
	const prefixes: { [string]: boolean } = {}
	for _, gameInfo in games do
		prefixes[gameInfo.attributePrefix] = true
	end
	for _, repository in SavedRepositories(saved) do
		const gameInfo = FromRepository(repository)
		if not FindByRepository(games, repository) and not prefixes[gameInfo.attributePrefix] then
			prefixes[gameInfo.attributePrefix] = true
			table.insert(games, gameInfo)
		end
	end
	return games
end

--- The game for owner/repo and the saved repositories with it added. A game already listed comes
--- back with isNew false and the saved repositories as they were.
function Games.Add(saved: unknown, repository: string): Added
	const problem = ProblemWith(repository)
	if problem then
		return { ok = false, problem = problem }
	end
	const repositories = SavedRepositories(saved)
	const games = Games.All(repositories)
	const listed = FindByRepository(games, repository)
	if listed then
		return { ok = true, game = listed, repositories = repositories, isNew = false }
	end
	const gameInfo = FromRepository(repository)
	for _, other in games do
		if other.attributePrefix == gameInfo.attributePrefix then
			return {
				ok = false,
				problem = `{repository} would share the {gameInfo.attributePrefix} attributes with {other.repository}`,
			}
		end
	end
	const added = table.clone(repositories)
	table.insert(added, gameInfo.repository)
	return { ok = true, game = gameInfo, repositories = added, isNew = true }
end

--- The saved repositories without owner/repo, and the game that was removed, if it was saved.
function Games.Remove(saved: unknown, repository: string): Removed
	const wanted = string.lower(repository)
	const result: Removed = { repositories = {}, removed = nil }
	for _, savedRepository in SavedRepositories(saved) do
		if savedRepository == wanted then
			result.removed = FromRepository(savedRepository)
		else
			table.insert(result.repositories, savedRepository)
		end
	end
	return result
end

return Games
