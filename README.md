# Amnezia Browser VPN

Chromium extension for sending the browser's web traffic through an AmneziaWG configuration. The extension imports local `.conf` profiles and controls a Windows Native Messaging host. The host runs AmneziaWG in a userspace network stack and exposes a loopback SOCKS5 proxy; Windows system routes and other applications are not changed.

### macOS и Linux

**Важно:** текущая версия не устанавливает VPN-туннель на macOS или Linux. Native host использует Windows API, native/build.ps1 собирает EXE, а native/install.ps1 регистрирует Native Messaging через реестр Windows.

### macOS Отдельный репозиторий для macOS-версии: https://github.com/DanOrLove/AmneziaBrowserExtensionMacOS

### Linux
Отдельный репозиторий для Linux-версии: https://github.com/DanOrLove/AmneziaBrowserExtensionLinux

> **Status:** early prototype. The native component has been built for Windows x64. Test with a profile you control before relying on it. See [Limitations and security](#limitations-and-security).

## Русский

### Возможности

- Импорт конфигурации AmneziaWG/WireGuard из файла `.conf` или вставкой текста.
- Локальное хранение нескольких профилей, выбор и удаление профиля.
- Подключение и отключение из всплывающего окна расширения.
- Веб-трафик Chromium направляется через локальный SOCKS5 и AmneziaWG userspace-туннель.
- Системные маршруты Windows и маршруты остальных приложений не меняются.
- При подключении расширение блокирует WebRTC UDP, который не может пройти через SOCKS5.

### Требования

- Windows 10/11 (x64 или ARM64).
- Chromium, Google Chrome, Microsoft Edge либо другой браузер на Chromium (Chromium, Brave, Vivaldi).
- Интернет при первой установке: установщик сам скачивает Go и Go-модули (около 150 МБ). Заранее ставить Go не нужно.
- Конфиг AmneziaWG в формате WireGuard INI (`[Interface]`, `[Peer]`).

Установка и регистрация компонента выполняются для текущего пользователя без прав администратора. Для использования администраторами или другими Windows-учётными записями компонент нужно собрать и зарегистрировать в их профилях.

### Установка

1. Скачайте ZIP репозитория с GitHub и распакуйте его в постоянную локальную папку. Не удаляйте и не перемещайте папку после регистрации Native Messaging: запись Windows указывает на полный путь к собранной программе.
2. Дважды нажмите `install.bat` — один запуск делает всё:

   - проверяет версию Windows и архитектуру (x64 или ARM64);
   - проверяет доступ в интернет;
   - находит Go 1.25+ или скачивает официальную сборку с go.dev и сверяет её SHA-256;
   - скачивает Go-модули (если proxy.golang.org недоступен, пробует зеркала);
   - собирает `native\AmneziaBrowserVpnHost.exe` и проверяет, что он запускается;
   - регистрирует Native Messaging host в HKCU для всех найденных браузеров на Chromium (Chrome, Edge, Chromium, Brave, Vivaldi);
   - копирует путь к папке `extension` в буфер обмена и открывает страницу расширений.

   Права администратора не нужны, Go устанавливать заранее не нужно. Ход установки пишется в журнал `%LOCALAPPDATA%\AmneziaBrowserVPN\install.log`.

   Дополнительные варианты запуска:

   ```powershell
   # сразу загрузить расширение в браузер (если он ещё не запущен)
   powershell -ExecutionPolicy Bypass -File .\install.ps1 -AutoLoadExtension

   # свой GOPROXY, если модули не скачиваются напрямую
   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Goproxy https://goproxy.io,direct

   # использовать уже установленный Go
   powershell -ExecutionPolicy Bypass -File .\install.ps1 -GoExe "C:\Program Files\Go\bin\go.exe"
   ```

   Отдельные шаги по-прежнему доступны:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\native\build.ps1
   powershell -ExecutionPolicy Bypass -File .\native\install.ps1
   ```

3. На открывшейся странице `chrome://extensions` (или `edge://extensions`) включите **Режим разработчика**, нажмите **Загрузить распакованное расширение** и выберите папку `extension` внутри проекта.
4. Подтвердите разрешения расширения для прокси, настроек приватности и Native Messaging.

Если браузер был открыт во время сборки и регистрации, перезагрузите расширение на странице расширений или перезапустите браузер.

> Установщик автоматически настраивает нативный компонент, но Chrome требует вручную выбрать локальную папку расширения. Для прямой установки расширения в один клик оно должно быть опубликовано в Chrome Web Store.


### Если нужно только открыть интерфейс расширения:

1. Скачайте и распакуйте репозиторий.
2. В Chrome или Chromium откройте chrome://extensions.
3. Включите режим разработчика, нажмите **Загрузить распакованное расширение** и выберите папку extension.
4. Интерфейс можно осмотреть, но импорт профиля не подключит VPN. При нажатии **Подключить** native host не запустится, и трафик через туннель не пойдёт.

Не запускайте native/build.ps1 и native/install.ps1 на этих системах. Для полноценной поддержки нужно отдельно адаптировать native host под macOS/Linux, добавить сборку и регистрацию Native Messaging для каждой ОС, а затем проверить подключение на реальных системах.
### Первое подключение и использование

1. Нажмите значок **Amnezia Browser VPN** на панели расширений.
2. В разделе **Добавить конфиг** выберите свой `.conf`-файл или вставьте текст конфига. Укажите название профиля и нажмите **Сохранить конфиг**.
3. Выберите профиль в списке и нажмите **Подключить**.
4. Откройте сайт в Chromium. AmneziaWG выполняет рукопожатие при первом сетевом запросе; запуск локального прокси сам по себе ещё не доказывает доступность VPN-сервера.
5. Чтобы вернуть прежние настройки прокси и WebRTC, нажмите **Отключить VPN**.

Проверьте внешний IP в браузере до и после подключения. Другие приложения Windows должны продолжать использовать обычное системное соединение.

### Сборка из исходников и обновление

После обновления исходников запустите `install.bat` ещё раз, чтобы пересобрать и зарегистрировать host. Затем перезагрузите расширение на `chrome://extensions` или `edge://extensions`. Если нужно выполнить только вручную:

```powershell
powershell -ExecutionPolicy Bypass -File .\native\build.ps1
powershell -ExecutionPolicy Bypass -File .\native\install.ps1
```

Затем откройте `chrome://extensions` или `edge://extensions` и нажмите кнопку перезагрузки расширения. Профили остаются в локальном хранилище браузера при перезагрузке расширения; удаление самого расширения может удалить их, поэтому храните исходные конфиги отдельно.

### Удаление

1. Если VPN включён, нажмите **Отключить VPN** в расширении.
2. Откройте страницу расширений и удалите расширение.
3. Из корневой папки проекта запустите `uninstall.bat` (или `powershell -ExecutionPolicy Bypass -File .\uninstall.ps1`). Он остановит туннель, удалит регистрацию Native Messaging для всех браузеров, собранный `.exe`, скачанный Go и папку `%LOCALAPPDATA%\AmneziaBrowserVPN`.

4. Ключ `-KeepData` сохраняет журнал и рабочие файлы, `-Force` отключает подтверждение. Проверьте, что VPN отключён, прежде чем удалять папку данных вручную.

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -KeepData -Force
   ```

### Диагностика

Проверить профиль без подключения (парсинг, параметры обфускации, разрешение Endpoint):

```powershell
.\native\AmneziaBrowserVpnHost.exe check .\my-profile.conf
```

Команда печатает адреса, DNS, MTU, применённые параметры AmneziaWG (Jc/Jmin/Jmax, S1-S4, H1-H4, I1-I5), разрешённый IP Endpoint и список пропущенных параметров. Код возврата 1 означает, что конфиг не подходит.

Журналы:

- `%LOCALAPPDATA%\AmneziaBrowserVPN\install.log` — установка и регистрация.
- `%LOCALAPPDATA%\AmneziaBrowserVPN\proxy.log` — работа туннеля. Для подробного вывода запустите host с переменной `AMNEZIA_LOG_LEVEL=verbose` (или задайте её перед сборкой/запуском из установщика).

Порт локального SOCKS5 выбирается автоматически (1080-1089), потому что 1080 часто занят другими SOCKS-клиентами. Фактический порт возвращается расширению и пишется в `proxy.pid` как `PID PORT`; переменная `AMNEZIA_PROXY_PORT` задаёт порт принудительно.

### Устранение неполадок

- **«Native host has exited» / компонент не найден:** проверьте, что `native\AmneziaBrowserVpnHost.exe` собран и `native\install.ps1` выполнен из папки, где проект останется установлен. После этого перезапустите браузер.
- **Ошибка Go при сборке:** установщик скачивает Go сам. Если загрузка не удалась, поставьте Go вручную с [официальной страницы](https://go.dev/dl/) и запустите `install.ps1 -GoExe \"C:\Program Files\Go\bin\go.exe\"`. Подробности — в `%LOCALAPPDATA%\AmneziaBrowserVPN\install.log`.
- **Порт 1080 занят:** компонент сам выбирает свободный порт в диапазоне 1080-1089 и сообщает его расширению. Если нужен фиксированный порт, задайте переменную окружения `AMNEZIA_PROXY_PORT`.
- **Сайт не открывается:** проверьте активность и доступность сервера, соответствие `PrivateKey`/`PublicKey`, `Endpoint` и параметров обфускации на стороне сервера. Журнал локального компонента: `%LOCALAPPDATA%\AmneziaBrowserVPN\proxy.log`.
- **Расширение не управляет прокси или WebRTC:** проверьте политики браузера и другие расширения, которые могут контролировать те же настройки.

### Ограничения и безопасность

- Это прототип: локальный мост передаёт TCP CONNECT через SOCKS5. UDP-приложения и QUIC не туннелируются. Настройка Chromium блокирует WebRTC UDP без прокси; корпоративная политика браузера может запретить изменить эту настройку.
- Успешный запуск означает, что локальный прокси слушает порт. Работу VPN-сервера нужно подтвердить реальным запросом из браузера.
- `DNS` в конфиге должен содержать IP-адреса DNS-серверов. Конфиги с DNS-именами не поддерживаются.
- SOCKS5 без аутентификации слушает только `127.0.0.1:1080`. Расширение автоматически настраивает прокси браузера; другие программы не перенаправляются, но локальное приложение при желании может обратиться к этому порту.
- Сохранённые профили в `chrome.storage.local` и временный файл `active.conf` содержат приватный ключ в открытом виде для текущей Windows-учётной записи. Не публикуйте конфиги и удаляйте рабочую папку данных после отключения, если больше не используете приложение.
- В репозитории включён `.gitignore` для `.conf`, `.vpn`, собранного `.exe`, локальных SDK и файлов регистрации. Перед коммитом всегда проверяйте `git status` и список staged-файлов.

### Устройство проекта

- `extension/` — Manifest V3, интерфейс, локальные профили и управление прокси Chromium.
- `native/main.go` — Native Messaging host, конфигурация AmneziaWG через официальную Go-библиотеку и SOCKS5 TCP CONNECT-мост.
- `install.ps1`, `install.bat` — установка в один запуск: проверки, автоматическая установка Go, сборка, регистрация, открытие браузера.
- `uninstall.ps1`, `uninstall.bat` — удаление регистрации, данных и скачанных инструментов.
- `native/common.ps1` — общие функции установщика: журнал, загрузка Go, определение браузеров, вычисление ID расширения.
- `native/build.ps1` — сборка исполняемого файла (x64/ARM64) с проверкой запуска.
- `native/install.ps1` — регистрация/удаление Native Messaging host для браузеров на Chromium.
- `native/THIRD_PARTY.md` — сведения об основной внешней зависимости.

## English

### Features

- Import an AmneziaWG/WireGuard profile from a `.conf` file or pasted text.
- Store multiple profiles locally, select one, or delete it.
- Connect and disconnect from the extension popup.
- Route Chromium web traffic through a local SOCKS5 proxy backed by an AmneziaWG userspace tunnel.
- Do not change Windows system routes or automatically redirect other applications.
- Disable non-proxied WebRTC UDP while connected because SOCKS5 cannot carry it.

### Requirements

- Windows 10/11 (x64 or ARM64).
- Chromium, Google Chrome, Microsoft Edge, or another Chromium-based browser (Chromium, Brave, Vivaldi).
- Internet access on first install: the installer downloads Go and the Go modules itself (about 150 MB). Go does not need to be installed beforehand.
- An AmneziaWG profile in WireGuard INI format (`[Interface]`, `[Peer]`).

The component is built and registered for the current Windows user and does not require administrator rights. Build and register it separately for each Windows account that needs to use it.

### Installation

1. Download the repository ZIP from GitHub and extract it to a permanent local folder. Do not move or delete that folder after registering Native Messaging: the Windows registry entry contains the absolute path to the host executable.
2. Double-click `install.bat` — a single run does everything:

   - checks the Windows version and architecture (x64 or ARM64);
   - checks internet access;
   - finds Go 1.25+ or downloads the official build from go.dev and verifies its SHA-256;
   - downloads the Go modules (falls back to mirrors when proxy.golang.org is unreachable);
   - builds `native\AmneziaBrowserVpnHost.exe` and verifies that it starts;
   - registers the Native Messaging host in HKCU for every Chromium-based browser found (Chrome, Edge, Chromium, Brave, Vivaldi);
   - copies the `extension` folder path to the clipboard and opens the extensions page.

   No administrator rights and no preinstalled Go are required. The installer writes a log to `%LOCALAPPDATA%\AmneziaBrowserVPN\install.log`.

   Extra options:

   ```powershell
   # load the extension into the browser right away (when it is not running yet)
   powershell -ExecutionPolicy Bypass -File .\install.ps1 -AutoLoadExtension

   # custom GOPROXY when modules cannot be downloaded directly
   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Goproxy https://goproxy.io,direct

   # reuse an existing Go toolchain
   powershell -ExecutionPolicy Bypass -File .\install.ps1 -GoExe "C:\Program Files\Go\bin\go.exe"
   ```

   The individual steps remain available:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\native\build.ps1
   powershell -ExecutionPolicy Bypass -File .\native\install.ps1
   ```

3. On the opened `chrome://extensions` (or `edge://extensions`) page, enable **Developer mode**, choose **Load unpacked**, and select the repository's `extension` folder.
4. Approve the extension permissions for proxy settings, privacy settings, and Native Messaging.

If the browser was open during the build or registration, reload the extension on the extensions page or restart the browser.

> The installer configures the native component automatically, but Chrome requires you to select the local extension folder manually. Direct one-click extension installation requires publishing it in the Chrome Web Store.

### macOS and Linux

**Important:** the current version does not establish a VPN tunnel on macOS or Linux. The native host uses Windows APIs, native/build.ps1 produces an EXE, and native/install.ps1 registers Native Messaging in the Windows registry.

Separate repository for the macOS edition: [DanOrLove/AmneziaBrowserExtensionMacOS](https://github.com/DanOrLove/AmneziaBrowserExtensionMacOS).

To open the extension interface only:

1. Download and extract the repository.
2. Open chrome://extensions in Chrome or Chromium.
3. Enable Developer mode, click **Load unpacked**, and select the extension folder.
4. You can inspect the interface, but importing a profile will not connect the VPN. Clicking **Connect** cannot start the native host, and browser traffic will not go through the tunnel.

Do not run native/build.ps1 or native/install.ps1 on these systems. Full support requires a native host port for macOS/Linux, build and Native Messaging registration scripts for each OS, and connection testing on those systems.
### First connection and usage

1. Click the **Amnezia Browser VPN** toolbar icon.
2. Under **Add config**, choose a `.conf` file or paste the profile text. Enter a profile name and click **Save config**.
3. Select a profile and click **Connect**.
4. Open a website in Chromium. AmneziaWG performs its handshake on the first network request; starting the local proxy alone does not prove that the VPN server is reachable.
5. Click **Disconnect VPN** to restore the previous browser proxy and WebRTC settings.

Check the public IP in the browser before and after connecting. Other Windows applications should continue using the normal system connection.

### Rebuild and update

After updating the source, run `install.bat` again to rebuild and register the host. Then reload the extension on `chrome://extensions` or `edge://extensions`. To run only the commands manually:

```powershell
powershell -ExecutionPolicy Bypass -File .\native\build.ps1
powershell -ExecutionPolicy Bypass -File .\native\install.ps1
```

Then reload the extension on `chrome://extensions` or `edge://extensions`. Profiles remain in the browser's local extension storage when the extension is reloaded. Removing the extension may delete them, so keep the original configuration files separately.

### Uninstall

1. If the VPN is connected, click **Disconnect VPN** in the extension.
2. Remove the extension from the browser's extensions page.
3. From the project root, run `uninstall.bat` (or `powershell -ExecutionPolicy Bypass -File .\uninstall.ps1`). It stops the tunnel and removes the Native Messaging registration for every browser, the built `.exe`, the downloaded Go toolchain, and `%LOCALAPPDATA%\AmneziaBrowserVPN`.

4. Use `-KeepData` to keep the log and working files and `-Force` to skip the confirmation prompt.

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -KeepData -Force
   ```

### Diagnostics

Check a profile without connecting (parsing, obfuscation parameters, Endpoint resolution):

```powershell
.\native\AmneziaBrowserVpnHost.exe check .\my-profile.conf
```

The command prints addresses, DNS, MTU, the applied AmneziaWG parameters (Jc/Jmin/Jmax, S1-S4, H1-H4, I1-I5), the resolved Endpoint IP and any skipped parameters. Exit code 1 means the profile is not usable.

Logs:

- `%LOCALAPPDATA%\AmneziaBrowserVPN\install.log` — installation and registration.
- `%LOCALAPPDATA%\AmneziaBrowserVPN\proxy.log` — tunnel runtime. Set `AMNEZIA_LOG_LEVEL=verbose` for detailed output.

The local SOCKS5 port is chosen automatically (1080-1089) because 1080 is often taken by other SOCKS clients. The actual port is returned to the extension and stored in `proxy.pid` as `PID PORT`; `AMNEZIA_PROXY_PORT` pins a specific port.

### Troubleshooting

- **“Native host has exited” / host not found:** make sure `native\AmneziaBrowserVpnHost.exe` was built and `native\install.ps1` was run from the folder where the project will remain installed. Restart the browser afterward.
- **Go build error:** the installer downloads Go automatically. If that fails, install Go manually from the [official downloads page](https://go.dev/dl/) and run `install.ps1 -GoExe \"C:\Program Files\Go\bin\go.exe\"`. Details are in `%LOCALAPPDATA%\AmneziaBrowserVPN\install.log`.
- **Port 1080 is busy:** the component picks the first free port in the 1080-1089 range and reports it to the extension. Set `AMNEZIA_PROXY_PORT` to pin a specific port.
- **A website does not load:** check server availability, `PrivateKey`/`PublicKey`, `Endpoint`, and the obfuscation parameters configured on the server. The native component log is `%LOCALAPPDATA%\AmneziaBrowserVPN\proxy.log`.
- **The extension cannot control proxy or WebRTC settings:** check browser policies and other extensions that may control the same settings.

### Limitations and security

- This is an early prototype. The local bridge carries TCP CONNECT over SOCKS5. UDP applications and QUIC are not tunneled. Chromium is configured to block WebRTC UDP that cannot use the proxy; enterprise browser policy may prevent changing this setting.
- A successful start only confirms that the local proxy is listening. Confirm VPN connectivity with an actual browser request.
- The config's `DNS` setting must contain DNS server IP addresses. DNS hostnames are unsupported.
- An unauthenticated SOCKS5 proxy listens only on `127.0.0.1:1080`. The extension configures the browser automatically; other applications are not redirected, although a local application can connect to the proxy port if it chooses.
- Profiles in `chrome.storage.local` and the temporary `active.conf` contain the private key in plaintext accessible to the current Windows account. Do not publish your profiles. Remove the app data folder after disconnecting if you no longer need it.
- `.gitignore` excludes `.conf`, `.vpn`, the generated `.exe`, local SDKs, and the generated Native Messaging manifest. Always review `git status` and the staged file list before committing.

### Project layout

- `extension/` — Manifest V3 UI, local profile storage, and Chromium proxy control.
- `native/main.go` — Native Messaging host, AmneziaWG setup using the official Go library, and SOCKS5 TCP CONNECT bridge.
- `install.ps1`, `install.bat` — one-shot installer: checks, automatic Go setup, build, registration, browser launch.
- `uninstall.ps1`, `uninstall.bat` — removes the registration, working data, and downloaded tooling.
- `native/common.ps1` — shared installer helpers: logging, Go download, browser discovery, extension ID.
- `native/build.ps1` — builds the Windows executable (x64/ARM64) and verifies it starts.
- `native/install.ps1` — registers/unregisters the Native Messaging host for Chromium-based browsers.
- `native/THIRD_PARTY.md` — information about the main third-party dependency.
