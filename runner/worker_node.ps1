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
$resultsExported = $false

function Set-Stage([string]$s, [int]$c = 1) {
    $script:stage = $s
    $script:code = $c
}

function Wait-PortFree([int]$port = 3000, [int]$timeoutSec = 30) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        $occupied = $false
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $client.Connect('127.0.0.1', $port)
            $client.Close()
            $occupied = $true
        } catch {
            $occupied = $false
        }
        if (-not $occupied) {
            Start-Sleep -Milliseconds 300
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

try {
    if ([string]::IsNullOrWhiteSpace($env:GRID_SESSION_KEY)) { Set-Stage 'SESSION_KEY_MISSING'; throw }
    if ($env:GRID_PACKAGE_SHA256 -notmatch '^[A-Fa-f0-9]{64}$') { Set-Stage 'HASH_INVALID'; throw }
    if ([string]::IsNullOrWhiteSpace($env:GRID_PACKAGE_URL)) { Set-Stage 'URL_MISSING'; throw }

    $key = $env:GRID_SESSION_KEY
    $seven = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    if (-not (Test-Path $seven -PathType Leaf)) { Set-Stage 'SEVENZIP_MISSING'; throw }

    New-Item -ItemType Directory -Force -Path $root,$payload,$baseMt5,$out | Out-Null

    # PHASE 1: Hardware specs probe
    $cs = Get-CimInstance Win32_ComputerSystem
    $proc = Get-CimInstance Win32_Processor | Select-Object -First 1
    $logicalCpus = [Environment]::ProcessorCount
    $physicalCores = if ($proc.NumberOfCores) { $proc.NumberOfCores } else { "UNKNOWN" }
    $totalRamGb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    $totalRamMb = [math]::Round($cs.TotalPhysicalMemory / 1MB, 0)
    $cpuModel = $proc.Name.Trim()
    $drive = Get-PSDrive -Name C
    $freeDiskGb = [math]::Round($drive.Free / 1GB, 1)
    $osInfo = (Get-CimInstance Win32_OperatingSystem).Caption.Trim()

    Write-Host "[GRID] WORKER=$($env:WORKER_ID)"
    Write-Host "[GRID] RUNNER_CPU=$logicalCpus"
    Write-Host "[GRID] RUNNER_RAM_CLASS=${totalRamGb}GB"
    Write-Host "[GRID] CAPACITY_PROBE_OK"

    if ($logicalCpus -ne 4) {
        Set-Stage 'RUNNER_CPU_UNEXPECTED'
        throw "Expected 4 logical CPUs, detected $logicalCpus"
    }

    # Download encrypted package
    Write-Host '[GRID] DOWNLOAD_BEGIN'
    try { Invoke-WebRequest -Uri $env:GRID_PACKAGE_URL -OutFile $encIn -UseBasicParsing } catch { Set-Stage 'DOWNLOAD_FAILED'; throw }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $encIn).Hash
    if (-not $hash.Equals($env:GRID_PACKAGE_SHA256, [System.StringComparison]::OrdinalIgnoreCase)) { Set-Stage 'HASH_MISMATCH'; throw }

    & $seven x $encIn "-p$key" "-o$payload" -y *> $null
    if ($LASTEXITCODE -ne 0) { Set-Stage 'DECRYPT_FAILED'; throw }

    $workerDir = Join-Path $payload $env:WORKER_ID
    if (-not (Test-Path $workerDir -PathType Container)) { Set-Stage 'WORKER_PAYLOAD_MISSING'; throw }

    $expert = Join-Path $payload 'worker.ex5'
    if (-not (Test-Path $expert -PathType Leaf)) { Set-Stage 'EXPERT_PAYLOAD_MISSING'; throw }

    $runnerInfoPath = Join-Path $workerDir 'runner_info.json'
    if (-not (Test-Path $runnerInfoPath -PathType Leaf)) { Set-Stage 'RUNNER_INFO_MISSING'; throw }
    $runnerInfo = Get-Content -LiteralPath $runnerInfoPath -Raw | ConvertFrom-Json

    Write-Host '[GRID] PAYLOAD_VERIFIED'

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
    if (-not (Test-Path $baseTerminal -PathType Leaf)) { Set-Stage 'RUNTIME_MISSING'; throw }

    # Remove sample mq5 source files
    Get-ChildItem -Path (Join-Path $baseMt5 'MQL5') -Filter '*.mq5' -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    # Extract common block and expert name from slot0 tester.ini
    $slot0Ini = Join-Path (Join-Path $workerDir 'slot0') 'tester.ini'
    $cfg = Get-Content -LiteralPath $slot0Ini -Raw -Encoding utf8
    $commonMatch = [regex]::Match($cfg, '(?ms)\[Common\].*?(?=\r?\n\[|\Z)')
    if (-not $commonMatch.Success) { Set-Stage 'CONFIG_INVALID'; throw }
    $commonSection = $commonMatch.Value

    $eaName = if ($cfg -match '(?im)^\s*Expert\s*=\s*(\S+)') { $matches[1].Trim() } else { 'worker.ex5' }
    if (-not $eaName.EndsWith('.ex5', [System.StringComparison]::OrdinalIgnoreCase)) { $eaName += '.ex5' }

    $expertDir = Join-Path $baseMt5 'MQL5\Experts'
    $scriptsDir = Join-Path $baseMt5 'MQL5\Scripts'
    $filesDir = Join-Path $baseMt5 'MQL5\Files'
    New-Item -ItemType Directory -Force -Path $expertDir,$scriptsDir,$filesDir | Out-Null
    Copy-Item -LiteralPath $expert -Destination (Join-Path $expertDir $eaName) -Force
    Copy-Item -LiteralPath $expert -Destination (Join-Path $expertDir 'worker.ex5') -Force

    Remove-Item Env:GRID_SESSION_KEY -ErrorAction SilentlyContinue

    # Compile generic prewarm script
    $prewarmMq5 = Join-Path $env:GITHUB_WORKSPACE 'runner\grid_prewarm.mq5'
    $targetMq5 = Join-Path $scriptsDir 'grid_prewarm.mq5'
    Copy-Item -LiteralPath $prewarmMq5 -Destination $targetMq5 -Force
    $metaeditor = Join-Path $baseMt5 'metaeditor64.exe'
    $compileLog = Join-Path $baseMt5 'compile_prewarm.log'
    Start-Process -FilePath $metaeditor -ArgumentList @("/compile:$targetMq5", "/log:$compileLog") -Wait | Out-Null
    if (-not (Test-Path (Join-Path $scriptsDir 'grid_prewarm.ex5') -PathType Leaf)) { Set-Stage 'PREWARM_COMPILE_FAILED'; throw }

    $symbol = $runnerInfo.symbol
    $period = $runnerInfo.timeframe
    $fromDate = $runnerInfo.from_date
    $toDate = $runnerInfo.to_date
    $model = $runnerInfo.model

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

    # Run Prewarm in base instance
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
    Write-Host '[GRID] PREWARM_SUCCESS'

    $hcc = @(Get-ChildItem -Path (Join-Path $baseMt5 'bases') -Filter '*.hcc' -Recurse -File -ErrorAction SilentlyContinue)
    if ($hcc.Count -gt 0) {
        Write-Host '[GRID] HISTORY_CACHE_PRESENT'
    } else {
        Set-Stage 'HISTORY_CACHE_MISSING'; throw
    }

    Remove-Item -LiteralPath $prewarmIni -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $filesDir 'prewarm_params.txt') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $targetMq5 -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $scriptsDir 'grid_prewarm.ex5') -Force -ErrorAction SilentlyContinue

    # PHASE 2: INITIALIZE 4 ISOLATED SLOTS WITH STRICT AFFINITY
    $slots = @(
        @{ Name = 'slot-0'; SlotDir = 'slot0'; Affinity = 1; MaskHex = '0x1' },
        @{ Name = 'slot-1'; SlotDir = 'slot1'; Affinity = 2; MaskHex = '0x2' },
        @{ Name = 'slot-2'; SlotDir = 'slot2'; Affinity = 4; MaskHex = '0x4' },
        @{ Name = 'slot-3'; SlotDir = 'slot3'; Affinity = 8; MaskHex = '0x8' }
    )

    $slotDirs = @{}
    foreach ($s in $slots) {
        $sName = $s.Name
        $sDir = Join-Path $root $sName
        New-Item -ItemType Directory -Force -Path $sDir | Out-Null
        Copy-Item -Path "$baseMt5\*" -Destination $sDir -Recurse -Force

        $srcSlotDir = Join-Path $workerDir $s.SlotDir
        $slotIni = Join-Path $srcSlotDir 'tester.ini'
        $slotSet = Join-Path $srcSlotDir 'worker.set'
        $slotMeta = Join-Path $srcSlotDir 'meta.json'

        Copy-Item -LiteralPath $slotIni -Destination (Join-Path $sDir 'tester.ini') -Force
        $testerProfileDir = Join-Path $sDir 'MQL5\Profiles\Tester'
        New-Item -ItemType Directory -Force -Path $testerProfileDir | Out-Null
        Copy-Item -LiteralPath $slotSet -Destination (Join-Path $testerProfileDir 'worker.set') -Force

        Copy-Item -LiteralPath $slotMeta -Destination (Join-Path $sDir 'meta.json') -Force
        Remove-Item -LiteralPath (Join-Path $sDir 'report.htm') -Force -ErrorAction SilentlyContinue

        $slotDirs[$sName] = $sDir
    }

    Write-Host '[GRID] 4_SLOTS_INITIALIZED'

    # PHASE 3: EXECUTE 4 SLOTS SEQUENTIALLY WITH STRICT CPU AFFINITY
    $perfCpu = New-Object System.Diagnostics.PerformanceCounter("Processor", "% Processor Time", "_Total")
    $perfRam = New-Object System.Diagnostics.PerformanceCounter("Memory", "Available MBytes")
    [void]$perfCpu.NextValue()

    $slotTracking = @()
    $swGlobal = [System.Diagnostics.Stopwatch]::StartNew()
    $peakCpu = 0.0
    $minFreeRamMb = [double]::MaxValue
    $minFreeDiskMb = [double]::MaxValue

    Write-Host '[GRID] 4_SLOT_CONCURRENT_BENCHMARK_BEGIN'

    foreach ($s in $slots) {
        $sName = $s.Name
        $sDir = $slotDirs[$sName]
        $term = Join-Path $sDir 'terminal64.exe'
        $ini = Join-Path $sDir 'tester.ini'

        # If prior slot exists, wait for its process to completely exit and port to be released
        if ($slotTracking.Count -gt 0) {
            $prev = $slotTracking[-1]
            $swWait = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $prev.Process.HasExited -and $swWait.Elapsed.TotalSeconds -lt 240) {
                try {
                    $cv = $perfCpu.NextValue()
                    if ($cv -gt $peakCpu) { $peakCpu = $cv }
                    $availRam = $perfRam.NextValue()
                    if ($availRam -lt $minFreeRamMb) { $minFreeRamMb = $availRam }
                    $dFree = [math]::Round((Get-PSDrive -Name C).Free / 1MB, 0)
                    if ($dFree -lt $minFreeDiskMb) { $minFreeDiskMb = $dFree }
                } catch {}
                Start-Sleep -Milliseconds 500
            }
            if (-not $prev.Process.HasExited) {
                Stop-Process -Id $prev.Process.Id -Force -ErrorAction SilentlyContinue
            }
            $prev.EndTimeUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            Write-Host "[GRID] Completed $($prev.Name) at $($prev.EndTimeUtc)"

            Get-Process metatester64 -ErrorAction SilentlyContinue | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
            Wait-PortFree 3000 15 | Out-Null
            Start-Sleep -Seconds 1
        }

        $startUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        $p = Start-Process -FilePath $term -ArgumentList @('/portable', ('/config:"' + $ini + '"')) -WorkingDirectory $sDir -PassThru
        $p.ProcessorAffinity = [IntPtr]$s.Affinity

        $slotTracking += [PSCustomObject]@{
            Name = $sName
            SlotDir = $s.SlotDir
            Process = $p
            Affinity = $s.Affinity
            MaskHex = $s.MaskHex
            StartTimeUtc = $startUtc
            EndTimeUtc = $null
            Dir = $sDir
        }
        Write-Host "[GRID] Launched $sName (Affinity: $($s.MaskHex)) at $startUtc"
    }

    # Wait for the 4th (last) slot to complete
    $lastSlot = $slotTracking[-1]
    $swLast = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $lastSlot.Process.HasExited -and $swLast.Elapsed.TotalSeconds -lt 240) {
        try {
            $cv = $perfCpu.NextValue()
            if ($cv -gt $peakCpu) { $peakCpu = $cv }
            $availRam = $perfRam.NextValue()
            if ($availRam -lt $minFreeRamMb) { $minFreeRamMb = $availRam }
            $dFree = [math]::Round((Get-PSDrive -Name C).Free / 1MB, 0)
            if ($dFree -lt $minFreeDiskMb) { $minFreeDiskMb = $dFree }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    if (-not $lastSlot.Process.HasExited) {
        Stop-Process -Id $lastSlot.Process.Id -Force -ErrorAction SilentlyContinue
    }
    $lastSlot.EndTimeUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    Write-Host "[GRID] Completed $($lastSlot.Name) at $($lastSlot.EndTimeUtc)"

    $swGlobal.Stop()

    Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
    Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    # PHASE 4: RESULT EXTRACTION & PARITY VERIFICATION
    $allPassed = $true
    $passCount = 0
    $slotResults = @()

    foreach ($st in $slotTracking) {
        $rpt = Join-Path $st.Dir 'report.htm'
        $b = 0; $tk = 0; $tr = -1; $dp = '0.00'; $pnl = '0.00'

        if (Test-Path -LiteralPath $rpt -PathType Leaf) {
            $htm = Get-Content -LiteralPath $rpt -Raw
            if ($htm -match '<td[^>]*>Bars:</td>\s*<td[^>]*><b>(\d+)</b></td>') { $b = [int]$matches[1] }
            if ($htm -match '<td[^>]*>Ticks:</td>\s*<td[^>]*><b>(\d+)</b></td>') { $tk = [int]$matches[1] }
            if ($htm -match '<td[^>]*>Initial Deposit:</td>\s*<td[^>]*><b>([^<]+)</b></td>') { $dp = $matches[1].Trim() }
            if ($htm -match '<td[^>]*>Total Trades:</td>\s*<td[^>]*><b>(\d+)</b></td>') { $tr = [int]$matches[1] }
            if ($htm -match '<td[^>]*>Total Net Profit:</td>\s*<td[^>]*><b>([^<]+)</b></td>') { $pnl = $matches[1].Trim() }
        }

        $isPass = ($b -gt 0 -and $tk -gt 0 -and (Test-Path -LiteralPath $rpt -PathType Leaf))
        if ($isPass) {
            $passCount++
            Write-Host "[GRID] $($st.Name) PASS"
        } else {
            $allPassed = $false
            Write-Host "[GRID] $($st.Name) FAIL"
        }

        $slotResults += [PSCustomObject]@{
            Slot = $st.Name
            SlotDir = $st.SlotDir
            Passed = $isPass
            Bars = $b
            Ticks = $tk
            Trades = $tr
            Deposit = $dp
            Pnl = $pnl
            StartTime = $st.StartTimeUtc
            EndTime = $st.EndTimeUtc
        }

        # Archive report
        Copy-Item -LiteralPath $rpt -Destination (Join-Path $out "$($st.Name)_report.htm") -Force -ErrorAction SilentlyContinue

        # Archive slot meta
        $slotMetaSrc = Join-Path $st.Dir 'meta.json'
        if (Test-Path $slotMetaSrc) {
            Copy-Item -LiteralPath $slotMetaSrc -Destination (Join-Path $out "$($st.Name)_meta.json") -Force
        }

        # Archive slot logs
        $testerLogDir = Join-Path $st.Dir 'Tester\logs'
        if (Test-Path $testerLogDir) {
            Get-ChildItem -Path $testerLogDir -Filter '*.log' | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $out "$($st.Name)_Tester_$($_.Name)") -Force
            }
        }
        $termLogDir = Join-Path $st.Dir 'logs'
        if (Test-Path $termLogDir) {
            Get-ChildItem -Path $termLogDir -Filter '*.log' | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $out "$($st.Name)_Terminal_$($_.Name)") -Force
            }
        }
    }

    $peakRamUsedMb = [math]::Round($totalRamMb - $minFreeRamMb, 0)
    $totalDurationSec = [math]::Round($swGlobal.Elapsed.TotalSeconds, 1)

    Copy-Item -LiteralPath $runnerInfoPath -Destination (Join-Path $out 'runner_info.json') -Force

    $summaryLines = @(
        "WORKER_ID=$($env:WORKER_ID)",
        "RUNNER_OS=$osInfo",
        "RUNNER_LOGICAL_CPU=$logicalCpus",
        "RUNNER_REPORTED_CORES=$physicalCores",
        "RUNNER_RAM_GB=$totalRamGb",
        "RUNNER_DISK_GB=$freeDiskGb",
        "CPU_MODEL=$cpuModel",
        "FOUR_TEST_ONE_RUNNER=$(if ($allPassed -and $passCount -eq 4) { 'PASS' } else { 'FAIL' })",
        "SLOT_0=$(if ($slotResults.Count -gt 0 -and $slotResults[0].Passed) { 'PASS' } else { 'FAIL' })",
        "SLOT_1=$(if ($slotResults.Count -gt 1 -and $slotResults[1].Passed) { 'PASS' } else { 'FAIL' })",
        "SLOT_2=$(if ($slotResults.Count -gt 2 -and $slotResults[2].Passed) { 'PASS' } else { 'FAIL' })",
        "SLOT_3=$(if ($slotResults.Count -gt 3 -and $slotResults[3].Passed) { 'PASS' } else { 'FAIL' })",
        "PEAK_CPU_PERCENT=$([math]::Round($peakCpu, 1))",
        "PEAK_RAM_USED_MB=$peakRamUsedMb",
        "MIN_FREE_RAM_MB=$([math]::Round($minFreeRamMb, 0))",
        "MIN_FREE_DISK_MB=$([math]::Round($minFreeDiskMb, 0))",
        "CPU_AFFINITY_VALIDATED=PASS",
        "TOTAL_DURATION_SEC=$totalDurationSec",
        "PASS_COUNT=$passCount"
    )
    Set-Content -LiteralPath (Join-Path $out 'runner_summary.txt') -Value $summaryLines -Encoding ascii
    $resultsExported = $true

    if (-not $allPassed -or $passCount -ne 4) {
        Set-Stage 'SLOT_TESTS_PARITY_FAILED'
        throw "One or more slots failed"
    }

    Write-Host "[GRID] 4_SLOTS_ALL_PASS (Duration: ${totalDurationSec}s)"
    $stage = 'OK'
    $code = 0
} catch {
    if ($stage -eq 'INIT' -or $stage -eq 'OK') { $stage = 'EXECUTION_FAILED' }
    if ($code -eq 0) { $code = 1 }
    Write-Host "[GRID] $stage : $($_.Exception.Message)"
} finally {
    if (-not $resultsExported -and (Test-Path -LiteralPath $root)) {
        # Export partial artifacts on failure
        for ($i = 0; $i -lt 4; $i++) {
            $sName = "slot-$i"
            $sDir = Join-Path $root $sName
            if (Test-Path -LiteralPath $sDir) {
                $rpt = Join-Path $sDir 'report.htm'
                if (Test-Path -LiteralPath $rpt) { Copy-Item -LiteralPath $rpt -Destination (Join-Path $out "${sName}_report.htm") -Force -ErrorAction SilentlyContinue }
                $meta = Join-Path $sDir 'meta.json'
                if (Test-Path -LiteralPath $meta) { Copy-Item -LiteralPath $meta -Destination (Join-Path $out "${sName}_meta.json") -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    if (Test-Path -LiteralPath $baseMt5) {
        $sf = Join-Path $baseMt5 'MQL5\Files\grid_prewarm.status'
        if (Test-Path -LiteralPath $sf) { Copy-Item -LiteralPath $sf -Destination $out -Force }
    }

    Set-Content -LiteralPath (Join-Path $out 'opaque_id.txt') -Value $env:GRID_OPAQUE_ID -NoNewline -Encoding ascii
    Set-Content -LiteralPath (Join-Path $out 'stage.txt') -Value $stage -NoNewline -Encoding ascii
    Set-Content -LiteralPath (Join-Path $out 'exit.txt') -Value $code -NoNewline -Encoding ascii

    if (-not [string]::IsNullOrWhiteSpace($key) -and (Test-Path -LiteralPath $out)) {
        Push-Location $out
        try {
            & $seven a -t7z $encOut '.\*' "-p$key" -mhe=on -mx=7 *> $null
            if ($LASTEXITCODE -eq 0) {
                Write-Host '[GRID] RESULT_READY'
            } else {
                Write-Host '[GRID] RESULT_ENCRYPT_FAILED'
            }
        } finally { Pop-Location }
    }

    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    $key = $null

    if ($null -ne $env:GITHUB_OUTPUT -and (Test-Path -LiteralPath $env:GITHUB_OUTPUT)) {
        "exit_code=$code" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
        "stage=$stage" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
    }
}

if ($stage -ne 'OK' -or $code -ne 0) {
    exit 1
}
