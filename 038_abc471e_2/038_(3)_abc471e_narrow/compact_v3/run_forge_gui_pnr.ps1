param(
    [Parameter(Mandatory=$true)][string]$Project
)

$ErrorActionPreference = 'Stop'
$app = 'C:\Program Files\Renesas Electronics\Go Configure Software Hub\GP6.exe'
$projectPath = (Resolve-Path -LiteralPath $Project).Path
$projectRoot = Split-Path $projectPath -Parent
$buildDir = Join-Path $projectRoot 'ffpga\build'
$statusPath = Join-Path $projectRoot 'automation_status.txt'
$logPath = Join-Path $projectRoot 'forge_bitstream_log.txt'
$uiFinalPath = Join-Path $projectRoot 'ui_final.txt'
$resultPath = Join-Path $projectRoot 'automation_result.json'

function Set-Status([string]$value) {
    (Get-Date).ToString('o') + ' ' + $value |
        Set-Content -Encoding UTF8 -LiteralPath $statusPath
}

function Get-ProcessWindows($desktop, $pidCondition) {
    return $desktop.FindAll(
        [Windows.Automation.TreeScope]::Children,
        $pidCondition
    )
}

function Find-ElementByName($windows, [string]$name) {
    foreach ($window in $windows) {
        $elements = $window.FindAll(
            [Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.Condition]::TrueCondition
        )
        foreach ($element in $elements) {
            if ($element.Current.Name -eq $name) {
                return $element
            }
        }
    }
    return $null
}

