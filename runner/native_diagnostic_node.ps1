# native_diagnostic_node.ps1
# Specialized diagnostic runner node for MT5 Strategy Tester process & resource telemetry.
# Designed to audit process explosion, handle leaks, and agent lifetime dynamics.

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

# Diagnostic Telemetry State
$telemetrySnapshots = [System.Collections.Generic.List[object]]::new()
$seenPids = [System.Collections.Generic.HashSet[int]]::new()
$pidCreationTimes = @{}
$exitedPidCount = 0
$maxSimultaneousMetatester = 0
$maxTotalProcesses = 0
$minFreeRamMb = 999999.0
$peakUsedRamMb = 0.0
$peakTotalHandles = 0
$resourceExplosionAborted = $false

try {
    Write-Host "[DIAG] NATIVE DIAGNOSTIC NODE INITIALIZED"

    if ([string]::IsNullOrWhiteSpace($env:GRID_SESSION_KEY)) { Set-Stage 'SESSION_KEY_MISSING'; throw "ERR_SESSION_KEY_MISSING" }
    if ($env:GRID_PACKAGE_SHA256 -notmatch '^[A-Fa-f0-9]{64}$') { Set-Stage 'HASH_INVALID'; throw "ERR_PACKAGE_HASH_INVALID" }
    if ([string]::IsNullOrWhiteSpace($env:GRID_PACKAGE_URL)) { Set-Stage 'URL_MISSING'; throw "ERR_PACKAGE_URL_MISSING" }

    $workerId = if (-not [string]::IsNullOrWhiteSpace($env:GRID_WORKER_ID)) { $env:GRID_WORKER_ID.Trim() } else { 'diagnostic-00' }
    $key = $env:GRID_SESSION_KEY
    $opaqueId = if (-not [string]::IsNullOrWhiteSpace($env:GRID_OPAQUE_ID)) { $env:GRID_OPAQUE_ID.Trim() } else { 'unknown' }

    Write-Host "[DIAG] RUNNER_CONFIG: WORKER_ID=$workerId, OPAQUE_ID=$opaqueId"

    $seven = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    if (-not (Test-Path $seven -PathType Leaf)) { Set-Stage 'SEVENZIP_MISSING'; throw "ERR_SEVENZIP_MISSING" }

    New-Item -ItemType Directory -Force -Path $root,$payload,$baseMt5,$out | Out-Null

    # 1. Hardware Probe
    $cs = Get-CimInstance Win32_ComputerSystem
    $logicalCpus = [Environment]::ProcessorCount
    $totalRamGb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    $drive = Get-PSDrive -Name C
    $freeDiskGb = [math]::Round($drive.Free / 1GB, 1)

    Write-Host "[DIAG] HARDWARE: CPUS=$logicalCpus, RAM_GB=$totalRamGb, DISK_GB=$freeDiskGb"

    # 2. Download and decrypt payload
    Write-Host "[DIAG] DOWNLOAD_PACKAGE_BEGIN"
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

    Write-Host "[DIAG] PAYLOAD_VERIFIED"

    # 3. Locate worker configuration directory
    $workerDir = Join-Path $payload $workerId
    if (-not (Test-Path $workerDir -PathType Container)) {
        # Fallback to runner-07 or first subdirectory if workerId not matched
        $subDirs = @(Get-ChildItem $payload -Directory)
        if ($subDirs.Count -eq 1) {
            $workerDir = $subDirs[0].FullName
        } else {
            $r07Dir = Join-Path $payload 'runner-07'
            if (Test-Path $r07Dir -PathType Container) {
                $workerDir = $r07Dir
            } else {
                Set-Stage 'WORKER_PAYLOAD_MISSING'; throw "ERR_WORKER_PAYLOAD_MISSING"
            }
        }
    }

    $runSpecFile = Join-Path $workerDir 'run_spec.json'
    if (-not (Test-Path $runSpecFile -PathType Leaf)) { Set-Stage 'WORKER_RUN_SPEC_MISSING'; throw "ERR_WORKER_RUN_SPEC_MISSING" }

    $workerSet = Join-Path $workerDir 'worker.set'
    if (-not (Test-Path $workerSet -PathType Leaf)) { Set-Stage 'WORKER_SET_MISSING'; throw "ERR_WORKER_SET_MISSING" }

    $workerMetaFile = Join-Path $workerDir 'meta.json'
    if (-not (Test-Path $workerMetaFile -PathType Leaf)) { Set-Stage 'WORKER_META_MISSING'; throw "ERR_WORKER_META_MISSING" }

    # Parse runtime run_spec
    $specJson = Get-Content -LiteralPath $runSpecFile -Raw -Encoding utf8 | ConvertFrom-Json
    $symbol = $specJson.symbol.ToString().Trim()
    $timeframe = $specJson.timeframe.ToString().Trim()
    $fromDate = $specJson.from_date.ToString().Trim()
    $toDate = $specJson.to_date.ToString().Trim()
    $model = if ($specJson.model -ne $null) { $specJson.model.ToString().Trim() } else { '0' }
    $deposit = if ($specJson.deposit -ne $null) { $specJson.deposit.ToString().Trim() } else { '10000' }
    $currency = if ($specJson.currency) { $specJson.currency.ToString().Trim() } else { 'USD' }
    $leverage = if ($specJson.leverage -ne $null) { $specJson.leverage.ToString().Trim() } else { '100' }

    # Shared config files
    $commonFile = Join-Path $workerDir 'common.ini'
    if (-not (Test-Path $commonFile -PathType Leaf)) { $commonFile = Join-Path $payload 'common.ini' }
    if (-not (Test-Path $commonFile -PathType Leaf)) { Set-Stage 'COMMON_CONFIG_MISSING'; throw "ERR_COMMON_CONFIG_MISSING" }
    $commonSection = (Get-Content -LiteralPath $commonFile -Raw -Encoding utf8).Trim()

    # 4. Install MT5 Runtime
    Write-Host "[DIAG] INSTALL_MT5_BEGIN"
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

    if (-not (Test-Path $termDefault -PathType Leaf)) { Set-Stage 'RUNTIME_DEFAULT_MISSING'; throw "ERR_RUNTIME_DEFAULT_MISSING" }

    Copy-Item -Path "$defaultMt5\*" -Destination $baseMt5 -Recurse -Force
    $baseTerminal = Join-Path $baseMt5 'terminal64.exe'
    $baseEditor = Join-Path $baseMt5 'metaeditor64.exe'
    if (-not (Test-Path $baseTerminal -PathType Leaf)) { Set-Stage 'RUNTIME_COPIED_MISSING'; throw "ERR_RUNTIME_COPIED_MISSING" }

    Get-ChildItem -Path (Join-Path $baseMt5 'MQL5') -Filter '*.mq5' -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Host "[DIAG] MT5_INSTALLED"

    # 5. Direct-Endpoint Prewarm
    $prewarmScriptSource = Join-Path $workerDir 'grid_prewarm.mq5'
    if (-not (Test-Path $prewarmScriptSource -PathType Leaf)) { $prewarmScriptSource = Join-Path $payload 'grid_prewarm.mq5' }
    if (-not (Test-Path $prewarmScriptSource -PathType Leaf)) { $prewarmScriptSource = Join-Path $PSScriptRoot 'grid_prewarm.mq5' }
    if (-not (Test-Path $prewarmScriptSource -PathType Leaf)) { Set-Stage 'PREWARM_SOURCE_MISSING'; throw "ERR_PREWARM_SOURCE_MISSING" }

    $scriptsDir = Join-Path $baseMt5 'MQL5\Scripts'
    New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
    Copy-Item -LiteralPath $prewarmScriptSource -Destination (Join-Path $scriptsDir 'grid_prewarm.mq5') -Force

    $logComp = Join-Path $root 'compile.log'
    Start-Process -FilePath $baseEditor -ArgumentList @('/portable', ('/compile:"' + (Join-Path $scriptsDir 'grid_prewarm.mq5') + '"'), ('/log:"' + $logComp + '"')) -Wait | Out-Null
    $prewarmEx5 = Join-Path $scriptsDir 'grid_prewarm.ex5'
    if (-not (Test-Path $prewarmEx5 -PathType Leaf)) { Set-Stage 'PREWARM_COMPILE_FAILED'; throw "ERR_PREWARM_COMPILE_FAILED" }

    $filesDir = Join-Path $baseMt5 'MQL5\Files'
    New-Item -ItemType Directory -Force -Path $filesDir | Out-Null
    $paramContent = "FromDate=$fromDate`nToDate=$toDate`nModel=$model"
    Set-Content -LiteralPath (Join-Path $filesDir 'prewarm_params.txt') -Value $paramContent -Encoding ascii

    $prewarmIni = Join-Path $baseMt5 'prewarm.ini'
    $prewarmIniContent = "$commonSection`n`n[StartUp]`nScript=grid_prewarm`nSymbol=$symbol`nPeriod=$timeframe`nShutdownTerminal=1`n"
    [System.IO.File]::WriteAllText($prewarmIni, $prewarmIniContent, $utf8NoBom)
    Write-Host '[DIAG] PREWARM_INI_ENCODING_OK'

    Write-Host "[DIAG] PREWARM_BEGIN"
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

    $statusFile = Join-Path $filesDir 'grid_prewarm.status'
    if (-not (Test-Path $statusFile -PathType Leaf)) { Set-Stage 'PREWARM_SENTINEL_MISSING'; throw "ERR_PREWARM_SENTINEL_MISSING" }

    $statusContent = Get-Content -LiteralPath $statusFile -Raw
    if ($statusContent -notmatch '(?im)^\s*STATUS\s*=\s*PASS') { Set-Stage 'PREWARM_FAILED'; throw "ERR_PREWARM_FAILED" }

    $m1Bars = if ($statusContent -match '(?im)^\s*M1_BARS\s*=\s*(\d+)') { [int]$matches[1] } else { 0 }
    $targetBars = if ($statusContent -match '(?im)^\s*TARGET_BARS\s*=\s*(\d+)') { [int]$matches[1] } else { 0 }
    if ($m1Bars -le 0 -or $targetBars -le 0) { Set-Stage 'PREWARM_INSUFFICIENT_BARS'; throw "ERR_PREWARM_INSUFFICIENT_BARS" }

    Write-Host "[DIAG] PREWARM_PASS: M1_BARS=$m1Bars, TARGET_BARS=$targetBars"

    # 6. Configure Strategy Tester Optimization
    $expertsDir = Join-Path $baseMt5 'MQL5\Experts'
    New-Item -ItemType Directory -Force -Path $expertsDir | Out-Null
    $workerEx5 = Join-Path $workerDir 'worker.ex5'
    if (-not (Test-Path $workerEx5 -PathType Leaf)) { $workerEx5 = Join-Path $payload 'worker.ex5' }
    if (-not (Test-Path $workerEx5 -PathType Leaf)) { Set-Stage 'EXPERT_MISSING'; throw "ERR_EXPERT_MISSING" }
    Copy-Item -LiteralPath $workerEx5 -Destination (Join-Path $expertsDir 'worker.ex5') -Force

    $profilesTesterDir = Join-Path $baseMt5 'MQL5\Profiles\Tester'
    New-Item -ItemType Directory -Force -Path $profilesTesterDir | Out-Null
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

    # 7. Launch Optimization with High-Fidelity 10-Second Process & Resource Telemetry
    $optStartUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Host "[DIAG] OPTIMIZATION_START_UTC=$optStartUtc"

    $termProc = Start-Process -FilePath $baseTerminal -ArgumentList @('/portable', ('/config:"' + $testerIni + '"')) -WorkingDirectory $baseMt5 -PassThru

    $perfCpu = New-Object System.Diagnostics.PerformanceCounter("Processor", "% Processor Time", "_Total")
    $null = $perfCpu.NextValue()

    $timeoutSec = 6300  # 105 minutes hard watchdog
    $swOpt = [System.Diagnostics.Stopwatch]::StartNew()
    $sampleIntervalSec = 10
    $lastSampleSec = 0

    while (-not $termProc.HasExited) {
        Start-Sleep -Seconds 1
        $elapsedSec = [int]$swOpt.Elapsed.TotalSeconds

        # Hard watchdog check
        if ($elapsedSec -ge $timeoutSec) {
            Stop-Process -Id $termProc.Id -Force -ErrorAction SilentlyContinue
            Get-Process metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Set-Stage 'OPTIMIZATION_TIMEOUT'; throw "ERR_OPTIMIZATION_TIMEOUT"
        }

        # Sample every 10 seconds
        if ($elapsedSec -ge ($lastSampleSec + $sampleIntervalSec)) {
            $lastSampleSec = $elapsedSec
            $nowUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

            # 1. System Resources
            $cpuVal = 0.0
            $freeMemMb = 0.0
            $usedMemMb = 0.0
            $totMemMb = 0.0
            try {
                $cpuVal = [math]::Round($perfCpu.NextValue(), 1)
                $os = Get-CimInstance Win32_OperatingSystem
                $freeMemMb = [math]::Round($os.FreePhysicalMemory / 1024, 1)
                $totMemMb = [math]::Round($os.TotalVisibleMemorySize / 1024, 1)
                $usedMemMb = [math]::Round($totMemMb - $freeMemMb, 1)

                if ($freeMemMb -lt $minFreeRamMb) { $minFreeRamMb = $freeMemMb }
                if ($usedMemMb -gt $peakUsedRamMb) { $peakUsedRamMb = $usedMemMb }
            } catch {}

            # 2. Process Counts & Handles
            $allProcs = @(Get-Process -ErrorAction SilentlyContinue)
            $totProcCount = $allProcs.Count
            $totHandleCount = 0
            foreach ($p in $allProcs) {
                try { $totHandleCount += $p.HandleCount } catch {}
            }
            if ($totProcCount -gt $maxTotalProcesses) { $maxTotalProcesses = $totProcCount }
            if ($totHandleCount -gt $peakTotalHandles) { $peakTotalHandles = $totHandleCount }

            $termProcs = @(Get-Process terminal64 -ErrorAction SilentlyContinue)
            $agentProcs = @(Get-Process metatester64 -ErrorAction SilentlyContinue)

            $simultaneousAgents = $agentProcs.Count
            if ($simultaneousAgents -gt $maxSimultaneousMetatester) {
                $maxSimultaneousMetatester = $simultaneousAgents
            }

            # 3. Agent Process Telemetry (Detailed items for encrypted file only)
            $agentDetails = [System.Collections.Generic.List[object]]::new()
            $currentAgentPids = [System.Collections.Generic.HashSet[int]]::new()

            # Query CIM process details for command line and parent process
            $cimAgents = @{}
            try {
                Get-CimInstance Win32_Process -Filter "Name = 'metatester64.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
                    $cimAgents[$_.ProcessId] = $_
                }
            } catch {}

            foreach ($a in $agentProcs) {
                try {
                    $pidNum = $a.Id
                    $null = $currentAgentPids.Add($pidNum)
                    if ($seenPids.Add($pidNum)) {
                        $pidCreationTimes[$pidNum] = $nowUtc
                    }

                    $parentPid = $null
                    $cmdLine = $null
                    if ($cimAgents.ContainsKey($pidNum)) {
                        $parentPid = $cimAgents[$pidNum].ParentProcessId
                        $cmdLine = $cimAgents[$pidNum].CommandLine
                    }

                    $startTimeStr = $null
                    try { $startTimeStr = $a.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch {}
                    $totProcMs = 0
                    try { $totProcMs = [math]::Round($a.TotalProcessorTime.TotalMilliseconds, 0) } catch {}

                    $agentDetails.Add([PSCustomObject]@{
                        PID = $pidNum
                        ParentProcessId = $parentPid
                        StartTime = $startTimeStr
                        WorkingSet64 = $a.WorkingSet64
                        PrivateMemorySize64 = $a.PrivateMemorySize64
                        HandleCount = $a.HandleCount
                        TotalProcessorTimeMs = $totProcMs
                        CommandLine = $cmdLine
                    })
                } catch {}
            }

            # 4. Check for exited agent PIDs
            foreach ($sp in $seenPids) {
                if (-not $currentAgentPids.Contains($sp)) {
                    # This PID was previously seen and has now exited
                }
            }
            $exitedPidCount = $seenPids.Count - $currentAgentPids.Count

            # 5. Record Telemetry Snapshot
            $snapshot = [PSCustomObject]@{
                timestamp = $nowUtc
                elapsed_sec = $elapsedSec
                cpu_percent = $cpuVal
                free_ram_mb = $freeMemMb
                used_ram_mb = $usedMemMb
                total_ram_mb = $totMemMb
                total_processes = $totProcCount
                total_handles = $totHandleCount
                terminal64_count = $termProcs.Count
                metatester64_count = $simultaneousAgents
                metatester_agents = $agentDetails
            }
            $telemetrySnapshots.Add($snapshot)

            # 6. PUBLIC LOG: COUNTS ONLY (Never print command lines or private data)
            Write-Host "[DIAG] ELAPSED=${elapsedSec}s | TERM_COUNT=$($termProcs.Count) | AGENT_COUNT=$simultaneousAgents | FREE_RAM_MB=$freeMemMb | CPU_PCT=$cpuVal | TOT_PROCS=$totProcCount | TOT_HANDLES=$totHandleCount"

            # 7. Safety Resource Watch (Section 13)
            if ($simultaneousAgents -gt 64 -or $freeMemMb -lt 1500 -or $totProcCount -gt 250) {
                Write-Host "[DIAG] SAFETY_RESOURCE_WATCH_TRIGGERED: Agents=$simultaneousAgents, FreeRAM=$freeMemMb, TotProcs=$totProcCount"
                $resourceExplosionAborted = $true
                Set-Stage 'RESOURCE_EXPLOSION_ABORT' 1

                # Stop terminal and agents immediately to preserve OS health
                Stop-Process -Id $termProc.Id -Force -ErrorAction SilentlyContinue
                Get-Process metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                break
            }
        }
    }

    $optEndUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Host "[DIAG] OPTIMIZATION_END_UTC=$optEndUtc"

    # Stop processes if still running
    Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    # Calculate agent creation rate
    $elapsedMinutes = [math]::Max(1.0, [math]::Round($swOpt.Elapsed.TotalMinutes, 2))
    $createdPerMin = [math]::Round($seenPids.Count / $elapsedMinutes, 2)
    $stillAliveAtEnd = @(Get-Process metatester64 -ErrorAction SilentlyContinue).Count

    # Check passes from report.xml
    $reportXml = Join-Path $baseMt5 'opt_report.xml'
    $completedPasses = 0
    $passCountSource = 'NONE'

    if (Test-Path -LiteralPath $reportXml -PathType Leaf) {
        try {
            $xmlTxt = Get-Content -LiteralPath $reportXml -Raw -Encoding utf8
            $matchRows = [regex]::Matches($xmlTxt, '<Row>\s*<Cell><Data ss:Type="(?:Number|String)">\d+</Data></Cell>')
            if ($matchRows.Count -gt 0) {
                $completedPasses = $matchRows.Count
                $passCountSource = 'REPORT_XML'
                Write-Host "[DIAG] REPORT_XML_DETECTED: COMPLETED_PASS_ROWS=$completedPasses"
            }
        } catch {
            Write-Host "[DIAG] REPORT_XML_PARSE_WARNING: $_"
        }
    }

    if ($completedPasses -eq 0) {
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
    }

    Write-Host "[DIAG] TOTAL_COMPLETED_PASSES=$completedPasses (SOURCE=$passCountSource)"

    # 8. Export Telemetry to Evidence Directory
    $diagSummary = [PSCustomObject]@{
        WORKER_ID = $workerId
        STAGE = $stage
        RESOURCE_EXPLOSION_ABORTED = $resourceExplosionAborted
        EXPECTED_PASSES = 4
        COMPLETED_PASSES = $completedPasses
        PASS_COUNT_SOURCE = $passCountSource
        UNIQUE_METATESTER_PIDS_SEEN = $seenPids.Count
        MAX_SIMULTANEOUS_METATESTER = $maxSimultaneousMetatester
        METATESTER_CREATED_PER_MINUTE = $createdPerMin
        METATESTER_EXITED = $exitedPidCount
        METATESTER_STILL_ALIVE_AT_END = $stillAliveAtEnd
        MAX_TOTAL_PROCESSES = $maxTotalProcesses
        MIN_FREE_RAM_MB = $minFreeRamMb
        PEAK_USED_RAM_MB = $peakUsedRamMb
        PEAK_TOTAL_HANDLES = $peakTotalHandles
        OPTIMIZATION_DURATION_SEC = [math]::Round($swOpt.Elapsed.TotalSeconds, 1)
    }

    $summaryJson = $diagSummary | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText((Join-Path $out 'diagnostic_summary.json'), $summaryJson, $utf8NoBom)

    # Detailed process snapshots (encrypted only)
    $telemetryJson = $telemetrySnapshots | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText((Join-Path $out 'diagnostic_telemetry.json'), $telemetryJson, $utf8NoBom)

    # Copy files to evidence
    Copy-Item -LiteralPath $statusFile -Destination (Join-Path $out 'prewarm_status.txt') -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $reportXml) { Copy-Item -LiteralPath $reportXml -Destination (Join-Path $out 'opt_report.xml') -Force }
    Copy-Item -LiteralPath $workerMetaFile -Destination (Join-Path $out 'meta.json') -Force
    Copy-Item -LiteralPath $testerIni -Destination (Join-Path $out 'tester.ini') -Force -ErrorAction SilentlyContinue

    $testerLogsDir = Join-Path $baseMt5 'Tester\logs'
    if (Test-Path -LiteralPath $testerLogsDir) {
        Copy-Item -LiteralPath $testerLogsDir -Destination (Join-Path $out 'Tester_logs') -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Summary text
    $summaryPath = Join-Path $out 'worker_summary.txt'
    $summaryContent = @"
WORKER_ID=$workerId
EXPECTED_PASSES=4
COMPLETED_PASSES=$completedPasses
PASS_COUNT_SOURCE=$passCountSource
MAX_SIMULTANEOUS_METATESTER=$maxSimultaneousMetatester
UNIQUE_METATESTER_PIDS_SEEN=$($seenPids.Count)
METATESTER_CREATED_PER_MINUTE=$createdPerMin
METATESTER_EXITED=$exitedPidCount
METATESTER_STILL_ALIVE_AT_END=$stillAliveAtEnd
MAX_TOTAL_PROCESSES=$maxTotalProcesses
MIN_FREE_RAM_MB=$minFreeRamMb
PEAK_USED_RAM_MB=$peakUsedRamMb
PEAK_TOTAL_HANDLES=$peakTotalHandles
RESOURCE_EXPLOSION_ABORTED=$resourceExplosionAborted
PREWARM_STATUS=PASS
M1_BARS=$m1Bars
TARGET_BARS=$targetBars
OPTIMIZATION_DURATION_SEC=$([math]::Round($swOpt.Elapsed.TotalSeconds, 1))
"@
    [System.IO.File]::WriteAllText($summaryPath, $summaryContent, $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $out 'canary_summary.txt'), $summaryContent, $utf8NoBom)

    if (-not $resourceExplosionAborted -and $completedPasses -eq 4) {
        Set-Stage 'OK' 0
    } elseif ($resourceExplosionAborted) {
        Set-Stage 'RESOURCE_EXPLOSION_ABORT' 1
    } else {
        Set-Stage 'PASS_COUNT_MISMATCH' 1
    }

    $resultsExported = $true
} catch {
    Write-Host "[DIAG] ERROR: $_"
    if ($stage -eq 'INIT' -or $stage -eq 'OK') {
        Set-Stage 'UNCAUGHT_EXCEPTION' 1
    }
} finally {
    try {
        [System.IO.File]::WriteAllText((Join-Path $out 'stage.txt'), $stage, $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $out 'exit.txt'), $code.ToString(), $utf8NoBom)

        # Encrypt evidence into o.bin (SURVIVES FAILURE)
        $encKey = if (-not [string]::IsNullOrWhiteSpace($key)) { $key } else { $env:GRID_SESSION_KEY }
        if (-not [string]::IsNullOrWhiteSpace($encKey) -and (Test-Path $seven -PathType Leaf)) {
            Push-Location $out
            try {
                & $seven a -t7z $encOut '.\*' "-p$encKey" -mhe=on -mx=5 | Out-Null
                Write-Host "[DIAG] Evidence encrypted to $encOut ($((Get-Item $encOut).Length) bytes)"
            } finally {
                Pop-Location
            }
        }
    } catch {
        Write-Host "[DIAG] Finalization error: $_"
    }

    # Cleanup temp
    Remove-Item Env:GRID_SESSION_KEY -ErrorAction SilentlyContinue
    $key = $null
    Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    Write-Host "[DIAG] NATIVE DIAGNOSTIC NODE FINISHED with stage=$stage code=$code"
    exit $code
}
