/**
 * P0 Beta Observability — CloudWatch dashboards, alarms, SNS, Budget & log retention.
 *
 * A SEPARATE construct (not inlined into StoryApiStack) so the observability surface is reviewable on its own
 * and can be omitted per environment. Everything is environment-parameterized (development|beta|gamma|
 * production) via `props.environment`; nothing here assumes the beta account exists. Metrics come from:
 *   - FREE AWS service metrics (SQS queue age / DLQ depth, Lambda Errors/Throttles/Duration/Concurrency,
 *     App Runner 5xx/RequestLatency) — preferred over custom metrics per the design.
 *   - CUSTOM EMF metrics in namespace "Story/Beta" emitted by the worker/api (GenerationStarted/Completed/
 *     Failed, QueueWaitMs, WorkerProcessingMs, ModelInvocations, InputTokens/OutputTokens,
 *     EstimatedModelCostUSD, ModelFallbacks, BedrockThrottles, RepairCount, CritiqueCount).
 *
 * This construct DEFINES resources; it does not provision anything until `cdk deploy` runs. Per the STOP gate
 * the owner deploys it only after B0 beta infra is accepted.
 */
import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as cloudwatch from "aws-cdk-lib/aws-cloudwatch";
import * as cwactions from "aws-cdk-lib/aws-cloudwatch-actions";
import * as sns from "aws-cdk-lib/aws-sns";
import * as snsSubs from "aws-cdk-lib/aws-sns-subscriptions";
import * as logs from "aws-cdk-lib/aws-logs";
import * as sqs from "aws-cdk-lib/aws-sqs";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as budgets from "aws-cdk-lib/aws-budgets";

const NAMESPACE = "Story/Beta";

export interface ObservabilityProps {
  /** development | beta | gamma | production — drives every resource name + retention/budget defaults. */
  readonly environment: string;
  /** The async job queue + its DLQ (free SQS metrics). */
  readonly jobsQueue: sqs.IQueue;
  readonly dlq: sqs.IQueue;
  /** The worker Lambda (free Lambda metrics + its log group for retention). */
  readonly worker: lambda.IFunction;
  /** App Runner service NAME (L1 CfnService exposes the name, used as the metric dimension). */
  readonly apiServiceName: string;
  /**
   * Optional SNS alarm destination (email or https Slack webhook). When omitted the topic is still created
   * (alarms wire to it) but has no subscription — the one value the owner fills before notification
   * acceptance (design amendment 7). An '@' is treated as email, anything starting with 'https' as a URL.
   */
  readonly alarmDestination?: string;
  /** Monthly USD budget for the AWS Budgets actual-spend alerts (50/80/100%). Default 100 in beta/dev. */
  readonly monthlyBudgetUsd?: number;
  /**
   * Create the AWS Budget resource here. DEFAULT FALSE: B0 provisions the account-level budget, and two
   * budgets over the same account double-notify (req 5). Enable only when B0 does NOT own the account budget.
   * The SNS alarm topic, dashboards and alarms are created regardless of this flag.
   */
  readonly createBudget?: boolean;
}

/** Explicit per-environment log retention (privacy + cost; design Phase 1). */
function retentionFor(environment: string): logs.RetentionDays {
  switch (environment) {
    case "production":
    case "gamma":
      return logs.RetentionDays.THREE_MONTHS; // 90d
    case "beta":
      return logs.RetentionDays.TWO_MONTHS; // 60d
    default:
      return logs.RetentionDays.ONE_MONTH; // 30d dev
  }
}

export class Observability extends Construct {
  public readonly alarmTopic: sns.Topic;
  public readonly dashboards: cloudwatch.Dashboard[] = [];
  public readonly alarms: cloudwatch.Alarm[] = [];

