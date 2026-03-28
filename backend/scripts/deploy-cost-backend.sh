#!/usr/bin/env bash
# Deploy the cost-backend CloudFormation stack used for the ECS-based backend service.
#
# Environment variables (override as needed):
#   AWS_PROFILE        AWS CLI profile to use (default: aws-cloudy)
#   AWS_REGION         Deployment region (default: us-east-1)
#   STACK_NAME         CloudFormation stack name (default: cost-backend-formation)
#   TEMPLATE_FILE      Path to the sarrescost ECS template
#   IMAGE_URI          Full ECR image URI (with digest) to deploy
#   RELEASE_TAG        Release tag used for stack metadata
#   TASK_CPU           CPU units for the task definition (default: 1024)
#   TASK_MEMORY        Memory (MiB) for the task definition (default: 4096)
#   DESIRED_COUNT      ECS service desired count (default: 1)
#   CONTAINER_PORT     Container/host port exposed through the ALB (default: 3001)
#   POLL_INTERVAL_SECONDS  Seconds between CloudFormation event polls (default: 10)
#
# Example:
#   STACK_NAME=cost-backend-formation \
#   IMAGE_URI=915759771410.dkr.ecr.us-east-1.amazonaws.com/openai-dashboard-backend@sha256:... \
#   ./scripts/deploy-cost-backend.sh

set -euo pipefail

log() { printf '[deploy-stack] %s\n' "$*"; }
log_progress() { printf '[progress] %-45s -> %s (%s)\n' "$1" "$2" "$3"; }

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd -- "${BACKEND_DIR}/.." && pwd)"
WORKSPACE_ROOT="$(cd -- "${REPO_ROOT}/.." && pwd)"

AWS_PROFILE="${AWS_PROFILE:-aws-cloudy}"
AWS_REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-cost-backend-formation}"
TEMPLATE_FILE="${TEMPLATE_FILE:-${WORKSPACE_ROOT}/infra/sarrescost-ecs.yaml}"
DEFAULT_ECR_REGISTRY="915759771410.dkr.ecr.us-east-1.amazonaws.com"
DEFAULT_ECR_REPOSITORY="openai-dashboard-backend"
DEFAULT_ECR_IMAGE_TAG="latest"
DEFAULT_IMAGE_URI_PLACEHOLDER="__AUTO_ECR_LATEST__"
IMAGE_URI="${IMAGE_URI:-${DEFAULT_IMAGE_URI_PLACEHOLDER}}"
RELEASE_TAG="${RELEASE_TAG:-REL-2026.03.25-ODBE-8020759}"
TASK_CPU="${TASK_CPU:-1024}"
TASK_MEMORY="${TASK_MEMORY:-4096}"
DESIRED_COUNT="${DESIRED_COUNT:-1}"
CONTAINER_PORT="${CONTAINER_PORT:-3001}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}"

VPC_ID="${VPC_ID:-vpc-d9d98fbd}"
PUBLIC_SUBNETS="${PUBLIC_SUBNETS:-subnet-0c39827a,subnet-c0c31e98}"
SECURITY_GROUP_ID="${SECURITY_GROUP_ID:-sg-81a24df9}"
ENVIRONMENT="${ENVIRONMENT:-prod}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --domain <root-domain>

Required arguments:
  --domain, -d    Root domain (e.g., sarres.com.br). Frontend assets will be
                  deployed to costly.<root-domain>.

Environment overrides:
  Set the variables documented at the top of this script (AWS_PROFILE, STACK_NAME,
  IMAGE_URI, etc.) as needed.
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

parse_args "$@"

if [[ -z "${DOMAIN}" ]]; then
  log "DOMAIN parameter is required."
  usage
  exit 1
fi

FRONTEND_ENABLED="${FRONTEND_ENABLED:-true}"
FRONTEND_ROOT_DOMAIN="${FRONTEND_ROOT_DOMAIN:-${DOMAIN}}"
FRONTEND_DOMAIN="${FRONTEND_DOMAIN:-costly.${DOMAIN}}"
FRONTEND_BUCKET="${FRONTEND_BUCKET:-costly.${DOMAIN}}"
FRONTEND_BUCKET_REGION="${FRONTEND_BUCKET_REGION:-${AWS_REGION}}"
FRONTEND_DIR="${FRONTEND_DIR:-${REPO_ROOT}/frontend}"
FRONTEND_DIST_DIR="${FRONTEND_DIST_DIR:-${FRONTEND_DIR}/dist}"
FRONTEND_CERT_REGION="${FRONTEND_CERT_REGION:-us-east-1}"
FRONTEND_HOSTED_ZONE_ID="${FRONTEND_HOSTED_ZONE_ID:-}"
FRONTEND_CERT_ARN="${FRONTEND_CERT_ARN:-}"
FRONTEND_DISTRIBUTION_ID="${FRONTEND_DISTRIBUTION_ID:-}"
FRONTEND_DISTRIBUTION_DOMAIN="${FRONTEND_DISTRIBUTION_DOMAIN:-}"
FRONTEND_DISTRIBUTION_CREATED="false"
FRONTEND_FORCE_REDEPLOY="${FRONTEND_FORCE_REDEPLOY:-false}"
CLOUDFRONT_HOSTED_ZONE_ID="Z2FDTNDATAQYW2"
ALLOW_ACM_REISSUE="${ALLOW_ACM_REISSUE:-false}"
BACKEND_DOMAIN="${BACKEND_DOMAIN:-api.${DOMAIN}}"
BACKEND_CERT_REGION="${BACKEND_CERT_REGION:-${AWS_REGION}}"
BACKEND_CERT_ARN="${BACKEND_CERT_ARN:-}"
BACKEND_HOSTED_ZONE_ID="${BACKEND_HOSTED_ZONE_ID:-}"
ALB_CANONICAL_ZONE_ID="${ALB_CANONICAL_ZONE_ID:-}"

LAST_EVENT_ID=""

dns_failure_guidance() {
  log "DNS troubleshooting options:"
  log "  1) Create or import a public Route 53 hosted zone for ${FRONTEND_ROOT_DOMAIN} (or set FRONTEND_HOSTED_ZONE_ID to an existing one that matches)."
  log "  2) Delegate ${FRONTEND_ROOT_DOMAIN} at your registrar to the Route 53 name servers shown in the hosted zone once it exists."
  log "  3) If you intentionally need only the backend right now, re-run with FRONTEND_ENABLED=false to bypass DNS/frontend tasks."
  log "  4) To target a different root domain, rerun the script with --domain <root-domain>."
}

