#!/usr/bin/env bash
# Install the extensions named in PG_EXTENSIONS and generate their config.
#
# Runs once, at build time. The preload line is generated from the same input
# that drives the install, which is the whole point: shared_preload_libraries
# naming a library that is not installed is a fatal startup error, so an image
# that builds green can otherwise refuse to start. See RFC 0004.
set -euo pipefail

MANIFEST="${MANIFEST:-/usr/local/share/postgres-extensions/extensions.manifest}"
SNIPPET_SRC="${SNIPPET_SRC:-/usr/local/share/postgres-extensions/conf.d}"
CONF_D="${CONF_D:-/etc/postgresql/conf.d}"
PG_MAJOR="${PG_MAJOR:?PG_MAJOR must be set}"
PG_EXTENSIONS="${PG_EXTENSIONS:-}"

die() {
	echo "FATAL: $*" >&2
	exit 1
}

[[ -f "${MANIFEST}" ]] || die "manifest not found: ${MANIFEST}"

# -------------------------
# Parse the manifest
# -------------------------
declare -A M_PACKAGE M_SQLNAME M_PRELOAD M_SNIPPET
manifest_names=()

while IFS= read -r line || [[ -n "${line}" ]]; do
	line="${line%%#*}"
	[[ -z "${line//[[:space:]]/}" ]] && continue

	IFS=':' read -r name package sql_name preload snippet <<<"${line}"
	name="$(echo "${name}" | xargs || true)"
	[[ -z "${name}" ]] && continue

	M_PACKAGE["${name}"]="$(echo "${package}" | xargs || true)"
	M_SQLNAME["${name}"]="$(echo "${sql_name}" | xargs || true)"
	M_PRELOAD["${name}"]="$(echo "${preload}" | xargs || true)"
	M_SNIPPET["${name}"]="$(echo "${snippet}" | xargs || true)"
	manifest_names+=("${name}")
done <"${MANIFEST}"

