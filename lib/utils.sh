#!/bin/bash

# ============================================================================
# du_setup_modular.sh - Shared Utilities Library
# Common functions used across multiple modules
# ============================================================================

# --- Color Definitions ---
if command -v tput >/dev/null 2>&1 && tput setaf 1 >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW="$(tput bold)$(tput setaf 3)"
    BLUE=$(tput setaf 12)  # Bright blue instead of standard blue
    PURPLE=$(tput setaf 13)  # Bright purple instead of standard purple
    CYAN=$(tput setaf 6)
    BOLD=$(tput bold)
    NC=$(tput sgr0)
else
    RED=$'\e[0;31m'
    GREEN=$'\e[0;32m'
    YELLOW=$'\e[1;33m'
    BLUE=$'\e[0;94m'  # Bright blue (code 94) instead of standard blue (34)
    PURPLE=$'\e[0;95m'  # Bright purple (code 95) instead of standard purple (35)
    CYAN=$'\e[0;36m'
    NC=$'\e[0m'
    BOLD=$'\e[1m'
fi

# --- Logging Functions ---
log() {
    # Only log if LOG_FILE is set and writable
    if [[ -n "$LOG_FILE" ]] && [[ -w "$(dirname "$LOG_FILE")" || -w "$LOG_FILE" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

print_header() {
    [[ $VERBOSE == false ]] && return
    printf '\n'
    printf '%s\n' "${CYAN}╔═════════════════════════════════════════════════════════════════╗${NC}"
    printf '%s\n' "${CYAN}║                                                                 ║${NC}"
    printf '%s\n' "${CYAN}║       DEBIAN/UBUNTU SERVER SETUP AND HARDENING SCRIPT           ║${NC}"
    printf '%s\n' "${CYAN}║                 v0.74.2_modular | 2026-01-10                    ║${NC}"
    printf '%s\n' "${CYAN}║                                                                 ║${NC}"
    printf '%s\n' "${CYAN}╚═════════════════════════════════════════════════════════════════╝${NC}"
    printf '\n'
    # Log to file if available
    if [[ -n "$LOG_FILE" ]] && [[ -w "$(dirname "$LOG_FILE")" || -w "$LOG_FILE" ]]; then
        {
            printf '\n'
            printf '╔═════════════════════════════════════════════════════════════════╗\n'
            printf '║                                                                 ║\n'
            printf '║       DEBIAN/UBUNTU SERVER SETUP AND HARDENING SCRIPT           ║\n'
            printf '║                 v0.74.2_modular | 2026-01-10                    ║\n'
            printf '║                                                                 ║\n'
            printf '╚═════════════════════════════════════════════════════════════════╝\n'
            printf '\n'
        } >> "$LOG_FILE" 2>/dev/null || true
    fi
}

print_section() {
    [[ $VERBOSE == false ]] && return
    printf '\n%s\n' "${BLUE}▓▓▓ $1 ▓▓▓${NC}"
    printf '%s\n' "${BLUE}$(printf '═%.0s' {1..65})${NC}"
    # Log to file if available
    if [[ -n "$LOG_FILE" ]] && [[ -w "$(dirname "$LOG_FILE")" || -w "$LOG_FILE" ]]; then
        printf '\n▓▓▓ %s ▓▓▓\n' "$1" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

print_success() {
    [[ $VERBOSE == false ]] && return
    printf '%s\n' "${GREEN}✓ $1${NC}"
    # Log to file if available
    if [[ -n "$LOG_FILE" ]] && [[ -w "$(dirname "$LOG_FILE")" || -w "$LOG_FILE" ]]; then
        printf '✓ %s\n' "$1" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

print_error() {
    printf '%s\n' "${RED}✗ $1${NC}"
    # Log to file if available
    if [[ -n "$LOG_FILE" ]] && [[ -w "$(dirname "$LOG_FILE")" || -w "$LOG_FILE" ]]; then
        printf '✗ %s\n' "$1" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

print_warning() {
    [[ $VERBOSE == false ]] && return
    printf '%s\n' "${YELLOW}⚠ $1${NC}"
    # Log to file if available
    if [[ -n "$LOG_FILE" ]] && [[ -w "$(dirname "$LOG_FILE")" || -w "$LOG_FILE" ]]; then
        printf '⚠ %s\n' "$1" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

print_info() {
    [[ $VERBOSE == false ]] && return
    printf '%s\n' "${PURPLE}ℹ $1${NC}"
    # Log to file if available
    if [[ -n "$LOG_FILE" ]] && [[ -w "$(dirname "$LOG_FILE")" || -w "$LOG_FILE" ]]; then
        printf 'ℹ %s\n' "$1" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

print_separator() {
    local header_text="$1"
    local color="${2:-$YELLOW}"
    local separator_char="${3:-=}"

    printf '%s\n' "${color}${header_text}${NC}"
    printf "${separator_char}%.0s" $(seq 1 ${#header_text})
    printf '\n'
    # Log to file if available
    if [[ -n "$LOG_FILE" ]] && [[ -w "$(dirname "$LOG_FILE")" || -w "$LOG_FILE" ]]; then
        printf '%s\n' "$header_text" >> "$LOG_FILE" 2>/dev/null || true
        printf "${separator_char}%.0s" $(seq 1 ${#header_text}) >> "$LOG_FILE" 2>/dev/null || true
        printf '\n' >> "$LOG_FILE" 2>/dev/null || true
    fi
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

# Check if a package is installed
is_installed() {
    # Usage: is_installed package-name && ...
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "installed"
}

# Ensure a directory exists and has proper ownership/permissions
ensure_dir_owned() {
    local dir="$1"
    mkdir -p "$dir"
    chmod 750 "$dir"
}

execute_command() {
    local cmd_string="$*"

    if [[ "$CLEANUP_PREVIEW" == "true" ]]; then
        printf '%s Would execute: %s\n' "${CYAN}[PREVIEW]${NC}" "${BOLD}$cmd_string${NC}"
        # Log to file if available
        if [[ -n "$LOG_FILE" ]] && [[ -w "$(dirname "$LOG_FILE")" || -w "$LOG_FILE" ]]; then
            printf '[PREVIEW] Would execute: %s\n' "$cmd_string" >> "$LOG_FILE" 2>/dev/null || true
        fi
        return 0
    else
        "$@"
        return $?
    fi
}