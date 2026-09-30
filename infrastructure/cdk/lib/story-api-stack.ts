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
    const repository = new ecr.Repository(this, "StoryApiRepo", {
      imageScanOnPush: true,
      // Keep the repo removable in non-prod; production would override.
      removalPolicy:
        environment === "production"
          ? cdk.RemovalPolicy.RETAIN
          : cdk.RemovalPolicy.DESTROY,
      lifecycleRules: [
        { maxImageCount: 10, description: "Retain only the 10 newest images" },
      ],
    });

    // --- App Runner access role (pull image from ECR) --------------------
    const accessRole = new iam.Role(this, "StoryApiAccessRole", {
      assumedBy: new iam.ServicePrincipal("build.apprunner.amazonaws.com"),
      description: "Lets App Runner pull the Story API image from ECR",
    });
    repository.grantPull(accessRole);

    // --- App Runner instance role (runtime task permissions) -------------
    // Least-privilege: no S3/Bedrock/DynamoDB grants at Milestone A — the
    // mock API needs none. Real grants are added when those services land.
    const instanceRole = new iam.Role(this, "StoryApiInstanceRole", {
      assumedBy: new iam.ServicePrincipal("tasks.apprunner.amazonaws.com"),
      description: "Runtime role for the Story API App Runner service",
    });

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
