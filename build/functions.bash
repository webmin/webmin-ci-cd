#!/usr/bin/env bash
# shellcheck disable=SC2181
# functions.bash (https://github.com/webmin/webmin-ci-cd)
# Copyright Ilia Ross <ilia@webmin.dev>
# Licensed under the MIT License
#
# Functions for the build process

# Set up SSH keys on the build machine
function setup_ssh {
	local key_path="$HOME/.ssh/id_rsa"

	# If SSH keys are already set up, skip this step
	if [ -f "$key_path" ]; then
		return 0
	fi

	# Use SSH command to generate new pair and take care of permissions
	cmd="ssh-keygen -t rsa -q -f \"$key_path\" \
		-N \"\" <<< \"y\"$VERBOSITY_LEVEL"
	eval "$cmd"
	rs=$?
	
	# Remove generated public key for consistency
	rm -f "$key_path.pub"
	
	if [[ -n "${CLOUD_SSH_PRV_KEY-}" ]]; then
		echo "Setting up SSH key .."
		postcmd $rs
		echo
		echo "$CLOUD_SSH_PRV_KEY" > "$key_path"
		return 0
	fi
}

# Set up SSH known hosts
function setup_ssh_known_hosts {
	local ssh_home="$HOME/.ssh"
	local ssh_known_hosts="$ssh_home/known_hosts"

	# Create .ssh directory if it doesn't exist
	mkdir -p "$ssh_home" && chmod 700 "$ssh_home"

	# Set up known_hosts from environment variable
	if [ -n "${CLOUD_UPLOAD_SSH_KNOWN_HOSTS-}" ]; then
		# Check if content already exists in known_hosts
		if ! grep -qF "$CLOUD_UPLOAD_SSH_KNOWN_HOSTS" "$ssh_known_hosts" 2>/dev/null; then
			echo "$CLOUD_UPLOAD_SSH_KNOWN_HOSTS" >> "$ssh_known_hosts"
			chmod 600 "$ssh_known_hosts"
		fi
	else
		# Return insecure fallback SSH options
		echo "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
	fi
}

# Upload to cloud
# Usage:
#   cloud_upload_list_delete=("remote_dir remote_file * [-_][0-9]*")
#   cloud_upload_list_upload=("$ROOT_REPOS/*" "$ROOT_REPOS/repodata")
#   cloud_upload cloud_upload_list_upload cloud_upload_list_delete
function cloud_upload {
	# Print new block only if defined
	if [ -n "${1-}" ]; then
		echo
	fi

	# Setup SSH keys on the build machine and configure known hosts if any
	local ssh_options ssh_warning_text
	ssh_options=$(setup_ssh_known_hosts)
	if [ -n "${ssh_options-}" ]; then
		ssh_warning_text=" (insecure)"
	fi
	
	# Setup SSH keys on the build machine
	setup_ssh

	# Delete files on remote if needed
	if [ -n "${2-}" ]; then
		echo "Deleting given files in $CLOUD_UPLOAD_SSH_HOST${ssh_warning_text-} .."
		local -n arr_del=$2
		local err=0
		for d in "${arr_del[@]}"; do
			if [ -n "$d" ]; then
				local remote_dir="${d%% *}"
				local remaining="${d#* }"
				local filename="${remaining%% *}"
				local patterns="${remaining#* }"
				local pre_pattern="${patterns%% *}"
				local post_pattern="${patterns#* }"
				local cmd1="ssh $ssh_options $CLOUD_UPLOAD_SSH_USER@"
				cmd1+="$CLOUD_UPLOAD_SSH_HOST \"cd '$remote_dir' && find . -maxdepth 1 "
				cmd1+="-name '${pre_pattern}${filename}${post_pattern}' -delete $VERBOSITY_LEVEL\""
				eval "$cmd1"
				if [ "$?" != "0" ]; then
					err=1
				fi
			fi
		done
		postcmd $err
		echo
	fi
	
	# Upload files to remote
	if [ -n "${1-}" ]; then
		echo "Uploading built files to $CLOUD_UPLOAD_SSH_HOST${ssh_warning_text-} .."
		local -n arr_upl=$1
		local err=0
		for u in "${arr_upl[@]}"; do
			if [ -n "$u" ]; then
				local cmd2="scp $ssh_options -r $u $CLOUD_UPLOAD_SSH_USER@"
				cmd2+="$CLOUD_UPLOAD_SSH_HOST:$CLOUD_UPLOAD_SSH_DIR/ $VERBOSITY_LEVEL"
				eval "$cmd2"
				if [ "$?" != "0" ]; then
					err=1
				fi
			fi
		done
		postcmd $err
		echo
	fi
}

# Sign and update repos metadata in remote
function cloud_sign_and_build_repos {
	# shellcheck disable=SC2034
	local repo_type="$1"
	# Setup SSH keys on the build machine and configure known hosts if any
	local ssh_options ssh_warning_text
	ssh_options=$(setup_ssh_known_hosts)
	if [ -n "${ssh_options-}" ]; then
		ssh_warning_text=" (insecure)"
	fi
	# Setup SSH keys on the build machine
	setup_ssh
	# Sign and update repos metadata directly on the remote server using the
	# sign-and-build-repos.bash script
	echo "Signing and updating repos metadata in $CLOUD_UPLOAD_SSH_HOST${ssh_warning_text-} .."
	local cmd1="ssh $ssh_options $CLOUD_UPLOAD_SSH_USER@"
	cmd1+="$CLOUD_UPLOAD_SSH_HOST \"$CLOUD_SIGN_BUILD_REPOS_CMD \
		'$CLOUD_UPLOAD_GPG_PASSPHRASE' '$CLOUD_UPLOAD_SSH_DIR' '$repo_type'\" \
		$VERBOSITY_LEVEL"
	eval "$cmd1"
	postcmd $?
	echo
}

