$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$stage = 'INIT'
$code = 0
$key = $null
$root = Join-Path $env:RUNNER_TEMP 'g'
$payload = Join-Path $root 'p'
$baseMt5 = Join-Path $root 'mt5'
$out = Join-Path $root 'o'
$encIn = Join-Path $root 'i.7z'
$encOut = Join-Path $env:RUNNER_TEMP 'o.bin'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Set-Stage([string]$s, [int]$c = 1) {
    $script:stage = $s
    $script:code = $c
}

$resultsExported = $false

try {
    Write-Host "[GRID] NATIVE BATCH NODE INITIALIZED"

    if ([string]::IsNullOrWhiteSpace($env:GRID_SESSION_KEY)) { Set-Stage 'SESSION_KEY_MISSING'; throw "ERR_SESSION_KEY_MISSING" }
    if ($env:GRID_PACKAGE_SHA256 -notmatch '^[A-Fa-f0-9]{64}$') { Set-Stage 'HASH_INVALID'; throw "ERR_PACKAGE_HASH_INVALID" }
    if ([string]::IsNullOrWhiteSpace($env:GRID_PACKAGE_URL)) { Set-Stage 'URL_MISSING'; throw "ERR_PACKAGE_URL_MISSING" }
    if ([string]::IsNullOrWhiteSpace($env:GRID_WORKER_ID)) { Set-Stage 'WORKER_ID_MISSING'; throw "ERR_WORKER_ID_MISSING" }

    $key = $env:GRID_SESSION_KEY
    $workerId = $env:GRID_WORKER_ID.Trim()
    $opaqueId = if (-not [string]::IsNullOrWhiteSpace($env:GRID_OPAQUE_ID)) { $env:GRID_OPAQUE_ID.Trim() } else { 'unknown' }

    Write-Host "[GRID] RUNNER_CONFIG: WORKER_ID=$workerId, OPAQUE_ID=$opaqueId"

    $seven = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    if (-not (Test-Path $seven -PathType Leaf)) { Set-Stage 'SEVENZIP_MISSING'; throw "ERR_SEVENZIP_MISSING" }

    New-Item -ItemType Directory -Force -Path $root,$payload,$baseMt5,$out | Out-Null

    # 1. Hardware Probe
    $cs = Get-CimInstance Win32_ComputerSystem
    $logicalCpus = [Environment]::ProcessorCount
    $totalRamGb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    $drive = Get-PSDrive -Name C
    $freeDiskGb = [math]::Round($drive.Free / 1GB, 1)

    Write-Host "[GRID] HARDWARE: CPUS=$logicalCpus, RAM_GB=$totalRamGb, DISK_GB=$freeDiskGb"

    # 2. Download and decrypt payload
    Write-Host "[GRID] DOWNLOAD_PACKAGE_BEGIN"
    try {
        Invoke-WebRequest -Uri $env:GRID_PACKAGE_URL -OutFile $encIn -UseBasicParsing
    } catch {
        Set-Stage 'DOWNLOAD_FAILED'; throw "ERR_DOWNLOAD_FAILED"
    }

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $encIn).Hash
    if (-not $hash.Equals($env:GRID_PACKAGE_SHA256, [System.StringComparison]::OrdinalIgnoreCase)) {
        Set-Stage 'HASH_MISMATCH'; throw "ERR_PACKAGE_HASH_MISMATCH"
    }

    & $seven x $encIn "-p$key" "-o$payload" -y *> $null
    if ($LASTEXITCODE -ne 0) { Set-Stage 'DECRYPT_FAILED'; throw "ERR_DECRYPT_FAILED" }

    # Erase session key from environment immediately
    Remove-Item Env:GRID_SESSION_KEY -ErrorAction SilentlyContinue

    Write-Host "[GRID] PAYLOAD_VERIFIED"

    # 3. Locate worker configuration directory
    $workerDir = Join-Path $payload $workerId
    if (-not (Test-Path $workerDir -PathType Container)) {
        # Fallback to payload root if worker directory not present (single worker)
        $workerDir = $payload
    }

    # Extract runtime config
    $commonFile = Join-Path $workerDir 'common.ini'
    if (-not (Test-Path $commonFile -PathType Leaf)) {
        $commonFile = Join-Path $payload 'common.ini'
    }

    $commonSection = $null
    if (Test-Path $commonFile -PathType Leaf) {
        $commonSection = (Get-Content -LiteralPath $commonFile -Raw -Encoding utf8).Trim()
    } else {
        $testerIniPayload = Join-Path $workerDir 'tester.ini'
        if (-not (Test-Path $testerIniPayload -PathType Leaf)) { $testerIniPayload = Join-Path $payload 'tester.ini' }
        if (Test-Path $testerIniPayload -PathType Leaf) {
            $rawIni = Get-Content -LiteralPath $testerIniPayload -Raw -Encoding utf8
            $m = [regex]::Match($rawIni, '(?ms)\[Common\].*?(?=\r?\n\[|\Z)')
            if ($m.Success) { $commonSection = $m.Value.Trim() }
        }
    }
    if ([string]::IsNullOrWhiteSpace($commonSection)) {
        Set-Stage 'COMMON_CONFIG_MISSING'; throw "ERR_COMMON_CONFIG_MISSING"
    }

    $runSpecFile = Join-Path $workerDir 'run_spec.json'
    if (-not (Test-Path $runSpecFile -PathType Leaf)) {
        $runSpecFile = Join-Path $payload 'run_spec.json'
    }

    $symbol = $null
    $timeframe = $null
    $fromDate = $null
    $toDate = $null
    $model = '0'
    $deposit = '10000'
    $currency = 'USD'
    $leverage = '100'

    if (Test-Path $runSpecFile -PathType Leaf) {
        try {
            $specJson = Get-Content -LiteralPath $runSpecFile -Raw -Encoding utf8 | ConvertFrom-Json
            if ($specJson.symbol) { $symbol = $specJson.symbol }
            if ($specJson.timeframe) { $timeframe = $specJson.timeframe }
            if ($specJson.from_date) { $fromDate = $specJson.from_date }
            if ($specJson.to_date) { $toDate = $specJson.to_date }
            if ($specJson.model) { $model = $specJson.model.ToString() }
            if ($specJson.deposit) { $deposit = $specJson.deposit.ToString() }
            if ($specJson.currency) { $currency = $specJson.currency }
            if ($specJson.leverage) { $leverage = $specJson.leverage.ToString() }
        } catch {
            Set-Stage 'RUN_SPEC_PARSE_FAILED'; throw "ERR_RUN_SPEC_PARSE_FAILED"
        }
    } else {
        $testerIniPayload = Join-Path $workerDir 'tester.ini'
        if (-not (Test-Path $testerIniPayload -PathType Leaf)) { $testerIniPayload = Join-Path $payload 'tester.ini' }
        if (Test-Path $testerIniPayload -PathType Leaf) {
            $rawIni = Get-Content -LiteralPath $testerIniPayload -Raw -Encoding utf8
            if ($rawIni -match '(?im)^\s*Symbol\s*=\s*(\S+)') { $symbol = $matches[1].Trim() }
            if ($rawIni -match '(?im)^\s*Period\s*=\s*(\S+)') { $timeframe = $matches[1].Trim() }
            if ($rawIni -match '(?im)^\s*FromDate\s*=\s*(\S+)') { $fromDate = $matches[1].Trim() }
            if ($rawIni -match '(?im)^\s*ToDate\s*=\s*(\S+)') { $toDate = $matches[1].Trim() }
            if ($rawIni -match '(?im)^\s*Model\s*=\s*(\S+)') { $model = $matches[1].Trim() }
            if ($rawIni -match '(?im)^\s*Deposit\s*=\s*(\S+)') { $deposit = $matches[1].Trim() }
            if ($rawIni -match '(?im)^\s*Currency\s*=\s*(\S+)') { $currency = $matches[1].Trim() }
            if ($rawIni -match '(?im)^\s*Leverage\s*=\s*(\S+)') { $leverage = $matches[1].Trim() }
        }
    }

    if ([string]::IsNullOrWhiteSpace($symbol) -or [string]::IsNullOrWhiteSpace($timeframe)) {
        Set-Stage 'RUNTIME_SPEC_MISSING'; throw "ERR_RUNTIME_SPEC_MISSING"
    }

    # 4. Install MT5 Runtime using proven architecture
    Write-Host "[GRID] INSTALL_MT5_BEGIN"
    $setup = Join-Path $root 's.exe'
    try {
        Invoke-WebRequest -Uri 'https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe' -OutFile $setup -UseBasicParsing
    } catch {
        Set-Stage 'RUNTIME_DOWNLOAD_FAILED'; throw "ERR_RUNTIME_DOWNLOAD_FAILED"
    }

    Start-Process -FilePath $setup -ArgumentList '/auto' | Out-Null
    $defaultMt5 = Join-Path $env:ProgramFiles 'MetaTrader 5'
    $termDefault = Join-Path $defaultMt5 'terminal64.exe'
    $deadline = (Get-Date).AddMinutes(5)
    while (-not (Test-Path $termDefault -PathType Leaf) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
    }
    Start-Sleep -Seconds 5
    Get-Process terminal64,metatester64,s,mt5setup -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $termDefault -PathType Leaf)) {
        Set-Stage 'RUNTIME_DEFAULT_MISSING'; throw "ERR_RUNTIME_DEFAULT_MISSING"
    }

    Copy-Item -Path "$defaultMt5\*" -Destination $baseMt5 -Recurse -Force
    $baseTerminal = Join-Path $baseMt5 'terminal64.exe'
    $baseEditor = Join-Path $baseMt5 'metaeditor64.exe'
    if (-not (Test-Path $baseTerminal -PathType Leaf)) {
        Set-Stage 'RUNTIME_COPIED_MISSING'; throw "ERR_RUNTIME_COPIED_MISSING"
    }

    # Clean sample mq5 files
    Get-ChildItem -Path (Join-Path $baseMt5 'MQL5') -Filter '*.mq5' -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Host "[GRID] MT5_INSTALLED"

    # 5. Direct-Endpoint Prewarm (Proven contract)
    $prewarmScriptSource = Join-Path $workerDir 'grid_prewarm.mq5'
    if (-not (Test-Path $prewarmScriptSource -PathType Leaf)) { $prewarmScriptSource = Join-Path $payload 'grid_prewarm.mq5' }
    if (-not (Test-Path $prewarmScriptSource -PathType Leaf)) { $prewarmScriptSource = Join-Path $PSScriptRoot 'grid_prewarm.mq5' }
    if (-not (Test-Path $prewarmScriptSource -PathType Leaf)) {
        Set-Stage 'PREWARM_SOURCE_MISSING'; throw "ERR_PREWARM_SOURCE_MISSING"
    }

    $scriptsDir = Join-Path $baseMt5 'MQL5\Scripts'
    New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
    Copy-Item -LiteralPath $prewarmScriptSource -Destination (Join-Path $scriptsDir 'grid_prewarm.mq5') -Force

    # Compile prewarm script
    $logComp = Join-Path $root 'compile.log'
    Start-Process -FilePath $baseEditor -ArgumentList @('/portable', ('/compile:"' + (Join-Path $scriptsDir 'grid_prewarm.mq5') + '"'), ('/log:"' + $logComp + '"')) -Wait | Out-Null
    $prewarmEx5 = Join-Path $scriptsDir 'grid_prewarm.ex5'
    if (-not (Test-Path $prewarmEx5 -PathType Leaf)) {
        Set-Stage 'PREWARM_COMPILE_FAILED'; throw "ERR_PREWARM_COMPILE_FAILED"
    }

    # 5b. Write prewarm parameters
    $filesDir = Join-Path $baseMt5 'MQL5\Files'
    New-Item -ItemType Directory -Force -Path $filesDir | Out-Null
    $paramContent = "FromDate=$fromDate`nToDate=$toDate`nModel=$model"
    Set-Content -LiteralPath (Join-Path $filesDir 'prewarm_params.txt') -Value $paramContent -Encoding ascii

    # Build prewarm.ini (UTF-8 WITHOUT BOM)
    $prewarmIni = Join-Path $baseMt5 'prewarm.ini'
    $prewarmIniContent = "$commonSection`n`n[StartUp]`nScript=grid_prewarm`nSymbol=$symbol`nPeriod=$timeframe`nShutdownTerminal=1`n"
    [System.IO.File]::WriteAllText($prewarmIni, $prewarmIniContent, $utf8NoBom)

    $prewarmBytes = [System.IO.File]::ReadAllBytes($prewarmIni)
    if ($prewarmBytes.Length -ge 3 -and $prewarmBytes[0] -eq 0xEF -and $prewarmBytes[1] -eq 0xBB -and $prewarmBytes[2] -eq 0xBF) {
        Set-Stage 'PREWARM_INI_BOM_INVALID'; throw "BOM detected in prewarm.ini"
    }
    Write-Host '[GRID] PREWARM_INI_ENCODING_OK'

    Write-Host "[GRID] PREWARM_BEGIN"
    $procPrewarm = Start-Process -FilePath $baseTerminal -ArgumentList @('/portable', ('/config:"' + $prewarmIni + '"')) -WorkingDirectory $baseMt5 -PassThru
    $swPrewarm = [System.Diagnostics.Stopwatch]::StartNew()
    $prewarmTimeoutSec = 300

    while (-not $procPrewarm.HasExited) {
        Start-Sleep -Seconds 2
        if ($swPrewarm.Elapsed.TotalSeconds -ge $prewarmTimeoutSec) {
            Stop-Process -Id $procPrewarm.Id -Force -ErrorAction SilentlyContinue
            Set-Stage 'PREWARM_TIMEOUT'; throw "ERR_PREWARM_TIMEOUT"
        }
    }

    Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
    Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    # Verify prewarm sentinel
    $statusFile = Join-Path $filesDir 'grid_prewarm.status'
    if (-not (Test-Path $statusFile -PathType Leaf)) {
        Set-Stage 'PREWARM_SENTINEL_MISSING'; throw "ERR_PREWARM_SENTINEL_MISSING"
    }

    $statusContent = Get-Content -LiteralPath $statusFile -Raw
    if ($statusContent -notmatch '(?im)^\s*STATUS\s*=\s*PASS') {
        Set-Stage 'PREWARM_FAILED'; throw "ERR_PREWARM_FAILED"
    }

    $m1Bars = if ($statusContent -match '(?im)^\s*M1_BARS\s*=\s*(\d+)') { [int]$matches[1] } else { 0 }
    $targetBars = if ($statusContent -match '(?im)^\s*TARGET_BARS\s*=\s*(\d+)') { [int]$matches[1] } else { 0 }

    if ($m1Bars -le 0 -or $targetBars -le 0) {
        Set-Stage 'PREWARM_INSUFFICIENT_BARS'; throw "ERR_PREWARM_INSUFFICIENT_BARS"
    }

    Write-Host "[GRID] PREWARM_PASS: M1_BARS=$m1Bars, TARGET_BARS=$targetBars"

    # 6. Configure Strategy Tester Optimization (1 Terminal, 4 Passes, Generic worker.ex5)
    $expertsDir = Join-Path $baseMt5 'MQL5\Experts'
    New-Item -ItemType Directory -Force -Path $expertsDir | Out-Null
    $workerEx5 = Join-Path $workerDir 'worker.ex5'
    if (-not (Test-Path $workerEx5 -PathType Leaf)) { $workerEx5 = Join-Path $payload 'worker.ex5' }
    if (-not (Test-Path $workerEx5 -PathType Leaf)) { Set-Stage 'EXPERT_MISSING'; throw "ERR_EXPERT_MISSING" }
    Copy-Item -LiteralPath $workerEx5 -Destination (Join-Path $expertsDir 'worker.ex5') -Force

    $profilesTesterDir = Join-Path $baseMt5 'MQL5\Profiles\Tester'
    New-Item -ItemType Directory -Force -Path $profilesTesterDir | Out-Null
    $workerSet = Join-Path $workerDir 'worker.set'
    if (-not (Test-Path $workerSet -PathType Leaf)) { $workerSet = Join-Path $payload 'worker.set' }
    if (-not (Test-Path $workerSet -PathType Leaf)) { Set-Stage 'SET_MISSING'; throw "ERR_SET_MISSING" }
    Copy-Item -LiteralPath $workerSet -Destination (Join-Path $profilesTesterDir 'worker.set') -Force

    $testerIni = Join-Path $baseMt5 'tester.ini'
    $testerIniContent = @"
