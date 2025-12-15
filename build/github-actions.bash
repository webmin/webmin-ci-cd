#!/usr/bin/env bash
# github-actions.bash (https://github.com/webmin/webmin-ci-cd)
# Copyright Ilia Ross <ilia@webmin.dev>
# Licensed under the MIT License
#
# Forced-command wrapper for automated repository operations
# Allows:
#   - Repository signing command with strict path checks
#   - SCP uploads only to the ~/domains directory, with downloads disabled
# Denies:
#   - Interactive shells, SFTP, SCP downloads, all other commands

# Add strict error handling
set -euo pipefail

# Set environment
export HOME=/home/repositories
export USER=repositories
export LOGNAME=repositories
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/sbin:$HOME/.local/bin

# Command of the client
readonly orig="${SSH_ORIGINAL_COMMAND-}"

# Disable helper function
deny() { echo "Denied" >&2; exit 1; }

# Allowed upload directory
readonly allow_base="$HOME/domains"
[[ -d "$allow_base" ]] || deny
allow_base_rp="$(readlink -f -- "$allow_base")" || deny
readonly allow_base_rp

# Allow SCP uploads only to the specified directory and completely deny all
# downloads
readonly cmd=${orig%% *}
readonly cmd_base=${cmd##*/}
if [[ $cmd_base == scp ]]; then
	# Split into argv, with paths not containing spaces
	read -r -a argv <<<"$orig"

	# Must be in upload mode (-t), and not in download mode (-f)
	has_t=0
	for a in "${argv[@]}"; do
		[[ $a == -f ]] && { echo "SCP downloads are disabled" >&2; exit 1; }
		[[ $a == -t ]] && has_t=1
	done
	[[ $has_t -eq 1 ]] || \
		{ echo "SCP downloads are disabled" >&2; exit 1; }

	# Destination is the last argument, make sure to limit it to the allowed
	# base
	readonly dest="${argv[${#argv[@]}-1]}"

	# Quick prefix check
	[[ $dest == "$allow_base"/* ]] || \
		{ echo "Uploads allowed only under $allow_base" >&2; exit 1; }

	# Require destination dir exists
	[[ -d "$dest" ]] || \
		{ echo "Upload destination must be an existing directory: $dest" >&2; \
		  exit 1; }

	# Realpath check blocks symlink escapes
	dest_rp="$(readlink -f -- "$dest")" || deny
	readonly dest_rp
	[[ $dest_rp == "$allow_base_rp"/* ]] || \
		{ echo "Upload destination escapes $allow_base" >&2; exit 1; }

	# Run real scp binary, don’t trust path
	exec /usr/bin/scp "${argv[@]:1}"
fi

# Block SFTP completely
if [[ $orig == */sftp-server* ]] || [[ $orig == internal-sftp* ]]; then
	echo "SFTP is disabled for this key" >&2
	exit 1
fi

# Allow delete call using: delete 'dir' 'pattern'
readonly del_re="^delete[[:space:]]+'([^']+)'[[:space:]]+'([^']+)'[[:space:]]*$"
if [[ $orig =~ $del_re ]]; then
	readonly del_dir=${BASH_REMATCH[1]}
	readonly del_pat=${BASH_REMATCH[2]}

	del_dir_rp="$(readlink -f -- "$del_dir")" || deny
	readonly del_dir_rp
	[[ -d "$del_dir_rp" ]] || deny
	[[ $del_dir_rp == "$allow_base_rp"/* ]] || deny

	[[ $del_pat == */* ]] && deny

	exec /usr/bin/find "$del_dir_rp" -maxdepth 1 -name "$del_pat" -delete
fi

# Allow promote hold management using:
#   promote_hold 'dir' 'pkgbase' 'add'
#   promote_hold 'dir' 'pkgbase' 'remove'
readonly hold_re="^promote_hold[[:space:]]+'([^']+)'[[:space:]]+'([^']+)'[[:space:]]+'(add|remove)'[[:space:]]*$"
if [[ $orig =~ $hold_re ]]; then
	readonly hold_dir=${BASH_REMATCH[1]}
	readonly pkg_base=${BASH_REMATCH[2]}
	readonly action=${BASH_REMATCH[3]}

	hold_dir_rp="$(readlink -f -- "$hold_dir")" || deny
	readonly hold_dir_rp
	[[ -d "$hold_dir_rp" ]] || deny
	[[ $hold_dir_rp == "$allow_base_rp"/* ]] || deny

	# Only allow simple names
	[[ $pkg_base =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || deny

	cd "$hold_dir_rp" || deny

	# Keep file local to the repo dir
	readonly hold_file=".promote-hold"
	readonly lock_file=".promote-hold.lock"

	if [[ $action == add ]]; then
		exec /usr/bin/flock -x "$lock_file" /usr/bin/bash -c \
			"touch '$hold_file' &&
			 ( grep -Fxq '$pkg_base' '$hold_file' || echo '$pkg_base' >> '$hold_file' )"
	else
		exec /usr/bin/flock -x "$lock_file" /usr/bin/bash -c \
			"[ -f '$hold_file' ] || exit 0
			 grep -Fxv '$pkg_base' '$hold_file' > '$hold_file.tmp' || true
			 /usr/bin/mv -f -- '$hold_file.tmp' '$hold_file'"
	fi
fi

# Allow signing call using: sign 'dir' 'target' ['promote']
readonly sign_re="^sign[[:space:]]+'([^']*)'[[:space:]]+'([^']*)'([[:space:]]+'([^']*)')?[[:space:]]*$"
if [[ $orig =~ $sign_re ]]; then
	readonly repo_dir=${BASH_REMATCH[1]}
	readonly repo_target=${BASH_REMATCH[2]}
	readonly promote=${BASH_REMATCH[4]-}

	# Realpath checks
	repo_dir_rp="$(readlink -f -- "$repo_dir")" || deny
	readonly repo_dir_rp
	[[ -d "$repo_dir_rp" ]] || deny
	[[ $repo_dir_rp == "$allow_base_rp"/* ]] || deny

	# Re-preset GPG signing key passphrases into agent cache
	if ! /usr/bin/sudo -n /usr/bin/systemctl restart \
		gpg-preset-repositories.service >/dev/null 2>&1
	then
		echo "Warning: Could not preset GPG passphrases, signing may" \
			 "fail if cache expired" >&2
	fi

	# Execute the signing script with validated params
	exec "$HOME/.local/sbin/sign-repo.bash" \
		 "$repo_dir_rp" "$repo_target" "$promote"
fi

# Allow sync call using: sync
readonly sync_re="^sync[[:space:]]*$"
if [[ $orig =~ $sync_re ]]; then
	exec "$HOME/.local/sbin/sync-remote-repos.bash"
fi

deny
