Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
 
# Настройки
$launcherPath = Join-Path $PSScriptRoot "Launcher.exe"
$windowTitlePart = "Launcher"   # Частичный заголовок окна
$buttonText = "Startup"
$maxWait = 60                   # Максимум 60 сек ожидания окна и отклика
 
function Start-Launcher {
    Write-Host "[>] Starting Launcher..."
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
    param($parentElement, $buttonText)
    Write-Host "[~] Waiting for button '$buttonText'..."
    while ($true) {
        Start-Sleep -Seconds 1
        $condition = New-Object System.Windows.Automation.PropertyCondition `
            ([System.Windows.Automation.AutomationElement]::NameProperty, $buttonText)
 
        $button = $parentElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
 
        if ($button) {
            return $button
        }
    }
}
 
# === Основной сценарий ===
 
while ($true) {
    Start-Launcher
 
    $winElement = Wait-For-Window -titlePart $windowTitlePart -timeout $maxWait
    if (-not $winElement) {
        Write-Warning "[X] Window not found. Exiting."
        exit 1
    }
 
    # Проверим, зависло ли окно
    $responsive = $false
    for ($i = 0; $i -lt $maxWait; $i++) {
        if (-not (Is-Window-Hung $winElement)) {
            Write-Host "[OK] Window is responsive."
            $responsive = $true
            break
        }
        Write-Host "[~] Window not responding... waiting..."
        Start-Sleep -Seconds 1
    }
 
    if (-not $responsive) {
        # Пробуем завершить зависший процесс и перезапустить
        Write-Warning "[X] Window still not responding after $maxWait sec. Killing and retrying..."
        Get-Process | Where-Object { $_.Path -eq $launcherPath } | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        continue
    }
 
    # Ждём кнопку и кликаем
    $btn = Wait-For-Button -parentElement $winElement -buttonText $buttonText
    try {
        $invoke = $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $invoke.Invoke()
        Write-Host "[OK] Button '$buttonText' clicked."
        break
    } catch {
        Write-Warning "[X] Failed to click the button: $_"
        exit 2
    }
}
 
Write-Host "[OK] Done."