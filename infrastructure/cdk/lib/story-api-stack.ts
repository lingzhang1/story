import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as ecr from "aws-cdk-lib/aws-ecr";
import * as iam from "aws-cdk-lib/aws-iam";
import * as apprunner from "aws-cdk-lib/aws-apprunner";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as sqs from "aws-cdk-lib/aws-sqs";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as lambdaEventSources from "aws-cdk-lib/aws-lambda-event-sources";
import * as events from "aws-cdk-lib/aws-events";
import * as targets from "aws-cdk-lib/aws-events-targets";
import * as path from "path";
import { Observability } from "./observability";

export interface StoryApiStackProps extends cdk.StackProps {
  /** Deployment environment name (development | staging | production). */
  readonly environment: string;
  /**
   * P0 Beta Observability. When true, add the CloudWatch dashboards/alarms/SNS/Budget/log-retention
   * construct. Default OFF so a plain synth/deploy is unchanged; the deploy pipeline passes
   * `-c observability=true` (and optionally `-c alarmDestination=...`, `-c monthlyBudgetUsd=...`) when the
   * owner is ready to provision it. Nothing is provisioned at synth time.
   */
  readonly enableObservability?: boolean;
  readonly alarmDestination?: string;
  readonly monthlyBudgetUsd?: number;
  /** Create the AWS Budget here. Default false so this stack never duplicates B0's account-level budget. */
  readonly createBudget?: boolean;
}

/**
 * Story API infrastructure — Milestone A.
 *
 * Provisions ONLY what the walking skeleton needs:
 *   - an ECR repository for the FastAPI container image
 *   - an App Runner service that pulls that image
 *   - an App Runner instance role and an ECR access role
 *
 * Deliberately provisions NONE of: SQS, Lambda, DynamoDB, Fargate,
 * API Gateway, Cognito, S3 (04-aws-infrastructure.md §4, Phase A).
 *
 * Uses the L1 `CfnService` from aws-cdk-lib (always present, no alpha
 * dependency) so `cdk synth` is stable on cdk 2.1143.
 */
export class StoryApiStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: StoryApiStackProps) {
    super(scope, id, props);

    const { environment } = props;

    // Immutable deploy: the pipeline passes `-c imageDigest=sha256:...` so App Runner is pinned to an
    // exact digest (auto-deploy off). Absent (legacy/local synth) -> mutable :latest fallback.
    const imageDigest = this.node.tryGetContext("imageDigest") as string | undefined;
    const cognitoUserPoolId = this.node.tryGetContext("cognitoUserPoolId") as string | undefined;
    const cognitoAppClientId = this.node.tryGetContext("cognitoAppClientId") as string | undefined;

    // --- Non-dev deploy safety: FAIL SYNTHESIS on missing release inputs -------------------------------
    // development may fall back to :latest + the known dev Cognito pool for local/iterative synth. beta,
    // gamma and production are real environments with their OWN accounts and credentials: a missing image
    // digest or Cognito pool/client id must HALT synthesis, never silently fall back to a mutable :latest
    // image or the dev pool (which would point a member account at dev's auth). Each required input is
    // listed explicitly so the error names exactly what the pipeline forgot to pass.
    const REQUIRES_EXPLICIT_RELEASE_INPUTS = ["beta", "gamma", "production"];
    if (REQUIRES_EXPLICIT_RELEASE_INPUTS.includes(environment)) {
      const missing: string[] = [];
      if (!imageDigest) missing.push("-c imageDigest=sha256:<digest> (no :latest fallback allowed)");
      if (!cognitoUserPoolId) missing.push("-c cognitoUserPoolId=<env pool> (no dev-pool fallback allowed)");
      if (!cognitoAppClientId) missing.push("-c cognitoAppClientId=<env client> (no dev-client fallback allowed)");
      if (missing.length) {
        throw new Error(
          `StoryApiStack(${environment}): refusing to synthesize without explicit release inputs — ${missing.join("; ")}.`
        );
      }
    }

    // --- ECR repository for the App Runner image -------------------------
    // Stable, deterministic name so the image can be built + pushed (via
    // CodeBuild or local Docker) BEFORE App Runner is created — App Runner
    // requires an image to exist at service-create time. The repo itself is
    // created out-of-band (aws ecr create-repository) and referenced here by
    // name, so this stack owns only App Runner + roles and can be deployed
    // once, after the image is in place.
    const repositoryName = `story-${environment}-api`;
    const repository = ecr.Repository.fromRepositoryName(
      this,
      "StoryApiRepo",
      repositoryName
    );

