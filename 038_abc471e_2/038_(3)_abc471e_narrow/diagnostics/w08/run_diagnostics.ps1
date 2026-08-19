$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$yosys = 'C:\Program Files\Renesas Electronics\Go Configure Software Hub\external\yosys\v59\yosys.exe'
$extractor = Join-Path $root 'tools\extract_resources.py'
$baselineResource = Join-Path $root 'experiments\w08\resource_summary.json'

if (-not (Test-Path -LiteralPath $yosys)) {
    throw "ForgeFPGA bundled Yosys not found: $yosys"
}

$variants = @(
    [pscustomobject]@{ Name='coefficient_pow_fixed'; Level=1; HasLevelParameter=$true },
    [pscustomobject]@{ Name='input_only'; Level=2; HasLevelParameter=$false },
    [pscustomobject]@{ Name='protocol_only'; Level=3; HasLevelParameter=$false }
)

$iverilogVersion = ((& iverilog -V 2>&1) | Select-Object -First 1) -join ''
$yosysVersion = ((& $yosys -V 2>&1) | Select-Object -First 1) -join ''
$rows = @()

foreach ($variant in $variants) {
    $dir = Join-Path $PSScriptRoot $variant.Name
    $main = Join-Path $dir 'main.v'
    $spi = Join-Path $dir 'spi_target.v'
    $tb = Join-Path $dir 'diagnostic_tb.v'

    # Static absence checks complement the dynamic testbench checks.
    $source = Get-Content -Raw -Encoding UTF8 -LiteralPath $main
    if ($variant.Name -eq 'coefficient_pow_fixed' -and
        $source -match 'comb_n|comb_r|comb_i|numerator|denominator|pow_result|pow_base|pow_exp|C_POW') {
        throw 'coefficient_pow_fixed still contains combination/pow state'
    }
    if ($variant.Name -eq 'input_only' -and
        $source -match 'C_FINAL|term_square|term_pair|coeff_|pow_|comb_') {
        throw 'input_only still contains final/combination/pow state'
    }
    if ($variant.Name -eq 'protocol_only' -and
        $source -match 'modular_multiplier|mul_start|mod_arith|C_INPUT|C_FINAL|reg \[WIDTH-1:0\] s[12]') {
        throw 'protocol_only still contains arithmetic state'
    }

    $metadata = [ordered]@{
        diagnostic = $variant.Name
        diagnostic_level = $variant.Level
        width = 8
        mod = 251
        n_max = 250
        iverilog = $iverilogVersion
        yosys = $yosysVersion
        yosys_options = 'flatten=true noDSP=true ABC9=true autoname=true'
    }
    $metadata | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $dir 'config.json')

    $vvp = Join-Path $dir 'diagnostic_tb.vvp'
    $compileOutput = @(& iverilog -g2012 -s diagnostic_tb `
        "-DTEST_DIAG_LEVEL=$($variant.Level)" -o $vvp $main $spi $tb 2>&1)
    [string]::Join("`r`n", $compileOutput) | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $dir 'icarus_compile.log')
    if ($LASTEXITCODE -ne 0) {
        throw "Icarus compile failed: $($variant.Name)"
    }
    $simOutput = @(& vvp $vvp 2>&1)
    $simOutput | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $dir 'icarus.log')
    if ($LASTEXITCODE -ne 0 -or
        -not ($simOutput | Where-Object { $_ -match '^SUMMARY .*FAIL=0$' })) {
        throw "Icarus simulation failed: $($variant.Name)"
    }

    $chparam = if ($variant.HasLevelParameter) {
        'chparam -set DIAG_LEVEL 1 -set WIDTH 8 -set MOD 251 -set N_MAX 250 main'
    } else {
        'chparam -set WIDTH 8 -set MOD 251 -set N_MAX 250 main'
    }
    $synthScript = @"
read_verilog -sv "main.v" "spi_target.v"
$chparam
hierarchy -check
flatten -noscopeinfo
synth_xilinx -nobram -noiopad -nodsp -abc9
clean
autoname
write_verilog "post_synth_results.v"
write_edif "netlist.edif"
tee -q -o post_synth_report.txt stat
"@
    $synthScript | Set-Content -Encoding ASCII -LiteralPath (Join-Path $dir 'synth_script.ys')

    Push-Location $dir
    try {
        $synthOutput = @(& $yosys -s 'synth_script.ys' 2>&1)
        $synthOutput | Set-Content -Encoding UTF8 -LiteralPath 'synth.log'
        if ($LASTEXITCODE -ne 0) {
            throw "Forge/Yosys synthesis failed: $($variant.Name)"
        }
    } finally {
        Pop-Location
    }

    $resourceJson = Join-Path $dir 'resource_summary.json'
    $resourceText = Join-Path $dir 'resource_summary.txt'
    & python $extractor --report (Join-Path $dir 'post_synth_report.txt') `
        --width 8 --mod 251 --n-max 250 --json-out $resourceJson `
        --text-out $resourceText | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Resource extraction failed: $($variant.Name)"
    }
    $resource = Get-Content -Raw -Encoding UTF8 -LiteralPath $resourceJson | ConvertFrom-Json
    $row = [ordered]@{ diagnostic=$variant.Name }
    foreach ($property in $resource.PSObject.Properties) {
        $row[$property.Name] = $property.Value
    }
    $rows += [pscustomobject]$row
    Write-Host "$($variant.Name): Icarus PASS, synthesis PASS, LUT=$($resource.lut_total) FF=$($resource.ff_total) CARRY4=$($resource.CARRY4)"
}

$baseline = Get-Content -Raw -Encoding UTF8 -LiteralPath $baselineResource | ConvertFrom-Json
$baselineRow = [ordered]@{ diagnostic='W08_BASELINE' }
foreach ($property in $baseline.PSObject.Properties) {
    $baselineRow[$property.Name] = $property.Value
}
$allRows = @([pscustomobject]$baselineRow) + $rows
$allRows | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot 'resource_comparison.csv')
$allRows | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot 'resource_comparison.json')
