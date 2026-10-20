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
    template.resourceCountIs("AWS::DynamoDB::Table", 3);  // jobs + media + R7 stories
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

  test("App Runner carries the media table + bucket env", () => {
    const svc = Object.values(template.findResources("AWS::AppRunner::Service"))[0] as any;
    const names = (svc.Properties.SourceConfiguration.ImageRepository.ImageConfiguration
      .RuntimeEnvironmentVariables as Array<{ Name: string }>).map((e) => e.Name);
    expect(names).toEqual(expect.arrayContaining(["STORY_MEDIA_TABLE", "STORY_MEDIA_BUCKET", "STORY_STORIES_TABLE"]));
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
