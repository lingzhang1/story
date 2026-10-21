#!/usr/bin/env bash
# YoTale invite-only beta provisioning (Option D).
#
# Idempotently provisions a CONFIRMED, EMAIL_OTP-compatible Cognito user and verifies the SES
# email identity so native USER_AUTH / EMAIL_OTP sign-in works for the invited address — with NO
# SignUp, NO password login, and NO custom Lambda triggers.
#
# ADMIN-ONLY. This calls Cognito admin APIs with the operator's own AWS credentials. It is NOT a
# server endpoint and MUST NEVER be exposed through a public/unauthenticated route — provisioning
# happens out-of-band by an operator running this script.
#
# Beta eligibility is maintained SEPARATELY from Cognito account existence: the eligibility ledger is
# a plain allowlist file (scripts/.yotale_beta_allowlist), the source of truth for "who is invited".
# A Cognito account is only the login mechanism. Revoking an invite removes eligibility AND disables
# (optionally deletes) the Cognito user, so a revoked tester cannot sign in even though SES stays verified.
#
# Usage:
#   scripts/yotale_beta_invite.sh invite  <email>     # provision (idempotent) + record eligibility
#   scripts/yotale_beta_invite.sh revoke  <email>     # remove eligibility + disable the Cognito user
#   scripts/yotale_beta_invite.sh status  <email>     # show eligibility + Cognito user status
#   scripts/yotale_beta_invite.sh list                # list the eligibility allowlist
#
# Env overrides (defaults are the YoTale dev pool):
#   POOL_ID   (default us-east-1_AzfHOEdA5)
#   REGION    (default us-east-1)
set -euo pipefail

POOL_ID="${POOL_ID:-us-east-1_AzfHOEdA5}"
REGION="${REGION:-us-east-1}"
ALLOWLIST="$(cd "$(dirname "$0")" && pwd)/.yotale_beta_allowlist"
touch "$ALLOWLIST"

# Normalize an email the same way the iOS client does (lowercase + trim).
norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | awk '{$1=$1;print}'; }

cognito_status() {
  aws cognito-idp admin-get-user --user-pool-id "$POOL_ID" --region "$REGION" \
    --username "$1" --query UserStatus --output text 2>/dev/null || echo "ABSENT"
}

invite() {
  local email; email="$(norm "$1")"
  # 1) SES: ensure the address identity exists (sandbox requires a verified recipient). Idempotent —
  #    re-creating an existing identity is a no-op that simply re-sends the verification if unverified.
  aws sesv2 create-email-identity --region "$REGION" --email-identity "$email" >/dev/null 2>&1 || true

  # 2) Cognito: create a CONFIRMED user with a verified email. email_verified=true + no password =>
  #    status CONFIRMED and EMAIL_OTP-compatible immediately (no FORCE_CHANGE_PASSWORD, no invite email).
  #    SUPPRESS stops the default Cognito invitation message. Idempotent: an existing user is handled.
  local st; st="$(cognito_status "$email")"
  if [ "$st" = "ABSENT" ]; then
    aws cognito-idp admin-create-user --user-pool-id "$POOL_ID" --region "$REGION" \
      --username "$email" \
      --user-attributes Name=email,Value="$email" Name=email_verified,Value=true \
      --message-action SUPPRESS >/dev/null
    echo "created CONFIRMED user: $email"
  else
    # Existing user: make sure it is enabled and email is marked verified (handles a prior revoke/disable).
    aws cognito-idp admin-enable-user --user-pool-id "$POOL_ID" --region "$REGION" --username "$email" >/dev/null 2>&1 || true
    aws cognito-idp admin-update-user-attributes --user-pool-id "$POOL_ID" --region "$REGION" \
      --username "$email" --user-attributes Name=email_verified,Value=true >/dev/null 2>&1 || true
    echo "existing user re-affirmed (status=$st): $email"
  fi

  # 3) Eligibility ledger (source of truth), kept separate from Cognito. Idempotent add.
  if ! grep -qxF "$email" "$ALLOWLIST"; then echo "$email" >> "$ALLOWLIST"; fi
  echo "invited (eligible): $email"
}

revoke() {
  local email; email="$(norm "$1")"
  # Remove eligibility first (source of truth), then disable the Cognito login so sign-in stops.
  grep -vxF "$email" "$ALLOWLIST" > "$ALLOWLIST.tmp" 2>/dev/null || true
  mv "$ALLOWLIST.tmp" "$ALLOWLIST" 2>/dev/null || true
  aws cognito-idp admin-disable-user --user-pool-id "$POOL_ID" --region "$REGION" --username "$email" >/dev/null 2>&1 \
    && echo "disabled Cognito user: $email" || echo "no Cognito user to disable: $email"
  echo "revoked (ineligible): $email"
}

status() {
  local email; email="$(norm "$1")"
  local elig="no"; grep -qxF "$email" "$ALLOWLIST" && elig="yes"
  echo "email:       $email"
  echo "eligible:    $elig"
  echo "cognito:     $(cognito_status "$email")"
}

case "${1:-}" in
  invite) [ -n "${2:-}" ] || { echo "usage: $0 invite <email>" >&2; exit 2; }; invite "$2" ;;
  revoke) [ -n "${2:-}" ] || { echo "usage: $0 revoke <email>" >&2; exit 2; }; revoke "$2" ;;
  status) [ -n "${2:-}" ] || { echo "usage: $0 status <email>" >&2; exit 2; }; status "$2" ;;
  list)   echo "beta allowlist ($ALLOWLIST):"; cat "$ALLOWLIST" ;;
  *) echo "usage: $0 {invite|revoke|status <email> | list}" >&2; exit 2 ;;
esac