function Invoke-Element($element) {
    $pattern = $null
    if ($element.TryGetCurrentPattern(
            [Windows.Automation.InvokePattern]::Pattern,
            [ref]$pattern)) {
        $pattern.Invoke()
        return
    }
    if ($element.TryGetCurrentPattern(
            [Windows.Automation.SelectionItemPattern]::Pattern,
            [ref]$pattern)) {
        $pattern.Select()
        return
    }
    throw "Element cannot be invoked: $($element.Current.Name)"
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Set-Status 'launching ForgeFPGA'

$process = Start-Process -FilePath $app -ArgumentList ('"' + $projectPath + '"') -WindowStyle Minimized -PassThru
$result = [ordered]@{
    process_id = $process.Id
    started_at = (Get-Date).ToString('o')
    pnr_started = $false
    pnr_completed = $false
    elapsed_seconds = 0
    bitstream_files = @()
    error = $null
}

try {
    $desktop = [Windows.Automation.AutomationElement]::RootElement
    $pidCondition = New-Object Windows.Automation.PropertyCondition(
        [Windows.Automation.AutomationElement]::ProcessIdProperty,
        $process.Id
    )

    $deadline = (Get-Date).AddSeconds(90)
    $windows = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $windows = Get-ProcessWindows $desktop $pidCondition
        if ($windows.Count -gt 0) { break }
    }
    if ($null -eq $windows -or $windows.Count -eq 0) {
        throw 'ForgeFPGA window was not created'
    }

    $fpgaEditor = Find-ElementByName $windows 'FPGA Editor'
    if ($null -eq $fpgaEditor) {
        throw 'FPGA Editor button was not found'
    }
    Invoke-Element $fpgaEditor
    Set-Status 'opening FPGA Editor'

    $deadline = (Get-Date).AddSeconds(90)
    $generate = $null
    while ((Get-Date) -lt $deadline -and $null -eq $generate) {
        Start-Sleep -Milliseconds 500
        $windows = Get-ProcessWindows $desktop $pidCondition
        $generate = Find-ElementByName $windows 'Generate Bitstream'
    }
    if ($null -eq $generate) {
        throw 'Generate Bitstream button was not found'
    }
    if (-not $generate.Current.IsEnabled) {
        throw 'Generate Bitstream button is disabled'
    }

    $runStart = Get-Date
    Invoke-Element $generate
    Set-Status 'Generate Bitstream invoked; waiting for PNR'

    $handledWindows = New-Object 'System.Collections.Generic.HashSet[string]'
    $deadline = (Get-Date).AddMinutes(12)
    $completionCandidate = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        $process.Refresh()
        if ($process.HasExited) {
            throw "ForgeFPGA exited during PNR with code $($process.ExitCode)"
        }
        $windows = Get-ProcessWindows $desktop $pidCondition
        $generate = Find-ElementByName $windows 'Generate Bitstream'

        foreach ($window in $windows) {
            $windowName = $window.Current.Name
            if ($windowName -and $windowName -notmatch 'ForgeFPGA Workshop') {
                $key = $windowName + '|' + $window.Current.AutomationId
                if ($handledWindows.Add($key)) {
                    $modalLines = @("WINDOW=$windowName")
                    $modalElements = $window.FindAll(
                        [Windows.Automation.TreeScope]::Descendants,
                        [Windows.Automation.Condition]::TrueCondition
                    )
                    foreach ($element in $modalElements) {
                        if ($element.Current.Name) {
                            $modalLines += "$($element.Current.ControlType.ProgrammaticName): $($element.Current.Name)"
                        }
                    }
                    $modalLines | Add-Content -Encoding UTF8 -LiteralPath (Join-Path $projectRoot 'modal_windows.log')
                    foreach ($acceptName in @('OK', 'Yes', 'Continue')) {
                        $accept = Find-ElementByName @($window) $acceptName
                        if ($null -ne $accept -and $accept.Current.IsEnabled) {
                            Invoke-Element $accept
                            break
                        }
                    }
                }
            }
        }

        $newPlacer = @(Get-Process 'eda-placer' -ErrorAction SilentlyContinue |
            Where-Object { $_.StartTime -ge $runStart })
        $pnrFiles = @(Get-ChildItem -LiteralPath $buildDir -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.LastWriteTime -ge $runStart -and
                $_.Name -match '^(PNR_|resource-utilization|clock_tree)'
            })
        $buttonDisabled = $null -ne $generate -and -not $generate.Current.IsEnabled
        if ($buttonDisabled -or $newPlacer.Count -gt 0 -or $pnrFiles.Count -gt 0) {
            if (-not $result.pnr_started) {
                $result.pnr_started = $true
                Set-Status 'PNR started'
            }
        }

        if ($result.pnr_started -and $null -ne $generate -and
                $generate.Current.IsEnabled -and $newPlacer.Count -eq 0) {
            if ($null -eq $completionCandidate) {
                $completionCandidate = Get-Date
            } elseif (((Get-Date) - $completionCandidate).TotalSeconds -ge 5) {
                $result.pnr_completed = $true
                break
            }
        } else {
            $completionCandidate = $null
        }
        $result.elapsed_seconds = [math]::Round(((Get-Date) - $runStart).TotalSeconds, 1)
        if (($result.elapsed_seconds % 15) -lt 1.1) {
            Set-Status "PNR running; elapsed=$($result.elapsed_seconds)s"
        }
    }
    if (-not $result.pnr_completed) {
        throw 'PNR automation timed out before completion'
    }

    Set-Status 'PNR completed; capturing GUI log'
    $windows = Get-ProcessWindows $desktop $pidCondition
    $bitstreamLog = Find-ElementByName $windows 'Bitstream Log'
    if ($null -ne $bitstreamLog) {
        Invoke-Element $bitstreamLog
        Start-Sleep -Seconds 2
    }
    $windows = Get-ProcessWindows $desktop $pidCondition
    $captured = $false
    foreach ($window in $windows) {
        $elements = $window.FindAll(
            [Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.Condition]::TrueCondition
        )
        foreach ($element in $elements) {
            if ($element.Current.AutomationId -like '*MessagesPanel*PlainTextEdit') {
                $textPattern = $null
                if ($element.TryGetCurrentPattern(
                        [Windows.Automation.TextPattern]::Pattern,
                        [ref]$textPattern)) {
                    $textPattern.DocumentRange.GetText(-1) |
                        Set-Content -Encoding UTF8 -LiteralPath $logPath
                    $captured = $true
                    break
                }
            }
        }
        if ($captured) { break }
    }

    $uiLines = @()
    foreach ($window in $windows) {
        $uiLines += "WINDOW=$($window.Current.Name)"
        $elements = $window.FindAll(
            [Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.Condition]::TrueCondition
        )
        foreach ($element in $elements) {
            if ($element.Current.Name) {
                $uiLines += ('TYPE={0}`tNAME={1}`tENABLED={2}' -f
                    $element.Current.ControlType.ProgrammaticName,
                    $element.Current.Name,
                    $element.Current.IsEnabled)
            }
        }
    }
    $uiLines | Set-Content -Encoding UTF8 -LiteralPath $uiFinalPath
    Set-Status 'PNR log captured'
} catch {
    $result.error = $_.Exception.Message
    Set-Status "ERROR: $($result.error)"
} finally {
    $result.elapsed_seconds = [math]::Round(((Get-Date) - [datetime]$result.started_at).TotalSeconds, 1)
    $result.bitstream_files = @(
        Get-ChildItem -LiteralPath $buildDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)bitstream|\.bin$|\.vm$' } |
            Select-Object -ExpandProperty Name
    )
    $result | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath $resultPath
    if (-not $process.HasExited) {
        $process.Kill()
        $process.WaitForExit()
    }
}

if ($null -ne $result.error) {
    exit 1
}
