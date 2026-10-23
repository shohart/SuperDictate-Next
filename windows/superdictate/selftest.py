"""Built-in checks, the counterpart of ``Parakey --self-test all``.

Everything here is pure logic: no microphone, no keyboard hook, no model,
no Qt. That is deliberate, these are the parts a port is most likely to
get subtly wrong, and they are the parts that can be verified on a
headless runner.
"""

from __future__ import annotations

import tempfile
from pathlib import Path

from .hotkeys import (
    MOD_ALT,
    MOD_CTRL,
    MOD_SHIFT,
    VK_ESCAPE,
    VK_LCONTROL,
    VK_LMENU,
    VK_RCONTROL,
    VK_RMENU,
    VK_RSHIFT,
    Action,
    HotkeyChoice,
    HotkeyStateMachine,
    TriggerMode,
    _Event,
)
from .settings import Correction, TextStyle
from .textproc import (
    apply_corrections,
    apply_text_style,
    learned_corrections,
    numbers_as_digits,
    process_transcript,
    remove_filler_words,
    repair_model_text,
)

_failures: list[str] = []


def _check(name: str, actual, expected) -> None:
    if actual != expected:
        _failures.append(f"{name}\n    expected: {expected!r}\n    actual:   {actual!r}")


# -- hotkey state machine -------------------------------------------------

HOTKEY = HotkeyChoice(VK_RCONTROL)
HISTORY_HOTKEY = HotkeyChoice(VK_RCONTROL, MOD_SHIFT)
EDIT_HOTKEY = HotkeyChoice(VK_RMENU, MOD_SHIFT)


def _machine() -> HotkeyStateMachine:
    return HotkeyStateMachine()


def _feed(machine, vk, down, modifiers, *, mode=TriggerMode.TOGGLE,
          recording=False, can_start=True, repeat=False):
    return machine.transition(
        _Event(vk=vk, is_down=down, modifiers=modifiers, is_repeat=repeat),
        hotkey=HOTKEY,
        history_hotkey=HISTORY_HOTKEY,
        edit_hotkey=EDIT_HOTKEY,
        trigger_mode=mode,
        is_recording=recording,
        can_start_recording=can_start,
    )


def test_toggle_starts_and_stops() -> None:
    machine = _machine()
    first = _feed(machine, VK_RCONTROL, True, MOD_CTRL)
    _check("toggle: first press starts", first.actions, [Action.PRESS])
    _check("toggle: press is suppressed", first.suppress, True)

    _feed(machine, VK_RCONTROL, False, 0, recording=True)
    second = _feed(machine, VK_RCONTROL, True, MOD_CTRL, recording=True)
    _check("toggle: second press stops", second.actions, [Action.RELEASE])


def test_toggle_does_not_flip_when_busy() -> None:
    machine = _machine()
    busy = _feed(machine, VK_RCONTROL, True, MOD_CTRL, can_start=False)
    _check("toggle: busy press is rejected", busy.actions, [Action.REJECTED_BUSY_PRESS])
    _feed(machine, VK_RCONTROL, False, 0, can_start=False)
    # The rejected press must not have flipped the toggle, so the next
    # press still starts rather than emitting a discarded release.
    ready = _feed(machine, VK_RCONTROL, True, MOD_CTRL)
    _check("toggle: next press still starts", ready.actions, [Action.PRESS])


def test_hold_press_and_release() -> None:
    machine = _machine()
    press = _feed(machine, VK_RCONTROL, True, MOD_CTRL, mode=TriggerMode.HOLD)
    _check("hold: press", press.actions, [Action.PRESS])
    release = _feed(machine, VK_RCONTROL, False, 0, mode=TriggerMode.HOLD, recording=True)
    _check("hold: release", release.actions, [Action.RELEASE])


def test_left_control_does_not_trigger() -> None:
    machine = _machine()
    result = _feed(machine, VK_LCONTROL, True, MOD_CTRL)
    _check("left control passes through", (result.suppress, result.actions), (False, []))


def test_history_chord() -> None:
    """Shift + Right Ctrl opens the history without starting a dictation.

    The chord is built on the dictation key itself, so the order matters:
    with Shift already down the chord is recognised on the Right Ctrl
    press and eats it, and no recording begins. Hands take "Shift + X" in
    that order without being asked, which is why this shortcut works and
    the old "Ctrl + Alt" one did not.
    """
    machine = _machine()
    shift = _feed(machine, VK_RSHIFT, True, MOD_SHIFT)
    _check("history: shift itself reaches the app", shift.suppress, False)
    chord = _feed(machine, VK_RCONTROL, True, MOD_SHIFT | MOD_CTRL)
    _check("history: chord opens the history", chord.actions,
           [Action.SHOW_HISTORY])
    _check("history: no dictation starts", Action.PRESS in chord.actions, False)
    _check("history: right ctrl is swallowed", chord.suppress, True)

    machine = _machine()
    _check("history: bare right ctrl still dictates",
           _feed(machine, VK_RCONTROL, True, MOD_CTRL).actions, [Action.PRESS])


def test_edit_chord() -> None:
    """Shift + Right Alt opens the editor, whichever key is pressed first.

    Regression: the editor shortcut was first built on Right Ctrl, the
    dictation key itself. Pressing Ctrl before Alt — the order most hands
    take "Ctrl+Alt" — started a recording on the way in and then let the
    Alt complete a chord whose primary key had already fired. A shortcut
    whose primary key does nothing on its own has no such order.
    """
    machine = _machine()
    shift = _feed(machine, VK_RSHIFT, True, MOD_SHIFT)
    _check("edit: shift itself reaches the app", shift.suppress, False)
    chord = _feed(machine, VK_RMENU, True, MOD_SHIFT | MOD_ALT)
    _check("edit: shift first opens the editor", chord.actions, [Action.SHOW_EDITOR])
    _check("edit: chord primary is suppressed", chord.suppress, True)

    machine = _machine()
    alt = _feed(machine, VK_RMENU, True, MOD_ALT)
    _check("edit: right alt alone does nothing", alt.actions, [])
    _check("edit: alt first opens the editor",
           _feed(machine, VK_RSHIFT, True, MOD_SHIFT | MOD_ALT).actions,
           [Action.SHOW_EDITOR])

    machine = _machine()
    _check("edit: bare right ctrl still dictates",
           _feed(machine, VK_RCONTROL, True, MOD_CTRL).actions, [Action.PRESS])
    _check("edit: alt added to a running dictation changes nothing",
           _feed(machine, VK_RMENU, True, MOD_CTRL | MOD_ALT,
                 recording=True).actions, [])


def test_escape_cancels_only_while_recording() -> None:
    machine = _machine()
    idle = _feed(machine, VK_ESCAPE, True, 0)
    _check("escape: passes through when idle", (idle.suppress, idle.actions), (False, []))

    machine = _machine()
    active = _feed(machine, VK_ESCAPE, True, 0, recording=True)
    _check("escape: cancels while recording", active.actions, [Action.CANCEL])


def test_modifiers_are_never_swallowed() -> None:
    """Regression: the editor chord must not cost the user the Shift key.

    The editor is "Shift + Right Alt", so Shift belongs to a shortcut,
    but suppressing it would break capital letters and Shift-click
    everywhere until the app quits. Only the chord's primary key may be
    eaten.
    """
    from .hotkeys import VK_LSHIFT

    for name, vk, mask in (("left shift", VK_LSHIFT, MOD_SHIFT),
                           ("right shift", VK_RSHIFT, MOD_SHIFT),
                           ("left alt", VK_LMENU, MOD_ALT)):
        machine = _machine()
        down = _feed(machine, vk, True, mask)
        _check(f"{name} down reaches the app", down.suppress, False)
        up = _feed(machine, vk, False, 0)
        _check(f"{name} up reaches the app", up.suppress, False)

    # Even mid-chord: Shift goes through, only Right Alt is eaten.
    machine = _machine()
    shift = _feed(machine, VK_RSHIFT, True, MOD_SHIFT)
    _check("shift before the chord passes", shift.suppress, False)
    chord = _feed(machine, VK_RMENU, True, MOD_SHIFT | MOD_ALT)
    _check("chord primary is suppressed", chord.suppress, True)
    _check("chord opens the editor", chord.actions, [Action.SHOW_EDITOR])
    release = _feed(machine, VK_RSHIFT, False, 0)
    _check("shift release still reaches the app", release.suppress, False)


def test_altgr_phantom_ctrl() -> None:
    """Regression: on the Russian layout Right Alt recorded as "Ctrl + Alt".

    An AltGr layout sends a Left Ctrl with scan code 0x21D in front of
    every Right Alt. It must not count as held, or a bare Right Alt
    shortcut works in English and not in Russian.
    """
    from .hotkeys import (ALTGR_PHANTOM_SCAN, held_modifier_mask,
                          is_altgr_phantom, is_altgr_phantom_time,
                          note_altgr_phantom_time)

    _check("phantom: 0x21D left ctrl", is_altgr_phantom(VK_LCONTROL, ALTGR_PHANTOM_SCAN), True)
    _check("phantom: a real left ctrl is not", is_altgr_phantom(VK_LCONTROL, 0x1D), False)
    _check("phantom: right alt is not", is_altgr_phantom(VK_RMENU, 0x38), False)

    # Windows reports both Left Ctrl and Right Alt as held.
    os_state = {VK_LCONTROL, VK_RMENU}.__contains__
    _check("phantom: right alt alone",
           held_modifier_mask(os_state, phantom_ctrl_down=True, real_lctrl_down=False),
           MOD_ALT)
    _check("phantom: a real ctrl held as well still counts",
           held_modifier_mask(os_state, phantom_ctrl_down=True, real_lctrl_down=True),
           MOD_CTRL | MOD_ALT)
    _check("phantom: without one, windows is believed",
           held_modifier_mask(os_state, phantom_ctrl_down=False, real_lctrl_down=False),
           MOD_CTRL | MOD_ALT)

    press = _machine().transition(
        _Event(vk=VK_RMENU, is_down=True,
               modifiers=held_modifier_mask(os_state, phantom_ctrl_down=True,
                                            real_lctrl_down=False)),
        hotkey=HotkeyChoice(VK_RMENU), history_hotkey=HISTORY_HOTKEY,
        edit_hotkey=EDIT_HOTKEY, trigger_mode=TriggerMode.TOGGLE, is_recording=False)
    _check("phantom: right alt shortcut starts on an altgr layout",
           press.actions, [Action.PRESS])

    note_altgr_phantom_time(123456)
    _check("phantom: recorder recognises its timestamp", is_altgr_phantom_time(123456), True)
    _check("phantom: other timestamps are real", is_altgr_phantom_time(123457), False)


# -- transcript processing ------------------------------------------------


def test_unk_repair() -> None:
    _check("unk: russian yo", repair_model_text("ещ<unk>", "ru"), "ещё")
    _check("unk: capital after sentence end",
           repair_model_text("Да. <unk>лка", "ru"), "Да. Ёлка")
    _check("unk: dropped for latin languages",
           repair_model_text("hello <unk> world", "en"), "hello world")


