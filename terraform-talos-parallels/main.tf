locals {
  controlplane_ips = [
    for node_name in sort(keys(var.controlplane_nodes)) : var.controlplane_nodes[node_name].ip
  ]
  worker_ips = [
    for node_name in sort(keys(var.worker_nodes)) : var.worker_nodes[node_name].ip
  ]
  all_nodes = merge(
    {
      for node_name, node in var.controlplane_nodes : node_name => merge(node, {
        role = "controlplane"
      })
    },
    {
      for node_name, node in var.worker_nodes : node_name => merge(node, {
        role = "worker"
      })
    }
  )
  cluster_endpoint  = "https://${var.controlplane_vip}:6443"
  iso_download_path = "${path.module}/generated/talos-${var.talos_architecture}.iso"
  installer_image   = "factory.talos.dev/installer/${talos_image_factory_schematic.this.id}:${var.talos_version}"
  iso_filename      = "metal-${var.talos_architecture}.iso"
}

# ---------------------------------------------------------------------------
# Image Factory – custom Talos image with extensions
# ---------------------------------------------------------------------------

data "talos_image_factory_extensions_versions" "this" {
  count         = length(var.talos_extensions) > 0 ? 1 : 0
  talos_version = var.talos_version
  filters = {
    names = var.talos_extensions
  }
}

# This schematic is what makes the downloaded ISO a properly customized
# first-boot image rather than the generic upstream Talos ISO: it bakes in
# the system extensions workloads deployed later in this config depend on
# (see var.talos_extensions, e.g. Longhorn's iscsi-tools/util-linux-tools).
# Extensions can only be added at install/upgrade time via a schematic like
# this one, so anything required on first boot must be declared here -
# adding it after nodes are already provisioned requires a full reinstall
# or a talosctl upgrade to a new schematic ID.
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      extraKernelArgs = ["random.trust_cpu=on", "random.trust_bootloader=on"]
      systemExtensions = {
        officialExtensions = length(var.talos_extensions) > 0 ? data.talos_image_factory_extensions_versions.this[0].extensions_info[*].name : []
      }
    }
  })
}

# Download the factory-built ISO (includes baked-in extensions)
resource "null_resource" "download_iso" {
  triggers = {
    schematic_id  = talos_image_factory_schematic.this.id
    talos_version = var.talos_version
    architecture  = var.talos_architecture
    iso_path      = local.iso_download_path
  }

  provisioner "local-exec" {
    command = <<-EOT
      mkdir -p "$(dirname "${local.iso_download_path}")"
      curl -fSL -o "${local.iso_download_path}" \
        "https://factory.talos.dev/image/${talos_image_factory_schematic.this.id}/${var.talos_version}/${local.iso_filename}"
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm -f \"${self.triggers.iso_path}\""
  }
}

# ---------------------------------------------------------------------------
# Parallels VMs
# ---------------------------------------------------------------------------

