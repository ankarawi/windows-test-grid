$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$stage = 'INIT'
$code = 0
$key = $null
$root = Join-Path $env:RUNNER_TEMP 'canary_g'
$payload = Join-Path $root 'p'
$baseMt5 = Join-Path $root 'base_mt5'
$out = Join-Path $root 'o'
$encIn = Join-Path $root 'i.7z'

function Set-Stage([string]$s, [int]$c = 1) {
    $script:stage = $s
    $script:code = $c
}

try {
    if ([string]::IsNullOrWhiteSpace($env:GRID_SESSION_KEY)) { Set-Stage 'SESSION_KEY_MISSING'; throw }
    if ($env:GRID_PACKAGE_SHA256 -notmatch '^[A-Fa-f0-9]{64}$') { Set-Stage 'HASH_INVALID'; throw }
    if ([string]::IsNullOrWhiteSpace($env:GRID_PACKAGE_URL)) { Set-Stage 'URL_MISSING'; throw }

    $key = $env:GRID_SESSION_KEY
    $seven = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    if (-not (Test-Path $seven -PathType Leaf)) { Set-Stage 'SEVENZIP_MISSING'; throw }

    New-Item -ItemType Directory -Force -Path $root,$payload,$baseMt5,$out | Out-Null

    Write-Host '[GRID] CANARY_START'
    try { Invoke-WebRequest -Uri $env:GRID_PACKAGE_URL -OutFile $encIn -UseBasicParsing } catch { Set-Stage 'DOWNLOAD_FAILED'; throw }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $encIn).Hash
    if (-not $hash.Equals($env:GRID_PACKAGE_SHA256, [System.StringComparison]::OrdinalIgnoreCase)) { Set-Stage 'HASH_MISMATCH'; throw }

    & $seven x $encIn "-p$key" "-o$payload" -y *> $null
    if ($LASTEXITCODE -ne 0) { Set-Stage 'DECRYPT_FAILED'; throw }

    $expert = Join-Path $payload 'worker.ex5'
    $canaryDir = Join-Path $payload 'canary'
    $config = Join-Path $canaryDir 'tester.ini'
    if (-not (Test-Path $expert -PathType Leaf)) { Set-Stage 'PAYLOAD_EXPERT_MISSING'; throw }
    if (-not (Test-Path $config -PathType Leaf)) { Set-Stage 'CANARY_CONFIG_MISSING'; throw }

    # Install MT5 runtime
    $setup = Join-Path $root 's.exe'
    try { Invoke-WebRequest -Uri 'https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe' -OutFile $setup -UseBasicParsing } catch { Set-Stage 'RUNTIME_DOWNLOAD_FAILED'; throw }
    Start-Process -FilePath $setup -ArgumentList '/auto' | Out-Null
    $defaultMt5 = Join-Path $env:ProgramFiles 'MetaTrader 5'
    $termDefault = Join-Path $defaultMt5 'terminal64.exe'
    $deadline = (Get-Date).AddMinutes(5)
    while (-not (Test-Path $termDefault -PathType Leaf) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
    Start-Sleep -Seconds 5
    Get-Process terminal64,metatester64,s,mt5setup -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $termDefault -PathType Leaf)) { Set-Stage 'RUNTIME_MISSING'; throw }
    Copy-Item -Path "$defaultMt5\*" -Destination $baseMt5 -Recurse -Force
    $baseTerminal = Join-Path $baseMt5 'terminal64.exe'

    Get-ChildItem -Path (Join-Path $baseMt5 'MQL5') -Filter '*.mq5' -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    $expertDir = Join-Path $baseMt5 'MQL5\Experts'
    $scriptsDir = Join-Path $baseMt5 'MQL5\Scripts'
    $filesDir = Join-Path $baseMt5 'MQL5\Files'
    New-Item -ItemType Directory -Force -Path $expertDir,$scriptsDir,$filesDir | Out-Null

    # Prewarm config
    $cfg = Get-Content -LiteralPath $config -Raw -Encoding utf8
    $commonMatch = [regex]::Match($cfg, '(?ms)\[Common\].*?(?=\r?\n\[|\Z)')
    if (-not $commonMatch.Success) { Set-Stage 'CONFIG_INVALID'; throw }
    $commonSection = $commonMatch.Value

    $symbol = if ($cfg -match '(?im)^\s*Symbol\s*=\s*(\S+)') { $matches[1].Trim() } else { '' }
    $period = if ($cfg -match '(?im)^\s*Period\s*=\s*(\S+)') { $matches[1].Trim() } else { 'M1' }
    $fromDate = if ($cfg -match '(?im)^\s*FromDate\s*=\s*(\S+)') { $matches[1].Trim() } else { '2024.08.01' }
    $toDate = if ($cfg -match '(?im)^\s*ToDate\s*=\s*(\S+)') { $matches[1].Trim() } else { '2026.01.31' }
    $model = if ($cfg -match '(?im)^\s*Model\s*=\s*(\S+)') { $matches[1].Trim() } else { '0' }

    $eaName = if ($cfg -match '(?im)^\s*Expert\s*=\s*(\S+)') { $matches[1].Trim() } else { 'worker.ex5' }
    if (-not $eaName.EndsWith('.ex5', [System.StringComparison]::OrdinalIgnoreCase)) { $eaName += '.ex5' }
    Copy-Item -LiteralPath $expert -Destination (Join-Path $expertDir $eaName) -Force
    Copy-Item -LiteralPath $expert -Destination (Join-Path $expertDir 'worker.ex5') -Force

    # Compile generic prewarm script
    $prewarmMq5 = Join-Path $env:GITHUB_WORKSPACE 'runner\grid_prewarm.mq5'
    $targetMq5 = Join-Path $scriptsDir 'grid_prewarm.mq5'
    Copy-Item -LiteralPath $prewarmMq5 -Destination $targetMq5 -Force
    $metaeditor = Join-Path $baseMt5 'metaeditor64.exe'
    $compileLog = Join-Path $baseMt5 'compile_prewarm.log'
    Start-Process -FilePath $metaeditor -ArgumentList @("/compile:$targetMq5", "/log:$compileLog") -Wait | Out-Null
    if (-not (Test-Path (Join-Path $scriptsDir 'grid_prewarm.ex5') -PathType Leaf)) { Set-Stage 'PREWARM_COMPILE_FAILED'; throw }

    $paramContent = "FromDate=$fromDate`nToDate=$toDate`nModel=$model"
    Set-Content -LiteralPath (Join-Path $filesDir 'prewarm_params.txt') -Value $paramContent -Encoding ascii

    $prewarmIni = Join-Path $baseMt5 'prewarm.ini'
    $prewarmIniContent = "$commonSection`n`n[StartUp]`nScript=grid_prewarm`nSymbol=$symbol`nPeriod=$period`nShutdownTerminal=1`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($prewarmIni, $prewarmIniContent, $utf8NoBom)

    $prewarmBytes = [System.IO.File]::ReadAllBytes($prewarmIni)
    if ($prewarmBytes.Length -ge 3 -and $prewarmBytes[0] -eq 0xEF -and $prewarmBytes[1] -eq 0xBB -and $prewarmBytes[2] -eq 0xBF) {
        Set-Stage 'PREWARM_INI_BOM_INVALID'; throw "BOM detected in prewarm.ini"
    }
    Write-Host '[GRID] PREWARM_INI_ENCODING_OK'

    # Run Prewarm
    Write-Host '[GRID] PREWARM_BEGIN'
    $procPrewarm = Start-Process -FilePath $baseTerminal -ArgumentList @('/portable',('/config:"'+$prewarmIni+'"')) -WorkingDirectory $baseMt5 -PassThru
    $swPrewarm = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $procPrewarm.HasExited) {
        Start-Sleep -Seconds 2
        if ($swPrewarm.Elapsed.TotalSeconds -ge 180) {
            Stop-Process -Id $procPrewarm.Id -Force -ErrorAction SilentlyContinue
            Set-Stage 'PREWARM_TIMEOUT'; throw
        }
    }

    Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
    Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    $statusPath = Join-Path $filesDir 'grid_prewarm.status'
    $prewarmStatusOk = $false
    if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
        $stContent = Get-Content -LiteralPath $statusPath -Raw
        $stPass = ($stContent -match '(?im)^\s*STATUS\s*=\s*PASS\s*$')
        $m1Bars = if ($stContent -match '(?im)^\s*M1_BARS\s*=\s*(\d+)') { [int]$matches[1] } else { 0 }
        $tgtBars = if ($stContent -match '(?im)^\s*TARGET_BARS\s*=\s*(\d+)') { [int]$matches[1] } else { 0 }
        if ($stPass -and $m1Bars -gt 0 -and $tgtBars -gt 0) {
            $prewarmStatusOk = $true
        }
    }

    if (-not $prewarmStatusOk) {
        Write-Host "[GRID] PREWARM_STATUS_FAILED: $(if (Test-Path $statusPath) { Get-Content $statusPath -Raw } else { 'STATUS_FILE_MISSING' })"
        Set-Stage 'PREWARM_FAILED'; throw
    }
    Write-Host '[GRID] PREWARM_SENTINEL_STATUS=PASS'
    Write-Host '[GRID] DIRECT_ENDPOINT_AUTH=PASS'
    Write-Host '[GRID] M1_BARS_OK'

    # Check history files
    $hcc = @(Get-ChildItem -Path (Join-Path $baseMt5 'bases') -Filter '*.hcc' -Recurse -File -ErrorAction SilentlyContinue)
    if ($hcc.Count -le 0) { Set-Stage 'HISTORY_CACHE_MISSING'; throw }

    Write-Host '[GRID] CANARY_SUCCESS'
    $stage = 'OK'
    $code = 0
} catch {
    if ($stage -eq 'INIT' -or $stage -eq 'OK') { $stage = 'CANARY_FAILED' }
    if ($code -eq 0) { $code = 1 }
    Write-Host "[GRID] $stage : $($_.Exception.Message)"
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    if ($null -ne $env:GITHUB_OUTPUT -and (Test-Path -LiteralPath $env:GITHUB_OUTPUT)) {
        "exit_code=$code" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
        "stage=$stage" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
    }
}

if ($stage -ne 'OK' -or $code -ne 0) { exit 1 }
