#!/usr/bin/env bash
# Smoke test for a distroless runtime. See RFC 0002 §5.5.
#
# No shell in the image, so everything goes through the python entrypoint.
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"

# libmagic is the one claim this image's README makes that a build cannot
# verify: the .so is copied in from another image's layer (the Debian `deps`
# stage), so it either resolves at runtime or it does not.
"${ENGINE}" run --rm "${IMAGE}" -c "import ctypes.util, ctypes; \
lib = ctypes.util.find_library('magic') or 'libmagic.so.1'; \
ctypes.CDLL(lib); print('libmagic:', lib)" ||
	{ echo "FAIL: libmagic did not load"; exit 1; }

# zlib, lzma and bz2 come out of the deps stage, and CPython's compression
# modules load the libraries of the release they were built against: a deps
# stage from the wrong release can import and then fail on the first compress().
# So round-trip real data through each, and print a line naming the module that
# broke rather than leaving the traceback as the only signal.
"${ENGINE}" run --rm -i "${IMAGE}" - <<'EOF' || { echo "FAIL: a compression module did not round-trip"; exit 1; }
payload = b"python-distroless-compression-round-trip" * 64
failed = False
for name in ("zlib", "lzma", "bz2"):
    try:
        module = __import__(name)
        if module.decompress(module.compress(payload)) != payload:
            raise AssertionError("the round-trip changed the payload")
    except Exception as error:
        print("FAIL: %s: %s" % (name, error))
        failed = True
    else:
        print("%s: round-trip ok" % name)
raise SystemExit(1 if failed else 0)
EOF

# sqlite3 is a stdlib module with a shared-library dependency: `_sqlite3` links
# libsqlite3.so.0, which is copied out of the deps stage like the compression
# libraries. Import it, read the library's own version through SQL, and round
# trip a row through an in-memory database, so a library that resolves but is
# unusable fails here rather than inside a consumer's pandas query.
"${ENGINE}" run --rm -i "${IMAGE}" - <<'EOF' || { echo "FAIL: sqlite3 did not round-trip"; exit 1; }
import sqlite3
try:
    print("sqlite3:", sqlite3.sqlite_version)
    db = sqlite3.connect(":memory:")
    try:
        version = db.execute("select sqlite_version()").fetchone()[0]
        assert version == sqlite3.sqlite_version, \
            "the library reports %s, the module %s" % (version, sqlite3.sqlite_version)
        db.execute("create table smoke (value text)")
        db.execute("insert into smoke values (?)", ("python-distroless",))
        row = db.execute("select value from smoke").fetchone()
        assert row == ("python-distroless",), "read back %r" % (row,)
    finally:
        db.close()
except Exception as error:
    print("FAIL: sqlite3: %s" % (error,))
    raise SystemExit(1)
print("sqlite3: in-memory round-trip ok")
EOF

# Non-root by construction, and the README says 65532.
uid=$("${ENGINE}" run --rm "${IMAGE}" -c "import os; print(os.getuid())")
[ "${uid}" = "65532" ] || { echo "FAIL: running as uid ${uid}, expected 65532"; exit 1; }
echo "uid: ${uid}"

# TMPDIR must be writable or every consumer that writes a temp file breaks.
#
# Both halves are load-bearing. `gettempdir()` is asserted because tempfile
# silently falls back to /tmp when TMPDIR is unset or unusable -- which in a
# distroless image is a directory that may not exist -- so a bare
# NamedTemporaryFile() can succeed while the configured directory is broken.
# `dir=` then writes to the configured path specifically rather than to
# whatever the fallback chain settled on.
"${ENGINE}" run --rm "${IMAGE}" -c "import tempfile, os; \
t = os.environ['TMPDIR']; g = tempfile.gettempdir(); \
assert g == t, 'gettempdir() is %s, but TMPDIR is %s' % (g, t); \
f = tempfile.NamedTemporaryFile(dir=t); f.write(b'x'); f.flush(); \
print('tmpdir writable:', t)" ||
	{ echo "FAIL: TMPDIR unset, not honoured, or not writable"; exit 1; }

