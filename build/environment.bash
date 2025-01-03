#!/usr/bin/env bash
# shellcheck disable=SC2034
# environment.bash
# Copyright Ilia Ross <ilia@webmin.dev>
# Configures environment variables for the build process

# Builder email
BUILDER_PACKAGE_NAME="${ENV__BUILDER_NAME:-webmin/webmin-ci-cd}"
BUILDER_PACKAGE_EMAIL="${ENV__BUILDER_EMAIL:-ilia@webmin.dev}"
BUILDER_MODULE_EMAIL="${ENV__BUILDER_EMAIL:-ilia@virtualmin.dev}"

# Set defaults
ROOT_DIR="${ENV__ROOT:-$HOME}"
ROOT_REPOS="${ENV__ROOT_REPOS:-$ROOT_DIR/repo}"
ROOT_BUILD="${ENV__ROOT_BUILD:-$ROOT_DIR/rpmbuild}"
ROOT_RPMS="${ENV__ROOT_RPMS:-$ROOT_BUILD/RPMS/noarch}"

# Create symlinks for Perl
PERL_SOURCE="/usr/bin/perl"
PERL_TARGET="/usr/local/bin/perl"
ln -fs "$PERL_SOURCE" "$PERL_TARGET"

# Cloud upload config
CLOUD_UPLOAD_GPG_PASSPHRASE="${CLOUD__GPG_PH:-}"
CLOUD_UPLOAD_SSH_HOST="${CLOUD__IP_ADDR:-}"
CLOUD_UPLOAD_SSH_USER="${CLOUD__UPLOAD_SSH_USER:-ghost}"
CLOUD_UPLOAD_SSH_DIR="${CLOUD__UPLOAD_SSH_DIR:-}"
CLOUD_SSH_PRV_KEY="${CLOUD__SSH_PRV_KEY:-}"
CLOUD_SIGN_BUILD_REPOS_CMD="${CLOUD__SIGN_BUILD_REPOS_CMD:-}"
CLOUD_GH_TOKEN="${CLOUD__GH_TOKEN:-}"

# Define verbosity level
VERBOSITY_LEVEL=' >/dev/null 2>&1 </dev/null'
VERBOSITY_LEVEL_TO_FILE='2> /dev/null'
VERBOSITY_LEVEL_WITH_INPUT=' >/dev/null 2>&1'
if [[ "'$*'" == *"--verbose"* ]]; then
    unset VERBOSITY_LEVEL VERBOSITY_LEVEL_TO_FILE VERBOSITY_LEVEL_WITH_INPUT
fi

# Project links
GIT_BASE_URL="https://github.com"
GIT_AUTH_URL="$GIT_BASE_URL"
echo "Token exists: $([[ -n "$CLOUD_GH_TOKEN" ]] && echo "YES" || echo "NO")"
if [ -n "$CLOUD_GH_TOKEN" ]; then
    GIT_AUTH_URL="https://oauth2:${CLOUD_GH_TOKEN}@github.com"
fi
WEBMIN_ORG_URL="$GIT_BASE_URL/webmin"
WEBMIN_REPO="$WEBMIN_ORG_URL/webmin"
VIRTUALMIN_ORG_AUTH_URL="$GIT_AUTH_URL/virtualmin"
