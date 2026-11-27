package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun/netstack"
)

const defaultProxyPort = 1080
const maxProxyPortAttempts = 10
const maxMessage = 2 * 1024 * 1024
const defaultDNS = "1.1.1.1"
const hostVersion = "amnezia-browser-vpn-host 0.3.0 windows"

type request struct {
	Command string `json:"command"`
	Config  string `json:"config"`
}

type response struct {
	OK      bool   `json:"ok"`
	Running bool   `json:"running,omitempty"`
	Port    int    `json:"port,omitempty"`
	Message string `json:"message,omitempty"`
}

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "--version", "-version", "version":
			fmt.Println(hostVersion)
			return
		case "check":
			if len(os.Args) != 3 {
				os.Exit(2)
			}
			if err := checkConfig(os.Args[2]); err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			return
		case "proxy":
			if len(os.Args) != 3 && len(os.Args) != 4 {
				os.Exit(2)
			}
			port := defaultProxyPort
			if len(os.Args) == 4 {
				parsed, err := strconv.Atoi(os.Args[3])
				if err != nil || parsed < 1 || parsed > 65535 {
					os.Exit(2)
				}
				port = parsed
			}
			if err := runProxy(os.Args[2], port); err != nil {
				log.Print(err)
				os.Exit(1)
			}
			return
		}
	}
	runNativeHost()
}

func runNativeHost() {
	requestBytes, err := readNativeMessage(os.Stdin)
	if err != nil {
		writeNativeResponse(response{Message: "Не удалось прочитать команду расширения."})
		return
	}
	var req request
	if err := json.Unmarshal(requestBytes, &req); err != nil {
		writeNativeResponse(response{Message: "Команда расширения повреждена."})
		return
	}

	var result response
	switch req.Command {
	case "start":
		result = startProxy(req.Config)
	case "stop":
		result = stopProxy()
	case "status":
		result = response{OK: true, Running: proxyRunning()}
	default:
		result = response{Message: "Неизвестная команда."}
	}
	writeNativeResponse(result)
}

func readNativeMessage(r io.Reader) ([]byte, error) {
	var header [4]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return nil, err
	}
	size := binary.LittleEndian.Uint32(header[:])
	if size == 0 || size > maxMessage {
		return nil, errors.New("invalid message size")
	}
	data := make([]byte, size)
	_, err := io.ReadFull(r, data)
	return data, err
}

func writeNativeResponse(value response) {
	data, err := json.Marshal(value)
	if err != nil || len(data) > maxMessage {
		return
	}
	var header [4]byte
	binary.LittleEndian.PutUint32(header[:], uint32(len(data)))
	_, _ = os.Stdout.Write(header[:])
	_, _ = os.Stdout.Write(data)
}

func dataDirectory() (string, error) {
	root := os.Getenv("LOCALAPPDATA")
	if root == "" {
		return "", errors.New("LOCALAPPDATA is unavailable")
	}
	dir := filepath.Join(root, "AmneziaBrowserVPN")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return "", err
	}
	return dir, nil
}

func startProxy(config string) response {
	cfg, err := parseConfig(config)
	if err != nil {
		return response{Message: "Конфиг не подходит для AmneziaWG: " + err.Error()}
	}
	if err := resolveEndpoint(cfg); err != nil {
		return response{Message: "Конфиг не подходит для AmneziaWG: " + err.Error()}
	}
	if proxyRunning() {
		// Подключение другим профилем: перезапускаем туннель с новым конфигом.
		if stopped := stopProxy(); !stopped.OK {
			return stopped
		}
	}
	port := chooseProxyPort()
	if proxyListening(port) {
		return response{Message: fmt.Sprintf("Порт %d занят другой программой. Закройте её или задайте переменную AMNEZIA_PROXY_PORT.", port)}
	}
	dir, err := dataDirectory()
	if err != nil {
		return response{Message: "Не удалось подготовить локальное хранилище: " + err.Error()}
	}
	executable, err := os.Executable()
	if err != nil {
		return response{Message: "Не удалось найти компонент VPN."}
	}
	configPath := filepath.Join(dir, "active.conf")
	if err := os.WriteFile(configPath, []byte(config), 0600); err != nil {
		return response{Message: "Не удалось сохранить рабочий конфиг: " + err.Error()}
	}
	logPath := filepath.Join(dir, "proxy.log")
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return response{Message: "Не удалось открыть журнал локального компонента."}
	}
	cmd := exec.Command(executable, "proxy", configPath, strconv.Itoa(port))
	cmd.Stdout, cmd.Stderr = logFile, logFile
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x00000008}
	if err := cmd.Start(); err != nil {
		logFile.Close()
		return response{Message: "Не удалось запустить AmneziaWG: " + err.Error()}
	}
	_ = logFile.Close()
	_ = writeProxyState(dir, cmd.Process.Pid, port)
	for attempt := 0; attempt < 100; attempt++ {
		if proxyListening(port) && processAlive(cmd.Process.Pid) {
			return response{OK: true, Running: true, Port: port, Message: successMessage(cfg, port)}
		}
		if !processAlive(cmd.Process.Pid) {
			_ = os.Remove(filepath.Join(dir, "proxy.pid"))
			_ = os.Remove(configPath)
			return response{Message: "Компонент остановился при запуске. Подробности записаны в локальный журнал."}
		}
		time.Sleep(100 * time.Millisecond)
	}
	_ = cmd.Process.Kill()
	_ = os.Remove(filepath.Join(dir, "proxy.pid"))
	_ = os.Remove(configPath)
	return response{Message: fmt.Sprintf("Прокси не открыл порт %d за 10 секунд. Проверьте конфиг и журнал.", port)}
}

