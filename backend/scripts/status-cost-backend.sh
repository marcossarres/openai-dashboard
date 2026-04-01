#!/usr/bin/env bash
# Report the health of the cost-backend platform components.
# Outputs a normalized status (working | not created | instaling | error)
# for each major AWS service/resource that makes up the stack.
#
# Environment variables (override as needed):
#   AWS_PROFILE             AWS CLI profile (default: aws-cloudy)
#   AWS_REGION              Region to inspect (default: us-east-1)
#   STACK_NAME              CloudFormation stack name (default: [project]-[domain]-cloud-formation)
#   ECS_CLUSTER_NAME        Fallback ECS cluster name if stack output unavailable
#                           (default: [project]-[domain]-ecs-cluster)
#   ECS_SERVICE_NAME        Fallback ECS service name (default: [project]-[domain]-ecs-service)
#   LOG_GROUP_NAME          CloudWatch Logs group to check (default: [project]-[domain]-log-group)
#   TARGET_GROUP_ID         Fallback target group ARN/name if stack resource lookup fails
#   LOAD_BALANCER_ID        Fallback ALB ARN/name if stack resource lookup fails
#   ASG_NAME                Fallback Auto Scaling group name if stack resource lookup fails
#                           (default: [project]-[domain]-auto-scaling-group)
#   ECR_REPOSITORY          ECR repository name to inspect (default: [project]-[domain]-ecr-repo)
#   ECR_REGISTRY_ID         Optional registry ID override (defaults to the account of AWS_PROFILE)
#   PROJECT                 Project prefix for derived resource names (can also be provided via --project/-p)
#
# Example:
#   STACK_NAME=cost-backend-formation ./scripts/status-cost-backend.sh

set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-aws-cloudy}"
AWS_REGION="${AWS_REGION:-us-east-1}"
DEFAULT_STACK_SENTINEL="__DEFAULT_STACK_NAME__"
DEFAULT_CLUSTER_SENTINEL="__DEFAULT_CLUSTER_NAME__"
DEFAULT_SERVICE_SENTINEL="__DEFAULT_SERVICE_NAME__"
DEFAULT_LOG_GROUP_SENTINEL="__DEFAULT_LOG_GROUP__"
DEFAULT_ASG_SENTINEL="__DEFAULT_ASG_NAME__"
DEFAULT_ECR_REPO_SENTINEL="__DEFAULT_ECR_REPO__"
DEFAULT_FRONTEND_ROOT_SENTINEL="__DEFAULT_FRONTEND_ROOT__"
DEFAULT_FRONTEND_DOMAIN_SENTINEL="__DEFAULT_FRONTEND_DOMAIN__"
DEFAULT_FRONTEND_BUCKET_SENTINEL="__DEFAULT_FRONTEND_BUCKET__"
DEFAULT_BACKEND_DOMAIN_SENTINEL="__DEFAULT_BACKEND_DOMAIN__"

STACK_NAME="${STACK_NAME:-${DEFAULT_STACK_SENTINEL}}"
ECS_CLUSTER_NAME="${ECS_CLUSTER_NAME:-${DEFAULT_CLUSTER_SENTINEL}}"
ECS_SERVICE_NAME="${ECS_SERVICE_NAME:-${DEFAULT_SERVICE_SENTINEL}}"
LOG_GROUP_NAME="${LOG_GROUP_NAME:-${DEFAULT_LOG_GROUP_SENTINEL}}"
TARGET_GROUP_ID="${TARGET_GROUP_ID:-}"
LOAD_BALANCER_ID="${LOAD_BALANCER_ID:-}"
ASG_NAME="${ASG_NAME:-${DEFAULT_ASG_SENTINEL}}"
ECR_REPOSITORY="${ECR_REPOSITORY:-${DEFAULT_ECR_REPO_SENTINEL}}"
ECR_REGISTRY_ID="${ECR_REGISTRY_ID:-}"
ALB_DNS_NAME=""
SUMMARY_ENTRIES=()

FRONTEND_ROOT_DOMAIN="${FRONTEND_ROOT_DOMAIN:-${DEFAULT_FRONTEND_ROOT_SENTINEL}}"
FRONTEND_DOMAIN="${FRONTEND_DOMAIN:-${DEFAULT_FRONTEND_DOMAIN_SENTINEL}}"
FRONTEND_BUCKET="${FRONTEND_BUCKET:-${DEFAULT_FRONTEND_BUCKET_SENTINEL}}"
FRONTEND_BUCKET_REGION="${FRONTEND_BUCKET_REGION:-${AWS_REGION}}"
FRONTEND_CERT_REGION="${FRONTEND_CERT_REGION:-us-east-1}"
FRONTEND_HOSTED_ZONE_ID="${FRONTEND_HOSTED_ZONE_ID:-}"
BACKEND_DOMAIN="${BACKEND_DOMAIN:-${DEFAULT_BACKEND_DOMAIN_SENTINEL}}"
BACKEND_CERT_REGION="${BACKEND_CERT_REGION:-${AWS_REGION}}"
BACKEND_HOSTED_ZONE_ID="${BACKEND_HOSTED_ZONE_ID:-}"
SECURITY_GROUP_ID="${SECURITY_GROUP_ID:-}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --domain <root-domain> --project <name>