def test_corrections() -> None:
    corrections = [Correction("гит хаб", "GitHub"), Correction("гит", "git")]
    text, count = apply_corrections("открой гит хаб и гит статус", corrections)
    _check("corrections: longest match wins", text, "открой GitHub и git статус")
    _check("corrections: count", count, 2)

    text, _ = apply_corrections("подгитовка", corrections)
    _check("corrections: respects word boundaries", text, "подгитовка")


def test_learned_corrections() -> None:
    """What a hand-corrected transcript is allowed to teach the dictionary."""
    _check("learned: one word out of several",
           learned_corrections("поставь чайник на плиту",
                               "поставь чайник на плите"),
           [("плиту", "плите")])
    # Different lengths on the two sides are kept whole: splitting them
    # would invent two rules neither of which is what the user meant.
    _check("learned: one word split into two",
           learned_corrections("немного текста", "не много текста"),
           [("немного", "не много")])
    _check("learned: case alone is not a misrecognition",
           learned_corrections("привет мир", "Привет мир"), [])
    _check("learned: punctuation alone is not either",
           learned_corrections("привет, мир", "привет мир"), [])
    # A word with nothing to pair it with cannot become a rule: the
    # dictionary has no way to express "replace this with nothing".
    _check("learned: a deletion teaches nothing",
           learned_corrections("это очень хорошо", "это хорошо"), [])
    _check("learned: an insertion teaches nothing",
           learned_corrections("это хорошо", "это очень хорошо"), [])
    _check("learned: an untouched transcript teaches nothing",
           learned_corrections("всё верно", "всё верно"), [])


def test_filler_removal() -> None:
    text, count = remove_filler_words("Um, hello uh world.")
    _check("fillers: removed and repunctuated", text, "Hello world.")
    _check("fillers: count", count, 2)

    text, _ = remove_filler_words("I did err on the side of caution")
    _check("fillers: 'err' survives", text, "I did err on the side of caution")

    text, _ = remove_filler_words("uh-huh, sure")
    _check("fillers: hyphenated interjections survive", text, "uh-huh, sure")


def test_text_style() -> None:
    _check("style: formal keeps everything",
           apply_text_style("Привет, мир.", TextStyle.FORMAL), "Привет, мир.")
    _check("style: standard drops the final stop",
           apply_text_style("Привет, мир.", TextStyle.STANDARD), "Привет, мир")
    _check("style: informal also lowercases",
           apply_text_style("Привет, мир.", TextStyle.INFORMAL), "привет, мир")

    # A question or an exclamation carries meaning a full stop does not,
    # so only the full stop is dropped.
    _check("style: question mark survives",
           apply_text_style("Как дела?", TextStyle.STANDARD), "Как дела?")
    _check("style: ellipsis survives",
           apply_text_style("Ну...", TextStyle.STANDARD), "Ну...")
    # An acronym would lose its meaning in lower case.
    _check("style: acronyms keep their case",
           apply_text_style("HTTP работает.", TextStyle.INFORMAL), "HTTP работает")
    _check("style: empty text is safe",
           apply_text_style("", TextStyle.INFORMAL), "")
    # A one-letter opening word is not an acronym. The old two-character
    # test counted the following space as upper case and kept the capital.
    _check("style: one-letter word still lowercases",
           apply_text_style("Я думаю.", TextStyle.INFORMAL), "я думаю")


def test_casual_style() -> None:
    _check("casual: inner stops become commas",
           apply_text_style("Первое. Второе. Третье.", TextStyle.CASUAL),
           "первое, второе, третье")
    # The scan must not swallow the stop that ends the word it just read.
    _check("casual: every stop is converted, not every other one",
           apply_text_style("А. Б. В. Г.", TextStyle.CASUAL), "а, б, в, г")
    _check("casual: a question mark keeps its tone but loses the capital",
           apply_text_style("Как дела? Всё хорошо.", TextStyle.CASUAL),
           "как дела? всё хорошо")
    _check("casual: an ellipsis is not a sentence break",
           apply_text_style("Ну... ладно.", TextStyle.CASUAL), "ну... ладно")
    _check("casual: acronyms survive the pass",
           apply_text_style("Это HTTP. HTTP работает.", TextStyle.CASUAL),
           "это HTTP, HTTP работает")
    # No capitals at all, not just none after a full stop: the model
    # capitalises for reasons of its own, and mid-sentence ones survived
    # a pass that only looked at sentence starts.
    _check("casual: a capital after a comma also goes",
           apply_text_style("Привет, Как дела?", TextStyle.CASUAL),
           "привет, как дела?")
    _check("casual: proper nouns are lowered too",
           apply_text_style("Вчера Москва не спала.", TextStyle.CASUAL),
           "вчера москва не спала")


def test_numbers_as_digits() -> None:
    _check("digits: a unit", numbers_as_digits("дай два", "ru"), "дай 2")
    _check("digits: tens plus units",
           numbers_as_digits("двадцать три", "ru"), "23")
    _check("digits: three places",
           numbers_as_digits("сто двадцать три", "ru"), "123")
    _check("digits: hundreds straight to units",
           numbers_as_digits("двести пять", "ru"), "205")
    _check("digits: a teen absorbs nothing after it",
           numbers_as_digits("пятнадцать пять", "ru"), "15 5")
    _check("digits: feminine and neuter forms",
           numbers_as_digits("одна две одно", "ru"), "1 2 1")
    # Only the nominative is converted. "Из двух часов" would become
    # "из 2 часов", which is not how anyone writes it.
    _check("digits: oblique cases are left as words",
           numbers_as_digits("из двух часов", "ru"), "из двух часов")
    _check("digits: equal places stay apart, as in a dictated code",
           numbers_as_digits("два три", "ru"), "2 3")
    _check("digits: punctuation separates numbers",
           numbers_as_digits("двадцать, три", "ru"), "20, 3")
    _check("digits: english",
           numbers_as_digits("twenty three files", "en"), "23 files")
    _check("digits: words that are not numerals are untouched",
           numbers_as_digits("привет мир", "ru"), "привет мир")


def test_pipeline_order() -> None:
    # An explicit correction must win over filler stripping.
    text, applied, removed = process_transcript(
        "um, ГитХаб",
        language="ru",
        corrections=[Correction("ГитХаб", "GitHub")],
        strip_fillers=True,
    )
    _check("pipeline: correction applied", "GitHub" in text, True)
    _check("pipeline: filler removed", removed, 1)
    _check("pipeline: correction counted", applied, 1)


# -- settings round trip --------------------------------------------------


def test_settings_round_trip() -> None:
    from .settings import Settings

    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "Settings.json"
        settings = Settings(path)
        settings.apply({
            "hotkey": HotkeyChoice(VK_RSHIFT, MOD_CTRL).to_json(),
            "enter_delay_milliseconds": 9000,   # out of range, must clamp
            "interface_language": "en",
            "unknown_key": "ignored",
        })

        reloaded = Settings(path)
        _check("settings: hotkey persisted", reloaded.hotkey,
               HotkeyChoice(VK_RSHIFT, MOD_CTRL))
        _check("settings: enter delay clamped", reloaded.enter_delay_milliseconds, 500)
        _check("settings: language persisted", reloaded.interface_language, "en")
        _check("settings: unknown keys dropped",
               "unknown_key" in reloaded.snapshot(), False)


def test_hud_timer_default() -> None:
    """The timer is the default, and installs from before it move once."""
    import json

    from .settings import HUDDisplayMode, Settings

    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "Settings.json"
        _check("timer: fresh install", Settings(path).hud_display_mode,
               HUDDisplayMode.TIMER_OUTLINE)

        path.write_text(json.dumps({"hud_display_mode": "levelBars"}), encoding="utf-8")
        migrated = Settings(path)
        _check("timer: 0.8.0 settings move over", migrated.hud_display_mode,
               HUDDisplayMode.TIMER_OUTLINE)

        migrated.apply({"hud_display_mode": "levelBars"})
        _check("timer: bars chosen afterwards stick", Settings(path).hud_display_mode,
               HUDDisplayMode.LEVEL_BARS)


def test_hotkey_json_guards() -> None:
    fallback = HotkeyChoice(VK_RCONTROL)
    _check("hotkey json: escape rejected",
           HotkeyChoice.from_json({"vk": VK_ESCAPE}, fallback), fallback)
    _check("hotkey json: garbage rejected",
           HotkeyChoice.from_json("nonsense", fallback), fallback)
    _check("hotkey json: self-modifier stripped",
           HotkeyChoice.from_json({"vk": VK_RCONTROL, "modifiers": MOD_CTRL}, fallback),
           HotkeyChoice(VK_RCONTROL, 0))


def test_filler_word_list() -> None:
    from .settings import DEFAULT_FILLER_WORDS

    text, count = remove_filler_words("Эм, привет. Ээ, как дела?",
                                      DEFAULT_FILLER_WORDS)
    _check("fillers: russian hesitations removed", text, "Привет. Как дела?")
    _check("fillers: russian count", count, 2)

    # The whole point of the word boundaries: "эм" inside "Эмма" is not a
    # hesitation, and a chosen word must not eat the words around it.
    _check("fillers: inside a word is left alone",
           remove_filler_words("Эмма пришла к маме", DEFAULT_FILLER_WORDS)[0],
           "Эмма пришла к маме")

    text, _ = remove_filler_words("Ну это самое, короче, я пошёл",
                                  ("ну", "это самое", "короче"))
    _check("fillers: longest phrase wins", text, "Я пошёл")

    _check("fillers: nothing chosen removes nothing",
           remove_filler_words("Ну, эм, ладно", ()),
           ("Ну, эм, ладно", 0))

    _check("fillers: a word not on the list stays",
           remove_filler_words("Короче, ладно", DEFAULT_FILLER_WORDS)[0],
           "Короче, ладно")


def test_compact_numbers() -> None:
    from . import i18n
    from .ui.stats import compact

    previous = i18n.language()
    try:
        i18n.set_language("ru")
        _check("compact: below a thousand is left alone", compact(999), "999")
        _check("compact: exact thousand", compact(1000), "1К")
        _check("compact: decimal below ten", compact(1590), "1,5К")
        _check("compact: no decimal past ten", compact(12345), "12К")
        # Rounding up here would read as "1000К" instead of "1М".
        _check("compact: rounds down at the boundary", compact(999999), "999К")
        _check("compact: millions", compact(1250000), "1,2М")
        i18n.set_language("en")
        _check("compact: latin suffix and point", compact(1590), "1.5K")
    finally:
        i18n.set_language(previous)


def test_autostart_starts_in_the_tray() -> None:
    """The one thing the login entry must say, besides the path.

    Without the flag an autostarted copy opens its window over whatever
    the user logged in to do, and the bug is invisible until the next
    reboot — worth a test rather than a second discovery.
    """
    from .system import _launch_command

    command = _launch_command()
    _check("autostart: launches minimized", command.endswith(" --minimized"), True)
    _check("autostart: executable is quoted", command.startswith('"'), True)


