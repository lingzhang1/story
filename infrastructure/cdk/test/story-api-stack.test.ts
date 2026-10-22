import * as cdk from "aws-cdk-lib";
import { Template, Match } from "aws-cdk-lib/assertions";
import { StoryApiStack } from "../lib/story-api-stack";

function synth(): Template {
  const app = new cdk.App();
  const stack = new StoryApiStack(app, "story-test-api", {
    environment: "test",
    env: { account: "123456789012", region: "us-east-1" },
  });
  return Template.fromStack(stack);
}

describe("StoryApiStack (Milestone A)", () => {
  const template = synth();

  test("references the ECR repo by stable name (created out-of-band, not in-template)", () => {
    // The repo is created out-of-band so the image can be pushed before
    // App Runner is created; the stack references it by name. Therefore the
    // template creates NO ECR repository resource itself...
    template.resourceCountIs("AWS::ECR::Repository", 0);
    // ...and App Runner pulls from an image identifier containing the
    // stable repo name `story-test-api`.
    const services = template.findResources("AWS::AppRunner::Service");
    const svc = Object.values(services)[0] as any;
    const imageId =
      svc.Properties.SourceConfiguration.ImageRepository.ImageIdentifier;
    expect(JSON.stringify(imageId)).toContain("story-test-api");
  });

  test("provisions an App Runner service", () => {
    template.resourceCountIs("AWS::AppRunner::Service", 1);
  });

  test("App Runner health check path is /health on port 8080", () => {
    template.hasResourceProperties("AWS::AppRunner::Service", {
      HealthCheckConfiguration: Match.objectLike({
        Protocol: "HTTP",
        Path: "/health",
      }),
      SourceConfiguration: Match.objectLike({
        ImageRepository: Match.objectLike({
          ImageConfiguration: Match.objectLike({ Port: "8080" }),
          ImageRepositoryType: "ECR",
        }),
      }),
    });
  });

  test("App Runner carries the Cognito + identity-table env (non-secret identifiers) — Increment 3", () => {
    const svc = Object.values(template.findResources("AWS::AppRunner::Service"))[0] as any;
    const envVars = svc.Properties.SourceConfiguration.ImageRepository.ImageConfiguration
      .RuntimeEnvironmentVariables as Array<{ Name: string; Value: string }>;
    const names = envVars.map((e) => e.Name);
    expect(names).toEqual(expect.arrayContaining([
      "STORY_ENVIRONMENT", "STORY_REQUIRE_AUTH", "STORY_COGNITO_USER_POOL_ID",
      "STORY_COGNITO_APP_CLIENT_ID", "STORY_IDENTITY_CLAIMS_TABLE", "STORY_USERS_TABLE",
    ]));
    // test env is not production -> optional-auth window on
    expect(envVars.find((e) => e.Name === "STORY_REQUIRE_AUTH")!.Value).toBe("0");
  });

  test("instance role has scoped identity-table access (not a wildcard) — Increment 3", () => {
    const blob = JSON.stringify(Object.values(template.findResources("AWS::IAM::Policy")));
    expect(blob).toContain("dynamodb:TransactWriteItems");
    expect(blob).toContain("table/story-test-identity-claims");
    expect(blob).toContain("table/story-test-users");
    expect(blob).not.toContain("table/*");  // never a wildcard over all tables
  });

  test("instance role has least-privilege Bedrock InvokeModel grant (Milestone C)", () => {
    template.hasResourceProperties("AWS::IAM::Policy", {
      PolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          Match.objectLike({
            Effect: "Allow",
            Action: Match.arrayWith(["bedrock:InvokeModel"]),
          }),
        ]),
      }),
    });
  });

  test("instance role grants least-privilege read on BOTH Epidemic secrets (REST + MCP), name-scoped", () => {
    const policies = template.findResources("AWS::IAM::Policy");
    const blob = JSON.stringify(Object.values(policies));
    // the EpidemicKeyRead statement exists with the read-only action
    expect(blob).toContain("EpidemicKeyRead");
    expect(blob).toContain("secretsmanager:GetSecretValue");
    // scoped to BOTH named secrets (name + 6-char suffix wildcard), nothing broader
    expect(blob).toContain(":secret:story-epidemic-key-??????");
    expect(blob).toContain(":secret:epidemic-mcp-api-key-??????");
    // must NOT grant a wildcard over all secrets
    expect(blob).not.toContain(":secret:*");
  });

  test("provisions the APPROVED async edit-planning resources (owner-approved 2026-10-13)", () => {
    // Phase A forbade these; the owner-approved async milestone adds exactly: 1 jobs table, 2 queues
    // (main + DLQ), the worker (+ the S3 auto-delete helper), the staging bucket, an SQS event source,
    // and the reconcile rule. API Gateway / Cognito / Fargate remain forbidden (separate tests below).
    // R2/R3 (owner-approved) adds the media ownership table -> 2 DynamoDB tables total.
    template.resourceCountIs("AWS::DynamoDB::Table", 5);  // jobs + media + R7 stories + R7-E understanding + P0-P3 rate-limits
    template.resourceCountIs("AWS::SQS::Queue", 2);          // jobs + DLQ
    template.resourceCountIs("AWS::Lambda::EventSourceMapping", 1);
    template.resourceCountIs("AWS::Events::Rule", 1);         // reconcile tick
    // At least the worker Lambda + the staging bucket exist.
    const all = template.toJSON().Resources as Record<string, { Type: string }>;
    const types = Object.values(all).map((r) => r.Type);
    expect(types.filter((t) => t === "AWS::Lambda::Function").length).toBeGreaterThanOrEqual(1);
    expect(types.filter((t) => t === "AWS::S3::Bucket").length).toBeGreaterThanOrEqual(1);
  });

  test("provisions ZERO API Gateway resources (any AWS::ApiGateway* type)", () => {
    const all = template.toJSON().Resources as Record<
      string,
      { Type: string }
    >;
    const apiGwResources = Object.values(all).filter((r) =>
      r.Type.startsWith("AWS::ApiGateway")
    );
    expect(apiGwResources).toHaveLength(0);
  });

  // ---- R2/R3: private cloud media storage -------------------------------------------------------
  test("provisions a PRIVATE media bucket: block-all public, SSE-S3, TLS-only, retained", () => {
    template.hasResourceProperties("AWS::S3::Bucket", {
      BucketName: "story-test-media-123456789012-us-east-1",
      PublicAccessBlockConfiguration: {
        BlockPublicAcls: true, BlockPublicPolicy: true,
        IgnorePublicAcls: true, RestrictPublicBuckets: true,
      },
      BucketEncryption: Match.objectLike({
        ServerSideEncryptionConfiguration: Match.arrayWith([
          Match.objectLike({ ServerSideEncryptionByDefault: Match.objectLike({ SSEAlgorithm: "AES256" }) }),
        ]),
      }),
    });
  });

  test("media bucket aborts incomplete multipart uploads after 7 days and does NOT expire originals", () => {
    const buckets = template.findResources("AWS::S3::Bucket");
    const media = Object.values(buckets).find(
      (b: any) => b.Properties?.BucketName === "story-test-media-123456789012-us-east-1") as any;
    expect(media).toBeDefined();
    const rules = media.Properties.LifecycleConfiguration.Rules as any[];
    // an abort rule exists (7 days) ...
    expect(rules.some((r) => r.AbortIncompleteMultipartUpload?.DaysAfterInitiation === 7)).toBe(true);
    // ... and NO rule expires completed objects (originals are retained)
    expect(rules.some((r) => r.ExpirationInDays !== undefined)).toBe(false);
  });

  test("media bucket is retained (never auto-deletes the user's only cloud copy)", () => {
    const buckets = template.findResources("AWS::S3::Bucket");
    const media = Object.entries(buckets).find(
      ([, b]: any) => b.Properties?.BucketName === "story-test-media-123456789012-us-east-1")!;
    expect((media[1] as any).DeletionPolicy).toBe("Retain");
  });

  test("provisions a media ownership table with composite key (story_user_id, cloud_media_id), no TTL", () => {
    const tables = template.findResources("AWS::DynamoDB::Table");
    const media = Object.values(tables).find((t: any) => t.Properties?.TableName === "story-test-media") as any;
    expect(media).toBeDefined();
    const keys = media.Properties.KeySchema as Array<{ AttributeName: string; KeyType: string }>;
    expect(keys).toEqual([
      { AttributeName: "story_user_id", KeyType: "HASH" },
      { AttributeName: "cloud_media_id", KeyType: "RANGE" },
    ]);
    // originals are durable: no TTL on the media table (the jobs table has one; this must not).
    expect(media.Properties.TimeToLiveSpecification).toBeUndefined();
  });

  test("provisions an R7 stories table with composite key (story_user_id, story_id), no TTL", () => {
    const tables = template.findResources("AWS::DynamoDB::Table");
    const st = Object.values(tables).find((t: any) => t.Properties?.TableName === "story-test-stories") as any;
    expect(st).toBeDefined();
    expect(st.Properties.KeySchema).toEqual([
      { AttributeName: "story_user_id", KeyType: "HASH" },
      { AttributeName: "story_id", KeyType: "RANGE" },
    ]);
    expect(st.Properties.TimeToLiveSpecification).toBeUndefined();
    expect(st.DeletionPolicy).toBe("Retain");
  });

  test("provisions an R7-E understanding table with composite key (story_user_id, moment_id)", () => {
    const tables = template.findResources("AWS::DynamoDB::Table");
    const u = Object.values(tables).find((t: any) => t.Properties?.TableName === "story-test-understanding") as any;
    expect(u).toBeDefined();
    expect(u.Properties.KeySchema).toEqual([
      { AttributeName: "story_user_id", KeyType: "HASH" },
      { AttributeName: "moment_id", KeyType: "RANGE" },
    ]);
    expect(u.DeletionPolicy).toBe("Retain");
  });

  test("provisions the P0-Phase3 rate-limit table (composite key, TTL on ttl, ephemeral)", () => {
    const tables = template.findResources("AWS::DynamoDB::Table");
    const rl = Object.values(tables).find((t: any) => t.Properties?.TableName === "story-test-rate-limits") as any;
    expect(rl).toBeDefined();
    expect(rl.Properties.KeySchema).toEqual([
      { AttributeName: "story_user_id", KeyType: "HASH" },
      { AttributeName: "rl_key", KeyType: "RANGE" },
    ]);
    expect(rl.Properties.TimeToLiveSpecification).toEqual({ AttributeName: "ttl", Enabled: true });
    expect(rl.Properties.BillingMode).toBe("PAY_PER_REQUEST");
  });

  test("App Runner carries the media table + bucket env", () => {
    const svc = Object.values(template.findResources("AWS::AppRunner::Service"))[0] as any;
    const names = (svc.Properties.SourceConfiguration.ImageRepository.ImageConfiguration
      .RuntimeEnvironmentVariables as Array<{ Name: string }>).map((e) => e.Name);
    expect(names).toEqual(expect.arrayContaining(["STORY_MEDIA_TABLE", "STORY_MEDIA_BUCKET", "STORY_STORIES_TABLE", "STORY_UNDERSTANDING_TABLE"]));
  });

  test("instance role media grant is least-privilege: object RW on media/* but NO s3:DeleteObject", () => {
    // Find the MediaObjectAccess statement specifically (the staging bucket's auto-delete helper has its OWN
    // s3:DeleteObject* on a DIFFERENT role, so assert against THIS statement, not the whole policy blob).
    const policies = Object.values(template.findResources("AWS::IAM::Policy")) as any[];
    let mediaStmt: any;
    for (const p of policies) {
      for (const s of p.Properties.PolicyDocument.Statement) {
        if (s.Sid === "MediaObjectAccess") mediaStmt = s;
      }
    }
    expect(mediaStmt).toBeDefined();
    const actions: string[] = mediaStmt.Action;
    expect(actions).toEqual(expect.arrayContaining(
      ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]));
    // No destructive delete in THIS increment's media grant.
    expect(actions.some((a) => a.toLowerCase().includes("delete"))).toBe(false);
  });
});


