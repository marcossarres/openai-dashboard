#!/usr/bin/env bash
# Update the cost backend stack and frontend artifacts using the latest ECR image and
# freshly-built frontend bundle.
#
# This script performs the following steps:
#   1. Determines the most recently pushed ECR image (or uses IMAGE_URI if provided).
#   2. Runs a CloudFormation deploy to roll the ECS service to that image.
#   3. Rebuilds the frontend (npm install + npm run build) and syncs it to the S3 bucket.
#   4. Issues a CloudFront invalidation so the new assets are served immediately.
#
# Environment variables (override as needed):
#   AWS_PROFILE, AWS_REGION, STACK_NAME, TEMPLATE_FILE
#   ECR_REPOSITORY, ECR_REGISTRY_ID, IMAGE_URI, RELEASE_TAG
#   VPC_ID, PUBLIC_SUBNETS, SECURITY_GROUP_ID, ENVIRONMENT
#   TASK_CPU, TASK_MEMORY, DESIRED_COUNT, CONTAINER_PORT
#   FRONTEND_DIR, FRONTEND_DIST_DIR, FRONTEND_BUCKET_REGION
#
# Usage:
#   ./update-cost-projet.sh --domain moneyclip.com.br

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd -- "${BACKEND_DIR}/.." && pwd)"
WORKSPACE_ROOT="$(cd -- "${REPO_ROOT}/.." && pwd)"

AWS_PROFILE="${AWS_PROFILE:-aws-cloudy}"
AWS_REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-cost-update-formation}"
TEMPLATE_FILE="${TEMPLATE_FILE:-${WORKSPACE_ROOT}/infra/sarrescost-ecs.yaml}"

ECR_REPOSITORY="${ECR_REPOSITORY:-openai-dashboard-backend}"
ECR_REGISTRY_ID="${ECR_REGISTRY_ID:-}" # optional override
IMAGE_URI="${IMAGE_URI:-}"
RELEASE_TAG="${RELEASE_TAG:-REL-$(date +%Y%m%d-%H%M%S)}"

VPC_ID="${VPC_ID:-vpc-d9d98fbd}"
PUBLIC_SUBNETS="${PUBLIC_SUBNETS:-subnet-0c39827a,subnet-c0c31e98}"
SECURITY_GROUP_ID="${SECURITY_GROUP_ID:-sg-81a24df9}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
TASK_CPU="${TASK_CPU:-1024}"
TASK_MEMORY="${TASK_MEMORY:-4096}"
DESIRED_COUNT="${DESIRED_COUNT:-1}"
CONTAINER_PORT="${CONTAINER_PORT:-3001}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --domain <root-domain>

Required arguments:
  --domain, -d    Root domain (e.g., sarres.com.br). Frontend assets live at costly.<root-domain>.

Environment overrides:
  See the variables listed at the top of this script.
USAGE
}

DOMAIN="${DOMAIN:-}"

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain|-d)
        if [[ -z "${2:-}" ]]; then
          log "Missing value for $1."
          usage
          exit 1
        fi
        DOMAIN="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      *)
        log "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ $# -gt 0 ]]; then
    log "Unexpected arguments: $*"
    usage
    exit 1
  fi
}

log() { printf '[update] %s\n' "$*"; }

parse_args "$@"

if [[ -z "${DOMAIN}" ]]; then
  log "DOMAIN parameter is required."
  usage
  exit 1
fi

FRONTEND_ROOT_DOMAIN="${FRONTEND_ROOT_DOMAIN:-${DOMAIN}}"
FRONTEND_DOMAIN="${FRONTEND_DOMAIN:-costly.${DOMAIN}}"
FRONTEND_BUCKET="${FRONTEND_BUCKET:-costly.${DOMAIN}}"
FRONTEND_BUCKET_REGION="${FRONTEND_BUCKET_REGION:-${AWS_REGION}}"
FRONTEND_DIR="${FRONTEND_DIR:-${REPO_ROOT}/frontend}"
FRONTEND_DIST_DIR="${FRONTEND_DIST_DIR:-${FRONTEND_DIR}/dist}"