Required arguments:
  --domain, -d    Root domain (e.g., sarres.com.br). The script will verify both the backend
                  stack and the frontend resources created for <project>.<root-domain>.
  --project, -p   Project prefix (alphanumeric + dashes). Used together with the domain to
                  derive the resource names for this deployment.

Environment overrides:
  FRONTEND_BUCKET_REGION, FRONTEND_CERT_REGION, FRONTEND_HOSTED_ZONE_ID,
  plus the backend-specific vars listed at the top of this file.
USAGE
}

DOMAIN="${DOMAIN:-}"
PROJECT="${PROJECT:-}"

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain|-d)
        if [[ -z "${2:-}" ]]; then
          printf 'Missing value for %s\n' "$1" >&2
          usage
          exit 1
        fi
        DOMAIN="$2"
        shift 2
        ;;
      --project|-p)
        if [[ -z "${2:-}" ]]; then
          printf 'Missing value for %s\n' "$1" >&2
          usage
          exit 1
        fi
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
        printf 'Unknown argument: %s\n' "$1" >&2
        usage
        exit 1
        ;;
    esac
  done

  if [[ $# -gt 0 ]]; then
    printf 'Unexpected arguments: %s\n' "$*" >&2
    usage
    exit 1
  fi
}

parse_args "$@"

if [[ -z "${DOMAIN}" ]]; then
  printf 'DOMAIN parameter is required.\n' >&2
  usage
  exit 1
fi

if [[ -z "${PROJECT}" ]]; then
  printf 'PROJECT parameter is required.\n' >&2
  usage
  exit 1
fi

DOMAIN_NORMALIZED="$(printf '%s' "${DOMAIN}" | tr '[:upper:]' '[:lower:]')"
DOMAIN_DNS_LABEL="$(printf '%s' "${DOMAIN_NORMALIZED}" | sed -E 's/[^a-z0-9.-]+/-/g' | sed -E 's/-+/-/g' | sed -E 's/^-+|-+$//g')"
if [[ -z "${DOMAIN_DNS_LABEL}" ]]; then
  printf 'DOMAIN must contain at least one valid character (letters, numbers, dashes, dots).\n' >&2
  exit 1
fi
DOMAIN_PREFIX_SEGMENT="$(printf '%s' "${DOMAIN_DNS_LABEL}" | tr '.' '-' | sed -E 's/-+/-/g' | sed -E 's/^-+|-+$//g')"
if [[ -z "${DOMAIN_PREFIX_SEGMENT}" ]]; then
  printf 'DOMAIN prefix segment empty after normalization; choose a valid domain.\n' >&2
  exit 1
fi

PROJECT_PREFIX="$(printf '%s' "${PROJECT}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g' | sed -E 's/^-+|-+$//g')"
if [[ -z "${PROJECT_PREFIX}" ]]; then
  printf 'PROJECT must contain at least one alphanumeric character (letters, numbers, dashes).\n' >&2
  exit 1
fi

RESOURCE_PREFIX="${PROJECT_PREFIX}-${DOMAIN_PREFIX_SEGMENT}"
FRIENDLY_NAME_PREFIX="${PROJECT_PREFIX}-${DOMAIN_DNS_LABEL}"

if [[ "${STACK_NAME}" == "${DEFAULT_STACK_SENTINEL}" ]]; then
  STACK_NAME="${RESOURCE_PREFIX}-cloud-formation"
fi
if [[ "${ECS_CLUSTER_NAME}" == "${DEFAULT_CLUSTER_SENTINEL}" ]]; then
  ECS_CLUSTER_NAME="${RESOURCE_PREFIX}-ecs-cluster"
fi
if [[ "${ECS_SERVICE_NAME}" == "${DEFAULT_SERVICE_SENTINEL}" ]]; then
  ECS_SERVICE_NAME="${RESOURCE_PREFIX}-ecs-service"
fi
if [[ "${LOG_GROUP_NAME}" == "${DEFAULT_LOG_GROUP_SENTINEL}" ]]; then
  LOG_GROUP_NAME="${RESOURCE_PREFIX}-log-group"
fi
if [[ "${ASG_NAME}" == "${DEFAULT_ASG_SENTINEL}" ]]; then
  ASG_NAME="${RESOURCE_PREFIX}-auto-scaling-group"
fi
if [[ "${ECR_REPOSITORY}" == "${DEFAULT_ECR_REPO_SENTINEL}" ]]; then
  ECR_REPOSITORY="${FRIENDLY_NAME_PREFIX}-ecr-repo"
fi
if [[ "${FRONTEND_ROOT_DOMAIN}" == "${DEFAULT_FRONTEND_ROOT_SENTINEL}" ]]; then
  FRONTEND_ROOT_DOMAIN="${DOMAIN_DNS_LABEL}"
fi
if [[ "${FRONTEND_DOMAIN}" == "${DEFAULT_FRONTEND_DOMAIN_SENTINEL}" ]]; then
  FRONTEND_DOMAIN="${PROJECT_PREFIX}.${FRONTEND_ROOT_DOMAIN}"
fi
if [[ "${FRONTEND_BUCKET}" == "${DEFAULT_FRONTEND_BUCKET_SENTINEL}" ]]; then
  FRONTEND_BUCKET="${FRONTEND_DOMAIN}"
fi
if [[ "${BACKEND_DOMAIN}" == "${DEFAULT_BACKEND_DOMAIN_SENTINEL}" ]]; then
  BACKEND_DOMAIN="api.${PROJECT_PREFIX}.${FRONTEND_ROOT_DOMAIN}"
fi

aws_cli() {
  aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" "$@"
}

normalize_field() {
  local value="$1"
  if [[ -z "${value}" || "${value}" == "None" || "${value}" == "null" ]]; then
    echo ""
  else
    echo "${value}"
  fi
}

component_status() {
  local svc_type="$1" name="$2" state="$3" message="$4" raw_status="${5:-}"
  printf '[status] %-30s %-11s %s\n' "${name}" "${state}" "${message}"
  local summary_status="${raw_status:-${state}}"
  local tab=$'\t'
  SUMMARY_ENTRIES+=("${svc_type}${tab}${name}${tab}${summary_status}")
}

friendly_id() {
  local value="$1"
  if [[ -z "${value}" || "${value}" == "None" ]]; then
    echo ""
  elif [[ "${value}" == arn:* ]]; then
    echo "${value##*/}"
  else
    echo "${value}"
  fi
}

to_upper() {
  local value="$1"
  if [[ -z "${value}" ]]; then
    echo ""
    return
  fi
  printf '%s' "${value}" | tr '[:lower:]' '[:upper:]'
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
  FRONTEND_HOSTED_ZONE_ID=""
  return 1
}

cf_stack_status() {
  aws_cli cloudformation describe-stacks --stack-name "${STACK_NAME}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "STACK_NOT_FOUND"
}

cf_output() {
  local key="$1"
  aws_cli cloudformation describe-stacks --stack-name "${STACK_NAME}" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" --output text 2>/dev/null || true
}

cf_parameter() {
  local key="$1"
  aws_cli cloudformation describe-stacks --stack-name "${STACK_NAME}" \
    --query "Stacks[0].Parameters[?ParameterKey=='${key}'].ParameterValue" --output text 2>/dev/null || true
}

cf_resource_id() {
  local logical_id="$1"
  aws_cli cloudformation describe-stack-resources --stack-name "${STACK_NAME}" \
    --logical-resource-id "${logical_id}" --query 'StackResources[0].PhysicalResourceId' \
    --output text 2>/dev/null || true
}

classify_stack_state() {
  local status="$1"
  case "${status}" in
    STACK_NOT_FOUND|DELETE_COMPLETE|DELETE_FAILED)
      echo "not created"
      ;;
    *ROLLBACK*|*FAILED)
      echo "error"
      ;;
    *IN_PROGRESS|REVIEW_IN_PROGRESS)
      echo "instaling"
      ;;
    *)
      echo "working"
      ;;
  esac
}

