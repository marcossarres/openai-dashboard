#!/usr/bin/env bash
# Delete the AWS project resources created/managed by deploy-aws-project.sh.
#
# The script removes the backend CloudFormation stack and also cleans up
# companion resources managed outside the stack, including:
#   - extra ECS services / extra target groups created when NSERVICES > 1
#   - CloudFront distribution for the frontend alias
#   - Route 53 frontend/backend aliases
#   - ACM certificates for frontend/backend domains
#   - optional S3 frontend bucket deletion
#   - best-effort HTTPS ingress rule cleanup on the shared ALB security group
#
# Safety notes:
#   - This script is destructive. Review arguments carefully before running.
#   - It does not execute automatically here; editing the file is safe.
#   - By default it preserves the frontend S3 bucket unless DELETE_FRONTEND_BUCKET=true.
#
# Environment variables (override as needed):
#   AWS_PROFILE               AWS CLI profile (default: aws-cloudy)
#   AWS_REGION                Region (default: us-east-1)
#   STACK_NAME                Stack name to delete (default: <project>-<domain>-cloud-formation)
#   ECS_CLUSTER_NAME          ECS cluster name (default: <project>-<domain>-ecs-cluster)
#   POLL_INTERVAL_SECONDS     Seconds between progress polls (default: 10)
#   FRONTEND_HOSTED_ZONE_ID   Optional hosted zone id override
#   FRONTEND_BUCKET_REGION    S3 region for frontend bucket (default: AWS_REGION)
#   FRONTEND_CERT_REGION      Frontend ACM region (default: us-east-1)
#   BACKEND_CERT_REGION       Backend ACM region (default: AWS_REGION)
#   DELETE_FRONTEND_BUCKET    true|false (default: false)
#   FRONTEND_CERTIFICATE_ARN  Optional frontend ACM ARN override
#   BACKEND_CERTIFICATE_ARN   Optional backend ACM ARN override
#   SECURITY_GROUP_ID         Optional SG id override for HTTPS rule cleanup
#
# Example:
#   ./scripts/delete-aws-project.sh --domain moneyclip.com.br --project cost

set -euo pipefail

log() { printf '[delete-stack] %s\n' "$*"; }
log_progress() { printf '[progress] %-45s -> %s (%s)\n' "$1" "$2" "$3"; }

AWS_PROFILE="${AWS_PROFILE:-aws-cloudy}"
AWS_REGION="${AWS_REGION:-us-east-1}"
DEFAULT_STACK_SENTINEL="__DEFAULT_STACK_NAME__"
DEFAULT_CLUSTER_SENTINEL="__DEFAULT_ECS_CLUSTER__"
STACK_NAME="${STACK_NAME:-${DEFAULT_STACK_SENTINEL}}"
ECS_CLUSTER_NAME="${ECS_CLUSTER_NAME:-${DEFAULT_CLUSTER_SENTINEL}}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}"
DELETE_FRONTEND_BUCKET="${DELETE_FRONTEND_BUCKET:-false}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --domain <root-domain> --project <name>

Required arguments:
  --domain, -d    Root domain (e.g., sarres.com.br). Frontend/backend DNS resources under
                  this domain will be cleaned up in addition to the backend stack.
  --project, -p   Project prefix (alphanumeric + dashes). Used to derive stack, ECS,
                  DNS, and frontend resource names.

Environment overrides:
  STACK_NAME, ECS_CLUSTER_NAME, AWS_PROFILE, AWS_REGION, FRONTEND_HOSTED_ZONE_ID,
  FRONTEND_BUCKET_REGION, FRONTEND_CERT_REGION, BACKEND_CERT_REGION,
  DELETE_FRONTEND_BUCKET, FRONTEND_CERTIFICATE_ARN, BACKEND_CERTIFICATE_ARN,
  SECURITY_GROUP_ID.
USAGE
}

DOMAIN="${DOMAIN:-}"
PROJECT="${PROJECT:-}"

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain|-d)
        [[ -n "${2:-}" ]] || { log "Missing value for $1."; usage; exit 1; }
        DOMAIN="$2"
        shift 2
        ;;
      --project|-p)
        [[ -n "${2:-}" ]] || { log "Missing value for $1."; usage; exit 1; }
        PROJECT="$2"
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

[[ -n "${DOMAIN}" ]] || { log "DOMAIN parameter is required."; usage; exit 1; }
[[ -n "${PROJECT}" ]] || { log "PROJECT parameter is required."; usage; exit 1; }

DOMAIN_NORMALIZED="$(printf '%s' "${DOMAIN}" | tr '[:upper:]' '[:lower:]')"
DOMAIN_DNS_LABEL="$(printf '%s' "${DOMAIN_NORMALIZED}" | sed -E 's/[^a-z0-9.-]+/-/g' | sed -E 's/-+/-/g' | sed -E 's/^-+|-+$//g')"
[[ -n "${DOMAIN_DNS_LABEL}" ]] || { log "DOMAIN must contain at least one valid character."; exit 1; }
DOMAIN_PREFIX_SEGMENT="$(printf '%s' "${DOMAIN_DNS_LABEL}" | tr '.' '-' | sed -E 's/-+/-/g' | sed -E 's/^-+|-+$//g')"
[[ -n "${DOMAIN_PREFIX_SEGMENT}" ]] || { log "DOMAIN prefix segment is empty after normalization."; exit 1; }

