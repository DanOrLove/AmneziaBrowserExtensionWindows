// Проверки разбора конфигов AmneziaWG/WireGuard.
// Запуск: go test ./native (в Windows).
package main

import (
	"encoding/base64"
	"strings"
	"testing"
)

func key() string {
	return base64.StdEncoding.EncodeToString(make([]byte, 32))
}

func amneziaConfig(extra string) string {
	return "[Interface]\n" +
		"PrivateKey = " + key() + "\n" +
		"Address = 10.8.1.2/32\n" +
		"Jc = 4\nJmin = 40\nJmax = 70\nS1 = 30\nS2 = 40\n" +
		"H1 = 1234\nH2 = 2345\nH3 = 3456\nH4 = 4567\n" +
		extra +
		"\n[Peer]\n" +
		"PublicKey = " + key() + "\n" +
		"AllowedIPs = 0.0.0.0/0, ::/0\n" +
		"Endpoint = 1.2.3.4:51820\n" +
		"PersistentKeepalive = 25\n"
}

func TestAmneziaConfigParses(t *testing.T) {
	cfg, err := parseConfig(amneziaConfig(""))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if err := resolveEndpoint(cfg); err != nil {
		t.Fatalf("endpoint resolution failed: %v", err)
	}
	ipc := cfg.ipc.String()
	for _, want := range []string{"jc=4", "jmin=40", "jmax=70", "s1=30", "s2=40", "h1=1234", "h4=4567", "persistent_keepalive_interval=25", "endpoint=1.2.3.4:51820"} {
		if !strings.Contains(ipc, want+"\n") {
			t.Errorf("ipc missing %q:\n%s", want, ipc)
		}
	}
	if len(cfg.ignored) != 0 {
		t.Errorf("unexpected ignored keys: %v", cfg.ignored)
	}
	if len(cfg.dns) != 1 || cfg.dns[0].String() != "1.1.1.1" {
		t.Errorf("expected default DNS, got %v", cfg.dns)
	}
	if len(cfg.addresses) != 1 || cfg.addresses[0].String() != "10.8.1.2" {
		t.Errorf("unexpected addresses: %v", cfg.addresses)
	}
}

func TestWgQuickExtrasAreIgnored(t *testing.T) {
	extra := "DNS = 1.1.1.1, 8.8.8.8\nTable = off\nPreUp = echo hi\nPostUp = route add\nJ1 = 5\nMTU = 1280\n"
	cfg, err := parseConfig(amneziaConfig(extra))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	ipc := cfg.ipc.String()
	for _, banned := range []string{"table=", "preup=", "postup=", "j1=", "mtu=", "dns="} {
		if strings.Contains(ipc, banned) {
			t.Errorf("ipc must not contain %q", banned)
		}
	}
	joined := strings.Join(cfg.ignored, ",")
	for _, want := range []string{"table", "preup", "postup", "j1"} {
		if !strings.Contains(joined, want) {
			t.Errorf("ignored keys missing %q (got %v)", want, cfg.ignored)
		}
	}
	if cfg.mtu != 1280 {
		t.Errorf("MTU not applied: %d", cfg.mtu)
	}
	if len(cfg.dns) != 2 {
		t.Errorf("expected 2 DNS servers, got %v", cfg.dns)
	}
}

func TestMissingRequiredFields(t *testing.T) {
	_, err := parseConfig("[Interface]\nPrivateKey = " + key() + "\nAddress = 10.0.0.2/32\n")
	if err == nil {
		t.Fatal("expected error for incomplete config")
	}
}

func TestHexKeysAccepted(t *testing.T) {
	const hexKey = "0000000000000000000000000000000000000000000000000000000000000000"
	source := "[Interface]\nPrivateKey = " + hexKey + "\nAddress = 10.0.0.2/32\nDNS = 1.1.1.1\n" +
		"[Peer]\nPublicKey = " + hexKey + "\nAllowedIPs = 0.0.0.0/0\nEndpoint = example.com:51820\n"
	cfg, err := parseConfig(source)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(cfg.ipc.String(), "private_key="+hexKey) {
		t.Errorf("hex key not converted: %s", cfg.ipc.String())
	}
}

func TestCommentsIgnored(t *testing.T) {
	source := "# leading comment\n[Interface]\nPrivateKey = " + key() + " # inline\n" +
		"Address = 10.0.0.2/32 ; trailing\nDNS = 1.1.1.1\n" +
		"[Peer]\nPublicKey = " + key() + "\nAllowedIPs = 0.0.0.0/0\nEndpoint = 1.2.3.4:51820\n"
	if _, err := parseConfig(source); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestSuccessMessageMentionsSkippedKeys(t *testing.T) {
	cfg, err := parseConfig(amneziaConfig("Table = off\n"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	message := successMessage(cfg, 1080)
	if !strings.Contains(message, "table") {
		t.Errorf("message should mention skipped keys: %s", message)
	}
}

func TestEndpointWithIPIsUsedAsIs(t *testing.T) {
	cfg, err := parseConfig(amneziaConfig(""))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if err := resolveEndpoint(cfg); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(cfg.ipc.String(), "endpoint=1.2.3.4:51820") {
		t.Errorf("endpoint not written to ipc: %s", cfg.ipc.String())
	}
}

func TestEndpointWithHostnameIsResolved(t *testing.T) {
	source := "[Interface]\nPrivateKey = " + key() + "\nAddress = 10.0.0.2/32\nDNS = 1.1.1.1\n" +
		"[Peer]\nPublicKey = " + key() + "\nAllowedIPs = 0.0.0.0/0\nEndpoint = localhost:51820\n"
	cfg, err := parseConfig(source)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if err := resolveEndpoint(cfg); err != nil {
		t.Fatalf("hostname endpoint must resolve: %v", err)
	}
	ipc := cfg.ipc.String()
	if !strings.Contains(ipc, "endpoint=127.0.0.1:51820") && !strings.Contains(ipc, "endpoint=[::1]:51820") {
		t.Errorf("hostname endpoint not resolved: %s", ipc)
	}
}

func TestEndpointWithoutResolvedNameFails(t *testing.T) {
	source := "[Interface]\nPrivateKey = " + key() + "\nAddress = 10.0.0.2/32\nDNS = 1.1.1.1\n" +
		"[Peer]\nPublicKey = " + key() + "\nAllowedIPs = 0.0.0.0/0\nEndpoint = does-not-exist.invalid:51820\n"
	cfg, err := parseConfig(source)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if err := resolveEndpoint(cfg); err == nil {
		t.Fatal("expected resolution error for a non-existent host")
	}
}
