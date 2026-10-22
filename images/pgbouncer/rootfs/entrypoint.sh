#!/bin/sh
# Generate pgbouncer.ini and userlist.txt from the environment, refuse what
# cannot be represented, print what won, and exec PgBouncer. See RFC 0001 and
# images/pgbouncer/README.md.
#
# edoburu/pgbouncer's own entrypoint is deliberately not run. It writes
# pgbouncer.ini only when the file is absent, so a changed environment never
# reaches a restarted container, and it puts the password in the `[databases]`
# connection string. This one rewrites both files on every start, and the
# password lives in userlist.txt alone.
set -eu

# shellcheck source=/dev/null
. /usr/local/lib/envconf.sh

PREFIX=PGBOUNCER
CONF_DIR=/etc/pgbouncer
CONF_FILE="${CONF_DIR}/pgbouncer.ini"
AUTH_FILE="${CONF_DIR}/userlist.txt"
ALLOWLIST="${PGBOUNCER_CONF_ALLOWLIST:-${CONF_DIR}/allowlist.conf}"
DENYLIST="${CONF_DIR}/denylist.conf"

WORK=$(mktemp -d)
CONF_TMP="${WORK}/pgbouncer.ini"
PASSTHROUGH="${WORK}/passthrough"
SRCMAP="${WORK}/srcmap"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT
: >"${CONF_TMP}"
: >"${SRCMAP}"

# Everything pgbouncer.ini carries goes through `emit`, so the file and the
# summary cannot disagree: one call does both. `note` reports without writing,
# for the settings whose value the file carries in a different shape (the four
# parts of the `[databases]` connection string are one line, not four). The
# origin doubles as the label a refusal names, since it is already the answer
# to "where did this come from" -- a curated variable, or the image's default.
#
#   emit <key> <value> <source> <origin>     the file and the summary
#   note <key> <value> <source> <origin>     the summary only
emit() {
	envconf_refuse_ini_value "${4:-image default}" "$2"
	printf '%s = %s\n' "$1" "$2" >>"${CONF_TMP}"
	note "$@"
}

note() {
	printf '%s\0%s\0%s\0%s\0' "$1" "$2" "$3" "${4:-}" >>"${SRCMAP}"
}

# _curated <writer> <key> <value> <variable> [default-origin]
#
# The source is `env` and the origin the variable's own name when the operator
# set it, and `baked` otherwise. Spelled out per setting this was nine pairs of
# the same two tests, which is where an image starts attributing a value to the
# wrong layer.
_curated() {
	_writer="$1"
	shift
	eval "_set=\${$3:-}"
	if [ -n "${_set}" ]; then
		"${_writer}" "$1" "$2" env "$3"
	else
		"${_writer}" "$1" "$2" baked "${4:-image default}"
	fi
}
emit_curated() { _curated emit "$@"; }
note_curated() { _curated note "$@"; }

# Curated variables the operator actually set, for RFC 0001 decision 11's
# collision check. Defaults are deliberately not in here: every curated knob
# has a default, so counting defaults would make the passthrough channel
# permanently unusable.
CURATED=""
curated_if_set() {
	# curated_if_set <var-name> <upstream-key>
	eval "_v=\${$1:-}"
	if [ -n "${_v}" ]; then
		CURATED="${CURATED} $2"
	fi
}

# The one field of the auth file this image writes, and the reason it is
# checked here rather than left to PgBouncer: `load_auth_file` reads a quoted
# field up to the first quote that is not doubled, so a password carrying a
# single `"` is stored truncated to whatever came before it. The client then
# fails to authenticate with the password it was given, against a file the
# image wrote, with nothing in the log to say why. Refused while the reason is
# still legible.
#
#   refuse_unwritable_credential <label> <value>
refuse_unwritable_credential() {
	envconf_refuse_newline "$1" "$2"
	case "$2" in
	*'"'*)
		envconf_die "$1 contains a double quote. PgBouncer's auth file escapes a quote by doubling it, and this image writes the value as it stands, so the quote would end the field early and the stored password would not be the one given. Choose a credential without one."
		;;
	esac
}