PROJECT_PREFIX="$(printf '%s' "${PROJECT}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g' | sed -E 's/^-+|-+$//g')"
[[ -n "${PROJECT_PREFIX}" ]] || { log "PROJECT must contain at least one alphanumeric character."; exit 1; }

RESOURCE_PREFIX="${PROJECT_PREFIX}-${DOMAIN_PREFIX_SEGMENT}"
FRIENDLY_NAME_PREFIX="${PROJECT_PREFIX}-${DOMAIN_DNS_LABEL}"
log "Resource prefix set to '${RESOURCE_PREFIX}'."

short_hash() {
  local source="$1"
  python3 - "$source" <<'PY'
import hashlib, sys
print(hashlib.sha1(sys.argv[1].encode()).hexdigest())
PY
}

TARGET_GROUP_NAME_PREFIX="tg-$(short_hash "${RESOURCE_PREFIX}")"
TARGET_GROUP_NAME_PREFIX="${TARGET_GROUP_NAME_PREFIX:0:13}"

if [[ "${STACK_NAME}" == "${DEFAULT_STACK_SENTINEL}" ]]; then
  STACK_NAME="${RESOURCE_PREFIX}-cloud-formation"
fi
if [[ "${ECS_CLUSTER_NAME}" == "${DEFAULT_CLUSTER_SENTINEL}" ]]; then
  ECS_CLUSTER_NAME="${RESOURCE_PREFIX}-ecs-cluster"
fi

FRONTEND_ROOT_DOMAIN="${FRONTEND_ROOT_DOMAIN:-${DOMAIN_DNS_LABEL}}"
FRONTEND_DOMAIN="${FRONTEND_DOMAIN:-${PROJECT_PREFIX}.${FRONTEND_ROOT_DOMAIN}}"
FRONTEND_BUCKET="${FRONTEND_BUCKET:-${FRONTEND_DOMAIN}}"
FRONTEND_BUCKET_REGION="${FRONTEND_BUCKET_REGION:-${AWS_REGION}}"
FRONTEND_CERT_REGION="${FRONTEND_CERT_REGION:-us-east-1}"
FRONTEND_HOSTED_ZONE_ID="${FRONTEND_HOSTED_ZONE_ID:-}"
FRONTEND_DISTRIBUTION_ID="${FRONTEND_DISTRIBUTION_ID:-}"
BACKEND_DOMAIN="${BACKEND_DOMAIN:-api.${PROJECT_PREFIX}.${DOMAIN_DNS_LABEL}}"
BACKEND_CERT_REGION="${BACKEND_CERT_REGION:-${AWS_REGION}}"
BACKEND_HOSTED_ZONE_ID="${BACKEND_HOSTED_ZONE_ID:-}"
SECURITY_GROUP_ID="${SECURITY_GROUP_ID:-}"
FRONTEND_CERTIFICATE_ARN="${FRONTEND_CERTIFICATE_ARN:-}"
BACKEND_CERTIFICATE_ARN="${BACKEND_CERTIFICATE_ARN:-}"
RESOLVED_FRONTEND_CERT_ARN="${FRONTEND_CERTIFICATE_ARN}"
RESOLVED_BACKEND_CERT_ARN="${BACKEND_CERTIFICATE_ARN}"

aws_cli() {
  aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" "$@"
}

stack_parameter() {
  local key="$1"
  aws_cli cloudformation describe-stacks --stack-name "${STACK_NAME}" \
    --query "Stacks[0].Parameters[?ParameterKey=='${key}'].ParameterValue" \
    --output text 2>/dev/null || true
}

stack_output() {
  local key="$1"
  aws_cli cloudformation describe-stacks --stack-name "${STACK_NAME}" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
    --output text 2>/dev/null || true
}

stack_resource() {
  local logical_id="$1"
  aws_cli cloudformation describe-stack-resources --stack-name "${STACK_NAME}" \
    --logical-resource-id "${logical_id}" --query 'StackResources[0].PhysicalResourceId' \
    --output text 2>/dev/null || true
}

normalize_field() {
  local value="$1"
  if [[ -z "${value}" || "${value}" == "None" || "${value}" == "null" ]]; then
    echo ""
  else
    echo "${value}"
  fi
}

if [[ -z "${SECURITY_GROUP_ID}" || "${SECURITY_GROUP_ID}" == "None" ]]; then
  SECURITY_GROUP_ID="$(normalize_field "$(stack_parameter DefaultSecurityGroupId)")"
fi