classify_simple_state() {
  local status="$1"
  case "${status}" in
    ""|None|MISSING)
      echo "not created"
      ;;
    *PROVISIONING*|*PENDING*|*DRAINING*|*INITIAL*|*DEGRADED*)
      echo "instaling"
      ;;
    *FAILED*|*ERROR*|*INACTIVE*)
      echo "error"
      ;;
    *)
      echo "working"
      ;;
  esac
}

report_stack() {
  local status
  status=$(cf_stack_status)
  local state
  state=$(classify_stack_state "${status}")
  if [[ "${state}" == "not created" ]]; then
    component_status "CFN" "CloudFormation stack (${STACK_NAME})" "${state}" "Stack ${STACK_NAME} not found in ${AWS_REGION}." "${status}"
  else
    component_status "CFN" "CloudFormation stack (${STACK_NAME})" "${state}" "status=${status}" "${status}"
  fi
}

STACK_STATUS=$(cf_stack_status)

STACK_EXISTS=true
if [[ "${STACK_STATUS}" == "STACK_NOT_FOUND" || "${STACK_STATUS}" == "DELETE_COMPLETE" || "${STACK_STATUS}" == "None" ]]; then
  STACK_EXISTS=false
fi

if ${STACK_EXISTS}; then
  cf_cluster=$(normalize_field "$(cf_output ClusterName)")
  cf_service=$(normalize_field "$(cf_output ServiceName)")
  cf_lb=$(normalize_field "$(cf_output LoadBalancerDNS)")
  [[ -n "${cf_cluster}" ]] && ECS_CLUSTER_NAME="${cf_cluster}"
  [[ -n "${cf_service}" ]] && ECS_SERVICE_NAME="${cf_service}"
  [[ -n "${cf_lb}" ]] && ALB_DNS_NAME="${cf_lb}"
  if [[ -z "${LOAD_BALANCER_ID}" ]]; then
    LOAD_BALANCER_ID=$(normalize_field "$(cf_resource_id SarrescostLoadBalancer)")
  fi
  if [[ -z "${TARGET_GROUP_ID}" ]]; then
    TARGET_GROUP_ID=$(normalize_field "$(cf_resource_id SarrescostTargetGroup)")
  fi
  if [[ -z "${ASG_NAME}" ]]; then
    ASG_NAME=$(normalize_field "$(cf_resource_id SarrescostAutoScalingGroup)")
  fi
  if [[ -z "${SECURITY_GROUP_ID}" ]]; then
    SECURITY_GROUP_ID=$(normalize_field "$(cf_parameter DefaultSecurityGroupId)")
  fi
