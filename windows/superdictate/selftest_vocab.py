"""Self-tests for ASR hotwords, vocabulary hygiene and the account sync.

Part of ``python main.py --self-test`` (:mod:`superdictate.selftest` runs
:data:`TESTS` and collects :data:`FAILURES`). Kept in a module of its own
because none of it needs Windows: the pure rules run anywhere, which is how
they were checked against the macOS tables on a Mac too
(``python -m superdictate.selftest_vocab``).

* ``test_asr_hotword_selection``: the macOS table of
  ``AsrHotwordSelection`` (asr-hotwords spec §6), case for case.
* ``test_asr_hint_store``: the ``asr_hint`` migration and every write path
  keeping the hint.
* ``test_asr_hotwords_settings_and_ipc``: settings, the TRANSCRIBE options
  (an empty list adds no key) on the wire, and the NPU path sending none.
* ``test_vocabulary_hygiene_review`` / ``..._cleanup``: §1's real-world
  examples and §2's keep-cases; the cleanup plan.
* ``test_vocabulary_edits_and_tombstones``: list saves write only the diff;
  every delete leaves a tombstone.
* ``test_vocabulary_sync_server``: two simulated machines against a local
  ``server/vocab-sync`` (skipped where the server or FastAPI is missing).
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

FAILURES: list[str] = []


def _check(name: str, actual, expected) -> None:
    if actual != expected:
        FAILURES.append(f"{name}\n    expected: {expected!r}\n    actual:   {actual!r}")


def _temp_db() -> str:
    handle, path = tempfile.mkstemp(suffix=".sqlite", prefix="sd-vocab-selftest-")
    os.close(handle)
    os.unlink(path)
    return path


def _remove_db(path: str) -> None:
    for suffix in ("", "-wal", "-shm"):
        try:
            os.unlink(path + suffix)
        except OSError:
            pass


class _Rec:
    """A stand-in record for the pure rules."""

    def __init__(self, id, source, replacement, origin="learned", asr_hint=None,
                 updated_at="2026-01-01T00:00:00Z"):
        self.id, self.source, self.replacement = id, source, replacement
        self.origin, self.asr_hint, self.updated_at = origin, asr_hint, updated_at


# -- ASR hotwords ----------------------------------------------------------

def test_asr_hotword_selection() -> None:
    from . import asr_hotwords as hw

    # (source, replacement, origin, hint, expected phrase or None): the
    # macOS self-test table (SelfTest.testAsrHotwords), unchanged.
    cases = [
        ("DR4 DM", "DDR4 DIMM", "learned", None, "DDR4 DIMM"),
        ("ЕСА", "ЕСИА", "learned", None, "ЕСИА"),
        ("Gm, вотчер,", "Gmail watcher,", "learned", None, "Gmail watcher"),
        ("Пони Чепуренко", "По Ничипуренко", "learned", None, "По Ничипуренко"),
        ("Егр", "ЕГРЮЛ", "learned", None, "ЕГРЮЛ"),
        ("TicTic,", "TickTick,", "learned", None, "TickTick"),
        ("тридцать семь. А", "37А", "learned", None, "37А"),
        ("1.", "1mm.", "learned", None, "1mm"),
        ("Аллес Скарш—", "Alien_skaarj —", "learned", None, "Alien_skaarj"),
        ("хаггинг фейс", "Hugging Face", "manual", None, "Hugging Face"),
        ("Смотри.", "Задайте вопрос ChatGPT", "learned", None, "Задайте вопрос ChatGPT"),
        ("Запомню", "Запомни", "learned", None, None),
        ("сторониной", "стороной", "learned", None, None),
        ("красненькову", "Красникову", "learned", None, None),
        ("Нечепуренко", "Ничипуренко", "learned", None, None),
        ("Нечепуренко", "Ничипуренко", "learned", True, "Ничипуренко"),
        ("красненькову", "Красникову", "learned", True, "Красникову"),
        ("докер", "Docker", "manual", False, None),
        ("Эмсипи", "MCP", "learned", False, None),
        ("сторониной", "стороной", "manual", None, "стороной"),
        ("оплатил", "оплатил.", "learned", True, None),
        ("ознакомления", "ознакомления.", "manual", None, None),
        ("Амирханян Ц", "АмирханянЦ", "learned", True, None),
        ("Х 99", "Х99", "manual", None, None),
        ("Инструменты.", "инструменты?", "manual", None, None),
        ("интернейшнл.", ".", "learned", True, None),
        ("S.", "1", "manual", None, None),
        ("икс", "X", "manual", True, None),
        ("12", "42!", "manual", True, None),
        ("длинно", "раз два три четыре пять", "manual", True, None),
        ("коротко", "раз два три QQ", "learned", None, "раз два три QQ"),
        ("кавычки", "«Ответ налоговая»", "manual", None, "Ответ налоговая"),
        ("тире", "— TDT –", "learned", None, "TDT"),
        ("ssh", "Ssh", "manual", None, None),
    ]
    for index, (source, replacement, origin, hint, expected) in enumerate(cases):
        record = _Rec(index, source, replacement, origin, hint)
        _check(f"hotwords: effective {source} -> {replacement} ({origin}, hint {hint})",
               hw.is_effective(source, replacement, origin, hint), expected is not None)
        _check(f"hotwords: phrase for {source} -> {replacement}",
               hw.phrases([record]), [expected] if expected else [])
    _check("hotwords: one uppercase Cyrillic letter is not term-like", hw.is_term_like("Ёлка"), False)
    _check("hotwords: two uppercase letters are term-like", hw.is_term_like("ЁЖ"), True)
    _check("hotwords: Latin-1 letters count as Latin", hw.is_term_like("café"), True)

    duplicates = [_Rec(i, s, r, "manual") for i, (s, r) in enumerate(
        [("гитхаб", "GitHub"), ("гит хаб", "GitHub"), ("Гетхаб.", "Github."),
         ("зип", "ZIP"), ("Зип,", "Zip,")])]
    _check("hotwords: exact duplicates merged, case variants kept, order kept",
           hw.phrases(duplicates), ["GitHub", "Github", "ZIP", "Zip"])
    many = [_Rec(i, f"s{i}", f"Term{i}", "manual") for i in range(1200)]
    capped = hw.phrases(many)
    _check("hotwords: capped at 1000", len(capped), hw.MAX_PHRASES)
    _check("hotwords: the cap keeps the first 1000 in order", capped[-1], "Term999")


def test_asr_hint_store() -> None:
    import sqlite3

    from .vocabulary import DraftEntry, Origin, VocabularyStore

    path = _temp_db()
    legacy = sqlite3.connect(path)
    legacy.executescript("""
        CREATE TABLE corrections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source TEXT NOT NULL COLLATE NOCASE,
            replacement TEXT NOT NULL,
            origin TEXT NOT NULL DEFAULT 'manual',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL);
        CREATE UNIQUE INDEX idx_corrections_source_nocase ON corrections (source);
        INSERT INTO corrections (source, replacement, origin, created_at, updated_at) VALUES
            ('Нечепуренко', 'Ничипуренко', 'learned', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
            ('DR4 DM', 'DDR4 DIMM', 'learned', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
            ('докер', 'Docker', 'manual', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
    """)
    legacy.commit()
    legacy.close()

    store = VocabularyStore(path)
    reopened = None
    try:
        migrated = store.all()
        _check("asr_hint: rows survive the migration", len(migrated), 3)
        _check("asr_hint: migrated rows start automatic",
               all(r.asr_hint is None for r in migrated), True)
        _check("asr_hint: automatic phrases after migration",
               store.asr_hotword_phrases(), ["DDR4 DIMM", "Docker"])
        surname = next(r for r in migrated if r.replacement == "Ничипуренко")
        docker = next(r for r in migrated if r.replacement == "Docker")
        store.set_asr_hint(surname.id, True)
        store.set_asr_hint(docker.id, False)
        _check("asr_hint: explicit hints applied",
               store.asr_hotword_phrases(), ["DDR4 DIMM", "Ничипуренко"])

        reopened = VocabularyStore(path)  # the migration again: idempotent
        _check("asr_hint: persists across connections", reopened.get(surname.id).asr_hint, True)
        _check("asr_hint: explicit off persists", reopened.get(docker.id).asr_hint, False)

        store.upsert("нечепуренко", "Ничипуренко", Origin.MANUAL)
        _check("asr_hint: upsert keeps the hint", store.get(surname.id).asr_hint, True)
        store.learn([("Нечепуренко", "Ничипуренко")])
        _check("asr_hint: learning a known source keeps the hint",
               store.get(surname.id).asr_hint, True)
        _check("asr_hint: learning over a manual rule keeps it manual",
               store.get(surname.id).origin, Origin.MANUAL)
        store.replace_all([("Нечепуренко", "Ничипуренко"), ("докер", "Docker"), ("ЕСА", "ЕСИА")])
        after = {r.source: r for r in store.all()}
        _check("asr_hint: replace_all keeps the hint", after["Нечепуренко"].asr_hint, True)
        _check("asr_hint: replace_all keeps explicit off", after["докер"].asr_hint, False)
        _check("asr_hint: new rows start automatic", after["ЕСА"].asr_hint, None)
        _check("asr_hint: phrases after replace_all",
               store.asr_hotword_phrases(), ["ЕСИА", "Ничипуренко"])
        store.set_asr_hint(surname.id, None)
        _check("asr_hint: None resets", store.get(surname.id).asr_hint, None)
        learned = store.learn([("Клод", "Claude")])
        _check("asr_hint: a learned row starts automatic", learned[0].asr_hint, None)

        # The list window's save carries the hint column.
        baseline = store.all()
        edited = [DraftEntry(r.source, r.replacement, True if r.source == "Клод" else r.asr_hint,
                             r.origin) for r in baseline]
        store.apply_edits(baseline, edited)
        _check("asr_hint: the list save writes a changed hint", store.find("Клод").asr_hint, True)
        _check("asr_hint: the list save keeps the origin", store.find("Клод").origin, Origin.LEARNED)
    finally:
        store.close()
        if reopened is not None:
            reopened.close()
        _remove_db(path)

    fresh = _temp_db()
    store = VocabularyStore(fresh)
    try:
        record = store.upsert("кью 8", "Q8", Origin.LEARNED)
        _check("asr_hint: a brand-new database has the column", record.asr_hint, None)
        _check("asr_hint: a brand-new database selects", store.asr_hotword_phrases(), ["Q8"])
    finally:
        store.close()
        _remove_db(fresh)


_ECHO_HOST = r"""
import json, struct, sys
REQ = struct.Struct("<4sHHQIQ"); RES = struct.Struct("<4sHHQI")
inp, out = sys.stdin.buffer, sys.stdout.buffer
def send(status, rid, body):
    data = json.dumps(body).encode()
    out.write(RES.pack(b"SDAR", 1, status, rid, len(data)) + data); out.flush()
def read(n):
    buf = b""
    while len(buf) < n:
        chunk = inp.read(n - len(buf))
        if not chunk: sys.exit(0)
        buf += chunk
    return buf
while True:
    magic, version, kind, rid, jlen, plen = REQ.unpack(read(REQ.size))
    raw = read(jlen); read(plen)
    if kind == 1:
        send(0, rid, {"provider_actual": "cpu", "model_id": "fake"})
    elif kind == 2:
        body = json.loads(raw or b"{}")
        result = {"text": raw.decode("utf-8"), "processing_seconds": 0.0}
        if body.get("hotwords"):
            result["hotwords_used"] = len(body["hotwords"]) - 1
            result["hotwords_skipped"] = body["hotwords"][-1:]
        send(0, rid, result)
    elif kind == 5:
        sys.exit(0)
"""


def test_asr_hotwords_settings_and_ipc() -> None:
    import numpy as np

    from . import asr_hotwords, onnx_host
    from .settings import Settings

    settings_path = Path(tempfile.mkdtemp()) / "Settings.json"
    settings = Settings(path=settings_path)
    _check("hotwords: on by default", settings.asr_hotwords_enabled, True)
    _check("hotwords: normal strength by default", settings.asr_hotwords_strength, "normal")
    _check("hotwords: default configuration",
           settings.asr_hotwords_configuration(["DDR4 DIMM"]),
           asr_hotwords.HotwordsConfiguration(("DDR4 DIMM",), 2.0))
    settings.apply({"asr_hotwords_strength": "strong"})
    _check("hotwords: strong = 3.0", settings.asr_hotwords_configuration(["x"]).score, 3.0)
    settings.apply({"asr_hotwords_strength": "bogus"})
    _check("hotwords: an unknown strength reads as normal", settings.asr_hotwords_strength, "normal")
    settings.apply({"asr_hotwords_enabled": False})
    _check("hotwords: disabled means no phrases",
           settings.asr_hotwords_configuration(["DDR4 DIMM"]), asr_hotwords.DISABLED)
    _check("hotwords: the switch round-trips", Settings(path=settings_path).asr_hotwords_enabled, False)

    for timestamps in (False, True):
        _check(f"hotwords: an empty list adds no key (timestamps={timestamps})",
               onnx_host.transcribe_options(timestamps=timestamps, hotwords=[], hotwords_score=3.0),
               {"timestamps": timestamps, "sample_rate": 16000})
    biased = onnx_host.transcribe_options(timestamps=False, hotwords=["DDR4 DIMM", "ЕСИА"],
                                          hotwords_score=3.0)
    _check("hotwords: the list and score are sent as given", biased,
           {"timestamps": False, "sample_rate": 16000,
            "hotwords": ["DDR4 DIMM", "ЕСИА"], "hotwords_score": 3.0})

    # On the wire, through a stand-in host that echoes the options back.
    script = Path(tempfile.mkdtemp()) / "echo_host.py"
    script.write_text(_ECHO_HOST, encoding="utf-8")
    host = onnx_host.OnnxHost([sys.executable, "-I", str(script)])
    try:
        host.create(model_directory=Path("m"), assets_directory=Path("a"), threads=1)
        plain = host.transcribe(np.zeros(400, dtype=np.float32))
        _check("hotwords: no list, the pre-hotwords request exactly",
               json.loads(plain.text), {"timestamps": False, "sample_rate": 16000})
        _check("hotwords: no list, no report", plain.hotwords_used, None)
        biased = host.transcribe(np.zeros(400, dtype=np.float32), timestamps=True,
                                 hotwords=("DDR4 DIMM", "ЕСИА", "Ω"), hotwords_score=2.0)
        _check("hotwords: the list reaches the host", json.loads(biased.text),
               {"timestamps": True, "sample_rate": 16000,
                "hotwords": ["DDR4 DIMM", "ЕСИА", "Ω"], "hotwords_score": 2.0})
        _check("hotwords: the host's report is read",
               (biased.hotwords_used, biased.hotwords_skipped), (2, ("Ω",)))
    finally:
        host.shutdown()

    # The NPU (OpenVINO) host has no hotwords: nothing is sent there.
    from . import asr

    configuration = asr_hotwords.HotwordsConfiguration(("DDR4 DIMM",), 2.0)
    cpu = asr.SpeechModel(threads=1)
    cpu.set_hotwords(configuration)
    _check("hotwords: the CPU path sends the list", cpu._request_hotwords(), configuration)
    npu = asr.SpeechModel(threads=1, backend=asr.BACKEND_NPU)
    npu.set_hotwords(configuration)
    _check("hotwords: the NPU path sends none", npu._request_hotwords(), asr_hotwords.DISABLED)


# -- hygiene ---------------------------------------------------------------

def _verdict(source, replacement, existing=()):
    from . import vocabulary_hygiene as h

    verdict = h.review(source, replacement, list(existing))
    if isinstance(verdict, h.Accept):
        return ("accept", verdict.source, verdict.replacement) + (
            (verdict.chain_rewrites,) if verdict.chain_rewrites else ())
    if isinstance(verdict, h.Reject):
        return ("reject", verdict.reason)
    return ("undo", verdict.existing_id)


def test_vocabulary_hygiene_review() -> None:
    from . import vocabulary_hygiene as h

    # §1, the real dictionary's garbage: rejected.
    rejected = [
        ("оплатил", "оплатил.", "punctuation"),
        ("соусом.", "соусом!!", "punctuation"),
        ("инструменты.", "инструменты?", "punctuation"),
        ("интернейшнл.", ".", "no-letters"),
        ("S.", "1", "no-letters"),
        ("Запомню", "Запомни", "inflection"),
        ("дополню,", "дополни,", "inflection"),
        ("пробиваю.", "пробивает.", "inflection"),
        ("капюшонном,", "капюшоном,", "inflection"),
        ("погонял", "погоняло", "inflection"),
        ("сторониной", "стороной", "inflection"),
        ("черноиск", "черновик", "inflection"),
        ("Смотри.", "Задайте вопрос ChatGPT", "rewrite"),
        ("тридцать семь. А", "37А", "rewrite"),
    ]
    for source, replacement, reason in rejected:
        _check(f"hygiene: {source} -> {replacement} rejected",
               _verdict(source, replacement), ("reject", reason))

    # §2's keep-cases: accepted unchanged.
    kept = [
        ("IS60", "IS-60"), ("Metal Fish", "MetalFish"), ("NH C14S", "NH-C14S"),
        ("Амирханян Ц", "АмирханянЦ"), ("Х 99", "Х99"), ("Егр", "ЕГРЮЛ"),
        ("Нечепуренко", "Ничипуренко"), ("красненькову", "Красникову"),
        ("паникший", "поникший"), ("снуху", "слуху"), ("Эмсипи", "MCP"),
        ("Эс эйч", "ssh"), ("Comment", "Command"), ("Юзу ВМ", "УВМ"),
        ("Кад Сендер", "kad sender"), ("DR4 DM", "DDR4 DIMM"), ("ЕСА", "ЕСИА"),
        ("1", "1mm"), ("хаггинг фейс", "Hugging Face"), ("Гетхаб", "Github"),
    ]
    for source, replacement in kept:
        _check(f"hygiene: {source} -> {replacement} kept",
               _verdict(source, replacement), ("accept", source, replacement))

    # Rule 1: edge punctuation goes from both sides.
    _check("hygiene: shared edge punctuation trimmed",
           _verdict("Pipline.", "Pipeline."), ("accept", "Pipline", "Pipeline"))
    _check("hygiene: one-sided edge punctuation trimmed",
           _verdict("Гетхаб.", "Github"), ("accept", "Гетхаб", "Github"))
    _check("hygiene: dashes and spaces at the edges",
           _verdict("Аллес Скарш—", "Alien_skaarj —"), ("accept", "Аллес Скарш", "Alien_skaarj"))
    _check("hygiene: a term's case fix is kept", _verdict("Github", "GitHub"),
           ("accept", "Github", "GitHub"))

    # Several sources for one target are correct.
    docx = [_Rec(1, "докx", "docx"), _Rec(2, "DogX", "docx")]
    _check("hygiene: another source for a known target is kept",
           _verdict("док икс", "docx", docx), ("accept", "док икс", "docx"))

    # Rule 6: undo.
    _check("hygiene: reverting a rule undoes it",
           _verdict("GitHub", "гитхаб", [_Rec(7, "гитхаб", "GitHub", "manual")]), ("undo", 7))
    _check("hygiene: reverting a pre-hygiene rule still undoes it",
           _verdict("Запомни", "Запомню", [_Rec(8, "Запомню", "Запомни")]), ("undo", 8))

    # Rule 7: chains.
    _check("hygiene: a typo of a typo follows the chain",
           _verdict("Pypline.", "Pipline.", [_Rec(3, "Pipline.", "Pipeline.")]),
           ("accept", "Pypline", "Pipeline"))
    _check("hygiene: chains ending at the source collapse onto the new target",
           _verdict("Гитхаб", "GitHub", [_Rec(4, "гит хаб", "Гитхаб")]),
           ("accept", "Гитхаб", "GitHub", ((4, "GitHub"),)))

    # Rule 8: one casing per target.
    _check("hygiene: a manual entry's casing wins",
           _verdict("Гетхаб", "Github", [_Rec(5, "гит хаб", "GitHub", "manual"),
                                         _Rec(6, "гитхабе", "Github", "learned",
                                              updated_at="2026-09-01T00:00:00Z")]),
           ("accept", "Гетхаб", "GitHub"))
    _check("hygiene: otherwise the newest entry's casing",
           _verdict("интернешнл", "international",
                    [_Rec(9, "интернейшенал", "International", updated_at="2026-09-01T00:00:00Z"),
                     _Rec(10, "интер", "INTERNATIONAL", updated_at="2026-01-01T00:00:00Z")]),
           ("accept", "интернешнл", "International"))
    _check("hygiene: Zip follows the manual ZIP",
           _verdict("зип", "Zip", [_Rec(11, "зипка", "ZIP", "manual")]), ("accept", "зип", "ZIP"))

    # The manual editor: rules 1 and 3 only.
    _check("hygiene: manual entries skip the inflection filter",
           h.review_manual("Запомню.", "Запомни."), h.Accept("Запомню", "Запомни"))
    _check("hygiene: manual entries still need letters",
           h.review_manual("S.", "1"), h.Reject("no-letters"))
    _check("hygiene: is_term_like is the hotword predicate", h.is_term_like("ЕГРЮЛ"), True)


def test_vocabulary_hygiene_cleanup() -> None:
    from . import vocabulary_hygiene as h
    from .vocabulary import Origin, VocabularyStore

    path = _temp_db()
    store = VocabularyStore(path)
    try:
        rows = [
            ("оплатил", "оплатил.", "learned"),
            ("интернейшнл.", ".", "learned"),
            ("Запомню", "Запомни", "learned"),
            ("Смотри.", "Задайте вопрос ChatGPT", "learned"),
            ("Pipline.", "Pipeline.", "learned"),
            ("Pypline.", "Pipline.", "learned"),
            ("гитхаб", "GitHub", "manual"),
            ("Гетхаб.", "Github.", "learned"),
            ("зип", "ZIP", "manual"),
            ("Зип,", "Zip,", "learned"),
            ("Гетхаб", "Гитхаб", "learned"),
            ("гитхабе", "Github", "learned"),
            ("зипы", "Zip", "learned"),
            ("докx", "docx", "learned"),
            ("DogX", "docx", "learned"),
            ("Нечепуренко", "Ничипуренко", "learned"),
            ("сторониной", "стороной", "manual"),
        ]
        for source, replacement, origin in rows:
            store.upsert(source, replacement, Origin(origin))
        with store._lock:  # «Гетхаб.» is the older of the two that collapse
            store._db.execute("UPDATE corrections SET updated_at = '2026-01-01T00:00:00Z' "
                              "WHERE source = 'Гетхаб.';")
            store._db.commit()
        plan = store.cleanup_plan()
        deleted = sorted((d.record.source, d.reason) for d in plan.deletions)
        rewritten = sorted((r.record.source, r.source, r.replacement, r.reasons) for r in plan.rewrites)
        _check("cleanup: deletions with reasons", deleted, sorted([
            ("оплатил", "punctuation"),
            ("интернейшнл.", "no-letters"),
            ("Запомню", "inflection"),
            ("Смотри.", "rewrite"),
            ("Гетхаб.", "duplicate"),      # trims onto the newer «Гетхаб»
            ("Зип,", "duplicate"),         # trims onto the manual «зип»
        ]))
        _check("cleanup: rewrites", rewritten, sorted([
            ("Pipline.", "Pipline", "Pipeline", ("trim",)),
            ("Pypline.", "Pypline", "Pipeline", ("trim", "chain")),
            ("Гетхаб", "Гетхаб", "GitHub", ("chain",)),   # Гитхаб → GitHub (manual)
            ("гитхабе", "гитхабе", "GitHub", ("case",)),
            ("зипы", "зипы", "ZIP", ("case",)),
        ]))
        _check("cleanup: duplicates listed",
               sorted(d.record.source for d in plan.duplicates), ["Гетхаб.", "Зип,"])

        store.apply_cleanup(plan)
        after = {r.source: r.replacement for r in store.all()}
        _check("cleanup: manual entries untouched",
               (after.get("гитхаб"), after.get("зип"), after.get("сторониной")),
               ("GitHub", "ZIP", "стороной"))
        _check("cleanup: several sources for one target stay",
               (after.get("докx"), after.get("DogX")), ("docx", "docx"))
        _check("cleanup: the applied result",
               (after.get("Pypline"), after.get("Гетхаб"), "Запомню" in after),
               ("Pipeline", "GitHub", False))
        tomb_keys = {t.key for t in store.tombstones()}
        _check("cleanup: deletions and re-keyed rows leave tombstones",
               {"оплатил", "запомню", "pypline.", "гетхаб.", "зип,"} <= tomb_keys, True)
        _check("cleanup: the re-used key has no tombstone", "гетхаб" in tomb_keys, False)
        _check("cleanup: a second run finds nothing", store.cleanup_plan().is_empty, True)
        _check("cleanup: an empty plan", h.cleanup_plan([]).is_empty, True)
    finally:
        store.close()
        _remove_db(path)


def test_vocabulary_learn_reviewed() -> None:
    from .vocabulary import Origin, VocabularyStore

    path = _temp_db()
    store = VocabularyStore(path)
    try:
        events = []
        store.add_listener(events.append)
        outcome = store.learn_reviewed("оплатил", "оплатил.")
        _check("learn: a rejected candidate writes nothing",
               (outcome.rejected, store.count(), events), ("punctuation", 0, []))
        store.upsert("гит хаб", "Гитхаб", Origin.LEARNED)
        outcome = store.learn_reviewed("Гитхаб.", "GitHub.")
        _check("learn: stored trimmed", [(r.source, r.replacement) for r in outcome.written],
               [("Гитхаб", "GitHub")])
        _check("learn: the chain collapsed", store.find("гит хаб").replacement, "GitHub")
        outcome = store.learn_reviewed("GitHub", "Гитхаб")
        _check("learn: a revert removes the rule",
               (outcome.undone_id is not None, store.find("Гитхаб")), (True, None))
        _check("learn: the revert leaves a tombstone",
               "гитхаб" in {t.key for t in store.tombstones()}, True)
        _check("learn: every write notified", set(events), {"local"})
    finally:
        store.close()
        _remove_db(path)


def test_learn_hygiene_in_edit_watch() -> None:
    """A rejected candidate never reaches the pill; a rewritten one does."""
    import time as _time

    from . import edit_watch
    from . import vocabulary_hygiene as h
    from .focus_target import FieldSnapshot
    from .vocabulary import LearnCandidate

    def run(dictated, edited):
        clock = {"t": 0.0}
        field = dictated + " конец"
        states = [(0, field), (1, edited + " конец")]
        pending, learned = [], []

        def read():
            text = [t for at, t in states if clock["t"] >= at][-1]
            return FieldSnapshot(element=1, pid=1, text=text, caret=None, secure=False)

        def review(candidate):
            verdict = h.review(candidate.source, candidate.replacement, [])
            if isinstance(verdict, h.Accept):
                return LearnCandidate(verdict.source, verdict.replacement)
            return None

        def sleep(seconds):
            clock["t"] += seconds

        watcher = edit_watch.EditWatcher(
            read, lambda c: learned.append((c.source, c.replacement)) or True,
            review=review, on_pending=lambda c, b: pending.append((c.source, c.replacement)),
            clock=lambda: clock["t"], sleep=sleep)
        watcher.begin(dictated)
        deadline = _time.monotonic() + 10
        while watcher._thread is not None and watcher._thread.is_alive() \
                and _time.monotonic() < deadline:
            _time.sleep(0.01)
        watcher.stop()
        return pending, learned

    _check("edit watch: an inflection edit gets no pill",
           run("я Запомню это", "я Запомни это"), ([], []))
    _check("edit watch: a punctuation edit gets no pill",
           run("он оплатил вчера", "он оплатил. вчера"), ([], []))
    _check("edit watch: a real correction is offered trimmed",
           run("залей на гитхаб.", "залей на GitHub."),
           ([("гитхаб", "GitHub")], [("гитхаб", "GitHub")]))


def test_vocabulary_edits_and_tombstones() -> None:
    from .vocabulary import DraftEntry, Origin, VocabularyStore

    path = _temp_db()
    store = VocabularyStore(path)
    try:
        store.upsert("гитхаб", "GitHub", Origin.LEARNED)
        store.upsert("дебиан", "Debian")
        store.upsert("зип", "ZIP")
        with store._lock:  # pretend these are old, so a rewrite would show
            store._db.execute("UPDATE corrections SET updated_at = '2026-01-01T00:00:00Z';")
            store._db.commit()
        baseline = store.all()
        # Meanwhile the sync changes «зип» on the store.
        store.apply_remote([{"source": "зип", "replacement": "ZIP archive", "origin": "manual",
                             "asr_hint": None, "deleted": False,
                             "updated_at": "2026-05-01T00:00:00Z"}])
        edited = [DraftEntry(r.source, r.replacement, r.asr_hint, r.origin)
                  for r in baseline if r.source != "дебиан"]
        edited.append(DraftEntry("кубер", "Kubernetes"))
        store.apply_edits(baseline, edited)
        after = {r.source: r for r in store.all()}
        _check("edits: the unchanged row keeps its stamp and origin",
               (after["гитхаб"].updated_at, after["гитхаб"].origin),
               ("2026-01-01T00:00:00Z", Origin.LEARNED))
        _check("edits: a row the sync changed meanwhile is not reverted",
               after["зип"].replacement, "ZIP archive")
        _check("edits: a removed row is deleted", "дебиан" in after, False)
        _check("edits: an added row is manual", after["кубер"].origin, Origin.MANUAL)
        _check("edits: the removal left a tombstone",
               [t.key for t in store.tombstones()], ["дебиан"])
        store.upsert("Дебиан", "Debian")
        _check("edits: re-adding the key removes the tombstone", store.tombstones(), [])
        store.delete_source("кубер")
        _check("delete: a tombstone", [t.source for t in store.tombstones()], ["кубер"])
        records, tombs = store.local_changes_since("2026-02-01T00:00:00Z")
        _check("changes since: the edited rows and the tombstone",
               (sorted(r.source for r in records), [t.key for t in tombs]),
               (["Дебиан", "зип"], ["кубер"]))
    finally:
        store.close()
        _remove_db(path)


# -- sync against a local server -----------------------------------------------

def _server_directory() -> Path | None:
    here = Path(__file__).resolve().parent.parent  # windows/
    candidate = here.parent / "server" / "vocab-sync"
    return candidate if (candidate / "app.py").is_file() else None


def _server_python() -> str | None:
    """An interpreter with FastAPI and uvicorn: ``SUPERDICTATE_SYNC_TEST_PYTHON``
    or this one."""
    python = os.environ.get("SUPERDICTATE_SYNC_TEST_PYTHON") or sys.executable
    try:
        probe = subprocess.run([python, "-c", "import fastapi, uvicorn"],
                               capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    return python if probe.returncode == 0 else None


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def test_vocabulary_sync_server() -> None:
    import urllib.request

    server_dir = _server_directory()
    python = _server_python() if server_dir is not None else None
    if server_dir is None or python is None:
        print("  (skipped test_vocabulary_sync_server: server/vocab-sync or FastAPI not available)")
        return

    from . import vocabulary_sync as vs
    from .settings import Settings
    from .vocabulary import Origin, VocabularyStore

    work = Path(tempfile.mkdtemp(prefix="sd-sync-selftest-"))
    port = _free_port()
    env = dict(os.environ, VOCAB_SYNC_DB=str(work / "server.sqlite"))
    server = subprocess.Popen(
        [python, "-m", "uvicorn", "app:app", "--host", "127.0.0.1", "--port", str(port),
         "--app-dir", str(server_dir), "--log-level", "warning"],
        cwd=str(work), env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    stores: list = []
    try:
        url = f"http://127.0.0.1:{port}"
        for _ in range(150):
            try:
                with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(
                        url + "/healthz", timeout=1) as response:
                    if response.status == 200:
                        break
            except OSError:
                time.sleep(0.1)
        else:
            _check("sync: the local server starts", server.poll(), None)
            return

        def device(name):
            store = VocabularyStore(str(work / f"{name}.sqlite"))
            stores.append(store)
            settings = Settings(path=work / f"{name}.json")
            settings.update_runtime({"vocabulary_sync_server_url": url})
            tokens = vs.MemoryTokenStore()
            return store, settings, tokens, vs.VocabularySync(store, settings, tokens=tokens)

        a_store, a_settings, a_tokens, a = device("a")
        b_store, b_settings, b_tokens, b = device("b")

        a_store.upsert("гитхаб", "GitHub")
        b_store.upsert("дебиан", "Debian", Origin.LEARNED)   # B's own, before sign-in
        _check("sync: a short password is refused",
               _sync_error(lambda: a.sign_in("user@example.com", "short")), vs.ERROR_INVALID)
        _check("sync: the first sign-in creates the account",
               a.sign_in("User@Example.com", "correct horse"), True)
        _check("sync: the server's e-mail is kept", a_settings.vocabulary_sync_email,
               "user@example.com")
        _check("sync: a wrong password", _sync_error(lambda: b.sign_in("user@example.com", "wrong pass")),
               vs.ERROR_WRONG_PASSWORD)
        _check("sync: the second machine joins", b.sign_in("user@example.com", "correct horse"), False)
        _check("sync: the first sync merged both dictionaries (B)",
               sorted(r.source for r in b_store.all()), ["гитхаб", "дебиан"])
        a.sync_now()
        _check("sync: the first sync merged both dictionaries (A)",
               sorted(r.source for r in a_store.all()), ["гитхаб", "дебиан"])
        _check("sync: the origin travels", a_store.find("дебиан").origin, Origin.LEARNED)
        _check("sync: status after a pass", (a.status.state, a.status.signed_in), (vs.STATE_OK, True))

        # An add on A appears on B, with its hint.
        record = a_store.upsert("кубер", "Kubernetes")
        a_store.set_asr_hint(record.id, False)
        a.sync_now()
        b.sync_now()
        added = b_store.find("кубер")
        _check("sync: an add on A appears on B",
               (added.replacement, added.asr_hint) if added else None, ("Kubernetes", False))
        _check("sync: a remote entry keeps its stamp",
               added.updated_at if added else None, a_store.find("кубер").updated_at)

        # A delete on B removes the entry on A.
        b_store.delete_source("дебиан")
        b.sync_now()
        a.sync_now()
        _check("sync: a delete on B removes it on A", a_store.find("дебиан"), None)
        _check("sync: and records the tombstone on A",
               "дебиан" in {t.key for t in a_store.tombstones()}, True)

        # A conflict: the newer updated_at wins on both machines.
        for store, replacement, stamp in ((a_store, "GitHub Enterprise", "2030-01-01T00:00:00Z"),
                                          (b_store, "GitHub.com", "2031-01-01T00:00:00Z")):
            with store._lock:
                store._db.execute("UPDATE corrections SET replacement = ?, updated_at = ? "
                                  "WHERE source = 'гитхаб';", (replacement, stamp))
                store._db.commit()
        a.sync_now()
        b.sync_now()
        a.sync_now()
        _check("sync: the newer edit wins on both",
               (a_store.find("гитхаб").replacement, b_store.find("гитхаб").replacement),
               ("GitHub.com", "GitHub.com"))

        # The hint travels on its own change too.
        surname = b_store.upsert("нечепуренко", "Ничипуренко", Origin.LEARNED)
        b.sync_now()
        a.sync_now()
        a_store.set_asr_hint(a_store.find("нечепуренко").id, True)
        with a_store._lock:  # one-second stamps: make the hint change strictly newer
            a_store._db.execute("UPDATE corrections SET updated_at = '2032-01-01T00:00:00Z' "
                                "WHERE source = 'нечепуренко';")
            a_store._db.commit()
        a.sync_now()
        b.sync_now()
        _check("sync: asr_hint travels with the entry", b_store.get(surname.id).asr_hint, True)
        _check("sync: and makes it a hotword there",
               "Ничипуренко" in b_store.asr_hotword_phrases(), True)

        # A pass with nothing new changes nothing.
        _check("sync: an idle pass applies nothing", (a.sync_now(), b.sync_now()), (0, 0))

        # 401: the token is dropped and the user is asked to sign in again.
        b_tokens.save("not-a-real-token")
        _check("sync: a refused token raises unauthorized", _sync_error(b.sync_now),
               vs.ERROR_UNAUTHORIZED)
        _check("sync: and is dropped", b_tokens.load(), None)
        _check("sync: the status asks to sign in again", b.status.state, vs.STATE_REAUTH)
        _check("sync: signed out after a 401", b.signed_in, False)

        a.sign_out()
        _check("sync: signing out drops the token", (a_tokens.load(), a.signed_in), (None, False))
        _check("sync: signing out resets the cursors",
               (a_settings.vocabulary_sync_last_server_revision,
                a_settings.vocabulary_sync_last_pushed_local_stamp), (0, ""))
    finally:
        for store in stores:
            store.close()
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()


def _sync_error(call) -> str:
    from .vocabulary_sync import SyncError

    try:
        call()
    except SyncError as exc:
        return exc.kind
    return "no error"


def test_sync_settings_and_token() -> None:
    from . import vocabulary_sync as vs
    from .settings import Settings

    work = Path(tempfile.mkdtemp(prefix="sd-sync-token-"))
    settings = Settings(path=work / "Settings.json")
    _check("sync: off by default", settings.vocabulary_sync_enabled, False)
    _check("sync: the default server", settings.vocabulary_sync_server_url,
           "https://superdictate.bykovlegal.ru")
    settings.update_runtime({"vocabulary_sync_enabled": True,
                             "vocabulary_sync_last_server_revision": 42})
    # The settings window's draft is a snapshot from before the sign-in.
    settings.apply({"vocabulary_sync_enabled": False,
                    "vocabulary_sync_last_server_revision": 0, "play_feedback_sounds": False})
    _check("sync: a stale settings draft does not undo the sign-in",
           (settings.vocabulary_sync_enabled, settings.vocabulary_sync_last_server_revision,
            settings.play_feedback_sounds), (True, 42, False))

    path = work / "VocabularySync.token"
    tokens = vs.DpapiTokenStore(path)
    _check("token: none at first", tokens.load(), None)
    tokens.save("secret-token-value")
    _check("token: round-trips", vs.DpapiTokenStore(path).load(), "secret-token-value")
    if sys.platform == "win32":
        _check("token: not stored in the clear", b"secret-token-value" in path.read_bytes(), False)
    tokens.clear()
    _check("token: cleared", (tokens.load(), path.exists()), (None, False))


TESTS = [
    test_asr_hotword_selection,
    test_asr_hint_store,
    test_asr_hotwords_settings_and_ipc,
    test_vocabulary_hygiene_review,
    test_vocabulary_hygiene_cleanup,
    test_vocabulary_learn_reviewed,
    test_learn_hygiene_in_edit_watch,
    test_vocabulary_edits_and_tombstones,
    test_sync_settings_and_token,
    test_vocabulary_sync_server,
]


def run_all() -> bool:
    FAILURES.clear()
    for test in TESTS:
        try:
            test()
        except Exception as exc:
            import traceback

            FAILURES.append(f"{test.__name__} raised {type(exc).__name__}: {exc}\n"
                            + traceback.format_exc())
    if FAILURES:
        print(f"FAILED: {len(FAILURES)} problem(s) in {len(TESTS)} tests\n")
        for failure in FAILURES:
            print(f"  * {failure}")
        return False
    print(f"OK: {len(TESTS)} vocabulary/hotword self-tests passed")
    return True


if __name__ == "__main__":
    sys.exit(0 if run_all() else 1)