if [[ -z "${ECS_CLUSTER_NAME}" || "${ECS_CLUSTER_NAME}" == "${DEFAULT_CLUSTER_SENTINEL}" ]]; then
  ECS_CLUSTER_NAME="$(normalize_field "$(stack_output ClusterName)")"
  [[ -n "${ECS_CLUSTER_NAME}" ]] || ECS_CLUSTER_NAME="${RESOURCE_PREFIX}-ecs-cluster"
fi

resolve_frontend_certificate_arn() {
  if [[ -n "${RESOLVED_FRONTEND_CERT_ARN}" && "${RESOLVED_FRONTEND_CERT_ARN}" != "None" ]]; then
    return 0
  fi
  local cert_arn
  cert_arn=$(aws --profile "${AWS_PROFILE}" --region "${FRONTEND_CERT_REGION}" acm list-certificates \
    --certificate-statuses ISSUED PENDING_VALIDATION INACTIVE EXPIRED VALIDATION_TIMED_OUT FAILED REVOKED \
    --query "CertificateSummaryList[?DomainName=='${FRONTEND_DOMAIN}'].CertificateArn | [0]" \
    --output text 2>/dev/null || echo "None")
  [[ -n "${cert_arn}" && "${cert_arn}" != "None" ]] || { RESOLVED_FRONTEND_CERT_ARN=""; return 1; }
  RESOLVED_FRONTEND_CERT_ARN="${cert_arn}"
}

resolve_backend_certificate_arn() {
  if [[ -n "${RESOLVED_BACKEND_CERT_ARN}" && "${RESOLVED_BACKEND_CERT_ARN}" != "None" ]]; then
    return 0
  fi
  local cert_arn
  cert_arn=$(aws --profile "${AWS_PROFILE}" --region "${BACKEND_CERT_REGION}" acm list-certificates \
    --certificate-statuses ISSUED PENDING_VALIDATION INACTIVE EXPIRED VALIDATION_TIMED_OUT FAILED REVOKED \
    --query "CertificateSummaryList[?DomainName=='${BACKEND_DOMAIN}'].CertificateArn | [0]" \
    --output text 2>/dev/null || echo "None")
  [[ -n "${cert_arn}" && "${cert_arn}" != "None" ]] || { RESOLVED_BACKEND_CERT_ARN=""; return 1; }
  RESOLVED_BACKEND_CERT_ARN="${cert_arn}"
}

LAST_EVENT_ID=""

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
    AWS::IAM::Role) echo "IAM role (${logical})" ;;
    AWS::IAM::InstanceProfile) echo "IAM instance profile (${logical})" ;;
    AWS::Logs::LogGroup) echo "CloudWatch Logs group (${logical})" ;;
    AWS::SecretsManager::Secret) echo "Secrets Manager secret (${logical})" ;;
    AWS::CloudFormation::Stack) echo "CloudFormation stack (${logical})" ;;
    *) echo "${type} (${logical})" ;;
  esac
}

set_event_cursor() {
  LAST_EVENT_ID=$(aws_cli cloudformation describe-stack-events --stack-name "${STACK_NAME}" \
    --max-items 1 --query 'StackEvents[0].EventId' --output text 2>/dev/null || true)
  [[ "${LAST_EVENT_ID}" != "None" ]] || LAST_EVENT_ID=""
}

emit_new_delete_events() {
  local output
  output=$(aws_cli cloudformation describe-stack-events --stack-name "${STACK_NAME}" \
    --query 'StackEvents[*].[EventId,Timestamp,LogicalResourceId,ResourceType,ResourceStatus]' \
    --output text 2>/dev/null || true)
  [[ -n "${output}" ]] || return 0

  local -a lines=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] && lines+=("${line}")
  done <<<"${output}"
  [[ ${#lines[@]} -gt 0 ]] || return 0

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
    LAST_EVENT_ID="${event_id:-${LAST_EVENT_ID}}"
    return 0
  fi

  local idx timestamp logical type status
  for (( idx=${#new_lines[@]}-1; idx>=0; idx-- )); do
    IFS=$'\t' read -r _ timestamp logical type status <<<"${new_lines[$idx]}"
    case "${status}" in
      DELETE_IN_PROGRESS) log_progress "$(resource_label "${type}" "${logical}")" "stopping" "${timestamp}" ;;
      DELETE_COMPLETE)    log_progress "$(resource_label "${type}" "${logical}")" "removed"  "${timestamp}" ;;
      DELETE_FAILED)      log_progress "$(resource_label "${type}" "${logical}")" "FAILED"   "${timestamp}" ;;
    esac
  done

  IFS=$'\t' read -r LAST_EVENT_ID _ <<<"${lines[0]}"
}

stack_status() {
  aws_cli cloudformation describe-stacks --stack-name "${STACK_NAME}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "STACK_NOT_FOUND"
}

wait_for_delete_with_progress() {
  while true; do
    emit_new_delete_events || true
    local status
    status=$(stack_status)
    case "${status}" in
      DELETE_COMPLETE|STACK_NOT_FOUND) return 0 ;;
      DELETE_FAILED) return 1 ;;
    esac
    sleep "${POLL_INTERVAL_SECONDS}"
  done
}

