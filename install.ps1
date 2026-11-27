<#
.SYNOPSIS
    Установщик Amnezia Browser VPN для Windows.

.DESCRIPTION
    Один запуск делает всё: проверяет систему, при необходимости сам скачивает
    переносимый Go, загружает Go-модули, собирает Native Messaging host,
    регистрирует его для браузеров на Chromium и открывает страницу расширений.
    Права администратора не нужны.

.PARAMETER GoExe
    Путь к уже установленному go.exe. Если не указан, установщик ищет Go сам
    и скачивает официальную сборку, когда версии нет.

.PARAMETER FreshGo
    Скачать заново переносимый Go, даже если подходящая версия уже есть.

.PARAMETER Offline
    Не обращаться к интернету (нужны заранее подготовленные Go и модули).

.PARAMETER SkipBrowser
    Не открывать браузер после установки.

.PARAMETER AutoLoadExtension
    Попробовать сразу загрузить расширение через --load-extension.

.PARAMETER Goproxy
    Свой GOPROXY, например https://goproxy.io,direct

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -AutoLoadExtension
#>

[CmdletBinding()]
param(
    [string]$GoExe = '',
    [switch]$FreshGo,
    [switch]$Offline,
    [switch]$SkipBrowser,
    [switch]$AutoLoadExtension,
    [string]$Goproxy = ''
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'native\common.ps1')
Install-PlatformTls

$nativeDir = Join-Path $root 'native'
$extensionDir = Join-Path $root 'extension'
$extensionManifest = Join-Path $extensionDir 'manifest.json'
$totalSteps = 7
$timer = [Diagnostics.Stopwatch]::StartNew()

Write-InstallBanner 'Amnezia Browser VPN · установка'
Write-InstallInfo ('Папка проекта: ' + $root)
Write-InstallLog ('PowerShell {0}; Windows build {1}' -f $PSVersionTable.PSVersion, [Environment]::OSVersion.Version.Build)

