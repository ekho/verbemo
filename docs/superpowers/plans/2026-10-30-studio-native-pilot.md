# Studio native pilot — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Work sequentially in the existing epic branch; delegation has not been selected.

**Goal:** Проверить один настоящий сценарий «открыть → читать/слушать → назначить участника → найти фразу» сначала на macOS, затем на Windows.

**Architecture:** Сохранить текущие сервисы, форматы, AppKit shell и WPF. На Mac сохранить строку названия/деталей в AppKit, под ней разместить общий плеер, затем встроить SwiftUI-блок версий/поиска/вкладок через один NSHostingView; сохранить NSTableView для длинной расшифровки, существующие assignment editor и AVPlayer. Поиск — по загруженному тексту одной выбранной версии, без фонового индекса и новых зависимостей.

**Tech Stack:** Swift 6 / macOS 14.2+, SwiftUI + AppKit, Swift Testing; существующий .NET 10 / WPF и Windows test projects.

**Spec:** [Компоненты](../../ux/redesign-2026-10/04-component-spec.md), [объём и P01–P09](../../ux/redesign-2026-10/05-native-pilots.md), [структура A](../../ux/redesign-2026-10/03-structure-and-flows.md).

**Status:** Объём одобрен пользователем 30.10.2026; выполнение начато с Task 1. Исходная ревизия `6148bbc`; макет #71 принят. Mac-приёмка предшествует Windows-реализации. Все новые имена типов/функций ниже — проектируемые интерфейсы.

## Global Constraints

- Только `codex/67-cross-platform-ux-redesign`, без новых веток/worktree. Не менять release/CI/данные/ASR. Не повышать minimum OS. Conventional Commits + Co-Authored-By.
- Сохранить все функции поверхности встречи: меню обработки/экспорта, календарь, версии, копирование, скорость/громкость, фоновые операции. Сверять карту функций #70, не считать отсутствие элемента в макете разрешением удалить его.
- Одна текущая встреча/версия и один player. SwiftUI не владеет файлами и не дублирует доменную модель. Никаких новых глобальных event bus, feature flags, зависимостей или миграции настроек.
- Стиль ограничить поверхностью пилота; не менять глобальный `JournalStyle` ради нового вида одной встречи. Настройки и другие сценарии — #73.
- Синтетические данные/изолированный профиль; никаких личных встреч и реальных provider calls. Windows build/test/GUI выполняются на Windows, не подменяются браузерным просмотром на Mac.
- Для новой логики — сначала проверка поведения, затем реализация. Не тестировать лишь наличие строк/имён классов. Для чистых отступов дополнительные unit tests не нужны.

## Review Focus

Ошибки выбранной версии и поздних callback; потеря scroll/focus/выделения при reload; сохранение при busy/unknown; размеры строк после resize; lifecycle NSHostingView и двойные actions; Windows selectable text; search UTF-16 ranges; сохранность исходного аудио и других версий. Вызовы существующих сервисов должны сохранить обработку ошибок и ограничения записи.

## Карта изменений