delete_stack() {
  log "Deleting stack ${STACK_NAME} in ${AWS_REGION}..."
  aws_cli cloudformation delete-stack --stack-name "${STACK_NAME}"
}

wait_for_ecs_service_gone() {
  local cluster="$1" service="$2"
  local attempts=0 max_attempts=60
  while (( attempts < max_attempts )); do
    local status
    status=$(aws_cli ecs describe-services --cluster "${cluster}" --services "${service}" \
      --query 'services[0].status' --output text 2>/dev/null || echo "MISSING")
    if [[ "${status}" == "MISSING" || "${status}" == "INACTIVE" || "${status}" == "None" ]]; then
      return 0
    fi
    sleep 5
    attempts=$((attempts + 1))
  done
  return 1
}

attempt_cluster_cleanup() {
  log "Attempting to delete ECS cluster ${ECS_CLUSTER_NAME} before retry..."
  local cluster_status
  cluster_status=$(aws_cli ecs describe-clusters --clusters "${ECS_CLUSTER_NAME}" \
    --query 'clusters[0].status' --output text 2>/dev/null || echo "MISSING")

  if [[ "${cluster_status}" == "MISSING" || "${cluster_status}" == "None" ]]; then
    log "ECS cluster ${ECS_CLUSTER_NAME} not found; nothing to remove."
    return 0
  fi

  local service_arns service_arn service_name
  service_arns=$(aws_cli ecs list-services --cluster "${ECS_CLUSTER_NAME}" --query 'serviceArns' --output text 2>/dev/null || echo "")
  for service_arn in ${service_arns}; do
    [[ -n "${service_arn}" && "${service_arn}" != "None" ]] || continue
    service_name="${service_arn##*/}"
    log "Force-deleting ECS service ${service_name} from cluster ${ECS_CLUSTER_NAME}."
    aws_cli ecs update-service --cluster "${ECS_CLUSTER_NAME}" --service "${service_name}" --desired-count 0 >/dev/null 2>&1 || true
    aws_cli ecs delete-service --cluster "${ECS_CLUSTER_NAME}" --service "${service_name}" --force >/dev/null 2>&1 || true
    wait_for_ecs_service_gone "${ECS_CLUSTER_NAME}" "${service_name}" || true
  done

  local container_arns container_arn
  container_arns=$(aws_cli ecs list-container-instances --cluster "${ECS_CLUSTER_NAME}" --query 'containerInstanceArns' --output text 2>/dev/null || echo "")
  for container_arn in ${container_arns}; do
    [[ -n "${container_arn}" && "${container_arn}" != "None" ]] || continue
    log "Deregistering ECS container instance ${container_arn}."
    aws_cli ecs deregister-container-instance --cluster "${ECS_CLUSTER_NAME}" --container-instance "${container_arn}" --force >/dev/null 2>&1 || true
  done

  aws_cli ecs delete-cluster --cluster "${ECS_CLUSTER_NAME}" >/dev/null 2>&1 || true
  log "Delete request sent for ECS cluster ${ECS_CLUSTER_NAME}."
}

find_frontend_hosted_zone() {
  if [[ -n "${FRONTEND_HOSTED_ZONE_ID}" ]]; then
    FRONTEND_HOSTED_ZONE_ID="${FRONTEND_HOSTED_ZONE_ID#/hostedzone/}"
    return 0
  fi
  local zone_name="${FRONTEND_ROOT_DOMAIN%.}."
  local lookup zone_id zone_value
  lookup=$(aws --profile "${AWS_PROFILE}" route53 list-hosted-zones-by-name \
    --dns-name "${zone_name}" --max-items 1 \
    --query "HostedZones[0].[Id,Name]" --output text 2>/dev/null || echo "")
  read -r zone_id zone_value <<<"${lookup}"
  if [[ -n "${zone_id}" && "${zone_id}" != "None" && "${zone_value}" == "${zone_name}" ]]; then
    FRONTEND_HOSTED_ZONE_ID="${zone_id#/hostedzone/}"
    return 0
  fi
  log "Route 53 hosted zone for ${FRONTEND_ROOT_DOMAIN} not found; skipping DNS cleanup."
  return 1
}