try {
    # ---------------------------------------------------------------- 1. Система
    Write-InstallStep -Number 1 -Total $totalSteps -Text 'Проверка системы'
    Assert-WindowsHost
    $arch = Get-WindowsArchitecture
    if (-not (Test-Path -LiteralPath $extensionManifest)) {
        throw "В папке проекта нет extension\manifest.json. Распакуйте репозиторий целиком: $root"
    }
    Write-InstallOk ('Windows 10/11, архитектура: ' + $arch)

    # ------------------------------------------------------------------ 2. Сеть
    Write-InstallStep -Number 2 -Total $totalSteps -Text 'Проверка доступа в интернет'
    if ($Offline) {
        Write-InstallWarn 'Режим -Offline: сеть не проверяется, всё должно быть уже скачано.'
    } else {
        $goDev = Test-InternetEndpoint -HostName 'go.dev'
        $goproxyOk = Test-InternetEndpoint -HostName 'proxy.golang.org'
        if (-not $goDev -and -not $goproxyOk) {
            Write-InstallWarn 'Нет доступа к go.dev и proxy.golang.org. Если Go и модули уже скачаны, установка продолжится.'
        } elseif (-not $goDev) {
            Write-InstallWarn 'go.dev недоступен: если Go не установлен, скачивание может не удаться.'
        } elseif (-not $goproxyOk) {
            Write-InstallWarn 'proxy.golang.org недоступен: установщик попробует другие зеркала модулей.'
        } else {
            Write-InstallOk 'Интернет доступен.'
        }
    }

    # -------------------------------------------------------------------- 3. Go
    Write-InstallStep -Number 3 -Total $totalSteps -Text 'Подготовка Go'
    $toolchain = $null
    if (-not $FreshGo) { $toolchain = Resolve-GoToolchain -Preferred $GoExe }

    if (-not $toolchain) {
        if ($Offline) {
            throw ('Go 1.25+ не найден, а установлен режим -Offline. Скачайте Go вручную: https://go.dev/dl/ и повторите запуск с -GoExe "C:\Program Files\Go\bin\go.exe".')
        }
        Write-InstallInfo 'Подходящий Go не найден — скачиваю официальную сборку.'
        $downloadedGo = Install-PortableGo -Arch $arch
        $toolchain = [pscustomobject]@{ Path = $downloadedGo; Version = (Get-GoVersionAt $downloadedGo) }
        Write-InstallOk ('Go установлен в ' + (Split-Path -Parent (Split-Path -Parent $downloadedGo)))
    } else {
        Write-InstallOk ('Использую Go ' + $toolchain.Version + ': ' + $toolchain.Path)
    }
    Set-GoBuildEnvironment -GoExe $toolchain.Path

    # ----------------------------------------------------------------- 4. Сборка
    Write-InstallStep -Number 4 -Total $totalSteps -Text 'Сборка локального компонента'
    $buildArgs = @{ GoExe = $toolchain.Path; Arch = $arch }
    if ($Goproxy) { $buildArgs.Goproxy = $Goproxy }
    $buildResult = & (Join-Path $nativeDir 'build.ps1') @buildArgs
    $buildResult = $buildResult | Where-Object { $_ -and $_.Path } | Select-Object -Last 1
    if (-not $buildResult) { throw 'Сборка не вернула путь к собранному файлу.' }

    # -------------------------------------------------------------- 5. Регистрация
    Write-InstallStep -Number 5 -Total $totalSteps -Text 'Регистрация Native Messaging'
    $registration = & (Join-Path $nativeDir 'install.ps1') -HostExe $buildResult.Path
    $registration = $registration | Where-Object { $_ -and $_.ExtensionId } | Select-Object -Last 1
    if (-not $registration) { throw 'Регистрация Native Messaging не вернула результат.' }

    # ------------------------------------------------------------- 6. Расширение
    Write-InstallStep -Number 6 -Total $totalSteps -Text 'Подключение расширения'
    $extensionCopied = Set-ClipboardText -Text $extensionDir
    if ($extensionCopied) {
        Write-InstallOk 'Путь к папке extension скопирован в буфер обмена.'
    } else {
        Write-InstallInfo ('Путь к папке: ' + $extensionDir)
    }

    $browser = $null
    if (-not $SkipBrowser) {
        $browser = Get-PreferredBrowser -Names @('Google Chrome', 'Microsoft Edge', 'Chromium', 'Brave', 'Vivaldi')
    }

    $autoLoaded = $false
    if ($browser -and $browser.ExePath -and $AutoLoadExtension) {
        $alreadyRunning = $false
        try {
            $processName = [IO.Path]::GetFileNameWithoutExtension($browser.ExePath)
            $alreadyRunning = [bool](Get-Process -Name $processName -ErrorAction SilentlyContinue)
        } catch { }
        if ($alreadyRunning) {
            Write-InstallWarn ('{0} уже запущен: автозагрузка расширения не сработает, используйте «Загрузить распакованное».' -f $browser.Name)
        } else {
            $argument = '--load-extension="{0}"' -f $extensionDir
            Start-Process -FilePath $browser.ExePath -ArgumentList $argument | Out-Null
            $autoLoaded = $true
            Write-InstallOk ('Расширение загружено в {0} через --load-extension.' -f $browser.Name)
        }
    }

    if ($browser -and $browser.ExePath -and -not $autoLoaded) {
        Start-Process -FilePath $browser.ExePath -ArgumentList $browser.ExtensionsUrl | Out-Null
        Write-InstallOk ('Открыл ' + $browser.ExtensionsUrl + ' в ' + $browser.Name + '.')
    } elseif (-not $browser) {
        Write-InstallWarn 'Браузер на Chromium не найден. Установите Chrome или Edge и откройте chrome://extensions.'
    }

    # ------------------------------------------------------------------ 7. Итог
    Write-InstallStep -Number 7 -Total $totalSteps -Text 'Готово'
    $timer.Stop()
    $elapsed = '{0:N0} с' -f $timer.Elapsed.TotalSeconds

    Write-Host ''
    Write-Host '  Установка завершена за ' -NoNewline
    Write-Host $elapsed -ForegroundColor Green
    Write-Host ''
    Write-Host '  Компонент:      ' -NoNewline -ForegroundColor Gray; Write-Host $buildResult.Path
    Write-Host '  Регистрация:    ' -NoNewline -ForegroundColor Gray; Write-Host (($registration.Browsers) -join ', ')
    Write-Host '  ID расширения:  ' -NoNewline -ForegroundColor Gray; Write-Host $registration.ExtensionId
    Write-Host '  Журнал:         ' -NoNewline -ForegroundColor Gray; Write-Host (Get-InstallLogPath)
    Write-Host ''
    Write-Host '  Последний шаг — подключить расширение в браузере:' -ForegroundColor White
    Write-Host '    1. Включите «Режим разработчика» на странице расширений.'
    Write-Host '    2. Нажмите «Загрузить распакованное расширение».'
    if ($extensionCopied) {
        Write-Host '    3. Вставьте путь из буфера обмена (Ctrl+V) и выберите папку:' -ForegroundColor Gray
    } else {
        Write-Host '    3. Выберите папку:' -ForegroundColor Gray
    }
    Write-Host ('       ' + $extensionDir) -ForegroundColor Gray
    Write-Host '    4. Подтвердите разрешения расширения (прокси, приватность, native messaging).'
    Write-Host ''
    Write-Host '  Удалить: запустите uninstall.bat из папки проекта.' -ForegroundColor DarkGray
    Write-Host ''

    Write-InstallLog ('Установка завершена за ' + $elapsed) 'OK'
    exit 0
}
catch {
    $timer.Stop()
    Write-Host ''
    Write-Host '  Установка не завершена.' -ForegroundColor Red
    Write-Host ('  ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ''
    Write-Host ('  Журнал: ' + (Get-InstallLogPath)) -ForegroundColor DarkGray
    Write-Host '  Если нужна помощь, приложите этот журнал к описанию проблемы.' -ForegroundColor DarkGray
    Write-Host ''
    Write-InstallLog ('ОШИБКА: ' + $_.Exception.Message) 'ERROR'
    exit 1
}
