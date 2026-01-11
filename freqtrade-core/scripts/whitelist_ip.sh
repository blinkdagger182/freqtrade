#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/whitelist_ip.sh [options]

Options:
  --ip <ip>            Public IP to whitelist (defaults to auto-detect).
  --cidr <cidr>        CIDR to whitelist (overrides --ip). Example: 1.2.3.4/32
  --target-ip <ip>     Public IP of the service to locate its security group.
  --url <url>          Service URL (extracts host and port, can locate SG).
  --port <port>        Port to allow (if omitted, auto-detects if only one tcp rule exists).
  --protocol <proto>   Protocol (default: tcp).
  --cluster <arn|name> ECS cluster ARN or name (optional if only one cluster exists).
  --service <arn|name> ECS service ARN or name (optional if only one service exists).
  --sg <sg-id>         Security group ID (skips ECS discovery).
  --region <region>    AWS region (defaults to AWS config or env).
  --description <txt>  Rule description (default: codex-whitelist).
  -h, --help           Show this help.

Examples:
  scripts/whitelist_ip.sh --port 3000
  scripts/whitelist_ip.sh --url http://43.216.215.179:8080/
  scripts/whitelist_ip.sh --cidr 203.0.113.10/32 --sg sg-0123456789abcdef0 --port 443
USAGE
}

ip=""
cidr=""
target_ip=""
url=""
port=""
protocol="tcp"
cluster=""
service=""
sg_id=""
region=""
description="codex-whitelist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip) ip="$2"; shift 2;;
    --cidr) cidr="$2"; shift 2;;
    --target-ip) target_ip="$2"; shift 2;;
    --url) url="$2"; shift 2;;
    --port) port="$2"; shift 2;;
    --protocol) protocol="$2"; shift 2;;
    --cluster) cluster="$2"; shift 2;;
    --service) service="$2"; shift 2;;
    --sg) sg_id="$2"; shift 2;;
    --region) region="$2"; shift 2;;
    --description) description="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
 done

