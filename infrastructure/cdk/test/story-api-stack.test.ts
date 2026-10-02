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

  test("provisions ZERO forbidden resource types", () => {
    const forbidden = [
      "AWS::DynamoDB::Table",
      "AWS::SQS::Queue",
      "AWS::Lambda::Function",
      "AWS::S3::Bucket",
    ];
    for (const type of forbidden) {
      template.resourceCountIs(type, 0);
    }
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
});
