#!/usr/bin/env bash
# shellcheck disable=SC2155 disable=SC2034
# sign-and-build-repos.bash (https://github.com/webmin/webmin-ci-cd)
# Copyright Ilia Ross <ilia@webmin.dev>
# Licensed under the MIT License
#
# Script to sign and build repositories in remote system

# Add strict error handling
set -euo pipefail

# Constants
readonly gpg_key="developers@webmin.com"
readonly apt_architectures=("all" "arm64" "amd64" "i386")
readonly apt_component="main"

# Input parameters
readonly gpg_ph=$(printf '%q' "$1")
readonly home_dir=$(printf '%q' "$2")
readonly repo_target=$(printf '%q' "$3")

# Directory structure
readonly rpm_repo="$home_dir/repodata"
readonly apt_pool_dir_name="pool"
readonly apt_pool_component_dir="$apt_pool_dir_name/$apt_component"
readonly apt_pool_dir="$home_dir/$apt_pool_component_dir"
readonly apt_repo_dists="$home_dir/dists"

# Temp directory
readonly temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT INT TERM

load_helper_functions() {
	local functions_file="${BASH_SOURCE[0]%/*}/functions.bash"
	if [ -f "$functions_file" ]; then
		# shellcheck disable=SC1090
		source "$functions_file"
		echo "Sourced functions file from $functions_file"
	else
		echo "Warning: The additional functions.bash file was not found" >&2
	fi
}

setup_repo_variables() {
	local -n out_origin=$1
	local -n out_desc=$2
	local -n out_codename=$3

	# Set default values for Webmin
	out_origin="Webmin Developers"
	out_desc="Automatically generated development builds of Webmin, Usermin and "
	out_desc+="Authentic Theme"
	out_codename="webmin"

	# Override values for Virtualmin if needed
	if [ "$repo_target" = "virtualmin.dev" ]; then
		out_origin="Virtualmin Developers"
		out_desc="Automatically generated development builds of Virtualmin, and "
		out_desc+="its plugins"
		out_codename="virtualmin"
	elif [ "$repo_target" = "cloudmin.dev" ]; then
		out_origin="Cloudmin Developers"
		out_desc="Automatically generated development builds of Cloudmin, and "
		out_desc+="its dependencies"
		out_codename="cloudmin"
	fi
}

generate_structured_apt_repo() {
	local apt_origin description codename
	setup_repo_variables apt_origin description codename

	local apt_repo_dists_codename_dir="$apt_repo_dists/$codename"
	local apt_repo_component_dir="$apt_repo_dists_codename_dir/$apt_component"

	# Create directories
	mkdir -p "$apt_pool_dir" "$apt_repo_component_dir"

	# Clean previous builds for testing repos only
	cleanup_old_builds

	# Update symlinks
	update_pool_symlinks

	# Generate metadata
	local sha256_entries sha512_entries
	generate_arch_metadata "$apt_repo_component_dir" sha256_entries sha512_entries

	# Create and sign release files
	create_release_files "$apt_repo_dists_codename_dir" "$apt_origin" "$codename" \
		"$description" "$sha256_entries" "$sha512_entries"
}

cleanup_old_builds() {
    # Skip cleanup if path contains "/rc." (like production has all releases)
    if [[ "$home_dir" =~ /rc\. ]]; then
        return 0
    fi

    # Skip cleanup if not a .dev repository
    if ! [[ "$repo_target" =~ ^(webmin|usermin|virtualmin|cloudmin)\.dev$ ]]; then
        return 0
    fi

    if ! command -v cleanup_packages >/dev/null; then
        echo "Warning: cleanup_packages function not available" >&2
		return 1
    else
        cleanup_packages "$home_dir" 1 "rpm deb tar.gz"
    fi
}

update_pool_symlinks() {
	find "$apt_pool_dir" -type l -exec rm -f {} +
	find "$home_dir" -type f -name "*.deb" -exec ln -s {} "$apt_pool_dir/" \;
}

filter_arch_metadata() {
    local arch=$1
    
    # For webmin.dev repository, we only need 'all' architecture
    if [ "$repo_target" = "webmin.dev" ] && [ "$arch" != "all" ]; then
        return 1
    fi
    
    # Allow all default architectures for other repositories
    return 0
}