# ---------------------------------------------------------------------------
# 1. the backend and the credential (RFC 0001 decision 4)
# ---------------------------------------------------------------------------
# DB_HOST and DB_USER have no sensible default: a pooler pointing at nothing
# answers every client with a connection error, and one that guessed the user
# would log into Postgres as somebody the operator did not choose.
db_host="${PGBOUNCER_DB_HOST:-}"
db_user="${PGBOUNCER_DB_USER:-}"
db_port="${PGBOUNCER_DB_PORT:-5432}"
# `*` is PgBouncer's fallback database key: a client asking for `app` is routed
# by it, with `dbname` defaulting to the name the client asked for. It is what
# edoburu's generated config defaults to as well, so a consumer that set
# nothing but DB_HOST/DB_USER/DB_PASSWORD keeps exactly the routing it had.
db_name="${PGBOUNCER_DB_NAME:-*}"

[ -n "${db_host}" ] || envconf_die "PGBOUNCER_DB_HOST is required: it names the Postgres server PgBouncer connects to."
[ -n "${db_user}" ] || envconf_die "PGBOUNCER_DB_USER is required: it names the user PgBouncer accepts from clients and logs into Postgres with."

# <NAME>_FILE wins over <NAME>, and an unreadable one aborts rather than
# falling back (RFC 0001 decision 4). Named PGBOUNCER_DB_PASSWORD so that
# PGBOUNCER_DB_PASSWORD_FILE is the file spelling the contract derives.
db_password=$(envconf_secret PGBOUNCER_DB_PASSWORD)
[ -n "${db_password}" ] || envconf_die "PGBOUNCER_DB_PASSWORD is required, through PGBOUNCER_DB_PASSWORD or PGBOUNCER_DB_PASSWORD_FILE. A pooler with no password authenticates nobody."

refuse_unwritable_credential PGBOUNCER_DB_USER "${db_user}"
refuse_unwritable_credential PGBOUNCER_DB_PASSWORD "${db_password}"

# ---------------------------------------------------------------------------
# 2. how clients authenticate
# ---------------------------------------------------------------------------
# D-9 refuses these two methods rather than leaving them to the operator:
# `trust` admits every user named in auth_file without a password and `any`
# admits every user at all, including as administrator of the console.
auth_type="${PGBOUNCER_AUTH_TYPE:-scram-sha-256}"
case "${auth_type}" in
trust | any)
	envconf_die "PGBOUNCER_AUTH_TYPE=${auth_type} authenticates nobody: every client that names a known user is let through, which is the opposite of what a pooler in front of a database is for. Use scram-sha-256 (the default), md5, plain or cert."
	;;
esac

# ---------------------------------------------------------------------------
# 3. everything else curated, defaulting to what every consumer sets today
# ---------------------------------------------------------------------------
listen_addr="${PGBOUNCER_LISTEN_ADDR:-0.0.0.0}"
listen_port="${PGBOUNCER_LISTEN_PORT:-6432}"
pool_mode="${PGBOUNCER_POOL_MODE:-transaction}"
max_client_conn="${PGBOUNCER_MAX_CLIENT_CONN:-1000}"
default_pool_size="${PGBOUNCER_DEFAULT_POOL_SIZE:-30}"
max_prepared_statements="${PGBOUNCER_MAX_PREPARED_STATEMENTS:-200}"
admin_users="${PGBOUNCER_ADMIN_USERS:-${db_user}}"
stats_users="${PGBOUNCER_STATS_USERS:-${db_user}}"

# ---------------------------------------------------------------------------
# 4. the [databases] section
# ---------------------------------------------------------------------------
# Only the section header here; the file's own header comment is written once,
# in section 8, where the temporary file is installed.
echo "[databases]" >>"${CONF_TMP}"

# The value here is a connection string, so it is a `key = value` line in the
# same ini grammar and the same three characters are refused in its parts -- a
# database name is a *key*, which is where a `[` is one line away from opening
# a section.
envconf_refuse_ini_value PGBOUNCER_DB_NAME "${db_name}"
envconf_refuse_ini_value PGBOUNCER_DB_HOST "${db_host}"
envconf_refuse_ini_value PGBOUNCER_DB_PORT "${db_port}"
envconf_refuse_ini_value PGBOUNCER_DB_USER "${db_user}"
printf '%s = host=%s port=%s user=%s\n' \
	"${db_name}" "${db_host}" "${db_port}" "${db_user}" >>"${CONF_TMP}"

