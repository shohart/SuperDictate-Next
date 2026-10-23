#!/bin/bash
# scripts/verify-release.sh — mandatory functional check of the macOS
# release ARTIFACT before `gh release create` (docs/RELEASING.md).
#
# usage: scripts/verify-release.sh <SuperDictate.zip>
#
# Self-tests run from the build tree. mac-v0.8.4 passed all of them and
# still shipped an LLM host that crashed on every GPU start: its Vulkan
# shaders were never in the bundle, and the build tree they were found in
# (a temporary worktree) was deleted after the build. So this script tests
# the zip itself, unpacked into a fresh directory, through the shipped
# binaries only:
#   1. bundle: signature, bundle id, version, designated requirement equal
#      to the installed app's (TCC permissions survive the update), helpers,
#      the LLM Vulkan shader corpus;
#   2. the LLM host from the bundle loads its shaders from the bundle, not
#      from any build tree;
#   3. correction on the GPU and the CPU, rewrite on the GPU, through the
#      real coordinator (`SuperDictate --diagnose-llm`);
#   4. speech recognition (Parakeet, and GigaAM if downloaded) on a `say`
#      recording (`SuperDictate --benchmark-transcribe`).
# Never touches /Applications or the LaunchAgent. Any failure exits non-zero.
# No `set -e`: a checker must run every check and report each failure.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIP="${1:-}"
[[ -f "$ZIP" ]] || { echo "usage: $0 <SuperDictate.zip>" >&2; exit 2; }

