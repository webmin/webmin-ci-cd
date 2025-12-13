#!/usr/bin/env bash
# shellcheck disable=SC2155 disable=SC2034 disable=SC2094
# sign-repo.bash (https://github.com/webmin/webmin-ci-cd)
# Copyright Ilia Ross <ilia@webmin.dev>
# Licensed under the MIT License
#
# Script to sign and build repositories in remote system

# Add strict error handling
set -euo pipefail

# Constants
readonly gpg_key=${GPG_KEY:-developers@webmin.com}
readonly apt_architectures=("all" "arm64" "amd64" "i386")
readonly apt_component="main"
readonly rundir="$(dirname "$(readlink -f "$0")")"

# Input parameters
readonly repo_dir=$(printf '%q' "$1")
readonly repo_target=$(printf '%q' "$2")
readonly promote_stable="${3-}"

# Acquire an exclusive flock keyed to signed repo to serialize concurrent runs
# per target directory
readonly lockfile="$repo_dir/.lock"
exec 200>"$lockfile"
if ! flock -w 120 200; then
  echo "Error: Timed out as another signing process is still running in $repo_dir" >&2
  exit 1
fi

# Directory structure
readonly rpm_repo="$repo_dir/repodata"
readonly apt_pool_dir_name="pool"
readonly apt_pool_component_dir="$apt_pool_dir_name/$apt_component"
readonly apt_pool_dir="$repo_dir/$apt_pool_component_dir"
readonly apt_repo_dists="$repo_dir/dists"

# Temp directory
readonly temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT INT TERM

# Load functions file for additional helper functions (cleanup_packages)
readonly functions_file="$rundir/functions.bash"
if [ -f "$functions_file" ]; then
	# shellcheck disable=SC1090
	source "$functions_file"
	echo "Sourced functions file from $functions_file"
else
	echo "Error: The additional functions.bash file was not found" >&2
	exit 1
fi

# Cleanup testing repo packages if applicable
function cleanup_testing_repo {
    # Skip cleanup if a known pre-release repo path
    if [[ "$repo_dir" =~ /rc\. ]]; then
        return 0
    fi

    # Skip cleanup if not a known development repo
    if ! [[ "$repo_target" =~ ^(webmin|usermin|virtualmin|cloudmin)\.dev$ ]]; then
        return 0
    fi

    if ! command -v cleanup_packages >/dev/null; then
        echo "Warning: cleanup_packages function not available" >&2
		return 1
    else
        cleanup_packages "$repo_dir" 1 "rpm deb tar.gz"
    fi
}

