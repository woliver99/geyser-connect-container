#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
# The SERVER_DIR now points to the /data volume inside the container.
# This is where all JARs, extensions, and version info will be stored.
SERVER_DIR="/data"
GEYSER_STANDALONE_LOCATION="${SERVER_DIR}/Geyser-Standalone.jar"
GEYSER_CONNECT_LOCATION="${SERVER_DIR}/extensions/GeyserConnect.jar"
MC_XBOX_BROADCAST_LOCATION="${SERVER_DIR}/extensions/MCXboxBroadcastExtension.jar"

# Version file (to store the current build/version numbers in JSON format)
VERSION_FILE="${SERVER_DIR}/version.json"

# Geyser API URLs
GEYSER_API_URL="https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest"
GEYSER_CONNECT_API_URL="https://download.geysermc.org/v2/projects/geyserconnect/versions/latest/builds/latest"

# MCXboxBroadcast GitHub API URL
MC_XBOX_BROADCAST_API_URL="https://api.github.com/repos/MCXboxBroadcast/Broadcaster/releases/latest"

# --- Helper Functions ---

# Check for required dependencies
check_dependencies() {
    echo "Checking for dependencies..."
    if ! command -v curl &> /dev/null; then
        echo "Error: curl is not installed. Please install it to continue."
        exit 1
    fi
    if ! command -v jq &> /dev/null; then
        echo "Error: jq is not installed. Please install it to parse API responses."
        exit 1
    fi
    echo "Dependencies found."
}

# Check if the data directory is writable
check_permissions() {
    echo "Checking permissions for ${SERVER_DIR}..."
    if [ ! -w "${SERVER_DIR}" ]; then
        echo "------------------------------------------------------------"
        echo "ERROR: Permission Denied."
        echo "The script cannot write to the data directory: ${SERVER_DIR}"
        echo "This usually happens when using a bind mount."
        echo "Please ensure the host directory you mounted has the correct permissions."
        echo "Example: 'sudo chown -R 1000:1000 ./your-data-directory'"
        echo "Assuming the non-root user in the container has UID 1000."
        echo "------------------------------------------------------------"
        exit 1
    fi
    echo "Permissions are correct."
}


# Read a specific key from the local version.json file
get_local_version() {
    local file=$1
    local key=$2
    if [ -f "$file" ]; then
        # Use jq to extract the key; if not present, return "0"
        jq -r ".${key} // \"0\"" "$file"
    else
        echo "0"
    fi
}

# Update a specific key in the local version.json file
update_local_version() {
    local file=$1
    local key=$2
    local version=$3
    local temp_json
    # Create an empty JSON object if the file doesn't exist
    if [ -f "$file" ]; then
        temp_json=$(cat "$file")
    else
        temp_json="{}"
    fi
    
    # Add or update the key-value pair using jq
    updated_json=$(echo "$temp_json" | jq --arg key "$key" --arg version "$version" '.[$key] = $version')
    
    # Write the updated JSON back to the file
    echo "$updated_json" > "$file"
}

# Download a file and verify its SHA256 checksum
download_and_verify() {
    local url=$1
    local destination=$2
    local expected_sha256=$3
    local temp_dest="${destination}.tmp"

    # Ensure the target directory exists (for extensions)
    mkdir -p "$(dirname "$destination")"

    echo "Downloading from $url..."
    # Use --fail to make curl exit with an error code on HTTP errors (like 404)
    if ! curl --fail -L -o "$temp_dest" "$url"; then
        echo "Error: Download failed for $url."
        rm -f "$temp_dest"
        return 1
    fi

    if [ -n "$expected_sha256" ]; then
        echo "Verifying checksum..."
        local actual_sha256=$(sha256sum "$temp_dest" | awk '{print $1}')
        if [ "$actual_sha256" != "$expected_sha256" ]; then
            echo "Error: Checksum mismatch for $destination."
            echo "Expected: $expected_sha256"
            echo "Got:      $actual_sha256"
            rm -f "$temp_dest"
            return 1
        fi
        echo "Checksum verified."
    else
        echo "Skipping checksum verification (not provided)."
    fi

    mv "$temp_dest" "$destination"
    echo "Successfully updated $destination."
    return 0
}

# --- Update Check Functions ---

check_geyser_standalone() {
    echo "Checking for Geyser-Standalone updates..."
    local local_build=$(get_local_version "$VERSION_FILE" "geyser_standalone")
    local api_response
    api_response=$(curl -sfL "$GEYSER_API_URL")

    # If the API response is empty, skip this check
    if [ -z "$api_response" ]; then
        echo "Warning: Failed to get API response for Geyser-Standalone. This could be a DNS or network issue inside the container."
        return 1
    fi

    local remote_build=$(echo "$api_response" | jq -r '.build // "0"')
    
    if [ "$remote_build" -gt "$local_build" ]; then
        echo "New Geyser-Standalone version found: Build $remote_build"
        local version=$(echo "$api_response" | jq -r '.version')
        local sha256=$(echo "$api_response" | jq -r '.downloads.standalone.sha256')
        local download_url="https://download.geysermc.org/v2/projects/geyser/versions/${version}/builds/${remote_build}/downloads/standalone"
        
        if download_and_verify "$download_url" "$GEYSER_STANDALONE_LOCATION" "$sha256"; then
            update_local_version "$VERSION_FILE" "geyser_standalone" "$remote_build"
            return 0 # Indicates an update was made
        fi
    else
        echo "Geyser-Standalone is up to date (Build $local_build)."
    fi
    return 1 # No update
}