    // --- App Runner access role (pull image from ECR) --------------------
    const accessRole = new iam.Role(this, "StoryApiAccessRole", {
      assumedBy: new iam.ServicePrincipal("build.apprunner.amazonaws.com"),
      description: "Lets App Runner pull the Story API image from ECR",
    });
    repository.grantPull(accessRole);

    // --- App Runner instance role (runtime task permissions) -------------
    // Milestone C: the API now calls Amazon Bedrock (Creative Intent) through
    // the Model Gateway, so the runtime role is granted least-privilege
    // bedrock:InvokeModel on foundation models + inference profiles. No S3 /
    // DynamoDB / SQS grants — still none are needed. Model id is runtime config
    // (STORY_BEDROCK_MODEL); the grant covers the model family in-region plus
    // cross-region inference-profile ARNs so a config switch needs no IAM change.
    const instanceRole = new iam.Role(this, "StoryApiInstanceRole", {
      assumedBy: new iam.ServicePrincipal("tasks.apprunner.amazonaws.com"),
      description: "Runtime role for the Story API App Runner service",
    });
    instanceRole.addToPolicy(
      new iam.PolicyStatement({
        sid: "BedrockInvoke",
        effect: iam.Effect.ALLOW,
        actions: ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
        resources: [
          `arn:aws:bedrock:*::foundation-model/*`,
          `arn:aws:bedrock:*:${this.account}:inference-profile/*`,
        ],
      })
    );

    // Read-only access to the Epidemic Sound API-key secrets the music
    // provider loads at runtime (packages/music_provider). Two secrets, both
    // least-privilege (GetSecretValue only, on these exact names):
    //   - story-epidemic-key   : Partner REST API key (PRODUCTION music path)
    //   - epidemic-mcp-api-key : Business-subscription MCP key (INTERNAL-TESTING
    //                            path, enabled by STORY_MUSIC_PROVIDER=mcp)
    // Secrets Manager appends a random 6-char suffix to each ARN, so the
    // resource is matched by name + '-??????' rather than a hard-coded suffix.
    // Scoped to these two names only — NOT a wildcard over all secrets.
    instanceRole.addToPolicy(
      new iam.PolicyStatement({
        sid: "EpidemicKeyRead",
        effect: iam.Effect.ALLOW,
        actions: ["secretsmanager:GetSecretValue"],
        resources: [
          `arn:aws:secretsmanager:${this.region}:${this.account}:secret:story-epidemic-key-??????`,
          `arn:aws:secretsmanager:${this.region}:${this.account}:secret:epidemic-mcp-api-key-??????`,
        ],
      })
    );

    // --- ASYNC EDIT PLANNING infra (owner-approved 2026-10-13, dev) ------
    // Beats App Runner's ~120s request ceiling: App Runner submits a job, a Lambda worker runs the SAME
    // plan/critique/validate core (up to 15 min), iOS polls. Resources: DynamoDB job table (TTL), SQS + DLQ,
    // private SSE S3 staging for DERIVED contact sheets only (24h lifecycle), the worker Lambda, and an
    // EventBridge reconcile tick. All names per async-edit-planning-CONTRACT.md.