$commonSection

[Tester]
Expert=worker.ex5
ExpertParameters=worker.set
Symbol=$symbol
Period=$timeframe
Deposit=$deposit
Currency=$currency
Leverage=$leverage
Model=$model
ExecutionMode=0
Optimization=1
OptimizationCriterion=0
FromDate=$fromDate
ToDate=$toDate
Report=opt_report.xml
ReplaceReport=1
ShutdownTerminal=1
Visual=0
UseLocal=1
UseRemote=0
UseCloud=0
"@
    [System.IO.File]::WriteAllText($testerIni, $testerIniContent, $utf8NoBom)

    # 7. Launch Single-Terminal Optimization & Concurrency Monitor (Watchdog: 105 minutes = 6300s)
    $optStartUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Host "[GRID] OPTIMIZATION_START_UTC=$optStartUtc"

    $termProc = Start-Process -FilePath $baseTerminal -ArgumentList @('/portable', ('/config:"' + $testerIni + '"')) -WorkingDirectory $baseMt5 -PassThru

    $prevCpu = @{}
    $maxAgentProcesses = 0
    $maxActiveAgents = 0
    $fourActiveFirstUtc = $null
    $fourActiveLastUtc = $null
    $samplesWith4Active = 0

    $perfCpu = New-Object System.Diagnostics.PerformanceCounter("Processor", "% Processor Time", "_Total")
    $null = $perfCpu.NextValue()

    $peakCpu = 0.0
    $peakMemMb = 0.0
    $minFreeMemMb = 999999.0

    $timeoutSec = 6300  # 105 minutes hard watchdog
    $swOpt = [System.Diagnostics.Stopwatch]::StartNew()
    $lastLogSec = 0

    while (-not $termProc.HasExited) {
        Start-Sleep -Seconds 1

        if ($swOpt.Elapsed.TotalSeconds -ge $timeoutSec) {
            Stop-Process -Id $termProc.Id -Force -ErrorAction SilentlyContinue
            Get-Process metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Set-Stage 'OPTIMIZATION_TIMEOUT'; throw "ERR_OPTIMIZATION_TIMEOUT"
        }

        # Resource monitoring
        try {
            $cpuVal = [math]::Round($perfCpu.NextValue(), 1)
            if ($cpuVal -gt $peakCpu) { $peakCpu = $cpuVal }

            $os = Get-CimInstance Win32_OperatingSystem
            $freeMem = [math]::Round($os.FreePhysicalMemory / 1024, 1)
            $totMem = [math]::Round($os.TotalVisibleMemorySize / 1024, 1)
            $usedMem = $totMem - $freeMem
            if ($usedMem -gt $peakMemMb) { $peakMemMb = $usedMem }
            if ($freeMem -lt $minFreeMemMb) { $minFreeMemMb = $freeMem }
        } catch {}

        # Sample active metatester64 processes
        $agents = @(Get-Process metatester64 -ErrorAction SilentlyContinue)
        if ($agents.Count -gt $maxAgentProcesses) { $maxAgentProcesses = $agents.Count }

        $activeCount = 0
        $currentUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

        foreach ($a in $agents) {
            try {
                if ($a.HasExited) { continue }
                $agentId = $a.Id
                $totTime = $a.TotalProcessorTime
                if ($null -ne $totTime) {
                    $currTime = $totTime.TotalMilliseconds
                    if ($prevCpu.ContainsKey($agentId)) {
                        $delta = $currTime - $prevCpu[$agentId]
                        if ($delta -gt 200) {
                            $activeCount++
                        }
                    }
                    $prevCpu[$agentId] = $currTime
                }
            } catch {}
        }

        if ($activeCount -gt $maxActiveAgents) { $maxActiveAgents = $activeCount }

        if ($activeCount -ge 4) {
            $samplesWith4Active++
            if ($null -eq $fourActiveFirstUtc) {
                $fourActiveFirstUtc = $currentUtc
            }
            $fourActiveLastUtc = $currentUtc
        }

        # Progress log every 30s
        $elapsedSec = [int]$swOpt.Elapsed.TotalSeconds
        if ($elapsedSec -ge ($lastLogSec + 30)) {
            $lastLogSec = $elapsedSec
            Write-Host "[GRID] ELAPSED=${elapsedSec}s | WORKER=$workerId | AGENTS_RUNNING=$($agents.Count) | AGENTS_ACTIVE=$activeCount | MAX_ACTIVE=$maxActiveAgents | SAMPLES_4WAY=$samplesWith4Active"
        }
    }

    $optEndUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Host "[GRID] OPTIMIZATION_END_UTC=$optEndUtc"

    # Allow 10s for agents to terminate cleanly
    Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    $fourAgentOverlapSec = $samplesWith4Active
    Write-Host "[GRID] METRICS: MAX_AGENTS=$maxAgentProcesses, MAX_ACTIVE=$maxActiveAgents, 4WAY_OVERLAP_SEC=$fourAgentOverlapSec"

    # 8. Validate Optimization Report & Completed Passes (Fixed Parser)
    $reportXml = Join-Path $baseMt5 'opt_report.xml'
    $completedPasses = 0
    $passCountSource = 'NONE'

    if (Test-Path -LiteralPath $reportXml -PathType Leaf) {
        try {
            $xmlTxt = Get-Content -LiteralPath $reportXml -Raw -Encoding utf8
            # Robust match: MT5 uses ss:Type="Number" for pass number: <Row><Cell><Data ss:Type="Number">0</Data></Cell>
            $matchRows = [regex]::Matches($xmlTxt, '<Row>\s*<Cell><Data ss:Type="(?:Number|String)">\d+</Data></Cell>')
            if ($matchRows.Count -gt 0) {
                $completedPasses = $matchRows.Count
                $passCountSource = 'REPORT_XML'
                Write-Host "[GRID] REPORT_XML_DETECTED: COMPLETED_PASS_ROWS=$completedPasses"
            }
        } catch {
            Write-Host "[GRID] REPORT_XML_PARSE_WARNING: $_"
        }
    }

    if ($completedPasses -eq 0) {
        # Check tester logs fallback
        $testerLogs = @(Get-ChildItem -Path (Join-Path $baseMt5 'Tester\logs') -Filter '*.log' -File -ErrorAction SilentlyContinue)
        foreach ($tl in $testerLogs) {
            $lines = Get-Content $tl.FullName -Encoding Unicode -ErrorAction SilentlyContinue
            foreach ($line in $lines) {
                if ($line -match 'optimization finished,\s*total passes\s*(\d+)') {
                    $p = [int]$matches[1]
                    if ($p -gt $completedPasses) {
                        $completedPasses = $p
                        $passCountSource = 'TESTER_LOG_FALLBACK'
                    }
                }
            }
        }
        if ($completedPasses -gt 0) {
            Write-Host "[GRID] TESTER_LOG_DETECTED: COMPLETED_PASSES=$completedPasses"
        }
    }

    Write-Host "[GRID] TOTAL_COMPLETED_PASSES=$completedPasses (SOURCE=$passCountSource)"

    # 9. Export Results to Evidence Directory
    Copy-Item -LiteralPath $statusFile -Destination (Join-Path $out 'prewarm_status.txt') -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $reportXml) { Copy-Item -LiteralPath $reportXml -Destination (Join-Path $out 'opt_report.xml') -Force }

    $metaInPayload = Join-Path $workerDir 'meta.json'
    if (-not (Test-Path $metaInPayload -PathType Leaf)) { $metaInPayload = Join-Path $payload 'meta.json' }
    if (Test-Path -LiteralPath $metaInPayload) { Copy-Item -LiteralPath $metaInPayload -Destination (Join-Path $out 'meta.json') -Force }

    Copy-Item -LiteralPath $testerIni -Destination (Join-Path $out 'tester.ini') -Force -ErrorAction SilentlyContinue

    $testerLogsDir = Join-Path $baseMt5 'Tester\logs'
    if (Test-Path -LiteralPath $testerLogsDir) {
        $destTesterLogs = Join-Path $out 'Tester_logs'
        Copy-Item -LiteralPath $testerLogsDir -Destination $destTesterLogs -Recurse -Force -ErrorAction SilentlyContinue
    }

    $agentDirs = @(Get-ChildItem -Path (Join-Path $baseMt5 'Tester') -Filter 'Agent-*' -Directory -ErrorAction SilentlyContinue)
    foreach ($ad in $agentDirs) {
        $destAd = Join-Path $out $ad.Name
        Copy-Item -LiteralPath $ad.FullName -Destination $destAd -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Summary
    $summaryPath = Join-Path $out 'worker_summary.txt'
    $summaryContent = @"
WORKER_ID=$workerId
TERMINAL_INSTANCES=1
LOGICAL_CPUS=$logicalCpus
TOTAL_RAM_GB=$totalRamGb
EXPECTED_PASSES=4
COMPLETED_PASSES=$completedPasses
PASS_COUNT_SOURCE=$passCountSource
MAX_AGENT_PROCESSES=$maxAgentProcesses
MAX_ACTIVE_AGENTS=$maxActiveAgents
FOUR_AGENT_OVERLAP_SEC=$fourAgentOverlapSec
PREWARM_STATUS=PASS
M1_BARS=$m1Bars
TARGET_BARS=$targetBars
PEAK_CPU_PERCENT=$peakCpu
PEAK_RAM_MB=$peakMemMb
OPTIMIZATION_DURATION_SEC=$([math]::Round($swOpt.Elapsed.TotalSeconds, 1))
"@
    [System.IO.File]::WriteAllText($summaryPath, $summaryContent, $utf8NoBom)

    # Also write canary_summary.txt for backwards compatibility with auditors
    [System.IO.File]::WriteAllText((Join-Path $out 'canary_summary.txt'), $summaryContent, $utf8NoBom)

    if ($completedPasses -eq 4) {
        Set-Stage 'OK' 0
    } else {
        Set-Stage 'PASS_COUNT_MISMATCH' 1
    }

    $resultsExported = $true
} catch {
    Write-Host "[GRID] ERROR: $_"
    if ($stage -eq 'INIT' -or $stage -eq 'OK') {
        Set-Stage 'UNCAUGHT_EXCEPTION' 1
    }
} finally {
    try {
        [System.IO.File]::WriteAllText((Join-Path $out 'stage.txt'), $stage, $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $out 'exit.txt'), $code.ToString(), $utf8NoBom)

        # Encrypt evidence into o.bin
        $encKey = if (-not [string]::IsNullOrWhiteSpace($key)) { $key } else { $env:GRID_SESSION_KEY }
        if (-not [string]::IsNullOrWhiteSpace($encKey) -and (Test-Path $seven -PathType Leaf)) {
            Push-Location $out
            try {
                & $seven a -t7z $encOut '.\*' "-p$encKey" -mhe=on -mx=5 | Out-Null
                Write-Host "[GRID] Evidence encrypted to $encOut ($((Get-Item $encOut).Length) bytes)"
            } finally {
                Pop-Location
            }
        }
    } catch {
        Write-Host "[GRID] Finalization error: $_"
    }

    # Cleanup temp
    Remove-Item Env:GRID_SESSION_KEY -ErrorAction SilentlyContinue
    $key = $null
    Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    Write-Host "[GRID] NATIVE BATCH NODE FINISHED with stage=$stage code=$code"
    exit $code
}