# Return APT repo metadata values based on target repo
function get_apt_repo_metadata {
	local -n out_origin=$1
	local -n out_desc=$2
	local -n out_codename=$3

	# Set default values for Webmin
	out_origin="Webmin Developers"
	out_desc="Automatically generated development builds of Webmin, Usermin and "
	out_desc+="Authentic Theme"
	out_codename="webmin"

	# Override values for other repositories
	if [ "$repo_target" = "download.virtualmin.com" ]; then
		out_origin="Virtualmin Releases"
		out_desc="Stable builds of Virtualmin and its plugins, Webmin, Usermin, "
		out_desc+="and related installation scripts"
		out_codename="virtualmin"
	elif [ "$repo_target" = "virtualmin.dev" ]; then
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

# Create APT repository structure and metadata
function create_apt_repo {
	local apt_origin description codename
	get_apt_repo_metadata apt_origin description codename

	local apt_repo_dists_codename_dir="$apt_repo_dists/$codename"
	local apt_repo_component_dir="$apt_repo_dists_codename_dir/$apt_component"

	# Create directories
	mkdir -p "$apt_pool_dir" "$apt_repo_component_dir"

	# Update symlinks
	find "$apt_pool_dir" -type l -exec rm -f {} +
		# Re-create symlinks for all .deb files and .deb symlinks under repo_dir
		# but not from the pool itself, since we just cleared it
		find "$repo_dir" \
			\( -type f -o -type l \) \
			-name "*.deb" \
			! -path "$apt_pool_dir/*" \
			-exec ln -s {} "$apt_pool_dir/" \;

	# Generate metadata
	local sha256_entries sha512_entries
	create_apt_arch_metadata "$apt_repo_component_dir" sha256_entries sha512_entries

	# Create and sign release files
	create_apt_release_files "$apt_repo_dists_codename_dir" "$apt_origin" "$codename" \
		"$description" "$sha256_entries" "$sha512_entries"
}

# Create APT architecture packages metadata
function create_apt_arch_metadata {
	local component_dir=$1
	local -n sha256_ref=$2
	local -n sha512_ref=$3

	filter_arch_metadata() {
		local arch=$1
		
		# For webmin.dev repository, we only need 'all' architecture
		if [ "$repo_target" = "webmin.dev" ] && [ "$arch" != "all" ]; then
			return 1
		fi
		
		# Allow all default architectures for other repositories
		return 0
	}
	
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

# Detect build type for APT release
function detect_apt_build_type {
	local dists_dir=$1
	local dir_repo=$2
	
	# Check if this is a preview/RC build based on directory path
	if [[ "$dir_repo" == *"/rc."* ]]; then
		echo "Preview Builds|preview"
		return
	fi
	
	# Check for testing timestamp pattern (YYYYMMDDHHMM) in RPM or DEB packages
	for file in "$dir_repo"/*.{rpm,deb}; do
		[ -f "$file" ] || continue
		if [[ "${file##*/}" =~ [0-9]{12} ]]; then
			echo "Testing Builds|testing"
			return
		fi
	done
	
	# Default to stable if no timestamp found
	echo "Stable Builds|stable"
}

# Create APT release file and sign it
function create_apt_release_files {
	local dists_dir=$1 origin=$2 codename=$3 description=$4 sha256_entries=$5 sha512_entries=$6
	local release_file="$dists_dir/Release"

	# Detect build type
	local build_info label suite
	build_info=$(detect_apt_build_type "$dists_dir" "$repo_dir")
	IFS='|' read -r label suite <<< "$build_info"

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

	# Sign release files
	rm -f "$dists_dir/InRelease"
	gpg --batch --yes --default-key "$gpg_key" --digest-algo SHA512 \
		--clearsign -o "$dists_dir/InRelease" "$release_file"
}

# Make DNF groups parameter
function make_dnf_groups_param {
	local config_file="${HOME}/.config/dnf-groups/${repo_target}"
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
	param=$(create_dnf_groups "${urls[@]}") || { 
		echo "Error: Failed to process URLs" >&2
		return 1
	}

	echo "$param"
}

# Create merged DNF groups file from configured URLs
function create_dnf_groups {

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

# Sign RPM package if it has changed
function sign_rpm {
	local rpm_file=$1 checksum_cache=$2
	local -n update_ref=$3

	local current_sum cached_sum
	current_sum=$(sha256sum "$rpm_file" | cut -d' ' -f1)
	cached_sum=$(grep "^${rpm_file}:" "$checksum_cache" | cut -d: -f2 || true)

	if [ "$current_sum" != "$cached_sum" ]; then
		local rpm_gpg_name="$gpg_key"

		# Use explicit RPM macros right here to avoid issues with different keys
		local rpm_opts=(
			--define "_signature gpg"
			--define "__gpg /usr/bin/gpg"
			--define "_gpg_name ${rpm_gpg_name}"
		)

		if ! rpm "${rpm_opts[@]}" --delsign "$rpm_file"; then
			echo "Warning: Failed to delete signature from $rpm_file" >&2
		fi

		if ! rpm "${rpm_opts[@]}" --addsign "$rpm_file"; then
			echo "Error: Failed to sign $rpm_file with key ${rpm_gpg_name}" >&2
			exit 1
		fi

		current_sum=$(sha256sum "$rpm_file" | cut -d' ' -f1)
		update_ref=1
	fi

	echo "${rpm_file}:${current_sum}" >> "$checksum_cache.$$"
}

# Create and sign DNF repository
function create_dnf_repo {
	mkdir -p "$rpm_repo"
	local checksum_cache="$rpm_repo/.known_checksums"
	touch "$checksum_cache"
	
	# Clean existing repo files
	find "$rpm_repo" -type f ! -name '.known_checksums' -delete

	# Process RPM files
	local rpm_repo_cache_update
	for rpm_file in *.rpm; do
		[ -f "$rpm_file" ] && [ ! -L "$rpm_file" ] || continue
		sign_rpm "$rpm_file" "$checksum_cache" rpm_repo_cache_update
	done

	# Update cache if needed
	[ -n "${rpm_repo_cache_update-}" ] && mv "$checksum_cache.$$" "$checksum_cache"
	rm -f "$checksum_cache.$$" 2>/dev/null || true

	# Create and sign repository
	local -a groups
	IFS=' ' read -r -a groups <<< "$(make_dnf_groups_param)"
	createrepo_c "${groups[@]}" "$repo_dir"
	gpg --batch --yes --default-key "$gpg_key" --digest-algo SHA512 -abs -o \
		"$repo_dir/repodata/repomd.xml.asc" "$repo_dir/repodata/repomd.xml"
}

# Remove each package latest symlinks
function remove_package_symlinks {
	local root="$1"
	cd "$root" || return 1
	shopt -s nullglob

	# Remove existing latest symlinks
	find "$root" -maxdepth 1 -type l \( \
			-name '*-latest*.deb' -o \
			-name '*-latest*.rpm' -o \
			-name '*-latest*.tar.gz' \
		\) -delete 2>/dev/null || true
	
}

# Re-create the latest symlinks for every package name since we've already
# created the repo metadata, so the links we make now won't be in the APT/RPM
# metadata.
function regenerate_package_symlinks {
	local root="$1"
	cd "$root" || return 1
	shopt -s nullglob

	# List files matching pattern
	list_sorted() {
		local base="$1" pat="$2"
		# outputs NUL-separated file names (relative)
		find "$base" -maxdepth 1 \( -type f -o -type l \) -name "$pat" \
			-printf '%T@ %P\0' | \
			sort -z -nr | cut -z -d' ' -f2-
	}

	# Create name-latest[-gpl|-pro][-<arch>].deb  (skips -<arch> when arch=all)
	# First, collect all deb packages and detect which have editions or
	# multiple architectures
	local -A deb_has_edition=()
	local -A deb_first_arch=()
	local -A deb_has_variants=()
	
	while IFS= read -r -d '' f; do
		mapfile -t fields < <(dpkg-deb -f "$f" Package Architecture Version 2>/dev/null \
							| sed -E 's/^[A-Za-z-]+:[[:space:]]*//') || continue
		local name="${fields[0]}" arch="${fields[1]}" ver="${fields[2]}"
		[[ -z $name ]] && continue
		
		# Check for editions
		if [[ $ver =~ (^|[.+~-])(gpl|pro)($|[.+~-]) ]]; then
			deb_has_edition["$name"]=1
		fi
		
		# Track first non-"all" arch seen; flag if we see a different one
		if [[ $arch != "all" ]]; then
			if [[ -z ${deb_first_arch["$name"]+x} ]]; then
				deb_first_arch["$name"]="$arch"
			elif [[ ${deb_first_arch["$name"]} != "$arch" ]]; then
				deb_has_variants["$name"]=1
			fi
		fi
	done < <(list_sorted "." '*.deb')

	# Now create links for deb packages
	local -A seen_deb=()
	local -A seen_generic=()
	local f name arch ver edition key link_name
	
	while IFS= read -r -d '' f; do
		mapfile -t fields < <(dpkg-deb -f "$f" Package Architecture Version 2>/dev/null \
							| sed -E 's/^[A-Za-z-]+:[[:space:]]*//') || continue
		name="${fields[0]}"; arch="${fields[1]}"; ver="${fields[2]}"
		[[ -z $name ]] && continue

		edition=""
		if [[ $ver =~ (^|[.+~-])(gpl|pro)($|[.+~-]) ]]; then
			edition="${BASH_REMATCH[2]}"
		fi

		# Only create generic link if package has no editions and no multiple
		# architectures
		if [[ -z ${seen_generic["$name"]+x} && \
			  -z ${deb_has_edition["$name"]+x} && \
			  -z ${deb_has_variants["$name"]+x} ]]; then
			ln -sfn "$f" "${name}-latest.deb"
			seen_generic["$name"]=1
		fi

		# Variant latest per (edition, arch)
		key="${name}|${edition}|${arch}"
		[[ ${seen_deb[$key]+x} ]] && continue

		link_name="${name}-latest"
		[[ -n $edition ]] && link_name+="-$edition"
		[[ $arch != "all" ]] && link_name+="-$arch"
		link_name+=".deb"

		ln -sfn "$f" "$link_name"
		seen_deb["$key"]=1
	done < <(list_sorted "." '*.deb')

	# Create name-latest[-gpl|-pro][-<arch>].rpm  (skips -<arch> when arch=noarch)
	# First, collect all rpm packages and detect which have editions or multiple
	# architectures
	local -A rpm_has_edition=()
	local -A rpm_first_arch=()
	local -A rpm_has_variants=()
	
	while IFS= read -r -d '' f; do
		local meta pname arch rel
		meta=$(rpm -qp --qf '%{NAME}|%{ARCH}|%{RELEASE}\n' "$f" 2>/dev/null) || continue
		IFS='|' read -r pname arch rel <<< "$meta"
		[[ -z $pname ]] && continue
		
		# Check for editions
		if [[ $rel =~ (^|[.])(gpl|pro)($|[.]) ]]; then
			rpm_has_edition["$pname"]=1
		fi
		
		# Track first non-"noarch" arch seen; flag if we see a different one
		if [[ $arch != "noarch" ]]; then
			if [[ -z ${rpm_first_arch["$pname"]+x} ]]; then
				rpm_first_arch["$pname"]="$arch"
			elif [[ ${rpm_first_arch["$pname"]} != "$arch" ]]; then
				rpm_has_variants["$pname"]=1
			fi
		fi
	done < <(list_sorted "." '*.rpm')

	# Now create rpm links
	local -A seen_rpm=()
	local -A seen_generic=()
	local f meta pname arch rel edition key link_name
	
	while IFS= read -r -d '' f; do
		meta=$(rpm -qp --qf '%{NAME}|%{ARCH}|%{RELEASE}\n' "$f" 2>/dev/null) || continue
		IFS='|' read -r pname arch rel <<< "$meta"
		[[ -z $pname ]] && continue

		edition=""
		[[ $rel =~ (^|[.])(gpl|pro)($|[.]) ]] && edition="${BASH_REMATCH[2]}"

		# Only create generic link if package has no editions and no multiple
		# architectures
		if [[ -z ${seen_generic["$pname"]+x} && \
			  -z ${rpm_has_edition["$pname"]+x} && \
			  -z ${rpm_has_variants["$pname"]+x} ]]; then
			ln -sfn "$f" "${pname}-latest.rpm"
			seen_generic["$pname"]=1
		fi

		# Variant latest per (edition,arch)
		key="${pname}|${edition}|${arch}"
		[[ ${seen_rpm[$key]+x} ]] && continue

		link_name="${pname}-latest"
		[[ -n $edition ]] && link_name+="-$edition"
		[[ $arch != "noarch" ]] && link_name+="-$arch"
		link_name+=".rpm"

		ln -sfn "$f" "$link_name"
		seen_rpm[$key]=1
	done < <(list_sorted "." '*.rpm')

	# Create name-latest[-gpl|-pro].tar.gz
	# First, collect all tar.gz packages and detect which have editions
	local -A tar_has_edition=()
	
	while IFS= read -r -d '' f; do
		local base="${f%.tar.gz}"
		if [[ $base =~ ^([a-zA-Z0-9_-]+)-[0-9] ]]; then
			local name="${BASH_REMATCH[1]}"
			if [[ $f =~ \.(gpl|pro)\. ]]; then
				tar_has_edition["$name"]=1
			fi
		fi
	done < <(list_sorted "." '*.tar.gz')

	# Now create tar.gz links
	local -A seen_tar=()
	local -A seen_generic=()
	local f name edition key link_name
	
	while IFS= read -r -d '' f; do
		local base="${f%.tar.gz}"
		
		# Extract name (everything before first dash followed by a digit)
		if [[ $base =~ ^([a-zA-Z0-9_-]+)-[0-9] ]]; then
			name="${BASH_REMATCH[1]}"
		else
			continue
		fi
		
		# Extract edition from filename (look for .gpl. or .pro. in filename)
		edition=""
		if [[ $f =~ \.gpl\. ]]; then
			edition="gpl"
		elif [[ $f =~ \.pro\. ]]; then
			edition="pro"
		fi

		# Only create generic link if package has no editions
		if [[ -z ${seen_generic["$name"]+x} && -z ${tar_has_edition["$name"]+x} ]]; then
			ln -sfn "$f" "${name}-latest.tar.gz"
			seen_generic["$name"]=1
		fi
		
		# Variant latest per edition
		key="${name}|${edition}"
		[[ -z $name || ${seen_tar[$key]+x} ]] && continue
		
		# Build link name: name-latest[-edition].tar.gz
		link_name="${name}-latest"
		[[ -n $edition ]] && link_name+="-$edition"
		link_name+=".tar.gz"
		
		ln -sfn "$f" "$link_name"
		seen_tar[$key]=1
	done < <(list_sorted "." '*.tar.gz')
}

# Copy RPM mtimes from RC to stable so HTML listing order matches RC
function copy_rpm_mtime_from_rc {
	local src_home=$1
	local dst_home=$2

	shopt -s nullglob
	local f base src dst
	for f in "$src_home"/*.rpm; do
		[[ -f "$f" ]] || continue
		base=${f##*/}
		src="$f"
		dst="$dst_home/$base"

		# Only touch real files in stable and skip missing or symlinks
		[[ -f "$dst" && ! -L "$dst" ]] || continue

		touch -r "$src" "$dst"
	done
	shopt -u nullglob
}

# Adjust the core product package times so they sort just above their own
# modules, but ignore other separate dedicated products
function prioritize_core_product {
	local root="$1"

	[ -d "$root" ] || return 0

	(
		cd "$root" || exit 0

		# So unmatched globs just disappear
		shopt -s nullglob

		bump_family() {
			local family="$1"
			local core base version latest mtime file

			# Core patterns for this family
			for core in \
				"${family}"-[0-9.]*.tar.gz \
				"${family}"-[0-9.]*-[0-9]*.noarch.rpm \
				"${family}"_[0-9.]*-[0-9]*_all.deb
			do
				[ -e "$core" ] || continue

				base="${core##*/}"
				version=""

				# Extract version string (can be 2.610 or 2.610.202512051200)
				case "$base" in
					${family}-*.tar.gz)
						# family-<version>.tar.gz
						version="${base#"${family}"-}"
						version="${version%.tar.gz}"
						;;
					${family}-*-*.noarch.rpm)
						# family-<version>-<rel>.noarch.rpm
						version="${base#"${family}"-}"
						version="${version%%-*}"
						;;
					${family}_*-*_all.deb)
						# family_<version>-<rel>_all.deb
						version="${base#"${family}"_}"
						version="${version%%-*}"
						;;
					*)
						continue
						;;
				esac

				[ -n "$version" ] || continue

				latest=0

				# Look only at modules of the same family+version, i.e.:
				#   family-<module>-<version>-*.rpm
				#   family-<module>-<version>.tar.gz
				#   family-<module>_<version>-*_all.deb
				for file in \
					"${family}"-[a-z]*-"${version}"-*.rpm \
					"${family}"-[a-z]*-"${version}".tar.gz \
					"${family}"-[a-z]*_"${version}"-*_all.deb
				do
					[ -e "$file" ] || continue

					# Skip separate packages for dedicated products like
					# Virtualmin or Cloudmin
					case "$file" in
						${family}-virtualmin-*|${family}-virtual-server-*|${family}-cloudmin-*|${family}-server-manager-*)
							# These should not be used to push the core time higher
							continue
							;;
					esac

					mtime=$(stat -L -c %Y -- "$file") || continue
					(( mtime > latest )) && latest=$mtime
				done

				# No regular modules of this version, then nothing to do
				(( latest == 0 )) && continue

				# Make the core just one second newer than its latest module to
				# put it right above its own modules
				touch -h -d "@$((latest + 1))" -- "$core"
			done
		}

		bump_family "webmin"
		bump_family "usermin"
	)
}

