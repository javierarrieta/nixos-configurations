# Podman/Docker-provider compatibility gate for llm01-podman workspaces.
#
# Run from a Coder-like provisioner pod with the mTLS client bundle mounted at
# /run/secrets/coder-podman-client and the registry pull credential mounted at
# /run/secrets/coder-registry-pull (same mounts the template uses). After a
# successful run, the evidence document
# docs/superpowers/evidence/2026-08-08-coder-podman-compatibility.md must be
# filled in and committed before any later task.

terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.6"
    }
  }
}

variable "host" {
  description = "mTLS Podman Docker-compatible API endpoint"
  default     = "tcp://llm01:2376"
}

variable "cert_path" {
  description = "Directory containing ca.pem, cert.pem, and key.pem"
  default     = "/run/secrets/coder-podman-client"
}

variable "registry_auth_username" {
  default = trimspace(file("/run/secrets/coder-registry-pull/username"))
}

variable "registry_auth_password" {
  default = trimspace(file("/run/secrets/coder-registry-pull/password"))
}

provider "docker" {
  host      = var.host
  cert_path = var.cert_path

  registry_auth {
    address  = "registry.l.arrieta.eu"
    username = var.registry_auth_username
    password = var.registry_auth_password
  }
}

# 1. mTLS + private registry pull: pulls through the authenticated remote API.
resource "docker_image" "workspace" {
  name = "registry.l.arrieta.eu/coder-workspace:compat-gate"
}

# 2. Local bind volume: exercises docker_volume local driver bind options, the
#    exact mechanism the llm01-podman template uses for iSCSI-backed homes.
resource "docker_volume" "home" {
  name = "coder-compat-gate-home"

  driver = "local"
  driver_opts = {
    type   = "none"
    o      = "bind"
    device = "/srv/coder/workspaces/coder-compat-gate"
  }
}

# 3. Container with memory/cpus cgroup v2 limits; run as non-root uid 1000.
resource "docker_container" "workspace" {
  name  = "coder-compat-gate"
  image = docker_image.workspace.image_id

  memory = 4096
  cpus   = "4"

  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home.name
  }

  user = "1000:1000"

  env = [
    "COMPAT_GATE=1",
  ]

  command = ["sh", "-c", "id; mount | grep ' /home/coder '; sleep 300"]
}

# 4. Restart/destroy cycle is exercised by `terraform apply`/`terraform
#    destroy`. Device isolation (no host devices/GPU) is verified by inspecting
#    `docker inspect` output on the host and is recorded in the evidence doc.
output "workspace_id" {
  value = docker_container.workspace.id
}
