#!/bin/bash

# Function to display help message
show_help() {
    cat << EOF
Usage: $(basename $0) [options]

This script checks and updates Helm chart dependencies in all Chart.yaml files
found in the templates directory. It compares current dependency versions with
the latest available versions from their respective repositories.

Options:
    -h, --help    Show this help message
    -y            Automatically update all dependencies without asking for confirmation
                  (Default behavior is to ask for confirmation for each update)
    -l, --list    Show a list of all dependency charts and their current versions
                  without checking for updates

Examples:
    $(basename $0)          # Run with confirmation prompts
    $(basename $0) -y       # Run with automatic updates
    $(basename $0) -l       # List all dependencies
    $(basename $0) --help   # Show this help message

The script will:
1. Search for all Chart.yaml files in the templates directory
2. Check each chart's dependencies
3. Compare current versions with latest available versions
4. Update versions if newer versions are available

Supports both HTTP-based Helm repositories and OCI registries.
EOF
    exit 0
}

# Function to list all dependencies
list_dependencies() {
    local chart_files=("$@")

    # Print header
    printf "\nListing all chart dependencies:\n"
    printf "%-30s %-20s %s\n" "DEPENDENCY" "VERSION" "REPOSITORY"
    printf "%s\n" "--------------------------------------------------------------------------------"

    for chart_file in "${chart_files[@]}"; do
        # Check if file has dependencies
        if ! yq e -e '.dependencies' "$chart_file" > /dev/null 2>&1; then
            continue
        fi

        # Get number of dependencies
        local deps_count=$(yq e '.dependencies | length' "$chart_file")

        for ((i=0; i<deps_count; i++)); do
            local name=$(yq e ".dependencies[$i].name" "$chart_file")
            local version=$(yq e ".dependencies[$i].version" "$chart_file")
            local repo=$(yq e ".dependencies[$i].repository" "$chart_file")

            printf "%-30s %-20s %s\n" "$name" "$version" "$repo"
        done
    done

    printf "\n"
    exit 0
}

# Check for --help first
for arg in "$@"; do
    if [ "$arg" == "--help" ]; then
        show_help
    fi
done

# Parse command line arguments
AUTO_CONFIRM=false
LIST_ONLY=false
while getopts "hyl-:" opt; do
    case ${opt} in
        h )
            show_help
            ;;
        y )
            AUTO_CONFIRM=true
            ;;
        l )
            LIST_ONLY=true
            ;;
        - )
            case "${OPTARG}" in
                help)
                    show_help
                    ;;
                list)
                    LIST_ONLY=true
                    ;;
                *)
                    echo "Invalid option: --${OPTARG}" 1>&2
                    echo "Use -h or --help for help" 1>&2
                    exit 1
                    ;;
            esac
            ;;
        \? )
            echo "Invalid option: -$OPTARG" 1>&2
            echo "Use -h or --help for help" 1>&2
            exit 1
            ;;
    esac
done

# Function to get index.yaml content from HTTP repository
get_index_yaml() {
    local repo_url=$1
    # Remove trailing slash if present
    repo_url=${repo_url%/}

    # Add index.yaml to the URL
    local index_url="${repo_url}/index.yaml"

    # Download index.yaml using curl
    local response
    response=$(curl -s -L "$index_url")
    if [ $? -eq 0 ]; then
        echo "$response"
    else
        echo "Failed to fetch index.yaml from $index_url" >&2
        return 1
    fi
}

# Function to get latest version from index.yaml content
get_latest_version_from_index() {
    local index_content=$1
    local chart_name=$2

    # Use yq to parse the index.yaml and get the latest version
    echo "$index_content" | yq e ".entries.${chart_name}[0].version" -
}

# Function to get the latest version of a chart from a repository
get_latest_version() {
    local repo_url=$1
    local chart_name=$2
    local current_version=$3

    # Handle OCI registry
    if [[ $repo_url == oci://* ]]; then
        # Get chart info using helm show chart
        local chart_info=$(helm show chart "$repo_url/$chart_name" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            local latest_version=$(echo "$chart_info" | yq e '.version' -)
            echo "$latest_version"
            return 0
        else
            echo "Failed to fetch chart info from OCI registry" >&2
            return 1
        fi
    fi

    # For HTTP-based repositories, use index.yaml
    local index_content
    index_content=$(get_index_yaml "$repo_url")
    if [[ $? -eq 0 ]]; then
        local latest_version
        latest_version=$(get_latest_version_from_index "$index_content" "$chart_name")
        if [[ -n "$latest_version" ]]; then
            echo "$latest_version"
            return 0
        fi
    fi

    echo "Failed to determine latest version" >&2
    return 1
}

# Function to process a Chart.yaml file
process_chart() {
    local chart_file=$1
    echo "Processing: $chart_file"

    # Check if file has dependencies
    if ! yq e -e '.dependencies' "$chart_file" > /dev/null 2>&1; then
        echo "No dependencies found in $chart_file"
        echo "----------------------------------------"
        return
    fi

    # Get number of dependencies
    local deps_count=$(yq e '.dependencies | length' "$chart_file")

    for ((i=0; i<deps_count; i++)); do
        local name=$(yq e ".dependencies[$i].name" "$chart_file")
        local current_version=$(yq e ".dependencies[$i].version" "$chart_file")
        local repo=$(yq e ".dependencies[$i].repository" "$chart_file")

        echo "Checking dependency: $name"
        echo "Current version: $current_version"
        echo "Repository: $repo"

        local latest_version=$(get_latest_version "$repo" "$name" "$current_version")
        local get_version_status=$?

        if [[ $get_version_status -eq 0 && -n "$latest_version" && "$latest_version" != "$current_version" ]]; then
            echo "New version available: $latest_version"

            # If AUTO_CONFIRM is true, update without asking
            if $AUTO_CONFIRM; then
                yq e ".dependencies[$i].version = \"$latest_version\"" -i "$chart_file"
                echo "Updated $name to version $latest_version"
            else
                read -p "Do you want to update $name from $current_version to $latest_version? (y/n) " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    yq e ".dependencies[$i].version = \"$latest_version\"" -i "$chart_file"
                    echo "Updated $name to version $latest_version"
                fi
            fi
        elif [[ $get_version_status -eq 1 ]]; then
            echo "Failed to check version. Please verify manually."
        else
            echo "Already using the latest version"
        fi
        echo "----------------------------------------"
    done
}

# Main script
if $AUTO_CONFIRM; then
    echo "Running in automatic update mode (no confirmation prompts)"
else
    echo "Running in interactive mode (will ask for confirmation before updates)"
fi

echo "Checking for helm chart dependency updates..."

# Store found Chart.yaml files in an array - macOS compatible version
IFS=$'\n' read -r -d '' -a chart_files < <(find templates -name Chart.yaml | sort)

# Check if any files were found
if [ ${#chart_files[@]} -eq 0 ]; then
    echo "No Chart.yaml files found in templates directory"
    exit 0
fi

# If list option is specified, show dependencies and exit
if $LIST_ONLY; then
    list_dependencies "${chart_files[@]}"
fi

# Process each chart file
for chart_file in "${chart_files[@]}"; do
    process_chart "$chart_file"
done

echo "Finished checking all charts"
