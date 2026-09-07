#!/usr/bin/env bash
# Exercise direct connection routing without SSH connections or filesystem mounts.
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
cp -R "$repo_dir/network/ssh-manager" "$test_dir/manager"
export SSH_MANAGER_TEST_DIR="$test_dir"

# Override only side effects; retain the real parser, lookup and action dispatcher.
cat > "$test_dir/manager/ssh-manager/zz-test.sh" <<'EOF'
CONFIG_DIR="$SSH_MANAGER_TEST_DIR"
CONFIG_FILE="$CONFIG_DIR/config.json"
init_config() { :; }
clear() { :; }
pause_for_key() { :; }
log_message() { :; }
record_server_usage() { :; }
check_sshfs_mc() { return 0; }
execute_sshfs_mc() {
    echo "SSHFS:$1"
    return "${TEST_STATUS:-0}"
}
ssh() { echo "SSH:$*"; }
fzf() { cat >/dev/null; printf '1\tProduction Backup\n'; }
EOF

cat > "$test_dir/config.json" <<'EOF'
{"servers":[
  {"name":"Production Server","host":"prod.example.com","user":"deploy","port":2222},
  {"name":"Production Backup","host":"backup.example.com","user":"deploy"},
  {"name":"list","host":"list.example.com","user":"deploy"}
]}
EOF

manager="$test_dir/manager/ssh-manager.sh"
assert_output() {
    local expected="$1" output
    shift
    output=$(bash "$manager" "$@")
    if [[ "$output" != *"$expected"* ]]; then
        printf 'Expected %s, got: %s\n' "$expected" "$output" >&2
        exit 1
    fi
}

assert_output 'SSHFS:0' sshfs 'Production Server'
assert_output 'SSHFS:0' sshfs 'tion ser'
assert_output 'SSHFS:1' sshfs Production
assert_output 'SSHFS:2' sshfs list
assert_output 'SSH:-p 2222 -t deploy@prod.example.com' 'Production Server'
assert_output 'SSH:-p 22 -t deploy@backup.example.com' Production
assert_output 'sshfs CONNECTION-NAME' --help
assert_output 'Production Server' list

for args in missing extra; do
    if [[ "$args" == missing ]]; then
        command_args=(sshfs)
    else
        command_args=(sshfs 'Production Server' extra)
    fi
    if bash "$manager" "${command_args[@]}" >"$test_dir/output" 2>&1; then
        echo 'Invalid arguments unexpectedly succeeded' >&2
        exit 1
    fi
done

status=0
TEST_STATUS=7 bash "$manager" sshfs 'Production Server' >"$test_dir/output" 2>&1 || status=$?
[[ "$status" -eq 7 ]] || { echo "Lost SSHFS exit status: $status" >&2; exit 1; }
echo 'ssh-manager direct connections: PASS'
