# Verbemo Independent Releases Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Подготовить отдельный Verbemo для macOS и Windows с собственными данными, подписью и единым проверяемым релизом в `ekho/verbemo`.

**Architecture:** Выборочно перенести Windows-реализацию в текущую macOS-базу, затем переименовать обе платформы и убрать статистику. Платформенные скрипты только собирают и проверяют пакеты; один ручной workflow собирает обе платформы из одного commit, объединяет артефакты и управляет публикацией через GitHub Releases. Публичный релиз и сайт в ходе этой задачи не публикуются.

**Tech Stack:** SwiftPM/AppKit, Sparkle; C#/.NET 10/WPF, Velopack 1.2.0; Bash, PowerShell, Python standard library, GitHub Actions, `gh`.

**Spec:** `docs/superpowers/specs/2026-10-19-verbemo-independent-releases-design.md`, утверждена пользователем 2026-10-19. Продуктовые решения уже приняты; этот документ задаёт порядок реализации и доказательства.

## Поправка пользователя, 2026-10-19

Покупка Apple Developer Program отложена. Локальные macOS-сборки с ad-hoc
подписью и их проверка продолжаются сейчас. Подготовка собственного подписанного
релиза, Developer ID и notarization остаётся в объёме работ; фактическая
сертификатная подпись и notarization ожидают членства и собственных credentials.
При отсутствии credentials preflight подписанного релиза должен явно завершаться
ошибкой. Это не блокирует импорт исходников, локальные сборки и тестирование.

## Global Constraints

- Продолжать `codex/verbemo-independent-releases`; исходный проверенный HEAD — `542f4922c516ed06341c49deca66870c993033f1`. Рабочая копия при подготовке плана чистая; `origin` заново получен через fetch.
- Название `Verbemo`, Swift package/executable/CLI `verbemo`, .NET `Verbemo.*`, Windows package ID `Verbemo`, первая собственная `VERSION` — `0.1.0`.
- macOS bundle ID и префикс собственных IPC/notification/service identifiers — `name.ekho.verbemo`. Идентификаторы сторонних framework сохраняются.
- Собственные `VERBEMO_*`; стандартные переменные провайдеров и инструментов сохраняются. Настройки macOS — `~/.config/verbemo`, собственные кеши/модели; записи на обеих платформах — `~/Verbemo Recordings`.
- Amanu и его данные остаются нетронутыми; автоматического переноса нет. Существующий выбор каталога позволяет открыть прежние записи по явному выбору пользователя. Общие ключи провайдеров доступны только для чтения.
- Windows-источник — `87b3b120278e5d0b10d79ff3355c017d4e52082c` из `origin/codex/ready-0.6.3`, подтверждён повторным fetch. Сохраняются macOS-диаризация, история, лицензии и copyright.
- Один source commit, один `VERSION`, один релиз `Verbemo <VERSION>` и тег `verbemo-v<VERSION>` для обеих платформ.
- Assets: `Verbemo-<VERSION>-macos-universal.dmg`, `Verbemo-<VERSION>-windows-x64-Setup.exe`, `Verbemo-<VERSION>-windows-x64-Portable.zip`, Windows update packages/metadata, `appcast.xml`, `releases.stable.json`, один общий `SHA256SUMS`.
- Sparkle: `https://github.com/ekho/verbemo/releases/latest/download/appcast.xml`; Windows `SimpleWebSource`: `https://github.com/ekho/verbemo/releases/latest/download/`, канал `stable`. Все пакеты feed присутствуют в том же релизе.
- Отдельных платформенных релизов, тегов и `verbemo-updates` нет. Ошибка любой платформы блокирует публикацию. Опубликованные assets и теги не заменяются; latest продвигается после проверки публичных скачиваний и хешей.
- Статистика приложения и сайта отключена, analytics backend не создаётся. Рабочий код и релиз не зависят от доменов, сервера, аккаунтов, ключей или publisher автора Amanu.
- Development-сборка возможна без релизных ключей; подписанный release без собственных credentials завершается ошибкой. Секреты не попадают в Git, аргументы диагностических выводов и логи.
- Только ненужные ветки, слитые в свежий `origin/master`, допускаются к удалению после проверяемой резервной копии. Все неслитые ветки, master и существующие теги сохраняются. `amanu` и `upstream` не изменяются.
- Conventional Commits; каждый commit содержит `Co-authored-by: OpenAI Codex <noreply@openai.com>`. Это явное указание пользователя имеет приоритет над старым разделом Commit messages в `CLAUDE.md`.

## Review Focus

