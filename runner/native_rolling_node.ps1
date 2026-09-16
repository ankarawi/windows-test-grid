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
        if (Test-Path $testerLogsDir -PathType Container) {
            $evLogsDir = Join-Path $out 'logs'
            New-Item -ItemType Directory -Force -Path $evLogsDir | Out-Null
            Copy-Item -Path "$testerLogsDir\*" -Destination $evLogsDir -Recurse -Force -ErrorAction SilentlyContinue
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
    if (-not (Test-Path $statusFile -PathType Leaf)) { Set-Stage 'PREWARM_SENTINEL_MISSING'; throw "ERR_PREWARM_SENTINEL_MISSING" }
    $statusContent = Get-Content -LiteralPath $statusFile -Raw
    if ($statusContent -notmatch '(?im)^\s*STATUS\s*=\s*PASS') { Set-Stage 'PREWARM_FAILED'; throw "ERR_PREWARM_FAILED" }
    Write-Host "[GRID] PREWARM_PASS=YES"

    # 4. Deploy worker.ex5
    $expertsDir = Join-Path $baseMt5 'MQL5\Experts'
    New-Item -ItemType Directory -Force -Path $expertsDir | Out-Null
    Copy-Item -LiteralPath $workerEx5Src -Destination (Join-Path $expertsDir 'worker.ex5') -Force

    # 5. Contract A: Deploy case SET file
    $profilesTesterDir = Join-Path $baseMt5 'MQL5\Profiles\Tester'
    New-Item -ItemType Directory -Force -Path $profilesTesterDir | Out-Null

    $setPreSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $setFile).Hash
    $activeSetPath = Join-Path $profilesTesterDir "case.set"
    Copy-Item -LiteralPath $setFile -Destination $activeSetPath -Force

    # Mark SET read-only during execution
    Set-ItemProperty -LiteralPath $activeSetPath -Name IsReadOnly -Value $true
    $setDeployedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $activeSetPath).Hash
    if (-not $setPreSha.Equals($setDeployedSha, [System.StringComparison]::OrdinalIgnoreCase)) {
        Set-Stage 'SET_DEPLOY_HASH_MISMATCH'; throw "ERR_SET_DEPLOY_HASH_MISMATCH"
    }

    # Clean cache and old reports
    $cacheDir = Join-Path $baseMt5 'Tester\cache'
    if (Test-Path $cacheDir) { Remove-Item -LiteralPath $cacheDir -Recurse -Force -ErrorAction SilentlyContinue }

    $reportXmlName = "opt_report.xml"
    $reportXmlPath = Join-Path $baseMt5 $reportXmlName
    if (Test-Path $reportXmlPath) { Remove-Item -LiteralPath $reportXmlPath -Force -ErrorAction SilentlyContinue }

    # Configure tester.ini
    $testerIni = Join-Path $baseMt5 'tester.ini'
    $testerIniContent = @"
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
Report=$reportXmlName
ReplaceReport=1
ShutdownTerminal=1
Visual=0
UseLocal=1
UseRemote=0
UseCloud=0
"@
    [System.IO.File]::WriteAllText($testerIni, $testerIniContent, $utf8NoBom)

    $iniContent = Get-Content -LiteralPath $testerIni -Raw
    if ($iniContent -notmatch [regex]::Escape("ExpertParameters=case.set")) {
        Set-Stage 'TESTER_INI_BINDING_FAILED'; throw "ERR_TESTER_INI_BINDING_FAILED"
    }
    Write-Host "[GRID] CONFIG_BINDING=PASS"
    Write-Host "[GRID] TESTER_CONFIG_BINDING=PASS"
    $testerIniSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $testerIni).Hash

    # 6. Launch MT5 optimization
    $launchTimeUtc = (Get-Date).ToUniversalTime()
    $termProc = Start-Process -FilePath $baseTerminal -ArgumentList @('/portable', ('/config:"' + $testerIni + '"')) -WorkingDirectory $baseMt5 -PassThru
    $script:termExitState = 'RUNNING'

    $perfCpu = New-Object System.Diagnostics.PerformanceCounter("Processor", "% Processor Time", "_Total")
    $null = $perfCpu.NextValue()

    $swOpt             = [System.Diagnostics.Stopwatch]::StartNew()
    $sampleIntervalSec = 5
    $lastSampleSec     = 0

    Set-Content -LiteralPath $telemetryLog -Value "# timestamp_utc,elapsed_sec,terminal_count,metatester_count,cpu_percent,free_ram_mb,used_ram_mb,total_procs" -Encoding ascii

    while (-not $termProc.HasExited) {
        Start-Sleep -Seconds 1
        $script:elapsedSec = [int]$swOpt.Elapsed.TotalSeconds

        # Watchdog check
        if ($script:elapsedSec -ge $timeoutSec) {
            $script:watchdogTriggered = $true
            $script:termExitState = 'KILLED_BY_WATCHDOG'
            Write-Host "[GRID] WATCHDOG_TIMEOUT"
            Stop-Process -Id $termProc.Id -Force -ErrorAction SilentlyContinue
            Get-Process metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Set-Stage 'WATCHDOG_TIMEOUT'
            throw "ERR_WATCHDOG_TIMEOUT"
        }

        # Checkpoint telemetry every 5s
        if ($script:elapsedSec -ge ($lastSampleSec + $sampleIntervalSec)) {
            $lastSampleSec = $script:elapsedSec
            $nowUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $cpuVal = 0.0; $freeMemMb = 0.0; $usedMemMb = 0.0; $totMemMb = 0.0
            try {
                $cpuVal    = [math]::Round($perfCpu.NextValue(), 1)
                $os        = Get-CimInstance Win32_OperatingSystem
                $freeMemMb = [math]::Round($os.FreePhysicalMemory / 1024, 1)
                $totMemMb  = [math]::Round($os.TotalVisibleMemorySize / 1024, 1)
                $usedMemMb = [math]::Round($totMemMb - $freeMemMb, 1)
                if ($freeMemMb -lt $script:minFreeRamMb) { $script:minFreeRamMb = $freeMemMb }
            } catch {}

            $allProcs   = @(Get-Process -ErrorAction SilentlyContinue)
            $totProcCnt = $allProcs.Count
            if ($totProcCnt -gt $script:maxTotalProcs) { $script:maxTotalProcs = $totProcCnt }

            $termProcs = @(Get-Process terminal64 -ErrorAction SilentlyContinue)
            $agentProcs = @(Get-Process metatester64 -ErrorAction SilentlyContinue)
            if ($agentProcs.Count -gt $script:maxMetatester) { $script:maxMetatester = $agentProcs.Count }

            $telemLine = "$nowUtc,$($script:elapsedSec),$($termProcs.Count),$($agentProcs.Count),$cpuVal,$freeMemMb,$usedMemMb,$totProcCnt"
            Add-Content -LiteralPath $telemetryLog -Value $telemLine -Encoding ascii

            # Resource guards
            if ($agentProcs.Count -gt 16 -or $freeMemMb -lt 2000 -or $totProcCnt -gt 200) {
                $script:resourceGuardTriggered = $true
                $script:termExitState = 'KILLED_BY_RESOURCE_GUARD'
                Write-Host "[GRID] RESOURCE_THRESHOLD_TRIGGERED"
                Stop-Process -Id $termProc.Id -Force -ErrorAction SilentlyContinue
                Get-Process metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Set-Stage 'RESOURCE_EXPLOSION_ABORT'
                throw "ERR_RESOURCE_EXPLOSION"
            }
        }
    }

    $script:termExitState = "EXITED_$($termProc.ExitCode)"

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

    # Restore SET write permission and verify unchanged
    Set-ItemProperty -LiteralPath $activeSetPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    $setPostSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $activeSetPath).Hash
    if (-not $setPreSha.Equals($setPostSha, [System.StringComparison]::OrdinalIgnoreCase)) {
        Set-Stage 'SET_MODIFIED_DURING_EXECUTION'; throw "ERR_SET_MODIFIED_DURING_EXECUTION"
    }

    # Verify report existence and freshness
    if (Test-Path $reportXmlPath -PathType Leaf) {
        $script:reportExists = $true
        $repTime = (Get-Item $reportXmlPath).LastWriteTimeUtc
        if ($repTime -lt $launchTimeUtc.AddSeconds(-5)) {
            Set-Stage 'STALE_REPORT'; throw "ERR_STALE_REPORT_DETECTED"
        }
    } else {
        Set-Stage 'REPORT_MISSING'; throw "ERR_REPORT_MISSING"
    }

    # Identity oracle execution
    $identityEvidenceFile = Join-Path $out 'identity_evidence.json'
    $oracleArgs = @(
        $oracleScript,
        '--xml',  $reportXmlPath,
        '--set',  $activeSetPath,
        '--meta', $metaFile,
        '--out',  $identityEvidenceFile
    )
    $oracleProc = Start-Process -FilePath 'python' -ArgumentList $oracleArgs -NoNewWindow -PassThru -Wait

    if ($oracleProc.ExitCode -eq 0) {
        Write-Host "[GRID] REPORT_PASS_ROWS=1"
        Write-Host "[GRID] EXECUTION_IDENTITY_CHECK=PASS"
    } else {
        Write-Host "[GRID] EXECUTION_IDENTITY_CHECK=FAIL"
        Set-Stage 'IDENTITY_ORACLE_FAILED'
        throw "ERR_IDENTITY_ORACLE_FAILED"
    }

    # Binding evidence
    $bindingEvidence = [PSCustomObject]@{
        opaque_id         = $opaqueId
        lane_id           = $laneId
        set_filename      = "case.set"
        set_pre_sha256    = $setPreSha
        set_post_sha256   = $setPostSha
        set_unchanged     = $setPreSha.Equals($setPostSha, [System.StringComparison]::OrdinalIgnoreCase)
        tester_ini_sha256 = $testerIniSha
    }
    $bindingEvidence | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'binding_evidence.json') -Encoding utf8

    # Move report files to evidence
    if (Test-Path $reportXmlPath) {
        Move-Item -LiteralPath $reportXmlPath -Destination (Join-Path $out $reportXmlName) -Force
    }
    $reportHtm = $reportXmlPath + ".htm"
    if (Test-Path $reportHtm) {
        Move-Item -LiteralPath $reportHtm -Destination (Join-Path $out ($reportXmlName + ".htm")) -Force
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
