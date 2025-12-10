#!/bin/bash
#
# Generate Release Notes
#
# This script generates comprehensive release notes by aggregating changes from:
# - gnosis_vpn-client repository (between version ranges)
# - gnosis_vpn-app repository (between version ranges)
# - gnosis_vpn packaging repository (since last release)
#
# Usage:
#   ./generate-release-notes.sh --next-release-version <version> \
#                                --previous-cli-version <version> \
#                                --current-cli-version <version> \
#                                --previous-app-version <version> \
#                                --current-app-version <version>
#
# Example:
#   ./generate-release-notes.sh --next-release-version 0.56.5 \
#                                --previous-cli-version 0.54.4 \
#                                --current-cli-version 0.56.1 \
#                                --previous-app-version 0.5.0 \
#                                --current-app-version 0.6.1
#

set -euo pipefail

# Helper function to call GitHub API
# Usage: gh_api_call <repo> <endpoint> <jq_query>
gh_api_call() {
    local repo="$1"
    local endpoint="$2"
    local jq_query="$3"
    
    gh api \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "/repos/${repo}${endpoint}" \
        --jq "${jq_query}" 2>/dev/null || echo ""
}

# Helper function to fetch and format release notes for a repository
# Usage: fetch_repo_release_notes <repo_name> <display_name> <emoji> <previous_version> <current_version>
fetch_repo_release_notes() {
    local repo_name="$1"
    local display_name="$2"
    local emoji="$3"
    local previous_version="$4"
    local current_version="$5"
    
    # Skip if versions are the same (no changes)
    if [[ "$previous_version" == "$current_version" ]]; then
        return 0
    fi
    
    # Create a temporary file to collect release notes
    local temp_notes=$(mktemp)
    
    # Get the creation dates for version boundaries
    local previous_date=$(gh_api_call "${repo_name}" "/releases/tags/v${previous_version}" '.created_at')
    local current_date=$(gh_api_call "${repo_name}" "/releases/tags/v${current_version}" '.created_at')
    
    # Get all releases between those dates (exclusive of previous, inclusive of current)
    if [[ -n "$previous_date" && -n "$current_date" ]]; then
        gh_api_call "${repo_name}" "/releases" \
            '.[] | select(.created_at > "'"${previous_date}"'" and .created_at <= "'"${current_date}"'") | .body' \
            | grep -E '^\* |^- ' \
            | sed 's/^* /- /' \
            > "$temp_notes" 2>/dev/null || true
    fi
    
    # Only print section if we found release notes
    if [[ -s "$temp_notes" ]]; then
        echo "## ${emoji} ${display_name} Changes (${repo_name})" >> release_notes.txt
        echo "" >> release_notes.txt
        echo "**Full Changelog**: https://github.com/${repo_name}/compare/v${previous_version}...v${current_version}" >> release_notes.txt
        echo "" >> release_notes.txt
        cat "$temp_notes" >> release_notes.txt
        echo "" >> release_notes.txt
        echo "" >> release_notes.txt
    fi
    
    rm -f "$temp_notes"
}

# Helper function to fetch and format packaging PRs
# Usage: fetch_packaging_prs <next_release_version>
fetch_packaging_prs() {
    local next_release_version="$1"
    
    # Get the last release tag
    local last_release_tag=$(gh release list --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null || echo "")
    
    if [[ -z "$last_release_tag" ]]; then
        return 0
    fi
    
    # Get the creation date of the last release
    local last_release_date=$(gh_api_call "gnosis/gnosis_vpn" "/releases/tags/${last_release_tag}" '.created_at')
    
    # Create a temporary file to collect PRs
    local temp_prs=$(mktemp)
    
    # Get all merged PRs after that date
    if [[ -n "$last_release_date" ]]; then
        gh_api_call "gnosis/gnosis_vpn" "/pulls?state=closed&sort=updated&direction=desc&per_page=100" \
            '.[] | select(.merged_at != null and .merged_at > "'"${last_release_date}"'") | "- [#\(.number)](\(.html_url)) \(.title)"' \
            > "$temp_prs" 2>/dev/null || true
    fi
    
    # Only print section if we found PRs
    if [[ -s "$temp_prs" ]]; then
        echo "## 📦 Packaging Changes (gnosis_vpn)" >> release_notes.txt
        echo "" >> release_notes.txt
        echo "**Full Changelog**: https://github.com/gnosis/gnosis_vpn/compare/${last_release_tag}...v${next_release_version}" >> release_notes.txt
        echo "" >> release_notes.txt
        cat "$temp_prs" >> release_notes.txt
        echo "" >> release_notes.txt
    fi
    
    rm -f "$temp_prs"
}