fi

report_ecs_cluster() {
  if [[ -z "${ECS_CLUSTER_NAME}" ]]; then
    component_status "ECS" "ECS cluster (${ECS_CLUSTER_NAME:-n/a})" "not created" "Cluster name unavailable; check stack outputs." ""
    return
  fi

  local info
  info=$(aws_cli ecs describe-clusters --clusters "${ECS_CLUSTER_NAME}" \
    --query 'clusters[0].[status,registeredContainerInstancesCount,runningTasksCount,activeServicesCount]' \
    --output text 2>/dev/null || echo "MISSING")

  if [[ "${info}" == "MISSING" || "${info}" == "None" ]]; then
    component_status "ECS" "ECS cluster (${ECS_CLUSTER_NAME})" "not created" "${ECS_CLUSTER_NAME} not found." "MISSING"
    return
  fi

  IFS=$'\t' read -r status registered running svc <<<"${info}"
  local state
  if [[ "${status}" == "PROVISIONING" || "${registered}" == "0" ]]; then
    state="instaling"
  elif [[ "${status}" == "ACTIVE" ]]; then
    state="working"
  else
    state=$(classify_simple_state "${status}")
  fi
  component_status "ECS" "ECS cluster (${ECS_CLUSTER_NAME})" "${state}" "status=${status}, container_instances=${registered}, services=${svc}, running_tasks=${running}" "${status}"
}

report_ecs_service() {
  if [[ -z "${ECS_CLUSTER_NAME}" ]]; then
    component_status "ECS" "ECS services" "not created" "Cluster name unavailable." ""
    return
  fi

  # List all services in the cluster
  local arns
  arns=$(aws_cli ecs list-services --cluster "${ECS_CLUSTER_NAME}" \
    --query 'serviceArns' --output text 2>/dev/null || echo "")

  if [[ -z "${arns}" || "${arns}" == "None" ]]; then
    component_status "ECS" "ECS services (${ECS_CLUSTER_NAME})" "not created" "No services found in cluster ${ECS_CLUSTER_NAME}." "MISSING"
    return
  fi

  # describe-services accepts up to 10 ARNs at once
  local service_list
  IFS=$'\t' read -r -a service_list <<< "${arns}"

  local infos
  infos=$(aws_cli ecs describe-services --cluster "${ECS_CLUSTER_NAME}" \
    --services "${service_list[@]}" \
    --query 'services[].[serviceName,status,desiredCount,runningCount,pendingCount,deployments[0].rolloutState]' \
    --output text 2>/dev/null || echo "")

  if [[ -z "${infos}" ]]; then
    component_status "ECS" "ECS services (${ECS_CLUSTER_NAME})" "not created" "Could not describe services in ${ECS_CLUSTER_NAME}." "MISSING"
    return
  fi

  while IFS=$'\t' read -r svc_name status desired running pending rollout; do
    [[ -z "${svc_name}" ]] && continue
    local state
    if [[ "${status}" != "ACTIVE" ]]; then
      state=$(classify_simple_state "${status}")
    elif [[ "${running}" == "${desired}" && "${pending}" == "0" && "${rollout}" == "COMPLETED" ]]; then
      state="working"
    else
      state="instaling"
    fi
    local details="status=${status}, desired=${desired}, running=${running}, pending=${pending}, rollout=${rollout:-n/a}"
    if [[ "${state}" == "working" && -n "${ALB_DNS_NAME}" ]]; then
      details+=", alb_domain=${ALB_DNS_NAME}"
    fi
    component_status "ECS" "ECS service (${svc_name})" "${state}" "${details}" "${status}"
  done <<< "${infos}"
}

