import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as wafv2 from "aws-cdk-lib/aws-wafv2";
import * as logs from "aws-cdk-lib/aws-logs";
import * as cloudwatch from "aws-cdk-lib/aws-cloudwatch";
import * as cwactions from "aws-cdk-lib/aws-cloudwatch-actions";
import * as sns from "aws-cdk-lib/aws-sns";

/**
 * StoryBetaWafStack — P0 Beta Security Phase 2 (AWS WAF & API abuse protection).
 *
 * DESIGN/REVIEW-GATED: instantiated only with `-c deployWaf=true`, so a normal synth/deploy never touches
 * it. REGIONAL WAFv2 Web ACL associated DIRECTLY to the beta App Runner service (no CloudFront).
 *
 * Owner-approved rules (2026-10-21), amendment: rule 5 starts in COUNT (not Block):
 *   0 Amazon IP Reputation            — Block
 *   1 Known Bad Inputs                — Block
 *   2 Common Rule Set (OWASP)         — Count (flip to Block after observing legitimate traffic)
 *   3 Rate-based 600 req / 5 min / IP — Count (flip to Block after observation)
 *   4 Request body > 2 MB             — Count (not Block, until real sizes + WAF inspection limits verified)
 *
 * It touches NOTHING else: App Runner, Cognito, S3, DynamoDB, SQS, Lambda, worker concurrency and auth are
 * untouched. The association REFERENCES the App Runner service ARN; it does not modify the service.
 *
 * Alarms REUSE the Observability thread's SNS topic (story-<env>-observability-alarms). This stack NEVER
 * creates an SNS topic, and it does NOT create notification-less alarms and call alerting done: if the topic
 * ARN is not supplied (and cannot be derived), synthesis FAILS loudly so the operator wires it explicitly.
 */
export interface StoryBetaWafStackProps extends cdk.StackProps {
  readonly environment: string;
  /** ARN of the App Runner service to protect. */
  readonly appRunnerServiceArn: string;
  /** ARN of the EXISTING Observability SNS topic to reuse for WAF alarms. Required — no duplicate topic. */
  readonly alarmTopicArn: string;
  /** Per-IP rate limit over a 5-minute window. */
  readonly rateLimit?: number;
  /** Max request body bytes before the size rule matches. */
  readonly maxBodyBytes?: number;
  /** Owner-approved 2026-10-22: flip the per-IP RATE rule from Count to Block (CRS stays Count). */
  readonly rateBlock?: boolean;
}

export class StoryBetaWafStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: StoryBetaWafStackProps) {
    super(scope, id, props);
    const env = props.environment;
    const rateLimit = props.rateLimit ?? 600;      // requests / 5 min / IP
    const maxBodyBytes = props.maxBodyBytes ?? 2 * 1024 * 1024; // 2 MB

    if (!props.alarmTopicArn) {
      // Loud failure — do NOT create alarms with no action and call alerting complete (owner amendment).
      throw new Error(
        "StoryBetaWafStack requires alarmTopicArn (the existing Observability SNS topic " +
          `story-${env}-observability-alarms). Refusing to create notification-less alarms.`
      );
    }
    if (!props.appRunnerServiceArn) {
      throw new Error("StoryBetaWafStack requires appRunnerServiceArn (the beta App Runner service to protect).");
    }

    // Managed rule group that only COUNTS: override the group's action to Count via overrideAction=count.
    const metric = (name: string) => ({ cloudWatchMetricsEnabled: true, metricName: name, sampledRequestsEnabled: true });

    const rules: wafv2.CfnWebACL.RuleProperty[] = [
      {
        name: "AmazonIpReputation", priority: 0,
        statement: { managedRuleGroupStatement: { vendorName: "AWS", name: "AWSManagedRulesAmazonIpReputationList" } },
        overrideAction: { none: {} },           // group's own Block actions apply
        visibilityConfig: metric("AmazonIpReputation"),
      },
      {
        name: "KnownBadInputs", priority: 1,
        statement: { managedRuleGroupStatement: { vendorName: "AWS", name: "AWSManagedRulesKnownBadInputsRuleSet" } },
        overrideAction: { none: {} },           // Block
        visibilityConfig: metric("KnownBadInputs"),
      },
      {
        name: "CommonRuleSet", priority: 2,
        statement: { managedRuleGroupStatement: { vendorName: "AWS", name: "AWSManagedRulesCommonRuleSet" } },
        overrideAction: { count: {} },          // COUNT first (flip to {none:{}} to enable blocking)
        visibilityConfig: metric("CommonRuleSet"),
      },
      {
        name: "RateLimitPerIp", priority: 3,
        statement: { rateBasedStatement: { limit: rateLimit, aggregateKeyType: "IP" } },
        // Owner GO 2026-10-22: Block when rateBlock=true (0 false-positive counts in 72h), else Count. The CRS
        // rule above STAYS Count (76 false-positive counts on AI JSON bodies — do NOT block it).
        action: props.rateBlock ? { block: {} } : { count: {} },
        visibilityConfig: metric("RateLimitPerIp"),
      },
      {
        name: "BodySizeOver2MB", priority: 4,
        statement: {
          sizeConstraintStatement: {
            fieldToMatch: { body: { oversizeHandling: "CONTINUE" } },
            comparisonOperator: "GT",
            size: maxBodyBytes,
            textTransformations: [{ priority: 0, type: "NONE" }],
          },
        },
        action: { count: {} },                  // COUNT first (owner amendment — not Block until verified)
        visibilityConfig: metric("BodySizeOver2MB"),
      },
    ];

