"""Russian / English interface strings.

macOS calls ``localizedText(russian, english, language:)`` at every use
site. The same idea, one table: ``tr("key")`` reads the currently selected
language, and the RU/EN toggle in settings takes effect immediately
because nothing caches the resolved string.
"""

from __future__ import annotations

_LANGUAGE = "ru"

_STRINGS: dict[str, tuple[str, str]] = {
    # -- status ------------------------------------------------------
    "app_name": ("SuperDictate", "SuperDictate"),
    "status_starting": ("Запуск…", "Starting…"),
    "status_downloading": ("Загрузка модели", "Downloading model"),
    "status_loading": ("Загрузка модели в память", "Loading model"),
    "status_ready": ("Работает", "Ready"),
    "status_recording": ("Запись", "Recording"),
    "status_correcting": ("Обработка текста", "Post-processing"),

    # -- vocabulary --------------------------------------------------
    "vocabulary_learned_title": ("Запомнил:", "Learned:"),
    "vocabulary_undo": ("Отменить", "Undo"),
    "vocabulary_undone": ("Правило удалено", "Rule removed"),

    # -- post-processing toasts --------------------------------------
    "toast_correction_on": ("Коррекция · вкл", "Correction · on"),
    "toast_correction_off": ("Коррекция · выкл", "Correction · off"),
    "toast_rewrite_on": ("Рерайт · вкл · {style}", "Rewrite · on · {style}"),
    "toast_rewrite_off": ("Рерайт · выкл", "Rewrite · off"),
    "toast_rewrite_style": ("Режим · {style}", "Style · {style}"),
    "toast_loading_model": ("Загружается модель…", "Loading model…"),
    "rewrite_style_polish": ("Причесать", "Polish"),
    "rewrite_style_structured_task": ("Задача", "Structured task"),
    "rewrite_style_official": ("Официальный", "Formal"),

    # -- vocabulary transfer -----------------------------------------
    "corrections_export": ("Экспорт…", "Export…"),
    "corrections_import": ("Импорт…", "Import…"),
    "corrections_imported": ("Добавлено правил: {count}",
                             "{count} rule(s) added"),
    "corrections_imported_partial": (
        "Добавлено правил: {count}, пропущено непригодных: {skipped}",
        "{count} rule(s) added, {skipped} unusable entr(ies) skipped"),
    "corrections_export_failed": ("Не удалось сохранить файл: {error}",
                                  "Could not save the file: {error}"),
    "corrections_import_failed": ("Не удалось прочитать файл: {error}",
                                  "Could not read the file: {error}"),

    # -- post-processing settings ------------------------------------
    "settings_tab_postprocessing": ("Обработка", "Post-processing"),
    "settings_correction": ("Коррекция", "Correction"),
    "settings_correction_hint": (
        "Исправляет ошибки распознавания и возвращает английским терминам "
        "латинское написание. Работает локально, ничего не уходит в сеть.",
        "Fixes recognition errors and restores canonical Latin spelling for "
        "English terms. Runs locally; nothing leaves the machine."),
    "settings_correction_mode": ("Коррекция текста", "Text correction"),
    "settings_correction_off": ("Выключена", "Off"),
    "settings_correction_on": ("Включена", "On"),
    "settings_correction_model": ("Модель", "Model"),
    "settings_correction_prompt": ("Свой промпт", "Custom prompt"),
    "settings_rewrite": ("Переписывание", "Rewrite"),
    "settings_rewrite_hint": (
        "Переписывает продиктованное в выбранном стиле. В отличие от "
        "коррекции, может менять структуру текста.",
        "Rewrites the dictation in the chosen style. Unlike correction, it "
        "may restructure the text."),
    "settings_rewrite_enabled": ("Включить переписывание", "Enable rewrite"),
    "settings_rewrite_style": ("Режим", "Mode"),
    "settings_rewrite_model": ("Модель", "Model"),
    "settings_prompt_placeholder": (
        "Пусто — используется встроенный промпт",
        "Empty — the built-in prompt is used"),
    "settings_llm_models": ("Веса моделей", "Model weights"),
    "settings_llm_models_hint": (
        "Скачиваются один раз и лежат локально. Проверяются по размеру и "
        "контрольной сумме — как и на macOS.",
        "Downloaded once and kept locally. Verified by size and checksum, "
        "the same as on macOS."),
    "settings_model_present": ("Загружена · {size} МБ", "Downloaded · {size} MB"),
    "settings_model_absent": ("Не загружена · {size} МБ", "Not downloaded · {size} MB"),
    "settings_model_failed": ("Ошибка: {error}", "Failed: {error}"),
    "settings_model_download": ("Скачать", "Download"),
    "llm_model_voicescribe": ("Быстрая (0.8B + адаптер)", "Fast (0.8B + adapter)"),
    "llm_model_yandexgpt": ("Качественная (8B)", "Quality (8B)"),

    # -- compute devices, one per engine -----------------------------
    "settings_llm_device": ("Где считать", "Where it runs"),
    "settings_llm_device_hint": (
        "Настраивается отдельно от распознавания речи: языковая модель "
        "заметно быстрее на видеокарте, а Parakeet на этих машинах "
        "оказывается быстрее и точнее на процессоре.",
        "Set independently of speech recognition: the language model is "
        "much faster on the GPU, while Parakeet turns out faster and more "
        "accurate on the CPU on these machines."),
    "settings_llm_backend": ("Обработка текста", "Text post-processing"),
    "settings_llm_backend_gpu": ("Видеокарта", "GPU"),
    "settings_llm_backend_cpu": ("Процессор", "CPU"),

    # -- HUD ---------------------------------------------------------
    "settings_hud_display_mode": ("Что показывать во время записи",
                                  "While recording, show"),
    "settings_hud_display_bars": ("Полоски уровня", "Level bars"),
    "settings_hud_display_timer": ("Таймер", "Timer"),
    "settings_hud_display_hint": (
        "Таймер появляется после десяти секунд диктовки — короткие "
        "фразы остаются с полосками.",
        "The timer appears ten seconds in; short dictations keep the bars."),
    "status_transcribing": ("Расшифровка", "Transcribing"),
    "status_failed": ("Ошибка", "Failed"),
    "status_no_microphone": ("Нет доступа к микрофону", "No microphone access"),
    "status_hook_failed": ("Хоткеи не перехватываются", "Hotkeys not captured"),

    # -- tray --------------------------------------------------------
    "tray_open_panel": ("Панель управления", "Control panel"),
    "tray_settings": ("Настройки", "Settings"),
    "tray_history": ("История", "History"),
    "tray_start": ("Начать диктовку", "Start dictation"),
    "tray_stop": ("Остановить", "Stop"),
    "tray_quit": ("Выйти", "Quit"),

    # -- control panel ----------------------------------------------
    "panel_service": ("Служба", "Service"),
    "panel_model": ("Модель", "Model"),
    "panel_hotkey": ("Диктовка", "Dictation"),
    "panel_hotkey_history": ("История", "History"),
    "panel_hotkey_edit": ("Правка", "Edit"),
    "panel_restart": ("Перезапустить", "Restart"),
    "panel_check_updates": ("Проверить обновления", "Check for updates"),
    "panel_compute": ("Вычисления", "Compute"),
    "panel_today": ("Сегодня", "Today"),
    "panel_total": ("Всего", "Total"),
    "panel_dictations": ("диктовок", "dictations"),
    "panel_words": ("слов", "words"),
    "panel_microphone": ("Микрофон", "Microphone"),
    "panel_shortcuts": ("Сочетания клавиш", "Shortcuts"),
    "panel_statistics": ("Статистика", "Statistics"),

    # -- statistics --------------------------------------------------
    "stats_today_dictations": ("Сегодня", "Today"),
    "stats_today_words": ("Слова", "Words"),
    "stats_total_dictations": ("Всего", "All time"),
    "stats_total_time": ("Наговорено", "Dictated"),
    # Suffixes for numbers a tile cannot hold in full. Cyrillic К and М in
    # Russian, so they match the surrounding text rather than sitting in it
    # as two Latin letters.
    "stats_short_thousand": ("К", "K"),
    "stats_short_million": ("М", "M"),
    "stats_short_billion": ("Б", "B"),
    "stats_unit_today": ("диктовок", "dictations"),
    "stats_unit_words_today": ("слов", "words"),
    "stats_unit_hours": ("времени", "of audio"),
    "stats_unit_minutes": ("времени", "of audio"),
    "stats_last_14_days": ("Последние 14 дней", "Last 14 days"),
    "stats_activity": ("Активность", "Activity"),

    # -- settings ----------------------------------------------------
    "settings_title": ("Настройки Dictation", "Dictation Settings"),
    "settings_tab_hotkeys": ("Сочетания", "Shortcuts"),
    "settings_tab_dictation": ("Диктовка", "Dictation"),
    "settings_tab_appearance": ("Вид", "Appearance"),
    "settings_tab_corrections": ("Замены", "Replacements"),
    "settings_tab_advanced": ("Дополнительно", "Advanced"),
    "settings_section_behaviour": ("Поведение", "Behaviour"),
    "settings_section_recognition": ("Распознавание", "Recognition"),
    "settings_section_capture": ("Запись", "Capture"),
    "settings_primary_hotkey": ("Основное сочетание", "Primary shortcut"),
    "settings_history_hotkey": ("Последние расшифровки", "Recent transcripts"),
    "settings_history_hotkey_hint": (
        "Показывает последние расшифровки пузырьками над капсулой. Стрелки "
        "выбирают, Enter вставляет выбранную в то поле, где вы были, Delete "
        "удаляет её из истории, Escape закрывает. Полная история со всеми "
        "записями открывается из трея и из панели управления.",
        "Shows the last few transcripts as bubbles above the capsule. The "
        "arrow keys choose, Enter inserts the chosen one into the field you "
        "came from, Delete forgets it, Escape closes. The full history opens "
        "from the tray and from the control panel."),
    "settings_edit_hotkey": ("Правка расшифровки", "Edit transcript"),
    "settings_edit_hotkey_hint": (
        "Возвращает на экран капсулу с текстом последней диктовки. Текст "
        "можно поправить прямо в ней: Enter сохраняет, Escape закрывает без "
        "изменений. Исправленные слова запоминаются как замены и применяются "
        "к следующим диктовкам. Само поле ввода, куда текст был вставлен, не "
        "трогается — Windows не даёт одной программе править текст в другой.",
        "Brings the capsule back with the text of the last dictation. It can "
        "be corrected right there: Enter saves, Escape closes without "
        "changes. Corrected words are remembered as replacements and applied "
        "to later dictations. The field the text was pasted into is left "
        "alone — Windows does not let one application edit text in another."),
    "settings_record": ("Записать", "Record"),
    "settings_trigger_mode": ("Режим", "Mode"),
    "settings_trigger_hold": ("Удерживать", "Press and hold"),
    "settings_trigger_toggle": ("Нажать и нажать снова", "Press to toggle"),
    "settings_completion": ("Повторное нажатие", "Second press"),
    "settings_completion_insert": ("Вставить текст", "Insert text"),
    "settings_completion_enter": ("Вставить текст и Enter", "Insert text and press Enter"),
    "settings_text_style": ("Стиль текста", "Text style"),
    "settings_text_style_formal": ("Формальный", "Formal"),
    "settings_text_style_standard": ("Стандартный", "Standard"),
    "settings_text_style_informal": ("Неформальный", "Informal"),
    "settings_text_style_casual": ("Разговорный", "Casual"),
    "settings_text_style_formal_hint": (
        "Текст вставляется ровно таким, каким его распознала модель: "
        "с заглавной буквы и с точкой в конце.",
        "The text is inserted exactly as recognised: leading capital, "
        "full stop at the end.",
    ),
    "settings_text_style_standard_hint": (
        "Точка в конце убирается, всё остальное остаётся как есть.",
        "The final full stop is dropped, everything else stays.",
    ),
    "settings_text_style_informal_hint": (
        "Точки в конце нет, и первая буква строчная.",
        "No full stop at the end, and the first letter is lowercase.",
    ),
    "settings_text_style_casual_hint": (
        "Заглавных нет вообще, кроме аббревиатур, а точки внутри фразы "
        "заменяются запятыми, так что реплика идёт одной строкой.",
        "No capitals at all except acronyms, and full stops inside the "
        "sentence become commas, so the line reads as one remark.",
    ),
    "settings_enter_delay": ("Задержка перед Enter, мс", "Delay before Enter, ms"),
    "settings_paste_suffix": ("После вставки", "After insertion"),
    "settings_suffix_space": ("Добавить пробел", "Append space"),
    "settings_suffix_none": ("Ничего", "No suffix"),
    "settings_suffix_newline": ("Перевод строки", "Append newline"),
    "settings_language": ("Язык диктовки", "Dictation language"),
    "settings_interface_language": ("Язык интерфейса", "Interface language"),
    "settings_input_device": ("Устройство ввода", "Input device"),
    "settings_device_default": ("Системное по умолчанию", "System default"),
    "settings_remove_fillers": ("Удалить слова-паразиты",
                                "Remove filler words"),
    "settings_fillers_list": ("Список слов", "Word list"),
    "settings_fillers_list_count": ("Список слов ({count})",
                                    "Word list ({count})"),
    "settings_fillers_note": (
        "Отмеченные слова удаляются из расшифровки. По умолчанию отмечены "
        "только звуки запинки: «это», «вот», «короче» и подобные — обычные "
        "слова, и удалять их без спроса значит менять сказанное. Своё слово "
        "или фраза добавляются в поле ниже.",
        "Ticked words are removed from the transcript. Only hesitation "
        "sounds are ticked by default: \"like\", \"actually\" and the rest "
        "are ordinary words, and removing those uninvited would change what "
        "was said. Add your own word or phrase in the field below.",
    ),
    "settings_fillers_add": ("Своё слово или фраза",
                             "Your own word or phrase"),
    "settings_numbers_as_digits": ("Числа цифрами",
                                   "Numbers as digits"),
    "settings_numbers_as_digits_hint": (
        "«Двадцать три» превращается в «23». Работает до 999.",
        "\"Twenty three\" becomes \"23\". Works up to 999.",
    ),
    "settings_mute": ("Отключать звук системы во время записи",
                      "Mute system output while recording"),
    "settings_pause_media": ("Ставить воспроизведение на паузу",
                             "Pause playback while recording"),
    "settings_pause_media_hint": (
        "В начале записи нажимается клавиша «пауза», в конце — ещё раз, "
        "так что видео или музыка продолжаются с того же места. Если в "
        "момент начала записи ничего не играло, нажатия не будет.",
        "The play/pause media key is pressed when the recording starts and "
        "again when it ends, so a video or a track continues where it left "
        "off. If nothing was playing, nothing is pressed.",
    ),
    "settings_stop_on_silence": (
        "Завершать запись автоматически после паузы",
        "Finish the recording automatically after a pause",
    ),
    "settings_silence_seconds": ("Длина паузы, с", "Pause length, s"),
    "settings_stop_on_silence_hint": (
        "Отсчёт начинается только после первых произнесённых слов.",
        "The countdown only starts once you have actually said something.",
    ),
    "settings_sounds": ("Звуковые сигналы", "Feedback sounds"),
    "settings_autostart": ("Запускать при входе в Windows", "Start at Windows login"),
    "settings_check_updates": ("Проверять обновления", "Check for updates"),
    "settings_waveform": ("Показывать капсулу с волной", "Show waveform capsule"),
    "settings_live_preview": ("Показывать текст во время записи",
                              "Show text while recording"),
    "settings_live_preview_hint": (
        "Над капсулой появляется вторая, поменьше, с расшифровкой на ходу. "
        "Слова по мере речи могут переписываться, а окончательный текст "
        "распознаётся заново после остановки. Занимает процессор всё время "
        "записи.",
        "A second, smaller capsule above the first, transcribing as you "
        "speak. Words can be rewritten as more audio arrives, and the final "
        "text is recognised again once recording stops. Costs CPU for the "
        "whole recording.",
    ),
    "settings_hud_size": ("Размер капсулы", "Capsule size"),
    "settings_hud_size_compact": ("Компактный", "Compact"),
    "settings_hud_size_standard": ("Стандартный", "Standard"),
    "settings_hud_size_large": ("Крупный", "Large"),
    "settings_hud_recording_color": ("Цвет записи", "Recording color"),
    "settings_hud_transcribing_color": ("Цвет расшифровки", "Transcribing color"),
    "settings_color_gradient": ("Градиент", "Gradient"),
    "settings_color_pick": ("Выбор цвета", "Pick a color"),
    "settings_color_hint": (
        "Нажмите на цвет, чтобы выбрать любой другой. С градиентом "
        "капсула заливается переходом между двумя цветами.",
        "Click a colour to pick any other. With a gradient the capsule is "
        "filled with a ramp between the two.",
    ),
    "settings_history_limit": ("Быстрая история", "Quick history"),
    "settings_history_off": ("Выключена", "Off"),
    "settings_history_last": ("Последние {n}", "Last {n}"),
    "settings_speech_model": ("Модель распознавания", "Speech model"),
    "settings_model_parakeet_ultra": ("Parakeet Ultra 0.6B · 25 языков",
                                      "Parakeet Ultra 0.6B · 25 languages"),
    "settings_model_gigaam_v3": ("GigaAM v3 · только русский",
                                 "GigaAM v3 · Russian only"),
    "settings_speech_model_hint": (
        "Распознавание идёт на процессоре, как и на macOS. GigaAM заметно "
        "точнее на русском, но других языков не знает. Модель скачивается "
        "при первом выборе (~600 / ~220 МБ).",
        "Recognition runs on the CPU, as on macOS. GigaAM is noticeably more "
        "accurate on Russian but knows no other language. The model "
        "downloads the first time it is chosen (~600 / ~220 MB)."),
    "settings_save_restart": ("Сохранить и перезапустить", "Save and restart"),
    "settings_cancel": ("Отмена", "Cancel"),

    # -- shortcut recorder ------------------------------------------
    "recorder_title": ("Новое сочетание", "Record shortcut"),
    "recorder_instruction": (
        "Нажмите одну клавишу или сочетание. Escape закроет окно без изменений.",
        "Press one key or a shortcut. Escape closes without changes.",
    ),
    "recorder_nothing": ("Ничего не выбрано", "Nothing selected"),
    "recorder_save": ("Сохранить", "Save"),

    # -- corrections -------------------------------------------------
    "corrections_source": ("Слышится как", "Heard as"),
    "corrections_replacement": ("Заменить на", "Replace with"),
    "corrections_add": ("Добавить", "Add"),
    "corrections_remove": ("Удалить", "Remove"),
    "corrections_note": (
        "Замены применяются к тексту до вставки; регистр игнорируется, "
        "совпадение по целым словам.",
        "Replacements are applied before insertion; matching is "
        "case-insensitive and whole-word.",
    ),

    # -- history window ----------------------------------------------
    "history_title": ("История диктовок", "Dictation history"),
    "history_empty": ("Пока пусто", "Nothing yet"),
    "history_insert": ("Вставить", "Insert"),
    "history_copy": ("Копировать", "Copy"),
    "history_delete": ("Удалить", "Delete"),
    "history_clear": ("Очистить всё", "Clear all"),
    "history_hint": (
        "Enter, вставить в активное окно. Esc, закрыть.",
        "Enter inserts into the active window, Esc closes.",
    ),

    # -- updates -----------------------------------------------------
    "update_available": ("Доступна версия {version}", "Version {version} available"),
    "update_none": ("Установлена последняя версия", "You are up to date"),
    "update_checking": ("Проверка…", "Checking…"),
    "update_failed": ("Не удалось проверить обновления", "Update check failed"),
    "update_open": ("Открыть страницу релиза", "Open release page"),
    "update_notification": (
        "Доступна версия {version}. Нажмите, чтобы открыть страницу релиза.",
        "Version {version} is available. Click to open the release page.",
    ),
    "update_opened": (
        "Доступна версия {version}, страница релиза открыта в браузере",
        "Version {version} available, the release page is open in the browser",
    ),
    "update_no_windows_build": (
        "Для Windows сборка ещё не опубликована",
        "No Windows build published yet",
    ),

    # -- errors ------------------------------------------------------
    # Two separate causes: a real permission block, and everything else
    # (device busy, unplugged, driver refusing the format). Reporting the
    # second as the first sent users hunting through privacy settings for
    # a problem that was not there.
    "error_microphone_denied": (
        "Windows не дал доступ к микрофону. Откройте Параметры → "
        "Конфиденциальность → Микрофон и разрешите доступ приложениям.",
        "Windows denied microphone access. Open Settings → Privacy → "
        "Microphone and allow desktop apps.",
    ),
    "error_microphone": (
        "Не удалось открыть микрофон: {reason}",
        "Could not open the microphone: {reason}",
    ),
    "error_microphone_busy": (
        "Микрофон занят другим приложением",
        "The microphone is in use by another application",
    ),
    "error_hook": (
        "Не удалось установить перехват клавиатуры. Запустите приложение "
        "от того же уровня прав, что и целевое окно.",
        "Could not install the keyboard hook. Run the app at the same "
        "privilege level as the window you type into.",
    ),
    "error_too_short": ("Слишком короткая запись", "Recording too short"),
    "error_no_speech": ("Речь не распознана", "No speech recognized"),
}


def set_language(language: str) -> None:
    global _LANGUAGE
    _LANGUAGE = "en" if language == "en" else "ru"


def language() -> str:
    return _LANGUAGE


_MONTHS: tuple[tuple[str, str], ...] = (
    ("янв", "Jan"), ("фев", "Feb"), ("мар", "Mar"), ("апр", "Apr"),
    ("май", "May"), ("июн", "Jun"), ("июл", "Jul"), ("авг", "Aug"),
    ("сен", "Sep"), ("окт", "Oct"), ("ноя", "Nov"), ("дек", "Dec"),
)


def month_abbr(month: int) -> str:
    """Abbreviated month name. ``strftime('%b')`` follows the C locale,
    which is English no matter what the interface language is."""
    return _MONTHS[month - 1][0 if _LANGUAGE == "ru" else 1]


def tr(key: str, **kwargs) -> str:
    pair = _STRINGS.get(key)
    if pair is None:
        return key
    text = pair[0] if _LANGUAGE == "ru" else pair[1]
    return text.format(**kwargs) if kwargs else text
