#!/bin/bash
#
# scripts/benchmark-parakeet.sh — permanent, re-runnable Parakeet CPU vs
# Vulkan benchmark (docs/parakeet-intel-backend.md §19). Requires macOS
# (uses `say`/`afconvert` for corpus synthesis and `/usr/bin/time -l` for
# peak RSS) and a built release SuperDictate binary
# (`./scripts/build-app.sh` or `swift build -c release --package-path
# swift`).
#
# It drives the REAL, permanent `--benchmark-transcribe` diagnostic entry
# point in swift/Sources/Parakey/main.swift, which itself calls the real
# production code (downloadParakeetModelIfNeeded, ParakeetEngine,
# TranscriptionWorker.resolvedParakeetThreadCount) — never a mock backend.
#
# Usage:
#   scripts/benchmark-parakeet.sh [--binary PATH] [--corpus-dir DIR]
#                                  [--out DIR] [--repeats N] [--devices "cpu vulkan"]
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
OUT_DIR="$ROOT_DIR/dist/benchmark-parakeet-$(date +%Y%m%d-%H%M%S)"
REPEATS=11   # first call = "first inference (cold)"; remaining N-1 = warm pool
DEVICES="cpu vulkan"

log_msg() { printf 'benchmark-parakeet: %s\n' "$*"; }
fail() { printf 'benchmark-parakeet: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary) BINARY="$2"; shift 2 ;;
        --corpus-dir) CORPUS_DIR="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --repeats) REPEATS="$2"; shift 2 ;;
        --devices) DEVICES="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^#//'
            exit 0
            ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS is required (uses 'say'/'afconvert')."

if [[ -z "$BINARY" ]]; then
    if [[ -x "$ROOT_DIR/dist/SuperDictate.app/Contents/MacOS/SuperDictate" ]]; then
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
#    synthesize with `say` + `afconvert`, matching this migration's Phase 1
#    corpus method (RU/EN/mixed, names, numbers, addresses, technical
#    terms, short commands, one long monologue) across four duration
#    buckets (~3s/10s/30s/120s nominal).
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

CORPUS_FILES=()
for spec in "${CORPUS_SPECS[@]}"; do
    IFS='|' read -r name voice rate text <<< "$spec"
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

# ---------------------------------------------------------------------------
# 3. Run one (device, clip) pair: one fresh process, cold load + warm-up +
#    REPEATS transcriptions of the same clip. Captures peak RSS via
#    `/usr/bin/time -l` around the whole process (covers cold load + all
#    repeats, so it's a realistic session ceiling, not a per-call figure).
# ---------------------------------------------------------------------------
run_one() {
    local device="$1" clip_path="$2" clip_name log_file time_file
    clip_name="$(basename "$clip_path" .wav)"
    log_file="$OUT_DIR/${device}_${clip_name}.log"
    time_file="$OUT_DIR/${device}_${clip_name}.time"

    local -a repeat_args=()
    local i
    for ((i = 0; i < REPEATS; i++)); do
        repeat_args+=("$clip_path")
    done

    if /usr/bin/time -l "$BINARY" --benchmark-transcribe parakeet "$device" 8 "${repeat_args[@]}" \
        > "$log_file" 2> "$time_file"; then
        echo "$log_file"
    else
        log_msg "  [$device/$clip_name] FAILED (see $log_file / $time_file) — see BENCH_FAILED line if present"
        cat "$time_file" >> "$log_file" 2>/dev/null || true
        echo "$log_file"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 4. Best-effort VRAM sampling around a Vulkan run (Phase 5's own report
#    documents this as unreliable over a fast, short-lived SSH-driven
#    process — kept here as a best-effort, clearly-labeled approximation,
#    not a precise measurement).
# ---------------------------------------------------------------------------
vram_snapshot() {
    ioreg -l 2>/dev/null | grep -m1 'inUseVidMemoryBytes' | grep -o '[0-9]*' || echo ""
}

# ---------------------------------------------------------------------------
# 5. Main sweep
# ---------------------------------------------------------------------------
REPORT="$OUT_DIR/report.md"
{
    echo "# Parakeet CPU vs Vulkan benchmark"
    echo
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Binary: $BINARY"
    echo "Repeats per clip: $REPEATS (first = cold first-inference, rest = warm pool)"
    echo
    echo "| Device | Clip | Dur (s) | Cold load (s) | Warm-up (s) | Actual device | First-infer (ms) | Warm median (ms) | Warm p95 (ms) | RTF (warm median) | Peak RSS (MB) | VRAM delta (best-effort) | Transcript |"
    echo "|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---|"
} > "$REPORT"

for device in $DEVICES; do
    log_msg "=== Device: $device ==="
    for clip_path in "${CORPUS_FILES[@]}"; do
        clip_name="$(basename "$clip_path" .wav)"
        log_msg "  Running $clip_name..."

        vram_before="$(vram_snapshot)"
        if ! log_file="$(run_one "$device" "$clip_path")"; then
            {
                echo "| $device | $clip_name | - | - | - | FAILED | - | - | - | - | - | - | see $log_file |"
            } >> "$REPORT"
            continue
        fi
        vram_after="$(vram_snapshot)"

        load_line="$(grep '^BENCH_LOAD' "$log_file" || true)"
        [[ -n "$load_line" ]] || { log_msg "    no BENCH_LOAD line, skipping"; continue; }
        load_s="$(field "$load_line" load_s)"
        warm_s="$(field "$load_line" warmup_s)"
        actual_device="$(field "$load_line" actual_device)"

        # `mapfile`/`readarray` are bash4+ only; this project's macOS shells
        # ship Apple's ancient bash 3.2, so build the array with a plain
        # while-read loop instead.
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
        if [[ -f "$OUT_DIR/${device}_${clip_name}.time" ]]; then
            peak_rss_bytes="$(grep 'maximum resident set size' "$OUT_DIR/${device}_${clip_name}.time" | awk '{print $1}')"
            if [[ -n "${peak_rss_bytes:-}" ]]; then
                peak_rss_mb="$(python3 -c "print(round($peak_rss_bytes/1024/1024, 1))")"
            fi
        fi

        vram_delta="n/a"
        if [[ -n "$vram_before" && -n "$vram_after" ]]; then
            vram_delta="$(python3 -c "print(round(($vram_after-$vram_before)/1024/1024, 2))" 2>/dev/null || echo "n/a")"
        fi

        transcript="$(field "${result_lines[0]}" text)"
        # field() stops at the first whitespace; grab the full text= tail instead.
        transcript="$(echo "${result_lines[0]}" | sed -n 's/.*text=//p')"

        {
            echo "| $device | $clip_name | $duration_s | $load_s | $warm_s | $actual_device | $first_ms | $warm_median_ms | $warm_p95_ms | $rtf | $peak_rss_mb | $vram_delta MB | $transcript |"
        } >> "$REPORT"
    done
done

log_msg "Done. Report: $REPORT"
log_msg "Raw logs: $OUT_DIR/*.log (stdout), $OUT_DIR/*.time (/usr/bin/time -l output)"
cat "$REPORT"
