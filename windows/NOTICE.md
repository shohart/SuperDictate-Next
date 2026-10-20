# Происхождение / Attribution

Это порт для Windows. Он не содержит кода macOS-версии (весь код написан
заново на Python + PySide6), но повторяет её поведение, названия настроек
и структуру данных, поэтому цепочка авторства сохраняется целиком.

| Проект | Автор | Роль |
| --- | --- | --- |
| [Parakey](https://github.com/rcourtman/Parakey) | Richard Courtman | оригинал (macOS, Swift) |
| [SuperDictate](https://github.com/shlgd/SuperDictate) | shlgd | форк Parakey, от которого взято поведение |
| Dictation for Windows | metawka | этот порт (Python, PySide6) |

Все три распространяются по лицензии MIT, см. [LICENSE](LICENSE).

## Сторонние компоненты

| Компонент | Лицензия | Назначение |
| --- | --- | --- |
| [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | CC-BY-4.0 (NVIDIA) | модель распознавания речи |
| [onnx-asr](https://github.com/istupakov/onnx-asr) | MIT | загрузчик и декодер модели |
| [ONNX Runtime](https://onnxruntime.ai/) | MIT | исполнение модели |
| [PySide6](https://doc.qt.io/qtforpython/) | LGPLv3 | интерфейс |
| [sounddevice](https://python-sounddevice.readthedocs.io/) / PortAudio | MIT | захват звука |
| [pycaw](https://github.com/AndreMiras/pycaw) | MIT | приглушение системного звука |

Веса модели не входят в состав установщика: они скачиваются при первом
запуске в `%LOCALAPPDATA%\Dictation\Models` и остаются под лицензией
CC-BY-4.0 NVIDIA.
