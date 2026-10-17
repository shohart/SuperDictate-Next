#!/bin/bash
#
# scripts/benchmark-asr.sh — benchmark of the app's speech engine
# (Parakeet via ONNX Runtime, CPU only) on the current hardware, measuring
# raw speech recognition WITHOUT any LLM correction: speed (cold load,
# warm-up, first-inference, warm latency, RTF, peak RSS) and quality (WER,
# CER, punctuation F1 vs the reference text that was actually spoken into
# the synthetic corpus).
#
# Requires macOS (uses `say`/`afconvert` for corpus synthesis and
# `/usr/bin/time -l` for peak RSS) and a packaged bundle carrying the
# SuperDictateOnnxHost helper (dist/SuperDictate-test.app, then
# dist/SuperDictate.app).
#
# It drives the REAL, permanent `--benchmark-transcribe` diagnostic entry
# point in swift/Sources/Parakey/main.swift, which itself calls the real
# production code (downloadOnnxModelIfNeeded, OnnxAsrEngine) — never a
# mock backend.
#
# Usage:
#   scripts/benchmark-asr.sh [--binary PATH] [--corpus-dir DIR]
#                             [--out DIR] [--repeats N] [--threads N]
#                             [--run-timeout SECONDS]   (per process, default 600)
#
# Notes:
#   - Every clip goes through the app's own dictation path
#     (TranscriptionWorker + transcribeSegmented: PauseSegmenter's <= 25 s
#     segments, overlap windows, seam dedup), never one whole-file engine
#     call. The long monologue clip (>= 60 s nominal) is transcribed once
#     (accuracy only); shorter clips get --repeats (1 cold + N-1 warm).
#   - The whisper and GGUF parakeet backends and the vulkan device were
#     removed (2026-10-17 comparison, spec §12); the app rejects them.
#   - The model is downloaded on first use if it is missing.
#
# Safety: this script never touches /Applications/SuperDictate.app or its
# LaunchAgent. It only invokes a locally built binary with
# --benchmark-transcribe, which (see main.swift) is checked and dispatched
# BEFORE NSApplication is constructed, so it can never fall through to
# normal app startup even in a release build.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BINARY=""
CORPUS_DIR="${TMPDIR:-/tmp}/superdictate-benchmark-corpus"
OUT_DIR="$ROOT_DIR/dist/benchmark-asr-$(date +%Y%m%d-%H%M%S)"
REPEATS=3    # first call = "first inference (cold)"; remaining N-1 = warm pool
DEVICES="cpu"
BACKENDS="onnx"
THREADS=8
RUN_TIMEOUT_SECONDS=600

log_msg() { printf 'benchmark-asr: %s\n' "$*"; }
fail() { printf 'benchmark-asr: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary) BINARY="$2"; shift 2 ;;
        --corpus-dir) CORPUS_DIR="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --repeats) REPEATS="$2"; shift 2 ;;
        --threads) THREADS="$2"; shift 2 ;;
        --run-timeout) RUN_TIMEOUT_SECONDS="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^#//'
            exit 0
            ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS is required (uses 'say'/'afconvert')."

if [[ -z "$BINARY" ]]; then
    if [[ -x "$ROOT_DIR/dist/SuperDictate-test.app/Contents/MacOS/SuperDictate" ]]; then
        BINARY="$ROOT_DIR/dist/SuperDictate-test.app/Contents/MacOS/SuperDictate"
    elif [[ -x "$ROOT_DIR/dist/SuperDictate.app/Contents/MacOS/SuperDictate" ]]; then
        BINARY="$ROOT_DIR/dist/SuperDictate.app/Contents/MacOS/SuperDictate"
    else
        log_msg "No --binary given and no dist/SuperDictate.app found; building release via swift build..."
        swift build -c release --package-path "$ROOT_DIR/swift"
        BIN_DIR="$(swift build -c release --package-path "$ROOT_DIR/swift" --show-bin-path)"
        BINARY="$BIN_DIR/Parakey"
    fi
