param(
    [Parameter(Mandatory=$true)][string]$InputFile,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [Parameter(Mandatory=$true)][string]$SessionKey
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $InputFile -PathType Leaf)) {
    throw 'INPUT_FILE_NOT_FOUND'
}
if ([string]::IsNullOrWhiteSpace($SessionKey) -or $SessionKey.Length -lt 32) {
    throw 'SESSION_KEY_TOO_SHORT'
}

$sevenZip = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
if (-not (Test-Path -LiteralPath $sevenZip)) {
    $cmd = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { throw 'ARCHIVER_UNAVAILABLE' }
    $sevenZip = $cmd.Source
}

$resolvedInput = (Resolve-Path -LiteralPath $InputFile).Path
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null

& $sevenZip x $resolvedInput "-p$SessionKey" "-o$resolvedOutput" -y *> $null
if ($LASTEXITCODE -ne 0) { throw 'DECRYPT_FAILED' }

$exitFile = Join-Path $resolvedOutput 'd\exit.txt'
$exitCode = $null
if (Test-Path -LiteralPath $exitFile) {
    $exitCode = (Get-Content -LiteralPath $exitFile -Raw).Trim()
}

[pscustomobject]@{
    OutputDirectory = $resolvedOutput
    ExitCode = $exitCode
    Files = @(Get-ChildItem -LiteralPath $resolvedOutput -File -Recurse -Force).Count
}
