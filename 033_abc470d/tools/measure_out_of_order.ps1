param(
    [int]$Runs = 3,
    [string[]]$OnlyCase = @()
)

$ErrorActionPreference = "Stop"
if ($Runs -ne 3) {
    throw "SPEC requires exactly three runs per condition"
}

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$build = Join-Path $root "build\out_of_order"
$caseDir = Join-Path $build "cases"
$resultDir = Join-Path $root "measurements"
$defaultCsvPath = Join-Path $resultDir "out_of_order_results.csv"
$generator = Join-Path $PSScriptRoot "out_of_order_cases.py"

New-Item -ItemType Directory -Force -Path $build, $caseDir, $resultDir |
    Out-Null

& python $generator --output-dir $caseDir
if ($LASTEXITCODE -ne 0) {
    throw "performance-case generation failed"
}
$manifest = Get-Content -Raw -LiteralPath (Join-Path $caseDir "manifest.json") |
    ConvertFrom-Json

if ($OnlyCase.Count -gt 0) {
    $knownCases = @($manifest.cases | ForEach-Object { [string]$_.name })
    foreach ($selectedCase in $OnlyCase) {
        if ($selectedCase -notin $knownCases) {
            throw "unknown case: $selectedCase"
        }
    }
    $csvPath = Join-Path $build "selected_results.csv"
} else {
    $csvPath = $defaultCsvPath
}

$implementations = @(
    [PSCustomObject]@{
        Name = "baseline_k1"
        Module = "abc470d_baseline"
        Source = Join-Path $root "abc470d_baseline.sv"
        Extra = @()
    },
    [PSCustomObject]@{
        Name = "fixed_k256"
        Module = "abc470d_fixed_parallel"
        Source = Join-Path $root "abc470d_fixed_parallel.sv"
        Extra = @("-P", "abc470d_fixed_parallel.K=256")
    },
    [PSCustomObject]@{
        Name = "ooo_256_1024_off"
        Module = "abc470d_out_of_order"
        Source = Join-Path $root "abc470d_out_of_order.sv"
        Extra = @(
            "-P", "abc470d_out_of_order.ISSUE_WIDTH=256",
            "-P", "abc470d_out_of_order.LOOKAHEAD=1024",
            "-P", "abc470d_out_of_order.ENABLE_CANCEL=0"
        )
    },
    [PSCustomObject]@{
        Name = "ooo_256_1024_on"
        Module = "abc470d_out_of_order"
        Source = Join-Path $root "abc470d_out_of_order.sv"
        Extra = @(
            "-P", "abc470d_out_of_order.ISSUE_WIDTH=256",
            "-P", "abc470d_out_of_order.LOOKAHEAD=1024",
            "-P", "abc470d_out_of_order.ENABLE_CANCEL=1"
        )
    }
)

$images = @{}
foreach ($implementation in $implementations) {
    $image = Join-Path $build "$($implementation.Name).vvp"
    $arguments = @(
        "-g2012",
        "-Wall",
        "-DONLINE_JUDGE",
        "-DATCODER",
        "-s",
        $implementation.Module
    ) + $implementation.Extra + @(
        "-o",
        $image,
        $implementation.Source
    )
    & iverilog @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "compilation failed: $($implementation.Name)"
    }
    $images[$implementation.Name] = $image
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