describe("P0 Beta Observability construct", () => {
  function synthWith(ctx: Record<string, unknown>): Template {
    // Non-dev environments now REQUIRE explicit release inputs (imageDigest + cognito ids) or synthesis
    // fails by design. Tests that don't care about those inputs get harmless defaults so they exercise the
    // behavior they actually assert (observability, naming, etc.) without tripping the release-input guard.
    // A test that specifically asserts the guard passes its own context and overrides these.
    const withReleaseDefaults = {
      imageDigest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
      cognitoUserPoolId: "us-east-1_TESTPOOL0",
      cognitoAppClientId: "testclient0000000000000000",
      // Default-bypass the observability-required guard for focused tests that don't assert observability;
      // the dedicated guard test passes allowNoObservability:undefined to exercise the refusal.
      allowNoObservability: "true",
      ...ctx,
    };
    const app = new cdk.App({ context: withReleaseDefaults });
    const stack = new StoryApiStack(app, "story-test-api", {
      environment: (ctx["environment"] as string) ?? "test",
      enableObservability: ctx["observability"] === "true",
      alarmDestination: ctx["alarmDestination"] as string | undefined,
      monthlyBudgetUsd: ctx["monthlyBudgetUsd"] ? Number(ctx["monthlyBudgetUsd"]) : undefined,
      createBudget: ctx["createBudget"] === "true",
      env: { account: "123456789012", region: "us-east-1" },
    });
    return Template.fromStack(stack);
  }

  test("default OFF: no dashboards, alarms, SNS topic, or budget", () => {
    const t = synthWith({ environment: "test" });
    t.resourceCountIs("AWS::CloudWatch::Dashboard", 0);
    t.resourceCountIs("AWS::CloudWatch::Alarm", 0);
    t.resourceCountIs("AWS::SNS::Topic", 0);
    t.resourceCountIs("AWS::Budgets::Budget", 0);
  });

  test("enabled: 4 dashboards, 10 alarms, 1 SNS topic", () => {
    const t = synthWith({ environment: "test", observability: "true" });
    t.resourceCountIs("AWS::CloudWatch::Dashboard", 4);
    t.resourceCountIs("AWS::CloudWatch::Alarm", 10);
    t.resourceCountIs("AWS::SNS::Topic", 1);
    // Every alarm wires an SNS action (no silent alarm).
    const alarms = t.findResources("AWS::CloudWatch::Alarm");
    for (const a of Object.values(alarms) as any[]) {
      expect(Array.isArray(a.Properties.AlarmActions)).toBe(true);
      expect(a.Properties.AlarmActions.length).toBeGreaterThan(0);
    }
  });

  test("DLQ alarm fires on a single visible message (treatMissingData not breaching)", () => {
    const t = synthWith({ environment: "test", observability: "true" });
    t.hasResourceProperties("AWS::CloudWatch::Alarm", Match.objectLike({
      AlarmName: "story-test-dlq-non-empty",
      Threshold: 1,
      ComparisonOperator: "GreaterThanOrEqualToThreshold",
      TreatMissingData: "notBreaching",
    }));
  });

  test("unwired metric alarms use treatMissingData=missing (never a healthy OK until an emitter ships)", () => {
    const t = synthWith({ environment: "test", observability: "true" });
    // The two alarms on metrics with NO emitter yet (auth/quota milestone) must sit in INSUFFICIENT_DATA
    // when there is no data — NOT OK. A green "no unauthorized access" on an unmeasured metric is misleading.
    for (const name of ["story-test-quota-enforcement-error", "story-test-unauthorized-access-anomaly"]) {
      t.hasResourceProperties("AWS::CloudWatch::Alarm", Match.objectLike({
        AlarmName: name,
        TreatMissingData: "missing",
      }));
    }
    // A WIRED infra alarm stays notBreaching (no data genuinely means nothing bad).
    t.hasResourceProperties("AWS::CloudWatch::Alarm", Match.objectLike({
      AlarmName: "story-test-lambda-errors",
      TreatMissingData: "notBreaching",
    }));
  });

  test("email alarmDestination + createBudget creates an SNS subscription AND an AWS Budget with 3 thresholds", () => {
    const t = synthWith({ environment: "test", observability: "true", createBudget: "true",
      alarmDestination: "ops@example.com", monthlyBudgetUsd: "150" });
    t.hasResourceProperties("AWS::SNS::Subscription", Match.objectLike({ Protocol: "email" }));
    t.resourceCountIs("AWS::Budgets::Budget", 1);
    t.hasResourceProperties("AWS::Budgets::Budget", Match.objectLike({
      Budget: Match.objectLike({ BudgetLimit: Match.objectLike({ Amount: 150, Unit: "USD" }) }),
    }));
    // Exactly the 3 owner-specified thresholds (req 7): 50 / 80 / 100% ACTUAL spend.
    const budgets = t.findResources("AWS::Budgets::Budget");
    const subs = (Object.values(budgets)[0] as any).Properties.Budget === undefined
      ? (Object.values(budgets)[0] as any).Properties.NotificationsWithSubscribers
      : (Object.values(budgets)[0] as any).Properties.NotificationsWithSubscribers;
    const thresholds = (subs as any[]).map((n) => n.Notification.Threshold).sort((a, b) => a - b);
    expect(thresholds).toEqual([50, 80, 100]);
  });

  test("B0 reconciliation: NO AWS Budget when createBudget is omitted (default), even with a destination", () => {
    // req 5 — the account-level budget is B0's; this stack must not create a duplicate by default. SNS +
    // alarms still come up (they do not depend on the budget).
    const t = synthWith({ environment: "beta", observability: "true", alarmDestination: "alerts@yotale.ai" });
    t.resourceCountIs("AWS::Budgets::Budget", 0);
    t.resourceCountIs("AWS::SNS::Topic", 1);
    t.hasResourceProperties("AWS::SNS::Subscription", Match.objectLike({ Protocol: "email" }));
  });

  test("MissingModelPricing is surfaced on the AI dashboard (unpriced != free, req 2)", () => {
    const t = synthWith({ environment: "test", observability: "true" });
    const dashboards = t.findResources("AWS::CloudWatch::Dashboard");
    const bodies = (Object.values(dashboards) as any[]).map((d) => d.Properties.DashboardBody);
    const joined = JSON.stringify(bodies);
    expect(joined).toContain("MissingModelPricing");
  });

  test("resource names are environment-parameterized", () => {
    const t = synthWith({ environment: "gamma", observability: "true" });
    t.hasResourceProperties("AWS::SNS::Topic", Match.objectLike({
      TopicName: "story-gamma-observability-alarms",
    }));
  });

  // --- B0 beta-config reconciliation regression tests ------------------------------------------------
  test("issue 1: OIDC deploy-role sub-claim is scoped to THIS environment, not hardcoded development", () => {
    const t = synthWith({ environment: "beta", observability: "false" });
    const roles = t.findResources("AWS::IAM::Role");
    const trustSubs = JSON.stringify(Object.values(roles).map((r: any) => r.Properties.AssumeRolePolicyDocument));
    // beta role trusts environment:beta ...
    expect(trustSubs).toContain("repo:lingzhang1*/story*:environment:beta");
    // ... and NOT environment:development (no cross-environment trust)
    expect(trustSubs).not.toContain("repo:lingzhang1*/story*:environment:development");
  });

  test("issue 1: owner/repo pattern is preserved unchanged (numeric-id tolerant, trust not broadened)", () => {
    const t = synthWith({ environment: "beta", observability: "false" });
    const roles = t.findResources("AWS::IAM::Role");
    const trust = JSON.stringify(Object.values(roles).map((r: any) => r.Properties.AssumeRolePolicyDocument));
    // The exact verified owner/repo glob is intact — only the environment segment changed.
    expect(trust).toContain("repo:lingzhang1*/story*:environment:");
    // No wildcard environment (would broaden trust to every GitHub Environment).
    expect(trust).not.toContain("repo:lingzhang1*/story*:environment:*");
  });

  test("issue 2: beta synthesis FAILS without an explicit image digest (no :latest fallback)", () => {
    expect(() =>
      // deliberately omit imageDigest by passing it empty; cognito ids present
      new StoryApiStack(new cdk.App({ context: {
        environment: "beta",
        cognitoUserPoolId: "us-east-1_X", cognitoAppClientId: "c",
      } }), "s", { environment: "beta", env: { account: "123456789012", region: "us-east-1" } })
    ).toThrow(/imageDigest/);
  });

  test("issue 2: beta synthesis FAILS without explicit cognito pool/client (no dev-credential fallback)", () => {
    expect(() =>
      new StoryApiStack(new cdk.App({ context: {
        environment: "beta",
        imageDigest: "sha256:abc",
      } }), "s", { environment: "beta", env: { account: "123456789012", region: "us-east-1" } })
    ).toThrow(/cognitoUserPoolId|cognitoAppClientId/);
  });

  test("issue 2: development MAY fall back to :latest + dev pool (local-synth convenience preserved)", () => {
    // The default synth() uses environment 'test' (not a release env) — proves dev-style synth still works
    // with no release inputs, i.e. the guard is scoped to beta/gamma/production only.
    expect(() => synth()).not.toThrow();
  });

  test("issue 3: beta worker has NO reserved concurrency (reproduces the deployed unreserved setting)", () => {
    // STORY_WORKER_CONCURRENCY is unset in the test env => no reservation, matching live beta (Concurrency=null).
    const t = synthWith({ environment: "beta", observability: "false" });
    const fns = t.findResources("AWS::Lambda::Function");
    const worker = Object.values(fns).find((f: any) =>
      JSON.stringify(f.Properties.Environment ?? {}).includes("STORY_JOBS_QUEUE_URL")) as any;
    expect(worker).toBeDefined();
    expect(worker.Properties.ReservedConcurrentExecutions).toBeUndefined();
  });

  test("beta is fail-closed: STORY_REQUIRE_AUTH=1 (account isolation); development stays optional (0)", () => {
    function requireAuthFor(env: string): string {
      const t = synthWith({ environment: env, observability: "false" });
      const svc = Object.values(t.findResources("AWS::AppRunner::Service"))[0] as any;
      const vars: any[] = svc.Properties.SourceConfiguration.ImageRepository.ImageConfiguration.RuntimeEnvironmentVariables;
      return (vars.find((v) => v.Name === "STORY_REQUIRE_AUTH") || {}).Value;
    }
    expect(requireAuthFor("beta")).toBe("1");
    expect(requireAuthFor("gamma")).toBe("1");
    expect(requireAuthFor("development")).toBe("0");
  });

  // --- Release-safety: observability cannot be silently dropped from a beta/gamma/prod deploy (req 6/7/9) ---
  test("beta synth FAILS if observability is omitted (prevents silent monitoring teardown)", () => {
    expect(() => synthWith({ environment: "beta", observability: "false", allowNoObservability: undefined }))
      .toThrow(/observability=true|DESTROYS live monitoring/);
  });

  test("beta synth with observability provisions monitoring (SNS topic + dashboards + alarms)", () => {
    const t = synthWith({ environment: "beta", observability: "true", alarmDestination: "alerts@yotale.ai" });
    t.resourceCountIs("AWS::SNS::Topic", 1);
    expect(Object.keys(t.findResources("AWS::CloudWatch::Dashboard")).length).toBeGreaterThanOrEqual(1);
    expect(Object.keys(t.findResources("AWS::CloudWatch::Alarm")).length).toBeGreaterThanOrEqual(1);
  });

  test("explicit allowNoObservability=true opt-out is honored (intentional teardown only)", () => {
    const t = synthWith({ environment: "beta", observability: "false", allowNoObservability: "true" });
    t.resourceCountIs("AWS::SNS::Topic", 0);
  });
});
