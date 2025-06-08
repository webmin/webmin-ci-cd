#!/usr/bin/env bash
# shellcheck disable=SC2034
# build-product-rpm.bash (https://github.com/webmin/webmin-ci-cd)
# Copyright Ilia Ross <ilia@webmin.dev>
# Licensed under the MIT License
#
# Automatically builds RPM packages of Webmin and Usermin with the latest
# Authentic Theme, pulls changes from GitHub, creates testing builds from the
# latest code with English-only support, production builds from the latest tag,
# uploads them to the pre-configured repository, updates the repository
# metadata, and interacts with the environment using bootstrap
#
# Usage:
#
#   Pull and build production versions of both Webmin and Usermin
#     ./build-product-rpm.bash
#
#   Pull and build testing versions of both Webmin and Usermin
#     ./build-product-rpm.bash --testing
#
#   Pull and build production Webmin version 2.101, forcing release
#   version 3, with core modules only and displaying verbose output
#     ./build-product-rpm.bash webmin 2.101 3 --build-type=core --testing
#
#   Pull and build production Usermin version 2.000,
#   automatically setting release version
#     ./build-product-rpm.bash usermin 2.000
#

# shellcheck disable=SC1091
# Bootstrap build environment
source ./bootstrap.bash || exit 1

# Build product func
function build {
	# Always return back to root directory
	cd "$ROOT_DIR" || exit 1

	# Define root
	local prod=$1
	# Define build type
	build_type=$(get_flag --build-type) || build_type='full'
	local root_prod="$ROOT_DIR/$prod"
	local ver
	local rel=1

	# Print build actual date
	date=$(get_current_date)

	# Create required symlinks
	create_symlinks

	# Print opening header
	echo "************************************************************************"
	echo "        build start date: $date                                         "
	echo "          package format: RPM                                           "
	echo "                 product: $prod ($build_type)                           "
	printf "    downloading packages: "
	flush_output

	# Download products from repos
	make_packages_repos "$root_prod" "$prod"
	local rs=$? # Store to print success or failure nicely later
	if [ $rs -eq 0 ]; then
		echo -e "✔"
	else
		echo -e "✘"
	fi
	
	# Print package version
	echo -n "         package version: "
	
	# Switch to product directory explicitly
	cd "$root_prod" || exit 1

	# Get latest product version (theme vs product)
	date_version=$(get_product_latest_commit_timestamp "$root_prod")

	# Handle other params
	if [ -n "${2-}" ] && [[ "${2-}" != *"--"* ]]; then
		ver=$2
	fi
	if [[ -n "${3-}" ]] && [[ "${3-}" != *"--"* ]]; then
		rel=$3
	fi
	if [ -z "${ver-}" ]; then
		if get_flag --testing; then
			ver=$(get_product_version "$root_prod")
		else
			ver=$(get_current_repo_tag "$root_prod")
		fi
	fi
	if get_flag --testing; then
		# Testing version must always be x.x.<last_commit_date>
		ver=$(echo "$ver" | cut -d. -f1,2)
		ver="$ver.$date_version"
		# Set actual product version
		echo "${ver}" >"version"
	fi

	printf "%s-%s\n" "$ver" "$rel"
	echo "************************************************************************"

	echo "Pulling latest changes .."
	# We need to pull first to get the latest tag,
	# so here we only report an error if any
	postcmd $rs
	echo

	echo "Pre-clean up .."
	# Make sure directories exist
	make_dir "$root_prod/newkey/rpm/"
	make_dir "$root_prod/umodules/"
	make_dir "$root_prod/minimal/"
	make_dir "$root_prod/tarballs/"
	make_dir "$ROOT_BUILD/BUILD/"
	make_dir "$ROOT_BUILD/BUILDROOT/"
	make_dir "$ROOT_BUILD/RPMS/"
	make_dir "$ROOT_BUILD/SOURCES/"
	make_dir "$ROOT_BUILD/SPECS/"
	make_dir "$ROOT_BUILD/SRPMS/"
	make_dir "$ROOT_REPOS/"

	# Purge old files
	purge_dir "$root_prod/newkey/rpm"
	purge_dir "$root_prod/umodules"
	purge_dir "$root_prod/minimal"
	purge_dir "$root_prod/tarballs"
	purge_dir "$ROOT_BUILD/BUILD"
	purge_dir "$ROOT_BUILD/BUILDROOT"
	purge_dir "$ROOT_BUILD/RPMS"
	purge_dir "$ROOT_BUILD/SOURCES"
	purge_dir "$ROOT_BUILD/SPECS"
	purge_dir "$ROOT_BUILD/SRPMS"
	remove_dir "$ROOT_REPOS/repodata"
	if [ -n "${prod-}" ]; then
		rm -f "$ROOT_REPOS/$prod-"*
		rm -f "$ROOT_REPOS/${prod}_"*
	fi
	postcmd $?
	make_dir "$ROOT_BUILD/RPMS/noarch"
	echo

	# Descend to project dir
	cd "$root_prod" || exit 1

	echo "Pre-building package .."
	if [ "$rel" -eq 1 ]; then
		args="$ver"
	else
		args="$ver-$rel"
	fi

	cmd="./makedist.pl \"--mod-list $build_type $args\" $VERBOSITY_LEVEL"
	eval "$cmd"
	postcmd $?
	echo

	echo "Building package .."
	cmd="RPM_MAINTAINER=\"$BUILDER_PACKAGE_NAME\" ./makerpm.pl \"$ver\" \"$rel\" \
		$VERBOSITY_LEVEL"
	eval "$cmd"
	postcmd $?
	echo

	cd "$ROOT_DIR" || exit 1
	echo "Preparing built files for upload .."
	cmd="cp -f $root_prod/tarballs/$prod*$ver*\.tar.gz \
		$ROOT_REPOS/${prod}-$ver.tar.gz $VERBOSITY_LEVEL"
	eval "$cmd"
	cmd="find $ROOT_RPMS -name $prod*$ver*\.rpm -exec mv '{}' \
		$ROOT_REPOS \; $VERBOSITY_LEVEL"
	eval "$cmd"
	# cmd="mv -f $ROOT_REPOS/$prod-$ver-$rel*\.rpm \
	#   $ROOT_REPOS/${prod}-$ver-$rel.noarch.rpm $VERBOSITY_LEVEL" # file name is already always the same
	# eval "$cmd"
	postcmd $?
	echo

	echo "Post-clean up .."
	cd "$ROOT_BUILD" || exit 1
	for dir in *; do
		cmd="rm -rf \"$dir/*\" $VERBOSITY_LEVEL"
		eval "$cmd"
	done
	postcmd $?

	# If the build type isn't full, build other modules separately for each product
	if [ "$build_type" != 'full' ]; then
		echo
		local product_upper="${prod^}"
		echo "Building $product_upper modules not included in the $build_type build .."
		old_e=${-//[^e]/}; set +e
		output=$(build_core_modules "$prod" "rpm" 2>&1)
		exit_code=$?
		[ "$old_e" ] && set -e
		if [ $exit_code -eq 0 ]; then
			echo ".. done"
		elif [ $exit_code -eq 2 ]; then
			echo ".. skipped : $output"
		else
			echo ".. failed : $output"
		fi
		cd "$ROOT_DIR" || exit 1
	fi
}

# Main
if [ -n "${1-}" ] && [[ "${1-}" != --* ]]; then
	build "$@"
else
	product_list=("webmin" "usermin")
	for product in "${product_list[@]}"; do
		build "$product" "$@"
	done
fi

# Upload built packages to the cloud
upload_list=("$ROOT_REPOS/"*)
cloud_upload upload_list
cloud_sign_and_build_repos webmin.dev
