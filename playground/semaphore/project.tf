# The playground's "game console": one Semaphore project on the instance that
# gcp-setup already runs. Each template is a button for a `play` command; the
# task history is the candidate's scoreboard (red = not fixed yet, green = solved).

resource "semaphoreui_project" "playground" {
  name               = "playground"
  alert              = false
  max_parallel_tasks = 1 # one incident at a time, like `play` itself
}

resource "semaphoreui_project_key" "none" {
  project_id = semaphoreui_project.playground.id
  name       = "No credentials"
  none       = {}
}

# A plain path is Semaphore's local repository mode, and it runs IN PLACE
# (db/Repository.go GetFullPath): no clone, no push needed.
resource "semaphoreui_project_repository" "lab" {
  project_id = semaphoreui_project.playground.id
  name       = "platform-lab (mounted read-only)"
  url        = var.lab_path_in_container
  branch     = "main"
  ssh_key_id = semaphoreui_project_key.none.id
}

resource "semaphoreui_project_inventory" "local" {
  project_id = semaphoreui_project.playground.id
  name       = "Local only"
  ssh_key_id = semaphoreui_project_key.none.id
  static = {
    inventory = "localhost ansible_connection=local"
  }
}

# Env vars reach a bash task from HERE, not from compose: Semaphore forwards
# only PATH from its own process (db_lib/LocalApp.go getEnvironmentVars).
# `variables` stays empty -- extra vars are appended to the command line.
resource "semaphoreui_project_environment" "playground" {
  project_id = semaphoreui_project.playground.id
  name       = "Playground (kind network)"
  environment = {
    PLAYGROUND_STATE        = "/state"
    PLAYGROUND_WORK         = "/work"
    PLAYGROUND_JENKINS_URL  = "http://playground-control-plane:30094"
    PLAYGROUND_GITEA_URL    = "http://playground-control-plane:30300"
    PLAYGROUND_REGISTRY_URL = "http://kind-registry:5000"
    KUBECONFIG              = "/state/kubeconfig-internal"
  }
  variables = {}
}

resource "semaphoreui_project_template" "start" {
  project_id     = semaphoreui_project.playground.id
  environment_id = semaphoreui_project_environment.playground.id
  inventory_id   = semaphoreui_project_inventory.local.id
  repository_id  = semaphoreui_project_repository.lab.id
  name           = "1. Start drill"
  app            = "bash"
  playbook       = "playground/semaphore/tasks/start.sh"
  description    = "Breaks something and prints the developer's ticket. Random keeps the drill's name hidden."

  survey_vars = [
    {
      name        = "drill"
      title       = "Drill"
      description = "Random = a drill you have not solved yet, name hidden."
      type        = "enum"
      required    = true
      enum_values = {
        "random (blind)"                              = "random"
        "01 Copied the Jenkinsfile from the wiki"     = "01"
        "02 Build says rolled back, feature not live" = "02"
        "03 No pods, no errors, nothing deployed"     = "03"
        "04 Just approve my script, please"           = "04"
        "05 Every build stuck waiting"                = "05"
        "06 Can our pipeline deploy to staging?"      = "06"
        "07 Every team red at 9:05"                   = "07"
        "08 Remove one bucket, not three"             = "08"
        "11 (aws) 401 from ECR, and IAM is fine"      = "11"
        "12 (aws) Security found a token in a log"    = "12"
        "13 (aws) denied: not authorized to perform"  = "13"
        "14 (aws) Pentest: any pod can push to ECR"   = "14"
      }
    },
    {
      name        = "track"
      title       = "Track (random only)"
      type        = "enum"
      required    = false
      enum_values = { any = "any", jenkins = "jenkins", kubernetes = "kubernetes", terraform = "terraform", aws = "aws" }
    },
    {
      name        = "tier"
      title       = "Tier (random only)"
      description = "aws needs the EKS lab running and its credentials mounted."
      type        = "enum"
      required    = false
      enum_values = { local = "local", aws = "aws" }
    },
  ]
}

locals {
  # Template name => play command. Fixed here; never user input.
  commands = {
    "2. Status"            = "status"
    "3. Hint (-15)"        = "hint"
    "4. Check my fix"      = "check"
    "5. Close the ticket"  = "close"
    "6. Reveal (give up)"  = "reveal"
    "7. Reset to baseline" = "reset"
    "8. Scoreboard"        = "score"
    "9. Doctor"            = "doctor"
    "10. List drills"      = "list"
  }
}

resource "semaphoreui_project_template" "command" {
  for_each       = local.commands
  project_id     = semaphoreui_project.playground.id
  environment_id = semaphoreui_project_environment.playground.id
  inventory_id   = semaphoreui_project_inventory.local.id
  repository_id  = semaphoreui_project_repository.lab.id
  name           = each.key
  app            = "bash"
  playbook       = "playground/semaphore/tasks/play.sh"
  arguments      = [each.value]
  description    = "playground/play ${each.value}"
}

output "project_id" { value = semaphoreui_project.playground.id }
output "template_ids" {
  value = merge(
    { (semaphoreui_project_template.start.name) = semaphoreui_project_template.start.id },
    { for name, t in semaphoreui_project_template.command : name => t.id },
  )
}
