#!/bin/bash

# ============================================================================
# du_setup_modular.sh - Shared Utilities Library
# Common functions used across multiple modules
# ============================================================================

if [[ "${DU_SETUP_UTILS_LOADED:-false}" == "true" ]]; then
    return 0 2>/dev/null || exit 0
fi
DU_SETUP_UTILS_LOADED=true

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
    printf '%s\n' "${CYAN}║                 v0.75.0_modular | 2026-07-28                    ║${NC}"
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
            printf '║                 v0.75.0_modular | 2026-07-28                    ║\n'
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

validate_ssh_port() {
    local port="$1"
    [[ "$port" == "22" ]] || validate_port "$port"
}

validate_backup_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]]
}

validate_backup_destination() {
    [[ "$1" =~ ^[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+$ ]]
}

validate_remote_backup_path() {
    [[ "$1" =~ ^/[^[:space:]]*/$ ]]
}

validate_cron_schedule() {
    [[ "$1" =~ ^((\*/)?[0-9,-]+|\*)[[:space:]]+(((\*/)?[0-9,-]+|\*)[[:space:]]+){3}((\*/)?[0-9,-]+|\*|[0-6])$ ]]
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

    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        print_error "A required answer was not supplied in non-interactive mode: $prompt"
        return 2
    fi

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

prompt_component_desired() {
    local key="$1" label="$2" installed="$3" enabled="$4"
    local stored current
    stored=$(state_get "component.${key}" "")

    if [[ "$installed" == "true" && "$enabled" != "true" ]]; then
        current=false
        print_warning "$label is installed but disabled; treating that as intentional." >&2
        print_info "To enable it later, rerun this installer and explicitly answer yes." >&2
    elif [[ "$installed" == "true" ]]; then
        current=true
    elif [[ -n "$stored" ]]; then
        current=$(normalize_bool "$stored") || current=true
    else
        # First-run policy: install supported optional components unless the
        # operator explicitly declines.
        current=true
    fi

    prompt_bool_current "Manage and enable $label?" "$current"
}

# Persistent state is stored one value per root-owned file. Values are data,
# never sourced as shell code.
state_path() {
    local key="$1"
    [[ "$key" =~ ^[a-zA-Z0-9_.-]+$ ]] || return 1
    printf '%s/%s\n' "$DU_SETUP_STATE_DIR" "$key"
}

state_get() {
    local key="$1" fallback="${2:-}" path
    path=$(state_path "$key") || return 1
    if [[ -r "$path" ]]; then
        head -n 1 -- "$path"
    else
        printf '%s\n' "$fallback"
    fi
}

state_set() {
    local key="$1" value="$2" path temp
    path=$(state_path "$key") || return 1
    temp=$(mktemp "${DU_SETUP_STATE_DIR}/.${key}.XXXXXX")
    printf '%s\n' "$value" > "$temp"
    chmod 0600 "$temp"
    chown root:root "$temp"
    mv -f -- "$temp" "$path"
}

normalize_bool() {
    case "${1,,}" in
        y|yes|true|1|enabled) printf 'true\n' ;;
        n|no|false|0|disabled) printf 'false\n' ;;
        *) return 1 ;;
    esac
}

prompt_bool_current() {
    local prompt="$1" current response suffix
    current=$(normalize_bool "$2") || return 1
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        printf '%s\n' "$current"
        return 0
    fi
    [[ "$current" == "true" ]] && suffix="[Y/n]" || suffix="[y/N]"
    while true; do
        read -rp "$(printf '%s' "${CYAN}${prompt} ${suffix}: ${NC}")" response
        if [[ -z "$response" ]]; then
            printf '%s\n' "$current"
            return 0
        fi
        normalize_bool "$response" && return 0
        print_error "Please answer yes or no, or press Enter to keep the current value." >&2
    done
}

prompt_value_current() {
    local prompt="$1" current="$2" validator="${3:-}" response
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        if [[ -z "$current" ]] || { [[ -n "$validator" ]] && ! "$validator" "$current"; }; then
            print_error "No valid current value exists for non-interactive prompt: $prompt" >&2
            return 2
        fi
        printf '%s\n' "$current"
        return 0
    fi
    while true; do
        read -rp "$(printf '%s' "${CYAN}${prompt} [${current}]: ${NC}")" response
        response="${response:-$current}"
        if [[ -z "$validator" ]] || "$validator" "$response"; then
            printf '%s\n' "$response"
            return 0
        fi
        print_error "Invalid value: $response" >&2
    done
}

is_valid_managed_admin() {
    local user="$1"
    [[ -n "$user" ]] && id "$user" >/dev/null 2>&1 &&
        id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx sudo
}

discover_managed_admin() {
    local candidate=""
    candidate=$(state_get managed_admin "")
    if is_valid_managed_admin "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
    fi
    [[ -n "$candidate" ]] && print_warning "Stored managed administrator '$candidate' is missing or no longer in sudo." >&2
    if [[ -r "$LEGACY_MANAGED_ADMIN_STATE" ]]; then
        candidate=$(head -n 1 "$LEGACY_MANAGED_ADMIN_STATE")
        if is_valid_managed_admin "$candidate"; then
            state_set managed_admin "$candidate"
            printf '%s\n' "$candidate"
            return 0
        fi
        print_warning "Legacy managed administrator '$candidate' is no longer valid." >&2
    fi
    return 1
}

install_if_changed() {
    local source_file="$1" destination="$2" mode="${3:-0644}"
    local owner="${4:-root}" group="${5:-root}"
    if [[ -f "$destination" ]] && cmp -s -- "$source_file" "$destination"; then
        return 1
    fi
    install -D -m "$mode" -o "$owner" -g "$group" "$source_file" "$destination"
    return 0
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

# --- Docker Compose Helper ---
# Requires Docker Compose v2 and runs the command
run_docker_compose() {
    if ! docker compose version >/dev/null 2>&1; then
        print_error "Docker Compose v2 ('docker compose') is required."
        return 1
    fi
    docker compose "$@"
}
