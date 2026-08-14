param(
    [int[]]$FixedKs = @(4, 8, 16, 32, 64, 128, 256, 512),
    [int]$Runs = 3,
    [switch]$SkipBaseline,
    [switch]$Append
)

$ErrorActionPreference = "Stop"

if ($Runs -ne 3) {
    throw "SPEC requires exactly three runs per condition"
}

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$build = Join-Path $root "build\fixed_parallel"
$caseDir = Join-Path $build "cases"
$resultDir = Join-Path $root "measurements"
$csvPath = Join-Path $resultDir "fixed_parallel_results.csv"
$fixedSource = Join-Path $root "abc470d_fixed_parallel.sv"
$baselineSource = Join-Path $root "abc470d_baseline.sv"
$generator = Join-Path $PSScriptRoot "fixed_parallel_cases.py"

New-Item -ItemType Directory -Force -Path $build, $caseDir, $resultDir |
    Out-Null

& python $generator --output-dir $caseDir
if ($LASTEXITCODE -ne 0) {
    throw "performance-case generation failed"
}
$manifest = Get-Content -Raw -LiteralPath (Join-Path $caseDir "manifest.json") |
    ConvertFrom-Json

$images = @{}
$allKs = @()
if (-not $SkipBaseline) {
    $baselineImage = Join-Path $build "baseline_k1.vvp"
    & iverilog -g2012 -Wall -DONLINE_JUDGE -DATCODER `
        -s abc470d_baseline -o $baselineImage $baselineSource
    if ($LASTEXITCODE -ne 0) {
        throw "Baseline compilation failed"
    }
    $images[1] = $baselineImage
    $allKs += 1
}

foreach ($k in $FixedKs) {
    if ($k -lt 1) {
        throw "K must be positive: $k"
    }
    $image = Join-Path $build "fixed_k$k.vvp"
    & iverilog -g2012 -Wall -DONLINE_JUDGE -DATCODER `
        -s abc470d_fixed_parallel `
        -P "abc470d_fixed_parallel.K=$k" `
        -o $image $fixedSource
    if ($LASTEXITCODE -ne 0) {
        throw "fixed-width compilation failed for K=$k"
    }
    $images[$k] = $image
    $allKs += $k
}

$vvp = (Get-Command vvp -ErrorAction Stop).Source

