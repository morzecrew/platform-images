package envconf

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"syscall"
	"unicode/utf8"
)

// MaxSecret is the most a referenced file may hold, as for a <NAME>_FILE.
const MaxSecret = 64 << 10

// A Reference is one form of file reference: a JSON object whose one key is
// Key, naming an absolute path, replaced by what Resolve makes of that file.
type Reference struct {
	Key     string
	Resolve func(file string) (Resolution, error)
}

// What a reference resolves to.
type Resolution struct {
	Value   any      // replaces the reference
	Secrets []string // redacted from the server's output
	Note    string   // follows the path in the summary, such as a count
}

// File is {"$file": "<absolute path>"}: the file's content, as a string.
var File = Reference{"$file", Secret(ReadSecret)}

// Secret makes a resolver for a reference that yields one string, which is
// itself the secret.
func Secret(read func(string) (string, error)) func(string) (Resolution, error) {
	return func(file string) (Resolution, error) {
		s, err := read(file)
		return Resolution{Value: s, Secrets: []string{s}}, err
	}
}

// A Ref is one resolved reference, as the summary names it.
type Ref struct{ Path, Kind, File, Note string }

// One source file and what became of it.
type Config struct {
	Src    string   // the source file
	Doc    any      // the resolved document
	Out    []byte   // Doc as JSON
	Refs   []Ref    // in document order
	Values []string // the resolved contents, so the server's messages can be redacted
}

// ResolveFile reads the JSON file at p and replaces each object that is
// exactly one of refs with what it resolves to, and nothing else. A near miss,
// such as a reference key beside another key, is an error.
func ResolveFile(p string, refs []Reference) (*Config, error) {
	raw, err := os.ReadFile(p)
	if err != nil {
		return nil, fmt.Errorf("%s: %v", p, Cause(err))
	}
	// UseNumber keeps every number as written; float64 would round a large one.
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var doc any
	if err := dec.Decode(&doc); err != nil {
		return nil, fmt.Errorf("%s is not valid JSON: %v", p, err)
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, fmt.Errorf("%s is not valid JSON: something follows its value", p)
	}
	c := &Config{Src: p}
	if c.Doc, err = c.resolve(doc, "", refs); err != nil {
		return nil, err
	}
	var out bytes.Buffer
	enc := json.NewEncoder(&out)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(c.Doc); err != nil {
		return nil, fmt.Errorf("%s: %v", p, err)
	}
	c.Out = out.Bytes()
	return c, nil
}

func (c *Config) resolve(v any, path string, refs []Reference) (any, error) {
	switch t := v.(type) {
	case map[string]any:
		for _, r := range refs {
			if target, ok := t[r.Key]; ok {
				return c.reference(t, r, target, path)
			}
		}
		keys := make([]string, 0, len(t))
		for k := range t {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			child := k
			if path != "" {
				child = path + "." + k
			}
			r, err := c.resolve(t[k], child, refs)
			if err != nil {
				return nil, err
			}
			t[k] = r
		}
	case []any:
		for i := range t {
			r, err := c.resolve(t[i], fmt.Sprintf("%s[%d]", path, i), refs)
			if err != nil {
				return nil, err
			}
			t[i] = r
		}
	}
	return v, nil
}

// A near miss is an error rather than a literal, or a typo would reach the
// server as an object it rejects with a message about some other field, or
// accepts.
func (c *Config) reference(obj map[string]any, r Reference, target any, path string) (any, error) {
	if len(obj) != 1 {
		var others []string
		for k := range obj {
			if k != r.Key {
				others = append(others, k)
			}
		}
		sort.Strings(others)
		return nil, c.errorf(path, `an object holding %q holds nothing else, and this one also holds %s`, r.Key, strings.Join(others, ", "))
	}
	file, ok := target.(string)
	if !ok || !filepath.IsAbs(file) {
		return nil, c.errorf(path, `%q must be an absolute path, as a string`, r.Key)
	}
	res, err := r.Resolve(file)
	if err != nil {
		return nil, c.errorf(path, "%s %v", file, err)
	}
	c.Refs = append(c.Refs, Ref{path, r.Key, file, res.Note})
	c.Values = append(c.Values, res.Secrets...)
	return res.Value, nil
}

// Names the file, the JSON path and the referenced path; never a value.
func (c *Config) errorf(path, format string, args ...any) error {
	if path == "" {
		path = "the top level"
	}
	return fmt.Errorf("%s: %s: %s", c.Src, path, fmt.Sprintf(format, args...))
}

// ReadSecret makes the checks the shared helper and envfile-exec make on a
// <NAME>_FILE, with the same limits. The error completes a sentence that
// starts with the path.
func ReadSecret(name string) (string, error) {
	// O_NONBLOCK so a FIFO opens at once, and the type is checked on what was
	// opened rather than on the path, which could change in between.
	f, err := os.OpenFile(name, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return "", errors.New("does not exist")
	case errors.Is(err, fs.ErrPermission):
		return "", fmt.Errorf("is not readable by uid %d", os.Getuid())
	case err != nil:
		return "", fmt.Errorf("could not be opened: %v", Cause(err))
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return "", fmt.Errorf("could not be read: %v", Cause(err))
	}
	if info.IsDir() {
		return "", errors.New("is a directory, which is what Compose leaves when a secret's source file is missing")
	}
	if !info.Mode().IsRegular() {
		return "", errors.New("is not a regular file")
	}
	b, err := io.ReadAll(io.LimitReader(f, MaxSecret+1))
	switch {
	case err != nil:
		return "", fmt.Errorf("could not be read: %v", Cause(err))
	case len(b) > MaxSecret:
		return "", fmt.Errorf("is larger than %d bytes", MaxSecret)
	case bytes.IndexByte(b, 0) >= 0:
		return "", errors.New("contains a NUL byte")
	case !utf8.Valid(b):
		return "", errors.New("is not valid UTF-8")
	}
	// One trailing newline: every editor adds one and no secret wants it.
	return strings.TrimSuffix(string(b), "\n"), nil
}

// Redact replaces every value in s, longest first, so a value that contains
// another is replaced whole.
func Redact(s string, values []string) string {
	sorted := slices.Clone(values)
	sort.Slice(sorted, func(i, j int) bool { return len(sorted[i]) > len(sorted[j]) })
	for _, v := range sorted {
		if v != "" {
			s = strings.ReplaceAll(s, v, "<redacted>")
		}
	}
	return s
}

// Cause is the error underneath a *PathError and the like, whose own message
// repeats the path the caller has already named.
func Cause(err error) error {
	if u := errors.Unwrap(err); u != nil {
		return u
	}
	return err
}
