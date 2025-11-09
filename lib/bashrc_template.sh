# shellcheck shell=bash
# ===================================================================
#   Universal Portable .bashrc for Modern Terminals
#   Optimized for Debian/Ubuntu servers with multi-terminal support
# ===================================================================

# If not running interactively, don't do anything.
case $- in
    *i*) ;;
      *) return ;;
esac

# --- History Control ---
# Don't put duplicate lines or lines starting with space in the history.
HISTCONTROL=ignoreboth:erasedups
# Append to the history file, don't overwrite it.
shopt -s histappend
# Set history length with reasonable values for server use.
HISTSIZE=10000
HISTFILESIZE=20000
# Allow editing of commands recalled from history.
shopt -s histverify
# Add timestamp to history entries for audit trail (ISO 8601 format).
HISTTIMEFORMAT="%Y-%m-%d %H:%M:%S  "
# Ignore common commands from history to reduce clutter.
HISTIGNORE="ls:ll:la:l:cd:pwd:exit:clear:c:history:h"

# --- General Shell Behavior & Options ---
# Check the window size after each command and update LINES and COLUMNS.
shopt -s checkwinsize
# Allow using '**' for recursive globbing (Bash 4.0+, suppress errors on older versions).
shopt -s globstar 2>/dev/null
# Allow changing to a directory by just typing its name (Bash 4.0+).
shopt -s autocd 2>/dev/null
# Autocorrect minor spelling errors in directory names (Bash 4.0+).
shopt -s cdspell 2>/dev/null
# Correct multi-line command editing.
shopt -s cmdhist 2>/dev/null
# Case-insensitive globbing (commented out to avoid unexpected behavior).
# shopt -s nocaseglob 2>/dev/null

# Set command-line editing mode. Emacs (default) or Vi.
set -o emacs
# For vi keybindings, uncomment the following line and comment the one above:
# set -o vi

# Make `less` more friendly for non-text input files.
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)" && export LESS='-RFXiMw'
# Colored man pages using less (TERMCAP sequences).
export LESS_TERMCAP_mb=$'\e[1;31m'
export LESS_TERMCAP_md=$'\e[1;36m'
export LESS_TERMCAP_me=$'\e[0m'
export LESS_TERMCAP_se=$'\e[0;36m'
export LESS_TERMCAP_so=$'\e[1;32m'
export LESS_TERMCAP_ue=$'\e[0m'

# --- Terminal & SSH Compatibility Fixes ---
# Handle Kitty terminal over SSH - fallback to xterm-256color if terminfo unavailable.
if [[ "$TERM" == "xterm-kitty" ]]; then
    # Check if kitty terminfo is available, otherwise fallback.
    if ! infocmp xterm-kitty &>/dev/null; then
        export TERM=xterm-256color
    fi
    # Ensure the shell looks for user-specific terminfo files.
    [[ -d "$HOME/.terminfo" ]] && export TERMINFO="$HOME/.terminfo"
fi

# Fix for other modern terminals that might not be recognized on older servers.
case "$TERM" in
    alacritty|wezterm)
        if ! infocmp "$TERM" &>/dev/null; then
            export TERM=xterm-256color
        fi
        ;;
esac

# Optional: if kitty exists locally, provide a convenience alias for SSH.
if command -v kitty &>/dev/null; then
    alias kssh='kitty +kitten ssh'
fi

# --- Prompt Configuration ---
# Set variable identifying the chroot you work in (used in the prompt below).
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(</etc/debian_chroot)
fi

# Set a colored prompt only if the terminal has color capability.
case "$TERM" in
    xterm-color|*-256color|xterm-kitty|alacritty|wezterm) color_prompt=yes;;
esac
if [ -z "$color_prompt" ] && [ -x /usr/bin/tput ] && tput setaf 1 &>/dev/null; then
    color_prompt=yes
fi

# --- Function to parse git branch only if in a git repo ---
parse_git_branch() {
    if git rev-parse --git-dir &>/dev/null; then
        git branch 2>/dev/null | sed -n '/^\*/s/* \(.*\)/\1/p'
    fi
    return 0
}

