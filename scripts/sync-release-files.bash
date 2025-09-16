#!/usr/bin/env bash
# Sync SourceForge release files to GitHub Releases.
# Requires the `github-release` CLI, and set "GITHUB_TOKEN" to a token with repo
# write access. Run from the project’s directory.
# Usage: ./sync-release-files.bash [webmin|usermin]

# Strict mode
set -u -o pipefail

# Check if github-release is installed
if ! command -v github-release >/dev/null 2>&1; then
	echo "Error: github-release CLI is not installed"
	echo "You can install it from https://github.com/github-release/github-release"
	exit 1
fi

# Project detection
project="${1:-}"
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

# Checks
if [[ ! -r version ]]; then
	echo "Usage: $0 <project>"
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

# Helper functions
sanitize_version() { printf "%s" "$1" | tr -cd 'v0-9.'; }
sanitize_file()    { printf "%s" "$1" | tr -cd 'a-z0-9_.-'; }
cap_first()        { printf "%s" "$1" | awk '{print toupper(substr($0,1,1)) substr($0,2)}'; }

# Temp dir with auto-clean on exit
tmp_dir="$(mktemp -d -t "sync-${project}-${version}-release.XXXX")"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT INT TERM

vprt="$(sanitize_version "$version")"
pqu="$(cap_first "$project")"

echo "Synchronizing release files for $pqu $vprt via $tmp_dir"

# Standard files
files=(
	"${project}-${version}.tar.gz"
	"${project}-${version}-minimal.tar.gz"
	"${project}-${version}.pkg.gz"
	"${project}_${version}_all.deb"
	"${project}-${version}-1.noarch.rpm"
)

# Main loop
error=0

for f in "${files[@]}"; do
	fprt="$(sanitize_file "$f")"
	url="https://sourceforge.net/projects/webadmin/files/${project}/${version}/${f}/download"

	echo "    Downloading from SourceForge (${project}/${fprt})"
	if wget -q -O "$tmp_dir/$f" "$url"; then
		echo "    .. done"
	else
		echo "    .. error: cannot download"
		((error++))
		continue
	fi

	if [[ "$f" != "$fprt" ]]; then
		ln -sf "$tmp_dir/$f" "$tmp_dir/$fprt"
	fi

	echo "    Uploading to GitHub (${project}/${fprt})"
	out="$(github-release upload \
		--security-token "$token" \
		--user "$org" \
		--repo "$project" \
		--tag "$vprt" \
		--name "$fprt" \
		--file "$tmp_dir/$fprt" 2>&1)" || true

	if [[ "$out" == *"error:"* ]]; then
		printf "    .. %s\n" "$out"
		((error++))
	else
		echo "    .. done"
	fi
done

if (( error > 0 )); then
	echo ".. done with errors"
	exit 1
else
	echo ".. done"
fi
