--!strict

const HttpService = game:GetService("HttpService")

const Config = require(script.Parent.Config)
const ProjectMap = require(script.Parent.ProjectMap)

const API_ROOT = "https://api.github.com"
const API_VERSION = "2022-11-28"
const ACCEPT_JSON = "application/vnd.github+json"
const ACCEPT_SHA = "application/vnd.github.sha"
const ACCEPT_RAW = "application/vnd.github.raw+json"
const MAX_ATTEMPTS = 3
const HTTP_BUDGET_ERROR = "Number of requests exceeded limit"
const HTTP_BUDGET_WAIT_SECONDS = 10
const MAX_HTTP_BUDGET_WAITS = 12
const RETRY_BASE_SECONDS = 2
const RUNS_PAGE_SIZE = 100
const HTTP_OK_FIRST = 200
const HTTP_OK_LAST = 299
const HTTP_NOT_MODIFIED = 304
const HTTP_UNAUTHORIZED = 401
const HTTP_FORBIDDEN = 403
const HTTP_NOT_FOUND = 404
const REFUSED_STATUSES = { [HTTP_UNAUTHORIZED] = true, [HTTP_FORBIDDEN] = true, [HTTP_NOT_FOUND] = true }
const HTTP_SERVER_ERROR_FIRST = 500
const REQUEST_ERROR_PREFIX = "GitHub "
const PASSING_CONCLUSIONS = { success = true, skipped = true, neutral = true }
const SUPERSEDED_CONCLUSION = "cancelled"

export type WorkflowRun = {
	id: number,
	name: string,
	status: string,
	conclusion: string?,
}

export type CheckSummary = {
	total: number,
	pending: { string },
	failed: { string },
}

export type Tree = {
	files: { ProjectMap.TreeFile },
	directories: { [string]: string },
}

type Response = {
	StatusCode: number,
	Body: string,
	Headers: { [string]: string },
}

export type Client = {
	repository: string,
	token: string,
	refused: boolean,
	headEtag: string?,
	headSha: string?,
	blobs: { [string]: string },
	trees: { [string]: Tree },
	commitTitles: { [string]: string },
	HeadSha: (self: Client, branch: string) -> string,
	WorkflowRuns: (self: Client, sha: string) -> CheckSummary,
	Tree: (self: Client, sha: string) -> Tree,
	Blob: (self: Client, sha: string) -> string,
	FetchBlobs: (self: Client, shas: { string }, maxParallel: number) -> (),
	CommitTitle: (self: Client, sha: string) -> string,
}

local function HeaderValue(response: Response, name: string): string?
	const wanted = string.lower(name)
	for headerName, value in response.Headers do
		if string.lower(headerName) == wanted then
			return value
		end
	end
	return nil
end

local function IsRateLimited(response: Response): boolean
	return HeaderValue(response, "X-RateLimit-Remaining") == "0" or HeaderValue(response, "Retry-After") ~= nil
end

local function Request(client: Client, path: string, accept: string, extraHeaders: { [string]: string }?): Response
	const token = client.token
	const headers = {
		Authorization = `Bearer {token}`,
		Accept = accept,
		["X-GitHub-Api-Version"] = API_VERSION,
	}
	if extraHeaders then
		for name, value in extraHeaders do
			headers[name] = value
		end
	end

	local lastError = `{REQUEST_ERROR_PREFIX}request for {path} made no attempt`
	local budgetWaits = 0
	local attempt = 0
	while attempt < MAX_ATTEMPTS do
		attempt += 1
		const ok, response = pcall(HttpService.RequestAsync, HttpService, {
			Url = API_ROOT .. path,
			Method = "GET",
			Headers = headers,
		})
		if
			not ok
			and string.find(tostring(response), HTTP_BUDGET_ERROR, 1, true)
			and budgetWaits < MAX_HTTP_BUDGET_WAITS
		then
			budgetWaits += 1
			attempt -= 1
			task.wait(HTTP_BUDGET_WAIT_SECONDS)
			continue
		end
		if ok then
			const status = response.StatusCode
			if (status >= HTTP_OK_FIRST and status <= HTTP_OK_LAST) or status == HTTP_NOT_MODIFIED then
				if client.token == token then
					client.refused = false
				end
				return response
			end
			if REFUSED_STATUSES[status] and not (status == HTTP_FORBIDDEN and IsRateLimited(response)) then
				if client.token == token then
					client.refused = true
				end
				error(`{REQUEST_ERROR_PREFIX}refused the token ({status} for {path})`, 0)
			end
			lastError = `{REQUEST_ERROR_PREFIX}answered {status} for {path}`
			if status < HTTP_SERVER_ERROR_FIRST then
				break
			end
		else
			lastError = `{REQUEST_ERROR_PREFIX}request for {path} failed: {response}`
		end
		if attempt < MAX_ATTEMPTS then
			task.wait(RETRY_BASE_SECONDS * attempt)
		end
	end
	error(lastError, 0)
end

local function DecodeBody(response: Response): any
	const ok, body = pcall(HttpService.JSONDecode, HttpService, response.Body)
	if not ok then
		error(`{REQUEST_ERROR_PREFIX}sent a body that is not JSON: {body}`, 0)
	end
	return body
end

const GitHub = {}