# --- Main prompt command function ---
__bash_prompt_command() {
    local rc=$?  # Capture last command exit status
    history -a
    history -n

    # --- Initialize prompt components ---
    local prompt_err="" prompt_git="" prompt_jobs="" prompt_venv=""
    local git_branch job_count

    # Error indicator
    (( rc != 0 )) && prompt_err="\[\e[31m\]✗\[\e[0m\]"

    # Git branch (dim yellow)
    git_branch=$(parse_git_branch)
    [[ -n "$git_branch" ]] && prompt_git="\[\e[2;33m\]($git_branch)\[\e[0m\]"

    # Background jobs (cyan)
    job_count=$(jobs -p | wc -l)
    (( job_count > 0 )) && prompt_jobs="\[\e[36m\]⚡${job_count}\[\e[0m\]"

    # Python virtualenv (dim green)
    [[ -n "$VIRTUAL_ENV" ]] && prompt_venv="\[\e[2;32m\][${VIRTUAL_ENV##*/}]\[\e[0m\]"

    # Ensure spacing between components
    [[ -n "$prompt_venv" ]] && prompt_venv=" $prompt_venv"
    [[ -n "$prompt_git" ]] && prompt_git=" $prompt_git"
    [[ -n "$prompt_jobs" ]] && prompt_jobs=" $prompt_jobs"
    [[ -n "$prompt_err" ]] && prompt_err=" $prompt_err"

    # --- Assemble PS1 ---
    if [ "$color_prompt" = yes ]; then
        PS1='${debian_chroot:+($debian_chroot)}\[\e[32m\]\u@\h\[\e[0m\]:\[\e[34m\]\w\[\e[0m\]'"${prompt_venv}${prompt_git}${prompt_jobs}${prompt_err}"' \$ '
    else
        PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w'"${prompt_venv}${git_branch}${prompt_jobs}${prompt_err}"' \$ '
    fi

    # --- Set Terminal Window Title ---
    case "$TERM" in
      xterm-kitty|alacritty|wezterm|xterm*|rxvt*)
        PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
        ;;
    esac
}

# --- Activate dynamic prompt ---
PROMPT_COMMAND=__bash_prompt_command

# --- Editor Configuration ---
# Set default editor with fallback chain.
if command -v vim &>/dev/null; then
    export EDITOR=vim
    export VISUAL=vim
elif command -v vi &>/dev/null; then
    export EDITOR=vi
    export VISUAL=vi
else
    export EDITOR=nano
    export VISUAL=nano
fi

# --- Additional Environment Variables ---
# Set default pager.
export PAGER=less
# Prevent Ctrl+S from freezing the terminal.
stty -ixon 2>/dev/null

# --- Useful Functions ---
# Create a directory and change into it.
mkcd() {
    mkdir -p "$1" && cd "$1" || exit
}

# Create a backup of a file with timestamp.
backup() {
    if [ -f "$1" ]; then
        local backup_file
        backup_file="$1.backup-$(date +%Y%m%d-%H%M%S)"
        cp "$1" "$backup_file"
        echo "Backup created: $backup_file"
    else
        echo "'$1' is not a valid file" >&2
        return 1
    fi
}

# Extract any archive file with a single command.
extract() {
    if [ -f "$1" ]; then
        case "$1" in
            *.tar.bz2)    tar xjf "$1"      ;;
            *.tar.gz)     tar xzf "$1"      ;;
            *.tar.xz)     tar xJf "$1"      ;;
            *.bz2)        bunzip2 "$1"      ;;
            *.gz)         gunzip "$1"       ;;
            *.tar)        tar xf "$1"       ;;
            *.tbz2)       tar xjf "$1"      ;;
            *.tgz)        tar xzf "$1"      ;;
            *.zip)        unzip "$1"        ;;
            *.Z)          uncompress "$1"   ;;
            *.7z)         7z x "$1"         ;;
            *.deb)        ar x "$1"         ;;
            *.tar.zst)
                if command -v zstd &>/dev/null; then
                    zstd -dc "$1" | tar xf -
                else
                    tar --zstd -xf "$1"
                fi
                ;;
            *)
                echo "'$1' cannot be extracted via extract()" >&2
                return 1
                ;;
        esac
    else
        echo "'$1' is not a valid file" >&2
        return 1
    fi
}

# Quick directory navigation up multiple levels.
up() {
    local d=""
    local limit="${1:-1}"
    for ((i=1; i<=limit; i++)); do
        d="../$d"
    done
    cd "$d" || return
}

# Find files by name in current directory tree.
ff() {
    find . -type f -iname "*$1*" 2>/dev/null
}

# Find directories by name in current directory tree.
fd() {
    find . -type d -iname "*$1*" 2>/dev/null
}

# Search for text in files recursively.
ftext() {
    grep -rnw . -e "$1" 2>/dev/null
}

# Create a tarball of a directory.
targz() {
    if [ -d "$1" ]; then
        tar czf "${1%%/}.tar.gz" "${1%%/}"
        echo "Created ${1%%/}.tar.gz"
    else
        echo "'$1' is not a valid directory" >&2
        return 1
    fi
}

# Show disk usage of current directory, sorted by size.
duh() {
    du -h --max-depth=1 "${1:-.}" | sort -hr
}

# Get the size of a file or directory.
sizeof() {
    du -sh "$1" 2>/dev/null
}

# Show most used commands from history.
histop() {
    history | awk '{CMD[$2]++; count++;} END { for (a in CMD) print count[a], a, (count[a]/count)*100 "%"}' | grep -v "./" | column -c3 -s " " -t | head -n20
}

