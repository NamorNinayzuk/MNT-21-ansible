#!/usr/bin/env bash
export TF_VAR_YC_CLOUD_ID=$(yc config get cloud-id)
export TF_VAR_YC_FOLDER_ID=$(yc config get folder-id)
export TF_VAR_YC_ZONE=$(yc config get compute-default-zone)

init() {
    terraform init
}

apply() {
    terraform apply --auto-approve
}

destroy() {
    terraform destroy --auto-approve
}

clear() {
    terraform destroy --auto-approve
    rm -rf .terraform*
    rm terraform.tfstate*
}

req() {
    ansible-galaxy install -r requirements.yml --force
}

run() {
    ansible-playbook -i inventory/prod.yml site.yml
}

rund() {
    ansible-playbook -i inventory/prod.yml --diff site.yml
}

lint() {
    ansible-lint
}

if [ $1 ]; then
    $1
else
    echo "Possible commands:"
    echo "  init - Terraform init"
    echo "  apply - Terraform apply"
    echo "  destroy - Terraform destroy"
    echo "  clear - Clear files from Terraform"
    echo "  req - Install requirements for Ansible"
    echo "  run - Run Ansible playbook"
    echo "  rund - Run Ansible playbook with diff"
    echo "  lint - Run Ansible-Lint"
fi