func stopProxy() response {
	dir, err := dataDirectory()
	if err != nil {
		return response{Message: err.Error()}
	}
	pid, port, stateErr := readProxyState(dir)
	if stateErr != nil {
		for candidate := defaultProxyPort; candidate < defaultProxyPort+maxProxyPortAttempts; candidate++ {
			if proxyListening(candidate) {
				return response{Message: "Нашёл локальный прокси, но не его процесс. Остановите его вручную."}
			}
		}
		_ = os.Remove(filepath.Join(dir, "active.conf"))
		return response{OK: true, Message: "VPN уже отключён."}
	}
	if !processAlive(pid) {
		_ = os.Remove(filepath.Join(dir, "proxy.pid"))
		_ = os.Remove(filepath.Join(dir, "active.conf"))
		if proxyListening(port) {
			return response{Message: fmt.Sprintf("Порт %d занят другой программой; её процесс не тронут.", port)}
		}
		return response{OK: true, Message: "VPN уже был остановлен."}
	}
	process, err := os.FindProcess(pid)
	if err != nil {
		return response{Message: "Не удалось открыть процесс локального туннеля."}
	}
	if err := process.Kill(); err != nil {
		return response{Message: "Не удалось остановить AmneziaWG: " + err.Error()}
	}
	for attempt := 0; attempt < 50 && proxyListening(port); attempt++ {
		time.Sleep(100 * time.Millisecond)
	}
	if proxyListening(port) {
		return response{Message: "Локальный прокси всё ещё отвечает; браузерный прокси восстановлен, но процесс требует остановки."}
	}
	_ = os.Remove(filepath.Join(dir, "proxy.pid"))
	_ = os.Remove(filepath.Join(dir, "active.conf"))
	return response{OK: true, Message: "VPN отключён для Chromium."}
}

func processAlive(pid int) bool {
	// On Windows, FindProcess doesn't report whether the process has exited.
	handle, err := syscall.OpenProcess(0x1000, false, uint32(pid)) // PROCESS_QUERY_LIMITED_INFORMATION
	if err != nil {
		return false
	}
	defer syscall.CloseHandle(handle)
	var exitCode uint32
	if syscall.GetExitCodeProcess(handle, &exitCode) != nil {
		return false
	}
	if exitCode != 259 {
		return false
	} // STILL_ACTIVE
	imagePath, err := processImagePath(handle)
	if err != nil {
		return false
	}
	executable, err := os.Executable()
	return err == nil && strings.EqualFold(filepath.Clean(imagePath), filepath.Clean(executable))
}

func processImagePath(handle syscall.Handle) (string, error) {
	proc := syscall.NewLazyDLL("kernel32.dll").NewProc("QueryFullProcessImageNameW")
	var buffer [2048]uint16
	size := uint32(len(buffer))
	result, _, callErr := proc.Call(uintptr(handle), 0, uintptr(unsafe.Pointer(&buffer[0])), uintptr(unsafe.Pointer(&size)))
	if result == 0 {
		return "", callErr
	}
	return syscall.UTF16ToString(buffer[:size]), nil
}