# Quick server info display
sysinfo() {
    # --- Self-Contained Color Detection ---
    local color_support=""
    case "$TERM" in
        xterm-color|*-256color|xterm-kitty|alacritty|wezterm) color_support="yes";;
    esac
    if [ -z "$color_support" ] && [ -x /usr/bin/tput ] && tput setaf 1 &>/dev/null; then
        color_support="yes"
    fi

    # --- Color Definitions ---
    if [ "$color_support" = "yes" ]; then
        local CYAN='\e[1;36m'
        local YELLOW='\e[1;33m'
        local BOLD_RED='\e[1;31m'
        local BOLD_WHITE='\e[1;37m'
        local GREEN='\e[1;32m'
        local DIM='\e[2m'
        local RESET='\e[0m'
    else
        local CYAN='' YELLOW='' BOLD_RED='' BOLD_WHITE='' GREEN='' DIM='' RESET=''
    fi

    # --- Header ---
    printf "\n%s=== System Information ===%s\n" "${BOLD_WHITE}" "${RESET}"

    # --- CPU Info ---
    local cpu_info
    cpu_info=$(lscpu | awk -F: '/Model name/ {print $2; exit}' | xargs || grep -m1 'model name' /proc/cpuinfo | cut -d ':' -f2 | xargs || echo "Unknown")
    [ -z "$cpu_info" ] && cpu_info="Unknown"

    # --- IP Detection (preferred interfaces first) ---
    local ip_addr
    for iface in eth0 wlan0 ens33 eno1 enp0s3; do
        ip_addr=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
        [ -n "$ip_addr" ] && break
    done
    [ -z "$ip_addr" ] && ip_addr=$(ip -4 addr show scope global | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)

    # --- System Info ---
    if [ -n "$ip_addr" ]; then
        printf "${CYAN}%-15s ${RESET} %s  ${YELLOW}[%s]${RESET}\n" "Hostname:" "$(hostname)" "$ip_addr"
    else
        printf "${CYAN}%-15s ${RESET} %s\n" "Hostname:" "$(hostname)"
    fi
    printf "${CYAN}%-15s ${RESET} %s\n" "OS:" "$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'Unknown')"
    printf "${CYAN}%-15s ${RESET} %s\n" "Kernel:" "$(uname -r)"
    printf "${CYAN}%-15s ${RESET} %s\n" "Uptime:" "$(uptime -p 2>/dev/null || uptime | sed 's/.*up //' | sed 's/,.*//')"
    printf "${CYAN}%-15s ${RESET} %s\n" "Server time:" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf "${CYAN}%-15s ${RESET} %s\n" "CPU:" "$cpu_info"

    # --- FIX 1: Corrected Memory line ---
    printf "${CYAN}%-15s${RESET}Memory: %s\n" "$(free -m | awk '/Mem/ {
        used = $3; total = $2; percent = int((used/total)*100);
        if (used >= 1024) { used_fmt = sprintf("%.1fGi", used/1024); } else { used_fmt = sprintf("%dMi", used); }
        if (total >= 1024) { total_fmt = sprintf("%.1fGi", total/1024); } else { total_fmt = sprintf("%dMi", total); }
        printf "%s / %s (%d%% used)\n", used_fmt, total_fmt, percent;
    }')"

    printf "${CYAN}%-15s ${RESET} %s\n" "Disk (/):" "$(df -h / | awk 'NR==2 {print $3 " / " $4 " (" $5 " used)"}')"

    # --- Reboot Status ---
    if [ -f /var/run/reboot-required ]; then
        printf "${CYAN}%-15s ${RESET} ${BOLD_RED}⚠ REBOOT REQUIRED${RESET}\n" "System:"
        [ -s /var/run/reboot-required.pkgs ] && \
            printf "                 ${DIM}Reason:${RESET} %s\n" "$(paste -sd ' ' /var/run/reboot-required.pkgs)"
    fi

    # --- Available Updates (APT) ---
    if command -v apt-get &>/dev/null; then
        # ... (apt-check logic) ...
        if [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null; then
            # --- FIX 2: Corrected Updates line ---
            printf "${CYAN}%-15s${RESET} %d packages available\n" "Updates:" "$total"
            if [ -n "$security" ] && [ "$security" -gt 0 ] 2>/dev/null; then
                printf " (%s security)\n" "$security"
            fi
            printf "\n"

            # List upgradable packages (up to 5) and highlight security
            mapfile -t upgradable_all < <(apt list --upgradable 2>/dev/null | tail -n +2)
            upgradable_list=$(printf "%s\n" "${upgradable_all[@]}" | head -n5 | awk -F/ '{print $1}')
            security_list=$(printf "%s\n" "${upgradable_all[@]}" | grep -i security | head -n5 | awk -F/ '{print $1}')
            [ -n "$upgradable_list" ] && \
                printf "                 ${DIM}Upgradable:${RESET} %s" "$(echo "$upgradable_list" | paste -sd ', ')"
            [ "$total" -gt 5 ] && printf " ... (+%s more)\n" $((total - 5))
            [ -n "$security_list" ] && \
                printf "                 ${YELLOW}Security:${RESET} %s" "$(echo "$security_list" | paste -sd ', ')"
            [ "$security" -gt 5 ] && printf " ... (+%s more)\n" $((security - 5))
        fi
    fi

    # --- Docker Info ---
    if command -v docker >/dev/null 2>&1; then
        mapfile -t docker_states < <(docker ps -a --format '{{.State}}' 2>/dev/null)
        total=${#docker_states[@]}
        if (( total > 0 )); then
            running=$(printf "%s\n" "${docker_states[@]}" | grep -c '^running$')
            printf "${CYAN}%-15s ${RESET} ${GREEN}%s running${RESET} / %s total containers\n" "Docker:" "$running" "$total"
        fi
    fi

    printf "\n"
}

# Check for available updates
checkupdates() {
    if [ -x /usr/lib/update-notifier/apt-check ]; then
        echo "Checking for updates..."
        /usr/lib/update-notifier/apt-check --human-readable
    elif command -v apt &>/dev/null; then
        apt list --upgradable 2>/dev/null
    else
        echo "No package manager found"
        return 1
    fi
}

# --- Aliases ---
# Enable color support for common commands.
if [ -x /usr/bin/dircolors ]; then
    if test -r ~/.dircolors; then
        eval "$(dircolors -b ~/.dircolors)"
    else
        eval "$(dircolors -b)"
    fi
    alias ls='ls --color=auto'
    alias dir='dir --color=auto'
    alias vdir='vdir --color=auto'
    alias grep='grep --color=auto'
    alias egrep='grep -E --color=auto'
    alias fgrep='grep -F --color=auto'
    alias diff='diff --color=auto'
    alias ip='ip --color=auto'
fi

# Standard ls aliases with human-readable sizes.
alias ll='ls -alFh'
alias la='ls -A'
alias l='ls -CF'
alias lt='ls -alFht'        # Sort by modification time, newest first
alias ltr='ls -alFhtr'      # Sort by modification time, oldest first
alias lS='ls -alFhS'        # Sort by size, largest first

# Safety aliases to prompt before overwriting.
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'
alias ln='ln -i'

# Convenience & Navigation aliases.
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'
alias -- -='cd -'
alias ~='cd ~'
alias h='history'
alias c='clear'
alias cls='clear'
alias reload='source ~/.bashrc && echo "Bashrc reloaded!"'

# PATH printer as a function (portable, no echo -e)
unalias path 2>/dev/null
path() {
    printf '%s\n' "${PATH//:/$'\n'}"
}

# Enhanced directory listing.
alias lsd='ls -d */ 2>/dev/null'      # List only directories
alias lsf='find . -maxdepth 1 -type f -printf "%f\n"'  # List only files

# System resource helpers.
alias df='df -h'
alias du='du -h'
alias free='free -h'
# psgrep as a function to accept patterns reliably
unalias psgrep 2>/dev/null
psgrep() {
    if [ $# -eq 0 ]; then
        echo "Usage: psgrep <pattern>" >&2
        return 1
    fi
    pgrep -af -i "$1"
}
alias ports='ss -tuln'
alias listening='ss -tlnp'
alias meminfo='free -h -l -t'
alias psmem='ps auxf | sort -nr -k 4 | head -10'
alias pscpu='ps auxf | sort -nr -k 3 | head -10'
alias top10='ps aux --sort=-%mem | head -n 11'

# Quick network info.
alias myip='curl -s ifconfig.me || curl -s icanhazip.com' # Alternatives: api.ipify.org, icanhazip.co
# Show local IP address(es), excluding loopback.
localip() {
    ip -4 addr | awk '/inet/ {print $2}' | cut -d/ -f1 | grep -v '127.0.0.1'
}
alias netstat='ss'
alias ping='ping -c 5'
alias fastping='ping -c 100 -i 0.2'

# Date and time helpers.
alias now='date +"%Y-%m-%d %H:%M:%S"'
alias nowdate='date +"%Y-%m-%d"'
alias timestamp='date +%s'

# File operations.
alias count='find . -type f | wc -l'  # Count files in current directory
alias cpv='rsync -ah --info=progress2'  # Copy with progress
alias wget='wget -c'  # Resume wget by default

# Git shortcuts (if git is available).
if command -v git &>/dev/null; then
    alias gs='git status'
    alias ga='git add'
    alias gc='git commit'
    alias gp='git push'
    alias gl='git log --oneline --graph --decorate'
    alias gd='git diff'
    alias gb='git branch'
    alias gco='git checkout'
fi

# --- Docker Shortcuts and Functions ---
if command -v docker >/dev/null 2>&1; then
    # Core Docker aliases
    alias d='docker'
    alias dps='docker ps'
    alias dpsa='docker ps -a'
    alias dpsq='docker ps -q'
    alias di='docker images'
    alias dv='docker volume ls'
    alias dn='docker network ls'
    alias dex='docker exec -it'
    alias dlog='docker logs -f'
    alias dins='docker inspect'
    alias drm='docker rm'
    alias drmi='docker rmi'
    alias dpull='docker pull'

    # Docker system management
    alias dprune='docker system prune -f'
    alias dprunea='docker system prune -af'
    alias ddf='docker system df'
    alias dvprune='docker volume prune -f'
    alias diprune='docker image prune -af'
    alias drmall='docker container prune -f'

    # Docker stats
    alias dstats='docker stats --no-stream'
    alias dstatsa='docker stats'
    dtop() {
        docker stats --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}'
    }

    # Safe stop all (shows command instead of executing)
    alias dstopall='echo "To stop all containers, run: docker stop \$(docker ps -q)"'

    # Docker Compose v2 aliases (check if compose plugin exists)
    if docker compose version &>/dev/null; then
        alias dc='docker compose'
        alias dcup='docker compose up -d'
        alias dcdown='docker compose down'
        alias dclogs='docker compose logs -f'
        alias dcps='docker compose ps'
        alias dcex='docker compose exec'
        alias dcbuild='docker compose build'
        alias dcbn='docker compose build --no-cache'
        alias dcrestart='docker compose restart'
        alias dcrecreate='docker compose up -d --force-recreate'
        alias dcpull='docker compose pull'
        alias dcstop='docker compose stop'
        alias dcstart='docker compose start'
        alias dcconfig='docker compose config'
        alias dcvalidate='docker compose config --quiet && echo "✓ docker-compose.yml is valid" || echo "✗ docker-compose.yml has errors"'
    fi

# --- Docker Functions ---

# Enter container shell (bash or sh fallback)
dsh() {
    if [ -z "$1" ]; then
        echo "Usage: dsh <container-name-or-id>" >&2
        return 1
    fi
    docker exec -it "$1" bash 2>/dev/null || docker exec -it "$1" sh
}

# Docker Compose enter shell (bash or sh fallback)
dcsh() {
    if [ -z "$1" ]; then
        echo "Usage: dcsh <service-name>" >&2
        return 1
    fi
    docker compose exec "$1" bash 2>/dev/null || docker compose exec "$1" sh
}

# Follow logs for a specific container with tail
dfollow() {
    if [ -z "$1" ]; then
        echo "Usage: dfollow <container-name-or-id> [lines]" >&2
        return 1
    fi
    local lines="${2:-100}"
    docker logs -f --tail "$lines" "$1"
}

# Show container IP addresses
dip() {
    if [ -z "$1" ]; then
        docker ps -q | xargs -I {} docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' {} 2>/dev/null
    else
        docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1" 2>/dev/null
    fi
}

# Show bind mounts for containers
dbinds() {
    if [ -z "$1" ]; then
        printf "\n\033[1;32mContainer Bind Mounts:\033[0m\n"
        printf "═══════════════════════════════════════════════\n"
        docker ps --format '{{.Names}}' | while IFS= read -r container; do
            printf "\n\033[1;32m%s\033[0m:\n" "$container"
            docker inspect "$container" --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}} → {{.Destination}}{{end}}{{end}}' "$container" 2>/dev/null
        done
        printf "\n\033[1;32m═════════════════════════════════════════\n"
    else
        printf "\nBind mounts for %s:\n" "$1"
        docker inspect "$1" --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}} → {{.Destination}}{{end}}{{end}}' "$1" 2>/dev/null
    fi
}