    const acl = new wafv2.CfnWebACL(this, "BetaWebAcl", {
      name: `story-${env}-api-waf`,
      scope: "REGIONAL",
      defaultAction: { allow: {} },
      rules,
      visibilityConfig: metric(`story-${env}-api-waf`),
    });

    // Direct association to the App Runner service (no CloudFront).
    new wafv2.CfnWebACLAssociation(this, "BetaWebAclAssociation", {
      resourceArn: props.appRunnerServiceArn,
      webAclArn: acl.attrArn,
    });

    // WAF logging -> dedicated CloudWatch Logs group (WAFv2 requires the aws-waf-logs- prefix), 30d retention,
    // with sensitive headers redacted so bearer tokens / cookies never land in logs.
    const logGroup = new logs.LogGroup(this, "WafLogGroup", {
      logGroupName: `aws-waf-logs-story-${env}`,
      retention: logs.RetentionDays.ONE_MONTH, // 30 days
      removalPolicy: cdk.RemovalPolicy.DESTROY, // a log group is reproducible; safe to destroy with the stack
    });
    new wafv2.CfnLoggingConfiguration(this, "WafLogging", {
      resourceArn: acl.attrArn,
      logDestinationConfigs: [logGroup.logGroupArn],
      redactedFields: [
        { singleHeader: { Name: "authorization" } },
        { singleHeader: { Name: "cookie" } },
        { singleHeader: { Name: "x-api-key" } },
      ],
    });

    // Alarms wired to the REUSED Observability SNS topic (imported by ARN — no topic created here).
    const alarmTopic = sns.Topic.fromTopicArn(this, "ObservabilityAlarmTopic", props.alarmTopicArn);
    const alarmAction = new cwactions.SnsAction(alarmTopic);

    const blocked = new cloudwatch.Metric({
      namespace: "AWS/WAFV2",
      metricName: "BlockedRequests",
      dimensionsMap: { WebACL: `story-${env}-api-waf`, Region: this.region, Rule: "ALL" },
      statistic: "Sum", period: cdk.Duration.minutes(5),
    });
    const blockedAlarm = new cloudwatch.Alarm(this, "WafBlockedRequestsAlarm", {
      alarmName: `story-${env}-waf-blocked-requests`,
      metric: blocked, threshold: 100, evaluationPeriods: 1,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      alarmDescription: "WAF blocked an unusual number of requests in 5 min (possible attack or false positive).",
    });
    blockedAlarm.addAlarmAction(alarmAction);

    // The rate rule runs in COUNT first; alarm on its CountedRequests so we can SEE abuse before flipping to
    // Block, and review false positives during the Count window.
    const rateCounted = new cloudwatch.Metric({
      namespace: "AWS/WAFV2",
      metricName: "CountedRequests",
      dimensionsMap: { WebACL: `story-${env}-api-waf`, Region: this.region, Rule: "RateLimitPerIp" },
      statistic: "Sum", period: cdk.Duration.minutes(5),
    });
    const rateAlarm = new cloudwatch.Alarm(this, "WafRateCountedAlarm", {
      alarmName: `story-${env}-waf-rate-counted`,
      metric: rateCounted, threshold: 600, evaluationPeriods: 1,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      alarmDescription: "Rate rule counted a burst (observation mode) — review before flipping to Block.",
    });
    rateAlarm.addAlarmAction(alarmAction);

    new cdk.CfnOutput(this, "WebAclArn", { value: acl.attrArn });
    new cdk.CfnOutput(this, "WafLogGroupName", { value: logGroup.logGroupName });
  }
}
