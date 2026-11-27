# Общие функции установщика Amnezia Browser VPN (Windows).
# Подключается через точку из install.ps1, uninstall.ps1 и native\*.ps1:
#   . (Join-Path $PSScriptRoot 'common.ps1')

$script:AppDataFolderName = 'AmneziaBrowserVPN'
$script:HostName          = 'com.amnezia.browser_vpn'
$script:HostExeName       = 'AmneziaBrowserVpnHost.exe'
$script:MinGoVersion      = [version]'1.25.0'

function Get-AppDataDir {
    $base = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    if (-not $base) {
        $profileDir = [Environment]::GetEnvironmentVariable('USERPROFILE')
        if ($profileDir) { $base = Join-Path $profileDir 'AppData\Local' }
    }
    if (-not $base) { throw 'Не удалось определить папку LOCALAPPDATA текущего пользователя.' }
    $dir = Join-Path $base $script:AppDataFolderName
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-ToolsDir {
    $dir = Join-Path (Get-AppDataDir) 'tools'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-InstallLogPath { return (Join-Path (Get-AppDataDir) 'install.log') }

function Write-InstallLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    try {
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -LiteralPath (Get-InstallLogPath) -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

function Write-InstallBanner {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor DarkGray
    Write-Host (' ' + $Text) -ForegroundColor White
    Write-Host ('=' * 64) -ForegroundColor DarkGray
    Write-InstallLog "=== $Text ==="
}

function Write-InstallStep {
    param(
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][int]$Total,
        [Parameter(Mandatory)][string]$Text
    )
    Write-Host ''
    Write-Host ('[{0}/{1}] {2}' -f $Number, $Total, $Text) -ForegroundColor Cyan
    Write-InstallLog ('--- шаг {0}/{1}: {2}' -f $Number, $Total, $Text)
}

function Write-InstallInfo {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ('      ' + $Text) -ForegroundColor Gray
    Write-InstallLog $Text
}

function Write-InstallOk {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ('  OK  ' + $Text) -ForegroundColor Green
    Write-InstallLog $Text 'OK'
}

function Write-InstallWarn {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ('  !!  ' + $Text) -ForegroundColor Yellow
    Write-InstallLog $Text 'WARN'
}

function Install-PlatformTls {
    # PowerShell 5.1 на Windows 10 по умолчанию может согласовывать только TLS 1.0.
    try {
        $current = [Net.ServicePointManager]::SecurityProtocol
        [Net.ServicePointManager]::SecurityProtocol = $current -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    $global:ProgressPreference = 'SilentlyContinue'
}

function Get-WindowsArchitecture {
    $arch = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432')
    if (-not $arch) { $arch = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE') }
    if (-not $arch) { throw 'Не удалось определить архитектуру процессора.' }
    switch ($arch.ToUpperInvariant()) {
        'AMD64' { return 'amd64' }
        'X64'   { return 'amd64' }
        'ARM64' { return 'arm64' }
        'X86'   { throw '32-битная Windows не поддерживается: нужна 64-битная версия (x64 или ARM64).' }
        default { throw "Неподдерживаемая архитектура процессора: $arch" }
    }
}

function Assert-WindowsHost {
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
        throw 'Этот установщик работает только в Windows. Для macOS используйте репозиторий AmneziaBrowserExtensionMacOS, для Linux — AmneziaBrowserExtensionLinux.'
    }
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw "Нужен PowerShell 5.1 или новее. Найдено: $($PSVersionTable.PSVersion)."
    }
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 10240) {
        throw "Нужна Windows 10 или новее. Найдена сборка $build."
    }
    if ($build -lt 17763) {
        Write-InstallWarn "Windows сборка $build старше 1809. Установка может работать, но браузеры обновить всё равно потребуется."
    }
}

function Test-InternetEndpoint {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [int]$Port = 443,
        [int]$TimeoutMs = 5000
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch { }
    }
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [int]$Attempts = 3
    )
    $errors = New-Object System.Collections.Generic.List[string]
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
            $timer = [Diagnostics.Stopwatch]::StartNew()
            Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing -TimeoutSec 900 -Headers @{ 'User-Agent' = 'AmneziaBrowserVPN-Installer' }
            $timer.Stop()
            $size = (Get-Item -LiteralPath $Destination).Length
            if ($size -le 0) { throw 'получен пустой файл' }
            Write-InstallInfo ('Скачано {0:N1} МБ за {1:N0} с' -f ($size / 1MB), $timer.Elapsed.TotalSeconds)
            return
        } catch {
            $errors.Add($_.Exception.Message)
            Write-InstallLog ("Попытка {0} из {1} не удалась: {2}" -f $attempt, $Attempts, $_.Exception.Message) 'WARN'
            if ($attempt -lt $Attempts) { Start-Sleep -Seconds (2 * $attempt) }
        }
    }
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        Write-InstallWarn 'Повторю загрузку через curl.exe.'
        & $curl.Source -L --fail --retry 2 --output $Destination $Uri 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Destination) -and (Get-Item -LiteralPath $Destination).Length -gt 0) { return }
    }
    throw ("Не удалось скачать {0}. Проверьте доступ в интернет. Ошибки: {1}" -f $Uri, ($errors -join '; '))
}