function Invoke-MeasuredVvp {
    param(
        [string]$Image,
        [string]$InputFile,
        [string]$OutputFile,
        [string]$ErrorFile
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $vvp
    $startInfo.Arguments = '-n "' + $Image + '"'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $inputStream = [System.IO.File]::OpenRead($InputFile)
    $outputStream = [System.IO.File]::Create($OutputFile)
    $errorStream = [System.IO.File]::Create($ErrorFile)

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $started = $process.Start()
    if (-not $started) {
        throw "failed to start vvp"
    }

    $inputTask = $inputStream.CopyToAsync($process.StandardInput.BaseStream)
    $outputTask = $process.StandardOutput.BaseStream.CopyToAsync($outputStream)
    $errorTask = $process.StandardError.BaseStream.CopyToAsync($errorStream)
    $inputTask.Wait()
    $process.Refresh()
    $peakBytes = [Math]::Max(
        [int64]$process.WorkingSet64,
        [int64]$process.PeakWorkingSet64
    )
    $process.StandardInput.Close()
    while (-not $process.WaitForExit(5)) {
        $process.Refresh()
        $peakBytes = [Math]::Max($peakBytes, [int64]$process.WorkingSet64)
        $peakBytes = [Math]::Max(
            $peakBytes,
            [int64]$process.PeakWorkingSet64
        )
    }
    $outputTask.Wait()
    $errorTask.Wait()
    $stopwatch.Stop()

    $inputStream.Dispose()
    $outputStream.Dispose()
    $errorStream.Dispose()

    if ($process.ExitCode -ne 0) {
        $diagnostic = Get-Content -Raw -LiteralPath $ErrorFile
        throw "vvp failed with $($process.ExitCode): $diagnostic"
    }

    return [PSCustomObject]@{
        Seconds = $stopwatch.Elapsed.TotalSeconds
        PeakBytes = $peakBytes
        Diagnostic = Get-Content -Raw -LiteralPath $ErrorFile
    }
}

$newResults = @()
foreach ($case in $manifest.cases) {
    $inputFile = [string]$case.input
    $expectedFile = [string]$case.expected

    foreach ($k in $allKs) {
        $expectedClock = [int64]$case.logical_clocks.PSObject.Properties["$k"].Value
        $times = @()
        $peaks = @()

        for ($run = 1; $run -le $Runs; $run++) {
            $outputFile = Join-Path $build "current.out"
            $errorFile = Join-Path $build "current.err"
            $measured = Invoke-MeasuredVvp `
                -Image $images[$k] `
                -InputFile $inputFile `
                -OutputFile $outputFile `
                -ErrorFile $errorFile

            & python $generator --verify $outputFile $expectedFile
            if ($LASTEXITCODE -ne 0) {
                throw "output mismatch: case=$($case.name), K=$k, run=$run"
            }

            if ($k -eq 1) {
                $pattern = 'LOGICAL_CLOCKS=(\d+) EXPECTED=(\d+)'
                if ($measured.Diagnostic -notmatch $pattern) {
                    throw "Baseline clock diagnostic missing"
                }
                $actualClock = [int64]$Matches[1]
                $queryClock = $actualClock - 2
            } else {
                $pattern = 'LOGICAL_CLOCKS=(\d+) QUERY_CLOCKS=(\d+) K=(\d+)'
                if ($measured.Diagnostic -notmatch $pattern) {
                    throw "fixed clock diagnostic missing for K=$k"
                }
                $actualClock = [int64]$Matches[1]
                $queryClock = [int64]$Matches[2]
                if ([int]$Matches[3] -ne $k) {
                    throw "reported K mismatch for K=$k"
                }
            }
            if (($actualClock -ne $expectedClock) -or
                ($queryClock -ne $expectedClock - 2)) {
                throw "clock mismatch: case=$($case.name), K=$k, " +
                    "actual=$actualClock, expected=$expectedClock"
            }

            $times += $measured.Seconds
            $peaks += $measured.PeakBytes
        }

        $sortedTimes = @($times | Sort-Object)
        $medianSeconds = [double]$sortedTimes[1]
        $peakBytes = [int64](($peaks | Measure-Object -Maximum).Maximum)
        $row = [PSCustomObject]@{
            case = [string]$case.name
            k = [int]$k
            logical_clocks = $expectedClock
            equivalent_50mhz_ms = [Math]::Round($expectedClock * 0.00002, 6)
            run1_seconds = [Math]::Round([double]$times[0], 3)
            run2_seconds = [Math]::Round([double]$times[1], 3)
            run3_seconds = [Math]::Round([double]$times[2], 3)
            median_seconds = [Math]::Round($medianSeconds, 3)
            peak_working_set_bytes = $peakBytes
            peak_working_set_mib = [Math]::Round($peakBytes / 1MB, 2)
        }
        $newResults += $row
        $message = (
            "RESULT case={0} K={1} clocks={2} 50MHz_ms={3} " +
            "median_s={4} peak_MiB={5}"
        ) -f @(
            $row.case,
            $row.k,
            $row.logical_clocks,
            $row.equivalent_50mhz_ms,
            $row.median_seconds,
            $row.peak_working_set_mib
        )
        Write-Output $message
    }
}

if ($Append -and (Test-Path -LiteralPath $csvPath)) {
    $existing = @(Import-Csv -LiteralPath $csvPath)
    $replaceKeys = @{}
    foreach ($row in $newResults) {
        $replaceKeys["$($row.case):$($row.k)"] = $true
    }
    $kept = @($existing | Where-Object {
        -not $replaceKeys.ContainsKey("$($_.case):$($_.k)")
    })
    @($kept + $newResults) |
        Sort-Object case, @{Expression = {[int]$_.k}} |
        Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath $csvPath
} else {
    $newResults |
        Sort-Object case, k |
        Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath $csvPath
}

Write-Output "CSV=$csvPath"
