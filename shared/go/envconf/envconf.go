// Package envconf is the environment-configuration contract in
// images/README.md for images whose runtime has no shell, where
// shared/rootfs/lib/envconf.sh cannot run: curated settings, the warning for
// an unknown name, secrets as files referenced from a JSON config, the startup
// summary, and a healthcheck that probes egress through the server.
package envconf

import (
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// ExConfig is EX_CONFIG, the code every image in this repository refuses a
// configuration with.
const ExConfig = 78

// A Setting is a curated name and the default that applies when it is unset
// or empty. The Dockerfile sets the same defaults as ENV, so that
// `docker inspect` shows them.
type Setting struct{ Name, Default string }

// An Image is what one entrypoint declares about itself.
type Image struct {
	Name     string // the package name, "xray"
	Title    string // the server's name in a sentence, "Xray"
	Bin      string // the server's absolute path
	Prefix   string // of every curated name, "XRAY_"
	Readme   string // where the curated names are documented
	Settings []Setting
	// Names under Prefix the server reads itself. They reach it untouched
	// and are not warned about.
	Upstream map[string]bool
}

// Get returns a curated setting, or its default when it is unset or empty.
func (im *Image) Get(name string) string {
	for _, s := range im.Settings {
		if s.Name == name {
			if v := os.Getenv(name); v != "" {
				return v
			}
			return s.Default
		}
	}
	panic("not a curated name: " + name)
}

func (im *Image) curated(name string) bool {
	for _, s := range im.Settings {
		if s.Name == name {
			return true
		}
	}
	return false
}

// Exec replaces this process with the server, given those arguments.
func (im *Image) Exec(args ...string) {
	err := syscall.Exec(im.Bin, append([]string{im.Bin}, args...), os.Environ())
	fmt.Fprintf(os.Stderr, "FATAL: exec %s: %v\n", im.Bin, err)
	os.Exit(1)
}

// WarnUnknown reports, on stderr, each name under Prefix that neither the
// image nor the server reads, and an expression the healthcheck would never
// check.
func (im *Image) WarnUnknown() {
	for _, kv := range os.Environ() {
		name, _, _ := strings.Cut(kv, "=")
		switch {
		case !strings.HasPrefix(name, im.Prefix), im.Upstream[name], im.curated(name):
		case strings.HasPrefix(name, im.Prefix+"CONF__"):
			fmt.Fprintf(os.Stderr, "WARN: %s is set, but this image has no %sCONF__ passthrough channel. %s is configured by the JSON in %sSOURCE_DIR -- see %s.\n", name, im.Prefix, im.Title, im.Prefix, im.Readme)
		default:
			fmt.Fprintf(os.Stderr, "WARN: %s is set but neither this image nor %s reads it. Check the spelling against %s.\n", name, im.Title, im.Readme)
		}
	}
	if im.Get(im.Prefix+"HEALTHCHECK_EXPECT") != "" && im.Get(im.Prefix+"HEALTHCHECK_PROXY") == "" {
		fmt.Fprintf(os.Stderr, "WARN: %[1]sHEALTHCHECK_EXPECT is set, but %[1]sHEALTHCHECK_PROXY is unset, so the healthcheck fetches nothing and the expression is not checked.\n", im.Prefix)
	}
}

// Summary prints the curated settings, the server's version and each
// resolved reference as the path it was read from, never the value.
func (im *Image) Summary(w io.Writer, version string, configs []*Config) {
	fmt.Fprintf(w, "[envconf] %s: effective configuration\n", im.Name)
	for _, s := range im.Settings {
		v := im.Get(s.Name)
		switch {
		case s.Name == im.Prefix+"HEALTHCHECK_PROXY" && v == "":
			v = "(unset: the healthcheck checks only that " + im.Title + " is running)"
		case s.Name == im.Prefix+"HEALTHCHECK_EXPECT" && v == "":
			v = "(unset: any 2xx passes)"
		case strings.HasSuffix(s.Name, "_URL"), strings.HasSuffix(s.Name, "_PROXY"):
			if u, err := url.Parse(v); err == nil {
				v = u.Redacted()
			}
		}
		fmt.Fprintf(w, "[envconf]   source=%-14s %s = %s\n", "env-or-default", s.Name, v)
	}
	fmt.Fprintf(w, "[envconf]   source=%-14s %s = %s\n", "image", im.Name, version)
	for _, c := range configs {
		fmt.Fprintf(w, "[envconf]   source=%-14s %s\n", "config", c.Src)
		for _, r := range c.Refs {
			from := r.File
			if r.Kind != File.Key {
				from = r.Kind + " " + r.File
			}
			if r.Note != "" {
				from += " " + r.Note
			}
			fmt.Fprintf(w, "[envconf]   source=%-14s %s <- %s   (%s)\n", "file", r.Path, from, c.Src)
		}
	}
	fmt.Fprintln(w, "[envconf] precedence: image default < environment")
}

// Overlap reports whether either directory is, or lies inside, the other.
// Compared as real paths: a symlink alias of one would otherwise pass as a
// separate directory.
func Overlap(a, b string) bool {
	a, b = canonical(a), canonical(b)
	return within(a, b) || within(b, a)
}

// The absolute path with every symlink resolved. A part that does not exist
// yet keeps its name under its parent's resolved path, so a directory still
// to be created is judged by where it would be created.
func canonical(p string) string {
	if abs, err := filepath.Abs(p); err == nil {
		p = abs
	}
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	parent := filepath.Dir(p)
	if parent == p {
		return p
	}
	return filepath.Join(canonical(parent), filepath.Base(p))
}

// Whether path is parent or lies under it.
func within(parent, path string) bool {
	rel, err := filepath.Rel(parent, path)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}
