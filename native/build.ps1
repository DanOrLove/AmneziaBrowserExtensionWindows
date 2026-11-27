# Сборка Native Messaging host для Windows.
# Можно запускать отдельно: powershell -ExecutionPolicy Bypass -File .\native\build.ps1
# install.ps1 вызывает этот файл, передавая путь к уже подготовленному Go.

[CmdletBinding()]
param(
    [string]$GoExe = '',
    [string]$Arch = '',
    [string]$Output = '',
    [string]$Goproxy = '',
    [switch]$SkipVerification
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$nativeDir = $PSScriptRoot
if (-not $Output) { $Output = Join-Path $nativeDir $script:HostExeName }
$Output = [IO.Path]::GetFullPath($Output)
if (-not $Arch) { $Arch = Get-WindowsArchitecture }

if (-not $GoExe) {
    $toolchain = Resolve-GoToolchain
    if (-not $toolchain) {
        throw 'Go 1.25 или новее не найден. Запустите install.ps1 из корня проекта: он скачает Go автоматически.'
    }
    $GoExe = $toolchain.Path
}
if (-not (Test-Path -LiteralPath $GoExe)) {
    throw "Не найден go.exe: $GoExe"
}

$goVersion = Get-GoVersionAt $GoExe
if (-not $goVersion) { throw "Не удалось определить версию Go в $GoExe." }
if ($goVersion -lt $script:MinGoVersion) {
    throw ("Нужен Go {0} или новее, найдено {1}. Запустите install.ps1 — он обновит Go." -f $script:MinGoVersion, $goVersion)
}

Set-GoBuildEnvironment -GoExe $GoExe
Write-InstallInfo ("Go {0}: {1}" -f $goVersion, $GoExe)

if (Stop-RunningHost) {
    Write-InstallInfo 'Остановлен запущенный компонент, чтобы заменить файл .exe.'
}

# --- Загрузка зависимостей Go -------------------------------------------------
$proxyCandidates = @()
if ($Goproxy) { $proxyCandidates += $Goproxy }
$proxyCandidates += @('', 'https://proxy.golang.org,direct', 'https://goproxy.io,direct', 'https://goproxy.cn,direct')

$downloadOk = $false
$index = 0
foreach ($candidate in $proxyCandidates) {
    $index++
    if ($candidate) {
        $env:GOPROXY = $candidate
        $label = $candidate
    } else {
        Remove-Item Env:\GOPROXY -ErrorAction SilentlyContinue
        $label = 'GOPROXY по умолчанию'
    }
    Write-InstallInfo ('Загрузка зависимостей ({0} из {1}, {2})...' -f $index, $proxyCandidates.Count, $label)
    Push-Location $nativeDir
    try {
        & $GoExe mod download 2>&1 | ForEach-Object { Write-InstallLog ([string]$_) }
        $downloadOk = ($LASTEXITCODE -eq 0)
    } finally {
        Pop-Location
    }
    if ($downloadOk) { break }
    Write-InstallWarn ('Не удалось скачать модули через {0}.' -f $label)
}

if (-not $downloadOk) {
    throw 'Не удалось скачать Go-модули. Проверьте интернет, VPN или корпоративный прокси (можно указать -Goproxy https://goproxy.io,direct).'
}
Write-InstallOk 'Зависимости Go загружены.'

# --- Сборка -------------------------------------------------------------------
Write-InstallInfo ('Сборка windows/{0}...' -f $Arch)
$env:GOOS = 'windows'
$env:GOARCH = $Arch
$env:CGO_ENABLED = '0'

Push-Location $nativeDir
try {
    & $GoExe build -trimpath -buildvcs=false -ldflags '-s -w' -o $Output .
    $buildExit = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($buildExit -ne 0) { throw 'Сборка AmneziaBrowserVpnHost завершилась ошибкой (см. сообщение Go выше).' }
if (-not (Test-Path -LiteralPath $Output)) { throw "Сборка не создала файл $Output." }

# --- Проверка результата ------------------------------------------------------
$size = (Get-Item -LiteralPath $Output).Length
if ($size -lt 2MB) { throw ("Собранный файл подозрительно мал ({0:N1} МБ)." -f ($size / 1MB)) }

if (-not $SkipVerification) {
    $versionOutput = ''
    try { $versionOutput = (& $Output --version 2>$null | Out-String).Trim() } catch { $versionOutput = '' }
    if ($versionOutput -notmatch 'amnezia-browser-vpn-host') {
        throw 'Собранный компонент не запускается: проверка "--version" не вернула ожидаемый ответ.'
    }
    Write-InstallOk ("Проверка запуска пройдена: {0}" -f $versionOutput)
}

Write-InstallOk ("Готово: {0} ({1:N1} МБ)" -f $Output, ($size / 1MB))
return [pscustomobject]@{ Path = $Output; Size = $size; GoExe = $GoExe; GoVersion = $goVersion; Arch = $Arch }
