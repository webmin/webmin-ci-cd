#!/usr/bin/env bash
# Sync SourceForge release files to GitHub Releases.
# Requires the `github-release` CLI and wget, and set "GITHUB_TOKEN" to a token
# with repo write access. Run from the project's directory.
# Usage: ./sync-release-files.bash [--force] [webmin|usermin]
#
# By default, existing GitHub assets are left untouched and reported as skipped.
# Use --force, or set GH_RELEASE_REPLACE=1, to overwrite existing assets.

# Strict mode
set -u -o pipefail

# Usage helper kept close to the top because several validation paths need it.
usage() {
	echo "Usage: $0 [--force] [webmin|usermin]"
	echo "       --force   overwrite existing GitHub release assets"
}

# Command-line options. The project remains optional; if omitted, it is inferred
# from the current Git repository or working directory below.
project=""
force=0
for arg in "$@"; do
	case "$arg" in
		--force)
			force=1
			;;
		-h|--help)
			usage
			exit 0
			;;
		webmin|usermin)
			if [[ -n "$project" ]]; then
				usage
				echo "Error: project was specified more than once"
				exit 1
			fi
			project="$arg"
			;;
		*)
			usage
			echo "Error: unknown option or project: $arg"
			exit 1
			;;
	esac
done

# Check required command-line tools after option parsing so --help works even on
# machines that are not configured for releases.
if ! command -v github-release >/dev/null 2>&1; then
	echo "Error: github-release CLI is not installed"
	echo "You can install it from https://github.com/github-release/github-release"
	exit 1
fi

if ! command -v wget >/dev/null 2>&1; then
	echo "Error: wget is not installed"
	exit 1
fi

# Project detection fallback. This keeps the old convenience behavior for
# release directories named `webmin` or `usermin`.
if [[ -z "${project}" ]]; then
	if git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
		project="$(basename "$git_root")"
	else
		project="$(basename "$PWD")"
	fi
fi

if [[ "$project" != "webmin" && "$project" != "usermin" ]]; then
	echo "Project name is not known: $project"
	exit 1
fi

# Release metadata and authentication checks.
if [[ ! -r version ]]; then
	usage
	echo "Error: version file not found in current directory"
	exit 1
fi

version="$(head -n1 version || true)"
if [[ -z "${version}" ]]; then
	echo "Error: version file is empty"
	exit 1
fi

token="${GITHUB_TOKEN:-}"
if [[ -z "${token}" ]]; then
	echo "Error: GitHub security access token must be set"
	exit 1
fi

org="${GH_ORG:-webmin}"
download_retries="${SOURCEFORGE_RETRIES:-6}"
download_retry_sleep="${SOURCEFORGE_RETRY_SLEEP:-20}"
replace_existing="${GH_RELEASE_REPLACE:-0}"

if (( force )); then
	replace_existing=1
fi

# Retry knobs are environment-configurable, but keep them numeric so arithmetic
# tests and sleep calls cannot fail halfway through the release.
case "$download_retries" in
	""|*[!0-9]*)
		echo "Error: SOURCEFORGE_RETRIES must be a positive integer"
		exit 1
		;;
esac
case "$download_retry_sleep" in
	""|*[!0-9]*)
		echo "Error: SOURCEFORGE_RETRY_SLEEP must be a non-negative integer"
		exit 1
		;;
esac
if (( download_retries < 1 )); then
	echo "Error: SOURCEFORGE_RETRIES must be a positive integer"
	exit 1
fi

# Helper functions
sanitize_version() { printf "%s" "$1" | tr -cd 'v0-9.'; }
sanitize_file()    { printf "%s" "$1" | tr -cd 'a-z0-9_.-'; }
cap_first()        { printf "%s" "$1" | awk '{print toupper(substr($0,1,1)) substr($0,2)}'; }

# Prefix multi-line command output so github-release/wget messages remain
# aligned with the script's status lines.
print_output() {
	local text line

	text="${1//$'\r'/$'\n'}"
	[[ -n "$text" ]] || return 0

	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		printf "    .. %s\n" "$line"
	done <<< "$text"
}

# SourceForge can briefly serve an HTML placeholder or error page for a newly
# uploaded file. Treat that as "not ready" instead of uploading bad bytes to
# GitHub.
looks_like_html() {
	local file="$1"
	local mime=""

	if command -v file >/dev/null 2>&1; then
		mime="$(file -b --mime-type "$file" 2>/dev/null || true)"
		case "$mime" in
			text/html|application/xhtml+xml) return 0 ;;
		esac
	fi

	# Keep binary bytes out of shell variables; archives may contain NUL bytes,
	# which Bash cannot store and will warn about in command substitutions.
	(
		set +o pipefail
		LC_ALL=C head -c 512 "$file" 2>/dev/null |
			grep -Eiq '^[[:space:]]*<(!doctype html|html)'
	)
}