def test_autostart_target_parsing() -> None:
    """Which executable an existing Run entry names.

    Read wrong, a stale entry either never gets repaired or gets
    repaired when it should have been left alone.
    """
    from .system import _autostart_target

    _check("autostart target: quoted path with a flag",
           _autostart_target(r'"C:\Program Files\D1CT\Dictation.exe" --minimized'),
           r"C:\Program Files\D1CT\Dictation.exe")
    _check("autostart target: quoted path alone",
           _autostart_target(r'"C:\Apps\Dictation.exe"'), r"C:\Apps\Dictation.exe")
    _check("autostart target: unquoted",
           _autostart_target(r"C:\Apps\Dictation.exe --minimized"),
           r"C:\Apps\Dictation.exe")


# -- runner ---------------------------------------------------------------

# -- LLM correction guardrail --------------------------------------------
#
# The bundled corrector drops the input's leading word now and then, rarely
# hallucinates a term, and deletes fillers by design. The cases live in
# fixtures/llm-correction-guardrail.json, shared with the macOS suite, so
# the two guardrails cannot drift apart: a divergence here is a port bug.

def _guardrail_fixture():
    import json
    from pathlib import Path

    path = Path(__file__).resolve().parents[2] / "fixtures" / "llm-correction-guardrail.json"
    if not path.is_file():
        _failures.append(f"guardrail fixture missing: {path} (run the self-test from a checkout)")
        return None
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def test_correction_guardrail() -> None:
    from .llm.guardrail import (MODEL_REMOVED_FILLERS, preserves_word_count,
                                sanitized_correction)

    fixture = _guardrail_fixture()
    if fixture is None:
        return
    _check("the filler list matches the shared fixture",
           list(MODEL_REMOVED_FILLERS), fixture["model_removed_fillers"])
    for case in fixture["cases"]:
        expected = case["output"].strip() if case["expect"] == "accept" else case["input"]
        _check(f"guardrail {case['expect']}s {case['input']!r} ({case['why']})",
               sanitized_correction(case["input"], case["output"]), expected)
    for case in fixture["word_count"]:
        text_in = " ".join(f"слово{n}" for n in range(case["input_words"]))
        text_out = " ".join(f"слово{n}" for n in range(case["output_words"]))
        _check(f"word count {case['input_words']} → {case['output_words']} ({case['why']})",
               preserves_word_count(text_in, text_out), case["expect"] == "accept")


def test_correction_chunks() -> None:
    from .llm.guardrail import correction_chunks

    _check("short text is one chunk", correction_chunks(" привет. "), ["привет."])
    _check("empty text is no chunks", correction_chunks("  "), [])
    sentence = "Это предложение средней длины для проверки разбиения. "
    text = (sentence * 30).strip()
    chunks = correction_chunks(text)
    _check("long text is split", len(chunks) > 1, True)
    _check("every chunk fits", all(len(c) <= 500 for c in chunks), True)
    _check("chunks end on sentences", all(c.endswith(".") for c in chunks), True)
    _check("joining restores the text", " ".join(chunks), text)
    run_on = " ".join(["слово"] * 300)
    pieces = correction_chunks(run_on)
    _check("an over-long sentence is cut at spaces",
           all(len(c) <= 500 for c in pieces) and " ".join(pieces) == run_on, True)


# -- vocabulary -----------------------------------------------------------

def test_learn_candidate() -> None:
    from .vocabulary import learn_candidate

    def pair(inserted, edited):
        found = learn_candidate(inserted, edited)
        return (found.source, found.replacement) if found else None

    _check("word swap is learnable",
           pair("залей на гитхаб", "залей на GitHub"), ("гитхаб", "GitHub"))
    _check("mid-sentence swap is learnable",
           pair("поставил дебиан вчера", "поставил Debian вчера"),
           ("дебиан", "Debian"))
    # Deletions teach nothing: somebody who removes a word and pauses to
    # think must not get the half-finished edit learned as a rule.
    _check("non-contiguous deletion is not learnable",
           pair("это очень длинное слово", "это длинное"), None)
    _check("intra-word trim is not learnable",
           pair("инглиш перевод", "глиш перевод"), None)
    _check("casing-only touch-up is not learnable",
           pair("Инглиш перевод", "инглиш перевод"), None)
    _check("an over-long span is prose editing, not vocabulary",
           pair("а б в г д е", "а б X Y Z W д е"), None)
    _check("unchanged text is not learnable",
           pair("привет мир", "привет мир"), None)


def test_vocabulary_store() -> None:
    import os
    import tempfile

    from .vocabulary import Origin, VocabularyStore

    path = tempfile.mktemp(suffix=".sqlite")
    store = VocabularyStore(path)
    try:
        store.upsert("гитхаб", "GitHub", Origin.LEARNED)
        store.upsert("дебиан", "Debian")
        # A second correction of the same word is the user changing their
        # mind, not a second rule — and the match has to be Unicode-aware,
        # which SQLite's own NOCASE collation is not for Cyrillic.
        store.upsert("ГИТХАБ", "GitHub Enterprise")
        _check("case-insensitive upsert does not duplicate", store.count(), 2)
        _check("upsert rewrites in place",
               store.find("гитхаб").replacement, "GitHub Enterprise")

        written = store.learn([("кубернетис", "Kubernetes")])
        _check("learn reports what it wrote", len(written), 1)
        _check("learned rules are marked as such",
               written[0].origin, Origin.LEARNED)
        # The undo path the learned toast calls.
        _check("undo removes the rule", store.delete_source("Кубернетис"), True)
        _check("count after undo", store.count(), 2)

        _check("export shape matches the macOS sync file",
               store.export_json()[0].keys() | set(), {"source", "replacement"})
    finally:
        store.close()
        try:
            os.unlink(path)
        except OSError:
            pass


# -- HUD timer ------------------------------------------------------------

def test_hud_elapsed_format() -> None:
    """MM:SS, and never a negative or a rolled-over hour field."""
    from .ui.hud import format_elapsed

    _check("zero", format_elapsed(0), "00:00")
    _check("seconds pad", format_elapsed(9), "00:09")
    _check("minutes", format_elapsed(65), "01:05")
    _check("ten minutes", format_elapsed(600), "10:00")
    # Past an hour the macOS readout keeps counting minutes rather than
    # growing an hours field, and so does this one.
    _check("beyond an hour", format_elapsed(3661), "61:01")
    _check("negative clamps", format_elapsed(-5), "00:00")


def test_hud_timer_activation() -> None:
    """The timer must not appear before the dictation is worth timing.

    Pure arithmetic on the blend curve: a capsule that flipped to a clock
    instantly would turn every two-second dictation into a stopwatch. Ten
    seconds and a half-second crossover, as on macOS.
    """
    from .ui.hud import timer_blend

    _check("bars at the start", timer_blend(0.0), 0.0)
    _check("still bars at nine seconds", timer_blend(9.0), 0.0)
    _check("still bars at the threshold", timer_blend(10.0), 0.0)
    _check("fully timer once the crossover is done", timer_blend(10.5), 1.0)
    _check("crossover is under way midway", 0.2 < timer_blend(10.25) < 0.8, True)


def test_hud_phase_speeds() -> None:
    """recordingHUDPhaseSpeed, constant for constant."""
    from .ui.hud import phase_speed

    _check("recording at rest", round(phase_speed("recording", 0.0), 2), 16.96)
    _check("recording at full voice", round(phase_speed("recording", 1.0), 2), 27.04)
    _check("transcribing", phase_speed("transcribing", 0.7), 10.2)
    _check("correcting", phase_speed("correcting", 0.0), 6.4)
    _check("error is still", phase_speed("error", 1.0), 0.0)


def test_hud_outline_path() -> None:
    """The timer's lit outline: nothing at 0, both sides, all of it at 1."""
    from PySide6.QtCore import QRectF

    from .ui.hud import outline_fill_path

    capsule = QRectF(0, 0, 80, 40)
    _check("empty at zero", outline_fill_path(capsule, 0.0).length() < 0.01, True)
    half = outline_fill_path(capsule, 0.5).length()
    full_perimeter = 2 * (80 - 40) + 3.14159 * 40
    _check("half lights half the perimeter",
           abs(half - full_perimeter / 2) < 1.5, True)
    bounds = outline_fill_path(capsule, 0.25).boundingRect()
    _check("grows symmetrically from the bottom centre",
           abs((bounds.left() + bounds.right()) / 2 - 40) < 0.5, True)
    _check("starts at the bottom", abs(bounds.bottom() - 40) < 0.5, True)


def test_contrast_color() -> None:
    """``contrast`` stays symbolic and resolves against the background."""
    from .settings import AccentColor, ColorSpec

    spec = ColorSpec.parse("contrast", ColorSpec.of(AccentColor.RED))
    _check("parsed as contrast", spec.is_contrast, True)
    _check("round-trips", spec.to_json(), "contrast")
    _check("black on light", spec.resolved(True).start, "#000000")
    _check("white on dark", spec.resolved(False).start, "#ffffff")
    plain = ColorSpec.of(AccentColor.RED)
    _check("other colours ignore the background",
           plain.resolved(True).start, plain.start)


def test_caret_geometry() -> None:
    """FocusedInsertionTargetLocator's rules for what counts as a caret."""
    from .focus_target import (
        Rect, is_reasonable_field, normalized_caret, usable_target, visual_frame)

    area = Rect(0, 0, 1920, 1040)
    _check("a zero-width caret gets a width",
           normalized_caret(Rect(100, 200, 0, 18)), Rect(100, 200, 2, 18))
    _check("a collapsed caret is no caret",
           normalized_caret(Rect(0, 0, 0, 0)), None)
    _check("a selection is not a caret",
           normalized_caret(Rect(100, 200, 300, 18)), None)
    _check("a whole field is not a caret",
           normalized_caret(Rect(100, 200, 10, 400)), None)

    caret = Rect(300, 500, 2, 18)
    field = Rect(250, 480, 600, 60)
    _check("a single-line field is anchored as a whole",
           visual_frame(field, caret, area), field)
    page = Rect(200, 100, 1200, 800)
    _check("a page-sized field is anchored on the caret's line",
           visual_frame(page, caret, area), Rect(200, 500, 1200, 18))
    _check("a field around the caret is reasonable",
           is_reasonable_field(field, caret, area), True)
    _check("a field away from the caret is not",
           is_reasonable_field(Rect(900, 900, 100, 30), caret, area), False)
    _check("a full-screen pane is not",
           is_reasonable_field(Rect(0, 0, 1900, 1000), caret, area), False)
    _check("a full-screen frame is not a HUD target",
           usable_target(Rect(0, 0, 1900, 900), area), False)
    _check("a line is",
           usable_target(Rect(200, 500, 1200, 18), area), True)