# envfile-exec, the <NAME>_FILE launcher. The cases run inside one container,
# against the installed script, so its shebang and isolated mode are what is
# tested. The child dumps its environment as JSON.
"${ENGINE}" run --rm -i "${IMAGE}" - <<'EOF' || { echo "FAIL: envfile-exec"; exit 1; }
import json, os, statistics, subprocess, sys, tempfile, time

L = "/usr/local/bin/envfile-exec"
PY = sys.executable
D = tempfile.mkdtemp()
DUMP = [PY, "-I", "-c", "import json, os; print(json.dumps(dict(os.environ)))"]
failed = []

def put(name, data):
    path = os.path.join(D, name)
    with open(path, "wb") as f:
        f.write(data)
    return path

def run(env, cmd=DUMP):
    # Bounded: a launcher that blocks opening a FIFO must fail, not hang CI.
    return subprocess.run([L, *cmd], env={"PATH": os.environ["PATH"], **env},
                          capture_output=True, text=True, timeout=20)

def case(label, env, *, rc=0, cmd=DUMP, child=None, err=(), noerr=()):
    try:
        try:
            r = run(env, cmd)
        except subprocess.TimeoutExpired:
            raise AssertionError("the launcher hung")
        assert r.returncode == rc, "exit %d, want %d: %s" % (r.returncode, rc, r.stderr.strip())
        if child:
            got = json.loads(r.stdout)
            for k, v in child.items():
                assert got.get(k) == v, "%s=%r, want %r" % (k, got.get(k), v)
        for s in err:
            assert s in r.stderr, "stderr lacks %r: %r" % (s, r.stderr)
        for s in noerr:
            assert s not in r.stderr, "stderr has %r: %r" % (s, r.stderr)
        print("ok   " + label)
    except AssertionError as e:
        failed.append(label)
        print("FAIL " + label + ": " + str(e))

ABSENT = None
s = put("s", b"s3cret\n")
case("declared A_FILE becomes A, and A_FILE is gone",
     {"ENVFILE_NAMES": " X,A\tB ", "A_FILE": s},
     child={"A": "s3cret", "A_FILE": ABSENT}, err=["[envfile] A <- A_FILE=" + s + "\n"])
case("exactly one trailing newline is stripped",
     {"ENVFILE_NAMES": "A", "A_FILE": put("nl2", b"pem\nbody\n\n")}, child={"A": "pem\nbody\n"})
case("an empty file gives an empty value",
     {"ENVFILE_NAMES": "A", "A_FILE": put("empty", b"")}, child={"A": ""})
case("_FILE wins over the plain value, and says so",
     {"ENVFILE_NAMES": "A", "A": "plain", "A_FILE": s},
     child={"A": "s3cret"}, err=["(plain A ignored)"])
case("a plain value alone is untouched and silent",
     {"ENVFILE_NAMES": "A", "A": "plain"}, child={"A": "plain"}, noerr=["[envfile]"])
case("an undeclared *_FILE stays a path",
     {"ENVFILE_NAMES": "A", "SSL_CERT_FILE": "/etc/ssl/x.pem"},
     child={"SSL_CERT_FILE": "/etc/ssl/x.pem", "SSL_CERT": ABSENT})
case("no ENVFILE_NAMES resolves nothing",
     {"A_FILE": s}, child={"A_FILE": s, "A": ABSENT}, noerr=["[envfile]"])

# Kubernetes: token -> ..data/token, ..data -> ..2026_10_14/
os.makedirs(os.path.join(D, "k8s", "..2026_10_14"))
put("k8s/..2026_10_14/token", b"from-k8s\n")
os.symlink("..2026_10_14", os.path.join(D, "k8s", "..data"))
os.symlink("..data/token", os.path.join(D, "k8s", "token"))
case("a Kubernetes-style symlink is followed",
     {"ENVFILE_NAMES": "A", "A_FILE": os.path.join(D, "k8s", "token")}, child={"A": "from-k8s"})

