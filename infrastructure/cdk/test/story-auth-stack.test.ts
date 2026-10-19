import * as cdk from "aws-cdk-lib";
import { Template, Match } from "aws-cdk-lib/assertions";
import { StoryAuthStack } from "../lib/story-auth-stack";

function synth(): Template {
  const app = new cdk.App();
  const stack = new StoryAuthStack(app, "story-test-auth", {
    environment: "test",
    env: { account: "123456789012", region: "us-east-1" },
  });
  return Template.fromStack(stack);
}

describe("StoryAuthStack (P0 Beta Auth, Increment 1)", () => {
  const template = synth();

  test("provisions exactly one Cognito user pool", () => {
    template.resourceCountIs("AWS::Cognito::UserPool", 1);
  });

  test("user pool is on the Essentials feature plan (required for native EMAIL_OTP)", () => {
    template.hasResourceProperties("AWS::Cognito::UserPool", {
      UserPoolTier: "ESSENTIALS",
    });
  });

  test("native passwordless EMAIL_OTP is enabled as a first-auth factor (no custom OTP Lambda needed)", () => {
    template.hasResourceProperties("AWS::Cognito::UserPool", {
      Policies: Match.objectLike({
        SignInPolicy: { AllowedFirstAuthFactors: Match.arrayWith(["EMAIL_OTP"]) },
      }),
    });
  });

  test("NO custom-auth Lambda triggers are wired (native EMAIL_OTP preferred over custom)", () => {
    // Increment 1 uses native EMAIL_OTP; there must be no DefineAuthChallenge/CreateAuthChallenge/VerifyAuth
    // Lambda config on the pool.
    const pools = template.findResources("AWS::Cognito::UserPool");
    const pool = Object.values(pools)[0] as any;
    const triggers = pool.Properties.LambdaConfig ?? {};
    expect(triggers.DefineAuthChallenge).toBeUndefined();
    expect(triggers.CreateAuthChallenge).toBeUndefined();
    expect(triggers.VerifyAuthChallengeResponse).toBeUndefined();
  });

  test("Sign in with Apple IdP is configured", () => {
    template.hasResourceProperties("AWS::Cognito::UserPoolIdentityProvider", {
      ProviderType: "SignInWithApple",
      ProviderName: "SignInWithApple",
    });
  });

  test("app client enables the USER_AUTH choice-based flow + refresh (native iOS, no secret)", () => {
    template.hasResourceProperties("AWS::Cognito::UserPoolClient", {
      GenerateSecret: false,
      ExplicitAuthFlows: Match.arrayWith(["ALLOW_USER_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]),
    });
  });

  test("StoryUser table separates immutable story_user_id from cognito_sub (reverse-lookup GSI)", () => {
    template.hasResourceProperties("AWS::DynamoDB::Table", {
      KeySchema: Match.arrayWith([{ AttributeName: "story_user_id", KeyType: "HASH" }]),
      GlobalSecondaryIndexes: Match.arrayWith([
        Match.objectLike({ IndexName: "by_cognito_sub" }),
        Match.objectLike({ IndexName: "by_provider_identity" }),
      ]),
    });
  });

  test("UserUsage table keyed (story_user_id, quota_period) for atomic quota reservation", () => {
    template.hasResourceProperties("AWS::DynamoDB::Table", {
      KeySchema: Match.arrayWith([
        { AttributeName: "story_user_id", KeyType: "HASH" },
        { AttributeName: "quota_period", KeyType: "RANGE" },
      ]),
    });
  });

  test("identity + usage data is RETAINed (never auto-deleted)", () => {
    template.allResourcesProperties("AWS::DynamoDB::Table", {
      PointInTimeRecoverySpecification: { PointInTimeRecoveryEnabled: true },
    });
    const pool = Object.values(template.findResources("AWS::Cognito::UserPool"))[0] as any;
    expect(pool.DeletionPolicy).toBe("Retain");
  });
});