# Show disk usage by containers (enable size reporting)
dsize() {
    printf "\n%-40s %s\n" "Container" "Size"
    printf "═════════════════════════════════════════\n"
    docker ps -a --size --format '{{.Names}}\t{{.Size}}' | column -t
    printf "\n"
}

# Restart a compose service and follow logs
dcreload() {
    if [ -z "$1" ]; then
        echo "Usage: dcreload <service-name>" >&2
        return 1
    fi
    docker compose restart "$1" && docker compose logs -f "$1"
}

# Update and restart a single compose service
dcupdate() {
    if [ -z "$1" ]; then
        echo "Usage: dcupdate <service-name>" >&2
        return 1
    fi
    docker compose pull "$1" && docker compose up -d "$1" && docker compose logs -f "$1"
}

# Show Docker Compose services status with detailed info
dcstatus() {
    printf "\n=== Docker Compose Services ===\n\n"
    docker compose ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}'
    printf "\n=== Resource Usage ===\n\n"
    docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}'
    printf "\n"
}

# Watch Docker Compose logs for specific service with grep
dcgrep() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Usage: dcgrep <service-name> <search-pattern>" >&2
        return 1
    fi
    docker compose logs -f "$1" | grep --color=auto -i "$2"
}

# Show environment variables for a container
denv() {
    if [ -z "$1" ]; then
        echo "Usage: denv <container-name-or-id>" >&2
        return 1
    fi
    docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sort
}