check_geyser_connect() {
    echo "Checking for GeyserConnect updates..."
    local local_build=$(get_local_version "$VERSION_FILE" "geyser_connect")
    local api_response
    api_response=$(curl -sfL "$GEYSER_CONNECT_API_URL")

    if [ -z "$api_response" ]; then
        echo "Warning: Failed to get API response for GeyserConnect. This could be a DNS or network issue inside the container."
        return 1
    fi

    local remote_build=$(echo "$api_response" | jq -r '.build // "0"')

    if [ "$remote_build" -gt "$local_build" ]; then
        echo "New GeyserConnect version found: Build $remote_build"
        local version=$(echo "$api_response" | jq -r '.version')
        local sha256=$(echo "$api_response" | jq -r '.downloads.geyserconnect.sha256')
        local download_url="https://download.geysermc.org/v2/projects/geyserconnect/versions/${version}/builds/${remote_build}/downloads/geyserconnect"

        if download_and_verify "$download_url" "$GEYSER_CONNECT_LOCATION" "$sha256"; then
            update_local_version "$VERSION_FILE" "geyser_connect" "$remote_build"
            return 0 # Indicates an update was made
        fi
    else
        echo "GeyserConnect is up to date (Build $local_build)."
    fi
    return 1 # No update
}

check_mcxbox_broadcast() {
    echo "Checking for MCXboxBroadcast updates..."
    local local_version=$(get_local_version "$VERSION_FILE" "mcxbox_broadcast")
    local api_response
    api_response=$(curl -sf "$MC_XBOX_BROADCAST_API_URL")
    
    if [ -z "$api_response" ]; then
        echo "Warning: Failed to get API response for MCXboxBroadcast. This could be a DNS or network issue inside the container."
        return 1
    fi

    local remote_version=$(echo "$api_response" | jq -r '.tag_name')

    if [ "$remote_version" != "$local_version" ]; then
        echo "New MCXboxBroadcast version found: $remote_version"
        # Select the correct asset object once to be more efficient
        local asset_json=$(echo "$api_response" | jq -r '.assets[] | select(.name == "MCXboxBroadcastExtension.jar")')

        if [ -z "$asset_json" ]; then
            echo "Error: Could not find the MCXboxBroadcastExtension.jar asset in the API response."
            return 1
        fi

        local download_url=$(echo "$asset_json" | jq -r '.browser_download_url')
        local sha256_digest=$(echo "$asset_json" | jq -r '.digest')
        # Strip the 'sha256:' prefix from the digest string
        local sha256_hash="${sha256_digest#sha256:}"
        
        # Pass the extracted checksum to the verification function
        if download_and_verify "$download_url" "$MC_XBOX_BROADCAST_LOCATION" "$sha256_hash"; then
            update_local_version "$VERSION_FILE" "mcxbox_broadcast" "$remote_version"
            return 0 # Indicates an update was made
        fi
    else
        echo "MCXboxBroadcast is up to date (Version $local_version)."
    fi
    return 1 # No update
}

# --- Server Management ---

GEYSER_PID=""

start_server() {
    if [ ! -f "${SERVER_DIR}/Geyser-Standalone.jar" ]; then
        echo "Error: Geyser-Standalone.jar not found! Cannot start server."
        return 1
    fi
    echo "Starting Geyser-Standalone server..."
    # Navigate to server directory to ensure it finds the JAR files and configs
    cd "$SERVER_DIR" || exit
    java -Xms128M -Xmx1024M -jar Geyser-Standalone.jar &
    GEYSER_PID=$!
    echo "Server started with PID: $GEYSER_PID"
}

stop_server() {
    if [ -n "$GEYSER_PID" ] && ps -p "$GEYSER_PID" > /dev/null; then
        echo "Stopping Geyser-Standalone server (PID: $GEYSER_PID)..."
        kill "$GEYSER_PID"
        wait "$GEYSER_PID" 2>/dev/null
        echo "Server stopped."
    else
        # Find any running geyser process and stop it, in case the PID was lost
        local pids=$(pgrep -f "Geyser-Standalone.jar")
        if [ -n "$pids" ]; then
            echo "Found orphaned server process(es). Stopping now..."
            kill "$pids"
            sleep 2
        else
            echo "Server is not running or PID is unknown."
        fi
    fi
}

is_server_running() {
    if [ -n "$GEYSER_PID" ] && ps -p "$GEYSER_PID" > /dev/null; then
        return 0 # True, it's running
    else
        # Check if any Geyser process is running, in case script restarted
        if pgrep -f "Geyser-Standalone.jar" > /dev/null; then
             return 0
        fi
        return 1 # False, it's not running
    fi
}


# --- Main Loop ---

main() {
    check_dependencies
    check_permissions # Add permission check before starting the loop
    
    while true; do
        echo "----------------------------------------"
        echo "Starting update check cycle at $(date)"
        
        updates_found=false
        
        # Check each component for updates
        if check_geyser_standalone; then updates_found=true; fi
        if check_geyser_connect; then updates_found=true; fi
        if check_mcxbox_broadcast; then updates_found=true; fi

        if [ "$updates_found" = true ]; then
            echo "Updates were installed. Restarting server..."
            stop_server
            start_server
        else
            echo "No updates found."
            if ! is_server_running; then
                echo "Server is not running. Starting it now..."
                start_server
            else
                echo "Server is already running."
            fi
        fi
        
        echo "Sleeping for 15 minutes..."
        sleep 900
    done
}

# Graceful shutdown on script exit
trap 'stop_server; echo "Script exiting."; exit 0' SIGINT SIGTERM

# Run the main function
main