1. На компьютере уже установлена Amanu с записями, ключами, автозапуском и запущенным процессом: Verbemo создаёт своё состояние и не активирует, не переносит и не удаляет чужое. Проверки: задачи 2, 3, 9.
2. Локальная конфигурация содержит `analytics: true`, а старые события лежат на диске: запуск, запись, завершение и CLI не создают идентификатор и не отправляют статистику. Проверки: задача 4.
3. Ref изменился между запуском workflow и сборкой, checkout неглубокий или пакеты взяты из разных сборок: подготовка останавливается до draft/publication. Проверки: задачи 5, 6, 7.
4. Процесс оборвался после публикации, загрузка вернула 404/неверный hash или другой релиз уже стал latest: повтор проверяет опубликованные bytes, не загружает assets заново и не откатывает latest. Проверки: задача 7.
5. Имя Windows installer/portable изменено, а inventory/feed осталось прежним; файлы отсутствуют, дублируются или имеют небезопасные пути: комплект отклоняется до публикации. Проверки: задачи 6, 7.

## Проверенная среда и ограничения

- Mac: Xcode 27.1, Swift 6.4; `security find-identity -v -p codesigning` вернул `0 valid identities found`.
- Именованные в спецификации `VERBEMO_*` credentials не заданы; список GitHub Actions secrets `ekho/verbemo` пуст. Проверялись наличие и имена, значения не выводились.
- `dotnet` и `pwsh` на этом Mac отсутствуют. В доступных проектах/чатах и интерфейсе handoff этой сессии доступен локальный хост; доступ к Windows-проекту не подтверждён. Это ограничение доступа, а не утверждение об отсутствии компьютера.
- Активный `gh` — `boris-gorbylev`; отдельно подтверждён доступ как `ekho` через токен из keyring, переданный только окружению дочернего процесса. Глобальный аккаунт не переключался. Открытых PR в `ekho/verbemo` при проверке нет; перед удалением веток это проверяется заново.
- Рабочая ветка пока отсутствует в origin. Реализация ещё не начата; сборки и продуктовые тесты при составлении плана не запускались.

## Карта файлов и общие интерфейсы

- `Sources/amanu/` → `Sources/verbemo/`, `Tests/amanuTests/` → `Tests/verbemoTests/`: существующая macOS-реализация и её проверки; package references обновляются вместе с переносом.
- `windows/`: выборочно импортированная реализация; затем `Verbemo.Windows.slnx`, `src/Verbemo.App`, `src/Verbemo.Core`, `tests/Verbemo.*` и соответствующие `.csproj`.
- `scripts/release_manifest.py` — стандартная библиотека Python: `validate_version(version: str) -> str`, `validate_release(directory: Path, version: str, source_commit: str, build_number: int) -> dict`, `write_checksums(directory: Path) -> Path`. Проверка metadata, feed, полного комплекта и hash; GitHub-записей нет.
- `scripts/release.py` — preflight и последовательность GitHub-операций; команды `preflight`, `prepare`, `publish`, `resume`. `prepare --dry-run` проверяет локальные fixtures без сети и загрузок; `publish` и `resume` явно выбираются оператором.
- `scripts/build-macos-release.sh` и `windows/scripts/Build-Release.ps1` — создание платформенных пакетов и локальных квитанций `macos-build.json` / `windows-build.json`; публикации нет.
- Квитанция содержит `platform`, `version`, `source_commit` (полный SHA), `build_number`, имена/hash/размеры файлов и результат проверки подписи. В общий комплект попадают только квитанции успешных платформенных задач одного запуска.
- `release-manifest.json` объединяет квитанции и список payload/feed/inventory с hash/размерами; не включает собственный hash и `SHA256SUMS`. Общий `SHA256SUMS` покрывает все публикуемые файлы, включая manifest, кроме самого себя. Квитанции — доказательства workflow, фактические подписи проверяются платформенными средствами.
- `.github/workflows/ci.yml` — проверки обеих платформ без публикации; `.github/workflows/release.yml` — единственный ручной маршрут общего релиза. Старые платформенные publisher workflows удаляются после переноса нужных проверок.
- `scripts/cleanup-merged-branches.py` — отдельный инструмент inventory/apply с явным списком кандидатов, bundle и защитой SHA; проверки на временных локальных репозиториях.

## Task 1: Интегрировать сохранённую Windows-реализацию

**Files:** импортировать из указанного SHA `windows/Amanu.Windows.slnx`, `windows/Directory.Build.props`, `windows/Directory.Packages.props`, `windows/src/`, `windows/tests/`, `windows/scripts/`, `windows/patches/`, `windows/Licenses/`; дополнить `.gitignore`, `THIRD-PARTY-NOTICES.md`; создать `docs/windows-source-import.md`; обновить `AGENTS.md`.

**Interfaces:** потребляет проверенный Windows SHA; предоставляет полное дерево Windows с прежним поведением для переименования. `Sources/`, `Tests/amanuTests/`, `Package.swift`, `Makefile` и `VERSION` этим импортом не заменяются.

