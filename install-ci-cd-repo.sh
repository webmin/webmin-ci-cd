#!/bin/sh
# shellcheck disable=SC2317
# install-ci-cd-repo.sh (https://github.com/webmin/webmin-ci-cd)
# Copyright Ilia Ross <ilia@webmin.dev>
# Licensed under the MIT License
#
# Installs package repository configuration for CI/CD builds

url="https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh"
virtualmin_license_file="/etc/virtualmin-license"
virtualmin_unstable_host="software.virtualmin.dev"
virtualmin_prerelease_host="rc.software.virtualmin.dev"

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

set_virtualmin_package_preferences() {
    fn_auth_user="$1"
    fn_auth_pass="$2"
    if [ -z "$fn_auth_user" ] || [ -z "$fn_auth_pass" ]; then
        echo "deb:webmin-virtual-server=1001=gpl rpm:wbm-virtual-server*pro*"
    fi
    return 0
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
    
    # Call package preference function if it exists
    pkg_prefs=""
    func="set_${product}_package_preferences"
    if command -v "$func" >/dev/null 2>&1; then
      pkg_prefs=$(eval "$func" "$auth_user" "$auth_pass")
    fi

    case "$product" in
        webmin)
            case "$type" in
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
    echo "Usage: ${0##*/} <webmin|virtualmin> <prerelease|unstable>"
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
        webmin|virtualmin) ;;
        *) usage "Invalid product name" ;;
    esac
    
    case "$repo_type" in
        prerelease|unstable) ;;
        *) usage "Invalid repository type" ;;
    esac
    
    # Setup repository
    setup_repo "$product" "$repo_type"
    exit $?
}

main "$@"
