#!/bin/bash
#
# Generate Release Notes
#
# This script generates comprehensive release notes by aggregating changes from:
# - gnosis_vpn-client repository (merged PRs between dates)
# - gnosis_vpn-app repository (merged PRs between dates)
# - gnosis_vpn Installer repository (merged PRs since last release)
#
#
# Example:
#   GNOSISVPN_PACKAGE_VERSION=0.56.5 \
#   GNOSISVPN_PREVIOUS_CLI_VERSION=0.54.4 \
#   GNOSISVPN_CLI_VERSION=0.56.1 \
#   GNOSISVPN_PREVIOUS_APP_VERSION=0.5.0 \
#   GNOSISVPN_APP_VERSION=0.6.1 \
#   GNOSISVPN_CHANGELOG_FORMAT=github \
#   ./generate-changelog.sh
#

set -euo pipefail

# Read from environment variables with defaults
: "${GNOSISVPN_PACKAGE_VERSION:=$(date +%Y.%m.%d+build.%H%M%S)}"
: "${GNOSISVPN_PREVIOUS_CLI_VERSION:?Error: GNOSISVPN_PREVIOUS_CLI_VERSION is required}"
: "${GNOSISVPN_CLI_VERSION:?Error: GNOSISVPN_CLI_VERSION is required}"
: "${GNOSISVPN_PREVIOUS_APP_VERSION:?Error: GNOSISVPN_PREVIOUS_APP_VERSION is required}"
: "${GNOSISVPN_APP_VERSION:?Error: GNOSISVPN_APP_VERSION is required}"
: "${GNOSISVPN_CHANGELOG_FORMAT:=github}"
: "${GNOSISVPN_BRANCH:=main}"
: "${GH_API_MAX_ATTEMPTS:=6}"

# Initialize changelog entries array
declare -a changelog_entries

# Decode the entry of a changelog
jq_decode() {
    echo "${1}" | base64 --decode
}

# Validate ISO8601 timestamp format
# Usage: validate_iso8601_date <date_string>
# Returns: 0 if valid, 1 if invalid
validate_iso8601_date() {
    local date_string="$1"
    
    # Check if empty
    if [[ -z "$date_string" ]]; then
        return 1
    fi
    
    # Check ISO8601 format: YYYY-MM-DDTHH:MM:SSZ or similar
    if [[ ! "$date_string" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$ ]]; then
        return 1
    fi
    
    # Additional validation: try to parse with date command
    if ! date -d "$date_string" &>/dev/null 2>&1; then
        # Try macOS date format
        if ! date -j -f "%Y-%m-%dT%H:%M:%S" "${date_string%Z}" &>/dev/null 2>&1; then
            return 1
        fi
    fi
    
    return 0
}

