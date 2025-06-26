Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes

# === Настройки ===
$CheckDelaySeconds = 20
$LoopIntervalSeconds = 10
$launcherPath = Join-Path $PSScriptRoot "Launcher.exe"
$windowTitlePart = "Launcher"
$buttonText = "Startup"
$maxWait = 60
$loadWait = 20
$logFile = Join-Path $PSScriptRoot "crash-report.log"
$launcherProcessName = "Launcher"  # Имя процесса лаунчера без расширения

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
        [int]$timeoutSeconds = 60
    )

    Log-Message "Waiting for button '$buttonText' (timeout: $timeoutSeconds seconds)..."

    Start-Sleep -Seconds $loadWait

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    while ($stopwatch.Elapsed.TotalSeconds -lt $timeoutSeconds) {
        if (-not $parentElement) {
            Log-Message "Launcher window element lost." "WARN"
            return $null
        }
        if (Is-Window-Hung $parentElement) {
            Log-Message "Launcher window hung." "WARN"
            return $null
        }

        $condition = New-Object System.Windows.Automation.PropertyCondition `
            ([System.Windows.Automation.AutomationElement]::NameProperty, $buttonText)
        $button = $parentElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($button) {
            return $button
        }

        Start-Sleep -Milliseconds 500
    }

    Log-Message "Timeout reached while waiting for button '$buttonText'." "WARN"
    return $null
}

function Restart-Game {
    Log-Message "Restarting game via launcher..."

    Start-Launcher

    $winElement = Wait-For-Window -titlePart $windowTitlePart -timeout $maxWait
    if (-not $winElement) {
        Log-Message "Launcher window not found after start." "WARN"
        return $false
    }

    for ($i = 0; $i -lt $maxWait; $i++) {
        if (-not (Is-Window-Hung $winElement)) {
            Log-Message "Launcher window is responsive."
            break
        }
        Log-Message "Launcher window not responding, waiting..." "WARN"
        Start-Sleep -Seconds 1
    }

    if (Is-Window-Hung $winElement) {
        Log-Message "Launcher window hung after wait. Killing launcher process." "WARN"
        Get-Process -Name $launcherProcessName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        return $false
    }

    $btn = Wait-For-Button -parentElement $winElement -buttonText $buttonText -timeoutSeconds 90
    if (-not $btn) {
        Log-Message "Button '$buttonText' not found within timeout. Launcher might still be updating." "WARN"
        return $false
    }

    try {
        $invoke = $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $invoke.Invoke()
        Log-Message "Button '$buttonText' clicked."
        return $true
    } catch {
        Log-Message "Failed to click the button: $_" "ERROR"
        return $false
    }
}

# === Основной цикл ===

Set-Location -Path $PSScriptRoot

while ($true) {

    # Проверяем лаунчер
    $launcherProc = Get-Process -Name $launcherProcessName -ErrorAction SilentlyContinue

    if (-not $launcherProc) {
        Log-Message "Launcher process not running. Starting launcher." "WARN"
        Restart-Game | Out-Null
    }
    elseif ($launcherProc.Responding -eq $false) {
        Log-Message "Launcher process not responding. Waiting $CheckDelaySeconds sec..." "WARN"
        Start-Sleep -Seconds $CheckDelaySeconds

        $launcherProc = Get-Process -Name $launcherProcessName -ErrorAction SilentlyContinue
        if ($launcherProc -and $launcherProc.Responding -eq $false) {
            Log-Message "Launcher still not responding. Restarting launcher." "WARN"
            Get-Process -Name $launcherProcessName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Restart-Game | Out-Null
        }
    }
    else {
        # Лаунчер жив и отвечает — проверяем кнопку
        $winElement = Get-WindowElementByTitle -titlePart $windowTitlePart
        if ($winElement) {
            $btn = Wait-For-Button -parentElement $winElement -buttonText $buttonText -timeoutSeconds 10
            if ($btn) {
                # Кнопка есть — всё ок, ничего не делаем
            }
            else {
                Log-Message "Button '$buttonText' not found yet, launcher might be updating." "INFO"
            }
        }
        else {
            Log-Message "Launcher window disappeared, restarting launcher." "WARN"
            Restart-Game | Out-Null
        }
    }

    # Проверяем BlizzardError
    $blizzardError = Get-Process -Name "BlizzardError" -ErrorAction SilentlyContinue
    if ($blizzardError) {
        Log-Message "BlizzardError.exe detected. Restarting WoW and Launcher..." "WARN"
        Stop-Process -Name "wowclassic" -Force -ErrorAction SilentlyContinue
        Stop-Process -Name "BlizzardError" -Force -ErrorAction SilentlyContinue
        Restart-Game | Out-Null
    }

    # Проверяем WoW
    $wowProcess = Get-Process -Name "wowclassic" -ErrorAction SilentlyContinue
    if (-not $wowProcess) {
        Log-Message "WoW not running. Restarting Launcher..." "WARN"
        Restart-Game | Out-Null
    }
    elseif ($wowProcess.Responding -eq $false) {
        Log-Message "WoW is not responding. Waiting $CheckDelaySeconds sec..." "WARN"
        Start-Sleep -Seconds $CheckDelaySeconds

        $wowProcess = Get-Process -Name "wowclassic" -ErrorAction SilentlyContinue
        if ($wowProcess -and $wowProcess.Responding -eq $false) {
            Log-Message "WoW still unresponsive. Restarting Launcher..." "WARN"
            Stop-Process -Name "wowclassic" -Force -ErrorAction SilentlyContinue
            Restart-Game | Out-Null
        }
    }

    Start-Sleep -Seconds $LoopIntervalSeconds
}
