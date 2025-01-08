#!/bin/sh
# install-ci-cd-repo.sh (https://github.com/webmin/webmin-ci-cd)
# Copyright 2025 Ilia Ross <ilia@webmin.dev>
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
