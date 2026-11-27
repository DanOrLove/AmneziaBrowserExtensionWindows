# Регистрация / удаление Native Messaging host для текущего пользователя Windows.
# Права администратора не нужны: используются ключи HKCU.
#   powershell -ExecutionPolicy Bypass -File .\native\install.ps1
#   powershell -ExecutionPolicy Bypass -File .\native\install.ps1 -Uninstall

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [string]$HostExe = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$nativeDir = $PSScriptRoot
$extensionManifest = [IO.Path]::GetFullPath((Join-Path $nativeDir '..\extension\manifest.json'))
$hostManifest = [IO.Path]::GetFullPath((Join-Path $nativeDir ($script:HostName + '.json')))
if (-not $HostExe) { $HostExe = Join-Path $nativeDir $script:HostExeName }
$HostExe = [IO.Path]::GetFullPath($HostExe)

$browsers = Get-BrowserDefinitions

if ($Uninstall) {
    $removed = @()
    foreach ($browser in $browsers) {
        $key = $browser.NativeHostsKey + '\' + $script:HostName
        if (Test-Path -LiteralPath $key) {
            Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue
            $removed += $browser.Name
        }
    }
    Remove-Item -LiteralPath $hostManifest -Force -ErrorAction SilentlyContinue
    if ($removed.Count -gt 0) {
        Write-InstallOk ('Регистрация удалена: ' + ($removed -join ', '))
    } else {
        Write-InstallInfo 'Записи реестра не найдены — регистрация уже удалена.'
    }
    return [pscustomobject]@{ Uninstalled = $true; Browsers = $removed }
}

if (-not (Test-Path -LiteralPath $HostExe)) {
    throw "Не найден собранный компонент: $HostExe. Сначала выполните сборку (install.ps1 или native\build.ps1)."
}
if (-not (Test-Path -LiteralPath $extensionManifest)) {
    throw "Не найден extension\manifest.json: $extensionManifest"
}

$extensionId = Get-ExtensionId -ManifestPath $extensionManifest

$manifestObject = [ordered]@{
    name            = $script:HostName
    description     = 'Local AmneziaWG SOCKS5 tunnel for Chromium'
    path            = $HostExe
    type            = 'stdio'
    allowed_origins = @('chrome-extension://' + $extensionId + '/')
}
$json = $manifestObject | ConvertTo-Json -Depth 4
# Важно: UTF-8 без BOM и полный путь. Кириллица в пути (например, на рабочем столе) не должна ломаться.
$utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
[IO.File]::WriteAllText($hostManifest, $json, $utf8NoBom)

$registered = @()
foreach ($browser in $browsers) {
    $exe = Get-BrowserExePath -Browser $browser
    $known = (Test-Path -LiteralPath $browser.RegistryRoot)
    if (-not $exe -and -not $known) { continue }
    $key = $browser.NativeHostsKey + '\' + $script:HostName
    New-Item -Path $key -Force | Out-Null
    Set-Item -Path $key -Value $hostManifest
    $registered += $browser.Name
}

if ($registered.Count -eq 0) {
    throw 'Не найден ни один браузер на Chromium (Chrome, Edge, Chromium, Brave, Vivaldi). Установите браузер и повторите установку.'
}

# Проверяем, что реестр действительно указывает на манифест.
foreach ($browser in $browsers) {
    if ($registered -notcontains $browser.Name) { continue }
    $key = $browser.NativeHostsKey + '\' + $script:HostName
    $value = $null
    try { $value = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).'(default)' } catch { $value = $null }
    if (-not $value) { throw "Запись реестра для $($browser.Name) не создана: $key" }
}

Write-InstallOk ('Native Messaging host зарегистрирован: ' + ($registered -join ', '))
Write-InstallInfo ('ID расширения: ' + $extensionId)
Write-InstallInfo ('Манифест: ' + $hostManifest)

return [pscustomobject]@{
    ExtensionId = $extensionId
    Browsers    = $registered
    Manifest    = $hostManifest
    HostExe     = $HostExe
}
