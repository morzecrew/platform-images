# shellcheck shell=sh
#
# envconf.sh — the shared env-config contract. See RFC 0001.
#
# Sourced by an image's entrypoint, never executed. POSIX sh: it has to run on
# Alpine without adding bash, which rules out associative arrays and ${var,,}.
# Set membership is therefore a space-padded string and a `case` glob, and
# lowercasing goes through `tr`.
#
# `local` is used throughout. It is not in POSIX, but every shell this can run
# in (busybox ash, dash, bash) implements it, and the alternative -- globals
# everywhere in a file that images source into their own entrypoint -- trades a
# portability nit for a class of collision bugs.
#
#   envconf_load_allowlist <path>
#   envconf_load_denylist  <path>
#   envconf_collect        <prefix> [curated_keys]
#   envconf_warn_unknown   <prefix> <curated_var_names>
#   envconf_render         <fmt> [infile]
#   envconf_summary        <prefix> [infile]
#   envconf_secret         <name>

# Space-padded so `case "$set" in *" $k "*)` is an exact membership test rather
# than a substring one -- without the padding, `max` would match `maxmemory`.
#
# _ENVCONF_ALLOW holds `normalized=canonical` pairs rather than bare keys,
# because normalizing is lossy and rendering needs the upstream spelling back.
# `-`->`_` makes `VALKEY_CONF__maxmemory_policy` and `..._MAXMEMORY-POLICY`
# match one allowlist entry, but valkey.conf wants `maxmemory-policy` -- and
# mapping `_`->`-` on the way out is not a safe inverse, since valkey also has
# `server_cpulist`, `bio_cpulist`, `bgsave_cpulist` and `aof_rewrite_cpulist`.
# So the allowlist file carries the exact upstream spelling and is the
# authority on it; normalization is only ever used for matching.
_ENVCONF_ALLOW=" "
_ENVCONF_DENY=" "
_ENVCONF_SECRET=" "
_ENVCONF_ALLOW_LOADED=""

# A literal newline and carriage return, for the value-safety check. The
# trailing X survives command substitution stripping the newline; then it goes.
_ENVCONF_NL=$(printf '\nX')
_ENVCONF_NL=${_ENVCONF_NL%X}
_ENVCONF_CR=$(printf '\rX')
_ENVCONF_CR=${_ENVCONF_CR%X}

envconf_die() {
	echo "FATAL: $*" >&2
	exit 1
}

envconf_warn() {
	echo "WARN: $*" >&2
}

# PG_CONF__Foo-Bar -> foo_bar. Upstream keys are case-insensitive and spell
# word breaks both ways, so both spellings have to land on one canonical form
# or the allowlist and the collision check disagree with each other.
_envconf_normalize() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '-' '_'
}

_envconf_in_set() {
	# $1 = set, $2 = key
	case "$1" in
	*" $2 "*) return 0 ;;
	esac
	return 1
}

# Canonical (upstream) spelling for a normalized key, or empty if not allowed.
_envconf_allow_canon() {
	local rest
	case "${_ENVCONF_ALLOW}" in
	*" $1="*)
		rest=${_ENVCONF_ALLOW#*" $1="}
		printf '%s' "${rest%% *}"
		;;
	esac
}

# A value that contains a newline cannot be represented by postgresql.conf,
# valkey.conf or a key-value file. Accepting one only defers the corruption to
# the server's parser, at a much worse moment (RFC 0001 decision 12).
_envconf_has_newline() {
	case "$1" in
	*"$_ENVCONF_NL"* | *"$_ENVCONF_CR"*) return 0 ;;
	esac
	return 1
}

