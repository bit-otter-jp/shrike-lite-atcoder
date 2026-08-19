param(
    [Parameter(Mandatory=$true)][string]$CandidateDir
)

$ErrorActionPreference = 'Stop'
$candidate = (Resolve-Path -LiteralPath $CandidateDir).Path
$config = Get-Content -Raw -Encoding UTF8 `
    -LiteralPath (Join-Path $candidate 'config.json') | ConvertFrom-Json
$resource = Get-Content -Raw -Encoding UTF8 `
    -LiteralPath (Join-Path $candidate 'resource_summary.json') |
    ConvertFrom-Json
$projectDir = Join-Path $candidate 'pnr_project'
$logPath = Join-Path $projectDir 'forge_bitstream_log.txt'
$automationPath = Join-Path $projectDir 'automation_result.json'
if (-not (Test-Path -LiteralPath $logPath)) {
    throw "Forge log not found: $logPath"
}
$log = Get-Content -Raw -Encoding UTF8 -LiteralPath $logPath
$automation = Get-Content -Raw -Encoding UTF8 -LiteralPath $automationPath |
    ConvertFrom-Json

function Match-Int([string]$Pattern, [int]$Group = 1) {
    $match = [regex]::Match($log, $Pattern,
        [Text.RegularExpressions.RegexOptions]::Multiline)
    if ($match.Success) { return [int]$match.Groups[$Group].Value }
    return $null
}

function Match-Double([string]$Pattern, [int]$Group = 1) {
    $match = [regex]::Match($log, $Pattern,
        [Text.RegularExpressions.RegexOptions]::Multiline)
    if ($match.Success) {
        return [double]::Parse($match.Groups[$Group].Value,
            [Globalization.CultureInfo]::InvariantCulture)
    }
    return $null
}

$typeLCapacity = Match-Int 'Type=L:\s+Capacity=(\d+)'
$typeLUsed = Match-Int 'Type=L:\s+Capacity=\d+\s+Utilized=(\d+)'
$packedClbs = Match-Int '^\s*(\d+) Logic 6-LUT CLBs\s*$'
$packedLuts = Match-Int '^\s*(\d+) CLB LUTs utilized'
$packedFfs = Match-Int '^\s*(\d+) CLB FFs utilized'
$postPack = Match-Double (
    'Post-LUT-packing timing:[\s\S]*?clk\s+<DEFAULT>\s+([0-9.]+)')
$placementFrequency = Match-Double (
    'Placement timing:[\s\S]*?clk\s+<DEFAULT>\s+([0-9.]+)')
$frequencyMatches = [regex]::Matches(
    $log,
    'clk\s+<DEFAULT>\s+([0-9.]+)',
    [Text.RegularExpressions.RegexOptions]::Multiline
)
$finalFrequency = if ($frequencyMatches.Count -gt 0) {
    [double]::Parse(
        $frequencyMatches[$frequencyMatches.Count - 1].Groups[1].Value,
        [Globalization.CultureInfo]::InvariantCulture)
} else { $null }
$minPlacerFailed = $log -match 'MinPlacer failed'
$fatalFit = $log -match 'design cannot fit into the current geometry'
$placementSuccess = $log -match 'Placement success:\s*1'
$routingVerified = $log -match 'Routing verified:\s*1'
$compilerComplete = $log -match 'FPGA Compiler Complete\.'
$normalExit = $log -match 'Normal Exit'
$exitCode = Match-Int 'Process exited with code (\d+)'
$pnrComplete = $placementSuccess -and $routingVerified -and
    $compilerComplete -and $normalExit -and ($exitCode -eq 0)
$placeFit = ($null -ne $typeLUsed) -and
    ($typeLUsed -le 140) -and $placementSuccess -and
    (-not $minPlacerFailed) -and (-not $fatalFit)
$placementResult = if ($placeFit) { 'PLACE_FIT' } else { 'PLACE_FAIL' }
$routeResult = if ($pnrComplete) { 'PNR_COMPLETE' } else { 'ROUTE_INCOMPLETE' }

$summary = [ordered]@{
    width = $config.width
    mod = $config.mod
    n_max = $config.n_max
    count_width = $config.count_width
    value_bytes = $config.value_bytes
    rtl_sha256 = $config.main_sha256
    lut = $resource.lut_total
    ff = $resource.ff_total
    carry4 = $resource.CARRY4
    lut_lower_bound = $resource.lut_only_rough_lower_bound
    classification = $placementResult
    place_fit = $placeFit
    pnr_complete = $pnrComplete
    placement_result = $placementResult
    route_result = $routeResult
    type_l_capacity = $typeLCapacity
    type_l_used = $typeLUsed
    packed_logic_clbs = $packedClbs
    packed_clb_luts = $packedLuts
    packed_clb_ffs = $packedFfs
    placement_success = $placementSuccess
    routing_verified = $routingVerified
    minplacer_failed = $minPlacerFailed
    fatal_fit_error = $fatalFit
    tool_exit_code = $exitCode
    post_lut_packing_estimate_mhz = $postPack
    post_placement_mhz = $placementFrequency
    post_route_mhz = if ($pnrComplete) { $finalFrequency } else { $null }
    wns_ns = $null
    tns_ns = $null
    timing_stage = if ($pnrComplete) { 'post-route' } elseif ($placeFit) {
        'post-placement-or-route-failure'
    } else { 'post-LUT-packing estimate' }
    automation_pnr_started = $automation.pnr_started
    automation_pnr_finished = $automation.pnr_completed
    bitstream_file_count = @($automation.bitstream_files).Count
    forge_log_sha256 = (Get-FileHash -Algorithm SHA256 `
        -LiteralPath $logPath).Hash.ToLowerInvariant()
}
$summary | ConvertTo-Json | Set-Content -Encoding UTF8 `
    -LiteralPath (Join-Path $projectDir 'pnr_summary.json')
$summary | ConvertTo-Json
