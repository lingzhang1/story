import * as cdk from "aws-cdk-lib";
import { Template, Match } from "aws-cdk-lib/assertions";
import { StoryAuthStack } from "../lib/story-auth-stack";

function synth(context: Record<string, unknown> = {}): Template {
  const app = new cdk.App({ context });
  const stack = new StoryAuthStack(app, "story-test-auth", {
    environment: "test",
    env: { account: "123456789012", region: "us-east-1" },
  });
  return Template.fromStack(stack);
}

describe("StoryAuthStack (P0 Beta Auth, Increment 1)", () => {
  const template = synth();
  // A second synth WITH Apple creds present (simulates post-Apple-portal provisioning).
  const withApple = synth({
    applePrivateKey: "-----BEGIN PRIVATE KEY-----\nTESTKEY\n-----END PRIVATE KEY-----",
    appleServicesId: "com.story.signin",
    appleTeamId: "TEAM123456",
    appleKeyId: "KEY1234567",
  });

  test("provisions exactly one Cognito user pool", () => {
    template.resourceCountIs("AWS::Cognito::UserPool", 1);
  });

  test("user pool is on the Essentials feature plan (required for native EMAIL_OTP)", () => {
    template.hasResourceProperties("AWS::Cognito::UserPool", {
      UserPoolTier: "ESSENTIALS",
    });
  });

  test("EMAIL_OTP is an allowed first-auth factor; PASSWORD is pool-level only (Cognito requires it)", () => {
    // Cognito rejects an EMAIL_OTP-only factor list, so PASSWORD must appear at the pool level. The real
    // no-password guarantee is enforced on the CLIENT (no SRP/password flow — asserted in the next test).
    template.hasResourceProperties("AWS::Cognito::UserPool", {
      Policies: Match.objectLike({
        SignInPolicy: { AllowedFirstAuthFactors: Match.arrayWith(["EMAIL_OTP"]) },
      }),
    });
  });

  test("app client has NO SRP/password flow; only USER_AUTH + REFRESH (correction 3)", () => {
    const clients = template.findResources("AWS::Cognito::UserPoolClient");
    const client = Object.values(clients)[0] as any;
    const flows: string[] = client.Properties.ExplicitAuthFlows;
    expect(flows).toEqual(expect.arrayContaining(["ALLOW_USER_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]));
    expect(flows).not.toContain("ALLOW_USER_SRP_AUTH");
    expect(flows).not.toContain("ALLOW_USER_PASSWORD_AUTH");
    expect(flows).not.toContain("ALLOW_ADMIN_USER_PASSWORD_AUTH");
  });

  test("Apple OAuth code-grant flow + callback configured, and a Cognito domain exists (correction 2)", () => {
    template.hasResourceProperties("AWS::Cognito::UserPoolClient", {
      AllowedOAuthFlows: Match.arrayWith(["code"]),
      CallbackURLs: Match.arrayWith(["story://auth"]),
    });
    template.resourceCountIs("AWS::Cognito::UserPoolDomain", 1);
    withApple.hasResourceProperties("AWS::Cognito::UserPoolClient", {
      SupportedIdentityProviders: Match.arrayWith(["SignInWithApple", "COGNITO"]),
    });
  });

  test("atomic identity-claim table exists for uniqueness (correction 1 — not GSI-only)", () => {
    template.hasResourceProperties("AWS::DynamoDB::Table", {
      TableName: Match.stringLikeRegexp("identity-claims"),
      KeySchema: Match.arrayWith([{ AttributeName: "claim_key", KeyType: "HASH" }]),
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

  test("Sign in with Apple IdP is configured WHEN Apple creds are supplied", () => {
    withApple.hasResourceProperties("AWS::Cognito::UserPoolIdentityProvider", {
      ProviderType: "SignInWithApple",
      ProviderName: "SignInWithApple",
    });
  });

  test("dev-provision reality: NO Apple IdP without creds; EMAIL_OTP still works (correction 9)", () => {
    // Apple creds are not yet available — the dev stack provisions without the Apple IdP.
    template.resourceCountIs("AWS::Cognito::UserPoolIdentityProvider", 0);
    template.hasResourceProperties("AWS::Cognito::UserPoolClient", {
      SupportedIdentityProviders: ["COGNITO"],
    });
  });

  test("app client is public (no secret) for native iOS", () => {
    template.hasResourceProperties("AWS::Cognito::UserPoolClient", {
      GenerateSecret: false,
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
