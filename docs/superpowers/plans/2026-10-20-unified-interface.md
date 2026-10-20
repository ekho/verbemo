# Единое окно Verbemo по согласованному макету — Implementation Plan

<!-- verbemo-unified-interface-plan-2026-10-20 -->

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Use superpowers:subagent-driven-development only if the user chooses delegated execution. Steps use checkbox (`- [ ]`) syntax for tracking. Эта задача содержит план; создание задачи не означает разрешение начать реализацию или публикацию релиза.

**Goal:** Перенести согласованную структуру и поведение HTML-макета в нативный интерфейс Verbemo: одно рабочее окно для встреч, текущей записи и настроек, без потери существующих функций и данных.

**Architecture:** Сохранить AppKit на macOS и WPF на Windows. Разделить существующие окна на переиспользуемое содержимое и один оконный контейнер; запись, очередь обработки и применение настроек продолжают жить вне представлений. Общие для пунктов меню и кнопок правила доступности команд проверяются повторно в сервисе перед выполнением.

**Tech Stack:** Swift 6 / AppKit, macOS 14.2+; C# / WPF, существующий target `net10.0-windows10.0.26100.0`; Swift Testing и xUnit. HTML служит UX-спецификацией, WebView и новые UI-фреймворки не вводятся.

**Spec:** Раздел «Целевой интерфейс» ниже и финальный интерактивный макет от 20.10.2026. Локальный оригинал: `/Users/ekho/.codex/visualizations/2026/10/20/01a1585c-bf17-7e51-821b-e5553343bd0d/verbemo-prototype/index.html`; SHA-256: `92580e26aa8a8cbc712d1cae70b7469864c05b8c86f7498dc5b6c7f3fd888473`. `http://127.0.0.1:8796/` — локальный просмотр, а не общедоступная ссылка. Ключевые требования полностью приведены в задаче, чтобы план не зависел от работающего локального сервера. В этапе 1 сохранить HTML и снимки в репозитории.

## Исходная точка и границы

Проверено по исходникам и GitHub `master` на 20.10.2026: `0d543151cafe47771c2e134aec15be6208ea9864`, версия `0.2.2`. На момент составления плана нативное приложение не переделано. Макет просмотрен в браузере: все шесть разделов настроек, карточка встречи, календарный блок, расшифровка, единое меню, текущая запись и её сохранение при переходе в настройки.

| Область | Текущая реализация | Решение |
| --- | --- | --- |
| macOS: окна и маршруты | `Sources/verbemo/Verbemo.swift`, `App/AppDelegate.swift`, `App/MainMenu.swift`; отдельные `UI/StatusWindow.swift`, `RecordingsWindow.swift`, `SettingsWindow.swift`, `AboutWindow.swift` | Один `ApplicationWindow`, переиспользуемые content views; все входы ведут в него |
| Windows: окна и маршруты | `windows/src/Verbemo.App/App.xaml.cs`, `TrayIconService.cs`; отдельные `StatusWindow.cs`, `RecordingsWindow.cs`, `SettingsWindow.cs` (включая About) | Один WPF `ApplicationWindow`; runtime и tray остаются вне окна |
| Настройки | macOS `SetupForm`, `SettingsSchema`, `SettingsApplier`, `ConfigWatch`; Windows `SetupForm`, `AdvancedSettings`, `AppSettingsStore`, `VerbemoRuntime.Update` | Одно место редактирования каждого параметра, существующая запись/валидация конфигурации |
| Встречи и версии | macOS `Sessions/SessionInventory.swift`, `TranscriptVersions.swift`, `PostProcessor.swift`; Windows `Core/Processing/SessionInventory.cs`, `Core/Processing/TranscriptVersions.cs`, `App/ProcessingCoordinator.cs` | Сохранить файловый архив, версии, ручные имена, запреты действий во время работы |
| Календарь | macOS `Meetings/CalendarWatcher.swift`, `MeetingContext.swift`: сохраняются название, приглашённые, время и ссылка звонка; не сохраняются агенда и идентификатор/ссылка события | Расширить необязательные метаданные и добавить реальный переход к событию. Ссылка звонка не заменяет ссылку календаря |
| Перегенерация | Есть завершение недоделанных этапов и повторная расшифровка; отдельной команды принудительного обновления готовой сводки нет | Добавить команду только для сводки с защитой в сервисе |

Общий UX переносится на обе платформы, с учётом их реальных возможностей. Windows сейчас не содержит EventKit-интеграции и каталога локальных моделей диаризации Nemotron 3 / LS-EEND / Community-1 из macOS. В этой задаче Windows отображает сохранённый календарный контекст и доступные говорящие/модели; создание нового Windows-календарного провайдера и перенос движков локальной диаризации сюда не входят. Недоступную возможность нельзя изображать работающей: показывать причину или не предлагать неподдерживаемый вариант. Это ограничение платформы, а не разрешение потерять уже работающую облачную диаризацию.