if [[ -n "$url" ]]; then
  hostport="${url#*://}"
  hostport="${hostport%%/*}"
  if [[ "$hostport" == *:* ]]; then
    url_host="${hostport%%:*}"
    url_port="${hostport##*:}"
  else
    url_host="$hostport"
    url_port=""
  fi
  if [[ -z "$port" && -n "$url_port" ]]; then
    port="$url_port"
  fi
  if [[ -z "$target_ip" && -n "$url_host" ]]; then
    if [[ "$url_host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      target_ip="$url_host"
    else
      resolved_ip="$(getent hosts "$url_host" | awk 'NR==1 {print $1}')"
      if [[ -n "$resolved_ip" ]]; then
        target_ip="$resolved_ip"
      fi
    fi
  fi
fi

if [[ -z "$region" ]]; then
  if [[ -n "$target_ip" ]]; then
    regions_text="$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text)"
    read -r -a regions <<<"$regions_text"
    match_region=""
    match_count=0
    for r in "${regions[@]}"; do
      eni_text="$(aws ec2 describe-network-interfaces --region "$r" \
        --filters Name=association.public-ip,Values="$target_ip" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)"
      if [[ -n "$eni_text" && "$eni_text" != "None" ]]; then
        match_region="$r"
        match_count=$((match_count + 1))
      fi
    done
    if (( match_count == 1 )); then
      region="$match_region"
    elif (( match_count > 1 )); then
      echo "Public IP ${target_ip} found in multiple regions. Use --region or --sg." >&2
      exit 2
    fi
  fi
  if [[ -z "$region" ]]; then
    region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
  fi
  if [[ -z "$region" ]]; then
    region="$(aws configure get region)"
  fi
fi

if [[ -z "$region" ]]; then
  echo "Region not set. Use --region, --url, or set AWS_REGION/AWS_DEFAULT_REGION." >&2
  exit 2
fi

if [[ -z "$cidr" ]]; then
  if [[ -z "$ip" ]]; then
    ip="$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')"
  fi
  if [[ -z "$ip" ]]; then
    echo "Failed to determine IP. Use --ip or --cidr." >&2
    exit 2
  fi
  cidr="${ip}/32"
fi

aws_args=(--region "$region")

if [[ -z "$sg_id" && -n "$target_ip" ]]; then
  sg_text="$(aws ec2 describe-network-interfaces "${aws_args[@]}" \
    --filters Name=association.public-ip,Values="$target_ip" \
    --query 'NetworkInterfaces[0].Groups[].GroupId' --output text)"
  if [[ -z "$sg_text" || "$sg_text" == "None" ]]; then
    echo "No security group found for public IP ${target_ip}. Use --sg." >&2
    exit 2
  fi
  read -r -a sgs <<<"$sg_text"
  if (( ${#sgs[@]} != 1 )); then
    echo "Multiple security groups found for public IP ${target_ip}. Use --sg." >&2
    exit 2
  fi
  sg_id="${sgs[0]}"
fi

if [[ -z "$sg_id" ]]; then
  if [[ -z "$cluster" ]]; then
    clusters_text="$(aws ecs list-clusters "${aws_args[@]}" --query 'clusterArns[]' --output text)"
    if [[ -z "$clusters_text" || "$clusters_text" == "None" ]]; then
      echo "No ECS clusters found. Use --cluster or --sg." >&2
      exit 2
    fi
    read -r -a clusters <<<"$clusters_text"
    if (( ${#clusters[@]} != 1 )); then
      echo "Multiple ECS clusters found. Use --cluster to select one." >&2
      exit 2
    fi
    cluster="${clusters[0]}"
  fi

  if [[ -z "$service" ]]; then
    services_text="$(aws ecs list-services "${aws_args[@]}" --cluster "$cluster" --query 'serviceArns[]' --output text)"
    if [[ -z "$services_text" || "$services_text" == "None" ]]; then
      echo "No ECS services found. Use --service or --sg." >&2
      exit 2
    fi
    read -r -a services <<<"$services_text"
    if (( ${#services[@]} != 1 )); then
      echo "Multiple ECS services found. Use --service to select one." >&2
      exit 2
    fi
    service="${services[0]}"
  fi

  sg_text="$(aws ecs describe-services "${aws_args[@]}" --cluster "$cluster" --services "$service" --query 'services[0].networkConfiguration.awsvpcConfiguration.securityGroups[]' --output text)"
  if [[ -z "$sg_text" || "$sg_text" == "None" ]]; then
    echo "No security group found on ECS service. Use --sg." >&2
    exit 2
  fi
  read -r -a sgs <<<"$sg_text"
  if (( ${#sgs[@]} != 1 )); then
    echo "Multiple security groups found. Use --sg to select one." >&2
    exit 2
  fi
  sg_id="${sgs[0]}"
fi

if [[ -z "$port" ]]; then
  ports_text="$(aws ec2 describe-security-groups "${aws_args[@]}" --group-ids "$sg_id" \
    --query "SecurityGroups[0].IpPermissions[?IpProtocol=='${protocol}' && FromPort==ToPort && length(IpRanges)>\`0\`].FromPort" \
    --output text)"
  if [[ -z "$ports_text" || "$ports_text" == "None" ]]; then
    echo "No matching ${protocol} rules found. Use --port." >&2
    exit 2
  fi
  read -r -a ports <<<"$ports_text"
  if (( ${#ports[@]} != 1 )); then
    echo "Multiple ${protocol} ports found. Use --port." >&2
    exit 2
  fi
  port="${ports[0]}"
fi

existing_cidr="$(aws ec2 describe-security-groups "${aws_args[@]}" --group-ids "$sg_id" \
  --query "SecurityGroups[0].IpPermissions[?IpProtocol=='${protocol}' && FromPort==\`${port}\` && ToPort==\`${port}\`].IpRanges[?CidrIp=='${cidr}'].CidrIp" \
  --output text)"

if [[ -n "$existing_cidr" && "$existing_cidr" != "None" ]]; then
  echo "${cidr} already allowed on ${protocol}/${port} in ${sg_id}."
  exit 0
fi

aws ec2 authorize-security-group-ingress "${aws_args[@]}" --group-id "$sg_id" \
  --ip-permissions "IpProtocol=${protocol},FromPort=${port},ToPort=${port},IpRanges=[{CidrIp=${cidr},Description=${description}}]"

echo "Added ${cidr} to ${sg_id} on ${protocol}/${port} (region ${region})."