report_asg() {
  if [[ -z "${ASG_NAME}" ]]; then
    component_status "ASG" "ECS AutoScaling (${ASG_NAME:-n/a})" "not created" "ASG logical ID missing; set ASG_NAME or deploy stack." ""
    return
  fi

  local info
  info=$(aws_cli autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${ASG_NAME}" \
    --query "AutoScalingGroups[0].[AutoScalingGroupName,DesiredCapacity,length(Instances),length(Instances[?LifecycleState=='InService'])]" \
    --output text 2>/dev/null || echo "MISSING")

  if [[ "${info}" == "MISSING" || "${info}" == "None" ]]; then
    component_status "ASG" "ECS AutoScaling (${ASG_NAME})" "not created" "Auto Scaling group ${ASG_NAME} not found." "MISSING"
    return
  fi

  IFS=$'\t' read -r name desired total in_service <<<"${info}"
  local state
  if [[ "${desired}" == "${in_service}" ]]; then
    state="working"
  elif [[ "${desired}" == "0" ]]; then
    state="working"
  else
    state="instaling"
  fi
  local label=$(friendly_id "${name}")
  component_status "ASG" "ECS AutoScaling (${label:-${name}})" "${state}" "name=${name}, desired=${desired}, in_service=${in_service}, total=${total}" "${in_service}/${desired}"
}

report_load_balancer() {
  local lb_id="${LOAD_BALANCER_ID}"
  if [[ -z "${lb_id}" ]]; then
    component_status "ALB" "Application Load Balancer" "not created" "ALB id unavailable; check stack resources." ""
    return
  fi

  local info
  info=$(aws_cli elbv2 describe-load-balancers --load-balancer-arns "${lb_id}" \
    --query 'LoadBalancers[0].[State.Code,DNSName]' --output text 2>/dev/null || echo "MISSING")

  if [[ "${info}" == "MISSING" || "${info}" == "None" ]]; then
    component_status "ALB" "Application Load Balancer (${lb_id})" "not created" "${lb_id} not found." "MISSING"
    return
  fi

  IFS=$'\t' read -r state dns <<<"${info}"
  local status
  status=$(classify_simple_state "$(to_upper "${state}")")
  local label=$(friendly_id "${lb_id}")
  component_status "ALB" "Application Load Balancer (${label:-${lb_id}})" "${status}" "state=${state}, dns=${dns}" "${state}"
}

report_target_group() {
  local tg_id="${TARGET_GROUP_ID}"
  if [[ -z "${tg_id}" ]]; then
    component_status "ALB" "ALB target group" "not created" "Target group id unavailable; check stack resources." ""
    return
  fi

  local states
  states=$(aws_cli elbv2 describe-target-health --target-group-arn "${tg_id}" \
    --query 'TargetHealthDescriptions[].TargetHealth.State' --output text 2>/dev/null || echo "MISSING")

  if [[ "${states}" == "MISSING" ]]; then
    component_status "ALB" "ALB target group (${tg_id})" "not created" "${tg_id} not found." "MISSING"
    return
  fi

  if [[ -z "${states}" ]]; then
    component_status "ALB" "ALB target group" "instaling" "No registered targets yet." "NO_TARGETS"
    return
  fi

  local state="working"
  for s in ${states}; do
    case "${s}" in
      healthy)
        continue
        ;;
      initial|unused|draining)
        state="instaling"
        ;;
      unhealthy)
        state="error"
        break
        ;;
      *)
        state="instaling"
        ;;
    esac
  done
  local label=$(friendly_id "${tg_id}")
  local summary_states
  summary_states=$(printf '%s' "${states}" | paste -sd ',' -)
  component_status "ALB" "ALB target group (${label:-${tg_id}})" "${state}" "targets=${states:-none}" "${summary_states:-${state}}"
}

