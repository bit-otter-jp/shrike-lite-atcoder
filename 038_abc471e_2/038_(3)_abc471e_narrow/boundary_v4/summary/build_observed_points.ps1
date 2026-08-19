$ErrorActionPreference = 'Stop'
$summaryDir = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$boundaryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

function Relative-Path([string]$Path) {
    return $Path.Substring($boundaryRoot.Length + 1).Replace('\', '/')
}

function First-Int([string]$Text, [string]$Pattern) {
    $match = [regex]::Match(
        $Text,
        $Pattern,
        [Text.RegularExpressions.RegexOptions]::Multiline
    )
    if ($match.Success) { return [int]$match.Groups[1].Value }
    return $null
}

function First-Double([string]$Text, [string]$Pattern) {
    $match = [regex]::Match(
        $Text,
        $Pattern,
        [Text.RegularExpressions.RegexOptions]::Multiline
    )
    if ($match.Success) {
        return [double]::Parse(
            $match.Groups[1].Value,
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    return $null
}

$candidateDirs = @(
    Get-ChildItem -LiteralPath $boundaryRoot -Directory |
        Where-Object { $_.Name -match '^w\d\d$' } |
        ForEach-Object {
            Get-ChildItem -LiteralPath $_.FullName -Directory |
                Where-Object { $_.Name -match '^n\d+$' }
        } |
        Sort-Object FullName
)

$rows = foreach ($candidate in $candidateDirs) {
    $configPath = Join-Path $candidate.FullName 'config.json'
    $resourcePath = Join-Path $candidate.FullName 'resource_summary.json'
    $icarusPath = Join-Path $candidate.FullName 'icarus.log'
    if (-not (Test-Path -LiteralPath $configPath) -or
        -not (Test-Path -LiteralPath $resourcePath)) {
        throw "Incomplete synthesis candidate: $($candidate.FullName)"
    }

    $config = Get-Content -Raw -Encoding UTF8 -LiteralPath $configPath |
        ConvertFrom-Json
    $resource = Get-Content -Raw -Encoding UTF8 -LiteralPath $resourcePath |
        ConvertFrom-Json
    $sources = [Collections.Generic.List[string]]::new()
    $sources.Add((Relative-Path $configPath))
    $sources.Add((Relative-Path $resourcePath))

    $icarus = 'NOT_RUN'
    $icarusTotal = $null
    $icarusPass = $null
    $icarusFail = $null
    if (Test-Path -LiteralPath $icarusPath) {
        $sources.Add((Relative-Path $icarusPath))
        $icarusText = Get-Content -Raw -Encoding UTF8 -LiteralPath $icarusPath
        $simMatch = [regex]::Match(
            $icarusText,
            'SUMMARY\s+WIDTH=\d+\s+VALUE_BYTES=\d+\s+TOTAL=(\d+)\s+PASS=(\d+)\s+FAIL=(\d+)'
        )
        if ($simMatch.Success) {
            $icarusTotal = [int]$simMatch.Groups[1].Value
            $icarusPass = [int]$simMatch.Groups[2].Value
            $icarusFail = [int]$simMatch.Groups[3].Value
            $icarus = if ($icarusFail -eq 0 -and
                $icarusPass -eq $icarusTotal) {
                "PASS $icarusPass/$icarusTotal"
            } else {
                "FAIL $icarusPass/$icarusTotal"
            }
        } else {
            $icarus = 'UNKNOWN'
        }
    }

    $logPath = Join-Path $candidate.FullName `
        'pnr_project\forge_bitstream_log.txt'
    $automationPath = Join-Path $candidate.FullName `
        'pnr_project\automation_result.json'
    $pnrRun = Test-Path -LiteralPath $logPath
    $packing = 'NOT_RUN'
    $typeL = $null
    $place = if ($resource.lut_only_rough_lower_bound -gt 140) {
        'SCREEN_FAIL'
    } else { 'NOT_RUN' }
    $route = 'NOT_RUN'
    $minPlacer = 'NOT_RUN'
    $timingStage = 'NOT_RUN'
    $fmax = $null
    $postPack = $null
    $postPlacement = $null
    $postRoute = $null
    $bitstreamFiles = $null
    $forgeLogSha256 = $null

    if ($pnrRun) {
        $sources.Add((Relative-Path $logPath))
        $log = Get-Content -Raw -Encoding UTF8 -LiteralPath $logPath
        $packing = if ($log -match 'Packing verified:\s*1') {
            'VERIFIED'
        } else { 'NOT_VERIFIED' }
        $typeL = First-Int $log `
            'Type=L:\s+Capacity=\d+\s+Utilized=(\d+)'
        $placementSuccess = $log -match 'Placement success:\s*1'
        $minPlacerFailed = $log -match 'MinPlacer failed'
        $routingVerified = $log -match 'Routing verified:\s*1'
        $normalExit = $log -match 'Normal Exit'
        $exitCode = First-Int $log 'Process exited with code (\d+)'
        $pnrComplete = $placementSuccess -and $routingVerified -and
            $normalExit -and ($exitCode -eq 0)
        $place = if ($placementSuccess -and $typeL -le 140) {
            'PLACE_FIT'
        } else { 'PLACE_FAIL' }
        $route = if ($pnrComplete) {
            'PNR_COMPLETE'
        } else { 'ROUTE_INCOMPLETE' }
        $minPlacer = if ($minPlacerFailed) {
            'FAIL'
        } elseif ($placementSuccess) {
            'SUCCESS'
        } else { 'UNKNOWN' }
        $postPack = First-Double $log `
            'Post-LUT-packing timing:[\s\S]*?clk\s+<DEFAULT>\s+([0-9.]+)'
        $postPlacement = First-Double $log `
            'Placement timing:[\s\S]*?clk\s+<DEFAULT>\s+([0-9.]+)'
        $frequencyMatches = [regex]::Matches(
            $log,
            'clk\s+<DEFAULT>\s+([0-9.]+)',
            [Text.RegularExpressions.RegexOptions]::Multiline
        )
        if ($pnrComplete -and $frequencyMatches.Count -gt 0) {
            $postRoute = [double]::Parse(
                $frequencyMatches[$frequencyMatches.Count - 1].Groups[1].Value,
                [Globalization.CultureInfo]::InvariantCulture
            )
            $timingStage = 'POST_ROUTE'
            $fmax = $postRoute
        } elseif ($placementSuccess -and $null -ne $postPlacement) {
            $timingStage = 'POST_PLACEMENT'
            $fmax = $postPlacement
        } elseif ($null -ne $postPack) {
            $timingStage = 'POST_LUT_PACKING_ESTIMATE'
            $fmax = $postPack
        }
        if (Test-Path -LiteralPath $automationPath) {
            $sources.Add((Relative-Path $automationPath))
            $automation = Get-Content -Raw -Encoding UTF8 `
                -LiteralPath $automationPath | ConvertFrom-Json
            $bitstreamFiles = @($automation.bitstream_files).Count
        }
        $forgeLogSha256 = (Get-FileHash -Algorithm SHA256 `
            -LiteralPath $logPath).Hash.ToLowerInvariant()
    }

    $roleKey = "w$($config.width)n$($config.n_max)"
    $role = switch ($roleKey) {
        'w5n30'  { 'MAX_WORLD_FAIL' }
        'w5n29'  { 'INTERRUPTED_RUN_OBSERVED' }
        'w5n15'  { 'SHRUNK_FIT' }
        'w6n60'  { 'MAX_WORLD_FIT' }
        'w7n126' { 'MAX_WORLD_FAIL' }
        'w7n63'  { 'SHRUNK_FIT' }
        'w8n250' { 'MAX_WORLD_FAIL' }
        'w8n63'  { 'TIER_FAIL' }
        'w8n31'  { 'TIER_FAIL' }
        'w8n15'  { 'TIER_FAIL' }
        'w8n7'   { 'LATE_WORK5_OBSERVED_FIT' }
        'w9n508' { 'MAX_WORLD_SCREEN_FAIL' }
        default  { 'ADDITIONAL_SYNTH_OBSERVATION' }
    }

    [pscustomobject][ordered]@{
        WIDTH = [int]$config.width
        MOD = [int]$config.mod
        N_MAX = [int]$config.n_max
        COUNT_WIDTH = [int]$config.count_width
        VALUE_BYTES = [int]$config.value_bytes
        Icarus = $icarus
        ICARUS_TOTAL = $icarusTotal
        ICARUS_PASS = $icarusPass
        ICARUS_FAIL = $icarusFail
        REGRESSION = $config.regression
        LUT = [int]$resource.lut_total
        FF = [int]$resource.ff_total
        CARRY4 = [int]$resource.CARRY4
        LUT_LB = [int]$resource.lut_only_rough_lower_bound
        PNR_RUN = if ($pnrRun) { 'YES' } else { 'NO' }
        PACKING = $packing
        Type_L = $typeL
        MinPlacer = $minPlacer
        PLACE = $place
        ROUTE = $route
        TIMING_STAGE = $timingStage
        FMAX_MHZ = $fmax
        POST_LUT_PACKING_MHZ = $postPack
        POST_PLACEMENT_MHZ = $postPlacement
        POST_ROUTE_MHZ = $postRoute
        WNS_NS = $null
        TNS_NS = $null
        BITSTREAM_FILE_COUNT = $bitstreamFiles
        OBSERVATION_ROLE = $role
        RTL_SHA256 = $config.main_sha256
        FORGE_LOG_SHA256 = $forgeLogSha256
        SOURCE_ARTIFACT = $sources -join ';'
    }
}

$csvPath = Join-Path $summaryDir 'observed_points.csv'
$jsonPath = Join-Path $summaryDir 'observed_points.json'
$rows | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath $csvPath
$rows | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 `
    -LiteralPath $jsonPath

[pscustomobject]@{
    candidates = $rows.Count
    icarus_pass = @($rows | Where-Object { $_.Icarus -like 'PASS *' }).Count
    pnr_runs = @($rows | Where-Object { $_.PNR_RUN -eq 'YES' }).Count
    place_fit = @($rows | Where-Object { $_.PLACE -eq 'PLACE_FIT' }).Count
    pnr_complete = @($rows | Where-Object { $_.ROUTE -eq 'PNR_COMPLETE' }).Count
    screen_fail = @($rows | Where-Object { $_.PLACE -eq 'SCREEN_FAIL' }).Count
} | ConvertTo-Json
