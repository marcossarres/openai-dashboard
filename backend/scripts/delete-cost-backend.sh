#!/usr/bin/env bash
# Delete the cost-backend CloudFormation stack with per-service progress output.
# Automatically retries once by deleting the ECS cluster if the stack
# fails due to a lingering cluster resource.
#
# Environment variables (override as needed):
#   AWS_PROFILE             AWS CLI profile (default: aws-cloudy)
#   AWS_REGION              Region (default: us-east-1)
#   STACK_NAME              Stack name to delete (default: cost-backend-formation)
#   ECS_CLUSTER_NAME        ECS cluster name to delete if stack removal fails
#                           because the cluster still exists (default: sarrescost-cluster)
#   POLL_INTERVAL_SECONDS   Seconds between progress polls (default: 10)
#
# Example:
#   STACK_NAME=cost-backend-formation ./scripts/delete-cost-backend.sh

set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-aws-cloudy}"
AWS_REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-cost-backend-formation}"
ECS_CLUSTER_NAME="${ECS_CLUSTER_NAME:-sarrescost-cluster}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --domain <root-domain>

Required arguments:
  --domain, -d    Root domain (e.g., sarres.com.br). Frontend assets deployed at costly.<root-domain>
                  will be cleaned up in addition to the backend stack.

Environment overrides:
  STACK_NAME, ECS_CLUSTER_NAME, AWS_PROFILE, AWS_REGION, FRONTEND_HOSTED_ZONE_ID,
  FRONTEND_BUCKET_REGION, FRONTEND_CERT_REGION.
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

log() { printf '[delete-stack] %s\n' "$*"; }
log_progress() { printf '[progress] %-45s -> %s (%s)\n' "$1" "$2" "$3"; }

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
FRONTEND_CERT_REGION="${FRONTEND_CERT_REGION:-us-east-1}"
FRONTEND_HOSTED_ZONE_ID="${FRONTEND_HOSTED_ZONE_ID:-}"
FRONTEND_DISTRIBUTION_ID="${FRONTEND_DISTRIBUTION_ID:-}"
BACKEND_DOMAIN="${BACKEND_DOMAIN:-api.${DOMAIN}}"
BACKEND_CERT_REGION="${BACKEND_CERT_REGION:-${AWS_REGION}}"
BACKEND_HOSTED_ZONE_ID="${BACKEND_HOSTED_ZONE_ID:-}"
SECURITY_GROUP_ID="${SECURITY_GROUP_ID:-}"

if [[ -z "${SECURITY_GROUP_ID}" || "${SECURITY_GROUP_ID}" == "None" ]]; then
  SECURITY_GROUP_ID="$(stack_parameter DefaultSecurityGroupId || true)"
  if [[ "${SECURITY_GROUP_ID}" == "None" ]]; then
    SECURITY_GROUP_ID=""
  fi
fi

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

stack_parameter() {
  local key="$1"
  aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
    cloudformation describe-stacks --stack-name "${STACK_NAME}" \
    --query "Stacks[0].Parameters[?ParameterKey=='${key}'].ParameterValue" \
    --output text 2>/dev/null
}

set_event_cursor() {
  LAST_EVENT_ID=$(aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
    cloudformation describe-stack-events --stack-name "${STACK_NAME}" \
    --max-items 1 --query 'StackEvents[0].EventId' --output text 2>/dev/null || true)
  if [[ "${LAST_EVENT_ID}" == "None" ]]; then
    LAST_EVENT_ID=""
  fi
}

emit_new_delete_events() {
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
    LAST_EVENT_ID="${event_id:-${LAST_EVENT_ID}}"
    return
  fi

  local idx
  for (( idx=${#new_lines[@]}-1; idx>=0; idx-- )); do
    IFS=$'\t' read -r event_id timestamp logical type status <<<"${new_lines[$idx]}"
    case "${status}" in
      DELETE_IN_PROGRESS)
        log_progress "$(resource_label "${type}" "${logical}")" "stopping" "${timestamp}"
        ;;
      DELETE_COMPLETE)
        log_progress "$(resource_label "${type}" "${logical}")" "removed" "${timestamp}"
        ;;
      DELETE_FAILED)
        log_progress "$(resource_label "${type}" "${logical}")" "FAILED" "${timestamp}"
        ;;
      *)
        continue
        ;;
    esac
  done

  IFS=$'\t' read -r LAST_EVENT_ID _ <<<"${lines[0]}"
}

