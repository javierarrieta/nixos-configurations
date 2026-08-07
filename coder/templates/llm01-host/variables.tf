data "coder_parameter" "host" {
  name         = "host"
  display_name = "Host"
  description  = "SSH host of llm01 (IP or resolvable hostname)"
  type         = "string"
}

data "coder_parameter" "ssh_private_key" {
  name         = "ssh_private_key"
  display_name = "SSH private key"
  description  = "SSH private key for the coder user on llm01"
  type         = "string"
}
