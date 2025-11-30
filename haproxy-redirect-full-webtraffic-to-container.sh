#!/bin/bash

# haproxy-redirect-full-webtraffic-to-container.sh
#
# Description: This script configures HAProxy to redirect full web traffic (HTTP and HTTPS/TLS passthrough)
# for a specified domain to a given Incus container. It performs prerequisite checks,
# gathers user input, validates the container, and safely updates the HAProxy configuration.
#
# Usage: sudo ./haproxy-redirect-full-webtraffic-to-container.sh
#
# Verified 1 Dec 2025 on HAProxy version 3.0.11 on Debian 13
# Author: Mohammed AlShannaq <mohd@extendy.uk>
# Copyright (c) Extendy LTD
# License: MIT
# Date: 2025-12-01

# --- Configuration ---
LOG_FILE="/var/log/haproxy-redirect-full-webtraffic-to-container.log"
# --- End Configuration ---

# --- Colour Definitions ---
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
NC='\033[0m' # No Colour
# --- End Colour Definitions ---

# --- Logging and Output Functions ---

# Function to log messages to the log file
log_message() {
    local message="$1"
    # Use tee to write to the log file with root privileges
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ${message}" | sudo tee -a "${LOG_FILE}" > /dev/null
}

# Function to print an error message in yellow and exit
error_exit() {
    local message="$1"
    log_message "ERROR: ${message}"
    echo -e "${YELLOW}ERROR: ${message}${NC}" >&2
    exit 1
}

# Function to print a message in yellow
yellow_text() {
    local message="$1"
    echo -e "${YELLOW}${message}${NC}"
}

# Function to print a success message in green
success_message() {
    local message="$1"
    log_message "SUCCESS: ${message}"
    echo -e "${GREEN}${message}${NC}"
}

# Function to check for root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root. Please use 'sudo' to execute."
    fi
    log_message "Root check passed."
}

# --- Prerequisite Check Functions ---

# Function to check if a command exists
check_command() {
    local cmd="$1"
    if ! command -v "${cmd}" &> /dev/null; then
        error_exit "${cmd} is not installed. Please install and enable it to continue."
    fi
    log_message "${cmd} is installed."
}

# Function to perform all prerequisite checks
prerequisite_checks() {
    log_message "Starting prerequisite checks..."
    
    # Check HAProxy binary and config file
    check_command "haproxy"
    if [ ! -f "/etc/haproxy/haproxy.cfg" ]; then
        error_exit "HAProxy configuration file /etc/haproxy/haproxy.cfg not found. Please ensure HAProxy is correctly installed."
    fi
    # Check Incus binary and daemon connectivity
    check_command "incus"
    # Check jq for JSON parsing
    check_command "jq"
    if ! incus list &> /dev/null; then
        error_exit "Incus daemon is not running or the user is not authorized. Please ensure Incus is running and you can interact with it."
    fi
    log_message "Incus daemon is accessible."

    log_message "All prerequisites passed."
}

# --- User Interaction Functions ---