# Strict GitHub API wrapper with exponential backoff and throttling detection
# Usage: gh_api_call_with_retry <repo> <endpoint> <jq_query>
# Returns: API response or exits with error after max attempts
gh_api_call_with_retry() {
    local repo="$1"
    local endpoint="$2"
    local jq_query="$3"
    local attempt=1
    local max_attempts="${GH_API_MAX_ATTEMPTS}"
    local delay=2
    
    while (( attempt <= max_attempts )); do
        echo "[DEBUG] GitHub API call attempt ${attempt}/${max_attempts}: /repos/${repo}${endpoint}" >&2
        
        # Capture both stdout and stderr, and the exit code
        local temp_output=$(mktemp)
        local temp_error=$(mktemp)
        local exit_code=0
        
        gh api \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "/repos/${repo}${endpoint}" \
            --jq "${jq_query}" \
            >"$temp_output" \
            2>"$temp_error" || exit_code=$?
        
        local output=$(cat "$temp_output")
        local error=$(cat "$temp_error")
        rm -f "$temp_output" "$temp_error"
        
        # Check for throttling in error message or HTTP 429
        if [[ $exit_code -ne 0 ]] && ( \
            echo "$error" | grep -qi "rate limit\|throttle\|429\|too many requests" || \
            echo "$output" | grep -qi "rate limit\|throttle\|API rate limit exceeded" \
        ); then
            if (( attempt >= max_attempts )); then
                echo "[ERROR] GitHub API throttled after ${max_attempts} attempts. Rate limit exceeded." >&2
                echo "[ERROR] Endpoint: /repos/${repo}${endpoint}" >&2
                echo "[ERROR] Last error: ${error}" >&2
                exit 1
            fi
            
            echo "[WARN] GitHub API throttled (attempt ${attempt}/${max_attempts}). Retrying in ${delay}s..." >&2
            sleep "$delay"
            delay=$((delay * 2))
            attempt=$((attempt + 1))
            continue
        fi
        
        # Check for other errors
        if [[ $exit_code -ne 0 ]]; then
            echo "[ERROR] GitHub API request failed: ${error}" >&2
            echo "[ERROR] Endpoint: /repos/${repo}${endpoint}" >&2
            exit 1
        fi
        
        # Success - return the output
        echo "$output"
        return 0
    done
    
    # Should not reach here, but safety net
    echo "[ERROR] GitHub API call failed after ${max_attempts} attempts" >&2
    exit 1
}

# Helper function to call GitHub API
# Usage: gh_api_call <repo> <endpoint> <jq_query>
gh_api_call() {
    local repo="$1"
    local endpoint="$2"
    local jq_query="$3"
    
    gh_api_call_with_retry "${repo}" "${endpoint}" "${jq_query}"
}

# Get the creation date of a release tag
# Usage: get_release_date <repo> <tag>
get_release_date() {
    local repo="$1"
    local tag="$2"
    
    echo "[DEBUG] Fetching release date for ${repo}/${tag}" >&2
    local date=$(gh_api_call "${repo}" "/releases/tags/${tag}" '.created_at')
    
    # Validate the date format
    if ! validate_iso8601_date "$date"; then
        echo "[ERROR] Invalid or empty release date for ${repo}/${tag}: '${date}'" >&2
        echo "[ERROR] Expected ISO8601 timestamp format (e.g., 2024-01-15T10:30:00Z)" >&2
        exit 1
    fi
    
    echo "$date"
}

