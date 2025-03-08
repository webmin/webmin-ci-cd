#!/usr/bin/env bash
# shellcheck disable=SC2181
# sync-github-secrets.bash (https://github.com/webmin/webmin-ci-cd)
# Copyright Ilia Ross <ilia@webmin.dev>
# Licensed under the MIT License
#
# Update, delete, or list GitHub secrets dynamically
# based on organization and repository

# Enable strict mode
set -euo pipefail

# Configuration
secrets_zip="${ENV_SECRETS_ZIP:-$HOME/Git/.secrets/gh-secrets.zip}"
temp_dir="/tmp/gh-secrets-$$"

# Repository lists
webmin_repos=(
	"webmin/webmin"
	"webmin/usermin"
	"webmin/authentic-theme"
)

virtualmin_repos=(
	"virtualmin/virtualmin-gpl"
	"virtualmin/virtualmin-pro"
	"virtualmin/virtualmin-awstats"
	"virtualmin/virtualmin-htpasswd"
	"virtualmin/virtualmin-mailman"
	"virtualmin/virtualmin-nginx-ssl"
	"virtualmin/virtualmin-nginx"
	"virtualmin/virtualmin-registrar"
	"virtualmin/virtualmin-support"
	"virtualmin/ruby-gems"
	"virtualmin/webmin-jailkit"
	"virtualmin/procmail-wrapper"
	"virtualmin/Virtualmin-Config"
	"virtualmin/virtualmin-core-meta"
	"virtualmin/virtualmin-stack-meta"
	"virtualmin/virtualmin-yum-groups"
	"virtualmin/virtualmin-wp-workbench"
	"virtualmin/slib"
	"virtualmin/virtualmin-install"
)

cloudmin_repos=(
	"virtualmin/cloudmin-yum-groups cloudmin"
	"virtualmin/cloudmin-core-meta cloudmin"
	"virtualmin/cloudmin-stack-meta cloudmin"
	"virtualmin/Cloudmin-Config"
)

# Secret names
secrets=(
	"DEV_GPG_PH"
	"DEV_IP_ADDR"
	"DEV_IP_KNOWN_HOSTS"
	"DEV_UPLOAD_SSH_USER"
	"DEV_UPLOAD_SSH_DIR"
	"DEV_SSH_PRV_KEY"
	"DEV_SIGN_BUILD_REPOS_CMD"
	"PRERELEASE_UPLOAD_SSH_DIR"
)

# Cleanup function
function cleanup {
	if [ -d "$temp_dir" ]; then
		rm -rf "$temp_dir"
	fi
}

trap cleanup EXIT

# Function to print usage
function usage {
	cat << EOF
Usage: $0 [OPTIONS]

Options:
	-r, --repo <repo>      Target a specific repository (format: owner/repo)
	-s, --secret <secret>  Target a specific secret for update or delete
	-d, --delete           Delete secrets instead of updating them
	-l, --list             List current secrets in repositories
	-h, --help             Show this help message

Examples:
	Update all secrets for all repositories
		$0

	Update all secrets for specific repositories                     
		$0 -r webmin/webmin -r webmin/usermin

	Update specific secrets for all repositories
		$0 -s DEV_GPG_PH -s DEV_IP_ADDR

	Update specific secrets for specific repositories
		$0 -r webmin/webmin -r webmin/usermin -s DEV_GPG_PH -s DEV_IP_ADDR

	Delete secrets for virtualmin/virtualmin-awstats
		$0 -r virtualmin/virtualmin-awstats -d

	List all secrets for all repositories
		$0 -l

	List secrets for specific repository
		$0 -l -r webmin/webmin
EOF
	exit 1
}

# Check if a repository is valid
function is_valid_repo {
	local user_input="$1"
	local user_base
	user_base=$(echo "$user_input" | awk '{print $1}')
	
	for r in "${webmin_repos[@]}" "${virtualmin_repos[@]}" "${cloudmin_repos[@]}"; do
		local arr_base
		arr_base=$(echo "$r" | awk '{print $1}')
		if [ "$arr_base" = "$user_base" ]; then
			return 0
		fi
	done
	return 1
}

# Check if a secret is valid
function is_valid_secret {
	local secret="$1"
	for s in "${secrets[@]}"; do
		if [[ "$secret" == "$s" ]]; then
			return 0
		fi
	done
	return 1
}

# List secrets for a repository
function list_repo_secrets {
	local repo="$1"
	local base_repo
	base_repo=$(echo "$repo" | awk '{print $1}')
	local org
	org=$(echo "$base_repo" | awk -F/ '{print $1}')
	
	echo "Listing secrets for $base_repo .."
	
	# Get all secrets from the repository
	local secrets_json
	secrets_json=$(gh secret list --repo "$base_repo" --json name,updatedAt 2>/dev/null)
	if [ $? -ne 0 ]; then
		echo "  Error: Failed to list secrets for $base_repo"
		return 1
	fi

	if [ "$secrets_json" = "[]" ]; then
		echo ".. warning : no secrets found"
		return 0
	fi

	if command -v jq >/dev/null 2>&1; then
		echo "$secrets_json" | jq -r '.[] | "  \(.name) (Last updated: \(.updatedAt))"'
	else
		echo "$secrets_json" \
		  | grep -o '"name":"[^"]*"' \
		  | cut -d'"' -f4 \
		  | while read -r sec; do
			  echo "  $sec"
		    done
	fi
}