fifo = os.path.join(D, "fifo")
os.mkfifo(fifo)
for label, path in [
    ("that is missing", os.path.join(D, "nope")),
    ("that is a directory", D),
    ("that is a device", "/dev/null"),
    ("that is a FIFO", fifo),
    ("over 64 KiB", put("big", b"TOPSECRET" * 7300)),
    ("that is not UTF-8", put("latin1", b"TOPSECRET\xff")),
    ("holding a NUL", put("nul", b"TOPSECRET\0x")),
]:
    case("a _FILE %s aborts with 78, naming it and not its content" % label,
         {"ENVFILE_NAMES": "A", "A": "plain", "A_FILE": path},
         rc=78, err=["A_FILE=" + path], noerr=["TOPSECRET", "plain"])

case("an invalid declared name aborts with 78", {"ENVFILE_NAMES": "A-B"}, rc=78, err=["'A-B'"])
case("a non-ASCII declared name aborts with 78", {"ENVFILE_NAMES": "PASSWÖRD"}, rc=78)
case("a name may not start with a digit", {"ENVFILE_NAMES": "1A"}, rc=78)
case("no command exits 64", {}, rc=64, cmd=[])
case("a missing command exits 127", {}, rc=127, cmd=["no-such-command"])
case("the command's exit code is the launcher's", {}, rc=3, cmd=[PY, "-c", "raise SystemExit(3)"])

# -IS: an application's PYTHONPATH must not run code in the launcher. Its own
# imports are frozen, so the way in is site importing sitecustomize.
put("sitecustomize.py", b"raise SystemExit('sitecustomize ran in the launcher')")
case("isolated from PYTHONPATH",
     {"ENVFILE_NAMES": "A", "A_FILE": s, "PYTHONPATH": D}, child={"A": "s3cret"})

def median_ms(cmd):
    times = []
    for _ in range(15):
        t = time.perf_counter()
        subprocess.run(cmd, check=True)
        times.append(time.perf_counter() - t)
    return statistics.median(times) * 1000

bare = [PY, "-I", "-c", "pass"]
print("startup cost: %.0f ms (median of 15)" % (median_ms([L, *bare]) - median_ms(bare)))
sys.exit(1 if failed else 0)
EOF

# What only a real container shows: the application is PID 1 and gets the
# signal (exec, not spawn), and `inspect` holds the path, never the value.
secret="$(mktemp)"
trap 'rm -f "${secret}"; "${ENGINE}" rm -f envfile-smoke-$$ >/dev/null 2>&1 || true' EXIT
printf 'pid1-secret\n' >"${secret}"
chmod 0644 "${secret}"
"${ENGINE}" run -d --name "envfile-smoke-$$" -v "${secret}:/run/secrets/a:ro" \
	-e ENVFILE_NAMES=A -e A_FILE=/run/secrets/a \
	--entrypoint /usr/local/bin/envfile-exec "${IMAGE}" /usr/local/bin/python3 -c '
import os, signal, sys, time
assert os.getpid() == 1, "the launcher spawned the app as pid %d" % os.getpid()
assert os.environ["A"] == "pid1-secret"
signal.signal(signal.SIGTERM, lambda *_: sys.exit(7))
print("ready", flush=True)
time.sleep(60)' >/dev/null
for _ in $(seq 50); do
	"${ENGINE}" logs "envfile-smoke-$$" 2>&1 | grep -q ready && break
	sleep 0.2
done
"${ENGINE}" logs "envfile-smoke-$$" 2>&1 | grep -q ready ||
	{ echo "FAIL: app under envfile-exec never got ready"; "${ENGINE}" logs "envfile-smoke-$$"; exit 1; }
env_json="$("${ENGINE}" inspect --format '{{json .Config.Env}}' "envfile-smoke-$$")"
case "${env_json}" in
*pid1-secret*) echo "FAIL: inspect shows the secret's value"; exit 1 ;;
*A_FILE=/run/secrets/a*) ;;
*) echo "FAIL: inspect lacks A_FILE: ${env_json}"; exit 1 ;;
esac
"${ENGINE}" kill --signal TERM "envfile-smoke-$$" >/dev/null
rc="$("${ENGINE}" wait "envfile-smoke-$$")"
[ "${rc}" = "7" ] || { echo "FAIL: SIGTERM did not reach the app as PID 1 (exit ${rc}, want 7)"; exit 1; }
echo "envfile-exec: app is PID 1, takes SIGTERM, inspect shows only the path"

echo "PASS: python-distroless"
