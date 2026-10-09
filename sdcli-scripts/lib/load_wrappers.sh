_sdcli_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

sqlplus() {
  bash "$_sdcli_lib_dir/sqlplus" "$@"
}

sqlldr() {
  bash "$_sdcli_lib_dir/sqlldr" "$@"
}