def test_target_stabilizer() -> None:
    """RecordingHUDTargetStabilizer: believe the start app, doubt blips."""
    from .focus_target import Rect, TargetFrame, TargetIdentity, TargetStabilizer

    def frame(pid: int, element: int) -> TargetFrame:
        rect = Rect(10, 10, 2, 16)
        return TargetFrame(rect, rect, "test", TargetIdentity(pid, 1, (element,)))

    stabilizer = TargetStabilizer()
    stabilizer.reset(100)
    _check("the starting app is believed at once",
           stabilizer.observe(frame(100, 1))[0], "switch")
    _check("then just followed", stabilizer.observe(frame(100, 1))[0], "update")
    _check("another field of the same app needs a second look",
           stabilizer.observe(frame(100, 2))[0], "none")
    _check("and gets it", stabilizer.observe(frame(100, 2))[0], "switch")
    _check("another app needs three",
           [stabilizer.observe(frame(200, 9))[0] for _ in range(3)],
           ["none", "none", "switch"])
    _check("a blip resets the count",
           [stabilizer.observe(t)[0] for t in (frame(300, 1), None, frame(300, 1))],
           ["none", "none", "none"])

    other = TargetStabilizer()
    other.reset(100)
    _check("a different app at the start is doubted too",
           other.observe(frame(555, 1))[0], "none")


# -- post-processing shortcuts --------------------------------------------

def test_postprocessing_chords() -> None:
    """The three post-processing chords reach their actions, and only them.

    The defaults deliberately avoid the right-hand modifiers the dictation,
    history and editor shortcuts are built on; an earlier draft put them
    there and this test caught the collision — Right Alt with Ctrl held,
    added to a running dictation, started firing the rewrite toggle.
    """
    from .hotkeys import (DEFAULT_CORRECTION_HOTKEY, DEFAULT_REWRITE_HOTKEY,
                          DEFAULT_REWRITE_STYLE_HOTKEY)

    # Modifier keys go down first, in the order a hand actually presses
    # them, then the chord's own key. _feed's defaults already carry the
    # dictation/history/edit shortcuts, so this exercises the real
    # precedence between all six.
    _MOD_KEYS = ((MOD_SHIFT, VK_RSHIFT), (MOD_CTRL, VK_RCONTROL),
                 (MOD_ALT, VK_RMENU))

    def press(shortcut):
        machine = _machine()
        held = 0
        for flag, vk in _MOD_KEYS:
            if shortcut.modifiers & flag:
                held |= flag
                _feed(machine, vk, True, held)
        result = _feed(machine, shortcut.vk, True, held)
        return list(result.actions)

    _check("correction chord toggles correction",
           press(DEFAULT_CORRECTION_HOTKEY), [Action.TOGGLE_CORRECTION])
    _check("rewrite chord toggles rewrite",
           press(DEFAULT_REWRITE_HOTKEY), [Action.TOGGLE_REWRITE])
    _check("style chord reaches the style action",
           press(DEFAULT_REWRITE_STYLE_HOTKEY), [Action.CYCLE_REWRITE_STYLE])
    # And none of them may start a dictation.
    for shortcut in (DEFAULT_CORRECTION_HOTKEY, DEFAULT_REWRITE_HOTKEY,
                     DEFAULT_REWRITE_STYLE_HOTKEY):
        _check(f"{shortcut.to_json()} never records",
               Action.PRESS in press(shortcut), False)


# -- long-dictation path --------------------------------------------------

def _sine(seconds: float, sample_rate: int = 16000, amplitude: float = 0.2):
    import numpy as np

    n = int(seconds * sample_rate)
    return (amplitude * np.sin(2 * np.pi * 220 * np.arange(n) / sample_rate)
            ).astype(np.float32)


def _quiet(seconds: float, sample_rate: int = 16000):
    import numpy as np

    return np.zeros(int(seconds * sample_rate), dtype=np.float32)


def test_pause_segmentation() -> None:
    """Ordinary dictations must not be cut; long ones must be, at pauses."""
    import numpy as np

    from .segmentation import segment

    SR = 16000
    # The single most important case: two sentences with a breath between
    # them go through as ONE segment, exactly as if segmentation did not
    # exist. Cutting here would reintroduce the clause-splitting punctuation
    # damage that fixed-size chunking was rejected for.
    short = np.concatenate([_sine(3), _quiet(0.6), _sine(4)])
    _check("a short dictation is not cut", len(segment(short, SR)), 1)

    long_one = np.concatenate([_sine(18), _quiet(0.6), _sine(6)])
    segments = segment(long_one, SR)
    _check("a long dictation is cut at its pause", len(segments), 2)
    _check("the cut lands at the start of the pause",
           segments[0].end_sample, 18 * SR)

    # No pause at all: the safety cap still has to bound the segment length,
    # or one unbroken run reaches the encoder's expensive regime.
    capped = segment(_sine(60), SR)
    _check("unbroken speech is capped",
           max(len(item.samples) for item in capped) <= 25 * SR, True)

    _check("silence carries no signal",
           [item.has_signal for item in segment(_quiet(5), SR)], [False])

    # Segments must tile the input exactly: no gap, no overlap, nothing lost.
    pieces = segment(np.concatenate(
        [_sine(18), _quiet(0.6), _sine(6), _quiet(0.5), _sine(20)]), SR)
    _check("segments are contiguous",
           all(pieces[i].end_sample == pieces[i + 1].start_sample
               for i in range(len(pieces) - 1)), True)


def test_overlap_windows() -> None:
    """Overlap is carved out of the cap, never added on top."""
    import numpy as np

    from .overlap import add_overlap
    from .segmentation import AudioSegment

    SR = 16000
    segments = [
        AudioSegment(_sine(20), True, 0),
        AudioSegment(_sine(20), True, 20 * SR),
        AudioSegment(_sine(20), True, 40 * SR),
    ]
    windows = add_overlap(segments, SR, overlap_seconds=4.0,
                          max_segment_seconds=25.0)
    _check("one window per segment", len(windows), 3)
    # 20 s of own audio against a 25 s cap leaves 5 s of budget, split
    # between the two sides — so 2.5 s each way, NOT the 4 s requested.
    _check("borrowed audio stays inside the cap",
           all(len(w.samples) <= 25 * SR for w in windows), True)
    _check("the first window borrows nothing on its left",
           windows[0].start_sample, 0)
    _check("the last window borrows nothing on its right",
           windows[-1].start_sample + len(windows[-1].samples), 60 * SR)
    _check("owned spans still tile the recording",
           [(w.owned_start, w.owned_end) for w in windows],
           [(0, 20 * SR), (20 * SR, 40 * SR), (40 * SR, 60 * SR)])

    # A single segment must come through completely untouched.
    single = add_overlap([AudioSegment(_sine(5), True, 0)], SR)
    _check("a single segment gets no overlap",
           len(single[0].samples), len(_sine(5)))


def test_seam_dedup() -> None:
    """The earlier window wins, and only across the seam."""
    from .overlap import AbsoluteWord, dedup_across_seam

    earlier = [AbsoluteWord("страна", 9.6), AbsoluteWord("может", 9.9),
               AbsoluteWord("сделать", 10.2)]
    # The later window re-emitted "сделать" at almost the same moment.
    candidates = [AbsoluteWord("сделать", 10.25), AbsoluteWord("для", 10.6)]
    survivors = dedup_across_seam(earlier, candidates, tolerance_seconds=0.24)
    _check("the duplicate is dropped", [w.text for w in survivors], ["для"])

    # Different text at the same instant is a collision, not a coincidence:
    # the earlier window's decoder had more context, so it still wins.
    collision = dedup_across_seam(earlier,
                                  [AbsoluteWord("зделать", 10.21)],
                                  tolerance_seconds=0.24)
    _check("a collision resolves in favour of the earlier window",
           collision, [])

    # Far enough apart is always kept, whatever it says.
    far = dedup_across_seam(earlier, [AbsoluteWord("сделать", 11.5)],
                            tolerance_seconds=0.24)
    _check("a word past the tolerance survives", len(far), 1)

    # With nothing on the earlier side there is nothing to collide with.
    _check("no references means nothing is dropped",
           len(dedup_across_seam([], candidates)), 2)


def test_words_from_tokens() -> None:
    """Sub-word pieces become words carrying the first piece's timestamp."""
    from .overlap import words_from_tokens

    tokens = [" And", " so", ",", " my", " f", "ell", "ow", " Amer", "icans"]
    stamps = [0.24, 0.56, 0.80, 0.96, 1.20, 1.36, 1.52, 1.68, 1.84]
    words = words_from_tokens(tokens, stamps)
    _check("pieces are joined into words",
           [w.text for w in words], ["And", "so,", "my", "fellow", "Americans"])
    _check("a word starts when its first piece did",
           [w.start for w in words], [0.24, 0.56, 0.96, 1.20, 1.68])
    _check("empty input gives no words", words_from_tokens([], []), [])


def test_boundary_oracles() -> None:
    """Each link answers, declines, or is overruled — and the chain never fails."""
    import numpy as np

    from .boundary import (MelEnergyBoundaryOracle, MidpointBoundaryOracle,
                           VadBoundaryOracle, chain)

    SR = 16000
    # A zone that is loud, then quiet, then loud: the split belongs in the
    # quiet part.
    zone = np.concatenate([_sine(1.0), _quiet(1.0), _sine(1.0)])
    mel = MelEnergyBoundaryOracle()
    split = mel.choose_split(zone, 0, len(zone), SR)
    _check("mel energy picks the quiet stretch",
           SR <= split <= 2 * SR, True)

    _check("midpoint always answers",
           MidpointBoundaryOracle().choose_split(zone, 100, 300, SR), 200)

    class _Silent:
        """A VAD that hears silence in the middle."""

        def speech_probabilities(self, samples):
            return np.array([0.9] * 10 + [0.1] * 10 + [0.9] * 10)

    class _Deaf:
        def speech_probabilities(self, samples):
            return None

    class _Angry:
        def speech_probabilities(self, samples):
            raise RuntimeError("model exploded")

    vad = VadBoundaryOracle(_Silent(), window_size_samples=512)
    _check("the VAD oracle picks the centre of the quiet run",
           vad.choose_split(zone, 0, len(zone), SR), 15 * 512)
    _check("an unavailable VAD declines",
           VadBoundaryOracle(_Deaf()).choose_split(zone, 0, len(zone), SR), None)

    # The chain must survive a link that declines AND a link that raises,
    # and must always produce an answer inside the zone.
    answer = chain([VadBoundaryOracle(_Angry()), VadBoundaryOracle(_Deaf())])(
        zone, 1000, 2000, SR)
    _check("the chain answers despite a raising link",
           1000 <= answer <= 2000, True)


