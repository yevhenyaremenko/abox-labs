variable "cluster_name" {
  description = "Cluster Name"
  type        = string
  default     = "abox"
}

variable "oci_registry" {
  description = "OCI registry base URL"
  type        = string
  default     = "oci://ghcr.io/yevhenyaremenko/abox-labs"
}

variable "releases_version" {
  description = "Default tag for releases OCI artifact bootstrap"
  type        = string
  default     = "0.1.0"
}

variable "enable_lab3_resources" {
  description = "Deploy Lab 3 resources: elicitation-mcp-server (custom Python MCP server with Elicitation support for ambiguous K8s queries) and lab3-agent. Disabled by default."
  type        = bool
  default     = false
}
