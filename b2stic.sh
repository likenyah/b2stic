#! /usr/bin/env sh
# SPDX-License-Identifier: 0BSD
# -----------------------------------------------------------------------------

: "${XDG_CONFIG_HOME:="${HOME}/.config"}"

: "${B2STIC_CONFIG:="${XDG_CONFIG_HOME}/b2stic/b2stic.conf"}"
: "${B2STIC_DRY_RUN:="n"}"
: "${B2STIC_LOG_FACILITY:="local0"}"
: "${B2STIC_REPOSITORY_2:="n"}"
: "${B2STIC_VERBOSE:="n"}"

b2stic_help="\
${0##*/} [-2chn] <repository-name> [<restic-command>]

Options:
 -2           Set RESTIC_* environment variables for repository 2. This allows
              for easier copying between repositories. Setting appropriate
              environment variables for the first repository is left to the
              user.
 -c <file>    Read configuration from <file>.
              Default: __ETCDIR__/b2stic/b2stic.conf if running as root, else
                       ${XDG_CONFIG_HOME}/b2stic/b2stic.conf
 -h           Display this help text.
 -n           Perform a \"dry run\"; do not actually execute commands, just
              print which commands would be exectued.
"

B2STIC_TMPDIR="$(mktemp -d -p "${TMPDIR:-"/tmp"}")"
trap 'rm -rf "${B2STIC_TMPDIR}"' EXIT

if [ "$(id -u)" -eq 0 ]; then
	B2STIC_CONFIG="__ETCDIR__/b2stic/b2stic.conf"
fi

_do_printf()
{
	_do_printf_fmt="${1}"
	shift

	# shellcheck disable=SC2059
	printf "${_do_printf_fmt}\\n" "${@}" >&2
}

checkyn()
{
	case "${1}" in
	[1Yy]|[Yy][Ee][Ss])
		return 0
		;;
	[0Nn]|[Nn][Oo])
		return 1
		;;
	*)
		return 2
		;;
	esac
}

log()
{
	if [ "$(id -u)" -ne 0 ]; then
		# Only bother with logging if we're running as root.
		return 0
	fi

	_log_spec="${B2STIC_LOG_FACILITY}.${1}"
	_log_fmt="${2}"
	shift 2

	# shellcheck disable=SC2059
	dryrun logger -t "${0##*/}[${$}]" -p "${_log_spec}" \
		"$(printf "${_log_fmt}\\n" "${@}")"
}

msg()
{
	log "info" "${@}"
	_do_printf "${@}"
}

error()
{
	_error_fmt="${1}"
	shift

	log "err" "error: ${_error_fmt}" "${@}"
	_do_printf "error: ${_error_fmt}" "${@}"
}

fatal()
{
	_fatal_fmt="${1}"
	shift

	log "crit" "fatal: ${_fatal_fmt}" "${@}"
	_do_printf "fatal: ${_fatal_fmt}" "${@}"
	exit 1
}

dryrun()
{
	if checkyn "${B2STIC_DRY_RUN}"; then
		msg "$ %s" "${*}"
	else
		"${@}"
	fi
}

match()
{
	printf "%s\\n" "${1}" | grep -Eq "${2}"
}

