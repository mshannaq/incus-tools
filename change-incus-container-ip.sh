#!/usr/bin/env bash
# change-incus-container-ip.sh
# This script can be used as part of an automation flow
# to set a static IPv4 address on an Incus container's eth0
# Author: Mohammed AlShannaq <mohd@extendy.uk>
# Copyright (c) 2025 Extendy LTD.
# MIT License
#
# This script helps assign a static IPv4 address to the eth0 interface of an Incus container.
# It supports interactive mode, prompting for the container name and IP address, or non-interactive
# usage via the -c <container> and -i <ipv4> command-line options. Pass -h or --help for usage details.

set -euo pipefail

#######################################################################
# Function: print_help
# Description: Display a detailed help message explaining what the script does
#   and how to use its available options.
#######################################################################
print_help() {
    cat <<'EOF'
Description:
  This script assigns a static IPv4 address to the eth0 interface of an
  Incus container. If no options are provided, the script prompts for any
  missing values (container name and IP address) interactively.

Usage:
  change-incus-container-ip.sh [-c <container_name>] [-i <ipv4_address>] [-h|--help]

Options:
  -c, --container   Specify the name of the Incus container.
  -i, --ip-address  Specify the static IPv4 address to assign.
                    When omitted or left empty, the script will suggest a free IP.
  -h, --help        Show this help message and exit.

Examples:
  # Interactive mode: prompts for container name and IP
  change-incus-container-ip.sh

  # Prompt only for IP; container is passed
  change-incus-container-ip.sh -c mycontainer

  # Non-interactive: specify container and IP directly
  change-incus-container-ip.sh -c mycontainer -i 10.1.196.50
EOF
}


# Parse '--help' as a long option before any other checks or parsing.
for arg in "$@"; do
    if [[ "$arg" == "--help" ]]; then
        print_help
        exit 0
    fi
done

## Note: we defer checking for the Incus CLI until after options are parsed.


# Note: '--help' long option is handled above. Short '-h' option is handled by getopts.

# Parse optional command-line arguments for non-interactive usage.
# Supported options:
#   -c <container_name>  specify the container name
#   -i <ip_address>      specify the desired IPv4 address
#   -h                   show usage
CT_NAME=""
IP_ADDR=""
while getopts ":c:i:h" opt; do
    case $opt in
        c)
            CT_NAME="$OPTARG"
            ;;
        i)
            IP_ADDR="$OPTARG"
            ;;
        h)
            print_help
            exit 0
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            print_help
            exit 1
            ;;
    esac
done
shift $((OPTIND - 1))

# Prompt for the container name if it was not provided via command-line.
if [[ -z "$CT_NAME" ]]; then
    read -rp "Container name: " CT_NAME
fi

# Ensure Incus is installed before making any Incus CLI calls.
if ! command -v incus >/dev/null 2>&1; then
    echo "Error: incus command not found. Please install Incus first."
    exit 1
fi

# Verify container exists
if ! incus info "$CT_NAME" >/dev/null 2>&1; then
    echo "Error: container '$CT_NAME' not found."
    exit 1
fi

echo "Leave empty to auto-suggest a free IP in the same subnet."
# Prompt for an IP address only if it wasn't provided via command-line.
if [[ -z "$IP_ADDR" ]]; then
    read -rp "Desired IPv4 address (e.g. 10.1.196.120): " IP_ADDR
fi

# Get all IPv4 addresses currently used by Incus containers
# This helps to avoid assigning an IP that is already in use.
USED_IPS=$(incus list --format csv -c 4 \
    | tr ' ' '\n' \
    | tr ',' '\n' \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' || true)

# Helper function to check if an IP is inside the USED_IPS list
ip_in_use() {
    local ip="$1"
    grep -qx "$ip" <<< "$USED_IPS" 2>/dev/null
}

# If user did not provide an IP, try to auto-suggest one
if [[ -z "${IP_ADDR}" ]]; then
    # Try to detect current container IP to know the subnet
    CURRENT_IP=$(incus list "$CT_NAME" --format csv -c 4 \
        | head -n 1 \
        | tr -d ' ')

    if [[ "$CURRENT_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        BASE_NET="${CURRENT_IP%.*}"
    else
        # Fallback default base network – adjust to your setup if needed
        BASE_NET="10.1.196"
    fi

    echo "No IP provided, trying to find a free IP in ${BASE_NET}.0/24 ..."

    # Try last octets from 100 to 250 as an example range
    SUGGESTED_IP=""
    for last_octet in $(seq 100 250); do
        CANDIDATE="${BASE_NET}.${last_octet}"
        if ! ip_in_use "$CANDIDATE"; then
            SUGGESTED_IP="$CANDIDATE"
            break
        fi
    done

    if [[ -z "$SUGGESTED_IP" ]]; then
        echo "Error: could not find a free IP in ${BASE_NET}.0/24."
        exit 1
    fi

    echo "Suggested free IP: $SUGGESTED_IP"
    IP_ADDR="$SUGGESTED_IP"
fi

# Basic IPv4 format validation
if ! [[ "$IP_ADDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Error: '$IP_ADDR' does not look like a valid IPv4 address."
    exit 1
fi

# Check if IP is already used by another container
CURRENT_OWNER=$(incus list --format csv -c n,4 \
    | awk -F',' -v ip="$IP_ADDR" '
    {
        gsub(/ +/, " ", $2);
        split($2, arr, " ");
        for (i in arr) {
            if (arr[i] == ip) {
                print $1;
                exit;
            }
        }
    }')

if [[ -n "${CURRENT_OWNER:-}" && "$CURRENT_OWNER" != "$CT_NAME" ]]; then
    echo "Error: IP $IP_ADDR is already in use by container '$CURRENT_OWNER'."
    exit 1
fi

echo "Applying static IP $IP_ADDR to container '$CT_NAME' (device eth0)..."

echo "Stopping container if running..."
if incus info "$CT_NAME" | grep -q "Status: RUNNING"; then
    incus stop "$CT_NAME"
else
    echo "Container already stopped. Continuing..."
fi

echo "Ensuring eth0 is overridden on instance level..."
# This will create a local override if eth0 comes from profiles.
# If eth0 is already a local device, Incus may complain that it exists; we ignore that.
incus config device override "$CT_NAME" eth0 >/dev/null 2>&1 || true

echo "Setting static IP on eth0..."
incus config device set "$CT_NAME" eth0 ipv4.address "$IP_ADDR"

echo "Starting container..."
incus start "$CT_NAME"

echo "Waiting for container IP to be applied..."
# Wait up to ~10 seconds for an IPv4 address to appear
for i in {1..10}; do
    IP_NOW=$(incus list "$CT_NAME" --format csv -c 4 | tr -d ' ')
    if [[ "$IP_NOW" =~ ([0-9]{1,3}\.){3}[0-9]{1,3} ]]; then
        break
    fi
    sleep 1
done

echo
echo "Done. Current container info:"
incus list "$CT_NAME"
