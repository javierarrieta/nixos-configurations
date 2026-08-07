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

  # Each workspace runs its own agent in its own session/process group, so
  # tearing down one workspace kills only its own agent on the shared host.
  # setsid makes the agent a new session leader; the backgrounded PID is the
  # process-group id, so `kill -- -PID` targets just that workspace's agent.
  provisioner "remote-exec" {
    inline = [
      "mkdir -p /home/coder/.cache/coder",
      "setsid sh -c '${coder_agent.main.init_script}' > /home/coder/.cache/coder/agent-${data.coder_workspace.me.name}.log 2>&1 & echo $! > /home/coder/.cache/coder/agent-${data.coder_workspace.me.name}.pid",
    ]
  }

  # Tear down only this workspace's agent (shared host; other workspaces'
  # agents must keep running).
  provisioner "remote-exec" {
    when   = destroy
    inline = [
      "PID=/home/coder/.cache/coder/agent-${data.coder_workspace.me.name}.pid",
      "if [ -f $PID ]; then kill -TERM -- -$(cat $PID) 2>/dev/null || true; rm -f $PID; fi",
      "true",
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