--- Whether an error raised through a Client came from GitHub or the network rather than from code.
function GitHub.IsRequestError(problem: unknown): boolean
	return type(problem) == "string" and string.sub(problem, 1, #REQUEST_ERROR_PREFIX) == REQUEST_ERROR_PREFIX
end

function GitHub.HeadSha(self: Client, branch: string): string
	const response = Request(
		self,
		`/repos/{self.repository}/commits/{branch}`,
		ACCEPT_SHA,
		if self.headEtag then { ["If-None-Match"] = self.headEtag } else nil
	)
	if response.StatusCode == HTTP_NOT_MODIFIED and self.headSha then
		return self.headSha
	end
	const sha = string.match(response.Body, "^%s*(%x+)%s*$")
	if not sha then
		error(`{REQUEST_ERROR_PREFIX}did not return a commit for {branch}`, 0)
	end
	self.headSha = sha
	self.headEtag = HeaderValue(response, "ETag")
	return sha
end

--- Judges a commit by the newest run of each CI workflow on it, so a cancelled or failed run that a
--- later run on the same commit replaced no longer counts.
function GitHub.Summarize(runs: { WorkflowRun }): CheckSummary
	const latest: { [string]: WorkflowRun } = {}
	for _, run in runs do
		if run.name ~= Config.CI_WORKFLOW then
			continue
		end
		const newest = latest[run.name]
		if newest == nil or run.id > newest.id then
			latest[run.name] = run
		end
	end
	const summary: CheckSummary = { total = 0, pending = {}, failed = {} }
	for name, run in latest do
		summary.total += 1
		if run.status ~= "completed" or run.conclusion == SUPERSEDED_CONCLUSION then
			table.insert(summary.pending, name)
		elseif not PASSING_CONCLUSIONS[run.conclusion or ""] then
			table.insert(summary.failed, `{name} ({run.conclusion})`)
		end
	end
	return summary
end

function GitHub.WorkflowRuns(self: Client, sha: string): CheckSummary
	const runs: { WorkflowRun } = {}
	local page = 1
	local seen = 0
	while true do
		const response = Request(
			self,
			`/repos/{self.repository}/actions/runs?head_sha={sha}&per_page={RUNS_PAGE_SIZE}&page={page}`,
			ACCEPT_JSON
		)
		const body = DecodeBody(response)
		for _, run in body.workflow_runs do
			seen += 1
			table.insert(runs, { id = run.id, name = run.name, status = run.status, conclusion = run.conclusion })
		end
		if seen >= body.total_count or #body.workflow_runs == 0 then
			return GitHub.Summarize(runs)
		end
		page += 1
	end
end

function GitHub.Tree(self: Client, sha: string): Tree
	const cached = self.trees[sha]
	if cached then
		return cached
	end
	const response = Request(self, `/repos/{self.repository}/git/trees/{sha}?recursive=1`, ACCEPT_JSON)
	const body = DecodeBody(response)
	if body.truncated then
		error(`{REQUEST_ERROR_PREFIX}truncated the file list for {sha}`, 0)
	end
	const tree: Tree = { files = {}, directories = {} }
	for _, item in body.tree do
		if item.type == "blob" then
			table.insert(tree.files, { path = item.path, sha = item.sha })
		elseif item.type == "tree" then
			tree.directories[item.path] = item.sha
		end
	end
	self.trees[sha] = tree
	return tree
end

function GitHub.Blob(self: Client, sha: string): string
	const cached = self.blobs[sha]
	if cached then
		return cached
	end
	const response = Request(self, `/repos/{self.repository}/git/blobs/{sha}`, ACCEPT_RAW)
	self.blobs[sha] = response.Body
	return response.Body
end

function GitHub.CommitTitle(self: Client, sha: string): string
	const cached = self.commitTitles[sha]
	if cached then
		return cached
	end
	const response = Request(self, `/repos/{self.repository}/git/commits/{sha}`, ACCEPT_JSON)
	const body = DecodeBody(response)
	const title = string.split(body.message, "\n")[1]
	self.commitTitles[sha] = title
	return title
end

function GitHub.FetchBlobs(self: Client, shas: { string }, maxParallel: number)
	const queue = {}
	for _, sha in shas do
		if not self.blobs[sha] and not table.find(queue, sha) then
			table.insert(queue, sha)
		end
	end
	if #queue == 0 then
		return
	end

	local nextIndex = 1
	local running = 0
	local failure: string? = nil
	const finished = Instance.new("BindableEvent")

	local function Worker()
		while failure == nil and nextIndex <= #queue do
			const sha = queue[nextIndex]
			nextIndex += 1
			const ok, problem = pcall(GitHub.Blob, self, sha)
			if not ok then
				failure = tostring(problem)
			end
		end
		running -= 1
		if running == 0 then
			finished:Fire()
		end
	end

	running = math.min(maxParallel, #queue)
	for _ = 1, running do
		task.spawn(Worker)
	end
	if running > 0 then
		finished.Event:Wait()
	end
	finished:Destroy()
	if failure then
		error(failure, 0)
	end
end

function GitHub.New(repository: string, token: string): Client
	return {
		repository = repository,
		token = token,
		refused = false,
		headEtag = nil,
		headSha = nil,
		blobs = {},
		trees = {},
		commitTitles = {},
		HeadSha = GitHub.HeadSha,
		WorkflowRuns = GitHub.WorkflowRuns,
		Tree = GitHub.Tree,
		Blob = GitHub.Blob,
		FetchBlobs = GitHub.FetchBlobs,
		CommitTitle = GitHub.CommitTitle,
	}
end

return GitHub