function Get-GoVersionAt {
    param([string]$GoExe)
    if (-not $GoExe) { return $null }
    if (-not (Test-Path -LiteralPath $GoExe)) { return $null }
    try { $raw = (& $GoExe version 2>$null | Out-String) } catch { return $null }
    if (-not $raw) { return $null }
    $match = [regex]::Match($raw, 'go(\d+)\.(\d+)(?:\.(\d+))?')
    if (-not $match.Success) { return $null }
    $major = [int]$match.Groups[1].Value
    $minor = [int]$match.Groups[2].Value
    $patch = 0
    if ($match.Groups[3].Success) { $patch = [int]$match.Groups[3].Value }
    return [version]::new($major, $minor, $patch)
}

function Resolve-GoToolchain {
    param([string]$Preferred = '')

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Preferred) { $candidates.Add($Preferred) }
    $cached = Join-Path (Get-ToolsDir) 'go\bin\go.exe'
    $candidates.Add($cached)
    $command = Get-Command go.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates.Add($command.Source) }

    $tooOld = ''
    foreach ($candidate in $candidates) {
        $version = Get-GoVersionAt $candidate
        if (-not $version) { continue }
        if ($version -ge $script:MinGoVersion) {
            return [pscustomobject]@{ Path = $candidate; Version = $version }
        }
        if (-not $tooOld) { $tooOld = '{0} ({1})' -f $candidate, $version }
    }
    if ($tooOld) {
        Write-InstallWarn ('Найден устаревший Go: {0}. Нужен {1} или новее.' -f $tooOld, $script:MinGoVersion)
    }
    return $null
}

function Get-GoDownloadInfo {
    param([Parameter(Mandatory)][string]$Arch)

    $sources = @(
        @{ Json = 'https://go.dev/dl/?mode=json'; Base = 'https://go.dev/dl/' },
        @{ Json = 'https://golang.google.cn/dl/?mode=json'; Base = 'https://golang.google.cn/dl/' }
    )

    foreach ($source in $sources) {
        try {
            $releases = Invoke-RestMethod -Uri $source.Json -UseBasicParsing -TimeoutSec 30 -Headers @{ 'User-Agent' = 'AmneziaBrowserVPN-Installer' }
        } catch {
            Write-InstallLog ("Не удалось получить {0}: {1}" -f $source.Json, $_.Exception.Message) 'WARN'
            continue
        }
        $stable = @($releases) | Where-Object { $_.stable } | Select-Object -First 1
        if (-not $stable) { continue }
        $file = @($stable.files) | Where-Object { $_.os -eq 'windows' -and $_.arch -eq $Arch -and $_.kind -eq 'archive' } | Select-Object -First 1
        if (-not $file) { continue }
        return [pscustomobject]@{
            Version  = [string]$stable.version
            FileName = [string]$file.filename
            Sha256   = [string]$file.sha256
            Url      = ($source.Base + [string]$file.filename)
        }
    }
    return $null
}

