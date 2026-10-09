#Requires -Version 5.1
<#
.SYNOPSIS
    Build the Studio Sync plugin, or install it into Studio's plugins folder.

.DESCRIPTION
    Builds the loader (studio-sync-loader/) with the engine (studio-sync/) at -Ref, and records
    which commit and trees it holds in BuildInfo, so the loader can tell when the engine on main
    is newer. The plugin holds no token: each person pastes one per GitHub account into it.

.PARAMETER Ref
    The commit to build from. Defaults to HEAD.

.PARAMETER OutFile
    Write the plugin file to this path. Without it, the plugin is installed into Studio's local
    plugins folder as StudioSync.rbxm.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/build-plugin.ps1

.EXAMPLE
    pwsh -File scripts/build-plugin.ps1 -Ref HEAD -OutFile StudioSync.rbxm
#>

[CmdletBinding()]
param(
	[string]$Ref = 'HEAD',
	[string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'

$PLUGIN_FILE = 'StudioSync.rbxm'
$PLUGIN_FOLDER = 'studio-sync'
$LOADER_FOLDER = 'studio-sync-loader'

function Ok($t) { Write-Host "    $t" -ForegroundColor Green }
function Fail($m) { Write-Host ""; Write-Host "    $m" -ForegroundColor Red; Write-Host ""; exit 1 }

function Invoke-Native {
	param([string]$Command, [string[]]$Arguments)
	$prev = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	$out = & $Command @Arguments 2>$null
	$script:NativeExit = $LASTEXITCODE
	$ErrorActionPreference = $prev
	return (($out -join "`n").Trim())
}

foreach ($tool in 'git', 'rojo') {
	if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Fail "$tool is not on PATH. Install the toolchain with 'rokit install'." }
}

if ($OutFile) {
	$OutFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).Path, $OutFile))
}

$repoRoot = Invoke-Native git @('rev-parse', '--show-toplevel')
if ($NativeExit -ne 0) { Fail "Not inside a git repository." }
Set-Location $repoRoot

$commit = Invoke-Native git @('rev-parse', "$Ref^{commit}")
if ($NativeExit -ne 0) { Fail "$Ref is not a commit." }
$engineTree = Invoke-Native git @('rev-parse', "${commit}:$PLUGIN_FOLDER")
if ($NativeExit -ne 0) { Fail "$Ref has no $PLUGIN_FOLDER folder." }
$loaderTree = Invoke-Native git @('rev-parse', "${commit}:$LOADER_FOLDER")
if ($NativeExit -ne 0) { Fail "$Ref has no $LOADER_FOLDER folder." }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("studio-sync-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
	$archive = Join-Path $work 'plugin.zip'
	Invoke-Native git @('archive', '--format=zip', "--output=$archive", $commit, $PLUGIN_FOLDER, $LOADER_FOLDER, 'default.project.json') | Out-Null
	if ($NativeExit -ne 0) { Fail "Could not export the plugin at $commit." }
	Expand-Archive -LiteralPath $archive -DestinationPath $work

	$utf8 = New-Object System.Text.UTF8Encoding($false)
	$builtAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
	[System.IO.File]::WriteAllText(
		(Join-Path (Join-Path $work $LOADER_FOLDER) 'BuildInfo.luau'),
		"return { commit = `"$commit`", engineTree = `"$engineTree`", loaderTree = `"$loaderTree`", builtAt = $builtAt }`n",
		$utf8
	)

	$project = Join-Path $work 'default.project.json'
	$prev = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	if ($OutFile) {
		& rojo build $project --output $OutFile
	}
	else {
		& rojo build $project --plugin $PLUGIN_FILE
	}
	$buildExit = $LASTEXITCODE
	$ErrorActionPreference = $prev
	if ($buildExit -ne 0) { Fail "rojo could not build the plugin." }
}
finally {
	Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$short = $commit.Substring(0, 7)
if ($OutFile) {
	Ok "Studio Sync $short built to $OutFile."
	exit 0
}

Ok "Studio Sync $short installed as $PLUGIN_FILE in Studio's plugins folder. Restart Studio to load it."
