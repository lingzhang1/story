# YoTale — TestFlight Email Self-Sign-up / Sign-in (Option A)

**Status: IMPLEMENTED on branch `feat/testflight-email-self-signup` — OFFLINE-TESTED — NOT MERGED — NOT DEPLOYED — DEVICE ACCEPTANCE PENDING — BETA-ARCHIVE CONFIG BLOCKER OPEN (§Beta configuration).**

Milestone: let any valid email self-register for the YoTale beta through the existing passwordless
EMAIL_OTP experience, with **no manual admin provisioning**, while existing users sign in unchanged and
every backend security control is preserved. Owner-approved Option A.

---

## 1. Existing vs new flow (one email-first UI)

Single screen, single journey: **enter email → Continue → receive a code → enter it → you're in.** The
client resolves new-vs-existing behind the scenes and runs the correct Cognito operation. No passwords, no
invite codes, no separate registration screen.

| | New user (self-signup) | Existing user (unchanged) |
|---|---|---|
| Resolve | `SignUp` succeeds → account created | `SignUp` → `UsernameExistsException` → fall through |
| Code source | Cognito `SignUp` verification code | `InitiateAuth(USER_AUTH, EMAIL_OTP)` challenge code |
| Verify op | `ConfirmSignUp` | `RespondToAuthChallenge(EMAIL_OTP_CODE)` |
| First sign-in | `ConfirmSignUp` returns `Session` → `InitiateAuth(USER_AUTH, Session)` → tokens (no 2nd code) | tokens returned directly |
| Fallback | if no usable `Session`: one standard EMAIL_OTP sign-in | n/a |

`OTPChallenge.kind` (`.signUp` / `.signIn`) carries which operation the pending code belongs to, so the
shared code-entry UI never guesses.

## 2. Cognito operations used
`SignUp` (passwordless) · `ConfirmSignUp` · `ResendConfirmationCode` · `InitiateAuth(USER_AUTH,
PREFERRED_CHALLENGE=EMAIL_OTP)` · `InitiateAuth(USER_AUTH, Session)` · `RespondToAuthChallenge`. Apple OAuth
code+PKCE unchanged.