def test_overlap_assembly() -> None:
    """Assembly keeps every word once, and refuses a result it cannot trust."""
    import numpy as np

    from .overlap import (AudioWindow, OverlapAssemblyError, Word, assemble)

    SR = 16000
    full = np.concatenate([_sine(10), _quiet(1.0), _sine(10)])
    windows = [
        AudioWindow(full[:12 * SR], 0, 0, 10 * SR, True),
        AudioWindow(full[9 * SR:], 9 * SR, 10 * SR, len(full), True),
    ]
    # The second window re-hears "мир" from the overlap.
    per_window = [
        [Word("привет", 1.0), Word("мир", 9.5)],
        [Word("мир", 0.5), Word("снова", 3.0)],
    ]
    result = assemble(windows, per_window, full, SR)
    _check("every word appears exactly once",
           result.text, "привет мир снова")

    # A window built from audio that carried signal but produced nothing is
    # not a transcript, it is a failure — the caller must fall back rather
    # than paste a hole.
    try:
        assemble(windows, [per_window[0], []], full, SR)
        _check("a silent signal-bearing window is refused", "no error", "error")
    except OverlapAssemblyError:
        pass

    _check("mismatched shapes are refused",
           _raises(lambda: assemble(windows, [per_window[0]], full, SR),
                   OverlapAssemblyError), True)


def _raises(callable_, exception_type) -> bool:
    try:
        callable_()
    except exception_type:
        return True
    except Exception:
        return False
    return False


def test_compute_backends_are_independent() -> None:
    """Speech recognition is CPU-only; the LLM device is its own setting.

    Same split as the macOS build since 0.7.0: Parakeet gains nothing from
    the GPU here while the local LLM is several times faster on it, so the
    only device switch left belongs to the LLM.
    """
    import tempfile

    from .settings import Settings

    settings = Settings(path=tempfile.mktemp(suffix=".json"))
    _check("the speech model defaults to Parakeet Ultra",
           settings.speech_model_profile, "parakeet_ultra_onnx")
    settings._set("speech_model_profile", "gigaam_v3_onnx")
    _check("GigaAM can be chosen", settings.speech_model_profile, "gigaam_v3_onnx")
    settings._set("speech_model_profile", "whisper_russian")
    _check("a retired or unknown model falls back to the default",
           settings.speech_model_profile, "parakeet_ultra_onnx")
    _check("the ASR model leaves the LLM device alone",
           settings.llm_compute_backend, "cpu")
    settings._set("llm_compute_backend", "cpu")
    _check("cpu means no offloaded layers", settings.llm_gpu_layers, 0)
    settings._set("llm_compute_backend", "gpu")
    _check("gpu means all of them", settings.llm_gpu_layers, 99)
    settings._set("llm_compute_backend", "nonsense")
    _check("an unknown value falls back to the cpu default",
           settings.llm_compute_backend, "cpu")


def test_llm_backend_without_bundled_host() -> None:
    # Release builds ship no LLM host: a stored "bundledLocal" (the macOS
    # default) must read as the endpoint, and the endpoint must get the
    # zero-shot prompt and the macOS default model name.
    import os
    import tempfile
    from unittest import mock

    from .llm import LLMBackend
    from .llm.pipeline import CustomEndpoint
    from .settings import Settings

    settings = Settings(path=tempfile.mktemp(suffix=".json"))
    with mock.patch("superdictate.llm.host.bundled_host_available", return_value=False):
        _check("no host: correction uses the endpoint",
               settings.correction_config().backend, LLMBackend.CUSTOM_ENDPOINT)
        _check("no host: rewrite uses the endpoint",
               settings.rewrite_config().backend, LLMBackend.CUSTOM_ENDPOINT)
    with mock.patch("superdictate.llm.host.bundled_host_available", return_value=True):
        _check("experimental host: the stored backend stands",
               settings.correction_config().backend, LLMBackend.BUNDLED_LOCAL)
    from .llm.models import BundledLLMModel, profile
    _check("the VoiceScribe rsLoRA runs at the macOS scale",
           profile(BundledLLMModel.VOICESCRIBE).lora_scale, 4.0)
    with mock.patch("superdictate.llm.host.bundled_host_available", return_value=True):
        settings._set("rewrite_engine_backend_v1", "bundledLocal")
        _check("local host: rewrite still goes to the endpoint (correction only)",
               settings.rewrite_config().backend, LLMBackend.CUSTOM_ENDPOINT)
        settings._set("correction_bundled_model_v2", "yandexgpt")
        _check("local host: an 8B correction model from macOS reads as VoiceScribe",
               settings.correction_config().model, BundledLLMModel.VOICESCRIBE)

    from .llm.host import HostSpec, host_command
    lora = r"C:\Program Files\SuperDictate\_internal\assets\models\gec-lora-adapter.gguf"
    gpu = HostSpec(model_path=r"C:\m\Qwen.gguf", lora_path=lora, lora_scale=4.0, gpu_layers=99)
    argv, cwd, env = host_command(r"C:\x\engines\llama\llama-server.exe", gpu, 5000)
    _check("llama-server: the LoRA goes by bare name, with its scale",
           argv[argv.index("--lora-scaled") + 1], "gec-lora-adapter.gguf:4")
    _check("llama-server: started in the adapter's folder", cwd, os.path.dirname(lora))
    _check("llama-server on the GPU: no cooperative-matrix shaders",
           env.get("GGML_VK_DISABLE_COOPMAT"), "1")
    _check("llama-server on the GPU: no context checkpoints",
           argv[argv.index("--ctx-checkpoints") + 1], "0")
    _check("llama-server: one request at a time", argv[argv.index("--parallel") + 1], "1")
    cpu = HostSpec(model_path=r"C:\m\Qwen.gguf", gpu_layers=0)
    argv, cwd, env = host_command(r"C:\x\engines\llama\llama-server.exe", cpu, 5000)
    _check("llama-server on the CPU: no GPU device at all",
           (argv[argv.index("--device") + 1], "--ctx-checkpoints" in argv, env), ("none", False, {}))
    from .llm.host import LLM_MAX_THREADS, llm_thread_count
    own, own_cwd, own_env = host_command(r"C:\x\engines\superdictate-llm-host.exe", gpu, 5000)
    _check("our host keeps the macOS flags",
           own[own.index("--lora-scale") + 1], "4.0")
    _check("our host gets an explicit thread count",
           own[own.index("--threads") + 1], str(llm_thread_count()))
    _check("our host on the GPU: no cooperative-matrix shaders either",
           own_env.get("GGML_VK_DISABLE_COOPMAT"), "1")
    _, _, own_cpu_env = host_command(r"C:\x\engines\superdictate-llm-host.exe", cpu, 5000)
    _check("our host on the CPU: no Vulkan environment", own_cpu_env, {})
    _check("threads: a 14-core hybrid laptop leaves cores free (8, not 14)",
           llm_thread_count(14), LLM_MAX_THREADS)
    _check("threads: a 4-core machine still gets two", llm_thread_count(4), 2)
    _check("threads: a 6-core machine keeps two cores free", llm_thread_count(6), 4)

    endpoint = CustomEndpoint(base_url="http://127.0.0.1:1234")
    _check("an endpoint needs only its address", endpoint.is_configured, True)
    _check("an empty model name falls back to the macOS default",
           endpoint.effective_model_name, "gpt-4o-mini")


def test_update_channel_is_windows_only() -> None:
    # Both platforms publish to one repository; a macOS release (mac-v0.9.0,
    # legacy v0.8.0, a .zip of the .app) must never read as a Windows update.
    from .updater import is_newer, newest_windows_release, parse_version

    releases = [
        {"tag_name": "mac-v0.9.0", "assets": [{"name": "SuperDictate.zip"}]},
        {"tag_name": "v0.8.0", "assets": [{"name": "SuperDictate.zip"}]},
        {"tag_name": "win-v0.7.1", "assets": []},
        {"tag_name": "win-v0.7.10", "assets": []},
        {"tag_name": "win-v0.8.0", "draft": True},
    ]
    _check("the newest win tag wins; macOS and drafts are ignored",
           newest_windows_release(releases)["tag_name"], "win-v0.7.10")
    _check("no Windows release, no update", newest_windows_release(releases[:2]), None)
    _check("win tags parse", parse_version("win-v0.7.10"), (0, 7, 10))
    _check("a newer win tag is newer", is_newer("win-v0.7.1", "0.7.0"), True)


def test_retired_asr_settings_are_dropped() -> None:
    """Settings from the onnx-asr / ggml era load without leaking through."""
    import json
    import tempfile

    from .settings import Settings

    path = tempfile.mktemp(suffix=".json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump({"asr_engine": "native", "compute_provider": "cuda",
                   "model_quantization": "full", "numbers_as_digits": False}, handle)
    settings = Settings(path=path)
    snapshot = settings.snapshot()
    _check("retired keys are not carried", sorted(
        key for key in ("asr_engine", "compute_provider", "model_quantization")
        if key in snapshot), [])
    _check("the rest of the file still loads", settings.numbers_as_digits, False)
    _check("the model is the default", settings.speech_model_profile, "parakeet_ultra_onnx")


def test_asr_thread_policy() -> None:
    """Every physical core but two, 2..16; a valid override wins."""
    from .onnx_host import resolved_thread_count

    _check("18 cores", resolved_thread_count(18, override=""), 16)
    _check("8 cores", resolved_thread_count(8, override=""), 6)
    _check("a 2-core machine still gets 2", resolved_thread_count(2, override=""), 2)
    _check("a valid override", resolved_thread_count(8, override="12"), 12)
    _check("an out-of-range override is ignored", resolved_thread_count(8, override="64"), 6)
    _check("a non-numeric override is ignored", resolved_thread_count(8, override="x"), 6)


def test_onnx_catalog_and_manifest() -> None:
    """The shared catalog parses, and the manifest keeps what the host checks."""
    from . import onnx_models
    from .asr import PROFILE_GIGAAM_V3, PROFILE_PARAKEET_ULTRA, model_id_for

    models = onnx_models.catalog()
    for profile in (PROFILE_PARAKEET_ULTRA, PROFILE_GIGAAM_V3):
        _check(f"{profile} is in the catalog", model_id_for(profile) in models, True)
    ultra = models[onnx_models.PARAKEET_ULTRA_MODEL_ID]
    _check("every Parakeet file is pinned to a revision",
           all("/resolve/" in item.url and len(item.sha256) == 64 for item in ultra.files), True)
    manifest = onnx_models._manifest_for(ultra.entry)
    _check("the manifest drops download URLs",
           any("url" in spec for spec in manifest["files"].values()), False)
    _check("the manifest drops presentation keys", "display_name" in manifest, False)
    _check("the manifest keeps the model id", manifest["model_id"], ultra.model_id)
    _check("a traversal path is refused",
           _raises(lambda: onnx_models._check_relative("../evil.onnx"),
                   onnx_models.ModelInstallError), True)
    _check("a nested path is refused",
           _raises(lambda: onnx_models._check_relative("sub/encoder.onnx"),
                   onnx_models.ModelInstallError), True)