resource "null_resource" "create_vms" {
  for_each = local.all_nodes

  depends_on = [null_resource.download_iso]

  triggers = {
    vm_name                        = each.key
    cpu                            = tostring(each.value.cpu)
    memory_mb                      = tostring(each.value.memory_mb)
    iso_path                       = local.iso_download_path
    schematic_id                   = talos_image_factory_schematic.this.id
    parallels_vm_path              = var.parallels_vm_path
    parallels_network_type         = var.parallels_network_type
    parallels_host_interface       = var.parallels_host_interface
    parallels_network_adapter_type = var.parallels_network_adapter_type
    vm_bios_type                   = var.vm_bios_type
    vm_disk_size_mb                = tostring(var.vm_disk_size_mb)
    start_vms                      = tostring(var.start_vms)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/zsh", "-c"]
    command     = <<-EOT
      set -euo pipefail

      VM_NAME="${each.key}"
      ISO_FILE="${local.iso_download_path}"

      if [ ! -f "$ISO_FILE" ]; then
        echo "ISO not found at $ISO_FILE"
        exit 1
      fi

      if ! prlctl list -a --no-header -o name | grep -Fxq "$VM_NAME"; then
        if [ -n "${var.parallels_vm_path}" ]; then
          prlctl create "$VM_NAME" --distribution linux --dst "${var.parallels_vm_path}"
        else
          prlctl create "$VM_NAME" --distribution linux
        fi
      else
        # Stop existing VM before reconfiguring
        prlctl stop "$VM_NAME" --kill 2>/dev/null || true
        sleep 2
      fi

      prlctl set "$VM_NAME" --cpus ${each.value.cpu}
      prlctl set "$VM_NAME" --memsize ${each.value.memory_mb}
      prlctl set "$VM_NAME" --bios-type ${var.vm_bios_type}
      prlctl set "$VM_NAME" --device-set hdd0 --size ${var.vm_disk_size_mb} --iface sata

      if [ "${var.parallels_network_type}" = "bridged" ] && [ -n "${var.parallels_host_interface}" ]; then
        prlctl set "$VM_NAME" --device-set net0 --type "${var.parallels_network_type}" --iface "${var.parallels_host_interface}" --adapter-type "${var.parallels_network_adapter_type}"
      else
        prlctl set "$VM_NAME" --device-set net0 --type "${var.parallels_network_type}" --adapter-type "${var.parallels_network_adapter_type}"
      fi

      prlctl set "$VM_NAME" --device-set cdrom0 --image "$ISO_FILE" --connect
      prlctl set "$VM_NAME" --device-bootorder "hdd0 cdrom0"
      if [ "${var.start_vms}" = "true" ]; then
        VM_STATUS="$(prlctl list "$VM_NAME" --no-header -o status || true)"
        if [ "$VM_STATUS" != "running" ]; then
          prlctl start "$VM_NAME"

          # Parallels' arm64 UEFI firmware does not implement EFI_RNG_PROTOCOL, so
          # Talos can stall at boot waiting for entropy (kernel random.trust_cpu /
          # random.trust_bootloader are no-ops here since there is no CPU RNG
          # instruction or firmware-supplied seed to trust). This is a known
          # limitation of Apple-silicon-hosted, non-QEMU hypervisors
          # (siderolabs/talos#11865). The documented manual workaround is pressing
          # random keys to generate interrupt-timing entropy; automate that here by
          # firing 100 harmless Left Shift key events spread over 5s to the console.
          ( for _ in $(seq 1 100); do
              prlctl send-key-event "$VM_NAME" -s 42 -d 1 >/dev/null 2>&1 || true
              sleep 0.05
            done ) &!

          # Actively poll for readiness instead of sleeping a fixed duration: wait
          # for a DHCP IP, then for the Talos maintenance API (apid, port 50000) to
          # actually accept connections. This runs in parallel with the keypress
          # loop above and returns as soon as the node is really ready, rather than
          # guessing how long boot + entropy unblocking will take.
          echo "Waiting for $VM_NAME to become network/API-ready..."
          READY=""
          for i in $(seq 1 60); do
            IP=$(prlctl list "$VM_NAME" -o ip --no-header 2>/dev/null \
                 | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || true)
            if [ -n "$IP" ] && nc -z -w 2 "$IP" 50000 2>/dev/null; then
              echo "$VM_NAME is up at $IP (Talos API reachable)"
              READY=1
              break
            fi
            sleep 2
          done
          if [ -z "$READY" ]; then
            echo "WARNING: $VM_NAME did not become network/API-ready within timeout, continuing anyway"
          fi
        fi
      fi
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/zsh", "-c"]
    command     = <<-EOT
      VM_NAME="${self.triggers.vm_name}"
      if prlctl list -a --no-header -o name | grep -Fxq "$VM_NAME"; then
        prlctl stop "$VM_NAME" --kill 2>/dev/null || true
        sleep 2
        prlctl delete "$VM_NAME" 2>/dev/null || true
      fi
    EOT
  }
}

# ---------------------------------------------------------------------------
# Talos configuration
# ---------------------------------------------------------------------------

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "controlplane" {
  for_each = var.controlplane_nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = [
    yamlencode({
      machine = {
        install = {
          disk              = var.install_disk
          image             = local.installer_image
          extraKernelArgs   = ["noxsave", "random.trust_cpu=on", "random.trust_bootloader=on"]
          grubUseUKICmdline = false
        }
        time = {
          disabled = false
          servers  = var.ntp_servers
        }
        network = {
          nameservers = var.dns_servers
          interfaces = [
            {
              deviceSelector = {
                driver = var.node_network_driver
              }
              addresses = ["${each.value.ip}/${var.node_prefix_length}"]
              routes = [
                {
                  network = "0.0.0.0/0"
                  gateway = var.gateway
                }
              ]
              vip = {
                ip = var.controlplane_vip
              }
            }
          ]
        }
        sysctls = {
          "net.ipv4.conf.all.arp_notify" = "1"
        }
      }
      cluster = {
        allowSchedulingOnControlPlanes = true
        apiServer = {
          certSANs = [
            var.controlplane_vip,
          ]
          extraArgs = {
            "bind-address" = "0.0.0.0"
          }
        }
      }
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      auto       = "off"
      hostname   = each.key
    })
  ]
}

