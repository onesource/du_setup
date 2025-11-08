#!/bin/bash

# ============================================================================
# du_setup.sh - Shared Utilities Library
# Common functions used across multiple modules
# ============================================================================

# --- Color Definitions ---
if command -v tput >/dev/null 2>&1 && tput setaf 1 >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW="$(tput bold)$(tput setaf 3)"
    BLUE=$(tput setaf 4)
    PURPLE=$(tput setaf 5)
    CYAN=$(tput setaf 6)
    BOLD=$(tput bold)
    NC=$(tput sgr0)
else
    RED=$'\e[0;31m'
    GREEN=$'\e[0;32m'
    YELLOW=$'\e[1;33m'
    BLUE=$'\e[0;34m'
    PURPLE=$'\e[0;35m'
    CYAN=$'\e[0;36m'
    NC=$'\e[0m'
    BOLD=$'\e[1m'
fi

# --- Logging Functions ---
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

print_header() {
    [[ $VERBOSE == false ]] && return
    printf '\n'
    printf '%s\n' "${CYAN}╔═════════════════════════════════════════════════════════════════╗${NC}"
    printf '%s\n' "${CYAN}║                                                                 ║${NC}"
    printf '%s\n' "${CYAN}║       DEBIAN/UBUNTU SERVER SETUP AND HARDENING SCRIPT           ║${NC}"
    printf '%s\n' "${CYAN}║                      v0.73 | 2025-10-22                         ║${NC}"
    printf '%s\n' "${CYAN}║                                                                 ║${NC}"
    printf '%s\n' "${CYAN}╚═════════════════════════════════════════════════════════════════╝${NC}"
    printf '\n'
}

print_section() {
    [[ $VERBOSE == false ]] && return
    printf '\n%s\n' "${BLUE}▓▓▓ $1 ▓▓▓${NC}" | tee -a "$LOG_FILE"
    printf '%s\n' "${BLUE}$(printf '═%.0s' {1..65})${NC}"
}

print_success() {
    [[ $VERBOSE == false ]] && return
    printf '%s\n' "${GREEN}✓ $1${NC}" | tee -a "$LOG_FILE"
}

print_error() {
    printf '%s\n' "${RED}✗ $1${NC}" | tee -a "$LOG_FILE"
}

print_warning() {
    [[ $VERBOSE == false ]] && return
    printf '%s\n' "${YELLOW}⚠ $1${NC}" | tee -a "$LOG_FILE"
}

print_info() {
    [[ $VERBOSE == false ]] && return
    printf '%s\n' "${PURPLE}ℹ $1${NC}" | tee -a "$LOG_FILE"
}

print_separator() {
    local header_text="$1"
    local color="${2:-$YELLOW}"
    local separator_char="${3:-=}"

    printf '%s\n' "${color}${header_text}${NC}"
    printf "${separator_char}%.0s" $(seq 1 ${#header_text})
    printf '\n'
}

# --- Validation Functions ---
validate_username() {
    local username="$1"
    [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ && ${#username} -le 32 ]]
}

validate_hostname() {
    local hostname="$1"
    [[ "$hostname" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,253}[a-zA-Z0-9]$ && ! "$hostname" =~ \.\. ]]
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1024 && "$port" -le 65535 ]]
}

validate_backup_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]]
}

validate_ssh_key() {
    local key="$1"
    [[ -n "$key" && "$key" =~ ^(ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|ssh-ed25519)\  ]]
}

validate_timezone() {
    local tz="$1"
    [[ -e "/usr/share/zoneinfo/$tz" ]]
}

validate_swap_size() {
    local size_upper="${1^^}" # Convert to uppercase for case-insensitivity
    [[ "$size_upper" =~ ^[0-9]+[MG]$ && "${size_upper%[MG]}" -ge 1 ]]
}

validate_ufw_port() {
    local port="$1"
    # Matches port (e.g., 8080) or port/protocol (e.g., 8080/tcp, 123/udp)
    [[ "$port" =~ ^[0-9]+(/tcp|/udp)?$ ]]
}

# --- Utility Functions ---
confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local response

    [[ $VERBOSE == false ]] && return 0

    if [[ $default == "y" ]]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi

    while true; do
        read -rp "$(printf '%s' "${CYAN}$prompt${NC}")" response
        response=${response,,}

        if [[ -z $response ]]; then
            response=$default
        fi

        case $response in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) printf '%s\n' "${RED}Please answer yes or no.${NC}" ;;
        esac
    done
}

convert_to_bytes() {
    local size_upper="${1^^}" # Convert to uppercase for case-insensitivity
    local unit="${size_upper: -1}"
    local value="${size_upper%[MG]}"
    if [[ "$unit" == "G" ]]; then
        echo $((value * 1024 * 1024 * 1024))
    elif [[ "$unit" == "M" ]]; then
        echo $((value * 1024 * 1024))
    else
        echo 0
    fi
}

# --- Cleanup Helper Functions ---
execute_check() {
    "$@"
}

execute_command() {
    local cmd_string="$*"

    if [[ "$CLEANUP_PREVIEW" == "true" ]]; then
        printf '%s Would execute: %s\n' "${CYAN}[PREVIEW]${NC}" "${BOLD}$cmd_string${NC}" | tee -a "$LOG_FILE"
        return 0
    else
        "$@"
        return $?
    fi
}