- [ ] **Step 1:** Сохранить `git diff --name-status` между базами и точный список импортируемых путей в `docs/windows-source-import.md`; для корневых notices перенести только недостающие Windows-зависимости. Зафиксировать исходный commit, а не движущееся имя ветки.
- [ ] **Step 2:** Перенести перечисленные пути через Git из этого SHA. Сравнить их tree/blob IDs с источником до переименования; `git diff --exit-code 542f492 -- Sources Tests/amanuTests Package.swift Makefile VERSION` должен пройти.
- [ ] **Step 3:** Обновить `AGENTS.md`: общая база обеих платформ и предстоящий единый маршрут; убрать обязательность отдельной Windows release-ветки и старое правило имени Amanu installer. Исторические инструкции сохраняются в истории Git.
- [ ] **Step 4:** На Windows выполнить исходные `dotnet restore windows/Amanu.Windows.slnx`, `dotnet build windows/Amanu.Windows.slnx -c Release --no-restore`, `dotnet test windows/tests/Amanu.Core.Tests/Amanu.Core.Tests.csproj -c Release --no-restore`, `dotnet test windows/tests/Amanu.Live.Tests/Amanu.Live.Tests.csproj -c Release --no-restore`, `windows/tests/Test-ReleaseInstallerName.ps1`. Если хост ещё недоступен, сохранить импорт как source-only и продолжить независимые задачи; задачу Windows acceptance оставить открытой.
- [ ] **Step 5:** `git diff --check`; commit `build: integrate the preserved Windows application sources` с Co-authored-by и ссылкой на исходный SHA в теле.

## Task 2: Переименовать macOS и отделить данные/идентификаторы

**Files:** переносы из карты; `Package.swift`, `VERSION`, `Makefile`; `Packaging/Verbemo-Info.plist`, `Packaging/Verbemo.entitlements`; `Resources/Verbemo.icns`, `Resources/Verbemo.icon/`; все собственные имена в Swift, scripts и тестовых callers. Основные точки: `Home.swift`, `Runtime.swift`, `ApplicationRelocation.swift`, `SingleInstance.swift`, `Notifications.swift`, `Setup/SetupCommand.swift`, `Sessions/RecordCommand.swift`, `Setup/Credentials.swift`, `Transcription/*ModelStore.swift`, `App/`, `UI/`. Создать `Tests/verbemoTests/ProductIdentityTests.swift`.

**Interfaces:** сохраняет существующие Swift APIs и диаризацию; меняет идентичность, пути, env, bundle/CLI/ресурсные ссылки. Предоставляет `make app` → `.build/Verbemo.app`, CLI `verbemo`, `VERSION=0.1.0`.

- [ ] **Step 1:** Добавить sandbox-тесты `separateHomeAndRecordings`, `separateModelsAndIPC`, `doesNotReadOrModifyAmanu`: создать прежние каталоги/конфиг с sentinel bytes, проверить новые пути, отдельные notifications, отсутствие чтения старых настроек и неизменность bytes после записи новых. Общие ключи провайдера остаются read-only; явно выбранный старый каталог открывается существующим API.
- [ ] **Step 2:** Запустить новые тесты до переименования; ожидается падение на старых путях/именах. Выполнить переносы и адресные замены собственных имён, `@testable import`, target references и `AMANU_*` callers. Рисунок значка, сторонние модели/framework и copyright оставить прежними.
- [ ] **Step 3:** Обновить login item, CLI symlink, relocation destination и собственные notification/service names. `Home.current` остаётся единственным входом для тестовых путей; default recordings становится `Verbemo Recordings`, без миграции Amanu.
- [ ] **Step 4:** `swift test --no-parallel`, Python script tests; затем `make app`. Проверить `lipo -archs`, plist bundle ID/version, лицензии, icon, LocalVQE/Nemotron и native frameworks. Реальный CLI проверить через `--help`; поведение `doctor` в тестах вызывать внутри `Home.scoped` sandbox. Реальный CLI doctor проверяется в задаче 9 с собственным состоянием Verbemo: подмена переменной HOME сама по себе не считается изоляцией Foundation home.
- [ ] **Step 5:** Убедиться, что тесты diarization/alignment/lifecycle и существующий механизм безопасной ad-hoc подписи сохранены. Commit `feat: give the macOS application its Verbemo identity`.

## Task 3: Переименовать Windows и убрать автоматический перенос Amanu

**Files:** переименовать solution, проекты/каталоги, namespaces, `AmanuRuntime.cs` → `VerbemoRuntime.cs`, `Assets/Amanu.ico` → `Assets/Verbemo.ico`; обновить XAML, manifests, scripts, tests. Особое внимание: `App.xaml.cs`, `StartupRegistration.cs`, `SecretStore.cs`, `Configuration/AppSettings.cs`, `ModelManager.cs`. Создать `windows/src/Verbemo.Core/Configuration/ProductIdentity.cs`, `windows/tests/Verbemo.Core.Tests/ProductIdentityTests.cs`.

