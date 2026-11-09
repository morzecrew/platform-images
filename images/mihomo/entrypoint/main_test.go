package main

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The generic parts, $file and the healthcheck among them, are tested in
// shared/go/envconf.

func write(t *testing.T, path, content string, mode os.FileMode) string {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestResolveSource(t *testing.T) {
	dir := t.TempDir()
	if _, err := resolveSource(filepath.Join(dir, "absent")); err == nil || !strings.Contains(err.Error(), "cannot be read") {
		t.Errorf("absent: err = %v", err)
	}
	if _, err := resolveSource(dir); err == nil || !strings.Contains(err.Error(), "holds no config.json") {
		t.Errorf("empty: err = %v", err)
	}
	url := write(t, filepath.Join(dir, "url"), "https://sub.example/s/t0ken\n", 0o400)
	src := filepath.Join(dir, "src")
	if err := os.Mkdir(src, 0o700); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(src, "config.json"), `{"proxy-providers": {"sub": {"type": "http", "url": {"$file": "`+url+`"}}}}`, 0o600)
	c, err := resolveSource(src)
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"proxy-providers":{"sub":{"type":"http","url":"https://sub.example/s/t0ken"}}}` + "\n"; string(c.Out) != want {
		t.Errorf("resolved %s", c.Out)
	}
	if len(c.Refs) != 1 || c.Refs[0].Path != "proxy-providers.sub.url" || c.Refs[0].File != url {
		t.Errorf("refs = %v", c.Refs)
	}
	for _, other := range []string{"config.yaml", "rules.json", ".hidden"} {
		p := write(t, filepath.Join(src, other), "{}", 0o600)
		if _, err := resolveSource(src); err == nil || !strings.Contains(err.Error(), p+" is not a file named config.json") {
			t.Errorf("%s: err = %v", other, err)
		}
		os.Remove(p)
	}
	os.Remove(filepath.Join(src, "config.json"))
	if err := os.Mkdir(filepath.Join(src, "config.json"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := resolveSource(src); err == nil || !strings.Contains(err.Error(), "config.json is not a file named config.json") {
		t.Errorf("a directory: err = %v", err)
	}
}

func TestCompetingConfigIsRefused(t *testing.T) {
	for _, name := range []string{"CLASH_CONFIG_STRING", "CLASH_CONFIG_FILE", "CLASH_HOME_DIR"} {
		t.Run(name, func(t *testing.T) {
			t.Setenv(name, "x")
			if err := checkEnv(); err == nil || !strings.HasPrefix(err.Error(), name+" is set") {
				t.Errorf("err = %v", err)
			}
		})
	}
	t.Setenv("CLASH_CONFIG_STRING", "")
	if err := checkEnv(); err != nil {
		t.Errorf("set empty: %v", err)
	}
}

func TestController(t *testing.T) {
	for _, tc := range []struct {
		name    string
		doc     map[string]any
		env     map[string]string
		refused string
	}{
		{"none", map[string]any{}, nil, ""},
		{"loopback", map[string]any{"external-controller": "127.0.0.1:9090"}, nil, ""},
		{"loopback, IPv6", map[string]any{"external-controller": "[::1]:9090"}, nil, ""},
		{"localhost", map[string]any{"external-controller": "localhost:9090"}, nil, ""},
		{"all interfaces", map[string]any{"external-controller": ":9090"}, nil, "external-controller is :9090, beyond loopback"},
		{"any address", map[string]any{"external-controller": "0.0.0.0:9090"}, nil, "external-controller is 0.0.0.0:9090"},
		{"TLS beyond loopback", map[string]any{"external-controller-tls": "192.0.2.1:9443"}, nil, "external-controller-tls is 192.0.2.1:9443"},
		{"no port", map[string]any{"external-controller": "127.0.0.1"}, nil, "beyond loopback"},
		{"with a secret", map[string]any{"external-controller": "0.0.0.0:9090", "secret": "s"}, nil, ""},
		{"an empty secret", map[string]any{"external-controller": "0.0.0.0:9090", "secret": ""}, nil, "secret is empty"},
		{"opened by upstream's override", map[string]any{"external-controller": "127.0.0.1:9090"},
			map[string]string{"CLASH_OVERRIDE_EXTERNAL_CONTROLLER": "0.0.0.0:9090"}, "CLASH_OVERRIDE_EXTERNAL_CONTROLLER is 0.0.0.0:9090"},
		{"a secret by upstream's override", map[string]any{"external-controller": "0.0.0.0:9090"},
			map[string]string{"CLASH_OVERRIDE_SECRET": "s"}, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for _, name := range []string{"CLASH_OVERRIDE_EXTERNAL_CONTROLLER", "CLASH_OVERRIDE_EXTERNAL_CONTROLLER_TLS", "CLASH_OVERRIDE_SECRET"} {
				t.Setenv(name, tc.env[name])
			}
			err := checkController(tc.doc)
			if tc.refused == "" && err != nil {
				t.Errorf("refused: %v", err)
			}
			if tc.refused != "" && (err == nil || !strings.Contains(err.Error(), tc.refused)) {
				t.Errorf("err = %v, want %q", err, tc.refused)
			}
		})
	}
}

func TestWriteHome(t *testing.T) {
	geodataDir = t.TempDir()
	for _, name := range geodata {
		write(t, filepath.Join(geodataDir, name), "pinned "+name, 0o444)
	}
	home := filepath.Join(t.TempDir(), "home")
	if err := os.Mkdir(home, 0o755); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(home, "config.json"), "old", 0o644)
	write(t, filepath.Join(home, "geosite.dat"), "updated", 0o644)

	if err := writeHome(home, []byte("{}\n")); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(home, "config.json")); string(b) != "{}\n" {
		t.Errorf("config.json holds %q", b)
	}
	if info, _ := os.Stat(filepath.Join(home, "config.json")); info.Mode().Perm() != 0o600 {
		t.Errorf("config.json mode %v", info.Mode().Perm())
	}
	if info, _ := os.Stat(filepath.Join(home, "geoip.dat")); info.Mode().Perm() != 0o644 {
		t.Errorf("geoip.dat mode %v", info.Mode().Perm())
	}
	for name, want := range map[string]string{"geoip.metadb": "pinned geoip.metadb", "geoip.dat": "pinned geoip.dat", "geosite.dat": "updated"} {
		if b, _ := os.ReadFile(filepath.Join(home, name)); string(b) != want {
			t.Errorf("%s holds %q, want %q", name, b, want)
		}
	}
	if found, _ := filepath.Glob(filepath.Join(home, "*.*.*")); len(found) != 0 {
		t.Errorf("left %v", found)
	}

	if err := writeHome(filepath.Join(home, "config.json", "below-a-file"), []byte("{}")); err == nil || !strings.Contains(err.Error(), "Mount a volume there") {
		t.Errorf("unwritable: err = %v", err)
	}
}

// The resolved secrets go into a new file, created 0600, which then replaces
// the old one: never into a file that is already there at a looser mode, and
// never as a half-written config.json that a start racing this one could read.
func TestWriteHomeReplacesConfig(t *testing.T) {
	geodataDir = t.TempDir()
	for _, name := range geodata {
		write(t, filepath.Join(geodataDir, name), name, 0o444)
	}
	home := t.TempDir()
	old := write(t, filepath.Join(home, "config.json"), "old", 0o644)
	f, err := os.Open(old)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := writeHome(home, []byte("{\"secret\": 1}\n")); err != nil {
		t.Fatal(err)
	}
	if b, _ := io.ReadAll(f); string(b) != "old" {
		t.Errorf("the secrets were written into the file that was there, at 0644: it now holds %q", b)
	}
	if found, _ := filepath.Glob(filepath.Join(home, "config.json?*")); len(found) != 0 {
		t.Errorf("left %v", found)
	}
}