delete_route53_alias_records_for_name() {
  local zone_id="$1" dns_name="$2" label="$3"
  local record_types=("A" "AAAA")
  local removed_any="false"
  local record_type record_json record_file change_file

  for record_type in "${record_types[@]}"; do
    record_json=$(aws --profile "${AWS_PROFILE}" route53 list-resource-record-sets \
      --hosted-zone-id "${zone_id}" \
      --query "ResourceRecordSets[?Type=='${record_type}' && Name=='${dns_name}.'] | [0]" \
      --output json 2>/dev/null || echo "null")
    [[ -n "${record_json}" && "${record_json}" != "null" ]] || continue

    record_file=$(mktemp)
    change_file=$(mktemp)
    printf '%s' "${record_json}" > "${record_file}"
    python3 - "${record_file}" "${change_file}" "${dns_name}" "${record_type}" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
change = {
    "Comment": f"Delete {sys.argv[4]} alias for {sys.argv[3]}",
    "Changes": [{"Action": "DELETE", "ResourceRecordSet": record}]
}
json.dump(change, open(sys.argv[2], 'w'))
PY
    if aws --profile "${AWS_PROFILE}" route53 change-resource-record-sets \
      --hosted-zone-id "${zone_id}" --change-batch file://"${change_file}" >/dev/null; then
      log "Deleted Route 53 ${record_type} alias for ${label}."
      removed_any="true"
    else
      log "Failed to delete Route 53 ${record_type} alias for ${label}."
    fi
    rm -f "${record_file}" "${change_file}"
  done

  [[ "${removed_any}" == "true" ]] || log "No Route 53 aliases found for ${label}; skipping."
}

delete_route53_alias_record() {
  find_frontend_hosted_zone || return 0
  delete_route53_alias_records_for_name "${FRONTEND_HOSTED_ZONE_ID}" "${FRONTEND_DOMAIN}" "${FRONTEND_DOMAIN}"
}

delete_backend_route53_alias_record() {
  local zone_id="${BACKEND_HOSTED_ZONE_ID:-${FRONTEND_HOSTED_ZONE_ID}}"
  if [[ -z "${zone_id}" ]]; then
    find_frontend_hosted_zone || return 0
    zone_id="${FRONTEND_HOSTED_ZONE_ID}"
  fi
  BACKEND_HOSTED_ZONE_ID="${zone_id}"
  delete_route53_alias_records_for_name "${zone_id}" "${BACKEND_DOMAIN}" "${BACKEND_DOMAIN}"
}

delete_acm_validation_records() {
  find_frontend_hosted_zone || return 0
  local records_json records_file change_file
  records_json=$(aws --profile "${AWS_PROFILE}" route53 list-resource-record-sets \
    --hosted-zone-id "${FRONTEND_HOSTED_ZONE_ID}" \
    --query "ResourceRecordSets[?Type=='CNAME' && starts_with(Name, '_') && contains(ResourceRecords[0].Value, 'acm-validations.aws')]" \
    --output json 2>/dev/null || echo "[]")
  if [[ "${records_json}" == "[]" ]]; then
    log "No ACM validation CNAME records found in hosted zone ${FRONTEND_ROOT_DOMAIN}; skipping."
    return 0
  fi
  records_file=$(mktemp)
  change_file=$(mktemp)
  printf '%s' "${records_json}" > "${records_file}"
  python3 - "${records_file}" "${change_file}" <<'PY'
import json, sys
records = json.load(open(sys.argv[1]))
change = {
    "Comment": "Delete ACM validation CNAME records",
    "Changes": [{"Action": "DELETE", "ResourceRecordSet": record} for record in records]
}
json.dump(change, open(sys.argv[2], 'w'))
PY
  if aws --profile "${AWS_PROFILE}" route53 change-resource-record-sets \
    --hosted-zone-id "${FRONTEND_HOSTED_ZONE_ID}" --change-batch file://"${change_file}" >/dev/null; then
    log "Deleted ACM validation CNAME records from hosted zone ${FRONTEND_ROOT_DOMAIN}."
  else
    log "Failed to delete one or more ACM validation CNAME records."
  fi
  rm -f "${records_file}" "${change_file}"
}

empty_bucket_versions() {
  local bucket="$1" region="$2"
  local key_marker="" version_marker=""
  while true; do
    local cmd=(aws --profile "${AWS_PROFILE}" --region "${region}" s3api list-object-versions --bucket "${bucket}")
    [[ -n "${key_marker}" ]] && cmd+=(--key-marker "${key_marker}")
    [[ -n "${version_marker}" ]] && cmd+=(--version-id-marker "${version_marker}")

    local list_output list_file delete_file parser_output truncated next_key next_version
    list_output=$("${cmd[@]}" --output json 2>/dev/null || echo "")
    [[ -n "${list_output}" ]] || return 1
    list_file=$(mktemp)
    delete_file=$(mktemp)
    printf '%s' "${list_output}" > "${list_file}"
    parser_output=$(python3 - "${list_file}" "${delete_file}" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
objects = []
for entry in data.get("Versions") or []:
    if entry.get("Key") and entry.get("VersionId"):
        objects.append({"Key": entry["Key"], "VersionId": entry["VersionId"]})
for entry in data.get("DeleteMarkers") or []:
    if entry.get("Key") and entry.get("VersionId"):
        objects.append({"Key": entry["Key"], "VersionId": entry["VersionId"]})
if objects:
    json.dump({"Objects": objects, "Quiet": False}, open(sys.argv[2], 'w'))
else:
    open(sys.argv[2], 'w').write('')
print('1' if data.get('IsTruncated') else '0')
print(data.get('NextKeyMarker') or '')
print(data.get('NextVersionIdMarker') or '')
PY
)
    rm -f "${list_file}"
    IFS=$'\n' read -r truncated next_key next_version <<<"${parser_output}"
    if [[ -s "${delete_file}" ]]; then
      aws --profile "${AWS_PROFILE}" --region "${region}" s3api delete-objects \
        --bucket "${bucket}" --delete file://"${delete_file}" >/dev/null 2>&1 || true
    fi
    rm -f "${delete_file}"
    [[ "${truncated}" == "1" ]] || break
    key_marker="${next_key}"
    version_marker="${next_version}"
  done
}

