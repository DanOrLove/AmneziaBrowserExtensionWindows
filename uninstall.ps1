<#
.SYNOPSIS
    Удаление Amnezia Browser VPN для Windows.

.DESCRIPTION
    Останавливает локальный туннель, удаляет регистрацию Native Messaging
    для всех браузеров, скачанный Go и рабочие данные.
    Само расширение нужно удалить на странице расширений браузера.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\uninstall.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -KeepData -Force
#>

[CmdletBinding()]
param(
    [switch]$KeepData,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'native\common.ps1')
Install-PlatformTls

Write-InstallBanner 'Amnezia Browser VPN · удаление'

if (-not $Force) {
    $answer = Read-Host 'Удалить регистрацию компонента и рабочие данные? [y/N]'
    if ($answer -notmatch '^(y|yes|д|да)$') {
        Write-InstallInfo 'Удаление отменено.'
        exit 0
    }
}

# 1. Останавливаем туннель.
$pids = @()
try {
    $pidFile = Join-Path (Get-AppDataDir) 'proxy.pid'
    if (Test-Path -LiteralPath $pidFile) {
        $raw = (Get-Content -LiteralPath $pidFile -Raw).Trim()
        if ($raw -match '^\d+$') { $pids += [int]$raw }
    }
} catch { }
if (Stop-RunningHost) { Write-InstallInfo 'Запущенные процессы компонента остановлены.' }

foreach ($id in $pids) {
    try {
        $process = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($process) { $process | Stop-Process -Force -ErrorAction SilentlyContinue }
    } catch { }
}

# 2. Удаляем регистрацию.
& (Join-Path $root 'native\install.ps1') -Uninstall | Out-Null

# 3. Удаляем рабочие данные и инструменты.
if ($KeepData) {
    Write-InstallInfo ('Рабочие данные сохранены: ' + (Get-AppDataDir))
} else {
    $appData = Get-AppDataDir
    try {
        Remove-Item -LiteralPath $appData -Recurse -Force
        Write-InstallOk ('Удалена папка ' + $appData)
    } catch {
        Write-InstallWarn ('Не удалось удалить ' + $appData + ': ' + $_.Exception.Message)
    }
}

# 4. Собранный .exe.
$exe = Join-Path $root 'native\AmneziaBrowserVpnHost.exe'
if (Test-Path -LiteralPath $exe) {
    try {
        Remove-Item -LiteralPath $exe -Force
        Write-InstallOk 'Собранный AmneziaBrowserVpnHost.exe удалён.'
    } catch {
        Write-InstallWarn 'Не удалось удалить .exe (возможно, он запущен).'
    }
}

Write-Host ''
Write-Host '  Готово. Осталось удалить расширение на странице chrome://extensions или edge://extensions.' -ForegroundColor White
Write-Host ''
exit 0