**Interfaces:** `ProductIdentity.DataDirectory(localAppData: string) -> string` возвращает `Verbemo Data`; `ProductIdentity.RecordingsDirectory(home: string) -> string` — `Verbemo Recordings`. Именованные константы определяют отдельные mutex/doorbell, credential prefix и startup entry; runtime и тесты используют их. Пакет устанавливается в собственный `%LOCALAPPDATA%/Verbemo`.

- [ ] **Step 1:** Тесты `AmanuDataRemainsUntouched`, `UsesIndependentCredentialAndStartupNames`, `ExplicitRecordingDirectoryStillWorks`: существующие `Amanu`, `Amanu Data`, записи и настройки остаются без изменений; defaults и IPC различаются. Запустить на Windows и увидеть падение на старой identity.
- [ ] **Step 2:** Выполнить переименование product-owned references, UI EN/RU и `VERBEMO_TEST_DATA`. Удалить вызов и ненужную реализацию автоматического `MoveOutOfInstallFolder` для Amanu; новая установка не импортирует старое состояние.
- [ ] **Step 3:** Обновить solution/project includes, WPF resource URI, assembly name, версии из корневого `VERSION`, tray/shortcut/autostart. Сохранить pinned native runtime versions и Unicode/CPU smoke tests.
- [ ] **Step 4:** На Windows: restore/build `windows/Verbemo.Windows.slnx`, Core/Live tests и native CPU/Unicode проверки. Все обязательные тесты проходят; пропуски platform/device tests перечисляются. На Mac выполнять только статические проверки без заявления Windows runtime acceptance.
- [ ] **Step 5:** Commit `feat: isolate the Windows application as Verbemo`.

## Task 4: Отключить статистику и убрать инфраструктуру автора

**Files:** `Sources/verbemo/Analytics/`, `Settings/SettingsSchema.swift`, `Settings/ConfigKeys.swift`, CLI registration/analytics command, настройки/setup/about; `windows/src/Verbemo.App/AnalyticsService.cs`, `windows/src/Verbemo.Core/Analytics/`, настройки/schema; удалить активные `scripts/analytics/`. Обновить прежние analytics tests и создать `Tests/scripts/test_independent_product.py`.

**Interfaces:** существующие `Analytics.start`, `track`, `settingChanged`, `flushOnExit` и Windows callers сохраняются как небольшой no-op там, где удаление callers потребовало бы менять рабочую логику. Sink/transport/identity/storage больше не создаются; аналитика всегда выключена.

- [ ] **Step 1:** Переписать проверки на новое требование: default, `analytics: true`, malformed config, pending events, start/record/quit/CLI дают ноль transport calls и не создают analytics identity/queue. Существующие тесты полезных recording/privacy границ сохранить.
- [ ] **Step 2:** Удалить рабочую отправку и идентификаторы статистики, UI-переключатель и старое объяснение о включённой отправке. `verbemo analytics` сообщает об отключённой статистике; попытка `on` возвращает понятную ошибку, не меняя настройки. Старое поле конфига не включает transport.
- [ ] **Step 3:** В `test_independent_product.py` задать явную область runtime/build/release/site файлов и запретить прежние endpoints, публичный Sparkle key, publisher и собственные `AMANU_*`. Исключения только для конкретной атрибуции, provenance и исторических документов; запрет не распространяется на имена сторонних зависимостей или явно выбранные пользователем пути.
- [ ] **Step 4:** Запустить Swift analytics/consent/schema tests, Windows соответствующие Core/Live tests, `python3 -m unittest discover -s Tests/scripts -p 'test_*.py'`. Подтвердить отсутствие network calls тестовыми transport spies, а не реальной отправкой.
- [ ] **Step 5:** Commit `fix: disable inherited product analytics and services`.

## Task 5: Подготовить собственную macOS-подпись и Sparkle

**Files:** `Makefile`, plist, `Sources/verbemo/Updates/AppUpdates.swift`, `Updates/UpdateGate.swift`, `Verbemo.swift` (бывший `Amanu.swift`), переходы состояния transcription/sweep/media import; `Tests/verbemoTests/UpdateGateTests.swift`; создать `scripts/build-macos-release.sh`, `scripts/release_manifest.py`, `Tests/scripts/test_release_manifest.py`, `.env.verbemo-release.example`; обновить `Tests/scripts/test_local_signing.py`, `test_release_preflight.py`, `test_update_feed_location.py`, `.gitignore`.