Не входят: изменение качества распознавания/диаризации (#11), словарь компании (#10), новые провайдеры, переписывание захвата звука, новый формат хранения аудио, публикация релиза. Обновление UX ошибок и ручного повтора согласовать с #8; не создавать второй независимый механизм retry. Восстановление Windows CI относится к #19.

## Global Constraints

- Одно основное окно; Настройки и «О Verbemo» — его разделы. Допустимы системные выборы файла/папки, запросы разрешений и подтверждения действий.
- Не менять bundle/app identity, ключи секретов, пути данных, лицензионные файлы и исходные copyright notices.
- Не переписывать существующий конфиг целиком ради нового UI; неизвестные ключи сохраняются, нечитаемый конфиг не заменяется дефолтами. Имеющиеся значения и фактические defaults важнее демоданных HTML.
- Сохранять `SettingsApplier` / `ConfigWatch` на macOS и `VerbemoRuntime.Update` / `AppSettingsStore` на Windows как путь применения настроек.
- Сохранять очередь, `SessionClaim` / lease, session locks, recovery, on_stop и правила передачи аудио/текста провайдерам. Переход между разделами и закрытие окна не прекращают запись или обработку.
- Во всём пользовательском интерфейсе по-русски — «Сводка», без «саммари» и «итоги». Английская локализация — Summary. Ключи `summary`, файлы `summary.md` и машинные протоколы не переименовываются.
- Генерация/перегенерация сводки запрещена до готовности окончательной расшифровки выбранной версии. Предварительный live-текст и оставшийся файл старой версии не считаются завершённой новой расшифровкой.
- Копирование и обработка всегда относятся к выбранной встрече и версии. Повторная расшифровка сохраняет предыдущую версию с её именами и сводкой.
- «Удалить» не превращается в безвозвратное удаление: сохраняется системная Корзина, проверка занятости и подтверждение. Речь об отсутствии отдельной Корзины внутри Verbemo, а не об отказе от восстановления средствами ОС. Отдельный раздел Корзины в приложении не добавляется.
- Локальные модели показываются из реального каталога платформы. Описания, размеры и совместимость берутся из каталога, а не из статических демозначений макета.
- Поддержать русский/английский интерфейс, клавиатуру, VoiceOver/Narrator, повышенный DPI и системное уменьшение анимации. Тема приложения не меняет тему ОС.
- Не закрывать Windows-приёмку результатами macOS или пропущенной Windows job. На текущей исходной точке Windows CI явно отключён до решения #19.

## Review Focus

1. Готовая старая версия рядом с новой незавершённой: кнопки не копируют и не перегенерируют результат другой версии — тесты этапов 2 и 5.
2. Запись/обработка продолжается при переходе в настройки, скрытии, повторном открытии и изменении размеров окна; подписки не дублируются — этапы 3 и 4.
3. Нечитаемый конфиг, отказ доступа к файлу, конкурентный CLI и удалённая снаружи встреча: UI сообщает причину и сохраняет данные — этапы 2, 5, 6.
4. Старая встреча без календарных полей, отклонённый доступ к календарю и повторная диаризация с новыми speaker IDs: нет ложной связи или переноса чужих имён — этап 8.
5. Узкое/невысокое окно, длинные названия, много участников, Light/Dark/System и уменьшение анимации: меню, текст и нижние настройки доступны — этапы 3, 5, 6, 9.

## Целевой интерфейс

### Окно и навигация

- Слева сверху бренд и встречи: «Все встречи», «В обработке», «Нужны действия». Блок настроек внизу: «Общие», «Запись», «Расшифровка», «Сводка и участники», «Хранение и модели», «О Verbemo»; ниже — состояние автозаписи с пиктограммой точки записи и круговой стрелки.
- В широком окне: навигация → список встреч → выбранная встреча. В узком — список и карточка сменяют друг друга без потери выбора, поиска, вкладки и версии. Высота заголовка разделов соответствует компактным 60 px макета с адаптацией к нативному масштабированию.
- Верхний заголовок «Все встречи» кликабелен из карточки: открывает весь список и сбрасывает фильтр/поиск. В самом списке это обычный заголовок. Отдельной кнопки «Назад / Все встречи» в карточке нет.
- «Импортировать» и «Новая запись» — только в разделе «Все встречи». При уже идущей записи повторный старт недоступен. Быстрые команды строки меню/tray и системное меню приложения сохраняются.
- Не переносить убранные элементы: строку «На этом Mac · …», верхний переключатель live-режима, «К встречам» в настройках, библиотечный breadcrumb, группы «Сегодня / Вчера / Ранее», подвал «N встреч / На этом компьютере».

### Список и карточка встречи

- Плоский список в обратном хронологическом порядке, поиск; карточки с лёгким нейтральным фоном и отдельным hover. Без зелёной заливки выбранной встречи. Дата и время: `20.10.2026 10:00`, далее длительность и участники.
- Порядок пиктограмм: календарь (только при подтверждённой связи), микрофон, документ расшифровки, checklist сводки. Основная пиктограмма 14 px; отметка диаризации — человечки слева снизу документа, статус завершения — справа снизу.
- Текущий этап плавно пульсирует (цикл около 1,8 с); запись и live-расшифровка могут быть активны одновременно. Пауза останавливает пульсацию. Готово, ожидание, ошибка, блокировка и отсутствие этапа различимы не одним цветом, имеют tooltip и доступное имя. При отсутствии созданной сводки подсказка точно «Сводка не создавалась». При Reduce Motion — статическое состояние.
- Карточка: название, дата/время, длительность, участники; при наличии — блок календаря; вкладки «Сводка», «Расшифровка», «Участники». Реальные ошибки показываются с причиной и конкретным действием.
- В обеих текстовых вкладках — отдельные кнопки копирования «Текст» и «Markdown». Верхнего общего Copy dropdown нет. В Расшифровке — «Расшифровать повторно», под ним только модель распознавания и модель диаризации (если применима); в Сводке — «Перегенерировать сводку», под ним только способ генерации.
- Сохранить существующие возможности, подробно не показанные в HTML: выбор версии в компактной строке после метаданных, прослушивание сохранённого аудио и открытие файла расшифровки вторичными действиями в содержимом. Не расширять ими согласованное меню.

Единое меню правой кнопки в списке и «…» в карточке, в точном порядке:

1. Переименовать.
2. Копировать транскрипцию.
3. Расшифровать повторно.
4. Копировать сводку.
5. Перегенерировать сводку.
6. Открыть папку в Finder / Проводнике.
7. Разделитель.
8. Удалить.

Копирование транскрипции доступно только для готового текста, копирование сводки — только для существующей сводки выбранной версии. Повторная расшифровка требует доступного аудио и пригодных настроек/моделей. Перегенерация требует готовой расшифровки, включённого сервиса сводки и свободной сессии. Те же условия применяются к кнопкам в содержимом и к вызову сервиса. Disabled-пункты объясняют причину. Меню помещается в окно, поддерживает Shift+F10, стрелки, Home/End, Escape и возврат фокуса.

### Текущая запись

- Общая полоса в самом верху содержимого окна, над навигацией и разделами: название-ссылка, таймер, пауза/продолжение, остановить и сохранить. Видна и в настройках. Нажатие на название открывает текущую запись.
- Название редактируется в записи. Live-текст расположен в самой записи, постепенно пополняется, показывает паузу, загрузку/отсутствие модели и ошибки. Выключение показа текста не останавливает сохранение аудио. Предварительный текст явно отделён от итоговой расшифровки.
- Импорт через системный диалог и drag-and-drop, ход импорта и отмена ведут в ту же библиотеку. Не переносить демонстрационный импорт готового примера в production.

### Настройки

| Раздел | Единственное место редактирования |
| --- | --- |
| Общие | Язык интерфейса; тема «Системная / Светлая / Тёмная»; запуск при входе; Dock/строка меню или taskbar/tray по платформе |
| Запись | Микрофон; источник системного звука; автозапись; календарь, где поддерживается; разрешения; задержки и ограничения в раскрываемом блоке |
| Расшифровка | Live-режим; облачная и локальная обработка после встречи; провайдер и его ключ; язык встреч; модель распознавания; включение и модель диаризации; редкая настройка группировки |
| Сводка и участники | Сервис сводки; только поля выбранного сервиса (API/model/base URL/ключ, CLI или Ollama); язык и шаблон сводки; определение имён и его backend |
| Хранение и модели | Папка записей, сохранение исходного аудио, занятое место, загрузка/прогресс/отмена/удаление моделей live, ASR и диаризации. Выбор рабочей модели здесь не дублируется |
| О Verbemo | Логотип, название, реальная версия сборки, описание, GitHub `ekho/verbemo`, поддержка и происхождение/лицензии. Верхнего дублирующего toolbar нет |

Для каждого существующего ключа схемы назначить один редактор, включая редкие параметры, отсутствующие в HTML: timeout, модели/версии провайдеров, base URL, call-app lists, on_stop и другие актуальные ключи. Редкие поля остаются в раскрываемых подразделах по смыслу, отдельную дублирующую вкладку «Дополнительно» не возвращать. Onboarding использует те же редакторы/правила, а не свою копию конфигурации.

Сохранить совместное включение облака и локальной обработки как fallback. Явно объяснять, что остаётся на устройстве и что передаётся провайдеру. Названия моделей, краткие особенности, размер, доступность и состояние загрузки видны при выборе ASR и диаризации. На macOS сохранить Nemotron 3, LS-EEND AMI и Community-1 с актуальными описаниями из `DiarizationModel`; платформенные ограничения, включая Intel, учитывать явно. Активная/используемая заданием модель не удаляется. Путь «скачать и продолжить» возобновляет именно ожидающую встречу.

«О Verbemo»: описание охватывает запись микрофона и приложений звонков, live и последующую расшифровку, разделение говорящих, сводку с решениями/задачами, хранение результатов и выбор локальной/облачной обработки. Версию получать из сборки, не закреплять `0.2.2`. Удалённый абзац «На основе Amanu Самата Галимова (MIT).» не возвращать; ссылка на происхождение и лицензии сохраняется.

### Календарь и участники

Только для встречи с подтверждённой связью показываются: ссылка на само событие, агенда при наличии, приглашённые (это не подтверждение присутствия). При диаризации над репликой можно выбрать участника этого события или снять сопоставление. Выбор применяется ко всем репликам данного говорящего в выбранной версии, попадает в копирование/экспорт, не меняет календарь и другие встречи. Сохранить свободное ручное имя для участников, которых нет в приглашении. Без диаризации не предлагать сопоставление говорящих.

## План выполнения

По прямому поручению пользователя от 20.10.2026 результат — смёрженный PR и дистрибутив в релизе. Этапы выполняются отдельными проверяемыми коммитами в одном интеграционном PR. Порядок ниже учитывает зависимости. Имена новых файлов и интерфейсов ниже — предлагаемый контракт реализации, а не утверждение об уже существующих API. Перед каждым PR сверить изменения master.

### Task 1: Зафиксировать спецификацию и матрицу сохранения функций

**Files:** создать `docs/ux/verbemo-interface/prototype.html`, `docs/ux/verbemo-interface/README.md`, снимки основных состояний в той же папке; в ходе реализации сохранить план этой issue в `docs/superpowers/plans/2026-10-20-unified-interface.md` с обратной ссылкой.

**Produces:** версионируемый UX-эталон и таблица `существующая функция / путь в новом UI / macOS / Windows / проверка`.

- [ ] Скопировать финальный HTML без изменений; проверить SHA-256 выше. Зафиксировать снимки списка, карточки, живой записи, настроек и узкого режима; не переносить demo-strip в нативный интерфейс.
- [ ] Сопоставить все поля обеих settings schemas с шестью разделами; явно включить версии, прослушивание, открытие артефактов, import/cancel, retry/skip diarization, разрешения, updates и безопасный выход.
- [ ] Зафиксировать платформенную матрицу: поддерживаемые ASR/live/диаризация/календарь, архитектуры, реальные размеры моделей. Опубликовать различия рядом со спецификацией.
- [ ] Проверить покрытие: у каждого действующего ключа настроек и каждого старого пользовательского действия есть целевое место или явно записанная причина недоступности платформы.

**Check:** `shasum -a 256 docs/ux/verbemo-interface/prototype.html` совпадает с эталоном; матрица не содержит потерянных функций и незаполненных пунктов.

### Task 2: Общие правила действий и безопасная перегенерация сводки

**Modify macOS:** `Sources/verbemo/Sessions/PostProcessor.swift`, `Summary/Summarizer.swift`, `Sessions/TranscriptVersions.swift`, `Sessions/SessionInventory.swift`; использовать существующие `SessionClaim` / `SessionLock`.

**Modify Windows:** `windows/src/Verbemo.App/ProcessingCoordinator.cs`, `VerbemoRuntime.cs`, `windows/src/Verbemo.Core/Processing/TranscriptVersions.cs`.

**Create:** `Sources/verbemo/UI/MeetingActionState.swift`; `windows/src/Verbemo.Core/Processing/MeetingActionState.cs`.

**Interfaces:** `MeetingActionState` — вычисляемое immutable состояние доступности действий для session + выбранной версии + фактической занятости + текущей конфигурации. Добавить `PostProcessor.regenerateSummary(_ dir: URL, policy: Policy = .configured) async throws` и Windows `RegenerateSummaryAsync(string directory, CancellationToken cancellationToken = default)`; runtime делегирует туда. Корневой session lock обязателен и при работе с архивной версией; UI передаёт явную выбранную artifact directory из inventory, без скрытого переключения на latest; сервис проверяет её принадлежность нужной сессии до записи.

- [ ] Добавить тесты `MeetingActionStateTests` / `SummaryRegenerationTests`: live-only, audio-only, queued ASR, незавершённый request со старым transcript, готовая версия, service off, missing audio, busy claim, unreadable config. Генерация разрешена только в готовой выбранной версии при свободной сессии и пригодном сервисе; повторная расшифровка запрещена без аудио.
- [ ] Убедиться, что новые тесты падают на отсутствующем поведении. Реализовать общий расчёт состояния и повторную проверку непосредственно при выполнении команды, после получения claim. Disabled-кнопка не является единственной защитой.
- [ ] Реализовать force-summary без повторного ASR и speaker naming: старую сводку сохранять до успешной атомарной записи новой; при ошибке/отмене она остаётся читаемой. Ручные имена и соседние версии не изменяются; on_stop не запускается повторно из-за UI-команды. Повтор после ошибки согласовать с #8, фоновый sweep не превращать в бесконечный retry.
- [ ] Проверить fake-backend тестом число вызовов: regenerate = один вызов summary, ноль ASR и naming; двойной клик/конкурентный CLI не создаёт второй запрос. При ошибке байты старой сводки и транскрипта сохраняются.

**Tests:** расширить `Tests/verbemoTests/Sessions/PostProcessingTests.swift`, `TranscriptVersionsTests.swift`, `SessionClaimTests.swift`; создать `Tests/verbemoTests/MeetingActionStateTests.swift`, `SummaryRegenerationTests.swift`; на Windows создать `windows/tests/Verbemo.Core.Tests/MeetingActionStateTests.cs`, `windows/tests/Verbemo.Live.Tests/SummaryRegenerationTests.cs`, расширить `RetranscriptionTests.cs`.

**Run:** `swift test --no-parallel --filter 'MeetingActionStateTests|SummaryRegenerationTests|PostProcessingTests|TranscriptVersionsTests|SessionClaimTests'`; на Windows `dotnet test windows/tests/Verbemo.Core.Tests/Verbemo.Core.Tests.csproj -c Release` и `dotnet test windows/tests/Verbemo.Live.Tests/Verbemo.Live.Tests.csproj -c Release --filter 'FullyQualifiedName~SummaryRegenerationTests|FullyQualifiedName~RetranscriptionTests'`. Успех — все выбранные тесты завершены, без реальных ключей и платных запросов.

### Task 3: Единое окно и маршрутизация всех входов

**Create macOS:** `Sources/verbemo/UI/ApplicationWindow.swift`, `ApplicationNavigationState.swift`, `SidebarView.swift`. **Modify:** `Verbemo.swift`, `App/AppDelegate.swift`, `App/MainMenu.swift`, `UI/MenuBarController.swift`; извлечь content из текущих окон без изменения сервисов.

**Create Windows:** `windows/src/Verbemo.App/ApplicationWindow.cs`, `ApplicationNavigationState.cs`, `SidebarView.cs`. **Modify:** `App.xaml.cs`, `TrayIconService.cs` и оболочки существующих окон.

**Interfaces:** `ApplicationNavigationState` хранит раздел, фильтр встреч, строку поиска, session ID, version key и вкладку. `ApplicationWindow.show(destination:)` на macOS / `ShowDestination(...)` на Windows используют существующий экземпляр окна. Представления не создают runtime, очередь или новый аудиозахват.

- [ ] Добавить `ApplicationNavigationTests` / `ApplicationWindowTests`: один window instance для приложения, Settings, About, Dock/tray/reopen и command-comma; сохранение session/version/tab/query после настроек; «Все встречи» из карточки очищает фильтр/поиск.
- [ ] Встроить sidebar и content-host: встречи сверху, настройки снизу, строка автозаписи под ними; равномерный компактный toolbar, без toolbar в About. Широкий режим со списком и деталью, узкий со сменой содержимого.
- [ ] Перенаправить старт, Dock/Start/reopen, tray/menu, Settings/About/update-entry и импорт в единственный контейнер. Закрытие/скрытие не завершает runtime; явный Quit сохраняет действующие проверки активной записи и обработки. Не менять пользовательскую настройку показа окна при старте.
- [ ] Проверить короткое окно: настройки прокручиваются и не перекрывают автозапись; фокус доступен при скрытых текстовых подписях sidebar. Старые самостоятельные окна больше не создаются через обычные маршруты.

**Tests/Run:** новые `Tests/verbemoTests/ApplicationNavigationTests.swift`, `ApplicationWindowTests.swift`; Windows `windows/tests/Verbemo.Live.Tests/ApplicationWindowTests.cs`. `swift test --no-parallel --filter 'ApplicationNavigationTests|ApplicationWindowTests'`; Windows Live filter `FullyQualifiedName~ApplicationWindowTests`.

### Task 4: Полоса текущей записи, live-текст и импорт

**Create:** macOS `UI/RecordingBarView.swift`, `LiveTranscriptView.swift`; Windows `App/RecordingBarView.cs`, `LiveTranscriptView.cs`. **Modify:** `UI/StatusWindow.swift`, `MediaImportPresentation.swift`, `Verbemo.swift`; Windows `StatusWindow.cs`, `App.xaml.cs`, `VerbemoRuntime.cs`. Переиспользовать `LiveTranscriptionCoordinator`, media import coordinator и существующие start/pause/stop методы.

**Consumes:** маршруты этапа 3 и реальные snapshots/events записи. **Produces:** глобальная полоса и содержимое активной встречи; ни таймер, ни запись не принадлежат жизненному циклу отдельной страницы.

- [ ] Перенести проверки в `RecordingWorkspaceTests`: Start → Settings → Pause → перейти по имени → Resume → Stop даёт одну сессию, таймер и пауза одинаковы во всех поверхностях; повторный Start невозможен. Скрытие окна не вызывает Stop.
- [ ] Разместить полосу над всей рабочей областью, привязать редактирование названия к текущей сессии. Сохранить ошибки начала/остановки и недоступности устройства, не показывать ложный успех.
- [ ] Подключить реальный поток live-текста: загрузка модели, модель отсутствует, ожидание речи, пауза, ошибка, live off. Не выдавать «Вы / Они» за подтверждённые имена участников; не использовать live как готовый источник генерации сводки.
- [ ] Перенести импорт, drop, прогресс и отмену в общее окно; видимые кнопки Import/New только в All meetings. Сохранить существующие entry points и отказ без записи частичного результата при отмене.
- [ ] Проверить отсутствие двойных подписок при многократном открытии раздела и отсутствие второго аудиотапа при тестировании разрешений во время записи.

**Tests/Run:** создать `Tests/verbemoTests/RecordingWorkspaceTests.swift`; адаптировать `StatusWindowLayoutTests.swift`, `MediaImportUITests.swift`, `MediaImportEntryPointTests.swift`. Windows создать `windows/tests/Verbemo.Live.Tests/RecordingWorkspaceTests.cs`, сохранить `LiveAudioTests.cs` и тесты recording coordinator. Swift filter `RecordingWorkspaceTests|StatusWindowLayoutTests|MediaImportUI|MediaImportEntryPoint`; Windows Live filter `RecordingWorkspaceTests|LiveAudioTests|RecordingActionsTests` по FullyQualifiedName.

### Task 5: Библиотека, вкладки, единое меню и операции с данными

**Create macOS:** `UI/MeetingListView.swift`, `MeetingDetailView.swift`, `MeetingActionsMenu.swift`, `SessionDeletionController.swift`. **Modify:** `RecordingsWindow.swift`, `Sessions/SessionInventory.swift`; использовать существующий Markdown/RTF renderer и TranscriptVersions.

**Create Windows:** `App/MeetingListView.cs`, `MeetingDetailView.cs`, `MeetingActionsMenu.cs`, `SessionDeletionController.cs`. **Modify:** `RecordingsWindow.cs`, `MarkdownPreview.cs`, `VerbemoRuntime.cs` и существующие методы session store.

**Consumes:** этапы 2–4. **Interfaces:** один генератор меню использует `MeetingActionState`, одни handlers вызываются из context menu, ellipsis и content buttons. Состояния этапов выводятся из inventory, claims и processing events, а не из фиктивного процента/таймера.

- [ ] Добавить тесты `MeetingPresentationTests` / `MeetingMenuTests`: фильтры, дата, последовательность и доступность команд одинаковы в обоих меню и вкладках; действующая старая версия не подменяет незавершённую новую. Пиктограмма диаризации отражает данные этой расшифровки, а не текущую глобальную настройку.
- [ ] Перенести плоские карточки, поиск и три фильтра; убрать перечисленные в спецификации служебные строки. Показать реальные стадии и ошибки, пульсировать только выполняемые, учесть Reduce Motion; tooltip disabled-summary — «Сводка не создавалась».
- [ ] Перенести вкладки и компактный выбор версии; сохранить просмотр аудио/артефактов и управление проблемной диаризацией (retry/skip с существующими запретами). Подключить повторную обработку и подсказки модели/способа генерации по спецификации.
- [ ] Реализовать четыре варианта копирования: transcript/summary × text/Markdown; сохранить поддержку выделенного текста и уже работающий RTF-путь. Вложенные списки, таймкоды и ручные имена не портятся. Menu-copy берёт plain text соответствующего содержимого независимо от открытой вкладки.
- [ ] Переименование меняет title в метаданных атомарно, без перемещения папки активной/обрабатываемой сессии; обновляет список, карточку и полосу записи. Внешнее удаление/повреждение файла не оставляет текст предыдущей встречи в панели.
- [ ] Удаление: заголовок и пункт «Удалить», подтверждение, активная запись/занятая сессия защищены и проверяются повторно. Для «Отменить» из макета использовать окно отмены 6,5 с перед отправкой в системную Корзину; операцией владеет controller приложения. На время ожидания удерживать отказ конкурирующей обработки этой сессии, Undo отменяет операцию; закрытие приложения до подтверждённой отправки отменяет отложенное удаление. Не делать необратимый fallback при ошибке recycle; возвращать строку и сообщать ошибку. Самостоятельный экран корзины не добавлять.
- [ ] Проверить меню на краях и в узком окне, клавиатуру и возврат фокуса. Название длинной встречи переносится, меню не попадает под sidebar.

**Tests:** новые `Tests/verbemoTests/MeetingPresentationTests.swift`, `MeetingMenuTests.swift`, `SessionDeletionTests.swift`; адаптировать `RecordingsWindowTests.swift`, `RecordingsCopySummaryTests.swift`, `RecordingsOpenActionsTests.swift`. Windows — соответствующие `MeetingPresentationTests.cs` в Core, `MeetingMenuTests.cs`, `SessionDeletionTests.cs` в Live, расширить `RecordingActionsTests.cs` и `TranscriptVersionsTests.cs`.

**Run:** Swift filter `MeetingPresentationTests|MeetingMenuTests|SessionDeletionTests|Recordings.*Tests`; Windows Core и соответствующие Live filters. Для удаления использовать disposable fixtures и fake recycle, для clipboard — отдельный pasteboard/восстановление clipboard. Проверить Cancel/Undo, ошибку файловой системы и claim, полученный между открытием диалога и подтверждением.

### Task 6: Настройки без дублей, тема и About

**Create macOS:** `UI/SettingsContentView.swift`, `SettingsPage.swift`, `AboutContentView.swift`, `AppearanceController.swift`. **Modify:** `SetupForm.swift`, `SettingsWindow.swift`, `AboutWindow.swift`, `SettingsApplier.swift`, `Settings/SettingsSchema.swift`, `ConfigKeys.swift`, `Config.swift` и соответствующая документация настроек.

**Create Windows:** `App/SettingsContentView.cs`, `SettingsPage.cs`, `AboutContentView.cs`, `AppearanceController.cs`. **Modify:** `SetupForm.cs`, `AdvancedSettings.cs`, `SettingsWindow.cs`, `VerbemoRuntime.cs`, `Core/Configuration/AppSettings.cs`, `SettingsSchema.cs`.

**Interfaces:** один `SettingsPage` для каждого целевого раздела, таблица принадлежности schema paths без повторов. Новый ключ `interface_theme` с допустимыми `system | light | dark`, default `system`; существующие конфиги не требуют миграции. AppearanceController меняет appearance только приложения; System реагирует на смену темы ОС.

- [ ] Добавить `SettingsNavigationTests`: каждый редактируемый schema path представлен ровно один раз; все существующие ключи доступны; выбранный provider показывает только свои поля; cloud + local fallback не теряется. Onboarding использует те же редакторы и валидаторы.
- [ ] Разнести поля по таблице выше, включая редкие настройки в раскрываемых блоках. Сохранить Credentials/SecretStore, подсказки перезапуска для restart-only полей и применение конфигурации из внешнего редактора.
- [ ] Добавить `AppearanceTests`: absent key → System; Light/Dark сохраняются между запусками; System следует ОС; смена темы сохраняет фокус/ввод/запись. Невалидное значение даёт config problem по существующему контракту, нечитаемый конфиг не перезаписывается.
- [ ] Реализовать выбор темы и актуальные платформенные labels. Не менять настройки внешнего вида ОС; использовать semantic colors и действующие `LayerTint` / Fluent brushes для live и Markdown.
- [ ] Встроить About без дублирующего заголовка: версия из bundle / `VerbemoRuntime.AppVersion`, описание и три ссылки согласно спецификации. Удалить только отдельный авторский абзац из UI; `LICENSE`, notices и `docs/origin.md` сохраняются.
- [ ] Обновить русские UI-строки на «Сводка», английские сохранить/дополнить; не менять дисковые ключи и CLI-протокол ради copy. Проверить RU/EN всех новых и извлечённых views.

**Tests/Run:** новые `Tests/verbemoTests/SettingsNavigationTests.swift`, `AppearanceTests.swift`; расширить `SettingsSchemaTests.swift`, `SettingsApplierTests.swift`, существующие localization/documentation tests. Windows новые `windows/tests/Verbemo.Live.Tests/SettingsNavigationTests.cs`, `AppearanceTests.cs`, расширить Core `AppSettingsTests.cs`, `SettingsSchemaTests.cs`, `DisabledAnalyticsSettingsTests.cs`, Live `ClickCheckBoxThemeTests.cs`. Swift filter `SettingsNavigationTests|AppearanceTests|SettingsSchemaTests|SettingsApplierTests|SettingsDocumentationTests`; Windows Core целиком и Live settings/theme filters. Проверки не должны возвращать отключённую аналитику или сбрасывать незнакомые поля.

### Task 7: Выбор моделей и управление загрузками

**Modify macOS:** `UI/SettingsContentView.swift`, `SetupForm.swift`, `ModelDownloadProgress.swift`; переиспользовать `Transcription/DiarizationModel.swift`, `DiarizationModelStore.swift`, `VerifiedModelStore.swift`, `ModelStorage.swift`, ASR/live model stores. **Modify Windows:** `App/SettingsContentView.cs`, `SetupForm.cs`, `ModelManager.cs`, `Core/Processing/LocalModels.cs`.

**Produces:** каталожные карточки выбора с кратким описанием и общая страница хранения. Selection хранится в имеющемся config, download state — в существующем store, а не в отдельной UI-копии.

- [ ] Добавить `ModelSettingsTests`: ASR/diarization выбор с описанием, размером и статусом; выбранная и реально используемая заданием модель защищены от удаления; смена раздела не запускает повторную загрузку.
- [ ] Разделить выбор в «Расшифровке» и операции с файлами в «Хранение и модели». Не возвращать удалённый переход «Выбрать модель разделения говорящих» на странице хранения; не дублировать редакторы.
- [ ] Подключить реальные download/progress/cancel/retry/delete и занятое место. «Скачать и продолжить» возвращает ожидающую сессию в очередь ровно один раз; при смене settings во время загрузки запрос сессии не подменяется новой моделью.
- [ ] Проверить offline/error/cancel, неполную загрузку, lock используемой модели, неподдерживаемую архитектуру. Не переносить Mac-модели и размеры в Windows-каталог, если runtime их не поддерживает.

**Tests/Run:** создать `Tests/verbemoTests/ModelSettingsTests.swift`, использовать существующие store tests; Windows расширить `windows/tests/Verbemo.Core.Tests/ModelManagerTests.cs`, добавить Live `ModelSettingsTests.cs`. Swift filter `ModelSettingsTests|DiarizationLifecycleTests|WhisperModelStoreTests`; Windows Core и Live `FullyQualifiedName~ModelSettingsTests`. Сетевые загрузки в unit tests заменить текущими fake HTTP; реальную загрузку отменить/возобновить отдельно на изолированном каталоге при GUI-приёмке.

### Task 8: Сохранённый календарный контекст и сопоставление говорящих

**Modify macOS:** `Meetings/CalendarWatcher.swift`, `MeetingContext.swift`, `AutoRecordController.swift`, `Sessions/SessionInventory.swift`, `PostProcessor.swift`, `Transcription/Transcript.swift`, `UI/MeetingDetailView.swift`. **Create:** `Sessions/MeetingCalendarMetadata.swift`, `UI/MeetingCalendarView.swift`.

**Modify Windows:** `Core/Processing/SessionInventory.cs`, `Core/Processing/TranscriptDocument.cs`, `App/ProcessingCoordinator.cs`, `App/MeetingDetailView.cs`; создать `Core/Sessions/MeetingCalendarMetadata.cs`, `App/MeetingCalendarView.cs` для чтения снимка метаданных. Новый автоматический Windows-календарный провайдер не добавлять.

**Interfaces:** необязательное расширение `meta.json.calendar` c `schema_version: 2`, `event_id`, `association: confirmed | candidate`, `calendar_title`, `event_url`, `agenda`, `participants[{id,name,email?,organizer?}]`; старые `title/attendees/link/scheduled_start/scheduled_end` продолжают читаться. `link` остаётся ссылкой звонка; `event_url` — отдельная ссылка календаря. `CalendarParticipant` содержит поля `id: String`, `name: String`, необязательные `email` и `organizer` (аналогичные поля C#). Добавить `PostProcessor.setSpeakerParticipant(_ speakerID: String, participant: CalendarParticipant?, in artifactDirectory: URL) throws` и Windows `SetSpeakerParticipantAsync(string directory, string speakerId, CalendarParticipant? participant, CancellationToken cancellationToken = default)`. Они сохраняют participant ID в версионных метаданных имён и обновляют отображаемое имя через существующий механизм SpeakerNames; `nil/null` снимает календарную связь. Старые SpeakerNames без participant ID продолжают читаться. При снятии связи сохранять независимо заданное ручное имя, если оно есть; иначе возвращать исходную подпись говорящего.

- [ ] Добавить `MeetingCalendarMetadataTests`: legacy без новых полей, linked/candidate/unlinked, событие удалено, пустая агенда, отказ EventKit, неизвестные новые поля и совпадающие имена участников. Legacy/кандидат не получают ложный индикатор подтверждённой связи.
- [ ] На macOS сохранять идентичность выбранного события и occurrence вместе со снимком доступного контекста. Для календарного старта с известным событием связь подтверждена; ближайшее по времени событие при обычном старте — кандидат до явного подтверждения. Неподтверждённому кандидату предлагать подтверждение в календарном блоке, без автоматического назначения чужих участников.
- [ ] Сохранять необязательную агенду локально при включённой календарной интеграции; не передавать новые calendar notes/email в LLM автоматически. Получать переход к существующему событию по ID через платформенный адаптер; если событие недоступно, сохранить снимок и объяснить недоступность ссылки. Не открывать URL звонка под названием «Открыть в календаре».
- [ ] Добавить блок события и список приглашённых; в Windows отображать доступный сохранённый снимок и поддерживаемую внешнюю ссылку, не изображая EventKit-интеграцию. Отсутствие событий/разрешения не мешает обычным встречам.
- [ ] Добавить выбор участника над репликой и снятие связи. Изменение применяется ко всем репликам speaker ID выбранной версии, копированию и экспорту; свободное ручное имя остаётся. Не менять приглашение и не выводить источник «Говорящий N · Звук системы» под каждым селектором.
- [ ] Проверить version isolation и повторную диаризацию: новые speaker IDs не наследуют сопоставления автоматически. Использовать session lock и существующий атомарный merge ручных имён; при занятости показать причину.

**Tests/Run:** новые `Tests/verbemoTests/MeetingCalendarMetadataTests.swift`, `SpeakerParticipantMappingTests.swift`; расширить `CalendarWatcherTests.swift`, `SessionNamingTests.swift` и `Sessions/SpeakerNamerTests.swift`. Windows новые Core `MeetingCalendarMetadataTests.cs`, Live `SpeakerParticipantMappingTests.cs`; Swift filter `MeetingCalendarMetadataTests|SpeakerParticipantMappingTests|CalendarWatcherTests|SessionNamingTests|SpeakerNamerTests`, Windows соответствующие filters. Не требовать реального календаря для unit tests; реальный macOS-переход к событию — отдельная проверка с разрешённым тестовым календарём.

### Task 9: Удаление старых оболочек и итоговая приёмка

**Modify:** старые `StatusWindow` / `SettingsWindow` / `AboutWindow` / `RecordingsWindow` и их call sites, тесты окон; `docs/testing/` — сценарии и фактические свидетельства нового интерфейса. Удалять оболочки только после переноса содержимого, подписок и всех входов. Отдельный setup/onboarding host остаётся только там, где нужен первый запуск/системные разрешения; обычные настройки всегда в основном окне.

- [ ] Поискать все старые точки создания окон и неоднозначные «Доделать», «не вышло», «Саммари пока нет»; заменить на целевые маршруты/понятные состояния. Старый `SettingsWindow.show()` не должен быть запасным путём к дублирующим настройкам.
- [ ] Выполнить focused tests каждого этапа, затем существующие полные проверки. macOS: `make verify-localvqe`, `VERBEMO_REQUIRE_LOCALVQE=1 swift test --no-parallel`, `swift build -c release`. Проверить наличие финального отчёта Swift Testing, а не только exit code. Отсутствующий LocalVQE/пропуск записать честно.
- [ ] На доступном Windows-хосте: `dotnet build windows/Verbemo.Windows.slnx -c Release`; `dotnet test windows/tests/Verbemo.Core.Tests/Verbemo.Core.Tests.csproj -c Release`; `dotnet test windows/tests/Verbemo.Live.Tests/Verbemo.Live.Tests.csproj -c Release`. Подтвердить хост и checkout до запуска. #19 не обходить отключением тестов: Windows-часть не принимается по skipped job или успешному Mac.
- [ ] Запустить реальные нативные приложения на обеих ОС и пройти сценарии ниже с изолированными данными. Сохранить source SHA, версию сборки, платформу, размеры/масштаб, скриншоты и наблюдаемые результаты. HTML-тесты не являются доказательством нативного поведения.
- [ ] Проверить локальные/ad-hoc сборки по текущему release route без публикации. Не менять VERSION/теги/релизные ограничения и не обещать Windows-релиз до #19. Учитывать, что merge в master запускает текущий автоматический preview workflow.

## Критерии приёмки задачи

- [ ] На каждой платформе одно основное окно; все Settings/About/menu/tray/reopen входят в него, открытие разделов не размножает окна.
- [ ] Запись, пауза, live-текст и таймер работают из общего окна; полоса сверху остаётся в настройках, название открывает текущую запись. Закрытие окна сохраняет фоновые процессы.
- [ ] Все встречи / В обработке / Нужны действия, поиск, переход в карточку и возврат, сохранение версии/вкладки работают согласно спецификации.
- [ ] В карточках дата и время полного формата, нейтральный фон/hover, компактные пиктограммы с нужным порядком и состояниями; диаризация слева снизу; «Сводка не создавалась»; Reduce Motion без пульсации.
- [ ] Оба меню и кнопки в содержимом используют одни обработчики/правила; копирование и генерация соседствуют, терминология едина.
- [ ] **Ни одна поверхность и прямой вызов команды не запускают сводку до готовности расшифровки нужной версии.** Проверены live, queued ASR, missing/corrupt transcript, version request и busy session.
- [ ] Повторный ASR сохраняет версии; повтор сводки не запускает ASR/naming, не теряет прежний результат при ошибке и не выполняет on_stop повторно.
- [ ] Все четыре text/Markdown copy работают с нужной версией и ручными именами; вложенные списки и существующий RTF не сломаны.
- [ ] Переименование, открытие папки, прослушивание, открытие расшифровки, удаление/отмена и запреты при записи/обработке проверены на реальных файлах fixtures.
- [ ] Настройки имеют один редактор на параметр, сохраняют старые и неизвестные значения; restart-only поля объясняют срок применения. Выбор темы сохраняется, System реагирует на ОС.
- [ ] Модели ASR/диаризации имеют актуальные описания; selection отделён от download/delete; используемые модели защищены, download/cancel/resume проверены.
- [ ] Календарный блок появляется только при подтверждённой связи; агенда необязательна, приглашённые не называются фактическими участниками; переход открывает событие. Старые данные читаются без миграции/ложных связей.
- [ ] Сопоставление говорящего действует во всех его репликах и экспорте выбранной версии; изменяется/снимается, не затрагивает календарь и другие версии/встречи.
- [ ] About без toolbar: реальная версия и ссылки собственного репозитория, описание функций, сохранённые лицензии.
- [ ] GUI-проверены ширины около 731, 796, 961 и 1280 логических px, невысокое окно около 600 px, длинные тексты, 125–200% Windows DPI, RU/EN, светлая/тёмная/системная тема, клавиатура и screen reader. Макетные значения адаптируются к нативным points/DPI без обрезки содержимого.
- [ ] Для каждой платформы приложены собственные build/test и GUI-свидетельства; известные блокеры явно отмечены, Windows не объявлен проверенным заочно. Задача не закрывается только по готовности HTML или macOS.

## Зависимости и организация доставки

- #8 — повтор после ошибок summary/naming и диагностика CLI: согласовать сервисную часть этапа 2, не дублировать её независимыми обработчиками.
- #19 — восстановление Windows CI/release; блокирует окончательное подтверждение Windows-поставки, а не изучение макета и подготовку UI-кода.
- #11 — качество диаризации вне scope: новый UI сохраняет неизвестные подписи вместо уверенных неправильных имён и не заявляет улучшение качества модели.
- Порядок: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9. После каждого этапа — focused checks, отдельный Conventional Commit/PR с Co-Authored-By по правилам репозитория; не ждать конца перед проверкой связей между этапами.
- До реализации перечитать исходный план и текущий master; изменения требований заносить в эту задачу и спецификацию. Реализацию, слияние и публикацию не считать выполненными при создании плана.

## Проверяемые ссылки на исходники

Все ссылки закреплены на просмотренном SHA, а не на плавающем master:

- [macOS: AppController и wiring окон](https://github.com/ekho/verbemo/blob/0d543151cafe47771c2e134aec15be6208ea9864/Sources/verbemo/Verbemo.swift)
- [macOS: библиотека и версии](https://github.com/ekho/verbemo/blob/0d543151cafe47771c2e134aec15be6208ea9864/Sources/verbemo/UI/RecordingsWindow.swift)
- [macOS: настройки и применение](https://github.com/ekho/verbemo/blob/0d543151cafe47771c2e134aec15be6208ea9864/Sources/verbemo/UI/SettingsApplier.swift)
- [macOS: календарный снимок](https://github.com/ekho/verbemo/blob/0d543151cafe47771c2e134aec15be6208ea9864/Sources/verbemo/Meetings/MeetingContext.swift)
- [macOS: post-processing](https://github.com/ekho/verbemo/blob/0d543151cafe47771c2e134aec15be6208ea9864/Sources/verbemo/Sessions/PostProcessor.swift)
- [Windows: оболочки приложения](https://github.com/ekho/verbemo/blob/0d543151cafe47771c2e134aec15be6208ea9864/windows/src/Verbemo.App/App.xaml.cs)
- [Windows: runtime](https://github.com/ekho/verbemo/blob/0d543151cafe47771c2e134aec15be6208ea9864/windows/src/Verbemo.App/VerbemoRuntime.cs)
- [Windows: обработка](https://github.com/ekho/verbemo/blob/0d543151cafe47771c2e134aec15be6208ea9864/windows/src/Verbemo.App/ProcessingCoordinator.cs)
- [CI и текущая пауза Windows](https://github.com/ekho/verbemo/blob/0d543151cafe47771c2e134aec15be6208ea9864/.github/workflows/ci.yml)
