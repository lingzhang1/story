import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as organizations from "aws-cdk-lib/aws-organizations";
import * as budgets from "aws-cdk-lib/aws-budgets";

/**
 * B0 Phase 2 — YoTale Organization foundation (management account `001188477936`, org `o-iqahcgt2wz`).
 *
 * DESIGN/REVIEW ONLY until `-c deployOrgFoundation=true` is passed (see bin/app.ts), mirroring the
 * existing `deployAuth` gate. This stack codifies the Organizations structure the owner approved
 * (Path A, 2026-10-21):
 *   - OUs: Workloads (beta/gamma/prod live here), Security, Sandbox.
 *   - SCP guardrails: region lock to us-east-1 with explicit global-service exceptions; deny leaving
 *     the org; protect the SCP/account-security surface from member-account tampering.
 *   - Per-account budgets: Beta $100, Gamma $50, Prod $100, each alerting at 50/80/100% (soft alerts,
 *     NOT hard caps — no action is attached; no public prod traffic is authorized).
 *
 * It deliberately does NOT create member accounts — those are a later, separately-approved increment
 * (organizations.CfnAccount) once beta/gamma/prod root emails are delivery-verified.
 *
 * Deploy target: the management account, us-east-1. Budgets and SCPs are global/us-east-1 resources.
 */

/** Root id of the YoTale org (management account 001188477936). Overridable via `-c orgRootId=`. */
const DEFAULT_ORG_ROOT_ID_CONTEXT = "orgRootId";

/** Approved monthly budget thresholds (USD) and alert percentages. */
const BUDGET_USD = { beta: 100, gamma: 50, prod: 100 } as const;
const ALERT_PERCENTAGES = [50, 80, 100] as const;

/** Where budget alerts are delivered. Overridable via `-c budgetAlertEmail=`. */
const DEFAULT_BUDGET_ALERT_EMAIL = "alerts@yotale.ai";

export interface OrgFoundationStackProps extends cdk.StackProps {
  /** Org root id (r-xxxx) under which the OUs are created. */
  readonly orgRootId: string;
  /** Email for budget notifications (forwarded admin inbox). */
  readonly budgetAlertEmail: string;
}

export class OrgFoundationStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: OrgFoundationStackProps) {
    super(scope, id, props);

    // ---- Organizational Units -------------------------------------------------
    const workloadsOu = new organizations.CfnOrganizationalUnit(this, "WorkloadsOu", {
      name: "Workloads",
      parentId: props.orgRootId,
    });
    const securityOu = new organizations.CfnOrganizationalUnit(this, "SecurityOu", {
      name: "Security",
      parentId: props.orgRootId,
    });
    const sandboxOu = new organizations.CfnOrganizationalUnit(this, "SandboxOu", {
      name: "Sandbox",
      parentId: props.orgRootId,
    });

    // ---- Service Control Policies ---------------------------------------------
    // 1) Region lock: deny all actions outside us-east-1 EXCEPT global services that only operate in
    //    us-east-1 / have no regional endpoint. Attached to the Workloads OU (not the root, so the
    //    management account itself is never fenced in).
    const regionLockScp = new organizations.CfnPolicy(this, "RegionLockScp", {
      name: "yotale-region-lock-us-east-1",
      type: "SERVICE_CONTROL_POLICY",
      description: "Deny actions outside us-east-1, with explicit global-service exceptions.",
      content: {
        Version: "2012-10-17",
        Statement: [
          {
            Sid: "DenyOutsideUsEast1",
            Effect: "Deny",
            NotAction: [
              // Global / partition-wide services with no regional isolation.
              "iam:*",
              "organizations:*",
              "sts:*",
              "route53:*",
              "route53domains:*",
              "cloudfront:*",
              "waf:*",
              "wafv2:*",
              "shield:*",
              "budgets:*",
              "ce:*",
              "cur:*",
              "account:*",
              "support:*",
              "trustedadvisor:*",
              "health:*",
              "globalaccelerator:*",
              "sso:*",
              "sso-directory:*",
              "identitystore:*",
              "artifact:*",
              "billing:*",
              "payments:*",
              "tax:*",
              "freetier:*",
              "notifications:*",
              "cloudtrail:*",
              // Bedrock inference profiles (us.anthropic.*) fan out to us-east-2 + us-west-2, so a Converse
              // via an inference profile legitimately invokes cross-region. Allow ONLY the invoke actions
              // outside us-east-1 (IAM still scopes which models); everything else stays region-locked.
              "bedrock:InvokeModel",
              "bedrock:InvokeModelWithResponseStream",
              "bedrock:Converse",
              "bedrock:ConverseStream",
            ],
            Resource: "*",
            Condition: {
              StringNotEquals: { "aws:RequestedRegion": "us-east-1" },
            },
          },
        ],
      },
      targetIds: [workloadsOu.attrId],
    });

