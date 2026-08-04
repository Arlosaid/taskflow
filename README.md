# Taskflow Project

Taskflow is a work-in-progress project for practicing the development and
deployment of a modern application with background processes and cloud
infrastructure.

It currently includes Terraform infrastructure for managing remote state in AWS.
The application, workers, and Kubernetes deployment will be added as the project
evolves.

## Structure

- `app/`: main application.
- `worker/`: asynchronous processes and background tasks.
- `infra/`: infrastructure as code with Terraform.
- `k8s/`: Kubernetes deployment configurations.
- `docs/`: documentation and study topics guide.

## Current technologies

- Python 3.12
- Terraform y AWS S3
- Ruff, pre-commit, TFLint, Checkov y Gitleaks
