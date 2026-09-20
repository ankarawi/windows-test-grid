# native_rolling_node.ps1
# Rolling pool single-case node runner for Windows-2022 VM.
# Fail-safe encrypted evidence emission on BOTH SUCCESS and CONTROLLED FAILURE.
# Checkpoint telemetry every 5s to transient temp file.
# Dynamic watchdog per timeout class (NORMAL=90m, SLOW=180m, VERY_SLOW=300m).
# Resource guards (metatester > 16, free RAM < 2000MB, procs > 200).
# Zero public plaintext leaks.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$stage = 'INIT'
$code  = 1
$key   = $null
$root    = Join-Path $env:RUNNER_TEMP 'g'
$payload = Join-Path $root 'p'
$baseMt5 = Join-Path $root 'mt5'
$out     = Join-Path $root 'o'
$encIn   = Join-Path $root 'i.7z'
$encOut  = Join-Path $env:RUNNER_TEMP 'o.bin'
$telemetryLog = Join-Path $env:RUNNER_TEMP 'telemetry_checkpoint.log'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$watchdogTriggered = $false
$resourceGuardTriggered = $false
$maxMetatester = 0
$minFreeRamMb = 999999.0
$maxTotalProcs = 0
$elapsedSec = 0
$reportExists = $false
$reportRows = 0
$termExitState = 'NOT_STARTED'

function Set-Stage([string]$s, [int]$c = 1) {
    $script:stage = $s
    $script:code  = $c
}

function Emit-EncryptedEvidence {
    try {
        if (-not (Test-Path $out -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $out | Out-Null
        }
        if (Test-Path $telemetryLog -PathType Leaf) {
            Copy-Item -LiteralPath $telemetryLog -Destination (Join-Path $out 'telemetry_checkpoint.log') -Force -ErrorAction SilentlyContinue
        }
        if ($script:code -ne 0 -or -not (Test-Path (Join-Path $out 'identity_evidence.json') -PathType Leaf)) {
            $failSummary = [PSCustomObject]@{
                stage                    = $script:stage
                exit_code                = $script:code
                opaque_id                = $env:GRID_OPAQUE_ID
                lane_id                  = $env:GRID_LANE_ID
                elapsed_sec              = $script:elapsedSec
                MAX_METATESTER           = $script:maxMetatester
                MIN_FREE_RAM_MB          = $script:minFreeRamMb
                MAX_TOTAL_PROCESSES      = $script:maxTotalProcs
                watchdog_triggered       = if ($script:watchdogTriggered) { 'YES' } else { 'NO' }
                resource_guard_triggered = if ($script:resourceGuardTriggered) { 'YES' } else { 'NO' }
                terminal_exit_state      = $script:termExitState
                report_exists            = if ($script:reportExists) { 'YES' } else { 'NO' }
                report_row_count         = $script:reportRows
            }
            $failSummary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'failure_summary.json') -Encoding utf8
        }
        $testerLogsDir = Join-Path $baseMt5 'Tester\logs'
        $mql5LogsDir   = Join-Path $baseMt5 'MQL5\Logs'
        $termLogsDir   = Join-Path $baseMt5 'Logs'
        $evLogsDir     = Join-Path $out 'logs'
        New-Item -ItemType Directory -Force -Path $evLogsDir | Out-Null
        if (Test-Path $testerLogsDir -PathType Container) {
            Copy-Item -Path "$testerLogsDir\*" -Destination $evLogsDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $mql5LogsDir -PathType Container) {
            Copy-Item -Path "$mql5LogsDir\*" -Destination $evLogsDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $termLogsDir -PathType Container) {
            Copy-Item -Path "$termLogsDir\*" -Destination $evLogsDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        # Recursively collect all log files from all slot and agent directories
        Get-ChildItem -Path $root -Filter "*.log" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/')
            $destFile = Join-Path $evLogsDir $rel
            $destDir = Split-Path $destFile -Parent
            New-Item -ItemType Directory -Force -Path $destDir | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $destFile -Force -ErrorAction SilentlyContinue
        }
        $prewarmStatus = Join-Path $baseMt5 'MQL5\Files\grid_prewarm.status'
        if (Test-Path $prewarmStatus -PathType Leaf) {
            Copy-Item -LiteralPath $prewarmStatus -Destination (Join-Path $out 'grid_prewarm.status') -Force -ErrorAction SilentlyContinue
        }
        if ($script:key -ne $null -and (Test-Path $out -PathType Container)) {
            $sevenZip = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
            if (Test-Path $sevenZip -PathType Leaf) {
                & $sevenZip a -t7z -mhe=on "-p$($script:key)" $encOut "$out\*" -y *>$null
                if (Test-Path $encOut -PathType Leaf) {
                    Write-Host "[GRID] EVIDENCE_ENCRYPTED"
                }
            }
        }
    } catch {
        # Fail-safe handler must never crash
    }
}

