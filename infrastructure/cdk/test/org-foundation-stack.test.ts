import * as cdk from "aws-cdk-lib";
import { Template, Match } from "aws-cdk-lib/assertions";
import { OrgFoundationStack } from "../lib/org-foundation-stack";

function synth(): Template {
  const app = new cdk.App();
  const stack = new OrgFoundationStack(app, "yotale-org-foundation-test", {
    orgRootId: "r-test",
    budgetAlertEmail: "alerts@yotale.ai",
    env: { account: "001188477936", region: "us-east-1" },
  });
  return Template.fromStack(stack);
}

describe("OrgFoundationStack (B0 Phase 2 — OUs, SCPs, budgets)", () => {
  const template = synth();

  test("creates exactly three OUs (Workloads, Security, Sandbox)", () => {
    template.resourceCountIs("AWS::Organizations::OrganizationalUnit", 3);
    for (const name of ["Workloads", "Security", "Sandbox"]) {
      template.hasResourceProperties("AWS::Organizations::OrganizationalUnit", {
        Name: name,
        ParentId: "r-test",
      });
    }
  });

  test("creates two SCPs (region-lock + protect-security)", () => {
    template.resourceCountIs("AWS::Organizations::Policy", 2);
    template.hasResourceProperties("AWS::Organizations::Policy", {
      Name: "yotale-region-lock-us-east-1",
      Type: "SERVICE_CONTROL_POLICY",
    });
    template.hasResourceProperties("AWS::Organizations::Policy", {
      Name: "yotale-protect-org-security",
      Type: "SERVICE_CONTROL_POLICY",
    });
  });

  test("region-lock SCP denies outside us-east-1 and exempts IAM/Organizations/Route53", () => {
    const policies = template.findResources("AWS::Organizations::Policy");
    const regionLock = Object.values(policies).find(
      (p: any) => p.Properties.Name === "yotale-region-lock-us-east-1"
    ) as any;
    expect(regionLock).toBeDefined();
    const stmt = regionLock.Properties.Content.Statement[0];
    expect(stmt.Effect).toBe("Deny");
    expect(stmt.Condition.StringNotEquals["aws:RequestedRegion"]).toBe("us-east-1");
    expect(stmt.NotAction).toEqual(expect.arrayContaining(["iam:*", "organizations:*", "route53:*", "cloudfront:*", "sso:*"]));
    // Bedrock invoke is exempt from the region lock so us. inference profiles can fan out to us-east-2/us-west-2.
    expect(stmt.NotAction).toEqual(expect.arrayContaining([
      "bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream", "bedrock:Converse", "bedrock:ConverseStream",
    ]));
  });

  test("protect-security SCP denies leaving the org and tampering with contacts/CloudTrail", () => {
    const policies = template.findResources("AWS::Organizations::Policy");
    const protect = Object.values(policies).find(
      (p: any) => p.Properties.Name === "yotale-protect-org-security"
    ) as any;
    const actions = protect.Properties.Content.Statement[0].Action;
    expect(actions).toEqual(
      expect.arrayContaining([
        "organizations:LeaveOrganization",
        "account:PutAlternateContact",
        "cloudtrail:StopLogging",
      ])
    );
  });

  test("creates three budgets with the approved monthly amounts", () => {
    template.resourceCountIs("AWS::Budgets::Budget", 3);
    template.hasResourceProperties("AWS::Budgets::Budget", {
      Budget: Match.objectLike({ BudgetName: "yotale-beta-monthly", BudgetLimit: { Amount: 100, Unit: "USD" } }),
    });
    template.hasResourceProperties("AWS::Budgets::Budget", {
      Budget: Match.objectLike({ BudgetName: "yotale-gamma-monthly", BudgetLimit: { Amount: 50, Unit: "USD" } }),
    });
    template.hasResourceProperties("AWS::Budgets::Budget", {
      Budget: Match.objectLike({ BudgetName: "yotale-prod-monthly", BudgetLimit: { Amount: 100, Unit: "USD" } }),
    });
  });

  test("each budget alerts at 50/80/100% ACTUAL spend to the admin inbox (soft alerts, no action)", () => {
    const budgets = template.findResources("AWS::Budgets::Budget");
    for (const b of Object.values(budgets) as any[]) {
      const notifs = b.Properties.NotificationsWithSubscribers;
      expect(notifs).toHaveLength(3);
      const thresholds = notifs.map((n: any) => n.Notification.Threshold).sort((x: number, y: number) => x - y);
      expect(thresholds).toEqual([50, 80, 100]);
      for (const n of notifs) {
        expect(n.Notification.NotificationType).toBe("ACTUAL");
        expect(n.Subscribers[0]).toEqual({ SubscriptionType: "EMAIL", Address: "alerts@yotale.ai" });
      }
    }
  });

  test("does NOT create any member accounts (separate approved increment)", () => {
    template.resourceCountIs("AWS::Organizations::Account", 0);
  });
});