empty_s3_bucket() {
  local bucket="$1" region="$2"
  log "Removing objects from s3://${bucket}..."
  aws --profile "${AWS_PROFILE}" --region "${region}" s3 rm "s3://${bucket}" --recursive >/dev/null 2>&1 || true
  local versioning_status
  versioning_status=$(aws --profile "${AWS_PROFILE}" --region "${region}" s3api get-bucket-versioning \
    --bucket "${bucket}" --query 'Status' --output text 2>/dev/null || echo "")
  if [[ "${versioning_status}" == "Enabled" || "${versioning_status}" == "Suspended" ]]; then
    log "Bucket s3://${bucket} has versioning ${versioning_status}; purging all versions..."
    empty_bucket_versions "${bucket}" "${region}" || true
  fi
}

delete_frontend_bucket() {
  [[ -n "${FRONTEND_BUCKET}" ]] || { log "FRONTEND_BUCKET is empty; skipping bucket deletion."; return 0; }
  if ! aws --profile "${AWS_PROFILE}" --region "${FRONTEND_BUCKET_REGION}" s3api head-bucket --bucket "${FRONTEND_BUCKET}" >/dev/null 2>&1; then
    log "Bucket s3://${FRONTEND_BUCKET} not found; nothing to clean up."
    return 0
  fi
  empty_s3_bucket "${FRONTEND_BUCKET}" "${FRONTEND_BUCKET_REGION}"
  log "Deleting bucket s3://${FRONTEND_BUCKET}..."
  aws --profile "${AWS_PROFILE}" --region "${FRONTEND_BUCKET_REGION}" s3api delete-bucket --bucket "${FRONTEND_BUCKET}" >/dev/null 2>&1 \
    && log "Deleted frontend bucket s3://${FRONTEND_BUCKET}." \
    || log "Failed to delete frontend bucket s3://${FRONTEND_BUCKET}; manual cleanup may be required."
}

create_cloudfront_invalidation() {
  local distribution_id="$1"
  [[ -n "${distribution_id}" && "${distribution_id}" != "None" ]] || return 0
  local invalidation_id
  invalidation_id=$(aws --profile "${AWS_PROFILE}" cloudfront create-invalidation \
    --distribution-id "${distribution_id}" --paths '/*' \
    --query 'Invalidation.Id' --output text 2>/dev/null || echo "")
  [[ -n "${invalidation_id}" && "${invalidation_id}" != "None" ]] || { log "Failed to request CloudFront invalidation for distribution ${distribution_id}."; return 1; }
  log "Requested CloudFront invalidation ${invalidation_id} for distribution ${distribution_id}."
  aws --profile "${AWS_PROFILE}" cloudfront wait invalidation-completed --distribution-id "${distribution_id}" --id "${invalidation_id}" >/dev/null 2>&1 || true
}

delete_cloudfront_distribution() {
  resolve_frontend_certificate_arn || true
  local distributions_json distributions_file distribution_ids parser_status
  distributions_json=$(aws --profile "${AWS_PROFILE}" cloudfront list-distributions --output json 2>/dev/null || echo "")
  [[ -n "${distributions_json}" ]] || { log "Failed to list CloudFront distributions; skipping frontend distribution cleanup."; return 0; }

  distributions_file=$(mktemp)
  printf '%s' "${distributions_json}" > "${distributions_file}"
  parser_status=0
  distribution_ids=$(python3 - "${FRONTEND_DOMAIN}" "${RESOLVED_FRONTEND_CERT_ARN:-}" "${distributions_file}" <<'PY'
import json, sys

domain = sys.argv[1]
cert = sys.argv[2] if sys.argv[2] not in ('', 'None') else ''
with open(sys.argv[3]) as fh:
    data = json.load(fh)
items = (data.get('DistributionList') or {}).get('Items') or []
matches = []
for item in items:
    aliases = (item.get('Aliases') or {}).get('Items') or []
    viewer_cert = item.get('ViewerCertificate') or {}
    if (domain and domain in aliases) or (cert and viewer_cert.get('ACMCertificateArn') == cert):
        matches.append(item['Id'])
print('\n'.join(matches))
PY
) || parser_status=$?
  rm -f "${distributions_file}"
  [[ ${parser_status} -eq 0 ]] || { log "Failed to parse CloudFront distribution list; skipping frontend distribution cleanup."; return 0; }
  [[ -n "${distribution_ids}" ]] || { log "No CloudFront distribution found for ${FRONTEND_DOMAIN}; skipping."; return 0; }

  local distribution_id config_dump mutated_config etag delete_etag
  while IFS= read -r distribution_id; do
    [[ -n "${distribution_id}" ]] || continue
    FRONTEND_DISTRIBUTION_ID="${distribution_id}"
    create_cloudfront_invalidation "${distribution_id}" || true
    log "Disabling CloudFront distribution ${distribution_id}..."
    config_dump=$(mktemp)
    mutated_config=$(mktemp)
    if ! aws --profile "${AWS_PROFILE}" cloudfront get-distribution-config --id "${distribution_id}" > "${config_dump}"; then
      log "Failed to fetch distribution config for ${distribution_id}."
      rm -f "${config_dump}" "${mutated_config}"
      continue
    fi
    etag=$(python3 - "${config_dump}" "${mutated_config}" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1]))
