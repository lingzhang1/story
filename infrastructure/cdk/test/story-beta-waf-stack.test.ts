import * as cdk from "aws-cdk-lib";
import { Template, Match } from "aws-cdk-lib/assertions";
import { StoryBetaWafStack } from "../lib/story-beta-waf-stack";

const APP_RUNNER_ARN =
  "arn:aws:apprunner:us-east-1:224033508028:service/story-beta-api/b4df1f58d93a4ef2ba3b573aafb206c1";
const TOPIC_ARN = "arn:aws:sns:us-east-1:224033508028:story-beta-observability-alarms";

function synth() {
  const app = new cdk.App();
  const stack = new StoryBetaWafStack(app, "story-beta-waf", {
    environment: "beta",
    appRunnerServiceArn: APP_RUNNER_ARN,
    alarmTopicArn: TOPIC_ARN,
    env: { account: "224033508028", region: "us-east-1" },
  });
  return Template.fromStack(stack);
}

describe("StoryBetaWafStack (P0 Beta Security Phase 2)", () => {
  const t = synth();

  test("one REGIONAL Web ACL, default Allow", () => {
    t.resourceCountIs("AWS::WAFv2::WebACL", 1);
    t.hasResourceProperties("AWS::WAFv2::WebACL", {
      Scope: "REGIONAL",
      DefaultAction: { Allow: {} },
    });
  });

  test("IP reputation + known bad inputs BLOCK (overrideAction none); CRS COUNT", () => {
    const acl = Object.values(t.findResources("AWS::WAFv2::WebACL"))[0] as any;
    const rules = acl.Properties.Rules;
    const byName = Object.fromEntries(rules.map((r: any) => [r.Name, r]));
    expect(byName.AmazonIpReputation.OverrideAction).toEqual({ None: {} });
    expect(byName.KnownBadInputs.OverrideAction).toEqual({ None: {} });
    expect(byName.CommonRuleSet.OverrideAction).toEqual({ Count: {} });
  });

  test("rate rule 600/IP in COUNT; body>2MB in COUNT (owner amendment)", () => {
    const acl = Object.values(t.findResources("AWS::WAFv2::WebACL"))[0] as any;
    const byName = Object.fromEntries(acl.Properties.Rules.map((r: any) => [r.Name, r]));
    expect(byName.RateLimitPerIp.Statement.RateBasedStatement.Limit).toBe(600);
    expect(byName.RateLimitPerIp.Action).toEqual({ Count: {} });
    expect(byName.BodySizeOver2MB.Statement.SizeConstraintStatement.Size).toBe(2 * 1024 * 1024);
    expect(byName.BodySizeOver2MB.Action).toEqual({ Count: {} });
  });

  test("rateBlock=true flips the RATE rule to Block; CRS STAYS Count (owner GO 2026-10-22)", () => {
    const app = new cdk.App();
    const stack = new StoryBetaWafStack(app, "story-beta-waf-block", {
      environment: "beta", appRunnerServiceArn: APP_RUNNER_ARN, alarmTopicArn: TOPIC_ARN,
      rateBlock: true, env: { account: "224033508028", region: "us-east-1" },
    });
    const acl = Object.values(Template.fromStack(stack).findResources("AWS::WAFv2::WebACL"))[0] as any;
    const byName = Object.fromEntries(acl.Properties.Rules.map((r: any) => [r.Name, r]));
    expect(byName.RateLimitPerIp.Action).toEqual({ Block: {} });        // rate rule now blocks
    expect(byName.CommonRuleSet.OverrideAction).toEqual({ Count: {} });  // CRS MUST remain Count
  });

  test("associates directly to the App Runner service (no CloudFront)", () => {
    t.hasResourceProperties("AWS::WAFv2::WebACLAssociation", {
      ResourceArn: APP_RUNNER_ARN,
    });
    t.resourceCountIs("AWS::CloudFront::Distribution", 0);
  });

  test("logging redacts sensitive headers and retains 30 days", () => {
    t.hasResourceProperties("AWS::WAFv2::LoggingConfiguration", {
      RedactedFields: Match.arrayWith([
        { SingleHeader: { Name: "authorization" } },
        { SingleHeader: { Name: "cookie" } },
      ]),
    });
    t.hasResourceProperties("AWS::Logs::LogGroup", {
      LogGroupName: "aws-waf-logs-story-beta",
      RetentionInDays: 30,
    });
  });

  test("REUSES the Observability SNS topic — creates NO topic of its own", () => {
    t.resourceCountIs("AWS::SNS::Topic", 0);
    // the alarm action points at the imported topic ARN
    const alarms = t.findResources("AWS::CloudWatch::Alarm");
    const actions = JSON.stringify(Object.values(alarms).map((a: any) => a.Properties.AlarmActions));
    expect(actions).toContain("story-beta-observability-alarms");
  });

  test("alarms exist and carry an action (never notification-less)", () => {
    const alarms = Object.values(t.findResources("AWS::CloudWatch::Alarm")) as any[];
    expect(alarms.length).toBeGreaterThanOrEqual(2);
    for (const a of alarms) {
      expect((a.Properties.AlarmActions ?? []).length).toBeGreaterThan(0);
    }
  });

  test("touches NO App Runner / Cognito / DynamoDB / S3 / SQS / Lambda resource", () => {
    for (const rt of ["AWS::AppRunner::Service", "AWS::Cognito::UserPool",
                       "AWS::DynamoDB::Table", "AWS::S3::Bucket", "AWS::SQS::Queue",
                       "AWS::Lambda::Function"]) {
      t.resourceCountIs(rt, 0);
    }
  });

  test("synthesis FAILS loudly without the Observability topic ARN (no silent action-less alarms)", () => {
    const app = new cdk.App();
    expect(() => new StoryBetaWafStack(app, "s", {
      environment: "beta", appRunnerServiceArn: APP_RUNNER_ARN, alarmTopicArn: "",
      env: { account: "224033508028", region: "us-east-1" },
    })).toThrow(/alarmTopicArn|notification-less/);
  });
});
