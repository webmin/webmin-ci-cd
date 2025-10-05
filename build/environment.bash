#!/usr/bin/env bash
# shellcheck disable=SC2034
# environment.bash (https://github.com/webmin/webmin-ci-cd)
# Copyright Ilia Ross <ilia@webmin.dev>
# Licensed under the MIT License
#
# Configures environment variables for the build process

# Extract the value of a specific flag
function get_flag {
	local flag=$1
	shift

	# If no arguments provided, use original global ARGV variable
	if [ $# -eq 0 ] && [ -n "$ARGV" ]; then
		local IFS=' '
		set -- $ARGV
	fi
	for arg in "$@"; do
		case $arg in
			"$flag")
				return 0
				;;
			"$flag"=*)
				echo "${arg#*=}"  # return the value
				return 0
				;;
		esac
	done

	return 1  # not found
}

# Save global argvs
export ARGV="$*"

# Builder email
export BUILDER_PACKAGE_NAME="${ENV__BUILDER_NAME:-webmin/webmin-ci-cd}"
export BUILDER_PACKAGE_EMAIL="${ENV__BUILDER_EMAIL:-developers@virtualmin.com}"
export BUILDER_MODULE_EMAIL="${ENV__BUILDER_EMAIL:-developers@virtualmin.com}"

# Set defaults
export ROOT_DIR="${ENV__ROOT:-$HOME}"
export ROOT_REPOS="${ENV__ROOT_REPOS:-$ROOT_DIR/repo}"
export ROOT_BUILD="${ENV__ROOT_BUILD:-$ROOT_DIR/rpmbuild}"
export ROOT_RPMS="${ENV__ROOT_RPMS:-$ROOT_BUILD/RPMS/noarch}"

# Cloud upload config
export CLOUD_BUILD_RUN_ATTEMPT="${CLOUD__BUILD_RUN_ATTEMPT:-1}"
export CLOUD_UPLOAD_GPG_PASSPHRASE="${CLOUD__GPG_PH-}"
export CLOUD_UPLOAD_SSH_HOST="${CLOUD__IP_ADDR-}"
export CLOUD_UPLOAD_SSH_KNOWN_HOSTS="${CLOUD__IP_KNOWN_HOSTS-}"
export CLOUD_UPLOAD_SSH_USER="${CLOUD__UPLOAD_SSH_USER-ghost}"
export CLOUD_UPLOAD_SSH_DIR="${CLOUD__UPLOAD_SSH_DIR-}"
export CLOUD_SSH_PRV_KEY="${CLOUD__SSH_PRV_KEY-}"
export CLOUD_SIGN_BUILD_REPOS_CMD="${CLOUD__SIGN_BUILD_REPOS_CMD-}"
export CLOUD_GH_TOKEN="${CLOUD__GH_TOKEN-}"

# Define verbosity level
if get_flag --verbose; then
	VERBOSITY_LEVEL=''
	VERBOSITY_LEVEL_TO_FILE=''
	VERBOSITY_LEVEL_WITH_INPUT=''
else
	VERBOSITY_LEVEL=' >/dev/null 2>&1 </dev/null'
	VERBOSITY_LEVEL_TO_FILE='2> /dev/null'
	VERBOSITY_LEVEL_WITH_INPUT=' >/dev/null 2>&1'
fi
export VERBOSITY_LEVEL VERBOSITY_LEVEL_TO_FILE VERBOSITY_LEVEL_WITH_INPUT

# Project links
export GIT_BASE_URL="https://github.com"
GIT_AUTH_URL="$GIT_BASE_URL"
if [ -n "$CLOUD_GH_TOKEN" ]; then
	GIT_AUTH_URL="https://oauth2:${CLOUD_GH_TOKEN}@github.com"
fi
export GIT_AUTH_URL
export WEBMIN_ORG_URL="$GIT_BASE_URL/webmin"
export WEBMIN_REPO="$WEBMIN_ORG_URL/webmin"
export VIRTUALMIN_ORG_AUTH_URL="$GIT_AUTH_URL/virtualmin"