# Post command func
function postcmd {
	local status="$1"
	local spaces="${2:-0}"

	# Create the padding with the specified number of spaces
	local padding
	padding=$(printf "%*s" "$spaces" "")

	if [ "$status" -ne 0 ]; then
		echo "${padding}.. failed"
		exit 1
	else
		echo "${padding}.. done"
	fi
}

# Get max number from array
function max {
	local max="$1"
	shift
	for value in "$@"; do
		if [[ "$value" -gt "$max" ]]; then
			max="$value"
		fi
	done
	echo "$max"
}

# Mkdir and children dirs
function make_dir {
	if [ ! -d "$1" ]; then
		mkdir -p "$1"
	fi
}

# Remove all content in dir
function purge_dir {
	for file in "$1"/*; do
		rm -rf "$file"
	done
}

# Remove dir
function remove_dir {
	if [ -d "$1" ]; then
		rm -rf "$1"
	fi
}

function get_remote_repo_tag {
	local repo_url="$1"

	# Fetch tags and extract the latest version
	git ls-remote --tags "$repo_url" 2>/dev/null | \
		awk -F/ '{print $3}' | \
		sed 's/\^{}//g' | \
		sort -V | \
		tail -n1 || {
			echo "Error: Failed to fetch tags from $repo_url." >&2
			return 1
		}
}

# Get latest tag version
function get_current_repo_tag {
	# shellcheck disable=SC2153
	local root_prod="$1"
	(
		cd "$root_prod" || exit 1
		ds=$(git ls-remote --tags --refs --sort="v:refname" origin | tail -n1 | \
			 awk '{print $2}' | sed 's|refs/tags/||')
		ds="${ds/v/}"
		echo "$ds"
	)
}

# Get product version based on version file
function get_product_version {
    local root_prod="$1"
    local version_file="$root_prod/version"

    if [[ -f "$version_file" ]]; then
        awk 'NF {print; exit}' "$version_file"
    else
        get_current_repo_tag "$root_prod"
    fi
}

# Get module version from module.info or Git tag
function get_module_version {
	local module_root="$1"
	local version=""
	
	# Check if module.info exists and extract version
	if [ -f "module.info" ]; then
		version=$(grep -E '^version=[0-9]+(\.[0-9]+)*' module.info | \
			head -n 1 | cut -d'=' -f2)
		version=$(echo "$version" | sed -E 's/^([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')
	fi

	# Fallback to get_current_repo_tag if no version found
	if [ -z "${version-}" ]; then
		version=$(get_current_repo_tag "$module_root")
	fi
	
	# Return version (assumes version is always found)
	echo "$version"
}

# Update version in module.info file
function update_module_version {
	local module_root="$1"
	local version="$2"
	local version_file="$module_root/module.info"
	if [ -f "$version_file" ]; then
		# Update version line
		sed -i "s/^version=[0-9]\+\(\.[0-9]\+\)*$/version=$version/" "$version_file"
	else
		echo "Error: module.info file is missing in $module_root" >&2
		return 1
	fi
}

# Get standard files excludes
function get_modules_exclude {
	local exclude
	exclude="--exclude .git --exclude .github --exclude .gitignore --exclude t"
	exclude+=" --exclude newfeatures --exclude CHANGELOG* --exclude README*"
	exclude+=" --exclude LICENSE* --exclude .travis.yml --exclude tmp"
	exclude+=" --exclude procmail-wrapper --exclude procmail-wrapper.c"
	echo "$exclude"
}

# Get latest commit time (with TZ)
function get_commit_timestamp {
	date -d "@$(git log -n1 --pretty='format:%ct')" +"%Y%m%d%H%M"
}

# Get latest commit time (with TZ) for the given repo
function get_repo_commit_timestamp {
	local repo_dir="$1"
	(
		cd "$repo_dir" || return 1
		get_commit_timestamp
	)
}

# Get latest commit date
function get_current_date {
	date +'%Y-%m-%d %H:%M:%S %z'
}

# Get latest commit date version
function get_product_latest_commit_timestamp {
	local root_prod="$1"
	local root_theme="$root_prod/authentic-theme"

	local theme_version
	local prod_version
	local max_prod
	local highest_version
	(
		theme_version=$(get_repo_commit_timestamp "$root_theme") || return 1
		prod_version=$(get_repo_commit_timestamp "$root_prod") || return 1
		max_prod=("$theme_version" "$prod_version")
		highest_version=$(max "${max_prod[@]}")
		echo "$highest_version"
	)
}

# Generate git clone command based on build type
generate_git_clone_cmd() {
	local repo_url="$1"
	local target_dir="$2"
	local tag_cmd

	# Check if building from tagged release
	if [ "$TESTING_BUILD" -eq 0 ]; then
		# Get the tag for this repo
		local tag
		tag=$(get_remote_repo_tag "$repo_url")
		
		# If we got a valid tag, use it
		if [ -n "$tag" ]; then
			tag_cmd="--branch $tag"
		fi
	fi

	echo "git clone --depth 1 ${tag_cmd-} $repo_url $target_dir $VERBOSITY_LEVEL"
}

# Clean git repo
function clean_git_repo {
	local repo_dir="$1"
	local oredir=">&2"
	if [[ $VERBOSE_MODE -eq 0 ]]; then
		oredir="$VERBOSITY_LEVEL"
	fi
	local cmd="git clean -fd $oredir && git reset --hard $oredir"
	local current_dir
	current_dir=$(pwd)
	echo "Current dir before: $current_dir >&2"
	# Change directory, run command, and return
	cd "$repo_dir" || return 1
	echo "Cleaning Git repo in $repo_dir ..  >&2"
	eval "$cmd"
	local rs=$?
	cd "$current_dir" || return 1
	echo "Current dir before: $current_dir >&2"
	echo "Result: $rs >&2"
	
	return $rs
}

# Pull project repo and theme
function make_packages_repos {
	local root_prod="$1"
	local prod="$2"
	local devel="$3"
	local cmd
	local reqrepo="webmin"
	local legacyrepo="webadmin"
	local repo="$reqrepo/$prod.git"
	local theme="authentic-theme"
	local lcmd="./bin/language-manager --mode=clean --yes $VERBOSITY_LEVEL_WITH_INPUT"
	
	# Clone repo
	if [ ! -d "$root_prod" ]; then
		cmd=$(generate_git_clone_cmd "$GIT_BASE_URL/$repo" "$root_prod")
		eval "$cmd"
		if [ "$?" != "0" ]; then
			return 1
		fi
	fi

	# Re-create legacy link unless it exists
	if [ ! -L "$ROOT_DIR/$legacyrepo" ]; then
		ln -fs "$ROOT_DIR/$reqrepo" "$ROOT_DIR/$legacyrepo"
	fi

	# Clone required repo
	if [ ! -d "$reqrepo" ]; then
		cmd=$(generate_git_clone_cmd "$WEBMIN_REPO" "$reqrepo")
		eval "$cmd"
		if [ "$?" != "0" ]; then
			return 1
		fi
		# Clean language files in the required product if testing build
		if [ "$devel" -eq 1 ]; then
			(
				cd "$ROOT_DIR/$reqrepo" || exit 1
				eval "$lcmd"
			)
		fi
	fi

	# Clean language files in the main product if testing build
	if [ "$devel" -eq 1 ]; then
		(
			cd "$ROOT_DIR/$prod" || exit 1
			eval "$lcmd"
		)
	fi

	# Clone theme
	if [ ! -d "$root_prod/$theme" ]; then
		cd "$root_prod" || exit 1
		repo="$reqrepo/$theme.git"
		cmd=$(generate_git_clone_cmd "$GIT_BASE_URL/$repo" "$theme")
		eval "$cmd"
		if [ "$?" != "0" ]; then
			return 1
		fi
	fi
	return 0
}

# Make module repo
function clone_module_repo {
	local module="$1"
	local target="$2"

	# Resolve module info mapping
	local names repo_name dir_name ver_pref deps_repo sub_dir 
	local cmd_clone_main cmd_clone_deps err
	names=$(resolve_module_info "$module")
	read -r repo_name dir_name ver_pref deps_repo sub_dir lic_id <<< "$names"

	# Clean up module directory
	remove_dir "$dir_name"

	# Check if module already exists via actions/checkout@
	if [[ -d "$HOME/work/$module" ]]; then
		cp -r "$HOME/work/$module" "$dir_name"
		clean_git_repo "$dir_name"
		printf "%s,%s,%s,%s" "$?" "$dir_name/$module" "$ver_pref" "$lic_id"
		return
	fi

	# Run cloning depending on the module type
	declare -a rs=()
	local target_dir="$dir_name"

	# Move directory if set
	if [[ -n "${sub_dir-}" ]]; then
		target_dir="$sub_dir"
	fi

	# Clone dependency first if exists
	if [[ -n "${deps_repo-}" ]]; then
		cmd_clone_deps=$(generate_git_clone_cmd "$target/$deps_repo.git" "$dir_name")
		eval "$cmd_clone_deps" || rs+=($?)
	fi

	# Clone main module
	cmd_clone_main=$(generate_git_clone_cmd "$target/$repo_name.git" "$target_dir")
	eval "$cmd_clone_main" || rs+=($?)

	# Check for errors
	err=0
	[ -n "${rs[*]}" ] && for r in "${rs[@]}"; do [ "$r" -gt 0 ] && { err=1; break; }; done

	# Return error code and new module directory name with version prefix
	printf "%s,%s,%s,%s" "$err" "$dir_name" "$ver_pref" "$lic_id"
}

# Get required build scripts from Webmin repo
function make_module_build_deps {
	# Create directory for build dependencies if it doesn't exist
	local build_deps_dir="${1:-$ROOT_DIR/build-deps}"
	if [ ! -d "$build_deps_dir" ]; then
		mkdir -p "$build_deps_dir"
	fi

	local required_files=(
		"create-module.pl"
		"lang_list.txt"
		"language-manager"
		"makemoduledeb.pl"
		"makemodulerpm.pl"
		"web-lib-funcs.pl"
	  )
	
	  local missing=false
	  for file in "${required_files[@]}"; do
		if [ ! -f "$build_deps_dir/$file" ]; then
		  missing=true
		  break
		fi
	  done
	
	  if $missing; then
		echo "Downloading build dependencies .."
	
		local temp_dir
		temp_dir="$(mktemp -d)"
		cd "$temp_dir" || exit 1
	
		local cmd="git clone --depth 1 --filter=blob:none --sparse \
			$WEBMIN_REPO.git $VERBOSITY_LEVEL"
		eval "$cmd"
		local rs1=$?
	
		cd webmin || exit 1
	
		# Copy required files to build-deps directory
		cp -f makemoduledeb.pl makemodulerpm.pl create-module.pl web-lib-funcs.pl \
			lang_list.txt "$build_deps_dir/"
	
		# Sparse checkout language-manager and copy it
		cmd="git sparse-checkout set --no-cone / /bin/language-manager $VERBOSITY_LEVEL"
		eval "$cmd"
		local rs2=$?

		# Check if clone was successful
		local final_rs=0
		if [ $rs1 -ne 0 ] || [ $rs2 -ne 0 ]; then
			final_rs=1
		fi
		postcmd $final_rs
	
		cp -f bin/language-manager "$build_deps_dir/"
	
		cd "$ROOT_DIR" || exit 1
		remove_dir "$temp_dir"
	fi
}

# Adjust module filename depending on package type
function adjust_module_filename {
	local repo_dir="$1"
	local package_type="$2"
	local failed=0
	local temp_file

	# Create a secure temporary file
	temp_file=$(mktemp) || { echo "Failed to create temporary file"; return 1; }

	# Find and adjust files based on the package type
	case "$package_type" in
	rpm)
		find "$repo_dir" -type f -name "*.rpm" > "$temp_file"
		;;
	deb)
		find "$repo_dir" -type f -name "*.deb" > "$temp_file"
		;;
	esac

	while read -r file; do
		base_name=$(basename "$file")
		dir_name=$(dirname "$file")
		local new_name

		case "$package_type" in
		rpm)
			# Handle RPM logic
			if [[ "$base_name" == webmin-* ]]; then
				new_name="${base_name/webmin-/wbm-}"
			elif [[ "$base_name" != wbm-* ]]; then
				new_name="wbm-$base_name"
			else
				continue
			fi
			;;
		deb)
			# Handle DEB logic
			if [[ "$base_name" != webmin-* ]]; then
				new_name="webmin-$base_name"
			else
				continue
			fi
			;;
		esac

		# Perform rename and check for failure
		if ! eval "mv \"$file\" \"$dir_name/$new_name\" \
		   $VERBOSITY_LEVEL_WITH_INPUT"; then
			failed=1
		fi
	done < "$temp_file"

	# Clean up the temporary file
	rm -f "$temp_file"

	# Return success or failure
	return $failed
}

# Retrieve the RPM module epoch from the provided list
function get_rpm_module_epoch {
	local module="$1"
	local script_dir
	local epoch_file
	script_dir="${BASH_SOURCE[0]%/*}"
	epoch_file="$script_dir/rpm-modules-epoch.txt"
	if [ ! -f "$epoch_file" ]; then
		echo "Error: $epoch_file not found" >&2
		return 1
	fi
	awk -F= -v module="$module" '$1 == module {print $2; exit}' "$epoch_file"
}

# Gets module mappings and dependencies from file
#  Format in file:
#    module=dir_name,[ver_pref],[deps_repo],[sub_dir],[license]
function resolve_module_info {
	local module_name="$1"
	local mapping_file="${BASH_SOURCE[0]%/*}/modules-mapping.txt"
	
	# Check if mapping file exists
	if [[ ! -f "$mapping_file" ]]; then
		echo "$module_name $module_name"
		return 0
	fi
	
	# Read entire file content
	local content
	content=$(<"$mapping_file")
	
	# Process the mapping content
	while IFS='=' read -r source_name target_info; do
		if [[ "$source_name" == "$module_name" ]]; then
			# Split comma-separated values into array
			IFS=',' read -r dir_name ver_pref deps_repo sub_dir lic_id <<< "$target_info"
			echo "$source_name $dir_name $ver_pref $deps_repo $sub_dir $lic_id"
			return 0
		fi
	done <<< "$content"

	# Return original name with empty optional values
	echo "$module_name $module_name"
}

# Function to get related modules
get_related_modules() {
	local module="$1"
	local mapping_file="module-groups.txt"

	# Check if the file exists
	if [ ! -f "$mapping_file" ]; then
		echo "$module"
		return
	fi

	# Loop through the file to find related modules
	while IFS='=' read -r key value; do
		if [ "$key" = "$module" ]; then
			echo "$module $value"
			return
		elif [ "$value" = "$module" ]; then
			echo "$module $key"
			return
		fi
	done < "$mapping_file"

	# Default to just the module if no match found
	echo "$module"
}

# Cleans up package files by keeping only the latest version of each package
# 
# Usage:
#   cleanup_packages [path] [max_depth] [extensions]
#
# Parameters:
#   path        Directory to process (default: current directory)
#   max_depth   Maximum depth for directory traversal (default: 1)
#   extensions  Space-separated list of file extensions to process
#               (default: all extensions found)
#
# Features:
#   - Handles version formats: X.Y, X.Y.Z, X.Y.YYYYMMDDHHMM
#   - Prioritizes files with '-latest' or '_latest' in name
#   - Processes files by extension and base package name
#   - Skips hidden directories (like .git)
#   - Handles both hyphen (-) and underscore (_) package naming
#
# Examples:
#   cleanup_packages                     # Current directory, all extensions
#   cleanup_packages /path/to/dir        # Specific path
#   cleanup_packages . 2                 # Current directory, depth 2
#   cleanup_packages . 1 "rpm deb"       # Only rpm and deb files
#   cleanup_packages /path 3 "rpm deb"   # Path, depth 3, specific extensions
function cleanup_packages {
	local search_path="${1:-.}" # Default to current directory if not set
	local max_depth="${2:-1}"   # Default to 1 if not specified
	local extensions_arg="$3"   # Optional extensions list (space-separated)

	# Validate input path
	if [[ ! -d "$search_path" ]]; then
		echo "Error: Directory '$search_path' does not exist"
		return 1
	fi

	is_latest() {
		local filename="$1"
		[[ $filename =~ [-_]latest[._] ]] && return 0
		return 1
	}

	get_base_package() {
		local filename="$1"
		# Remove extension and release number
		filename=${filename%.*}  # Remove any extension
		filename=${filename%_all}
		filename=${filename%.noarch}
		
		# Extract edition if present
		local edition
		if [[ $filename =~ [._-]([a-zA-Z0-9_]+)$ ]]; then
			edition="${BASH_REMATCH[1]}"
			# Remove the detected edition from filename
			filename=${filename%.*"${edition}"}
			filename=${filename%-"${edition}"}
		fi
		
		filename=${filename%-[0-9]}
		filename=${filename%-[0-9][0-9]}
		
		# Extract base package name
		local base
		if [[ $filename =~ ^(.*)-[0-9]+(\.[0-9]+)* ]] || 
		   [[ $filename =~ ^(.*)_[0-9]+(\.[0-9]+)* ]] || 
		   [[ $filename =~ ^(.*)-latest ]] || 
		   [[ $filename =~ ^(.*)_latest ]]; then
			base="${BASH_REMATCH[1]}"
		else
			base="$filename"
		fi
		
		# Append edition to base name if present
		if [ -n "${edition-}" ]; then
			echo "${base}-${edition}"
		else
			echo "$base"
		fi
	}

	get_version() {
		local filename="$1"
		# Extract version number and release number
		if [[ $filename =~ [^0-9]([0-9]+(\.[0-9]+[\.0-9]*)?)-([0-9]+) ]]; then
			# Combine version and release with a dot for proper version comparison
			echo "${BASH_REMATCH[1]}.${BASH_REMATCH[3]}"
		elif [[ $filename =~ [^0-9]([0-9]+(\.[0-9]+[\.0-9]*)?)[^0-9] ]]; then
			# If no release number, just use the version
			echo "${BASH_REMATCH[1]}"
		fi
	}

	version_gt() {
		test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
	}

	process_group() {
		local files="$1"
		local latest_ver="0"
		local latest_file=""
		
		# Convert string to array
		IFS=' ' read -r -a file_array <<< "$files"
		
		# Find latest version
		for file in "${file_array[@]}"; do
			[[ -z "${file-}" ]] && continue
			
			# If this is a latest version, keep it and skip other checks
			if is_latest "$file"; then
				latest_file="$file"
				break
			fi
			
			version=$(get_version "$file")
			if [ -n "${version-}" ]; then
				if [ -z "${latest_file-}" ] ||
					version_gt "$version" "$latest_ver"; then
					latest_ver="$version"
					latest_file="$file"
				fi
			fi
		done
		
		# Remove older versions
		for file in "${file_array[@]}"; do
			[[ -z "${file-}" ]] && continue
			if [ "$file" != "$latest_file" ]; then
				if [ -f "$file" ]; then
					rm "$file" 2>/dev/null || true
				fi
			fi
		done
	}

	# Process each directory up to max_depth, excluding .git directories
	find "$search_path" -maxdepth "$max_depth" -type d -not -path "*/\.*" | \
	  while read -r dir; do
		# Change to directory
		pushd "$dir" >/dev/null || continue

		# Initialize extensions array
		declare -A extensions

		if [ -n "${extensions_arg-}" ]; then
			# Use provided extensions
			for ext in $extensions_arg; do
				extensions["$ext"]=1
			done
		else
			# Find all unique extensions in the directory
			for file in *.*; do
				[[ -f "$file" ]] || continue
				ext="${file##*.}"
				[[ -n "${ext-}" ]] && extensions["$ext"]=1
			done
		fi

		# Group files by base package name and extension
		declare -A package_groups

		# Read all files with detected extensions
		for ext in "${!extensions[@]}"; do
			for file in *."$ext"; do
				[[ -f "$file" ]] || continue
				
				base_pkg=$(get_base_package "$file")
				[[ -z "${base_pkg-}" ]] && continue
				
				package_groups["$base_pkg.$ext"]+=" $file"
			done
		done

		# Process all package groups
		for pkg_ext in "${!package_groups[@]}"; do
			process_group "${package_groups[$pkg_ext]}"
		done

		# Return to original directory
		popd >/dev/null || exit 1
	done
}

