# YoTale — TestFlight Email Self-Sign-up / Sign-in (Option A)

**Status: IMPLEMENTED on branch `feat/testflight-email-self-signup` — OFFLINE-TESTED — BETA COGNITO/SES LIVE-CONFIG-VERIFIED — BETA BUILD-CONFIG + ARCHIVE SCHEME TRACKED (reproducible from clean checkout) — BETA ARCHIVE INFO.PLIST VERIFIED (baked beta, validator passed) — NOT DEVICE-TESTED (sandbox cannot run the Swift macro plugin; owner Xcode required) — NOT MERGED — NOT DEPLOYED — NOT LIVE-SIGNUP-VERIFIED.**

Status vocabulary (per owner request): *Implemented* = code written. *Offline-tested* = unit tests pass
(sandbox cannot build the SwiftData target). *Device-tested* = owner Xcode `Cmd-U` / device run. *Beta
archive-verified* = `verify_beta_archive.sh` passed against a real Beta archive. *Live beta signup-verified*
= a real external email registered and signed in against beta. Only the first two are claimed here.

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

**No pool-plan, SES, or infrastructure change is required** for the mechanism.

### 3a. Beta environment — LIVE CONFIGURATION VERIFIED (2026-10-27, account `224033508028`)
Inspected the actual live beta resources (not inferred from CDK). **LIVE CONFIGURATION VERIFIED** — this does
NOT assert live signup, OTP delivery, or a successful login, which remain a separate device acceptance gate.

Beta Cognito (pool `us-east-1_3cPNfbrUl`, client `4f3dtn9d0nk5uq1hcvbdc7m73c`):
- Self-signup allowed (`AllowAdminCreateUserOnly=false`). ✅
- Tier **ESSENTIALS**. ✅
- Email as username (`UsernameAttributes=[email]`, no alias). ✅
- Email auto-verification (`AutoVerifiedAttributes=[email]`). ✅
- `EMAIL_OTP` present in `AllowedFirstAuthFactors=[PASSWORD, EMAIL_OTP]`. ✅
- App-client flows `[ALLOW_USER_AUTH, ALLOW_REFRESH_TOKEN_AUTH]`. ✅
- `PreventUserExistenceErrors=ENABLED`. ✅
- No app-client secret (public PKCE). ✅

Beta SES (us-east-1, account `224033508028`):
- Production sending access enabled (`ProductionAccessEnabled=true`). ✅ (previously sandbox — testers no
  longer need a pre-verified recipient identity.)
- Sending enabled (`SendingEnabled=true`). ✅
- 24-hour sending quota reported **50,000**. ✅

**No new Cognito or SES infrastructure change is currently required** for beta.

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

## 7. Beta build configuration — IMPLEMENTED (code gate + xcconfig + archive validator)
A TestFlight **archive** previously resolved to **dev** defaults: `StoryLaunchConfig` read `env → persisted →
dev default`, and an archive has no scheme env vars and a tester's install has no persisted values. Fixed
without a remote config service and without P1-G0.

### 7a. Single resolved environment object
`apps/ios/Story/Story/Data/Auth/StoryEnvironment.swift` is now THE source of truth. `StoryAuthConfig.*` and
`StoryBackend.baseURL` read `StoryEnvironment.current` (one object, not independently-mutable keys), so no
caller can assemble a half-dev/half-beta mix.

### 7b. Resolution rules
- **DEBUG build:** unchanged developer flexibility — `scheme env → persisted UserDefaults → dev default`
  (via the existing `StoryLaunchConfig` chain). Attached dev runs and scheme toggles behave exactly as before.
- **RELEASE / Archive / TestFlight build (`#if !DEBUG`):** the environment is read **only** from values
  **baked into `Info.plist`** at build time (`StoryBuildEnv` + `StoryEnv*` keys, populated via
  `$(STORY_BUILD_ENV)` / `$(STORY_ENV_*)` substitution from the selected xcconfig). **`ProcessInfo.environment`
  and persisted `UserDefaults` are IGNORED.** So a stale dev override on a tester's device can never redirect
  a beta build.

### 7c. Runtime-override isolation (§5 — the core safety property)
In a release build: beta config comes only from the baked values; a persisted dev `STORY_API_BASE_URL` or
dev Cognito values from a prior dev install **cannot** override it; no Xcode Run env values are needed; and —
fail-closed — if `StoryBuildEnv=beta` but any required value is **missing**, an unresolved `$(...)` token, or
**mismatched** (beta API with dev pool, or vice-versa), the app **`fatalError`s at launch** rather than
silently selecting development. A release build labelled `development` (local/simulator release) is allowed
and resolves dev; it can never masquerade as beta (the consistency guard rejects a dev-labelled build that
carries non-dev Cognito). No unrelated UserDefaults or app data is touched — signed-in user data and local
SwiftData models are preserved.

### 7d. Build-time wiring (xcconfig — values baked, not code)
- `apps/ios/Story/Config/Development.xcconfig` → `STORY_BUILD_ENV=development` + dev identifiers.
- `apps/ios/Story/Config/Beta.xcconfig` → `STORY_BUILD_ENV=beta` + the **live-verified** beta identifiers.
- `Story/Info.plist` carries `$(STORY_*)` substitution keys (same pattern as the existing `GitCommitSHA`).

### 7e. Tracked project integration — DONE (reproducible from a clean checkout)
The Beta build configuration and archive scheme are now COMMITTED, so a clean checkout archives beta without
any local Xcode state:
- `project.pbxproj`: a **Beta** build configuration on the project + all three targets; the app target's
  Debug/Release use `Config/Development.xcconfig` and **Beta** uses `Config/Beta.xcconfig`
  (`baseConfigurationReference`). Purely additive — the owner's uncommitted `DEVELOPMENT_TEAM` signing lines
  were stashed during the edit and restored, never staged.
