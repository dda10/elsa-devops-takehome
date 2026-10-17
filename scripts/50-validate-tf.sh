#!/bin/sh
# 50 — Part 5b: format check, offline init and validate of the Cloudflare Terraform.
# No state, no backend, no credentials needed.
set -eu

cd /workspace/terraform/cloudflare
terraform fmt -check -recursive -diff
echo "terraform init (first run downloads the 43 MB Cloudflare provider; cached in the tfcache volume afterwards)"
terraform init -backend=false -input=false
terraform validate
echo "PASS: terraform fmt/init/validate"
