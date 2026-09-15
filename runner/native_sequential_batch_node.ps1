# native_sequential_batch_node.ps1
# Generic production sequential batch runner.
# Executes 4 slots sequentially on a single Windows-2022 VM.
# Hard process boundaries, per-slot config binding, MT5 execution observation,
# resource guards, watchdog, zero public plaintext leaks.
# Derived from proven sequential canary architecture.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$stage = 'INIT'
$code  = 0
$key   = $null
$root    = Join-Path $env:RUNNER_TEMP 'g'
$payload = Join-Path $root 'p'
$baseMt5 = Join-Path $root 'mt5'
$out     = Join-Path $root 'o'
$encIn   = Join-Path $root 'i.7z'
$encOut  = Join-Path $env:RUNNER_TEMP 'o.bin'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Set-Stage([string]$s, [int]$c = 1) {
    $script:stage = $s
    $script:code  = $c
}

try {
    Write-Host "[GRID] NATIVE SEQUENTIAL BATCH NODE INITIALIZED"
    Write-Host "[GRID] RUNNER_ID=$($env:GRID_RUNNER_ID)"

    if ([string]::IsNullOrWhiteSpace($env:GRID_SESSION_KEY))   { Set-Stage 'SESSION_KEY_MISSING'; throw "ERR_SESSION_KEY_MISSING" }
    if ($env:GRID_PACKAGE_SHA256 -notmatch '^[A-Fa-f0-9]{64}$') { Set-Stage 'HASH_INVALID'; throw "ERR_PACKAGE_HASH_INVALID" }
    if ([string]::IsNullOrWhiteSpace($env:GRID_PACKAGE_URL))  { Set-Stage 'URL_MISSING'; throw "ERR_PACKAGE_URL_MISSING" }

    $key      = $env:GRID_SESSION_KEY
    $opaqueId = if (-not [string]::IsNullOrWhiteSpace($env:GRID_OPAQUE_ID)) { $env:GRID_OPAQUE_ID.Trim() } else { 'unknown' }
    $runnerId = if (-not [string]::IsNullOrWhiteSpace($env:GRID_RUNNER_ID)) { $env:GRID_RUNNER_ID.Trim() } else { 'runner-xx' }

    Write-Host "[GRID] OPAQUE_ID=$opaqueId"

    $seven = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    if (-not (Test-Path $seven -PathType Leaf)) { Set-Stage 'SEVENZIP_MISSING'; throw "ERR_SEVENZIP_MISSING" }

    New-Item -ItemType Directory -Force -Path $root,$payload,$baseMt5,$out | Out-Null

    # ----------------------------------------------------------------
    # 1. Hardware probe
    # ----------------------------------------------------------------
    $cs         = Get-CimInstance Win32_ComputerSystem
    $logicalCpus = [Environment]::ProcessorCount
    $totalRamGb  = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    $drive       = Get-PSDrive -Name C
    $freeDiskGb  = [math]::Round($drive.Free / 1GB, 1)
    Write-Host "[GRID] HARDWARE: CPUS=$logicalCpus RAM_GB=$totalRamGb DISK_GB=$freeDiskGb"

    # ----------------------------------------------------------------
    # 2. Download and verify encrypted payload
    # ----------------------------------------------------------------
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

    & $seven x $encIn "-p$key" "-o$payload" -y *>$null
    if ($LASTEXITCODE -ne 0) { Set-Stage 'DECRYPT_FAILED'; throw "ERR_DECRYPT_FAILED" }

    # Erase session key from environment immediately after extraction
    Remove-Item Env:GRID_SESSION_KEY -ErrorAction SilentlyContinue

    Write-Host "[GRID] PAYLOAD_VERIFIED"

    # Locate required shared payload files
    $commonFile    = Join-Path $payload 'common.ini'
    $oracleScript  = Join-Path $payload 'oracle_validator.py'
    $prewarmScript = Join-Path $payload 'grid_prewarm.mq5'
    $workerEx5Src  = Join-Path $payload 'worker.ex5'

    foreach ($f in @($commonFile, $oracleScript, $prewarmScript, $workerEx5Src)) {
        if (-not (Test-Path $f -PathType Leaf)) {
            Set-Stage 'PAYLOAD_FILE_MISSING'; throw "ERR_PAYLOAD_FILE_MISSING: $f"
        }
    }
    $commonSection = (Get-Content -LiteralPath $commonFile -Raw -Encoding utf8).Trim()

    # ----------------------------------------------------------------
    # 3. Install MT5 runtime once
    # ----------------------------------------------------------------
    Write-Host "[GRID] INSTALL_MT5_BEGIN"
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

    # ----------------------------------------------------------------
    # 4. Prewarm — load history once per runner
    # ----------------------------------------------------------------
    # Load prewarm parameters from slot-00 run_spec
    $slot00SpecFile = Join-Path (Join-Path $payload 'slot-00') 'run_spec.json'
    $slot00Spec     = Get-Content -LiteralPath $slot00SpecFile -Raw -Encoding utf8 | ConvertFrom-Json

    # Validate prewarm contract: all 4 slots must share the same symbol/timeframe/dates/model
    $prewarmSymbol    = $slot00Spec.symbol.ToString().Trim()
    $prewarmTimeframe = $slot00Spec.timeframe.ToString().Trim()
    $prewarmFromDate  = $slot00Spec.from_date.ToString().Trim()
    $prewarmToDate    = $slot00Spec.to_date.ToString().Trim()
    $prewarmModel     = if ($slot00Spec.model -ne $null) { $slot00Spec.model.ToString().Trim() } else { '0' }

    foreach ($slotNum in @('slot-01','slot-02','slot-03')) {
        $sFile = Join-Path (Join-Path $payload $slotNum) 'run_spec.json'
        if (Test-Path $sFile -PathType Leaf) {
            $ss = Get-Content -LiteralPath $sFile -Raw -Encoding utf8 | ConvertFrom-Json
            if ($ss.symbol.ToString().Trim() -ne $prewarmSymbol -or
                $ss.timeframe.ToString().Trim() -ne $prewarmTimeframe -or
                $ss.from_date.ToString().Trim() -ne $prewarmFromDate -or
                $ss.to_date.ToString().Trim() -ne $prewarmToDate) {
                Set-Stage 'PREWARM_CONTRACT_VIOLATION'; throw "ERR_PREWARM_CONTRACT_VIOLATION: $slotNum differs from slot-00"
            }
        }
    }
    Write-Host "[GRID] PREWARM_CONTRACT_VALIDATED"

    $scriptsDir = Join-Path $baseMt5 'MQL5\Scripts'
    New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
    Copy-Item -LiteralPath $prewarmScript -Destination (Join-Path $scriptsDir 'grid_prewarm.mq5') -Force

    $logComp = Join-Path $root 'compile.log'
    Start-Process -FilePath $baseEditor -ArgumentList @('/portable', ('/compile:"' + (Join-Path $scriptsDir 'grid_prewarm.mq5') + '"'), ('/log:"' + $logComp + '"')) -Wait | Out-Null
    $prewarmEx5 = Join-Path $scriptsDir 'grid_prewarm.ex5'
    if (-not (Test-Path $prewarmEx5 -PathType Leaf)) { Set-Stage 'PREWARM_COMPILE_FAILED'; throw "ERR_PREWARM_COMPILE_FAILED" }

    $filesDir = Join-Path $baseMt5 'MQL5\Files'
    New-Item -ItemType Directory -Force -Path $filesDir | Out-Null
    $paramContent = "FromDate=$prewarmFromDate`nToDate=$prewarmToDate`nModel=$prewarmModel"
    Set-Content -LiteralPath (Join-Path $filesDir 'prewarm_params.txt') -Value $paramContent -Encoding ascii

    $prewarmIni = Join-Path $baseMt5 'prewarm.ini'
    $prewarmIniContent = "$commonSection`n`n[StartUp]`nScript=grid_prewarm`nSymbol=$prewarmSymbol`nPeriod=$prewarmTimeframe`nShutdownTerminal=1`n"
    [System.IO.File]::WriteAllText($prewarmIni, $prewarmIniContent, $utf8NoBom)

    Write-Host "[GRID] PREWARM_BEGIN"
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
    if (-not (Test-Path $statusFile -PathType Leaf)) { Set-Stage 'PREWARM_SENTINEL_MISSING'; throw "ERR_PREWARM_SENTINEL_MISSING" }
    $statusContent = Get-Content -LiteralPath $statusFile -Raw
    if ($statusContent -notmatch '(?im)^\s*STATUS\s*=\s*PASS') { Set-Stage 'PREWARM_FAILED'; throw "ERR_PREWARM_FAILED" }
    Write-Host "[GRID] PREWARM_PASS=YES"

    # Deploy worker.ex5 once
    $expertsDir = Join-Path $baseMt5 'MQL5\Experts'
    New-Item -ItemType Directory -Force -Path $expertsDir | Out-Null
    Copy-Item -LiteralPath $workerEx5Src -Destination (Join-Path $expertsDir 'worker.ex5') -Force

    $profilesTesterDir = Join-Path $baseMt5 'MQL5\Profiles\Tester'
    New-Item -ItemType Directory -Force -Path $profilesTesterDir | Out-Null

    # ----------------------------------------------------------------
    # 5. Sequential 4-slot execution
    # ----------------------------------------------------------------
    $slotNames   = @('slot-00', 'slot-01', 'slot-02', 'slot-03')
    $slotResults = @{}

    foreach ($slot in $slotNames) {
        Write-Host "[GRID] STARTING_SLOT: $slot"

        $slotDir = Join-Path $payload $slot
        if (-not (Test-Path $slotDir -PathType Container)) {
            Set-Stage 'SLOT_DIR_MISSING'; throw "ERR_SLOT_DIR_MISSING_$slot"
        }

        $runSpecFile = Join-Path $slotDir 'run_spec.json'
        $setFile     = Join-Path $slotDir "$slot.set"
        $metaFile    = Join-Path $slotDir 'meta.json'

        # Validate all required slot files
        foreach ($f in @($runSpecFile, $setFile, $metaFile)) {
            if (-not (Test-Path $f -PathType Leaf)) {
                Set-Stage 'SLOT_FILE_MISSING'; throw "ERR_SLOT_FILE_MISSING: $f"
            }
        }

        # Parse run spec
        $specJson  = Get-Content -LiteralPath $runSpecFile -Raw -Encoding utf8 | ConvertFrom-Json
        $symbol    = $specJson.symbol.ToString().Trim()
        $timeframe = $specJson.timeframe.ToString().Trim()
        $fromDate  = $specJson.from_date.ToString().Trim()
        $toDate    = $specJson.to_date.ToString().Trim()
        $model     = if ($specJson.model -ne $null) { $specJson.model.ToString().Trim() } else { '0' }
        $deposit   = if ($specJson.deposit -ne $null) { $specJson.deposit.ToString().Trim() } else { '10000' }
        $currency  = if ($specJson.currency) { $specJson.currency.ToString().Trim() } else { 'USD' }
        $leverage  = if ($specJson.leverage -ne $null) { $specJson.leverage.ToString().Trim() } else { '100' }

        # ---- Contract A: Configuration Binding ----
        # Record pre-deployment SET SHA256 (private, written to evidence)
        $setPreSha  = (Get-FileHash -Algorithm SHA256 -LiteralPath $setFile).Hash

        # Deploy case-specific SET to Tester Profiles with unique slot filename
        $activeSetPath = Join-Path $profilesTesterDir "$slot.set"
        Copy-Item -LiteralPath $setFile -Destination $activeSetPath -Force

        # Mark SET read-only during execution
        Set-ItemProperty -LiteralPath $activeSetPath -Name IsReadOnly -Value $true

        # Verify deployed SET SHA matches pre-deployment SHA
        $setDeployedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $activeSetPath).Hash
        if (-not $setPreSha.Equals($setDeployedSha, [System.StringComparison]::OrdinalIgnoreCase)) {
            Set-Stage 'SET_DEPLOY_HASH_MISMATCH'; throw "ERR_SET_DEPLOY_HASH_MISMATCH_$slot"
        }

        # Clean tester cache and old report for this slot
        $cacheDir = Join-Path $baseMt5 'Tester\cache'
        if (Test-Path $cacheDir) { Remove-Item -LiteralPath $cacheDir -Recurse -Force -ErrorAction SilentlyContinue }

        $reportXmlName = "opt_report_$slot.xml"
        $reportXmlPath = Join-Path $baseMt5 $reportXmlName
        if (Test-Path $reportXmlPath) { Remove-Item -LiteralPath $reportXmlPath -Force -ErrorAction SilentlyContinue }

        # Build tester.ini referencing the exact case-specific SET
        $testerIni = Join-Path $baseMt5 'tester.ini'
        $testerIniContent = @"
$commonSection

[Tester]
Expert=worker.ex5
ExpertParameters=$slot.set
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

        # Verify tester.ini references exact slot SET filename
        $iniContent = Get-Content -LiteralPath $testerIni -Raw
        if ($iniContent -notmatch [regex]::Escape("ExpertParameters=$slot.set")) {
            Set-Stage 'TESTER_INI_BINDING_FAILED'; throw "ERR_TESTER_INI_BINDING_FAILED_$slot"
        }
        Write-Host "[GRID] TESTER_CONFIG_BINDING=PASS"

        # Record tester.ini SHA for evidence
        $testerIniSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $testerIni).Hash

        # ---- Launch optimization ----
        $termProc = Start-Process -FilePath $baseTerminal -ArgumentList @('/portable', ('/config:"' + $testerIni + '"')) -WorkingDirectory $baseMt5 -PassThru

        $perfCpu = New-Object System.Diagnostics.PerformanceCounter("Processor", "% Processor Time", "_Total")
        $null = $perfCpu.NextValue()

        $timeoutSec        = 5400
        $swOpt             = [System.Diagnostics.Stopwatch]::StartNew()
        $sampleIntervalSec = 5
        $lastSampleSec     = 0
        $telemetrySnapshots = [System.Collections.Generic.List[object]]::new()
        $maxSimultaneousMetatester = 0
        $maxTotalProcesses  = 0
        $minFreeRamMb       = 999999.0
        $peakUsedRamMb      = 0.0

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
                $cpuVal = 0.0; $freeMemMb = 0.0; $usedMemMb = 0.0; $totMemMb = 0.0
                try {
                    $cpuVal    = [math]::Round($perfCpu.NextValue(), 1)
                    $os        = Get-CimInstance Win32_OperatingSystem
                    $freeMemMb = [math]::Round($os.FreePhysicalMemory / 1024, 1)
                    $totMemMb  = [math]::Round($os.TotalVisibleMemorySize / 1024, 1)
                    $usedMemMb = [math]::Round($totMemMb - $freeMemMb, 1)
                    if ($freeMemMb -lt $minFreeRamMb) { $minFreeRamMb = $freeMemMb }
                    if ($usedMemMb -gt $peakUsedRamMb) { $peakUsedRamMb = $usedMemMb }
                } catch {}

                $allProcs   = @(Get-Process -ErrorAction SilentlyContinue)
                $totProcCnt = $allProcs.Count
                if ($totProcCnt -gt $maxTotalProcesses) { $maxTotalProcesses = $totProcCnt }
                $agentProcs = @(Get-Process metatester64 -ErrorAction SilentlyContinue)
                if ($agentProcs.Count -gt $maxSimultaneousMetatester) { $maxSimultaneousMetatester = $agentProcs.Count }

                $telemetrySnapshots.Add([PSCustomObject]@{
                    timestamp_utc    = $nowUtc
                    elapsed_sec      = $elapsedSec
                    cpu_percent      = $cpuVal
                    free_ram_mb      = $freeMemMb
                    used_ram_mb      = $usedMemMb
                    total_procs      = $totProcCnt
                    metatester_procs = $agentProcs.Count
                })

                # Resource guards
                if ($agentProcs.Count -gt 16 -or $freeMemMb -lt 2000 -or $totProcCnt -gt 200) {
                    Write-Host "[GRID] RESOURCE_THRESHOLD_TRIGGERED"
                    Stop-Process -Id $termProc.Id -Force -ErrorAction SilentlyContinue
                    Get-Process metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                    Set-Stage 'RESOURCE_EXPLOSION_ABORT'
                    throw "ERR_RESOURCE_EXPLOSION_$slot"
                }
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
        if (-not $boundaryClean) { Set-Stage 'CLEAN_BOUNDARY_FAILED'; throw "ERR_CLEAN_BOUNDARY_FAILED_$slot" }
        Write-Host "[GRID] PROCESS_CLEAN_BOUNDARY=PASS"

        # Restore SET write permission and record post-run SHA
        Set-ItemProperty -LiteralPath $activeSetPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
        $setPostSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $activeSetPath).Hash
        if (-not $setPreSha.Equals($setPostSha, [System.StringComparison]::OrdinalIgnoreCase)) {
            Set-Stage 'SET_MODIFIED_DURING_EXECUTION'; throw "ERR_SET_MODIFIED_DURING_EXECUTION_$slot"
        }

        # Prepare evidence directory
        $slotEvidenceDir = Join-Path $out $slot
        New-Item -ItemType Directory -Force -Path $slotEvidenceDir | Out-Null

        # Save telemetry
        $telemetrySnapshots | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $slotEvidenceDir 'telemetry.json') -Encoding utf8

        # Run identity oracle (v2 two-contract model)
        $identityEvidenceFile = Join-Path $slotEvidenceDir 'identity_evidence.json'
        $oracleArgs = @(
            $oracleScript,
            '--xml',  $reportXmlPath,
            '--set',  $activeSetPath,
            '--meta', $metaFile,
            '--out',  $identityEvidenceFile
        )
        $oracleProc = Start-Process -FilePath 'python' -ArgumentList $oracleArgs -NoNewWindow -PassThru -Wait

        if ($oracleProc.ExitCode -eq 0) {
            Write-Host "[GRID] CASE_CONTRACT_VALIDATED"
            Write-Host "[GRID] EXECUTION_IDENTITY_CHECK=PASS"
        } else {
            Write-Host "[GRID] EXECUTION_IDENTITY_CHECK=FAIL"
            Set-Stage 'IDENTITY_ORACLE_FAILED'
            throw "ERR_IDENTITY_ORACLE_FAILED_$slot"
        }

        # Write binding evidence supplement (private — goes into encrypted artifact)
        $bindingEvidence = [PSCustomObject]@{
            slot              = $slot
            set_filename      = "$slot.set"
            set_pre_sha256    = $setPreSha
            set_post_sha256   = $setPostSha
            set_unchanged     = $setPreSha.Equals($setPostSha, [System.StringComparison]::OrdinalIgnoreCase)
            tester_ini_sha256 = $testerIniSha
        }
        $bindingEvidence | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $slotEvidenceDir 'binding_evidence.json') -Encoding utf8

        # Move report to evidence
        if (Test-Path $reportXmlPath) {
            Move-Item -LiteralPath $reportXmlPath -Destination (Join-Path $slotEvidenceDir $reportXmlName) -Force
        }
        $reportHtm = $reportXmlPath + ".htm"
        if (Test-Path $reportHtm) {
            Move-Item -LiteralPath $reportHtm -Destination (Join-Path $slotEvidenceDir ($reportXmlName + ".htm")) -Force
        }

        # Copy tester logs
        $testerLogsDir = Join-Path $baseMt5 'Tester\logs'
        $slotLogsDir   = Join-Path $slotEvidenceDir 'logs'
        New-Item -ItemType Directory -Force -Path $slotLogsDir | Out-Null
        if (Test-Path $testerLogsDir) {
            Copy-Item -Path "$testerLogsDir\*" -Destination $slotLogsDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        $slotResults[$slot] = 'PASS'
        Write-Host "[GRID] CASE_EXECUTION_PASS: SLOT=$slot"
    }

    # Verify all 4 slots completed
    if ($slotResults.Count -ne 4) { Set-Stage 'INCOMPLETE_SLOTS'; throw "ERR_INCOMPLETE_SLOTS" }
    foreach ($slot in $slotNames) {
        if ($slotResults[$slot] -ne 'PASS') { Set-Stage 'SLOT_FAILED'; throw "ERR_SLOT_FAILED_$slot" }
    }

    Write-Host "[GRID] ALL_4_SLOTS_COMPLETED_SUCCESSFULLY"

    # Encrypt and emit final evidence package
    & $seven a -t7z -mhe=on "-p$key" $encOut "$out\*" -y *>$null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $encOut -PathType Leaf)) {
        Set-Stage 'ENCRYPT_EVIDENCE_FAILED'; throw "ERR_ENCRYPT_EVIDENCE_FAILED"
    }
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