# Build native DEB and RPM packages for Linux systems
#
# This function builds both DEB and RPM packages for specified architectures.
# It handles compilation of C source files if provided and supports setting
# permissions, dependencies, and package metadata.
#
# Usage:
#   build_native_package \
#     --architectures x64 arm64 \
#     --files program.c \
#     --target-dir /path/to/output \
#     --base-name my-package-name \
#     [additional options]
#
# Required options:
#   --target-dir      Output directory for built packages
#   --base-name       Base name for the package
#   --files           One or more files to include in the package
#
# Optional:
#   --architectures  Target architectures (default: x64)
#                    Supported: x64 (amd64/x86_64), arm64 (arm64/aarch64), x86 (i386/i686)
#   --version        Package version (default: 1.0)
#   --release        Release number (default: 1)
#   --permissions    File permissions (default: 755)
#   --epoch          Package epoch
#   --license        Package license (default: GPLv3)
#   --maintainer     Package maintainer (default: $BUILDER_PACKAGE_NAME <$BUILDER_MODULE_EMAIL>)
#   --vendor         Package vendor (default: $BUILDER_PACKAGE_NAME)
#   --homepage       Package homepage URL
#   --description    Package description
#   --summary        Package summary (short description)
#   --group          Package group
#   --depends        Package dependencies
#   --section        Package section for DEB (default: admin)
#   --priority       Package priority for DEB (default: optional)
#   --provides       Package provides
#   --conflicts      Package conflicts
#   --replaces       Package replaces/obsoletes
#   --recommends     Recommended packages
#   --suggests       Suggested packages
#   --breaks         Packages this package breaks
#   --skip           Skip building the package of the specified type
#
# Returns:
#   0 on success, 1 on failure
function build_native_package {
	# Default values
	local arches=()
	declare -A deb_arch_map=(
		["x64"]="amd64"
		["arm64"]="arm64"
		["x86"]="i386"
		["noarch"]="all"
	)
	declare -A rpm_arch_map=(
		["x64"]="x86_64"
		["arm64"]="aarch64"
		["x86"]="i686"
		["noarch"]="noarch"
	)
	local version="1.0"
	local release="1"
	local license="GPLv3"
	local maintainer="$BUILDER_PACKAGE_NAME <$BUILDER_MODULE_EMAIL>"
	local vendor="$BUILDER_PACKAGE_NAME"
	local homepage
	local description
	local summary
	local group
	local target_dir
	local base_name
	local epoch
	local permissions="755"
	local section="admin"
	local priority="optional"
	local -a files=()
	local -a depends=()
	local -a provides=()
	local -a conflicts=()
	local -a replaces=()
	local -a recommends=()
	local -a suggests=()
	local -a breaks=()
	local spec_files_depth=1
	local skip
	local cmd
	local status=0

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case $1 in
			--architectures)
				shift
				while [[ $# -gt 0 ]] && [[ "$1" != --* ]]; do
					arches+=("$1")
					shift
				done
				;;
			--files)
				shift
				while [[ $# -gt 0 ]] && [[ "$1" != --* ]]; do
					files+=("$1")
					shift
				done
				;;
			--permissions)
				permissions="$2"
				shift 2
				;;
			--target-dir)
				target_dir="$2"
				shift 2
				;;
			--base-name)
				base_name="$2"
				shift 2
				;;
			--version)
				version="$2"
				shift 2
				;;
			--release)
				release="$2"
				shift 2
				;;
			--epoch)
				epoch="$2"
				shift 2
				;;
			--license)
				license="$2"
				shift 2
				;;
			--maintainer)
				maintainer="$2"
				shift 2
				;;
			--vendor)
				vendor="$2"
				shift 2
				;;
			--homepage)
				homepage="$2"
				shift 2
				;;
			--description)
				description="$2"
				shift 2
				;;
			--summary)
				summary="$2"
				shift 2
				;;
			--group)
				group="$2"
				shift 2
				;;
			--depends)
				shift
				while [[ $# -gt 0 ]] && [[ "$1" != --* ]]; do
					depends+=("$1")
					shift
				done
				;;
			--section)
				section="$2"
				shift 2
				;;
			--priority)
				priority="$2"
				shift 2
				;;
			--provides)
				shift
				while [[ $# -gt 0 ]] && [[ "$1" != --* ]]; do
					provides+=("$1")
					shift
				done
				;;
			--conflicts)
				shift
				while [[ $# -gt 0 ]] && [[ "$1" != --* ]]; do
					conflicts+=("$1")
					shift
				done
				;;
			--replaces)
				shift
				while [[ $# -gt 0 ]] && [[ "$1" != --* ]]; do
					replaces+=("$1")
					shift
				done
				;;
			--recommends)
				shift
				while [[ $# -gt 0 ]] && [[ "$1" != --* ]]; do
					recommends+=("$1")
					shift
				done
				;;
			--suggests)
				shift
				while [[ $# -gt 0 ]] && [[ "$1" != --* ]]; do
					suggests+=("$1")
					shift
				done
				;;
			--breaks)
				shift
				while [[ $# -gt 0 ]] && [[ "$1" != --* ]]; do
					breaks+=("$1")
					shift
				done
				;;
			--spec-files-depth)
				spec_files_depth="$2"
				shift 2
				;;
			--skip)
				skip="$2"
				shift 2
				;;
			*)
				echo "Unknown parameter: $1"
				return 1
				;;
		esac
	done

	# If no architectures specified, use defaults based on host architecture
	if [ ${#arches[@]} -eq 0 ]; then
		arches=("x64")
	fi

	# Function to map generic arch to specific format
	get_deb_arch() {
		local arch="$1"
		echo "${deb_arch_map[$arch]:-$arch}"
	}

	get_rpm_arch() {
		local arch="$1"
		echo "${rpm_arch_map[$arch]:-$arch}"
	}

	# Validate required parameters
	if [ -z "${target_dir-}" ] || [ -z "${base_name-}" ]; then
		echo "Error: --target-dir and --base-name are required"
		return 1
	fi

	# Check for noarch with C files
	if [[ " ${arches[*]} " =~ " noarch " ]]; then
		for file in "${files[@]}"; do
			if [[ "$file" =~ \.c$ ]]; then
				echo "Error: Cannot build noarch package with C source files"
				return 1
			fi
		done
	fi

	# Function to build DEB package
	build_deb() {
		local arch="$1"
		local work_dir
		work_dir="$(mktemp -d)"
		local pkg_name="${base_name}_${version}-${release}_${arch}"
		local status=0
		
		echo "Building package '$pkg_name' for arch $arch .."

		# Create package structure
		cmd="mkdir -p '$work_dir/DEBIAN'"
		eval "$cmd" || return 1
		
		# Process files
		for file in "${files[@]}"; do
			if [[ "$file" == *.c ]]; then
				local basename
				basename=$(basename "$file" .c)
				echo "  Compiling $file .."
				cmd="mkdir -p '$work_dir/usr/bin'"
				eval "$cmd" || return 1
				cmd="gcc -o '$work_dir/usr/bin/$basename' '$file' $VERBOSITY_LEVEL"
				eval "$cmd"
				postcmd $? 2
				
				echo "  Setting permissions for $basename .."
				cmd="chmod $permissions '$work_dir/usr/bin/$basename'"
				eval "$cmd"
				postcmd $? 2
			elif [ -d "$file" ]; then
				echo "  Preparing directory $file .."
				cmd="cp -r '$file'/* '$work_dir/'"
				eval "$cmd"
				postcmd $? 2
			else
				echo "  Preparing file $file .."
				local dir
				dir=$(dirname "$file")
				cmd="mkdir -p '$work_dir/$dir'"
				eval "$cmd" || return 1
				cmd="cp '$file' '$work_dir/$dir/'"
				eval "$cmd"
				postcmd $? 2
			fi
		done
		
	   # Create control file
		{
			echo "Package: $base_name"
			echo "Version: $version-$release"
			echo "Architecture: $arch"
			echo "Maintainer: $maintainer"
			echo "Section: $section"
			echo "Priority: $priority"
			[ ${#depends[@]} -gt 0 ] && echo "Depends: $(printf "%s, " "${depends[@]}" | sed 's/, $//')"
			[ ${#recommends[@]} -gt 0 ] && echo "Recommends: $(printf "%s, " "${recommends[@]}" | sed 's/, $//')"
			[ ${#suggests[@]} -gt 0 ] && echo "Suggests: $(printf "%s, " "${suggests[@]}" | sed 's/, $//')"
			[ ${#provides[@]} -gt 0 ] && echo "Provides: $(printf "%s, " "${provides[@]}" | sed 's/, $//')"
			[ ${#conflicts[@]} -gt 0 ] && echo "Conflicts: $(printf "%s, " "${conflicts[@]}" | sed 's/, $//')"
			[ ${#replaces[@]} -gt 0 ] && echo "Replaces: $(printf "%s, " "${replaces[@]}" | sed 's/, $//')"
			[ ${#breaks[@]} -gt 0 ] && echo "Breaks: $(printf "%s, " "${breaks[@]}" | sed 's/, $//')"
			[ -n "${homepage-}" ] && echo "Homepage: $homepage"
			echo "Description: ${summary:-$description}"
			if [ -n "${summary-}" ] && [ -n "${description-}" ]; then
				echo "$description" | fmt -w 74 | sed 's/^/ /'
			fi

		} > "$work_dir/DEBIAN/control"

		# Build package
		echo "  Building package .."
		cmd="fakeroot dpkg-deb --verbose --build '$work_dir' '$target_dir/${pkg_name}.deb' $VERBOSITY_LEVEL"
		eval "$cmd"
		status=$?
		postcmd $status 2

		postcmd $status
		
		# Cleanup
		rm -rf "$work_dir"
		
		return $status
	}

	# Function to build RPM package
	build_rpm() {
		local arch="$1"
		local work_dir
		work_dir="$(mktemp -d)"
		local pkg_name="${base_name}-${version}-${release}.${arch}"
		local status=0
		
		echo "Building package '$pkg_name' for arch $arch .."
		
		# Create RPM build structure
		cmd="mkdir -p '$work_dir'/{BUILD,RPMS,SOURCES,SPECS,SRPMS}"
		eval "$cmd" || return 1
		
		# Process files
		for file in "${files[@]}"; do
			if [[ "$file" == *.c ]]; then
				local basename
				basename=$(basename "$file" .c)
				echo "  Compiling $file .."
				cmd="mkdir -p '$work_dir/BUILD/usr/bin'"
				eval "$cmd" || return 1
				cmd="gcc -o '$work_dir/BUILD/usr/bin/$basename' '$file' $VERBOSITY_LEVEL"
				eval "$cmd"
				postcmd $? 2
				
				echo "  Setting permissions for $basename .."
				cmd="chmod $permissions '$work_dir/BUILD/usr/bin/$basename'"
				eval "$cmd"
				postcmd $? 2
			elif [ -d "$file" ]; then
				echo "  Preparing directory $file .."
				cmd="cp -r '$file' '$work_dir/BUILD/'"
				eval "$cmd"
				postcmd $? 2
			else
				echo "  Preparing file $file .."
				local dir
				dir=$(dirname "$file")
				cmd="mkdir -p '$work_dir/BUILD/$dir'"
				eval "$cmd" || return 1
				cmd="cp '$file' '$work_dir/BUILD/$dir/'"
				eval "$cmd"
				postcmd $? 2
			fi
		done
		
		# Create spec file
		{
			echo "%define _build_id_links none"
			[ -n "${summary-}" ] && echo "Summary: $summary"
			echo "Name: $base_name"
			echo "Version: $version"
			echo "Release: $release"
			[ -n "${epoch-}" ] && echo "Epoch: $epoch"
			echo "License: $license"
			[ -n "${group-}" ] && echo "Group: $group"
			echo "Vendor: $vendor"
			[ -n "${homepage-}" ] && echo "URL: $homepage"
			[ ${#depends[@]} -gt 0 ] && echo "Requires: $(IFS=' '; echo "${depends[*]}")"
			[ ${#recommends[@]} -gt 0 ] && echo "Recommends: $(IFS=' '; echo "${recommends[*]}")"
			[ ${#suggests[@]} -gt 0 ] && echo "Suggests: $(IFS=' '; echo "${suggests[*]}")"
			[ ${#conflicts[@]} -gt 0 ] && echo "Conflicts: $(IFS=' '; echo "${conflicts[*]}")"
			[ ${#breaks[@]} -gt 0 ] && echo "Conflicts: $(IFS=' '; echo "${breaks[*]}")"
			[ ${#provides[@]} -gt 0 ] && echo "Provides: $(IFS=' '; echo "${provides[*]}")"
			[ ${#replaces[@]} -gt 0 ] && echo "Obsoletes: $(IFS=' '; echo "${replaces[*]}")"
			echo "AutoReqProv: no"
			echo "BuildArch: $arch"
			echo
			echo "%description"
			if [ -n "${description-}" ]; then
				echo "$description" | fmt -w 74
			elif [ -n "${summary-}" ]; then
				echo "$summary"
			fi
			echo
			
			# Install section
			echo "%install"
			echo "rm -rf %{buildroot}"
			echo "mkdir -p %{buildroot}"
			for file in "${files[@]}"; do
				if [[ "$file" == *.c ]]; then
					echo "mkdir -p %{buildroot}%{_bindir}"
					echo "cp -f %{_builddir}/usr/bin/* %{buildroot}%{_bindir}/"
				elif [ -d "$file" ]; then
					echo "cp -R '$file'/* %{buildroot}/"
				fi
			done
			
			# Files section
			echo "%files"
			echo "%defattr(-,root,root)"
			for file in "${files[@]}"; do
				if [[ "$file" == *.c ]]; then
					basename=$(basename "$file" .c)
					echo "%attr($permissions,root,root) %{_bindir}/$basename"
				elif [ -d "$file" ]; then
					find "$file" -mindepth 1 -type d | while read -r dir; do
						clean_dir=${dir#"$file"/}
						# Avoid clash with filesystem package directories
						slash_count=${clean_dir//[^\/]/}
						slash_count=${#slash_count}
						if (( slash_count > spec_files_depth )); then
							echo "%dir /$clean_dir"
						fi
					done
					find "$file" -type f -o -type l | while read -r f; do
						clean_file=${f#"$file"/}
						# Check if files will be compressed
						if [[ "$clean_file" =~ /man[0-9]/ ]]; then
							clean_file="${clean_file}.gz"
						fi
						echo "%attr(-,root,root) /$clean_file"
					done
				fi
			done
			
			echo
			echo "%clean"
			echo "rm -rf %{buildroot}"
		} > "$work_dir/SPECS/${base_name}.spec"
		
		# Build package
		echo "  Building package .."
		cmd="rpmbuild --verbose --define '_topdir $work_dir' --target $arch-linux -bb '$work_dir/SPECS/${base_name}.spec' $VERBOSITY_LEVEL"
		eval "$cmd"
		status=$?
		postcmd $status 2
		
		if [ $status -eq 0 ]; then
			# Move the built package
			echo "  Moving package to target directory .."
			cmd="mv '$work_dir/RPMS/$arch/${pkg_name}.rpm' '$target_dir/'"
			eval "$cmd"
			status=$?
			postcmd $status 2
		fi

		postcmd $status
		
		# Cleanup
		rm -rf "$work_dir"
		
		return $status
	}

	# Build for all architectures
	cmd="mkdir -p '$target_dir'"
	eval "$cmd"
	status=$?
	local date
	date=$(get_current_date)

	if [ -z "${skip-}" ] || [ "$skip" != "deb" ]; then
		# Build DEB packages
		echo "************************************************************************"
		echo "        build start date: $date                                         "
		echo "          package format: DEB                                           "
		echo "            package name: $base_name                                    "
		echo "         package version: $version-$release                             "
		echo "           architectures: $(for arch in "${arches[@]}"; do echo -n "${deb_arch_map[$arch]} "; done)"
		echo "************************************************************************"

		for arch in "${arches[@]}"; do
			local deb_arch
			deb_arch=$(get_deb_arch "$arch")
			if [ -n "${deb_arch-}" ]; then
				build_deb "$deb_arch"
				[ $? -ne 0 ] && status=1
			fi
		done
	fi

	if [ -z "${skip-}" ] || [ "$skip" != "rpm" ]; then
		# Build RPM packages
		echo "************************************************************************"
		echo "        build start date: $date                                         "
		echo "          package format: RPM                                           "
		echo "            package name: $base_name                                    "
		echo "         package version: ${epoch:+$epoch:}$version-$release            "
		echo "           architectures: $(for arch in "${arches[@]}"; do echo -n "${rpm_arch_map[$arch]} "; done)"
		echo "************************************************************************"
		for arch in "${arches[@]}"; do
			local rpm_arch
			rpm_arch=$(get_rpm_arch "$arch")
			if [ -n "${rpm_arch-}" ]; then
				if [ "$rpm_arch" == "$(uname -m)" ] || [ "$rpm_arch" == "noarch" ]; then
					build_rpm "$rpm_arch"
					[ $? -ne 0 ] && status=1
				else
					echo "Skipping package build for arch $arch .."
					echo ".. not supported"
				fi
			fi
		done
	fi

	return $status
}

# Parses Debian control files and extracts package metadata. Supports both
# regular and testing builds, where testing builds append timestamp to version.
#
# Usage: parse_debian_control directory [testing]
#   directory:  Path containing .ctl files
#   testing: If set, appends timestamp to version for testing builds
#
# Returns: Package metadata in the order of:
#   package, version, depends, recommends, suggests, replaces
function parse_debian_control() {
	local ctl_dir="${1:?'Directory path required'}"
	local testing="${2:-}"

	# Validate directory and check for .ctl files
	[[ -d "$ctl_dir" ]] || { echo "Directory not found: $ctl_dir" >&2; return 1; }
	shopt -s nullglob
	local ctl_files=("$ctl_dir"/*.ctl)
	[[ ${#ctl_files[@]} -gt 0 ]] || { echo "No .ctl files found" >&2; return 1; }

	for ctl_file in "${ctl_files[@]}"; do
		# Initialize package metadata fields
		local package version depends recommends suggests replaces
		
		while IFS= read -r line; do
			case "${line,,}" in  # Case-insensitive matching
				package:*)    package=${line#*: }    ;;
				version:*)    
					version=${line#*: }
					version=${version%-*}            # Strip revision
					;;
				depends:*)    depends=${line#*: }    ;;
				recommends:*) recommends=${line#*: } ;;
				suggests:*)   suggests=${line#*: }   ;;
				replaces:*)   replaces=${line#*: }   ;;
			esac
		done < "$ctl_file"

		# Skip if required fields are missing
		[[ -n "${package:-}" && -n "${version:-}" ]] || continue

		# Append timestamp for testing builds
		if [[ -n "$testing" && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			version="${version%.*}.$(date +%Y%m%d%H%M)"
		fi

		printf '%s\n' "${package:-}" "${version:-}" "${depends:-}" "${recommends:-}" "${suggests:-}" "${replaces:-}"
	done
}

# Function to create needed symlinks for the build
function create_symlinks {
	ln -fs "/usr/bin/perl" "/usr/local/bin/perl"
}
