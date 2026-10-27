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
| [Parakeet TDT 0.6B v3, OpenVINO](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-ov) (FluidInference, зеркало [VoiceScribe](https://huggingface.co/VoiceScribe/voicescribe-parakeet)) | CC-BY-4.0 | модель для NPU |
| [GigaAM v3](https://huggingface.co/ai-sage/GigaAM-v3), OpenVINO и NPU-калибровка [Andrewsab](https://huggingface.co/Andrewsab/gigaam-v3-e2e-rnnt-ov-npu) (зеркала [VoiceScribe](https://huggingface.co/VoiceScribe/voicescribe-gigaam-npu)) | MIT | модель для NPU |
| [Horizon Labs punctuation-restoration](https://huggingface.co/Horizon-Labs/punctuation-restoration-base) (Small, Base; на основе [mmBERT](https://huggingface.co/jhu-clsp/mmBERT-base), MIT) | Apache-2.0 | восстановление пунктуации |
| [OpenVINO](https://github.com/openvinotoolkit/openvino) | Apache-2.0 | исполнение моделей на NPU |
| [ONNX Runtime](https://onnxruntime.ai/) | MIT | исполнение модели |
| [PySide6](https://doc.qt.io/qtforpython/) | LGPLv3 | интерфейс |
| [sounddevice](https://python-sounddevice.readthedocs.io/) / PortAudio | MIT | захват звука |
| [pycaw](https://github.com/AndreMiras/pycaw) | MIT | приглушение системного звука |

Веса модели не входят в состав установщика: они скачиваются при первом
запуске в `%LOCALAPPDATA%\Dictation\Models` и остаются под лицензией
CC-BY-4.0 NVIDIA.
