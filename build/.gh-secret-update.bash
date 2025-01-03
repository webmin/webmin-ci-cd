#!/usr/bin/env bash
# .gh-secret-update.bash
# Update, delete, or list GitHub secrets dynamically
# based on organization and repository

# Configuration
SECRETS_ZIP="${ENV_SECRETS_ZIP:-$HOME/.tmp/gh-secrets.zip}"
TEMP_DIR="/tmp/gh-secrets-$$"

# Repository lists
WEBMIN_REPOS=(
    "webmin/webmin"
    "webmin/usermin"
    "webmin/authentic-theme"
)

VIRTUALMIN_REPOS=(
    "virtualmin/ruby-gems"
    "virtualmin/virtualmin-awstats"
    "virtualmin/virtualmin-htpasswd"
    "virtualmin/virtualmin-mailman"
    "virtualmin/virtualmin-nginx-ssl"
    "virtualmin/virtualmin-nginx"
    "virtualmin/virtualmin-registrar"
    "virtualmin/virtualmin-support"
    "virtualmin/webmin-jailkit"
)

# Secret names
SECRETS=(
    "DEV_GPG_PH"
    "DEV_IP_ADDR"
    "DEV_IP_KNOWN_HOSTS"
    "DEV_UPLOAD_SSH_USER"
    "DEV_UPLOAD_SSH_DIR"
    "DEV_SSH_PRV_KEY"
    "DEV_SIGN_BUILD_REPOS_CMD"
)

# Cleanup function
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT

# Function to print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    -r, --repo REPO       Target a specific repository (format: owner/repo)
    -s, --secret SECRET   Target a specific secret for update or delete
    -d, --delete          Delete secrets instead of updating them
    -l, --list            List current secrets in repositories
    -h, --help            Show this help message

Examples:
    Update all secrets for all repositories
        $0

    Update all secrets for webmin/webmin                     
        $0 -r webmin/webmin

    Update webmin__DEV_GPG_PH for all repositories
        $0 -s webmin__DEV_GPG_PH

    Delete secrets for virtualmin/virtualmin-awstats
        $0 -r virtualmin/virtualmin-awstats -d

    List all secrets for all repositories
        $0 -l

    List secrets for specific repository
        $0 -l -r webmin/webmin
EOF
    exit 1
}

# Function to check if a repository is valid
is_valid_repo() {
    local repo="$1"
    for r in "${WEBMIN_REPOS[@]}" "${VIRTUALMIN_REPOS[@]}"; do
        if [ "$r" = "$repo" ]; then
            return 0
        fi
    done
    return 1
}

# Function to check if a secret is valid
is_valid_secret() {
    local secret="$1"
    for s in "${SECRETS[@]}"; do
        if [[ "$secret" == "$s" ]]; then
            return 0
        fi
    done
    return 1
}

# Function to list secrets for a repository
list_repo_secrets() {
    local repo="$1"
    local org
    org=$(echo "$repo" | awk -F/ '{print $1}')
    
    echo "Listing secrets for $repo .."
    
    # Get all secrets from the repository
    local secrets_json
    secrets_json=$(gh secret list --repo "$repo" --json name,updatedAt 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo "  Error: Failed to list secrets for $repo"
        return 1
    fi

    if [ "$secrets_json" = "[]" ]; then
        echo ".. warning : no secrets found"
        return 0
    fi

    if command -v jq >/dev/null 2>&1; then
        echo "$secrets_json" | jq -r '.[] | "  \(.name) (Last updated: \(.updatedAt))"'
    else
        # Fallback to simple output if jq is not available
        echo "$secrets_json" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | while read -r secret; do
            echo "  $secret"
        done
    fi
}

# Parse command line arguments
REPO=""
SECRET=""
DELETE=0
LIST=0

while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--repo)
            REPO="$2"
            if ! is_valid_repo "$REPO"; then
                echo "Error: Invalid repository: $REPO"
                exit 1
            fi
            shift 2
            ;;
        -s|--secret)
            SECRET="$2"
            if ! is_valid_secret "$SECRET"; then
                echo "Error: Invalid secret: $SECRET"
                exit 1
            fi
            shift 2
            ;;
        -d|--delete)
            DELETE=1
            shift
            ;;
        -l|--list)
            LIST=1
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
if [ "$LIST" -eq 1 ]; then
    # Determine which repositories to list
    repos_to_list=()
    if [ -n "$REPO" ]; then
        repos_to_list=("$REPO")
    else
        repos_to_list=("${WEBMIN_REPOS[@]}" "${VIRTUALMIN_REPOS[@]}")
    fi

    # List secrets for each repository
    for repo in "${repos_to_list[@]}"; do
        list_repo_secrets "$repo"
        echo
    done
    exit 0
