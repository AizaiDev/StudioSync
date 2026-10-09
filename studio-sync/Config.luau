--!strict

--- attributePrefix names the ServerStorage attributes each game's agents read, such as
--- CloudSeekersSyncCommit, so it stays what that game's CLAUDE.md documents.
export type Game = {
	name: string,
	repository: string,
	branch: string,
	attributePrefix: string,
}

export type Place = {
	label: string,
	project: string,
	game: Game,
}

export type Attributes = {
	commit: string,
	syncedAt: string,
	request: string,
	paused: string,
	changes: string,
	kept: string,
	lock: string,
	statusPrefix: string,
	seenPrefix: string,
}

const CLOUD_SEEKERS: Game = {
	name = "CloudSeekers",
	repository = "AizaiDev/CloudSeekers",
	branch = "main",
	attributePrefix = "CloudSeekersSync",
}

const FLOODED: Game = {
	name = "Flooded",
	repository = "ExZeret/Flooded",
	branch = "main",
	attributePrefix = "FloodedSync",
}

const EMBLEM_TALES: Game = {
	name = "Emblem Tales",
	repository = "EmblemTales/main",
	branch = "main",
	attributePrefix = "EmblemTalesSync",
}

local function AttributesFor(game: Game): Attributes
	const prefix = game.attributePrefix
	return {
		commit = `{prefix}Commit`,
		syncedAt = `{prefix}At`,
		request = `{prefix}Request`,
		paused = `{prefix}Paused`,
		changes = `{prefix}Changes`,
		kept = `{prefix}Kept`,
		lock = `{prefix}Lock`,
		statusPrefix = `{prefix}Status_`,
		seenPrefix = `{prefix}Seen_`,
	}
end

local function OwnerOf(repository: string): string
	return string.match(repository, "^[^/]+") or repository
end

return {
	NAME = "Studio Sync",
	REPOSITORY = "AizaiDev/StudioSync",
	BRANCH = "main",
	CI_WORKFLOW = "ci",
	SETTINGS = {
		tokenPrefix = "StudioSync_Token_",
		autoSync = "StudioSync_AutoSync",
		showStatus = "StudioSync_ShowStatus",
		engine = "StudioSync_EngineCode",
	},
	PLUGIN_FOLDER = "studio-sync",
	LOADER_FOLDER = "studio-sync-loader",
	PLACE_LIST_FILE = "studio-sync.json",
	GAMES = { CLOUD_SEEKERS, FLOODED, EMBLEM_TALES },
	AttributesFor = AttributesFor,
	OwnerOf = OwnerOf,
	POLL_SECONDS = 20,
	RECHECK_SECONDS = 300,
	MAX_AUTO_DELETES = 20,
	MAX_PARALLEL_FETCHES = 6,
	FETCH_BATCH_SIZE = 200,
	MAX_LISTED_CHANGES = 60,
	LOCK_CONFIRM_SECONDS = 3,
	LOCK_STALE_SECONDS = 120,
	ATTRIBUTE_HOST = "ServerStorage",
}