report_log_group() {
  if [[ -z "${LOG_GROUP_NAME}" ]]; then
    component_status "CWL" "CloudWatch Logs (${LOG_GROUP_NAME:-n/a})" "not created" "Log group name not specified." ""
    return
  fi

  local found
  found=$(aws_cli logs describe-log-groups --log-group-name-prefix "${LOG_GROUP_NAME}" \
    --query "logGroups[?logGroupName=='${LOG_GROUP_NAME}'] | length(@)" --output text 2>/dev/null || echo "0")

  if [[ "${found}" == "0" ]]; then
    component_status "CWL" "CloudWatch Logs (${LOG_GROUP_NAME})" "not created" "${LOG_GROUP_NAME} log group missing." "NOT_FOUND"
  else
    component_status "CWL" "CloudWatch Logs (${LOG_GROUP_NAME})" "working" "log_group=${LOG_GROUP_NAME}" "EXISTS"
  fi
}

report_ecr_repository() {
  if [[ -z "${ECR_REPOSITORY}" ]]; then
    component_status "ECR" "ECR repository" "not created" "Repository name not specified." ""
    return
  fi

  local repo_uri
  if [[ -n "${ECR_REGISTRY_ID}" ]]; then
    repo_uri=$(aws_cli ecr describe-repositories --registry-id "${ECR_REGISTRY_ID}" \
      --repository-names "${ECR_REPOSITORY}" --query 'repositories[0].repositoryUri' --output text 2>/dev/null || echo "MISSING")
  else
    repo_uri=$(aws_cli ecr describe-repositories --repository-names "${ECR_REPOSITORY}" \
      --query 'repositories[0].repositoryUri' --output text 2>/dev/null || echo "MISSING")
  fi

  if [[ "${repo_uri}" == "MISSING" || "${repo_uri}" == "None" ]]; then
    component_status "ECR" "ECR repository (${ECR_REPOSITORY})" "not created" "Repository not found in ${AWS_REGION}." "NOT_FOUND"
    return
  fi

  local latest
  if [[ -n "${ECR_REGISTRY_ID}" ]]; then
    latest=$(aws_cli ecr describe-images --registry-id "${ECR_REGISTRY_ID}" --repository-name "${ECR_REPOSITORY}" \
      --query "sort_by(imageDetails,&imagePushedAt)[-1].[join(',',imageTags),imageDigest,imagePushedAt]" --output text 2>/dev/null || echo "NO_IMAGES")
  else
    latest=$(aws_cli ecr describe-images --repository-name "${ECR_REPOSITORY}" \
      --query "sort_by(imageDetails,&imagePushedAt)[-1].[join(',',imageTags),imageDigest,imagePushedAt]" --output text 2>/dev/null || echo "NO_IMAGES")
  fi

  if [[ "${latest}" == "NO_IMAGES" || "${latest}" == "None" || -z "${latest}" ]]; then
    component_status "ECR" "ECR repository (${ECR_REPOSITORY})" "instaling" "${repo_uri} has no images yet." "NO_IMAGES"
    return
  fi

  IFS=$'\t' read -r tags digest pushed <<<"${latest}"
  tags=$(normalize_field "${tags}")
  digest=$(normalize_field "${digest}")
  pushed=$(normalize_field "${pushed}")
  component_status "ECR" "ECR repository (${ECR_REPOSITORY})" "working" "uri=${repo_uri}, latest_tag=${tags:-n/a}, digest=${digest:-n/a}, pushed_at=${pushed:-n/a}" "AVAILABLE"
}

report_frontend_bucket() {
  if aws --profile "${AWS_PROFILE}" --region "${FRONTEND_BUCKET_REGION}" s3api head-bucket \
    --bucket "${FRONTEND_BUCKET}" >/dev/null 2>&1; then
    component_status "S3" "Frontend bucket (s3://${FRONTEND_BUCKET})" "working" "bucket exists in ${FRONTEND_BUCKET_REGION}." "AVAILABLE"
  else
    component_status "S3" "Frontend bucket (s3://${FRONTEND_BUCKET})" "not created" "Bucket not found or inaccessible." "MISSING"
  fi
}

