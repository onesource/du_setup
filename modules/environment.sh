#!/bin/bash

# ============================================================================
# du_setup_modular.sh - Environment Detection Module
# Detects whether running in cloud VPS, bare metal, or container
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

# --- Environment Detection Function ---
detect_environment() {
    local VIRT_TYPE=""
    local MANUFACTURER=""
    local PRODUCT=""
    local IS_CLOUD_VPS=false

    # systemd-detect-virt
    if command -v systemd-detect-virt &>/dev/null; then
        VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "none")
    fi

    # dmidecode for hardware info
    if command -v dmidecode &>/dev/null && [[ $(id -u) -eq 0 ]]; then
        MANUFACTURER=$(dmidecode -s system-manufacturer 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "unknown")
        PRODUCT=$(dmidecode -s system-product-name 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "unknown")
    fi

    # Check /sys/class/dmi/id/ (fallback, doesn't require dmidecode)
    if [[ -z "$MANUFACTURER" || "$MANUFACTURER" == "unknown" ]]; then
        if [[ -r /sys/class/dmi/id/sys_vendor ]]; then
            MANUFACTURER=$(tr '[:upper:]' '[:lower:]' < /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "unknown")
        fi
    fi

    if [[ -z "$PRODUCT" || "$PRODUCT" == "unknown" ]]; then
        if [[ -r /sys/class/dmi/id/product_name ]]; then
            PRODUCT=$(tr '[:upper:]' '[:lower:]' < /sys/class/dmi/id/product_name 2>/dev/null || echo "unknown")
        fi
    fi

    if command -v dmidecode &>/dev/null && [[ $(id -u) -eq 0 ]]; then
        DETECTED_BIOS_VENDOR=$(dmidecode -s bios-vendor 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "unknown")
    elif [[ -r /sys/class/dmi/id/bios_vendor ]]; then
        DETECTED_BIOS_VENDOR=$(tr '[:upper:]' '[:lower:]' < /sys/class/dmi/id/bios_vendor 2>/dev/null || echo "unknown")
    fi

    # Cloud provider detection patterns
    local CLOUD_PATTERNS=(
        # VPS/Cloud Providers
        "digitalocean"
        "linode"
        "vultr"
        "hetzner"
        "ovh"
        "scaleway"
        "contabo"
        "netcup"
        "ionos"
        "hostinger"
        "racknerd"
        "upcloud"
        "dreamhost"
        "kimsufi"
        "online.net"
        "equinix metal"
        "lightsail"
        "scaleway"
        # Major Cloud Platforms
        "amazon"
        "amazon ec2"
        "aws"
        "google"
        "gce"
        "google compute engine"
        "microsoft"
        "azure"
        "oracle cloud"
        "alibaba"
        "tencent"
        "rackspace"
        # Virtualization indicating cloud VPS
        "droplet"
        "linodekvm"
        "kvm"
        "openstack"
    )

    # Check if manufacturer or product matches cloud patterns
    for pattern in "${CLOUD_PATTERNS[@]}"; do
        if [[ "$MANUFACTURER" == *"$pattern"* ]] || [[ "$PRODUCT" == *"$pattern"* ]]; then
            IS_CLOUD_VPS=true
            break
        fi
    done

    # Additional checks based on virtualization type
    case "$VIRT_TYPE" in
        kvm|qemu)
            if [[ -z "$IS_CLOUD_VPS" ]] || [[ "$IS_CLOUD_VPS" == "false" ]]; then
                if [[ -d /etc/cloud/cloud.cfg.d ]] && grep -qE "(Hetzner|DigitalOcean|Vultr|OVH)" /etc/cloud/cloud.cfg.d/* 2>/dev/null; then
                    IS_CLOUD_VPS=true
                fi
            fi
            ;;
        vmware)
            IS_CLOUD_VPS=false
            ;;
        oracle|virtualbox)
            IS_CLOUD_VPS=false
            ;;
        xen)
            IS_CLOUD_VPS=true
            ;;
        hyperv|microsoft)
            if [[ "$MANUFACTURER" == *"microsoft"* ]] && [[ "$PRODUCT" == *"virtual machine"* ]]; then
                IS_CLOUD_VPS=false
            fi
            ;;
        none)
            IS_CLOUD_VPS=false
            ;;
    esac

    # Determine environment type based on detection
    if [[ "$VIRT_TYPE" == "none" ]]; then
        ENVIRONMENT_TYPE="bare-metal"
    elif [[ "$IS_CLOUD_VPS" == "true" ]]; then
        ENVIRONMENT_TYPE="commercial-cloud"
    elif [[ "$VIRT_TYPE" =~ ^(kvm|qemu)$ ]]; then
        if [[ "$MANUFACTURER" == "qemu" && "$PRODUCT" =~ ^(standard pc|pc-|pc ) ]]; then
            ENVIRONMENT_TYPE="uncertain-kvm"
        else
            ENVIRONMENT_TYPE="commercial-cloud"
        fi
    elif [[ "$VIRT_TYPE" =~ ^(vmware|virtualbox|oracle)$ ]]; then
        ENVIRONMENT_TYPE="personal-vm"
    elif [[ "$VIRT_TYPE" == "xen" ]]; then
        ENVIRONMENT_TYPE="uncertain-xen"
    else
        ENVIRONMENT_TYPE="unknown"
    fi

    DETECTED_PROVIDER_NAME=""
    case "$ENVIRONMENT_TYPE" in
        commercial-cloud)
            if [[ "$MANUFACTURER" =~ digitalocean ]]; then
                DETECTED_PROVIDER_NAME="DigitalOcean"
            elif [[ "$MANUFACTURER" =~ hetzner ]]; then
                DETECTED_PROVIDER_NAME="Hetzner Cloud"
            elif [[ "$MANUFACTURER" =~ vultr ]]; then
                DETECTED_PROVIDER_NAME="Vultr"
            elif [[ "$MANUFACTURER" =~ linode || "$PRODUCT" =~ akamai ]]; then
                DETECTED_PROVIDER_NAME="Linode/Akamai"
            elif [[ "$MANUFACTURER" =~ ovh ]]; then
                DETECTED_PROVIDER_NAME="OVH"
            elif [[ "$MANUFACTURER" =~ amazon || "$PRODUCT" =~ "ec2" ]]; then
                DETECTED_PROVIDER_NAME="Amazon Web Services (AWS)"
            elif [[ "$MANUFACTURER" =~ google ]]; then
                DETECTED_PROVIDER_NAME="Google Cloud Platform"
            elif [[ "$MANUFACTURER" =~ microsoft ]]; then
                DETECTED_PROVIDER_NAME="Microsoft Azure"
            else
                DETECTED_PROVIDER_NAME="Cloud VPS Provider"
            fi
            ;;
        personal-vm)
            if [[ "$VIRT_TYPE" == "virtualbox" || "$MANUFACTURER" =~ innotek ]]; then
                DETECTED_PROVIDER_NAME="VirtualBox"
            elif [[ "$VIRT_TYPE" == "vmware" ]]; then
                DETECTED_PROVIDER_NAME="VMware"
            else
                DETECTED_PROVIDER_NAME="Personal VM"
            fi
            ;;
        uncertain-kvm)
            DETECTED_PROVIDER_NAME="KVM/QEMU Hypervisor"
            ;;
    esac

    # Export results as global variables
    export ENVIRONMENT_TYPE
    DETECTED_VIRT_TYPE="$VIRT_TYPE"
    DETECTED_MANUFACTURER="$MANUFACTURER"
    DETECTED_PRODUCT="$PRODUCT"
    DETECTED_BIOS_VENDOR="${DETECTED_BIOS_VENDOR:-unknown}"
    IS_CLOUD_PROVIDER="$IS_CLOUD_VPS"

    log "Environment detection: VIRT=$VIRT_TYPE, MANUFACTURER=$MANUFACTURER, PRODUCT=$PRODUCT, IS_CLOUD=$IS_CLOUD_VPS, TYPE=$ENVIRONMENT_TYPE"
}