| Ответственность | macOS | Windows |
|---|---|---|
| Контекст/сборка экрана | `Sources/verbemo/UI/MeetingLibraryController.swift` | `windows/src/Verbemo.App/RecordingsWindow.cs` |
| Новая шапка/стиль | новые `Sources/verbemo/UI/StudioMeetingHeader.swift`, `StudioStyle.swift` | новый `windows/src/Verbemo.App/StudioMeetingHeader.cs`; локальные ресурсы в нём/контейнере встречи |
| Текст/назначение | `MeetingTranscriptView.swift`, `MeetingSpeakerView.swift` в том же UI-каталоге | `RecordingsWindow.cs`, `SpeakerIdentityEditor.cs`, `MarkdownPreview.cs` в App |
| Плеер | `Sources/verbemo/UI/MeetingPlaybackView.swift` | `windows/src/Verbemo.App/MeetingPlayer.cs` |
| Поиск | новый `Sources/verbemo/UI/MeetingTextSearch.swift` | новый `windows/src/Verbemo.Core/Processing/MeetingTextSearch.cs` |
| Интеграция shell при необходимости | `Sources/verbemo/UI/ApplicationWindow.swift`, `MeetingListView.swift` | `windows/src/Verbemo.App/ApplicationWindow.cs` |
| Unit/integration tests | новые `Tests/verbemoTests/MeetingTextSearchTests.swift`, `StudioMeetingHeaderTests.swift`; существующие `MeetingLibraryControllerTests`, `MeetingPlaybackTests`, `SpeakerAssignmentTests`, `JournalWorkspaceTests` | новый `windows/tests/Verbemo.Core.Tests/MeetingTextSearchTests.cs`; существующие Live `JournalLayoutTests`, `SpeakerIdentityEditorTests`, `SpeakerParticipantMappingTests`, `MeetingPlayerTests` |
| Данные/свидетельства | `docs/ux/redesign-2026-10/fixtures/` и новый `evidence-72/` | те же договорённости; отдельный Windows manifest |

Существующие assignment/processing/storage-сервисы — потребляемые интерфейсы, не цель рефакторинга. Если для сценария требуется менять их семантику, сначала обновить объём и причину.

## Task 1 — Контекст чтения и локальный поиск Mac

**Прогресс 30.10:** matcher и методы контроллера/расшифровки готовы, прошли 35 focused tests. Видимое поле поиска ещё не подключено; scroll/resize и оставшиеся проверки Task 1 впереди. При 0% лимита работа остановлена. [Свидетельства](../../ux/redesign-2026-10/evidence-72/progress.md).

**Files:** создать `MeetingTextSearch.swift` / `MeetingTextSearchTests.swift`; изменить `MeetingLibraryController.swift`, `MeetingTranscriptView.swift`, `MeetingLibraryControllerTests.swift`.

**Interfaces**
- Consumes: selected artifact directory из `TranscriptVersions.Version`; `Transcript`, `SpeakerNames`; `MarkdownPreview.render(_:fontSize:)` возвращает NSAttributedString — поиск сводки по его `.string`, не исходному markdown.
- Produces: `MeetingTextSearch.matches(in: String, query: String) -> [NSRange]` — неперекрывающиеся совпадения в UTF-16 исходной строки. Пробелы краёв запроса отбрасываются, пустой запрос возвращает `[]`, регистр игнорируется, regex/диакритическая нормализация не добавляются.
- В контроллере небольшой `SearchHit`: вкладка, индекс сегмента для расшифровки или nil для сводки, диапазон текста. `ReadingPosition`: вкладка, индекс сегмента/позиция символа, относительный отступ. Контекст результатов содержит session URL + version key + generation; не сохраняется на диск.

- [ ] Зафиксировать исходную ревизию и baseline существующих focused tests. Сгенерировать fixtures в новом temp-dir по README. Добавить failing cases: RU/EN регистр, emoji перед совпадением, несколько одинаковых вхождений, пустой/пробельный/отсутствующий запрос. Явно проверить NSRange на исходной строке.
- [ ] Реализовать чистый matcher; один и тот же массив SearchHit задаёт count, переходы и подсветку. Покрыть ввод в середине запроса, wrap next/previous, отсутствие summary и ошибки его чтения.
- [ ] Перед reload сохранять позицию нужной вкладки; `showDetail` не должен всегда делать `scrollToBeginningOfDocument`. Добавить узкие методы capture/restore/reveal для existing text views; не сохранять NSView ссылками после пересоздания строк.
- [ ] Сохранять origin только при первом непустом запросе. Очистка/Escape восстанавливают origin; явная смена версии/встречи инвалидирует его. При async read/update проверять все три части контекста. Назначение в той же версии не сбрасывает позицию.
- [ ] Добавить интеграционные тесты: поиск в архиве не видит текущую версию; поздний результат старой версии не применяется; clear после смены встречи не возвращает старую; summary match приводит на нужную вкладку. Чтение/поиск не вызывает запись.
- [ ] Запустить `swift test --no-parallel --filter 'MeetingTextSearchTests|MeetingLibraryControllerTests'`; результат — все выбранные проверки прошли, список реально выбранных tests не пуст. Commit: `feat(ux): add version-scoped meeting search`.