# Parse command line arguments
declare -a selected_repos=()
declare -a selected_secrets=()
delete=0
list=0

while [[ $# -gt 0 ]]; do
	case $1 in
		-r|--repo)
			if [[ -z "$2" || "$2" == -* ]]; then
				echo "Error: --repo requires a value"
				exit 1
			fi
			base_repo=$(echo "$2" | awk '{print $1}')
			if ! is_valid_repo "$2"; then
				echo "Error: Invalid repository: $base_repo"
				exit 1
			fi
			selected_repos+=("$2")
			shift 2
			;;
		-s|--secret)
			if [[ -z "$2" || "$2" == -* ]]; then
				echo "Error: --secret requires a value"
				exit 1
			fi
			if ! is_valid_secret "$2"; then
				echo "Error: Invalid secret: $2"
				exit 1
			fi
			selected_secrets+=("$2")
			shift 2
			;;
		-d|--delete)
			delete=1
			shift
			;;
		-l|--list)
			list=1
			shift
			;;
		-h|--help)
			usage
			;;
		*)
			echo "Unknown option: $1"
			usage
			;;
	esac
done

# Handle listing secrets
if [ "$list" -eq 1 ]; then
	# Determine which repositories to list
	repos_to_list=()
	if [ ${#selected_repos[@]} -gt 0 ]; then
		repos_to_list=("${selected_repos[@]}")
	else
		repos_to_list=(
			"${webmin_repos[@]}"
			"${virtualmin_repos[@]}"
			"${cloudmin_repos[@]}"
		)
	fi

	# List secrets for each repository
	for repo in "${repos_to_list[@]}"; do
		list_repo_secrets "$repo"
		echo
	done
	exit 0
fi

# Check if the secrets zip exists unless deleting
if [ "$delete" -eq 0 ] && [ ! -f "$secrets_zip" ]; then
	echo "Error: Secrets zip '$secrets_zip' file not found"
	exit 1
fi

# Create temp dir
mkdir -p "$temp_dir"

# Extract secrets if updating
if [ "$delete" -eq 0 ]; then
	# Ask for the ZIP passphrase
	read -r -s -p "Enter passphrase for secrets zip: " zip_pass
	echo

	# Extract secrets to the temporary directory
	if ! unzip -P "$zip_pass" -d "$temp_dir" "$secrets_zip" > /dev/null 2>&1; then
		echo "Error: Failed to extract secrets : Invalid passphrase or access to the file is insufficient"
		exit 1
	fi
fi

# Update secrets
function update_repo_secrets {
	local repo="$1"
	local base_repo
	base_repo=$(echo "$repo" | awk '{print $1}')
	local org
	org=$(echo "$base_repo" | awk -F/ '{print $1}')
	local prefix
	prefix=$(echo "$repo" | awk '{print $2}')

	# Use second token if present
	if [ -n "$prefix" ]; then
		org="$prefix"
	fi

	echo "Updating secrets for $repo .."
	
	# Determine which secrets to update
	local secrets_to_update=()
	if [ ${#selected_secrets[@]} -gt 0 ]; then
		for s in "${selected_secrets[@]}"; do
			secrets_to_update+=("${s#*__}")
		done
	else
		secrets_to_update=("${secrets[@]}")
	fi
	
	# Update each secret
	for s in "${secrets_to_update[@]}"; do
		local full_secret_name="${org}__${s}"
		local secret_file="$temp_dir/${full_secret_name}"
		echo "  Updating $s .."
		if [ -f "$secret_file" ]; then
			local err
			err=$(gh secret set "$s" --repo "$base_repo" < "$secret_file" 2>&1)
			if [ $? -ne 0 ]; then
				echo "  .. failed : $err"
			else
				echo "  .. done"
			fi
		else
			echo "  .. warning : secret file '$secret_file' not found for '$s'"
		fi
	done
}

# Delete secrets
function delete_repo_secrets {
	local repo="$1"
	local base_repo
	base_repo=$(echo "$repo" | awk '{print $1}')
	local org
	org=$(echo "$base_repo" | awk -F/ '{print $1}')
	local prefix
	prefix=$(echo "$repo" | awk '{print $2}')

	# Use second token if present
	if [ -n "$prefix" ]; then
		org="$prefix"
	fi

	echo "Deleting secrets for $repo .."
	
	# Determine which secrets to delete
	local secrets_to_delete=()
	if [ ${#selected_secrets[@]} -gt 0 ]; then
		for s in "${selected_secrets[@]}"; do
			secrets_to_delete+=("${s#*__}")
		done
	else
		secrets_to_delete=("${secrets[@]}")
	fi
	
	# Delete each secret
	for s in "${secrets_to_delete[@]}"; do
		echo "  Deleting $s .."
		local err
		err=$(gh secret remove "$s" --repo "$base_repo" 2>&1)
		if [ $? -ne 0 ]; then
			echo "  .. failed : $err"
		else
			echo "  .. done"
		fi
	done
}

# Determine which repositories to act on
repos_to_update=()
if [ ${#selected_repos[@]} -gt 0 ]; then
	repos_to_update=("${selected_repos[@]}")
else
	repos_to_update=(
		"${webmin_repos[@]}"
		"${virtualmin_repos[@]}"
		"${cloudmin_repos[@]}"
	)
fi

# Perform the update or delete operation for each repository
for repo in "${repos_to_update[@]}"; do
	if [ "$delete" -eq 1 ]; then
		delete_repo_secrets "$repo"
	else
		update_repo_secrets "$repo"
	fi
done