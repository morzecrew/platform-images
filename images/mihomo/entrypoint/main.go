// mihomo-entrypoint starts mihomo on a config whose secrets are files.
//
//	mihomo-entrypoint [run]                resolve, check, test, then exec mihomo
//	mihomo-entrypoint healthcheck          probe egress through mihomo
//	mihomo-entrypoint <anything else...>   exec mihomo with those arguments
//
// mihomo reads no value from a file and expands no variable, so a secret can
// only reach it inside its config. The source is one JSON file, which mihomo
// reads as YAML; this replaces each JSON object in it that is exactly
// {"$file": "/absolute/path"} with that file's content as a string, and
// changes nothing else. The contract is in images/mihomo/README.md.
package main

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/morzecrew/platform-images/shared/go/envconf"
)

// mihomo's own names are CLASH_*, SAFE_PATHS and the like, outside the prefix.
var img = &envconf.Image{
	Name: "mihomo", Title: "mihomo", Bin: "/usr/local/bin/mihomo", Prefix: "MIHOMO_",
	Readme: "images/mihomo/README.md",
	Settings: []envconf.Setting{
		{Name: "MIHOMO_SOURCE_DIR", Default: "/etc/mihomo"},
		{Name: "MIHOMO_HOME", Default: "/var/lib/mihomo"},
		{Name: "MIHOMO_HEALTHCHECK_URL", Default: "https://www.gstatic.com/generate_204"},
		{Name: "MIHOMO_HEALTHCHECK_PROXY", Default: ""},
		{Name: "MIHOMO_HEALTHCHECK_TIMEOUT", Default: "10s"},
		{Name: "MIHOMO_HEALTHCHECK_EXPECT", Default: ""},
	},
}

const configName = "config.json"

// The geodata copied from upstream's image at build time. A var, so the tests
// can point it elsewhere.
var (
	geodataDir = "/usr/local/share/mihomo"
	geodata    = []string{"geoip.metadb", "geosite.dat", "geoip.dat"}
)

func main() {
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "healthcheck" {
		os.Exit(img.Healthcheck(filepath.Join(img.Get("MIHOMO_HOME"), configName)))
	}
	if len(args) > 0 && args[0] != "run" {
		img.Exec(args...) // -v, -t, generate, convert-ruleset, ...
	}
	// -d, -f, -config, -ext-ctl and -secret would each undo what start checks.
	if len(args) > 1 {
		fmt.Fprintln(os.Stderr, "usage: mihomo-entrypoint [run]\n`run` takes no arguments: mihomo is configured by $MIHOMO_SOURCE_DIR/config.json. To run mihomo with flags of your own, give them without `run`.")
		os.Exit(2)
	}
	if err := start(); err != nil {
		fmt.Fprintln(os.Stderr, "FATAL:", err)
		os.Exit(envconf.ExConfig)
	}
}

func start() error {
	img.WarnUnknown()
	if err := checkEnv(); err != nil {
		return err
	}
	src := filepath.Clean(img.Get("MIHOMO_SOURCE_DIR"))
	home := filepath.Clean(img.Get("MIHOMO_HOME"))
	// The resolved config is written into the home directory, so a home that
	// is or holds the source would have its config replaced with the
	// resolved secrets, and the next start would find no reference to read.
	if envconf.Overlap(src, home) {
		return fmt.Errorf("MIHOMO_HOME (%s) and MIHOMO_SOURCE_DIR (%s) overlap, and the resolved config is written into MIHOMO_HOME. Point them at separate directories", home, src)
	}
	if _, err := img.HealthSettings(); err != nil {
		return err
	}
	c, err := resolveSource(src)
	if err != nil {
		return err
	}
	if err := checkController(c.Doc); err != nil {
		return err
	}
	if err := writeHome(home, c.Out); err != nil {
		return err
	}
	cfg := filepath.Join(home, configName)
	version, err := testConfig(home, cfg, c.Values)
	if err != nil {
		return err
	}
	img.Summary(os.Stderr, version, []*envconf.Config{c})
	img.Exec("-d", home, "-f", cfg)
	return nil
}

// mihomo reads these instead of, or as well as, the config this image hands
// it. CLASH_CONFIG_STRING wins over -f; the other two lose to -d and -f
// silently. Either way two configs would compete, so each is refused.
var competing = [][2]string{
	{"CLASH_CONFIG_STRING", "a whole config, which mihomo would read instead of the one resolved from MIHOMO_SOURCE_DIR"},
	{"CLASH_CONFIG_FILE", "a config file, which this image replaces with the one resolved from MIHOMO_SOURCE_DIR"},
	{"CLASH_HOME_DIR", "a home directory, which this image replaces with MIHOMO_HOME"},
}

