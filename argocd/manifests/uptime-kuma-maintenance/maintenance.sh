#!/bin/sh
set -eu

data_dir=${DATA_DIR:-/data}
work_dir=${WORK_DIR:-/work}
retention_days=${RETENTION_DAYS:-30}
safety_bytes=${SAFETY_BYTES:-16777216}
maintenance_id=${MAINTENANCE_ID:-retention-30d-20260808}
db="$data_dir/kuma.db"
marker_dir="$data_dir/.maintenance"
marker="$marker_dir/$maintenance_id.done"
source_copy="$work_dir/source.db"
compact_db="$work_dir/compact.db"
new_db="$data_dir/kuma.db.new"
rollback_db="$data_dir/kuma.db.pre-$maintenance_id"

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command unavailable: $1"
}

is_decimal() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

file_size() {
    if stat -c %s "$1" >/dev/null 2>&1; then
        stat -c %s "$1"
    else
        stat -f %z "$1"
    fi
}

validate_database() {
    validate_db=$1

    test "$(sqlite3 "$validate_db" "PRAGMA integrity_check;")" = "ok" || fail "integrity check failed: $validate_db"
    test "$(sqlite3 "$validate_db" "SELECT value FROM setting WHERE key='keepDataPeriodDays';")" = "30" || fail "retention setting validation failed: $validate_db"
    test "$(sqlite3 "$validate_db" "SELECT count(*) FROM heartbeat WHERE time < '$cutoff_utc';")" = "0" || fail "old heartbeat validation failed: $validate_db"
    test "$(sqlite3 "$validate_db" "SELECT count(*) FROM monitor;")" = "$monitor_count_before" || fail "monitor count validation failed: $validate_db"
}

case "$retention_days" in
    '' | *[!0-9]*) fail "RETENTION_DAYS must contain only digits" ;;
esac
test "$retention_days" = "30" || fail "RETENTION_DAYS must equal 30 for this operation"

is_decimal "$safety_bytes" || fail "SAFETY_BYTES must contain only digits"
case "$maintenance_id" in
    '' | */* | *..*) fail "MAINTENANCE_ID contains an unsafe path component" ;;
esac

test ! -e "$marker" || exit 0

for required_command in sqlite3 df stat cp mv sync; do
    require_command "$required_command"
done

if [ -e "$rollback_db" ]; then
    rm -f "$db" "$db-shm" "$db-wal"
    mv "$rollback_db" "$db"
fi

test -f "$db" || fail "database not found: $db"
test -d "$work_dir" || fail "workspace not found: $work_dir"
test ! -e "$rollback_db" || fail "rollback database already exists: $rollback_db"
rm -f "$source_copy" "$compact_db"

monitor_count_before=$(sqlite3 "$db" "SELECT count(*) FROM monitor;")
is_decimal "$monitor_count_before" || fail "could not record monitor count"
printf '%s\n' "$monitor_count_before" > "$work_dir/monitor-count.before"
cutoff_utc=$(sqlite3 "$db" "SELECT datetime('now', '-30 days');")
test -n "$cutoff_utc" || fail "could not record retention cutoff"
printf '%s\n' "$cutoff_utc" > "$work_dir/cutoff.utc"

checkpoint_result=$(sqlite3 "$db" "PRAGMA wal_checkpoint(TRUNCATE);")
case "$checkpoint_result" in
    0\|*\|*) ;;
    *) fail "WAL checkpoint did not complete: $checkpoint_result" ;;
esac

sqlite3 "$db" ".backup '$source_copy'"

setting_count=$(sqlite3 "$source_copy" "SELECT count(*) FROM setting WHERE key='keepDataPeriodDays';")
test "$setting_count" = "1" || fail "expected exactly one keepDataPeriodDays setting"
heartbeat_count_before=$(sqlite3 "$source_copy" "SELECT count(*) FROM heartbeat;")
is_decimal "$heartbeat_count_before" || fail "could not record heartbeat count"

sqlite3 "$source_copy" <<SQL
BEGIN IMMEDIATE;
UPDATE setting
SET value = '30'
WHERE key = 'keepDataPeriodDays';
DELETE FROM heartbeat
WHERE time < '$cutoff_utc';
COMMIT;
SQL

sqlite3 "$source_copy" "VACUUM;"
mv "$source_copy" "$compact_db"

validate_database "$compact_db"
rm -f "$new_db" "$new_db-wal" "$new_db-shm"
heartbeat_count_after=$(sqlite3 "$compact_db" "SELECT count(*) FROM heartbeat;")
is_decimal "$heartbeat_count_after" || fail "could not record post-cleanup heartbeat count"
removed_heartbeat_count=$((heartbeat_count_before - heartbeat_count_after))

compact_size=$(file_size "$compact_db")
available_bytes=$(df -Pk "$data_dir" | awk 'NR == 2 { print $4 * 1024 }')
is_decimal "$compact_size" || fail "could not determine compact database size"
is_decimal "$available_bytes" || fail "could not determine available PVC space"
test $((compact_size + safety_bytes)) -le "$available_bytes" || fail "insufficient PVC space for safe replacement"

on_exit() {
    exit_status=$1

    if [ "$exit_status" -ne 0 ]; then
        rm -f "$new_db" "$new_db-wal" "$new_db-shm" || :
        if [ -e "$rollback_db" ]; then
            if [ -e "$db" ]; then
                rm -f "$db" "$db-shm" "$db-wal" || :
            fi
            if [ ! -e "$db" ]; then
                mv "$rollback_db" "$db" || :
            fi
        fi
    fi

    return 0
}

trap 'on_exit $?' EXIT
trap 'exit 1' HUP INT TERM

mv "$db" "$rollback_db"
cp "$compact_db" "$new_db"
sync
validate_database "$new_db"
mv "$new_db" "$db"
sync
validate_database "$db"
rm -f "$rollback_db" "$db-shm" "$db-wal" "$new_db-wal" "$new_db-shm"

mkdir -p "$marker_dir"
marker_tmp="$marker_dir/.${maintenance_id}.done.$$"
completion_utc=$(sqlite3 "$db" "SELECT datetime('now');")
{
    printf 'maintenance_id=%s\n' "$maintenance_id"
    printf 'retention_days=%s\n' "$retention_days"
    printf 'heartbeat_rows_before=%s\n' "$heartbeat_count_before"
    printf 'heartbeat_rows_after=%s\n' "$heartbeat_count_after"
    printf 'heartbeat_rows_removed=%s\n' "$removed_heartbeat_count"
    printf 'compact_size_bytes=%s\n' "$compact_size"
    printf 'completed_utc=%s\n' "$completion_utc"
} > "$marker_tmp"
mv "$marker_tmp" "$marker"

trap - EXIT HUP INT TERM