_FAKE_HOST = r"""
import json, struct, sys, threading, time
REQ = struct.Struct("<4sHHQIQ"); RES = struct.Struct("<4sHHQI")
inp, out = sys.stdin.buffer, sys.stdout.buffer
lock = threading.Lock()
def send(status, rid, body):
    data = json.dumps(body).encode()
    with lock:
        out.write(RES.pack(b"SDAR", 1, status, rid, len(data)) + data); out.flush()
def read(n):
    buf = b""
    while len(buf) < n:
        chunk = inp.read(n - len(buf))
        if not chunk: sys.exit(0)
        buf += chunk
    return buf
hanging = {}
while True:
    magic, version, kind, rid, jlen, plen = REQ.unpack(read(REQ.size))
    body = json.loads(read(jlen) or b"{}"); pcm = read(plen)
    if kind == 1:
        send(0, rid, {"provider_actual": "cpu", "model_id": body.get("model_id", "fake")})
    elif kind == 2:
        count = plen // 4
        if count == 1600: hanging[rid] = True; continue
        if count == 3200: sys.exit(7)
        send(0, rid, {"text": f"samples {count}", "processing_seconds": 0.01,
                      "words": [{"w": "samples", "start": 0.0, "end": 0.1},
                                {"w": str(count), "start": 0.2, "end": 0.3}]})
    elif kind == 4:
        target = body["target"]; send(0, rid, {})
        if hanging.pop(target, False): send(8, target, {"category": "CANCELLED", "message": ""})
    elif kind == 5:
        sys.exit(0)
"""


def test_onnx_host_ipc() -> None:
    """Framing v1 against a stand-in host: success, timeout→CANCEL, crash."""
    import sys
    import tempfile

    import numpy as np

    from . import onnx_host

    script = Path(tempfile.mkdtemp()) / "fake_host.py"
    script.write_text(_FAKE_HOST, encoding="utf-8")

    host = onnx_host.OnnxHost([sys.executable, "-I", str(script)])
    try:
        host.create(model_directory=Path("m"), assets_directory=Path("a"), threads=4,
                    expected_model_id="parakeet-ultra-int8")
        _check("CREATE reports the model", host.model_id, "parakeet-ultra-int8")
        result = host.transcribe(np.zeros(800, dtype=np.float32), timestamps=True)
        _check("TRANSCRIBE round-trips the PCM", result.text, "samples 800")
        _check("words carry their times",
               [(w.text, w.start) for w in result.words], [("samples", 0.0), ("800", 0.2)])

        original = onnx_host.timeout_seconds
        onnx_host.timeout_seconds = lambda count, rate=16000: 0.3
        try:
            _check("a hung request times out via CANCEL",
                   _raises(lambda: host.transcribe(np.zeros(1600, dtype=np.float32)),
                           onnx_host.TimedOut), True)
        finally:
            onnx_host.timeout_seconds = original
        _check("a timed-out host is not reused", host.is_alive, False)
    finally:
        host.shutdown()

    crashing = onnx_host.OnnxHost([sys.executable, "-I", str(script)])
    try:
        crashing.create(model_directory=Path("m"), assets_directory=Path("a"), threads=1)
        _check("a host that dies mid-request is reported",
               _raises(lambda: crashing.transcribe(np.zeros(3200, dtype=np.float32)),
                       onnx_host.HostExited), True)
        _check("and marked dead", crashing.is_alive, False)
    finally:
        crashing.shutdown()


