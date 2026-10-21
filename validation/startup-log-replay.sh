#!/usr/bin/env bash
set -Eeuo pipefail

# Run from a clean checkout of the candidate head. The base source is used only
# for the temporary comparison build and is restored before the script exits.

BASE_SHA="${BASE_SHA:-9f8e6c4eb82b782c63954e087908c7a2ba45e226}"
HEAD_SHA="${HEAD_SHA:-$(git rev-parse HEAD)}"
NODE_FILE="crates/agglayer-node/src/node.rs"
SECRET_URL="ws://127.0.0.1:1/repro-token"
REPO_ROOT="$(git rev-parse --show-toplevel)"
ARTIFACT_DIR="${REPLAY_ARTIFACT_DIR:-}"

die() {
    printf 'startup replay: %s\n' "$*" >&2
    exit 1
}

cd "$REPO_ROOT"

[[ -z "$(git status --porcelain)" ]] || die "the checkout must be clean"
command -v jq >/dev/null 2>&1 || die "jq is required to parse JSON tracing output"
git cat-file -e "${BASE_SHA}^{commit}" || die "base commit is unavailable: ${BASE_SHA}"
git cat-file -e "${HEAD_SHA}^{commit}" || die "head commit is unavailable: ${HEAD_SHA}"
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "$HEAD_SHA")" ]] || die "HEAD does not match HEAD_SHA"

changed_files="$(git diff --name-only "$BASE_SHA" "$HEAD_SHA")"
[[ "$changed_files" == "$NODE_FILE" ]] || die "the base/head comparison is broader than ${NODE_FILE}"

replay_dir="$(mktemp -d "${TMPDIR:-/tmp}/agglayer-startup-replay.XXXXXX")"
node_backup="$replay_dir/node.rs.head"
cp "$NODE_FILE" "$node_backup"

restore_head_source() {
    cp "$node_backup" "$NODE_FILE"
}

cleanup() {
    local status=$?

    # Keep only the fake-endpoint replay evidence when the caller requests an
    # artifact directory. The raw logs are useful for review; the message
    # projections make the JSON assertion independently inspectable.
    set +e
    if [[ -n "$ARTIFACT_DIR" ]]; then
        mkdir -p "$ARTIFACT_DIR"
        for label in base head; do
            for artifact in run.log messages.txt; do
                if [[ -f "$replay_dir/$label/case/$artifact" ]]; then
                    cp "$replay_dir/$label/case/$artifact" \
                        "$ARTIFACT_DIR/${label}.${artifact}"
                fi
            done
        done
    fi
    restore_head_source
    rm -rf "$replay_dir"
    exit "$status"
}
trap cleanup EXIT

git show "$BASE_SHA:$NODE_FILE" > "$replay_dir/node.rs.base"
git show "$HEAD_SHA:$NODE_FILE" > "$replay_dir/node.rs.head.expected"
grep -Fq 'Starting BlockClock with provider:' "$replay_dir/node.rs.base" \
    || die "base source does not contain the URL-bearing startup record"
grep -Fq 'info!("Starting BlockClock");' "$replay_dir/node.rs.head.expected" \
    || die "head source does not contain the fixed startup record"
if grep -Fq 'Starting BlockClock with provider:' "$replay_dir/node.rs.head.expected"; then
    die "head source still contains the URL-bearing startup record"
fi