# Fetch merged PRs from a repository between two dates
# Usage: fetch_merged_prs <repo_name> <start_date> <end_date> <component> <branch>
fetch_merged_prs() {
    local repo_name="$1"
    local start_date="$2"
    local end_date="$3"
    local component="$4"
    local branch="${5:-main}"  # Default to main if not provided
    
    # Skip if dates are the same or empty
    if [[ -z "$start_date" || -z "$end_date" || "$start_date" == "$end_date" ]]; then
        return 0
    fi
    
    echo "[INFO] Fetching PRs for ${component} (branch: ${branch}) between ${start_date} and ${end_date}..." >&2
    
    # Fetch merged PRs on specified branch between the dates
    # Use the strict API wrapper instead of direct gh api call
    local prs=$(gh_api_call_with_retry "${repo_name}" "/pulls?state=closed&base=${branch}&sort=updated&direction=desc&per_page=100" '.[] | select(.merged_at != null and .merged_at > "'"${start_date}"'" and .merged_at <= "'"${end_date}"'") | @base64')
    
    if [[ -z "$prs" ]]; then
        echo "[INFO] No PRs found for ${component}" >&2
        return 0
    fi
    
    # Process each PR
    for pr_encoded in ${prs}; do
        local pr_decoded=$(jq_decode "${pr_encoded}")
        
        # Validate JSON format
        if ! echo "${pr_decoded}" | jq empty 2>/dev/null; then
            echo "[ERROR] Invalid JSON record: ${pr_decoded}" >&2
            continue
        fi
        
        local id=$(echo "${pr_decoded}" | jq -r '.number')
        local title=$(echo "${pr_decoded}" | jq -r '.title')
        local labels=$(echo "${pr_decoded}" | jq -r '[.labels[].name] | join(", ")' | sed 's/,$//')
        local state=$(echo "${pr_decoded}" | jq -r '.state' | tr '[:upper:]' '[:lower:]')
        local author=$(echo "${pr_decoded}" | jq -r '.user.login')
        local merged_at=$(echo "${pr_decoded}" | jq -r '.merged_at // empty' | awk -F 'T' '{print $1}')
        
        if [[ -z ${merged_at} ]]; then
            merged_at=$(date '+%Y-%m-%d') # Fallback to current date
        fi
        
        # Extract changelog_type from the title
        # Expected format: "type(component): description" or "type: description"
        # If no colon exists, type defaults to "other"
        if [[ "$title" == *":"* ]]; then
            local changelog_type=$(echo "${title}" | awk -F ':' '{print $1}' | awk -F '(' '{print $1}' | tr '[:upper:]' '[:lower:]' | xargs)
        else
            local changelog_type="other"
        fi
        
        # Trim whitespace from changelog_type
        changelog_type=${changelog_type## }
        changelog_type=${changelog_type%% }
        
        # Add fallback if still empty
        changelog_type=${changelog_type:-"other"}

        # Assign repository as component prefix to distinguish between repos
        echo "[DEBUG] Processing PR: id=${id}, title=${title}, author=${author}, labels=${labels}, merged_at=${merged_at}, type=${changelog_type}, component=${component}" >&2
        
        # Add to changelog entries array
        changelog_entries+=("$(jq -nc --arg id "$id" \
            --arg title "$title" \
            --arg author "$author" \
            --arg labels "$labels" \
            --arg state "$state" \
            --arg date "$merged_at" \
            --arg ctype "$changelog_type" \
            --arg comp "$component" \
            '{id:$id,title:$title,author:$author,labels:$labels,state:$state,date:$date,changelog_type:$ctype,component:$comp}')")
    done
}

# Build the changelog in GitHub format
github_format_changelog() {
    local section_feature="\n### New Features\n\n"
    local section_fix="\n### Fixes\n\n"
    local section_refactor="\n### Refactor\n\n"
    local section_ci="\n### Automation\n\n"
    local section_documentation="\n### Documentation\n\n"
    local section_other="\n### Other\n\n"
    
    local change_log_content="## What's Changed\n"
    
    # Add summary header
    if [[ "$previous_cli_version" != "$current_cli_version" ]] || [[ "$previous_app_version" != "$current_app_version" ]]; then
        change_log_content+="\nThis release contains the following component updates:\n\n"
        
        if [[ "$previous_cli_version" != "$current_cli_version" ]]; then
            change_log_content+="- **[GnosisVPN Client](https://github.com/gnosis/gnosis_vpn-client)**: Updated from [v${previous_cli_version}](https://github.com/gnosis/gnosis_vpn-client/releases/tag/v${previous_cli_version}) to [v${current_cli_version}](https://github.com/gnosis/gnosis_vpn-client/releases/tag/v${current_cli_version})\n"
        fi
        
        if [[ "$previous_app_version" != "$current_app_version" ]]; then
            change_log_content+="- **[GnosisVPN App](https://github.com/gnosis/gnosis_vpn-app)**: Updated from [v${previous_app_version}](https://github.com/gnosis/gnosis_vpn-app/releases/tag/v${previous_app_version}) to [v${current_app_version}](https://github.com/gnosis/gnosis_vpn-app/releases/tag/v${current_app_version})\n"
        fi
        
        change_log_content+="\n"
    fi
    
    # Process each changelog entry
    for entry in "${changelog_entries[@]}"; do
        local id=$(echo "$entry" | jq -r '.id')
        local title=$(echo "$entry" | jq -r '.title')
        local author=$(echo "$entry" | jq -r '.author')
        local component=$(echo "$entry" | jq -r '.component')
        local changelog_type=$(echo "$entry" | jq -r '.changelog_type')
        
        # Determine which section this entry belongs to
        case "$changelog_type" in
            feat|feature)
                section_feature+="- [${component}] ${title} by @${author} in #${id}\n"
                ;;
            fix|bugfix)
                section_fix+="- [${component}] ${title} by @${author} in #${id}\n"
                ;;
            refactor)
                section_refactor+="- [${component}] ${title} by @${author} in #${id}\n"
                ;;
            ci|cd|chore)
                section_ci+="- [${component}] ${title} by @${author} in #${id}\n"
                ;;
            docs|documentation)
                section_documentation+="- [${component}] ${title} by @${author} in #${id}\n"
                ;;
            *)
                section_other+="- [${component}] ${title} by @${author} in #${id}\n"
                ;;
        esac
    done
    
    # Add sections that have content
    for section in section_feature section_fix section_refactor section_ci section_documentation section_other; do
        if [[ ${!section} == *" by "* ]]; then
            change_log_content+="${!section}\n"
        fi
    done
    
    echo -e "${change_log_content}"
}