generate_arch_metadata() {
	local component_dir=$1
	local -n sha256_ref=$2
	local -n sha512_ref=$3

	for arch in "${apt_architectures[@]}"; do
		if ! filter_arch_metadata "$arch"; then
			continue
		fi

		local arch_dir="$component_dir/binary-$arch"
		local packages_file="$arch_dir/Packages"
		local packages_gz="$arch_dir/Packages.gz"

		mkdir -p "$arch_dir"

		echo "Generating Packages and Packages.gz for $arch"
		dpkg-scanpackages --multiversion "$apt_pool_component_dir" > "$packages_file"
		gzip -1 < "$packages_file" > "$packages_gz"

		# Generate hash entries
		sha256_ref+=" $(sha256sum "$packages_file" | awk '{print $1}') $(wc -c < "$packages_file") $apt_component/binary-$arch/Packages"$'\n'
		sha256_ref+=" $(sha256sum "$packages_gz" | awk '{print $1}') $(wc -c < "$packages_gz") $apt_component/binary-$arch/Packages.gz"$'\n'
		sha512_ref+=" $(sha512sum "$packages_file" | awk '{print $1}') $(wc -c < "$packages_file") $apt_component/binary-$arch/Packages"$'\n'
		sha512_ref+=" $(sha512sum "$packages_gz" | awk '{print $1}') $(wc -c < "$packages_gz") $apt_component/binary-$arch/Packages.gz"$'\n'
	done
}

detect_build_type() {
	local dir=$1
	local build_type="preview"  # default to preview

	# Check RPM packages first
	for file in "$dir"/*.rpm; do
		if [ -f "$file" ]; then
			local filename=${file##*/}
			# Check for testing timestamp pattern in filename
			if [[ "$filename" =~ [0-9]{12} ]]; then
				build_type="testing"
				break
			fi
		fi
	done

	# If not found in RPMs, check DEBs
	if [ "$build_type" = "preview" ]; then
		for file in "$dir"/*.deb; do
			if [ -f "$file" ]; then
				local filename=${file##*/}
				# Check for testing timestamp pattern in filename
				if [[ "$filename" =~ [0-9]{12} ]]; then
					build_type="testing"
					break
				fi
			fi
		done
	fi
	echo "$build_type"
}

create_release_files() {
	local dists_dir=$1 origin=$2 codename=$3 description=$4 sha256_entries=$5 sha512_entries=$6
	local release_file="$dists_dir/Release"

	# Detect build type based on package names
	local build_type
	build_type=$(detect_build_type "$home_dir")
	echo "Detected build type: $build_type"
	local label suite
	if [ "$build_type" = "testing" ]; then
		label="Testing Builds"
		suite="testing"
	else
		label="Preview Builds"
		suite="preview"
	fi

	# Create Release file
	cat > "$release_file" <<EOF
Origin: $origin
Label: $label
Suite: $suite
Codename: $codename
Version: 1.0
Architectures: ${apt_architectures[*]}
Components: $apt_component
Description: $description
Date: $(date -Ru)
SHA256:
$sha256_entries
SHA512:
$sha512_entries
EOF

	# Sign InRelease and Release files
	sign_release_files "$dists_dir" "$release_file"
}

sign_release_files() {
	local dists_dir=$1 release_file=$2

	# Sign InRelease
	rm -f "$dists_dir/InRelease"
	echo "$gpg_ph" | gpg --batch --yes --passphrase-fd 0 --pinentry-mode loopback \
		--default-key "$gpg_key" --digest-algo SHA512 \
		--clearsign -o "$dists_dir/InRelease" "$release_file"

	# Sign Release
	rm -f "$dists_dir/Release.gpg"
	echo "$gpg_ph" | gpg --batch --yes --passphrase-fd 0 --pinentry-mode loopback \
		--default-key "$gpg_key" --digest-algo SHA512 -abs -o "$dists_dir/Release.gpg" "$release_file"
}

make_dnf_groups_param() {
	local home="${HOME_BASE:-$HOME}"
	local config_file="${home}/.config/dnf-groups/${repo_target}"
	local param=""

	# Check if the config file exists
	[[ -f "$config_file" ]] || return 0

	# Validate config file (must not be empty and must be readable)
	[[ -s "$config_file" && -r "$config_file" ]] || {
		echo "Error: Config file is empty or unreadable at $config_file" >&2
		return 1
	}

	# Read URLs from config file
	local urls=()
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ -n "$line" ]] || continue  # Skip empty lines
		urls+=("$line")
	done < "$config_file" || { 
		echo "Error: Failed to read URLs from $config_file" >&2
		return 1
	}

	# Validate URLs array
	[[ "${#urls[@]}" -gt 0 ]] || { 
		echo "Error: No URLs found in $config_file" >&2
		return 1
	}

	# Process URLs and get parameter
	param=$(handle_dnf_groups "${urls[@]}") || { 
		echo "Error: Failed to process URLs" >&2
		return 1
	}

	echo "$param"
}

