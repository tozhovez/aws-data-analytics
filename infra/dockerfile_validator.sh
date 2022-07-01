#!/usr/bin/env bash
set -Eeuo pipefail

# TODO allow multiple files in "$@"

[ "$#" -le 1 ]
df="$(cat "$@")"
dfName="${1:-${DOCKERFILE_VALIDATOR_LABEL:-stdin}}"

# https://www.gnu.org/software/bash/manual/bashref.html#Exit-Status ("When a command terminates on a fatal signal whose number is N, Bash uses the value 128+N as the exit status. If a command is not found, the child process created to execute it returns a status of 127. If a command is found but is not executable, the return status is 126.")
maxExitCode=125
maxErrors="$(( maxExitCode - 1))" # save the biggest number for script errors

declare -A colors=(
	[reset]=''
	[ohno]=''
	[file]=''
	[message]=''
	[labels]=''
	[urls]=''
	[refs]=''
)
if [ -t 1 ] && command -v tput > /dev/null && tput setaf 1 &> /dev/null; then
	colors[reset]='\e[m'
	colors[ohno]='\e[0;31m'
	colors[file]='\e[0;34m'
	colors[message]='\e[1;31m'
	colors[labels]='\e[0;37m'
	colors[urls]='\e[0;32m'
	colors[refs]='\e[1;30m'
fi
_color() {
	local color="${colors[$1]:-}"
	echo -ne "$color"
}

ohNoes=0
oh_no_context() {
	(( ohNoes++ )) || :

	local message="$1"; shift
	echo "$(_color ohno)oh no$(_color reset): $(_color file)$dfName$(_color reset): $(_color message)$message$(_color reset)"
	if [ "$#" -gt 0 ]; then
		[ "$1" = '--' ] || echo >&2 "  $(_color labels)urls:$(_color reset)"
		while [ "$#" -gt 0 ]; do
			local url="$1"; shift
			[ "$url" != '--' ] || break
			echo "    - $(_color urls)$url$(_color reset)"
		done
		if [ "$#" -gt 0 ]; then
			local instruction="$1"; shift
			[ -z "$instruction" ] || instruction+=' '
			echo "  $(_color labels)refs:$(_color reset)"
			local IFS=$'\n' line
			for line in $*; do
				echo "    $(_color refs)$instruction$line$(_color reset)"
			done
		fi
	fi
	echo
}

# https://github.com/moby/buildkit/blob/v0.3.3/frontend/dockerfile/dockerfile2llb/directives.go
_parser_directive() {
	local directive="$1"; shift

	gawk -v directive="$directive" '
		match($0, /^#\s*([a-zA-Z][a-zA-Z0-9]*)\s*=\s*(.+?)\s*$/, m) {
			if (m[1] == directive) {
				print m[2]
				found = 1
				exit
			}
			next
		}
		{ exit }
		END {
			exit(found ? 0 : 1)
		}
	' <<<"$df"
}

# check "parser directives" for "syntax=" to complain about custom Dockerfile syntax
if syntax="$(_parser_directive 'syntax')"; then
	echo >&2 "error: custom syntax in use! ('$syntax'); can't parse Dockerfile!"
	exit "$maxExitCode" # custom syntax means we can't assume it's standard Dockerfile syntax and the rest of our checks are MOOOOOOO(t)
fi

