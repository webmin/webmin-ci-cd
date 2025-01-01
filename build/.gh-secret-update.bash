#!/usr/bin/env bash
# .gh-secret-update.bash
# Update GitHub secrets dynamically based on organization and repository using
# local secrets zip file

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
    "DEV_UPLOAD_SSH_USER"
    "DEV_UPLOAD_SSH_DIR"
    "DEV_SSH_PRV_KEY"
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
    -r, --repo REPO       Update secrets for a specific repository (format: owner/repo)
    -s, --secret SECRET   Update a specific secret across repositories or within a repository
    -h, --help            Show this help message

Examples:
    Update all secrets for all repositories
        $0

    Update all secrets for webmin/webmin                     
        $0 -r webmin/webmin

    Update webmin__DEV_GPG_PH for all repositories
        $0 -s webmin__DEV_GPG_PH

    Update virtualmin__DEV_GPG_PH for virtualmin/virtualmin-awstats only
        $0 -r virtualmin/virtualmin-awstats -s virtualmin__DEV_GPG_PH
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

# Parse command line arguments
REPO=""
SECRET=""

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
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Check if the secrets zip exists
if [ ! -f "$SECRETS_ZIP" ]; then
    echo "Error: Secrets zip '$SECRETS_ZIP' file not found"
    exit 1
fi

# Create a temporary directory
mkdir -p "$TEMP_DIR"

# Ask for the ZIP passphrase
read -s -p "Enter passphrase for secrets zip: " ZIP_PASS
echo

# Extract secrets to the temporary directory
if ! unzip -P "$ZIP_PASS" -d "$TEMP_DIR" "$SECRETS_ZIP" > /dev/null 2>&1; then
    echo "Error: Failed to extract secrets—invalid passphrase or insufficient access to the documents"
    exit 1
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

# Determine which repositories to update
repos_to_update=()
if [ -n "$REPO" ]; then
    repos_to_update=("$REPO")
else
    repos_to_update=("${WEBMIN_REPOS[@]}" "${VIRTUALMIN_REPOS[@]}")
fi

# Update secrets for each repository
for repo in "${repos_to_update[@]}"; do
    update_repo_secrets "$repo"
done