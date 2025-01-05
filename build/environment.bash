#!/usr/bin/env bash
# shellcheck disable=SC2034
# environment.bash
# Copyright Ilia Ross <ilia@webmin.dev>
# Configures environment variables for the build process

# Builder email
export BUILDER_PACKAGE_NAME="${ENV__BUILDER_NAME:-webmin/webmin-ci-cd}"
export BUILDER_PACKAGE_EMAIL="${ENV__BUILDER_EMAIL:-ilia@webmin.dev}"
export BUILDER_MODULE_EMAIL="${ENV__BUILDER_EMAIL:-ilia@virtualmin.dev}"

# Set defaults
export ROOT_DIR="${ENV__ROOT:-$HOME}"
export ROOT_REPOS="${ENV__ROOT_REPOS:-$ROOT_DIR/repo}"
export ROOT_BUILD="${ENV__ROOT_BUILD:-$ROOT_DIR/rpmbuild}"
export ROOT_RPMS="${ENV__ROOT_RPMS:-$ROOT_BUILD/RPMS/noarch}"

# Cloud upload config
export CLOUD_UPLOAD_GPG_PASSPHRASE="${CLOUD__GPG_PH-}"
export CLOUD_UPLOAD_SSH_HOST="${CLOUD__IP_ADDR-}"
export CLOUD_UPLOAD_SSH_KNOWN_HOSTS="${CLOUD__IP_KNOWN_HOSTS-}"
export CLOUD_UPLOAD_SSH_USER="${CLOUD__UPLOAD_SSH_USER-ghost}"
export CLOUD_UPLOAD_SSH_DIR="${CLOUD__UPLOAD_SSH_DIR-}"
export CLOUD_SSH_PRV_KEY="${CLOUD__SSH_PRV_KEY-}"
export CLOUD_SIGN_BUILD_REPOS_CMD="${CLOUD__SIGN_BUILD_REPOS_CMD-}"
export CLOUD_GH_TOKEN="${CLOUD__GH_TOKEN-}"

# Define verbosity level
export VERBOSE_MODE=0
export VERBOSITY_LEVEL=' >/dev/null 2>&1 </dev/null'
export VERBOSITY_LEVEL_TO_FILE='2> /dev/null'
export VERBOSITY_LEVEL_WITH_INPUT=' >/dev/null 2>&1'
if [[ "'$*'" == *"--verbose"* ]]; then
    echo "Enabling verbose mode"
    VERBOSE_MODE=1
    VERBOSITY_LEVEL=''
    VERBOSITY_LEVEL_TO_FILE=''
    VERBOSITY_LEVEL_WITH_INPUT=''
fi

# Define testing build
export TESTING_BUILD=0
if [[ "'$*'" == *"--testing"* ]]; then
    echo "Enabling testing build"
    export TESTING_BUILD=1
fi

# Project links
export GIT_BASE_URL="https://github.com"
export GIT_AUTH_URL="$GIT_BASE_URL"
if [ -n "$CLOUD_GH_TOKEN" ]; then
    export GIT_AUTH_URL="https://oauth2:${CLOUD_GH_TOKEN}@github.com"
fi
export WEBMIN_ORG_URL="$GIT_BASE_URL/webmin"
export WEBMIN_REPO="$WEBMIN_ORG_URL/webmin"
export VIRTUALMIN_ORG_AUTH_URL="$GIT_AUTH_URL/virtualmin"