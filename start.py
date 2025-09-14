#!/usr/bin/env python3

import hashlib
import json
import os
import signal
import subprocess
import time
import threading
from pathlib import Path
from typing import Any, Optional

import requests

# --- Configuration ---
SERVER_DIR = Path("/data")
GEYSER_STANDALONE_LOCATION = SERVER_DIR / "Geyser-Standalone.jar"
GEYSER_CONNECT_LOCATION = SERVER_DIR / "extensions" / "GeyserConnect.jar"
MC_XBOX_BROADCAST_LOCATION = SERVER_DIR / "extensions" / "MCXboxBroadcastExtension.jar"
VERSION_FILE = SERVER_DIR / "version.json"

GEYSER_API_URL = "https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest"
GEYSER_CONNECT_API_URL = "https://download.geysermc.org/v2/projects/geyserconnect/versions/latest/builds/latest"
MC_XBOX_BROADCAST_API_URL = "https://api.github.com/repos/MCXboxBroadcast/Broadcaster/releases/latest"

# --- Globals for Process and Signal Management ---
geyser_process: Optional[subprocess.Popen] = None
# An Event is a more efficient way to handle interruptible waits than a sleep loop.
shutdown_event = threading.Event()

# --- Main Application Logic ---

def main():
    """The main application loop."""
    print("Starting Geyser Updater Application (Python Version)...")
    
    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)

    check_permissions()

    while not shutdown_event.is_set():
        try:
            if not is_server_running():
                print("----------------------------------------")
                print("Server not running. Performing checks before startup...")
                run_update_checks()
                start_server()

            if is_server_running():
                print(f"Server is running (PID: {geyser_process.pid}). Waiting for 15 minutes or shutdown signal...")
                
                # This will wait for 900 seconds, but will return immediately
                # if the shutdown_event is set by the signal handler.
                shutdown_event.wait(timeout=900)

                if shutdown_event.is_set(): # Shutdown was triggered
                    break

                if is_server_running(): # Timer finished naturally
                    print("15 minute timer finished. Checking for updates online...")
                    # If updates are found, they will be downloaded, and we then restart the server.
                    if run_update_checks():
                        print("Updates found and installed. Restarting server to apply changes...")
                        stop_server()
                        # The main loop will handle starting the server again on the next iteration.
            else:
                # Server failed to start or crashed, wait a bit before retrying
                print("Server is not running, will retry after a short delay.")
                shutdown_event.wait(timeout=30)

        except Exception as e:
            print(f"An unexpected error occurred in the main loop: {e}")
            shutdown_event.wait(timeout=30) # Wait before retrying


# --- Update Check Functions ---

def run_update_checks() -> bool:
    """Runs all update checks and returns True if any updates were installed."""
    print(f"Starting update check cycle at {time.strftime('%Y-%m-%d %H:%M:%S %Z')}")
    results = [
        check_geyser_standalone(),
        check_geyser_connect(),
        check_mcxbox_broadcast(),
    ]
    updates_found = any(results)
    if updates_found:
        print("Updates were installed.")
    else:
        print("No new updates found.")
    return updates_found

def check_geyser_standalone() -> bool:
    print("Checking for Geyser-Standalone updates...")
    versions = get_local_versions()
    local_build = versions.get("geyser_standalone", 0)
    
    remote_info = get_api_response(GEYSER_API_URL)
    if not remote_info:
        return False

    remote_build = remote_info.get("build", 0)
    if remote_build > local_build:
        print(f"New Geyser-Standalone version found: Build {remote_build}")
        version = remote_info["version"]
        sha256 = remote_info["downloads"]["standalone"]["sha256"]
        url = f"https://download.geysermc.org/v2/projects/geyser/versions/{version}/builds/{remote_build}/downloads/standalone"
        if download_and_verify(url, GEYSER_STANDALONE_LOCATION, sha256):
            update_local_version("geyser_standalone", remote_build)
            return True
    else:
        print(f"Geyser-Standalone is up to date (Build {local_build}).")
    return False

def check_geyser_connect() -> bool:
    print("Checking for GeyserConnect updates...")
    versions = get_local_versions()
    local_build = versions.get("geyser_connect", 0)

    remote_info = get_api_response(GEYSER_CONNECT_API_URL)
    if not remote_info:
        return False
        
    remote_build = remote_info.get("build", 0)
    if remote_build > local_build:
        print(f"New GeyserConnect version found: Build {remote_build}")
        version = remote_info["version"]
        sha256 = remote_info["downloads"]["geyserconnect"]["sha256"]
        url = f"https://download.geysermc.org/v2/projects/geyserconnect/versions/{version}/builds/{remote_build}/downloads/geyserconnect"
        if download_and_verify(url, GEYSER_CONNECT_LOCATION, sha256):
            update_local_version("geyser_connect", remote_build)
            return True
    else:
        print(f"GeyserConnect is up to date (Build {local_build}).")
    return False

