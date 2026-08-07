variable "host" {
  description = "SSH host of llm01 (IP or resolvable hostname)"
  type        = string
}

variable "ssh_private_key" {
  description = "SSH private key for the coder user on llm01"
  type        = string
  sensitive   = true
}