# One key per line; '#' starts a comment; an optional trailing `!secret` marks
# the key for redaction in the summary.
envconf_load_allowlist() {
	local path="$1"
	local line key marker canon

	[ -n "${path}" ] || envconf_die "envconf_load_allowlist: no path given"
	# A missing allowlist is a build defect, not a runtime condition: the image
	# shipped without the file that defines what it accepts.
	[ -f "${path}" ] || envconf_die "allowlist not found: ${path}"

	while IFS= read -r line || [ -n "${line}" ]; do
		line=${line%%#*}
		# Trim without echo/xargs: `set --` re-splits on IFS and drops padding.
		# shellcheck disable=SC2086
		set -- ${line}
		key="${1:-}"
		marker="${2:-}"
		[ -n "${key}" ] || continue

		# The file's spelling is kept verbatim as the canonical form; only the
		# lookup side is normalized.
		canon="${key}"
		key=$(_envconf_normalize "${key}")
		[ -n "$(_envconf_allow_canon "${key}")" ] ||
			_ENVCONF_ALLOW="${_ENVCONF_ALLOW}${key}=${canon} "

		if [ "${marker}" = "!secret" ]; then
			_envconf_in_set "${_ENVCONF_SECRET}" "${key}" ||
				_ENVCONF_SECRET="${_ENVCONF_SECRET}${key} "
		fi
	done <"${path}"

	_ENVCONF_ALLOW_LOADED=1
}

# Same format, no markers. Separate file because it is a different claim:
# the allowlist says what an operator may set, the denylist says what nobody
# may set regardless of what the allowlist says.
envconf_load_denylist() {
	local path="$1"
	local line key

	[ -n "${path}" ] || envconf_die "envconf_load_denylist: no path given"
	[ -f "${path}" ] || envconf_die "denylist not found: ${path}"

	while IFS= read -r line || [ -n "${line}" ]; do
		line=${line%%#*}
		# shellcheck disable=SC2086
		set -- ${line}
		key="${1:-}"
		[ -n "${key}" ] || continue
		key=$(_envconf_normalize "${key}")
		_envconf_in_set "${_ENVCONF_DENY}" "${key}" ||
			_ENVCONF_DENY="${_ENVCONF_DENY}${key} "
	done <"${path}"
}

# Scan the environment for <prefix>_CONF__*, normalize, check both lists, and
# emit NUL-delimited key/value pairs on stdout.
#
# The environment is enumerated through awk's ENVIRON rather than `env`, and
# this is load-bearing: `env` output is line-oriented, so a value containing a
# newline is already split into two lines by the time the shell sees it and the
# refusal below could never fire. ENVIRON yields names only; the value comes
# from the shell's own variable, at full fidelity.
#
# $2, if given, is the space-delimited set of upstream keys the image wrote
# from curated variables. A passthrough key that targets one of them aborts,
# naming both (RFC 0001 decision 11) -- the check lives here because this is
# where the passthrough keys already are.
envconf_collect() {
	local prefix="$1"
	local curated="${2:-}"
	local strict_var strict names name raw key canon value

	[ -n "${prefix}" ] || envconf_die "envconf_collect: no prefix given"
	[ -n "${_ENVCONF_ALLOW_LOADED}" ] ||
		envconf_die "envconf_collect: allowlist not loaded"

	strict_var="${prefix}_CONF_STRICT"
	eval "strict=\${${strict_var}:-fail}"
	case "${strict}" in
	fail | ignore) ;;
	*) envconf_die "${strict_var} must be 'fail' or 'ignore', got '${strict}'" ;;
	esac

	# Normalized on both sides, so an image may declare its curated keys in
	# whichever spelling its config format uses.
	curated=" $(printf '%s' "${curated}" | tr '[:upper:]' '[:lower:]' | tr '-' '_') "

	# Sorted, so two runs with the same environment render byte-identically.
	names=$(awk -v pfx="${prefix}_CONF__" \
		'BEGIN { for (k in ENVIRON) if (index(k, pfx) == 1) print k }' | sort)

	for name in ${names}; do
		raw=${name#"${prefix}_CONF__"}
		[ -n "${raw}" ] || continue
		key=$(_envconf_normalize "${raw}")

		# Read the value through awk, never `eval "value=\${${name}}"`.
		# Environment variable names may contain characters the shell's
		# parameter syntax claims: `VALKEY_CONF__notify-keyspace-events`
		# expands as ${VALKEY_CONF__notify-...}, which is "use
		# VALKEY_CONF__notify, or the literal 'keyspace-events' if unset" --
		# so the lookup silently returns a plausible wrong value rather than
		# failing. Dashed keys are explicitly expected here (§5.1 normalizes
		# `-` to `_`), which is what makes this reachable rather than
		# theoretical.
		#
		# The trailing X survives command substitution stripping newlines, so
		# a value that ends in one still reaches the refusal below.
		value=$(awk -v n="${name}" 'BEGIN { printf "%s", ENVIRON[n] }'; printf X)
		value=${value%X}

		if _envconf_in_set "${_ENVCONF_DENY}" "${key}"; then
			envconf_die "${name} is denylisted and cannot be set"
		fi

		canon=$(_envconf_allow_canon "${key}")
		if [ -z "${canon}" ]; then
			if [ "${strict}" = "fail" ]; then
				envconf_die "${name} is not in the allowlist (set ${strict_var}=ignore to skip)"
			fi
			envconf_warn "ignoring ${name}: not in the allowlist"
			continue
		fi

		if _envconf_in_set "${curated}" "${key}"; then
			envconf_die "${name} and this image's curated variable for '${key}' both set it; unset one"
		fi

		if _envconf_has_newline "${value}"; then
			envconf_die "${name} contains a newline, which no supported config format can represent"
		fi

		printf '%s\0%s\0' "${canon}" "${value}"
	done
}

# Warn about <prefix>_* variables that are neither a curated name nor a
# passthrough key (RFC 0001 decision 9). A typo'd curated knob that silently
# does nothing is the failure this contract exists to prevent, and one log line
# is cheaper than that.
#
# Not fatal, deliberately: a real container's environment is full of unrelated
# variables, and a fail-closed rule here would refuse to start because a
# sibling service shares a prefix.
#
# The noise objection is answered by the ignore list rather than by silence.
# The image's own control variables are excluded -- a warning that fires on
# <PREFIX>_CONF_STRICT itself teaches operators to ignore all of them.
#
#   envconf_warn_unknown <prefix> <curated_var_names>
envconf_warn_unknown() {
	local prefix="$1"
	local curated=" ${2:-} "
	local names name

	[ -n "${prefix}" ] || envconf_die "envconf_warn_unknown: no prefix given"

	names=$(awk -v pfx="${prefix}_" \
		'BEGIN { for (k in ENVIRON) if (index(k, pfx) == 1) print k }' | sort)

	for name in ${names}; do
		# The passthrough channel and its own controls.
		case "${name}" in
		"${prefix}_CONF__"*) continue ;;
		"${prefix}_CONF_STRICT" | "${prefix}_CONF_ALLOWLIST") continue ;;
		esac
		# Any <NAME>_FILE, since the base name is what the image declares.
		case "${name}" in
		*_FILE) continue ;;
		esac
		_envconf_in_set "${curated}" "${name}" && continue
		envconf_warn "${name} is set but this image does not use it. Check the spelling against images/<name>/README.md, or use ${prefix}_CONF__<directive> for a passthrough setting."
	done
}