def check_mcxbox_broadcast() -> bool:
    print("Checking for MCXboxBroadcast updates...")
    versions = get_local_versions()
    local_version = versions.get("mcxbox_broadcast", "0")

    remote_info = get_api_response(MC_XBOX_BROADCAST_API_URL)
    if not remote_info:
        return False

    remote_version = remote_info.get("tag_name")
    if remote_version != local_version:
        print(f"New MCXboxBroadcast version found: {remote_version}")
        for asset in remote_info.get("assets", []):
            if asset.get("name") == "MCXboxBroadcastExtension.jar":
                url = asset["browser_download_url"]
                sha256 = asset["digest"].replace("sha256:", "")
                if download_and_verify(url, MC_XBOX_BROADCAST_LOCATION, sha256):
                    update_local_version("mcxbox_broadcast", remote_version)
                    return True
    else:
        print(f"MCXboxBroadcast is up to date (Version {local_version}).")
    return False


# --- Process Management ---

def start_server() -> None:
    """Starts the Geyser-Standalone.jar process."""
    global geyser_process
    if not GEYSER_STANDALONE_LOCATION.exists():
        print("Error: Geyser-Standalone.jar not found! Cannot start server.")
        return
    
    print("Starting Geyser-Standalone server...")
    try:
        geyser_process = subprocess.Popen(
            ["java", "-Xms128M", "-Xmx1024M", "-jar", str(GEYSER_STANDALONE_LOCATION)],
            cwd=str(SERVER_DIR),
        )
    except (IOError, OSError) as e:
        print(f"Failed to start server process: {e}")

def stop_server() -> None:
    """Stops the Geyser server process gracefully."""
    global geyser_process
    if not is_server_running():
        print("Server is not running.")
        return

    print(f"Stopping Geyser-Standalone server (PID: {geyser_process.pid})...")
    geyser_process.terminate()  # Sends SIGTERM
    try:
        geyser_process.wait(timeout=8)
        print("Server stopped gracefully.")
    except subprocess.TimeoutExpired:
        print("Server did not stop within 8 seconds. Forcing shutdown...")
        geyser_process.kill()  # Sends SIGKILL
    geyser_process = None

def is_server_running() -> bool:
    """Checks if the geyser_process is alive."""
    return geyser_process is not None and geyser_process.poll() is None

def shutdown_handler(signum, frame) -> None:
    """Handles SIGTERM and SIGINT for graceful shutdown."""
    print(f"\nShutdown signal ({signal.Signals(signum).name}) received. Notifying main loop...")
    shutdown_event.set()


# --- File & Network Helpers ---

def check_permissions() -> None:
    """Checks if the script has write permissions to the server directory."""
    try:
        test_file = SERVER_DIR / ".permission_test"
        test_file.write_text("test")
        test_file.unlink()
        print("Permissions are correct.")
    except IOError as e:
        print("------------------------------------------------------------")
        print(f"ERROR: Permission Denied. Cannot write to {SERVER_DIR}")
        print("Please ensure the host directory you mounted has the correct permissions.")
        print("Example: 'sudo chown -R 1000:1000 ./your-data-directory'")
        print("------------------------------------------------------------")
        exit(1)

def get_api_response(url: str) -> Optional[dict]:
    """Fetches and parses a JSON response from a URL."""
    try:
        response = requests.get(url, timeout=15)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.RequestException as e:
        print(f"Warning: Failed to get API response from {url}: {e}")
        return None

def download_and_verify(url: str, destination: Path, expected_sha256: str) -> bool:
    """Downloads a file and verifies its SHA256 checksum."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    temp_dest = destination.with_suffix(destination.suffix + ".tmp")

    try:
        print(f"Downloading from {url}...")
        with requests.get(url, stream=True, timeout=300) as r:
            r.raise_for_status()
            with open(temp_dest, "wb") as f:
                for chunk in r.iter_content(chunk_size=8192):
                    f.write(chunk)
        
        print("Verifying checksum...")
        actual_sha256 = hashlib.sha256(temp_dest.read_bytes()).hexdigest()

        if actual_sha256.lower() != expected_sha256.lower():
            print(f"Error: Checksum mismatch for {destination.name}")
            print(f"  Expected: {expected_sha256}")
            print(f"  Actual:   {actual_sha256}")
            return False
        
        print("Checksum verified.")
        temp_dest.rename(destination)
        print(f"Successfully updated {destination.name}.")
        return True

    except (requests.exceptions.RequestException, IOError) as e:
        print(f"Error during download/verification: {e}")
        return False
    finally:
        if temp_dest.exists():
            temp_dest.unlink()

def get_local_versions() -> dict:
    """Reads the local version JSON file."""
    if VERSION_FILE.exists():
        try:
            return json.loads(VERSION_FILE.read_text())
        except json.JSONDecodeError:
            print("Warning: version.json is corrupted. Starting fresh.")
            return {}
    return {}

def update_local_version(key: str, value: Any) -> None:
    """Updates a key in the local version JSON file."""
    versions = get_local_versions()
    versions[key] = value
    VERSION_FILE.write_text(json.dumps(versions, indent=2))

if __name__ == "__main__":
    main()
    # When the main loop exits (due to shutdown_event), perform final cleanup.
    print("Main loop finished. Performing final shutdown...")
    stop_server()
    print("Updater exiting.")


