param(
    [int]$Runs = 3,
    [string[]]$OnlyCase = @(),
    [string[]]$OnlyImplementation = @()
)

$ErrorActionPreference = "Stop"
if ($Runs -ne 3) {
    throw "This measurement uses exactly three runs per condition"
}

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$build = Join-Path $root "build\fast_vvp\measurement"
$caseDir = Join-Path $build "cases"
$resultDir = Join-Path $root "measurements"
$csvPath = Join-Path $resultDir "fast_vvp_results.csv"
$generator = Join-Path $PSScriptRoot "fast_vvp_cases.py"

New-Item -ItemType Directory -Force -Path $build, $caseDir, $resultDir |
    Out-Null

& python $generator --output-dir $caseDir
if ($LASTEXITCODE -ne 0) {
    throw "maximum-case generation failed"
}
$manifest = Get-Content -Raw -LiteralPath (Join-Path $caseDir "manifest.json") |
    ConvertFrom-Json

$implementations = @(
    [PSCustomObject]@{
        Name = "baseline"
        Module = "abc470d_baseline"
        Source = Join-Path $root "abc470d_baseline.sv"
    },
    [PSCustomObject]@{
        Name = "permutation_compiler"
        Module = "abc470d_permutation_compiler"
        Source = Join-Path $root "abc470d_permutation_compiler.sv"
    },
    [PSCustomObject]@{
        Name = "fast_vvp"
        Module = "abc470d_fast_vvp"
        Source = Join-Path $root "abc470d_fast_vvp.sv"
    }
)

if ($OnlyImplementation.Count -gt 0) {
    $implementations = @(
        $implementations |
            Where-Object { $_.Name -in $OnlyImplementation }
    )
    if ($implementations.Count -ne $OnlyImplementation.Count) {
        throw "unknown or duplicate OnlyImplementation value"
    }
}

$images = @{}
foreach ($implementation in $implementations) {
    $image = Join-Path $build "$($implementation.Name).vvp"
    $compileArgs = @(
        "-g2012",
        "-Wall",
        "-DONLINE_JUDGE",
        "-DATCODER",
        "-s",
        $implementation.Module,
        "-o",
        $image,
        $implementation.Source
    )
    & iverilog @compileArgs
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
    if (-not $process.Start()) {
        throw "failed to start vvp"
    }

    $inputTask = $inputStream.CopyToAsync($process.StandardInput.BaseStream)
    $outputTask = $process.StandardOutput.BaseStream.CopyToAsync($outputStream)
    $errorTask = $process.StandardError.BaseStream.CopyToAsync($errorStream)
    $inputTask.Wait()
    $process.StandardInput.Close()

    $peakBytes = 0L
    while (-not $process.WaitForExit(5)) {
        $process.Refresh()
        $peakBytes = [Math]::Max(
            $peakBytes,
            [int64]$process.WorkingSet64
        )
        $peakBytes = [Math]::Max(
            $peakBytes,
            [int64]$process.PeakWorkingSet64
        )
    }
    $outputTask.Wait()
    $errorTask.Wait()
    $stopwatch.Stop()
    $process.Refresh()
    $peakBytes = [Math]::Max(
        $peakBytes,
        [int64]$process.PeakWorkingSet64
    )

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
    }
}

$results = @()
foreach ($case in $manifest.cases) {
    if (($OnlyCase.Count -gt 0) -and ($case.name -notin $OnlyCase)) {
        continue
    }
    foreach ($implementation in $implementations) {
        $times = @()
        $peaks = @()
        for ($run = 1; $run -le $Runs; $run++) {
            Write-Output (
                "RUN case={0} impl={1} repetition={2}/{3}" -f
                $case.name, $implementation.Name, $run, $Runs
            )
            $outputFile = Join-Path $build "current.out"
            $errorFile = Join-Path $build "current.err"
            $invokeArgs = @{
                Image = $images[$implementation.Name]
                InputFile = [string]$case.input
                OutputFile = $outputFile
                ErrorFile = $errorFile
            }
            $measured = Invoke-MeasuredVvp @invokeArgs

            & python $generator --verify $outputFile ([string]$case.expected)
            if ($LASTEXITCODE -ne 0) {
                throw (
                    "output mismatch: case={0}, implementation={1}, run={2}" -f
                    $case.name, $implementation.Name, $run
                )
            }
            $times += [double]$measured.Seconds
            $peaks += [int64]$measured.PeakBytes
        }

        $ordered = @($times | Sort-Object)
        $median = $ordered[1]
        $peak = ($peaks | Measure-Object -Maximum).Maximum
        $results += [PSCustomObject]@{
            case = [string]$case.name
            implementation = $implementation.Name
            n = [int]$case.n
            q = [int]$case.q
            type1_count = [int]$case.type1_count
            type2_count = [int]$case.type2_count
            input_bytes = (Get-Item -LiteralPath $case.input).Length
            run1_seconds = [Math]::Round($times[0], 6)
            run2_seconds = [Math]::Round($times[1], 6)
            run3_seconds = [Math]::Round($times[2], 6)
            median_seconds = [Math]::Round($median, 6)
            peak_working_set_bytes = [int64]$peak
            peak_working_set_mib = [Math]::Round($peak / 1MB, 2)
        }
        Write-Output (
            "PASS case={0} impl={1} median={2:F3}s peak={3:F2}MiB" -f
            $case.name, $implementation.Name, $median, ($peak / 1MB)
        )
    }
}

$results | Export-Csv -NoTypeInformation -Encoding utf8 -LiteralPath $csvPath
Write-Output $csvPath