# Generate release summary with component version updates
# Usage: generate_release_summary <previous_cli_version> <current_cli_version> <previous_app_version> <current_app_version>
generate_release_summary() {
    local previous_cli_version="$1"
    local current_cli_version="$2"
    local previous_app_version="$3"
    local current_app_version="$4"
    
    # Initialize release notes file
    cat > release_notes.txt <<EOF
This release contains the following component updates:

EOF

    # Add client version line only if versions differ
    if [[ "$previous_cli_version" != "$current_cli_version" ]]; then
        cat >> release_notes.txt <<EOF
- **[GnosisVPN Client](https://github.com/gnosis/gnosis_vpn-client)**: Updated from [v${previous_cli_version}](https://github.com/gnosis/gnosis_vpn-client/releases/tag/v${previous_cli_version}) to [v${current_cli_version}](https://github.com/gnosis/gnosis_vpn-client/releases/tag/v${current_cli_version})
EOF
    fi

    # Add app version line only if versions differ
    if [[ "$previous_app_version" != "$current_app_version" ]]; then
        cat >> release_notes.txt <<EOF
- **[GnosisVPN App](https://github.com/gnosis/gnosis_vpn-app)**: Updated from [v${previous_app_version}](https://github.com/gnosis/gnosis_vpn-app/releases/tag/v${previous_app_version}) to [v${current_app_version}](https://github.com/gnosis/gnosis_vpn-app/releases/tag/v${current_app_version})
EOF
    fi

    cat >> release_notes.txt <<EOF

The release includes all changes from the client and app repositories between these versions, along with packaging improvements made to the installer.

EOF
}

# Parse and validate command line arguments
# Returns: Sets global variables next_release_version, previous_cli_version, current_cli_version,
#          previous_app_version, current_app_version
parse_arguments() {
    # Initialize variables
    next_release_version=""
    previous_cli_version=""
    current_cli_version=""
    previous_app_version=""
    current_app_version=""
    
    # Parse named arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --next-release-version)
                next_release_version="$2"
                shift 2
                ;;
            --previous-cli-version)
                previous_cli_version="$2"
                shift 2
                ;;
            --current-cli-version)
                current_cli_version="$2"
                shift 2
                ;;
            --previous-app-version)
                previous_app_version="$2"
                shift 2
                ;;
            --current-app-version)
                current_app_version="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: $0 --next-release-version <version> \\"
                echo "          --previous-cli-version <version> \\"
                echo "          --current-cli-version <version> \\"
                echo "          --previous-app-version <version> \\"
                echo "          --current-app-version <version>"
                exit 0
                ;;
            *)
                echo "Error: Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
    
    # Check that all required arguments are provided
    if [[ -z "$next_release_version" || -z "$previous_cli_version" || -z "$current_cli_version" || \
          -z "$previous_app_version" || -z "$current_app_version" ]]; then
        echo "Error: Missing required arguments"
        echo "Usage: $0 --next-release-version <version> \\"
        echo "          --previous-cli-version <version> \\"
        echo "          --current-cli-version <version> \\"
        echo "          --previous-app-version <version> \\"
        echo "          --current-app-version <version>"
        exit 1
    fi
}

# Main function
main() {
    # Parse command line arguments
    parse_arguments "$@"
    rm -f release_notes.txt
    echo "Generating release notes..."
    echo "  Package version: v${next_release_version}"
    echo "  Client: v${previous_cli_version} -> v${current_cli_version}"
    echo "  App: v${previous_app_version} -> v${current_app_version}"
    
    generate_release_summary "$previous_cli_version" "$current_cli_version" "$previous_app_version" "$current_app_version"
    fetch_repo_release_notes "gnosis/gnosis_vpn-client" "Client" "🔧" "$previous_cli_version" "$current_cli_version"
    fetch_repo_release_notes "gnosis/gnosis_vpn-app" " App" "🖥️" "$previous_app_version" "$current_app_version"
    fetch_packaging_prs "$next_release_version"
    
    # Display the generated notes
    echo ""
    echo "✅ Release notes generated successfully!"
    echo ""
    echo "=========================================="
    cat release_notes.txt
    echo "=========================================="
}

# Run main function with all arguments
main "$@"
