# Org-Foundation IaC — Source ↔ Live Reconciliation

**Status: RECOVERED SOURCE, DEPLOYMENT DEFERRED.** Do NOT `cdk deploy` this stack.
**Read-only audit date:** 2026-10-24. **Management account:** 001188477936. **Org root:** `r-6dce`.

## Provenance
Recovered from `feat/r1-account-ownership-isolation` commits `5441a1d` (stack) and `97586c1`
(region-lock SCP bedrock-invoke exemption). The three other commits on that branch
(beta OIDC pipeline, SES DEVELOPER mode, worker reservedConcurrency) were **excluded** — they
are already present on master (`deploy-beta.yml`, `story-auth-stack.ts` SES block ln 66-75,
`story-api-stack.ts` reservedConcurrentExecutions ln 294).

## Files
- `infrastructure/cdk/lib/org-foundation-stack.ts`
- `infrastructure/cdk/test/org-foundation-stack.test.ts`
- Minimal `bin/app.ts` wiring: context-gated (`-c deployOrgFoundation=true -c orgRootId=r-xxxx`),
  management-account-only. A normal api/auth/waf synth never instantiates it.

## Critical finding — EVERY declared resource ALREADY EXISTS live

The Organizations resources were deployed out-of-band; only the CDK source was never merged.
A fresh `cdk deploy` would attempt to **CREATE duplicates** → `AlreadyExists`/conflict. This
needs **CDK import / resource adoption**, NOT a deploy.

### Organizational Units (declared 3 — all live under root r-6dce)
| Declared (stack) | Live id | Match |
|---|---|---|
| Workloads | `ou-6dce-u19fn3wl` | ✅ exists |
| Security  | `ou-6dce-57g6g62t` | ✅ exists |
| Sandbox   | `ou-6dce-rical63w` | ✅ exists |

### Service Control Policies (declared 2 — both live)
| Declared (stack) | Live id | Live attachment | Match |
|---|---|---|---|
| `yotale-region-lock-us-east-1` | `p-njbqhrap` | Workloads OU | ✅ exists + attached |
| `yotale-protect-org-security`  | `p-0nmld7v3` | Sandbox + Workloads OUs | ✅ exists + attached |

(Also live, not declared here: `p-FullAWSAccess`, `p-hf8k7ynx` DenyLeaveAndCloseAccount.)

### Budgets (live in mgmt acct 001188477936)
`yotale-beta-monthly` ($100), `yotale-gamma-monthly` ($50), `yotale-prod-monthly` ($100).
The stack declares env-scoped budgets — reconcile names/amounts before any adoption.

## Answers to the reconciliation questions
1. **Already on master?** No — source absent; recovered here.
2. **Relevant to current Org architecture?** Yes — it is the IaC for the live resources above.
3. **Conflicts with deployed infra?** YES if deployed as-is — every OU/SCP already exists →
   duplicate-create conflict. Live resources are authoritative.
4. **Necessary before TestFlight?** No. Not a release blocker.
5. **Could it modify/replace AWS resources?** Yes, if ever deployed — it touches Organizations,
   SCPs, budgets. Hence deferred + import-gated.
6. **Retain/rewrite/defer/discard?** RETAIN as reviewed IaC; DEFER deploy. Before any deploy,
   perform `cdk import` to adopt `r-6dce` OUs + SCPs `p-njbqhrap`/`p-0nmld7v3` + existing budgets,
   then `cdk diff` must show **zero create/replace/delete** before proceeding.

## Required before any future deploy (NOT done here)
- `cdk import yotale-org-foundation` to adopt the 3 OUs, 2 SCPs, and budgets by their live ids.
- Confirm `cdk diff` is clean (no create/replace/delete) under `AWS_PROFILE=yotale-mgmt`.
- Verify SCP `content` byte-matches live policy JSON (esp. the region-lock bedrock NotAction set).

## Assertion discipline
TypeScript compile + `cdk synth` + jest green do **NOT** prove deployment safety here — they
cannot see that the resources already exist. Live Organizations state is authoritative.
