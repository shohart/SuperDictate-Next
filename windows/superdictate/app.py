"""Application orchestration: the dictation state machine.

Everything the macOS ``AppDelegate`` coordinates lives here, the hotkey
listener, the recorder, the transcription worker, the HUD, the tray and
the windows, with one structural difference. macOS splits the product
into a background LaunchAgent plus a separate control panel process that
talk through a status file. On Windows a single process owns the keyboard
hook and the UI, and closing the control panel just hides a window; the
tray icon is what keeps the service alive. A named mutex replaces the PID
file so a second launch surfaces the running instance.

Thread layout:

* **Hook thread**, decodes hotkeys, never blocks (see :mod:`hotkeys`).
* **Qt thread**, all UI, plus recorder start/stop.
* **Model thread**, one worker draining a queue, so a second dictation
  started while the first is still transcribing simply queues up.
"""

from __future__ import annotations

import os
import queue
import threading
import time
from concurrent.futures import Future
from dataclasses import dataclass
from enum import Enum
from typing import Optional

import numpy as np
from PySide6.QtCore import QObject, Qt, QTimer, Signal

from . import (asr, audio, edit_watch, focus_target, i18n, incremental, inject, system,
               textproc, transcription)
from .history import History, HistoryEntry, UsageStats
from .hotkeys import Action, HotkeyListener
from .llm import LLMPostprocessor
from .vocabulary import VocabularyStore, migrate_json_if_needed
from .logging_setup import get as get_logger
from .settings import CompletionBehavior, Settings

log = get_logger("app")

#: How often an idle app asks the speech host whether its NPU compile is done.
NPU_POLL_SECONDS = 10.0

# Live preview. The model is not a streaming one: each pass re-reads the
# audio from the start, so the cost grows with the length of the dictation
# and the interval has to grow with it. PREVIEW_DUTY is the share of one
# core the preview is allowed to keep busy; the rest of the time it waits.
PREVIEW_FIRST_DELAY = 1.0
PREVIEW_MIN_INTERVAL = 0.7
PREVIEW_MIN_AUDIO_SECONDS = 0.6
PREVIEW_WINDOW_SECONDS = 30.0
PREVIEW_DUTY = 0.5

# How many past transcripts the shortcut offers over the capsule. Kept in
# step with superdictate.ui.bubbles.MAX_ENTRIES, and not imported from it:
# this module knows nothing about Qt and the self-tests rely on that.
HISTORY_BUBBLE_COUNT = 6


class AppState(str, Enum):
    STARTING = "starting"
    DOWNLOADING = "downloading"
    LOADING = "loading"
    READY = "ready"
    RECORDING = "recording"
    TRANSCRIBING = "transcribing"
    # The LLM stages run after transcription and can take seconds on a cold
    # host, so they get their own state: the HUD says "correcting" rather
    # than pretending the ASR is still working.
    CORRECTING = "correcting"
    FAILED = "failed"


@dataclass
class _Job:
    samples: np.ndarray
    behavior: CompletionBehavior
    enqueued_at: float
    recovered: bool = False
    # Resolves to the focus_target.InsertionTarget captured when the
    # recording started: where the text goes, wherever the user is now.
    target: Optional[Future] = None
    # Windows already transcribed while the recording ran (incremental.py);
    # finished on the worker, right before the full buffer is transcribed.
    speculative: Optional["incremental.IncrementalTranscriber"] = None


