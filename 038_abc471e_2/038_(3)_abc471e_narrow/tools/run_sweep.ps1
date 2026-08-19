param(
    [switch]$SkipSimulation,
    [switch]$SkipSynthesis
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$experiments = Join-Path $root 'experiments'
$rtlMain = Join-Path $root 'ffpga\src\main.v'
$rtlSpi = Join-Path $root 'ffpga\src\spi_target.v'
$testbench = Join-Path $root 'sim\abc471e_narrow_tb.v'
$configTool = Join-Path $PSScriptRoot 'width_configs.py'
$resourceTool = Join-Path $PSScriptRoot 'extract_resources.py'
$yosys = 'C:\Program Files\Renesas Electronics\Go Configure Software Hub\external\yosys\v59\yosys.exe'

if (-not (Test-Path -LiteralPath $yosys)) {
    throw "ForgeFPGA bundled Yosys not found: $yosys"
}

New-Item -ItemType Directory -Force -Path $experiments | Out-Null
$configDocument = python $configTool --json | ConvertFrom-Json
$configs = @($configDocument | ForEach-Object { $_ })
if ($configs.Count -eq 1 -and $configs[0] -is [System.Array]) {
    $configs = @($configs[0])
}
$configs | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $experiments 'configs.json')

$iverilogVersion = ((& iverilog -V 2>&1) | Select-Object -First 1) -join ''
$yosysVersion = ((& $yosys -V 2>&1) | Select-Object -First 1) -join ''
$summary = @()

foreach ($config in $configs) {
    $width = [int]$config.width
    $mod = [int]$config.mod
    $nMax = [int]$config.n_max
    $name = 'w{0:D2}' -f $width
    $experiment = Join-Path $experiments $name
    New-Item -ItemType Directory -Force -Path $experiment | Out-Null

    $metadata = [ordered]@{
        width = $width
        mod = $mod
        n_max = $nMax
        prime_verified = [bool]$config.prime_verified
        architecture = 'single parameterized S1/S2 RTL'
        iverilog = $iverilogVersion
        yosys = $yosysVersion
        yosys_options = 'flatten=true noDSP=true ABC9=true autoname=true'
    }
    $metadata | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $experiment 'config.json')

    $simStatus = 'SKIPPED'
    $mulClocks = $null
    $aiMin = $null
    $aiMax = $null
    if (-not $SkipSimulation) {
        $vvp = Join-Path $experiment 'abc471e_narrow_tb.vvp'
        $compileArgs = @(
            '-g2012', '-s', 'abc471e_narrow_tb',
            "-DTEST_WIDTH=$width", "-DTEST_MOD=$mod", "-DTEST_N_MAX=$nMax",
            '-o', $vvp, $rtlMain, $rtlSpi, $testbench
        )
        $compileOutput = @(& iverilog @compileArgs 2>&1)
        $compileOutput | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $experiment 'icarus_compile.log')
        if ($LASTEXITCODE -ne 0) {
            throw "Icarus compile failed for $name"
        }
        $simOutput = @(& vvp $vvp 2>&1)
        $simOutput | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $experiment 'icarus.log')
        if ($LASTEXITCODE -ne 0) {
            throw "Icarus simulation failed for $name"
        }
        $summaryLine = $simOutput | Where-Object { $_ -match '^SUMMARY ' } | Select-Object -Last 1
        if ($summaryLine -notmatch 'FAIL=0$') {
            throw "Icarus did not report a clean summary for $name"
        }
        $perfLine = $simOutput | Where-Object { $_ -match '^PERF WIDTH=' } | Select-Object -Last 1
        $aiLine = $simOutput | Where-Object { $_ -match '^PERF AI_SAMPLES=' } | Select-Object -Last 1
        if ($perfLine -match 'MUL_CLOCKS=(\d+)') { $mulClocks = [int]$Matches[1] }
        if ($aiLine -match 'AI_MIN_CLOCKS=(\d+)') { $aiMin = [int]$Matches[1] }
        if ($aiLine -match 'AI_MAX_CLOCKS=(\d+)') { $aiMax = [int]$Matches[1] }
        $simStatus = 'PASS'
    }

    $resource = $null
    if (-not $SkipSynthesis) {
        $synthScript = @"
read_verilog -sv "../../ffpga/src/main.v" "../../ffpga/src/spi_target.v"
chparam -set WIDTH $width -set MOD $mod -set N_MAX $nMax main
hierarchy -check
flatten -noscopeinfo
synth_xilinx -nobram -noiopad -nodsp -abc9
clean
autoname
write_verilog "post_synth_results.v"
write_edif "netlist.edif"
tee -q -o post_synth_report.txt stat
"@
        $synthScript | Set-Content -Encoding ASCII -LiteralPath (Join-Path $experiment 'synth_script.ys')
        Push-Location $experiment
        try {
            $synthOutput = @(& $yosys -s 'synth_script.ys' 2>&1)
            $synthOutput | Set-Content -Encoding UTF8 -LiteralPath 'synth.log'
            if ($LASTEXITCODE -ne 0) {
                throw "Forge/Yosys synthesis failed for $name"
            }
        } finally {
            Pop-Location
        }
        $resourceJson = Join-Path $experiment 'resource_summary.json'
        $resourceText = Join-Path $experiment 'resource_summary.txt'
        & python $resourceTool --report (Join-Path $experiment 'post_synth_report.txt') `
            --width $width --mod $mod --n-max $nMax `
            --json-out $resourceJson --text-out $resourceText | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Resource extraction failed for $name"
        }
        $resource = Get-Content -Raw -Encoding UTF8 -LiteralPath $resourceJson | ConvertFrom-Json
    }

    $row = [ordered]@{
        width = $width
        mod = $mod
        n_max = $nMax
        prime_verified = [bool]$config.prime_verified
        icarus = $simStatus
        mul_clocks = $mulClocks
        ai_min_clocks = $aiMin
        ai_max_clocks = $aiMax
    }
    if ($null -ne $resource) {
        foreach ($property in $resource.PSObject.Properties) {
            if ($property.Name -notin @('width', 'mod', 'n_max')) {
                $row[$property.Name] = $property.Value
            }
        }
    }
    $summary += [pscustomobject]$row
    Write-Host "$name simulation=$simStatus synthesis=$(-not $SkipSynthesis)"
}

$summary | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath (Join-Path $experiments 'sweep_summary.csv')
$summary | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $experiments 'sweep_summary.json')
