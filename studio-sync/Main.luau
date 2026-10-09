--!strict

const ChangeHistoryService = game:GetService("ChangeHistoryService")
const HttpService = game:GetService("HttpService")
const Players = game:GetService("Players")
const RunService = game:GetService("RunService")

const Apply = require(script.Parent.Apply)
const Config = require(script.Parent.Config)
const GitHub = require(script.Parent.GitHub)
const Overlay = require(script.Parent.Overlay)
const Places = require(script.Parent.Places)
const ProjectMap = require(script.Parent.ProjectMap)
const SyncPlan = require(script.Parent.SyncPlan)
const World = require(script.Parent.World)

const SHORT_SHA_LENGTH = 7
const LOG_PREFIX = `[{Config.NAME}]`
const UNDO_PREFIX = Config.NAME
const MAX_KEYS_IN_STATUS = 5
const PAUSED_TEXT = "Auto-sync is paused for everyone in this place. Press Sync now to sync and resume it."
const ENGINE_FILE_PATTERN = "^([%w_]+)%.luau$"
const STOPPED_TEXT = "Stopped, because another copy of the plugin took over"
const NO_TOKENS_TEXT =
	"No GitHub tokens yet. Paste your game's read-only token, which its owner sends you, in the box above the status pill."
const ADD_TOKEN_TEXT =
	"Paste a read-only GitHub token for another game, or a new one to replace a token GitHub refused."

--- status is nil on a loader installed before the status overlay existed.
export type Buttons = {
	sync: PluginToolbarButton,
	auto: PluginToolbarButton,
	status: PluginToolbarButton?,
	token: PluginToolbarButton?,
}

export type EngineCode = {
	commit: string,
	tree: string,
	files: { [string]: string },
}

--- What the loader in studio-sync-loader/ hands every engine it starts. engineTree and loaderTree are
--- the git tree SHAs of the running studio-sync/ and studio-sync-loader/. Upgrade swaps in new code,
--- carrying a Sync now press over as the new engine's first cycle (firstCycleManual). Healthy tells
--- the loader this engine finished a check of main, so it may be kept for the next launch.
export type Context = {
	plugin: Plugin,
	engineTree: string?,
	loaderTree: string?,
	rejectedTree: string?,
	firstCycleManual: boolean?,
	Buttons: () -> Buttons,
	Upgrade: (code: EngineCode, manual: boolean) -> (),
	Healthy: () -> (),
}

type Status = Overlay.Status

type EngineCheck = {
	upgrade: EngineCode?,
	settled: boolean,
	head: string?,
}

type EngineCheckResult = {
	upgrade: EngineCode?,
	broken: boolean,
}

local function Ok(text: string): Status
	return { tone = "Ok", text = text }
end

local function Working(text: string): Status
	return { tone = "Working", text = text }
end

local function Attention(text: string): Status
	return { tone = "Attention", text = text }
end

local function DecodeJson(text: string): (boolean, any)
	return pcall(HttpService.JSONDecode, HttpService, text)
end

local function Short(sha: string?): string
	return if sha then string.sub(sha, 1, SHORT_SHA_LENGTH) else "nothing yet"
end

local function Summary(result: Apply.Result, problemCount: number): string
	const parts = {}
	for _, tally in
		{
			{ count = result.created, label = "created" },
			{ count = result.updated, label = "updated" },
			{ count = result.replaced, label = "replaced" },
			{ count = result.deleted, label = "deleted" },
		}
	do
		if tally.count > 0 then
			table.insert(parts, `{tally.count} {tally.label}`)
		end
	end
	if problemCount > 0 then
		table.insert(parts, `{problemCount} left alone, see Output`)
	end
	return if #parts > 0 then table.concat(parts, ", ") else "already matched"
end

