#!/usr/bin/env bash
# shellcheck disable=SC2034
# build-rpm-module.bash
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
#     ./build-rpm-module.bash virtualmin-nginx --testing --verbose
#
#   Build specific module with version and release
#     ./build-rpm-module.bash virtualmin-nginx 2.36 2
#

# shellcheck disable=SC1091
# Bootstrap build environment
source ./bootstrap.bash || exit 1

# Build module func
function build() {
    # Always return back to root directory
    cd "$ROOT_DIR" || exit 1

    # Define variables
    local module_dir edition_id license last_commit_date ver rel epoch epoch_str
    license="GPLv3"
    local module=$1
    local root_module
    local devel=0

    # Print build actual date
    date=$(get_current_date)

    # Print opening header
    echo "************************************************************************"
    echo "        build start date: $date                                         "
    echo "          package format: RPM                                           "
    echo "                  module: $module                                       "
    echo -n "     downloading package: "

    # Clone module repository and dependencies if any
    IFS=$',' read -r rs module_dir edition_id lic_id <<< "$(clone_module_repo \
        "$module" "$MODULES_REPO_URL")"
    module="$module_dir"
    root_module="$ROOT_DIR/$module"
    if [ -n "$edition_id" ]; then
        edition_id=".$edition_id"
    fi
    if [ -n "$lic_id" ]; then
        license="$lic_id"
    fi
    if [ "$rs" -eq 0 ]; then
        echo -e "✔"
    else
        echo -e "✘"
    fi

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
    if [[ "'$4'" != *"--"* ]] && [[ -n "$4" ]]; then
        epoch_str="$4:"
        epoch="--epoch $4"
    else
        # Check if module has epoch
        epoch=$(get_rpm_module_epoch "$module")
        if [ -n "$epoch" ]; then
            epoch_str="$epoch:"
            epoch="--epoch $epoch"
        fi
    fi
    if [ -z "$ver" ]; then
        ver=$(get_module_version "$root_module")
    fi
    if [[ "'$*'" == *"--testing"* ]]; then
        devel=1
        # Testing version must always be x.x.<last_commit_date>, this will
        # effectively remove the patch version from any module for testing
        # builds
        ver=$(echo "$ver" | cut -d. -f1,2)
        ver="$ver.$last_commit_date"
    fi

    echo "                 version: $epoch_str$ver-$rel$edition_id"
    echo "                 license: $license"
    echo "************************************************************************"

    echo "Pulling latest changes.."
    postcmd "$rs"
    echo

    echo "Pre-clean up .."
    # Make sure directories exist
    make_dir "$ROOT_DIR/newkey/rpm/"
    make_dir "$ROOT_DIR/umodules/"
    make_dir "$ROOT_DIR/minimal/"
    make_dir "$ROOT_DIR/tarballs/"
    make_dir "$ROOT_BUILD/BUILD/"
    make_dir "$ROOT_BUILD/BUILDROOT/"
    make_dir "$ROOT_BUILD/RPMS/"
    make_dir "$ROOT_RPMS"
    make_dir "$ROOT_BUILD/SOURCES/"
    make_dir "$ROOT_BUILD/SPECS/"
    make_dir "$ROOT_BUILD/SRPMS/"
    make_dir "$ROOT_REPOS"
    postcmd $?
    echo

    # Download required build dependencies
    make_module_build_deps

    # Build RPM package
    echo "Building packages.."
    (
        cd "$ROOT_DIR" || exit 1
        modules_exclude=$(get_modules_exclude)
        cmd="$ROOT_DIR/build-deps/makemodulerpm.pl $epoch --release \
            $rel$edition_id --rpm-depends --licence '$license' --allow-overwrite --rpm-dir \
            $ROOT_BUILD --target-dir $ROOT_REPOS $modules_exclude \
            --vendor '$BUILDER_PACKAGE_NAME' $module $ver $VERBOSITY_LEVEL"
        eval "$cmd"
        postcmd $?
    )
    echo

    # Adjust module filename for edge cases
    echo "Adjusting module filename .."
    adjust_module_filename "$ROOT_REPOS" "rpm"
    postcmd $?
    echo

    echo "Post-clean up .."
    remove_dir "$root_module"
    # Purge old files
    purge_dir "$ROOT_BUILD/BUILD"
    purge_dir "$ROOT_BUILD/BUILDROOT"
    purge_dir "$ROOT_BUILD/RPMS"
    purge_dir "$ROOT_BUILD/SOURCES"
    purge_dir "$ROOT_BUILD/SPECS"
    purge_dir "$ROOT_BUILD/SRPMS"
    remove_dir "$ROOT_REPOS/repodata"
    postcmd $?
}

# Main
if [ -n "$1" ] && [[ "'$1'" != *"--"* ]]; then
    MODULES_REPO_URL="$VIRTUALMIN_ORG_AUTH_URL"
    build "$@"
    upload_list=("$ROOT_REPOS/"*)
    cloud_upload upload_list
    cloud_sign_and_build_repos virtualmin.dev
else
    # Error otherwise
    echo "Error: No module specified"
    exit 1
fi