# Read NUL-delimited pairs, write a config file on stdout.
#
# The stream is translated NUL->newline and read two lines at a time. That is
# safe precisely because envconf_collect refuses newline-bearing values, so the
# only newlines present are the delimiters this just wrote. A tab is untouched,
# which is the case that motivated NUL over `key<TAB>value` in the first place.
envconf_render() {
	local fmt="$1"
	local infile="${2:-}"

	case "${fmt}" in
	valkeyconf) ;;
	pgconf | keyvalue)
		envconf_die "envconf_render: format '${fmt}' is declared by RFC 0001 but not implemented; it ships with its first consumer"
		;;
	*) envconf_die "envconf_render: unknown format '${fmt}'" ;;
	esac

	if [ -n "${infile}" ]; then
		_envconf_render_valkeyconf <"${infile}"
	else
		_envconf_render_valkeyconf
	fi
}

# valkey.conf is `directive argument` per line. An argument containing
# whitespace, a quote or a backslash goes in double quotes with those escaped;
# anything else is emitted bare, which keeps the common file readable.
_envconf_render_valkeyconf() {
	local key value
	tr '\0' '\n' | while IFS= read -r key && IFS= read -r value; do
		case "${value}" in
		'' | *[[:space:]]* | *'"'* | *'\'*)
			value=$(printf '%s' "${value}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
			printf '%s "%s"\n' "${key}" "${value}"
			;;
		*)
			printf '%s %s\n' "${key}" "${value}"
			;;
		esac
	done
}