**Interfaces:** `scripts/build-macos-release.sh --version <VERSION> --source-commit <SHA> --output <dir>` выпускает DMG, подписанный `appcast.xml` и `macos-build.json`. `VERBEMO_SIGN_ID` явный для release; `VERBEMO_SPARKLE_PUBLIC_KEY` встраивается при bundle build, private key только через `VERBEMO_SPARKLE_PRIVATE_KEY_FILE`.

- [ ] **Step 1:** Добавить падающие tests: missing credentials до build/network; wrong origin/version/SHA, shallow history и dirty tree отклоняются; dev bundle без key не запускает Sparkle; bundle с key использует собственный feed. Проверить ключ/public-private match и отказ перезаписи готового versioned DMG.
- [ ] **Step 2:** Реализовать `validate_version` для стабильного трёхкомпонентного SemVer и preflight, проверяющий source/`VERSION`/origin. `build_number` получать из полной истории того же SHA; сохранять единое значение в receipts, plist и feed. Исторические версии Amanu не задают floor для пространства `verbemo-v*`.
- [ ] **Step 3:** Выделить macOS packaging из старого publisher. Потреблять явные `VERBEMO_SIGN_ID`, Sparkle key file/public key, `VERBEMO_NOTARY_KEY_FILE`, `VERBEMO_NOTARY_KEY_ID`, `VERBEMO_NOTARY_ISSUER_ID`; release не допускает ad-hoc или fallback после signing failure. Dev-сборка сохраняет допустимый ad-hoc режим без Hardened Runtime.
- [ ] **Step 4:** Сохранить universal/minimum-macOS checks, nested signing innermost-first, обязательные ресурсы/лицензии, notarization/staple/Gatekeeper проверки. Appcast подписывает финальные bytes DMG, указывает конкретный `verbemo-v<VERSION>` download URL и совпадающие version/build/size. Сайт и чужие `.env.asc` не читаются.
- [ ] **Step 5:** Исправить подтверждённый пробел UpdateGate: текущий `AppController` передаёт только `isRecording` и освобождает install сразу после stop, до последующей обработки. Ввести `UpdateGate.init(isBusy: @escaping () -> Bool)`, `postponeInstallIfBusy(_ install: @escaping () -> Void) -> Bool`, `activityDidChange() -> Void`; predicate включает запись, очередь/постобработку и media import. Обновить callers при постановке и завершении работы; install вызывает handler ровно один раз только после повторной проверки idle. Тесты покрывают recording → processing → idle, новую запись до завершения processing, повторные idle callbacks, ошибку updater и сохранение записи. Алгоритмы транскрибации не менять.
- [ ] **Step 6:** Python tests и локальная dev-сборка проходят; реальный signed/notarized package проверяется только при наличии ключей. Документировать безопасный пример конфигурации; `.env.verbemo-release`, private keys и сертификаты игнорируются. Commit `build: prepare independent macOS signing and updates`.

## Task 6: Подготовить собственные Windows-пакеты и обновления

**Files:** `windows/src/Verbemo.App/UpdateService.cs`, `windows/scripts/Build-Release.ps1`, `Set-ReleaseInstallerName.ps1`, `Test-ReleaseSignatures.ps1`; `windows/tests/Test-ReleaseInstallerName.ps1`; создать `windows/tests/Test-ReleaseArtifacts.ps1`, `windows/tests/Verbemo.Live.Tests/UpdateServiceTests.cs`; дополнить `scripts/release_manifest.py` и его tests.

**Interfaces:** `Build-Release.ps1 -Version <VERSION> -SourceCommit <SHA> -OutputDirectory <dir> [-CertificatePath <path> -CertificatePassword <secret>] [-Development]`. Release mode требует сертификат; явный Development допускает unsigned пакет и маркирует его непригодным к публикации. Выход: versioned installer/portable, полный текущий `.nupkg`, metadata/feed, `windows-build.json`.

- [ ] **Step 1:** Добавить tests на точные имена installer/portable, несовпадение `VERSION`, отсутствие сертификата в release mode, collision имён и отсутствующий referenced package. После rename hash signed bytes не меняется; обе inventory-записи получают новые имена до checksums.
- [ ] **Step 2:** Переименовать Velopack pack ID/title/mainExe/author metadata в Verbemo; сохранение лицензий проверить и в portable, и в nupkg. Выходную папку делать новой; предыдущие версии не подмешивать. Полный текущий пакет исключает зависимость feed от старого релиза.
- [ ] **Step 3:** Проверять Authenticode, timestamp и соответствие собственного сертификата на Setup, first-party payload, launcher/updater, содержимом portable/nupkg. Ожидаемую identity брать из явно предоставленного сертификата, без Fands/Azure credentials автора. Пароль не печатать, временные key/cert files удалять в `finally`.
- [ ] **Step 4:** Заменить `GithubSource` на `SimpleWebSource` с утверждённым URL и `ExplicitChannel = "stable"`. Update tests через подставной downloader/feed проверяют package resolution, 404, cancellation и запрет установки во время recording/processing; публичная сеть не используется.
- [ ] **Step 5:** Windows build/Core/Live tests и PowerShell artifact tests проходят. `Set-ReleaseInstallerName.ps1` больше не создаёт частный публикуемый SHA256SUMS; единственный общий файл делает задача 7 после объединения обеих платформ. Commit `build: prepare Verbemo Windows packages and update feed`.