function Install-PortableGo {
    param([Parameter(Mandatory)][string]$Arch)

    $info = Get-GoDownloadInfo -Arch $Arch
    if (-not $info) {
        throw 'Не удалось получить список версий Go с go.dev. Скачайте Go вручную: https://go.dev/dl/ и запустите установщик снова (или укажите -GoExe путь к go.exe).'
    }

    Write-InstallInfo ('Последняя стабильная версия: {0} (windows/{1})' -f $info.Version, $Arch)
    $zip = Join-Path ([IO.Path]::GetTempPath()) $info.FileName
    Invoke-DownloadFile -Uri $info.Url -Destination $zip

    $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($info.Sha256 -and $actual -ne $info.Sha256.ToLowerInvariant()) {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        throw 'Контрольная сумма архива Go не совпала с официальной. Загрузка отменена.'
    }
    Write-InstallInfo 'Контрольная сумма SHA-256 совпала.'

    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue } catch { }
    $staging = Join-Path (Get-ToolsDir) ('go.tmp.' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    try {
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $staging)
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }

    $extracted = Join-Path $staging 'go'
    if (-not (Test-Path -LiteralPath (Join-Path $extracted 'bin\go.exe'))) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        throw 'В архиве Go не найден bin\go.exe.'
    }

    $target = Join-Path (Get-ToolsDir) 'go'
    if (Test-Path -LiteralPath $target) {
        try {
            Remove-Item -LiteralPath $target -Recurse -Force
        } catch {
            $stale = $target + '.old.' + [guid]::NewGuid().ToString('N').Substring(0, 6)
            Move-Item -LiteralPath $target -Destination $stale -Force
        }
    }
    Move-Item -LiteralPath $extracted -Destination $target -Force
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    return (Join-Path $target 'bin\go.exe')
}

function Set-GoBuildEnvironment {
    param([Parameter(Mandatory)][string]$GoExe)

    $binDir = Split-Path -Parent $GoExe
    $goRoot = Split-Path -Parent $binDir
    $env:GOROOT = $goRoot
    $env:PATH = $binDir + [IO.Path]::PathSeparator + $env:PATH
    $env:CGO_ENABLED = '0'
    $env:GO111MODULE = 'on'

    $appData = Get-AppDataDir
    $env:GOPATH = Join-Path $appData 'go'
    $env:GOCACHE = Join-Path $appData 'go-cache'
    foreach ($dir in @($env:GOPATH, $env:GOCACHE)) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
    Write-InstallLog ("GOROOT={0}; GOPATH={1}; GOCACHE={2}" -f $env:GOROOT, $env:GOPATH, $env:GOCACHE)
}

function Get-ExtensionId {
    param([Parameter(Mandatory)][string]$ManifestPath)

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "Не найден manifest.json расширения: $ManifestPath"
    }
    $json = [IO.File]::ReadAllText($ManifestPath, [Text.Encoding]::UTF8)
    $manifest = $json | ConvertFrom-Json
    if (-not $manifest.key) {
        throw 'В extension\manifest.json нет поля "key": невозможно вычислить постоянный ID расширения.'
    }
    $bytes = [Convert]::FromBase64String([string]$manifest.key)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }

    $builder = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt 16; $i++) {
        $value = $hash[$i]
        [void]$builder.Append([char](97 + ($value -shr 4)))
        [void]$builder.Append([char](97 + ($value -band 0x0F)))
    }
    return $builder.ToString()
}

