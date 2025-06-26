Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes

# === Настройки ===
$CheckDelaySeconds = 20
$LoopIntervalSeconds = 10
$launcherPath = Join-Path $PSScriptRoot "Launcher.exe"
$launcherProcessName = "Launcher"
$windowTitlePart = "Launcher"
$buttonText = "Startup"
$maxWait = 60
$loadWait = 20
$buttonWaitTimeout = 90
$logFile = Join-Path $PSScriptRoot "crash-report.log"

# === Логирование ===
function Log-Message {
    param (
        [string]$message,
        [string]$type = "INFO"  # INFO / WARN / ERROR
    )
    $timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    $entry = "[$timestamp] [$type] $message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry
}

# === UI Automation ===
function Start-Launcher {
    Log-Message "Starting Launcher..."
    Start-Process -FilePath $launcherPath
}

function Get-WindowElementByTitle {
    param($titlePart)
    $desktop = [System.Windows.Automation.AutomationElement]::RootElement
    $condition = New-Object System.Windows.Automation.PropertyCondition `
        ([System.Windows.Automation.AutomationElement]::ControlTypeProperty, `
         [System.Windows.Automation.ControlType]::Window)
    $windows = $desktop.FindAll("Children", $condition)
    foreach ($win in $windows) {
        if ($win.Current.Name -like "*$titlePart*") {
            return $win
        }
    }
    return $null
}

function Wait-For-Window {
    param($titlePart, $timeout)
    for ($i = 0; $i -lt $timeout; $i++) {
        $element = Get-WindowElementByTitle -titlePart $titlePart
        if ($element) {
            return $element
        }
        Start-Sleep -Seconds 1
    }
    return $null
}

function Is-Window-Hung {
    param($element)
    try {
        $null = $element.Current.Name
        return $false
    } catch {
        return $true
    }
}

function Wait-For-Button {
    param(
        $parentElement,
        $buttonText,
        [int]$timeoutSeconds = $buttonWaitTimeout
    )

    Log-Message "Waiting for button '$buttonText' with timeout $timeoutSeconds seconds..."
    Start-Sleep -Seconds $loadWait
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    while ($stopwatch.Elapsed.TotalSeconds -lt $timeoutSeconds) {
        # Проверяем процесс лаунчера
        $launcherProc = Get-Process -Name $launcherProcessName -ErrorAction SilentlyContinue
        if (-not $launcherProc) {
            Log-Message "Launcher process not running during button wait. Returning null." "WARN"
            return $null
        }
        elseif ($launcherProc.Responding -eq $false) {
            Log-Message "Launcher process not responding during button wait. Returning null." "WARN"
            return $null
        }

        if (-not $parentElement) {
            Log-Message "Launcher window element lost during button wait." "WARN"
            return $null
        }
        if (Is-Window-Hung $parentElement) {
            Log-Message "Launcher window hung during button wait." "WARN"
            return $null
        }

        # Ищем кнопку по имени и ControlType.Button
        $conditionName = New-Object System.Windows.Automation.PropertyCondition `
            ([System.Windows.Automation.AutomationElement]::NameProperty, $buttonText)
        $conditionType = New-Object System.Windows.Automation.PropertyCondition `
            ([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
        $condition = New-Object System.Windows.Automation.AndCondition($conditionName, $conditionType)

        $button = $parentElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)

        if ($button) {
            Log-Message "Button '$buttonText' found."
            return $button
        } else {
            Log-Message "Button '$buttonText' not found yet. Waiting..."
        }

        Start-Sleep -Seconds 1
    }

    Log-Message "Timeout reached while waiting for button '$buttonText'." "WARN"
    return $null
}

function Restart-Game {
    Log-Message "Restarting game via launcher..."

    while ($true) {
        Start-Launcher

        $winElement = Wait-For-Window -titlePart $windowTitlePart -timeout $maxWait
        if (-not $winElement) {
            Log-Message "Launcher window not found. Retrying..." "WARN"
            Start-Sleep -Seconds 2
            continue
        }

        $responsive = $false
        for ($i = 0; $i -lt $maxWait; $i++) {
            if (-not (Is-Window-Hung $winElement)) {
                Log-Message "Launcher window is responsive."
                $responsive = $true
                break
            }
            Log-Message "Launcher not responding... waiting..." "WARN"
            Start-Sleep -Seconds 1
        }

        if (-not $responsive) {
            Log-Message "Launcher hung. Killing and retrying..." "WARN"
            Get-Process -Name $launcherProcessName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            continue
        }

        $btn = Wait-For-Button -parentElement $winElement -buttonText $buttonText -timeoutSeconds $buttonWaitTimeout
        if (-not $btn) {
            Log-Message "Button '$buttonText' not found or launcher not responsive during wait. Restarting launcher..." "WARN"
            Get-Process -Name $launcherProcessName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            continue
        }

        try {
            $invoke = $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
            $invoke.Invoke()
            Log-Message "Button '$buttonText' clicked."
            break
        } catch {
            Log-Message "Failed to click the button: $_" "ERROR"
            exit 2
        }
    }
}

# === Основной цикл ===

while ($true) {
    $blizzardError = Get-Process -Name "BlizzardError" -ErrorAction SilentlyContinue
    if ($blizzardError) {
        Log-Message "BlizzardError.exe detected. Restarting..." "WARN"
        Stop-Process -Name "wowclassic" -Force -ErrorAction SilentlyContinue
        Stop-Process -Name "BlizzardError" -Force -ErrorAction SilentlyContinue
        Restart-Game
        Start-Sleep -Seconds $LoopIntervalSeconds
        continue
    }

    $wowProcess = Get-Process -Name "wowclassic" -ErrorAction SilentlyContinue
    if (-not $wowProcess) {
        Log-Message "WoW not running. Restarting..." "WARN"
        Restart-Game
        Start-Sleep -Seconds $LoopIntervalSeconds
        continue
    }

    if ($wowProcess.Responding -eq $false) {
        Log-Message "WoW is not responding. Waiting $CheckDelaySeconds sec..." "WARN"
        Start-Sleep -Seconds $CheckDelaySeconds
        $wowProcess = Get-Process -Name "wowclassic" -ErrorAction SilentlyContinue
        if ($wowProcess -and $wowProcess.Responding -eq $false) {
            Log-Message "WoW still unresponsive. Restarting..." "WARN"
            Stop-Process -Name "wowclassic" -Force -ErrorAction SilentlyContinue
            Restart-Game
        }
    }

    Start-Sleep -Seconds $LoopIntervalSeconds
}