# Remove all stopped containers
drmall() {
    # Using modern, direct command
    docker container prune -f
}

fi

# --- Systemd shortcuts.
if command -v systemctl &>/dev/null; then
    alias sysstart='sudo systemctl start'
    alias sysstop='sudo systemctl stop'
    alias sysrestart='sudo systemctl restart'
    alias sysstatus='sudo systemctl status'
    alias sysenable='sudo systemctl enable'
    alias sysdisable='sudo systemctl disable'
    alias sysreload='sudo systemctl daemon-reload'
fi

# --- Apt aliases for Debian/Ubuntu (only if apt is available) ---
if command -v apt &>/dev/null; then
    alias aptup='sudo apt update && sudo apt upgrade'
    alias aptin='sudo apt install'
    alias aptrm='sudo apt remove'
    alias aptsearch='apt search'
    alias aptshow='apt show'
    alias aptclean='sudo apt autoremove && sudo apt autoclean'
    alias aptlist='apt list --installed'
fi

# --- PATH Configuration ---
# Add user's local bin directories to PATH if they exist.
[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"
[ -d "$HOME/bin" ] && export PATH="$HOME/bin:$PATH"

# --- Server-Specific Configuration ---
# Load hostname-specific configurations if they exist.
# This allows per-server customization without modifying main bashrc.
if [ -f ~/.bashrc."$(hostname -s)" ]; then
    # shellcheck disable=SC1090
    . ~/.bashrc."$(hostname -s)"
fi

# --- Bash Completion & Personal Aliases ---
# Enable programmable completion features.
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    # shellcheck disable=SC1091
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    # shellcheck disable=SC1091
    . /etc/bash_completion
  fi
fi

# Source personal aliases if file exists.
if [ -f ~/.bash_aliases ]; then
    # shellcheck disable=SC1090
    . ~/.bash_aliases
fi

# Source local machine-specific settings that shouldn't be in version control.
if [ -f ~/.bashrc.local ]; then
    # shellcheck disable=SC1090
    . ~/.bashrc.local
fi

# --- Welcome Message for SSH Sessions ---
# Show system info and context on login for SSH sessions.
if [ -n "$SSH_CONNECTION" ]; then
    # Use existing sysinfo function for a full system overview.
    sysinfo

    # Display previous login information (skip current session)
    last_login=$(last -R "$USER" 2>/dev/null | sed -n '2p' | awk '{$1=""; print}' | xargs || echo "")
    [ -n "$last_login" ] && printf "Last login: %s\n" "$last_login"

    # Show active sessions
    printf "Active sessions: %s\n" "$(who | wc -l)"
    printf -- "-----------------------------------------------------\n\n"
fi

# --- Help System ---
# Display all custom functions and aliases with descriptions
bashhelp() {
    local category="${1:-all}"

    case "$category" in
        all|"")
            cat << 'HELPTEXT'

╔══════════════════════════════════════════════════╗
║              .bashrc - Quick Reference                 ║
╚═══════════════════════════════════════════════════╝

Usage: bashhelp [category]
Categories: navigation, files, system, docker, git, network

════════════════════════════════════════════════════
 📁 NAVIGATION & DIRECTORY
══════════════════════════════════════════════════
  ..                 Go up one directory
  ...                Go up two directories
  ....               Go up three directories
  .....              Go up four directories
  -                  Go to previous directory
  ~                  Go to home directory
  mkcd <dir>         Create directory and cd into it
  up <n>             Go up N directories (e.g., up 3)
  path               Display PATH variable (one per line)

 ════════════════════════════════════════════════
 📄 FILE OPERATIONS
════════════════════════════════════════════════
Listing:
  ll, la, l, lt, ltr, lS, lsd, lsf

Finding:
  ff <name>          Find files by name (case-insensitive)
  fd <name>          Find directories by name (case-insensitive)
  ftext <text>       Search for text in files recursively

Archives:
  extract <file>     Extract any archive (tar, zip, 7z, etc.)
  targz <dir>        Create tar.gz of directory
  backup <file>      Create timestamped backup of file

Size Info:
  sizeof <path>      Get size of file or directory
  duh [path]         Disk usage sorted by size
  count              Count files in current directory
  cpv <src> <dst>  Copy with progress (rsync)

 ════════════════════════════════════════════════
 💻 SYSTEM & MONITORING
════════════════════════════════════════════════
Overview:
  sysinfo            Display comprehensive system information
  checkupdates       Check for available system updates

Processes:
  psgrep <pat>       Search for process by name
  psmem              Show top 10 processes by memory usage
  pscpu              Show top 10 processes by CPU usage
  top10              Show top memory-consuming processes
  histop             Show most used commands
  reload             Reload bashrc configuration

Network:
  ports              Show all listening ports (TCP/UDP)
  listening          Show listening ports with process info
  meminfo            Display detailed memory information
  free               Free memory (human-readable)

History:
  h                  Show command history
  histop             Show most used commands

 ════════════════════════════════════════════════
 🐳 DOCKER & DOCKER COMPOSE
══════════════════════════════════════════════════
Docker Commands:
  d, dps, dpsa, di, dv, dn, dex, dlog, dins, drm, drmi, dpull

Management:
  dsh <id>           Enter container shell (bash/sh)
  dip [id]           Show container IP addresses
  dsize              Show disk usage by containers
  dbinds [id]        Show bind mounts for containers
  denv <id>          Show environment variables
  dfollow <id>       Follow logs with tail (default 100 lines)
  drmall             Remove all stopped containers

Stats & Cleanup:
  dstats, dstatsa, dtop
  dprune, dprunea, ddf, dvprune, diprune

Docker Compose:
  dc, dcup, dcdown, dclogs, dcps, dcex, dcsh

Management:
  dcbuild, dcbn, dcrestart, dcrecreate, dcpull, dcstop, dcstart
  dcstatus           Show service status & resource usage
  dcreload <srv>     Restart service and follow logs
  dcupdate <srv>     Pull, restart service, follow logs
  dcgrep <srv> <p>  Filter service logs
  dcconfig           Show resolved compose configuration
  dcvalidate         Validate compose file syntax

Examples:
  dsh mycontainer
  dcup
  dcupdate nginx
  dcgrep app "error"

 ══════════════════════════════════════════════════
 🔀 GIT SHORTCUTS
════════════════════════════════════════════════════
  gs                 git status
  ga                 git add
  gc                 git commit
  gp                 git push
  gl                 git log (graph view)
  gd                 git diff
  gb                 git branch
  gco                git checkout

Examples:
  gs                   # Check status
  ga .                 # Add all changes
  gc -m "Update docs"  # Commit with message
  gp                   # Push to remote

 ══════════════════════════════════════════════════
 🌐 NETWORK
════════════════════════════════════════════════════
  myip               Show external IP address
  localip            Show local IP address(es)
  ports              Show all listening ports
  listening          Show listening ports with process info
  ping               Ping with 5 packets (default)
  fastping           Fast ping (100 packets, 0.2s interval)
  netstat            Network connections (ss)

Examples:
  myip               # Get public IP
  localip            # Get local IPs
  ping google.com      # Ping with 5 packets
  ports              # Show all open ports

 ══════════════════════════════════════════════════
 ⚙️  SYSTEM ADMINISTRATION
════════════════════════════════════════════════════
Systemd:
  sysstart <srv>    Start service
  sysstop <srv>     Stop service
  sysrestart <srv>   Restart service
  sysstatus <srv>    Show service status
  sysenable <srv>    Enable service
  sysdisable <srv>   Disable service
  sysreload          Reload systemd daemon

APT (Debian/Ubuntu):
  aptup              Update and upgrade packages
  aptin <pkg>        Install package
  aptrm <pkg>        Remove package
  aptsearch <term>    Search for packages
  aptshow <pkg>      Show package information
  aptclean           Remove unused packages
  aptlist            List installed packages

 ════════════════════════════════════════════════
 🕒 DATE & TIME
══════════════════════════════════════════════════════════
  now                Current date and time (YYYY-MM-DD HH:MM:SS)
  nowdate            Current date (YYYY-MM-DD)
  timestamp          Unix timestamp

 ════════════════════════════════════════════════
 ℹ️  HELP & INFORMATION
══════════════════════════════════════════════════════
  bashhelp           Show this help (all categories)
  bashhelp navigation Show navigation commands only
  bashhelp files     Show file operation commands
  bashhelp system    Show system monitoring commands
  bashhelp docker    Show docker commands only
  bashhelp git       Show git shortcuts
  bashhelp network   Show network commands

 ════════════════════════════════════════════════
 💡 TIP: Most commands support --help or -h for more information
      The prompt shows: ✗ for failed commands, git branch when in repo
      The prompt includes Docker status when available
      Run 'commands' to see all available commands

HELPTEXT
            ;;
        navigation)
            cat << 'HELPTEXT'