report_cloudfront_distribution() {
  local info
  info=$(aws --profile "${AWS_PROFILE}" cloudfront list-distributions \
    --query "DistributionList.Items[?Aliases.Items && contains(Aliases.Items, '${FRONTEND_DOMAIN}')].[Id,Status,Enabled,DomainName]" \
    --output text 2>/dev/null || echo "")
  if [[ -z "${info}" || "${info}" == "None" ]]; then
    component_status "CFD" "CloudFront (${FRONTEND_DOMAIN})" "not created" "No distribution with alias ${FRONTEND_DOMAIN}." "MISSING"
    return
  fi
  local dist_id dist_status dist_enabled dist_domain
  read -r dist_id dist_status dist_enabled dist_domain <<<"${info}"
  local state="instaling"
  if [[ "${dist_status}" == "Deployed" && "${dist_enabled}" == "True" ]]; then
    state="working"
  elif [[ "${dist_status}" == "Deployed" && "${dist_enabled}" == "False" ]]; then
    state="error"
  fi
  component_status "CFD" "CloudFront (${FRONTEND_DOMAIN})" "${state}" "id=${dist_id}, status=${dist_status}, enabled=${dist_enabled}, domain=${dist_domain}" "${dist_status}"
}

report_route53_alias() {
  if ! find_frontend_hosted_zone; then
    component_status "R53" "Route 53 alias (${FRONTEND_DOMAIN})" "not created" "Hosted zone ${FRONTEND_ROOT_DOMAIN} not found." "ZONE_MISSING"
    return
  fi
  local alias_info
  alias_info=$(aws --profile "${AWS_PROFILE}" route53 list-resource-record-sets \
    --hosted-zone-id "${FRONTEND_HOSTED_ZONE_ID}" \
    --query "ResourceRecordSets[?Type=='A' && Name=='${FRONTEND_DOMAIN}.'].AliasTarget.[DNSName,HostedZoneId]" \
    --output text 2>/dev/null || echo "")
  if [[ -z "${alias_info}" || "${alias_info}" == "None" ]]; then
    component_status "R53" "Route 53 alias (${FRONTEND_DOMAIN})" "not created" "Alias not present in hosted zone ${FRONTEND_ROOT_DOMAIN}." "MISSING"
    return
  fi
  local dns_name dns_zone
  read -r dns_name dns_zone <<<"${alias_info}"
  component_status "R53" "Route 53 alias (${FRONTEND_DOMAIN})" "working" "alias -> ${dns_name} (zone=${dns_zone})" "ALIAS_SET"
}

report_backend_route53_alias() {
  local zone_id="${BACKEND_HOSTED_ZONE_ID:-${FRONTEND_HOSTED_ZONE_ID}}"
  if [[ -z "${zone_id}" ]]; then
    if ! find_frontend_hosted_zone; then
      component_status "R53" "Route 53 alias (${BACKEND_DOMAIN})" "not created" "Hosted zone ${FRONTEND_ROOT_DOMAIN} not found." "ZONE_MISSING"
      return
    fi
    zone_id="${FRONTEND_HOSTED_ZONE_ID}"
  fi
  BACKEND_HOSTED_ZONE_ID="${zone_id}"
  local alias_info
  alias_info=$(aws --profile "${AWS_PROFILE}" route53 list-resource-record-sets \
    --hosted-zone-id "${zone_id}" \
    --query "ResourceRecordSets[?Type=='A' && Name=='${BACKEND_DOMAIN}.'].AliasTarget.[DNSName,HostedZoneId]" \
    --output text 2>/dev/null || echo "")
  if [[ -z "${alias_info}" || "${alias_info}" == "None" ]]; then
    component_status "R53" "Route 53 alias (${BACKEND_DOMAIN})" "not created" "Alias not present in hosted zone ${FRONTEND_ROOT_DOMAIN}." "MISSING"
    return
  fi
  local dns_name dns_zone
  read -r dns_name dns_zone <<<"${alias_info}"
  component_status "R53" "Route 53 alias (${BACKEND_DOMAIN})" "working" "alias -> ${dns_name} (zone=${dns_zone})" "ALIAS_SET"
}

report_acm_certificate() {
  local cert_arn
  cert_arn=$(aws --profile "${AWS_PROFILE}" --region "${FRONTEND_CERT_REGION}" acm list-certificates \
    --certificate-statuses ISSUED PENDING_VALIDATION INACTIVE EXPIRED VALIDATION_TIMED_OUT FAILED REVOKED \
    --query "CertificateSummaryList[?DomainName=='${FRONTEND_DOMAIN}'].CertificateArn | [0]" \
    --output text 2>/dev/null || echo "None")
  if [[ -z "${cert_arn}" || "${cert_arn}" == "None" ]]; then
    component_status "ACM" "ACM certificate (${FRONTEND_DOMAIN})" "not created" "No ACM certificate found in ${FRONTEND_CERT_REGION}." "NOT_FOUND"
    return
  fi
  local status in_use
  status=$(aws --profile "${AWS_PROFILE}" --region "${FRONTEND_CERT_REGION}" acm describe-certificate \
    --certificate-arn "${cert_arn}" --query 'Certificate.Status' --output text 2>/dev/null || echo "UNKNOWN")
  in_use=$(aws --profile "${AWS_PROFILE}" --region "${FRONTEND_CERT_REGION}" acm describe-certificate \
    --certificate-arn "${cert_arn}" --query 'length(Certificate.InUseBy)' --output text 2>/dev/null || echo "0")
  local state
  case "${status}" in
    ISSUED)
      state="working"
      ;;
    PENDING_VALIDATION|INACTIVE)
      state="instaling"
      ;;
    FAILED|VALIDATION_TIMED_OUT|REVOKED)
      state="error"
      ;;
    *)
      state="instaling"
      ;;
  esac
  local arn_short=$(friendly_id "${cert_arn}")
  component_status "ACM" "ACM certificate (${FRONTEND_DOMAIN})" "${state}" "status=${status}, in_use=${in_use}, arn=${arn_short:-${cert_arn}}" "${status}"
}

