#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

fail_test() {
  echo "$1" >&2
  exit 1
}

assert_contains_file() {
  local file="$1"
  local expected="$2"
  grep -F "$expected" "$file" >/dev/null || fail_test "Expected $file to contain: $expected"
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

home_dir="$tmpdir/home"
SDCLI_PROFILE_DIR="$tmpdir/selected-profile"
preference_dir="$SDCLI_PROFILE_DIR/system26.2.0.186.2220/o.sqldeveloper"
preference_file="$preference_dir/product-preferences.xml"
mkdir -p "$preference_dir"

HOME="$home_dir" SQLDEVELOPER_FILE_OUTPUT_OPTION=1 configure_sqldeveloper_file_output_option
[[ -f "$preference_file" ]] || fail_test "Missing preferences were not installed from the controlled template"
assert_contains_file "$preference_file" '<!-- sdcli-autokit FileOutputOption v1 begin -->'
assert_contains_file "$preference_file" '<value n="FileOutputOption" v="1"/>'

# SQL Developer may add unrelated preferences after the controlled template is
# installed. Updating the managed value must preserve those additions.
sed '/<\/ide:preferences>/i\
   <hash n="DBConfig"/>' "$preference_file" > "$preference_file.with-dbconfig"
mv "$preference_file.with-dbconfig" "$preference_file"
sed -E 's/^[[:space:]]+(<!-- sdcli-autokit FileOutputOption v1 (begin|end) -->)$/ \1/' \
  "$preference_file" > "$preference_file.reindented"
mv "$preference_file.reindented" "$preference_file"
HOME="$home_dir" SQLDEVELOPER_FILE_OUTPUT_OPTION=3 configure_sqldeveloper_file_output_option
assert_contains_file "$preference_file" '<value n="FileOutputOption" v="3"/>'
assert_contains_file "$preference_file" '<hash n="DBConfig"/>'

before_repeat="$(cksum "$preference_file")"
HOME="$home_dir" SQLDEVELOPER_FILE_OUTPUT_OPTION=3 configure_sqldeveloper_file_output_option
after_repeat="$(cksum "$preference_file")"
[[ "$before_repeat" == "$after_repeat" ]] || fail_test "Repeated preference installation was not idempotent"

# The vendor removes XML comments when saving our bootstrapped preferences.
# The project lifecycle marker still establishes ownership; do not tell the
# operator to delete a working preference file and its encryption metadata.
sed '/<!-- sdcli-autokit FileOutputOption v1 /d' "$preference_file" > "$preference_file.saved"
mv "$preference_file.saved" "$preference_file"
printf 'test-identity\tready\n' > "$SDCLI_PROFILE_DIR/.autokit-profile"
vendor_before="$(cksum "$preference_file")"
vendor_output="$(SQLDEVELOPER_FILE_OUTPUT_OPTION=3 configure_sqldeveloper_file_output_option 2>&1)"
[[ "$vendor_before" == "$(cksum "$preference_file")" ]] || fail_test 'Vendor-saved preferences were rewritten'
[[ "$vendor_output" != *'[WARN]'* ]] || fail_test 'Vendor-saved project preferences were incorrectly treated as unmanaged'

unknown_home="$tmpdir/unknown-home"
unknown_dir="$unknown_home/.sqldeveloper/system26.2.0.186.2220/o.sqldeveloper"
unknown_file="$unknown_dir/product-preferences.xml"
mkdir -p "$unknown_dir"
cat > "$unknown_file" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<ide:preferences xmlns:ide="http://xmlns.oracle.com/ide/hash">
  <hash n="unrecognized-layout">
    <value n="FileOutputOption" v="9"/>
  </hash>
</ide:preferences>
XML
unknown_before="$(cksum "$unknown_file")"
unknown_output="$(SDCLI_PROFILE_DIR="$unknown_home/.sqldeveloper" HOME="$unknown_home" SQLDEVELOPER_FILE_OUTPUT_OPTION=2 configure_sqldeveloper_file_output_option 2>&1)"
unknown_after="$(cksum "$unknown_file")"
[[ "$unknown_before" == "$unknown_after" ]] || fail_test "Unknown existing preferences were modified"
[[ "$unknown_output" == *"not managed by sdcli-autokit; left unchanged"* ]] \
  || fail_test "Unknown preference layout did not produce an actionable warning"

upgrade_home="$tmpdir/upgrade-home"
managed_old_dir="$upgrade_home/.sqldeveloper/system25/o.sqldeveloper"
unknown_new_dir="$upgrade_home/.sqldeveloper/system26/o.sqldeveloper"
mkdir -p "$managed_old_dir" "$unknown_new_dir"
cp "$preference_file" "$managed_old_dir/product-preferences.xml"
cp "$unknown_file" "$unknown_new_dir/product-preferences.xml"
managed_old_before="$(cksum "$managed_old_dir/product-preferences.xml")"
unknown_new_before="$(cksum "$unknown_new_dir/product-preferences.xml")"
upgrade_output="$(SDCLI_PROFILE_DIR="$upgrade_home/.sqldeveloper" HOME="$upgrade_home" SQLDEVELOPER_FILE_OUTPUT_OPTION=4 configure_sqldeveloper_file_output_option 2>&1)"
[[ "$managed_old_before" == "$(cksum "$managed_old_dir/product-preferences.xml")" ]] \
  || fail_test "An ambiguous older managed preferences file was modified"
[[ "$unknown_new_before" == "$(cksum "$unknown_new_dir/product-preferences.xml")" ]] \
  || fail_test "An ambiguous newer unknown preferences file was modified"
[[ "$upgrade_output" == *"multiple SQL Developer product-preferences.xml files"* \
    && "$upgrade_output" == *"left unchanged"* ]] \
  || fail_test "Multiple versioned preferences did not produce an actionable ambiguity warning"

ambiguous_home="$tmpdir/ambiguous-home"
mkdir -p \
  "$ambiguous_home/.sqldeveloper/system25/o.sqldeveloper" \
  "$ambiguous_home/.sqldeveloper/system26/o.sqldeveloper"
ambiguous_output="$(SDCLI_PROFILE_DIR="$ambiguous_home/.sqldeveloper" HOME="$ambiguous_home" configure_sqldeveloper_file_output_option 2>&1)"
[[ "$ambiguous_output" == *"multiple SQL Developer preference directories"* ]] \
  || fail_test "Ambiguous missing preference target did not produce an actionable warning"
[[ ! -e "$ambiguous_home/.sqldeveloper/system25/o.sqldeveloper/product-preferences.xml" ]]
[[ ! -e "$ambiguous_home/.sqldeveloper/system26/o.sqldeveloper/product-preferences.xml" ]]

echo "migration preferences test passed"
