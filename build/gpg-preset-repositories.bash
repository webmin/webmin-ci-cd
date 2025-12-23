#!/usr/bin/env bash
# gpg-preset-repositories.bash (https://github.com/webmin/webmin-ci-cd)
# Copyright Ilia Ross <ilia@webmin.dev>
# Licensed under the MIT License
#
# Presets the GPG passphrase (server part and user/CI part) into the
# repositories user's gpg-agent for repo signing
set -euo pipefail
set +x

readonly ph1_file="passphrase1.txt"
readonly kg_webmin="key1.keygrip"
readonly kg_virtualmin="key2.keygrip"

main() {
	local ph1 ph2 full

	cleanup() { unset ph1 ph2 full; }
	trap cleanup EXIT INT TERM HUP

	[[ -f "$ph1_file" ]] || {
		echo "Error: Stored passphrase file not found: $ph1_file" >&2
		return 1
	}
	[[ -f "$kg_webmin" ]] || {
		echo "Error: Webmin keygrip not found: $kg_webmin" >&2
		return 1
	}
	[[ -f "$kg_virtualmin" ]] || {
		echo "Error: Virtualmin keygrip not found: $kg_virtualmin" >&2
		return 1
	}

	ph1="$(cat "$ph1_file")"
	[[ -n "$ph1" ]] || {
		echo "Error: Stored passphrase is empty" >&2
		return 1
	}

	if [[ -t 0 ]]; then
		if command -v systemd-ask-password >/dev/null 2>&1; then
			ph2="$(systemd-ask-password "Enter signing passphrase:")" || true
		fi
		if [[ -z "${ph2:-}" ]]; then
			[[ -w /dev/tty ]] || {
				echo "Error: no TTY available for prompt" >&2
				return 1
			}
			printf "Enter signing passphrase: " > /dev/tty
			IFS= read -r -s ph2 < /dev/tty
			printf "\n" > /dev/tty
		fi
	else
		IFS= read -r ph2 || true
	fi

	[[ -n "$ph2" ]] || {
		echo "Error: User provided passphrase is empty" >&2
		return 1
	}
	[[ ${#ph2} -le 200 ]] || {
		echo "Error: User provided passphrase is too long" >&2
		return 1
	}

	full="${ph1}${ph2}"

	sudo -u repositories /usr/bin/gpgconf \
		--launch gpg-agent >/dev/null 2>&1 || true

	printf "%s" "$full" | \
		sudo -u repositories /usr/libexec/gpg-preset-passphrase \
		--preset "$(cat "$kg_webmin")" >/dev/null

	printf "%s" "$full" | \
		sudo -u repositories /usr/libexec/gpg-preset-passphrase \
		--preset "$(cat "$kg_virtualmin")" >/dev/null
}

main "$@"
