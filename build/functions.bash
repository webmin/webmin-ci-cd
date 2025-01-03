#!/usr/bin/env bash
# shellcheck disable=SC2181
# functions.bash
# Copyright Ilia Ross <ilia@webmin.dev>
# Build functions for the build process

# Set up SSH keys on the build machine
setup_ssh() {
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

# Upload to cloud
# Usage:
#   cloud_upload_list_delete=("remote_dir remote_file pre_pattern post_pattern")
#   cloud_upload_list_upload=("$ROOT_REPOS/*" "$ROOT_REPOS/repodata")
#   cloud_upload cloud_upload_list_upload cloud_upload_list_delete
cloud_upload() {
    # Print new block only if defined
    local ssh_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    if [ -n "$1" ]; then
        echo
    fi

    # Setup SSH keys on the build machine
    setup_ssh

    # Delete files on remote if needed
    if [ -n "$2" ]; then
        echo "Deleting given files in $CLOUD_UPLOAD_SSH_HOST .."
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
                local cmd1="ssh $ssh_args $CLOUD_UPLOAD_SSH_USER@"
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
        echo "Uploading built files to $CLOUD_UPLOAD_SSH_HOST .."
        local -n arr_upl=$1
        local err=0
        for u in "${arr_upl[@]}"; do
            if [ -n "$u" ]; then
                local cmd2="scp $ssh_args -r $u $CLOUD_UPLOAD_SSH_USER@"
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
cloud_repo_sign_and_update() {
    # shellcheck disable=SC2034
    local repo_type="$1"
    # Setup SSH keys on the build machine
    setup_ssh
    # Sign and update repos metadata in remote
    echo "Signing and updating repos metadata in $CLOUD_UPLOAD_SSH_HOST .."
    local ssh_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    local cmd1="ssh $ssh_args $CLOUD_UPLOAD_SSH_USER@"
    cmd1+="$CLOUD_UPLOAD_SSH_HOST \"$CLOUD_SIGN_BUILD_REPOS_CMD\" $VERBOSITY_LEVEL"
    eval "$cmd1"
    postcmd $?
    echo
}

# Post command func
postcmd() {
    if [ "$1" != "0" ]; then
        echo ".. failed"
        exit 1
    else
        echo ".. done"
    fi
}

# Get max number from array
max() {
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
make_dir() {
    if [ ! -d "$1" ]; then
        mkdir -p "$1"
    fi
}

# Remove all content in dir
purge_dir() {
    for file in "$1"/*; do
        rm -rf "$file"
    done
}

# Remove dir
remove_dir() {
    if [ -d "$1" ]; then
        rm -rf "$1"
    fi
}

# Get latest tag version
get_current_repo_tag() {
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

get_module_version() {
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

update_module_version() {
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
get_current_date() {
    date +'%Y-%m-%d %H:%M:%S %z'
}

# Get latest commit date version
get_latest_commit_date_version() {
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
make_packages_repos() {
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
make_module_repo_cmd() {
    local module="$1"
    local target="$2"
    printf "git clone --depth 1 $target/%s.git %s" \
        "$module" "$VERBOSITY_LEVEL"
}

# Get last commit date from repo
get_last_commit_date() {
    local repo_dir="$1"
    (
        cd "$repo_dir" || return 1
        git log -n1 --pretty='format:%cd' --date=format:'%Y%m%d%H%M'
    )
}

# Get required build scripts from Webmin repo
make_module_build_deps() {
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
adjust_module_filename() {
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
get_rpm_module_epoch() {
    local module="$1"
    local script_dir
    local epoch_file
    script_dir=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
    epoch_file="$script_dir/rpm-modules-epoch.txt"
    if [ ! -f "$epoch_file" ]; then
        echo "Error: $epoch_file not found" >&2
        return 1
    fi
    awk -F= -v module="$module" '$1 == module {print $2; exit}' "$epoch_file"
}