report_alb_security_group() {
  if [[ -z "${SECURITY_GROUP_ID}" ]]; then
    component_status "SG" "ALB security group" "not created" "Security group ID unavailable (stack missing?)." "UNKNOWN"
    return
  fi
  local permissions
  permissions=$(aws_cli ec2 describe-security-groups --group-ids "${SECURITY_GROUP_ID}" \
    --query "SecurityGroups[0].IpPermissions[?IpProtocol=='tcp' && FromPort==\`443\` && ToPort==\`443\`]" \
    --output json 2>/dev/null || echo "[]")
  local label=$(friendly_id "${SECURITY_GROUP_ID}")
  if [[ "${permissions}" == "[]" || "${permissions}" == "None" ]]; then
    component_status "SG" "ALB security group (${label:-${SECURITY_GROUP_ID}})" "not created" "No TCP/443 ingress rule present." "NO_HTTPS"
  else
    component_status "SG" "ALB security group (${label:-${SECURITY_GROUP_ID}})" "working" "TCP/443 ingress rule detected on ${SECURITY_GROUP_ID}." "HTTPS_ENABLED"
  fi
}

report_backend_acm_certificate() {
  local cert_arn
  cert_arn=$(aws --profile "${AWS_PROFILE}" --region "${BACKEND_CERT_REGION}" acm list-certificates \
    --certificate-statuses ISSUED PENDING_VALIDATION INACTIVE EXPIRED VALIDATION_TIMED_OUT FAILED REVOKED \
    --query "CertificateSummaryList[?DomainName=='${BACKEND_DOMAIN}'].CertificateArn | [0]" \
    --output text 2>/dev/null || echo "None")
  if [[ -z "${cert_arn}" || "${cert_arn}" == "None" ]]; then
    component_status "ACM" "ACM certificate (${BACKEND_DOMAIN})" "not created" "No ACM certificate found in ${BACKEND_CERT_REGION}." "NOT_FOUND"
    return
  fi
  local status in_use
  status=$(aws --profile "${AWS_PROFILE}" --region "${BACKEND_CERT_REGION}" acm describe-certificate \
    --certificate-arn "${cert_arn}" --query 'Certificate.Status' --output text 2>/dev/null || echo "UNKNOWN")
  in_use=$(aws --profile "${AWS_PROFILE}" --region "${BACKEND_CERT_REGION}" acm describe-certificate \
    --certificate-arn "${cert_arn}" --query 'length(Certificate.InUseBy)' --output text 2>/dev/null || echo "0")
  local state
  case "${status}" in
    ISSUED)
      state="working"
      ;;
    PENDING_VALIDATION|INACTIVE)
      state="instaling"
      ;;
    FAILED|VALIDATION_TIMED_OUT|REVOKED)
      state="error"
      ;;
    *)
      state="instaling"
      ;;
  esac
  local arn_short=$(friendly_id "${cert_arn}")
  component_status "ACM" "ACM certificate (${BACKEND_DOMAIN})" "${state}" "status=${status}, in_use=${in_use}, arn=${arn_short:-${cert_arn}}" "${status}"
}

print_summary_table() {
  printf '\n%-12s %-60s %-15s\n' "Service type" "Component" "Status"
  printf '%0.s-' {1..90}
  printf '\n'
  local entry
  for entry in "${SUMMARY_ENTRIES[@]}"; do
    IFS=$'\t' read -r svc name raw_status <<<"${entry}"
    printf '%-12s %-60.50s %-15s\n' "${svc}" "${name}" "${raw_status}"
  done
}

report_stack
report_ecs_cluster
report_ecs_service
report_asg
report_load_balancer
report_target_group
report_log_group
report_ecr_repository
report_frontend_bucket
report_cloudfront_distribution
report_route53_alias
report_acm_certificate
report_backend_route53_alias
report_backend_acm_certificate
report_alb_security_group
print_summary_table