## Task 7: Один общий release workflow и проверка полного комплекта

**Files:** создать `.github/workflows/release.yml`, `scripts/release.py`, `Tests/scripts/test_common_release.py`; дополнить `scripts/release_manifest.py`, `test_release_manifest.py`; заменить опасное поведение `scripts/release.sh` явной справкой/переходом к общему маршруту; обновить `.github/workflows/ci.yml`, удалить `.github/workflows/windows-beta.yml`, перенести нужные metadata checks в CI.

**Interfaces:** workflow inputs `ref`, `version`, `operation=prepare|publish|resume` (default `prepare`). `release.py preflight --ref ... --version ...`; `prepare --artifacts ... --version ... --source-commit ... --build-number ... [--dry-run]`; `publish --artifacts ...`; `resume --tag verbemo-v<VERSION>`. Только publish/resume имеют GitHub write permission; `resume` не зависит от jobs сборки.

- [ ] **Step 1:** Tests `BothPlatformsRequired`, `SameVersionAndCommitRequired`, `FeedPackagesMustExist`, `OneSharedTagAndChecksum`, `WrongRepositoryRejected`, `DryRunHasNoWrites`, `LatestAfterPublicHashCheck`, `ResumeNeverRebuildsOrOverwrites`, `NewerLatestNeverRollsBack`. Использовать локальные fixtures, временный Git repo и stub `gh`/HTTP: assertions на порядок команд/состояний, ноль реальных запросов и секретов.
- [ ] **Step 2:** Реализовать `validate_release`: обе receipts успешны; версия/SHA/build равны; имена уникальны, без абсолютных путей/`..`; размеры/hash совпадают; appcast enclosure и все Velopack feed/inventory entries указывают на присутствующие файлы этого релиза. Изменённый package, лишняя/отсутствующая платформа и неверная подпись платформенной проверки отклоняются до draft.
- [ ] **Step 3:** Реализовать `write_checksums` после окончательных имён и metadata; `prepare` формирует `release-manifest.json` и единственный `SHA256SUMS`. Положительный fixture даёт предсказуемый полный набор; отрицательные cases из Review Focus 3/5 завершаются ошибкой без GitHub-записей.
- [ ] **Step 4:** Workflow разрешает ref в полный SHA один раз и checkout обеих платформ делает именно по нему с полной историей. Данные inputs передаются через env/проверенные arguments, не вставляются в исполняемый shell. `concurrency: verbemo-release`, `cancel-in-progress: false`; jobs macOS/Windows → aggregate с `needs` обеих успешных jobs. Push/PR CI собирает и проверяет обе платформы с `contents: read`.
- [ ] **Step 5:** Для CI описать собственный импорт Developer ID через `VERBEMO_MACOS_CERTIFICATE_BASE64`/`VERBEMO_MACOS_CERTIFICATE_PASSWORD` во временный keychain; notarization key через `VERBEMO_NOTARY_KEY_BASE64` материализуется в `VERBEMO_NOTARY_KEY_FILE`. Windows — `VERBEMO_WINDOWS_CERTIFICATE_BASE64`/`VERBEMO_WINDOWS_CERTIFICATE_PASSWORD`. Публичный Sparkle key и остальные указанные spec IDs задаются отдельно. Credentials только в signing jobs; очистка keychain/файлов обязательна. Эти дополнительные имена — детали доставки ключей в CI, не новые сервисы.
- [ ] **Step 6:** `publish` явно нацелен на `ekho/verbemo`: проверить свежие stable Verbemo version/build floors и tag SHA; создать один draft и тег без force; загрузить полный набор без clobber; скачать draft assets через API и сверить. Опубликовать с `make_latest=false`, проверить публичные скачивания без token и SHA256SUMS, повторно проверить version floor, затем `make_latest=true`. До последней операции прежний latest сохраняется.
- [ ] **Step 7:** Для существующего draft повтор разрешает только совпадающие SHA/manifest/bytes и догружает отсутствующее; конфликт останавливает процесс. Для опубликованного тега доступен только `resume`: сверка полного опубликованного набора и продвижение latest, без build/upload/delete/tag rewrite и без требования повторно предоставить signing credentials. Неудачный публичный download оставляет latest прежним; более новый latest запрещает откат. Fixture-тесты покрывают каждый сбой и повтор.
- [ ] **Step 8:** Все Python/workflow tests проходят, CI для обеих платформ проверен после публикации ветки/PR. В этой задаче запускать только проверки и `prepare --dry-run` с fixtures: public publish/resume не исполнять. Commit `ci: prepare one gated release for all Verbemo platforms`.