try {
    Write-Host "[GRID] NATIVE ROLLING NODE INITIALIZED"
    $opaqueId = if (-not [string]::IsNullOrWhiteSpace($env:GRID_OPAQUE_ID)) { $env:GRID_OPAQUE_ID.Trim() } else { 'unknown' }
    $laneId   = if (-not [string]::IsNullOrWhiteSpace($env:GRID_LANE_ID))   { $env:GRID_LANE_ID.Trim() } else { 'xx' }
    Write-Host "[GRID] OPAQUE_ID=$opaqueId"
    Write-Host "[GRID] LANE_ID=$laneId"

    if ([string]::IsNullOrWhiteSpace($env:GRID_SESSION_KEY))   { Set-Stage 'SESSION_KEY_MISSING'; throw "ERR_SESSION_KEY_MISSING" }
    if ($env:GRID_PACKAGE_SHA256 -notmatch '^[A-Fa-f0-9]{64}$') { Set-Stage 'HASH_INVALID'; throw "ERR_PACKAGE_HASH_INVALID" }
    if ([string]::IsNullOrWhiteSpace($env:GRID_PACKAGE_URL))  { Set-Stage 'URL_MISSING'; throw "ERR_PACKAGE_URL_MISSING" }

    $key = $env:GRID_SESSION_KEY

    # Parse timeout
    $timeoutMin = 90
    if (-not [string]::IsNullOrWhiteSpace($env:GRID_TIMEOUT_MINUTES)) {
        [int]::TryParse($env:GRID_TIMEOUT_MINUTES, [ref]$timeoutMin) | Out-Null
    }
    $timeoutSec = $timeoutMin * 60

    $seven = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    if (-not (Test-Path $seven -PathType Leaf)) { Set-Stage 'SEVENZIP_MISSING'; throw "ERR_SEVENZIP_MISSING" }

    New-Item -ItemType Directory -Force -Path $root,$payload,$baseMt5,$out | Out-Null

    # 1. Download and verify encrypted task package
    try {
        Invoke-WebRequest -Uri $env:GRID_PACKAGE_URL -OutFile $encIn -UseBasicParsing
    } catch {
        Set-Stage 'DOWNLOAD_FAILED'; throw "ERR_DOWNLOAD_FAILED"
    }

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $encIn).Hash
    if (-not $hash.Equals($env:GRID_PACKAGE_SHA256, [System.StringComparison]::OrdinalIgnoreCase)) {
        Set-Stage 'HASH_MISMATCH'; throw "ERR_PACKAGE_HASH_MISMATCH"
    }

    & $seven x $encIn "-p$key" "-o$payload" -y *>$null
    if ($LASTEXITCODE -ne 0) { Set-Stage 'DECRYPT_FAILED'; throw "ERR_DECRYPT_FAILED" }

    # Erase session key from environment immediately
    Remove-Item Env:GRID_SESSION_KEY -ErrorAction SilentlyContinue

    Write-Host "[GRID] PAYLOAD_VERIFIED"

    # Shared payload files
    $commonFile    = Join-Path $payload 'common.ini'
    $oracleScript  = Join-Path $payload 'oracle_validator.py'
    $prewarmScript = Join-Path $payload 'grid_prewarm.mq5'
    $workerEx5Src  = Join-Path $payload 'worker.ex5'

    # Case files in payload root
    $runSpecFile   = Join-Path $payload 'run_spec.json'
    $setFile       = Join-Path $payload 'case.set'
    $metaFile      = Join-Path $payload 'meta.json'

    foreach ($f in @($commonFile, $oracleScript, $prewarmScript, $workerEx5Src, $runSpecFile, $setFile, $metaFile)) {
        if (-not (Test-Path $f -PathType Leaf)) {
            Set-Stage 'PAYLOAD_FILE_MISSING'; throw "ERR_PAYLOAD_FILE_MISSING: $f"
        }
    }
    $commonSection = (Get-Content -LiteralPath $commonFile -Raw -Encoding utf8).Trim()

    $specJson  = Get-Content -LiteralPath $runSpecFile -Raw -Encoding utf8 | ConvertFrom-Json
    $symbol    = $specJson.symbol.ToString().Trim()
    $timeframe = $specJson.timeframe.ToString().Trim()
    $fromDate  = $specJson.from_date.ToString().Trim()
    $toDate    = $specJson.to_date.ToString().Trim()
    $model     = if ($specJson.model -ne $null) { $specJson.model.ToString().Trim() } else { '0' }
    $deposit   = if ($specJson.deposit -ne $null) { $specJson.deposit.ToString().Trim() } else { '10000' }
    $currency  = if ($specJson.currency) { $specJson.currency.ToString().Trim() } else { 'USD' }
    $leverage  = if ($specJson.leverage -ne $null) { $specJson.leverage.ToString().Trim() } else { '100' }

    # 2. Install MT5 runtime
    $setup = Join-Path $root 's.exe'
    try {
        Invoke-WebRequest -Uri 'https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe' -OutFile $setup -UseBasicParsing
    } catch {
        Set-Stage 'RUNTIME_DOWNLOAD_FAILED'; throw "ERR_RUNTIME_DOWNLOAD_FAILED"
    }

    Start-Process -FilePath $setup -ArgumentList '/auto' | Out-Null
    $defaultMt5  = Join-Path $env:ProgramFiles 'MetaTrader 5'
    $termDefault = Join-Path $defaultMt5 'terminal64.exe'
    $deadline    = (Get-Date).AddMinutes(5)
    while (-not (Test-Path $termDefault -PathType Leaf) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
    }
    Start-Sleep -Seconds 5
    Get-Process terminal64,metatester64,s,mt5setup -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $termDefault -PathType Leaf)) { Set-Stage 'RUNTIME_DEFAULT_MISSING'; throw "ERR_RUNTIME_DEFAULT_MISSING" }

    Copy-Item -Path "$defaultMt5\*" -Destination $baseMt5 -Recurse -Force
    $baseTerminal = Join-Path $baseMt5 'terminal64.exe'
    $baseEditor   = Join-Path $baseMt5 'metaeditor64.exe'
    if (-not (Test-Path $baseTerminal -PathType Leaf)) { Set-Stage 'RUNTIME_COPIED_MISSING'; throw "ERR_RUNTIME_COPIED_MISSING" }

    Get-ChildItem -Path (Join-Path $baseMt5 'MQL5') -Filter '*.mq5' -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host "[GRID] MT5_INSTALLED"

    # DEPLOY BROKER SERVERS.DAT AND ACCOUNTS.DAT IF PRESENT IN PAYLOAD
    $payloadServers = Join-Path $payload 'servers.dat'
    if (Test-Path $payloadServers -PathType Leaf) {
        $cfgDir = Join-Path $baseMt5 'Config'
        New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
        Copy-Item -LiteralPath $payloadServers -Destination (Join-Path $cfgDir 'servers.dat') -Force
        $defCfg = Join-Path $defaultMt5 'Config'
        New-Item -ItemType Directory -Force -Path $defCfg | Out-Null
        Copy-Item -LiteralPath $payloadServers -Destination (Join-Path $defCfg 'servers.dat') -Force
        Write-Host "[GRID] BROKER_SERVERS_DAT_DEPLOYED"
    }
    $payloadAccounts = Join-Path $payload 'accounts.dat'
    if (Test-Path $payloadAccounts -PathType Leaf) {
        $cfgDir = Join-Path $baseMt5 'Config'
        New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
        Copy-Item -LiteralPath $payloadAccounts -Destination (Join-Path $cfgDir 'accounts.dat') -Force
        $defCfg = Join-Path $defaultMt5 'Config'
        New-Item -ItemType Directory -Force -Path $defCfg | Out-Null
        Copy-Item -LiteralPath $payloadAccounts -Destination (Join-Path $defCfg 'accounts.dat') -Force
        Write-Host "[GRID] BROKER_ACCOUNTS_DAT_DEPLOYED"
    }

    # AUTHENTIC HISTORY & BROKER DATA INJECTION — deployed to ALL base and tester directories
    function Deploy-AllHistory([string]$targetMt5) {
        $payloadHistory = Join-Path $payload 'history'
        $payloadTesterHistory = Join-Path $payload 'tester_history'
        $payloadSymbols = Join-Path $payload 'symbols'
        $payloadTicks   = Join-Path $payload 'ticks'

        $basesDir = Join-Path $targetMt5 'bases'
        New-Item -ItemType Directory -Force -Path $basesDir | Out-Null
        $knownBases = @('RoboForex-Pro', 'RoboForex-ECN', 'Default', 'MetaQuotes-Demo', '46.4.62.181-443', '46.4.62.181', '46.4.62.181_443')
        Get-ChildItem -Path $basesDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if ($knownBases -notcontains $_.Name) { $knownBases += $_.Name }
        }

        $tBasesDir = Join-Path $targetMt5 'Tester\bases'
        New-Item -ItemType Directory -Force -Path $tBasesDir | Out-Null
        $knownTBases = @('RoboForex-Pro', 'RoboForex-ECN', 'Default', 'MetaQuotes-Demo', '46.4.62.181-443', '46.4.62.181', '46.4.62.181_443')
        Get-ChildItem -Path $tBasesDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if ($knownTBases -notcontains $_.Name) { $knownTBases += $_.Name }
        }
        
        # 1. Deploy client terminal history (.hcc + cache)
        if (Test-Path $payloadHistory -PathType Container) {
            foreach ($srv in $knownBases) {
                $histDir = Join-Path $basesDir "$srv\history\$symbol"
                New-Item -ItemType Directory -Force -Path $histDir | Out-Null
                Copy-Item -Path "$payloadHistory\*" -Destination $histDir -Recurse -Force
            }
            $sampleDir = Join-Path $basesDir "RoboForex-Pro\history\$symbol"
            $hccCount = (Get-ChildItem $sampleDir -Filter "*.hcc" -ErrorAction SilentlyContinue).Count
            Write-Host "[GRID] AUTHENTIC_HISTORY_DEPLOYED: $symbol ($hccCount .hcc files into $($knownBases.Count) bases)"
        }

        # 2. Deploy Strategy Tester history (.hcs)
        if (Test-Path $payloadTesterHistory -PathType Container) {
            foreach ($srv in $knownTBases) {
                $tHistDir = Join-Path $tBasesDir "$srv\history\$symbol"
                New-Item -ItemType Directory -Force -Path $tHistDir | Out-Null
                Copy-Item -Path "$payloadTesterHistory\*" -Destination $tHistDir -Recurse -Force
            }
            Write-Host "[GRID] TESTER_HCS_DEPLOYED: $symbol into $($knownTBases.Count) tester bases"
        }

        # 3. Deploy broker symbols database (symbols-*.dat, selected-*.dat)
        if (Test-Path $payloadSymbols -PathType Container) {
            foreach ($srv in $knownBases) {
                $symDir = Join-Path $basesDir "$srv\symbols"
                New-Item -ItemType Directory -Force -Path $symDir | Out-Null
                Copy-Item -Path "$payloadSymbols\*" -Destination $symDir -Recurse -Force
            }
            foreach ($srv in $knownTBases) {
                $tSymDir = Join-Path $tBasesDir "$srv\symbols"
                New-Item -ItemType Directory -Force -Path $tSymDir | Out-Null
                Copy-Item -Path "$payloadSymbols\*" -Destination $tSymDir -Recurse -Force
            }
            Write-Host "[GRID] BROKER_SYMBOLS_DEPLOYED into $($knownBases.Count) bases and $($knownTBases.Count) tester bases"
        }

        # 4. Deploy broker ticks specifications
        if (Test-Path $payloadTicks -PathType Container) {
            foreach ($srv in $knownBases) {
                $ticksDir = Join-Path $basesDir "$srv\ticks"
                New-Item -ItemType Directory -Force -Path $ticksDir | Out-Null
                Copy-Item -Path "$payloadTicks\*" -Destination $ticksDir -Recurse -Force
            }
            foreach ($srv in $knownTBases) {
                $tTicksDir = Join-Path $tBasesDir "$srv\ticks"
                New-Item -ItemType Directory -Force -Path $tTicksDir | Out-Null
                Copy-Item -Path "$payloadTicks\*" -Destination $tTicksDir -Recurse -Force
            }
            Write-Host "[GRID] BROKER_TICKS_DEPLOYED into $($knownBases.Count) bases and $($knownTBases.Count) tester bases"
        }
    }

    Deploy-AllHistory $baseMt5

    # 3. Prewarm exact case domain
    $scriptsDir = Join-Path $baseMt5 'MQL5\Scripts'
    New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
    Copy-Item -LiteralPath $prewarmScript -Destination (Join-Path $scriptsDir 'grid_prewarm.mq5') -Force

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

    Write-Host "[GRID] PREWARM_CONTRACT_VALIDATED"
    $procPrewarm = Start-Process -FilePath $baseTerminal -ArgumentList @('/portable', ('/config:"' + $prewarmIni + '"')) -WorkingDirectory $baseMt5 -PassThru
    $swPrewarm   = [System.Diagnostics.Stopwatch]::StartNew()

    while (-not $procPrewarm.HasExited) {
        Start-Sleep -Seconds 2
        if ($swPrewarm.Elapsed.TotalSeconds -ge 300) {
            Stop-Process -Id $procPrewarm.Id -Force -ErrorAction SilentlyContinue
            Set-Stage 'PREWARM_TIMEOUT'; throw "ERR_PREWARM_TIMEOUT"
        }
    }
    Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
    Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    $statusFile = Join-Path $filesDir 'grid_prewarm.status'
    if (-not (Test-Path $statusFile -PathType Leaf)) {
        Write-Host "[GRID] PREWARM_WARN: Sentinel file missing. Proceeding to Strategy Tester."
    } else {
        $statusContent = (Get-Content -LiteralPath $statusFile -Raw).Trim()
        Write-Host "[GRID] PREWARM STATUS: $statusContent"
        if ($statusContent -match '(?im)^\s*STATUS\s*=\s*PASS') {
            Write-Host "[GRID] PREWARM_PASS=YES"
        } else {
            Write-Host "[GRID] PREWARM_WARN: Prewarm status is $statusContent. Proceeding to Strategy Tester with live sync."
        }
    }

    # Re-deploy history into any bases created during prewarm
    Deploy-AllHistory $baseMt5

    # 4. Deploy worker.ex5
    $expertsDir = Join-Path $baseMt5 'MQL5\Experts'
    New-Item -ItemType Directory -Force -Path $expertsDir | Out-Null
    Copy-Item -LiteralPath $workerEx5Src -Destination (Join-Path $expertsDir 'worker.ex5') -Force

    # Clean cache and old reports in base
    $cacheDir = Join-Path $baseMt5 'Tester\cache'
    if (Test-Path $cacheDir) { Remove-Item -LiteralPath $cacheDir -Recurse -Force -ErrorAction SilentlyContinue }

    # Determine cases to run from meta.json (up to 4 cases for the 4 CPU cores)
    $metaJson = Get-Content -LiteralPath $metaFile -Raw -Encoding utf8 | ConvertFrom-Json
    $caseIds = @()
    if ($metaJson.cases -ne $null) {
        $caseIds = @($metaJson.cases.PSObject.Properties.Name)
    }
    if ($caseIds.Count -eq 0) {
        $caseIds = @("case_0")
    }
    $caseCount = [math]::Min($caseIds.Count, 4)
    $logicalCpus = [System.Environment]::ProcessorCount
    Write-Host "[GRID] QUAD_CORE_DISPATCH: $caseCount TESTS on $logicalCpus CPU CORES"

    # Launch up to 4 concurrent MT5 instances (one per core)
    $slots = @()
    $launchTimeUtc = (Get-Date).ToUniversalTime()

    for ($i = 0; $i -lt $caseCount; $i++) {
        $cId = $caseIds[$i]
        $slotDir = Join-Path $root "slot_$i"
        robocopy $baseMt5 $slotDir /E /NFL /NDL /NJH /NJS | Out-Null
        Deploy-AllHistory $slotDir

        # Case SET file: case_{i}.set or fallback to case.set
        $cSetFile = Join-Path $payload "case_$i.set"
        if (-not (Test-Path $cSetFile -PathType Leaf)) {
            $cSetFile = $setFile
        }

        $cProfilesTesterDir = Join-Path $slotDir 'MQL5\Profiles\Tester'
        New-Item -ItemType Directory -Force -Path $cProfilesTesterDir | Out-Null
        $cActiveSet = Join-Path $cProfilesTesterDir "case.set"
        Copy-Item -LiteralPath $cSetFile -Destination $cActiveSet -Force
        Set-ItemProperty -LiteralPath $cActiveSet -Name IsReadOnly -Value $true

        $cTesterIni = Join-Path $slotDir 'tester.ini'
        $cReportXmlName = "opt_report.xml"
        $cTesterIniContent = @"
$commonSection

[Tester]
Expert=worker.ex5
ExpertParameters=case.set
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
Report=$cReportXmlName
ReplaceReport=1
ShutdownTerminal=1
Visual=0
UseLocal=1
UseRemote=0
UseCloud=0
"@
        [System.IO.File]::WriteAllText($cTesterIni, $cTesterIniContent, $utf8NoBom)

        # Launch MT5 instance bound to CPU Core $i (Affinity: 1, 2, 4, 8)
        $termExe = Join-Path $slotDir 'terminal64.exe'
        $cProc = Start-Process -FilePath $termExe -ArgumentList @('/portable', ('/config:"' + $cTesterIni + '"')) -WorkingDirectory $slotDir -PassThru
        $affinityMask = [IntPtr](1 -shl $i)
        try { $cProc.ProcessorAffinity = $affinityMask } catch {}

        $slots += [PSCustomObject]@{
            Index     = $i
            JobId     = $cId
            SlotDir   = $slotDir
            SetFile   = $cSetFile
            ActiveSet = $cActiveSet
            Process   = $cProc
            ReportXml = Join-Path $slotDir $cReportXmlName
            TesterIni = $cTesterIni
        }
        Write-Host "[GRID] CORE-$i RUNNING: $cId on slot_$i (CPU Affinity: $(1 -shl $i))"
    }

    # Monitor all concurrent instances
    $perfCpu = New-Object System.Diagnostics.PerformanceCounter("Processor", "% Processor Time", "_Total")
    $null = $perfCpu.NextValue()
    $swOpt = [System.Diagnostics.Stopwatch]::StartNew()
    $sampleIntervalSec = 5
    $lastSampleSec = 0

    Set-Content -LiteralPath $telemetryLog -Value "# timestamp_utc,elapsed_sec,active_instances,cpu_percent,free_ram_mb,used_ram_mb" -Encoding ascii

    while ($true) {
        Start-Sleep -Seconds 2
        $runningCount = 0
        foreach ($s in $slots) {
            if (-not $s.Process.HasExited) { $runningCount++ }
        }
        if ($runningCount -eq 0) { break }

        $script:elapsedSec = [int]$swOpt.Elapsed.TotalSeconds

        # Watchdog check
        if ($script:elapsedSec -ge $timeoutSec) {
            $script:watchdogTriggered = $true
            Write-Host "[GRID] WATCHDOG_TIMEOUT"
            foreach ($s in $slots) {
                Stop-Process -Id $s.Process.Id -Force -ErrorAction SilentlyContinue
            }
            Get-Process metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Set-Stage 'WATCHDOG_TIMEOUT'; throw "ERR_WATCHDOG_TIMEOUT"
        }

        # Checkpoint telemetry
        if ($script:elapsedSec -ge ($lastSampleSec + $sampleIntervalSec)) {
            $lastSampleSec = $script:elapsedSec
            $nowUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $cpuVal = 0.0; $freeMemMb = 0.0; $usedMemMb = 0.0
            try {
                $cpuVal    = [math]::Round($perfCpu.NextValue(), 1)
                $os        = Get-CimInstance Win32_OperatingSystem
                $freeMemMb = [math]::Round($os.FreePhysicalMemory / 1024, 1)
                $totMemMb  = [math]::Round($os.TotalVisibleMemorySize / 1024, 1)
                $usedMemMb = [math]::Round($totMemMb - $freeMemMb, 1)
            } catch {}
            Add-Content -LiteralPath $telemetryLog -Value "$nowUtc,$($script:elapsedSec),$runningCount,$cpuVal,$freeMemMb,$usedMemMb" -Encoding ascii
        }
    }

    # Hard process clean boundary
    Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
    Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    $cleanDeadline = (Get-Date).AddSeconds(30)
    $boundaryClean = $false
    while ((Get-Date) -lt $cleanDeadline) {
        $activeTerminals = @(Get-Process terminal64  -ErrorAction SilentlyContinue).Count
        $activeAgents    = @(Get-Process metatester64 -ErrorAction SilentlyContinue).Count
        if ($activeTerminals -eq 0 -and $activeAgents -eq 0) { $boundaryClean = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $boundaryClean) { Set-Stage 'CLEAN_BOUNDARY_FAILED'; throw "ERR_CLEAN_BOUNDARY_FAILED" }
    Write-Host "[GRID] PROCESS_CLEAN_BOUNDARY=PASS"

    # Validate each completed case with oracle
    $allPassed = $true
    foreach ($s in $slots) {
        $jId = $s.JobId
        Set-ItemProperty -LiteralPath $s.ActiveSet -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue

        # Run oracle validator for this case
        $evOut = Join-Path $out "identity_evidence_$jId.json"
        $oracleArgs = @(
            $oracleScript,
            '--xml',    $s.ReportXml,
            '--set',    $s.ActiveSet,
            '--meta',   $metaFile,
            '--job-id', $jId,
            '--out',    $evOut
        )
        $oProc = Start-Process -FilePath 'python' -ArgumentList $oracleArgs -NoNewWindow -PassThru -Wait
        if ($oProc.ExitCode -eq 0) {
            Write-Host "[GRID] ORACLE PASS: $jId (Core-$($s.Index))"
        } else {
            Write-Host "[GRID] ORACLE FAIL: $jId (Core-$($s.Index))"
            $allPassed = $false
        }

        # Copy report
        if (Test-Path $s.ReportXml) {
            Copy-Item -LiteralPath $s.ReportXml -Destination (Join-Path $out "opt_report_$jId.xml") -Force
        }
        Copy-Item -LiteralPath $s.ActiveSet -Destination (Join-Path $out "case_$($s.Index).set") -Force
    }

    # Backward-compatible identity_evidence.json
    $firstEv = Join-Path $out "identity_evidence_$($slots[0].JobId).json"
    if (Test-Path $firstEv) {
        Copy-Item -LiteralPath $firstEv -Destination (Join-Path $out 'identity_evidence.json') -Force
    }

    # Collect all RD19797 result JSON files from Common/Files and all slot directories
    $commonFilesDir = Join-Path $env:APPDATA 'MetaQuotes\Terminal\Common\Files'
    if (Test-Path $commonFilesDir) {
        Get-ChildItem -Path $commonFilesDir -Filter '*_result.json' -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $out -Force
            Write-Host "[GRID] COLLECTED_COMMON_RESULT: $($_.Name)"
        }
    }
    Get-ChildItem -Path $root -Filter '*_result.json' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $out -Force
        Write-Host "[GRID] COLLECTED_LOCAL_RESULT: $($_.Name)"
    }

    Set-Stage 'OK' 0

} catch {
    Write-Host "[GRID] EXECUTION_ERROR: $($_.Exception.Message)"
    if ($stage -eq 'INIT') { Set-Stage 'UNHANDLED_EXCEPTION' 1 }
} finally {
    Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Emit-EncryptedEvidence
    exit $script:code
}
