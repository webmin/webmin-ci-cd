#!/usr/bin/env bash
# shellcheck disable=SC2034
# build-deb-module.bash
# Copyright Ilia Ross <ilia@webmin.dev>
#
# Automatically builds DEB Webmin module pulls changes from GitHub, creates
# testing builds from the latest code with English-only support, production
# builds from the latest tag, uploads them to the pre-configured repository,
# updates the repository metadata, and interacts with the environment using
# bootstrap
#
# Usage:
#
#   Build testing module with in verbose mode
#     ./build-deb-module.bash virtualmin-nginx --testing --verbose
#
#   Build specific module with version and release
#     ./build-deb-module.bash virtualmin-nginx 2.36 2
#

# shellcheck disable=SC1091
# Bootstrap build environment
source ./bootstrap.bash || exit 1

# Build module func
build_module() {
    # Always return back to root directory
    cd "$ROOT_DIR" || exit 1

    # Define variables
    local last_commit_date
    local ver=""
    local verorig=""
    local module=$1
    local rel
    local devel=0
    local root_module="$ROOT_DIR/$module"

    # Print build actual date
    date=$(get_current_date)

    # Print opening header
    echo "************************************************************************"
    echo "        build start date: $date                                         "
    echo "          package format: DEB                                           "
    echo "                  module: $module                                       "

    # Pull or clone module repository
    remove_dir "$root_module"
    cmd=$(make_module_repo_cmd "$module" "$MODULES_REPO_URL")
    eval "$cmd"
    rs=$?

    # Git last commit date
    last_commit_date=$(get_last_commit_date "$root_module")

    # Handle other params
    cd "$root_module" || exit 1
    if [[ "'$2'" != *"--"* ]]; then
        ver=$2
    fi
    if [[ "'$3'" != *"--"* ]] && [[ -n "$3" ]]; then
        rel=$3
    else
        rel=1
    fi
    if [ -z "$ver" ]; then
        ver=$(get_module_version "$root_module")
    fi
    if [[ "'$*'" == *"--testing"* ]]; then
        devel=1
        verorig=$ver
        ver=$(echo "$ver" | cut -d. -f1,2)
        ver="$ver.$last_commit_date"
    fi

    echo "  package output version: $ver-$rel"
    echo "************************************************************************"

    echo "Pulling latest changes.."
    postcmd $rs
    echo

    echo "Pre-clean up .."
    # Make sure directories exist
    make_dir "$root_module/tmp"
    make_dir "$ROOT_REPOS"

    # Purge old files
    purge_dir "$root_module/tmp"
    if [ "$module" != "" ]; then
        rm -f "$ROOT_REPOS/$module-latest"*
    fi
    postcmd $?
    echo

    # Download required build dependencies
    make_module_build_deps
    
    # Build DEB package
    echo "Building packages .."
    (
        # XXXX Update actual module testing version dynamically
        cd "$ROOT_DIR" || exit 1
        cmd="$ROOT_DIR/build-deps/makemoduledeb.pl --release $rel --deb-depends \
            --licence 'GPLv3' --email '$BUILDER_MODULE_EMAIL' --allow-overwrite \
            --target-dir $root_module/tmp $module $VERBOSITY_LEVEL"
        eval "$cmd"
        postcmd $?
    )

    echo
    echo "Preparing built files for upload .."
    # Move DEB to repos
    cmd="find $root_module/tmp -name webmin-${module}*$verorig*\.deb -exec mv '{}' \
        $ROOT_REPOS \; $VERBOSITY_LEVEL"
    eval "$cmd"
    if [ "$devel" -eq 1 ]; then
        cmd="mv -f $ROOT_REPOS/*${module}*$verorig*\.deb \
            $ROOT_REPOS/${module}_${ver}-${rel}_all.deb $VERBOSITY_LEVEL"
        eval "$cmd"
    fi
    postcmd $?
    echo
    
    # Adjust module filename
    echo "Adjusting module filename .."
    adjust_module_filename "$ROOT_REPOS" "deb"
    postcmd $?
    echo

    echo "Post-clean up .."
    remove_dir "$root_module"
    postcmd $?
}

# Main
if [ -n "$1" ] && [[ "'$1'" != *"--"* ]]; then
    MODULES_REPO_URL="$VIRTUALMIN_ORG_AUTH_URL"
    build_module "$@"
    cloud_upload_list_upload=("$ROOT_REPOS/*$1*")
    cloud_upload cloud_upload_list_upload
    cloud_repo_sign_and_update
else
    # Error otherwise
    echo "Error: No module specified"
    exit 1
fi
