#!/bin/sh
# shellcheck disable=SC2317 disable=SC2329
# install-ci-cd-repo.sh (https://github.com/webmin/webmin-ci-cd)
# Copyright Ilia Ross <ilia@webmin.dev>
# Licensed under the MIT License
#
# Installs package repository configuration for CI/CD builds

url="https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh"
virtualmin_license_file="/etc/virtualmin-license"
cloudmin_license_file="/etc/server-manager-license"
# virtualmin_stable_host="download.virtualmin.com"
virtualmin_stable_host="rc.software.virtualmin.dev" # tmp for testing
virtualmin_unstable_host="software.virtualmin.dev"
virtualmin_prerelease_host="rc.software.virtualmin.dev"
cloudmin_unstable_host="software.cloudmin.dev"
cloudmin_prerelease_host="rc.software.cloudmin.dev"

download_script() {
	tmp_file=$(mktemp)
	
	for downloader in "curl -fsSL" "wget -qO-"; do
		if command -v "${downloader%% *}" >/dev/null 2>&1; then
			case $downloader in
				curl*) curl -fsSL "$1" > "$tmp_file" ;;
				wget*) wget -qO- "$1" > "$tmp_file" ;;
			esac
			echo "$tmp_file"
			return 0
		fi
	done
	
	echo "Error: Neither curl nor wget is installed." >&2
	return 1
}

check_virtualmin_license() {
	if [ -f "$virtualmin_license_file" ]; then
		serial=$(grep "SerialNumber" "$virtualmin_license_file" | cut -d= -f2)
		license=$(grep "LicenseKey" "$virtualmin_license_file" | cut -d= -f2)
		if [ "$serial" != "GPL" ] && [ "$license" != "GPL" ]; then
			echo "--auth-user=$serial --auth-pass=$license"
		fi
	fi
	return 0
}

check_cloudmin_license() {
	if [ -f "$cloudmin_license_file" ]; then
		serial=$(grep "SerialNumber" "$cloudmin_license_file" | cut -d= -f2)
		license=$(grep "LicenseKey" "$cloudmin_license_file" | cut -d= -f2)
		if [ "$serial" != "GPL" ] && [ "$license" != "GPL" ]; then
			echo "--auth-user=$serial --auth-pass=$license"
		fi
	fi
	return 0
}

set_virtualmin_package_preferences() {
	fn_auth_user="$1"
	fn_auth_pass="$2"
	if [ -z "$fn_auth_user" ] || [ -z "$fn_auth_pass" ]; then
		printf '%s\n' \
			"deb:pin:webmin-virtual-server=1001=gpl" \
			"rpm:exclude:*virtual-server*pro*"
	fi
	return 0
}

set_virtualmin_repo_preferences() {
	type="$1"
	prefix="$2"
	param="$3"
	rpm_virtualmin_repo_preferences() {
		type="$1"
		param="$2"
		
		# Handle priority parameter
		if [ "$param" = "priority" ]; then
			case "$type" in
				"unstable")
					echo "rpm:priority=10"
					;;
				"prerelease")
					echo "rpm:priority=20"
					;;
			esac
		fi
	}

	# Construct the function name
	func_name="${prefix}_virtualmin_repo_preferences"

	# Check if the function exists using POSIX compatible method
	if command -v "$func_name" >/dev/null 2>&1; then
		# Call the function with type and param
		"$func_name" "$type" "$param"
	fi
}

set_cloudmin_repo_preferences() {
	type="$1"
	prefix="$2"
	param="$3"
	rpm_cloudmin_repo_preferences() {
		type="$1"
		param="$2"
		
		# Handle priority parameter
		if [ "$param" = "priority" ]; then
			case "$type" in
				"unstable")
					echo "rpm:priority=10"
					;;
				"prerelease")
					echo "rpm:priority=20"
					;;
			esac
		fi
	}

	# Construct the function name
	func_name="${prefix}_cloudmin_repo_preferences"

	# Check if the function exists using POSIX compatible method
	if command -v "$func_name" >/dev/null 2>&1; then
		# Call the function with type and param
		"$func_name" "$type" "$param"
	fi
}