resolve_latest_image() {
  if [[ -n "${IMAGE_URI}" ]]; then
    log "Using IMAGE_URI=${IMAGE_URI} (provided via environment)."
    return 0
  fi

  local repo_uri
  if [[ -n "${ECR_REGISTRY_ID}" ]]; then
    repo_uri=$(aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" ecr describe-repositories \
      --registry-id "${ECR_REGISTRY_ID}" --repository-names "${ECR_REPOSITORY}" \
      --query 'repositories[0].repositoryUri' --output text 2>/dev/null || echo "")
  else
    repo_uri=$(aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" ecr describe-repositories \
      --repository-names "${ECR_REPOSITORY}" \
      --query 'repositories[0].repositoryUri' --output text 2>/dev/null || echo "")
  fi

  if [[ -z "${repo_uri}" || "${repo_uri}" == "None" ]]; then
    log "ECR repository ${ECR_REPOSITORY} not found."
    exit 1
  fi

  local digest
  if [[ -n "${ECR_REGISTRY_ID}" ]]; then
    digest=$(aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" ecr describe-images \
      --registry-id "${ECR_REGISTRY_ID}" --repository-name "${ECR_REPOSITORY}" \
      --query "sort_by(imageDetails,&imagePushedAt)[-1].imageDigest" --output text 2>/dev/null || echo "")
  else
    digest=$(aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" ecr describe-images \
      --repository-name "${ECR_REPOSITORY}" \
      --query "sort_by(imageDetails,&imagePushedAt)[-1].imageDigest" --output text 2>/dev/null || echo "")
  fi

  if [[ -z "${digest}" || "${digest}" == "None" ]]; then
    log "ECR repository ${ECR_REPOSITORY} has no images to deploy."
    exit 1
  fi

  IMAGE_URI="${repo_uri}@${digest}"
  log "Resolved latest ECR image: ${IMAGE_URI}"
}

update_backend_stack() {
  log "Updating CloudFormation stack ${STACK_NAME} with IMAGE_URI=${IMAGE_URI} (release ${RELEASE_TAG})..."
  aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" cloudformation deploy \
    --stack-name "${STACK_NAME}" \
    --template-file "${TEMPLATE_FILE}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset \
    --parameter-overrides \
      VpcId="${VPC_ID}" \
      PublicSubnets="${PUBLIC_SUBNETS}" \
      DefaultSecurityGroupId="${SECURITY_GROUP_ID}" \
      ImageUri="${IMAGE_URI}" \
      ContainerPort="${CONTAINER_PORT}" \
      DesiredCount="${DESIRED_COUNT}" \
      TaskCpu="${TASK_CPU}" \
      TaskMemory="${TASK_MEMORY}" \
      Environment="${ENVIRONMENT}" \
      ReleaseTag="${RELEASE_TAG}"
}

build_frontend_assets() {
  if [[ ! -d "${FRONTEND_DIR}" ]]; then
    log "Frontend directory ${FRONTEND_DIR} not found."
    exit 1
  fi
  log "Installing frontend dependencies..."
  npm --prefix "${FRONTEND_DIR}" install >/dev/null
  log "Building frontend assets..."
  npm --prefix "${FRONTEND_DIR}" run build >/dev/null
  if [[ ! -d "${FRONTEND_DIST_DIR}" ]]; then
    log "Frontend dist directory ${FRONTEND_DIST_DIR} missing after build."
    exit 1
  fi
}

sync_frontend_assets_to_s3() {
  log "Syncing ${FRONTEND_DIST_DIR}/ -> s3://${FRONTEND_BUCKET}/ ..."
  if ! aws --profile "${AWS_PROFILE}" --region "${FRONTEND_BUCKET_REGION}" s3api head-bucket --bucket "${FRONTEND_BUCKET}" >/dev/null 2>&1; then
    log "S3 bucket s3://${FRONTEND_BUCKET} not found. Run the initial deploy first."
    exit 1
  fi
  aws --profile "${AWS_PROFILE}" --region "${FRONTEND_BUCKET_REGION}" s3 sync "${FRONTEND_DIST_DIR}/" "s3://${FRONTEND_BUCKET}/" --delete >/dev/null
}

find_frontend_distribution() {
  aws --profile "${AWS_PROFILE}" cloudfront list-distributions \
    --query "DistributionList.Items[?Aliases.Items && contains(Aliases.Items, '${FRONTEND_DOMAIN}')].[Id,DomainName]" \
    --output text 2>/dev/null || echo ""
}

invalidate_cloudfront() {
  local info
  info=$(find_frontend_distribution)
  if [[ -z "${info}" || "${info}" == "None" ]]; then
    log "CloudFront distribution for ${FRONTEND_DOMAIN} not found; skipping invalidation."
    return 0
  fi
  read -r dist_id dist_domain <<<"${info}"
  log "Issuing CloudFront invalidation for distribution ${dist_id} (${dist_domain})..."
  aws --profile "${AWS_PROFILE}" cloudfront create-invalidation \
    --distribution-id "${dist_id}" \
    --paths "/*" >/dev/null
  log "CloudFront invalidation submitted for ${dist_id}."
}

log "Starting cost project update for ${FRONTEND_DOMAIN} (${STACK_NAME})..."
resolve_latest_image
update_backend_stack
build_frontend_assets
sync_frontend_assets_to_s3
invalidate_cloudfront
log "Update completed successfully."