stack_status() {
  aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
    cloudformation describe-stacks --stack-name "${STACK_NAME}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "STACK_NOT_FOUND"
}

wait_for_delete_with_progress() {
  while true; do
    emit_new_delete_events || true
    local status
    status=$(stack_status)

    case "${status}" in
      DELETE_COMPLETE|STACK_NOT_FOUND)
        return 0
        ;;
      DELETE_FAILED)
        return 1
        ;;
    esac

    sleep "${POLL_INTERVAL_SECONDS}"
  done
}

delete_stack() {
  log "Deleting stack ${STACK_NAME} in ${AWS_REGION}..."
  aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
    cloudformation delete-stack --stack-name "${STACK_NAME}"
}

attempt_cluster_cleanup() {
  log "Attempting to delete ECS cluster ${ECS_CLUSTER_NAME} before retry..."
  local cluster_status
  cluster_status=$(aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" ecs describe-clusters \
    --clusters "${ECS_CLUSTER_NAME}" --query 'clusters[0].status' --output text 2>/dev/null || echo "MISSING")

  if [[ "${cluster_status}" == "MISSING" || "${cluster_status}" == "None" ]]; then
    log "ECS cluster ${ECS_CLUSTER_NAME} not found; nothing to remove."
    return
  fi

  aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" ecs delete-cluster \
    --cluster "${ECS_CLUSTER_NAME}" >/dev/null
  log "Deleted ECS cluster ${ECS_CLUSTER_NAME}."
}

find_frontend_hosted_zone() {
  if [[ -n "${FRONTEND_HOSTED_ZONE_ID}" ]]; then
    FRONTEND_HOSTED_ZONE_ID="${FRONTEND_HOSTED_ZONE_ID#/hostedzone/}"
    return 0
  fi
  local zone_name="${FRONTEND_ROOT_DOMAIN%.}."
  local lookup
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

delete_route53_alias_record() {
  if ! find_frontend_hosted_zone; then
    return 0
  fi
  local record_types=("A" "AAAA")
  local removed_any="false"
  for record_type in "${record_types[@]}"; do
    local record_json
    record_json=$(aws --profile "${AWS_PROFILE}" route53 list-resource-record-sets \
      --hosted-zone-id "${FRONTEND_HOSTED_ZONE_ID}" \
      --query "ResourceRecordSets[?Type=='${record_type}' && Name=='${FRONTEND_DOMAIN}.'] | [0]" \
      --output json 2>/dev/null || echo "null")
    if [[ -z "${record_json}" || "${record_json}" == "null" ]]; then
      continue
    fi
    local record_file change_file
    record_file=$(mktemp)
    change_file=$(mktemp)
    printf '%s' "${record_json}" > "${record_file}"
    python3 - "$record_file" "$change_file" "${FRONTEND_DOMAIN}" "${record_type}" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
change = {
    "Comment": f"Delete {sys.argv[4]} alias for {sys.argv[3]}",
    "Changes": [{
        "Action": "DELETE",
        "ResourceRecordSet": record
    }]
}
json.dump(change, open(sys.argv[2], 'w'))
PY
    if aws --profile "${AWS_PROFILE}" route53 change-resource-record-sets \
      --hosted-zone-id "${FRONTEND_HOSTED_ZONE_ID}" \
      --change-batch file://"${change_file}" >/dev/null; then
      log "Deleted Route 53 ${record_type} alias record for ${FRONTEND_DOMAIN}."
      removed_any="true"
    else
      log "Failed to delete Route 53 ${record_type} alias record for ${FRONTEND_DOMAIN}."
    fi
    rm -f "${record_file}" "${change_file}"
  done
  if [[ "${removed_any}" != "true" ]]; then
    log "No Route 53 CloudFront aliases found for ${FRONTEND_DOMAIN}; skipping."
  fi
}

delete_backend_route53_alias_record() {
  local zone_id="${BACKEND_HOSTED_ZONE_ID:-${FRONTEND_HOSTED_ZONE_ID}}"
  if [[ -z "${zone_id}" ]]; then
    if ! find_frontend_hosted_zone; then
      return 0
    fi
    zone_id="${FRONTEND_HOSTED_ZONE_ID}"
  fi
  BACKEND_HOSTED_ZONE_ID="${zone_id}"
  local record_types=("A" "AAAA")
  local removed_any="false"
  for record_type in "${record_types[@]}"; do
    local record_json
    record_json=$(aws --profile "${AWS_PROFILE}" route53 list-resource-record-sets \
      --hosted-zone-id "${zone_id}" \
      --query "ResourceRecordSets[?Type=='${record_type}' && Name=='${BACKEND_DOMAIN}.'] | [0]" \
      --output json 2>/dev/null || echo "null")
    if [[ -z "${record_json}" || "${record_json}" == "null" ]]; then
      continue
    fi
    local record_file change_file
    record_file=$(mktemp)
    change_file=$(mktemp)
    printf '%s' "${record_json}" > "${record_file}"
    python3 - "$record_file" "$change_file" "${BACKEND_DOMAIN}" "${record_type}" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
change = {
    "Comment": f"Delete backend alias {sys.argv[3]}",
    "Changes": [{
        "Action": "DELETE",
        "ResourceRecordSet": record
    }]
}
json.dump(change, open(sys.argv[2], 'w'))
PY
    if aws --profile "${AWS_PROFILE}" route53 change-resource-record-sets \
      --hosted-zone-id "${zone_id}" \
      --change-batch file://"${change_file}" >/dev/null; then
      log "Deleted backend Route 53 ${record_type} alias for ${BACKEND_DOMAIN}."
      removed_any="true"
    else
      log "Failed to delete backend Route 53 ${record_type} alias for ${BACKEND_DOMAIN}."
    fi
    rm -f "${record_file}" "${change_file}"
  done
  if [[ "${removed_any}" != "true" ]]; then
    log "No backend Route 53 aliases found for ${BACKEND_DOMAIN}; skipping."
  fi
}

delete_acm_validation_records() {
  if ! find_frontend_hosted_zone; then
    return 0
  fi
  local records_json
  records_json=$(aws --profile "${AWS_PROFILE}" route53 list-resource-record-sets \
    --hosted-zone-id "${FRONTEND_HOSTED_ZONE_ID}" \
    --query "ResourceRecordSets[?Type=='CNAME' && starts_with(Name, '_') && contains(ResourceRecords[0].Value, 'acm-validations.aws') && contains(Name, '${FRONTEND_DOMAIN}.')]" \
    --output json 2>/dev/null || echo "[]")
  if [[ "${records_json}" == "[]" ]]; then
    log "No ACM validation CNAME records found for ${FRONTEND_DOMAIN}; skipping."
    return 0
  fi
  local records_file change_file
  records_file=$(mktemp)
  change_file=$(mktemp)
  printf '%s' "${records_json}" > "${records_file}"
  python3 - "$records_file" "$change_file" <<'PY'
import json, sys
records = json.load(open(sys.argv[1]))
change = {
    "Comment": "Delete ACM validation CNAME records",
    "Changes": [{"Action": "DELETE", "ResourceRecordSet": record} for record in records]
}
json.dump(change, open(sys.argv[2], 'w'))
PY
  if aws --profile "${AWS_PROFILE}" route53 change-resource-record-sets \
    --hosted-zone-id "${FRONTEND_HOSTED_ZONE_ID}" \
    --change-batch file://"${change_file}" >/dev/null; then
    log "Deleted ACM validation CNAME records for ${FRONTEND_DOMAIN}."
  else
    log "Failed to delete ACM validation CNAME records for ${FRONTEND_DOMAIN}."
  fi
  rm -f "${records_file}" "${change_file}"
}

delete_frontend_bucket() {
  log "Checking frontend bucket s3://${FRONTEND_BUCKET}..."
  if aws --profile "${AWS_PROFILE}" --region "${FRONTEND_BUCKET_REGION}" s3api head-bucket \
    --bucket "${FRONTEND_BUCKET}" >/dev/null 2>&1; then
    log "Removing s3://${FRONTEND_BUCKET} (and all contents)..."
    if aws --profile "${AWS_PROFILE}" --region "${FRONTEND_BUCKET_REGION}" s3 rb "s3://${FRONTEND_BUCKET}" --force >/dev/null; then
      log "Deleted bucket s3://${FRONTEND_BUCKET}."
    else
      log "Failed to delete bucket s3://${FRONTEND_BUCKET}."
    fi
  else
    log "Bucket s3://${FRONTEND_BUCKET} not found; skipping."
  fi
}

create_cloudfront_invalidation() {
  local distribution_id="$1"
  if [[ -z "${distribution_id}" || "${distribution_id}" == "None" ]]; then
    return 0
  fi

  local invalidation_id
  invalidation_id=$(aws --profile "${AWS_PROFILE}" cloudfront create-invalidation \
    --distribution-id "${distribution_id}" \
    --paths "/*" \
    --query 'Invalidation.Id' --output text 2>/dev/null || echo "")

  if [[ -z "${invalidation_id}" || "${invalidation_id}" == "None" ]]; then
    log "Failed to request CloudFront invalidation for distribution ${distribution_id}."
    return 1
  fi

  log "Requested CloudFront invalidation ${invalidation_id} for distribution ${distribution_id}."
  return 0
}

delete_cloudfront_distribution() {
  local distribution_info
  distribution_info=$(aws --profile "${AWS_PROFILE}" cloudfront list-distributions \
    --query "DistributionList.Items[?Aliases.Items && contains(Aliases.Items, '${FRONTEND_DOMAIN}')].[Id,Status]" \
    --output text 2>/dev/null || echo "")
  if [[ -z "${distribution_info}" || "${distribution_info}" == "None" ]]; then
    log "No CloudFront distribution found for ${FRONTEND_DOMAIN}; skipping."
    return 0
  fi
  local distribution_id
  distribution_id=$(printf '%s' "${distribution_info}" | awk '{print $1}')
  FRONTEND_DISTRIBUTION_ID="${distribution_id}"
  create_cloudfront_invalidation "${distribution_id}" || true
  log "Disabling CloudFront distribution ${distribution_id}..."
  local config_dump mutated_config
  config_dump=$(mktemp)
  mutated_config=$(mktemp)
  if ! aws --profile "${AWS_PROFILE}" cloudfront get-distribution-config \
    --id "${distribution_id}" > "${config_dump}"; then
    log "Failed to fetch distribution config for ${distribution_id}."
    rm -f "${config_dump}" "${mutated_config}"
    return 1
  fi
  local etag
  etag=$(python3 - "$config_dump" "$mutated_config" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    payload = json.load(fh)
config = payload["DistributionConfig"]
config["Enabled"] = False
aliases = config.get("Aliases")
if aliases:
    aliases["Items"] = []
    aliases["Quantity"] = 0
json.dump(config, open(sys.argv[2], 'w'))
print(payload["ETag"])
PY
)
  if [[ -z "${etag}" ]]; then
    log "Could not determine ETag for distribution ${distribution_id}."
    rm -f "${config_dump}" "${mutated_config}"
    return 1
  fi
  if ! aws --profile "${AWS_PROFILE}" cloudfront update-distribution \
    --id "${distribution_id}" --if-match "${etag}" \
    --distribution-config file://"${mutated_config}" >/dev/null; then
    log "Failed to disable CloudFront distribution ${distribution_id}."
    rm -f "${config_dump}" "${mutated_config}"
    return 1
  fi
  log "Waiting for CloudFront distribution ${distribution_id} to finish disabling..."
  aws --profile "${AWS_PROFILE}" cloudfront wait distribution-deployed --id "${distribution_id}" || true
  local delete_etag
  delete_etag=$(aws --profile "${AWS_PROFILE}" cloudfront get-distribution-config \
    --id "${distribution_id}" --query 'ETag' --output text 2>/dev/null || echo "")
  if [[ -z "${delete_etag}" || "${delete_etag}" == "None" ]]; then
    log "Failed to fetch delete ETag for distribution ${distribution_id}."
    rm -f "${config_dump}" "${mutated_config}"
    return 1
  fi
  if aws --profile "${AWS_PROFILE}" cloudfront delete-distribution \
    --id "${distribution_id}" --if-match "${delete_etag}" >/dev/null; then
    log "Deleted CloudFront distribution ${distribution_id}."
  else
    log "Failed to delete CloudFront distribution ${distribution_id}."
  fi
  rm -f "${config_dump}" "${mutated_config}"
}

delete_acm_certificate() {
  local cert_arn
  cert_arn=$(aws --profile "${AWS_PROFILE}" --region "${FRONTEND_CERT_REGION}" acm list-certificates \
    --certificate-statuses ISSUED PENDING_VALIDATION INACTIVE EXPIRED VALIDATION_TIMED_OUT FAILED REVOKED \
    --query "CertificateSummaryList[?DomainName=='${FRONTEND_DOMAIN}'].CertificateArn | [0]" \
    --output text 2>/dev/null || echo "None")
  if [[ -z "${cert_arn}" || "${cert_arn}" == "None" ]]; then
    log "No ACM certificate found for ${FRONTEND_DOMAIN}; skipping."
    return 0
  fi
  log "Deleting ACM certificate ${cert_arn}..."
  if aws --profile "${AWS_PROFILE}" --region "${FRONTEND_CERT_REGION}" acm delete-certificate \
    --certificate-arn "${cert_arn}" >/dev/null; then
    log "Deleted ACM certificate ${cert_arn}."
  else
    log "Failed to delete ACM certificate ${cert_arn}."
  fi
}

delete_backend_acm_certificate() {
  local cert_arn
  cert_arn=$(aws --profile "${AWS_PROFILE}" --region "${BACKEND_CERT_REGION}" acm list-certificates \
    --certificate-statuses ISSUED PENDING_VALIDATION INACTIVE EXPIRED VALIDATION_TIMED_OUT FAILED REVOKED \
    --query "CertificateSummaryList[?DomainName=='${BACKEND_DOMAIN}'].CertificateArn | [0]" \
    --output text 2>/dev/null || echo "None")
  if [[ -z "${cert_arn}" || "${cert_arn}" == "None" ]]; then
    log "No backend ACM certificate found for ${BACKEND_DOMAIN}; skipping."
    return 0
  fi
  log "Deleting backend ACM certificate ${cert_arn} (${BACKEND_DOMAIN})."
  if aws --profile "${AWS_PROFILE}" --region "${BACKEND_CERT_REGION}" acm delete-certificate \
    --certificate-arn "${cert_arn}" >/dev/null; then
    log "Deleted backend ACM certificate ${cert_arn}."
  else
    log "Failed to delete backend ACM certificate ${cert_arn}."
  fi
}

remove_https_rule_from_security_group() {
  if [[ -z "${SECURITY_GROUP_ID}" ]]; then
    log "Security group ID unknown; skipping HTTPS rule cleanup."
    return 0
  fi
  local rule
  rule=$(aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" ec2 describe-security-groups \
    --group-ids "${SECURITY_GROUP_ID}" \
    --query "SecurityGroups[0].IpPermissions[?IpProtocol=='tcp' && FromPort==\`443\` && ToPort==\`443\`]" \
    --output text 2>/dev/null || echo "")
  if [[ -z "${rule}" || "${rule}" == "None" ]]; then
    log "No TCP/443 ingress rule found on ${SECURITY_GROUP_ID}; skipping."
    return 0
  fi
  log "Revoking TCP/443 ingress rule from security group ${SECURITY_GROUP_ID}."
  if aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" ec2 revoke-security-group-ingress \
    --group-id "${SECURITY_GROUP_ID}" \
    --ip-permissions '[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0","Description":"ECS sarrescost ALB HTTPS"}]}]' >/dev/null 2>&1; then
    log "Removed TCP/443 ingress from ${SECURITY_GROUP_ID}."
  else
    log "Failed to revoke TCP/443 ingress from ${SECURITY_GROUP_ID}."
  fi
}

cleanup_frontend_resources() {
  log "----- Frontend teardown for ${FRONTEND_DOMAIN} -----"
  delete_cloudfront_distribution || true
  delete_frontend_bucket || true
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
