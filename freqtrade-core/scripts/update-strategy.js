#!/usr/bin/env node
"use strict";

/*
Update a Freqtrade strategy end-to-end:
1) Update local ecs-taskdef.json so it's in sync.
2) Store the strategy in SSM for persistence across instance rebuilds.
3) Update SSM config.json to point at the strategy name.
4) Copy the strategy to the running EC2 host for immediate use.
5) Register a new ECS task definition and update the service.
*/

const fs = require("fs");
const path = require("path");
const os = require("os");
const { execFileSync } = require("child_process");

function run(cmd, args, opts = {}) {
  execFileSync(cmd, args, { stdio: "inherit", ...opts });
}

function runCapture(cmd, args) {
  return execFileSync(cmd, args, { encoding: "utf8" }).trim();
}

function usageAndExit() {
  const msg = `
Usage:
  node scripts/update-strategy.js --name Strategy002 --file freqtrade/strategy/strategy-1 \\
    --host 43.216.215.179 --key freqtrade-ecs-key.pem

Optional env vars (defaults shown):
  REGION=ap-southeast-5
  CLUSTER=freqtrade-ecs
  SERVICE=freqtrade-service
  TASKDEF_PATH=ecs-taskdef.json
  SSM_CONFIG_PARAM=/freqtrade/config.json
  SSM_STRATEGY_PREFIX=/freqtrade/strategies
`;
  console.error(msg.trim());
  process.exit(1);
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--name") out.name = argv[++i];
    else if (arg === "--file") out.file = argv[++i];
    else if (arg === "--host") out.host = argv[++i];
    else if (arg === "--key") out.key = argv[++i];
    else if (arg === "--help" || arg === "-h") usageAndExit();
    else {
      console.error(`Unknown arg: ${arg}`);
      usageAndExit();
    }
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
if (!args.name || !args.file || !args.host || !args.key) {
  usageAndExit();
}

const region = process.env.REGION || "ap-southeast-5";
const cluster = process.env.CLUSTER || "freqtrade-ecs";
const service = process.env.SERVICE || "freqtrade-service";
const taskdefPath = process.env.TASKDEF_PATH || "ecs-taskdef.json";
const ssmConfigParam = process.env.SSM_CONFIG_PARAM || "/freqtrade/config.json";
const ssmStrategyPrefix = process.env.SSM_STRATEGY_PREFIX || "/freqtrade/strategies";

const strategyName = args.name;
const strategyFile = args.file;
const host = args.host;
const keyPath = args.key;

if (!fs.existsSync(strategyFile)) {
  console.error(`Strategy file not found: ${strategyFile}`);
  process.exit(1);
}

if (!fs.existsSync(taskdefPath)) {
  console.error(`Task definition not found: ${taskdefPath}`);
  process.exit(1);
}

// 1) Update local ecs-taskdef.json
const taskdef = JSON.parse(fs.readFileSync(taskdefPath, "utf8"));
const container = taskdef.containerDefinitions && taskdef.containerDefinitions[0];
if (!container || !Array.isArray(container.command)) {
  console.error("Unexpected ecs-taskdef.json structure.");
  process.exit(1);
}
const cmd = container.command.slice();
const idx = cmd.indexOf("--strategy");
if (idx === -1 || idx === cmd.length - 1) {
  console.error("Could not find '--strategy' in task definition command.");
  process.exit(1);
}
cmd[idx + 1] = strategyName;
container.command = cmd;
fs.writeFileSync(taskdefPath, JSON.stringify(taskdef, null, 2) + "\n", "utf8");
console.log(`Updated ${taskdefPath} to strategy ${strategyName}`);

// 2) Put strategy into SSM
const absStrategyFile = path.resolve(strategyFile);
run("aws", [
  "ssm",
  "put-parameter",
  "--region",
  region,
  "--name",
  `${ssmStrategyPrefix}/${strategyName}.py`,
  "--type",
  "String",
  "--overwrite",
  "--value",
  `file://${absStrategyFile}`,
]);
console.log(`Updated SSM parameter ${ssmStrategyPrefix}/${strategyName}.py`);

// 3) Update config.json in SSM to point to this strategy
const configRaw = runCapture("aws", [
  "ssm",
  "get-parameter",
  "--region",
  region,
  "--name",
  ssmConfigParam,
  "--with-decryption",
]);
const configParam = JSON.parse(configRaw).Parameter;
const configJson = JSON.parse(configParam.Value);
configJson.strategy = strategyName;

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "freqtrade-"));
const tmpConfigPath = path.join(tmpDir, "config.json");
fs.writeFileSync(tmpConfigPath, JSON.stringify(configJson), "utf8");

run("aws", [
  "ssm",
  "put-parameter",
  "--region",
  region,
  "--name",
  ssmConfigParam,
  "--type",
  configParam.Type,
  "--overwrite",
  "--value",
  `file://${tmpConfigPath}`,
]);
console.log(`Updated SSM parameter ${ssmConfigParam} with strategy ${strategyName}`);

// 4) Copy strategy to the running host for immediate use
run("scp", [
  "-i",
  keyPath,
  "-o",
  "StrictHostKeyChecking=accept-new",
  absStrategyFile,
  `ec2-user@${host}:/opt/freqtrade/user_data/strategies/${strategyName}.py`,
]);
console.log(`Copied strategy to EC2 host ${host}`);

// 5) Register task definition and update ECS service
const registerRaw = runCapture("aws", [
  "ecs",
  "register-task-definition",
  "--region",
  region,
  "--cli-input-json",
  `file://${path.resolve(taskdefPath)}`,
]);
const taskDefArn = JSON.parse(registerRaw).taskDefinition.taskDefinitionArn;

run("aws", [
  "ecs",
  "update-service",
  "--region",
  region,
  "--cluster",
  cluster,
  "--service",
  service,
  "--task-definition",
  taskDefArn,
]);
run("aws", [
  "ecs",
  "wait",
  "services-stable",
  "--region",
  region,
  "--cluster",
  cluster,
  "--services",
  service,
]);
console.log(`Deployed ${taskDefArn} and service is stable.`);

