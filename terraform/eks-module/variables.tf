variable "region" { default = "us-east-1" }
variable "prefix" { default = "andrei-lab" }

variable "kubernetes_version" {
  description = "1.33 minimum -- Flux v2.9's documented floor."
  type        = string
  default     = "1.33"
}

variable "public_access_cidrs" {
  description = "Who may reach the Kubernetes API. Your /32."
  type        = list(string)

  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "Refusing to expose the Kubernetes API to the whole internet."
  }
}

variable "node_instance_type" { default = "t3.medium" }
variable "node_desired_size" { default = 2 }
variable "node_min_size" { default = 1 }
variable "node_max_size" { default = 3 }