## Task 2 — SwiftUI-шапка внутри существующего workspace

**Files:** новые `StudioMeetingHeader.swift`, `StudioStyle.swift`, `StudioMeetingHeaderTests.swift`; `MeetingLibraryController.swift`; при нужной привязке — `ApplicationWindow.swift`/`MeetingListView.swift`, `JournalWorkspaceTests.swift`.

**Interfaces**
- Consumes: состояние контроллера — список версий/выбранный ключ, вкладка, query, текущий hit/count, доступность; callbacks selectVersion/selectTab/queryChanged/next/previous/clear. Название и showDetails остаются в строке AppKit над плеером.
- Produces: один NSHostingView с `StudioMeetingHeader: View`. Контроллер владеет стабильной observable presentation model; `.onAppear`/`.onChange` не запускают повторное чтение/запись. Тексты берутся из существующего RU/EN-механизма, не новой localization-системы.

- [ ] Добавить focused проверки callback: одно действие — один вызов; программное обновление snapshot не выбирает версию повторно. Сохранить regression-проверку возвращения из настроек к той же встрече.
- [ ] Порядок workspace: строка названия/деталей AppKit → существующий плеер → header (версия/поиск, затем вкладки) → содержимое. Встроить header, согласовать intrinsic height с Auto Layout. Добавить native tooltip/accessibility labels, команды ⌘F/Enter/Shift+Enter/Escape, не перехватывая ввод текста у чужих контролов. Фокус в поле переживает обновление count.
- [ ] Применить StudioStyle локально: роль цвета/шрифта/интервалов из спецификации. Сохранить системный focus ring/contrast settings. Библиотечный фильтр подписать «Название встречи», убрать только дублирующее действие глобального поиска, если оно существует в native shell.
- [ ] Сохранить/добавить нативный изменяемый разделитель библиотеки и возврат её ширины после скрытия; ограничения ширины и клавиатурное управление проверить в P07/P08.
- [ ] Проверить узкое окно и крупный текст: header может прокручиваться, плеер/текст остаются достижимы. Не ставить фиксированную высоту, отсекающую переносы.
- [ ] `swift test --no-parallel --filter 'StudioMeetingHeaderTests|JournalWorkspaceTests|MeetingLibraryControllerTests'` и `swift build`. GUI smoke: Tab туда/обратно через SwiftUI/AppKit, ⌘F, смена версии, resize. Commit: `feat(ux): host Studio meeting header in SwiftUI`.

## Task 3 — Реплики, назначение и плеер Mac

**Files:** `MeetingTranscriptView.swift`, `MeetingSpeakerView.swift`, `MeetingPlaybackView.swift`, соответствующие существующие tests; при необходимости новые behavioral cases в `MeetingLibraryControllerTests.swift`.

**Interfaces**
- Consumes: `MeetingTranscriptView.update(transcript:names:participants:canEdit:canPlay:canMatchParticipants:)`, callbacks `onPlayFrom` / `onAssign`; `PostProcessor.setSpeakerParticipant(_:participant:name:in:)` через существующий controller.
- Consumes: `MeetingPlaybackView.setMeeting(_:)`, `.play(from:)`, существующие sources/offsets/скорость/громкость. Produces: отдельное stop-действие, при необходимости новый `stopPlayback()` сбрасывает позицию без потери настроек player.