data "talos_machine_configuration" "worker" {
  for_each = var.worker_nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = [
    yamlencode({
      machine = {
        install = {
          disk              = var.install_disk
          image             = local.installer_image
          extraKernelArgs   = ["noxsave", "random.trust_cpu=on", "random.trust_bootloader=on"]
          grubUseUKICmdline = false
        }
        time = {
          disabled = false
          servers  = var.ntp_servers
        }
        network = {
          nameservers = var.dns_servers
          interfaces = [
            {
              deviceSelector = {
                driver = var.node_network_driver
              }
              addresses = ["${each.value.ip}/${var.node_prefix_length}"]
              routes = [
                {
                  network = "0.0.0.0/0"
                  gateway = var.gateway
                }
              ]
            }
          ]
        }
        sysctls = {
          "net.ipv4.conf.all.arp_notify" = "1"
        }
        kernel = {
          modules = [
            { name = "nbd" },
            { name = "iscsi_tcp" },
          ]
        }
      }
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      auto       = "off"
      hostname   = each.key
    })
  ]
}

# ---------------------------------------------------------------------------
# Generated config files
# ---------------------------------------------------------------------------

resource "local_sensitive_file" "controlplane_machineconfig" {
  for_each = data.talos_machine_configuration.controlplane

  filename        = "${path.module}/generated/controlplane-${each.key}.yaml"
  content         = each.value.machine_configuration
  file_permission = "0600"

  depends_on = [null_resource.download_iso]
}

resource "local_sensitive_file" "worker_machineconfig" {
  for_each = data.talos_machine_configuration.worker

  filename        = "${path.module}/generated/worker-${each.key}.yaml"
  content         = each.value.machine_configuration
  file_permission = "0600"

  depends_on = [null_resource.download_iso]
}

# ---------------------------------------------------------------------------
# Discover VM IPs – tries Parallels DHCP first, falls back to static IP
# (after Talos installs, VMs switch to static IPs that Parallels may not see)
# ---------------------------------------------------------------------------

