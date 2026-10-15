variable "region" {
  type    = string
  default = "us-east-1"
}

variable "prefix" {
  type    = string
  default = "platform-lab"
}

variable "artifactory_version" {
  description = "releases-docker.jfrog.io/jfrog/artifactory-oss tag. Pinned; see versions.env."
  type        = string
  default     = "7.161.26"
}

variable "ui_cidrs" {
  description = "Who may reach the Artifactory UI. Lab default is open; the admin password is changed on first login."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
