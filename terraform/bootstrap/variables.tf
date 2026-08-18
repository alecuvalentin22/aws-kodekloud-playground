variable "region" {
  description = "KodeKloud playground is pinned to us-east-1 / us-east-2 / us-west-2."
  type        = string
  default     = "us-east-1"
}

variable "prefix" {
  type    = string
  default = "andrei-lab"
}

variable "force_destroy" {
  description = <<-EOT
    true  -> `terraform destroy` deletes the bucket even with state objects in it.
             Correct for a throwaway playground.
    false -> destroy fails while state exists. Correct for a real account, where
             you would also add `lifecycle { prevent_destroy = true }`.
  EOT
  type        = bool
  default     = true
}
