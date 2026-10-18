--!strict

const Config = require(script.Parent.Config)

const REPOSITORY_PATTERN = "^[%w%-]+/[%w%-%._]+$"
const WORD_PATTERN = "[%w]+"
const PREFIX_SUFFIX = "Sync"
const DEFAULT_BRANCH = "main"

export type Added = { ok: true, repositories: { string }, game: Config.Game } | { ok: false, problem: string }

const Games = {}

--- Whether text is a GitHub repository written as owner/repo. No GitHub token contains a slash.
function Games.IsRepository(text: string): boolean
	return string.match(text, REPOSITORY_PATTERN) ~= nil
end

--- The attribute prefix of a game added from the plugin: its repository's name with each word
--- capitalised and the separators dropped, then Sync, so owner/my-game reads MyGameSync.
function Games.PrefixFor(repository: string): string
	const name = string.match(repository, "[^/]+$") or repository
	const words: { string } = {}
	for word in string.gmatch(name, WORD_PATTERN) do
		table.insert(words, string.upper(string.sub(word, 1, 1)) .. string.sub(word, 2))
	end
	return table.concat(words) .. PREFIX_SUFFIX
end

local function FromRepository(repository: string): Config.Game
	return {
		name = string.match(repository, "[^/]+$") or repository,
		repository = repository,
		branch = DEFAULT_BRANCH,
		attributePrefix = Games.PrefixFor(repository),
	}
end

local function SavedRepositories(saved: unknown): { string }
	const repositories: { string } = {}
	if type(saved) ~= "table" then
		return repositories
	end
	for _, repository in saved :: { unknown } do
		if type(repository) == "string" and Games.IsRepository(repository) then
			table.insert(repositories, repository)
		end
	end
	return repositories
end

local function Find(games: { Config.Game }, repository: string): Config.Game?
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
		if not Find(games, repository) and not prefixes[gameInfo.attributePrefix] then
			prefixes[gameInfo.attributePrefix] = true
			table.insert(games, gameInfo)
		end
	end
	return games
end

--- Adds owner/repo to the saved repositories. A game already listed is returned as it is, with the
--- saved list unchanged.
function Games.Add(saved: unknown, repository: string): Added
	if not Games.IsRepository(repository) then
		return { ok = false, problem = `{repository} is not a repository written as owner/repo` }
	end
	const repositories = SavedRepositories(saved)
	const games = Games.All(repositories)
	const listed = Find(games, repository)
	if listed then
		return { ok = true, repositories = repositories, game = listed }
	end
	const gameInfo = FromRepository(repository)
	if gameInfo.attributePrefix == PREFIX_SUFFIX then
		return { ok = false, problem = `{repository} has no letters or digits in its name` }
	end
	for _, other in games do
		if other.attributePrefix == gameInfo.attributePrefix then
			return {
				ok = false,
				problem = `{repository} would share the {gameInfo.attributePrefix} attributes with {other.repository}`,
			}
		end
	end
	table.insert(repositories, repository)
	return { ok = true, repositories = repositories, game = gameInfo }
end

return Games