# Download a release asset with a small propagation window for SourceForge
# mirrors. A valid download must succeed, be non-empty, and not look like HTML.
download_release_file() {
	local url="$1"
	local output="$2"
	local attempt out status

	for (( attempt = 1; attempt <= download_retries; attempt++ )); do
		rm -f "$output"
		out="$(wget -q -O "$output" "$url" 2>&1)"
		status=$?

		if (( status == 0 )) && [[ -s "$output" ]] && ! looks_like_html "$output"; then
			return 0
		fi

		if (( attempt < download_retries )); then
			if (( status == 0 )); then
				echo "    .. SourceForge file is not ready yet (attempt $attempt/$download_retries); retrying in ${download_retry_sleep}s"
			else
				echo "    .. download failed (attempt $attempt/$download_retries); retrying in ${download_retry_sleep}s"
				print_output "$out"
			fi
			sleep "$download_retry_sleep"
		fi
	done

	if (( status == 0 )); then
		echo "    .. error: downloaded file was empty or looked like an HTML page"
	else
		echo "    .. error: cannot download"
		print_output "$out"
	fi
	return 1
}

# github-release reports duplicate assets as a 422 already_exists error. For a
# normal sync that is idempotent success; with --force we let --replace handle it.
is_already_uploaded_error() {
	local text

	text="$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]')"
	case "$text" in
		*"already_exists"*|*"already exists"*) return 0 ;;
	esac

	return 1
}

# Temp dir with auto-clean on exit. Signal traps must exit after cleanup; if a
# Ctrl-C only removed the temp dir and continued, later upload steps would fail
# in confusing ways.
tmp_dir="$(mktemp -d -t "sync-${project}-${version}-release.XXXX")"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
trap 'trap - EXIT; cleanup; exit 130' INT
trap 'trap - EXIT; cleanup; exit 143' TERM

vprt="$(sanitize_version "$version")"
pqu="$(cap_first "$project")"

echo "Synchronizing release files for $pqu $vprt via $tmp_dir"
if [[ "$replace_existing" == "1" ]]; then
	echo "Force mode enabled: existing GitHub release assets will be overwritten"
fi

# Standard files
if [ "${project}" = "webmin" ]; then
        files=(
                "${project}-${version}.tar.gz"
                "${project}-${version}-minimal.tar.gz"
                "${project}-${version}.pkg.gz"
                "${project}_${version}_all.deb"
                "${project}-${version}-1.noarch.rpm"
        )
else
        files=(
                "${project}-${version}.tar.gz"
                "${project}-webmail-${version}.tar.gz"
                "${project}_${version}_all.deb"
                "${project}-webmail_${version}_all.deb"
                "${project}-${version}-1.noarch.rpm"
                "${project}-webmail-${version}-1.noarch.rpm"
        )
fi

# Main loop
error=0
uploaded=0
skipped=0

for f in "${files[@]}"; do
	fprt="$(sanitize_file "$f")"
	url="https://sourceforge.net/projects/webadmin/files/${project}/${version}/${f}/download"

	echo "    Downloading from SourceForge (${project}/${fprt})"
	if download_release_file "$url" "$tmp_dir/$f"; then
		echo "    .. done"
	else
		((error++))
		continue
	fi

	if [[ "$f" != "$fprt" ]]; then
		ln -sf "$tmp_dir/$f" "$tmp_dir/$fprt"
	fi

	echo "    Uploading to GitHub (${project}/${fprt})"
	upload_args=(
		upload
		--user "$org"
		--repo "$project"
		--tag "$vprt"
		--name "$fprt"
		--file "$tmp_dir/$fprt"
	)

	if [[ "$replace_existing" == "1" ]]; then
		# github-release --replace deletes the existing asset first, then uploads
		# the new file. Keep it opt-in because a failed upload can leave no asset.
		upload_args+=(--replace)
	fi

	if out="$(github-release "${upload_args[@]}" 2>&1)"; then
		print_output "$out"
		echo "    .. done"
		((uploaded++))
		continue
	fi

	if [[ "$replace_existing" != "1" ]] && is_already_uploaded_error "$out"; then
		echo "    .. already exists on GitHub, skipped"
		((skipped++))
	else
		print_output "$out"
		echo "    .. error: upload failed"
		((error++))
	fi
done

if (( error > 0 )); then
	echo ".. done with errors ($uploaded uploaded, $skipped skipped, $error failed)"
	exit 1
else
	echo ".. done ($uploaded uploaded, $skipped skipped)"
fi
