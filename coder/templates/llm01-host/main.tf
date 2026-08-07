terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 0.17"
    }
  }
}

provider "coder" {}

data "coder_workspace" "me" {}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
  dir  = "/home/coder"

  env = {
    GIT_AUTHOR_NAME     = data.coder_workspace.me.owner_name
    GIT_AUTHOR_EMAIL    = "${data.coder_workspace.me.owner_email}"
    GIT_COMMITTER_NAME  = data.coder_workspace.me.owner_name
    GIT_COMMITTER_EMAIL = "${data.coder_workspace.me.owner_email}"
  }
}

resource "terraform_data" "install_agent" {
  depends_on = [coder_agent.main]

  connection {
    type        = "ssh"
    host        = var.host
    user        = "coder"
    private_key = var.ssh_private_key
  }

  # init_script installs the agent binary (if missing) and starts it;
  # background it because it blocks while the agent runs.
  provisioner "remote-exec" {
    inline = [
      "nohup bash -c '${coder_agent.main.init_script}' > /home/coder/.cache/coder/agent.log 2>&1 &",
    ]
  }

  # Tear down the agent when the workspace is stopped/deleted.
  provisioner "remote-exec" {
    when   = destroy
    inline = [
      "pkill -f 'coder agent' || true",
    ]
  }
}

resource "coder_metadata" "llm01_info" {
  count       = data.coder_workspace.me.start_count
  resource_id = coder_agent.main.id

  item {
    key   = "host"
    value = var.host
  }
}