- `xcshareddata/xcschemes/Story (Beta).xcscheme`: shared scheme whose **Archive** (and Launch/Profile/Analyze)
  action uses the **Beta** configuration, with **no EnvironmentVariables block** — the beta backend is baked,
  not injected by Run-scheme rows.
- `xcodebuild -list` shows configurations Debug/Release/**Beta** and schemes Story + **Story (Beta)**.

### 7f. Resolved build settings + real archive — VERIFIED
- `xcodebuild -showBuildSettings -scheme "Story (Beta)" -configuration Beta` resolves: `STORY_BUILD_ENV=beta`,
  API `https://asxtxgjiis.us-east-1.awsapprunner.com`, pool `us-east-1_3cPNfbrUl`, client
  `4f3dtn9d0nk5uq1hcvbdc7m73c`, domain `story-beta-auth`, redirect `story://auth`, region `us-east-1`.
  **Debug** resolves the dev identifiers. (Confirmed in the resolved config, not just the xcconfig — §4.)
- A real `xcodebuild archive` was run with the Story (Beta) scheme. Its `ProcessInfoPlistFile` step produced
  the app `Info.plist` with every `$(STORY_*)` substitution resolved to the beta values, and
  `scripts/verify_beta_archive.sh` passed against that **archive-produced** Info.plist (no dev identifiers, no
  unresolved tokens). **xcconfig `//` truncation bug found and fixed** (a `//` starts an xcconfig comment) by
  assembling URLs via a `SLASH` helper.
- The archive's Swift **compile could not complete in the agent sandbox**: the Swift macro plugin
  (`@Observable` / SwiftData `@Model`) fails here with "external macro implementation ... could not be found /
  swift-plugin-server produced malformed response" — and the SAME failure hits the untouched existing
  `Story`/Debug build (198 occurrences), so it is the known sandbox macro limitation, NOT a defect in this
  change or the Beta config. A full compiled+signed archive requires the owner's Xcode (where macros run).

### 7g. Pre-archive validator (fail-closed)
`scripts/verify_beta_archive.sh <Story.app|Info.plist|.xcarchive app>` inspects the BUILT app's baked
`Info.plist` and exits non-zero unless `StoryBuildEnv=beta` with all beta identifiers present, no unresolved
tokens, and **no dev identifier leaked**. Passed against the real archive Info.plist; a synthetic
beta-label-with-dev-pool plist fails as expected. The runtime `StoryEnvironment` fail-closed check remains as
defense in depth.

## 8. Regression tests (offline)
- `apps/ios/Story/StoryTests/CognitoSelfSignUpTests.swift` (new, 14 cases): new-user signup, existing-user
  fallthrough, ConfirmSignUp→session sign-in, no-session fallback, existing OTP verify, wrong/expired code,
  throttling, resend routing (confirm vs initiate), disabled account, unknown-email `noOTPPath`, network
  failure — via a target-routing URLProtocol stub (network-free).
- `apps/ios/Story/StoryTests/StoryEnvironmentTests.swift` (new, 5 cases): dev default is consistent;
  beta-label-with-dev-pool rejected; beta-label-with-dev-API rejected; fully-beta consistent;
  `StoryEnvironment.current` is internally consistent. (The release-only fatalError paths cannot run in a
  unit process; they are covered by `verify_beta_archive.sh` + device step E.)
- `apps/ios/Story/StoryTests/AuthGatingTests.swift`: replaced the obsolete invite-only enumeration test with
  a unified-copy non-enumeration test; existing AU-defer / AuthGate tests unchanged.
- `scripts/verify_beta_archive.sh` smoke-tested (beta plist passes; dev-leak plist fails).
- Backend auth tests unchanged and green (45).
- **iOS tests compile only on a device `Cmd-U`** (no CI iOS job; sandbox cannot build the SwiftData macro).
  `swiftc -parse` ran clean on the edited sources but is NOT a build gate.

## 9. Device acceptance plan (owner runs)
- **A. Existing account** (dev scheme) — sign in; prior Stories/Moments/GeneratedOutputs/AU/music preserved.
- **B. New account** (dev scheme) — a genuinely new email registers, gets a real code, confirms, reaches
  YoTale with no admin provisioning.
- **C. Interrupted registration** — kill the app between SignUp and code entry; relaunch; complete/recover
  (account exists in Cognito → resolves as existing-user OTP; no duplicate).
- **D. Reinstall** — sign in again with the same email; cloud-owned data re-associates with the same
  `story_user_id`.
- **E. Beta build** — after wiring the Beta configuration (§7e), install a **Beta-configured** build and
  confirm `STORY_ACTIVE_BACKEND` logs the beta pool/API **without any attached Xcode scheme**, and
  `verify_beta_archive.sh` passes on the archive. Do NOT create a live beta test user until separately
  authorized.

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

## 12. Remaining owner approvals / actions
1. **Wire the Beta build configuration in Xcode** (§7e) — duplicate Release → Beta, point configs at the
   xcconfigs, add a Story (Beta) archive scheme. (Not hand-edited in the pbxproj to avoid clobbering the
   uncommitted `DEVELOPMENT_TEAM` signing lines.)
2. Run the device acceptance matrix **A–E** (owner device `Cmd-U` / installs).
3. Run `scripts/verify_beta_archive.sh` against the first Beta archive (must print OK).
4. Authorize PR #71 merge / beta deploy / live beta signup / TestFlight submission (all currently STOPPED).

Beta Cognito/SES prerequisites are **LIVE CONFIGURATION VERIFIED** (§3a) — no infra change required.
