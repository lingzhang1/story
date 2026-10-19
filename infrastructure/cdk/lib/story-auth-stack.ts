import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as cognito from "aws-cdk-lib/aws-cognito";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";

/**
 * StoryAuthStack — P0 Beta Authentication (Increment 1, DESIGN/CDK ONLY).
 *
 * SEPARATE stack from StoryApiStack so auth can be reviewed/synthesized without touching the accepted
 * api-stack. NOTHING here is provisioned in this milestone — this file exists to `cdk synth` and unit-test.
 *
 * Decisions encoded (owner-approved 2026-10-18):
 *  - ONE Cognito User Pool, the single IdP for BOTH Sign in with Apple (federated) and passwordless
 *    Email OTP (NATIVE Cognito EMAIL_OTP via the USER_AUTH choice-based flow — verified to work headlessly
 *    through the SDK InitiateAuth/RespondToAuthChallenge, so NO custom OTP Lambda triggers are needed).
 *  - Native EMAIL_OTP requires the **Essentials** feature plan (Lite does not offer it). Set via escape
 *    hatch because aws-cdk-lib 2.160.0 predates the L2 FeaturePlan/SignInPolicy props.
 *  - Identity separation: cognito `sub` is the AUTH subject; the IMMUTABLE application-owned `story_user_id`
 *    (UUID) lives in the StoryUser table, mapped FROM cognito_sub. Email/Apple-subject are provider
 *    identities, NEVER the primary key. No automatic email-based account merge (linking is explicit, below).
 *
 * aws-cdk-lib 2.160.0 compatibility: the L2 `UserPool` lacks `featurePlan` and `signInPolicy`, and there is
 * no Apple-IdP L2 or generic-IdP property for EMAIL. Those are applied via `addPropertyOverride` on the
 * underlying CfnUserPool, and Apple is added as a raw `CfnUserPoolIdentityProvider`. This avoids bumping the
 * CDK lib (which would risk the accepted api-stack synth).
 */
export interface StoryAuthStackProps extends cdk.StackProps {
  readonly environment: string;
  /** Apple Services ID (client_id). Supplied at provision time; left as a context value for synth. */
  readonly appleServicesId?: string;
  /** Apple Team ID. */
  readonly appleTeamId?: string;
  /** Apple Sign-in key id. */
  readonly appleKeyId?: string;
}

export class StoryAuthStack extends cdk.Stack {
  public readonly userPool: cognito.UserPool;
  public readonly userPoolClient: cognito.UserPoolClient;
  public readonly identityClaimTable: dynamodb.Table;
  public readonly storyUserTable: dynamodb.Table;
  public readonly userUsageTable: dynamodb.Table;

