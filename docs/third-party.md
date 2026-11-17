# Внешние компоненты диаризации

В репозитории нет весов моделей или скопированных библиотек. Инструменты установки получают их в отдельный каталог для локальной разработки.

| Компонент | Закрепление | Источник |
|---|---|---|
| sherpa-onnx | v2.0.1; SHA-256 release asset отдельно для Linux x86_64, macOS arm64 и x86_64 | https://github.com/k2-fsa/sherpa-onnx/releases/tag/v2.0.1 |
| Pyannote segmentation 3.0 ONNX | revision 9403a6902bb58e3d5ae8c7e77c3422de279db2e0; SHA-256 220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079 | https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0 |
| WeSpeaker VoxCeleb ResNet34 ONNX | revision 0743f301363dec56491a490f6d6cbc9d67f9a3bf; SHA-256 5ef208a9da1453335308a6b6f4e6dfbd7e183a38b604de0a57664f45d257fe94 | https://huggingface.co/csukuangfj/speaker-embedding-models |

sherpa-onnx публикуется под Apache-2.0; ONNX Runtime — MIT. В закреплённом репозитории segmentation есть LICENSE MIT (CNRS, 2022). Исходный WeSpeaker публикуется под Apache-2.0: https://github.com/wenet-e2e/wespeaker/blob/master/LICENSE. В используемом зеркале embedding-файла отдельная карточка лицензии весов не обнаружена; не следует считать лицензию исходного кода отдельным подтверждением условий распространения весов. Сейчас веса используются локально и не включены в поставку проекта.

Тестовый файл 1-two-speakers-en.wav получен из официального релиза speaker-segmentation-models; release API не предоставляет для него digest. Загрузка выполнена через HTTPS, фактический SHA-256 сохранён в отчёте. Это исходный пример для функциональной проверки, не размеченный корпус DER. Аудио в репозиторий не добавлено.

Перед упаковкой моделей в распространяемое приложение потребуется оформить уведомления и подтвердить условия распространения конкретных весов. Текущие результаты относятся к локальной разработке.