═ NAVIGATION & DIRECTORY COMMANDS ═══

  ..                 Go up one directory
  ...                Go up two directories
  ....               Go up three directories
  .....              Go up four directories
  -                  Go to previous directory
  ~                  Go to home directory
  mkcd <dir>         Create directory and cd into it
  up <n>             Go up N directories (e.g., up 3)
  path               Display PATH variable (one per line)

Examples:
  mkcd ~/projects/newapp     # Create and enter directory
  up 3                       # Go up 3 levels
  cd -                       # Return to previous directory

HELPTEXT
            ;;
        files)
            cat << 'HELPTEXT'

═ FILE OPERATION COMMANDS ═══

Listing:
  ll, la, l, lt, ltr, lS, lsd, lsf

Finding:
  ff <name>          Find files by name (case-insensitive)
  fd <name>          Find directories by name (case-insensitive)
  ftext <text>       Search for text in files recursively

Archives:
  extract <file>     Extract any archive (tar, zip, 7z, etc.)
  targz <dir>        Create tar.gz of directory
  backup <file>      Create timestamped backup of file

Size Info:
  sizeof <path>      Get size of file or directory
  duh [path]         Disk usage sorted by size
  count              Count files in current directory
  cpv <src> <dst>  Copy with progress (rsync)

Examples:
  ff README          # Find files named *README*
  extract data.tar.gz  # Extract tar.gz archive
  backup ~/.bashrc    # Backup .bashrc with timestamp