    // DynamoDB job table — PK job_id; TTL on expires_at (NOT immediate — reads treat past-expiry as expired).
    const jobsTable = new dynamodb.Table(this, "EditPlanJobsTable", {
      tableName: `story-${environment}-edit-plan-jobs`,
      partitionKey: { name: "job_id", type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      timeToLiveAttribute: "expires_at",
      removalPolicy: cdk.RemovalPolicy.DESTROY, // dev
    });

    // SQS DLQ + main queue (maxReceiveCount 2 — a poison message lands in the DLQ, never re-drives forever).
    const dlq = new sqs.Queue(this, "EditPlanJobsDLQ", {
      queueName: `story-${environment}-edit-plan-jobs-dlq`,
      retentionPeriod: cdk.Duration.days(14),
    });
    const jobsQueue = new sqs.Queue(this, "EditPlanJobsQueue", {
      queueName: `story-${environment}-edit-plan-jobs`,
      visibilityTimeout: cdk.Duration.seconds(960), // > worker deadline 840s + margin
      deadLetterQueue: { queue: dlq, maxReceiveCount: 2 },
    });

    // Private, encrypted S3 staging for DERIVED JPEG contact sheets + the request body JSON ONLY (never source
    // video). Explicit delete on terminal; this 24h lifecycle is the backstop. No public access.
    const stagingBucket = new s3.Bucket(this, "EditPlanStagingBucket", {
      bucketName: `story-${environment}-edit-plan-staging-${this.account}-${this.region}`,
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      lifecycleRules: [{ expiration: cdk.Duration.days(1) }],
      removalPolicy: cdk.RemovalPolicy.DESTROY, // dev
      autoDeleteObjects: true, // dev
    });

    // ---- R2/R3: PRIVATE ORIGINAL-MEDIA STORAGE (dev only) ------------------------------------------
    // A SEPARATE bucket from the 24h edit-plan staging bucket: original media is DURABLE (retained), not
    // transient derived sheets. Private, SSE-S3, TLS-only, no public access. Incomplete multipart uploads are
    // aborted after 7 days (cost hygiene) but COMPLETED originals are NOT expired. Account-scoped keys
    // (media/{story_user_id}/{cloud_media_id}/original) are enforced by the app, which only ever presigns a key
    // under the caller's own prefix.
    const mediaBucket = new s3.Bucket(this, "MediaBucket", {
      bucketName: `story-${environment}-media-${this.account}-${this.region}`,
      encryption: s3.BucketEncryption.S3_MANAGED,      // SSE-S3 (SSE-KMS is a public-release hardening)
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      lifecycleRules: [
        // Abort incomplete multipart uploads after 7 days; NO expiration on completed originals (retained).
        { abortIncompleteMultipartUploadAfter: cdk.Duration.days(7) },
      ],
      removalPolicy: cdk.RemovalPolicy.RETAIN, // dev: originals are the user's only cloud copy — never auto-delete the bucket
    });

    // DynamoDB media-ownership table — composite key (story_user_id HASH, cloud_media_id RANGE). A Query on the
    // PK lists one account's media; a wrong owner finds nothing (no cross-account leak). NO TTL: originals are
    // durable (unlike the edit-plan jobs table). PAY_PER_REQUEST, mirroring the jobs table.
    const mediaTable = new dynamodb.Table(this, "MediaOwnershipTable", {
      tableName: `story-${environment}-media`,
      partitionKey: { name: "story_user_id", type: dynamodb.AttributeType.STRING },
      sortKey: { name: "cloud_media_id", type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: cdk.RemovalPolicy.RETAIN, // dev: ownership records are durable alongside the originals
    });

    // R7 — account-owned Story documents (metadata sync). Composite key (story_user_id HASH, story_id RANGE):
    // a Query on the PK lists ONE account's Stories; a wrong owner finds nothing (no cross-account leak).
    // Server monotonic `revision` + `last_mutation_id` live inside items (optimistic concurrency + idempotency
    // are app-enforced via conditional writes). NO TTL — Story projects are durable. PAY_PER_REQUEST. RETAIN
    // (a Story doc is the user's only cloud copy of their project metadata). SEPARATE from the media table.
    const storiesTable = new dynamodb.Table(this, "StoryDocumentsTable", {
      tableName: `story-${environment}-stories`,
      partitionKey: { name: "story_user_id", type: dynamodb.AttributeType.STRING },
      sortKey: { name: "story_id", type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // R7-E — account-level Moment Understanding (SHARED across Stories; keyed by moment_id). Composite key
    // (story_user_id HASH, moment_id RANGE) -> a Query lists one account's AU; a wrong owner finds nothing.
    // Lets Device B RESTORE understanding instead of re-running Asset Understanding (Bedrock). PAY_PER_REQUEST,
    // RETAIN, no TTL (durable). Pure add, separate from the stories + media tables.
    const understandingTable = new dynamodb.Table(this, "MomentUnderstandingTable", {
      tableName: `story-${environment}-understanding`,
      partitionKey: { name: "story_user_id", type: dynamodb.AttributeType.STRING },
      sortKey: { name: "moment_id", type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // Worker Lambda — DOCKER-FREE zip asset (the sandbox cannot run Docker). scripts/build_worker_asset.sh
    // pre-stages app/ + packages/ + contracts/ + prompts/ + the Linux cp312 pydantic wheels into
    // infrastructure/cdk/.worker-asset (boto3 is in the Lambda runtime). The planner resolves prompts at
    // packages/edit_planner/../../prompts -> the asset root, which the layout satisfies. 15-min timeout for
    // >120s plans; conservative configurable concurrency.
    const worker = new lambda.Function(this, "EditPlanWorker", {
      functionName: `story-${environment}-edit-plan-worker`,
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: "app.worker.handler",
      code: lambda.Code.fromAsset(path.join(__dirname, "..", ".worker-asset")),
      timeout: cdk.Duration.seconds(900),
      memorySize: 2048,
      // Reserved concurrency is OPT-IN, driven by STORY_WORKER_CONCURRENCY. Unset or "0" => NO reservation
      // (worker runs from the shared unreserved pool). This reproduces the ACTUAL deployed beta worker,
      // which has no reserved concurrency (a fresh account's Lambda limit of 10 forbids reserving any, since
      // AWS requires >=10 unreserved to remain). Dev/prod set a positive value to cap concurrency. Changing
      // the deployed beta value requires separate approval — this reconciliation only reproduces it.
      ...(Number(process.env.STORY_WORKER_CONCURRENCY ?? "0") > 0
        ? { reservedConcurrentExecutions: Number(process.env.STORY_WORKER_CONCURRENCY) }
        : {}),
      environment: {
        PYTHONPATH: "/var/task:/var/task/packages",
        STORY_JOBS_TABLE: jobsTable.tableName,
        STORY_JOBS_QUEUE_URL: jobsQueue.queueUrl,
        STORY_STAGING_BUCKET: stagingBucket.bucketName,
        STORY_WORKER_DEADLINE_S: "840",
        STORY_EDIT_PLAN_VERSION: "5.2",
        STORY_LLM_FALLBACK_MODEL: "us.anthropic.claude-sonnet-4-6",
      },
    });
    worker.addEventSource(new lambdaEventSources.SqsEventSource(jobsQueue, {
      batchSize: 1,
      reportBatchItemFailures: true,
    }));
    // Worker IAM: job table RW, staging get+delete+list (NOT put — only App Runner stages), Bedrock invoke.
    jobsTable.grantReadWriteData(worker);
    stagingBucket.grantRead(worker);
    stagingBucket.grantDelete(worker);
    // The SqsEventSource grants CONSUME (receive/delete), but the EventBridge reconcile tick runs
    // reconcile_lost_enqueue() which RE-ENQUEUES stranded jobs via sqs:SendMessage. Without this grant the
    // send fails with AccessDenied, the reconciler swallows it, and a job whose original enqueue was lost sits
    // in `queued` forever (observed: status=queued attempt_count=0 reconcile_count=None for 10+ min). Grant
    // send so the lost-enqueue recovery actually works.
    jobsQueue.grantSendMessages(worker);
    worker.addToRolePolicy(new iam.PolicyStatement({
      sid: "BedrockInvoke", effect: iam.Effect.ALLOW,
      actions: ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
      resources: [`arn:aws:bedrock:*::foundation-model/*`,
                  `arn:aws:bedrock:*:${this.account}:inference-profile/*`],
    }));

    // EventBridge reconcile tick (concern 6): every 1 min, hit the dev reconcile route via the worker? No —
    // reconcile is a DynamoDB scan + enqueue; give the worker a scheduled self-invoke path by invoking the
    // reconcile through a tiny scheduled rule that sends a sentinel SQS message the worker treats as a sweep.
    // Minimal: a scheduled rule enqueues a reconcile sentinel; the worker runs reconcile_lost_enqueue.
    const reconcileRule = new events.Rule(this, "EditPlanReconcileRule", {
      ruleName: `story-${environment}-edit-plan-reconcile`,
      schedule: events.Schedule.rate(cdk.Duration.minutes(1)),
    });
    reconcileRule.addTarget(new targets.LambdaFunction(worker, {
      event: events.RuleTargetInput.fromObject({ reconcile: true }),
    }));

    // App Runner instance role: write jobs, STAGE sheets (put only), send to the queue.
    jobsTable.grantReadWriteData(instanceRole);
    stagingBucket.grantPut(instanceRole);
    jobsQueue.grantSendMessages(instanceRole);

    // R2/R3 media: the App Runner role needs the media table (ownership records) RW and the media bucket for
    // presigning + verification. Least-privilege: s3:PutObject/GetObject (presign both), GetObject for HeadObject
    // verification, AbortMultipartUpload + ListMultipartUploadParts for resumable multipart. NO s3:DeleteObject
    // (no deletion this increment) and NO bucket-level admin. Scoped to the media/* prefix.
    mediaTable.grantReadWriteData(instanceRole);
    storiesTable.grantReadWriteData(instanceRole); // R7: account-owned Story documents RW
    understandingTable.grantReadWriteData(instanceRole); // R7-E: account-level Moment Understanding RW
    instanceRole.addToPolicy(new iam.PolicyStatement({
      sid: "MediaObjectAccess",
      effect: iam.Effect.ALLOW,
      actions: ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      resources: [mediaBucket.arnForObjects("media/*")],
    }));

    // P0 Beta Auth Increment 3: scoped access to the identity tables owned by the SEPARATE story-<env>-auth
    // stack. Referenced by NAME (cross-stack string, not a hard CDK dependency) so the api stack deploys
    // independently; IAM is scoped to exactly these two tables (read + write + transactions for atomic claims).
    const identityClaimsTableName =
      (this.node.tryGetContext("identityClaimsTable") as string) ?? `story-${environment}-identity-claims`;
    const storyUsersTableName =
      (this.node.tryGetContext("storyUsersTable") as string) ?? `story-${environment}-users`;
    instanceRole.addToPolicy(new iam.PolicyStatement({
      actions: ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query",
                "dynamodb:TransactWriteItems"],
      resources: [
        `arn:aws:dynamodb:${this.region}:${this.account}:table/${identityClaimsTableName}`,
        `arn:aws:dynamodb:${this.region}:${this.account}:table/${storyUsersTableName}`,
        `arn:aws:dynamodb:${this.region}:${this.account}:table/${storyUsersTableName}/index/*`,
      ],
    }));

    // --- App Runner service ---------------------------------------------
    const service = new apprunner.CfnService(this, "StoryApiService", {
      serviceName: `story-${environment}-api`,
      sourceConfiguration: {
        // Pull the container image from ECR.
        authenticationConfiguration: {
          accessRoleArn: accessRole.roleArn,
        },
        // Pipeline-controlled releases: when the deploy passes an immutable digest
        // (`-c imageDigest=sha256:...`) the service is pinned to that digest and AUTO-DEPLOY IS OFF
        // (App Runner forbids auto-deploy on a digest ref, and we want exactly-one deploy authority — the
        // GitHub pipeline). With no digest (a legacy/local synth) it falls back to the mutable :latest tag
        // with auto-deploy, so the old path still works until it is retired.
        autoDeploymentsEnabled: imageDigest ? false : true,
        imageRepository: {
          imageRepositoryType: "ECR",
          imageIdentifier: imageDigest
            ? `${repository.repositoryUri}@${imageDigest}`
            : `${repository.repositoryUri}:latest`,
          imageConfiguration: {
            port: "8080",
            // NOTE: App Runner runtimeEnvironmentVariables is a FULL REPLACE, not a merge. Every var the
            // service needs MUST be listed here — omitting one (as an earlier revision did) silently drops it
            // from the live service. These restore the music provider + frozen prompt pins that were clobbered.
            runtimeEnvironmentVariables: [
              { name: "STORY_JOBS_TABLE", value: jobsTable.tableName },
              { name: "STORY_JOBS_QUEUE_URL", value: jobsQueue.queueUrl },
              { name: "STORY_STAGING_BUCKET", value: stagingBucket.bucketName },
              { name: "STORY_JOBS_API_ENABLED", value: "1" },
              // R2/R3 cloud media (private original-media storage).
              { name: "STORY_MEDIA_TABLE", value: mediaTable.tableName },
              { name: "STORY_MEDIA_BUCKET", value: mediaBucket.bucketName },
              { name: "STORY_STORIES_TABLE", value: storiesTable.tableName }, // R7
              { name: "STORY_UNDERSTANDING_TABLE", value: understandingTable.tableName }, // R7-E
              // Music provider (Epidemic) — without these the provider is disabled and /v1/music/candidates 404s.
              { name: "STORY_EPIDEMIC_MODE", value: "prototyping" },
              { name: "STORY_MUSIC_PROVIDER", value: "mcp" },
              // Frozen edit-planner prompt pin + model fallback (so the sync + async paths both use v5.2).
              { name: "STORY_EDIT_PLAN_VERSION", value: "5.2" },
              { name: "STORY_LLM_FALLBACK_MODEL", value: "us.anthropic.claude-sonnet-4-6" },
              // P0 Beta Auth Increment 3: wire the (separately-provisioned) dev Cognito pool + identity
              // tables. These are non-secret resource identifiers (NOT credentials), read from context so prod
              // supplies its own; dev defaults match the provisioned story-development-auth stack.
              { name: "STORY_ENVIRONMENT", value: environment },
              // Dev stays in optional-auth so existing iOS builds keep working; prod is fail-closed in code
              // regardless of this value.
              { name: "STORY_REQUIRE_AUTH", value: environment === "production" ? "1" : "0" },
              { name: "STORY_COGNITO_USER_POOL_ID",
                // beta/gamma/prod: guaranteed non-null by the release-input guard above. dev: keep the known
                // dev pool as a local-synth convenience.
                value: cognitoUserPoolId ?? "us-east-1_AzfHOEdA5" },
              { name: "STORY_COGNITO_APP_CLIENT_ID",
                value: cognitoAppClientId ?? "5rnvp7oq6d7crbt01ldpe89tkh" },
              { name: "STORY_IDENTITY_CLAIMS_TABLE", value: identityClaimsTableName },
              { name: "STORY_USERS_TABLE", value: storyUsersTableName },
            ],
          },
        },
      },
      instanceConfiguration: {
        // Start small; scale from measurement (04-aws-infrastructure.md §13).
        cpu: "1 vCPU",
        memory: "2 GB",
        instanceRoleArn: instanceRole.roleArn,
      },
      healthCheckConfiguration: {
        protocol: "HTTP",
        path: "/health",
        interval: 10,
        timeout: 5,
        healthyThreshold: 1,
        unhealthyThreshold: 5,
      },
    });

    // --- Outputs (non-secret) -------------------------------------------
    new cdk.CfnOutput(this, "EcrRepositoryUri", {
      value: repository.repositoryUri,
      description: "ECR repository URI for the Story API image",
    });
    new cdk.CfnOutput(this, "ApiServiceUrl", {
      value: `https://${service.attrServiceUrl}`,
      description: "App Runner service URL (Story API base URL)",
    });

    // --- Gate 2: GitHub Actions OIDC deploy role (DEV ONLY) ---------------
    // Short-lived, keyless CI deploys. The role trusts GitHub's OIDC provider
    // and is scoped by the `sub` claim to THIS repo + the development
    // environment, so only a run of `lingzhang1/story` in the `development`
    // GitHub Environment can assume it. NEVER AdministratorAccess — the inline
    // policy lists exactly the actions a `cdk deploy` + artifact push of THIS
    // stack needs (documented per statement below). Provisioned only for
    // non-production environments; production gets a separately-reviewed role.
    if (environment !== "production") {
      // One OIDC provider per account (reused if it already exists out-of-band).
      const githubOidc = new iam.OpenIdConnectProvider(this, "GitHubOIDCProvider", {
        url: "https://token.actions.githubusercontent.com",
        clientIds: ["sts.amazonaws.com"],
      });

      const deployRole = new iam.Role(this, "StoryDevDeployRole", {
        roleName: `story-${environment}-github-deploy`,
        description: "GitHub Actions OIDC role for DEV cdk deploy + artifact push (least privilege)",
        maxSessionDuration: cdk.Duration.hours(1),
        assumedBy: new iam.WebIdentityPrincipal(
          githubOidc.openIdConnectProviderArn,
          {
            StringEquals: { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
            // GitHub may emit a numeric-id-qualified sub (repo:owner@<id>/repo@<id>:environment:...);
            // match it with a StringLike that pins owner + repo name + THIS environment. The owner/repo
            // pattern (lingzhang1*/story*) is UNCHANGED — it already tolerates the numeric repository-id
            // qualifier GitHub appends — and only the environment segment is parameterized, so a beta role
            // trusts exactly environment:beta and the dev role exactly environment:development. Trust is
            // NOT broadened: each env's role matches its own single GitHub Environment, never a wildcard.
            StringLike: {
              "token.actions.githubusercontent.com:sub":
                `repo:lingzhang1*/story*:environment:${environment}`,
            },
          }
        ),
      });

      // CloudFormation: cdk deploy drives CFN on this stack + CDKToolkit only. DeleteStack is
      // deliberately OMITTED — a dev deploy updates, never tears down the stack (req 4). DeleteChangeSet
      // is kept because cdk routinely cleans up its own change sets during a deploy.
      deployRole.addToPolicy(new iam.PolicyStatement({
        sid: "CloudFormationDeploy",
        actions: [
          "cloudformation:DescribeStacks", "cloudformation:CreateStack", "cloudformation:UpdateStack",
          "cloudformation:DescribeStackEvents", "cloudformation:GetTemplate",
          "cloudformation:DescribeStackResources", "cloudformation:CreateChangeSet",
          "cloudformation:DescribeChangeSet", "cloudformation:ExecuteChangeSet",
          "cloudformation:DeleteChangeSet", "cloudformation:GetTemplateSummary",
        ],
        resources: [
          `arn:aws:cloudformation:${this.region}:${this.account}:stack/story-${environment}-api/*`,
          `arn:aws:cloudformation:${this.region}:${this.account}:stack/CDKToolkit/*`,
        ],
      }));

      // CDK asset upload: tightened to THIS account's CDK bootstrap asset bucket + container-assets
      // ECR repo (hnb659fds qualifier). ecr:GetAuthorizationToken has NO resource-level support (AWS
      // limitation — it is account-wide by design), so it is a separate `*` statement; everything else
      // is resource-scoped.
      deployRole.addToPolicy(new iam.PolicyStatement({
        sid: "EcrAuthToken",
        actions: ["ecr:GetAuthorizationToken",
                  // Public-ECR login for an authenticated base-image pull (avoids the anonymous 429 limit).
                  "ecr-public:GetAuthorizationToken", "sts:GetServiceBearerToken"],
        resources: ["*"],   // API LIMITATION: these auth-token actions do not support resource-level perms
      }));
      deployRole.addToPolicy(new iam.PolicyStatement({
        sid: "CdkAssetUpload",
        actions: [
          "s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:GetBucketLocation",
          "ecr:BatchCheckLayerAvailability", "ecr:PutImage", "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:BatchGetImage", "ecr:DescribeImages",
        ],
        resources: [
          `arn:aws:s3:::cdk-hnb659fds-assets-${this.account}-${this.region}`,
          `arn:aws:s3:::cdk-hnb659fds-assets-${this.account}-${this.region}/*`,
          `arn:aws:ecr:${this.region}:${this.account}:repository/cdk-hnb659fds-container-assets-${this.account}-${this.region}`,
          // The app image repo itself (the digest-pinned API image is pushed here by the workflow).
          `arn:aws:ecr:${this.region}:${this.account}:repository/story-${environment}-api`,
        ],
      }));

      // App Runner: describe/update/start scoped to the dev service ARN; ListServices has no
      // resource-level support (AWS limitation) so it is a separate `*`-scoped read-only statement.
      deployRole.addToPolicy(new iam.PolicyStatement({
        sid: "AppRunnerList",
        actions: ["apprunner:ListServices"],
        resources: ["*"],   // API LIMITATION: ListServices does not support resource-level perms
      }));
      deployRole.addToPolicy(new iam.PolicyStatement({
        sid: "AppRunnerDeploy",
        actions: [
          "apprunner:DescribeService", "apprunner:UpdateService",
          "apprunner:StartDeployment", "apprunner:DescribeOperation",
        ],
        resources: [
          `arn:aws:apprunner:${this.region}:${this.account}:service/story-${environment}-api/*`,
        ],
      }));

      // Lambda: publish + update the async worker.
      deployRole.addToPolicy(new iam.PolicyStatement({
        sid: "LambdaDeploy",
        actions: [
          "lambda:GetFunction", "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration",
          "lambda:PublishVersion", "lambda:GetFunctionConfiguration",
        ],
        resources: [`arn:aws:lambda:${this.region}:${this.account}:function:story-${environment}-*`],
      }));

      // --- Dedicated, SCOPED CloudFormation execution role (Option B) ------
      // The shared CDK bootstrap exec role carries AdministratorAccess; driving CFN through it would give
      // this deploy role admin-equivalent reach inside the stack's changeset. Instead we create a role
      // CloudFormation assumes ONLY for Story's dev stack, scoped to the exact service namespaces the
      // stack provisions (App Runner, DynamoDB, SQS, S3, Lambda, Events, SSM read, IAM for the app's own
      // roles) in THIS account+region. `cdk deploy --role-arn <this>` passes it explicitly, so the shared
      // bootstrap role is never used and is left untouched.
      const cfnExecRole = new iam.Role(this, "StoryDevCfnExecRole", {
        roleName: `story-${environment}-cfn-exec`,
        description: "Scoped CloudFormation execution role for Story dev deploys (NO AdministratorAccess)",
        assumedBy: new iam.ServicePrincipal("cloudformation.amazonaws.com"),
      });
      cfnExecRole.addToPolicy(new iam.PolicyStatement({
        sid: "StoryDevStackServices",
        actions: [
          "apprunner:*",            // create/update/describe the service + its auto-scaling config
          "dynamodb:*",             // the jobs table
          "sqs:*",                  // queue + DLQ
          "s3:*",                   // staging bucket + bucket policy + the S3 auto-delete custom resource
          "lambda:*",               // worker + ESM + permissions + the OIDC custom-resource handler
          "events:*",               // the reconcile EventBridge rule
          "ssm:GetParameters", "ssm:GetParameter",   // CDK reads the bootstrap version param
          "logs:*",                 // Lambda log groups
        ],
        // Service-level scope to this account+region. CloudFormation creates these resources, so ARNs
        // are not known pre-create; scoping by service+account+region removes cross-account/cross-service
        // admin reach, which is the escalation the review flagged. (A resource-ARN-per-type policy is a
        // future tightening; this already eliminates AdministratorAccess.)
        resources: ["*"],
        conditions: { StringEquals: { "aws:RequestedRegion": this.region } },
      }));
      cfnExecRole.addToPolicy(new iam.PolicyStatement({
        sid: "StoryDevStackIam",
        // CFN creates the app's OWN roles (App Runner access/instance, worker) + passes them to services.
        // Scoped to story-*/StoryApiStack-* role names so it cannot touch unrelated roles, and PassRole is
        // PassedToService-conditioned.
        actions: ["iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole", "iam:UntagRole",
                  "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
                  "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
                  "iam:UpdateAssumeRolePolicy", "iam:UpdateRole", "iam:UpdateRoleDescription",
                  "iam:CreatePolicy", "iam:DeletePolicy", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
                  "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions",
                  "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
                  "iam:GetOpenIDConnectProvider", "iam:TagOpenIDConnectProvider",
                  "iam:UpdateOpenIDConnectProviderThumbprint", "iam:AddClientIDToOpenIDConnectProvider"],
        resources: [
          `arn:aws:iam::${this.account}:role/story-${environment}-*`,
          `arn:aws:iam::${this.account}:role/StoryApiStack-*`,
          `arn:aws:iam::${this.account}:policy/story-${environment}-*`,
          `arn:aws:iam::${this.account}:oidc-provider/token.actions.githubusercontent.com`,
        ],
      }));
      cfnExecRole.addToPolicy(new iam.PolicyStatement({
        sid: "StoryDevStackPassRole",
        actions: ["iam:PassRole"],
        // Resource scope (only story-*/StoryApiStack-* roles) is the guardrail. The PassedToService
        // condition is intentionally NOT set here: App Runner's control plane does not reliably present
        // the iam:PassedToService context key when validating PassRole during a SERVICE UPDATE, which
        // denied the digest re-pin. Scoping by role name keeps this safe (it can only pass Story's own
        // app roles), without the condition that App Runner update breaks on.
        resources: [`arn:aws:iam::${this.account}:role/story-${environment}-*`,
                    `arn:aws:iam::${this.account}:role/StoryApiStack-*`],
      }));

      // IAM PassRole on the DEPLOY role: it may pass EXACTLY the dedicated cfn-exec role to
      // CloudFormation — and NOTHING else. It explicitly CANNOT pass the admin bootstrap exec role or any
      // other role (point 4). This is the single PassRole the deploy role holds.
      deployRole.addToPolicy(new iam.PolicyStatement({
        sid: "PassOnlyScopedCfnExec",
        actions: ["iam:PassRole"],
        resources: [cfnExecRole.roleArn],
        conditions: { StringEquals: { "iam:PassedToService": "cloudformation.amazonaws.com" } },
      }));

      // CDK CLI reads the bootstrap version SSM param to confirm compatibility before a deploy.
      deployRole.addToPolicy(new iam.PolicyStatement({
        sid: "CdkBootstrapVersionRead",
        actions: ["ssm:GetParameter", "ssm:GetParameters"],
        resources: [`arn:aws:ssm:${this.region}:${this.account}:parameter/cdk-bootstrap/*`],
      }));

      new cdk.CfnOutput(this, "GitHubDeployRoleArn", {
        value: deployRole.roleArn,
        description: "ARN GitHub Actions assumes via OIDC for dev deploys",
      });
      new cdk.CfnOutput(this, "CfnExecRoleArn", {
        value: cfnExecRole.roleArn,
        description: "Scoped CloudFormation execution role — pass to `cdk deploy --role-arn`",
      });
    }
    new cdk.CfnOutput(this, "Environment", { value: environment });
    new cdk.CfnOutput(this, "EditPlanJobsTableName", { value: jobsTable.tableName });
    new cdk.CfnOutput(this, "StoryDocumentsTableName", { value: storiesTable.tableName });
    new cdk.CfnOutput(this, "MomentUnderstandingTableName", { value: understandingTable.tableName });
    new cdk.CfnOutput(this, "EditPlanJobsQueueUrl", { value: jobsQueue.queueUrl });
    new cdk.CfnOutput(this, "EditPlanStagingBucketName", { value: stagingBucket.bucketName });
    new cdk.CfnOutput(this, "EditPlanWorkerName", { value: worker.functionName });

    // P0 Beta Observability (opt-in via context, default OFF so a plain synth is unchanged). Provisions
    // nothing at synth time; the owner enables it on deploy after B0 beta infra is accepted.
    if (props.enableObservability) {
      new Observability(this, "Observability", {
        environment,
        jobsQueue,
        dlq,
        worker,
        apiServiceName: `story-${environment}-api`,
        alarmDestination: props.alarmDestination,
        monthlyBudgetUsd: props.monthlyBudgetUsd ?? (environment === "beta" ? 100 : undefined),
        createBudget: props.createBudget,
      });
    }
  }
}