- [ ] Добавить failing tests: rename в архиве не затрагивает current; cancel ничего не пишет; busy/unknown не позволяет запрещённое назначение; обработка ошибки сохраняет ввод. Сохранять повторную проверку версии и canEdit перед записью.
- [ ] Перестроить только представление NSTableView-строк: 190 + 16 + body, padding 10, перенос при нехватке места; row height вычислять из фактической ширины/шрифта/имени. Сохранить reuse и selectable text, не создавать hosting view на каждую строку.
- [ ] Во вкладке «Участники» встроить имя и выбор участника прямо в строку, первые три реплики и icon-only playback. Имя сохраняется по blur/Enter, выбор сразу, Escape отменяет черновик; ошибка сохраняет ввод. Не дублировать сервис записи и проверку версии.
- [ ] Карандаш открывает существующий editor в popover с Save/Cancel и областью действия. Ввод является черновиком до Save; закрытие popover ничего не записывает. Существующий cleanup dropdown accessibility в `SpeakerAssignmentChoice` сохранить. После read-back вернуть позицию и фокус по устойчивому speaker/segment identity.
- [ ] Плеер: иконки Play/Pause/Stop и доступные имена отражают фактическое состояние, включая конец и ошибку. Смена вида/поиск/rename не пересоздаёт player. Проверить смещения sources и все существующие скорости/volume.
- [ ] `swift test --no-parallel --filter 'SpeakerAssignmentTests|MeetingPlaybackTests|MeetingLibraryControllerTests|JournalWorkspaceTests'`. GUI проверить rapid scroll/resize и назначение на 180 репликах, копирование RU/emoji, stop/replay. Commit: `feat(ux): compact transcript and playback controls`.

## Task 4 — Mac-приёмка и решение по мосту

**Files:** fixtures только при необходимом дополнении; новый `docs/ux/redesign-2026-10/evidence-72/macos.md`; обновить `05-native-pilots.md` фактическими результатами.

- [ ] Запустить полный `swift test --no-parallel` и собрать локальный app существующим `make app` после проверки ресурсов/зависимостей. Сохранить команды и ошибки; не выдавать `swift build` за сборку GUI bundle.
- [ ] Подготовить отдельную QA-копию bundle/профиль аналогично UX69, но с новым идентификатором и пустым home. До запуска сверить фактические `CFBundleIdentifier`, путь данных и изоляцию preferences; использовать только сгенерированные встречи. Не менять установленный пользовательский app.
- [ ] Выполнить P01–P09 и записать точные шаги, исходную ревизию, снимки, матрицу pass/fail/unverified. Для звука добавить синтетический тон существующим test audio helper; тишина не доказывает audible playback.
- [ ] Сравнить до/после SHA. У назначения ожидаемые производные изменения определить по реальному существующему сервису, не whitelist одного файла. Перечислить непроверенные свойства, в том числе minimum macOS, если доступен только новый host.
- [ ] Зафиксировать вывод SwiftUI: фокус/размер/состояния работают либо конкретный дефект и узкое исправление. Commit: `docs(ux): record macOS Studio pilot evidence`. Представить пользователю реальный Mac-пилот; переход к Task 5 после его приёмки.

## Task 5 — Эквивалентный Windows-пилот

**Files:** WPF/Core/test files из карты. Создавать helper поиска рядом с существующими meeting models, не новый архитектурный слой.

**Interfaces**
- Consumes: `TranscriptVersion.Directory`, `TranscriptDocument.Segments`, `SpeakerFile`; `VerbemoRuntime.SetSpeakerParticipantAsync` / `SetSpeakerNameAsync`; `MeetingPlayer.Load` / `Seek`.
- Produces: `MeetingTextSearch.Matches(string text, string query)` возвращает список `(int Start, int Length)` UTF-16 в исходном text, неперекрывающиеся ordinal-ignore-case совпадения. Та же семантика и test cases, что в Task 1. Позиции WPF TextPointer строить по текстовым runs; raw offset не равен числу служебных символов FlowDocument.
- `RecordingsWindow` сохраняет существующий `transcriptShown` guard и дополнительно связывает search/origin/editor с session + version. Header не запускает storage operations самостоятельно.