    // 2) Protect the org/account-security surface: member accounts (and their roles) must not be able
    //    to leave the org, disable guardrails, or tamper with account-level security contacts.
    const protectSecurityScp = new organizations.CfnPolicy(this, "ProtectSecurityScp", {
      name: "yotale-protect-org-security",
      type: "SERVICE_CONTROL_POLICY",
      description: "Deny leaving the org and tampering with org/account security controls.",
      content: {
        Version: "2012-10-17",
        Statement: [
          {
            Sid: "DenyLeaveOrgAndTamper",
            Effect: "Deny",
            Action: [
              "organizations:LeaveOrganization",
              "organizations:DeleteOrganization",
              "organizations:RemoveAccountFromOrganization",
              "account:PutAlternateContact",
              "account:DeleteAlternateContact",
              "account:PutContactInformation",
              "account:CloseAccount",
              "cloudtrail:StopLogging",
              "cloudtrail:DeleteTrail",
            ],
            Resource: "*",
          },
        ],
      },
      // Attach to the three workload-bearing OUs; the Security OU keeps CloudTrail admin powers.
      targetIds: [workloadsOu.attrId, sandboxOu.attrId],
    });

    // ---- Per-account budgets --------------------------------------------------
    // Budgets are created per environment with 50/80/100% ACTUAL-spend notifications. These are alerts
    // only — no budgets:action is attached, so nothing is throttled or stopped. Note: these resources
    // live in the management account; a budget scoped to a member account is added once that member
    // account exists (via the LinkedAccount cost filter) — here we define the management-account-level
    // consolidated envelope per environment name, to be refined in the member-account increment.
    for (const [envName, amount] of Object.entries(BUDGET_USD)) {
      new budgets.CfnBudget(this, `Budget-${envName}`, {
        budget: {
          budgetName: `yotale-${envName}-monthly`,
          budgetType: "COST",
          timeUnit: "MONTHLY",
          budgetLimit: { amount, unit: "USD" },
        },
        notificationsWithSubscribers: ALERT_PERCENTAGES.map((pct) => ({
          notification: {
            notificationType: "ACTUAL",
            comparisonOperator: "GREATER_THAN",
            threshold: pct,
            thresholdType: "PERCENTAGE",
          },
          subscribers: [{ subscriptionType: "EMAIL", address: props.budgetAlertEmail }],
        })),
      });
    }

    // ---- Outputs --------------------------------------------------------------
    new cdk.CfnOutput(this, "WorkloadsOuId", { value: workloadsOu.attrId });
    new cdk.CfnOutput(this, "SecurityOuId", { value: securityOu.attrId });
    new cdk.CfnOutput(this, "SandboxOuId", { value: sandboxOu.attrId });
    new cdk.CfnOutput(this, "RegionLockScpId", { value: regionLockScp.attrId });
    new cdk.CfnOutput(this, "ProtectSecurityScpId", { value: protectSecurityScp.attrId });
  }
}