_envconf_is_secret() {
	local key
	local upper

	# Receives a canonical key; _ENVCONF_SECRET is keyed by normalized form.
	key=$(_envconf_normalize "$1")
	_envconf_in_set "${_ENVCONF_SECRET}" "${key}" && return 0

	upper=$(printf '%s' "${key}" | tr '[:lower:]' '[:upper:]')

	# Substring is right for these: no config directive in scope contains
	# "password" or "token" innocently.
	case "${upper}" in
	*PASSWORD* | *TOKEN* | *SECRET* | *HEADERS*) return 0 ;;
	esac

	# KEY is different, and RFC 0001 §5.2's bare *KEY* is too broad. Config
	# namespaces are full of innocent "key": `notify-keyspace-events` is an
	# allowlisted valkey directive, and redacting it would hide a setting an
	# operator specifically needs to read while protecting nothing. So match
	# KEY/KEYS as a whole segment -- `api_key` and `signing-keys` still
	# redact, `keyspace` and `keepalive` do not.
	case "_${upper}_" in
	*_KEY_* | *_KEYS_*) return 0 ;;
	esac
	return 1
}

# Print the effective configuration, one line per setting, redacting secrets.
#
# Reads NUL-delimited *quads* -- key, value, source, origin -- on stdin. The
# image builds that stream because only the image knows where its layers live:
# which file was baked in, which mounted fragment supplied a value, which
# environment variable a key came from. The helper has a prefix and `environ`,
# and neither answers "which layer won", which is the question the summary
# exists for.
#
# Quads rather than the key/source/origin triple this was specified as: the
# summary prints the effective *value* (that is most of its output), and the
# helper cannot obtain it. A triple would have forced every image to pass the
# values through a second channel. See EXECUTION-LOG D-014.
envconf_summary() {
	local prefix="$1"
	local infile="${2:-}"

	[ -n "${prefix}" ] || envconf_die "envconf_summary: no prefix given"

	echo "[envconf] ${prefix}: effective non-default settings" >&2
	if [ -n "${infile}" ]; then
		_envconf_summary_body <"${infile}"
	else
		_envconf_summary_body
	fi
	echo "[envconf] precedence: baked < mounted < env" >&2
}

_envconf_summary_body() {
	local key value source origin shown
	tr '\0' '\n' |
		while IFS= read -r key && IFS= read -r value &&
			IFS= read -r source && IFS= read -r origin; do
			# The key stays visible and only the value is hidden. RFC 0001's
			# example line shows `<redacted>` in place of the whole pair, but
			# the origin column names the variable anyway -- so hiding the key
			# conceals nothing and costs the reader the one thing the summary
			# is for, which is knowing what got set.
			if _envconf_is_secret "${key}"; then
				shown="${key} = <redacted>"
			else
				shown="${key} = ${value}"
			fi
			if [ -n "${origin}" ]; then
				printf '[envconf]   source=%-12s %-42s (%s)\n' \
					"${source}" "${shown}" "${origin}" >&2
			else
				printf '[envconf]   source=%-12s %s\n' "${source}" "${shown}" >&2
			fi
		done
}

# <NAME>_FILE wins over <NAME>. An unreadable <NAME>_FILE aborts rather than
# falling back: starting with the wrong credential is worse than not starting
# (RFC 0001 decision 4).
#
# Prints the value on stdout and nothing else, so it is safe to capture.
envconf_secret() {
	local name="$1"
	local file_var file value

	[ -n "${name}" ] || envconf_die "envconf_secret: no name given"

	file_var="${name}_FILE"
	eval "file=\${${file_var}:-}"

	if [ -n "${file}" ]; then
		[ -r "${file}" ] ||
			envconf_die "${file_var} is set to '${file}', which is not readable"
		# Strip a single trailing newline: every editor adds one and no secret
		# wants it. Embedded newlines are the file's business, not ours.
		value=$(cat "${file}"; printf X)
		value=${value%X}
		value=${value%"$_ENVCONF_NL"}
		printf '%s' "${value}"
		return 0
	fi

	eval "value=\${${name}:-}"
	printf '%s' "${value}"
}