config = payload['DistributionConfig']
config['Enabled'] = False
aliases = config.get('Aliases')
if aliases:
    aliases['Items'] = []
    aliases['Quantity'] = 0
json.dump(config, open(sys.argv[2], 'w'))
print(payload['ETag'])
PY
)
    if [[ -z "${etag}" ]]; then
      log "Could not determine ETag for distribution ${distribution_id}."
      rm -f "${config_dump}" "${mutated_config}"
      continue
    fi
    aws --profile "${AWS_PROFILE}" cloudfront update-distribution --id "${distribution_id}" --if-match "${etag}" \
      --distribution-config file://"${mutated_config}" >/dev/null 2>&1 || { log "Failed to disable CloudFront distribution ${distribution_id}."; rm -f "${config_dump}" "${mutated_config}"; continue; }
    aws --profile "${AWS_PROFILE}" cloudfront wait distribution-deployed --id "${distribution_id}" >/dev/null 2>&1 || true
    delete_etag=$(aws --profile "${AWS_PROFILE}" cloudfront get-distribution-config --id "${distribution_id}" --query 'ETag' --output text 2>/dev/null || echo "")
    if [[ -z "${delete_etag}" || "${delete_etag}" == "None" ]]; then
      log "Failed to fetch delete ETag for distribution ${distribution_id}."
      rm -f "${config_dump}" "${mutated_config}"
      continue
    fi
    aws --profile "${AWS_PROFILE}" cloudfront delete-distribution --id "${distribution_id}" --if-match "${delete_etag}" >/dev/null 2>&1 \
      && log "Deleted CloudFront distribution ${distribution_id}." \
      || log "Failed to delete CloudFront distribution ${distribution_id}."
    rm -f "${config_dump}" "${mutated_config}"
  done <<<"${distribution_ids}"
}

delete_acm_certificate() {
  resolve_frontend_certificate_arn || { log "No ACM certificate found for ${FRONTEND_DOMAIN}; skipping."; return 0; }
  local cert_arn="${RESOLVED_FRONTEND_CERT_ARN}"
  log "Deleting ACM certificate ${cert_arn} (${FRONTEND_DOMAIN})..."
  aws --profile "${AWS_PROFILE}" --region "${FRONTEND_CERT_REGION}" acm delete-certificate --certificate-arn "${cert_arn}" >/dev/null 2>&1 \
    && { log "Deleted ACM certificate ${cert_arn}."; RESOLVED_FRONTEND_CERT_ARN=""; } \
    || log "Failed to delete ACM certificate ${cert_arn}."
}

delete_backend_acm_certificate() {
  resolve_backend_certificate_arn || { log "No backend ACM certificate found for ${BACKEND_DOMAIN}; skipping."; return 0; }
  local cert_arn="${RESOLVED_BACKEND_CERT_ARN}"
  log "Deleting backend ACM certificate ${cert_arn} (${BACKEND_DOMAIN})..."
  aws --profile "${AWS_PROFILE}" --region "${BACKEND_CERT_REGION}" acm delete-certificate --certificate-arn "${cert_arn}" >/dev/null 2>&1 \
    && { log "Deleted backend ACM certificate ${cert_arn}."; RESOLVED_BACKEND_CERT_ARN=""; } \
    || log "Failed to delete backend ACM certificate ${cert_arn}."
}

describe_target_group_by_name() {
  local tg_name="$1"
  aws_cli elbv2 describe-target-groups --names "${tg_name}" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo ""
}

reset_listener_to_single_target() {
  local listener_arn="$1" target_group_arn="$2"
  [[ -n "${listener_arn}" && "${listener_arn}" != "None" && -n "${target_group_arn}" && "${target_group_arn}" != "None" ]] || return 0
  local config_file
  config_file=$(mktemp)
  cat <<JSON > "${config_file}"
[
  {
    "Type": "forward",
    "ForwardConfig": {
      "TargetGroups": [
        {"TargetGroupArn": "${target_group_arn}", "Weight": 1}
      ]
    }
  }
]
JSON
  aws_cli elbv2 modify-listener --listener-arn "${listener_arn}" --default-actions file://"${config_file}" >/dev/null 2>&1 || true
  rm -f "${config_file}"
}

