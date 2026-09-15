# native_sequential_node.ps1
# Sequential four-case execution runner on a single VM.
# Hard process boundaries between cases, 5-second telemetry sampling,
# true observed execution identity oracle, zero public plaintext leaks.

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

try {
    Write-Host "[GRID] NATIVE SEQUENTIAL NODE INITIALIZED"

    if ([string]::IsNullOrWhiteSpace($env:GRID_SESSION_KEY)) { Set-Stage 'SESSION_KEY_MISSING'; throw "ERR_SESSION_KEY_MISSING" }
    if ($env:GRID_PACKAGE_SHA256 -notmatch '^[A-Fa-f0-9]{64}$') { Set-Stage 'HASH_INVALID'; throw "ERR_PACKAGE_HASH_INVALID" }
    if ([string]::IsNullOrWhiteSpace($env:GRID_PACKAGE_URL)) { Set-Stage 'URL_MISSING'; throw "ERR_PACKAGE_URL_MISSING" }

    $key = $env:GRID_SESSION_KEY
    $opaqueId = if (-not [string]::IsNullOrWhiteSpace($env:GRID_OPAQUE_ID)) { $env:GRID_OPAQUE_ID.Trim() } else { 'unknown' }

    Write-Host "[GRID] RUNNER_CONFIG: OPAQUE_ID=$opaqueId"

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

    # Erase session key from environment immediately after extraction
    Remove-Item Env:GRID_SESSION_KEY -ErrorAction SilentlyContinue

    Write-Host "[GRID] PAYLOAD_VERIFIED"

    # Verify shared files
    $commonFile = Join-Path $payload 'common.ini'
    if (-not (Test-Path $commonFile -PathType Leaf)) { Set-Stage 'COMMON_CONFIG_MISSING'; throw "ERR_COMMON_CONFIG_MISSING" }
    $commonSection = (Get-Content -LiteralPath $commonFile -Raw -Encoding utf8).Trim()

    $oracleScript = Join-Path $payload 'oracle_validator.py'
    if (-not (Test-Path $oracleScript -PathType Leaf)) { Set-Stage 'ORACLE_SCRIPT_MISSING'; throw "ERR_ORACLE_SCRIPT_MISSING" }

    # 3. Install MT5 Runtime once
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

    if (-not (Test-Path $termDefault -PathType Leaf)) { Set-Stage 'RUNTIME_DEFAULT_MISSING'; throw "ERR_RUNTIME_DEFAULT_MISSING" }

    Copy-Item -Path "$defaultMt5\*" -Destination $baseMt5 -Recurse -Force
    $baseTerminal = Join-Path $baseMt5 'terminal64.exe'
    $baseEditor   = Join-Path $baseMt5 'metaeditor64.exe'
    if (-not (Test-Path $baseTerminal -PathType Leaf)) { Set-Stage 'RUNTIME_COPIED_MISSING'; throw "ERR_RUNTIME_COPIED_MISSING" }

    Get-ChildItem -Path (Join-Path $baseMt5 'MQL5') -Filter '*.mq5' -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Host "[GRID] MT5_INSTALLED"

    # 4. Direct-Endpoint Prewarm once
    $prewarmScriptSource = Join-Path $payload 'grid_prewarm.mq5'
    if (-not (Test-Path $prewarmScriptSource -PathType Leaf)) { $prewarmScriptSource = Join-Path $PSScriptRoot 'grid_prewarm.mq5' }
    if (-not (Test-Path $prewarmScriptSource -PathType Leaf)) { Set-Stage 'PREWARM_SOURCE_MISSING'; throw "ERR_PREWARM_SOURCE_MISSING" }

    $scriptsDir = Join-Path $baseMt5 'MQL5\Scripts'
    New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
    Copy-Item -LiteralPath $prewarmScriptSource -Destination (Join-Path $scriptsDir 'grid_prewarm.mq5') -Force

    $logComp = Join-Path $root 'compile.log'
    Start-Process -FilePath $baseEditor -ArgumentList @('/portable', ('/compile:"' + (Join-Path $scriptsDir 'grid_prewarm.mq5') + '"'), ('/log:"' + $logComp + '"')) -Wait | Out-Null
    $prewarmEx5 = Join-Path $scriptsDir 'grid_prewarm.ex5'
    if (-not (Test-Path $prewarmEx5 -PathType Leaf)) { Set-Stage 'PREWARM_COMPILE_FAILED'; throw "ERR_PREWARM_COMPILE_FAILED" }

    # Prewarm parameters from case-00 run_spec
    $c00SpecFile = Join-Path (Join-Path $payload 'case-00') 'run_spec.json'
    $c00Spec = Get-Content -LiteralPath $c00SpecFile -Raw -Encoding utf8 | ConvertFrom-Json
    $prewarmSymbol    = $c00Spec.symbol.ToString().Trim()
    $prewarmTimeframe = $c00Spec.timeframe.ToString().Trim()
    $prewarmFromDate  = $c00Spec.from_date.ToString().Trim()
    $prewarmToDate    = $c00Spec.to_date.ToString().Trim()
    $prewarmModel     = if ($c00Spec.model -ne $null) { $c00Spec.model.ToString().Trim() } else { '0' }

    $filesDir = Join-Path $baseMt5 'MQL5\Files'
    New-Item -ItemType Directory -Force -Path $filesDir | Out-Null
    $paramContent = "FromDate=$prewarmFromDate`nToDate=$prewarmToDate`nModel=$prewarmModel"
    Set-Content -LiteralPath (Join-Path $filesDir 'prewarm_params.txt') -Value $paramContent -Encoding ascii

    $prewarmIni = Join-Path $baseMt5 'prewarm.ini'
    $prewarmIniContent = "$commonSection`n`n[StartUp]`nScript=grid_prewarm`nSymbol=$prewarmSymbol`nPeriod=$prewarmTimeframe`nShutdownTerminal=1`n"
    [System.IO.File]::WriteAllText($prewarmIni, $prewarmIniContent, $utf8NoBom)

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

    $statusFile = Join-Path $filesDir 'grid_prewarm.status'
    if (-not (Test-Path $statusFile -PathType Leaf)) { Set-Stage 'PREWARM_SENTINEL_MISSING'; throw "ERR_PREWARM_SENTINEL_MISSING" }

    $statusContent = Get-Content -LiteralPath $statusFile -Raw
    if ($statusContent -notmatch '(?im)^\s*STATUS\s*=\s*PASS') { Set-Stage 'PREWARM_FAILED'; throw "ERR_PREWARM_FAILED" }
    Write-Host "[GRID] PREWARM_PASS=YES"

    # Copy worker.ex5 to MQL5\Experts once
    $expertsDir = Join-Path $baseMt5 'MQL5\Experts'
    New-Item -ItemType Directory -Force -Path $expertsDir | Out-Null
    $workerEx5 = Join-Path $payload 'worker.ex5'
    if (-not (Test-Path $workerEx5 -PathType Leaf)) { Set-Stage 'EXPERT_MISSING'; throw "ERR_EXPERT_MISSING" }
    Copy-Item -LiteralPath $workerEx5 -Destination (Join-Path $expertsDir 'worker.ex5') -Force

    $profilesTesterDir = Join-Path $baseMt5 'MQL5\Profiles\Tester'
    New-Item -ItemType Directory -Force -Path $profilesTesterDir | Out-Null

    # 5. Sequential Execution of the 4 Cases
    $caseSlots = @('case-00', 'case-01', 'case-02', 'case-03')
    $caseResults = @{}

    foreach ($slot in $caseSlots) {
        Write-Host "[GRID] STARTING_CASE_EXECUTION: SLOT=$slot"

        $caseDir = Join-Path $payload $slot
        if (-not (Test-Path $caseDir -PathType Container)) {
            Set-Stage 'CASE_DIR_MISSING'; throw "ERR_CASE_DIR_MISSING_$slot"
        }

        $runSpecFile = Join-Path $caseDir 'run_spec.json'
        $workerSet   = Join-Path $caseDir 'worker.set'
        $metaFile    = Join-Path $caseDir 'meta.json'

        if (-not (Test-Path $runSpecFile -PathType Leaf)) { Set-Stage 'RUN_SPEC_MISSING'; throw "ERR_RUN_SPEC_MISSING_$slot" }
        if (-not (Test-Path $workerSet -PathType Leaf))   { Set-Stage 'WORKER_SET_MISSING'; throw "ERR_WORKER_SET_MISSING_$slot" }
        if (-not (Test-Path $metaFile -PathType Leaf))     { Set-Stage 'META_FILE_MISSING'; throw "ERR_META_FILE_MISSING_$slot" }

        # Parse run_spec
        $specJson  = Get-Content -LiteralPath $runSpecFile -Raw -Encoding utf8 | ConvertFrom-Json
        $symbol    = $specJson.symbol.ToString().Trim()
        $timeframe = $specJson.timeframe.ToString().Trim()
        $fromDate  = $specJson.from_date.ToString().Trim()
        $toDate    = $specJson.to_date.ToString().Trim()
        $model     = if ($specJson.model -ne $null) { $specJson.model.ToString().Trim() } else { '0' }
        $deposit   = if ($specJson.deposit -ne $null) { $specJson.deposit.ToString().Trim() } else { '10000' }
        $currency  = if ($specJson.currency) { $specJson.currency.ToString().Trim() } else { 'USD' }
        $leverage  = if ($specJson.leverage -ne $null) { $specJson.leverage.ToString().Trim() } else { '100' }

        # Deploy worker.set for this case
        $activeWorkerSet = Join-Path $profilesTesterDir 'worker.set'
        Copy-Item -LiteralPath $workerSet -Destination $activeWorkerSet -Force

        # Clean tester cache and report
        $cacheDir = Join-Path $baseMt5 'Tester\cache'
        if (Test-Path $cacheDir) { Remove-Item -LiteralPath $cacheDir -Recurse -Force -ErrorAction SilentlyContinue }

        $reportXmlName = "opt_report_$slot.xml"
        $reportXmlPath = Join-Path $baseMt5 $reportXmlName
        if (Test-Path $reportXmlPath) { Remove-Item -LiteralPath $reportXmlPath -Force -ErrorAction SilentlyContinue }

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
Report=$reportXmlName
ReplaceReport=1
ShutdownTerminal=1
Visual=0
UseLocal=1
UseRemote=0
UseCloud=0
"@
        [System.IO.File]::WriteAllText($testerIni, $testerIniContent, $utf8NoBom)

        # Launch optimization
        $termProc = Start-Process -FilePath $baseTerminal -ArgumentList @('/portable', ('/config:"' + $testerIni + '"')) -WorkingDirectory $baseMt5 -PassThru

        $perfCpu = New-Object System.Diagnostics.PerformanceCounter("Processor", "% Processor Time", "_Total")
        $null = $perfCpu.NextValue()

        $timeoutSec        = 5400  # 90 minutes hard watchdog
        $swOpt             = [System.Diagnostics.Stopwatch]::StartNew()
        $sampleIntervalSec = 5
        $lastSampleSec     = 0

        $telemetrySnapshots = [System.Collections.Generic.List[object]]::new()
        $maxSimultaneousMetatester = 0
        $maxTotalProcesses = 0
        $minFreeRamMb = 999999.0
        $peakUsedRamMb = 0.0
        $resourceExplosion = $false

        while (-not $termProc.HasExited) {
            Start-Sleep -Seconds 1
            $elapsedSec = [int]$swOpt.Elapsed.TotalSeconds

            if ($elapsedSec -ge $timeoutSec) {
                Stop-Process -Id $termProc.Id -Force -ErrorAction SilentlyContinue
                Get-Process metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Set-Stage 'WATCHDOG_TIMEOUT'; throw "ERR_WATCHDOG_TIMEOUT_$slot"
            }

            if ($elapsedSec -ge ($lastSampleSec + $sampleIntervalSec)) {
                $lastSampleSec = $elapsedSec
                $nowUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

                $cpuVal    = 0.0
                $freeMemMb = 0.0
                $usedMemMb = 0.0
                $totMemMb  = 0.0
                try {
                    $cpuVal = [math]::Round($perfCpu.NextValue(), 1)
                    $os = Get-CimInstance Win32_OperatingSystem
                    $freeMemMb = [math]::Round($os.FreePhysicalMemory / 1024, 1)
                    $totMemMb  = [math]::Round($os.TotalVisibleMemorySize / 1024, 1)
                    $usedMemMb = [math]::Round($totMemMb - $freeMemMb, 1)
                    if ($freeMemMb -lt $minFreeRamMb) { $minFreeRamMb = $freeMemMb }
                    if ($usedMemMb -gt $peakUsedRamMb) { $peakUsedRamMb = $usedMemMb }
                } catch {}

                $allProcs     = @(Get-Process -ErrorAction SilentlyContinue)
                $totProcCount = $allProcs.Count
                if ($totProcCount -gt $maxTotalProcesses) { $maxTotalProcesses = $totProcCount }

                $agentProcs = @(Get-Process metatester64 -ErrorAction SilentlyContinue)
                if ($agentProcs.Count -gt $maxSimultaneousMetatester) { $maxSimultaneousMetatester = $agentProcs.Count }

                $snap = [PSCustomObject]@{
                    timestamp_utc       = $nowUtc
                    elapsed_sec         = $elapsedSec
                    cpu_percent         = $cpuVal
                    free_ram_mb         = $freeMemMb
                    used_ram_mb         = $usedMemMb
                    total_procs         = $totProcCount
                    metatester_procs    = $agentProcs.Count
                }
                $telemetrySnapshots.Add($snap)

                # Telemetry threshold guard
                if ($agentProcs.Count -gt 16 -or $freeMemMb -lt 2000 -or $totProcCount -gt 200) {
                    Write-Host "[GRID] RESOURCE_THRESHOLD_TRIGGERED"
                    Stop-Process -Id $termProc.Id -Force -ErrorAction SilentlyContinue
                    Get-Process metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                    $resourceExplosion = $true
                    Set-Stage 'RESOURCE_EXPLOSION_ABORT'
                    throw "ERR_RESOURCE_EXPLOSION_$slot"
                }
            }
        }

        # Hard Process Cleanup Boundary
        Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
        Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

        $cleanBoundaryDeadline = (Get-Date).AddSeconds(30)
        $boundaryClean = $false
        while ((Get-Date) -lt $cleanBoundaryDeadline) {
            $activeTerminals = @(Get-Process terminal64 -ErrorAction SilentlyContinue).Count
            $activeAgents    = @(Get-Process metatester64 -ErrorAction SilentlyContinue).Count
            if ($activeTerminals -eq 0 -and $activeAgents -eq 0) {
                $boundaryClean = $true
                break
            }
            Start-Sleep -Seconds 2
        }

        if (-not $boundaryClean) {
            Set-Stage 'CLEAN_BOUNDARY_FAILED'; throw "ERR_CLEAN_BOUNDARY_FAILED_$slot"
        }
        Write-Host "[GRID] PROCESS_CLEAN_BOUNDARY=PASS"

        # Evidence folder for this case
        $caseEvidenceDir = Join-Path $out $slot
        New-Item -ItemType Directory -Force -Path $caseEvidenceDir | Out-Null

        # Save telemetry
        $telemPath = Join-Path $caseEvidenceDir 'telemetry.json'
        $telemetrySnapshots | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $telemPath -Encoding utf8

        # Run True Observed Execution Identity Oracle
        $identityEvidenceFile = Join-Path $caseEvidenceDir 'identity_evidence.json'
        $oracleProc = Start-Process -FilePath 'python' -ArgumentList @(
            $oracleScript,
            '--xml', $reportXmlPath,
            '--set', $activeWorkerSet,
            '--meta', $metaFile,
            '--out', $identityEvidenceFile
        ) -NoNewWindow -PassThru -Wait

        if ($oracleProc.ExitCode -eq 0) {
            Write-Host "[GRID] CASE_CONTRACT_VALIDATED"
            Write-Host "[GRID] EXECUTION_IDENTITY_CHECK=PASS"
        } else {
            Write-Host "[GRID] EXECUTION_IDENTITY_CHECK=FAIL"
            Set-Stage 'IDENTITY_ORACLE_FAILED'
            throw "ERR_IDENTITY_ORACLE_FAILED_$slot"
        }

        # Move report files to case evidence directory
        if (Test-Path $reportXmlPath) {
            Move-Item -LiteralPath $reportXmlPath -Destination (Join-Path $caseEvidenceDir $reportXmlName) -Force
        }
        $reportHtm = $reportXmlPath + ".htm"
        if (Test-Path $reportHtm) {
            Move-Item -LiteralPath $reportHtm -Destination (Join-Path $caseEvidenceDir ($reportXmlName + ".htm")) -Force
        }

        # Copy tester logs
        $testerLogsDir = Join-Path $baseMt5 'Tester\logs'
        $caseLogsDir = Join-Path $caseEvidenceDir 'logs'
        New-Item -ItemType Directory -Force -Path $caseLogsDir | Out-Null
        if (Test-Path $testerLogsDir) {
            Copy-Item -Path "$testerLogsDir\*" -Destination $caseLogsDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        $caseResults[$slot] = 'PASS'
        Write-Host "[GRID] CASE_EXECUTION_PASS: SLOT=$slot"
    }

    # 6. Verify all 4 cases succeeded
    if ($caseResults.Count -ne 4) {
        Set-Stage 'INCOMPLETE_CASES'; throw "ERR_INCOMPLETE_CASES"
    }
    foreach ($slot in $caseSlots) {
        if ($caseResults[$slot] -ne 'PASS') {
            Set-Stage 'CASE_FAILED'; throw "ERR_CASE_FAILED_$slot"
        }
    }

    Write-Host "[GRID] ALL_4_CASES_COMPLETED_SUCCESSFULLY"

    # 7. Encrypt Final Evidence Package
    # Re-obtain key from memory for encryption
    & $seven a -t7z -mhe=on "-p$key" $encOut "$out\*" -y *> $null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $encOut -PathType Leaf)) {
        Set-Stage 'ENCRYPT_EVIDENCE_FAILED'; throw "ERR_ENCRYPT_EVIDENCE_FAILED"
    }

    # Wipe plaintext evidence
    Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "[GRID] EVIDENCE_ENCRYPTED_SUCCESS"
    Set-Stage 'OK' 0

} catch {
    Write-Host "[GRID] EXECUTION_ERROR: $($_.Exception.Message)"
    if ($stage -eq 'INIT') { Set-Stage 'UNHANDLED_EXCEPTION' 1 }
} finally {
    Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    exit $script:code
}