fi
[[ -x "$BINARY" ]] || fail "Binary not found or not executable: $BINARY"

mkdir -p "$CORPUS_DIR" "$OUT_DIR"

# ---------------------------------------------------------------------------
# 1. Corpus: reuse if present (deterministic file names below), else
#    synthesize with `say` + `afconvert`, matching the Phase 1 corpus
#    method (RU/EN/mixed, names, numbers, addresses, technical terms,
#    short commands, one long monologue) across four duration buckets
#    (~3s/10s/30s/120s nominal). The reference text IS the ground truth
#    for WER/CER/punctuation scoring.
# ---------------------------------------------------------------------------
declare -a CORPUS_SPECS=(
    "03s_ru_command|Milena|185|Открой браузер и найди погоду."
    "03s_en_command|Samantha|185|Open the browser and check the weather."
    "10s_ru_numbers|Milena|185|Мой номер телефона восемь девятьсот двенадцать триста сорок пять шестьдесят семь восемьдесят девять. Код доступа четыре два ноль ноль один."
    "10s_en_technical|Samantha|185|The GGUF model is loaded once through the C bridge, quantized to Q eight zero, and runs inference through GGML Vulkan on the AMD Radeon GPU."
    "10s_mixed_ru_en|Milena|185|Давай откроем приложение Super Dictate и проверим настройки Vulkan и GPU acceleration для инференса."
    "30s_ru_paragraph|Milena|185|Сегодня прекрасная погода для прогулки по городу. Утром прошел небольшой дождь, но сейчас небо чистое и светит солнце. Мы планируем встретиться с друзьями в кафе на главной площади, обсудить рабочие вопросы и составить план на следующую неделю. После обеда нужно заехать в магазин за продуктами и забрать посылку с почты."
    "30s_en_paragraph|Samantha|185|This morning started with a light rain, but the sky cleared up by noon and the sun came out. We are planning to meet our colleagues at the downtown office to review the quarterly report and discuss the roadmap for the next release. After lunch there is a scheduled call with the engineering team."
    "120s_ru_monologue|Milena|185|Добрый день, уважаемые коллеги! Сегодня я хочу рассказать о развитии нашего проекта за последний квартал. Мы значительно улучшили производительность системы распознавания речи, снизили задержку обработки запросов почти вдвое и повысили точность распознавания русского языка, особенно в части имен собственных, географических названий и технических терминов. Отдельное внимание было уделено поддержке смешанной русско-английской речи, что особенно важно для команд, работающих в международной среде. Мы также провели серию нагрузочных тестов на реальном оборудовании, включая процессоры Intel Xeon и видеокарты AMD Radeon, чтобы убедиться в стабильности работы приложения при длительном использовании. Результаты тестирования показали, что система остается отзывчивой даже после ста последовательных запросов подряд, без утечек памяти и без деградации качества распознавания."
)

# bash 3.2 (macOS default) has no associative arrays, so keep the reference
# texts as "name|text" pairs and look them up via reference_for().
declare -a REFERENCE_PAIRS=()
CORPUS_FILES=()
for spec in "${CORPUS_SPECS[@]}"; do
    IFS='|' read -r name voice rate text <<< "$spec"
    REFERENCE_PAIRS+=("$name|$text")
    wav="$CORPUS_DIR/${name}.wav"
    if [[ ! -s "$wav" ]]; then
        aiff="$CORPUS_DIR/${name}.aiff"
        say -v "$voice" -r "$rate" -o "$aiff" "$text"
        afconvert -f WAVE -d I16@16000 -c 1 "$aiff" "$wav"
        rm -f "$aiff"
    fi
    CORPUS_FILES+=("$wav")
done
log_msg "Corpus ready: ${#CORPUS_FILES[@]} clips in $CORPUS_DIR (synthetic, macOS 'say' — no private recordings)."

