#!/usr/bin/env bash
# shellcheck disable=SC1091
# bootstrap.bash (https://github.com/webmin/webmin-ci-cd)
# Version 1.1.0
# Copyright Ilia Ross <ilia@webmin.dev>
# Licensed under the MIT License
#
# Bootstrap the build process

# Enable strict mode
set -euo pipefail

# Bootstrap URL
build_bootstrap_url="https://raw.githubusercontent.com/webmin/webmin-ci-cd/main/build"

# Bootstrap scripts
bootstrap_scripts=(
	"environment.bash"
	"functions.bash"
	"build-module-deb.bash"
	"build-product-deb.bash"
	"build-module-rpm.bash"
	"build-product-rpm.bash"
	"rpm-modules-epoch.txt"
	"modules-mapping.txt"
	"module-groups.txt"
)

bootstrap() {
	local argvs="$*"
	local base_url="$build_bootstrap_url/"
	local script_dir
	local ts
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	ts=$(date +%s)
	download_script() {
		local script_url="$1?$ts"
		local script_path="$2"
		for downloader in "curl -fsSL" "wget -qO-"; do
			if command -v "${downloader%% *}" >/dev/null 2>&1; then
			if eval "$downloader \"$script_url\" > \"$script_path\""; then
				chmod +x "$script_path"
				return 0
			fi
			fi
		done
		return 1
	}
	for script in "${bootstrap_scripts[@]}"; do
	local script_path="$script_dir/$script"
	if [ ! -f "$script_path" ]; then
		if ! download_script "${base_url}${script}" "$script_path"; then
		echo "Error: Failed to download $script. Cannot continue."
		exit 1
		fi
	fi
	done

	# Source build variables
	source "$script_dir/environment.bash" "$argvs" || exit 1

	# Source general build functions
	source "$script_dir/functions.bash" || exit 1
}

# Bootstrap build environment
bootstrap "$@" || exit 1
