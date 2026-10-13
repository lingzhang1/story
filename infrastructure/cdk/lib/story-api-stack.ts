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

export interface StoryApiStackProps extends cdk.StackProps {
  /** Deployment environment name (development | staging | production). */
  readonly environment: string;
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
      reservedConcurrentExecutions: Number(process.env.STORY_WORKER_CONCURRENCY ?? "2"),
      environment: {
        PYTHONPATH: "/var/task:/var/task/packages",
        STORY_JOBS_TABLE: jobsTable.tableName,
        STORY_JOBS_QUEUE_URL: jobsQueue.queueUrl,
        STORY_STAGING_BUCKET: stagingBucket.bucketName,
        STORY_WORKER_DEADLINE_S: "840",
        STORY_WORKER_ALLOW_TEST_DELAY: "1",
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

    // --- App Runner service ---------------------------------------------
    const service = new apprunner.CfnService(this, "StoryApiService", {
      serviceName: `story-${environment}-api`,
      sourceConfiguration: {
        // Pull the container image from ECR.
        authenticationConfiguration: {
          accessRoleArn: accessRole.roleArn,
        },
        autoDeploymentsEnabled: true,
        imageRepository: {
          imageRepositoryType: "ECR",
          // ':latest' — a concrete tag/digest is injected by the deploy
          // pipeline; this is the repository URI the service pulls from.
          imageIdentifier: `${repository.repositoryUri}:latest`,
          imageConfiguration: {
            port: "8080",
            runtimeEnvironmentVariables: [
              { name: "STORY_JOBS_TABLE", value: jobsTable.tableName },
              { name: "STORY_JOBS_QUEUE_URL", value: jobsQueue.queueUrl },
              { name: "STORY_STAGING_BUCKET", value: stagingBucket.bucketName },
              { name: "STORY_JOBS_API_ENABLED", value: "1" },
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
    new cdk.CfnOutput(this, "Environment", { value: environment });
    new cdk.CfnOutput(this, "EditPlanJobsTableName", { value: jobsTable.tableName });
    new cdk.CfnOutput(this, "EditPlanJobsQueueUrl", { value: jobsQueue.queueUrl });
    new cdk.CfnOutput(this, "EditPlanStagingBucketName", { value: stagingBucket.bucketName });
    new cdk.CfnOutput(this, "EditPlanWorkerName", { value: worker.functionName });
  }
}
