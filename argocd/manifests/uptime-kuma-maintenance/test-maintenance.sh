#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
tmp_dir=$(mktemp -d)

cleanup() {
    rm -rf "$tmp_dir"
}

trap cleanup EXIT HUP INT TERM

create_fixture() {
    fixture_data_dir=$1

    mkdir -p "$fixture_data_dir"
    sqlite3 "$fixture_data_dir/kuma.db" <<'SQL' >/dev/null
CREATE TABLE setting (
  id INTEGER PRIMARY KEY,
  key VARCHAR(200) NOT NULL,
  value TEXT,
  type VARCHAR(20)
);
CREATE TABLE monitor (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL
);
CREATE TABLE heartbeat (
  id INTEGER PRIMARY KEY,
  monitor_id INTEGER NOT NULL REFERENCES monitor(id) ON DELETE CASCADE,
  time DATETIME NOT NULL,
  msg TEXT
);
INSERT INTO setting(key, value, type) VALUES ('keepDataPeriodDays', '180', 'general');
INSERT INTO monitor(id, name) VALUES (1, 'kept-monitor');
INSERT INTO heartbeat(monitor_id, time, msg) VALUES
  (1, datetime('now', '-31 days'), 'delete-me'),
  (1, datetime('now', '-29 days'), 'keep-me');
PRAGMA journal_mode=WAL;
SQL
}

data_dir="$tmp_dir/data"
work_dir="$tmp_dir/work"
create_fixture "$data_dir"
mkdir -p "$work_dir"

DATA_DIR="$data_dir" WORK_DIR="$work_dir" SAFETY_BYTES=0 sh "$script_dir/maintenance.sh"

test "$(sqlite3 "$data_dir/kuma.db" "SELECT value FROM setting WHERE key='keepDataPeriodDays';")" = "30"
test "$(sqlite3 "$data_dir/kuma.db" "SELECT count(*) FROM heartbeat WHERE msg='delete-me';")" = "0"
test "$(sqlite3 "$data_dir/kuma.db" "SELECT count(*) FROM heartbeat WHERE msg='keep-me';")" = "1"
test "$(sqlite3 "$data_dir/kuma.db" "SELECT count(*) FROM monitor;")" = "1"
test "$(sqlite3 "$data_dir/kuma.db" "PRAGMA integrity_check;")" = "ok"
test -f "$data_dir/.maintenance/retention-30d-20260808.done"
printf '%s\n' "successful purge test"

checksum_before_second=$(cksum "$data_dir/kuma.db")
DATA_DIR="$data_dir" WORK_DIR="$work_dir" SAFETY_BYTES=0 sh "$script_dir/maintenance.sh"
test "$(cksum "$data_dir/kuma.db")" = "$checksum_before_second"
printf '%s\n' "idempotency test"

low_data_dir="$tmp_dir/low-data"
low_work_dir="$tmp_dir/low-work"
create_fixture "$low_data_dir"
mkdir -p "$low_work_dir"
checksum_before_low_space=$(cksum "$low_data_dir/kuma.db")
available_bytes=$(df -Pk "$low_data_dir" | awk 'NR == 2 { print $4 * 1024 }')
safety_bytes=$((available_bytes + 1))

set +e
DATA_DIR="$low_data_dir" WORK_DIR="$low_work_dir" SAFETY_BYTES="$safety_bytes" sh "$script_dir/maintenance.sh"
low_space_exit=$?
set -e

test "$low_space_exit" -ne 0
test "$(cksum "$low_data_dir/kuma.db")" = "$checksum_before_low_space"
test ! -e "$low_data_dir/.maintenance/retention-30d-20260808.done"
printf '%s\n' "low-space abort test"

DATA_DIR="$low_data_dir" WORK_DIR="$low_work_dir" SAFETY_BYTES=0 sh "$script_dir/maintenance.sh"
test -f "$low_data_dir/.maintenance/retention-30d-20260808.done"
printf '%s\n' "workspace recovery test"

