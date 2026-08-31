$ErrorActionPreference = "Stop"

$workspace = Split-Path -Parent $PSScriptRoot
$buildDirectory = Join-Path $PSScriptRoot "build"
$simulation = Join-Path $buildDirectory "abc472b_tb.vvp"

New-Item -ItemType Directory -Force -Path $buildDirectory | Out-Null

& iverilog -g2012 -Wall -s tb_abc472b -o $simulation `
    (Join-Path $workspace "ffpga/src/spi_target.v") `
    (Join-Path $workspace "ffpga/src/main.v") `
    (Join-Path $PSScriptRoot "tb_abc472b.v")

if ($LASTEXITCODE -ne 0) {
    if (Test-Path -LiteralPath $simulation) {
        Remove-Item -LiteralPath $simulation -Force
    }
    exit $LASTEXITCODE
}

& vvp $simulation
$simulationResult = $LASTEXITCODE
Remove-Item -LiteralPath $simulation -Force
exit $simulationResult
