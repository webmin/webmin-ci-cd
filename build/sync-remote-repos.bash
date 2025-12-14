#!/usr/bin/env bash
# sync-remote-repos.bash (https://github.com/webmin/webmin-ci-cd)
# Copyright Ilia Ross <ilia@webmin.dev>
# Licensed under the MIT License
#
# Full mirror sync from staging to repo server
#
# Keeps the repo server identical to staging, except these paths which are
# never overwritten or deleted on the repo server:
#   .repo-theme
#   .htaccess
#   401.html
#   .lock*
#   .uploaded_list*

# Add strict error handling
set -euo pipefail

# Remote endpoint
readonly repo_host="ci-cd"

# Local base
readonly domains_base="$HOME/domains"

# Deny helper
deny() { echo "Error: $*" >&2; exit 1; }

# Base sanity
[[ -d "$domains_base" ]] || deny "Missing domains base: $domains_base"

# Rsync options
readonly -a rsync_opts=(
	"--archive"
	"--delete"
	"--delete-delay"
	"--itemize-changes"
	"--human-readable"
	"--safe-links"
	"--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r"
	"--exclude=/.repo-theme/"
	"--exclude=/.lock*"
	"--exclude=/.uploaded_list*"
	"--exclude=/.htaccess"
	"--exclude=/401.html"
)

# Track results
failures=0
synced=0

# Sync each domain public_html
shopt -s nullglob
for dom_path in "$domains_base"/*; do
	[[ -d "$dom_path" ]] || continue

	dom="${dom_path##*/}"
	src="$domains_base/$dom/public_html"
	dst="$domains_base/$dom/public_html"

	# Skip domains without public_html on staging
	[[ -d "$src" ]] || { echo "Skipping $dom (missing $src)" >&2; continue; }

	echo "--------------------------------------------------------------------------------"
	echo "Domain   : $dom"
	echo "Source   : $src"
	echo "Target   : $repo_host:$dst"
	echo "--------------------------------------------------------------------------------"

	# Run rsync with colored output and line wrapping
	if stdbuf -oL /usr/bin/rsync "${rsync_opts[@]}" "$src/" "$repo_host:$dst/" 2>&1 | \
		stdbuf -oL fold -w 80 -s | while IFS= read -r line; do
			printf "\033[47m\033[30m%-80s\033[0m\n" "$line"
		done
	then
		synced=$((synced + 1))
	else
		echo "Error: Sync failed for $dom" >&2
		failures=$((failures + 1))
	fi
	echo ""
done

# Summary
echo "================================================================================"
echo "Sync complete: $synced succeeded, $failures failed"
echo "================================================================================"
[[ $failures -eq 0 ]] || exit 1