HELPTEXT
            ;;
        system)
            cat << 'HELPTEXT'

═ SYSTEM MONITORING COMMANDS ═══

Overview:
  sysinfo            Display comprehensive system information
  checkupdates       Check for available system updates

Processes:
  psgrep <pat>       Search for process by name
  psmem              Show top 10 processes by memory usage
  pscpu              Show top 10 processes by CPU usage
  top10              Show top memory-consuming processes
  histop             Show most used commands
  reload             Reload bashrc configuration

Network:
  ports              Show all listening ports (TCP/UDP)
  listening          Show listening ports with process info
  meminfo            Display detailed memory information
  free               Free memory (human-readable)

History:
  h                  Show command history
  histop             Show most used commands

Examples:
  psgrep nginx
  psmem | grep docker
  ports
  sysinfo

HELPTEXT
            ;;
        docker)
            cat << 'HELPTEXT'

═ DOCKER COMMANDS ═══

Basic:
  dps, dpsa, di, dv, dn, dex, dlog, dins, drm, drmi, dpull

Management:
  dsh <id>           Enter container shell (bash/sh)
  dip [id]           Show container IP addresses
  dsize              Show disk usage by containers
  dbinds [id]        Show bind mounts for containers
  denv <id>          Show environment variables
  dfollow <id>       Follow logs with tail (default 100 lines)
  drmall             Remove all stopped containers