data "external" "vm_dhcp_ip" {
  for_each   = local.all_nodes
  depends_on = [null_resource.create_vms]

  program = ["/bin/zsh", "-c", <<-EOT
    STATIC_IP="${each.value.ip}"
    VM_NAME="${each.key}"

    # If the VM no longer exists (e.g. during destroy), return the static IP
    if ! prlctl list -a --no-header -o name | grep -Fxq "$VM_NAME"; then
      printf '{"ip":"%s"}' "$STATIC_IP"
      exit 0
    fi

    # Try to get the IP Parallels can see (works for DHCP before install)
    for i in $(seq 1 30); do
      IP=$(prlctl list "$VM_NAME" -o ip --no-header 2>/dev/null \
           | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
      if [ -n "$IP" ]; then
        printf '{"ip":"%s"}' "$IP"
        exit 0
      fi
      sleep 3
    done

    # Fall back to the configured static IP
    printf '{"ip":"%s"}' "$STATIC_IP"
  EOT
  ]
}

# ---------------------------------------------------------------------------
# Apply configs to DHCP IPs, bootstrap, and retrieve kubeconfig
# ---------------------------------------------------------------------------

resource "talos_machine_configuration_apply" "controlplane" {
  for_each = var.controlplane_nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane[each.key].machine_configuration
  node                        = data.external.vm_dhcp_ip[each.key].result.ip
  endpoint                    = data.external.vm_dhcp_ip[each.key].result.ip
  apply_mode                  = "auto"
}

resource "talos_machine_configuration_apply" "worker" {
  for_each = var.worker_nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker[each.key].machine_configuration
  node                        = data.external.vm_dhcp_ip[each.key].result.ip
  endpoint                    = data.external.vm_dhcp_ip[each.key].result.ip
  apply_mode                  = "auto"
}

# Disconnect the boot ISO once config has been applied and Talos has started
# installing to disk. The installer image comes from the network (Image
# Factory), not the local ISO, so the ISO is only needed for the very first
# maintenance-mode boot. Leaving it connected makes Parallels' arm64 EFI
# firmware boot-device selection non-deterministic across reboots: on some
# restarts it re-enters the stateless Talos ISO (maintenance mode) instead of
# the installed disk, which shows up as "no IP" / DNS and NTP
# (time.cloudflare.com) failures that never resolve.
resource "null_resource" "eject_iso" {
  for_each = local.all_nodes

  depends_on = [
    talos_machine_configuration_apply.controlplane,
    talos_machine_configuration_apply.worker,
  ]

  triggers = {
    vm_name = each.key
  }

  provisioner "local-exec" {
    interpreter = ["/bin/zsh", "-c"]
    command     = <<-EOT
      set -euo pipefail
      VM_NAME="${each.key}"
      if prlctl list -a --no-header -o name | grep -Fxq "$VM_NAME"; then
        prlctl set "$VM_NAME" --device-set cdrom0 --disconnect 2>/dev/null || true
      fi
    EOT
  }
}

# Wait for nodes to install to disk and reboot with static IPs. Rather than
# sleeping a fixed duration, actively poll each node's static IP for the
# Talos maintenance/apid API (port 50000) to accept connections, returning as
# soon as every node is actually back up instead of guessing how long the
# install + reboot will take.
resource "null_resource" "wait_for_reboot" {
  depends_on = [
    talos_machine_configuration_apply.controlplane,
    talos_machine_configuration_apply.worker,
    null_resource.eject_iso,
  ]

  triggers = {
    cp_ips = join(",", local.controlplane_ips)
    wk_ips = join(",", local.worker_ips)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/zsh", "-c"]
    command     = <<-EOT
      set -euo pipefail
      ALL_IPS="${join(" ", concat(local.controlplane_ips, local.worker_ips))}"

      echo "=== Waiting for nodes to finish installing to disk and reboot on static IPs ==="
      for ip in $ALL_IPS; do
        echo -n "  $ip: "
        READY=""
        for i in $(seq 1 60); do
          if nc -z -w 2 "$ip" 50000 2>/dev/null; then
            echo "Talos API ready"
            READY=1
            break
          fi
          sleep 3
        done
        if [ -z "$READY" ]; then
          echo "WARNING: Talos API on $ip not ready after timeout, continuing anyway"
        fi
      done
    EOT
  }
}

resource "talos_machine_bootstrap" "this" {
  depends_on = [null_resource.wait_for_reboot]

  node                 = local.controlplane_ips[0]
  endpoint             = local.controlplane_ips[0]
  client_configuration = talos_machine_secrets.this.client_configuration
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on = [talos_machine_bootstrap.this]

  node                 = local.controlplane_ips[0]
  endpoint             = local.controlplane_ips[0]
  client_configuration = talos_machine_secrets.this.client_configuration
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [var.controlplane_vip]
  nodes                = concat(local.controlplane_ips, local.worker_ips)
}

resource "local_sensitive_file" "talosconfig" {
  filename        = "${path.module}/generated/talosconfig"
  content         = data.talos_client_configuration.this.talos_config
  file_permission = "0600"

  depends_on = [null_resource.download_iso]
}

resource "local_sensitive_file" "kubeconfig" {
  depends_on = [talos_cluster_kubeconfig.this]

  filename        = "${path.module}/generated/kubeconfig"
  content         = talos_cluster_kubeconfig.this.kubeconfig_raw
  file_permission = "0600"
}

# ---------------------------------------------------------------------------
# Cluster health check – verify all nodes are up on static IPs and K8s API
# is responding before installing add-ons
# ---------------------------------------------------------------------------

resource "null_resource" "cluster_health_check" {
  depends_on = [local_sensitive_file.kubeconfig, talos_machine_bootstrap.this]

  triggers = {
    cp_ips = join(",", local.controlplane_ips)
    wk_ips = join(",", local.worker_ips)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/zsh", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${local_sensitive_file.kubeconfig.filename}"
      VIP="https://${var.controlplane_vip}:6443"
      CP1="https://${local.controlplane_ips[0]}:6443"
      ALL_IPS="${join(" ", concat(local.controlplane_ips, local.worker_ips))}"

      echo "=== Waiting for all static IPs to be reachable ==="
      for ip in $ALL_IPS; do
        echo -n "  $ip: "
        for i in $(seq 1 60); do
          if ping -c1 -W2 "$ip" >/dev/null 2>&1; then
            echo "UP"
            break
          fi
          if [ "$i" -eq 60 ]; then
            echo "TIMEOUT (continuing anyway)"
          fi
          sleep 3
        done
      done

      echo ""
      echo "=== Waiting for Kubernetes API on $CP1 ==="
      for i in $(seq 1 60); do
        if kubectl --server="$CP1" get nodes >/dev/null 2>&1; then
          echo "Kubernetes API is ready"
          break
        fi
        if [ "$i" -eq 60 ]; then
          echo "ERROR: Kubernetes API not ready after 5 minutes"
          exit 1
        fi
        sleep 5
      done

      # Determine API server: prefer VIP, fall back to CP1
      KUBE_API="$CP1"
      echo ""
      echo "=== Checking VIP (${var.controlplane_vip}) health ==="
      VIP_OK=false
      for i in $(seq 1 60); do
        HTTP=$(curl -sk -o /dev/null -w "%%{http_code}" "$VIP/healthz" 2>/dev/null || echo "000")
        if [ "$HTTP" = "401" ] || [ "$HTTP" = "200" ]; then
          echo "VIP $VIP is healthy (HTTP $HTTP)"
          VIP_OK=true
          KUBE_API="$VIP"
          break
        fi
        echo "  attempt $i/60 – VIP returned HTTP $HTTP, retrying in 5s..."
        sleep 5
      done

      if [ "$VIP_OK" = "false" ]; then
        echo "WARNING: VIP not reachable from host (Parallels bridged MAC issue)"
        echo "  kubectl/helm commands will use CP1 directly"
      fi

      echo ""
      echo "=== Waiting for all nodes to be Ready (via $KUBE_API) ==="
      EXPECTED=${length(keys(merge(var.controlplane_nodes, var.worker_nodes)))}
      for i in $(seq 1 60); do
        READY=$(kubectl --server="$KUBE_API" get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true)
        if [ "$READY" -ge "$EXPECTED" ]; then
          echo "All $READY/$EXPECTED nodes Ready"
          break
        fi
        echo "  $READY/$EXPECTED nodes Ready, waiting..."
        if [ "$i" -eq 60 ]; then
          echo "WARNING: only $READY/$EXPECTED nodes Ready after timeout"
        fi
        sleep 5
      done

      echo ""
      echo "=== Cluster health summary ==="
      kubectl --server="$KUBE_API" get nodes -o wide 2>&1 || true
    EOT
  }
}

# ---------------------------------------------------------------------------
# Copy kubeconfig to default location (~/.kube/config)
# ---------------------------------------------------------------------------

resource "null_resource" "copy_kubeconfig" {
  depends_on = [null_resource.cluster_health_check]

  triggers = {
    kubeconfig = local_sensitive_file.kubeconfig.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/zsh", "-c"]
    command     = <<-EOT
      set -euo pipefail
      mkdir -p "$HOME/.kube"
      cp "${local_sensitive_file.kubeconfig.filename}" "$HOME/.kube/config"
      chmod 600 "$HOME/.kube/config"
      echo "Kubeconfig copied to $HOME/.kube/config"
    EOT
  }
}

# ---------------------------------------------------------------------------
# MetalLB – L2 load balancer for bare-metal / Parallels
# ---------------------------------------------------------------------------

resource "null_resource" "metallb_install" {
  depends_on = [null_resource.cluster_health_check]

  triggers = {
    metallb_version = var.metallb_version
    kubeconfig      = local_sensitive_file.kubeconfig.filename
  }

  provisioner "local-exec" {
    interpreter = ["/bin/zsh", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${local_sensitive_file.kubeconfig.filename}"
      VIP="https://${var.controlplane_vip}:6443"
      CP1="https://${local.controlplane_ips[0]}:6443"

      # Prefer VIP, fall back to CP1
      if curl -sk -o /dev/null -w "%%{http_code}" "$VIP/healthz" 2>/dev/null | grep -qE '^(200|401)$'; then
        KUBE_API="$VIP"
      else
        KUBE_API="$CP1"
      fi
      echo "Using API server: $KUBE_API"

      # Create namespace and label it as privileged before installing
      kubectl --server="$KUBE_API" create namespace metallb-system 2>/dev/null || true
      kubectl --server="$KUBE_API" label --overwrite ns metallb-system \
        pod-security.kubernetes.io/enforce=privileged \
        pod-security.kubernetes.io/audit=privileged \
        pod-security.kubernetes.io/warn=privileged

      helm repo add metallb https://metallb.github.io/metallb 2>/dev/null || true
      helm repo update metallb

      helm upgrade --install metallb metallb/metallb \
        --namespace metallb-system \
        --version "${var.metallb_version}" \
        --kube-apiserver "$KUBE_API" \
        --wait --timeout 5m
    EOT
  }
}

resource "null_resource" "metallb_config" {
  depends_on = [null_resource.metallb_install]

  triggers = {
    ip_range   = var.metallb_ip_range
    kubeconfig = local_sensitive_file.kubeconfig.filename
  }

  provisioner "local-exec" {
    interpreter = ["/bin/zsh", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${local_sensitive_file.kubeconfig.filename}"
      VIP="https://${var.controlplane_vip}:6443"
      CP1="https://${local.controlplane_ips[0]}:6443"

      # Prefer VIP, fall back to CP1
      if curl -sk -o /dev/null -w "%%{http_code}" "$VIP/healthz" 2>/dev/null | grep -qE '^(200|401)$'; then
        KUBE_API="$VIP"
      else
        KUBE_API="$CP1"
      fi
      echo "Using API server: $KUBE_API"

      # Wait for MetalLB CRDs to be available
      for i in $(seq 1 30); do
        if kubectl --server="$KUBE_API" get crd ipaddresspools.metallb.io >/dev/null 2>&1; then
          break
        fi
        sleep 3
      done

      kubectl --server="$KUBE_API" apply -f - <<EOF
      apiVersion: metallb.io/v1beta1
      kind: IPAddressPool
      metadata:
        name: default-pool
        namespace: metallb-system
      spec:
        addresses:
          - ${var.metallb_ip_range}
      ---
      apiVersion: metallb.io/v1beta1
      kind: L2Advertisement
      metadata:
        name: default-l2
        namespace: metallb-system
      spec:
        ipAddressPools:
          - default-pool
      EOF
    EOT
  }
}

# ---------------------------------------------------------------------------
# Traefik – ingress controller with LoadBalancer service
# ---------------------------------------------------------------------------

resource "null_resource" "traefik_install" {
  depends_on = [null_resource.metallb_config]

  triggers = {
    traefik_version  = var.traefik_version
    traefik_replicas = tostring(var.traefik_replicas)
    kubeconfig       = local_sensitive_file.kubeconfig.filename
  }

  provisioner "local-exec" {
    interpreter = ["/bin/zsh", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${local_sensitive_file.kubeconfig.filename}"
      VIP="https://${var.controlplane_vip}:6443"
      CP1="https://${local.controlplane_ips[0]}:6443"

      # Prefer VIP, fall back to CP1
      if curl -sk -o /dev/null -w "%%{http_code}" "$VIP/healthz" 2>/dev/null | grep -qE '^(200|401)$'; then
        KUBE_API="$VIP"
      else
        KUBE_API="$CP1"
      fi
      echo "Using API server: $KUBE_API"

      # Create namespace and label it as privileged
      kubectl --server="$KUBE_API" create namespace traefik 2>/dev/null || true
      kubectl --server="$KUBE_API" label --overwrite ns traefik \
        pod-security.kubernetes.io/enforce=privileged \
        pod-security.kubernetes.io/audit=privileged \
        pod-security.kubernetes.io/warn=privileged

      helm repo add traefik https://traefik.github.io/charts 2>/dev/null || true
      helm repo update traefik

      helm upgrade --install traefik traefik/traefik \
        --namespace traefik \
        --version "${var.traefik_version}" \
        --set deployment.replicas=${var.traefik_replicas} \
        --set service.type=LoadBalancer \
        --kube-apiserver "$KUBE_API" \
        --wait --timeout 5m
    EOT
  }
}

# ---------------------------------------------------------------------------
# Cloudflared – Cloudflare Tunnel (remotely managed)
# ---------------------------------------------------------------------------

resource "null_resource" "cloudflared_install" {
  depends_on = [null_resource.traefik_install]

  triggers = {
    tunnel_token = var.cloudflared_tunnel_token
    kubeconfig   = local_sensitive_file.kubeconfig.filename
  }

  provisioner "local-exec" {
    interpreter = ["/bin/zsh", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${local_sensitive_file.kubeconfig.filename}"
      VIP="https://${var.controlplane_vip}:6443"
      CP1="https://${local.controlplane_ips[0]}:6443"

      # Prefer VIP, fall back to CP1
      if curl -sk -o /dev/null -w "%%{http_code}" "$VIP/healthz" 2>/dev/null | grep -qE '^(200|401)$'; then
        KUBE_API="$VIP"
      else
        KUBE_API="$CP1"
      fi
      echo "Using API server: $KUBE_API"

      # Create namespace and label it as privileged
      kubectl --server="$KUBE_API" create namespace cloudflared 2>/dev/null || true
      kubectl --server="$KUBE_API" label --overwrite ns cloudflared \
        pod-security.kubernetes.io/enforce=privileged \
        pod-security.kubernetes.io/audit=privileged \
        pod-security.kubernetes.io/warn=privileged

      # Create/update the tunnel token secret
      kubectl --server="$KUBE_API" -n cloudflared create secret generic tunnel-token \
        --from-literal=token="${var.cloudflared_tunnel_token}" \
        --dry-run=client -o yaml | kubectl --server="$KUBE_API" apply -f -

      # Deploy cloudflared
      kubectl --server="$KUBE_API" apply -f - <<EOF
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: cloudflared
        namespace: cloudflared
      spec:
        replicas: 2
        selector:
          matchLabels:
            app: cloudflared
        template:
          metadata:
            labels:
              app: cloudflared
          spec:
            securityContext:
              runAsNonRoot: true
              runAsUser: 65532
              seccompProfile:
                type: RuntimeDefault
            containers:
              - name: cloudflared
                image: cloudflare/cloudflared:latest
                env:
                  - name: TUNNEL_TOKEN
                    valueFrom:
                      secretKeyRef:
                        name: tunnel-token
                        key: token
                command:
                  - cloudflared
                  - tunnel
                  - --no-autoupdate
                  - --metrics
                  - 0.0.0.0:2000
                  - run
                securityContext:
                  allowPrivilegeEscalation: false
                  capabilities:
                    drop:
                      - ALL
                  readOnlyRootFilesystem: true
                livenessProbe:
                  httpGet:
                    path: /ready
                    port: 2000
                  initialDelaySeconds: 10
                  periodSeconds: 10
                  failureThreshold: 3
                resources:
                  requests:
                    cpu: 100m
                    memory: 128Mi
                  limits:
                    cpu: 500m
                    memory: 256Mi
      EOF

      # Wait for rollout
      kubectl --server="$KUBE_API" -n cloudflared rollout status deployment/cloudflared --timeout=5m
    EOT
  }
}

# ---------------------------------------------------------------------------
# Longhorn – distributed block storage. Installed before Metrics Server
# since it needs the "longhorn" storage class to be available.
# ---------------------------------------------------------------------------

resource "null_resource" "longhorn_install" {
  depends_on = [null_resource.cloudflared_install]

  triggers = {
    longhorn_version = var.longhorn_version
    kubeconfig       = local_sensitive_file.kubeconfig.filename
  }

  provisioner "local-exec" {
    interpreter = ["/bin/zsh", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${local_sensitive_file.kubeconfig.filename}"
      VIP="https://${var.controlplane_vip}:6443"
      CP1="https://${local.controlplane_ips[0]}:6443"

      # Prefer VIP, fall back to CP1
      if curl -sk -o /dev/null -w "%%{http_code}" "$VIP/healthz" 2>/dev/null | grep -qE '^(200|401)$'; then
        KUBE_API="$VIP"
      else
        KUBE_API="$CP1"
      fi
      echo "Using API server: $KUBE_API"

      # Create namespace and label it as privileged for pod security admission
      kubectl --server="$KUBE_API" create namespace longhorn-system 2>/dev/null || true
      kubectl --server="$KUBE_API" label --overwrite ns longhorn-system \
        pod-security.kubernetes.io/enforce=privileged \
        pod-security.kubernetes.io/audit=privileged \
        pod-security.kubernetes.io/warn=privileged

      helm repo add longhorn https://charts.longhorn.io 2>/dev/null || true
      helm repo update longhorn

      helm upgrade --install longhorn longhorn/longhorn \
        --namespace longhorn-system \
        --version "${var.longhorn_version}" \
        --set defaultSettings.defaultDataPath="/var/lib/longhorn" \
        --set ingress.enabled=true \
        --set ingress.ingressClassName=traefik \
        --set ingress.host=longhorn.cluster.local \
        --kube-apiserver "$KUBE_API" \
        --wait --timeout 5m
    EOT
  }
}

# ---------------------------------------------------------------------------
# Metrics Server – with kubelet-insecure-tls for Talos (no IP SANs in certs)
# ---------------------------------------------------------------------------

resource "null_resource" "metrics_server_install" {
  depends_on = [null_resource.longhorn_install]

  triggers = {
    metrics_server_version = var.metrics_server_version
    kubeconfig             = local_sensitive_file.kubeconfig.filename
  }

  provisioner "local-exec" {
    interpreter = ["/bin/zsh", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${local_sensitive_file.kubeconfig.filename}"
      VIP="https://${var.controlplane_vip}:6443"
      CP1="https://${local.controlplane_ips[0]}:6443"

      # Prefer VIP, fall back to CP1
      if curl -sk -o /dev/null -w "%%{http_code}" "$VIP/healthz" 2>/dev/null | grep -qE '^(200|401)$'; then
        KUBE_API="$VIP"
      else
        KUBE_API="$CP1"
      fi
      echo "Using API server: $KUBE_API"

      helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
      helm repo update metrics-server

      helm upgrade --install metrics-server metrics-server/metrics-server \
        --namespace kube-system \
        --version "${var.metrics_server_version}" \
        --set 'args={--kubelet-insecure-tls}' \
        --kube-apiserver "$KUBE_API" \
        --wait --timeout 5m
    EOT
  }
}

# ---------------------------------------------------------------------------
# Longhorn external IngressRoute – Cloudflare tunnel traffic
# ---------------------------------------------------------------------------

resource "null_resource" "longhorn_ingressroute" {
  depends_on = [null_resource.longhorn_install]

  triggers = {
    hostname    = var.longhorn_external_hostname
    kubeconfig  = local_sensitive_file.kubeconfig.filename
    annotations = "v2-homepage-discovery"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/zsh", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${local_sensitive_file.kubeconfig.filename}"
      VIP="https://${var.controlplane_vip}:6443"
      CP1="https://${local.controlplane_ips[0]}:6443"

      # Prefer VIP, fall back to CP1
      if curl -sk -o /dev/null -w "%%{http_code}" "$VIP/healthz" 2>/dev/null | grep -qE '^(200|401)$'; then
        KUBE_API="$VIP"
      else
        KUBE_API="$CP1"
      fi
      echo "Using API server: $KUBE_API"

      kubectl --server="$KUBE_API" apply -f - <<EOF
      apiVersion: traefik.io/v1alpha1
      kind: IngressRoute
      metadata:
        name: longhorn-external
        namespace: longhorn-system
        annotations:
          gethomepage.dev/enabled: "true"
          gethomepage.dev/name: "Longhorn"
          gethomepage.dev/description: "Distributed block storage"
          gethomepage.dev/group: "Cluster Management"
          gethomepage.dev/icon: "longhorn"
          gethomepage.dev/href: "http://longhorn.cluster.local"
          gethomepage.dev/pod-selector: ""
      spec:
        entryPoints:
          - web
        routes:
          - match: Host(\`${var.longhorn_external_hostname}\`)
            kind: Rule
            services:
              - name: longhorn-frontend
                port: 80
      EOF
    EOT
  }
}

# ---------------------------------------------------------------------------
# Prometheus / Grafana – monitoring stack
# ---------------------------------------------------------------------------

resource "null_resource" "prometheus_install" {
  depends_on = [null_resource.longhorn_ingressroute]

  triggers = {
    script_hash = filemd5("${path.module}/monitoring/deploy-prometheus.sh")
    values_hash = filemd5("${path.module}/monitoring/prometheus-values.yaml")
    kubeconfig  = local_sensitive_file.kubeconfig.filename
  }

  provisioner "local-exec" {
    interpreter = ["/bin/zsh", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${local_sensitive_file.kubeconfig.filename}"
      VIP="https://${var.controlplane_vip}:6443"
      CP1="https://${local.controlplane_ips[0]}:6443"

      # Prefer VIP, fall back to CP1
      if curl -sk -o /dev/null -w "%%{http_code}" "$VIP/healthz" 2>/dev/null | grep -qE '^(200|401)$'; then
        KUBE_API="$VIP"
      else
        KUBE_API="$CP1"
      fi
      echo "Using API server: $KUBE_API"
      export KUBE_API

      helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
      helm repo update prometheus-community

      bash "${path.module}/monitoring/deploy-prometheus.sh"
    EOT
  }
}

# ---------------------------------------------------------------------------
# Homepage – dashboard deployed last so it can discover all services
# ---------------------------------------------------------------------------

resource "null_resource" "homepage_install" {
  depends_on = [null_resource.prometheus_install]

  triggers = {
    script_hash = filemd5("${path.module}/homepage/homepage.sh")
    kubeconfig  = local_sensitive_file.kubeconfig.filename
  }

  provisioner "local-exec" {
    interpreter = ["/bin/zsh", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${local_sensitive_file.kubeconfig.filename}"
      bash "${path.module}/homepage/homepage.sh" install
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/zsh", "-c"]
    command     = <<-EOT
      export KUBECONFIG="${path.module}/generated/kubeconfig"
      bash "${path.module}/homepage/homepage.sh" remove 2>/dev/null || true
    EOT
  }
}