failures=0
pass() { printf '  PASS %s\n' "$*"; }
failed() { printf '  FAIL %s\n' "$*"; failures=$((failures + 1)); }
step() { printf '\n== %s\n' "$*"; }
# No coreutils `timeout` on stock macOS; a hung check must not hang the release.
with_timeout() { local seconds=$1; shift; perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/superdictate-verify.XXXXXX")"
HOST_PID=""
cleanup() {
    [[ -n "$HOST_PID" ]] && kill -9 "$HOST_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT
ditto -x -k "$ZIP" "$WORK/unpacked" || { echo "cannot unpack $ZIP" >&2; exit 1; }
[[ -d "$WORK/unpacked/SuperDictate.app" ]] || { echo "no SuperDictate.app in $ZIP" >&2; exit 1; }
# Physical path: the host reports its shader directory resolved (/var is
# /private/var on macOS).
APP="$(cd "$WORK/unpacked/SuperDictate.app" && pwd -P)"
BIN="$APP/Contents/MacOS/SuperDictate"
LLM_HOST="$APP/Contents/Helpers/SuperDictateLLMHost"
MODELS="$HOME/Library/Application Support/SuperDictate/Models/LLM"

step "1. Bundle"
codesign --verify --deep --strict "$APP" && pass "signature verifies" || failed "signature"
[[ "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" == "com.local.superdictate" ]] \
    && pass "bundle id" || failed "bundle id"
want="$(plutil -extract CFBundleShortVersionString raw "$ROOT_DIR/swift/Info.plist")"
got="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
[[ "$got" == "$want" ]] && pass "version $got" || failed "version $got, swift/Info.plist says $want"
if [[ -d /Applications/SuperDictate.app ]]; then
    dr() { codesign -d -r- "$1" 2>&1 | grep '^designated'; }
    [[ "$(dr "$APP")" == "$(dr /Applications/SuperDictate.app)" ]] \
        && pass "designated requirement equals the installed app's" \
        || failed "designated requirement differs from the installed app's (permissions would reset)"
fi
for helper in SuperDictateLLMHost SuperDictateOnnxHost; do
    [[ -x "$APP/Contents/Helpers/$helper" ]] && pass "helper $helper" || failed "helper $helper missing"
done
shader_count="$(find "$APP/Contents/Resources/llama-vulkan-shaders" -name '*.spv' 2>/dev/null | wc -l | tr -d ' ')"
[[ -f "$APP/Contents/Resources/llama-vulkan-shaders/matmul_f32_f32.spv" ]] \
    && pass "LLM Vulkan shaders in the bundle ($shader_count .spv)" \
    || failed "LLM Vulkan shaders missing from the bundle"

step "2. LLM host loads its shaders from the bundle"
if "$LLM_HOST" --list-devices 2>/dev/null | grep -q '^DEVICE'; then
    port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
    "$LLM_HOST" --model "$MODELS/Qwen_Qwen3.5-0.8B-Q6_K.gguf" --host 127.0.0.1 --port "$port" \
        --gpu-layers 999 --ctx-size 4096 > "$WORK/host.log" 2>&1 &
    HOST_PID=$!
    for _ in $(seq 1 240); do
        kill -0 "$HOST_PID" 2>/dev/null || break
        curl -s --noproxy '*' -m 1 "http://127.0.0.1:$port/health" | grep -q ok && break
        sleep 0.25
    done
    if kill -0 "$HOST_PID" 2>/dev/null; then
        pass "GPU host started"
        kill -9 "$HOST_PID" 2>/dev/null || true
    else
        failed "GPU host died while starting: $(tail -1 "$WORK/host.log")"
    fi
    HOST_PID=""
    grep -q "vulkan shaders: $APP/Contents/" "$WORK/host.log" \
        && pass "shader directory is inside the bundle" \
        || failed "shader directory is not inside the bundle: $(grep 'vulkan shaders' "$WORK/host.log" || echo none)"
    ! grep -q "failed to load SPIR-V" "$WORK/host.log" \
        && pass "no missing shaders" || failed "missing shaders: $(grep -m1 'failed to load SPIR-V' "$WORK/host.log")"
    gpu_modes="gpu cpu"
else
    echo "  (no Vulkan GPU on this Mac: the GPU checks are skipped)"
    gpu_modes="cpu"
fi

step "3. Correction and rewrite through the shipped coordinator"
# An argument the binary does not know falls through to the normal app
# start, which can rewrite the production LaunchAgent (AGENTS.md). Never
# run a bundle older than --diagnose-llm with it.
if ! grep -q -- "--diagnose-llm" "$BIN"; then
    failed "this build has no --diagnose-llm: correction, rewrite and ASR were not checked"
    gpu_modes=""
    asr_checks=0
else
    asr_checks=1
fi
for mode in $gpu_modes; do
    if with_timeout 600 "$BIN" --diagnose-llm correction "$mode" "я развернул дебиан сервер и залил изменения на гитхаб" \
        > "$WORK/llm.out" 2>&1; then
        pass "correction on $mode: $(grep '^LLM_DIAG ' "$WORK/llm.out" | sed 's/^LLM_DIAG //')"
    else
        failed "correction on $mode: $(grep 'LLM_DIAG' "$WORK/llm.out" | tr '\n' ' ')"
    fi
done
rewrite_mode="${gpu_modes%% *}"
if [[ -n "$rewrite_mode" ]] && with_timeout 900 "$BIN" --diagnose-llm rewrite "$rewrite_mode" "ну короче скажи клиенту что договор мы подпишем не раньше пятницы" \
    > "$WORK/llm.out" 2>&1; then
    pass "rewrite on $rewrite_mode: $(grep '^LLM_DIAG ' "$WORK/llm.out" | sed 's/^LLM_DIAG //')"
elif [[ -n "$rewrite_mode" ]]; then
    failed "rewrite on $rewrite_mode: $(grep 'LLM_DIAG' "$WORK/llm.out" | tr '\n' ' ')"
fi

step "4. Speech recognition"
say -v Milena -r 145 "Открой докер и залей изменения на гитхаб." -o "$WORK/speech.aiff" \
    && afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/speech.aiff" "$WORK/speech.wav" \
    || failed "cannot synthesize the test recording"
asr_models="onnx"
(( asr_checks )) || asr_models=""
[[ -n "$asr_models" && -d "$HOME/Library/Application Support/SuperDictate/onnx/gigaam-v3-e2e-rnnt-int8" ]] && asr_models="onnx gigaam"
for asr in $asr_models; do
    if with_timeout 600 "$BIN" --benchmark-transcribe "$asr" cpu 4 "$WORK/speech.wav" > "$WORK/asr.out" 2>&1 \
        && text="$(grep '^BENCH_RESULT' "$WORK/asr.out" | sed 's/.* text=//')" \
        && grep -qi "изменения" <<< "$text"; then
        pass "ASR $asr: $text"
    else
        failed "ASR $asr: $(grep -E 'BENCH_RESULT|BENCH_FAILED' "$WORK/asr.out" | tail -1)"
    fi
done

echo
if (( failures > 0 )); then
    echo "verify-release: $failures check(s) FAILED -- do not publish this build"
    exit 1
fi
echo "verify-release: all checks passed"
