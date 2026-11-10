# A minimal project stack for the reusable workflows' own tests
# (.github/workflows/building-blocks.yml). No provider credentials, local state
# on the runner: a plan and an apply touch nothing outside the job.

terraform {
  required_version = ">= 1.10.0"
}

variable "greeting" {
  type    = string
  default = "hello from the example consumer"
}

resource "terraform_data" "example" {
  input = var.greeting
}

output "greeting" {
  value = terraform_data.example.output
}