$results = @()
foreach ($case in $manifest.cases) {
    if (($OnlyCase.Count -gt 0) -and ($case.name -notin $OnlyCase)) {
        continue
    }
    foreach ($implementation in $implementations) {
        if (($case.name -eq "strong_dependency") -and
            ($implementation.Name -notin @(
                "fixed_k256",
                "ooo_256_1024_off"
            ))) {
            continue
        }
        $times = @()
        $peaks = @()
        $recorded = $null

        for ($run = 1; $run -le $Runs; $run++) {
            $outputFile = Join-Path $build "current.out"
            $errorFile = Join-Path $build "current.err"
            $measured = Invoke-MeasuredVvp `
                -Image $images[$implementation.Name] `
                -InputFile ([string]$case.input) `
                -OutputFile $outputFile `
                -ErrorFile $errorFile

            & python $generator --verify $outputFile ([string]$case.expected)
            if ($LASTEXITCODE -ne 0) {
                throw "output mismatch: case=$($case.name), " +
                    "implementation=$($implementation.Name), run=$run"
            }

            $logicalClocks = 0L
            $queryClocks = 0L
            $issueCycles = 0L
            $type1Executed = 0L
            $type1Canceled = 0L
            $type2Executed = 0L
            $type2Eliminated = 0L

            if ($implementation.Name -eq "baseline_k1") {
                if ($measured.Diagnostic -notmatch
                    'LOGICAL_CLOCKS=(\d+) EXPECTED=(\d+)') {
                    throw "Baseline diagnostic missing"
                }
                $logicalClocks = [int64]$Matches[1]
                if ($logicalClocks -ne [int64]$case.baseline_logical_clocks) {
                    throw "Baseline clock mismatch: case=$($case.name)"
                }
                $queryClocks = $logicalClocks - 2
                $issueCycles = [int64]$case.type1_count
                $type1Executed = [int64]$case.type1_count
                $type2Executed = [int64]$case.type2_count
            } elseif ($implementation.Name -eq "fixed_k256") {
                if ($measured.Diagnostic -notmatch
                    'LOGICAL_CLOCKS=(\d+) QUERY_CLOCKS=(\d+) K=(\d+)') {
                    throw "Fixed diagnostic missing"
                }
                $logicalClocks = [int64]$Matches[1]
                $queryClocks = [int64]$Matches[2]
                if (($logicalClocks -ne
                    [int64]$case.fixed_k256_logical_clocks) -or
                    ([int]$Matches[3] -ne 256)) {
                    throw "Fixed clock mismatch: case=$($case.name)"
                }
                $issueCycles = $queryClocks - [int64]$case.type2_count
                $type1Executed = [int64]$case.type1_count
                $type2Executed = [int64]$case.type2_count
            } else {
                $pattern =
                    'LOGICAL_CLOCKS=(\d+) QUERY_CLOCKS=(\d+) ' +
                    'ISSUE_CYCLES=(\d+) TYPE1_EXECUTED=(\d+) ' +
                    'TYPE1_CANCELED=(\d+) TYPE2_EXECUTED=(\d+) ' +
                    'TYPE2_ELIMINATED=(\d+) ISSUE_WIDTH=(\d+) ' +
                    'LOOKAHEAD=(\d+) CANCEL=(\d+)'
                if ($measured.Diagnostic -notmatch $pattern) {
                    throw "OoO diagnostic missing: $($implementation.Name)"
                }
                $logicalClocks = [int64]$Matches[1]
                $queryClocks = [int64]$Matches[2]
                $issueCycles = [int64]$Matches[3]
                $type1Executed = [int64]$Matches[4]
                $type1Canceled = [int64]$Matches[5]
                $type2Executed = [int64]$Matches[6]
                $type2Eliminated = [int64]$Matches[7]
                $expectedCancel = if (
                    $implementation.Name -eq "ooo_256_1024_on"
                ) { 1 } else { 0 }
                if (([int]$Matches[8] -ne 256) -or
                    ([int]$Matches[9] -ne 1024) -or
                    ([int]$Matches[10] -ne $expectedCancel)) {
                    throw "OoO parameter mismatch: $($implementation.Name)"
                }
                if (($logicalClocks -ne $queryClocks + 2) -or
                    ($queryClocks -ne $issueCycles + $type2Executed) -or
                    ($type1Executed + $type1Canceled -ne
                        [int64]$case.type1_count) -or
                    ($type2Executed + $type2Eliminated -ne
                        [int64]$case.type2_count)) {
                    throw "OoO statistic invariant failed: " +
                        "case=$($case.name), impl=$($implementation.Name)"
                }
                if (($expectedCancel -eq 0) -and
                    (($type1Canceled -ne 0) -or ($type2Eliminated -ne 0))) {
                    throw "cancellation occurred in OFF mode"
                }
                if (($case.name -eq "strong_dependency") -and
                    ($implementation.Name -eq "ooo_256_1024_off") -and
                    ($logicalClocks -ne 500002)) {
                    throw "Strong dependency clock mismatch"
                }
            }

            $currentRecord = @(
                $logicalClocks,
                $queryClocks,
                $issueCycles,
                $type1Executed,
                $type1Canceled,
                $type2Executed,
                $type2Eliminated
            ) -join ":"
            if ($null -eq $recorded) {
                $recorded = $currentRecord
            } elseif ($recorded -ne $currentRecord) {
                throw "non-deterministic counters: case=$($case.name), " +
                    "implementation=$($implementation.Name)"
            }

            $times += $measured.Seconds
            $peaks += $measured.PeakBytes
        }

        $counter = $recorded.Split(":")
        $logicalClocks = [int64]$counter[0]
        $queryClocks = [int64]$counter[1]
        $issueCycles = [int64]$counter[2]
        $type1Executed = [int64]$counter[3]
        $type1Canceled = [int64]$counter[4]
        $type2Executed = [int64]$counter[5]
        $type2Eliminated = [int64]$counter[6]
        $sortedTimes = @($times | Sort-Object)
        $medianSeconds = [double]$sortedTimes[1]
        $peakBytes = [int64](($peaks | Measure-Object -Maximum).Maximum)
        if ($issueCycles -gt 0) {
            $averageIssued = [Math]::Round(
                $type1Executed / [double]$issueCycles,
                3
            )
            $issueEfficiency = [Math]::Round(
                100.0 * $averageIssued / 256.0,
                3
            )
        } else {
            $averageIssued = 0.0
            $issueEfficiency = 0.0
        }

        $row = [PSCustomObject]@{
            case = [string]$case.name
            implementation = [string]$implementation.Name
            logical_clocks = $logicalClocks
            equivalent_50mhz_ms = [Math]::Round($logicalClocks * 0.00002, 6)
            query_clocks = $queryClocks
            issue_cycles = $issueCycles
            type1_executed = $type1Executed
            type1_canceled = $type1Canceled
            type2_executed = $type2Executed
            type2_eliminated = $type2Eliminated
            average_issued = $averageIssued
            issue_efficiency_percent = $issueEfficiency
            run1_seconds = [Math]::Round([double]$times[0], 3)
            run2_seconds = [Math]::Round([double]$times[1], 3)
            run3_seconds = [Math]::Round([double]$times[2], 3)
            median_seconds = [Math]::Round($medianSeconds, 3)
            peak_working_set_bytes = $peakBytes
            peak_working_set_mib = [Math]::Round($peakBytes / 1MB, 2)
        }
        $results += $row
        $message = (
            "RESULT case={0} impl={1} clocks={2} median_s={3} " +
            "peak_MiB={4} avg_issue={5} canceled={6} t2_elim={7}"
        ) -f @(
            $row.case,
            $row.implementation,
            $row.logical_clocks,
            $row.median_seconds,
            $row.peak_working_set_mib,
            $row.average_issued,
            $row.type1_canceled,
            $row.type2_eliminated
        )
        Write-Output $message
    }
}

$results | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath $csvPath
Write-Output "CSV=$csvPath"
