--!strict

const RunService = game:GetService("RunService")

const BundledMain = require(script.Bundled.Main)
const Config = require(script.Bundled.Config)

const LOG_PREFIX = `[{Config.NAME}]`
const SHORT_SHA_LENGTH = 7
const HEALTH_GRACE_SECONDS = 90
const HEALTH_STRIKES_BEFORE_REJECT = 2

type Context = BundledMain.Context
type EngineCode = BundledMain.EngineCode
type Main = { Start: (Context) -> () -> () }

type BuildInfo = {
	commit: string,
	engineTree: string,
	loaderTree: string,
	builtAt: number,
}

type SavedEngine = {
	commit: string,
	tree: string,
	files: { [string]: string },
	savedAt: number,
}

type Running = {
	stop: () -> (),
	tree: string?,
	folder: Folder?,
	code: EngineCode?,
	healthy: boolean,
	previous: Running?,
}

if not RunService:IsEdit() then
	return
end

local function LoadBuildInfo(): BuildInfo?
	const module = script:FindFirstChild("BuildInfo")
	if module and module:IsA("ModuleScript") then
		-- any: BuildInfo exists only in a build made by scripts/build-plugin.ps1
		return (require :: any)(module)
	end
	return nil
end

const buildInfo: BuildInfo? = LoadBuildInfo()

local buttons: BundledMain.Buttons? = nil
local running: Running? = nil
local rejectedTree: string? = nil
const healthStrikes: { [string]: number } = {}

local function Short(sha: string): string
	return string.sub(sha, 1, SHORT_SHA_LENGTH)
end

local function Buttons(): BundledMain.Buttons
	if buttons then
		return buttons
	end
	const toolbar = plugin:CreateToolbar(Config.NAME)
	const created = {
		sync = toolbar:CreateButton("StudioSyncNow", "Sync green main into this place now", "", "Sync now"),
		auto = toolbar:CreateButton("StudioSyncAuto", "Sync green main automatically", "", "Auto-sync"),
		status = toolbar:CreateButton(
			"StudioSyncStatus",
			"Show this Studio's sync status in the viewport",
			"",
			"Status"
		),
	}
	created.sync.ClickableWhenViewportHidden = true
	created.auto.ClickableWhenViewportHidden = true
	created.status.ClickableWhenViewportHidden = true
	buttons = created
	return created
end

local function SavedEngineCode(): SavedEngine?
	const saved = plugin:GetSetting(Config.SETTINGS.engine)
	if
		type(saved) == "table"
		and type(saved.commit) == "string"
		and type(saved.tree) == "string"
		and type(saved.savedAt) == "number"
		and type(saved.files) == "table"
		and type(saved.files.Main) == "string"
	then
		return saved :: SavedEngine
	end
	return nil
end

local function SaveEngineCode(code: EngineCode)
	const saved: SavedEngine = {
		commit = code.commit,
		tree = code.tree,
		files = code.files,
		savedAt = os.time(),
	}
	const ok, problem = pcall(plugin.SetSetting, plugin, Config.SETTINGS.engine, saved)
	if not ok then
		warn(`{LOG_PREFIX} could not keep this version for the next launch: {problem}`)
	end
end

local function BuildEngine(code: EngineCode): Folder
	const folder = Instance.new("Folder")
	folder.Name = `Engine_{Short(code.commit)}`
	for name, source in code.files do
		const module = Instance.new("ModuleScript")
		module.Name = name
		module.Source = source
		module.Parent = folder
	end
	folder.Parent = script
	return folder
end

local Upgrade: (code: EngineCode, manual: boolean) -> ()

local function MarkHealthy(record: Running)
	if record.healthy or running ~= record then
		return
	end
	record.healthy = true
	if record.tree then
		healthStrikes[record.tree] = nil
	end
	if record.code then
		SaveEngineCode(record.code)
	end
	const previous = record.previous
	record.previous = nil
	if previous and previous.folder then
		previous.folder:Destroy()
	end
end

local function Launch(main: ModuleScript, record: Running, manual: boolean): boolean
	const ok, result = pcall(function()
		const engine = (require :: any)(main) :: Main
		return engine.Start({
			plugin = plugin,
			engineTree = record.tree,
			loaderTree = if buildInfo then buildInfo.loaderTree else nil,
			rejectedTree = rejectedTree,
			firstCycleManual = manual,
			Buttons = Buttons,
			Upgrade = Upgrade,
			Healthy = function()
				MarkHealthy(record)
			end,
		})
	end)
	if not ok then
		warn(`{LOG_PREFIX} could not start: {result}`)
		return false
	end
	record.stop = result
	running = record
	return true
end

local function StartBundled(manual: boolean)
	const tree = if buildInfo then buildInfo.engineTree else nil
	Launch(script.Bundled.Main, { stop = function() end, tree = tree, healthy = true }, manual)
end

local function StartDownloaded(code: EngineCode, healthy: boolean, manual: boolean): Running?
	const built, folder = pcall(BuildEngine, code)
	if not built then
		warn(`{LOG_PREFIX} could not build the {Config.NAME} from {Short(code.commit)}: {folder}`)
		return nil
	end
	const main = folder:FindFirstChild("Main")
	const record: Running = { stop = function() end, tree = code.tree, folder = folder, code = code, healthy = healthy }
	if main and main:IsA("ModuleScript") and Launch(main, record, manual) then
		return record
	end
	folder:Destroy()
	return nil
end

local function FallBack(previous: Running?, manual: boolean)
	if previous and previous.code and StartDownloaded(previous.code, true, manual) then
		return
	end
	StartBundled(manual)
end

local function CheckHealth(record: Running)
	if running ~= record or record.healthy then
		return
	end
	const commit = if record.code then Short(record.code.commit) else "main"
	const tree = record.tree
	const strikes = if tree then (healthStrikes[tree] or 0) + 1 else HEALTH_STRIKES_BEFORE_REJECT
	const retry = if strikes < HEALTH_STRIKES_BEFORE_REJECT then " and will try it again" else ""
	warn(
		`{LOG_PREFIX} the {Config.NAME} from {commit} never finished a check of main, so it went back to the previous version{retry}`
	)
	record.stop()
	running = nil
	if record.folder then
		record.folder:Destroy()
	end
	if tree then
		healthStrikes[tree] = strikes
	end
	if strikes >= HEALTH_STRIKES_BEFORE_REJECT then
		rejectedTree = tree
	end
	const previous = record.previous
	if previous and previous.folder then
		previous.folder:Destroy()
	end
	FallBack(previous, false)
end

Upgrade = function(code: EngineCode, manual: boolean)
	const previous = running
	if previous then
		previous.stop()
	end
	running = nil
	const record = StartDownloaded(code, false, manual)
	if record then
		record.previous = previous
		print(`{LOG_PREFIX} updated itself to main at {Short(code.commit)}`)
		task.delay(HEALTH_GRACE_SECONDS, CheckHealth, record)
		return
	end
	rejectedTree = code.tree
	if previous and previous.folder then
		previous.folder:Destroy()
	end
	FallBack(previous, manual)
end

const saved = SavedEngineCode()
if saved and (buildInfo == nil or (saved.savedAt > buildInfo.builtAt and saved.tree ~= buildInfo.engineTree)) then
	if StartDownloaded(saved, true, false) then
		return
	end
	rejectedTree = saved.tree
	plugin:SetSetting(Config.SETTINGS.engine, nil)
end
StartBundled(false)
