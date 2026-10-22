#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
fail_test() { printf '%s\n' "$*" >&2; exit 1; }
get_required_value() {
  [[ "$1" == '.migration_repository.repo_user.user' ]] || fail_test "unexpected config lookup: $1"
  printf 'migrep\n'
}
TOOL_DATA="$tmpdir/data"
PROJECT_ROOT="$TOOL_DATA/projects"
DRY_RUN=false
mkdir -p "$tmpdir/bin" "$tmpdir/gate" "$tmpdir/wallet-a" "$tmpdir/wallet-b"
for wallet in "$tmpdir/wallet-a" "$tmpdir/wallet-b"; do
  touch "$wallet/tnsnames.ora" "$wallet/sqlnet.ora" "$wallet/cwallet.sso"
done
cat > "$tmpdir/bin/sdcli" <<'SDK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$IDE_USER_DIR" "${TNS_ADMIN-}" "${JAVA_TOOL_OPTIONS-}" "${JDK_JAVA_OPTIONS-}" "${_JAVA_OPTIONS-}" > "$PROFILE_CAPTURE"
touch "$PROFILE_GATE/$PROFILE_LABEL"
for attempt in {1..60}; do
  [[ -f "$PROFILE_GATE/a" && -f "$PROFILE_GATE/b" ]] && break
  sleep 0.05
done
[[ -f "$PROFILE_GATE/a" && -f "$PROFILE_GATE/b" ]] || exit 19
printf 'driver completed successfully\n'
SDK
chmod +x "$tmpdir/bin/sdcli"
export PATH="$tmpdir/bin:$PATH" PROFILE_GATE="$tmpdir/gate"
context() {
  ACTIVE_MIGRATION_NAME="$1"
  ACTIVE_REPOSITORY_NAME="migration_repo_$1"
  ACTIVE_SUPER_CONNECTION_NAME="super_migration_$1"
  ACTIVE_REPOSITORY_CONN="host-$1:1521/service"
  ACTIVE_WALLET_DIR="$tmpdir/wallet-$1"
  ACTIVE_WALLET_CONFIG_PATH="migrations.$1.target.wallet_dir"
  MODE=init
}
job() {
  local label="$1"
  trap 'release_profile_lock' EXIT
  context "$label"
  RUN_LOG_FILE="$tmpdir/$label.log"
  touch "$RUN_LOG_FILE"
  JAVA_TOOL_OPTIONS='-Xmx256m -Dkeep="a b" -Doracle.net.tns_admin=/stale -Doracle.net.tns_admin="/old path"'
  JDK_JAVA_OPTIONS='-Dkeep2=yes -Doracle.net.tns_admin=/stale2'
  _JAVA_OPTIONS='"-Doracle.net.tns_admin=/stale3" -Dkeep3="value -Doracle.net.tns_admin=/literal"'
  configure_active_oracle_wallet
  prepare_project_profile
  export PROFILE_LABEL="$label" PROFILE_CAPTURE="$tmpdir/$label.env"
  run_sdcli sdcli migration -actions=driver
  mark_project_profile_ready
}
(job a) &
pid_a=$!
(job b) &
pid_b=$!
wait "$pid_a"
wait "$pid_b"
for label in a b; do
  [[ "$(sed -n '1p' "$tmpdir/$label.env")" == "$TOOL_DATA/profiles/$label" ]] || fail_test 'wrong child profile'
  [[ "$(sed -n '2p' "$tmpdir/$label.env")" == "$tmpdir/wallet-$label" ]] || fail_test 'wallet crossed projects'
  [[ "$(sed -n '3p' "$tmpdir/$label.env")" == *'-Dkeep="a b"'* ]] || fail_test 'unrelated quoted Java option lost'
  [[ "$(sed -n '3p' "$tmpdir/$label.env")" == *"-Doracle.net.tns_admin=$tmpdir/wallet-$label"* ]] || fail_test 'selected JVM wallet missing'
  ! grep -Eq 'stale|old path' "$tmpdir/$label.env" || fail_test 'inherited wallet survived'
  [[ "$(sed -n '4p' "$tmpdir/$label.env")" == '-Dkeep2=yes' ]] || fail_test 'JDK options changed'
  [[ "$(sed -n '5p' "$tmpdir/$label.env")" == '-Dkeep3="value -Doracle.net.tns_admin=/literal"' ]] || fail_test 'quoted JVM token was not removed or an unrelated quoted value was changed'
done
context a
MODE=conn-setup
prepare_project_profile
if (trap - EXIT; PROFILE_LOCK_HELD=false; prepare_project_profile) >/dev/null 2>&1; then
  fail_test 'same profile accepted concurrent writer'
fi
release_profile_lock
context a
prepare_project_profile
[[ "$(awk -F '\t' '{print $2}' "$SDCLI_PROFILE_DIR/.autokit-profile")" == pending ]] || fail_test 'reinitialization left an old ready state active'
release_profile_lock
ACTIVE_REPOSITORY_CONN='changed-host:1521/other'
if (trap 'release_profile_lock' EXIT; prepare_project_profile) >/dev/null 2>&1; then
  fail_test 'changed target reused the existing profile'
fi
context pending
MODE=init
prepare_project_profile
release_profile_lock
MODE=conn-setup
if (trap 'release_profile_lock' EXIT; prepare_project_profile) >/dev/null 2>&1; then
  fail_test 'pending initialization entered connection setup'
fi
context clean
ACTIVE_WALLET_DIR=''
JAVA_TOOL_OPTIONS='-Xmx128m -Doracle.net.tns_admin=/stale'
TNS_ADMIN=/stale
configure_active_oracle_wallet
[[ -z "${TNS_ADMIN:-}" && "$JAVA_TOOL_OPTIONS" == '-Xmx128m' ]] || fail_test 'non-wallet project inherited a wallet'
DRY_RUN=true
prepare_project_profile
[[ ! -e "$TOOL_DATA/profiles/clean" ]] || fail_test 'dry run created profile state'
printf 'project profile test passed\n'
