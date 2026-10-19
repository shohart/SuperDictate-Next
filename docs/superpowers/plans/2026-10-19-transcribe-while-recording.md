# Transcribe while recording — plan

Date: 2026-10-19. Branch `fix/llm-correction-long-dictation`. Repo rules:
`AGENTS.md` (never launch or install .app bundles; self-tests only on the
`swift build` debug binary `swift/.build/debug/Parakey`, never
`--self-test all`; after any self-test check the production LaunchAgent:
`launchctl list | grep superdictate` shows one agent and
`~/Library/LaunchAgents/com.local.superdictate.agent.plist` points at
`/Applications/SuperDictate.app/Contents/MacOS/SuperDictate`).

## Why

Long dictations wait for all of their audio to be transcribed after the
hotkey is released: a 4-min dictation is ~14 s of ONNX work (GigaAM v3,
16 threads), a 5-min one ~19 s. The audio is already cut into ≤ 25 s
segments at pauses (`PauseSegmenter`) and transcribed as overlapping
windows (`transcribeWithOverlapWindows`), one window at a time. Most of
those windows are fixed long before the user stops talking. Transcribing
them during the recording leaves only the last one or two windows for
after release: ~1–3 s whatever the length.

## Hard requirements

1. **Same text as today.** For the same captured buffer the final text must
   be byte-identical to the current batch path. Speculative results are a
   cache, never a different algorithm: at release, segments and windows are
   computed from the FULL buffer exactly as today; a window is taken from
   the cache only if its `startSample` and sample count match exactly (and
   the cached audio is the same — compare a cheap checksum or the samples);
   anything else is transcribed again. Then Phase B assembly runs as today.
2. **The LLM sees only the final text.** Correction and rewrite
   (`LLMPostprocessingCoordinator.finalizedText`) run once per dictation, on
   the fully assembled text, after release — never on partial or per-window
   text. Keep it that way and add a self-test (or an assertion on the call
   order through a test seam) that pins it.
3. **Never lose a dictation.** Any failure in the speculative path (throw,
   cancellation, mismatch) just drops the cache; the release path still has
   the full buffer and the existing fallbacks (overlap path → plain
   segmentation, retain-on-loss) unchanged.
4. **Short dictations unchanged.** Under ~15 s nothing is segmented; no
   speculative work starts, no extra latency or CPU.
5. **Audio capture is never starved.** Speculative ASR runs off the audio
   thread; it must not block capture, the HUD, or the hotkey. Cancel
   recording → discard the cache and stop speculative work promptly.
6. **One ASR call at a time.** The worker (`TranscriptionWorker`) has an
   `inFlight` guard. At release, wait for (or cancel) the in-flight
   speculative window before the release path uses the worker; never race
   it.

## Design (verify each assumption against the code first)

- **Segment stability.** Check whether `PauseSegmenter.segment` is a
  left-to-right greedy pass whose cut positions over a prefix of the buffer
  depend only on audio up to (cut + pause threshold / safety margin). If so,
  a segment is final once the segmenter run on the growing buffer has
  emitted at least one more segment after it (or enough audio past its end).
  If the hard-cap cut searches backwards or anything depends on the total
  length, define "stable" conservatively — correctness comes from the
  exact-match check at release anyway; stability only decides how much work
  is wasted.
- **Window stability.** `OverlapWindower.addOverlap` gives window i
  `overlapBefore` (from segment i−1, bounded by segment i's own budget) and
  `overlapAfter` (≤ 4 s of segment i+1, bounded by segment i's budget and
  segment i+1's length). So window i is fixed once segment i is final and
  segment i+1 holds at least `min(4 s, halfBudget)` of audio. Note the
  special case: with ≤ 1 total segment there is no overlap at all — the
  speculative path only ever starts once there are ≥ 2 segments.
- **Snapshot source.** Find how `AudioCapture` accumulates samples during a
  recording (and the crash journal) and add a cheap way to read the
  samples captured so far (copy-on-read is fine every 1–2 s; 25 s of 16 kHz
  float is 1.6 MB).
- **Driver.** A small type (e.g. `IncrementalOverlapTranscriber`, an actor
  or a task owned by the recording lifecycle) that every ~1–2 s while
  recording: snapshots the buffer, runs the segmenter + windower on it,
  and transcribes (via `worker.transcribeWithTokens`) the next stable window
  not yet cached. Keyed cache: `(startSample, samples.count) → (checksum,
  [TranscribedWord], timing)`. At release: stop the driver, await the
  in-flight call, then run the normal overlap path with the cache passed in
  (`transcribeWithOverlapWindows(..., cachedWindows:)`), logging
  `overlap transcription: N windows (K from recording-time cache)`.
- **Timing/latency log.** `engine_call` should reflect only the post-release
  work; add the speculative ASR seconds as a separate field so the latency
  line stays honest.
- **Settings/model switch mid-recording**: if the ASR model is reloaded,
  drop the cache (the cache must carry the model id).

## Tasks

1. Read and confirm the assumptions above (segmenter, windower, capture,
   recording lifecycle in `ParakeyApp.swift` / `RecordingLifecycle.swift`,
   the release → transcribe → `finalizedText` → insert path). Write down in
   the code comments what makes a window stable.
2. Implement the cache-aware overlap path + driver. Pure parts (stability
   rule, cache matching) as plain functions with self-tests.
3. Self-tests (new group, e.g. `incremental-transcription`, plus keep
   `onnx-asr`, `llm-guardrail`, `llm-unload-delay`, `asr-thread-policy`
   green), hermetic with a fake worker:
   - growing-buffer simulation: feeding a long synthetic buffer in chunks
     yields segments/windows whose stable prefix equals the final full-
     buffer segmentation;
   - final text with cache == final text without cache (fake worker that
     returns deterministic words per window);
   - a cache entry with mismatched audio/length is ignored and re-run;
   - cancellation mid-recording discards the cache and nothing leaks;
   - postprocessing (`finalizedText`) is invoked exactly once, after
     assembly, with the full text.
4. Diagnostic: extend `--benchmark-transcribe` (or add
   `--benchmark-transcribe-streaming [onnx|gigaam] cpu <threads> <speed>
   <wav...>`) that feeds the WAV into the driver at `speed`× real time
   (e.g. 4), then "releases" and prints `post_release_s`, total speculative
   ASR seconds, windows reused, and the text — and compares it to the batch
   path's text for the same file (print `identical=true/false`). Must be
   safe to run on the installed app like the existing benchmark (no UI, no
   agent interaction).
5. `swift build`, the self-test groups above on the debug binary, the
   LaunchAgent safety check. Run the streaming benchmark on the DEBUG
   binary only if it can find the model; otherwise leave it to the
   coordinator. Do NOT install or launch any .app — the coordinator does
   that with `scripts/install-local.sh`.
6. Commit on the branch (conventional message, end with
   `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`). Update
   `docs/specs/cross-platform-onnx-asr-spec.md` with a short section on the
   recording-time path.

## Done when

- Streaming benchmark on `tts16k.wav` (245 s) and the 326 s real
  concatenation: `identical=true`, post-release time ≤ ~3 s with GigaAM at
  16 threads (today ~14 s / ~20 s).
- All listed self-tests pass; LaunchAgent intact.
