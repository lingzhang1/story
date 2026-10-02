import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as ecr from "aws-cdk-lib/aws-ecr";
import * as iam from "aws-cdk-lib/aws-iam";
import * as apprunner from "aws-cdk-lib/aws-apprunner";

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
  }
}