fi

# Check if the secrets zip exists unless deleting
if [ "$DELETE" -eq 0 ] && [ ! -f "$SECRETS_ZIP" ]; then
    echo "Error: Secrets zip '$SECRETS_ZIP' file not found"
    exit 1
fi

# Create a temporary directory
mkdir -p "$TEMP_DIR"

# Extract secrets if updating
if [ "$DELETE" -eq 0 ]; then
    # Ask for the ZIP passphrase
    read -s -p "Enter passphrase for secrets zip: " ZIP_PASS
    echo

    # Extract secrets to the temporary directory
    if ! unzip -P "$ZIP_PASS" -d "$TEMP_DIR" "$SECRETS_ZIP" > /dev/null 2>&1; then
        echo "Error: Failed to extract secrets—invalid passphrase or insufficient access to the documents"
        exit 1
    fi
fi

# Function to update secrets for a repository
update_repo_secrets() {
    local repo="$1"
    local org
    org=$(echo "$repo" | awk -F/ '{print $1}')
    
    echo "Updating secrets for $repo .."
    
    # Determine which secrets to update
    local secrets_to_update=("${SECRETS[@]}")
    if [ -n "$SECRET" ]; then
        secrets_to_update=("${SECRET#*__}")
    fi
    
    # Update each secret
    for secret in "${secrets_to_update[@]}"; do
        local full_secret_name="${org}__${secret}"
        local secret_file="$TEMP_DIR/${full_secret_name}"
        echo "  Updating $secret .."
        if [ -f "$secret_file" ]; then
            local err
            err=$(gh secret set "$secret" --repo "$repo" < "$secret_file" 2>&1)
            if [ $? -ne 0 ]; then
                echo "  .. failed : $err"
            else
                echo "  .. done"
            fi
        else
            echo "  .. warning : secret file '$secret_file' not found for '$secret'"
        fi
    done
}

# Function to delete secrets for a repository
delete_repo_secrets() {
    local repo="$1"
    local org
    org=$(echo "$repo" | awk -F/ '{print $1}')
    
    echo "Deleting secrets for $repo .."
    
    # Determine which secrets to delete
    local secrets_to_delete=("${SECRETS[@]}")
    if [ -n "$SECRET" ]; then
        secrets_to_delete=("${SECRET#*__}")
    fi
    
    # Delete each secret
    for secret in "${secrets_to_delete[@]}"; do
        echo "  Deleting $secret .."
        local err
        err=$(gh secret remove "$secret" --repo "$repo" 2>&1)
        if [ $? -ne 0 ]; then
            echo "  .. failed : $err"
        else
            echo "  .. done"
        fi
    done
}

# Determine which repositories to update or delete
repos_to_update=()
if [ -n "$REPO" ]; then
    repos_to_update=("$REPO")
else
    repos_to_update=("${WEBMIN_REPOS[@]}" "${VIRTUALMIN_REPOS[@]}")
fi

# Perform the update or delete operation for each repository
for repo in "${repos_to_update[@]}"; do
    if [ "$DELETE" -eq 1 ]; then
        delete_repo_secrets "$repo"
    else
        update_repo_secrets "$repo"
    fi
done