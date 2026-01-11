#!/bin/bash
set -euxo pipefail

REGION="ap-southeast-5"

# Join the ECS cluster
echo "ECS_CLUSTER=freqtrade-ecs" >> /etc/ecs/ecs.config

# Ensure awscli is available for SSM fetch
yum -y install awscli

# Prepare user_data volume for freqtrade
mkdir -p /opt/freqtrade/user_data/strategies /opt/freqtrade/user_data/logs

# Pull config and matching strategy from SSM
aws ssm get-parameter --region "$REGION" --name /freqtrade/config.json --with-decryption --query 'Parameter.Value' --output text > /opt/freqtrade/user_data/config.json
STRATEGY_NAME="$(
  python3 - <<'PY'
import json
with open("/opt/freqtrade/user_data/config.json", "r") as f:
    cfg = json.load(f)
print(cfg.get("strategy", "SimpleStrategy"))
PY
)"
aws ssm get-parameter --region "$REGION" --name "/freqtrade/strategies/${STRATEGY_NAME}.py" --query 'Parameter.Value' --output text > "/opt/freqtrade/user_data/strategies/${STRATEGY_NAME}.py"