# Function to get host IP and confirm with user, then gather domain and container name
get_user_inputs() {
    log_message "Checking host network configuration and gathering user input."

    # Get eth0 IP address
    HOST_IP=$(ip addr show eth0 | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    if [ -z "${HOST_IP}" ]; then
        error_exit "Could not determine the IP address of 'eth0'. Please check your network configuration."
    fi
    log_message "Host eth0 IP determined as: ${HOST_IP}"

    # Confirmation from user
    yellow_text "The host server's public IP address (from eth0) is: ${HOST_IP}"
    read -r -p "Please confirm that you have pointed your domain to this IP address (yes/no): " CONFIRM_IP
    if [[ ! "${CONFIRM_IP}" =~ ^[Yy][Ee][Ss]$ ]]; then
        error_exit "Confirmation failed. Please point your domain to ${HOST_IP} before running the script."
    fi
    log_message "User confirmed domain pointing to host IP."

    # Gather domain and container name
    read -r -p "Enter the domain or subdomain you want to host (e.g., example.com or sub.example.com): " DOMAIN
    if [ -z "${DOMAIN}" ]; then
        error_exit "Domain name cannot be empty."
    fi
    log_message "Target domain: ${DOMAIN}"

    read -r -p "Enter the Incus container name that will host the website: " CONTAINER_NAME
    if [ -z "${CONTAINER_NAME}" ]; then
        error_exit "Container name cannot be empty."
    fi
    log_message "Target container name: ${CONTAINER_NAME}"
}

# --- Incus Functions ---

# Function to check container existence and get its IP
get_container_ip() {
    log_message "Checking Incus container '${CONTAINER_NAME}' and retrieving its IP address."

    # Check if container exists and is running
    if ! incus list --format csv -c n,s | grep -q "^${CONTAINER_NAME},RUNNING$"; then
        error_exit "Incus container '${CONTAINER_NAME}' does not exist or is not running. Please check the container name and status."
    fi
    log_message "Container '${CONTAINER_NAME}' exists and is running."

    # Get the container's IP address
    CONTAINER_IP=$(incus list "${CONTAINER_NAME}" --format json | jq -r '.[0].state.network.eth0.addresses[] | select(.family == "inet") | .address' 2>/dev/null)

    if [ -z "${CONTAINER_IP}" ]; then
        error_exit "Could not determine the IP address for container '${CONTAINER_NAME}'. Ensure the container has an 'eth0' interface with an IPv4 address."
    fi
    
    log_message "Container IP determined as: ${CONTAINER_IP}"
    yellow_text "Traffic for domain ${DOMAIN} will be redirected to container IP: ${CONTAINER_IP}"
}

# --- HAProxy Configuration Functions ---

# Function to insert rules into a frontend block
# $1: frontend name (e.g., http_in)
# $2: rules to insert (e.g., ${HTTP_RULES})
insert_rules_into_frontend() {
    local frontend_name="$1"
    local rules="$2"
    local config_file="/etc/haproxy/haproxy.cfg"
    local start_line
    local end_line
    local insert_line
    local temp_file

    log_message "Attempting to insert rules into frontend: ${frontend_name}"

    # 1. Find the start of the frontend block
    start_line=$(grep -n "^frontend ${frontend_name}" "${config_file}" | cut -d: -f1 | head -1)
    if [ -z "${start_line}" ]; then
        error_exit "Could not find 'frontend ${frontend_name}' block for rule insertion. This should not happen."
    fi

    # 2. Find the end of the frontend block (the line before the next block or EOF)
    # We look for the next block definition (frontend, backend, listen) after the start line
    end_line=$(grep -n -A 1000 "^[[:space:]]*\(frontend\|backend\|listen\)" "${config_file}" | grep -B 1 "^[[:space:]]*\(frontend\|backend\|listen\)" | grep -v "^--$" | tail -1 | cut -d- -f1)
    
    # If no next block is found, the end line is the end of the file
    if [ -z "${end_line}" ] || [ "${end_line}" -le "${start_line}" ]; then
        end_line=$(wc -l < "${config_file}")
    fi

    # 3. Find the insertion point (before 'default_backend' or right after 'mode')
    # Search for 'default_backend' between start_line and end_line
    # We use 'sed' to get the content of the block and 'grep -n' to find the line number of 'default_backend' relative to the block start.
    default_backend_line_rel=$(sed -n "${start_line},${end_line}p" "${config_file}" | grep -n "^[[:space:]]*default_backend" | cut -d: -f1 | head -1)

    if [ -n "${default_backend_line_rel}" ]; then
        # If default_backend is found, calculate the absolute line number.
        insert_line=$((start_line + default_backend_line_rel - 1))
        log_message "Found 'default_backend' at line ${insert_line}. Inserting rules before it."
    else
        # If default_backend is not found, insert right after the 'mode' line.
        # This is the safest place to insert new rules at the beginning of the block.
        # Assuming 'frontend', 'bind', 'mode' are the first three lines.
        insert_line=$((start_line + 3))
        log_message "No 'default_backend' found. Inserting rules after 'mode' line at line ${insert_line}."
    fi

    # 4. Insert the rules using a temporary file for safety
    temp_file=$(mktemp)
    
    # Read the file up to the insertion point
    head -n $((insert_line - 1)) "${config_file}" > "${temp_file}"
    
    # Add the new rules
    echo -e "${rules}" >> "${temp_file}"
    
    # Read the rest of the file
    tail -n +${insert_line} "${config_file}" >> "${temp_file}"

    # Overwrite the original file
    sudo mv "${temp_file}" "${config_file}"
    
    log_message "Successfully inserted rules into frontend: ${frontend_name}"
}

# Function to insert HTTP rules
insert_http_rules() {
    insert_rules_into_frontend "http_in" "${HTTP_RULES}"
}

# Function to insert HTTPS rules
insert_https_rules() {
    insert_rules_into_frontend "https_in" "${HTTPS_RULES}"
}

# Function to check for existing domain and generate the config block
check_and_generate_config() {
    log_message "Checking HAProxy configuration for existing domain: ${DOMAIN}"

    # Check if the domain is already configured in haproxy.cfg
    if grep -q "website ${DOMAIN}" /etc/haproxy/haproxy.cfg; then
        error_exit "The domain '${DOMAIN}' is already configured in /etc/haproxy/haproxy.cfg. Please remove it manually before proceeding."
    fi
    log_message "Domain '${DOMAIN}' is not found in existing HAProxy configuration."

    # 1. Check and create generic frontends if they don't exist
    # This is a critical step to ensure the script works on a clean HAProxy install.
    
    # Check for http_in
    if ! grep -q "frontend http_in" /etc/haproxy/haproxy.cfg; then
        log_message "Generic HTTP frontend 'http_in' not found. Creating it."
        echo -e "\nfrontend http_in\n    bind *:80\n    mode http\n    # Add default_backend here if needed for non-matching traffic" | sudo tee -a /etc/haproxy/haproxy.cfg > /dev/null
    fi

    # Check for https_in
    if ! grep -q "frontend https_in" /etc/haproxy/haproxy.cfg; then
        log_message "Generic HTTPS frontend 'https_in' not found. Creating it."
        echo -e "\nfrontend https_in\n    bind *:443\n    mode tcp\n    # Required for SNI inspection in TCP mode\n    tcp-request inspect-delay 5s\n    tcp-request content accept if { req_ssl_hello_type 1 }\n    # Add default_backend here if needed for non-matching traffic" | sudo tee -a /etc/haproxy/haproxy.cfg > /dev/null
    fi

    # 2. Define the rules to be inserted into the frontends
    # These are global variables that will be used by the insertion functions
    HTTP_RULES=$(cat <<-EOF
    acl host_${CONTAINER_NAME} hdr(host) -i ${DOMAIN}
    use_backend backend_${CONTAINER_NAME}_http if host_${CONTAINER_NAME}
EOF
)
    HTTPS_RULES=$(cat <<-EOF
    acl host_ssl_${CONTAINER_NAME} req_ssl_sni -i ${DOMAIN}
    use_backend backend_${CONTAINER_NAME}_https if host_ssl_${CONTAINER_NAME}
EOF
)

    # 3. Generate the configuration block to be appended (only backends)
    HAPROXY_CONFIG=$(cat <<-EOF
######################################################
### website ${DOMAIN}
######################################################

# --- Backend Definitions ---

# Backend for HTTP traffic (Port 80)
backend backend_${CONTAINER_NAME}_http
    mode http
    server ${CONTAINER_NAME}_server ${CONTAINER_IP}:80 check

# Backend for HTTPS traffic (Port 443 - TLS Passthrough)
backend backend_${CONTAINER_NAME}_https
    mode tcp
    server ${CONTAINER_NAME}_server ${CONTAINER_IP}:443 check

EOF
)
    log_message "Generated HAProxy configuration block and rules for insertion."
}






# Function to append config, validate, and reload HAProxy
apply_and_reload_haproxy() {
    log_message "Attempting to append configuration to /etc/haproxy/haproxy.cfg"
    
    # Append the configuration block
    echo -e "\n${HAPROXY_CONFIG}" | sudo tee -a /etc/haproxy/haproxy.cfg > /dev/null
    if [ $? -ne 0 ]; then
        error_exit "Failed to append configuration to /etc/haproxy/haproxy.cfg. Check file permissions."
    fi
    log_message "Configuration successfully appended."

    # Validate the new configuration
    yellow_text "Validating new HAProxy configuration..."
    if ! haproxy -c -f /etc/haproxy/haproxy.cfg; then
        # If validation fails, attempt to revert the change
        log_message "HAProxy configuration validation failed. Attempting to revert the changes."
        # Get the line number of the start of the added block
        START_LINE=$(grep -n "website ${DOMAIN}" /etc/haproxy/haproxy.cfg | tail -1 | cut -d: -f1)
        
        if [ -n "${START_LINE}" ]; then
            # Remove the appended block
            sudo sed -i "${START_LINE},\$d" /etc/haproxy/haproxy.cfg
            log_message "Attempted to revert configuration changes starting from line ${START_LINE}."
        fi
        error_exit "HAProxy configuration validation failed. The new configuration was NOT applied. Please check /etc/haproxy/haproxy.cfg for errors."
    fi
    log_message "HAProxy configuration validated successfully."

    # Reload HAProxy service
    yellow_text "Reloading HAProxy service..."
    if ! systemctl reload haproxy; then
        error_exit "Failed to reload HAProxy service. Check 'systemctl status haproxy' for details."
    fi
    log_message "HAProxy service reloaded successfully."
}

# --- Main Script Logic Placeholder ---

# 1. Check for root
check_root

# 2. Create log file if it doesn't exist
if [ ! -f "${LOG_FILE}" ]; then
    sudo touch "${LOG_FILE}"
    sudo chmod 644 "${LOG_FILE}"
    log_message "Created log file: ${LOG_FILE}"
fi

log_message "Script execution started."

# 3. Prerequisite checks
prerequisite_checks
# 4. Network check and user input
get_user_inputs
# 5. Container check and IP retrieval
get_container_ip
# 6. HAProxy config check and generation
check_and_generate_config

# 7. Insert rules into frontends
insert_http_rules
insert_https_rules

# 8. Apply config and reload HAProxy
apply_and_reload_haproxy

# 8. Final success message and advice
success_message "HAProxy full redirect for ${DOMAIN} to container ${CONTAINER_NAME} (${CONTAINER_IP}) added successfully."
yellow_text "Advice: Do not forget to point the domain '${DOMAIN}' into the host public IP '${HOST_IP}' to start using the hosting service in that container."

# End of script
log_message "Script execution finished."
exit 0