## Task 8: Документация, сайт и package manifests

**Files:** `README.md`, `SUPPORT.md`, `CLAUDE.md`, `AGENTS.md`, `docs/releasing.md`, `docs/pitfalls.md`, `docs/analytics.md`, активные testing/runbooks; Windows README/BETA/LIVE_TRANSCRIPTION/packaging docs; `landing/index.html`, `landing/ru/index.html`, обе privacy pages, `script.js`, `README.md`, `robots.txt`, `sitemap.xml`, `landing/tests/check.py`, `browser.cjs`; download helpers/tests и `.github/workflows/readme-downloads.yml`.

**Interfaces:** до первого собственного релиза download links ведут на `https://github.com/ekho/verbemo/releases`. После реального релиза helpers принимают проверенный общий manifest и формируют versioned ссылки/manifest, без публикации каталогов пакетов или сайта.

- [ ] **Step 1:** Изменить download/landing tests: EN/RU показывают Verbemo, собственный source/support, статистика отключена, запросов `/m`/stats нет; до первого релиза используются Releases links без выдуманных installers. Убрать заявления о состоявшейся подписи Apple/Microsoft и текущей публичной версии Amanu.
- [ ] **Step 2:** Обновить тексты и существующий About с атрибуцией происхождения/лицензиями. Удалить активные `landing/deploy/nginx/amanu*.conf`, старый `landing/appcast.xml`, чужие domain canonical/sitemap URLs без замены выдуманным доменом. Локальный сайт и релиз работают без nginx/SSH deploy.
- [ ] **Step 3:** Перенести исторические Amanu Scoop/WinGet manifests в `docs/history/amanu-packaging/` без подмены publisher. Подготовить генерацию собственных manifest из реальных version/hash/signature metadata; до появления артефактов не публиковать фиктивный install command или manifest с placeholder checksum.
- [ ] **Step 4:** Переснять локальные macOS-скриншоты после задачи 9 и обновить проверки изображений. Старые брендированные Windows-снимки убрать из активных страниц до получения снимков действующего Verbemo на Windows; происхождение исторических материалов сохранить. Новый дизайн/рисунок значка не требуется.
- [ ] **Step 5:** `python3 landing/tests/check.py`, browser behavior tests через существующий runner и все Tests/scripts проходят. `docs/releasing.md` описывает credentials, один release, dry-run, восстановление после сбоя и точные пределы проверок. Commit `docs: document Verbemo installation privacy and common releases`.

## Task 9: Проверить действующие приложения и подготовить ветку к review

**Files:** создать `docs/testing/verbemo-independent-releases-acceptance.md`; при необходимости корректировать только выявленные регрессии в owning tasks, с повтором затронутых тестов.

**Interfaces:** отчёт разделяет source/static, macOS runtime, Windows automated/runtime, signing credentials, CI/PR и публичную публикацию. Непроверенное не отмечается completed.

- [ ] **Step 1:** На Mac выполнить script/landing tests, `make verify-localvqe`, `VERBEMO_REQUIRE_LOCALVQE=1 swift test --no-parallel`, `make app`, universal/resource/signature checks и CLI help. `doctor` сначала проверить в `Home.scoped` tests, затем реальной командой с собственным состоянием Verbemo и отключёнными cloud/CLI backends: необходимые defaults настроить через существующий конфиг Verbemo, ключи провайдеров не вызывать. Сохранить команды, revision, результаты и реальные skips.
- [ ] **Step 2:** Открыть `.build/Verbemo.app` через LaunchServices (`open`), проверить EN/RU About/Settings, отдельное состояние, новый CLI symlink/login item и второй запуск при работающей Amanu. Разрешения новой identity проверять честно; Amanu не заменять/не останавливать. Для записи использовать только контролируемый тестовый звук, без захвата текущих встреч; существующие device grants не считать доказательством новых.
- [ ] **Step 3:** Снова проверить доступность Windows-хоста и проекта. На нём выполнить restore/build/Core/Live/native/packaging checks, открыть реальное приложение и проверить UI, coexistence, installation/update/uninstall в изолированном тестовом профиле. Обновление проверить двумя тестовыми версиями через локальный feed; подготовленный стабильный `VERSION` не менять ради теста и публичный latest не использовать для испытания.
- [ ] **Step 4:** Если Windows host или собственные certificates отсутствуют, записать конкретные невыполненные checks и причины; продолжить доступные source/CI проверки. Реальную signed/notarized/macOS update acceptance и Windows подпись/GUI не подменять fixtures, ad-hoc или CI.
- [ ] **Step 5:** Провести финальный review всего diff с требованиями spec и Review Focus; исправить найденное. Перед push/PR подтвердить `ekho` в окружении конкретного `gh` процесса; опубликовать рабочую ветку и draft PR в `ekho/verbemo`, приложить ссылку к чату. PR объясняет результат и реальные ограничения, не содержит заявления о готовом публичном релизе.
- [ ] **Step 6:** Проверить CI обеих платформ на точном PR HEAD и обновить отчёт; commit `test: record Verbemo build and runtime acceptance evidence`. Слияние не требуется для подготовки reviewable результата; состояние ветки/PR и непроверенные gates явно указать.