target_dir="${CARGO_TARGET_DIR:-$REPO_ROOT/target}"
[[ "$target_dir" = /* ]] || target_dir="$REPO_ROOT/$target_dir"
export CARGO_TARGET_DIR="$target_dir"

build_binary() {
    local label="$1"
    mkdir -p "$replay_dir/$label"
    # The default cached proof ELF is sufficient; never trigger a proof rebuild
    # or update a checked-in artifact for this startup-only replay.
    env -u AGGLAYER_ELF_BUILD CARGO_INCREMENTAL="${CARGO_INCREMENTAL:-0}" \
        cargo build --locked --release --bin agglayer
    cp "$CARGO_TARGET_DIR/release/agglayer" "$replay_dir/$label/agglayer"
}

cp "$replay_dir/node.rs.base" "$NODE_FILE"
build_binary base
restore_head_source
cmp -s "$NODE_FILE" "$node_backup" || die "failed to restore candidate source"
build_binary head

make_config() {
    local label="$1"
    local binary="$replay_dir/$label/agglayer"
    local case_dir="$replay_dir/$label/case"
    local generated="$case_dir/generated.toml"
    local config="$case_dir/agglayer.toml"

    mkdir -p "$case_dir"
    (cd "$case_dir" && "$binary" config --base-dir "$case_dir") > "$generated"
    sed \
        -e "s|^ws-node-url = .*|ws-node-url = \"$SECRET_URL\"|" \
        -e 's|^prometheus-addr = .*|prometheus-addr = "127.0.0.1:0"|' \
        -e 's|^format = .*|format = "json"|' \
        -e 's|^outputs = .*|outputs = ["stdout"]|' \
        "$generated" > "$config"
    grep -Fq "ws-node-url = \"$SECRET_URL\"" "$config" \
        || die "failed to install the replay WebSocket URL in $label config"
    grep -Fq 'prometheus-addr = "127.0.0.1:0"' "$config" \
        || die "failed to isolate telemetry in $label config"
    grep -Fq 'format = "json"' "$config" \
        || die "failed to select JSON logging in $label config"
    grep -Fq 'outputs = ["stdout"]' "$config" \
        || die "failed to select stdout logging in $label config"
    printf '%s\n' "$config"
}

parse_json_messages() {
    local log="$1"
    local messages="$2"

    # tracing-subscriber JSON keeps event fields under .fields by default.
    # fromjson? deliberately ignores the binary's non-JSON stderr diagnostics
    # while retaining every valid tracing record for the assertions below.
    jq -Rr 'fromjson? | select(type == "object") | (.fields.message // .message // empty)' \
        "$log" > "$messages"

    local records
    records="$(jq -Rr 'fromjson? | select(type == "object") | 1' "$log" \
        | awk '{count += $1} END {print count + 0}')"
    [[ "$records" -gt 0 ]] || die "${log} contains no JSON tracing records"
}

run_case() {
    local label="$1"
    local binary="$replay_dir/$label/agglayer"
    local config
    local case_dir="$replay_dir/$label/case"
    local log="$case_dir/run.log"
    local messages="$case_dir/messages.txt"
    local status=0

    config="$(make_config "$label")"
    timeout 15s env RUST_LOG=info "$binary" run --cfg "$config" > "$log" 2>&1 || status=$?

    [[ "$status" -ne 124 ]] || die "$label startup did not fail within the 15-second bound"
    [[ "$status" -ne 137 ]] || die "$label startup was killed by the timeout"
    [[ "$status" -ne 0 ]] || die "$label startup unexpectedly reached a running state"
    parse_json_messages "$log" "$messages"
    printf '%s\n' "$log"
}

base_log="$(run_case base)"
head_log="$(run_case head)"

base_messages="$replay_dir/base/case/messages.txt"
head_messages="$replay_dir/head/case/messages.txt"
base_expected="Starting BlockClock with provider: $SECRET_URL"

base_startup_count="$(awk -v expected="$base_expected" '$0 == expected {count++} END {print count + 0}' \
    "$base_messages")"
[[ "$base_startup_count" -eq 1 ]] \
    || die "base runtime did not reproduce exactly one URL-bearing startup record"

head_startup_count="$(awk '$0 == "Starting BlockClock" {count++} END {print count + 0}' \
    "$head_messages")"
[[ "$head_startup_count" -eq 1 ]] \
    || die "head runtime did not emit exactly one fixed startup record"

head_url_message_count="$(awk -v url="$SECRET_URL" 'index($0, url) {count++} END {print count + 0}' \
    "$head_messages")"
[[ "$head_url_message_count" -eq 0 ]] \
    || die "head JSON tracing messages contain the replay endpoint"

if grep -Fq "$SECRET_URL" "$head_log"; then
    die "head runtime emitted the replay endpoint outside the startup record"
fi

head_start_line="$(awk '$0 == "Starting BlockClock" {print NR; exit}' "$head_messages")"
head_failure_line="$(awk '/^Failed to connect to L1 WebSocket/ || /^Failed to start BlockClock:/ {print NR; exit}' \
    "$head_messages")"
[[ -n "$head_failure_line" ]] || die "head runtime did not report the refused WebSocket connection"
[[ "$head_start_line" -lt "$head_failure_line" ]] \
    || die "head startup record was not emitted before the connection failure"

printf 'startup replay passed: base reproduces the URL-bearing record; head preserves the lifecycle record without the endpoint.\n'