  constructor(scope: Construct, id: string, props: StoryAuthStackProps) {
    super(scope, id, props);
    const env = props.environment;
    const isProd = env === "production";

    // ---- Cognito User Pool ----------------------------------------------------------------------------
    this.userPool = new cognito.UserPool(this, "StoryUserPool", {
      userPoolName: `story-${env}-users`,
      selfSignUpEnabled: true,
      signInAliases: { email: true },
      // Email is a verified, mutable contact attribute — NOT the identity. story_user_id is the identity.
      standardAttributes: { email: { required: true, mutable: true } },
      autoVerify: { email: true },
      accountRecovery: cognito.AccountRecovery.EMAIL_ONLY,
      // Short-lived access/id tokens; rotating refresh handled on the app client below.
      removalPolicy: isProd ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.RETAIN, // RETAIN in all envs: a pool holds real users.
    });

    const cfnPool = this.userPool.node.defaultChild as cognito.CfnUserPool;
    // Essentials feature plan — REQUIRED for native passwordless EMAIL_OTP.
    cfnPool.addPropertyOverride("UserPoolTier", "ESSENTIALS");
    // Correction 3 (passwordless): Story exposes NO password UI. Cognito REQUIRES `PASSWORD` to appear in
    // AllowedFirstAuthFactors (an EMAIL_OTP-only list is rejected: "PASSWORD should be configured as one of
    // the allowed first auth factors"), so PASSWORD stays here at the POOL level — but NO password auth flow
    // is enabled on the app client (no ALLOW_USER_PASSWORD_AUTH / ALLOW_USER_SRP_AUTH below), so a client can
    // never actually perform a password sign-in. EMAIL_OTP is the real first factor; Apple is federated.
    cfnPool.addPropertyOverride("Policies.SignInPolicy.AllowedFirstAuthFactors", ["PASSWORD", "EMAIL_OTP"]);
    // Cognito sends the OTP email via its default sender (SES later for branded/high-volume). Documented
    // in the design: SES is in SANDBOX today — default Cognito email is rate-limited and NOT for production
    // beta volume; SES production access is a provisioning prerequisite (NOT enabled here).

    // ---- Sign in with Apple (federated IdP) -----------------------------------------------------------
    // Raw Cfn because 2.160.0 has no Apple L2. Credentials are passed at provision time (context/Secrets),
    // never committed. Apple's `sub` is the provider identity; the Apple relay email is a contact attribute
    // only — never the Story identity.
    // Correction 9 / dev-provision reality: Apple creds are NOT yet available (Apple Developer portal step).
    // The Apple IdP is created ONLY when a real private key is supplied (-c applePrivateKey=...), so the dev
    // auth stack can be provisioned NOW (pool + EMAIL_OTP + tables + domain) and Apple is added later without
    // a rebuild. Email OTP is fully functional without it.
    const applePrivateKey = this.node.tryGetContext("applePrivateKey") as string | undefined;
    const appleEnabled = !!applePrivateKey && applePrivateKey !== "PLACEHOLDER_PRIVATE_KEY";
    let appleIdp: cognito.CfnUserPoolIdentityProvider | undefined;
    if (appleEnabled) {
      appleIdp = new cognito.CfnUserPoolIdentityProvider(this, "AppleIdp", {
        userPoolId: this.userPool.userPoolId,
        providerName: "SignInWithApple",
        providerType: "SignInWithApple",
        attributeMapping: { email: "email", email_verified: "email_verified" },
        providerDetails: {
          client_id: props.appleServicesId ?? this.node.tryGetContext("appleServicesId"),
          team_id: props.appleTeamId ?? this.node.tryGetContext("appleTeamId"),
          key_id: props.appleKeyId ?? this.node.tryGetContext("appleKeyId"),
          private_key: applePrivateKey,
          authorize_scopes: "email name",
        },
      });
    }

    // Correction 2 (Apple flow): a User Pool federates Apple via the OAuth Authorization-Code + PKCE flow
    // against the Cognito DOMAIN — the native ASAuthorization identity token CANNOT be swapped directly for
    // User-Pool tokens (that direct path is Identity-Pool-only, which issues AWS creds, not our account).
    // Flow: app opens ASWebAuthenticationSession -> Cognito /oauth2/authorize?identity_provider=SignInWithApple
    // -> Apple consent -> Cognito callback (custom scheme) -> app gets the code -> exchanges at Cognito
    // /oauth2/token for id/access/refresh JWTs. REQUIRES a Cognito domain + callback URLs + code-grant.
    this.userPool.addDomain("StoryAuthDomain", {
      cognitoDomain: { domainPrefix: `story-${env}-auth` },
    });
    const callbackScheme = "story://auth"; // native iOS custom-scheme redirect

    // ---- App client (native iOS; public, no secret) ---------------------------------------------------
    this.userPoolClient = this.userPool.addClient("StoryiOSClient", {
      userPoolClientName: `story-${env}-ios`,
      generateSecret: false,
      // Correction 3: NO userSrp / userPassword. Email OTP uses USER_AUTH (override below); Apple uses the
      // OAuth code-grant configured here.
      authFlows: {},
      oAuth: {
        flows: { authorizationCodeGrant: true }, // PKCE client-side; implicit + client-creds OFF
        scopes: [cognito.OAuthScope.OPENID, cognito.OAuthScope.EMAIL, cognito.OAuthScope.PROFILE],
        callbackUrls: [callbackScheme],
        logoutUrls: [callbackScheme],
      },
      supportedIdentityProviders: appleEnabled
        ? [
            cognito.UserPoolClientIdentityProvider.custom("SignInWithApple"),
            cognito.UserPoolClientIdentityProvider.COGNITO,
          ]
        : [cognito.UserPoolClientIdentityProvider.COGNITO], // EMAIL_OTP path works without Apple
      accessTokenValidity: cdk.Duration.minutes(60),
      idTokenValidity: cdk.Duration.minutes(60),
      refreshTokenValidity: cdk.Duration.days(30),
      preventUserExistenceErrors: true,
    });
    if (appleIdp) this.userPoolClient.node.addDependency(appleIdp);
    const cfnClient = this.userPoolClient.node.defaultChild as cognito.CfnUserPoolClient;
    // Correction 3: ONLY USER_AUTH (carries EMAIL_OTP) + REFRESH. No ALLOW_USER_SRP_AUTH, no password flow.
    cfnClient.addPropertyOverride("ExplicitAuthFlows", ["ALLOW_USER_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]);

    // ---- Correction 1: ATOMIC identity-uniqueness claim table -----------------------------------------
    // GSIs do NOT enforce uniqueness. A claim is a conditional PutItem with attribute_not_exists(claim_key)
    // — or a TransactWriteItems that writes the StoryUser row AND this claim together. claim_key =
    // "cognito#<sub>" | "apple#<sub>" | "email#<verified_email>". The condition makes a concurrent second
    // sign-in/link for the SAME subject FAIL atomically, so one subject/provider identity maps to exactly one
    // story_user_id even under race. This table is the uniqueness source of truth; the StoryUser GSIs are
    // lookup-only.
    this.identityClaimTable = new dynamodb.Table(this, "IdentityClaimTable", {
      tableName: `story-${env}-identity-claims`,
      partitionKey: { name: "claim_key", type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      pointInTimeRecovery: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // ---- StoryUser mapping table (immutable story_user_id <- cognito_sub) ------------------------------
    // story_user_id is the application-owned identity. by_cognito_sub resolves it per request. Uniqueness is
    // enforced by the claim table above (conditional write), NOT by these GSIs (lookup-only).
    this.storyUserTable = new dynamodb.Table(this, "StoryUserTable", {
      tableName: `story-${env}-users`,
      partitionKey: { name: "story_user_id", type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      pointInTimeRecovery: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });
    // Reverse lookup: cognito_sub -> story_user_id (what require_user() resolves on every request).
    this.storyUserTable.addGlobalSecondaryIndex({
      indexName: "by_cognito_sub",
      partitionKey: { name: "cognito_sub", type: dynamodb.AttributeType.STRING },
    });
    // Linking-collision guard: a (provider, provider_subject) pair maps to exactly one story_user_id.
    this.storyUserTable.addGlobalSecondaryIndex({
      indexName: "by_provider_identity",
      partitionKey: { name: "provider_identity", type: dynamodb.AttributeType.STRING }, // "apple#<sub>" | "email#<verified_email>"
    });

    // ---- UserUsage table (quota foundation; atomic reserve-before-inference, Phase 4) -----------------
    this.userUsageTable = new dynamodb.Table(this, "UserUsageTable", {
      tableName: `story-${env}-user-usage`,
      partitionKey: { name: "story_user_id", type: dynamodb.AttributeType.STRING },
      sortKey: { name: "quota_period", type: dynamodb.AttributeType.STRING }, // e.g. "2026-10" or "intro"
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      pointInTimeRecovery: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // ---- Outputs --------------------------------------------------------------------------------------
    new cdk.CfnOutput(this, "UserPoolId", { value: this.userPool.userPoolId });
    new cdk.CfnOutput(this, "UserPoolClientId", { value: this.userPoolClient.userPoolClientId });
    new cdk.CfnOutput(this, "IdentityClaimTableName", { value: this.identityClaimTable.tableName });
    new cdk.CfnOutput(this, "StoryUserTableName", { value: this.storyUserTable.tableName });
    new cdk.CfnOutput(this, "UserUsageTableName", { value: this.userUsageTable.tableName });
    new cdk.CfnOutput(this, "JwksUrl", {
      value: `https://cognito-idp.${this.region}.amazonaws.com/${this.userPool.userPoolId}/.well-known/jwks.json`,
      description: "JWKS endpoint the backend require_user() dependency fetches to verify JWTs.",
    });
  }
}