## Task 10: Удалить только ненужные слитые ветки

**Files:** создать `scripts/cleanup-merged-branches.py`, `Tests/scripts/test_branch_cleanup.py`, `docs/branch-cleanup.md`; snapshots и bundle — в `.git/migration/`, вне tracked files.

**Interfaces:** `inventory --output <json>` фиксирует свежие origin heads, master SHA, PR и worktree references; `apply --inventory <json> --bundle <path> --branches <names...>` удаляет только указанные прошедшие проверки refs. По умолчанию — read-only inventory.

- [ ] **Step 1:** На временных bare/local repos добавить tests `UnmergedBranchIsPreserved`, `ChangedHeadIsPreserved`, `MasterAndWorktreeBranchesArePreserved`, `OpenPRIsPreserved`, `OtherRemotesUntouched`, `BundleRestoresDeletedRefs`. Пример: изменившаяся с inventory ветка отклоняется, даже если новый head тоже слит.
- [ ] **Step 2:** Inventory делает fetch только origin и читает актуальные SHA/PR/worktrees. Кандидат — предок текущего origin/master, ненужный, без открытого PR/активной рабочей копии; master и текущая рабочая ветка исключены. Неслитые ветки только классифицировать по ancestry, без анализа содержимого и новых архивных тегов.
- [ ] **Step 3:** Создать свежий `git bundle create ... --all`; выполнить `git bundle verify` и восстановление refs в пустом тестовом repo. Сохранить before snapshots origin branches и всех тегов; операции с amanu/upstream отсутствуют.
- [ ] **Step 4:** Непосредственно перед удалением повторить master/head/ancestry/PR/worktree проверки. Remote deletion использовать с точным `--force-with-lease=refs/heads/<name>:<checked-SHA>`; изменение master или кандидата требует нового inventory. Локальные refs удалять только при совпадении ожидаемого SHA и отсутствии worktree; при частичном сбое остановиться и сохранить фактический результат.
- [ ] **Step 5:** Проверить after refs: все неслитые branches и теги имеют прежние SHA, каждый удалённый head был предком проверенного master, исторические commits достижимы через сохранённые refs; snapshot/bundle позволяет восстановление. Удалять слитые refs только из явного списка, не менять чужие репозитории.
- [ ] **Step 6:** `python3 -m unittest discover -s Tests/scripts -p 'test_branch_cleanup.py'` проходит; выполнить очистку разрешённых кандидатов и сохранить точные имена/SHA/backup evidence в отчёт. `codex/verbemo-independent-releases` остаётся до собственного слияния. Commit `chore: document safe cleanup of merged Verbemo branches`.

## Самопроверка плана

- Identity/data/coexistence: задачи 2–3; Windows integration/provenance и AGENTS: задача 1.
- Analytics/services и active-source guard: задача 4; подпись/update gates: задачи 5–6.
- Общий commit/version/tag, полный комплект, dry-run/failures/resume/latest: задача 7.
- Сайт, privacy, контакты, package manifests и историческая атрибуция: задача 8.
- Реальные проверки, ограничения host/credentials, CI и reviewable PR: задача 9.
- Bundle/ancestry/SHA/PR/worktree/tags/unmerged protection: задача 10.
- Каждый пункт Review Focus закреплён отрицательными и положительными проверками в owning task. Публичный релиз и сайт остаются вне исполнения этого плана в рамках текущего поручения.

## Первичные источники для реализации

- [Sparkle: публикация и подпись appcast, version/build](https://sparkle-project.org/documentation/publishing/).
- [Velopack: SimpleWebSource](https://docs.velopack.io/integrating/update-sources), [размещение feed и пакетов вместе](https://docs.velopack.io/distributing/overview).
- [GitHub Releases API: create/update release и make_latest](https://docs.github.com/en/rest/releases/releases).

Документация сверена 2026-10-19; точные вызовы сверять также с закреплёнными в репозитории версиями Sparkle/Velopack. Успех unit fixtures не является проверкой подписанного опубликованного обновления.