resolve_latest_image_uri() {
  local repository="${DEFAULT_ECR_REPOSITORY}"
  local registry="${DEFAULT_ECR_REGISTRY}"
  local tag="${DEFAULT_ECR_IMAGE_TAG}"
  local digest
  digest=$(aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" ecr describe-images \
    --repository-name "${repository}" \
    --image-ids imageTag="${tag}" \
    --query 'imageDetails[0].imageDigest' --output text 2>/dev/null || echo "")

  if [[ -z "${digest}" || "${digest}" == "None" ]]; then
    log "Unable to resolve the '${tag}' image in ${registry}/${repository}."
    return 1
  fi

  printf '%s/%s@%s\n' "${registry}" "${repository}" "${digest}"
  return 0
}

normalize_ns_entries() {
  local entry
  tr -s '[:space:]' '\n' | while IFS= read -r entry; do
    [[ -z "${entry}" || "${entry}" == "None" ]] && continue
    entry="$(printf '%s' "${entry}" | tr '[:upper:]' '[:lower:]')"
    entry="${entry%.}."
    printf '%s\n' "${entry}"
  done | sort -u
}

collect_public_ns_records() {
  local domain="$1"
  local output=""
  if command -v dig >/dev/null 2>&1; then
    output=$(dig +short NS "${domain}" 2>/dev/null || true)
  elif command -v nslookup >/dev/null 2>&1; then
    output=$(nslookup -type=NS "${domain}" 2>/dev/null | awk -F'=' '/nameserver =/ {gsub(/^[ \t]+/, "", $2); print $2}' || true)
  else
    return 1
  fi
  if [[ -z "${output}" ]]; then
    return 1
  fi
  printf '%s\n' "${output}"
  return 0
}

ensure_public_ns_matches_route53() {
  local zone_id="$1"
  local route53_ns
  route53_ns=$(aws --profile "${AWS_PROFILE}" route53 get-hosted-zone \
    --id "/hostedzone/${zone_id}" \
    --query 'DelegationSet.NameServers' --output text 2>/dev/null || true)
  if [[ -z "${route53_ns}" || "${route53_ns}" == "None" ]]; then
    log "Could not retrieve Route 53 name servers for hosted zone ${zone_id}."
    return 1
  fi

  local public_ns
  if ! public_ns=$(collect_public_ns_records "${FRONTEND_ROOT_DOMAIN}"); then
    log "Unable to query public NS records for ${FRONTEND_ROOT_DOMAIN} (dig/nslookup missing or domain not delegated)."
    return 1
  fi

  local normalized_route53 normalized_public
  normalized_route53=$(printf '%s\n' "${route53_ns}" | normalize_ns_entries)
  normalized_public=$(printf '%s\n' "${public_ns}" | normalize_ns_entries)

  if [[ -z "${normalized_public}" ]]; then
    log "No public NS records detected for ${FRONTEND_ROOT_DOMAIN}."
    return 1
  fi

  if [[ "${normalized_route53}" != "${normalized_public}" ]]; then
    local expected="$(printf '%s' "${normalized_route53}" | tr '\n' ',' | sed 's/,$//')"
    local actual="$(printf '%s' "${normalized_public}" | tr '\n' ',' | sed 's/,$//')"
    log "Route 53 name servers do not match public NS records for ${FRONTEND_ROOT_DOMAIN}."
    log "  Route 53: ${expected}"
    log "  Public : ${actual}"
    return 1
  fi

  log "Public NS delegation matches Route 53 for ${FRONTEND_ROOT_DOMAIN}."
  return 0
}

ensure_alb_security_group_rules() {
  if [[ -z "${SECURITY_GROUP_ID}" || "${SECURITY_GROUP_ID}" == "None" ]]; then
    log "DefaultSecurityGroupId is empty; cannot ensure HTTPS ingress."
    return 1
  fi

  local https_rule
  https_rule=$(aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" ec2 describe-security-groups \
    --group-ids "${SECURITY_GROUP_ID}" \
    --query "SecurityGroups[0].IpPermissions[?IpProtocol=='tcp' && FromPort==\`443\` && ToPort==\`443\`]" \
    --output text 2>/dev/null || echo "")

  if [[ -n "${https_rule}" && "${https_rule}" != "None" ]]; then
    log "Security group ${SECURITY_GROUP_ID} already allows HTTPS ingress."
    return 0
  fi

  log "Authorizing TCP/443 ingress on security group ${SECURITY_GROUP_ID}..."
  if ! aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" ec2 authorize-security-group-ingress \
    --group-id "${SECURITY_GROUP_ID}" \
    --ip-permissions '[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0","Description":"ECS sarrescost ALB HTTPS"}]}]' >/dev/null 2>&1; then
    log "Failed to authorize HTTPS ingress on ${SECURITY_GROUP_ID}."
    return 1
  fi
  log "Security group ${SECURITY_GROUP_ID} now permits TCP/443 from 0.0.0.0/0."
  return 0
}

create_route53_hosted_zone() {
  local domain="${FRONTEND_ROOT_DOMAIN%.}."
  local caller_ref="frontend-bootstrap-$(date +%s)"
  log "Creating Route 53 hosted zone for ${FRONTEND_ROOT_DOMAIN}..."
  local hosted_zone_id
  hosted_zone_id=$(aws --profile "${AWS_PROFILE}" route53 create-hosted-zone \
    --name "${domain}" \
    --caller-reference "${caller_ref}" \
    --hosted-zone-config Comment="Created by deploy-cost-backend.sh",PrivateZone=false \
    --query 'HostedZone.Id' --output text 2>/dev/null || true)
  if [[ -z "${hosted_zone_id}" || "${hosted_zone_id}" == "None" ]]; then
    log "Failed to create Route 53 hosted zone automatically."
    return 1
  fi
  hosted_zone_id="${hosted_zone_id#/hostedzone/}"
  log "Hosted zone /hostedzone/${hosted_zone_id} created."

  local ns_records
  ns_records=$(aws --profile "${AWS_PROFILE}" route53 get-hosted-zone \
    --id "/hostedzone/${hosted_zone_id}" \
    --query 'DelegationSet.NameServers' --output text 2>/dev/null || true)
  if [[ -z "${ns_records}" || "${ns_records}" == "None" ]]; then
    log "Could not retrieve NS records for the new hosted zone; check the AWS console."
  else
    log "Name servers for ${FRONTEND_ROOT_DOMAIN}:"
    while IFS= read -r ns_entry; do
      [[ -z "${ns_entry}" ]] && continue
      log "  - ${ns_entry%.}."
    done <<<"${ns_records}"
  fi

  log "Update your domain registrar to delegate ${FRONTEND_ROOT_DOMAIN} to the name servers above, then rerun this script once DNS propagation completes."
  exit 1
}

prompt_route53_bootstrap() {
  if [[ ! -t 0 ]]; then
    log "Route 53 hosted zone missing and no interactive TTY available to create it automatically."
    return 1
  fi
  local answer
  read -r -p "Route 53 hosted zone for ${FRONTEND_ROOT_DOMAIN} not found. Create it now? [y/N]: " answer
  case "${answer}" in
    [Yy][Yy]*|[Yy])
      create_route53_hosted_zone
      ;;
    *)
      log "Route 53 configuration skipped at user request."
      return 1
      ;;
  esac
}

verify_dns_prerequisites() {
  if [[ "${FRONTEND_ENABLED}" != "true" ]]; then
    log "DNS verification skipped because FRONTEND_ENABLED=false."
    return 0
  fi
  if [[ -z "${FRONTEND_ROOT_DOMAIN}" ]]; then
    log "FRONTEND_ROOT_DOMAIN is empty; cannot verify hosted zone."
    return 1
  fi

  local desired_zone_name="${FRONTEND_ROOT_DOMAIN%.}."
  local zone_id="${FRONTEND_HOSTED_ZONE_ID:-}"
  local zone_name=""
  local private_flag=""
  if [[ -n "${zone_id}" ]]; then
    zone_id="${zone_id#/hostedzone/}"
    read -r zone_name private_flag < <(
      aws --profile "${AWS_PROFILE}" route53 get-hosted-zone \
        --id "/hostedzone/${zone_id}" \
        --query 'HostedZone.[Name,Config.PrivateZone]' --output text 2>/dev/null || true
    )
  else
    read -r zone_id zone_name private_flag < <(
      aws --profile "${AWS_PROFILE}" route53 list-hosted-zones-by-name \
        --dns-name "${desired_zone_name}" --max-items 1 \
        --query "HostedZones[0].[Id,Name,Config.PrivateZone]" --output text 2>/dev/null || true
    )
  fi

  if [[ -z "${zone_id}" || -z "${zone_name}" || "${zone_id}" == "None" || "${zone_name}" == "None" || "${zone_name}" != "${desired_zone_name}" ]]; then
    log "No Route 53 hosted zone found for ${FRONTEND_ROOT_DOMAIN}."
    prompt_route53_bootstrap || true
    dns_failure_guidance
    return 1
  fi

  if [[ "${private_flag}" == "True" ]]; then
    log "Hosted zone ${zone_id} for ${FRONTEND_ROOT_DOMAIN} is private; a public zone is required for the frontend."
    dns_failure_guidance
    return 1
  fi

  FRONTEND_HOSTED_ZONE_ID="${zone_id#/hostedzone/}"
  if ! ensure_public_ns_matches_route53 "${FRONTEND_HOSTED_ZONE_ID}"; then
    dns_failure_guidance
    return 1
  fi
  log "Verified Route 53 hosted zone ${FRONTEND_HOSTED_ZONE_ID} and delegation for ${FRONTEND_ROOT_DOMAIN}."
  return 0
}

resource_label() {
  local type="$1" logical="$2"
  case "$type" in
    AWS::ECS::Cluster) echo "ECS cluster (${logical})" ;;
    AWS::ECS::Service) echo "ECS service (${logical})" ;;
    AWS::ECS::TaskDefinition) echo "ECS task definition (${logical})" ;;
    AWS::ElasticLoadBalancingV2::LoadBalancer) echo "Application Load Balancer (${logical})" ;;
    AWS::ElasticLoadBalancingV2::TargetGroup) echo "Target group (${logical})" ;;
    AWS::ElasticLoadBalancingV2::Listener) echo "ALB listener (${logical})" ;;
    AWS::AutoScaling::AutoScalingGroup) echo "Auto Scaling group (${logical})" ;;
    AWS::EC2::LaunchTemplate) echo "EC2 launch template (${logical})" ;;
    AWS::EC2::Instance) echo "EC2 instance (${logical})" ;;
    AWS::IAM::Role) echo "IAM role (${logical})" ;;
    AWS::IAM::InstanceProfile) echo "IAM instance profile (${logical})" ;;
    AWS::Logs::LogGroup) echo "CloudWatch Logs group (${logical})" ;;
    AWS::SecretsManager::Secret) echo "Secrets Manager secret (${logical})" ;;
    *) echo "${type} (${logical})" ;;
  esac
}

set_event_cursor() {
  LAST_EVENT_ID=$(aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
    cloudformation describe-stack-events --stack-name "${STACK_NAME}" \
    --max-items 1 --query 'StackEvents[0].EventId' --output text 2>/dev/null || true)
  if [[ "${LAST_EVENT_ID}" == "None" ]]; then
    LAST_EVENT_ID=""
  fi
}

emit_stack_events() {
  local output
  if ! output=$(aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
      cloudformation describe-stack-events --stack-name "${STACK_NAME}" \
      --query 'StackEvents[*].[EventId,Timestamp,LogicalResourceId,ResourceType,ResourceStatus]' \
      --output text 2>/dev/null); then
    return
  fi

  [[ -z "${output}" ]] && return

  local -a lines=()
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    lines+=("${line}")
  done <<<"${output}"

  [[ ${#lines[@]} -eq 0 ]] && return

  local -a new_lines=()
  local event_id
  for line in "${lines[@]}"; do
    IFS=$'\t' read -r event_id _ <<<"${line}"
    if [[ -n "${LAST_EVENT_ID}" && "${event_id}" == "${LAST_EVENT_ID}" ]]; then
      break
    fi
    new_lines+=("${line}")
  done

  if [[ ${#new_lines[@]} -eq 0 ]]; then
    IFS=$'\t' read -r event_id _ <<<"${lines[0]}"
    LAST_EVENT_ID="${event_id}"
    return
  fi

  local idx action timestamp logical type status
  for (( idx=${#new_lines[@]}-1; idx>=0; idx-- )); do
    IFS=$'\t' read -r _ timestamp logical type status <<<"${new_lines[$idx]}"
    case "${status}" in
      CREATE_IN_PROGRESS) action="creating" ;;
      CREATE_COMPLETE) action="created" ;;
      CREATE_FAILED) action="FAILED to create" ;;
      UPDATE_IN_PROGRESS) action="updating" ;;
      UPDATE_COMPLETE|UPDATE_COMPLETE_CLEANUP_IN_PROGRESS) action="updated" ;;
      UPDATE_FAILED) action="FAILED to update" ;;
      IMPORT_IN_PROGRESS) action="importing" ;;
      IMPORT_COMPLETE) action="imported" ;;
      ROLLBACK_IN_PROGRESS|UPDATE_ROLLBACK_IN_PROGRESS) action="rolling back" ;;
      ROLLBACK_COMPLETE|UPDATE_ROLLBACK_COMPLETE) action="rolled back" ;;
      *) continue ;;
    esac
    log_progress "$(resource_label "${type}" "${logical}")" "${action}" "${timestamp}"
  done

  IFS=$'\t' read -r LAST_EVENT_ID _ <<<"${lines[0]}"
}

stack_status() {
  aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
    cloudformation describe-stacks --stack-name "${STACK_NAME}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "STACK_NOT_FOUND"
}

is_transitional_status() {
  case "$1" in
    CREATE_IN_PROGRESS|UPDATE_IN_PROGRESS|UPDATE_COMPLETE_CLEANUP_IN_PROGRESS|\
    IMPORT_IN_PROGRESS|IMPORT_ROLLBACK_IN_PROGRESS|\
    ROLLBACK_IN_PROGRESS|UPDATE_ROLLBACK_IN_PROGRESS)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

watch_stack_events() {
  local deploy_pid="$1"
  while true; do
    emit_stack_events || true
    local status
    status=$(stack_status)
    if ! kill -0 "${deploy_pid}" 2>/dev/null && is_transitional_status "${status}"; then
      # Deployment process ended but stack still transitioning; keep polling.
      :
    elif ! kill -0 "${deploy_pid}" 2>/dev/null && ! is_transitional_status "${status}"; then
      break
    fi
    if kill -0 "${deploy_pid}" 2>/dev/null || is_transitional_status "${status}"; then
      sleep "${POLL_INTERVAL_SECONDS}"
      continue
    fi
    break
  done
  emit_stack_events || true
}

ensure_frontend_hosted_zone() {
  if [[ -n "${FRONTEND_HOSTED_ZONE_ID}" ]]; then
    return 0
  fi
  local zone_name="${FRONTEND_ROOT_DOMAIN%.}."
  local zone_id
  zone_id=$(aws --profile "${AWS_PROFILE}" route53 list-hosted-zones \
    --query "HostedZones[?Name=='${zone_name}'].Id | [0]" --output text 2>/dev/null || echo "None")
  local zone_created="false"
  if [[ -z "${zone_id}" || "${zone_id}" == "None" ]]; then
    log "Route 53 hosted zone for ${FRONTEND_ROOT_DOMAIN} not found. Creating it now..."
    local caller_ref="frontend-zone-$(date +%s)"
    zone_id=$(aws --profile "${AWS_PROFILE}" route53 create-hosted-zone \
      --name "${FRONTEND_ROOT_DOMAIN}" \
      --caller-reference "${caller_ref}" \
      --query 'HostedZone.Id' --output text)
    zone_created="true"
  fi
  FRONTEND_HOSTED_ZONE_ID="${zone_id#/hostedzone/}"
  log "Route 53 hosted zone ${FRONTEND_ROOT_DOMAIN} detected (ID=${FRONTEND_HOSTED_ZONE_ID})."
  if [[ "${zone_created}" == "true" ]]; then
    log "Hosted zone created. Configure your domain registrar to delegate ${FRONTEND_ROOT_DOMAIN} to Route 53 using the name servers below."
    log_zone_delegation_instructions
  fi
  return 0
}

log_zone_delegation_instructions() {
  if [[ -z "${FRONTEND_HOSTED_ZONE_ID}" ]]; then
    return
  fi
  local zone_name="${FRONTEND_ROOT_DOMAIN%.}."
  local ns_records
  ns_records=$(aws --profile "${AWS_PROFILE}" route53 list-resource-record-sets \
    --hosted-zone-id "${FRONTEND_HOSTED_ZONE_ID}" \
    --query "ResourceRecordSets[?Type=='NS' && Name=='${zone_name}'].ResourceRecords[].Value" \
    --output text 2>/dev/null || echo "")
  if [[ -z "${ns_records}" || "${ns_records}" == "None" ]]; then
    log "Name server records for ${FRONTEND_ROOT_DOMAIN} were not found; verify the hosted zone manually."
    return
  fi
  log "Delegate ${FRONTEND_ROOT_DOMAIN} at your registrar to these Route 53 name servers:"
  while IFS=$'\t' read -r ns_entry; do
    [[ -z "${ns_entry}" ]] && continue
    log "  - ${ns_entry%.}"
  done <<<"${ns_records}"
  log "After the registrar update propagates (often a few hours), rerun this script so costly.sarres.com.br resolves through Route 53."
}

publish_dns_validation_records() {
  local cert_arn="$1"
  local hosted_zone_id="$2"
  local domain_label="$3"
  local cert_region="$4"

  if [[ -z "${hosted_zone_id}" ]]; then
    log "Cannot publish ACM validation records for ${domain_label} without a hosted zone id."
    return 1
  fi

  local records
  local attempts=0
  local max_attempts=10
  while true; do
    records=$(aws --profile "${AWS_PROFILE}" --region "${cert_region}" acm describe-certificate \
      --certificate-arn "${cert_arn}" \
      --query "Certificate.DomainValidationOptions[].ResourceRecord.[Name,Type,Value]" \
      --output text 2>/dev/null || echo "")
    if [[ -n "${records}" && "${records}" != "None" ]]; then
      break
    fi
    if (( attempts >= max_attempts )); then
      log "Certificate ${cert_arn} did not return DNS validation records after ${max_attempts} attempts."
      return 1
    fi
    log "Waiting for ACM to produce DNS validation records for ${cert_arn} (attempt $((attempts + 1)))..."
    sleep 3
    attempts=$((attempts + 1))
  done

  while IFS=$'\t' read -r name type value; do
    [[ -z "${name}" || "${name}" == "None" ]] && continue
    local tmp_file
    tmp_file=$(mktemp)
    cat <<JSON > "${tmp_file}"
{
  "Comment": "ACM validation for ${domain_label}",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${name}",
      "Type": "${type}",
      "TTL": 300,
      "ResourceRecords": [{"Value": "${value}"}]
    }
  }]
}
JSON
    local change_id
    change_id=$(aws --profile "${AWS_PROFILE}" route53 change-resource-record-sets \
      --hosted-zone-id "${hosted_zone_id}" \
      --change-batch file://"${tmp_file}" \
      --query 'ChangeInfo.Id' --output text)
    rm -f "${tmp_file}"
    log "ACM validation record ${name} (${type}) -> ${value} upserted in Route 53 (change ${change_id})."
    log "Waiting for Route 53 change ${change_id} to propagate..."
    aws --profile "${AWS_PROFILE}" route53 wait resource-record-sets-changed --id "${change_id}" >/dev/null
    log "Change ${change_id} is INSYNC; ACM can now read ${name}."
  done <<<"${records}"
  return 0
}

wait_for_certificate() {
  local cert_arn="$1"
  local cert_region="$2"
  local domain_label="$3"
  local attempts=0
  local max_attempts=40
  local status
  while (( attempts < max_attempts )); do
    status=$(aws --profile "${AWS_PROFILE}" --region "${cert_region}" acm describe-certificate \
      --certificate-arn "${cert_arn}" --query 'Certificate.Status' --output text 2>/dev/null || echo "UNKNOWN")
    case "${status}" in
      ISSUED)
        log "ACM certificate ${cert_arn} for ${domain_label} issued."
        return 0
        ;;
      FAILED)
        log "ACM certificate ${cert_arn} for ${domain_label} failed validation."
        return 1
        ;;
    esac
    log "Certificate ${cert_arn} for ${domain_label} status=${status}; waiting for DNS validation..."
    sleep 15
    attempts=$((attempts + 1))
  done
  log "Timed out waiting for ACM certificate ${cert_arn} (${domain_label}) to issue."
  return 1
}

ensure_frontend_certificate() {
  log "Checking ACM certificate for ${FRONTEND_DOMAIN} (region ${FRONTEND_CERT_REGION})..."
  local cert_arn
  cert_arn=$(aws --profile "${AWS_PROFILE}" --region "${FRONTEND_CERT_REGION}" acm list-certificates \
    --certificate-statuses ISSUED PENDING_VALIDATION INACTIVE EXPIRED VALIDATION_TIMED_OUT FAILED REVOKED \
    --query "CertificateSummaryList[?DomainName=='${FRONTEND_DOMAIN}'].CertificateArn | [0]" \
    --output text 2>/dev/null || echo "None")
  if [[ -n "${cert_arn}" && "${cert_arn}" != "None" ]]; then
    FRONTEND_CERT_ARN="${cert_arn}"
    local status
    status=$(aws --profile "${AWS_PROFILE}" --region "${FRONTEND_CERT_REGION}" acm describe-certificate \
      --certificate-arn "${cert_arn}" --query 'Certificate.Status' --output text 2>/dev/null || echo "UNKNOWN")
    case "${status}" in
      ISSUED|INACTIVE)
        log "Using existing certificate ${cert_arn} (status=${status})."
        return 0
        ;;
      PENDING_VALIDATION)
        log "Certificate ${cert_arn} currently ${status}; ensuring DNS validation records exist..."
        publish_dns_validation_records "${cert_arn}" "${FRONTEND_HOSTED_ZONE_ID}" "${FRONTEND_DOMAIN}" "${FRONTEND_CERT_REGION}" || return 1
        wait_for_certificate "${cert_arn}" "${FRONTEND_CERT_REGION}" "${FRONTEND_DOMAIN}" || return 1
        return 0
        ;;
      EXPIRED|VALIDATION_TIMED_OUT|FAILED|REVOKED)
        if [[ "${ALLOW_ACM_REISSUE}" == "true" ]]; then
          log "Certificate ${cert_arn} is ${status}; ALLOW_ACM_REISSUE=true so a new certificate will be requested."
        else
          log "Certificate ${cert_arn} exists with status ${status}; refusing to request a new certificate automatically."
          log "Delete or clean up the existing ACM certificate (or rerun with ALLOW_ACM_REISSUE=true) before redeploying."
          return 1
        fi
        ;;
      *)
        log "Certificate ${cert_arn} returned status ${status}; attempting to reuse it."
        publish_dns_validation_records "${cert_arn}" "${FRONTEND_HOSTED_ZONE_ID}" "${FRONTEND_DOMAIN}" "${FRONTEND_CERT_REGION}" || return 1
        wait_for_certificate "${cert_arn}" "${FRONTEND_CERT_REGION}" "${FRONTEND_DOMAIN}" || return 1
        return 0
        ;;
    esac
  fi

  log "Requesting new ACM certificate for ${FRONTEND_DOMAIN}..."
  FRONTEND_CERT_ARN=$(aws --profile "${AWS_PROFILE}" --region "${FRONTEND_CERT_REGION}" acm request-certificate \
    --domain-name "${FRONTEND_DOMAIN}" \
    --validation-method DNS \
    --options CertificateTransparencyLoggingPreference=ENABLED \
    --idempotency-token "frontend$(date +%s)" \
    --query 'CertificateArn' --output text)
  publish_dns_validation_records "${FRONTEND_CERT_ARN}" "${FRONTEND_HOSTED_ZONE_ID}" "${FRONTEND_DOMAIN}" "${FRONTEND_CERT_REGION}" || return 1
  wait_for_certificate "${FRONTEND_CERT_ARN}" "${FRONTEND_CERT_REGION}" "${FRONTEND_DOMAIN}" || return 1
  return 0
}

ensure_backend_certificate() {
  if [[ -z "${BACKEND_DOMAIN}" ]]; then
    log "BACKEND_DOMAIN is empty; cannot provision ACM certificate."
    return 1
  fi
  if [[ -z "${BACKEND_HOSTED_ZONE_ID}" ]]; then
    log "BACKEND_HOSTED_ZONE_ID is empty; cannot publish validation records for ${BACKEND_DOMAIN}."
    return 1
  fi

  log "Checking ACM certificate for ${BACKEND_DOMAIN} (region ${BACKEND_CERT_REGION})..."
  local cert_arn
  cert_arn=$(aws --profile "${AWS_PROFILE}" --region "${BACKEND_CERT_REGION}" acm list-certificates \
    --certificate-statuses ISSUED PENDING_VALIDATION INACTIVE EXPIRED VALIDATION_TIMED_OUT FAILED REVOKED \
    --query "CertificateSummaryList[?DomainName=='${BACKEND_DOMAIN}'].CertificateArn | [0]" \
    --output text 2>/dev/null || echo "None")

  if [[ -n "${cert_arn}" && "${cert_arn}" != "None" ]]; then
    BACKEND_CERT_ARN="${cert_arn}"
    local status
    status=$(aws --profile "${AWS_PROFILE}" --region "${BACKEND_CERT_REGION}" acm describe-certificate \
      --certificate-arn "${cert_arn}" --query 'Certificate.Status' --output text 2>/dev/null || echo "UNKNOWN")
    case "${status}" in
      ISSUED|INACTIVE)
        log "Reusing existing backend certificate ${cert_arn} (status=${status})."
        return 0
        ;;
      PENDING_VALIDATION)
        log "Backend certificate ${cert_arn} pending validation; re-publishing DNS records."
        publish_dns_validation_records "${cert_arn}" "${BACKEND_HOSTED_ZONE_ID}" "${BACKEND_DOMAIN}" "${BACKEND_CERT_REGION}" || return 1
        wait_for_certificate "${cert_arn}" "${BACKEND_CERT_REGION}" "${BACKEND_DOMAIN}" || return 1
        return 0
        ;;
      *)
        log "Backend certificate ${cert_arn} currently ${status}; requesting a fresh certificate."
        ;;
    esac
  fi

  log "Requesting new backend ACM certificate for ${BACKEND_DOMAIN}..."
  BACKEND_CERT_ARN=$(aws --profile "${AWS_PROFILE}" --region "${BACKEND_CERT_REGION}" acm request-certificate \
    --domain-name "${BACKEND_DOMAIN}" \
    --validation-method DNS \
    --options CertificateTransparencyLoggingPreference=ENABLED \
    --idempotency-token "backend$(date +%s)" \
    --query 'CertificateArn' --output text)
  publish_dns_validation_records "${BACKEND_CERT_ARN}" "${BACKEND_HOSTED_ZONE_ID}" "${BACKEND_DOMAIN}" "${BACKEND_CERT_REGION}" || return 1
  wait_for_certificate "${BACKEND_CERT_ARN}" "${BACKEND_CERT_REGION}" "${BACKEND_DOMAIN}" || return 1
  return 0
}

build_frontend_assets() {
  if [[ ! -d "${FRONTEND_DIR}" ]]; then
    log "Frontend directory ${FRONTEND_DIR} not found; skipping frontend deployment."
    return 1
  fi
  if ! command -v npm >/dev/null 2>&1; then
    log "npm command not available; cannot build frontend."
    return 1
  fi
  log "Installing frontend dependencies in ${FRONTEND_DIR}..."
  npm --prefix "${FRONTEND_DIR}" install >/dev/null
  log "Building frontend assets (npm run build)..."
  npm --prefix "${FRONTEND_DIR}" run build >/dev/null
  if [[ ! -d "${FRONTEND_DIST_DIR}" ]]; then
    log "Frontend build output ${FRONTEND_DIST_DIR} not found after build."
    return 1
  fi
  return 0
}

ensure_frontend_bucket() {
  if aws --profile "${AWS_PROFILE}" --region "${FRONTEND_BUCKET_REGION}" s3api head-bucket --bucket "${FRONTEND_BUCKET}" >/dev/null 2>&1; then
    log "Using existing S3 bucket s3://${FRONTEND_BUCKET}."
  else
    log "Creating S3 bucket s3://${FRONTEND_BUCKET} (region ${FRONTEND_BUCKET_REGION})..."
    if [[ "${FRONTEND_BUCKET_REGION}" == "us-east-1" ]]; then
      aws --profile "${AWS_PROFILE}" --region "${FRONTEND_BUCKET_REGION}" s3api create-bucket --bucket "${FRONTEND_BUCKET}" >/dev/null
    else
      aws --profile "${AWS_PROFILE}" --region "${FRONTEND_BUCKET_REGION}" s3api create-bucket --bucket "${FRONTEND_BUCKET}" \
        --create-bucket-configuration LocationConstraint="${FRONTEND_BUCKET_REGION}" >/dev/null
    fi
  fi

  log "Configuring public website hosting for s3://${FRONTEND_BUCKET}..."
  aws --profile "${AWS_PROFILE}" --region "${FRONTEND_BUCKET_REGION}" s3api put-public-access-block --bucket "${FRONTEND_BUCKET}" \
    --public-access-block-configuration BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false >/dev/null

  local policy_file
  policy_file=$(mktemp)
  cat <<POLICY > "${policy_file}"
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowPublicRead",
    "Effect": "Allow",
    "Principal": "*",
    "Action": ["s3:GetObject"],
    "Resource": ["arn:aws:s3:::${FRONTEND_BUCKET}/*"]
  }]
}
POLICY
  aws --profile "${AWS_PROFILE}" --region "${FRONTEND_BUCKET_REGION}" s3api put-bucket-policy --bucket "${FRONTEND_BUCKET}" --policy file://"${policy_file}"
  rm -f "${policy_file}"

  aws --profile "${AWS_PROFILE}" --region "${FRONTEND_BUCKET_REGION}" s3 website "s3://${FRONTEND_BUCKET}/" \
    --index-document index.html --error-document index.html >/dev/null
  return 0
}

sync_frontend_assets_to_s3() {
  if [[ ! -d "${FRONTEND_DIST_DIR}" ]]; then
    log "Frontend dist directory ${FRONTEND_DIST_DIR} not found; ensure the build completed."
    return 1
  fi
  log "Syncing frontend assets to s3://${FRONTEND_BUCKET}..."
  aws --profile "${AWS_PROFILE}" --region "${FRONTEND_BUCKET_REGION}" s3 sync "${FRONTEND_DIST_DIR}/" "s3://${FRONTEND_BUCKET}/" --delete >/dev/null
  return 0
}

find_frontend_distribution() {
  local existing
  existing=$(aws --profile "${AWS_PROFILE}" cloudfront list-distributions \
    --query "DistributionList.Items[?Aliases.Items && contains(Aliases.Items, '${FRONTEND_DOMAIN}')].[Id,DomainName]" \
    --output text 2>/dev/null || echo "")
  if [[ -n "${existing}" && "${existing}" != "None" ]]; then
    read -r FRONTEND_DISTRIBUTION_ID FRONTEND_DISTRIBUTION_DOMAIN <<<"${existing}"
    return 0
  fi
  return 1
}

frontend_already_provisioned() {
  local bucket_ok=1
  if aws --profile "${AWS_PROFILE}" --region "${FRONTEND_BUCKET_REGION}" s3api head-bucket --bucket "${FRONTEND_BUCKET}" >/dev/null 2>&1; then
    bucket_ok=0
  fi
  local distribution_ok=1
  if find_frontend_distribution; then
    distribution_ok=0
  fi
  if [[ ${bucket_ok} -eq 0 && ${distribution_ok} -eq 0 ]]; then
    return 0
  fi
  return 1
}

ensure_cloudfront_distribution() {
  if find_frontend_distribution; then
    log "Reusing existing CloudFront distribution ${FRONTEND_DISTRIBUTION_ID} (${FRONTEND_DISTRIBUTION_DOMAIN})."
    FRONTEND_DISTRIBUTION_CREATED="false"
    return 0
  fi

  log "Creating CloudFront distribution for ${FRONTEND_DOMAIN}..."
  local config_file
  config_file=$(mktemp)
  cat <<JSON > "${config_file}"
{
  "CallerReference": "frontend-${FRONTEND_DOMAIN}-$(date +%s)",
  "Aliases": {"Quantity": 1, "Items": ["${FRONTEND_DOMAIN}"]},
  "DefaultRootObject": "index.html",
  "Comment": "cost backend frontend (${FRONTEND_DOMAIN})",
  "Enabled": true,
  "Origins": {
    "Quantity": 1,
    "Items": [{
      "Id": "s3-${FRONTEND_BUCKET}",
      "DomainName": "${FRONTEND_BUCKET}.s3.${FRONTEND_BUCKET_REGION}.amazonaws.com",
      "OriginPath": "",
      "CustomHeaders": {"Quantity": 0},
      "S3OriginConfig": {"OriginAccessIdentity": ""}
    }]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-${FRONTEND_BUCKET}",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 2,
      "Items": ["GET", "HEAD"],
      "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}
    },
    "Compress": true,
    "DefaultTTL": 86400,
    "MinTTL": 0,
    "MaxTTL": 31536000,
    "ForwardedValues": {
      "QueryString": true,
      "Cookies": {"Forward": "none"},
      "Headers": {"Quantity": 0},
      "QueryStringCacheKeys": {"Quantity": 0}
    }
  },
  "PriceClass": "PriceClass_100",
  "CustomErrorResponses": {
    "Quantity": 2,
    "Items": [
      {"ErrorCode": 403, "ResponseCode": "200", "ResponsePagePath": "/index.html", "ErrorCachingMinTTL": 120},
      {"ErrorCode": 404, "ResponseCode": "200", "ResponsePagePath": "/index.html", "ErrorCachingMinTTL": 120}
    ]
  },
  "ViewerCertificate": {
    "ACMCertificateArn": "${FRONTEND_CERT_ARN}",
    "SSLSupportMethod": "sni-only",
    "MinimumProtocolVersion": "TLSv1.2_2021",
    "Certificate": "${FRONTEND_CERT_ARN}",
    "CertificateSource": "acm"
  },
  "Restrictions": {
    "GeoRestriction": {"RestrictionType": "none", "Quantity": 0}
  },
  "HttpVersion": "http2",
  "IsIPV6Enabled": true
}
JSON
  read -r FRONTEND_DISTRIBUTION_ID FRONTEND_DISTRIBUTION_DOMAIN <<<"$(aws --profile "${AWS_PROFILE}" cloudfront create-distribution \
    --distribution-config file://"${config_file}" \
    --query 'Distribution.[Id,DomainName]' --output text)"
  rm -f "${config_file}"
  log "Created CloudFront distribution ${FRONTEND_DISTRIBUTION_ID} (${FRONTEND_DISTRIBUTION_DOMAIN})."
  FRONTEND_DISTRIBUTION_CREATED="true"
  return 0
}

create_cloudfront_invalidation() {
  if [[ "${FRONTEND_DISTRIBUTION_CREATED}" == "true" ]]; then
    log "Skipping CloudFront invalidation; distribution ${FRONTEND_DISTRIBUTION_ID} is brand new."
    return 0
  fi

  if [[ -z "${FRONTEND_DISTRIBUTION_ID}" ]]; then
    if ! find_frontend_distribution; then
      log "No CloudFront distribution found for ${FRONTEND_DOMAIN}; skipping invalidation."
      return 0
    fi
  fi

  local invalidation_id
  invalidation_id=$(aws --profile "${AWS_PROFILE}" cloudfront create-invalidation \
    --distribution-id "${FRONTEND_DISTRIBUTION_ID}" \
    --paths "/*" \
    --query 'Invalidation.Id' --output text 2>/dev/null || echo "")

  if [[ -z "${invalidation_id}" || "${invalidation_id}" == "None" ]]; then
    log "Failed to request CloudFront invalidation for ${FRONTEND_DOMAIN}."
    return 1
  fi

  log "Requested CloudFront invalidation ${invalidation_id} for distribution ${FRONTEND_DISTRIBUTION_ID}."
  return 0
}

ensure_frontend_route53_alias() {
  if [[ -z "${FRONTEND_HOSTED_ZONE_ID}" ]]; then
    log "Cannot create Route 53 alias without a hosted zone id."
    return 1
  fi
  if [[ -z "${FRONTEND_DISTRIBUTION_DOMAIN}" ]]; then
    log "Cannot create Route 53 alias without a CloudFront domain."
    return 1
  fi
  local alias_dns="${FRONTEND_DISTRIBUTION_DOMAIN}"
  [[ "${alias_dns}" != *. ]] && alias_dns="${alias_dns}."
  local change_file
  change_file=$(mktemp)
  cat <<JSON > "${change_file}"
{
  "Comment": "Alias ${FRONTEND_DOMAIN} -> ${alias_dns}",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${FRONTEND_DOMAIN}.",
      "Type": "A",
      "AliasTarget": {
        "HostedZoneId": "${CLOUDFRONT_HOSTED_ZONE_ID}",
        "DNSName": "${alias_dns}",
        "EvaluateTargetHealth": false
      }
    }
  },
  {
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${FRONTEND_DOMAIN}.",
      "Type": "AAAA",
      "AliasTarget": {
        "HostedZoneId": "${CLOUDFRONT_HOSTED_ZONE_ID}",
        "DNSName": "${alias_dns}",
        "EvaluateTargetHealth": false
      }
    }
  }]
}
JSON
  aws --profile "${AWS_PROFILE}" route53 change-resource-record-sets \
    --hosted-zone-id "${FRONTEND_HOSTED_ZONE_ID}" \
    --change-batch file://"${change_file}"
  rm -f "${change_file}"
  log "Route 53 alias for ${FRONTEND_DOMAIN} now points to ${alias_dns}."
  return 0
}

ensure_backend_route53_alias() {
  local alias_dns="$1"
  local alias_zone_id="$2"
  if [[ -z "${BACKEND_HOSTED_ZONE_ID}" ]]; then
    log "Cannot create backend Route 53 alias without a hosted zone id."
    return 1
  fi
  if [[ -z "${alias_dns}" || "${alias_dns}" == "None" ]]; then
    log "Cannot create backend Route 53 alias without a load balancer DNS name."
    return 1
  fi
  if [[ -z "${alias_zone_id}" || "${alias_zone_id}" == "None" ]]; then
    log "Cannot create backend Route 53 alias without the ALB canonical hosted zone id."
    return 1
  fi
  local formatted_alias="${alias_dns%.}."
  local change_file
  change_file=$(mktemp)
  cat <<JSON > "${change_file}"
{
  "Comment": "Alias ${BACKEND_DOMAIN} -> ${formatted_alias}",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${BACKEND_DOMAIN}.",
      "Type": "A",
      "AliasTarget": {
        "HostedZoneId": "${alias_zone_id}",
        "DNSName": "${formatted_alias}",
        "EvaluateTargetHealth": false
      }
    }
  },
  {
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${BACKEND_DOMAIN}.",
      "Type": "AAAA",
      "AliasTarget": {
        "HostedZoneId": "${alias_zone_id}",
        "DNSName": "${formatted_alias}",
        "EvaluateTargetHealth": false
      }
    }
  }]
}
JSON
  aws --profile "${AWS_PROFILE}" route53 change-resource-record-sets \
    --hosted-zone-id "${BACKEND_HOSTED_ZONE_ID}" \
    --change-batch file://"${change_file}"
  rm -f "${change_file}"
  log "Route 53 alias for ${BACKEND_DOMAIN} now points to ${formatted_alias}."
  return 0
}

flush_local_dns_cache() {
  local flushed="false"
  if command -v dscacheutil >/dev/null 2>&1; then
    if dscacheutil -flushcache >/dev/null 2>&1; then
      log "Flushed macOS DNS cache via dscacheutil."
      flushed="true"
    fi
  fi
  if command -v killall >/dev/null 2>&1; then
    if killall -HUP mDNSResponder >/dev/null 2>&1; then
      log "Restarted mDNSResponder to refresh DNS cache."
      flushed="true"
    fi
  fi
  if command -v systemd-resolve >/dev/null 2>&1; then
    if systemd-resolve --flush-caches >/dev/null 2>&1; then
      log "Flushed systemd-resolved DNS cache."
      flushed="true"
    fi
  fi
  if command -v resolvectl >/dev/null 2>&1; then
    if resolvectl flush-caches >/dev/null 2>&1; then
      log "Flushed resolvectl DNS cache."
      flushed="true"
    fi
  fi
  if [[ "${flushed}" != "true" ]]; then
    log "No supported DNS cache flush command found on this host; skipping."
  fi
}

deploy_frontend_stack() {
  log "----- Frontend readiness for ${FRONTEND_DOMAIN} -----"
  if frontend_already_provisioned && [[ "${FRONTEND_FORCE_REDEPLOY}" != "true" ]]; then
    log "Frontend bucket + CloudFront distribution already exist; skipping (set FRONTEND_FORCE_REDEPLOY=true to force)."
    return 0
  fi
  if ! ensure_frontend_hosted_zone; then
    log "Route 53 prerequisites missing; skipping frontend deployment."
    return 0
  fi
  if ! ensure_frontend_certificate; then
    log "ACM certificate for ${FRONTEND_DOMAIN} could not be validated; skipping frontend deployment."
    return 0
  fi
  if ! build_frontend_assets; then
    log "Frontend build failed; aborting frontend deployment."
    return 1
  fi
  if ! ensure_frontend_bucket; then
    log "Failed to prepare S3 bucket ${FRONTEND_BUCKET}."
    return 1
  fi
  if ! sync_frontend_assets_to_s3; then
    log "Failed to upload frontend assets to s3://${FRONTEND_BUCKET}."
    return 1
  fi
  if ! ensure_cloudfront_distribution; then
    log "CloudFront distribution setup failed."
    return 1
  fi
  if ! create_cloudfront_invalidation; then
    log "CloudFront invalidation request failed; continuing without waiting for cache flush."
  fi
  if ! ensure_frontend_route53_alias; then
    log "Failed to update Route 53 alias for ${FRONTEND_DOMAIN}."
    return 1
  fi
  log "Frontend deployed at https://${FRONTEND_DOMAIN} (distribution ${FRONTEND_DISTRIBUTION_ID:-n/a})."
  flush_local_dns_cache || true
  return 0
}

if [[ "${IMAGE_URI}" == "${DEFAULT_IMAGE_URI_PLACEHOLDER}" ]]; then
  if ! IMAGE_URI="$(resolve_latest_image_uri)"; then
    log "Failed to determine the ECR image tagged '${DEFAULT_ECR_IMAGE_TAG}'. Set IMAGE_URI manually."
    exit 1
  fi
  log "Resolved '${DEFAULT_ECR_IMAGE_TAG}' tag to ${IMAGE_URI}."
fi

log "Running DNS verification before starting service deployment..."
if ! verify_dns_prerequisites; then
  log "DNS verification step failed; halting deployment as requested."
  exit 1
fi

if ! ensure_alb_security_group_rules; then
  log "Unable to ensure HTTPS ingress on security group ${SECURITY_GROUP_ID}."
  exit 1
fi

if [[ -z "${BACKEND_HOSTED_ZONE_ID}" ]]; then
  BACKEND_HOSTED_ZONE_ID="${FRONTEND_HOSTED_ZONE_ID}"
fi

if [[ -z "${BACKEND_CERT_ARN}" ]]; then
  if ! ensure_backend_certificate; then
    log "Backend certificate provisioning failed; aborting deployment."
    exit 1
  fi
fi

cat <<DEPLOY_PARAMS
Deploying stack: ${STACK_NAME}
Template:       ${TEMPLATE_FILE}
Region:         ${AWS_REGION}
Image URI:      ${IMAGE_URI}
Backend cert:   ${BACKEND_CERT_ARN}
Release tag:    ${RELEASE_TAG}
Task sizing:    CPU=${TASK_CPU}, Memory=${TASK_MEMORY}
Network:        VPC=${VPC_ID}, Subnets=${PUBLIC_SUBNETS}, SG=${SECURITY_GROUP_ID}
DEPLOY_PARAMS

set_event_cursor
log "Invoking CloudFormation deploy (progress streaming enabled)..."

run_deploy() {
  aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
    cloudformation deploy \
    --stack-name "${STACK_NAME}" \
    --template-file "${TEMPLATE_FILE}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
      VpcId="${VPC_ID}" \
      PublicSubnets="${PUBLIC_SUBNETS}" \
      DefaultSecurityGroupId="${SECURITY_GROUP_ID}" \
      ImageUri="${IMAGE_URI}" \
      ContainerPort="${CONTAINER_PORT}" \
      DesiredCount="${DESIRED_COUNT}" \
      TaskCpu="${TASK_CPU}" \
      TaskMemory="${TASK_MEMORY}" \
      AlbCertificateArn="${BACKEND_CERT_ARN}" \
      Environment="${ENVIRONMENT}" \
      ReleaseTag="${RELEASE_TAG}"
}

run_deploy &
DEPLOY_PID=$!
watch_stack_events "${DEPLOY_PID}"

if ! wait "${DEPLOY_PID}"; then
  log "CloudFormation deploy command failed. See progress logs above for details."
  exit 1
fi

log "Stack deployment finished; collecting AWS service summaries..."

cf_query() {
  aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
    cloudformation describe-stacks --stack-name "${STACK_NAME}" --query "$1" --output text 2>/dev/null
}

STACK_STATUS=$(cf_query 'Stacks[0].StackStatus')
SERVICE_ARN=$(cf_query "Stacks[0].Outputs[?OutputKey=='ServiceName'].OutputValue")
CLUSTER_NAME=$(cf_query "Stacks[0].Outputs[?OutputKey=='ClusterName'].OutputValue")
LOAD_BALANCER_DNS=$(cf_query "Stacks[0].Outputs[?OutputKey=='LoadBalancerDNS'].OutputValue")

log "CloudFormation status: ${STACK_STATUS}"
log "  Cluster: ${CLUSTER_NAME:-n/a}"
log "  Service: ${SERVICE_ARN:-n/a}"
log "  ALB DNS: ${LOAD_BALANCER_DNS:-n/a}"

if ! ensure_backend_route53_alias "${LOAD_BALANCER_DNS}" "${ALB_CANONICAL_ZONE_ID}"; then
  log "Backend Route 53 alias update failed; verify DNS for ${BACKEND_DOMAIN} manually."
fi

SERVICE_NAME="${SERVICE_ARN##*/}"
if [[ -n "${CLUSTER_NAME}" && -n "${SERVICE_NAME}" && "${SERVICE_NAME}" != "None" ]]; then
  log "ECS service details (cluster=${CLUSTER_NAME}, service=${SERVICE_NAME}):"
  aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" ecs describe-services \
    --cluster "${CLUSTER_NAME}" \
    --services "${SERVICE_NAME}" \
    --query 'services[0].{Status:status,Desired:desiredCount,Running:runningCount,TaskDefinition:taskDefinition}' \
    --output table
fi

STACK_RESOURCE() {
  aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
    cloudformation describe-stack-resources --stack-name "${STACK_NAME}" \
    --logical-resource-id "$1" --query 'StackResources[0].PhysicalResourceId' --output text 2>/dev/null
}

ALB_ARN=$(STACK_RESOURCE SarrescostLoadBalancer || true)
ALB_CANONICAL_ZONE_ID=""
ALB_DNS_FROM_API=""
if [[ -n "${ALB_ARN}" && "${ALB_ARN}" != "None" ]]; then
  read -r ALB_DNS_FROM_API ALB_CANONICAL_ZONE_ID <<<"$(aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" elbv2 describe-load-balancers \
    --load-balancer-arns "${ALB_ARN}" \
    --query 'LoadBalancers[0].[DNSName,CanonicalHostedZoneId]' --output text 2>/dev/null || echo -e "\t")"
fi
if [[ -z "${LOAD_BALANCER_DNS}" || "${LOAD_BALANCER_DNS}" == "None" ]]; then
  LOAD_BALANCER_DNS="${ALB_DNS_FROM_API:-}"
fi

ASG_NAME=$(STACK_RESOURCE SarrescostAutoScalingGroup || true)
if [[ -n "${ASG_NAME}" && "${ASG_NAME}" != "None" ]]; then
  log "Auto Scaling group summary (${ASG_NAME}):"
  aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
    autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "${ASG_NAME}" \
    --query 'AutoScalingGroups[0].{Name:AutoScalingGroupName,Desired:DesiredCapacity,Instances:Instances[].{Id:InstanceId,Type:InstanceType,AZ:AvailabilityZone}}' \
    --output table
fi

TARGET_GROUP_ARN=$(STACK_RESOURCE SarrescostTargetGroup || true)
if [[ -n "${TARGET_GROUP_ARN}" && "${TARGET_GROUP_ARN}" != "None" ]]; then
  log "ALB target health (${TARGET_GROUP_ARN}):"
  aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
    elbv2 describe-target-health --target-group-arn "${TARGET_GROUP_ARN}" \
    --query 'TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State}' \
    --output table
fi

if [[ -n "${LOAD_BALANCER_DNS}" && "${LOAD_BALANCER_DNS}" != "None" ]]; then
  log "Application available at: http://${LOAD_BALANCER_DNS}:${CONTAINER_PORT}/health"
fi

if [[ "${FRONTEND_ENABLED}" == "true" ]]; then
  if ! deploy_frontend_stack; then
    log "Frontend workflow finished with warnings/errors; review messages above."
  fi
else
  log "FRONTEND_ENABLED=false; skipping frontend workflow."
fi