[[ ${#manifest_names[@]} -gt 0 ]] || die "manifest ${MANIFEST} defines no extensions"

# -------------------------
# Validate the request
# -------------------------
# Canonical order is manifest order, not the order the caller happened to type.
# The label and the preload line both derive from this, so two builds asking for
# the same set produce the same strings.
selected=()
for want in ${PG_EXTENSIONS}; do
	[[ -n "${M_PACKAGE[${want}]+x}" ]] ||
		die "unknown extension '${want}'. Valid names: ${manifest_names[*]}"
done
for name in "${manifest_names[@]}"; do
	for want in ${PG_EXTENSIONS}; do
		[[ "${want}" == "${name}" ]] && selected+=("${name}") && break
	done
done

# The image label is set from PG_EXTENSIONS as given, so the given string has
# to already be the canonical one -- otherwise two builds of the same set carry
# different labels and the label stops describing the build (RFC 0004 dec. 10).
# Rather than canonicalising silently, refuse and name the correct spelling.
canonical="${selected[*]}"
requested="$(echo ${PG_EXTENSIONS} | xargs || true)"
if [[ "${requested}" != "${canonical}" ]]; then
	die "PG_EXTENSIONS must be in manifest order. Got '${requested}', expected '${canonical}'."
fi

echo "Selected extensions: ${selected[*]:-<none>}"

# -------------------------
# Install
# -------------------------
apt-get update

# pgroonga needs its own apt source first. One extension needing a repository is
# a special case; a manifest column for it would be a schema built for one row.
for name in "${selected[@]}"; do
	[[ "${name}" == "pgroonga" ]] || continue
	apt-get install -y --no-install-recommends ca-certificates wget gnupg lsb-release
	codename="$(lsb_release --codename --short)"
	wget -O /tmp/groonga-apt-source.deb \
		"https://packages.groonga.org/debian/groonga-apt-source-latest-${codename}.deb"
	apt-get install -y -V /tmp/groonga-apt-source.deb
	rm -f /tmp/groonga-apt-source.deb
	apt-get update
done

packages=()
for name in "${selected[@]}"; do
	packages+=("${M_PACKAGE[${name}]//%M/${PG_MAJOR}}")
done

if [[ ${#packages[@]} -gt 0 ]]; then
	apt-get install -y -V --no-install-recommends "${packages[@]}"
fi

apt-get clean
rm -rf /var/lib/apt/lists/*

# -------------------------
# Generate config
# -------------------------
mkdir -p "${CONF_D}"

# Manifest-order preloads first, then the unconditional pg_stat_statements.
# The order is not cosmetic: it reproduces the pre-refactor line exactly, and
# extensions initialise in list order.
preloads=()
for name in "${selected[@]}"; do
	[[ -n "${M_PRELOAD[${name}]}" ]] && preloads+=("${M_PRELOAD[${name}]}")
done
preloads+=("pg_stat_statements")

preload_csv="$(
	IFS=,
	echo "${preloads[*]}"
)"

{
	echo "# Auto-generated from PG_EXTENSIONS at build time. Do not edit."
	echo "# Selected: ${selected[*]:-<none>}"
	echo "shared_preload_libraries = '${preload_csv}'"
} >"${CONF_D}/10-extensions.conf"

# pg_stat_statements ships with the server and is always preloaded, so its
# settings are unconditional too. They live here rather than in postgresql.conf
# because that file is included *before* conf.d and would override this.
cp "${SNIPPET_SRC}/pg_stat_statements.conf" "${CONF_D}/11-pg_stat_statements.conf"

for name in "${selected[@]}"; do
	snippet="${M_SNIPPET[${name}]}"
	[[ -z "${snippet}" ]] && continue
	[[ -f "${SNIPPET_SRC}/${snippet}" ]] || die "snippet missing for ${name}: ${snippet}"
	cp "${SNIPPET_SRC}/${snippet}" "${CONF_D}/12-${snippet}"
done

chown -R postgres:postgres "${CONF_D}"
chmod 0644 "${CONF_D}"/*.conf

# Record what this build put in conf.d, so the startup summary can tell an
# image-shipped fragment from an operator-mounted one. The build is the only
# place that knows: at runtime both are just files in the include directory,
# and RFC 0001 decision 13 requires this image to attribute each of them.
#
# A filename convention would be cheaper and wrong the moment an operator
# mounts a file whose name looks baked.
(
	cd "${CONF_D}"
	for f in *.conf; do
		[[ -f "${f}" ]] && echo "${f}"
	done
) >"${CONF_D}/.baked-fragments"
chown postgres:postgres "${CONF_D}/.baked-fragments"
chmod 0644 "${CONF_D}/.baked-fragments"

# -------------------------
# Verify
# -------------------------
# A filesystem check, not a SQL one: the build has no server and never runs
# initdb, so a SQL gate would mean standing up a throwaway cluster inside this
# layer. The control file is what the server itself reads to decide an extension
# is available, so testing for it answers the same question in one `test -f`.
ext_dir="/usr/share/postgresql/${PG_MAJOR}/extension"
pkglibdir="$(pg_config --pkglibdir)"

for name in "${selected[@]}"; do
	control="${ext_dir}/${M_SQLNAME[${name}]}.control"
	[[ -f "${control}" ]] || die "control file missing for ${name}: ${control}"

	preload="${M_PRELOAD[${name}]}"
	[[ -z "${preload}" ]] && continue
	[[ -f "${pkglibdir}/${preload}.so" ]] ||
		die "preload library missing for ${name}: ${pkglibdir}/${preload}.so"
done

# The unconditional one is verified too — if it ever stops shipping with the
# server, the generated preload line would name a library that is not there.
[[ -f "${pkglibdir}/pg_stat_statements.so" ]] ||
	die "preload library missing: ${pkglibdir}/pg_stat_statements.so"

echo "Extensions verified: ${selected[*]:-<none>} (+ pg_stat_statements)"
echo "shared_preload_libraries = '${preload_csv}'"