func checkEnv() error {
	for _, c := range competing {
		if os.Getenv(c[0]) != "" {
			return fmt.Errorf("%s is set: it names %s. Unset it -- see images/mihomo/README.md", c[0], c[1])
		}
	}
	if skip, _ := strconv.ParseBool(os.Getenv("SKIP_SAFE_PATH_CHECK")); skip {
		fmt.Fprintln(os.Stderr, "WARN: SKIP_SAFE_PATH_CHECK is true, so mihomo reads a provider or rule file at any path the config names, not only under MIHOMO_HOME and SAFE_PATHS.")
	}
	return nil
}

// The source directory holds config.json and nothing else: a second file is
// one the operator expects mihomo to read, and it would not be.
func resolveSource(dir string) (*envconf.Config, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("MIHOMO_SOURCE_DIR is %s, which cannot be read (%v). Mount the mihomo config there", dir, envconf.Cause(err))
	}
	found := false
	for _, e := range entries {
		p := filepath.Join(dir, e.Name())
		info, err := os.Stat(p)
		if err != nil {
			return nil, fmt.Errorf("%s: %v", p, envconf.Cause(err))
		}
		if e.Name() != configName || !info.Mode().IsRegular() {
			return nil, fmt.Errorf("%s is not a file named %s. MIHOMO_SOURCE_DIR holds that one file and nothing else; mihomo's YAML is written as JSON here, so that its file references can be resolved", p, configName)
		}
		found = true
	}
	if !found {
		return nil, fmt.Errorf("MIHOMO_SOURCE_DIR is %s, which holds no %s. Mount the mihomo config there", dir, configName)
	}
	return envconf.ResolveFile(filepath.Join(dir, configName), []envconf.Reference{envconf.File})
}

// The REST API reads and changes the whole configuration, the subscription
// included, so it may listen beyond loopback only behind a secret. Upstream's
// overrides are applied first, as mihomo applies them.
func checkController(doc any) error {
	m, _ := doc.(map[string]any)
	value := func(env, key string) (string, string) {
		if v := os.Getenv(env); v != "" {
			return v, env
		}
		s, _ := m[key].(string)
		return s, key
	}
	if secret, _ := value("CLASH_OVERRIDE_SECRET", "secret"); secret != "" {
		return nil
	}
	for _, c := range [][2]string{
		{"CLASH_OVERRIDE_EXTERNAL_CONTROLLER", "external-controller"},
		{"CLASH_OVERRIDE_EXTERNAL_CONTROLLER_TLS", "external-controller-tls"},
	} {
		addr, from := value(c[0], c[1])
		if addr != "" && !loopback(addr) {
			return fmt.Errorf("%s is %s, beyond loopback, and secret is empty, so anyone who reaches that port could read the subscription and change the configuration. Set secret, as a $file reference, or listen on 127.0.0.1", from, addr)
		}
	}
	return nil
}

func loopback(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	return host == "localhost" || (ip != nil && ip.IsLoopback())
}

func writeHome(home string, config []byte) error {
	hint := func(err error) error {
		return fmt.Errorf("MIHOMO_HOME is %s, which is not writable by uid %d (%v). Mount a volume there, which also keeps the provider caches across restarts, such as Compose's `volumes: [\"mihomo:%s\"]`", home, os.Getuid(), envconf.Cause(err), home)
	}
	if err := os.MkdirAll(home, 0o700); err != nil {
		return hint(err)
	}
	cfg := filepath.Join(home, configName)
	// WriteFile keeps the mode of a file that is already there.
	if err := os.WriteFile(cfg, config, 0o600); err != nil {
		return hint(err)
	}
	if err := os.Chmod(cfg, 0o600); err != nil {
		return hint(err)
	}
	// Absent files only: geo-auto-update, if the operator turns it on,
	// replaces them in the home directory, and a newer file is kept.
	for _, name := range geodata {
		dst := filepath.Join(home, name)
		if _, err := os.Lstat(dst); !errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err := copyFile(filepath.Join(geodataDir, name), dst); err != nil {
			return hint(err)
		}
	}
	return nil
}

// Through a temporary name, so a start interrupted halfway leaves no
// truncated file that the next start would keep.
func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".tmp"
	out, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, dst)
}

// Runs `mihomo -t` on the resolved config and returns mihomo's version line.
// mihomo quotes what it rejects, such as a provider's URL, so its output is
// printed with every resolved value replaced.
func testConfig(home, cfg string, values []string) (string, error) {
	out, err := exec.Command(img.Bin, "-t", "-d", home, "-f", cfg).CombinedOutput()
	if err != nil {
		fmt.Fprint(os.Stderr, envconf.Redact(string(out), values))
		return "", fmt.Errorf("mihomo -t refused the configuration (%v)", err)
	}
	out, err = exec.Command(img.Bin, "-v").Output()
	if err != nil {
		return "", fmt.Errorf("mihomo -v: %v", err)
	}
	version, _, _ := strings.Cut(string(out), "\n")
	return version, nil
}
