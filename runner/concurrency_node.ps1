$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$stage = 'INIT'
$code = 0
$key = $null
$root = Join-Path $env:RUNNER_TEMP 'g'
$payload = Join-Path $root 'p'
$baseMt5 = Join-Path $root 'base_mt5'
$out = Join-Path $root 'o'
$encIn = Join-Path $root 'i.7z'
$encOut = Join-Path $env:RUNNER_TEMP 'o.bin'

function Set-Stage([string]$s, [int]$c = 1) {
    $script:stage = $s
    $script:code = $c
}

try {
    if ([string]::IsNullOrWhiteSpace($env:GRID_SESSION_KEY)) { Set-Stage 'SESSION_KEY_MISSING'; throw "Session key is missing" }
    if ($env:GRID_PACKAGE_SHA256 -notmatch '^[A-Fa-f0-9]{64}$') { Set-Stage 'HASH_INVALID'; throw "Package SHA256 invalid" }
    if ([string]::IsNullOrWhiteSpace($env:GRID_PACKAGE_URL)) { Set-Stage 'URL_MISSING'; throw "Package URL missing" }

    $key = $env:GRID_SESSION_KEY
    $runnerIndex = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_INDEX)) { $env:RUNNER_INDEX } else { '00' }
    $barrierUtcStr = $env:BARRIER_UTC

    $seven = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    if (-not (Test-Path $seven -PathType Leaf)) { Set-Stage 'SEVENZIP_MISSING'; throw "7-Zip not found" }

    New-Item -ItemType Directory -Force -Path $root,$payload,$baseMt5,$out | Out-Null

    # 1. Hardware probe
    $cs = Get-CimInstance Win32_ComputerSystem
    $proc = Get-CimInstance Win32_Processor | Select-Object -First 1
    $logicalCpus = [Environment]::ProcessorCount
    $totalRamGb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    $totalRamMb = [math]::Round($cs.TotalPhysicalMemory / 1MB, 0)
    $drive = Get-PSDrive -Name C
    $freeDiskGb = [math]::Round($drive.Free / 1GB, 1)
    $freeDiskMb = [math]::Round($drive.Free / 1MB, 1)
    $initialFreeDiskMb = $freeDiskMb

    Write-Host "[GRID] RUNNER_INDEX=$runnerIndex"
    Write-Host "[GRID] LOGICAL_CPUS=$logicalCpus"
    Write-Host "[GRID] TOTAL_RAM_GB=$totalRamGb"
    Write-Host "[GRID] FREE_DISK_GB=$freeDiskGb"

    if ($logicalCpus -ne 4) {
        Write-Host "[GRID] WARNING: Expected 4 logical CPUs, detected $logicalCpus"
    }

    # 2. Download and decrypt payload
    Write-Host '[GRID] DOWNLOAD_PACKAGE_BEGIN'
    try {
        Invoke-WebRequest -Uri $env:GRID_PACKAGE_URL -OutFile $encIn -UseBasicParsing
    } catch {
        Set-Stage 'DOWNLOAD_FAILED'; throw "Failed to download payload package"
    }

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $encIn).Hash
    if (-not $hash.Equals($env:GRID_PACKAGE_SHA256, [System.StringComparison]::OrdinalIgnoreCase)) {
        Set-Stage 'HASH_MISMATCH'; throw "Package hash mismatch"
    }

    & $seven x $encIn "-p$key" "-o$payload" -y *> $null
    if ($LASTEXITCODE -ne 0) { Set-Stage 'DECRYPT_FAILED'; throw "Failed to decrypt payload" }

    # Erase session key from process environment
    Remove-Item Env:GRID_SESSION_KEY -ErrorAction SilentlyContinue

    $expertPayload = Join-Path $payload 'ConcurrencyProbeEA.ex5'
    if (-not (Test-Path $expertPayload -PathType Leaf)) {
        # Fallback to any .ex5
        $cand = Get-ChildItem -Path $payload -Filter '*.ex5' -File | Select-Object -First 1
        if ($cand) { $expertPayload = $cand.FullName }
        else { Set-Stage 'EXPERT_PAYLOAD_MISSING'; throw "ConcurrencyProbeEA.ex5 missing in payload" }
    }

    $cfgIni = Join-Path $payload 'tester.ini'
    if (-not (Test-Path $cfgIni -PathType Leaf)) { Set-Stage 'CONFIG_MISSING'; throw "tester.ini missing in payload" }
    $cfgContent = Get-Content -LiteralPath $cfgIni -Raw -Encoding utf8

    $commonMatch = [regex]::Match($cfgContent, '(?ms)\[Common\].*?(?=\r?\n\[|\Z)')
    if (-not $commonMatch.Success) { Set-Stage 'CONFIG_COMMON_MISSING'; throw "No [Common] section in tester.ini" }
    $commonSection = $commonMatch.Value

    $symbol = if ($cfgContent -match '(?im)^\s*Symbol\s*=\s*(\S+)') { $matches[1].Trim() } else { 'EURUSD' }
    $period = if ($cfgContent -match '(?im)^\s*Period\s*=\s*(\S+)') { $matches[1].Trim() } else { 'H1' }
    $fromDate = if ($cfgContent -match '(?im)^\s*FromDate\s*=\s*(\S+)') { $matches[1].Trim() } else { '2026.08.01' }
    $toDate = if ($cfgContent -match '(?im)^\s*ToDate\s*=\s*(\S+)') { $matches[1].Trim() } else { '2026.08.05' }
    $model = if ($cfgContent -match '(?im)^\s*Model\s*=\s*(\d+)') { [int]$matches[1] } else { 1 }

    Write-Host '[GRID] PAYLOAD_VERIFIED'

    # 3. Install MT5 Runtime
    Write-Host '[GRID] INSTALL_MT5_BEGIN'
    $setup = Join-Path $root 'mt5setup.exe'
    try {
        Invoke-WebRequest -Uri 'https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe' -OutFile $setup -UseBasicParsing
    } catch {
        Set-Stage 'RUNTIME_DOWNLOAD_FAILED'; throw "Failed to download MT5 installer"
    }

    Start-Process -FilePath $setup -ArgumentList '/auto' | Out-Null
    $defaultMt5 = Join-Path $env:ProgramFiles 'MetaTrader 5'
    $termDefault = Join-Path $defaultMt5 'terminal64.exe'
    $deadline = (Get-Date).AddMinutes(5)
    while (-not (Test-Path $termDefault -PathType Leaf) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
    }
    Start-Sleep -Seconds 5
    Get-Process terminal64,metatester64,mt5setup -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $termDefault -PathType Leaf)) { Set-Stage 'RUNTIME_MISSING'; throw "terminal64.exe not found after install" }

    Copy-Item -Path "$defaultMt5\*" -Destination $baseMt5 -Recurse -Force
    $baseTerminal = Join-Path $baseMt5 'terminal64.exe'
    $baseMetaeditor = Join-Path $baseMt5 'metaeditor64.exe'
    if (-not (Test-Path $baseTerminal -PathType Leaf)) { Set-Stage 'BASE_TERMINAL_MISSING'; throw "Base terminal64.exe missing" }

    # Clean sample mq5 source files
    Get-ChildItem -Path (Join-Path $baseMt5 'MQL5') -Filter '*.mq5' -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    # Setup directories
    $expertDir = Join-Path $baseMt5 'MQL5\Experts'
    $scriptsDir = Join-Path $baseMt5 'MQL5\Scripts'
    $filesDir = Join-Path $baseMt5 'MQL5\Files'
    $profilesTesterDir = Join-Path $baseMt5 'MQL5\Profiles\Tester'
    New-Item -ItemType Directory -Force -Path $expertDir,$scriptsDir,$filesDir,$profilesTesterDir | Out-Null

    # Copy ConcurrencyProbeEA
    Copy-Item -LiteralPath $expertPayload -Destination (Join-Path $expertDir 'ConcurrencyProbeEA.ex5') -Force

    # 4. Broker Prewarm
    Write-Host '[GRID] PREWARM_SETUP'
    $prewarmMq5 = Join-Path $env:GITHUB_WORKSPACE 'runner\grid_prewarm.mq5'
    $targetPrewarmMq5 = Join-Path $scriptsDir 'grid_prewarm.mq5'
    Copy-Item -LiteralPath $prewarmMq5 -Destination $targetPrewarmMq5 -Force
    $compileLog = Join-Path $baseMt5 'compile_prewarm.log'
    Start-Process -FilePath $baseMetaeditor -ArgumentList @("/compile:$targetPrewarmMq5", "/log:$compileLog") -Wait | Out-Null

    $prewarmEx5 = Join-Path $scriptsDir 'grid_prewarm.ex5'
    if (-not (Test-Path $prewarmEx5 -PathType Leaf)) { Set-Stage 'PREWARM_COMPILE_FAILED'; throw "Failed to compile grid_prewarm.mq5" }

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
    Write-Host '[GRID] PREWARM_INI_NO_BOM_VERIFIED'

    Write-Host '[GRID] PREWARM_EXECUTE_BEGIN'
    $procPrewarm = Start-Process -FilePath $baseTerminal -ArgumentList @('/portable', ('/config:"' + $prewarmIni + '"')) -WorkingDirectory $baseMt5 -PassThru
    $swPrewarm = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $procPrewarm.HasExited) {
        Start-Sleep -Seconds 2
        if ($swPrewarm.Elapsed.TotalSeconds -ge 180) {
            Stop-Process -Id $procPrewarm.Id -Force -ErrorAction SilentlyContinue
            Set-Stage 'PREWARM_TIMEOUT'; throw "Prewarm timed out after 180s"
        }
    }

    Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
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
        Set-Stage 'PREWARM_FAILED'; throw "Prewarm failed or bars <= 0"
    }

    $hcc = @(Get-ChildItem -Path (Join-Path $baseMt5 'bases') -Filter '*.hcc' -Recurse -File -ErrorAction SilentlyContinue)
    if ($hcc.Count -eq 0) { Set-Stage 'HISTORY_CACHE_MISSING'; throw "No .hcc history cache files found" }
    Write-Host '[GRID] PREWARM_SUCCESS'

    # Cleanup prewarm artifacts
    Remove-Item -LiteralPath $prewarmIni -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $filesDir 'prewarm_params.txt') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $targetPrewarmMq5 -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $prewarmEx5 -Force -ErrorAction SilentlyContinue

    # 5. Configure Strategy Tester Optimization (4 passes: ProbeSlot 0..3)
    $setPath = Join-Path $profilesTesterDir 'ConcurrencyProbeEA.set'
    "ProbeSlot=0||0||1||3||Y" | Set-Content -LiteralPath $setPath -Encoding ascii

    $testerIni = Join-Path $baseMt5 'tester.ini'
    $testerIniContent = @"