## 3. Passwordless prerequisites — VERIFIED (dev pool `us-east-1_AzfHOEdA5`, client `5rnvp7oq6d7crbt01ldpe89tkh`)
- Self-signup enabled (`AllowAdminCreateUserOnly=false`). ✅
- Tier **ESSENTIALS** (native EMAIL_OTP feature plan). ✅
- `AllowedFirstAuthFactors=[PASSWORD, EMAIL_OTP]`; app client flows `[ALLOW_USER_AUTH, ALLOW_REFRESH_TOKEN_AUTH]`. ✅
- `AutoVerifiedAttributes=[email]`, `UsernameAttributes=[email]` (email IS the username, not an alias). ✅
- `PreventUserExistenceErrors=ENABLED` (anti-enumeration). ✅
- SDK `SignUp` is passwordless (AWS docs: *"For SDK-based SignUp operations, users aren't required to supply
  a password"*). The iOS client uses the raw IDP JSON API, not hosted UI. ✅
- `ConfirmSignUp` returns a `Session` usable to immediately sign in via `USER_AUTH` (AWS `ConfirmSignUp` API
  reference, Response Elements → `Session`). ✅
- Admin-provisioned accounts remain compatible — they are ordinary CONFIRMED users and take the existing-user
  branch unchanged. ✅

**No pool-plan, SES, or infrastructure change is required** for the mechanism. (Beta pool not re-verified
live this session — `yotale-beta` SSO token was expired; the beta `StoryAuthStack` CDK encodes the same
ESSENTIALS + self-signup + USER_AUTH shape. Re-verify against the live beta pool before beta archive.)

## 4. Account-status semantics (backend, unchanged)
New backend accounts are created `account_status=active`, `beta_access_status=invited`, and `_enforce_status`
admits `{eligible, invited}` in all non-development envs — so a self-registered tester is admitted with **no
backend change**. Explicit `revoked`/`waitlisted`/`denied` still 403. Suspended/deleted accounts still 403.
No change to JWT validation, the central auth boundary, ownership isolation, WAF, throttle, or quota.

## 5. Error recovery (handled)
Existing-confirmed · new-account · existing-unconfirmed (UsernameExists → OTP recovery) · duplicate signup
(falls through to sign-in) · resend (ResendConfirmationCode for `.signUp`, fresh InitiateAuth for `.signIn`) ·
expired code · wrong code · throttling (`tooManyAttempts`) · network failure (`transport`) · disabled/revoked
(`accountDisabled`, never silently recreated) · app-restart mid-registration (account already created in
Cognito → next launch resolves as existing-user OTP; no duplicate). No admin bypass; minimal enumeration.

## 6. Auth security
No security control changed. Backend auth suite GREEN
(`test_central_auth_boundary.py`, `test_paid_endpoint_protection.py`, `test_auth_and_job_ownership.py` — 45
tests). Enumeration-safe copy; removed all "invite-only" user-facing strings.

## 7. Beta configuration — RELEASE BLOCKER (open, minimal fix identified)
`StoryLaunchConfig` resolves `env var → persisted UserDefaults → nil → dev default`. For a **TestFlight
archive**, `ProcessInfo.environment` is empty (not an attached Xcode run) and a tester's fresh install has
nothing persisted, so the app falls through to the **dev** pool/API defaults. The Xcode scheme env rows
cannot fix this (they inject only on attached launch). The project has only `Debug`/`Release` configs and no
compile-time environment flag.

**Minimal correction to propose (not yet implemented, pending owner go-ahead):** add a dedicated **Beta**
build configuration (or an archive scheme) that sets a compile-time flag (e.g.
`SWIFT_ACTIVE_COMPILATION_CONDITIONS = BETA_RELEASE`), and make `StoryAuthConfig`/`StoryBackend` resolve
their final default from that flag (beta identifiers under `#if BETA_RELEASE`, dev otherwise). This removes
all reliance on env rows / persisted state for an archive and is verifiable independently of an attached
run. This is **not** the deferred P1-G0 consolidation — it is the single release-blocking default.

## 8. Regression tests (offline)
- `apps/ios/Story/StoryTests/CognitoSelfSignUpTests.swift` (new, 14 cases): new-user signup, existing-user
  fallthrough, ConfirmSignUp→session sign-in, no-session fallback, existing OTP verify, wrong/expired code,
  throttling, resend routing (confirm vs initiate), disabled account, unknown-email `noOTPPath`, network
  failure — via a target-routing URLProtocol stub (network-free).
- `apps/ios/Story/StoryTests/AuthGatingTests.swift`: replaced the obsolete invite-only enumeration test with
  a unified-copy non-enumeration test; existing AU-defer / AuthGate tests unchanged.
- Backend auth tests unchanged and green.
- **iOS tests compile only on a device `Cmd-U`** (no CI iOS job; sandbox cannot build the SwiftData macro).
  `swiftc -parse` ran clean on the edited sources but is NOT a build gate.

## 9. Device acceptance plan (owner runs on dev scheme)
- **A. Existing account** — sign in; prior Stories/Moments/GeneratedOutputs/AU/music preserved.
- **B. New account** — a genuinely new email registers, gets a real code, confirms, reaches YoTale with no
  admin provisioning.
- **C. Interrupted registration** — kill the app between SignUp and code entry; relaunch; complete/recover
  (account exists in Cognito → resolves as existing-user OTP; no duplicate).
- **D. Reinstall** — sign in again with the same email; cloud-owned data re-associates with the same
  `story_user_id`.
- **E. Beta archive config** — archived build points at beta resources without Run-scheme vars (BLOCKED
  until §7 fix lands).

## 10. Cleanup status
- Invite-only user-facing copy removed (SignInView, error strings). ✅
- `scripts/yotale_beta_invite.sh` retained as **legacy/administrative** tooling (recovery/provisioning), not
  deleted — public signup does not remove admin recovery. Marked as legacy in this doc.
- `scripts/.yotale_beta_allowlist` is a **script-only ledger, not a runtime gate** (no backend code reads
  it). Documented here; no runtime consumer to remove.
- No new invitation-management service introduced.

## 11. Remaining TestFlight setup (App Store Connect — owner actions)
See the audit section of the prior allowlist report; summarized: create internal + external tester groups,
upload a beta-distributable build, complete external Beta App Review, configure a public invitation link with
an initial tester limit, and record how to disable the link / stop testing. **A TestFlight invitation does
NOT authenticate a user to the YoTale backend** — Cognito EMAIL_OTP sign-up/sign-in is the only backend auth.

## 12. Remaining owner approvals
1. Approve the §7 minimal Beta-build-configuration fix (required before any beta archive).
2. Re-verify the live **beta** Cognito pool prerequisites (needs a fresh `yotale-beta` SSO session).
3. Run the device acceptance matrix (A–E).
4. Authorize PR merge / beta deploy / TestFlight submission (all currently STOPPED per the task).