  constructor(scope: Construct, id: string, props: ObservabilityProps) {
    super(scope, id);
    const { environment, jobsQueue, dlq, worker, apiServiceName } = props;
    const env = environment;

    // ---- SNS alarm topic (one topic, owner-approved destination) ---------------------------------------
    this.alarmTopic = new sns.Topic(this, "AlarmTopic", {
      topicName: `story-${env}-observability-alarms`,
      displayName: `Story ${env} observability alarms`,
    });
    if (props.alarmDestination) {
      const d = props.alarmDestination;
      if (d.includes("@")) {
        this.alarmTopic.addSubscription(new snsSubs.EmailSubscription(d));
      } else if (d.startsWith("https")) {
        this.alarmTopic.addSubscription(new snsSubs.UrlSubscription(d));
      }
    }
    const alarmAction = new cwactions.SnsAction(this.alarmTopic);

    // ---- Explicit log retention on the worker log group (privacy + cost) -------------------------------
    // The App Runner application/service log groups are created by the service; retention there is set via a
    // separate LogRetention custom resource keyed by the known group names so we never assume defaults.
    new logs.LogRetention(this, "WorkerLogRetention", {
      logGroupName: `/aws/lambda/${worker.functionName}`,
      retention: retentionFor(env),
    });
    for (const suffix of ["application", "service"]) {
      new logs.LogRetention(this, `ApiLogRetention-${suffix}`, {
        logGroupName: `/aws/apprunner/${apiServiceName}/${suffix}`,
        retention: retentionFor(env),
      });
    }

    // ---- Metric helpers --------------------------------------------------------------------------------
    const dims = (extra: Record<string, string> = {}) => ({ env, ...extra });
    const custom = (name: string, stat = "Sum", extraDims: Record<string, string> = {}) =>
      new cloudwatch.Metric({
        namespace: NAMESPACE, metricName: name, statistic: stat,
        period: cdk.Duration.minutes(5), dimensionsMap: dims(extraDims),
      });
    const sqsM = (q: sqs.IQueue, name: string, stat = "Maximum") =>
      q.metric(name, { statistic: stat, period: cdk.Duration.minutes(5) });

    // Free service metrics
    const dlqDepth = sqsM(dlq, "ApproximateNumberOfMessagesVisible");
    const queueAge = sqsM(jobsQueue, "ApproximateAgeOfOldestMessage");
    const lambdaErrors = worker.metricErrors({ period: cdk.Duration.minutes(5), statistic: "Sum" });
    const lambdaThrottles = worker.metricThrottles({ period: cdk.Duration.minutes(5), statistic: "Sum" });
    const lambdaDuration = worker.metricDuration({ period: cdk.Duration.minutes(5), statistic: "p99" });
    const appRunner5xx = new cloudwatch.Metric({
      namespace: "AWS/AppRunner", metricName: "5xxStatusResponses", statistic: "Sum",
      period: cdk.Duration.minutes(5), dimensionsMap: { ServiceName: apiServiceName },
    });
    const appRunnerLatency = new cloudwatch.Metric({
      namespace: "AWS/AppRunner", metricName: "RequestLatency", statistic: "p95",
      period: cdk.Duration.minutes(5), dimensionsMap: { ServiceName: apiServiceName },
    });

    // Custom product/AI metrics
    const started = custom("GenerationStarted");
    const completed = custom("GenerationCompleted");
    const failed = custom("GenerationFailed");
    const estCost = custom("EstimatedModelCostUSD");
    const invocations = custom("ModelInvocations");
    const inTok = custom("InputTokens");
    const outTok = custom("OutputTokens");
    const fallbacks = custom("ModelFallbacks");
    const throttles = custom("BedrockThrottles");
    const repairs = custom("RepairCount");
    const critiques = custom("CritiqueCount");
    const queueWait = custom("QueueWaitMs", "p95");
    const workerMs = custom("WorkerProcessingMs", "p95");

    // Failure rate as a % of started, with a MINIMUM SAMPLE COUNT guard (amendment 3): the expression yields
    // 0 unless there are >= 5 starts in the window, so one failure in two requests never pages.
    const failureRatePct = new cloudwatch.MathExpression({
      expression: "IF(starts >= 5, 100 * fails / starts, 0)",
      usingMetrics: { starts: started, fails: failed },
      period: cdk.Duration.minutes(10), label: "GenerationFailure% (min 5 starts)",
    });
    const successRate = new cloudwatch.MathExpression({
      expression: "IF(starts > 0, 100 * done / starts, 100)",
      usingMetrics: { starts: started, done: completed },
      period: cdk.Duration.minutes(5), label: "OperationSuccessRate%",
    });

    // ---- Dashboard 1 — Product & Generation Health -----------------------------------------------------
    const d1 = new cloudwatch.Dashboard(this, "ProductHealth", {
      dashboardName: `story-${env}-product-generation-health`,
    });
    d1.addWidgets(
      new cloudwatch.GraphWidget({ title: "Generations started / completed / failed",
        left: [started, completed, failed], width: 12 }),
      new cloudwatch.SingleValueWidget({ title: "Success rate %", metrics: [successRate], width: 6 }),
      new cloudwatch.GraphWidget({ title: "Backend job time vs CLIENT time-to-playable (distinct series)",
        left: [workerMs, queueWait],
        right: [custom("TimeToPlayableVideo", "p95"), custom("TimeToPlayableVideo", "p50")], width: 12,
        leftYAxis: { label: "backend ms" }, rightYAxis: { label: "client ms (playback, NOT planning)" } }),
      new cloudwatch.GraphWidget({ title: "Cancellation / recovery / duplicate-prevention",
        left: [custom("GenerationCancelled"), custom("GenerationRecovered"),
               custom("DuplicateInferencePrevented")], width: 6 }),
    );

    // ---- Dashboard 2 — AI Usage / Latency / Throttling / Cost ------------------------------------------
    const d2 = new cloudwatch.Dashboard(this, "AiUsageCost", {
      dashboardName: `story-${env}-ai-usage-latency-cost`,
    });
    d2.addWidgets(
      new cloudwatch.GraphWidget({ title: "Model invocations & fallbacks", left: [invocations, fallbacks], width: 8 }),
      new cloudwatch.GraphWidget({ title: "Tokens (in/out)", left: [inTok, outTok], width: 8 }),
      new cloudwatch.SingleValueWidget({ title: "Estimated model cost (USD, daily sum)",
        metrics: [estCost.with({ statistic: "Sum", period: cdk.Duration.days(1) })], width: 8 }),
      new cloudwatch.GraphWidget({ title: "Model latency p50/p95",
        left: [custom("ModelLatencyMs", "p50"), custom("ModelLatencyMs", "p95")], width: 12 }),
      new cloudwatch.GraphWidget({ title: "Throttles / repairs / critiques",
        left: [throttles, repairs, critiques], width: 8 }),
      new cloudwatch.GraphWidget({ title: "Missing model pricing (unpriced attempts — $ gap, NOT free)",
        left: [custom("MissingModelPricing")], width: 4 }),
    );

    // ---- Dashboard 3 — Infra & Async Queue Health (mostly FREE metrics) --------------------------------
    const d3 = new cloudwatch.Dashboard(this, "InfraQueueHealth", {
      dashboardName: `story-${env}-infra-queue-health`,
    });
    d3.addWidgets(
      new cloudwatch.GraphWidget({ title: "Queue depth & age", left: [
        sqsM(jobsQueue, "ApproximateNumberOfMessagesVisible"), queueAge], width: 8 }),
      new cloudwatch.GraphWidget({ title: "DLQ depth", left: [dlqDepth], width: 4 }),
      new cloudwatch.GraphWidget({ title: "Lambda errors / throttles / p99 duration",
        left: [lambdaErrors, lambdaThrottles], right: [lambdaDuration], width: 12 }),
      new cloudwatch.GraphWidget({ title: "App Runner 5xx & p95 latency",
        left: [appRunner5xx], right: [appRunnerLatency], width: 12 }),
      new cloudwatch.GraphWidget({ title: "Queue wait vs worker exec (ms, distinct)",
        left: [queueWait], right: [workerMs], width: 12 }),
    );

    // ---- Dashboard 4 — Auth, Quota & Beta Usage (schema now; data with the auth milestone) -------------
    const d4 = new cloudwatch.Dashboard(this, "AuthQuotaBeta", {
      dashboardName: `story-${env}-auth-quota-beta-usage`,
    });
    d4.addWidgets(
      new cloudwatch.TextWidget({ markdown:
        `## Auth / Quota / Beta usage\n_Widgets reserved — populated when the auth/quota milestone lands ` +
        `(no principal exists yet). Metrics: AuthFailures, AuthorizationDenials, QuotaConsumed, QuotaDenials, ` +
        `RateLimitDenials, ActiveUsers, GenerationsPerUserDay._`, width: 24, height: 3 }),
      new cloudwatch.GraphWidget({ title: "Auth failures / authz denials",
        left: [custom("AuthFailures"), custom("AuthorizationDenials")], width: 8 }),
      new cloudwatch.GraphWidget({ title: "Quota consumed / denials / rate-limit denials",
        left: [custom("QuotaConsumed"), custom("QuotaDenials"), custom("RateLimitDenials")], width: 8 }),
      new cloudwatch.GraphWidget({ title: "Active users (daily)",
        left: [custom("ActiveUsers", "Maximum", {})], width: 8 }),
    );
    this.dashboards.push(d1, d2, d3, d4);

    // ---- Alarms (low-noise; multi-datapoint; explicit treatMissingData) --------------------------------
    const GTE = cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD;
    const GT = cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD;
    const mk = (
      id: string, metric: cloudwatch.IMetric,
      opts: { threshold: number; evaluationPeriods: number; comparisonOperator: cloudwatch.ComparisonOperator;
              datapointsToAlarm?: number },
      treatMissing: cloudwatch.TreatMissingData = cloudwatch.TreatMissingData.NOT_BREACHING,
    ) => {
      const a = new cloudwatch.Alarm(this, id, {
        alarmName: `story-${env}-${id}`, metric,
        threshold: opts.threshold, evaluationPeriods: opts.evaluationPeriods,
        comparisonOperator: opts.comparisonOperator, datapointsToAlarm: opts.datapointsToAlarm,
        treatMissingData: treatMissing,
      });
      a.addAlarmAction(alarmAction);
      this.alarms.push(a);
      return a;
    };

    // 1. DLQ non-empty — a message present must page.
    mk("dlq-non-empty", dlqDepth, { threshold: 1, evaluationPeriods: 1, comparisonOperator: GTE });
    // 2. Queue backlog/age > 5 min for 2 of 3 windows.
    mk("queue-age-backlog", queueAge, { threshold: 300_000, evaluationPeriods: 3, datapointsToAlarm: 2,
       comparisonOperator: GT });
    // 3. Lambda failures >= 3 in 5 min.
    mk("lambda-errors", lambdaErrors, { threshold: 3, evaluationPeriods: 1, comparisonOperator: GTE });
    // 4. Lambda p99 duration sustained near timeout (2 x 5 min).
    mk("lambda-duration-p99", lambdaDuration, { threshold: 25_000, evaluationPeriods: 2, comparisonOperator: GT });
    // 5. App Runner 5xx sustained.
    mk("apprunner-5xx", appRunner5xx, { threshold: 5, evaluationPeriods: 2, comparisonOperator: GT });
    // 6. Generation failure rate > 20% (with >=5 starts guard baked into the expression), 2 windows.
    mk("generation-failure-rate", failureRatePct, { threshold: 20, evaluationPeriods: 2, comparisonOperator: GT });
    // 7. Bedrock sustained throttling (not a single spike): 15 min window, 3 datapoints.
    mk("bedrock-throttling", throttles, { threshold: 3, evaluationPeriods: 3, datapointsToAlarm: 3,
       comparisonOperator: GT });
    // 8. Quota ENFORCEMENT error (distinct from a normal denial) — alarms on any error. Schema now.
    mk("quota-enforcement-error", custom("QuotaEnforcementError"), { threshold: 0, evaluationPeriods: 1,
       comparisonOperator: GT });
    // 9. Abnormal daily model cost over the budget line.
    mk("abnormal-model-cost", estCost.with({ statistic: "Sum", period: cdk.Duration.days(1) }),
       { threshold: props.monthlyBudgetUsd ? props.monthlyBudgetUsd / 15 : 20, evaluationPeriods: 1,
         comparisonOperator: GT });
    // 10. Unauthorized-access anomaly (possible probing). Schema now (auth milestone populates it).
    mk("unauthorized-access-anomaly", custom("AuthorizationDenials"), { threshold: 20, evaluationPeriods: 1,
       comparisonOperator: GT });

    // ---- AWS Budget — monthly, with 50/80/100% ACTUAL-spend notifications ------------------------------
    // Beta/dev default = $100 (req 7). GATED on createBudget (default false) so this never duplicates B0's
    // account-level budget (req 5) — when B0 owns the account budget, leave createBudget off and rely on the
    // `abnormal-model-cost` CloudWatch alarm (which is independent of AWS Budgets) for cost paging.
    const budget = props.monthlyBudgetUsd ?? (env === "production" ? 500 : 100);
    const notify = props.alarmDestination && props.alarmDestination.includes("@")
      ? [{ subscriptionType: "EMAIL", address: props.alarmDestination }]
      : undefined;
    if (props.createBudget && notify) {
      new budgets.CfnBudget(this, "MonthlyBudget", {
        budget: { budgetType: "COST", timeUnit: "MONTHLY",
          budgetLimit: { amount: budget, unit: "USD" }, budgetName: `story-${env}-monthly` },
        notificationsWithSubscribers: [50, 80, 100].map((pct) => ({
          notification: { notificationType: "ACTUAL", comparisonOperator: "GREATER_THAN",
            threshold: pct, thresholdType: "PERCENTAGE" },
          subscribers: notify as any,
        })),
      });
    }

    new cdk.CfnOutput(this, "AlarmTopicArn", { value: this.alarmTopic.topicArn });
  }
}
