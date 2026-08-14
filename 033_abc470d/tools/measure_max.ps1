param()

$ErrorActionPreference = "Stop"

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$build = Join-Path $root "build"
$source = Join-Path $root "abc470d_baseline.sv"
$image = Join-Path $build "abc470d_baseline.vvp"
$inputFile = Join-Path $build "max.in"
$outputFile = Join-Path $build "max.out"
$errorFile = Join-Path $build "max.err"
$generator = Join-Path $PSScriptRoot "max_case.py"

New-Item -ItemType Directory -Force -Path $build | Out-Null

& python $generator --generate $inputFile
if ($LASTEXITCODE -ne 0) {
    throw "maximum-case generation failed"
}

& iverilog -g2012 -Wall -DONLINE_JUDGE -DATCODER `
    -s abc470d_baseline -o $image $source
if ($LASTEXITCODE -ne 0) {
    throw "iverilog compilation failed"
}

$vvp = (Get-Command vvp -ErrorAction Stop).Source
$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = $vvp
$startInfo.Arguments = '-n "' + $image + '"'
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true

$process = New-Object System.Diagnostics.Process
$process.StartInfo = $startInfo
$inputStream = [System.IO.File]::OpenRead($inputFile)
$outputStream = [System.IO.File]::Create($outputFile)
$errorStream = [System.IO.File]::Create($errorFile)

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$started = $process.Start()
if (-not $started) {
    throw "failed to start vvp"
}

# Drain both output pipes while supplying input so none of the three streams
# can block another one on an OS pipe buffer.
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
    $peakBytes = [Math]::Max($peakBytes, [int64]$process.PeakWorkingSet64)
}
$outputTask.Wait()
$errorTask.Wait()
$stopwatch.Stop()
$process.Refresh()

$inputStream.Dispose()
$outputStream.Dispose()
$errorStream.Dispose()

if ($process.ExitCode -ne 0) {
    Get-Content -Raw -LiteralPath $errorFile
    throw "vvp failed with exit code $($process.ExitCode)"
}

& python $generator --verify $outputFile
if ($LASTEXITCODE -ne 0) {
    throw "maximum-case output verification failed"
}

$clockLine = Get-Content -LiteralPath $errorFile |
    Where-Object { $_ -match '^LOGICAL_CLOCKS=' } |
    Select-Object -First 1
if ($clockLine -notmatch '^LOGICAL_CLOCKS=(\d+) EXPECTED=(\d+)') {
    throw "logical-clock diagnostic is missing"
}
if (($Matches[1] -ne '500002') -or ($Matches[2] -ne '500002')) {
    throw "logical-clock count is not 500002: $clockLine"
}

$peakMiB = [Math]::Round($peakBytes / 1MB, 2)
$seconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)

Write-Output "MAX_CASE_OK=true"
Write-Output "N=500000 Q=500000 TYPE1_QUERIES=500000"
Write-Output $clockLine
Write-Output "VVP_SECONDS=$seconds"
Write-Output "PEAK_WORKING_SET_BYTES=$peakBytes"
Write-Output "PEAK_WORKING_SET_MIB=$peakMiB"