# No `password=`: PgBouncer takes the password of the user named above from
# auth_file, which is what keeps the credential out of pgbouncer.ini. The four
# parts get one summary row each rather than one row for the line, because the
# question an operator asks here is which variable supplied which part -- and
# because the line they compose already appears above, in the form PgBouncer
# reads. Reported, not emitted: this section is `[databases]`, where a
# `db_host = ...` line would be a database named db_host.
note_curated db_name "${db_name}" PGBOUNCER_DB_NAME
note_curated db_host "${db_host}" PGBOUNCER_DB_HOST
note_curated db_port "${db_port}" PGBOUNCER_DB_PORT
note_curated db_user "${db_user}" PGBOUNCER_DB_USER

# The value is handed over as it is: the summary's own name rule (*PASSWORD*)
# is what keeps it out of the log, and passing a placeholder here would make
# that redaction a claim nothing tests.
if [ -n "${PGBOUNCER_DB_PASSWORD_FILE:-}" ]; then
	note db_password "${db_password}" env "PGBOUNCER_DB_PASSWORD_FILE=${PGBOUNCER_DB_PASSWORD_FILE}"
else
	# Named so an operator reading the log can see they took the path that
	# exposes the value to `docker inspect`.
	note db_password "${db_password}" env "PGBOUNCER_DB_PASSWORD (visible in docker inspect)"
fi

# ---------------------------------------------------------------------------
# 5. the [pgbouncer] section
# ---------------------------------------------------------------------------
printf '\n[pgbouncer]\n' >>"${CONF_TMP}"

emit_curated listen_addr "${listen_addr}" PGBOUNCER_LISTEN_ADDR
emit_curated listen_port "${listen_port}" PGBOUNCER_LISTEN_PORT
# Empty rather than /tmp: the container is reached over TCP, and the image's
# own config directory is not a place to leave a socket that clients on the
# host cannot see. Denylisted, so no passthrough can move it.
emit unix_socket_dir "" baked "image default"
emit auth_file "${AUTH_FILE}" baked "image default"
emit_curated auth_type "${auth_type}" PGBOUNCER_AUTH_TYPE
emit_curated pool_mode "${pool_mode}" PGBOUNCER_POOL_MODE
emit_curated max_client_conn "${max_client_conn}" PGBOUNCER_MAX_CLIENT_CONN
emit_curated default_pool_size "${default_pool_size}" PGBOUNCER_DEFAULT_POOL_SIZE
emit_curated max_prepared_statements "${max_prepared_statements}" PGBOUNCER_MAX_PREPARED_STATEMENTS
# Both default to DB_USER, which is the whole consumer configuration today: the
# same credentials open the pooler and read its console.
emit_curated admin_users "${admin_users}" PGBOUNCER_ADMIN_USERS PGBOUNCER_DB_USER
emit_curated stats_users "${stats_users}" PGBOUNCER_STATS_USERS PGBOUNCER_DB_USER

# Baked, with no curated variable: the shape of the pool rather than a knob
# every consumer sets. An operator who wants them reaches them through
# PGBOUNCER_CONF__min_pool_size and ..._reserve_pool_size, which are on the
# allowlist.
emit min_pool_size 5 baked "image default"
emit reserve_pool_size 10 baked "image default"

# `extra_float_digits` is a startup parameter psql and several drivers send,
# and PgBouncer refuses a startup parameter it does not track. edoburu's
# generated config ignores it, so the consumers this image is for have never
# seen that refusal.
emit ignore_startup_parameters "extra_float_digits" baked "image default"

# ---------------------------------------------------------------------------
# 6. the passthrough channel
# ---------------------------------------------------------------------------
curated_if_set PGBOUNCER_LISTEN_PORT listen_port
curated_if_set PGBOUNCER_AUTH_TYPE auth_type
curated_if_set PGBOUNCER_POOL_MODE pool_mode
curated_if_set PGBOUNCER_MAX_CLIENT_CONN max_client_conn
curated_if_set PGBOUNCER_DEFAULT_POOL_SIZE default_pool_size
curated_if_set PGBOUNCER_MAX_PREPARED_STATEMENTS max_prepared_statements
curated_if_set PGBOUNCER_ADMIN_USERS admin_users
curated_if_set PGBOUNCER_STATS_USERS stats_users