##
# config_normalise - Preprocess a configuration file so we can use it later.
#
# @1: Configuration file to preprocess.
# @2: File to write preprocessed configuration to.
#
# @return: None.
#
# We normalise a configuration file such that all lines are assignments,
# matching the following regular expression:
#
#     /^[[:alnum:]_-]+(\.[[:alnum:]_-]+)?=[^[:space:]].*$/
config_normalise()
{
	_config_normalise_tmpf="$(mktemp -p "${B2STIC_TMPDIR}")"

	# This is probably about the limit of what should be done with sed(1).
	sed -En '
		# Strip empty lines, comment lines, and end-of-line comments.
		/^[[:space:]]*(#.*)?$/d
		s/[[:space:]]*#.*$//

		# Fold escaped newlines.
		: fold
		/\\$/ {
			N
			s/\\\n[[:space:]]*//
			t fold
		}

		# Strip start-of-line and end-of-line whitespace.
		s/^[[:space:]]+//
		s/[[:space:]]+$//

		# Remove insignificant intra-line whitespace.
		s/^\[[[:space:]]*([[:alnum:]_-]+)[[:space:]]*\]$/[\1]/
		s/^([[:alnum:]._-]+)[[:space:]]*=[[:space:]]*/\1=/

		# Keep track of the current section by shoving it into hold
		# space.
		/^\[[[:alnum:]_-]+\]$/ {
			s/^\[//
			s/\]$//
			h
			d
		}

		# An invalid section name is a fatal error because it causes
		# problems for the rest of the file.
		/^\[.*\]$/ {
			s/^\[//
			s/\]$//
			s/^/ERRORF:invalid section name:/
			p
			d
		}

		# Assignments with explicit section names get passed through as
		# they are. (After stripping quotes.)
		/^[[:alnum:]_-]+\.[[:alnum:]_-]+=.*$/ {
			s/="(.*)"$|='\''(.*)'\''$/=\1\2/
			p
			d
		}

		# Assignments with implicit section names need to be
		# transformed into assignments with explicit section names.
		/^[[:alnum:]_-]+=.*$/ {
			# Somehow convince sed(1) to do the equivalent of
			# prepending hold space + "." to pattern space:
			#
			# 1. Prepend "." to pattern space.
			# 2. Append pattern to hold to get
			#    "<section>.\n<var>=<val>" in hold space.
			# 3. Swap pattern and hold to get
			#    "<section>.\n<var>=<val>" back into pattern space.
			# 4. Remove the embedded newline we just created.
			# 5. If we had no section, remove the leading ".".
			s/^/./
			H
			x
			s/\n//
			s/^\.//

			# Strip quotes.
			s/="(.*)"$|='\''(.*)'\''$/=\1\2/

			# Okay, now we actually have what we want.
			p

			# Recover the section name. Since we cannot have a "."
			# in the section name, remove everything from the first
			# "." to the end of the line and shove it back into
			# hold space.
			#
			# If we do not have a section name, wipe the pattern
			# space entirely.
			s/=.*$//

			/^[[:alnum:]_-]+$/ {
				s/.*//
			}

			s/\..*$//
			h
			d
		}

		# Everything else is invalid and we should be able to safely
		# ignore it.
		/^.*$/ {
			s/^/ERROR:invalid line:/
			p
			d
		}
		' <"${1}" | sort -u >"${_config_normalise_tmpf}"

	mv -f "${_config_normalise_tmpf}" "${2}"
}

##
# config_get - Retrieve the value of a key from a configuration file.
#
# @1: Key to retrieve the value of.
#
# @return: 0 (true) if the specified key was found, writing its value to
#          stdout(3), 1 (false) if the specified key was not found, or 2
#          (false) on error, writing an error message to stderr(3).
#
# A valid key must match the following regular expression:
#
#     /^[[:alnum:]_-]+(\.[[:alnum:]._-]+)?$/
config_get()
{
	if [ "${#}" -ne 1 ]; then
		error "expected arguments: <key>"
		return 2
	fi

	if ! match "${1}" '^[[:alnum:]_-]+(\.[[:alnum:]_-]+)?$'; then
		error "invalid key: %s" "${1}"
		return 2
	fi

	_config_get_tmpf="$(mktemp -p "${B2STIC_TMPDIR}")"
	config_normalise "${B2STIC_CONFIG}" "${_config_get_tmpf}"

	_config_get_errors="$(mktemp -p "${B2STIC_TMPDIR}")"
	grep -E '^ERRORF?' <"${_config_get_tmpf}" >"${_config_get_errors}"

	# If there were errors, write them all out.
	if [ -s "${_config_get_errors}" ]; then
		while IFS=: read -r _config_get_e _config_get_s _config_get_l; do
			error "%s: '%s'" "${_config_get_s}" "${_config_get_l}"

			# If we hit a fatal error, return now.
			if [ "${_config_get_e}" = "ERRORF" ]; then
				return 2
			fi
		done <"${_config_get_errors}"
	fi

	if ! grep -Eq "^${1}=" <"${_config_get_tmpf}"; then
		return 1
	fi

	sed -En "s/^${1}=//p" <"${_config_get_tmpf}"
}

##
# get_val - Retrieve a configuration value for a repository.
#
# @1: Repository name.
# @2: Configuration key.
#
# @return: 0 (true) if successful, writing the value to stdout(1), or 1 (false)
#          otherwise, writing an error message to stderr(3).
#
# This function first checks whether <key>-command is set and evaluates it if
# so. Such a command is expected to write only the appropriate value to
# stdout(1).
get_val()
{
	if _get_val_cmd="$(config_get "${1}.${2}-command")"; then
		if ! dryrun eval "${_get_val_cmd}"; then
			error "%s-command failure: %s" "${2}" "${_get_val_cmd}"
			return 2
		fi

		return 0
	fi

	if config_get "${1}.${2}"; then
		return 0
	fi

	if _get_val_cmd="$(config_get "${2}-command")"; then
		if ! dryrun eval "${_get_val_cmd}"; then
			error "%s-command failure: %s" "${2}" "${_get_val_cmd}"
			return 1
		fi

		return 0
	fi

	if config_get "${2}"; then
		return 0
	fi

	error "failed to determine %s for repository: %s" "${2}" "${1}"
	return 1
}

##
# get_pass - Retrieve a password command or a password file for a repository.
#
# @1: Repository name.
#
# @return: 0 (true) if successful, writing the value to stdout(1), or 1 (false)
#          otherwise, writing an error message to stderr(3).
get_pass()
{
	if ! config_get "${1}.password-command" \
	&& ! config_get "${1}.password" \
	&& ! config_get "password-command" \
	&& ! config_get "password"; then
		error "failed to determine password for repository: %s" "${1}"
		return 1
	fi
}

##
# restic_b2wrap - Wrapper for accessing B2 buckets with restic(1).
#
# @1:   Repository name in the configuration file.
# @...: Further arguments to pass to restic(1).
#
# @return: See restic(1).
restic_b2wrap()
{
	if ! _restic_b2wrap_bucket="$(config_get "${1}.bucket")" \
	|| ! _restic_b2wrap_path="$(config_get "${1}.path")"; then
		fatal "failed to get repository location: %s" "${1}"
	fi

	_restic_b2wrap_repo="b2:${_restic_b2wrap_bucket}:${_restic_b2wrap_path}"

	if ! B2_ACCOUNT_ID="$(get_val "${1}" "account-id")" \
	|| ! B2_ACCOUNT_KEY="$(get_val "${1}" "account-key")" \
	|| ! _restic_b2wrap_pass="$(get_pass "${1}")"; then
		fatal "failed to set up environment for repository: %s" "${1}"
	fi

	# Allow for manual password input via the restic(1) prompt.
	if [ "${_restic_b2wrap_pass}" = "restic-prompt" ]; then
		unset _restic_b2wrap_pass
	fi

	if checkyn "${B2STIC_REPOSITORY_2}"; then
		RESTIC_REPOSITORY2="${_restic_b2wrap_repo}"

		if [ -n "${_restic_b2wrap_pass}" ]; then
			if [ -f "${_restic_b2wrap_pass}" ]; then
				RESTIC_PASSWORD_FILE2="${_restic_b2wrap_pass}"
			else
				RESTIC_PASSWORD_COMMAND2="${_restic_b2wrap_pass}"
			fi
		else
			unset RESTIC_PASSWORD_COMMAND2
			unset RESTIC_PASSWORD_FILE2
		fi
	else
		RESTIC_REPOSITORY="${_restic_b2wrap_repo}"

		if [ -n "${_restic_b2wrap_pass}" ]; then
			if [ -f "${_restic_b2wrap_pass}" ]; then
				RESTIC_PASSWORD_FILE="${_restic_b2wrap_pass}"
			else
				RESTIC_PASSWORD_COMMAND="${_restic_b2wrap_pass}"
			fi
		else
			unset RESTIC_PASSWORD_COMMAND
			unset RESTIC_PASSWORD_FILE
		fi
	fi

	export B2_ACCOUNT_ID
	export B2_ACCOUNT_KEY
	export RESTIC_PASSWORD_COMMAND
	export RESTIC_PASSWORD_COMMAND2
	export RESTIC_PASSWORD_FILE
	export RESTIC_PASSWORD_FILE2
	export RESTIC_REPOSITORY
	export RESTIC_REPOSITORY2

	shift
	dryrun restic "${@}"
	_restic_b2wrap_ret="${?}"

	unset B2_ACCOUNT_ID
	unset B2_ACCOUNT_KEY
	unset RESTIC_PASSWORD_COMMAND
	unset RESTIC_PASSWORD_COMMAND2
	unset RESTIC_PASSWORD_FILE
	unset RESTIC_PASSWORD_FILE2
	unset RESTIC_REPOSITORY
	unset RESTIC_REPOSITORY2

	return "${_restic_b2wrap_ret}"
}

while getopts ":2c:hn" opt; do
	case "${opt}" in
	2)
		B2STIC_REPOSITORY_2="y"
		;;
	c)
		B2STIC_CONFIG="${OPTARG}"
		;;
	h)
		printf "%s" "${b2stic_help}"
		exit 0
		;;
	n)
		B2STIC_DRY_RUN="y"
		;;
	:)
		fatal "option requires argument: -%s" "${OPTARG}"
		;;
	*)
		fatal "invalid option: -%s" "${OPTARG}"
		;;
	esac
done
shift "$((OPTIND - 1))"

if [ "${#}" -lt 1 ]; then
	fatal "expected arguments: <repository-name> [<restic-command>]"
fi

if [ ! -f "${B2STIC_CONFIG}" ] || [ ! -r "${B2STIC_CONFIG}" ]; then
	fatal "configuration file does not exist or is not readable: %s" \
		"${B2STIC_CONFIG}"
fi

restic_b2wrap "${@}"
