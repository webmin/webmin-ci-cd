#!/usr/bin/env bash
# shellcheck disable=SC2181
# functions.bash
# Copyright Ilia Ross <ilia@webmin.dev>
# Build functions for the build process

# Set up SSH keys on the build machine
function setup_ssh() {
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
    
    if [[ -n "${CLOUD_SSH_PRV_KEY:-}" ]]; then
        echo "Setting up SSH key .."
        postcmd $rs
        echo
        echo "$CLOUD_SSH_PRV_KEY" > "$key_path"
        return 0
    fi
}

# Set up SSH known hosts
function setup_ssh_known_hosts() {
    local ssh_home="$HOME/.ssh"
    local ssh_known_hosts="$ssh_home/known_hosts"

    # Create .ssh directory if it doesn't exist
    mkdir -p "$ssh_home" && chmod 700 "$ssh_home"

    # Set up known_hosts from environment variable
    if [ -n "$CLOUD_UPLOAD_SSH_KNOWN_HOSTS" ]; then
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
function cloud_upload() {
    # Print new block only if defined
    if [ -n "$1" ]; then
        echo
    fi

    # Setup SSH keys on the build machine and configure known hosts if any
    local ssh_options ssh_warning_text
    ssh_options=$(setup_ssh_known_hosts)
    if [ -n "$ssh_options" ]; then
        ssh_warning_text=" (insecure)"
    fi
    
    # Setup SSH keys on the build machine
    setup_ssh

    # Delete files on remote if needed
    if [ -n "$2" ]; then
        echo "Deleting given files in $CLOUD_UPLOAD_SSH_HOST$ssh_warning_text .."
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
    if [ -n "$1" ]; then
        echo "Uploading built files to $CLOUD_UPLOAD_SSH_HOST$ssh_warning_text .."
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
function cloud_sign_and_build_repos() {
    # shellcheck disable=SC2034
    local repo_type="$1"
    # Setup SSH keys on the build machine and configure known hosts if any
    local ssh_options ssh_warning_text
    ssh_options=$(setup_ssh_known_hosts)
    if [ -n "$ssh_options" ]; then
        ssh_warning_text=" (insecure)"
    fi
    # Setup SSH keys on the build machine
    setup_ssh
    # Sign and update repos metadata in remote
    echo "Signing and updating repos metadata in $CLOUD_UPLOAD_SSH_HOST$ssh_warning_text .."
    local cmd1="ssh $ssh_options $CLOUD_UPLOAD_SSH_USER@"
    cmd1+="$CLOUD_UPLOAD_SSH_HOST \"$CLOUD_SIGN_BUILD_REPOS_CMD\" $VERBOSITY_LEVEL"
    eval "$cmd1"
    postcmd $?
    echo
}

# Post command func
function postcmd() {
    if [ "$1" != "0" ]; then
        echo ".. failed"
        exit 1
    else
        echo ".. done"
    fi
}

# Get max number from array
function max() {
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
function make_dir() {
    if [ ! -d "$1" ]; then
        mkdir -p "$1"
    fi
}

# Remove all content in dir
function purge_dir() {
    for file in "$1"/*; do
        rm -rf "$file"
    done
}

# Remove dir
function remove_dir() {
    if [ -d "$1" ]; then
        rm -rf "$1"
    fi
}

# Get latest tag version
function get_current_repo_tag() {
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

function get_module_version() {
    local module_root="$1"
    local version=""
    
    # Check if module.info exists and extract version
    if [ -f "module.info" ]; then
        version=$(grep -E '^version=[0-9]+(\.[0-9]+)*' module.info | \
            head -n 1 | cut -d'=' -f2)
        version=$(echo "$version" | sed -E 's/^([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')
    fi

    # Fallback to get_current_repo_tag if no version found
    if [ -z "$version" ]; then
        version=$(get_current_repo_tag "$module_root")
    fi
    
    # Return version (assumes version is always found)
    echo "$version"
}

function get_modules_exclude() {
    local exclude
    exclude="--exclude .git --exclude .github --exclude .gitignore --exclude t"
    exclude+=" --exclude newfeatures --exclude CHANGELOG --exclude README.md"
    exclude+=" --exclude LICENSE --exclude .travis.yml --exclude tmp"
    echo "$exclude"
}

function update_module_version() {
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

# Get latest commit date
function get_current_date() {
    date +'%Y-%m-%d %H:%M:%S %z'
}

# Get latest commit date version
function get_latest_commit_date_version() {
    local theme_version
    local prod_version
    local max_prod
    local highest_version
    local root_prod="$1"
    local root_theme="$root_prod/authentic-theme"
    (
        cd "$root_theme" || exit 1
        theme_version=$(git log -n1 --pretty='format:%cd' --date=format:'%Y%m%d%H%M')
        cd "$root_prod" || exit 1
        prod_version=$(git log -n1 --pretty='format:%cd' --date=format:'%Y%m%d%H%M')
        max_prod=("$theme_version" "$prod_version")
        highest_version=$(max "${max_prod[@]}")
        echo "$highest_version"
    )
}

# Pull project repo and theme
function make_packages_repos() {
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
        cmd="git clone --depth 1 $GIT_BASE_URL/$repo $VERBOSITY_LEVEL"
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
        cmd="git clone --depth 1 $WEBMIN_REPO $VERBOSITY_LEVEL"
        eval "$cmd"
        if [ "$?" != "0" ]; then
            return 1
        fi
        # Clean language files in the required product if testing build
        if [ "$devel" == "1" ]; then
            (
                cd "$ROOT_DIR/$reqrepo" || exit 1
                eval "$lcmd"
            )
        fi
    fi

    # Clean language files in the main product if testing build
    if [ "$devel" == "1" ]; then
        (
            cd "$ROOT_DIR/$prod" || exit 1
            eval "$lcmd"
        )
    fi

    # Clone theme
    if [ ! -d "$root_prod/$theme" ]; then
        cd "$root_prod" || exit 1
        repo="$reqrepo/$theme.git"
        cmd="git clone --depth 1 $GIT_BASE_URL/$repo $VERBOSITY_LEVEL"
        eval "$cmd"
        if [ "$?" != "0" ]; then
            return 1
        fi
    fi
return 0
}

# Make module repo
function make_module_repo_cmd() {
    local module="$1"
    local target="$2"
    printf "git clone --depth 1 $target/%s.git %s" \
        "$module" "$VERBOSITY_LEVEL"
}

# Get last commit date from repo
function get_last_commit_date() {
    local repo_dir="$1"
    (
        cd "$repo_dir" || return 1
        git log -n1 --pretty='format:%cd' --date=format:'%Y%m%d%H%M'
    )
}

# Get required build scripts from Webmin repo
function make_module_build_deps() {
    # Create directory for build dependencies if it doesn't exist
    if [ ! -d "$ROOT_DIR/build-deps" ]; then
        mkdir -p "$ROOT_DIR/build-deps"
    fi

    # Download required scripts from Webmin repo if they don't exist
    if [ ! -f "$ROOT_DIR/build-deps/makemoduledeb.pl" ] || \
       [ ! -f "$ROOT_DIR/build-deps/makemodulerpm.pl" ] || \
       [ ! -f "$ROOT_DIR/build-deps/create-module.pl" ]; then
        echo "Downloading build dependencies .."
        
        # Create temporary directory
        local temp_dir
        temp_dir=$(mktemp -d)
        cd "$temp_dir" || exit 1
        
        # Clone Webmin repository (minimal depth)
        cmd="git clone --depth 1 --filter=blob:none --sparse \
            $WEBMIN_REPO.git $VERBOSITY_LEVEL"
        eval "$cmd"
        postcmd $?
        echo
        
        cd webmin || exit 1
        
        # Copy required files to build-deps directory
        cp makemoduledeb.pl makemodulerpm.pl create-module.pl \
            "$ROOT_DIR/build-deps/"
        
        # Make scripts executable
        chmod +x "$ROOT_DIR/build-deps/"*.pl
        
        # Clean up
        cd "$ROOT_DIR" || exit 1
        remove_dir "$temp_dir"
    fi
}

# Adjust module filename depending on package type
function adjust_module_filename() {
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
function get_rpm_module_epoch() {
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

    function is_latest {
        local filename="$1"
        [[ $filename =~ [-_]latest[._] ]] && return 0
        return 1
    }

    function get_base_package {
        local filename="$1"
        # Remove extension and release number
        filename=${filename%.*}  # Remove any extension
        filename=${filename%_all}
        filename=${filename%.noarch}
        filename=${filename%-[0-9]}
        filename=${filename%-[0-9][0-9]}
        
        # Extract base package name
        if [[ $filename =~ ^(.*)-[0-9]+(\.[0-9]+)* ]] || 
           [[ $filename =~ ^(.*)_[0-9]+(\.[0-9]+)* ]] || 
           [[ $filename =~ ^(.*)-latest ]] || 
           [[ $filename =~ ^(.*)_latest ]]; then
            echo "${BASH_REMATCH[1]}"
        else
            echo "$filename"
        fi
    }

    function get_version {
        local filename="$1"
        # Extract version number
        if [[ $filename =~ [^0-9]([0-9]+(\.[0-9]+[\.0-9]*)?)[^0-9] ]]; then
            echo "${BASH_REMATCH[1]}"
        fi
    }

    function version_gt {
        test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
    }

    function process_group {
        local files="$1"
        local latest_ver="0"
        local latest_file=""
        
        # Convert string to array
        IFS=' ' read -r -a file_array <<< "$files"
        
        # Find latest version
        for file in "${file_array[@]}"; do
            [[ -z "$file" ]] && continue
            
            # If this is a latest version, keep it and skip other checks
            if is_latest "$file"; then
                latest_file="$file"
                break
            fi
            
            version=$(get_version "$file")
            if [ -n "$version" ]; then
                if [ -z "$latest_file" ] ||
                   version_gt "$version" "$latest_ver"; then
                    latest_ver="$version"
                    latest_file="$file"
                fi
            fi
        done
        
        # Remove older versions
        for file in "${file_array[@]}"; do
            [[ -z "$file" ]] && continue
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

        if [ -n "$extensions_arg" ]; then
            # Use provided extensions
            for ext in $extensions_arg; do
                extensions["$ext"]=1
            done
        else
            # Find all unique extensions in the directory
            for file in *.*; do
                [[ -f "$file" ]] || continue
                ext="${file##*.}"
                [[ -n "$ext" ]] && extensions["$ext"]=1
            done
        fi

        # Group files by base package name and extension
        declare -A package_groups

        # Read all files with detected extensions
        for ext in "${!extensions[@]}"; do
            for file in *."$ext"; do
                [[ -f "$file" ]] || continue
                
                base_pkg=$(get_base_package "$file")
                [[ -z "$base_pkg" ]] && continue
                
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