local function ListKeys(keys: { string }): string
	const shown = table.move(keys, 1, math.min(#keys, MAX_KEYS_IN_STATUS), 1, {})
	if #keys > #shown then
		table.insert(shown, `{#keys - #shown} more`)
	end
	return table.concat(shown, ", ")
end

const Main = {}

type Session = {
	Stop: () -> (),
	AskToken: (prompt: string, Submit: (token: string) -> string?) -> (),
	ReloadToken: () -> (),
}

local function StartSyncing(context: Context, place: Config.Place, client: GitHub.Client): Session
	const host = game:GetService(Config.ATTRIBUTE_HOST)
	const attributes = Config.AttributesFor(place.game)
	const repository = place.game.repository
	const branch = place.game.branch
	const owner = Config.OwnerOf(repository)
	const tokenSetting = Config.SETTINGS.tokenPrefix .. owner
	const noTokenText =
		`Error: no GitHub token for {owner}. Paste a read-only token that can read {repository} in the box above the status pill.`
	const refusedTokenText =
		`Error: GitHub refused the {owner} token. Paste a new one that can read {repository} in the box above the status pill.`
	const localPlayer = Players.LocalPlayer
	const studioId = if localPlayer then tostring(localPlayer.UserId) else "Local"
	const statusAttribute = attributes.statusPrefix .. studioId
	const seenAttribute = attributes.seenPrefix .. studioId

	const plugin = context.plugin
	const overlay = Overlay.New(place.label, function()
		const changes = host:GetAttribute(attributes.changes)
		return if type(changes) == "string" then changes else nil
	end)

	local function SetStatus(status: Status)
		overlay.Show(status)
		if host:GetAttribute(statusAttribute) == status.text then
			return
		end
		host:SetAttribute(statusAttribute, status.text)
		print(`{LOG_PREFIX} {place.label}: {status.text}`)
	end

	local stopped = false
	const connections: { RBXScriptConnection } = {}

	local function Stop()
		stopped = true
		for _, connection in connections do
			connection:Disconnect()
		end
		overlay.Destroy()
	end

	const buttons = context.Buttons()
	local showStatus = plugin:GetSetting(Config.SETTINGS.showStatus) ~= false
	overlay.SetVisible(showStatus)
	const statusButton = buttons.status
	if statusButton then
		statusButton:SetActive(showStatus)
		table.insert(
			connections,
			statusButton.Click:Connect(function()
				showStatus = not showStatus
				plugin:SetSetting(Config.SETTINGS.showStatus, showStatus)
				statusButton:SetActive(showStatus)
				overlay.SetVisible(showStatus)
			end)
		)
	end

	local function SavedToken(): string?
		const saved = plugin:GetSetting(tokenSetting)
		return if type(saved) == "string" and saved ~= "" then saved else nil
	end

	const pluginClient = GitHub.New(Config.REPOSITORY, client.token)
	local autoSync = plugin:GetSetting(Config.SETTINGS.autoSync) ~= false

	local function SetToken(token: string)
		client.token = token
		client.refused = false
		pluginClient.token = token
		pluginClient.refused = false
	end
	local busy = false
	local requestQueued = false
	local queuedManual = false
	local warnedLoaderOutdated = false
	local pendingUpgrade: EngineCode? = nil
	local engineCheckedAt: string? = nil
	local engineCheckFailed = false
	local unloadableTree: string? = nil
	local downloadFailedFor: string? = nil
	local lastSyncStatus: Status? = nil
	local lastSyncedHead: string? = nil
	local heldClaim: string? = nil
	local lastPlannedAt: number? = nil
	local lastWarnedProblems: string? = nil
	const listedFor: { [string]: string } = {}

	local function Heartbeat()
		host:SetAttribute(seenAttribute, if autoSync then os.time() else nil)
	end

	local function SyncedCommit(): string?
		const synced = host:GetAttribute(attributes.commit)
		return if type(synced) == "string" then synced else nil
	end

	local function DescribeCommit(sha: string): string
		const ok, title = pcall(client.CommitTitle, client, sha)
		return if ok then `{Short(sha)} {title}` else Short(sha)
	end

	overlay.SetHover(function(): string
		const synced = SyncedCommit()
		const lines = { if synced then `Synced: {DescribeCommit(synced)}` else "Nothing synced yet" }
		const ok, head = pcall(client.HeadSha, client, branch)
		if not ok then
			table.insert(lines, "main: could not reach GitHub")
		elseif head == synced then
			table.insert(lines, "This is the latest main")
		else
			table.insert(lines, `main: {DescribeCommit(head)}`)
		end
		return table.concat(lines, "\n")
	end)

	local function MappingFor(sha: string): (ProjectMap.Mapping, GitHub.Tree, string)
		const tree = client:Tree(sha)
		local projectBlob: string? = nil
		for _, file in tree.files do
			if file.path == place.project then
				projectBlob = file.sha
			end
		end
		if not projectBlob then
			error(`{place.project} is missing at {Short(sha)}`, 0)
		end
		const project = HttpService:JSONDecode(client:Blob(projectBlob))

		const documentFiles = ProjectMap.DocumentPaths(project, tree.files)
		const documentBlobs = {}
		for _, file in documentFiles do
			table.insert(documentBlobs, file.sha)
		end
		client:FetchBlobs(documentBlobs, Config.MAX_PARALLEL_FETCHES)
		const documents: ProjectMap.Documents = {}
		for _, file in documentFiles do
			documents[file.path] = client:Blob(file.sha)
		end
		return ProjectMap.Build(project, tree.files, documents, DecodeJson), tree, projectBlob
	end

	local function ForgetOldTrees(holder: GitHub.Client, keep: { string? })
		for sha in holder.trees do
			if not table.find(keep, sha) then
				holder.trees[sha] = nil
			end
		end
	end

	local function WarnIfLoaderOutdated(tree: GitHub.Tree)
		const mainLoaderTree = tree.directories[Config.LOADER_FOLDER]
		if warnedLoaderOutdated or not context.loaderTree or not mainLoaderTree then
			return
		end
		if mainLoaderTree ~= context.loaderTree then
			warnedLoaderOutdated = true
			warn(
				`{LOG_PREFIX} {Config.REPOSITORY} has a newer {Config.NAME} loader than this one. Reinstall the plugin as its README describes.`
			)
		end
	end

	local function EngineBlobs(tree: GitHub.Tree): ({ [string]: string }?, string?)
		const prefix = Config.PLUGIN_FOLDER .. "/"
		const blobs: { [string]: string } = {}
		for _, file in tree.files do
			if string.sub(file.path, 1, #prefix) == prefix then
				const name = string.match(string.sub(file.path, #prefix + 1), ENGINE_FILE_PATTERN)
				if not name then
					return nil, `{file.path} is not a module {Config.NAME} can update itself with`
				end
				blobs[name] = file.sha
			end
		end
		return blobs, nil
	end

	local function FetchEngine(head: string, engineTree: string, blobs: { [string]: string }): EngineCode
		const shas = {}
		for _, sha in blobs do
			table.insert(shas, sha)
		end
		pluginClient:FetchBlobs(shas, Config.MAX_PARALLEL_FETCHES)
		const files: { [string]: string } = {}
		for name, sha in blobs do
			files[name] = pluginClient:Blob(sha)
		end
		return { commit = head, tree = engineTree, files = files }
	end

	local function CheckEngine(): EngineCheck
		const head = pluginClient:HeadSha(Config.BRANCH)
		if head == engineCheckedAt then
			return { upgrade = nil, settled = true }
		end
		const checks = pluginClient:WorkflowRuns(head)
		if checks.total == 0 or #checks.failed > 0 or #checks.pending > 0 then
			return { upgrade = nil, settled = false }
		end
		const tree = pluginClient:Tree(head)
		ForgetOldTrees(pluginClient, { head })
		WarnIfLoaderOutdated(tree)
		const mainEngineTree = tree.directories[Config.PLUGIN_FOLDER]
		if
			mainEngineTree == nil
			or mainEngineTree == context.engineTree
			or mainEngineTree == context.rejectedTree
			or mainEngineTree == unloadableTree
		then
			return { upgrade = nil, settled = true, head = head }
		end
		const blobs, problem = EngineBlobs(tree)
		if not blobs then
			unloadableTree = mainEngineTree
			warn(
				`{LOG_PREFIX} staying on this version, because the one on {Config.REPOSITORY} at {Short(head)} cannot load: {problem}`
			)
			return { upgrade = nil, settled = true, head = head }
		end
		const ok, result = pcall(FetchEngine, head, mainEngineTree, blobs)
		if not ok then
			if downloadFailedFor ~= mainEngineTree then
				downloadFailedFor = mainEngineTree
				warn(`{LOG_PREFIX} could not download the {Config.NAME} at {Short(head)}; will retry: {result}`)
			end
			return { upgrade = nil, settled = false }
		end
		return { upgrade = result, settled = true, head = head }
	end

	local function CheckEngineQuietly(): EngineCheckResult
		const ok, check = pcall(CheckEngine)
		if not ok then
			if not GitHub.IsRequestError(check) then
				if not engineCheckFailed then
					engineCheckFailed = true
					warn(`{LOG_PREFIX} this version could not check {Config.REPOSITORY} for a newer one: {check}`)
				end
				return { upgrade = nil, broken = true }
			end
			if not engineCheckFailed then
				engineCheckFailed = true
				warn(`{LOG_PREFIX} could not check {Config.REPOSITORY} for a newer {Config.NAME}; will retry: {check}`)
			end
			return { upgrade = nil, broken = false }
		end
		engineCheckFailed = false
		if check.settled and check.head then
			engineCheckedAt = check.head
		end
		return { upgrade = check.upgrade, broken = false }
	end

	local function NewClaim(): string
		return `{studioId}|{HttpService:GenerateGUID(false)}|{os.time()}`
	end

	local function LockIsFree(): boolean
		const claim = host:GetAttribute(attributes.lock)
		if type(claim) ~= "string" then
			return true
		end
		const claimedAt = tonumber(string.match(claim, "|(%d+)$"))
		return claimedAt == nil or os.time() - claimedAt >= Config.LOCK_STALE_SECONDS
	end

	local function TakeLock(): boolean
		if not LockIsFree() then
			return false
		end
		const claim = NewClaim()
		host:SetAttribute(attributes.lock, claim)
		task.wait(Config.LOCK_CONFIRM_SECONDS)
		if host:GetAttribute(attributes.lock) ~= claim then
			return false
		end
		heldClaim = claim
		return true
	end

	local function RenewLock()
		if heldClaim == nil or host:GetAttribute(attributes.lock) ~= heldClaim then
			error("another Studio took over the sync", 0)
		end
		const claim = NewClaim()
		host:SetAttribute(attributes.lock, claim)
		heldClaim = claim
	end

	local function ReleaseLock()
		if heldClaim and host:GetAttribute(attributes.lock) == heldClaim then
			host:SetAttribute(attributes.lock, nil)
		end
		heldClaim = nil
	end

	local function ReportChanges(result: Apply.Result, head: string)
		if #result.changes > 0 then
			const shown = table.move(result.changes, 1, math.min(#result.changes, Config.MAX_LISTED_CHANGES), 1, {})
			if #result.changes > #shown then
				table.insert(shown, `... and {#result.changes - #shown} more`)
			end
			const list = table.concat(shown, "\n")
			host:SetAttribute(attributes.changes, list)
			print(`{LOG_PREFIX} {place.label} now matches main at {Short(head)}:\n{list}`)
		end
	end

	local function ListOnce(heading: string, keys: { string }, head: string)
		if #keys == 0 or listedFor[heading] == head then
			return
		end
		listedFor[heading] = head
		warn(`{LOG_PREFIX} {heading}:\n{table.concat(keys, "\n")}`)
	end

	local function StoredKept(): { SyncPlan.Kept }
		const text = host:GetAttribute(attributes.kept)
		if type(text) ~= "string" then
			return {}
		end
		const ok, decoded = DecodeJson(text)
		return if ok then SyncPlan.ReadKept(decoded) else {}
	end

	local function StoreKept(kept: { SyncPlan.Kept })
		const text = if #kept > 0 then HttpService:JSONEncode(kept) else nil
		if host:GetAttribute(attributes.kept) ~= text then
			host:SetAttribute(attributes.kept, text)
		end
	end

	type Outcome = {
		result: Apply.Result,
		keptProblems: { ProjectMap.Problem },
	}

	local function SettleKept(
		newlyKept: { SyncPlan.Kept },
		desired: ProjectMap.Mapping,
		world: World.World
	): { ProjectMap.Problem }
		const candidates = StoredKept()
		table.move(newlyKept, 1, #newlyKept, #candidates + 1, candidates)
		const remaining, problems = SyncPlan.StillKept(candidates, desired, world)
		StoreKept(remaining)
		return problems
	end

	type Previous = {
		mapping: ProjectMap.Mapping,
		projectBlob: string,
	}

	local function PreviousMapping(synced: string, head: string, current: Previous): Previous
		if synced == head then
			return current
		end
		const ok, mapping, _, projectBlob = pcall(MappingFor, synced)
		if not ok then
			error(`could not read the last synced commit {Short(synced)}, so this sync will retry: {mapping}`, 0)
		end
		return { mapping = mapping, projectBlob = projectBlob }
	end

	local function HoldReason(plan: SyncPlan.Plan, projectBlob: string, previous: Previous?): string?
		const reasons = {}
		if #plan.leftovers > 0 then
			table.insert(
				reasons,
				`this first sync found {#plan.leftovers} scripts that git does not have ({ListKeys(plan.leftovers)}), which it deletes`
			)
		end
		if #plan.twins > 0 then
			table.insert(
				reasons,
				`this first sync creates {#plan.twins} instances beside a same-named Studio instance of another class ({ListKeys(
					plan.twins
				)}), which may be Studio-only`
			)
		end
		if #plan.unrecorded > 0 then
			table.insert(
				reasons,
				`this first sync changes the class of {#plan.unrecorded} scripts or folders ({ListKeys(plan.unrecorded)}), which may be Studio-only`
			)
		end
		if #plan.retyped > 0 then
			table.insert(
				reasons,
				`git changed the class of {#plan.retyped} instances that Studio cannot convert ({ListKeys(plan.retyped)}), so each is replaced by a new one that takes its children`
			)
		end
		const deleted = if previous then plan.counts.deleted else 0
		if deleted > Config.MAX_AUTO_DELETES then
			table.insert(reasons, `it deletes {deleted} instances`)
		elseif deleted > 0 and previous and previous.projectBlob ~= projectBlob then
			table.insert(reasons, `it changes {place.project} and deletes {deleted} instances`)
		end
		return if #reasons > 0 then table.concat(reasons, "; ") else nil
	end

	local function SyncTo(head: string, manual: boolean): Status
		const synced = SyncedCommit()
		if not manual and host:GetAttribute(attributes.paused) == true then
			return Attention(PAUSED_TEXT)
		end
		const desired, _, projectBlob = MappingFor(head)
		const previous = if synced
			then PreviousMapping(synced, head, { mapping = desired, projectBlob = projectBlob })
			else nil
		ForgetOldTrees(client, { head, synced })

		const world = World.New(desired.services)
		const built = SyncPlan.Build(desired, if previous then previous.mapping else nil, world)
		const plan = if synced == head and not manual then SyncPlan.SourcesOnly(built) else built
		ListOnce("the first sync changes the class of", plan.unrecorded, head)
		ListOnce("the first sync creates these beside a same-named Studio instance", plan.twins, head)
		ListOnce("git changed the class of", plan.retyped, head)
		ListOnce("the first sync found these scripts that git does not have", plan.leftovers, head)
		const holdReason = if manual then nil else HoldReason(plan, projectBlob, previous)
		if holdReason then
			const since = if synced then ` since {Short(synced)}` else ""
			return Attention(
				`Holding main at {Short(head)}: {holdReason}{since}, and later commits wait behind it. Press Sync now in the {Config.NAME} toolbar to apply it.`
			)
		end

		local outcome: Outcome
		const applies = #plan.ops > 0 or synced ~= head
		if applies then
			const needed = {}
			for _, op in plan.ops do
				if
					(op.kind == "Create" or op.kind == "Update" or op.kind == "Replace")
					and op.entry.blob
					and not op.entry.source
				then
					table.insert(needed, op.entry.blob)
				end
			end
			for first = 1, #needed, Config.FETCH_BATCH_SIZE do
				Heartbeat()
				RenewLock()
				if #needed > Config.FETCH_BATCH_SIZE then
					SetStatus(Working(`Downloading {first - 1} of {#needed} files for {Short(head)}`))
				end
				const batch = table.move(needed, first, math.min(first + Config.FETCH_BATCH_SIZE - 1, #needed), 1, {})
				client:FetchBlobs(batch, Config.MAX_PARALLEL_FETCHES)
				if stopped then
					return Working(STOPPED_TEXT)
				end
			end
			Heartbeat()
			RenewLock()
			if stopped then
				return Working(STOPPED_TEXT)
			end

			const recording = ChangeHistoryService:TryBeginRecording(`{UNDO_PREFIX} {Short(head)}`)
			if not recording then
				return Working(`Studio is busy recording another change; will retry {Short(head)}`)
			end
			const ok, applied = pcall(function(): Outcome
				const result = Apply.Run(plan, world, client.blobs)
				return { result = result, keptProblems = SettleKept(result.kept, desired, world) }
			end)
			if not ok then
				ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
				error(`sync of {Short(head)} rolled back: {applied}`, 0)
			end
			outcome = applied
			host:SetAttribute(attributes.commit, head)
			host:SetAttribute(attributes.syncedAt, os.time())
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		else
			outcome = {
				result = {
					created = 0,
					updated = 0,
					replaced = 0,
					deleted = 0,
					changes = {},
					kept = {},
					problems = {},
				},
				keptProblems = SettleKept({}, desired, world),
			}
		end

		const result = outcome.result
		const problems = table.clone(plan.problems)
		table.move(result.problems, 1, #result.problems, #problems + 1, problems)
		table.move(outcome.keptProblems, 1, #outcome.keptProblems, #problems + 1, problems)
		ReportChanges(result, head)
		const problemLines = {}
		for _, problem in problems do
			table.insert(problemLines, `{LOG_PREFIX} left alone {problem.path}: {problem.reason}`)
		end
		const problemText = table.concat(problemLines, "\n")
		if #problems > 0 and (applies or problemText ~= lastWarnedProblems) then
			warn(problemText)
		end
		lastWarnedProblems = problemText
		const text = if applies
			then `Synced {Short(head)}: {Summary(result, #problems)}`
			elseif #problems > 0 then `Up to date with main at {Short(head)}: {Summary(result, #problems)}`
			else `Up to date with main at {Short(head)}`
		const status = if #problems > 0 then Attention(text) else Ok(text)
		lastSyncStatus = status
		lastSyncedHead = head
		return status
	end

	local function UpToDate(head: string): Status
		if lastSyncedHead == head and lastSyncStatus then
			return lastSyncStatus
		end
		return Ok(`Up to date with main at {Short(head)}`)
	end

	local function RunCycle(manual: boolean): Status
		if manual then
			if host:GetAttribute(attributes.paused) ~= nil then
				host:SetAttribute(attributes.paused, nil)
			end
		elseif host:GetAttribute(attributes.paused) == true then
			return Attention(PAUSED_TEXT)
		elseif not autoSync then
			return {
				tone = "Off",
				text = "Auto-sync is off on this computer. Press Sync now, or turn Auto-sync back on.",
			}
		end

		const head = client:HeadSha(branch)
		const engineCheckResult = CheckEngineQuietly()
		if not engineCheckResult.broken then
			context.Healthy()
		end
		pendingUpgrade = engineCheckResult.upgrade
		if pendingUpgrade then
			return Working(`Updating {Config.NAME} to {Short(pendingUpgrade.commit)}`)
		end
		const syncedSha = SyncedCommit()
		const plannedAt = lastPlannedAt
		const recheckDue = plannedAt == nil or os.clock() - plannedAt >= Config.RECHECK_SECONDS
		if not manual and head == syncedSha and not recheckDue then
			return UpToDate(head)
		end

		const checks = client:WorkflowRuns(head)
		if #checks.failed > 0 then
			return Attention(
				`CI failed on {Short(head)} ({table.concat(checks.failed, ", ")}); staying on {Short(syncedSha)}`
			)
		end
		if checks.total == 0 or #checks.pending > 0 then
			return Working(`Waiting for CI on {Short(head)}; staying on {Short(syncedSha)}`)
		end

		if stopped then
			return Working(STOPPED_TEXT)
		end
		if not TakeLock() then
			return Working("Another Studio in this place is syncing")
		end
		lastPlannedAt = os.clock()
		const ok, status = pcall(SyncTo, head, manual)
		ReleaseLock()
		if not ok then
			error(status, 0)
		end
		return status
	end

	local AskForToken: (prompt: string) -> ()
	local askedForAnotherToken = false

	local function Cycle(manual: boolean)
		if stopped then
			return
		end
		if busy then
			requestQueued = true
			queuedManual = queuedManual or manual
			return
		end
		if client.token == "" or client.refused then
			const saved = SavedToken()
			if saved and saved ~= client.token then
				SetToken(saved)
			end
		end
		if client.token == "" then
			AskForToken(noTokenText)
			return
		end
		busy = true
		Heartbeat()
		const tokenUsed = client.token
		const ok, status = pcall(RunCycle, manual)
		busy = false
		if stopped then
			return
		end
		if client.refused and client.token == tokenUsed then
			AskForToken(refusedTokenText)
		elseif ok then
			if not askedForAnotherToken then
				overlay.CloseTokenBox()
			end
			SetStatus(status)
		else
			SetStatus(Attention(`Error: {status}`))
		end
		Heartbeat()
		const upgrade = pendingUpgrade
		if upgrade and not stopped then
			pendingUpgrade = nil
			task.defer(context.Upgrade, upgrade, SyncedCommit() ~= nil and (manual or queuedManual))
			return
		end
		if requestQueued then
			const replayManual = queuedManual
			requestQueued = false
			queuedManual = false
			task.defer(Cycle, replayManual)
		end
	end

	local function CheckToken(candidate: string): string?
		const probe = GitHub.New(repository, candidate)
		const ok, problem = pcall(function()
			probe:WorkflowRuns(probe:HeadSha(branch))
		end)
		if not ok then
			return if probe.refused then "GitHub refused that token." else `That token did not work: {problem}`
		end
		plugin:SetSetting(tokenSetting, candidate)
		SetToken(candidate)
		task.spawn(Cycle, false)
		return nil
	end

	AskForToken = function(prompt: string)
		askedForAnotherToken = false
		SetStatus(Attention(prompt))
		overlay.AskToken(prompt, CheckToken)
	end

	buttons.auto:SetActive(autoSync)

	for _, connection in
		{
			buttons.sync.Click:Connect(function()
				task.spawn(Cycle, true)
			end),
			buttons.auto.Click:Connect(function()
				autoSync = not autoSync
				plugin:SetSetting(Config.SETTINGS.autoSync, autoSync)
				buttons.auto:SetActive(autoSync)
				task.spawn(Cycle, false)
			end),
			ChangeHistoryService.OnUndo:Connect(function(action: string)
				if string.sub(action, 1, #UNDO_PREFIX) == UNDO_PREFIX then
					host:SetAttribute(attributes.paused, true)
					SetStatus(
						Attention(
							`You undid {action}, so auto-sync is paused for everyone in this place. Press Sync now or Redo to resume.`
						)
					)
				end
			end),
			ChangeHistoryService.OnRedo:Connect(function(action: string)
				if string.sub(action, 1, #UNDO_PREFIX) == UNDO_PREFIX then
					host:SetAttribute(attributes.paused, nil)
					task.spawn(Cycle, false)
				end
			end),
			host:GetAttributeChangedSignal(attributes.request):Connect(function()
				task.spawn(Cycle, false)
			end),
		}
	do
		table.insert(connections, connection)
	end

	table.insert(
		connections,
		plugin.Unloading:Connect(function()
			Stop()
			pcall(ReleaseLock)
			pcall(host.SetAttribute, host, seenAttribute, nil)
			pcall(host.SetAttribute, host, statusAttribute, nil)
		end)
	)

	task.spawn(function()
		local manual = context.firstCycleManual == true
		while not stopped do
			Cycle(manual)
			manual = false
			task.wait(Config.POLL_SECONDS)
		end
	end)

	return {
		Stop = Stop,
		AskToken = function(prompt: string, Submit: (token: string) -> string?)
			askedForAnotherToken = true
			overlay.AskToken(prompt, Submit, function()
				askedForAnotherToken = false
			end)
		end,
		ReloadToken = function()
			askedForAnotherToken = false
			const saved = SavedToken()
			if saved and saved ~= client.token then
				SetToken(saved)
			end
			overlay.CloseTokenBox()
			task.spawn(Cycle, false)
		end,
	}
end

function Main.Start(context: Context): () -> ()
	if not RunService:IsEdit() then
		return function() end
	end

	const plugin = context.plugin
	const buttons = context.Buttons()
	const host = game:GetService(Config.ATTRIBUTE_HOST)
	local stopped = false
	local searching = false
	local searchAgain = false
	local session: Session? = nil
	local tokenOverlay: Overlay.Overlay? = nil
	const warned: { [string]: boolean } = {}

	local function WarnOnce(text: string)
		if not warned[text] then
			warned[text] = true
			warn(`{LOG_PREFIX} {text}`)
		end
	end

	local function SavedTokenFor(owner: string): string?
		const saved = plugin:GetSetting(Config.SETTINGS.tokenPrefix .. owner)
		return if type(saved) == "string" and saved ~= "" then saved else nil
	end

	local function CloseTokenOverlay()
		if tokenOverlay then
			tokenOverlay.Destroy()
			tokenOverlay = nil
		end
	end

	local FindPlace: () -> ()

	local function SaveAnyToken(candidate: string): string?
		local lastProblem = "it cannot read any game's repository"
		for _, gameInfo in Config.GAMES do
			const probe = GitHub.New(gameInfo.repository, candidate)
			const ok, problem = pcall(function()
				probe:WorkflowRuns(probe:HeadSha(gameInfo.branch))
			end)
			if ok then
				const owner = Config.OwnerOf(gameInfo.repository)
				plugin:SetSetting(Config.SETTINGS.tokenPrefix .. owner, candidate)
				print(`{LOG_PREFIX} saved the {owner} token`)
				const current = session
				if current then
					current.ReloadToken()
				else
					CloseTokenOverlay()
					task.spawn(FindPlace)
				end
				return nil
			elseif not probe.refused then
				lastProblem = tostring(problem)
			end
		end
		return `That token did not work: {lastProblem}. It needs Read on Contents, Actions and Metadata.`
	end

	local function AskForToken(prompt: string)
		const current = session
		if current then
			current.AskToken(prompt, SaveAnyToken)
			return
		end
		const shown = tokenOverlay or Overlay.New(Config.NAME, function()
			return nil
		end)
		tokenOverlay = shown
		shown.Show(Attention(prompt))
		shown.AskToken(prompt, SaveAnyToken, CloseTokenOverlay)
	end

	FindPlace = function()
		if stopped or session then
			return
		end
		if searching then
			searchAgain = true
			return
		end
		searching = true
		searchAgain = false
		local anyToken = false
		local unreachable = false
		local stampedWithoutToken: Config.Game? = nil
		for _, gameInfo in Config.GAMES do
			const owner = Config.OwnerOf(gameInfo.repository)
			const token = SavedTokenFor(owner)
			const stamped = type(host:GetAttribute(Config.AttributesFor(gameInfo).commit)) == "string"
			if not token then
				if stamped then
					stampedWithoutToken = gameInfo
				end
				continue
			end
			anyToken = true
			const client = GitHub.New(gameInfo.repository, token)
			const ok, parsed = pcall(Places.Read, client, gameInfo.branch)
			if stopped then
				searching = false
				return
			end
			if not ok then
				if client.refused then
					if stamped then
						stampedWithoutToken = gameInfo
					end
					WarnOnce(
						`GitHub refused the {owner} token, so {gameInfo.name} places cannot sync. Press Add token to replace it.`
					)
				else
					unreachable = true
					WarnOnce(`could not read the {gameInfo.name} place list; will retry: {parsed}`)
				end
				continue
			end
			if parsed.problem then
				WarnOnce(`{gameInfo.repository}: {parsed.problem}`)
			end
			const entry = parsed.places[game.PlaceId]
			if entry then
				searching = false
				CloseTokenOverlay()
				session =
					StartSyncing(context, { label = entry.label, project = entry.project, game = gameInfo }, client)
				return
			end
		end
		searching = false
		if stampedWithoutToken then
			const owner = Config.OwnerOf(stampedWithoutToken.repository)
			AskForToken(
				`This place syncs {stampedWithoutToken.name}. Paste the read-only {owner} token, which its owner sends you, in the box above the status pill.`
			)
		elseif not anyToken then
			AskForToken(NO_TOKENS_TEXT)
		end
		if searchAgain then
			task.spawn(FindPlace)
		elseif unreachable then
			task.delay(Config.POLL_SECONDS, FindPlace)
		end
	end

	const tokenButton = buttons.token
	const tokenConnection = if tokenButton
		then tokenButton.Click:Connect(function()
			AskForToken(ADD_TOKEN_TEXT)
		end)
		else nil

	task.spawn(FindPlace)

	return function()
		stopped = true
		if tokenConnection then
			tokenConnection:Disconnect()
		end
		CloseTokenOverlay()
		const current = session
		if current then
			current.Stop()
		end
	end
end

return Main
