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

$entry = Join-Path $InputDirectory 'entry.ps1'
if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) {
    throw 'ENTRY_MISSING'
}

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
}