function Get-BrowserDefinitions {
    $programFiles = [Environment]::GetEnvironmentVariable('ProgramFiles')
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')

    $chromePaths = @()
    foreach ($base in @($programFiles, $programFilesX86, $localAppData)) {
        if ($base) { $chromePaths += (Join-Path $base 'Google\Chrome\Application\chrome.exe') }
    }
    $edgePaths = @()
    foreach ($base in @($programFiles, $programFilesX86, $localAppData)) {
        if ($base) { $edgePaths += (Join-Path $base 'Microsoft\Edge\Application\msedge.exe') }
    }
    $chromiumPaths = @()
    foreach ($base in @($programFiles, $programFilesX86, $localAppData)) {
        if ($base) {
            $chromiumPaths += (Join-Path $base 'Chromium\Application\chrome.exe')
            $chromiumPaths += (Join-Path $base 'Chromium\Application\chromium.exe')
        }
    }
    $bravePaths = @()
    foreach ($base in @($programFiles, $programFilesX86, $localAppData)) {
        if ($base) { $bravePaths += (Join-Path $base 'BraveSoftware\Brave-Browser\Application\brave.exe') }
    }
    $vivaldiPaths = @()
    foreach ($base in @($programFiles, $programFilesX86, $localAppData)) {
        if ($base) { $vivaldiPaths += (Join-Path $base 'Vivaldi\Application\vivaldi.exe') }
    }

    return @(
        [pscustomobject]@{ Name = 'Google Chrome'; RegistryRoot = 'HKCU:\Software\Google\Chrome'; NativeHostsKey = 'HKCU:\Software\Google\Chrome\NativeMessagingHosts'; ExePaths = $chromePaths; ExtensionsUrl = 'chrome://extensions' }
        [pscustomobject]@{ Name = 'Microsoft Edge'; RegistryRoot = 'HKCU:\Software\Microsoft\Edge'; NativeHostsKey = 'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts'; ExePaths = $edgePaths; ExtensionsUrl = 'edge://extensions' }
        [pscustomobject]@{ Name = 'Chromium'; RegistryRoot = 'HKCU:\Software\Chromium'; NativeHostsKey = 'HKCU:\Software\Chromium\NativeMessagingHosts'; ExePaths = $chromiumPaths; ExtensionsUrl = 'chrome://extensions' }
        [pscustomobject]@{ Name = 'Brave'; RegistryRoot = 'HKCU:\Software\BraveSoftware\Brave-Browser'; NativeHostsKey = 'HKCU:\Software\BraveSoftware\Brave-Browser\NativeMessagingHosts'; ExePaths = $bravePaths; ExtensionsUrl = 'brave://extensions' }
        [pscustomobject]@{ Name = 'Vivaldi'; RegistryRoot = 'HKCU:\Software\Vivaldi'; NativeHostsKey = 'HKCU:\Software\Vivaldi\NativeMessagingHosts'; ExePaths = $vivaldiPaths; ExtensionsUrl = 'vivaldi://extensions' }
    )
}

function Get-BrowserExePath {
    param([Parameter(Mandatory)]$Browser)
    foreach ($path in $Browser.ExePaths) {
        if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    }
    return ''
}

function Get-InstalledBrowsers {
    $result = @()
    foreach ($browser in (Get-BrowserDefinitions)) {
        $exe = Get-BrowserExePath -Browser $browser
        if ($exe -or (Test-Path -LiteralPath $browser.RegistryRoot)) {
            $result += [pscustomobject]@{ Name = $browser.Name; ExePath = $exe; ExtensionsUrl = $browser.ExtensionsUrl; NativeHostsKey = $browser.NativeHostsKey }
        }
    }
    return $result
}

function Get-PreferredBrowser {
    param([string[]]$Names)
    $browsers = Get-InstalledBrowsers
    if (-not $browsers) { return $null }
    if ($Names) {
        foreach ($name in $Names) {
            $match = $browsers | Where-Object { $_.Name -eq $name -and $_.ExePath } | Select-Object -First 1
            if ($match) { return $match }
        }
    }
    $withExe = $browsers | Where-Object { $_.ExePath } | Select-Object -First 1
    if ($withExe) { return $withExe }
    return ($browsers | Select-Object -First 1)
}

function Stop-RunningHost {
    $processName = [IO.Path]::GetFileNameWithoutExtension($script:HostExeName)
    $running = Get-Process -Name $processName -ErrorAction SilentlyContinue
    if (-not $running) { return $false }
    try {
        $running | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        Write-InstallLog 'Остановлены запущенные процессы AmneziaBrowserVpnHost.'
        return $true
    } catch {
        return $false
    }
}

function Set-ClipboardText {
    param([Parameter(Mandatory)][string]$Text)
    try { Set-Clipboard -Value $Text -ErrorAction Stop; return $true } catch { }
    try { $Text | & clip.exe; return ($LASTEXITCODE -eq 0) } catch { }
    return $false
}