func proxyListening(port int) bool {
	conn, err := net.DialTimeout("tcp", proxyAddress(port), 150*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

func proxyAddress(port int) string {
	return net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
}

// chooseProxyPort берёт порт из AMNEZIA_PROXY_PORT либо первый свободный,
// начиная с 1080: этот порт часто занят другими SOCKS-клиентами.
func chooseProxyPort() int {
	if raw := strings.TrimSpace(os.Getenv("AMNEZIA_PROXY_PORT")); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 && parsed < 65536 {
			return parsed
		}
	}
	for port := defaultProxyPort; port < defaultProxyPort+maxProxyPortAttempts; port++ {
		if !proxyListening(port) {
			return port
		}
	}
	return defaultProxyPort
}

// readProxyState читает PID и порт из файла состояния "PID PORT".
// Файл старого формата (только PID) тоже поддерживается.
func readProxyState(dir string) (pid int, port int, err error) {
	data, err := os.ReadFile(filepath.Join(dir, "proxy.pid"))
	if err != nil {
		return 0, 0, err
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return 0, 0, errors.New("state file is empty")
	}
	pid, err = strconv.Atoi(fields[0])
	if err != nil || pid < 1 {
		return 0, 0, errors.New("state file is damaged")
	}
	port = defaultProxyPort
	if len(fields) > 1 {
		if parsed, parseErr := strconv.Atoi(fields[1]); parseErr == nil && parsed > 0 && parsed < 65536 {
			port = parsed
		}
	}
	return pid, port, nil
}

func writeProxyState(dir string, pid, port int) error {
	data := strconv.Itoa(pid) + " " + strconv.Itoa(port)
	return os.WriteFile(filepath.Join(dir, "proxy.pid"), []byte(data), 0600)
}

func proxyRunning() bool {
	dir, err := dataDirectory()
	if err != nil {
		return false
	}
	pid, port, err := readProxyState(dir)
	return err == nil && processAlive(pid) && proxyListening(port)
}

type wgConfig struct {
	addresses    []netip.Addr
	dns          []netip.Addr
	mtu          int
	endpointHost string
	endpointPort string
	ipc          strings.Builder
	ignored      []string
}

// amneziawg-go принимает только эти ключи в IpcSet. Всё остальное (параметры
// wg-quick вида Table/PreUp, теги J1-J3 из AmneziaWG 1.5 и т.п.) раньше
// приводило к ошибке "invalid UAPI key" и полному отказу подключения.
var supportedInterfaceKeys = map[string]bool{
	"listen_port": true, "fwmark": true, "jc": true, "jmin": true, "jmax": true,
	"s1": true, "s2": true, "s3": true, "s4": true,
	"h1": true, "h2": true, "h3": true, "h4": true,
	"i1": true, "i2": true, "i3": true, "i4": true, "i5": true,
	"header_protection_key": true, "content_padding_addition": true,
	"rekey_after_time": true, "rekey_timeout": true, "reject_after_time": true,
	"keepalive_timeout": true, "max_handshake_attempts": true,
	"random_trailers": true, "disable_cookies": true,
}

var supportedPeerKeys = map[string]bool{
	"protocol_version": true,
}

func isSupportedKey(section, key string) bool {
	if section == "interface" {
		return supportedInterfaceKeys[key]
	}
	return supportedPeerKeys[key]
}

func parseConfig(source string) (*wgConfig, error) {
	cfg := &wgConfig{mtu: 1420}
	section := ""
	seenPrivateKey, seenPublicKey, seenEndpoint, seenAllowedIPs := false, false, false, false
	scanner := bufio.NewScanner(strings.NewReader(source))
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	for lineNo := 1; scanner.Scan(); lineNo++ {
		line := strings.TrimSpace(scanner.Text())
		if cut := strings.IndexAny(line, "#;"); cut >= 0 {
			line = strings.TrimSpace(line[:cut])
		}
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.ToLower(strings.TrimSpace(line[1 : len(line)-1]))
			if section != "interface" && section != "peer" {
				return nil, fmt.Errorf("строка %d: неизвестная секция", lineNo)
			}
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok || section == "" {
			return nil, fmt.Errorf("строка %d: ожидалось имя = значение", lineNo)
		}
		key, value = strings.ToLower(strings.TrimSpace(key)), strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if section == "interface" {
			switch key {
			case "privatekey":
				encoded, err := decodeKey(value)
				if err != nil {
					return nil, fmt.Errorf("строка %d: неверный PrivateKey", lineNo)
				}
				cfg.ipc.WriteString("private_key=" + hex.EncodeToString(encoded) + "\n")
				seenPrivateKey = true
			case "address":
				for _, part := range strings.Split(value, ",") {
					p, err := netip.ParsePrefix(strings.TrimSpace(part))
					if err != nil {
						a, addrErr := netip.ParseAddr(strings.TrimSpace(part))
						if addrErr != nil {
							return nil, fmt.Errorf("строка %d: неверный Address", lineNo)
						}
						cfg.addresses = append(cfg.addresses, a)
					} else {
						cfg.addresses = append(cfg.addresses, p.Addr())
					}
				}
			case "dns":
				for _, part := range strings.Split(value, ",") {
					a, err := netip.ParseAddr(strings.TrimSpace(part))
					if err != nil {
						return nil, fmt.Errorf("строка %d: DNS должен содержать IP-адреса", lineNo)
					}
					cfg.dns = append(cfg.dns, a)
				}
			case "mtu":
				parsed, err := strconv.Atoi(value)
				if err != nil || parsed < 576 || parsed > 65535 {
					return nil, fmt.Errorf("строка %d: неверный MTU", lineNo)
				}
				cfg.mtu = parsed
			case "headerprotectionkey":
				encoded, err := decodeKey(value)
				if err != nil {
					return nil, fmt.Errorf("строка %d: неверный HeaderProtectionKey", lineNo)
				}
				cfg.ipc.WriteString("header_protection_key=" + hex.EncodeToString(encoded) + "\n")
			case "randomtrailers", "disablecookies":
				flag := strings.ToLower(value)
				if flag == "on" {
					flag = "true"
				}
				if flag == "off" {
					flag = "false"
				}
				if flag != "true" && flag != "false" {
					return nil, fmt.Errorf("строка %d: ожидалось on/off", lineNo)
				}
				ipcKey := strings.ReplaceAll(key, "trailers", "_trailers")
				ipcKey = strings.ReplaceAll(ipcKey, "cookies", "_cookies")
				cfg.ipc.WriteString(ipcKey + "=" + flag + "\n")
			default:
				if isSupportedKey(section, key) {
					cfg.ipc.WriteString(key + "=" + value + "\n")
				} else {
					cfg.ignored = append(cfg.ignored, key)
				}
			}
		} else {
			switch key {
			case "publickey":
				encoded, err := decodeKey(value)
				if err != nil {
					return nil, fmt.Errorf("строка %d: неверный PublicKey", lineNo)
				}
				cfg.ipc.WriteString("public_key=" + hex.EncodeToString(encoded) + "\n")
				seenPublicKey = true
			case "presharedkey":
				encoded, err := decodeKey(value)
				if err != nil {
					return nil, fmt.Errorf("строка %d: неверный PresharedKey", lineNo)
				}
				cfg.ipc.WriteString("preshared_key=" + hex.EncodeToString(encoded) + "\n")
			case "endpoint":
				host, port, err := net.SplitHostPort(value)
				if err != nil || host == "" || port == "" {
					return nil, fmt.Errorf("строка %d: неверный Endpoint", lineNo)
				}
				// amneziawg-go принимает в endpoint только IP:порт, поэтому имя
				// хоста разрешаем отдельно (resolveEndpoint) перед IpcSet.
				cfg.endpointHost = host
				cfg.endpointPort = port
				seenEndpoint = true
			case "allowedips":
				for _, part := range strings.Split(value, ",") {
					p, err := netip.ParsePrefix(strings.TrimSpace(part))
					if err != nil {
						return nil, fmt.Errorf("строка %d: неверный AllowedIPs", lineNo)
					}
					cfg.ipc.WriteString("allowed_ip=" + p.String() + "\n")
				}
				seenAllowedIPs = true
			case "persistentkeepalive":
				cfg.ipc.WriteString("persistent_keepalive_interval=" + value + "\n")
			default:
				if isSupportedKey(section, key) {
					cfg.ipc.WriteString(key + "=" + value + "\n")
				} else {
					cfg.ignored = append(cfg.ignored, key)
				}
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if !seenPrivateKey || !seenPublicKey || !seenEndpoint || !seenAllowedIPs || len(cfg.addresses) == 0 {
		return nil, errors.New("обязательные поля PrivateKey, Address, PublicKey, Endpoint и AllowedIPs должны быть заполнены")
	}
	// SOCKS5 передаёт имена хостов, поэтому без DNS внутри туннеля ничего не
	// открывается. Если в конфиге DNS не указан, используем публичный резолвер.
	if len(cfg.dns) == 0 {
		cfg.dns = []netip.Addr{netip.MustParseAddr(defaultDNS)}
	}
	cfg.ignored = uniqueKeys(cfg.ignored)
	return cfg, nil
}

func uniqueKeys(keys []string) []string {
	if len(keys) < 2 {
		return keys
	}
	seen := make(map[string]bool, len(keys))
	result := keys[:0]
	for _, key := range keys {
		if seen[key] {
			continue
		}
		seen[key] = true
		result = append(result, key)
	}
	return result
}

// checkConfig печатает разбор конфига без запуска туннеля: удобно проверить,
// что профиль совместим, и увидеть, какие параметры обфускации применились.
func checkConfig(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	cfg, err := parseConfig(string(data))
	if err != nil {
		return fmt.Errorf("конфиг не подходит для AmneziaWG: %w", err)
	}
	if err := resolveEndpoint(cfg); err != nil {
		fmt.Printf("ВНИМАНИЕ: %v\n", err)
	}

	fmt.Printf("файл:   %s\n", path)
	fmt.Printf("адреса: %s\n", joinAddresses(cfg.addresses))
	fmt.Printf("DNS:    %s\n", joinAddresses(cfg.dns))
	fmt.Printf("MTU:    %d\n", cfg.mtu)

	secret := map[string]bool{
		"private_key": true, "public_key": true, "preshared_key": true, "header_protection_key": true,
	}
	var interfaceKeys, peerKeys []string
	section := "interface"
	for _, line := range strings.Split(cfg.ipc.String(), "\n") {
		if line == "" {
			continue
		}
		key, value, _ := strings.Cut(line, "=")
		switch key {
		case "public_key", "preshared_key", "endpoint", "allowed_ip", "persistent_keepalive_interval", "protocol_version":
			section = "peer"
		}
		if secret[key] {
			value = "задан"
		}
		if len(value) > 48 {
			value = fmt.Sprintf("%.24s... (%d символов)", value, len(value))
		}
		if section == "interface" {
			interfaceKeys = append(interfaceKeys, key+"="+value)
		} else {
			peerKeys = append(peerKeys, key+"="+value)
		}
	}
	fmt.Printf("interface: %s\n", strings.Join(interfaceKeys, ", "))
	fmt.Printf("peer:      %s\n", strings.Join(peerKeys, ", "))
	if len(cfg.ignored) > 0 {
		fmt.Printf("пропущены неподдерживаемые параметры: %s\n", strings.Join(cfg.ignored, ", "))
	} else {
		fmt.Println("пропущенных параметров нет")
	}
	return nil
}

func joinAddresses(addresses []netip.Addr) string {
	if len(addresses) == 0 {
		return "нет"
	}
	parts := make([]string, len(addresses))
	for i, address := range addresses {
		parts[i] = address.String()
	}
	return strings.Join(parts, ", ")
}

func successMessage(cfg *wgConfig, port int) string {
	message := fmt.Sprintf("AmneziaWG-прокси запущен на 127.0.0.1:%d. Трафик браузера пойдёт через туннель.", port)
	if len(cfg.ignored) > 0 {
		message += " Пропущены неподдерживаемые параметры: " + strings.Join(cfg.ignored, ", ") + "."
	}
	return message
}

func decodeKey(value string) ([]byte, error) {
	if raw, err := hex.DecodeString(value); err == nil && len(raw) == 32 {
		return raw, nil
	}
	raw, err := base64.StdEncoding.DecodeString(value)
	if err != nil || len(raw) != 32 {
		return nil, errors.New("ожидался 32-байтовый ключ base64 или hex")
	}
	return raw, nil
}

// Уровень журнала AmneziaWG. AMNEZIA_LOG_LEVEL=verbose включает подробный вывод
// (рукопожатия, ошибки) в proxy.log — это основной инструмент диагностики.
func logLevel() int {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("AMNEZIA_LOG_LEVEL"))) {
	case "verbose", "debug":
		return device.LogLevelVerbose
	case "silent", "off":
		return device.LogLevelSilent
	default:
		return device.LogLevelError
	}
}

// resolveEndpoint превращает Endpoint в формат UAPI "IP:порт": библиотека
// amneziawg-go отвергает доменные имена в endpoint ошибкой ParseAddr.
func resolveEndpoint(cfg *wgConfig) error {
	if cfg.endpointPort == "" {
		return errors.New("в конфиге не задан Endpoint")
	}
	if address, err := netip.ParseAddr(cfg.endpointHost); err == nil {
		cfg.ipc.WriteString("endpoint=" + net.JoinHostPort(address.String(), cfg.endpointPort) + "\n")
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	addresses, err := net.DefaultResolver.LookupIPAddr(ctx, cfg.endpointHost)
	if err != nil || len(addresses) == 0 {
		return fmt.Errorf("не удалось разрешить имя Endpoint %q: %v", cfg.endpointHost, err)
	}
	chosen := addresses[0].IP
	for _, candidate := range addresses {
		if candidate.IP.To4() != nil {
			chosen = candidate.IP
			break
		}
	}
	cfg.ipc.WriteString("endpoint=" + net.JoinHostPort(chosen.String(), cfg.endpointPort) + "\n")
	return nil
}

func runProxy(configPath string, port int) error {
	data, err := os.ReadFile(configPath)
	if err != nil {
		return err
	}
	cfg, err := parseConfig(string(data))
	if err != nil {
		return err
	}
	if err := resolveEndpoint(cfg); err != nil {
		return err
	}
	tun, tunnel, err := netstack.CreateNetTUN(cfg.addresses, cfg.dns, cfg.mtu)
	if err != nil {
		return err
	}
	dev := device.NewDevice(tun, conn.NewDefaultBind(), device.NewLogger(logLevel(), "amneziawg: "))
	if err := dev.IpcSet(cfg.ipc.String()); err != nil {
		dev.Close()
		return err
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return err
	}
	defer dev.Close()
	ln, err := net.Listen("tcp", proxyAddress(port))
	if err != nil {
		return err
	}
	defer ln.Close()
	for {
		client, err := ln.Accept()
		if err != nil {
			return err
		}
		go serveSocks5(client, tunnel.DialContext)
	}
}

func serveSocks5(client net.Conn, dial func(context.Context, string, string) (net.Conn, error)) {
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(15 * time.Second))
	var header [2]byte
	if _, err := io.ReadFull(client, header[:]); err != nil || header[0] != 5 {
		return
	}
	methods := make([]byte, int(header[1]))
	if _, err := io.ReadFull(client, methods); err != nil {
		return
	}
	noAuth := false
	for _, method := range methods {
		if method == 0 {
			noAuth = true
			break
		}
	}
	if !noAuth {
		_, _ = client.Write([]byte{5, 255})
		return
	}
	if _, err := client.Write([]byte{5, 0}); err != nil {
		return
	} // no-auth; loopback only
	var req [4]byte
	if _, err := io.ReadFull(client, req[:]); err != nil || req[0] != 5 || req[1] != 1 || req[2] != 0 {
		return
	}
	host := ""
	switch req[3] {
	case 1:
		addr := make([]byte, 4)
		if _, err := io.ReadFull(client, addr); err != nil {
			return
		}
		host = net.IP(addr).String()
	case 4:
		addr := make([]byte, 16)
		if _, err := io.ReadFull(client, addr); err != nil {
			return
		}
		host = net.IP(addr).String()
	case 3:
		size := []byte{0}
		if _, err := io.ReadFull(client, size); err != nil {
			return
		}
		name := make([]byte, int(size[0]))
		if _, err := io.ReadFull(client, name); err != nil {
			return
		}
		host = string(name)
	default:
		return
	}
	var portBytes [2]byte
	if _, err := io.ReadFull(client, portBytes[:]); err != nil {
		return
	}
	port := binary.BigEndian.Uint16(portBytes[:])
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	upstream, err := dial(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(int(port))))
	if err != nil {
		_, _ = client.Write([]byte{5, 4, 0, 1, 0, 0, 0, 0, 0, 0})
		return
	}
	defer upstream.Close()
	_ = client.SetDeadline(time.Time{})
	if _, err := client.Write([]byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0}); err != nil {
		return
	}
	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(upstream, client)
		if half, ok := upstream.(interface{ CloseWrite() error }); ok {
			_ = half.CloseWrite()
		}
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(client, upstream)
		if half, ok := client.(interface{ CloseWrite() error }); ok {
			_ = half.CloseWrite()
		}
		done <- struct{}{}
	}()
	<-done
	<-done
}