# ---------------------------------------------------------------------------
# 2. Helpers
# ---------------------------------------------------------------------------

# Extract a "key=value" field from a BENCH_RESULT / BENCH_LOAD line.
field() {
    local line="$1" key="$2"
    # shellcheck disable=SC2001
    echo "$line" | sed -n "s/.*[[:space:]]${key}=\\([^[:space:]]*\\).*/\\1/p"
}

# Look up the reference text for a clip name from REFERENCE_PAIRS.
reference_for() {
    local name="$1" pair
    for pair in "${REFERENCE_PAIRS[@]}"; do
        if [[ "$pair" == "$name|"* ]]; then
            echo "${pair#*|}"
            return 0
        fi
    done
    return 1
}

median() {
    python3 -c "
import sys
vals = sorted(float(x) for x in sys.argv[1:])
n = len(vals)
if n == 0:
    print('nan')
elif n % 2 == 1:
    print(vals[n // 2])
else:
    print((vals[n // 2 - 1] + vals[n // 2]) / 2)
" "$@"
}

p95() {
    python3 -c "
import sys
vals = sorted(float(x) for x in sys.argv[1:])
n = len(vals)
if n == 0:
    print('nan')
else:
    idx = min(n - 1, int(round(0.95 * (n - 1))))
    print(vals[idx])
" "$@"
}

# WER / CER / punctuation-F1 of hypothesis vs reference. Prints three
# space-separated floats. WER/CER strip punctuation and case; the
# punctuation score is a position-insensitive multiset F1 over sentence
# punctuation (.,!?;:…—–) — a proxy for how faithfully the backend
# reproduces the punctuation that was actually spoken.
score_accuracy() {
    python3 - "$1" "$2" <<'PY'
import sys, re
from collections import Counter

ref, hyp = sys.argv[1], sys.argv[2]

def lev(a, b):
    if len(a) < len(b):
        a, b = b, a
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]

def words(s):
    return re.sub(r'[^\w\s]', '', s.lower(), flags=re.UNICODE).split()

def chars(s):
    return list(re.sub(r'[^\w]', '', s.lower(), flags=re.UNICODE))

rw, hw = words(ref), words(hyp)
wer = lev(rw, hw) / max(1, len(rw))
rc, hc = chars(ref), chars(hyp)
cer = lev(rc, hc) / max(1, len(rc))

PUNCT = set('.,!?;:…—–')
rp = Counter(ch for ch in ref if ch in PUNCT)
hp = Counter(ch for ch in hyp if ch in PUNCT)
inter = sum((rp & hp).values())
tp, pp = sum(rp.values()), sum(hp.values())
prec = inter / pp if pp else 0.0
rec = inter / tp if tp else 0.0
f1 = 2 * prec * rec / (prec + rec) if (prec + rec) else 0.0

print(f"{wer:.4f} {cer:.4f} {f1:.4f}")
PY
}

# ---------------------------------------------------------------------------
# 3. Run one (backend, device, clip) triple: one fresh process, cold load +
#    warm-up + repeats of the same clip. Captures peak RSS via
#    `/usr/bin/time -l` around the whole process (covers cold load + all
#    repeats, so it's a realistic session ceiling, not a per-call figure).
# ---------------------------------------------------------------------------
run_one() {
    local backend="$1" device="$2" clip_path="$3" clip_name log_file time_file
    clip_name="$(basename "$clip_path" .wav)"
    log_file="$OUT_DIR/${backend}_${device}_${clip_name}.log"
    time_file="$OUT_DIR/${backend}_${device}_${clip_name}.time"

    local repeats="$REPEATS"
    local dur_hint
    dur_hint="$(python3 -c "
import wave
with wave.open('$clip_path', 'rb') as w:
    print(w.getnframes() / w.getframerate())
")"
    # The 120s monologue is transcribed once (accuracy only) to keep the
    # CPU runs tractable; shorter clips get the full repeat pool.
    if python3 -c "exit(0 if float('$dur_hint') >= 60 else 1)"; then
        repeats=1
    fi

    local -a repeat_args=()
    local i
    for ((i = 0; i < repeats; i++)); do
        repeat_args+=("$clip_path")
    done

    # Per-run timeout (macOS has no coreutils `timeout`): a hung run is
    # killed, recorded as failed, and the sweep moves on.
    /usr/bin/time -l "$BINARY" --benchmark-transcribe "$backend" "$device" "$THREADS" "${repeat_args[@]}" \
        > "$log_file" 2> "$time_file" &
    local run_pid=$!
    # The timer must not hold this function's stdout: it runs inside $(...),
    # and an orphaned sleep would keep the pipe open for the full timeout.
    ( sleep "$RUN_TIMEOUT_SECONDS"; pkill -TERM -P "$run_pid" 2>/dev/null; kill -TERM "$run_pid" 2>/dev/null ) \
        > /dev/null 2>&1 < /dev/null &
    local timer_pid=$!
    local run_status=0
    wait "$run_pid" || run_status=$?
    pkill -P "$timer_pid" 2>/dev/null; kill "$timer_pid" 2>/dev/null; wait "$timer_pid" 2>/dev/null || true
    if [[ $run_status -eq 0 ]]; then
        echo "$log_file"
    else
        log_msg "  [$backend/$device/$clip_name] FAILED (see $log_file / $time_file) — see BENCH_FAILED line if present"
        cat "$time_file" >> "$log_file" 2>/dev/null || true
        echo "$log_file"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 4. Main sweep
# ---------------------------------------------------------------------------
REPORT="$OUT_DIR/report.md"
{
    echo "# ASR backend comparison: $BACKENDS"
    echo
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Binary: $BINARY"
    echo "Backends: $BACKENDS"
    echo "Devices: $DEVICES"
    echo "Threads: $THREADS"
    echo "Repeats per clip: $REPEATS (first = cold first-inference, rest = warm pool; monologue = 1)"
    echo "Path: the app's segmented dictation path (PauseSegmenter <= 25 s, overlap windows, seam dedup)."
    echo "Scoring: WER/CER (case-insensitive, punctuation-stripped) and punctuation F1 (multiset of .,!?;:…—–) vs the reference text spoken into the corpus."
    echo "No LLM correction applied."
    echo
} > "$REPORT"

# The three per-clip sections are collected in separate files and joined
# after the sweep, so each table stays contiguous.
ACCURACY_PART="$OUT_DIR/.accuracy.md"
LATENCY_PART="$OUT_DIR/.latency.md"
TRANSCRIPTS_PART="$OUT_DIR/.transcripts.md"

# Per-clip accuracy table (first transcript of each run).
{
    echo "## Accuracy (raw recognition, no correction)"
    echo
    echo "| Backend | Device | Clip | WER | CER | Punct F1 |"
    echo "|---|---|---|---:|---:|---:|"
} > "$ACCURACY_PART"

# Per-clip latency table.
{
    echo "## Latency"
    echo
    echo "| Backend | Device | Clip | Dur (s) | Cold load (s) | Warm-up (s) | First-infer (ms) | Warm median (ms) | Warm p95 (ms) | RTF (warm median) | Peak RSS, main process only (MB) |"
    echo "|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|"
} > "$LATENCY_PART"

# Transcripts (reference + hypothesis per backend/device/clip).
{
    echo "## Transcripts"
    echo
} > "$TRANSCRIPTS_PART"

for backend in $BACKENDS; do
    for device in $DEVICES; do
        log_msg "=== Backend: $backend / Device: $device ==="
        for clip_path in "${CORPUS_FILES[@]}"; do
            clip_name="$(basename "$clip_path" .wav)"
            log_msg "  Running $clip_name..."

            if ! log_file="$(run_one "$backend" "$device" "$clip_path")"; then
                {
                    echo "| $backend | $device | $clip_name | - | - | - |"
                } >> "$ACCURACY_PART"
                continue
            fi

            load_line="$(grep '^BENCH_LOAD' "$log_file" || true)"
            [[ -n "$load_line" ]] || { log_msg "    no BENCH_LOAD line, skipping"; continue; }
            load_s="$(field "$load_line" load_s)"
            warm_s="$(field "$load_line" warmup_s)"
            actual_device="$(field "$load_line" actual_device)"

            result_lines=()
            while IFS= read -r bench_line; do
                result_lines+=("$bench_line")
            done < <(grep '^BENCH_RESULT' "$log_file" || true)
            [[ ${#result_lines[@]} -gt 0 ]] || { log_msg "    no BENCH_RESULT lines, skipping"; continue; }

            duration_s="$(field "${result_lines[0]}" duration_s)"
            first_wall_s="$(field "${result_lines[0]}" wall_s)"
            first_ms="$(python3 -c "print(round(float('$first_wall_s')*1000, 1))")"

            warm_ms_list=()
            for ((i = 1; i < ${#result_lines[@]}; i++)); do
                w="$(field "${result_lines[$i]}" wall_s)"
                warm_ms_list+=("$(python3 -c "print(float('$w')*1000)")")
            done
            if [[ ${#warm_ms_list[@]} -gt 0 ]]; then
                warm_median_ms="$(median "${warm_ms_list[@]}")"
                warm_p95_ms="$(p95 "${warm_ms_list[@]}")"
            else
                warm_median_ms="$first_ms"
                warm_p95_ms="$first_ms"
            fi
            rtf="$(python3 -c "print(round((float('$warm_median_ms')/1000.0)/float('$duration_s'), 4)) if float('$duration_s') > 0 else print('nan')")"

            peak_rss_mb="-"
            if [[ -f "$OUT_DIR/${backend}_${device}_${clip_name}.time" ]]; then
                peak_rss_bytes="$(grep 'maximum resident set size' "$OUT_DIR/${backend}_${device}_${clip_name}.time" | awk '{print $1}')"
                if [[ -n "${peak_rss_bytes:-}" ]]; then
                    peak_rss_mb="$(python3 -c "print(round($peak_rss_bytes/1024/1024, 1))")"
                fi
            fi

            transcript="$(echo "${result_lines[0]}" | sed -n 's/.*text=//p')"
            reference="$(reference_for "$clip_name")"
            read -r wer cer pf1 <<< "$(score_accuracy "$reference" "$transcript")"

            {
                echo "| $backend | $device | $clip_name | $wer | $cer | $pf1 |"
            } >> "$ACCURACY_PART"
            {
                echo "| $backend | $device | $clip_name | $duration_s | $load_s | $warm_s | $first_ms | $warm_median_ms | $warm_p95_ms | $rtf | $peak_rss_mb |"
            } >> "$LATENCY_PART"
            {
                echo "### $backend / $device / $clip_name"
                echo
                echo "- **Reference:** $reference"
                echo "- **Transcript:** $transcript"
                echo
            } >> "$TRANSCRIPTS_PART"
        done
    done
done
{
    cat "$ACCURACY_PART"; echo
    cat "$LATENCY_PART"; echo
    cat "$TRANSCRIPTS_PART"
} >> "$REPORT"
rm -f "$ACCURACY_PART" "$LATENCY_PART" "$TRANSCRIPTS_PART"

# ---------------------------------------------------------------------------
# 5. Summary tables (aggregated per backend × device)
# ---------------------------------------------------------------------------
{
    echo "## Summary (means across clips)"
    echo
    echo "| Backend | Device | Mean WER | Mean CER | Mean Punct F1 | Mean first-infer (ms) | Mean warm median (ms) | Mean RTF | Mean cold load (s) |"
    echo "|---|---|---:|---:|---:|---:|---:|---:|---:|"
} >> "$REPORT"

for backend in $BACKENDS; do
    for device in $DEVICES; do
        wer_vals=(); cer_vals=(); pf1_vals=(); first_vals=(); warm_vals=(); rtf_vals=(); load_vals=()
        for clip_path in "${CORPUS_FILES[@]}"; do
            clip_name="$(basename "$clip_path" .wav)"
            log_file="$OUT_DIR/${backend}_${device}_${clip_name}.log"
            [[ -f "$log_file" ]] || continue
            load_line="$(grep '^BENCH_LOAD' "$log_file" || true)"
            [[ -n "$load_line" ]] || continue
            result_lines=()
            while IFS= read -r bench_line; do
                result_lines+=("$bench_line")
            done < <(grep '^BENCH_RESULT' "$log_file" || true)
            [[ ${#result_lines[@]} -gt 0 ]] || continue

            duration_s="$(field "${result_lines[0]}" duration_s)"
            transcript="$(echo "${result_lines[0]}" | sed -n 's/.*text=//p')"
            reference="$(reference_for "$clip_name")"
            read -r wer cer pf1 <<< "$(score_accuracy "$reference" "$transcript")"
            wer_vals+=("$wer"); cer_vals+=("$cer"); pf1_vals+=("$pf1")

            first_wall_s="$(field "${result_lines[0]}" wall_s)"
            first_vals+=("$(python3 -c "print(float('$first_wall_s')*1000)")")

            warm_ms_list=()
            for ((i = 1; i < ${#result_lines[@]}; i++)); do
                w="$(field "${result_lines[$i]}" wall_s)"
                warm_ms_list+=("$(python3 -c "print(float('$w')*1000)")")
            done
            if [[ ${#warm_ms_list[@]} -gt 0 ]]; then
                warm_vals+=("$(median "${warm_ms_list[@]}")")
                clip_warm_median="$(median "${warm_ms_list[@]}")"
            else
                warm_vals+=("$(python3 -c "print(float('$first_wall_s')*1000)")")
                clip_warm_median="$(python3 -c "print(float('$first_wall_s')*1000)")"
            fi
            rtf="$(python3 -c "print(round((float('$clip_warm_median')/1000.0)/float('$duration_s'), 4)) if float('$duration_s') > 0 else print('nan')")"
            rtf_vals+=("$rtf")
            load_vals+=("$(field "$load_line" load_s)")
        done

        if [[ ${#wer_vals[@]} -eq 0 ]]; then
            {
                echo "| $backend | $device | - | - | - | - | - | - | - |"
            } >> "$REPORT"
            continue
        fi
        mean() { python3 -c "
import sys
vals = [float(x) for x in sys.argv[1:]]
print(round(sum(vals)/len(vals), 4))
" "$@"; }
        {
            echo "| $backend | $device | $(mean "${wer_vals[@]}") | $(mean "${cer_vals[@]}") | $(mean "${pf1_vals[@]}") | $(python3 -c "
import sys
print(round(sum(float(x) for x in sys.argv[1:])/len(sys.argv[1:]), 1))
" "${first_vals[@]}") | $(python3 -c "
import sys
print(round(sum(float(x) for x in sys.argv[1:])/len(sys.argv[1:]), 1))
" "${warm_vals[@]}") | $(mean "${rtf_vals[@]}") | $(python3 -c "
import sys
print(round(sum(float(x) for x in sys.argv[1:])/len(sys.argv[1:]), 2))
" "${load_vals[@]}") |"
        } >> "$REPORT"
    done
done

log_msg "Done. Report: $REPORT"
log_msg "Raw logs: $OUT_DIR/*.log (stdout), $OUT_DIR/*.time (/usr/bin/time -l output)"
cat "$REPORT"