Stats & Cleanup:
  dstats, dstatsa, dtop
  dprune, dprunea, ddf, dvprune, diprune

Docker Compose:
  dc, dcup, dcdown, dclogs, dcps, dcex, dcsh

Management:
  dcbuild, dcbn, dcrestart, dcrecreate, dcpull, dcstop, dcstart
  dcstatus           Show service status & resource usage
  dcreload <srv>     Restart service and follow logs
  dcupdate <srv>     Pull, restart service, follow logs
  dcgrep <srv> <p>  Filter service logs
  dcconfig           Show resolved compose configuration
  dcvalidate         Validate compose file syntax

Examples:
  dsh mycontainer
  dcup
  dcupdate nginx
  dcgrep app "error"

HELPTEXT
            ;;
        git)
            cat << 'HELPTEXT'

═ GIT SHORTCUTS ═══

  gs                 git status
  ga                 git add
  gc                 git commit
  gp                 git push
  gl                 git log (graph view)
  gd                 git diff
  gb                 git branch
  gco                git checkout

Examples:
  gs                   # Check status
  ga .                 # Add all changes
  gc -m "Update docs"  # Commit with message
  gp                   # Push to remote

HELPTEXT
            ;;
        network)
            cat << 'HELPTEXT'

═ NETWORK COMMANDS ═══

  myip               Show external IP address
  localip            Show local IP address(es)
  ports              Show all listening ports
  listening          Show listening ports with process info
  ping               Ping with 5 packets (default)
  fastping           Fast ping (100 packets, 0.2s interval)
  netstat            Network connections (ss)

Examples:
  myip               # Get public IP
  localip            # Get local IPs
  ping google.com      # Ping with 5 packets
  ports              # Show all open ports

HELPTEXT
            ;;
        *)
            echo "Unknown category: $category"
            echo "Available categories: navigation, files, system, docker, git, network"
            echo "Use 'bashhelp' or 'bashhelp all' for complete reference"
            return 1
            ;;
    esac
}

# Preserve Bash's builtin `help` while integrating bashhelp
help() {
    case "${1:-}" in
        ""|all|navigation|files|system|docker|git|network)
            bashhelp "$@"
            ;;
        *)
            command help "$@" 2>/dev/null || builtin help "$@"
            ;;
    esac
}

# Shorter alias for bashhelp (not for help - that's a function now)
alias bh='bashhelp'

# Quick command list (compact)
alias commands='compgen -A function -A alias | grep -v "^_" | sort | column'

# --- Performance Note ---
# This configuration is optimized for performance using built-in bash operations
# and minimizing external command calls. If startup feels slow, check:
# - ~/.bash_aliases and ~/.bashrc.local for expensive operations
# - Consider moving rarely-used functions to separate files
# - Use 'time bash -i -c exit' to measure startup time