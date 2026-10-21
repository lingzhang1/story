#!/usr/bin/env node
import "source-map-support/register";
import * as cdk from "aws-cdk-lib";
import { StoryApiStack } from "../lib/story-api-stack";
import { StoryAuthStack } from "../lib/story-auth-stack";

const app = new cdk.App();

// Environment name drives resource naming/config. Milestone A defaults to
// "development"; staging/production use the same definition with different
// context (04-aws-infrastructure.md §7).
const environment =
  (app.node.tryGetContext("environment") as string) ?? "development";

// P0 Beta Observability — opt-in via context (default OFF). `-c observability=true` adds the dashboards/
// alarms/SNS/log-retention construct; nothing is provisioned at synth time.
//   -c alarmDestination=...  SNS notification target (email or https webhook).
//                            PROPOSED default: alerts@yotale.ai (req 6, pending verified email forwarding).
//   -c monthlyBudgetUsd=...  AWS Budgets monthly cap. Beta initial = $100 (req 7), alerts at 50/80/100%.
//   -c createBudget=true     Actually create the AWS Budget. DEFAULT FALSE so this stack never DUPLICATES
//                            B0's account-level budget (req 5): enable here only if B0 does NOT own the
//                            account budget. Alarms/dashboards/SNS are independent of this flag.
const enableObservability = app.node.tryGetContext("observability") === "true";
const alarmDestination =
  (app.node.tryGetContext("alarmDestination") as string | undefined) ?? "alerts@yotale.ai";
const monthlyBudgetUsdCtx = app.node.tryGetContext("monthlyBudgetUsd") as string | undefined;
const createBudget = app.node.tryGetContext("createBudget") === "true";

new StoryApiStack(app, `story-${environment}-api`, {
  environment,
  enableObservability,
  alarmDestination,
  monthlyBudgetUsd: monthlyBudgetUsdCtx ? Number(monthlyBudgetUsdCtx) : undefined,
  createBudget,
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION,
  },
  tags: {
    Project: "Story",
    Environment: environment,
    ManagedBy: "CDK",
  },
});

// P0 Beta Auth (Increment 1) — DESIGN/REVIEW ONLY. The auth stack is instantiated ONLY when explicitly
// requested with `-c deployAuth=true`, so a normal `cdk deploy`/`synth` of the api never touches it. This
// is the pre-provisioning gate in code: nothing in this stack can be created without that flag.
if (app.node.tryGetContext("deployAuth") === "true") {
  new StoryAuthStack(app, `story-${environment}-auth`, {
    environment,
    env: {
      account: process.env.CDK_DEFAULT_ACCOUNT,
      region: process.env.CDK_DEFAULT_REGION,
    },
    tags: { Project: "Story", Environment: environment, ManagedBy: "CDK", Component: "auth" },
  });
}

app.synth();