failure_data_dir="$tmp_dir/failure-data"
failure_work_dir="$tmp_dir/failure-work"
failure_bin_dir="$tmp_dir/failure-bin"
create_fixture "$failure_data_dir"
mkdir -p "$failure_work_dir" "$failure_bin_dir"
failure_checksum_before=$(cksum "$failure_data_dir/kuma.db")
real_sqlite3=$(command -v sqlite3)
{
    printf '%s\n' '#!/bin/sh'
    # shellcheck disable=SC2016
    printf '%s\n' 'if [ "$1" = "$FAILING_DB" ] && [ "$2" = "PRAGMA integrity_check;" ] && [ -f "$FAIL_ARM_FILE" ]; then'
    printf '%s\n' '    exit 1'
    printf '%s\n' 'fi'
    # shellcheck disable=SC2016
    printf '%s\n' 'exec "$REAL_SQLITE3" "$@"'
} > "$failure_bin_dir/sqlite3"
chmod +x "$failure_bin_dir/sqlite3"
touch "$tmp_dir/fail-final-validation"

set +e
DATA_DIR="$failure_data_dir" WORK_DIR="$failure_work_dir" SAFETY_BYTES=0 \
    PATH="$failure_bin_dir:$PATH" REAL_SQLITE3="$real_sqlite3" \
    FAILING_DB="$failure_data_dir/kuma.db" FAIL_ARM_FILE="$tmp_dir/fail-final-validation" \
    sh "$script_dir/maintenance.sh"
final_validation_exit=$?
set -e

test "$final_validation_exit" -ne 0
test "$(cksum "$failure_data_dir/kuma.db")" = "$failure_checksum_before"
test "$(sqlite3 "$failure_data_dir/kuma.db" "SELECT value FROM setting WHERE key='keepDataPeriodDays';")" = "180"
test "$(sqlite3 "$failure_data_dir/kuma.db" "SELECT count(*) FROM heartbeat WHERE msg='delete-me';")" = "1"
test ! -e "$failure_data_dir/kuma.db.new"
test ! -e "$failure_data_dir/kuma.db.pre-retention-30d-20260808"
test ! -e "$failure_data_dir/.maintenance/retention-30d-20260808.done"
printf '%s\n' "post-swap rollback test"

interrupted_data_dir="$tmp_dir/interrupted-data"
interrupted_work_dir="$tmp_dir/interrupted-work"
create_fixture "$interrupted_data_dir"
mkdir -p "$interrupted_work_dir"
mv "$interrupted_data_dir/kuma.db" "$interrupted_data_dir/kuma.db.pre-retention-30d-20260808"

DATA_DIR="$interrupted_data_dir" WORK_DIR="$interrupted_work_dir" SAFETY_BYTES=0 sh "$script_dir/maintenance.sh"
test "$(sqlite3 "$interrupted_data_dir/kuma.db" "SELECT value FROM setting WHERE key='keepDataPeriodDays';")" = "30"
test ! -e "$interrupted_data_dir/kuma.db.pre-retention-30d-20260808"
test -f "$interrupted_data_dir/.maintenance/retention-30d-20260808.done"
printf '%s\n' "interrupted replacement recovery test"

dual_data_dir="$tmp_dir/dual-data"
dual_work_dir="$tmp_dir/dual-work"
create_fixture "$dual_data_dir"
mkdir -p "$dual_work_dir"
cp "$dual_data_dir/kuma.db" "$dual_data_dir/kuma.db.pre-retention-30d-20260808"
printf '%s\n' "not a SQLite database" > "$dual_data_dir/kuma.db"

DATA_DIR="$dual_data_dir" WORK_DIR="$dual_work_dir" SAFETY_BYTES=0 sh "$script_dir/maintenance.sh"
test "$(sqlite3 "$dual_data_dir/kuma.db" "SELECT value FROM setting WHERE key='keepDataPeriodDays';")" = "30"
test ! -e "$dual_data_dir/kuma.db.pre-retention-30d-20260808"
test -f "$dual_data_dir/.maintenance/retention-30d-20260808.done"
printf '%s\n' "dual-database interruption recovery test"
