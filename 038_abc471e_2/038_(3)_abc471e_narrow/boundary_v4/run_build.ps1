param(
    [Parameter(Mandatory=$true)][int]$Width,
    [Parameter(Mandatory=$true)][int]$Mod,
    [Parameter(Mandatory=$true)][int]$NMax,
    [Parameter(Mandatory=$true)][int]$ValueBytes,
    [Parameter(Mandatory=$true)][string]$OutputName,
    [ValidateSet('Full','Short')][string]$Regression = 'Full'
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$outputDir = Join-Path $PSScriptRoot $OutputName
$yosys = 'C:\Program Files\Renesas Electronics\Go Configure Software Hub\external\yosys\v59\yosys.exe'
$extractor = Join-Path $projectRoot 'tools\extract_resources.py'
$main = Join-Path $PSScriptRoot 'main.v'
$spi = Join-Path $PSScriptRoot 'spi_target.v'
$tb = Join-Path $PSScriptRoot 'boundary_v4_tb.v'

if (-not (Test-Path -LiteralPath $yosys)) {
    throw "ForgeFPGA bundled Yosys not found: $yosys"
}
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

$iverilogVersion = ((& iverilog -V 2>&1) | Select-Object -First 1) -join ''
$yosysVersion = ((& $yosys -V 2>&1) | Select-Object -First 1) -join ''
$mainHash = (Get-FileHash -LiteralPath $main -Algorithm SHA256).Hash.ToLower()
$spiHash = (Get-FileHash -LiteralPath $spi -Algorithm SHA256).Hash.ToLower()
$tbHash = (Get-FileHash -LiteralPath $tb -Algorithm SHA256).Hash.ToLower()
$countWidth = if ($NMax -le 1) { 1 } else {
    [int][Math]::Ceiling([Math]::Log($NMax + 1, 2))
}
$metadata = [ordered]@{
    architecture = 'boundary_v4'
    width = $Width
    mod = $Mod
    n_max = $NMax
    count_width = $countWidth
    value_bytes = $ValueBytes
    main_sha256 = $mainHash
    spi_target_sha256 = $spiHash
    testbench_sha256 = $tbHash
    regression = $Regression.ToLowerInvariant()
    iverilog = $iverilogVersion
    yosys = $yosysVersion
    yosys_options = 'flatten=true noDSP=true ABC9=true autoname=true'
}
$metadata | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $outputDir 'config.json')

$vvp = Join-Path $outputDir 'boundary_v4_tb.vvp'
$regressionDefine = if ($Regression -eq 'Short') {
    '-DBOUNDARY_SHORT=1'
} else {
    '-DBOUNDARY_FULL=1'
}
$compileOutput = @(& iverilog -g2012 -s compact_v3_tb `
    "-DTEST_WIDTH=$Width" "-DTEST_MOD=$Mod" "-DTEST_N_MAX=$NMax" `
    "-DTEST_VALUE_BYTES=$ValueBytes" $regressionDefine `
    -o $vvp $main $spi $tb 2>&1)
$compileOutput | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $outputDir 'icarus_compile.log')
if ($LASTEXITCODE -ne 0) {
    throw "Icarus compile failed for $OutputName"
}
$simOutput = @(& vvp $vvp 2>&1)
$simOutput | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $outputDir 'icarus.log')
if ($LASTEXITCODE -ne 0 -or
    -not ($simOutput | Where-Object { $_ -match '^SUMMARY .*FAIL=0$' })) {
    throw "Icarus simulation failed for $OutputName"
}

$mainYosys = $main.Replace('\', '/')
$spiYosys = $spi.Replace('\', '/')
$synthScript = @"
read_verilog -sv "$mainYosys" "$spiYosys"
chparam -set WIDTH $Width -set MOD $Mod -set N_MAX $NMax -set VALUE_BYTES $ValueBytes main
hierarchy -check
flatten -noscopeinfo
synth_xilinx -nobram -noiopad -nodsp -abc9
clean
autoname
write_verilog "post_synth_results.v"
write_edif "netlist.edif"
tee -q -o post_synth_report.txt stat
"@
$synthScript | Set-Content -Encoding ASCII -LiteralPath (Join-Path $outputDir 'synth_script.ys')

Push-Location $outputDir
try {
    $synthOutput = @(& $yosys -s 'synth_script.ys' 2>&1)
    $synthOutput | Set-Content -Encoding UTF8 -LiteralPath 'synth.log'
    if ($LASTEXITCODE -ne 0) {
        throw "Forge/Yosys synthesis failed for $OutputName"
    }
} finally {
    Pop-Location
}

$resourceJson = Join-Path $outputDir 'resource_summary.json'
$resourceText = Join-Path $outputDir 'resource_summary.txt'
& python $extractor --report (Join-Path $outputDir 'post_synth_report.txt') `
    --width $Width --mod $Mod --n-max $NMax --json-out $resourceJson `
    --text-out $resourceText | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Resource extraction failed for $OutputName"
}
$resource = Get-Content -Raw -Encoding UTF8 -LiteralPath $resourceJson | ConvertFrom-Json
Write-Host "$OutputName PASS: LUT=$($resource.lut_total) FF=$($resource.ff_total) CARRY4=$($resource.CARRY4) MUXF7=$($resource.MUXF7) MUXF8=$($resource.MUXF8)"
