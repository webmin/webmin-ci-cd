#!/usr/bin/env bash
# shellcheck disable=SC2034
# build-module-deb.bash (https://github.com/webmin/webmin-ci-cd)
# Copyright Ilia Ross <ilia@webmin.dev>
# Licensed under the MIT License
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
#     ./build-module-deb.bash virtualmin-nginx --testing --verbose
#
#   Build specific module with version and release
#     ./build-module-deb.bash virtualmin-nginx 2.36 2
#

# shellcheck disable=SC1091
# Bootstrap build environment
source ./bootstrap.bash || exit 1

# Build module func
function build {
	# Always return back to root directory
	cd "$ROOT_DIR" || exit 1

	# Define variables
	local module_dir edition_id license build_type last_commit_date ver rel
	local module=$1
	license=$(get_flag --build-license) || license='GPLv3'
	build_type=$(get_flag --build-type) || build_type='full'
	local core_module=0
	if get_flag --core-module >/dev/null; then
		core_module=1
	fi
	local root_module

	# Print build actual date
	local date
	date=$(get_current_date)

	# Define build dependencies directory
	local build_deps="$ROOT_DIR/build-deps" 

	# Create required symlinks
	create_symlinks

	# Print opening header
	echo "************************************************************************"
	echo "        build start date: $date                                         "
	echo "          package format: DEB                                           "
	echo "                  module: $module                                       "
	printf "     downloading package: "
	flush_output

	# Get module build flags
	flags=$(resolve_module_flags "$module")

	# Clone module repository and dependencies if any
	IFS=, read -r rs module_dir edition_id lic_id last_commit_date <<< \
		"$(clone_module_repo "$module" "$MODULES_REPO_URL" "$core_module")"
	module="$module_dir"
	root_module="$ROOT_DIR/$module"
	if [ -n "${edition_id-}" ]; then
		edition_id="-$edition_id"
	fi
	if [ -n "${lic_id-}" ]; then
		license="$lic_id"
	fi
	if [ "$rs" -eq 0 ]; then
		echo -e "✔"
		# Git last commit date unless already set by dependent repo
		last_commit_date=${last_commit_date:-"$(get_repo_commit_timestamp "$root_module")"}

		# Handle other params
		cd "$root_module" || exit 1
		if [ -n "${2-}" ] && [[ "${2-}" != *"--"* ]]; then
			ver=$2
		fi
		if [[ -n "${3-}" ]] && [[ "${3-}" != *"--"* ]]; then
			rel=$3
		else
			rel=1
		fi
		if [ -z "${ver-}" ]; then
			ver=$(get_module_version "$root_module")
		fi
		if get_flag --testing; then
			# Testing version must always be x.x.<last_commit_date>, this will
			# effectively remove the patch version from any module for testing
			# builds
			ver=$(echo "$ver" | cut -d. -f1,2)
			ver="$ver.$last_commit_date"
		fi
		echo "                 version: $ver-$rel$edition_id ($build_type)"
	else
		echo -e "✘"
	fi

	echo "                 license: $license"
	echo "************************************************************************"

	echo "Pulling latest changes .."
	postcmd "$rs"
	echo

	echo "Pre-clean up .."
	# Make sure directories exist
	make_dir "$ROOT_REPOS"
	postcmd $?
	echo

	# Download required build dependencies
	make_module_build_deps
	
	# Build DEB package
	(
		cd "$ROOT_DIR" || exit 1

		# Clean language files in the package if testing build and no --no-clean
		# flag given
		if get_flag --testing && ! get_flag --no-clean; then
			echo "Cleaning language files .."
			lcmd="$build_deps/language-manager --lib-path=$build_deps \
				--mode=clean --yes $VERBOSITY_LEVEL_WITH_INPUT"
			eval "$lcmd"
			postcmd $?
			echo
		fi
		
		# Build DEB package
		echo "Building packages .."
		modules_exclude=$(get_modules_exclude)
		cmd="$build_deps/makemoduledeb.pl --mod-list $build_type \
			--release $rel$edition_id \
			--mod-depends --mod-recommends $flags --licence '$license' \
			--email '$BUILDER_PACKAGE_NAME <$BUILDER_MODULE_EMAIL>' \
			--allow-overwrite --target-dir $ROOT_REPOS $modules_exclude \
			$module $ver $VERBOSITY_LEVEL"
		eval "$cmd"
		postcmd $?
		echo
	)
	
	# Adjust module filename for edge cases
	if ! get_flag --core-module >/dev/null; then
		echo "Adjusting module filename .."
		adjust_module_filename "$ROOT_REPOS" "deb"
		postcmd $?
		echo
	fi

	# Post-build clean up
	if [[ ! -f "$root_module/.nodelete" ]]; then
		echo "Post-clean up .."
		remove_dir "$root_module"
		postcmd $?
	fi
}

# Main
if [ -n "${1-}" ] && [[ "'${1-}'" != *"--"* ]]; then
	MODULES_REPO_URL="$VIRTUALMIN_ORG_AUTH_URL"
	related_modules=$(get_related_modules "$1")
	for mod in $related_modules; do
		build "$mod" "${@:2}"
	done
	if ! get_flag --no-upload >/dev/null; then
		upload_list=("$ROOT_REPOS/"*)
		cloud_upload upload_list
		cloud_sign_and_build_repos virtualmin.dev
	fi
else
	# Error otherwise
	echo "Error: No module specified"
	exit 1
fi