- [ ] Подтвердить Windows host online, repo/ветку/revision/dirty state; не переключать чужую dirty-работу. До изменения получить baseline Core/Live tests на этом host.
- [ ] Добавить failing Core search cases и Live случаи stale-version, clear/origin, rename/error/cancel. Реализовать такой же header/иконки/состояния WPF без нового UI framework; общий плеер располагается под названием, выше версии/поиска/вкладок.
- [ ] Переделать JSON-реплики `ShowTranscriptParticipantsAsync`: метаданные слева, выделяемый native текст справа. Переиспользовать существующий read-only RichTextBox/MarkdownPreview-подход без markdown-интерпретации обычной реплики. Оставить `SpeakerIdentityEditor` за карандашом; draft до Apply, save/cancel/error как на Mac.
- [ ] Сводку искать по фактически отображаемому plain text и сопоставлять hits с TextPointer, сохраняя formatting. Полная Windows row virtualization не отдельная цель пилота: сначала проверить 180 сегментов; при неприемлемом scroll/layout вернуть конкретную проблему в объём.
- [ ] Плеер/stop/ошибки/скорость/громкость и source offsets сохранить; не создавать второй таймер/player из header. Команды Ctrl+F, Enter/Shift+Enter/Escape, UI Automation Name/HelpText локализовать.
- [ ] На Windows выполнить `dotnet build windows/src/Verbemo.App/Verbemo.App.csproj --configuration Release`, `dotnet test windows/tests/Verbemo.Core.Tests/Verbemo.Core.Tests.csproj --configuration Release`, `dotnet test windows/tests/Verbemo.Live.Tests/Verbemo.Live.Tests.csproj --configuration Release`. Не считать skipped tests прошедшими.
- [ ] Commit: `feat(ux): add native Windows Studio pilot`. Выполнить P01–P09 на настоящем WPF app с `VERBEMO_TEST_DATA` в новом temp-dir; отдельные 100/150/200% DPI и text scaling, Narrator/contrast themes. Сохранить `evidence-72/windows.md`. Недоступный host — unverified, #72 остаётся открытой.

## Task 6 — Общий результат и откат

**Files:** `05-native-pilots.md`, `04-component-spec.md` при подтверждённых уточнениях, epic plan и issue #72.

- [ ] Сопоставить Mac/Windows по P01–P09, перечислить различия контролов и доступных операций, все найденные/исправленные проблемы и оставшиеся ограничения. Не заявлять ускорение UX без baseline пользователя.
- [ ] Проверить, что изменения не удалили функции из карты #70 и не изменили форматы/данные. Повторять тесты только после относящихся к ним исправлений; не запускать дорогие проверки без новой причины.
- [ ] Откат при блокирующем дефекте: `git revert` только коммитов пилота в обратном порядке после проверки текущего diff; не reset/force-push и не откат чужих изменений. Данные совместимы, миграций нет. Если обнаружена несовместимость — это дефект пилота.
- [ ] Commit/push evidence, read-back issue. Попросить приёмку результатов и определить следующий сценарий #73. Не merge/master/release и не закрывать #72 до отдельной приёмки обеих ОС.

## Самопроверка плана, 30.10.2026

Сценарий покрыт задачами 1–5; реальные сервисные входы сверены с исходниками `caf46e5`. Новые интерфейсы явно обозначены. Контекст/поиск, SwiftUI presentation и native текст/player имеют разные ответственности; полного UI framework rewrite нет. Права редактирования, async guards, copied text, архивы и аудиосмещения включены в проверки. Недоступная Windows и отсутствие minimum-OS host не скрываются. Это review документа, не исполнение перечисленных команд и не независимая кодовая приёмка.