escape="$(_parser_directive 'escape' || echo '\')"
# should be one of \ or ` (https://github.com/moby/buildkit/blob/v0.3.3/frontend/dockerfile/parser/parser.go#L102)
[ "$escape" = '\' ] || [ "$escape" = '`' ]
[ "${#escape}" = 1 ]
escapeRegex="${escape//\\/\\\\}"'[[:space:]]*'

_flatten() {
	gawk -v line='' '
		/^[[:space:]]*#/ {
			gsub(/^[[:space:]]+/, "")
			print
			next
		}
		{
			if (match($0, /^(.*)('"$escapeRegex"')$/, m)) {
				line = line m[1]
				next
			}
			print line $0
			line = ""
		}
	' <<<"$df"
}

flatDf="$(_flatten)"
df="$flatDf"

_filter() {
	local instruction="$1"; shift

	gawk -v instruction="$instruction" -v IGNORECASE=1 '
		tolower(instruction) == tolower($1) {
			gsub("^" instruction "[[:space:]]+", "")
			print
		}
	' <<<"$df"
}

# TODO warn about "FROM ...:latest" (explicit or implied, and also check "COPY --from=...")

runs="$(_filter 'RUN')"
if chowns="$(grep -E '^ch(own|mod)[[:space:]]+.*' <<<"$runs")" && [ -n "$chowns" ]; then
	oh_no_context "'RUN chown'/'RUN chmod' in use!" \
		'https://github.com/moby/moby/issues/783#issuecomment-19237045' \
		'--' 'RUN' "$chowns"
fi
if aptkeys="$(grep -E '(^|[;|&])[[:space:]]*apt-key[[:space:]]+(-[^[:space:]]*[[:space:]]+)*(add|adv)' <<<"$runs")" && [ -n "$aptkeys" ]; then
	oh_no_context "'RUN apt-key add|adv' in use!" \
		'https://manpages.debian.org/apt-key#COMMANDS ("Instead of using this command ... /etc/apt/trusted.gpg.d/ ...")' \
		'--' 'RUN' "$aptkeys"
fi
if gpgs="$(grep -E '(^|[;|&])[[:space:]]*gpg[[:space:]]+[^;|&]*' <<<"$runs" | grep -vE '(^|[;|&])[[:space:]]*gpg[[:space:]]+[^;|&]*--batch[^;|&]*')" && [ -n "$gpgs" ]; then
	oh_no_context "'RUN gpg ...' in use without '--batch'!" \
		'https://bugs.debian.org/913614#27 ("PS --batch everywhere for API mode")' \
		'https://github.com/docker-library/busybox/pull/55' \
		'--' 'RUN' "$gpgs"
fi
if aptUpgrades="$(grep -E '(^|[;|&])[[:space:]]*apt(-get)?[[:space:]]+(-[^[:space:]]*[[:space:]]+)*([a-z]+-)?upgrade' <<<"$runs")" && [ -n "$aptUpgrades" ]; then
	oh_no_context "'RUN apt-get upgrade' (or equivalent) in use!" \
		'https://docs.docker.com/develop/develop-images/dockerfile_best-practices/#apt-get' \
		'--' 'RUN' "$aptUpgrades"
fi
if yumUpdates="$(grep -E '(^|[;|&])[[:space:]]*(yum|dnf|tdnf|microdnf)[[:space:]]+(-[^[:space:]]*[[:space:]]+)*update' <<<"$runs")" && [ -n "$yumUpdates" ]; then
	oh_no_context "'RUN yum update' (or equivalent) in use!" \
		'https://docs.docker.com/develop/develop-images/dockerfile_best-practices/#apt-get' \
		'--' 'RUN' "$yumUpdates"
fi
# TODO "apk upgrade" / "apk add --upgrade"
if aptInstalls="$(grep -E '(^|[;|&])[[:space:]]*apt(-get)?[[:space:]]+(-[^[:space:]]*[[:space:]]+)*([a-z]+-)?install' <<<"$runs")" && [ -n "$aptInstalls" ]; then
	if essential="$(grep 'build-essential' <<<"$aptInstalls")" && [ -n "$essential" ]; then
		# TODO determine whether we're actually building Debian packages in this `RUN` line before we blanket complain about this
		oh_no_context "'RUN apt-get install build-essential' should be replaced by more specific dependencies such as 'make' and 'gcc' (unless building Debian packages)" \
			'https://packages.debian.org/unstable/build-essential' \
			'--' 'RUN' "$essential"
	fi
fi
if aptCleans="$(grep -E '(^|[;|&])[[:space:]]*apt(-get)?[[:space:]]+(-[^[:space:]]*[[:space:]]+)*([a-z]+-)?clean' <<<"$runs")" && [ -n "$aptCleans" ]; then
	oh_no_context "'RUN apt-get clean' in use!" \
		'https://docs.docker.com/develop/develop-images/dockerfile_best-practices/#apt-get' \
		'https://github.com/debuerreotype/debuerreotype/blob/5cf7949ecf1cec1afece267688bda64cd34a6817/scripts/debuerreotype-minimizing-config#L85-L109' \
		'https://github.com/tianon/docker-brew-ubuntu-core/blob/ec931883d8292935b62ac40757287491e6ff467e/focal/Dockerfile#L21-L24' \
		'--' 'RUN' "$aptCleans"
fi

# TODO complain about mixing "--no-cache" with "--update" on "apk" invocations
# TODO complain about missing "--no-network" on "apk del"

# TODO catch "curl" without "-f" / "--fail"

if alpineGlibc="$(grep 'alpine-pkg-glibc' <<<"$df")" && [ -n "$alpineGlibc" ]; then
	oh_no_context 'use of alpine-pkg-glibc is HIGHLY discouraged, as the results can be very unstable' \
		'https://ariadne.space/2021/08/26/there-is-no-such-thing-as-a-glibc-based-alpine-image/' \
		'https://gitlab.alpinelinux.org/alpine/aports/-/merge_requests/24647' \
		'--' '' "$alpineGlibc"
fi
# TODO detect mixing of Alpine edge and a release, for example

adds="$(_filter 'ADD')"
# https://github.com/moby/moby/blob/740349757396d8f1ad573d4b78148baca9c979aa/pkg/urlutil/urlutil.go#L12 (valid prefixes for ADD <url>)
if urls="$(grep -E '^(--[^[:space:]]*[[:space:]]+)*https?://' <<<"$adds")" && [ -n "$urls" ]; then
	# TODO find a better link that explains why this is bad
	oh_no_context "'ADD' with a remote URL in use!" \
		'https://github.com/moby/moby/issues/15717 (cache has to redownload every time)' \
		'https://github.com/docker-library/official-images#image-build (checksums, signatures, verification)' \
		'--' 'ADD' "$urls"
fi

declare -A labelSeen=()
labelKeys=()
declare -A labelVals=()
_parse_labels() {
	# parse each label into an individual line
	local labels
	labels="$(_filter 'LABEL')"

	local textRegex='([^"[:space:]]+?)|"((\\.|[^"])*?)"'
	local sedTextRegex='s/'"$textRegex"'/\1\2/g; s/\\(.)/\1/g'

	local IFS=$'\n' line
	for line in $labels; do
		# check for simple "LABEL key val" style first
		local key val
		key="$(grep -oP '^[[:space:]]*('"$textRegex"')+([[:space:]]+|$)' <<<"$line")"
		if [ -n "$key" ] && [[ "$key" != *=* ]]; then
			# must be "LABEL key val" (no "=")
			val="${line#$key}"
			key="$(sed -r 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$key")"

			key="$(sed -r "$sedTextRegex" <<<"$key")"
			val="$(sed -r "$sedTextRegex" <<<"$val")"

			if [ -z "${labelSeen[$key]:-}" ]; then
				labelSeen[$key]=1
				labelKeys+=( "$key" )
			fi
			labelVals[$key]="$val"
			continue
		fi

		local split
		split="$(
			grep -oP '('"$textRegex"')+?=('"$textRegex"')+([[:space:]]+|$)' <<<"$line" \
				| sed -r 's/[[:space:]]+$//'
		)"

		local keyVal
		for keyVal in $split; do
			key="$(grep -oP '^('"$textRegex"')+?=' <<<"$keyVal")"
			val="${keyVal#$key}"
			key="${key%=}"

			key="$(sed -r "$sedTextRegex" <<<"$key")"
			val="$(sed -r "$sedTextRegex" <<<"$val")"

			if [ -z "${labelSeen[$key]:-}" ]; then
				labelSeen[$key]=1
				labelKeys+=( "$key" )
			fi
			labelVals[$key]="$val"
		done
	done
}

# https://github.com/opencontainers/image-spec/blob/v1.0.1/annotations.md#pre-defined-annotation-keys
declare -A labelSuggestions=(
	[maintainer]='org.opencontainers.image.authors'
	[repository]='org.opencontainers.image.source'

	# https://github.com/label-schema/label-schema.org#readme
	# https://github.com/opencontainers/image-spec/blob/v1.0.1/annotations.md#back-compatibility-with-label-schema
	[org.label-schema.build-date]='org.opencontainers.image.created'
	[org.label-schema.url]='org.opencontainers.image.url'
	[org.label-schema.vcs-url]='org.opencontainers.image.source'
	[org.label-schema.version]='org.opencontainers.image.version'
	[org.label-schema.vcs-ref]='org.opencontainers.image.revision'
	[org.label-schema.vendor]='org.opencontainers.image.vendor'
	[org.label-schema.name]='org.opencontainers.image.title'
	[org.label-schema.description]='org.opencontainers.image.description'
)
declare -A ociLabels=(
	# https://github.com/opencontainers/image-spec/blob/v1.0.1/annotations.md#pre-defined-annotation-keys
	[org.opencontainers.image.created]=1
	[org.opencontainers.image.authors]=1
	[org.opencontainers.image.url]=1
	[org.opencontainers.image.documentation]=1
	[org.opencontainers.image.source]=1
	[org.opencontainers.image.version]=1
	[org.opencontainers.image.revision]=1
	[org.opencontainers.image.vendor]=1
	[org.opencontainers.image.licenses]=1
	[org.opencontainers.image.ref.name]=1
	[org.opencontainers.image.title]=1
	[org.opencontainers.image.description]=1
)

_parse_labels
for labelKey in "${labelKeys[@]}"; do
	labelVal="${labelVals[$labelKey]}"

	labelContext="$labelKey $labelVal"

	if [[ "$labelVal" == '='* ]]; then
		# https://github.com/CentOS/sig-cloud-instance-images/blob/0cea32a0018ac2d874960d9378a9745bf92affd2/docker/Dockerfile#L4 😂
		oh_no_context "'LABEL $labelKey' value starts with '='; likely a misplaced space?" \
			'https://github.com/docker-library/repo-info/blob/175a6702073f22907ad8db1d5a7c7d2dd32ee4fe/repos/centos/local/7.5.1804.md' \
			'--' 'LABEL' "$labelContext"
	fi

	if [ -n "${labelSuggestions[$labelKey]:-}" ]; then
		oh_no_context "'LABEL $labelKey' should be replaced with 'LABEL ${labelSuggestions[$labelKey]}'" \
			'https://docs.docker.com/config/labels-custom-metadata/#key-format-recommendations' \
			'https://github.com/opencontainers/image-spec/blob/v1.0.1/annotations.md#pre-defined-annotation-keys' \
			'--' 'LABEL' "$labelContext"
		continue
	fi

	if [[ "$labelKey" != *.* ]]; then
		oh_no_context "'LABEL $labelKey' should use full reverse DNS style key ('LABEL org.example...')" \
			'https://docs.docker.com/config/labels-custom-metadata/#key-format-recommendations' \
			'https://github.com/opencontainers/image-spec/blob/v1.0.1/annotations.md#rules' \
			'--' 'LABEL' "$labelContext"
		continue
	fi

	case "$labelKey" in
		org.label-schema.*)
			oh_no_context "deprecated Label Schema 'LABEL $labelKey' in use!" \
				'https://github.com/label-schema/label-schema.org#readme' \
				'https://github.com/opencontainers/image-spec/blob/v1.0.1/annotations.md#pre-defined-annotation-keys' \
				'--' 'LABEL' "$labelContext"
			continue
			;;

		org.opencontainers.*)
			if [ -z "${ociLabels[$labelKey]:-}" ]; then
				oh_no_context "undefined OCI annotation key 'LABEL $labelKey' in use!" \
					'https://github.com/opencontainers/image-spec/blob/v1.0.1/annotations.md#pre-defined-annotation-keys' \
					'--' 'LABEL' "$labelContext"
				continue
			fi
			;;
	esac
done

maintainer="$(_filter 'MAINTAINER')"
if [ -n "$maintainer" ]; then
	oh_no_context "deprecated 'MAINTAINER' in use! (consider 'LABEL org.opencontainers.image.authors=')" \
		'https://docs.docker.com/engine/reference/builder/#maintainer-deprecated' \
		'https://github.com/moby/moby/pull/25466 + https://github.com/moby/moby/pull/32700' \
		'https://github.com/opencontainers/image-spec/blob/v1.0.1/annotations.md#pre-defined-annotation-keys' \
		'--' 'MAINTAINER' "$maintainer"
fi

if debianFrontend="$(grep 'DEBIAN_FRONTEND' <<<"$df")" && [ -n "$debianFrontend" ]; then
	oh_no_context "'DEBIAN_FRONTEND' detected; is it really necessary?" \
		'https://github.com/moby/moby/issues/4032#issuecomment-34597177' \
		'https://bugs.debian.org/929417 (installing "perl" leads to debconf bugs)' \
		'--' '' "$debianFrontend"
fi

# TODO check for "pecl install foo1 foo2" and/or "gpg --recv-keys key1 key2"

if [ "$ohNoes" -gt "$maxErrors" ]; then
	ohNoes="$maxErrors"
fi
exit "$ohNoes"