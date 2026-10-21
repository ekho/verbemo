# Verbemo: эталон интерфейса

План и требования: [issue #21](https://github.com/ekho/verbemo/issues/21), [план реализации](../../superpowers/plans/2026-10-20-unified-interface.md).

`prototype.html` — финальный интерактивный UX-макет от 20.10.2026, SHA-256 `92580e26aa8a8cbc712d1cae70b7469864c05b8c86f7498dc5b6c7f3fd888473`. Обработка, модели, запись и календарь в HTML имитируются; его defaults и размеры файлов не являются спецификацией конфигурации нативного приложения.

## Сохранение функций

| Функция | Целевое место | macOS / Windows | Проверка |
|---|---|---|---|
| Запись, пауза, live | Общая полоса и активная встреча | Обе | RecordingWorkspaceTests |
| Архив, фильтры, поиск | Все встречи / В обработке / Нужны действия | Обе | MeetingPresentationTests |
| Версии, аудио и файлы | Карточка и выбор версии | Обе | TranscriptVersionsTests / RecordingActionsTests |
| Копирование и повтор | Общее меню и текстовые вкладки | Обе | MeetingMenuTests / SummaryRegenerationTests |
| Настройки / разрешения | Шесть разделов; редкие поля внутри них | Обе с платформенными разрешениями | SettingsNavigationTests |
| Модели / загрузки | Расшифровка / Хранение и модели | Каталог платформы | ModelSettingsTests |
| Календарь / говорящие | Карточка события / расшифровка | EventKit на Mac; сохранённый контекст на Windows | MeetingCalendarMetadataTests / SpeakerParticipantMappingTests |
| Автостарт, tray/menu, выход, updates | Настройки / системное меню | Обе | ApplicationWindowTests / существующие runtime tests |
| Диаризация retry/skip, неизвестные подписи | Ошибка во встрече | Существующие возможности платформы | MeetingLibraryControllerTests / diarization lifecycle |
| Недеструктивное удаление | Удалить с подтверждением и отменой | Обе | SessionDeletionTests |

Снимки фиксируют согласованную терминологию «Сводка» и меню; не являются доказательством реализации нативного UI.