$commonSection

[Tester]
Expert=ConcurrencyProbeEA.ex5
ExpertParameters=ConcurrencyProbeEA.set
Symbol=$symbol
Period=$period
Deposit=10000
Currency=USD
Leverage=100
Model=1
ExecutionMode=0
Optimization=1
OptimizationCriterion=0
FromDate=$fromDate
ToDate=$toDate
Report=report.htm
ReplaceReport=1
ShutdownTerminal=1
UseLocal=1
UseRemote=0
UseCloud=0
"@
    [System.IO.File]::WriteAllText($testerIni, $testerIniContent, $utf8NoBom)

    # 6. Barrier Synchronization
    $readyUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Host "[GRID] READY_UTC=$readyUtc"

    if (-not [string]::IsNullOrWhiteSpace($barrierUtcStr)) {
        Write-Host "[GRID] BARRIER_UTC=$barrierUtcStr"
        $barrier = [DateTime]::Parse($barrierUtcStr).ToUniversalTime()
        $now = (Get-Date).ToUniversalTime()
        if ($now -gt $barrier) {
            Write-Host "[GRID] WARNING: Arrived AFTER barrier: now=$($now.ToString('o')) barrier=$($barrier.ToString('o'))"
        } else {
            $waitSeconds = [math]::Round(($barrier - $now).TotalSeconds, 1)
            Write-Host "[GRID] WAITING_FOR_BARRIER: $waitSeconds seconds remaining"
            while ((Get-Date).ToUniversalTime() -lt $barrier) {
                Start-Sleep -Milliseconds 250
            }
            Write-Host "[GRID] BARRIER_TRIGGERED"
        }
    } else {
        Write-Host "[GRID] NO_BARRIER_SPECIFIED - proceeding immediately"
    }

    # 7. Launch Optimization & Sample 4 Active Agents (Gate 3)
    $optStartUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Host "[GRID] OPTIMIZATION_START_UTC=$optStartUtc"

    $proc = Start-Process -FilePath $baseTerminal -ArgumentList @('/portable', ('/config:"' + $testerIni + '"')) -WorkingDirectory $baseMt5 -PassThru

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
    $peakDiskUsedMb = 0.0
    $minFreeDiskMb = 999999.0

    $timeoutSec = 600
    $swOpt = [System.Diagnostics.Stopwatch]::StartNew()

    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 1

        if ($swOpt.Elapsed.TotalSeconds -ge $timeoutSec) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            Get-Process metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Set-Stage 'OPTIMIZATION_TIMEOUT'; throw "Optimization timed out after $timeoutSec seconds"
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

            $curDrive = Get-PSDrive -Name C
            $curFreeDiskMb = [math]::Round($curDrive.Free / 1MB, 1)
            $diskUsed = [math]::Max(0.0, ($initialFreeDiskMb - $curFreeDiskMb))
            if ($diskUsed -gt $peakDiskUsedMb) { $peakDiskUsedMb = $diskUsed }
            if ($curFreeDiskMb -lt $minFreeDiskMb) { $minFreeDiskMb = $curFreeDiskMb }
        } catch {}

        # Sample active metatester64 processes
        $agents = @(Get-Process metatester64 -ErrorAction SilentlyContinue)
        if ($agents.Count -gt $maxAgentProcesses) { $maxAgentProcesses = $agents.Count }

        $activeCount = 0
        $currentUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

        foreach ($a in $agents) {
            $pid = $a.Id
            $currTime = $a.TotalProcessorTime.TotalMilliseconds
            if ($prevCpu.ContainsKey($pid)) {
                $delta = $currTime - $prevCpu[$pid]
                # If agent consumed > 200 ms of CPU in 1 second interval, it is actively running
                if ($delta -gt 200) {
                    $activeCount++
                }
            }
            $prevCpu[$pid] = $currTime
        }

        if ($activeCount -gt $maxActiveAgents) { $maxActiveAgents = $activeCount }

        if ($activeCount -ge 4) {
            $samplesWith4Active++
            if ($null -eq $fourActiveFirstUtc) {
                $fourActiveFirstUtc = $currentUtc
            }
            $fourActiveLastUtc = $currentUtc
        }
    }

    $optEndUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Host "[GRID] OPTIMIZATION_END_UTC=$optEndUtc"

    # Wait briefly for agents to close cleanly
    Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    # 8. Analyze completed passes
    $passCount = 0
    $testerLogs = @(Get-ChildItem -Path (Join-Path $baseMt5 'Tester\logs') -Filter '*.log' -File -ErrorAction SilentlyContinue)
    foreach ($tl in $testerLogs) {
        $lines = Get-Content $tl.FullName -Encoding Unicode -ErrorAction SilentlyContinue
        foreach ($line in $lines) {
            if ($line -match 'optimization finished,\s*total passes\s*(\d+)') {
                $p = [int]$matches[1]
                if ($p -gt $passCount) { $passCount = $p }
            }
            if ($line -match '(\d+)\s*new records saved to cache file') {
                $p = [int]$matches[1]
                if ($p -gt $passCount) { $passCount = $p }
            }
        }
    }

    if ($passCount -eq 0 -and (Test-Path "$baseMt5\report.htm")) {
        $html = Get-Content "$baseMt5\report.htm" -Raw -ErrorAction SilentlyContinue
        $passCount = ([regex]::Matches($html, 'Pass\s*\d+')).Count
        if ($passCount -eq 0) {
            $passCount = ([regex]::Matches($html, '(?i)<tr[^>]*>\s*<td>\d+</td>')).Count
        }
    }

    $fourActiveDurationSec = 0
    if ($fourActiveFirstUtc -and $fourActiveLastUtc) {
        $t1 = [DateTime]::Parse($fourActiveFirstUtc).ToUniversalTime()
        $t2 = [DateTime]::Parse($fourActiveLastUtc).ToUniversalTime()
        $fourActiveDurationSec = [math]::Max(0, [int]($t2 - $t1).TotalSeconds)
    }

    Write-Host "[GRID] PASS_COUNT_COMPLETED=$passCount"
    Write-Host "[GRID] MAX_AGENT_PROCESSES=$maxAgentProcesses"
    Write-Host "[GRID] MAX_ACTIVE_AGENTS=$maxActiveAgents"
    Write-Host "[GRID] FOUR_ACTIVE_FIRST_UTC=$fourActiveFirstUtc"
    Write-Host "[GRID] FOUR_ACTIVE_LAST_UTC=$fourActiveLastUtc"
    Write-Host "[GRID] FOUR_ACTIVE_DURATION_SEC=$fourActiveDurationSec"
    Write-Host "[GRID] SAMPLES_WITH_4_ACTIVE=$samplesWith4Active"
    Write-Host "[GRID] PEAK_CPU_PERCENT=$peakCpu"
    Write-Host "[GRID] PEAK_MEMORY_MB=$peakMemMb"
    Write-Host "[GRID] MIN_FREE_MEMORY_MB=$minFreeMemMb"
    Write-Host "[GRID] PEAK_DISK_USED_MB=$peakDiskUsedMb"
    Write-Host "[GRID] MIN_FREE_DISK_MB=$minFreeDiskMb"

    # Assertions
    if ($passCount -lt 4) { Set-Stage 'INCOMPLETE_PASSES'; throw "Pass count is $passCount, expected 4" }
    if ($maxActiveAgents -lt 4) { Set-Stage 'MAX_ACTIVE_AGENTS_LOW'; throw "Max active agents is $maxActiveAgents, expected 4" }
    if ($fourActiveDurationSec -le 0) { Set-Stage 'NO_4_WAY_OVERLAP'; throw "Four active agents overlap duration is <= 0" }

    # 9. Build Evidence and Encrypt
    $evidence = @{
        runner_index = $runnerIndex
        logical_cpus = $logicalCpus
        ready_utc = $readyUtc
        barrier_utc = $barrierUtcStr
        optimization_start_utc = $optStartUtc
        optimization_end_utc = $optEndUtc
        pass_count_completed = $passCount
        max_agent_processes = $maxAgentProcesses
        max_active_agents = $maxActiveAgents
        four_active_first_utc = $fourActiveFirstUtc
        four_active_last_utc = $fourActiveLastUtc
        four_active_duration_seconds = $fourActiveDurationSec
        samples_with_4_active = $samplesWith4Active
        peak_cpu_percent = $peakCpu
        peak_memory_mb = $peakMemMb
        min_free_memory_mb = $minFreeMemMb
        peak_disk_used_mb = $peakDiskUsedMb
        min_free_disk_mb = $minFreeDiskMb
        crashes = 0
        timeouts = 0
        history_failures = 0
        network_failures = 0
    }

    $evidenceJson = $evidence | ConvertTo-Json -Depth 5
    $evidenceFile = Join-Path $out 'evidence.json'
    [System.IO.File]::WriteAllText($evidenceFile, $evidenceJson, $utf8NoBom)

    # Re-read session key from memory for encryption
    & $seven a $encOut $evidenceFile "-p$key" -y *> $null
    if ($LASTEXITCODE -ne 0) { Set-Stage 'EVIDENCE_ENCRYPT_FAILED'; throw "Failed to encrypt evidence" }

    Write-Host '[GRID] EVIDENCE_ENCRYPTED_OK'
    Write-Host '[GRID] STATUS=PASS'
    Set-Stage 'SUCCESS' 0

} catch {
    Write-Host "[GRID] ERROR: $_"
    if ($script:code -eq 0) { $script:code = 1 }
} finally {
    # Cleanup baseMt5 and payload
    Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue
    "exit_code=$($script:code)" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
    "stage=$($script:stage)" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
    exit $script:code
}
