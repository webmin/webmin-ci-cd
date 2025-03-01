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
#   Pull and build production Webmin version 2.101, forcing
#   release version 3, displaying verbose output
#     ./build-product-deb.bash webmin 2.101 3 --testing
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

	local devel=0
	if [ "$TESTING_BUILD" -eq 1 ]; then
		devel=1
	fi

	# Always return back to root directory
	cd "$ROOT_DIR" || exit 1

	# Define root
	local prod=$1
	local root_prod="$ROOT_DIR/$prod"
	local root_apt="$root_prod/deb"
	local ver
	local rel=1
	local relval

	# Print build actual date
	date=$(get_current_date)

	# Create required symlinks
	create_symlinks

	# Print opening header
	echo "************************************************************************"
	echo "        build start date: $date                                         "
	echo "          package format: DEB                                           "
	echo "                 product: $prod                                         "
	echo -n "    downloading packages: "
	
	# Download products from repos
	make_packages_repos "$root_prod" "$prod" "$devel"
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
	fi
	if [ -z "${ver-}" ]; then
		if [ "$TESTING_BUILD" -eq 1 ]; then
			ver=$(get_product_version "$root_prod")
		else
			ver=$(get_current_repo_tag "$root_prod")
		fi
	fi
	if [ "$TESTING_BUILD" -eq 1 ]; then
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
	cmd="./makedist.pl \"${ver}${relval-}\" $VERBOSITY_LEVEL"
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
}

# Main
if [ -n "${1-}" ] && [[ "${1-}" != --* ]]; then
	build "$@"
	upload_list=("$ROOT_REPOS/$1"*)
else
	build webmin "$@"
	build usermin "$@"
	upload_list=("$ROOT_REPOS/"*)
fi

cloud_upload upload_list
cloud_sign_and_build_repos webmin.dev