def test_openvino_windows() -> None:
    """Static NPU windows: overlapping, ending on the audio, cut mid-overlap."""
    from .openvino_asr import SAMPLE_RATE, plan_windows

    _check("short audio is one window",
           plan_windows(SAMPLE_RATE * 5, SAMPLE_RATE * 15, SAMPLE_RATE * 3),
           [(0, SAMPLE_RATE * 5, float("-inf"), float("inf"))])
    spans = plan_windows(SAMPLE_RATE * 40, SAMPLE_RATE * 15, SAMPLE_RATE * 3)
    _check("40 s in 15 s windows, 3 s overlap",
           [(s // SAMPLE_RATE, e // SAMPLE_RATE) for s, e, _, _ in spans],
           [(0, 15), (12, 27), (24, 39), (25, 40)])
    _check("every window is full", {e - s for s, e, _, _ in spans}, {SAMPLE_RATE * 15})
    _check("the cuts sit in the middle of each overlap",
           [(a, b) for _, _, a, b in spans],
           [(float("-inf"), 13.5), (13.5, 25.5), (25.5, 32.0), (32.0, float("inf"))])
    _check("the keep spans tile the audio without a gap",
           all(spans[i][3] == spans[i + 1][2] for i in range(len(spans) - 1)), True)

    from .openvino_asr import Word, stitch

    def words(*items):
        return [Word(text, start, start + 0.3, 1.0) for text, start in items]

    def texts(items):
        return [w.w for w in items]

    first = stitch([], words(("чтобы", 9.84), ("распознавание", 10.16), ("речи", 11.20),
                             ("выполнялось", 11.68)), float("-inf"), 11.19, 0.08)
    # The NPU case: "речи" lands just after the cut in one window and just
    # before it in the next. A plain cut kept it in neither.
    second = words(("распознавание", 10.18), ("речи", 11.14), ("выполнялось", 11.62),
                   ("именно", 12.50))
    _check("stitch: a word straddling the cut is kept once",
           texts(stitch(first, second, 11.19, float("inf"), 0.08)),
           ["чтобы", "распознавание", "речи", "выполнялось", "именно"])
    early = stitch([], words(("а", 1.0), ("б", 11.10)), float("-inf"), 11.19, 0.08)
    _check("stitch: a word heard on both sides of the cut is not doubled",
           texts(stitch(early, words(("б", 11.30), ("в", 11.9)), 11.19, float("inf"), 0.08)),
           ["а", "б", "в"])
    # "за" 12.90, "внимание" 13.06: two real words exactly two frames apart.
    _check("stitch: neighbouring words after the cut are both kept",
           texts(stitch(words(("а", 1.0)), words(("за", 12.90), ("внимание", 13.06)), 8.07,
                        float("inf"), 0.08)),
           ["а", "за", "внимание"])
    _check("stitch: a window does not reach back past its overlap",
           texts(stitch(words(("а", 1.0)), words(("x", 8.0), ("в", 12.0)), 11.19,
                        float("inf"), 0.08)),
           ["а", "в"])


def test_openvino_word_rules() -> None:
    """Text and words exactly as the native families build them."""
    from .openvino_asr import Token, words_space_rule, words_word_start_rule

    pieces = ["▁При", "вет", ",", "▁мир", "."]
    tokens = [Token(0, 0.0, 0.9), Token(1, 0.08, 0.5), Token(2, 0.16, 0.8),
              Token(3, 0.4, 0.7), Token(4, 0.48, 0.6)]
    nemo = words_word_start_rule(tokens, pieces, 0.08, 1.0)
    _check("nemo: text", nemo.text, "Привет, мир.")
    _check("nemo: words", [w.w for w in nemo.words], ["Привет,", "мир."])
    _check("nemo: a word ends one frame after its last piece", nemo.words[0].end, 0.24)
    _check("nemo: confidence is the weakest piece", nemo.words[0].conf, 0.5)

    giga = words_space_rule(tokens, pieces, 0.04, 1.0)
    _check("gigaam: text", giga.text, "Привет, мир.")
    _check("gigaam: words", [w.w for w in giga.words], ["Привет,", "мир."])
    spaced = words_space_rule([Token(0, 0.0, 1.0), Token(1, 0.1, 1.0)], ["▁a", "▁,"], 0.04, 1.0)
    _check("gigaam: no space before punctuation", spaced.text, "a,")


def test_sentencepiece_reader() -> None:
    """Pieces come out of a ModelProto in id order, other fields skipped."""
    import tempfile

    from .openvino_asr import sentencepiece_pieces

    def varint(value: int) -> bytes:
        out = b""
        while True:
            byte = value & 0x7F
            value >>= 7
            out += bytes([byte | (0x80 if value else 0)])
            if not value:
                return out

    def field(number: int, payload: bytes) -> bytes:
        return varint(number << 3 | 2) + varint(len(payload)) + payload

    def piece(text: str) -> bytes:
        # piece (1), score (2, fixed32), type (3, varint)
        return field(1, text.encode()) + bytes([2 << 3 | 5]) + b"\0\0\x80\xbf" + bytes([3 << 3, 1])

    model = b"".join(field(1, piece(p)) for p in ("<unk>", "▁при", "вет"))
    model += field(2, b"trainer spec, ignored")
    path = Path(tempfile.mkdtemp()) / "tokenizer.model"
    path.write_bytes(model)
    _check("sentencepiece pieces", sentencepiece_pieces(path), ["<unk>", "▁при", "вет"])


def test_gigaam_features() -> None:
    """GigaAM log-mel: frame count, silence floor, and a tone where it belongs."""
    import numpy as np

    from .openvino_asr import gigaam_features

    features, frames = gigaam_features(np.zeros(16000, dtype=np.float32))
    _check("1 s gives 99 frames (center=False)", (features.shape, frames), ((64, 99), 99))
    _check("silence sits on the clamp floor",
           bool(np.allclose(features, np.log(1e-9), atol=1e-3)), True)
    tone = np.sin(2 * np.pi * 1000 * np.arange(16000) / 16000).astype(np.float32)
    loudest = int(np.argmax(gigaam_features(tone)[0].mean(axis=1)))
    # 64 HTK bands up to 8 kHz: 1 kHz is 21.9 bands in, the peak of band 22.
    _check("a 1 kHz tone lands in its mel band", loudest, 22)
    _check("audio shorter than one frame has none", gigaam_features(np.zeros(100))[1], 0)


def test_npu_backend_settings_and_catalog() -> None:
    """The NPU choice: stored, coerced, and mapped to the OpenVINO models."""
    import tempfile

    from . import onnx_models, openvino_asr
    from .asr import (BACKEND_CPU, BACKEND_NPU, PROFILE_GIGAAM_V3,
                      PROFILE_PARAKEET_ULTRA, model_id_for)
    from .settings import Settings

    settings = Settings(path=tempfile.mktemp(suffix=".json"))
    _check("recognition defaults to the CPU", settings.speech_compute_backend, "cpu")
    settings._set("speech_compute_backend", "npu")
    _check("the NPU can be chosen", settings.speech_compute_backend, "npu")
    settings._set("speech_compute_backend", "gpu")
    _check("anything else reads as the CPU", settings.speech_compute_backend, "cpu")

    _check("CPU Parakeet is the ONNX model",
           model_id_for(PROFILE_PARAKEET_ULTRA, BACKEND_CPU), onnx_models.PARAKEET_ULTRA_MODEL_ID)
    _check("NPU Parakeet is the OpenVINO model",
           model_id_for(PROFILE_PARAKEET_ULTRA, BACKEND_NPU), onnx_models.PARAKEET_OV_MODEL_ID)
    _check("NPU GigaAM is the NPU-calibrated model",
           model_id_for(PROFILE_GIGAAM_V3, BACKEND_NPU), onnx_models.GIGAAM_OV_MODEL_ID)

    models = onnx_models.catalog()
    for model_id in (onnx_models.PARAKEET_OV_MODEL_ID, onnx_models.GIGAAM_OV_MODEL_ID):
        entry = models.get(model_id)
        _check(f"{model_id} is in the catalog", entry is not None, True)
        if entry is None:
            continue
        _check(f"{model_id} is an OpenVINO model", entry.runtime, onnx_models.RUNTIME_OPENVINO)
        _check(f"{model_id} has a family the host knows",
               entry.entry["family"] in openvino_asr.FAMILIES, True)
        _check(f"{model_id} files are pinned",
               all("/resolve/" in f.url and len(f.sha256) == 64 and f.size > 0
                   for f in entry.files), True)
        _check(f"{model_id} installs beside, not inside, the ONNX models",
               onnx_models.model_directory(model_id).parent.name, "openvino")
    _check("the ONNX models stay where they were",
           onnx_models.model_directory(onnx_models.PARAKEET_ULTRA_MODEL_ID).parent.name, "onnx")


_FAKE_OV_HOST = r"""
import sys, time
sys.path.insert(0, sys.argv[1])
from superdictate import openvino_asr, openvino_host

class Fake:
    device = "NPU"
    window_samples = 240000
    def transcribe(self, samples, cancelled):
        if samples.size == 1600:
            while not cancelled():
                time.sleep(0.01)
            raise openvino_asr.Cancelled("request cancelled")
        word = openvino_asr.Word(str(samples.size), 0.25, 0.5, 0.9)
        return openvino_asr.Transcript(f"samples {samples.size}", [word])

def load(family, directory, device, cache):
    if device == "NPU" and str(directory).endswith("nonpu"):
        raise RuntimeError("compile failed\nZE_RESULT_ERROR_INVALID_ARGUMENT")
    model = Fake(); model.device = device
    return model

openvino_asr.load = load
sys.exit(openvino_host.main([]))
"""


def test_openvino_host_ipc() -> None:
    """SuperDictateOvHost through the app's own client: the same framing v1."""
    import sys
    import tempfile

    import numpy as np

    from . import onnx_host

    script = Path(tempfile.mkdtemp()) / "fake_ov_host.py"
    script.write_text(_FAKE_OV_HOST, encoding="utf-8")
    package_root = str(Path(__file__).resolve().parent.parent)
    command = [sys.executable, "-I", str(script), package_root]

    host = onnx_host.OnnxHost(command)
    try:
        host.create_with({"engine": "openvino", "family": "nemo_tdt_ov", "model_id": "x-ov",
                          "model_directory": "m", "device": "NPU"}, timeout=30)
        _check("ov CREATE reports the model", host.model_id, "x-ov")
        _check("ov CREATE reports the NPU", host.provider_actual, "npu")
        _check("ov CREATE reports the model's fixed window", host.window_seconds, 15.0)
        result = host.transcribe(np.zeros(800, dtype=np.float32), timestamps=True)
        _check("ov TRANSCRIBE round-trips the PCM", result.text, "samples 800")
        _check("ov words carry their times",
               [(w.text, w.start, w.end) for w in result.words], [("800", 0.25, 0.5)])

        original = onnx_host.timeout_seconds
        onnx_host.timeout_seconds = lambda count, rate=16000: 0.3
        try:
            _check("ov: a hung request times out via CANCEL",
                   _raises(lambda: host.transcribe(np.zeros(1600, dtype=np.float32)),
                           onnx_host.TimedOut), True)
        finally:
            onnx_host.timeout_seconds = original
    finally:
        host.shutdown()

    fallback = onnx_host.OnnxHost(command)
    try:
        fallback.create_with({"engine": "openvino", "family": "gigaam_rnnt_ov",
                              "model_directory": "nonpu", "device": "NPU"}, timeout=30)
        _check("ov: an NPU that will not compile falls back to the CPU",
               fallback.provider_actual, "cpu")
        _check("ov: and says why",
               "ZE_RESULT_ERROR_INVALID_ARGUMENT" in fallback.provider_fallback_reason, True)
    finally:
        fallback.shutdown()

    refused = onnx_host.OnnxHost(command)
    try:
        error = None
        try:
            refused.create_with({"engine": "openvino", "family": "whisper"}, timeout=30)
        except onnx_host.NativeError as exc:
            error = exc.category
        _check("ov: an unknown family is refused", error, "unsupported_model_family")
    finally:
        refused.shutdown()


def test_npu_encoder_background_compile() -> None:
    """A slow NPU compile starts the model on the CPU and moves it over later;
    a cached (fast) one starts on the NPU; a failed one stays on the CPU."""
    import tempfile
    import threading
    import time
    import types

    from . import openvino_asr

    path = Path(tempfile.mkdtemp()) / "encoder.xml"
    path.write_text("<net/>", encoding="utf-8")
    release = threading.Event()
    behaviour = {"npu": "slow"}

    def fake_compile(core, model_path, device):
        if device == "NPU":
            if behaviour["npu"] == "fail":
                raise RuntimeError("compile\nZE_RESULT_ERROR_INVALID_ARGUMENT")
            if behaviour["npu"] == "slow":
                release.wait(5)
        return types.SimpleNamespace(device=device, outputs=[], inputs=[],
                                     create_infer_request=lambda: f"request-{device}")

    saved = (openvino_asr._compile, openvino_asr._core, openvino_asr._configure_npu)
    openvino_asr._compile = fake_compile
    openvino_asr._core = lambda cache: object()
    openvino_asr._configure_npu = lambda core: None
    try:
        slot = openvino_asr.EncoderSlot(path, "NPU", None, quick_wait=0.05)
        _check("npu slow: starts on the CPU", (slot.device, slot.request), ("CPU", "request-CPU"))
        _check("npu slow: says it is compiling", slot.compiling, True)
        _check("npu slow: nothing to swap yet", slot.swap(), False)
        release.set()
        deadline = time.monotonic() + 5
        while slot.compiling and time.monotonic() < deadline:
            time.sleep(0.01)
        _check("npu slow: moves to the NPU once compiled",
               (slot.swap(), slot.device, slot.request), (True, "NPU", "request-NPU"))

        behaviour["npu"] = "fast"
        _check("npu cached: starts on the NPU",
               openvino_asr.EncoderSlot(path, "NPU", None, quick_wait=2).device, "NPU")

        behaviour["npu"] = "fail"
        failed = openvino_asr.EncoderSlot(path, "NPU", None, quick_wait=2)
        _check("npu failed: stays on the CPU", failed.device, "CPU")
        _check("npu failed: keeps the reason", failed.npu_error, "ZE_RESULT_ERROR_INVALID_ARGUMENT")
    finally:
        openvino_asr._compile, openvino_asr._core, openvino_asr._configure_npu = saved


def test_hotkey_hook_refresh() -> None:
    """The keyboard hook is re-installed new-before-old, and kept on failure.

    Windows evicts a low-level hook silently when its callback misses
    LowLevelHooksTimeout (seen while a background NPU compile kept every
    core busy), so the listener re-installs it periodically.
    """
    from unittest import mock

    from . import hotkeys

    listener = hotkeys.HotkeyListener(lambda actions: None)
    calls = []
    fake = mock.MagicMock()
    fake.SetWindowsHookExW.side_effect = lambda *a: calls.append("set") or 222
    fake.UnhookWindowsHookEx.side_effect = lambda h: calls.append(("unhook", h))
    listener._hook = 111
    with mock.patch.object(hotkeys, "user32", fake):
        listener._refresh_hook()
        _check("hook refresh: the new hook goes in before the old comes out",
               calls, ["set", ("unhook", 111)])
        _check("hook refresh: the new handle is kept", listener._hook, 222)
        fake.SetWindowsHookExW.side_effect = lambda *a: 0
        listener._refresh_hook()
        _check("hook refresh: a failed install keeps the working hook", listener._hook, 222)
    _check("hook refresh: often enough to bound a dead shortcut",
           hotkeys.HOOK_REFRESH_SECONDS <= 30, True)


def _run_edit_watch(states, inserted, *, pid=42):
    """Drive edit_watch.EditWatcher through ``states``: ``[(at_seconds, text, element)]``,
    each field state holding from its time until the next one. Returns the
    candidates it saved."""
    import time as _time

    from . import edit_watch
    from .focus_target import FieldSnapshot

    clock = {"t": 0.0}
    learned = []

    def read():
        current = None
        for at, text, element in states:
            if clock["t"] >= at:
                current = (text, element)
        if current is None or current[0] is None:
            return None
        text, element = current
        return FieldSnapshot(element=element, pid=pid, text=text,
                             caret=None, secure=text == "<password>")

    def fake_sleep(seconds):
        clock["t"] += seconds

    watcher = edit_watch.EditWatcher(read, lambda c: learned.append((c.source, c.replacement)) or True,
                                     clock=lambda: clock["t"], sleep=fake_sleep)
    watcher.begin(inserted)
    deadline = _time.monotonic() + 10
    while watcher._thread is not None and watcher._thread.is_alive() and _time.monotonic() < deadline:
        _time.sleep(0.01)
    watcher.stop()
    return learned


def test_edit_watch_learns_like_macos() -> None:
    """Corrections made in place right after a paste are learned, as on macOS."""
    from .edit_watch import inserted_range

    before, after = "Письмо: ", " Спасибо."
    dictated = "напиши на инглиш пожалуйста"
    field = before + dictated + after
    fixed = field.replace("инглиш", "English")
    _check("edit watch: the inserted span is found",
           inserted_range(dictated, field, None), (len(before), len(before) + len(dictated)))
    _check("edit watch: the occurrence nearest the caret wins",
           inserted_range("да", "да или да", 9), (7, 9))
    _check("edit watch: no-break spaces read as spaces",
           inserted_range("a b ", "x a b", None), (2, 5))

    _check("edit watch: a word fixed in place is learned after the pause",
           _run_edit_watch([(0, field, 1), (2, field.replace("инглиш", "Eng"), 1),
                            (2.1, fixed, 1)], dictated),
           [("инглиш", "English")])
    _check("edit watch: an edit still being typed is not learned half done",
           _run_edit_watch([(0, field, 1), (2, field.replace("инглиш", "Eng"), 1),
                            (5, fixed, 1)], dictated),
           [("инглиш", "English")])
    _check("edit watch: a second fix after the first is learned on its own",
           _run_edit_watch([(0, field, 1), (1, fixed, 1),
                            (8, fixed.replace("пожалуйста", "please"), 1)], dictated),
           [("инглиш", "English"), ("пожалуйста", "please")])
    _check("edit watch: a pure deletion teaches nothing",
           _run_edit_watch([(0, field, 1), (1, field.replace(" инглиш", ""), 1)], dictated), [])
    _check("edit watch: focus moving away ends the watch",
           _run_edit_watch([(0, field, 1), (1, fixed, 2)], dictated), [])
    _check("edit watch: an edit outside the dictation ends the watch",
           _run_edit_watch([(0, field, 1), (1, "Привет! " + fixed, 1)], dictated), [])
    _check("edit watch: a password field is never watched",
           _run_edit_watch([(0, "<password>", 1)], dictated), [])
    _check("edit watch: text that never shows up is not guessed at",
           _run_edit_watch([(0, "что-то другое", 1), (1, "что-то иное", 1)], dictated), [])
    _check("edit watch: nothing is learned after the 45 s window",
           _run_edit_watch([(0, field, 1), (50, fixed, 1)], dictated), [])


def _speech_like(seconds_pattern, sample_rate=16000, seed=7):
    """Noise bursts (speech) and zeros (pauses): ``[(speech_s, pause_s), ...]``."""
    import numpy as np

    rng = np.random.RandomState(seed)
    parts = []
    for speech, pause in seconds_pattern:
        parts.append((rng.randn(int(speech * sample_rate)) * 0.1).astype(np.float32))
        parts.append(np.zeros(int(pause * sample_rate), dtype=np.float32))
    return np.concatenate(parts)


class _FakeWordModel:
    """Deterministic words from the audio itself: same audio, same words."""

    def __init__(self, window_seconds=0.0):
        self.generation = 1
        self.calls = 0
        self.max_window_seconds = window_seconds
        self.lock = __import__("threading").Lock()

    def transcribe_words(self, samples):
        from .incremental import window_checksum
        from .onnx_host import HostTranscription, HostWord

        with self.lock:
            self.calls += 1
        words = []
        for index, start in enumerate(range(0, len(samples) - 8000, 8000)):
            chunk = samples[start:start + 8000]
            if float(abs(chunk).mean()) < 0.01:
                continue
            tag = window_checksum(chunk).hex()[:4]
            words.append(HostWord(text=f"w{tag}", start=start / 16000, end=(start + 8000) / 16000))
        return HostTranscription(" ".join(w.text for w in words), 0.0, tuple(words))

    def transcribe(self, samples, enqueued_at):
        from .asr import TranscriptionResult

        return TranscriptionResult(self.transcribe_words(samples).text, len(samples) / 16000, 0, 0)


def test_incremental_stable_windows() -> None:
    """A window called stable on a prefix is exactly a window of the full buffer."""
    from .incremental import stable_windows, window_checksum
    from .overlap import add_overlap
    from .segmentation import segment

    full = _speech_like([(9, 0.6), (8, 0.7), (11, 0.5), (6, 0.8), (12, 0.6), (7, 0.1)])
    final = {(w.start_sample, len(w.samples)): window_checksum(w.samples)
             for w in add_overlap(segment(full, 16000), 16000)}
    seen = set()
    wrong = []
    for end in range(16000, len(full), 16000 // 2):
        for window in stable_windows(full[:end], 16000):
            key = (window.start_sample, len(window.samples))
            seen.add(key)
            if final.get(key) != window_checksum(window.samples):
                wrong.append((end, key))
    _check("incremental: every stable window matches the final windowing", wrong, [])
    _check("incremental: all but the last window or two become stable before the end",
           len(seen) >= len(final) - 2, True)
    _check("incremental: a short recording has no stable window",
           stable_windows(full[:16000 * 10], 16000), [])


def test_incremental_transcription_matches_batch() -> None:
    """Recording-time work never changes the text, and saves the release work."""
    import threading

    from . import transcription
    from .incremental import IncrementalTranscriber

    full = _speech_like([(9, 0.6), (8, 0.7), (11, 0.5), (6, 0.8), (12, 0.6), (7, 0.1)])
    batch_model = _FakeWordModel()
    batch = transcription.transcribe(batch_model, full, 0.0)

    model = _FakeWordModel()
    captured = {"n": 0}
    done = threading.Event()

    def snapshot():
        if done.is_set():
            return None
        captured["n"] = min(len(full), captured["n"] + 16000)   # 1 s per poll
        return full[:captured["n"]]

    driver = IncrementalTranscriber(model, snapshot, sample_rate=16000, poll_seconds=0.005).start()
    deadline = __import__("time").monotonic() + 20
    while captured["n"] < len(full) and __import__("time").monotonic() < deadline:
        __import__("time").sleep(0.01)
    done.set()
    cache = driver.finish()
    calls_while_recording = model.calls
    streamed = transcription.transcribe(model, full, 0.0, cache=cache)

    windows = batch.segments
    _check("incremental: the text is identical to the batch path", streamed.text, batch.text)
    _check("incremental: it really took the overlap path", streamed.overlap_path, True)
    _check("incremental: at most two windows are left for the release",
           streamed.windows_reused >= windows - 2, True)
    _check("incremental: release transcribed only what was not cached",
           model.calls - calls_while_recording, windows - streamed.windows_reused)

    model.generation += 1   # the model was reloaded since: nothing may be reused
    reloaded = transcription.transcribe(model, full, 0.0, cache=cache)
    _check("incremental: a reloaded model ignores the cache", reloaded.windows_reused, 0)
    _check("incremental: and still gives the same text", reloaded.text, batch.text)


def test_segment_limits_follow_the_model_window() -> None:
    """A 15 s NPU model gets segments (and so windows) no longer than 15 s."""
    from . import transcription
    from .overlap import add_overlap
    from .segmentation import segment

    _check("limits: an unbounded model keeps the defaults",
           transcription.segment_limits(_FakeWordModel()), (25.0, 15.0))
    _check("limits: a 30 s model keeps the defaults too",
           transcription.segment_limits(_FakeWordModel(30.01)), (25.0, 15.0))
    max_s, min_s = transcription.segment_limits(_FakeWordModel(15.0))
    _check("limits: a 15 s model caps at 15 s", (max_s, min_s), (15.0, 9.0))
    full = _speech_like([(7, 0.6), (5, 0.7), (9, 0.5), (14, 0.8), (6, 0.1)])
    windows = add_overlap(segment(full, 16000, max_segment_seconds=max_s, min_segment_seconds=min_s),
                          16000, max_segment_seconds=max_s)
    _check("limits: no window exceeds the model's input",
           max(len(w.samples) for w in windows) <= 15 * 16000, True)


def test_vocabulary_transfer() -> None:
    """The exchange file must be the one the macOS build reads.

    This is the whole point of the module: a dictionary carried between the
    two platforms has to open on the other side without conversion. An
    earlier version of this port wrote a bare list, which would not have.
    """
    import json

    from .vocabulary_transfer import (SCHEMA_VERSION, TransferError, decode,
                                      encode)

    pairs = [("гитхаб", "GitHub"), ("дебиан", "Debian")]
    document = json.loads(encode(pairs))
    _check("the envelope carries a schema version",
           document["schemaVersion"], SCHEMA_VERSION)
    _check("and the corrections themselves",
           document["corrections"],
           [{"source": "гитхаб", "replacement": "GitHub"},
            {"source": "дебиан", "replacement": "Debian"}])
    for key in ("exportedAt", "appVersion"):
        _check(f"the envelope carries {key}", key in document, True)

    _check("a round trip is lossless", decode(encode(pairs)).corrections, pairs)

    # The shape this port used to write, and its own settings file: still
    # readable, so nobody's existing export becomes garbage.
    bare = json.dumps([{"source": "докер", "replacement": "Docker"}])
    _check("a bare list still imports", decode(bare).corrections,
           [("докер", "Docker")])

    # Junk entries are dropped, but counted, so the UI can say so instead of
    # losing them silently.
    messy = json.dumps({"schemaVersion": 1, "corrections": [
        {"source": "ок", "replacement": "OK"},
        {"source": "", "replacement": "nope"},
        "not even an object",
    ]})
    result = decode(messy)
    _check("usable entries survive", len(result.corrections), 1)
    _check("unusable ones are counted", result.skipped, 2)

    # A newer schema must be refused outright rather than half-read.
    newer = json.dumps({"schemaVersion": SCHEMA_VERSION + 1, "corrections": []})
    _check("a newer schema is refused",
           _raises(lambda: decode(newer), TransferError), True)
    _check("a file with no schema is refused",
           _raises(lambda: decode('{"corrections": []}'), TransferError), True)
    _check("nonsense is refused",
           _raises(lambda: decode("not json at all"), TransferError), True)


_TESTS = [
    test_toggle_starts_and_stops,
    test_toggle_does_not_flip_when_busy,
    test_hold_press_and_release,
    test_left_control_does_not_trigger,
    test_history_chord,
    test_edit_chord,
    test_escape_cancels_only_while_recording,
    test_modifiers_are_never_swallowed,
    test_altgr_phantom_ctrl,
    test_unk_repair,
    test_corrections,
    test_learned_corrections,
    test_filler_removal,
    test_text_style,
    test_casual_style,
    test_numbers_as_digits,
    test_pipeline_order,
    test_settings_round_trip,
    test_hud_timer_default,
    test_hotkey_json_guards,
    test_filler_word_list,
    test_compact_numbers,
    test_autostart_starts_in_the_tray,
    test_autostart_target_parsing,
    test_correction_guardrail,
    test_correction_chunks,
    test_learn_candidate,
    test_vocabulary_store,
    test_hud_elapsed_format,
    test_hud_timer_activation,
    test_hud_phase_speeds,
    test_hud_outline_path,
    test_contrast_color,
    test_caret_geometry,
    test_target_stabilizer,
    test_postprocessing_chords,
    test_pause_segmentation,
    test_overlap_windows,
    test_seam_dedup,
    test_words_from_tokens,
    test_boundary_oracles,
    test_overlap_assembly,
    test_compute_backends_are_independent,
    test_llm_backend_without_bundled_host,
    test_update_channel_is_windows_only,
    test_retired_asr_settings_are_dropped,
    test_asr_thread_policy,
    test_onnx_catalog_and_manifest,
    test_onnx_host_ipc,
    test_openvino_windows,
    test_openvino_word_rules,
    test_sentencepiece_reader,
    test_gigaam_features,
    test_npu_backend_settings_and_catalog,
    test_openvino_host_ipc,
    test_npu_encoder_background_compile,
    test_edit_watch_learns_like_macos,
    test_hotkey_hook_refresh,
    test_incremental_stable_windows,
    test_incremental_transcription_matches_batch,
    test_segment_limits_follow_the_model_window,
    test_vocabulary_transfer,
]


def run_all() -> bool:
    _failures.clear()
    errored = 0
    for test in _TESTS:
        try:
            test()
        except Exception as exc:  # a crashing test is a failing test
            errored += 1
            _failures.append(f"{test.__name__} raised {type(exc).__name__}: {exc}")

    if _failures:
        print(f"FAILED: {len(_failures)} problem(s) in {len(_TESTS)} tests\n")
        for failure in _failures:
            print(f"  * {failure}")
        return False
    print(f"OK: {len(_TESTS)} self-tests passed")
    return True
