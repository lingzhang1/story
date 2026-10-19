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

new StoryApiStack(app, `story-${environment}-api`, {
  environment,
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