setup_repo() {
	product="$1"
	type="$2"
	if ! script=$(download_script "$url"); then
		return 1
	fi

	auth_user=""
	auth_pass=""
	[ "$product" = "virtualmin" ] && {
		license_data=$(check_virtualmin_license)
		auth_user=$(echo "$license_data" | awk '{print $1}')
		auth_pass=$(echo "$license_data" | awk '{print $2}')
	}
	[ "$product" = "cloudmin" ] && {
		license_data=$(check_cloudmin_license)
		auth_user=$(echo "$license_data" | awk '{print $1}')
		auth_pass=$(echo "$license_data" | awk '{print $2}')
	}
	
	# Call package preference function if it exists
	pkg_prefs=""
	func="set_${product}_package_preferences"
	if command -v "$func" >/dev/null 2>&1; then
	  pkg_prefs=$(eval "$func" "$auth_user" "$auth_pass")
	fi

	# Call repo preference function if it exists
	repo_prefs=""
	func="set_${product}_repo_preferences"
	if command -v "$func" >/dev/null 2>&1; then
	  repo_prefs=$(eval "$func" "$type" "rpm" "priority")
	fi

	case "$product" in
		webmin)
			case "$type" in
			    stable)     sh "$script" "--stable" "--force" ;;
				prerelease) sh "$script" "--prerelease" "--force" ;;
				unstable)   sh "$script" "--unstable" "--force" ;;
			esac
			;;
		virtualmin)
			case "$type" in
				prerelease)
					set -- \
						--force \
						--prerelease-host="$virtualmin_prerelease_host" \
						--name=virtualmin \
						--dist=virtualmin \
						--description=Virtualmin \
						--component=main \
						--check-binary=0 \
						--prerelease
					
					[ -n "$auth_user" ] && set -- "$@" "$auth_user"
					[ -n "$auth_pass" ] && set -- "$@" "$auth_pass"
					[ -n "$pkg_prefs" ] && set -- "$@" "--pkg-prefs=$pkg_prefs"
					[ -n "$repo_prefs" ] && set -- "$@" "--repo-prefs=$repo_prefs"
					
					sh "$script" "$@"
					;;
				unstable)
					set -- \
						--force \
						--unstable-host="$virtualmin_unstable_host" \
						--name=virtualmin \
						--dist=virtualmin \
						--description=Virtualmin \
						--component=main \
						--check-binary=0 \
						--unstable
					
					[ -n "$auth_user" ] && set -- "$@" "$auth_user"
					[ -n "$auth_pass" ] && set -- "$@" "$auth_pass"
					[ -n "$pkg_prefs" ] && set -- "$@" "--pkg-prefs=$pkg_prefs"
					[ -n "$repo_prefs" ] && set -- "$@" "--repo-prefs=$repo_prefs"
					
					sh "$script" "$@"
					;;
				stable)
					set -- \
						--force \
						--host="$virtualmin_stable_host" \
						--repo-rpm-path=/ \
						--repo-deb-path=/ \
						--key="virtualmin-developers-2025-rsa.pub.asc virtualmin-developers-2026-rsa.pub.asc" \
						--key-server=https://keyserve.virtualmin.com \
						--key-name="Virtualmin 8" \
						--key-suffix=virtualmin-8 \
						--name=virtualmin \
						--dist=virtualmin \
						--description=Virtualmin \
						--component=main \
						--check-binary=0 \
						--stable
					
					[ -n "$auth_user" ] && set -- "$@" "$auth_user"
					[ -n "$auth_pass" ] && set -- "$@" "$auth_pass"
					[ -n "$pkg_prefs" ] && set -- "$@" "--pkg-prefs=$pkg_prefs"
					[ -n "$repo_prefs" ] && set -- "$@" "--repo-prefs=$repo_prefs"
					
					sh "$script" "$@"
					;;
			esac
			;;
		cloudmin)
			case "$type" in
				prerelease)
					set -- \
						--force \
						--prerelease-host="$cloudmin_prerelease_host" \
						--name=cloudmin \
						--dist=cloudmin \
						--description=Cloudmin \
						--component=main \
						--check-binary=0 \
						--prerelease
					
					[ -n "$auth_user" ] && set -- "$@" "$auth_user"
					[ -n "$auth_pass" ] && set -- "$@" "$auth_pass"
					[ -n "$pkg_prefs" ] && set -- "$@" "--pkg-prefs=$pkg_prefs"
					[ -n "$repo_prefs" ] && set -- "$@" "--repo-prefs=$repo_prefs"

					sh "$script" "$@"
					;;
				unstable)
					set -- \
						--force \
						--unstable-host="$cloudmin_unstable_host" \
						--name=cloudmin \
						--dist=cloudmin \
						--description=Cloudmin \
						--component=main \
						--check-binary=0 \
						--unstable
					
					[ -n "$auth_user" ] && set -- "$@" "$auth_user"
					[ -n "$auth_pass" ] && set -- "$@" "$auth_pass"
					[ -n "$pkg_prefs" ] && set -- "$@" "--pkg-prefs=$pkg_prefs"
					[ -n "$repo_prefs" ] && set -- "$@" "--repo-prefs=$repo_prefs"
					
					sh "$script" "$@"
					;;
			esac
			;;
	esac
	
	ret=$?
	rm -f "$script"
	return $ret
}

usage() {
	if [ -n "${1-}" ]; then
		echo "Error: $1"
		echo
	fi
	echo "Usage: ${0##*/} <webmin|virtualmin|cloudmin> <stable|prerelease|unstable>"
	exit "${2:-1}"
}

main() {
	# Check for help flags
	case "${1-}" in
		-h|--help)
			usage "" 0
			;;
	esac

	# Validate number of arguments
	if [ $# -ne 2 ]; then
		usage "Wrong number of arguments"
	fi

	product="$1"
	repo_type="$2"
	
	# Validate arguments
	case "$product" in
		webmin|virtualmin|cloudmin) ;;
		*) usage "Invalid product name" ;;
	esac
	
	case "$repo_type" in
		stable|prerelease|unstable) ;;
		*) usage "Invalid repository type" ;;
	esac
	
	# Setup repository
	setup_repo "$product" "$repo_type"
	exit $?
}

main "$@"
