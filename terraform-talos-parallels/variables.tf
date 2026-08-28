variable "cluster_name" {
  description = "Talos cluster name."
  type        = string
  default     = "talos-parallels"
}

variable "talos_version" {
  description = "Talos version for machine configs, secrets, and Image Factory."
  type        = string
  default     = "v1.8.4"
}

variable "kubernetes_version" {
  description = "Kubernetes version to render into Talos machine configs."
  type        = string
  default     = "v1.31.4"
}

variable "talos_architecture" {
  description = "CPU architecture for the Talos image (amd64 or arm64)."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["amd64", "arm64"], var.talos_architecture)
    error_message = "talos_architecture must be one of: amd64, arm64."
  }
}

variable "talos_extensions" {
  description = "Official Talos extensions to include via Image Factory."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Parallels
# ---------------------------------------------------------------------------

variable "parallels_vm_path" {
  description = "Optional destination directory for created VMs. Leave empty for Parallels defaults."
  type        = string
  default     = ""
}

variable "parallels_network_type" {
  description = "Parallels network mode for VM net0."
  type        = string
  default     = "bridged"

  validation {
    condition     = contains(["shared", "bridged", "host-only"], var.parallels_network_type)
    error_message = "parallels_network_type must be one of: shared, bridged, host-only."
  }
}

variable "parallels_host_interface" {
  description = "Host interface name for bridged mode (e.g. en0)."
  type        = string
  default     = "en0"
}

variable "parallels_network_adapter_type" {
  description = "Virtual NIC model for net0."
  type        = string
  default     = "virtio"

  validation {
    condition     = contains(["virtio", "e1000", "rtl"], var.parallels_network_adapter_type)
    error_message = "parallels_network_adapter_type must be one of: virtio, e1000, rtl."
  }
}

variable "vm_bios_type" {
  description = "VM firmware type."
  type        = string
  default     = "efi-arm64"

  validation {
    condition     = contains(["legacy", "efi32", "efi64", "efi-arm64"], var.vm_bios_type)
    error_message = "vm_bios_type must be one of: legacy, efi32, efi64, efi-arm64."
  }
}

variable "vm_disk_size_mb" {
  description = "Primary VM disk size for hdd0, in MB."
  type        = number
  default     = 102400
}

variable "start_vms" {
  description = "Start VMs after creation/update."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Networking (192.168.60.0/24)
# ---------------------------------------------------------------------------

variable "controlplane_vip" {
  description = "Shared VIP used as the Kubernetes control-plane endpoint."
  type        = string
  default     = "192.168.60.210"
}

variable "node_network_driver" {
  description = "Kernel driver used to match the guest NIC via deviceSelector."
  type        = string
  default     = "virtio_net"
}

variable "node_prefix_length" {
  description = "CIDR prefix length for static node IP addresses."
  type        = number
  default     = 24
}

variable "gateway" {
  description = "Default gateway for node routes."
  type        = string
  default     = "192.168.60.1"
}

variable "dns_servers" {
  description = "DNS resolver IP addresses configured on each node together with its static network settings."
  type        = list(string)
  default     = ["192.168.60.1"]

  validation {
    condition = (
      length(var.dns_servers) > 0 &&
      alltrue([
        for server in var.dns_servers : can(cidrhost("${server}/32", 0))
      ])
    )
    error_message = "dns_servers must contain at least one valid IPv4 resolver address."
  }
}

variable "install_disk" {
  description = "Target disk Talos installs to."
  type        = string
  default     = "/dev/sda"
}

variable "talos_api_wait_duration" {
  description = "How long Terraform waits after VM start before applying Talos configs."
  type        = string
  default     = "30s"
}

# ---------------------------------------------------------------------------
# MetalLB
# ---------------------------------------------------------------------------

variable "metallb_version" {
  description = "MetalLB Helm chart version."
  type        = string
  default     = "0.14.9"
}

variable "metallb_ip_range" {
  description = "IP range for MetalLB L2 address pool."
  type        = string
  default     = "192.168.60.230-192.168.60.250"
}

# ---------------------------------------------------------------------------
# Traefik
# ---------------------------------------------------------------------------

variable "traefik_version" {
  description = "Traefik Helm chart version."
  type        = string
  default     = "34.3.0"
}

variable "traefik_replicas" {
  description = "Number of Traefik deployment replicas."
  type        = number
  default     = 3
}

# ---------------------------------------------------------------------------
# Cloudflared Tunnel
# ---------------------------------------------------------------------------

variable "cloudflared_tunnel_token" {
  description = "Cloudflare Tunnel token for the remotely-managed tunnel."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Metrics Server
# ---------------------------------------------------------------------------

variable "metrics_server_version" {
  description = "Metrics Server Helm chart version."
  type        = string
  default     = "3.13.0"
}

# ---------------------------------------------------------------------------
# Longhorn
# ---------------------------------------------------------------------------

variable "longhorn_version" {
  description = "Longhorn Helm chart version."
  type        = string
  default     = "1.7.3"
}

variable "longhorn_external_hostname" {
  description = "External hostname for Longhorn UI via Cloudflare tunnel."
  type        = string
  default     = "longhorn.wickedgoodwifi.com"
}

# ---------------------------------------------------------------------------
# Node definitions
# ---------------------------------------------------------------------------

variable "controlplane_nodes" {
  description = "Control-plane node definitions."
  type = map(object({
    ip        = string
    cpu       = number
    memory_mb = number
  }))
  default = {
    "talos-cp-1" = {
      ip        = "192.168.60.211"
      cpu       = 4
      memory_mb = 8192
    }
    "talos-cp-2" = {
      ip        = "192.168.60.212"
      cpu       = 4
      memory_mb = 8192
    }
    "talos-cp-3" = {
      ip        = "192.168.60.213"
      cpu       = 4
      memory_mb = 8192
    }
  }
}

variable "worker_nodes" {
  description = "Worker node definitions."
  type = map(object({
    ip        = string
    cpu       = number
    memory_mb = number
  }))
  default = {
    "talos-wk-1" = {
      ip        = "192.168.60.221"
      cpu       = 4
      memory_mb = 8192
    }
    "talos-wk-2" = {
      ip        = "192.168.60.222"
      cpu       = 4
      memory_mb = 8192
    }
    "talos-wk-3" = {
      ip        = "192.168.60.223"
      cpu       = 4
      memory_mb = 8192
    }
  }
}
