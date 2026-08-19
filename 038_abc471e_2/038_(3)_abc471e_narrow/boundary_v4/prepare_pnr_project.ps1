param(
    [Parameter(Mandatory=$true)][string]$CandidateDir
)

$ErrorActionPreference = 'Stop'
$boundaryRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$workspaceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$candidate = (Resolve-Path -LiteralPath $CandidateDir).Path
if (-not $candidate.StartsWith(
        $boundaryRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw "Candidate must be below boundary_v4: $candidate"
}

$required = @(
    'config.json',
    'netlist.edif',
    'post_synth_results.v',
    'post_synth_report.txt',
    'synth_script.ys'
)
foreach ($name in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $candidate $name))) {
        throw "Missing candidate artifact: $name"
    }
}

$projectDir = Join-Path $candidate 'pnr_project'
$buildDir = Join-Path $projectDir 'ffpga\build'
$srcDir = Join-Path $projectDir 'ffpga\src'
$timingDir = Join-Path $projectDir 'ffpga\timing-constraints'
New-Item -ItemType Directory -Force -Path $buildDir,$srcDir,$timingDir |
    Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $buildDir 'bitstream') |
    Out-Null

foreach ($name in $required[1..4]) {
    Copy-Item -LiteralPath (Join-Path $candidate $name) `
        -Destination (Join-Path $buildDir $name) -Force
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'main.v') `
    -Destination (Join-Path $srcDir 'main.v') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'spi_target.v') `
    -Destination (Join-Path $srcDir 'spi_target.v') -Force
Copy-Item -LiteralPath `
    (Join-Path $workspaceRoot 'compact_v3\pnr_gui_project\ffpga\build\io_spec_in.txt') `
    -Destination (Join-Path $buildDir 'io_spec_in.txt') -Force
Copy-Item -LiteralPath `
    (Join-Path $workspaceRoot 'compact_v3\pnr_gui_project\ffpga\timing-constraints\atcoder_spi_template_v3.sdc') `
    -Destination (Join-Path $timingDir 'atcoder_spi_template_v3.sdc') -Force

$projectPath = Join-Path $projectDir 'boundary_candidate.ffpga'
$projectText = Get-Content -Raw -Encoding UTF8 -LiteralPath `
    (Join-Path $workspaceRoot 'abc471e_narrow.ffpga')
$pnrArguments = @(
    '-ENABLE_BITSTREAM_OUTPUT_BIN 0',
    '-ENABLE_BITSTREAM_OUTPUT_LOG 0',
    '-ENABLE_BITSTREAM_OUTPUT_AXI 0',
    '-ENABLE_BITSTREAM_OUTPUT_AXI_CRC 0',
    '-ENABLE_BITSTREAM_OUTPUT_VM 0',
    '-ENABLE_BITSTREAM_OUTPUT_DB 0',
    '-SHOW_GUI 0'
) -join ' '
$replacement = '<additionalArguments>' + $pnrArguments +
    '</additionalArguments>'
$projectText = [regex]::Replace(
    $projectText,
    '<additionalArguments></additionalArguments>',
    $replacement,
    1
)
$projectText | Set-Content -Encoding UTF8 -LiteralPath $projectPath

$config = Get-Content -Raw -Encoding UTF8 `
    -LiteralPath (Join-Path $candidate 'config.json') | ConvertFrom-Json
$inputManifest = [ordered]@{
    width = $config.width
    mod = $config.mod
    n_max = $config.n_max
    count_width = $config.count_width
    value_bytes = $config.value_bytes
    rtl_sha256 = $config.main_sha256
    netlist_sha256 = (Get-FileHash -Algorithm SHA256 `
        -LiteralPath (Join-Path $buildDir 'netlist.edif')).Hash.ToLowerInvariant()
    io_spec_sha256 = (Get-FileHash -Algorithm SHA256 `
        -LiteralPath (Join-Path $buildDir 'io_spec_in.txt')).Hash.ToLowerInvariant()
    sdc_sha256 = (Get-FileHash -Algorithm SHA256 `
        -LiteralPath (Join-Path $timingDir 'atcoder_spi_template_v3.sdc')).Hash.ToLowerInvariant()
    bitstream_outputs_enabled = $false
}
$inputManifest | ConvertTo-Json | Set-Content -Encoding UTF8 `
    -LiteralPath (Join-Path $projectDir 'pnr_input_manifest.json')

Write-Output $projectPath