handle_dnf_groups() {

    # Check if URLs were passed
    if [ "$#" -lt 1 ]; then
        echo "Error: No URLs provided" >&2
        return 1
    fi

    # Download each file
    echo "Downloading comps files .." >&2
    local downloaded_files=()
    for url in "$@"; do
        local filename="$temp_dir/${url##*/}"
        if ! curl -fsS "$url" -o "$filename"; then
			echo ".. error : failed to download $url" >&2
			return 1
		fi
        downloaded_files+=("$filename")
    done
    echo ".. done" >&2

    # Create merged comps file
    local comps_all="$temp_dir/merged-comps.xml"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE comps PUBLIC "-//Red Hat, Inc.//DTD Comps info//EN" "comps.dtd">'
        echo '<comps>'
        for file in "${downloaded_files[@]}"; do
            sed -n '/<group>/,/<\/group>/p' "$file"
        done
        echo '</comps>'
    } > "$comps_all"

    # Validate XML
    if ! command -v xmllint >/dev/null 2>&1; then
        echo "Error: xmllint not found, validation required" >&2
        return 1
    fi

    echo "Validating merged XML .." >&2
    if ! xmllint --noout "$comps_all" 2>/dev/null; then
        echo ".. error : XML validation failed" >&2
        return 1
    fi
    echo ".. done" >&2

    # If all good, return the --groupfile parameter with the merged groups file
    echo "--groupfile $comps_all"
}

handle_rpm_packages() {
	mkdir -p "$rpm_repo"
	local checksum_cache="$rpm_repo/.known_checksums"
	touch "$checksum_cache"
	
	# Clean existing repo files
	find "$rpm_repo" -type f ! -name '.known_checksums' -delete

	# Process RPM files
	local rpm_repo_cache_update
	for rpm_file in *.rpm; do
		[ -f "$rpm_file" ] || continue
		process_rpm_file "$rpm_file" "$checksum_cache" rpm_repo_cache_update
	done

	# Update cache if needed
	[ -n "${rpm_repo_cache_update-}" ] && mv "$checksum_cache.$$" "$checksum_cache"
	rm -f "$checksum_cache.$$" 2>/dev/null || true

	# Create and sign repository
	local -a groups
	IFS=' ' read -r -a groups <<< "$(make_dnf_groups_param)"
	createrepo_c "${groups[@]}" "$home_dir"
	echo "$gpg_ph" | gpg --batch --yes --passphrase-fd 0 --pinentry-mode loopback \
		--default-key "$gpg_key" --digest-algo SHA512 -abs -o \
		"$home_dir/repodata/repomd.xml.asc" "$home_dir/repodata/repomd.xml"
}

process_rpm_file() {
	local rpm_file=$1 checksum_cache=$2
	local -n update_ref=$3

	local current_sum cached_sum
	current_sum=$(sha256sum "$rpm_file" | cut -d' ' -f1)
	cached_sum=$(grep "^${rpm_file}:" "$checksum_cache" | cut -d: -f2 || true)

	if [ "$current_sum" != "$cached_sum" ]; then
		if ! rpm --delsign "$rpm_file"; then
			echo "Warning: Failed to delete signature from $rpm_file" >&2
		fi
		if ! rpm --addsign "$rpm_file"; then
			echo "Error: Failed to sign $rpm_file" >&2
			exit 1
		fi
		current_sum=$(sha256sum "$rpm_file" | cut -d' ' -f1)
		update_ref=1
	fi
	echo "${rpm_file}:${current_sum}" >> "$checksum_cache.$$"
}

function make_latest_links {
	local root="$1"
	cd "$root" || return 1
	shopt -s nullglob

	# The main script creates new -latest links for each package name. It
	# already created the repo metadata, so the links we make now won't be in
	# the APT/RPM metadata.

	# List regular files matching pattern
	list_sorted() {
		local base="$1" pat="$2"
		# outputs NUL-separated file names (relative)
		find "$base" -maxdepth 1 -type f -name "$pat" -printf '%T@ %P\0' | sort -z -nr | cut -z -d' ' -f2-
	}

	# Use DEB name to latest linking
	# name_version[_release]_arch.deb -> name-latest.deb
	list_sorted "$root" '*.deb' | {
		local -A seen_deb=()
		local f name
		while IFS= read -r -d '' f; do
			name="${f%%_*}"                        # before first "_"
			[[ -z $name || ${seen_deb[$name]+x} ]] && continue
			ln -sfn "$f" "${name}-latest.deb"
			seen_deb[$name]=1
		done
	}

	# Use RPM name to latest linking
	# name-version-release.arch.rpm -> name-latest.rpm
	list_sorted "$root" '*.rpm' | {
		local -A seen_rpm=()
		local f pname
		while IFS= read -r -d '' f; do
			pname=$(rpm -qp --qf '%{NAME}\n' "$f" 2>/dev/null) || continue
			[[ -z $pname || ${seen_rpm[$pname]+x} ]] && continue
			ln -sfn "$f" "${pname}-latest.rpm"
			seen_rpm[$pname]=1
		done
	}
}

main() {
	cd "$home_dir" || exit 1

	# Load functions
	load_helper_functions

	# Call pre build tasks if available
	if command -v pre_build >/dev/null 2>&1; then
		pre_build "$gpg_ph" "$home_dir" "$repo_target"
	fi

	# Generate structured APT repository
	generate_structured_apt_repo

	# Handle RPM packages
	handle_rpm_packages

	# Call post build tasks if available
	if command -v post_build >/dev/null 2>&1; then
		post_build "$gpg_ph" "$home_dir" "$repo_target"
	fi
}

main
