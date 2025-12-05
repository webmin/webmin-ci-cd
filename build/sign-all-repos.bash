#!/usr/bin/env bash
# shellcheck disable=SC2155 disable=SC2034
# sign-all-repos.bash (https://github.com/webmin/webmin-ci-cd)
# Copyright Ilia Ross <ilia@webmin.dev>
# Licensed under the MIT License
#
# Script to manually sign and build all repositories in known target
#
# Usage:
#   ./sign-all-repos.bash
#   ./sign-all-repos.bash download.webmin.dev
#   ./sign-all-repos.bash software.virtualmin.dev
#   ./sign-all-repos.bash rc.software.virtualmin.dev promote

set -euo pipefail

function main() {
    local repo_dir
    local domain_name
    local base_domain
    local target_domain="${1:-}"
    local promote="${2:-}"
    
    for repo_dir in "$HOME"/domains/*/; do
        # Remove trailing slash
        repo_dir=${repo_dir%/}
        
        # Get just the directory name (domain name)
        domain_name=$(basename "$repo_dir")

        # Skip if target domain specified and doesn't match
        if [[ -n "$target_domain" && "$domain_name" != "$target_domain" ]]; then
            echo "Skipping $domain_name, does not match target $target_domain"
            continue
        fi
        
        # Extract the based domain name (e.g. webmin.dev or virtualmin.dev)
        base_domain=$(echo "$domain_name" | awk -F. '{print $(NF-1)"."$NF}')

        # Repository directory is in public_html
        repo_dir="$repo_dir/public_html"
        if [ ! -d "$repo_dir" ]; then
            echo "Error: Directory $repo_dir does not exist! Skipping..."
            continue
        fi

        echo "--------------------------------------------------------------------------------"
        echo "Domain   : $domain_name"
        echo "Directory: $repo_dir"
        echo "--------------------------------------------------------------------------------"
        
        # Run the signing and building script with colored output and line
        # wrapping
        stdbuf -oL sign-repo.bash "$repo_dir" "$base_domain" "$promote" 2>&1 | \
            stdbuf -oL fold -w 80 -s | while IFS= read -r line; do
                    printf "\033[47m\033[30m%-80s\033[0m\n" "$line"
            done
    done
}

main "$@"