class DictationController(QObject):
    """Owns the dictation lifecycle and emits UI-facing signals."""

    state_changed = Signal(str)            # AppState value
    progress_changed = Signal(object)      # asr.Progress
    level_changed = Signal(float)
    preview_changed = Signal(str)         # partial text while recording
    transcript_ready = Signal(str)
    # Something is wrong with the machine, not with what was said: no
    # microphone, no keyboard hook, no model. These outlive the moment and
    # go to the Windows notification centre.
    error_raised = Signal(str)
    # The dictation itself came to nothing. Reported on the capsule, which
    # the user is already looking at, and gone a few seconds later.
    # Carries (icon name, message).
    dictation_failed = Signal(str, str)
    # The full history window, from the tray and the control panel.
    history_toggle_requested = Signal()
    # The last few transcripts as bubbles over the capsule, from the
    # shortcut. Carries them newest first.
    history_bubbles_requested = Signal(list)
    settings_applied = Signal()
    # The speech model moved to another device (the NPU, once its background
    # compile finished); the panel shows the device.
    device_changed = Signal()
    # Rules just learned, as (source, replacement) pairs. The UI
    # offers an undo for them; see ui.learn_toast.
    vocabulary_learned = Signal(list)
    # A short-lived "X is now on/off" card. Carries (text, tone), where the
    # tone is "on", "off", or a rewrite style's value.
    state_toast_requested = Signal(str, str)
    # A persistent "loading the model" card, shown while a cold LLM host
    # starts. Empty text dismisses it.
    loading_toast_requested = Signal(str)
    # The window the dictation started in was closed (or would not come
    # back): the text went to the clipboard instead of into another app.
    paste_redirected = Signal(str)

    def __init__(self, settings: Settings) -> None:
        super().__init__()
        self.settings = settings
        self.history = History()
        self.usage = UsageStats()
        # SQLite, not the JSON list this port started from: the
        # dictionary grows on its own from hand-corrections, and a
        # whole-file rewrite per learn is both a lost-write risk and a
        # re-parse of the entire list on every dictation. An existing
        # Corrections.json is folded in once, then set aside.
        self.corrections = VocabularyStore()
        migrate_json_if_needed(self.corrections)
        # Post-processing hosts are started lazily, on the first dictation
        # that actually needs one — a multi-GB model must not be loaded at
        # launch for a feature the user may never turn on.
        self.postprocessor = LLMPostprocessor()
        self.postprocessor.gpu_layers = settings.llm_gpu_layers
        # Cold-start feedback. The callbacks fire on the transcription
        # worker thread; the signals are queued, so the widgets are still
        # only ever touched from the Qt thread.
        self.postprocessor.on_load_stage = (
            lambda _stage: self.loading_toast_requested.emit(
                i18n.tr("toast_loading_model")))
        self.postprocessor.on_load_finished = (
            lambda: self.loading_toast_requested.emit(""))
        self.sounds = system.Sounds(settings.play_feedback_sounds)
        self.output_mute = system.OutputMute()
        self.media_pause = system.MediaPause()
        # The mute now trails the start cue by a thread, so it has to be
        # possible to tell it that its recording is over. See _mute_after_cue.
        self._playback_lock = threading.Lock()
        self._recording_session = 0

        self._state = AppState.STARTING
        self._state_lock = threading.Lock()
        self._jobs: "queue.Queue[Optional[_Job]]" = queue.Queue()
        self._worker: Optional[threading.Thread] = None
        self._model: Optional[asr.SpeechModel] = None
        self._preview_stop: Optional[threading.Event] = None
        self._speculative: Optional[incremental.IncrementalTranscriber] = None
        # Every focus/caret query, for the HUD and for the paste. One
        # thread, shared, so UI Automation is only ever touched from it.
        self.focus = focus_target.FocusProbe()
        # Learns corrections from edits made to a dictation right after it
        # was pasted (the macOS PostInsertionEditWatcher).
        self.edit_watch = edit_watch.EditWatcher(
            lambda: self.focus.read_field().result(timeout=1.0),
            self._learn_from_edit,
            own_pids=frozenset({os.getpid()}))
        self._insertion_target: Optional[Future] = None
        self._terminating = False
        self.last_error: str = ""
        # What the last dictation produced, kept so the editor has
        # something to open on. Deliberately not restored from the archive
        # at startup: correcting a sentence from yesterday is what the
        # replacement dictionary in the settings is for.
        self.last_transcript: str = ""

        self.recorder = audio.Recorder(
            on_level=self._on_level,
            on_auto_stop=self._on_auto_stop,
        )
        self.recorder.silence_stop_enabled = self.settings.stop_on_silence
        self.recorder.silence_stop_seconds = self.settings.silence_stop_seconds
        self.listener = HotkeyListener(self._on_hotkey_actions)
        self._apply_hotkey_settings()
        self.listener.is_recording_active = lambda: self.state is AppState.RECORDING
        self.listener.can_start_recording = self._can_start_recording

        # Hook-thread callbacks are marshalled onto the Qt thread through
        # this queued signal; touching widgets from the hook thread would
        # be both a Qt violation and a hook-timeout risk.
        self._action_bridge = _ActionBridge()
        self._action_bridge.actions.connect(self._handle_actions,
                                            Qt.ConnectionType.QueuedConnection)

    # -- state --------------------------------------------------------

    @property
    def state(self) -> AppState:
        with self._state_lock:
            return self._state

    def _set_state(self, state: AppState) -> None:
        with self._state_lock:
            if self._state is state:
                return
            self._state = state
        self.state_changed.emit(state.value)

    def _can_start_recording(self) -> bool:
        return self.state is AppState.READY and not self._terminating

    # -- startup / shutdown -------------------------------------------

    def start(self) -> None:
        # A previous run killed from Task Manager can leave the foreground
        # app convinced a modifier is still down. Correct that before the
        # hook goes in, while nothing of ours is suppressing anything.
        stray = inject.clear_stuck_modifiers()
        if stray:
            log.debug("Cleared %d stray modifier(s) left over from a previous run",
                      len(stray))

        # Same idea for the speakers: a run that died mid-recording left
        # them muted, and a silent machine is a lot harder to connect to
        # this app than a stuck Shift.
        self.output_mute.recover()

        self.listener.start()
        if not self.listener.installed:
            log.error("Keyboard hook could not be installed")
            self.error_raised.emit(i18n.tr("error_hook"))

        # The autostart entry is rewritten by older versions without the
        # tray flag; put it back before the user notices at the next login.
        system.repair_autostart()

        self._worker = threading.Thread(target=self._worker_loop,
                                        name="transcription-worker", daemon=True)
        self._worker.start()

        # Whether this machine has an Intel NPU decides what the settings
        # offer; asking takes a helper process a second or two, so it is
        # asked now, long before anybody opens them.
        asr.probe_npu_async()
        # Silero VAD places the seams of long dictations; its 885 KB model
        # is fetched in the background, as on macOS.
        from . import vad
        threading.Thread(target=vad.ensure_model, name="vad-download", daemon=True).start()

    def load_model(self) -> None:
        """Start the model loading. Deliberately separate from :meth:`start`.

        Creating the encoder session takes about 3.7 seconds and holds
        the GIL for nearly all of it — it is ONNX Runtime building the
        graph, the same cost for the 640 MB weights as for the 2.4 GB
        ones, and there is no way to give the interpreter back in the
        middle of it. Whatever is on screen at that moment cannot repaint
        and Windows may grey it out as "not responding".

        So the load waits for the window to finish drawing itself first.
        The stall is the same length either way, but it lands on a panel
        that has already painted the words "загрузка модели" instead of
        on an empty frame that looks like a hang.
        """
        threading.Thread(target=self._prepare_model, name="model-loader",
                         daemon=True).start()

    def shutdown(self) -> None:
        self._terminating = True
        self._stop_preview()
        self._discard_speculative()
        self.edit_watch.stop()
        try:
            if self.recorder.is_recording:
                self.recorder.discard()
        finally:
            self._restore_playback()
        self.listener.stop()
        self._jobs.put(None)
        if self._worker is not None:
            self._worker.join(timeout=3.0)
        if self._model is not None:
            self._model.unload()
        # After the worker has joined: a host torn down mid-request would
        # turn a finished dictation into a lost one.
        self.postprocessor.shutdown()
        self.focus.close()

    def _prepare_model(self) -> None:
        backend = self.settings.speech_compute_backend
        if backend == asr.BACKEND_NPU and asr.npu_info() is None:
            log.warning("Speech backend is set to the NPU, but none was found; using the CPU")
            backend = asr.BACKEND_CPU
        model = asr.SpeechModel(profile=self.settings.speech_model_profile, backend=backend)
        self._model = model

        def on_progress(progress: asr.Progress) -> None:
            self.progress_changed.emit(progress)
            if progress.state is asr.State.DOWNLOADING:
                self._set_state(AppState.DOWNLOADING)
            elif progress.state is asr.State.LOADING:
                self._set_state(AppState.LOADING)

        if model.prepare(on_progress):
            self._set_state(AppState.READY)
            self._recover_pending_dictation()
            self._warm_up_correction()
            if model.npu_compiling:
                threading.Thread(target=self._watch_npu_compile, args=(model,),
                                 name="npu-compile-watch", daemon=True).start()
        else:
            self.last_error = model.error or "unknown error"
            self._set_state(AppState.FAILED)
            self.error_raised.emit(self.last_error)

    def _recover_pending_dictation(self) -> None:
        """Transcribe audio a crash left behind, into history only.

        macOS restores the unfinished recording so the words are not lost;
        pasting it into whatever happens to be focused now would be worse
        than useless, so the recovered text goes to history and the user
        re-inserts it from there.
        """
        samples = audio.read_pending_dictation()
        audio.clear_pending_dictation()
        if samples is None:
            return
        log.info("Recovering %.1fs of audio from an interrupted session",
                 len(samples) / audio.SAMPLE_RATE)
        self._jobs.put(_Job(samples, self.settings.primary_completion_behavior,
                            time.monotonic(), recovered=True))

    # -- settings -----------------------------------------------------

    def apply_settings(self) -> None:
        """Re-read every live-adjustable preference. The macOS panel calls
        this "Save and restart"; nothing here needs a process restart
        except a model change, which reloads on its own."""
        self._apply_hotkey_settings()
        self.recorder.silence_stop_enabled = self.settings.stop_on_silence
        self.recorder.silence_stop_seconds = self.settings.silence_stop_seconds
        self.sounds.enabled = self.settings.play_feedback_sounds
        i18n.set_language(self.settings.interface_language)
        system.set_autostart(self.settings.start_at_login)
        # A changed LLM device only takes effect on the next cold host
        # start, so any host already running is retired here rather than
        # left serving requests on the device the user just switched away
        # from.
        wanted_layers = self.settings.llm_gpu_layers
        if wanted_layers != self.postprocessor.gpu_layers:
            log.info("LLM compute backend changed to %s; unloading hosts",
                     self.settings.llm_compute_backend)
            self.postprocessor.gpu_layers = wanted_layers
            self.postprocessor.shutdown()
        # A changed correction model, device or prompt means a new host
        # (or none): load it now rather than on the next dictation.
        self._warm_up_correction()
        self.settings_applied.emit()

    def _apply_hotkey_settings(self) -> None:
        self.listener.hotkey = self.settings.hotkey
        self.listener.history_hotkey = self.settings.history_hotkey
        # No transcript-editor shortcut: corrections are learned from edits
        # made in place, right after the paste (edit_watch.py), as on macOS.
        self.listener.edit_hotkey = None
        self.listener.correction_hotkey = self.settings.correction_hotkey
        self.listener.rewrite_hotkey = self.settings.rewrite_hotkey
        self.listener.rewrite_style_hotkey = self.settings.rewrite_style_hotkey
        self.listener.enter_hotkey = (self.settings.enter_hotkey
                                      if self.settings.alternate_completion_enabled else None)
        self.listener.trigger_mode = self.settings.trigger_mode
        self.listener.reset_state()

    def reload_model(self) -> None:
        """Swap weights or compute device without restarting the app."""
        if self._model is not None:
            self._model.unload()
        self._set_state(AppState.STARTING)
        threading.Thread(target=self._prepare_model, name="model-loader",
                         daemon=True).start()

    # -- hotkey plumbing ----------------------------------------------

    def _on_hotkey_actions(self, actions) -> None:
        self._action_bridge.actions.emit([action.value for action in actions])

    def _handle_actions(self, action_values: list[str]) -> None:
        for value in action_values:
            action = Action(value)
            if action is Action.PRESS:
                self.begin_recording()
            elif action is Action.RELEASE:
                self.finish_recording(self.settings.primary_completion_behavior)
            elif action is Action.RELEASE_ALTERNATE:
                # The other finish: paste + Enter when the primary only
                # pastes, and the reverse.
                self.finish_recording(self.settings.primary_completion_behavior.opposite)
            elif action is Action.CANCEL:
                self.cancel_recording()
            elif action is Action.SHOW_HISTORY:
                self.request_history_bubbles()
            elif action is Action.TOGGLE_CORRECTION:
                self.toggle_correction()
            elif action is Action.TOGGLE_REWRITE:
                self.toggle_rewrite()
            elif action is Action.CYCLE_REWRITE_STYLE:
                self.cycle_rewrite_style()
            elif action is Action.REJECTED_BUSY_PRESS:
                self.sounds.play("rejected")

    # -- post-processing shortcuts -------------------------------------
    #
    # These write the setting directly rather than going through the
    # settings window, and manage the host's delayed unload themselves: a
    # quick off/on by hotkey should reuse the model that is already warm,
    # not pay a multi-second reload for a toggle the user reversed in two
    # seconds. Turning something OFF only schedules the unload — a host a
    # still-enabled stage needs (the shared 8B, with rewrite left on) keeps
    # running.

    def toggle_correction(self) -> None:
        enabled = not self.settings.correction_enabled
        self.settings.set_correction_enabled(enabled)
        log.info("text correction: %s via hotkey",
                 "enabled" if enabled else "disabled")
        self._after_postprocessing_toggle(enabled)
        self.state_toast_requested.emit(
            i18n.tr("toast_correction_on" if enabled else "toast_correction_off"),
            "on" if enabled else "off")

    def toggle_rewrite(self) -> None:
        enabled = not self.settings.rewrite_enabled
        self.settings.set_rewrite_enabled(enabled)
        log.info("text rewrite: %s via hotkey",
                 "enabled" if enabled else "disabled")
        self._after_postprocessing_toggle(enabled)
        if enabled:
            style = self.settings.rewrite_config().style
            self.state_toast_requested.emit(
                i18n.tr("toast_rewrite_on",
                        style=i18n.tr(f"rewrite_style_{style.value}")),
                style.value)
        else:
            self.state_toast_requested.emit(i18n.tr("toast_rewrite_off"), "off")

    def cycle_rewrite_style(self) -> None:
        """Step to the next built-in style, turning rewrite on if it was off.

        Pressing a style shortcut is asking for that style, so it would be
        obtuse to change the setting and leave the stage disabled.
        """
        from .llm import RewriteStyle

        styles = list(RewriteStyle)
        current = self.settings.rewrite_config().style
        following = styles[(styles.index(current) + 1) % len(styles)]
        self.settings.set_rewrite_style(following)
        if not self.settings.rewrite_enabled:
            self.settings.set_rewrite_enabled(True)
            self.postprocessor.cancel_scheduled_unload()
        log.info("text rewrite style: %s via hotkey", following.value)
        self.state_toast_requested.emit(
            i18n.tr("toast_rewrite_style",
                    style=i18n.tr(f"rewrite_style_{following.value}")),
            following.value)

    def _watch_npu_compile(self, model) -> None:
        """Until the background NPU compile ends, ask the host every
        NPU_POLL_SECONDS where the model runs, so the panel switches from
        "CPU, compiling" to the NPU without waiting for a dictation."""
        while not self._terminating and model is self._model and model.npu_compiling:
            time.sleep(NPU_POLL_SECONDS)
            if model.refresh_device() and not model.npu_compiling:
                log.info("Speech model moved to %s after its background compile",
                         ", ".join(model.active_providers).upper())
                self.device_changed.emit()

    def _warm_up_correction(self) -> None:
        """Load the local correction model and prime its prompt cache in the
        background, so the next dictation does not pay for either."""
        if self._terminating:
            return
        config = self.settings.correction_config()
        threading.Thread(target=self.postprocessor.warm_up, args=(config,),
                         name="llm-warm-up", daemon=True).start()

    def _after_postprocessing_toggle(self, enabled: bool) -> None:
        if enabled:
            self.postprocessor.cancel_scheduled_unload()
            self._warm_up_correction()
        elif not (self.settings.correction_enabled or self.settings.rewrite_enabled):
            self.postprocessor.schedule_unload()
        if self.settings.play_feedback_sounds:
            self.sounds.play("start" if enabled else "stop")

    # -- recording ----------------------------------------------------

    def begin_recording(self) -> None:
        if not self._can_start_recording():
            self.sounds.play("rejected")
            return
        # Pausing first: it decides by listening to the output device, which
        # muting would silence and the start cue would fill with our own tone.
        if self.settings.pause_media_while_recording:
            self.media_pause.pause()
        # The field the user is in right now is where the text goes, even if
        # they switch windows while speaking (PendingTextInsertionTargetStore
        # on macOS). Captured off the Qt thread; the paste waits for it.
        self._insertion_target = self.focus.capture()
        # A new dictation ends the watch on the previous one.
        self.edit_watch.stop()
        if not self.recorder.start(self.settings.input_device):
            self._drop_insertion_target()
            self._restore_playback()
            message = self._microphone_error_message(self.recorder.last_error or "")
            self.last_error = message
            self.sounds.play("error")
            self.error_raised.emit(message)
            self.listener.reset_toggle()
            return
        self._set_state(AppState.RECORDING)
        # The mute waits for the start cue to finish. Muting first silenced
        # the cue along with everything else, so the one sound that says
        # "it is listening now" was the one nobody could hear.
        #
        # The recorder is already running by then, so the cue itself lands
        # in the first fraction of a second of the clip. That is the right
        # way round: a beep at the front of a recording costs nothing, and
        # holding the microphone shut until the cue ends would clip the
        # first word of anybody who starts talking straight away.
        if self.settings.mute_while_recording:
            with self._playback_lock:
                self._recording_session += 1
                session = self._recording_session
            self.sounds.play("start",
                             then=lambda: self._mute_after_cue(session))
        else:
            self.sounds.play("start")
        self._start_preview()
        self._start_speculative()

    @staticmethod
    def _microphone_error_message(reason: str) -> str:
        """Name the actual cause instead of always blaming permissions."""
        lowered = reason.lower()
        if "denied" in lowered or "access" in lowered or "-9996" in lowered:
            return i18n.tr("error_microphone_denied")
        if "unanticipated host" in lowered or "device unavailable" in lowered:
            return i18n.tr("error_microphone_busy")
        return i18n.tr("error_microphone", reason=reason or "?")

    def finish_recording(self, behavior: CompletionBehavior) -> None:
        if self.state is not AppState.RECORDING:
            return
        self._stop_preview(clear=False)
        speculative, self._speculative = self._speculative, None
        samples = self.recorder.stop()
        self._restore_playback()
        audio.clear_pending_dictation()
        self.sounds.play("stop")

        duration = len(samples) / audio.SAMPLE_RATE
        if duration < audio.MIN_CLIP_SECONDS:
            log.info("Discarding %.2fs clip (below %.2fs minimum)",
                     duration, audio.MIN_CLIP_SECONDS)
            # Same cleanup as a cancel. Without it the toggle stays flipped
            # on, so the next press emits a discarded .release and the
            # hotkey looks dead until it is pressed a third time.
            self.listener.reset_toggle()
            self._drop_insertion_target()
            self._discard_speculative(speculative)
            self._set_state(AppState.READY)
            self.dictation_failed.emit("clock", i18n.tr("error_too_short"))
            return

        self._set_state(AppState.TRANSCRIBING)
        target, self._insertion_target = self._insertion_target, None
        self._jobs.put(_Job(samples, behavior, time.monotonic(), target=target,
                            speculative=speculative))

    def cancel_recording(self) -> None:
        if self.state is not AppState.RECORDING:
            return
        self._stop_preview()
        self._discard_speculative()
        self.recorder.discard()
        self._restore_playback()
        self.listener.reset_toggle()
        self._drop_insertion_target()
        self._set_state(AppState.READY)
        log.info("Recording cancelled")

    def _mute_after_cue(self, session: int) -> None:
        """Mute, unless the recording this belongs to is already over.

        Runs on the cue's thread, a fraction of a second after the
        recording started, which is long enough for a very short dictation
        to have finished and restored the sound already. Muting then would
        leave the machine silent with nothing recording. The session number
        and the lock make the two orders equivalent: either the mute
        happens and the restore undoes it, or the restore happens and the
        mute is skipped.
        """
        with self._playback_lock:
            if session != self._recording_session:
                return
            self.output_mute.mute()

    def _restore_playback(self) -> None:
        """Undo both interventions, in the order they were applied.

        Unmuting first means the video the media key resumes is audible from
        its first frame. Both calls are no-ops unless they did something,
        so this is safe to call on every path out of a recording — including
        the ones where the settings were off.
        """
        with self._playback_lock:
            self._recording_session += 1
            self.output_mute.restore()
        self.media_pause.resume()

    def _on_level(self, level: float) -> None:
        self.level_changed.emit(level)

    def _on_auto_stop(self) -> None:
        log.info("Auto-stopping after %d minutes", audio.MAX_RECORDING_SECONDS // 60)
        self._action_bridge.actions.emit([Action.RELEASE.value])

    # -- transcription while recording --------------------------------

    def _start_speculative(self) -> None:
        """Transcribe the parts of a long recording that can no longer change
        while it is still running (incremental.py). Does nothing until the
        recording is long enough to be segmented at all."""
        self._discard_speculative()
        model = self._model
        if model is None or not model.is_ready:
            return
        recorder = self.recorder

        def snapshot():
            # None once this recording is over: the driver then stops.
            return recorder.snapshot() if recorder.is_recording else None

        max_segment, min_segment = transcription.segment_limits(model)
        self._speculative = incremental.IncrementalTranscriber(
            model, snapshot, sample_rate=audio.SAMPLE_RATE,
            max_segment_seconds=max_segment, min_segment_seconds=min_segment).start()

    def _discard_speculative(self, speculative=None) -> None:
        """Stop and drop recording-time work without waiting for it: the
        window in flight finishes in the background."""
        if speculative is None:
            speculative, self._speculative = self._speculative, None
        if speculative is not None:
            threading.Thread(target=speculative.cancel, name="recording-time-asr-cancel",
                             daemon=True).start()

    # -- live preview --------------------------------------------------

    def _start_preview(self) -> None:
        if not self.settings.live_preview:
            return
        stop = threading.Event()
        self._preview_stop = stop
        threading.Thread(target=self._preview_loop, args=(stop,),
                         name="live-preview", daemon=True).start()

    def _stop_preview(self, *, clear: bool = True) -> None:
        """End the preview loop. ``clear`` also wipes what it last showed.

        A finished recording keeps its last preview on screen: the words
        are about to be replaced by the real transcription, and blanking
        the bubble for the second or two in between reads as the app
        having thrown the dictation away.
        """
        stop, self._preview_stop = self._preview_stop, None
        if stop is not None:
            stop.set()
            if clear:
                self.preview_changed.emit("")

    def _preview_loop(self, stop: threading.Event) -> None:
        """Re-transcribe the recording so far, over and over, until it ends.

        Only the last :data:`PREVIEW_WINDOW_SECONDS` are read. Beyond that
        a single pass costs more than the interval between passes, and the
        point of the preview is to be roughly current, not complete: the
        real transcription runs on the whole clip when recording stops.
        """
        delay = PREVIEW_FIRST_DELAY
        while not stop.wait(delay):
            if not self.recorder.is_recording:
                return
            model = self._model
            if model is None or not model.is_ready:
                return

            samples = self.recorder.snapshot(PREVIEW_WINDOW_SECONDS)
            if len(samples) < PREVIEW_MIN_AUDIO_SECONDS * audio.SAMPLE_RATE:
                delay = PREVIEW_MIN_INTERVAL
                continue

            outcome = model.transcribe_preview(samples)
            if outcome is None:
                delay = PREVIEW_MIN_INTERVAL
                continue
            raw, inference_seconds = outcome
            if stop.is_set():
                return

            text, _, _ = textproc.process_transcript(
                raw,
                language=self.settings.dictation_language,
                corrections=self.corrections.all(),
                strip_fillers=self.settings.remove_filler_words,
                filler_words=self.settings.filler_words,
                digits=self.settings.numbers_as_digits,
                style=self.settings.text_style,
            )
            if text and self.recorder.elapsed > PREVIEW_WINDOW_SECONDS:
                text = "… " + text
            self.preview_changed.emit(text)

            delay = max(PREVIEW_MIN_INTERVAL,
                        inference_seconds * (1.0 - PREVIEW_DUTY) / PREVIEW_DUTY)

    # -- transcription worker -----------------------------------------

    def _worker_loop(self) -> None:
        while True:
            job = self._jobs.get()
            if job is None:
                return
            try:
                self._run_job(job)
            except Exception as exc:
                log.exception("Transcription failed")
                self.last_error = str(exc)
                self.sounds.play("error")
                self.error_raised.emit(str(exc))
            finally:
                if not self._terminating:
                    self._set_state(AppState.READY)

    def _run_job(self, job: _Job) -> None:
        model = self._model
        if model is None or not model.is_ready:
            raise RuntimeError("Speech model is not ready")

        # Waits for the recording-time window in flight (one ASR call at a
        # time), then transcribes the full buffer, reusing what matches.
        cache = job.speculative.finish() if job.speculative is not None else None
        result = transcription.transcribe(model, job.samples, job.enqueued_at, cache=cache)
        text, applied, removed = textproc.process_transcript(
            result.text,
            language=self.settings.dictation_language,
            corrections=self.corrections.all(),
            strip_fillers=self.settings.remove_filler_words,
            filler_words=self.settings.filler_words,
            digits=self.settings.numbers_as_digits,
            style=self.settings.text_style,
        )
        log.info(
            "Transcribed %.1fs of audio in %.2fs (RTF %.2f, %d segment(s)%s%s, "
            "%d corrections, %d fillers removed)",
            result.audio_seconds, result.inference_seconds,
            result.realtime_factor, result.segments,
            ", overlap" if result.overlap_path else "",
            f", {result.windows_reused} window(s) done while recording"
            if result.windows_reused else "", applied, removed,
        )

        if not text:
            self.dictation_failed.emit("mic", i18n.tr("error_no_speech"))
            return

        text = self._postprocessed(text)

        # The preview stopped a beat before the recording did, so its last
        # words are missing. This is the same sentence, complete.
        if self.settings.live_preview and not job.recovered:
            self.preview_changed.emit(text)

        self.history.add(HistoryEntry(
            text=text,
            created_at=time.time(),
            audio_seconds=result.audio_seconds,
            transcription_seconds=result.inference_seconds,
        ))
        self.usage.record(text, result.audio_seconds)
        self.transcript_ready.emit(text)
        self.last_transcript = text

        if job.recovered:
            # Recovered audio never auto-pastes; see _recover_pending_dictation.
            return

        payload = text + self.settings.paste_suffix.text
        if not self._return_to_target(job, payload):
            return
        inject.paste_text(
            payload,
            press_enter=job.behavior.presses_enter,
            enter_delay_ms=self.settings.enter_delay_milliseconds,
        )
        if not job.behavior.presses_enter:
            # A message already sent with Enter is not there to be fixed.
            self.edit_watch.begin(payload)

    def _return_to_target(self, job: _Job, payload: str) -> bool:
        """Back to the field the dictation began in. False: do not paste.

        The macOS rule (textInsertionRoute): a target that is still there
        gets the text even if the user has moved on; one that is gone gets
        nothing, because "whatever is in front now" is exactly the wrong
        place. The text is not lost — it is on the clipboard.
        """
        target = None
        if job.target is not None:
            try:
                target = job.target.result(timeout=1.0)
            except Exception as exc:
                log.warning("Insertion target was not captured: %s", exc)
        if target is None:
            return True
        outcome = self.focus.restore(target)
        if outcome in (focus_target.RestoreOutcome.TARGET_GONE,
                       focus_target.RestoreOutcome.NOT_ACTIVATED):
            inject.write_clipboard_text(payload)
            key = ("paste_target_gone"
                   if outcome is focus_target.RestoreOutcome.TARGET_GONE
                   else "paste_target_unreachable")
            self.paste_redirected.emit(i18n.tr(key, app=target.process))
            return False
        return True

    def _drop_insertion_target(self) -> None:
        pending, self._insertion_target = self._insertion_target, None
        if pending is not None:
            pending.add_done_callback(
                lambda done: self.focus.release(done.result()) if not done.exception() else None)

    def _postprocessed(self, text: str) -> str:
        """Run the enabled LLM stages, or return ``text`` untouched.

        Deliberately synchronous, on the transcription worker thread: the
        stages are sequential, the host serializes requests anyway, and the
        user is already waiting on this dictation. It never raises — the
        pipeline's own failure policy returns the input unchanged — so a
        model that will not load costs the correction, never the text.
        """
        correction = self.settings.correction_config()
        rewrite = self.settings.rewrite_config()
        if not correction.enabled and not rewrite.enabled:
            return text

        self._set_state(AppState.CORRECTING)
        started = time.monotonic()
        try:
            return self.postprocessor.finalize(
                text, correction=correction, rewrite=rewrite)
        finally:
            log.info("Post-processing took %.2fs", time.monotonic() - started)

    # -- quick history --------------------------------------------------

    def request_history_bubbles(self) -> None:
        """Offer the last few transcripts over the capsule.

        Refused mid-dictation for the same reason the editor is: the
        capsule belongs to the recording that is running.
        """
        if self.state is not AppState.READY or self._terminating:
            self.sounds.play("rejected")
            return
        entries = self.history.entries(HISTORY_BUBBLE_COUNT)
        if not entries:
            self.sounds.play("rejected")
            return
        self.history_bubbles_requested.emit([entry.text for entry in entries])

    def forget_history_entry(self, index: int) -> None:
        self.history.remove(index)

    # -- correcting the last dictation ---------------------------------

    def _learn_from_edit(self, candidate) -> list:
        """Save one rule found by the edit watcher (its thread). The toast
        is what makes it reversible: a rule learned from a typo the user
        meant to keep is worse than no learning at all."""
        records = self.corrections.learn([(candidate.source, candidate.replacement)])
        if records:
            log.info("Learned a correction from an edit in place: %r -> %r",
                     candidate.source, candidate.replacement)
            self.vocabulary_learned.emit([(r.source, r.replacement) for r in records])
            if self.last_transcript and candidate.source in self.last_transcript:
                amended = self.last_transcript.replace(candidate.source, candidate.replacement, 1)
                if self.history.amend(self.last_transcript, amended):
                    self.transcript_ready.emit(amended)
                self.last_transcript = amended
        return records

    # -- manual insertion (history window) -----------------------------

    def insert_text(self, text: str) -> None:
        inject.paste_text(text + self.settings.paste_suffix.text)


class _ActionBridge(QObject):
    actions = Signal(list)
