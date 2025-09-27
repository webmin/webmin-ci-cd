#!/usr/bin/env bash
# shellcheck disable=SC2034
# build-product-deb.bash (https://github.com/webmin/webmin-ci-cd)
# Copyright Ilia Ross <ilia@webmin.dev>
# Licensed under the MIT License
#
# Automatically builds DEB packages of Webmin and Usermin with the latest
# Authentic Theme, pulls changes from GitHub, creates testing builds from the
# latest code with English-only support, production builds from the latest tag,
# uploads them to the pre-configured repository, updates the repository
# metadata, and interacts with the environment using bootstrap
#
# Usage:
#
#   Pull and build production versions of both Webmin and Usermin
#     ./build-product-deb.bash
#
#   Pull and build testing versions of both Webmin and Usermin
#     ./build-product-deb.bash --testing
#
#   Pull and build production Webmin version 2.101, forcing release
#   version 3, with core modules only and displaying verbose output
#     ./build-product-deb.bash webmin 2.101 3 --build-type=core --testing
#
#   Pull and build production Usermin version 2.000,
#   automatically setting release version
#     ./build-product-deb.bash usermin 2.000
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
	local root_apt="$root_prod/deb"
	local ver
	local rel
	local relval

	# Print build actual date
	date=$(get_current_date)

	# Create required symlinks
	create_symlinks

	# Print opening header
	echo "************************************************************************"
	echo "        build start date: $date                                         "
	echo "          package format: DEB                                           "
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
		relval="-$3"
	else
		rel=${CLOUD_BUILD_RUN_ATTEMPT:-1}
		if [ "$rel" -gt 1 ]; then
			relval="-$rel"
		fi
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
	make_dir "$ROOT_REPOS/"
	make_dir "$root_apt/"
	make_dir "$root_prod/newkey/deb/"
	make_dir "$root_prod/umodules/"
	make_dir "$root_prod/minimal/"
	make_dir "$root_prod/tarballs/"

	# Purge old files
	purge_dir "$root_prod/newkey/deb"
	purge_dir "$root_prod/umodules"
	purge_dir "$root_prod/minimal"
	purge_dir "$root_prod/tarballs"
	if [ -n "${prod-}" ]; then
		rm -f "$ROOT_REPOS/$prod-"*
		rm -f "$ROOT_REPOS/${prod}_"*
	fi
	postcmd $?
	echo

	# Descend to project dir
	cd "$root_prod" || exit 1

	echo "Pre-building package .."
	cmd="./makedist.pl \"--mod-list $build_type ${ver}${relval-}\" \
		$VERBOSITY_LEVEL"
	eval "$cmd"
	postcmd $?
	echo

	echo "Building package .."
	local makecmd
	makecmd="DEB_MAINTAINER=\"$BUILDER_PACKAGE_NAME <$BUILDER_PACKAGE_EMAIL>\" \
		./makedebian.pl"
	if [ -z "${relval-}" ]; then
		cmd="$makecmd \"$ver\" $VERBOSITY_LEVEL"
	else
		cmd="$makecmd \"$ver\" \"$rel\" $VERBOSITY_LEVEL"
	fi
	eval "$cmd"
	postcmd $?
	echo

	cd "$ROOT_DIR" || exit 1
	echo "Preparing built files for upload .."
	cmd="cp -f $root_prod/tarballs/${prod}*${ver}*\.tar.gz \
		$ROOT_REPOS/${prod}-$ver.tar.gz $VERBOSITY_LEVEL"
	eval "$cmd"
	cmd="find $root_apt -name ${prod}*${ver}*\.deb -exec mv '{}' \
		$ROOT_REPOS \; $VERBOSITY_LEVEL"
	eval "$cmd"
	cmd="mv -f $ROOT_REPOS/${prod}*${ver}*\.deb \
		$ROOT_REPOS/${prod}_${ver}-${rel}_all.deb $VERBOSITY_LEVEL"
	eval "$cmd"
	postcmd $?

	# If the build type isn't full, build other modules separately for each product
	if [ "$build_type" != 'full' ]; then
		echo
		local product_upper="${prod^}"
		echo "Building $product_upper modules not included in the $build_type build .."
		old_e=${-//[^e]/}; set +e
		output=$(build_core_modules "$prod" "deb" 2>&1)
		exit_code=$?
		[ "$old_e" ] && set -e
		if [ $exit_code -eq 0 ]; then
			echo ".. no modules changed"
		elif [ $exit_code -eq 2 ]; then
			echo ".. skipped : $output"
		elif [ $exit_code -eq 3 ]; then
			echo ".. done for : $output"
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
