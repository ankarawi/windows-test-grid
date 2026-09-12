param(
    [Parameter(Mandatory=$true)][string]$InputDirectory,
    [Parameter(Mandatory=$true)][string]$OutputFile,
    [Parameter(Mandatory=$true)][string]$SessionKey
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $InputDirectory -PathType Container)) {
    throw 'INPUT_DIRECTORY_NOT_FOUND'
}
if ([string]::IsNullOrWhiteSpace($SessionKey) -or $SessionKey.Length -lt 32) {
    throw 'SESSION_KEY_TOO_SHORT'
}

$expert = Join-Path $InputDirectory 'worker.ex5'
$config = Join-Path $InputDirectory 'tester.ini'
$setFile = Join-Path $InputDirectory 'worker.set'

if (-not (Test-Path -LiteralPath $expert -PathType Leaf)) { throw 'EXPERT_MISSING' }
if (-not (Test-Path -LiteralPath $config -PathType Leaf)) { throw 'CONFIG_MISSING' }

$files = @(Get-ChildItem -LiteralPath $InputDirectory -File -Recurse -Force)
$allowedNames = @('worker.ex5','tester.ini','worker.set','servers.dat')
foreach ($file in $files) {
    if ($file.DirectoryName -ne (Resolve-Path -LiteralPath $InputDirectory).Path) { throw 'NESTED_PAYLOAD_NOT_ALLOWED' }
    if ($allowedNames -notcontains $file.Name) { throw 'PAYLOAD_FILE_NOT_ALLOWED' }
}

$cfg = Get-Content -LiteralPath $config -Raw
if ($cfg -match '(?im)^\s*AllowDllImport\s*=\s*1\s*$') { throw 'DLL_NOT_ALLOWED' }
if ($cfg -match '(?im)^\s*Script\s*=') { throw 'SCRIPT_NOT_ALLOWED' }
if ($cfg -notmatch '(?im)^\s*Expert\s*=\s*worker(?:\.ex5)?\s*$') { throw 'EXPERT_NAME_INVALID' }
if ($cfg -notmatch '(?im)^\s*Optimization\s*=\s*0\s*$') { throw 'POC_REQUIRES_SINGLE_TEST' }
if ($cfg -notmatch '(?im)^\s*Report\s*=\s*report\s*$') { throw 'REPORT_NAME_INVALID' }
if ($cfg -notmatch '(?im)^\s*ReplaceReport\s*=\s*1\s*$') { throw 'REPLACE_REPORT_REQUIRED' }
if ($cfg -notmatch '(?im)^\s*ShutdownTerminal\s*=\s*1\s*$') { throw 'SHUTDOWN_REQUIRED' }

$hasSet = Test-Path -LiteralPath $setFile -PathType Leaf
$declaresSet = $cfg -match '(?im)^\s*ExpertParameters\s*=\s*worker\.set\s*$'
if ($hasSet -ne $declaresSet) { throw 'SET_CONTRACT_MISMATCH' }

$sevenZip = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
if (-not (Test-Path -LiteralPath $sevenZip)) {
    $cmd = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { throw 'ARCHIVER_UNAVAILABLE' }
    $sevenZip = $cmd.Source
}

$resolvedInput = (Resolve-Path -LiteralPath $InputDirectory).Path
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputFile)
$parent = Split-Path -Parent $resolvedOutput
if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
Remove-Item -LiteralPath $resolvedOutput -Force -ErrorAction SilentlyContinue

Push-Location $resolvedInput
try {
    & $sevenZip a -t7z $resolvedOutput '.\*' "-p$SessionKey" -mhe=on -mx=7 *> $null
    if ($LASTEXITCODE -ne 0) { throw 'ENCRYPT_FAILED' }
} finally {
    Pop-Location
}

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedOutput).Hash.ToLowerInvariant()
[pscustomobject]@{
    File = $resolvedOutput
    Sha256 = $hash
    Size = (Get-Item -LiteralPath $resolvedOutput).Length
    ContainsSet = $hasSet
}