cleanup_additional_ecs_services() {
  local cluster_name="${ECS_CLUSTER_NAME:-${RESOURCE_PREFIX}-ecs-cluster}"
  local service_prefix="${RESOURCE_PREFIX}-ecs-service-"
  local service_arns service_arn service_name suffix
  service_arns=$(aws_cli ecs list-services --cluster "${cluster_name}" --output text --query 'serviceArns' 2>/dev/null || echo "")
  [[ -n "${service_arns}" && "${service_arns}" != "None" ]] || return 0

  local -a extra_suffixes=()
  for service_arn in ${service_arns}; do
    [[ -n "${service_arn}" && "${service_arn}" != "None" ]] || continue
    service_name="${service_arn##*/}"
    if [[ "${service_name}" == ${service_prefix}* ]]; then
      suffix="${service_name#${service_prefix}}"
      if [[ "${suffix}" =~ ^[0-9]{2}$ && "${suffix}" != "01" ]]; then
        log "Deleting ECS service ${service_name} prior to stack removal."
        aws_cli ecs update-service --cluster "${cluster_name}" --service "${service_name}" --desired-count 0 >/dev/null 2>&1 || true
        aws_cli ecs delete-service --cluster "${cluster_name}" --service "${service_name}" --force >/dev/null 2>&1 || true
        wait_for_ecs_service_gone "${cluster_name}" "${service_name}" || true
        extra_suffixes+=("${suffix}")
      fi
    fi
  done

  [[ ${#extra_suffixes[@]} -gt 0 ]] || return 0

  local listener_arn base_target_group_arn suffix tg_name tg_arn
  listener_arn=$(stack_resource ProjectListener || true)
  base_target_group_arn=$(stack_resource SarrescostTargetGroup || true)
  reset_listener_to_single_target "${listener_arn}" "${base_target_group_arn}"

  for suffix in "${extra_suffixes[@]}"; do
    tg_name="${TARGET_GROUP_NAME_PREFIX}-${suffix}"
    tg_arn=$(describe_target_group_by_name "${tg_name}")
    if [[ -n "${tg_arn}" && "${tg_arn}" != "None" ]]; then
      log "Deleting target group ${tg_name} (${tg_arn})."
      aws_cli elbv2 delete-target-group --target-group-arn "${tg_arn}" >/dev/null 2>&1 || true
    fi
  done
}

remove_https_rule_from_security_group() {
  [[ -n "${SECURITY_GROUP_ID}" ]] || { log "Security group ID unknown; skipping HTTPS rule cleanup."; return 0; }
  local rule
  rule=$(aws_cli ec2 describe-security-groups --group-ids "${SECURITY_GROUP_ID}" \
    --query "SecurityGroups[0].IpPermissions[?IpProtocol=='tcp' && FromPort==\`443\` && ToPort==\`443\`]" \
    --output text 2>/dev/null || echo "")
  if [[ -z "${rule}" || "${rule}" == "None" ]]; then
    log "No TCP/443 ingress rule found on ${SECURITY_GROUP_ID}; skipping."
    return 0
  fi
  log "Revoking TCP/443 ingress rule from security group ${SECURITY_GROUP_ID}."
  aws_cli ec2 revoke-security-group-ingress --group-id "${SECURITY_GROUP_ID}" \
    --ip-permissions '[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0","Description":"ECS sarrescost ALB HTTPS"}]}]' >/dev/null 2>&1 \
    && log "Removed TCP/443 ingress from ${SECURITY_GROUP_ID}." \
    || log "Failed to revoke TCP/443 ingress from ${SECURITY_GROUP_ID}."
}

cleanup_frontend_resources() {
  log "----- Frontend teardown for ${FRONTEND_DOMAIN} -----"
  delete_cloudfront_distribution || true
  if [[ "${DELETE_FRONTEND_BUCKET}" == "true" ]]; then
    delete_frontend_bucket || true
  else
    log "Preserving frontend bucket s3://${FRONTEND_BUCKET}; DELETE_FRONTEND_BUCKET=false."
  fi
  delete_route53_alias_record || true
  delete_acm_validation_records || true
  delete_acm_certificate || true
}

cleanup_backend_resources() {
  log "----- Backend teardown for ${BACKEND_DOMAIN} -----"
  delete_backend_route53_alias_record || true
  delete_backend_acm_certificate || true
  remove_https_rule_from_security_group || true
}

cleanup_additional_ecs_services || true

set_event_cursor
delete_stack

if wait_for_delete_with_progress; then
  log "Stack ${STACK_NAME} deleted successfully."
  cleanup_frontend_resources
  cleanup_backend_resources
  exit 0
fi

log "Initial delete failed. Investigating dependencies..."
attempt_cluster_cleanup

log "Retrying stack deletion..."
set_event_cursor
delete_stack

if wait_for_delete_with_progress; then
  log "Stack ${STACK_NAME} deleted after dependency cleanup."
  cleanup_frontend_resources
  cleanup_backend_resources
else
  log "Stack ${STACK_NAME} still failed to delete. Manual intervention required."
  exit 1
fi