# RFC 0001 decision 9: a typo'd curated name warns rather than doing nothing.
# Every PGBOUNCER_* this image reads is listed here; a curated variable missing
# from this list makes the image warn about its own knob.
envconf_warn_unknown "${PREFIX}" "\
PGBOUNCER_DB_HOST PGBOUNCER_DB_USER PGBOUNCER_DB_PASSWORD \
PGBOUNCER_DB_PORT PGBOUNCER_DB_NAME \
PGBOUNCER_LISTEN_ADDR PGBOUNCER_LISTEN_PORT PGBOUNCER_AUTH_TYPE \
PGBOUNCER_POOL_MODE PGBOUNCER_MAX_CLIENT_CONN PGBOUNCER_DEFAULT_POOL_SIZE \
PGBOUNCER_MAX_PREPARED_STATEMENTS PGBOUNCER_ADMIN_USERS PGBOUNCER_STATS_USERS"

envconf_load_allowlist "${ALLOWLIST}"
envconf_load_denylist "${DENYLIST}"
envconf_collect "${PREFIX}" "${CURATED}" >"${PASSTHROUGH}"

if [ -s "${PASSTHROUGH}" ]; then
	printf '\n;; --- from the environment ---\n' >>"${CONF_TMP}"
	envconf_render pgbouncerconf "${PASSTHROUGH}" >>"${CONF_TMP}"
	# Re-read as pairs to extend them into summary quads. envconf_collect
	# refuses a newline-bearing value and the renderer refuses the rest, so
	# what is left reads a line at a time.
	tr '\0' '\n' <"${PASSTHROUGH}" | while IFS= read -r k && IFS= read -r v; do
		printf '%s\0%s\0%s\0%s\0' "${k}" "${v}" env "${PREFIX}_CONF__${k}" >>"${SRCMAP}"
	done
fi

# ---------------------------------------------------------------------------
# 7. re-check the refusal against the assembled file
# ---------------------------------------------------------------------------
# The check above reads the environment; this one reads what was written, and
# it is the one that holds. `auth_type` is on the allowlist, so
# PGBOUNCER_CONF__auth_type=trust is an allowlisted spelling of the same
# setting, and PgBouncer takes the last occurrence of a repeated key -- so the
# refused methods are refused whichever channel supplies them.
#
# Mirrors PgBouncer's own parser: a line whose first character is `;` or `#` is
# a comment, a section header has no `=`, and everything after the first `=` is
# the value, trimmed.
effective() {
	awk -v key="$1" '
		{
			line = $0
			sub(/^[ \t]+/, "", line)
			if (line == "" || substr(line, 1, 1) == ";" || substr(line, 1, 1) == "#") next
			eq = index(line, "=")
			if (eq == 0) next
			k = substr(line, 1, eq - 1)
			v = substr(line, eq + 1)
			gsub(/^[ \t]+|[ \t]+$/, "", k)
			gsub(/^[ \t]+|[ \t]+$/, "", v)
			if (k == key) last = v
		}
		END { print last }
	' "${CONF_TMP}"
}

eff_auth_type=$(effective auth_type)
case "${eff_auth_type}" in
trust | any)
	envconf_die "the assembled pgbouncer.ini authenticates with auth_type=${eff_auth_type}: PGBOUNCER_CONF__auth_type sets what PGBOUNCER_AUTH_TYPE refuses. Use scram-sha-256 (the default), md5, plain or cert."
	;;
esac

# ---------------------------------------------------------------------------
# 8. install, report, hand off
# ---------------------------------------------------------------------------
# 0600, and the password is in this file and nowhere else. Rewritten from
# scratch rather than appended to, so a restart cannot leave a second entry
# behind -- which is what edoburu's script does, and why a rotated password
# there only takes effect for a user it has not seen before.
umask 077
printf '"%s" "%s"\n' "${db_user}" "${db_password}" >"${AUTH_FILE}"
chmod 0600 "${AUTH_FILE}"

{
	echo ";; Generated by the morze pgbouncer entrypoint. Do not edit; it is"
	echo ";; rewritten on every start. See images/pgbouncer/README.md."
	echo
	cat "${CONF_TMP}"
} >"${CONF_FILE}"
chmod 0644 "${CONF_FILE}"

envconf_summary "${PREFIX}" "${SRCMAP}" "effective configuration" \
	"precedence: image default < environment"

# The trap does not fire across `exec`, and one of the files under WORK is the
# source map, which carries every value in the clear -- the password among
# them. Removing it here rather than relying on the trap is what makes "the
# credential is in userlist.txt alone" true of the running container and not
# only of the files this image installs. The postgres and caddy entrypoints
# do the same thing, in the same place, for the same reason.
cleanup
trap - EXIT

exec pgbouncer "${CONF_FILE}"