# Build the changelog in JSON format
json_format_changelog() {
    local change_log_content="$(printf '%s\n' "${changelog_entries[@]}" | jq -s -c '.')"
    echo -e "${change_log_content}"
}

# Function to determine the release type
get_release_type() {
    # Default to stable
    local release_type="stable"
    
    # Check for experimental, breaking, or release labels
    if [[ $(printf '%s\n' "${changelog_entries[@]}" | jq -r '.labels' | grep -E "experimental|breaking") ]]; then
        release_type="unstable"
    fi
    
    # Check if the version contains "-rc." or is the first release (x.y.0)
    if [[ ${next_release_version} == *"-rc."* ]] || [[ ${next_release_version} =~ ^[0-9]+\.[0-9]+\.0$ ]]; then
        release_type="unstable"
    fi
    
    echo "${release_type}"
}

# Function to determine the urgency level
get_urgency_level() {
    local version=${1}
    
    # Extract the patch number from the version
    local patch_number=$(echo ${version} | awk -F '.' '{print $3}' | awk -F '-' '{print $1}')
    
    # Determine urgency based on patch number
    if [[ ${version} == *"-rc."* ]] || [[ ${patch_number} -eq 0 ]]; then
        echo "optional"
    else
        echo "medium"
    fi
}

# Build the changelog in Debian format
debian_format_changelog() {
    local distribution=$(get_release_type)
    local urgency=$(get_urgency_level "${next_release_version}")
    local maintainer="GnosisVPN (Gnosis VPN) <tech@hoprnet.org>"
    local date="$(date -R)"
    
    # Ensure clean assignment to debian_changelog
    local debian_changelog="gnosisvpn (${next_release_version}) ${distribution}; urgency=${urgency}\n"
    
    for entry in "${changelog_entries[@]}"; do
        local id=$(echo "$entry" | jq -r '.id')
        local title=$(echo "$entry" | jq -r '.title')
        local author=$(echo "$entry" | jq -r '.author')
        
        # Check the length of the entry line and adjust if necessary
        # Debian policy recommends keeping changelog lines under 80 characters
        local entry_line="  * ${title} by @${author} in #${id}\n"
        
        if [[ ${#entry_line} -le 80 ]]; then
            debian_changelog+="${entry_line}"
        else
            # Truncate title to fit within 80 characters
            # (entry_line_length - title_length) = overhead indentation: " by @author in #id\n"
            # Substract 3 for the "..." that will be appended to the truncated title
            # Result: how many characters of the title we can use to stay under 80 chars
            local max_title_length=$((80 - (${#entry_line} - ${#title}) - 3))
            
            if ((max_title_length < 1)); then
                max_title_length=1
            fi
            
            local truncated_title=$(echo "${title}" | cut -c1-${max_title_length})
            debian_changelog+="  * ${truncated_title}... by @${author} in #${id}\n"
        fi
    done
    
    debian_changelog+="\n -- ${maintainer}  ${date}\n"
    
    echo -e "${debian_changelog}"
}

# Build the changelog in RPM format
rpm_format_changelog() {
    local rpm_changelog=""
    
    # Sort entries by date and author (newest first)
    local sorted_entries=$(printf '%s\n' "${changelog_entries[@]}" | jq -s 'sort_by([.date, .author]) | reverse')
    
    # Group entries by date and author, and build the changelog
    local current_date=""
    local current_author=""
    
    while read -r entry; do
        local id=$(echo "$entry" | jq -r '.id')
        local title=$(echo "$entry" | jq -r '.title')
        local author=$(echo "$entry" | jq -r '.author')
        local date=$(echo "$entry" | jq -r '.date')
        local changelog_type=$(echo "$entry" | jq -r '.changelog_type')
        local component=$(echo "$entry" | jq -r '.component')
        
        # Add date/author header when they change
        if [[ $date != "$current_date" || $author != "$current_author" ]]; then
            current_date="$date"
            current_author="$author"
            rpm_changelog+="* ${date} ${author} - ${next_release_version}\n"
        fi
        
        # Remove the type(component): prefix from title if present
        local clean_title=$(echo "$title" | sed -E 's/^.*\): //')
        
        # Add the changelog entry with type and component tags
        rpm_changelog+="- [${changelog_type}][${component}] ${clean_title} in #${id}\n"
    done <<<"$(echo "${sorted_entries}" | jq -c '.[]')"
    
    echo -e "${rpm_changelog}"
}

# Validate and assign variables from environment
validate_inputs() {
    next_release_version="$GNOSISVPN_PACKAGE_VERSION"
    previous_cli_version="$GNOSISVPN_PREVIOUS_CLI_VERSION"
    current_cli_version="$GNOSISVPN_CLI_VERSION"
    previous_app_version="$GNOSISVPN_PREVIOUS_APP_VERSION"
    current_app_version="$GNOSISVPN_APP_VERSION"
    format="$GNOSISVPN_CHANGELOG_FORMAT"
    branch="$GNOSISVPN_BRANCH"
    
    # Validate format
    case "$format" in
        github|debian|json|rpm)
            ;;
        *)
            echo "Error: Unsupported format: ${format}"
            echo "Supported formats: github, debian, json, rpm"
            exit 1
            ;;
    esac
}

# Main function
main() {
    # Validate inputs from environment
    validate_inputs
    
    echo "Generating release notes..." >&2
    echo "  Package version: v${next_release_version}" >&2
    echo "  Client: v${previous_cli_version} -> v${current_cli_version}" >&2
    echo "  App: v${previous_app_version} -> v${current_app_version}" >&2
    echo "  Format: ${format}" >&2
    echo "  Branch: ${branch}" >&2
    echo "" >&2
    
    # Get release dates for version boundaries
    local cli_previous_date=""
    local cli_current_date=""
    local app_previous_date=""
    local app_current_date=""
    local pkg_last_release_date=""
    local changelog_entries=()
    
    # Fetch CLI dates if versions differ
    if [[ "$previous_cli_version" != "$current_cli_version" ]]; then
        cli_previous_date=$(get_release_date "gnosis/gnosis_vpn-client" "v${previous_cli_version}")
        cli_current_date=$(get_release_date "gnosis/gnosis_vpn-client" "v${current_cli_version}")
        echo "[INFO] CLI date range: ${cli_previous_date} to ${cli_current_date}" >&2
    fi
    
    # Fetch App dates if versions differ
    if [[ "$previous_app_version" != "$current_app_version" ]]; then
        app_previous_date=$(get_release_date "gnosis/gnosis_vpn-app" "v${previous_app_version}")
        app_current_date=$(get_release_date "gnosis/gnosis_vpn-app" "v${current_app_version}")
        echo "[INFO] App date range: ${app_previous_date} to ${app_current_date}" >&2
    fi
    
    # Get the last release tag for packaging repo
    local last_release_tag=""
    echo "[DEBUG] Fetching last release tag for gnosis/gnosis_vpn" >&2
    
    # Try to get the last release tag, but don't fail if there are no releases
    local temp_output=$(mktemp)
    local temp_error=$(mktemp)
    local exit_code=0
    
    gh release list --limit 1 --json tagName --jq '.[0].tagName' \
        >"$temp_output" \
        2>"$temp_error" || exit_code=$?
    
    last_release_tag=$(cat "$temp_output")
    local error=$(cat "$temp_error")
    rm -f "$temp_output" "$temp_error"
    
    # Check for throttling
    if [[ $exit_code -ne 0 ]] && echo "$error" | grep -qi "rate limit\|throttle\|429\|too many requests"; then
        echo "[ERROR] GitHub API throttled while fetching release list." >&2
        echo "[ERROR] Error: ${error}" >&2
        exit 1
    fi
    
    # If error is "no releases found" or similar, that's OK - we just skip
    if [[ $exit_code -ne 0 ]] && ! echo "$error" | grep -qi "no releases\|not found"; then
        echo "[WARN] Could not fetch release list: ${error}" >&2
    fi
    
    if [[ -n "$last_release_tag" ]]; then
        pkg_last_release_date=$(get_release_date "gnosis/gnosis_vpn" "${last_release_tag}")
        local pkg_current_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        echo "[INFO] Installer date range: ${pkg_last_release_date} to ${pkg_current_date}" >&2
    fi
    
    echo "" >&2
    
    # Fetch PRs from all repositories
    if [[ -n "$cli_previous_date" && -n "$cli_current_date" ]]; then
        fetch_merged_prs "gnosis/gnosis_vpn-client" "$cli_previous_date" "$cli_current_date" "Client" "$branch"
    fi
    
    if [[ -n "$app_previous_date" && -n "$app_current_date" ]]; then
        fetch_merged_prs "gnosis/gnosis_vpn-app" "$app_previous_date" "$app_current_date" "App" "$branch"
    fi
    
    if [[ -n "$pkg_last_release_date" ]]; then
        fetch_merged_prs "gnosis/gnosis_vpn" "$pkg_last_release_date" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "Installer" "$branch"
    fi
    
    echo "" >&2
    echo "✅ Fetched ${#changelog_entries[@]} PRs total" >&2
    echo "" >&2
    
    # Generate changelog to build directory
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BUILD_DIR="${SCRIPT_DIR}/../build"
    mkdir -p "${BUILD_DIR}/changelog"
    
    case $format in
        debian)
            debian_format_changelog > "${BUILD_DIR}/changelog/changelog"
            ;;
        github)
            github_format_changelog > "${BUILD_DIR}/changelog/changelog"
            ;;
        json)
            json_format_changelog > "${BUILD_DIR}/changelog/changelog"
            ;;
        rpm)
            rpm_format_changelog > "${BUILD_DIR}/changelog/changelog"
            ;;
        *)
            echo "Error: Unsupported format: ${format}" >&2
            exit 1
            ;;
    esac
    
    # Compress the changelog for packaging compatibility
    gzip -9n -c "${BUILD_DIR}/changelog/changelog" > "${BUILD_DIR}/changelog/changelog.gz"

    # Display the generated notes
    echo "=========================================="
    cat "${BUILD_DIR}/changelog/changelog"
    echo "=========================================="
    echo "Changelog saved to ${BUILD_DIR}/changelog/changelog"
    echo "Compressed changelog saved to ${BUILD_DIR}/changelog/changelog.gz"
}

# Run main function with all arguments
main "$@"