# Remove stable RPMs that no longer exist in any mapped RC repo
function prune_orphan_rpms_from_stable {
	local stable_home=$1
	local map_file=$2

	[[ -r "$map_file" ]] || {
		echo "Warning: cannot prune orphans; missing map file $map_file" >&2
		return 0
	}

	# Collect all RC roots that map to this stable_home
	local src_path rhs home_stable repo_stable gpg_key_stable
	local -a rc_roots=()

	while IFS= read -r line; do
		# Skip empty or comment lines
		[[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

		# Format: /rc/path=/stable/path:repo_label:gpg_email
		src_path=${line%%=*}
		rhs=${line#*=}
		IFS=':' read -r home_stable repo_stable gpg_key_stable <<< "$rhs"

		# Only care about entries pointing to this stable_home
		[[ "$home_stable" != "$stable_home" ]] && continue

		rc_roots+=("$src_path")
	done < "$map_file"

	# Nothing mapped? Then nothing to prune by this rule.
	[[ ${#rc_roots[@]} -gt 0 ]] || return 0

	# Build set of RPM basenames that still exist in ANY of the mapped RC roots
	declare -A allowed_rpms=()
	shopt -s nullglob
	local root f base
	for root in "${rc_roots[@]}"; do
		[[ -d "$root" ]] || continue
		for f in "$root"/*.rpm; do
			[[ -e "$f" ]] || continue
			base=$(basename -- "$f")
			allowed_rpms["$base"]=1
		done
	done

	# Now walk RPMs in stable_home and remove those not present in any RC root
	for f in "$stable_home"/*.rpm; do
		[[ -e "$f" ]] || continue
		# Skip symlinks here, as those are handled by the broken-symlink cleaner
		[[ -L "$f" ]] && continue

		base=$(basename -- "$f")

		if [[ -z ${allowed_rpms["$base"]+x} ]]; then
			echo "Removing orphaned stable RPM (not present in any mapped RC): $f" >&2
			rm -f -- "$f"
		fi
	done
	shopt -u nullglob
}

# Remove broken symlinks to packages and scripts at given repo root
function cleanup_broken_root_symlinks {
	local root=$1

	# Remove only broken symlinks to packages and scripts at the repo root, with
	# -xtype l, i.e. symlink whose target cannot be resolved
	find "$root" -maxdepth 1 -xtype l \( \
		-name '*.rpm'    -o \
		-name '*.deb'    -o \
		-name '*.tar.gz' -o \
		-name '*.sh' \
	\) -print -delete 2>/dev/null || true
}

# Promote RC repository to one or more stable repositories based on mapping file
function promote_to_stable {
	local rc_home=$1
	local map_file="${HOME}/.config/stable-map.txt"

	# Only promote rc.* dirs
	if [[ "$rc_home" != *"/rc."* ]]; then
		return 0
	fi

	if [[ ! -r "$map_file" ]]; then
		echo "Cannot promote to stable because mapping file $map_file not found or not readable" >&2
		return 0
	fi

	while IFS= read -r line; do
		# Skip empty or comment lines
		[[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

		# Format: /rc/path=/stable/path:repo_label:gpg_email
		local src_path rhs
		src_path=${line%%=*}
		rhs=${line#*=}

		# Only process entries whose source path matches the current rc_home
		[[ "$src_path" != "$rc_home" ]] && continue

		local home_stable repo_stable gpg_key_stable
		IFS=':' read -r home_stable repo_stable gpg_key_stable <<< "$rhs"

		if [[ -z "$home_stable" || -z "$repo_stable" ]]; then
			echo "Warning: malformed stable mapping line in $map_file: $line" >&2
			continue
		fi

		echo "Promoting pre-release repo:"
		echo "  from: $rc_home"
		echo "    to: $home_stable ($repo_stable)"
		echo "   key: ${gpg_key_stable:-$gpg_key}"

		# Symlink packages and scripts from current RC to stable
		promote_files_to_stable "$rc_home" "$home_stable"

		# Remove stable RPMs that no longer exist in any mapped RC repo
		prune_orphan_rpms_from_stable "$home_stable" "$map_file"

		# Clean up broken symlinks at stable repo root
		cleanup_broken_root_symlinks "$home_stable"

		# Re-run signing repo on the stable repo using specified GPG key if any
		if [[ -n "$gpg_key_stable" ]]; then
			GPG_KEY="$gpg_key_stable" \
				"$rundir/sign-repo.bash" "$home_stable" "$repo_stable"
		else
			"$rundir/sign-repo.bash" "$home_stable" "$repo_stable"
		fi

		# Now copy time stamps of RPMs from RC to stable
		copy_rpm_mtime_from_rc "$rc_home" "$home_stable"

	done < "$map_file"
}

# Promote files from RC repo to stable repo by symlinking, except RPMs which
# are copied to allow separate signing
function promote_files_to_stable {
	local src_home=$1
	local dst_home=$2

	mkdir -p "$dst_home"

	shopt -s nullglob
	
	# If uploaded list exists, only promote those basenames
	local list="$src_home/.uploaded_list"
	local -a only_files=()
	local filtered=0

	if [[ -s "$list" ]]; then
		# Take the same lock as writer
		{
			flock 9
			mapfile -t only_files <"$list"
			rm -f -- "$list"
		} 9>"$src_home/.uploaded_list.lock"

		(( ${#only_files[@]} )) && filtered=1
	fi

	local f base target
	for f in "$src_home"/*.rpm \
			 "$src_home"/*.deb \
			 "$src_home"/*.tar.gz \
			 "$src_home"/*.sh; do
		[[ -e "$f" ]] || continue
		# Only promote real files from RC, not symlinks
		[[ -L "$f" ]] && continue

		# Get basename
		base=$(basename -- "$f")
		
		# If we have a filtered list, skip anything not in it
		if (( filtered )); then
			local match=0 w
			for w in "${only_files[@]}"; do
				if [[ "$w" == "$base" ]]; then
					match=1
					break
				fi
			done
			(( !match )) && continue
		fi

		# Determine allowed target path
		target="$dst_home/$base"

		if [[ $f == *.rpm ]]; then
			# Copy RPMs, so stable can have its own signature
			if [[ -e "$target" || -L "$target" ]]; then
				cp -pf -- "$f" "$target"
			else
				cp -p -- "$f" "$target"
			fi
		else
			# Non-RPMs, keep symlink behavior
			if [[ -L "$target" ]]; then
				ln -sfn "$f" "$target"
			elif [[ -e "$target" ]]; then
				echo "Warning: $target exists and is not a symlink; leaving as-is" >&2
			else
				ln -s "$f" "$target"
			fi
		fi
	done
	shopt -u nullglob
}

# Main script routine
function main {
	cd "$repo_dir" || exit 1

	# Remove existing symlinks to latest packages
	remove_package_symlinks "$repo_dir"

	# Clean previous builds for testing repos only
	cleanup_testing_repo

	# Generate APT repository
	create_apt_repo

	# Create DNF/YUM repository
	create_dnf_repo

	# Re-create symlinks to latest packages
	regenerate_package_symlinks "$repo_dir"

	# Prioritize the core product package time so it sorts just above its own
	# modules
	prioritize_core_product "$repo_dir"

	# Promote from RC repo to one or more stable repos if requested
	if [[ -n "$promote_stable" ]]; then
		promote_to_stable "$repo_dir"
	fi
}

main
