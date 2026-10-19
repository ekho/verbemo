# Windows source import, 2026-10-19

The Windows implementation is imported selectively into Verbemo's existing macOS
base. The source is commit `87b3b120278e5d0b10d79ff3355c017d4e52082c` (the preserved
`origin/codex/ready-0.6.3` snapshot), not the moving branch name.
The comparison base is `542f4922c516ed06341c49deca66870c993033f1`. This is not a merge of the
Windows branch: macOS source, tests, diarization, root build/version files and
existing license/copyright material remain in place.

## Exact import scope and object verification

Only the following paths are imported. Directory object IDs are source Git tree
IDs; file object IDs are source Git blob IDs. All 110 imported blobs and
modes were compared with the staged index, and each working-file blob was checked
with `git hash-object` before renaming or product changes.

| Path | Source object ID |
| --- | --- |
| `windows/Amanu.Windows.slnx` | `198db715004c820ea42ff38b3401c5462a834bbb` |
| `windows/Directory.Build.props` | `b6abd2e9e1b98ee0d69386bbe7fa26530364fc9c` |
| `windows/Directory.Packages.props` | `e43cec76d0cbd6d52b1ff38ce5ff14fef40bf113` |
| `windows/src` | `1fd831f8c83b5fd36c25470814a30f6d70853398` |
| `windows/tests` | `3b563113968224d9e09c03de647dc380726d6530` |
| `windows/scripts` | `769d8e721043830488826bcb5dbc7d1107fa0d94` |
| `windows/patches` | `fa07b1f9ead7a6983e1b97f90ea5e8d2921156d2` |
| `windows/Licenses` | `625e5bb053a6bce7faafa57d5503681854664999` |

The source manifest below records every imported path and its exact blob ID.
Existing Windows documentation and packaging manifests outside this scope were
not replaced. No publisher workflow was imported. The root notices add only the
missing Markdig attribution; existing macOS and diarization notices are retained.

```text
100644 blob 198db715004c820ea42ff38b3401c5462a834bbb	windows/Amanu.Windows.slnx
100644 blob b6abd2e9e1b98ee0d69386bbe7fa26530364fc9c	windows/Directory.Build.props
100644 blob e43cec76d0cbd6d52b1ff38ce5ff14fef40bf113	windows/Directory.Packages.props
100644 blob c44a6a26a3484e76a5c76cf1b1afbfe27576d187	windows/Licenses/Markdig.txt
100644 blob ab1e44880cc11aeb629e000c82045eb686f47478	windows/patches/transcribe-cli-init-backends.patch
100644 blob 0f3f0e4617f6ff2e2b6142d5dc808d8bc11c644c	windows/patches/transcribe-cli-unicode-paths.patch
100644 blob be651b77acb8ae90f663c7897fe960ce678a1379	windows/scripts/Build-LiveRuntime.ps1
100644 blob e557507a191e1761c85a58432e7fc21f1b767310	windows/scripts/Build-LocalRuntime.ps1
100644 blob 40344550eb4b6e11fdc9e59a29cc292ba2185baa	windows/scripts/Build-Release.ps1
100644 blob 926f04b6482faff4f4629cfefa9bde9d0094fc58	windows/scripts/Set-ReleaseInstallerName.ps1
100644 blob fc2bfed5de930025833f8dc7d821151fc11fa15d	windows/scripts/Test-NativeCpu.ps1
100644 blob 71d2e1d7225d4e336098d5e7393365ac6762f4c9	windows/scripts/Test-ReleaseSignatures.ps1
100644 blob af82ecbed4a85a84247749c3604ad7d1d23a3b84	windows/src/Amanu.App/Access.cs
100644 blob 7860576e452cd8a47f875a7d7d7809ff2dd24a0d	windows/src/Amanu.App/AdvancedSettings.cs
100644 blob cfa813ffb9ea385e54ca304bebbff979598bbc63	windows/src/Amanu.App/Amanu.App.csproj
100644 blob 168ab97e39f8ffffe33ae450fd04b177ec72702a	windows/src/Amanu.App/AmanuRuntime.cs
100644 blob 26fda39e3c42b47569bef86c8c782c1c12f28a12	windows/src/Amanu.App/AnalyticsService.cs
100644 blob 8202564baac50852e2f379f22d7993d170304672	windows/src/Amanu.App/App.xaml
100644 blob 7d554f1eaa6629dab760172d781850fe6b941d2c	windows/src/Amanu.App/App.xaml.cs
100644 blob fbf8a1219832808d8314090d9b9d107c7953fdc6	windows/src/Amanu.App/Assets/Amanu.ico
100644 blob b338ba0b35efc87f7709768274adf15833864f65	windows/src/Amanu.App/AudioPreprocessor.cs
100644 blob cf1efaf0dfb9339a7c8acf90618ffe25ab13b757	windows/src/Amanu.App/CallActivityMonitor.cs
100644 blob 31a349967f74a56f8c5766f2451c1efc1ea83f8a	windows/src/Amanu.App/ClickControls.cs
100644 blob 0f14a7d7ab9aea188541cc79c0275efcbc6656c8	windows/src/Amanu.App/CommandLineToolLocator.cs
100644 blob bef293ea8f598980c7767c21266091156818806c	windows/src/Amanu.App/LanguageServices.cs
100644 blob 457729c95fe119d39804ba494100647efbe4133d	windows/src/Amanu.App/LiveAudioResampler.cs
100644 blob 234c9e9855d338e3a0388a924a89247c218dcf07	windows/src/Amanu.App/LiveSpeechStream.cs
100644 blob 176f6629b736dd8f9d8393df1219bbc7a4b1ef07	windows/src/Amanu.App/LiveSpeechWorker.cs
100644 blob 509f8dd5c31d2a2d6ae17103e49f292e2df82d6f	windows/src/Amanu.App/LiveTranscriptionCoordinator.cs
100644 blob 580a42e0493c9736fb2a50467160877be6fffd37	windows/src/Amanu.App/MarkdownPreview.cs
100644 blob 4fceb9351445a855511944a30856a99d196f0ced	windows/src/Amanu.App/ModelManager.cs
100644 blob 0c8511dfe76006f1a2e1414544baf858fc7cc08b	windows/src/Amanu.App/ProcessingCoordinator.cs
100644 blob 8780abedf575575122ced4f14853372b4ed1ba58	windows/src/Amanu.App/Properties/AssemblyInfo.cs
100644 blob 88fea9c1c98b98c2ee0ce8272387d92d91b5a304	windows/src/Amanu.App/RecordingsWindow.cs
100644 blob 23648fe53c68d13cc561c8b8878aeaeb27ca7222	windows/src/Amanu.App/SecretStore.cs
100644 blob f0c41414b83e82b19efb568270919cdd71ea4502	windows/src/Amanu.App/SettingsWindow.cs
100644 blob 24d85acaae0b0c4541d86523a6fe90ab8deb1166	windows/src/Amanu.App/SetupForm.cs
100644 blob 3a064cd279bcc617f47b1cc2edaec56218a0d861	windows/src/Amanu.App/StartupRegistration.cs
100644 blob 36b433efc1ff6401ae5b71d2fca3c343bf7ac7b0	windows/src/Amanu.App/StatusWindow.cs
100644 blob 403be2122322c81db9c32c982d493bda911ff365	windows/src/Amanu.App/TranscriptionServices.cs
100644 blob fee9f79ef235de06ff5c1823ecf6af9f7cb00572	windows/src/Amanu.App/TrayIconService.cs
100644 blob 3ac44c90fd5c01efc158a3acfb070acea77d0b7f	windows/src/Amanu.App/Ui.cs
100644 blob 0ffcb12327b7e445c9f977b46f8d219170d90cd1	windows/src/Amanu.App/UpdateService.cs
100644 blob 21d76c545f7e8848fc0e1cc336911675230a0762	windows/src/Amanu.App/WindowsAudioCapture.cs
100644 blob a40b44e5938ae07363208345f74dc93916f9d825	windows/src/Amanu.App/app.manifest
100644 blob eceb88f53b1c550d35e8e568381bcbe1421b372d	windows/src/Amanu.Core/Amanu.Core.csproj
100644 blob 71599ca5721f5e06734d02d3dd21c842862c83af	windows/src/Amanu.Core/Analytics/AnalyticsPolicy.cs
100644 blob 694db4fba8e2d25250a420c4052239a2a475a2c4	windows/src/Amanu.Core/Configuration/AppSettings.cs
100644 blob 4b951d71248f929fbba3b4547cfaa1f0ad086e44	windows/src/Amanu.Core/Configuration/AppSettingsStore.cs
100644 blob 3b0f331955d3c48fa3d180aac94952d2eb4f9b78	windows/src/Amanu.Core/Configuration/SettingsDocument.cs
100644 blob cee6520932566acd177a548959bc977790c4257e	windows/src/Amanu.Core/Configuration/SettingsSchema.cs
100644 blob 3c11f30ed59a14773ecb21cedb0f88383a6de8c0	windows/src/Amanu.Core/Configuration/SetupChoice.cs
100644 blob 63f3d4d73cb4a65aa7dd98893d659a7a8088c073	windows/src/Amanu.Core/Localization/Localized.cs
100644 blob 7febcdbb0af292705c485cfd5d200aa9778411a7	windows/src/Amanu.Core/Processing/CliArguments.cs
100644 blob 695e0ba5192a13e93afe99d4635f489cea337d5b	windows/src/Amanu.Core/Processing/CpuTranscriptionGate.cs
100644 blob 88b67505d14d0ebfe629e0211e09beee1472e8b3	windows/src/Amanu.Core/Processing/LocalModels.cs
100644 blob ebfe3cae2c97e70fdb1218cf5ce98e3a28e3691e	windows/src/Amanu.Core/Processing/MeetingEgress.cs
100644 blob 80e46ad2bc882d731a25d0b2a0b689d37a80d7bc	windows/src/Amanu.Core/Processing/MeetingLanguages.cs
100644 blob c935326caf6b095c45744bc324213ac23d845ccf	windows/src/Amanu.Core/Processing/ProcessingFailure.cs
100644 blob 01874cef7832b6166f0c2bb4c9392e6a10e6de0d	windows/src/Amanu.Core/Processing/ProcessingPolicy.cs
100644 blob edf0e534e95ae30cfc99a4abe870f94521973be4	windows/src/Amanu.Core/Processing/SessionInventory.cs
100644 blob b9393fe51cebfa3011e921ef132f3be62d8c0564	windows/src/Amanu.Core/Processing/SpeakerLabels.cs
100644 blob 8fb9b62db2b13d2f008f5f4bfb3a627b16983827	windows/src/Amanu.Core/Processing/SummaryTemplate.cs
100644 blob e8d656b281e4482fcd9cb451b3705018d9a2852f	windows/src/Amanu.Core/Processing/TranscriptDocument.cs
100644 blob f27dd3e0e5a614e9c4dab22aceab95a6f057e8f3	windows/src/Amanu.Core/Processing/TranscriptVersions.cs
100644 blob a81bd2dcc9db036661ab8afbe4b28772bd127cab	windows/src/Amanu.Core/Recording/AutoRecordPolicy.cs
100644 blob c03a2aa402c2a3a80a0e6f63c0dadde742ebccb1	windows/src/Amanu.Core/Recording/CallProcessMatcher.cs
100644 blob 0c56d2599c714d02cd6c331b1085f47b05a4054a	windows/src/Amanu.Core/Recording/LiveAudioQueue.cs
100644 blob 2196c367364592c5424a6ced1e39e0b543550fa3	windows/src/Amanu.Core/Recording/RecordingCoordinator.cs
100644 blob 98ad1c0fb8b4a1d0f86964c2d5cefab1841e4298	windows/src/Amanu.Core/Recording/RecordingDisplay.cs
100644 blob 508668af4d7a749a264db31562eafe1a1f9d5858	windows/src/Amanu.Core/Sessions/SessionStore.cs
100644 blob 7817a4becf983a074535dc54a4f2f3a662125856	windows/tests/Amanu.Core.Tests/Amanu.Core.Tests.csproj
100644 blob b5e3accac8027826af522c4e9e25609feaca3091	windows/tests/Amanu.Core.Tests/AnalyticsPolicyTests.cs
100644 blob 08fb9bceb8a356d606dd48ffe7ab96e62fc93571	windows/tests/Amanu.Core.Tests/AppSettingsStoreTests.cs
100644 blob a9261c26028ad5ea034c198dd05730d7359340fe	windows/tests/Amanu.Core.Tests/AppSettingsTests.cs
100644 blob 4265e8ebd54cadd42de43fdad09fecd5961f45c7	windows/tests/Amanu.Core.Tests/AutoRecordPolicyTests.cs
100644 blob b324d21a15e297afb9d12c325610d5da959bc2c7	windows/tests/Amanu.Core.Tests/CallProcessMatcherTests.cs
100644 blob f86ff6441717cd2ef6ecd557e42aec83d5389623	windows/tests/Amanu.Core.Tests/CommandLineToolLocatorTests.cs
100644 blob 46ce6506dd6dcfdda85d86bf3d579dadfe612dd7	windows/tests/Amanu.Core.Tests/CpuTranscriptionGateTests.cs
100644 blob 727e5eb7b6736a4564aebd65425a806fc06948b0	windows/tests/Amanu.Core.Tests/EgressTests.cs
100644 blob c802f4480b198aad9bb8709a616c0891f99086c9	windows/tests/Amanu.Core.Tests/GlobalUsings.cs
100644 blob eb55cb5fb2e896d587af0ce70e5efd84c9413d3f	windows/tests/Amanu.Core.Tests/ModelManagerTests.cs
100644 blob c81865d0211fda8fa56fba01c5721bf0d3748974	windows/tests/Amanu.Core.Tests/ProcessingContractTests.cs
100644 blob b6fca3eba90e40e769cc0b7ed7c78cc483702c9b	windows/tests/Amanu.Core.Tests/ProcessingFailureTests.cs
100644 blob ce410700b41f29131f6044a246e04e0a7afa0f3a	windows/tests/Amanu.Core.Tests/RecordingCoordinatorTests.cs
100644 blob 4f1bab585d0ca36fd4049c042a605647ed44ac31	windows/tests/Amanu.Core.Tests/RecordingDisplayTests.cs
100644 blob ee44bdcc8fe7ddbfa6d913916f81d2cfcdf6b528	windows/tests/Amanu.Core.Tests/SessionInventoryTests.cs
100644 blob 7f14af3805f2735ffc33847109acdc2d084198b3	windows/tests/Amanu.Core.Tests/SessionStoreTests.cs
100644 blob d234bbcd5295d74de6d3dcf6afbc2a25047b37d9	windows/tests/Amanu.Core.Tests/SettingsSchemaTests.cs
100644 blob 3677e716457089331bf0bd0e09380304f53c4444	windows/tests/Amanu.Core.Tests/SetupChoiceTests.cs
100644 blob f79be847ea1967365ea562a53ef7bff9b23afede	windows/tests/Amanu.Core.Tests/SummaryProviderTests.cs
100644 blob 8dedbc6e7a56ba15cc3ccb6ca4611886e607950d	windows/tests/Amanu.Core.Tests/TemporaryDirectory.cs
100644 blob 5309e84b89459b2ea299b4b2896d04955a3e555d	windows/tests/Amanu.Core.Tests/TranscriptVersionsTests.cs
100644 blob c674c9ef3c490971a95c197bd72acc75aacc2df1	windows/tests/Amanu.Live.Harness/Amanu.Live.Harness.csproj
100644 blob 721d9f65749080104a79b5515edc56d7bea452a2	windows/tests/Amanu.Live.Harness/CaptureValidation.cs
100644 blob 7aa2851e1c08512a6931c2445d774effabf378f6	windows/tests/Amanu.Live.Harness/Program.cs
100644 blob cc166cb8e83623a5d80c2d269bcd2305b94afc89	windows/tests/Amanu.Live.Tests/Amanu.Live.Tests.csproj
100644 blob 5ed9b672a76242478ce8ae7cc29f636e662bbc64	windows/tests/Amanu.Live.Tests/AssemblyAiRequestTests.cs
100644 blob 7d0347f0a6e73e49bac7720fbfa9da40356b357c	windows/tests/Amanu.Live.Tests/ClickCheckBoxThemeTests.cs
100644 blob 74ee4e05d75a89eb19dfa34b208db64eb12bb52f	windows/tests/Amanu.Live.Tests/LiveAudioTests.cs
100644 blob 2419b5d9172d847c89a2716b4a73e00608e5345d	windows/tests/Amanu.Live.Tests/LivePreloadTests.cs
100644 blob 695b9737989421fc6038c993cb483dd9cdecc07c	windows/tests/Amanu.Live.Tests/LongAudioChunkTests.cs
100644 blob 84da28bfe0ae9469374edf7afcc3d9e2be908643	windows/tests/Amanu.Live.Tests/MarkdownPreviewTests.cs
100644 blob 08f71585de2c3fe1270b9bd1afb8ca22bcc68d73	windows/tests/Amanu.Live.Tests/ProcessingHookTests.cs
100644 blob a9967cff069897c8825ccac5b79db6722ec66a7c	windows/tests/Amanu.Live.Tests/RecordingActionsTests.cs
100644 blob 991aedcd88ffc30bc123903758385212bd6389eb	windows/tests/Amanu.Live.Tests/RecordingQueueTests.cs
100644 blob 861b50d69c7516880b1149bb2da19a3600ccd9e1	windows/tests/Amanu.Live.Tests/RetranscriptionTests.cs
100644 blob 9897f0357da37f06e564c85901fb01334453914f	windows/tests/Test-NativeUnicodePaths.ps1
100644 blob 20565788b7b5e049c361fd6f7c44390cede9ca90	windows/tests/Test-ReleaseInstallerName.ps1
100644 blob 5254bcb6e02eff626763b6d8813469eea57aeb80	windows/tests/test_workflow_safety.py
```

## Differences between the bases

Exact output of `git diff --name-status 542f4922c516ed06341c49deca66870c993033f1 87b3b120278e5d0b10d79ff3355c017d4e52082c`:

```text
M	.gitattributes
M	.github/workflows/ci.yml
D	.github/workflows/readme-downloads.yml
M	.github/workflows/windows-beta.yml
A	.github/workflows/windows-package-metadata.yml
M	.gitignore
M	AGENTS.md
M	Makefile
M	PRIVACY.md
M	README.md
D	Resources/Licenses/LS-EEND-AMI-LICENSE
D	Resources/Licenses/NeMo-Speech.cpp-LICENSE
D	Resources/Licenses/NeMo-Speech.cpp-NOTICE
D	Resources/Licenses/NeMo-Speech.cpp-THIRD_PARTY_NOTICES.md
D	Resources/Licenses/NeMo-Speech.cpp-ggml-LICENSE
D	Resources/Licenses/NeMo-Speech.cpp-sentencepiece-LICENSE
D	Resources/Licenses/NeMo-Speech.cpp-sentencepiece-absl-LICENSE
D	Resources/Licenses/NeMo-Speech.cpp-sentencepiece-darts-clone-LICENSE
D	Resources/Licenses/NeMo-Speech.cpp-sentencepiece-protobuf-lite-LICENSE
D	Resources/Licenses/Nemotron-3-Diarization-OpenMDW-1.1.html
M	Sources/amanu/Amanu.swift
M	Sources/amanu/App/MainMenu.swift
M	Sources/amanu/Audio/AudioChannelExtractor.swift
D	Sources/amanu/Audio/DiarizationAudioSource.swift
M	Sources/amanu/Audio/TrackCompressor.swift
M	Sources/amanu/Config.swift
M	Sources/amanu/Doctor.swift
M	Sources/amanu/Sessions/PostProcessor.swift
M	Sources/amanu/Sessions/SessionCommands.swift
M	Sources/amanu/Sessions/SessionInventory.swift
M	Sources/amanu/Sessions/SpeakerNamer.swift
M	Sources/amanu/Sessions/SpeakerNames.swift
M	Sources/amanu/Sessions/TranscriptVersions.swift
M	Sources/amanu/Settings/ConfigKeys.swift
M	Sources/amanu/Settings/ConfigProblem.swift
M	Sources/amanu/Settings/SettingsSchema.swift
M	Sources/amanu/Subprocess.swift
D	Sources/amanu/Transcription/DiarizationAlignment.swift
D	Sources/amanu/Transcription/DiarizationArtifacts.swift
D	Sources/amanu/Transcription/DiarizationEngine.swift
D	Sources/amanu/Transcription/DiarizationModel.swift
D	Sources/amanu/Transcription/DiarizationModelStore.swift
D	Sources/amanu/Transcription/DiarizationState.swift
D	Sources/amanu/Transcription/DiarizationTypes.swift
M	Sources/amanu/Transcription/EngineResolver.swift
D	Sources/amanu/Transcription/LocalDiarizationPipeline.swift
M	Sources/amanu/Transcription/ModelStorage.swift
D	Sources/amanu/Transcription/NemotronDiarizationRunner.swift
M	Sources/amanu/Transcription/ParakeetEngine.swift
M	Sources/amanu/Transcription/Transcript.swift
M	Sources/amanu/Transcription/TranscriptionCoordinator.swift
M	Sources/amanu/Transcription/TranscriptionEngine.swift
M	Sources/amanu/Transcription/TranscriptionInputs.swift
M	Sources/amanu/Transcription/TranscriptionScratch.swift
M	Sources/amanu/Transcription/WhisperEngine.swift
M	Sources/amanu/UI/ChoiceCard.swift
D	Sources/amanu/UI/ModelDownloadProgress.swift
M	Sources/amanu/UI/RecordingsWindow.swift
M	Sources/amanu/UI/SettingsWindow.swift
M	Sources/amanu/UI/SetupForm.swift
M	THIRD-PARTY-NOTICES.md
M	Tests/amanuTests/CredentialsTests.swift
M	Tests/amanuTests/DoctorSummaryTests.swift
M	Tests/amanuTests/InterfaceLanguageTests.swift
M	Tests/amanuTests/RecordingsWindowTests.swift
M	Tests/amanuTests/SettingsSchemaTests.swift
M	Tests/amanuTests/SetupFormBehaviourTests.swift
M	Tests/amanuTests/SetupTests.swift
M	Tests/amanuTests/SubprocessTests.swift
D	Tests/amanuTests/TextEditingShortcutTests.swift
D	Tests/amanuTests/Transcription/DiarizationAlignmentTests.swift
D	Tests/amanuTests/Transcription/DiarizationAudioSourceTests.swift
D	Tests/amanuTests/Transcription/DiarizationEvaluation.swift
D	Tests/amanuTests/Transcription/DiarizationEvaluationTests.swift
D	Tests/amanuTests/Transcription/DiarizationLifecycleTests.swift
D	Tests/amanuTests/Transcription/DiarizationModelTests.swift
M	Tests/amanuTests/Transcription/EngineResolutionTests.swift
D	Tests/amanuTests/Transcription/LocalDiarizationAudioRegressionTests.swift
D	Tests/amanuTests/Transcription/LocalDiarizationPipelineTests.swift
M	Tests/amanuTests/Transcription/ModelStorageTests.swift
D	Tests/amanuTests/Transcription/NemotronDiarizationRunnerTests.swift
D	Tests/amanuTests/Transcription/ParakeetWordTimingTests.swift
M	Tests/amanuTests/Transcription/WhisperEngineTests.swift
D	Tests/amanuTests/Transcription/WhisperRealWordTimingTests.swift
D	Tests/amanuTests/Transcription/WhisperWordTimingTests.swift
M	Tests/amanuTests/WindowShots.swift
D	Tests/scripts/test_local_signing.py
D	Tests/scripts/test_readme_downloads.py
D	Tests/scripts/test_verify_nemotron_diar.py
M	VERSION
M	docs/handoffs/2026-10-02-ready-release-macos.md
M	docs/pitfalls.md
M	docs/release-notes-v0.6.3.md
D	docs/release-notes-v0.6.4.md
D	docs/release-notes-v0.6.5.md
M	docs/releasing.md
A	docs/specs/2026-09-20-windows-app-design.md
D	docs/superpowers/plans/2026-10-10-diarization-model-choice.md
D	docs/superpowers/specs/2026-10-19-verbemo-independent-releases-design.md
A	docs/testing/assemblyai-code-switching-2026-10-01.md
D	docs/testing/local-diarization-evaluation.md
D	docs/testing/local-diarization-validation.md
D	docs/testing/prepare-ami-diarization-fixture.py
A	docs/testing/windows-0.6.0-qa-2026-10-01.md
A	docs/testing/windows-beta17-qa-2026-09-30.md
A	docs/testing/windows-hardware-checklist.md
A	docs/windows-handoff-2026-09-29.md
A	docs/windows-testing-handoff-2026-09-29.md
A	docs/windows-unicode-paths-2026-10-06.md
M	landing/appcast.xml
M	landing/deploy/nginx/amanu.conf
M	landing/index.html
M	landing/ru/index.html
M	landing/tests/browser.cjs
M	landing/tests/check.py
D	scripts/build-nemotron-diar.sh
M	scripts/release.sh
D	scripts/update-readme-downloads.py
D	scripts/verify-nemotron-diar.py
A	windows/Amanu.Windows.slnx
A	windows/BETA.md
A	windows/Directory.Build.props
A	windows/Directory.Packages.props
A	windows/LIVE_TRANSCRIPTION.md
A	windows/Licenses/Markdig.txt
A	windows/RELEASE_NOTES.md
A	windows/packaging/winget/0.6.5/FandsSoftware.Amanu.installer.yaml
A	windows/packaging/winget/0.6.5/FandsSoftware.Amanu.locale.en-US.yaml
A	windows/packaging/winget/0.6.5/FandsSoftware.Amanu.yaml
A	windows/patches/transcribe-cli-init-backends.patch
A	windows/patches/transcribe-cli-unicode-paths.patch
A	windows/scripts/Build-LiveRuntime.ps1
A	windows/scripts/Build-LocalRuntime.ps1
A	windows/scripts/Build-Release.ps1
A	windows/scripts/Set-ReleaseInstallerName.ps1
A	windows/scripts/Test-NativeCpu.ps1
A	windows/scripts/Test-ReleaseSignatures.ps1
A	windows/src/Amanu.App/Access.cs
A	windows/src/Amanu.App/AdvancedSettings.cs
A	windows/src/Amanu.App/Amanu.App.csproj
A	windows/src/Amanu.App/AmanuRuntime.cs
A	windows/src/Amanu.App/AnalyticsService.cs
A	windows/src/Amanu.App/App.xaml
A	windows/src/Amanu.App/App.xaml.cs
A	windows/src/Amanu.App/Assets/Amanu.ico
A	windows/src/Amanu.App/AudioPreprocessor.cs
A	windows/src/Amanu.App/CallActivityMonitor.cs
A	windows/src/Amanu.App/ClickControls.cs
A	windows/src/Amanu.App/CommandLineToolLocator.cs
A	windows/src/Amanu.App/LanguageServices.cs
A	windows/src/Amanu.App/LiveAudioResampler.cs
A	windows/src/Amanu.App/LiveSpeechStream.cs
A	windows/src/Amanu.App/LiveSpeechWorker.cs
A	windows/src/Amanu.App/LiveTranscriptionCoordinator.cs
A	windows/src/Amanu.App/MarkdownPreview.cs
A	windows/src/Amanu.App/ModelManager.cs
A	windows/src/Amanu.App/ProcessingCoordinator.cs
A	windows/src/Amanu.App/Properties/AssemblyInfo.cs
A	windows/src/Amanu.App/RecordingsWindow.cs
A	windows/src/Amanu.App/SecretStore.cs
A	windows/src/Amanu.App/SettingsWindow.cs
A	windows/src/Amanu.App/SetupForm.cs
A	windows/src/Amanu.App/StartupRegistration.cs
A	windows/src/Amanu.App/StatusWindow.cs
A	windows/src/Amanu.App/TranscriptionServices.cs
A	windows/src/Amanu.App/TrayIconService.cs
A	windows/src/Amanu.App/Ui.cs
A	windows/src/Amanu.App/UpdateService.cs
A	windows/src/Amanu.App/WindowsAudioCapture.cs
A	windows/src/Amanu.App/app.manifest
A	windows/src/Amanu.Core/Amanu.Core.csproj
A	windows/src/Amanu.Core/Analytics/AnalyticsPolicy.cs
A	windows/src/Amanu.Core/Configuration/AppSettings.cs
A	windows/src/Amanu.Core/Configuration/AppSettingsStore.cs
A	windows/src/Amanu.Core/Configuration/SettingsDocument.cs
A	windows/src/Amanu.Core/Configuration/SettingsSchema.cs
A	windows/src/Amanu.Core/Configuration/SetupChoice.cs
A	windows/src/Amanu.Core/Localization/Localized.cs
A	windows/src/Amanu.Core/Processing/CliArguments.cs
A	windows/src/Amanu.Core/Processing/CpuTranscriptionGate.cs
A	windows/src/Amanu.Core/Processing/LocalModels.cs
A	windows/src/Amanu.Core/Processing/MeetingEgress.cs
A	windows/src/Amanu.Core/Processing/MeetingLanguages.cs
A	windows/src/Amanu.Core/Processing/ProcessingFailure.cs
A	windows/src/Amanu.Core/Processing/ProcessingPolicy.cs
A	windows/src/Amanu.Core/Processing/SessionInventory.cs
A	windows/src/Amanu.Core/Processing/SpeakerLabels.cs
A	windows/src/Amanu.Core/Processing/SummaryTemplate.cs
A	windows/src/Amanu.Core/Processing/TranscriptDocument.cs
A	windows/src/Amanu.Core/Processing/TranscriptVersions.cs
A	windows/src/Amanu.Core/Recording/AutoRecordPolicy.cs
A	windows/src/Amanu.Core/Recording/CallProcessMatcher.cs
A	windows/src/Amanu.Core/Recording/LiveAudioQueue.cs
A	windows/src/Amanu.Core/Recording/RecordingCoordinator.cs
A	windows/src/Amanu.Core/Recording/RecordingDisplay.cs
A	windows/src/Amanu.Core/Sessions/SessionStore.cs
A	windows/tests/Amanu.Core.Tests/Amanu.Core.Tests.csproj
A	windows/tests/Amanu.Core.Tests/AnalyticsPolicyTests.cs
A	windows/tests/Amanu.Core.Tests/AppSettingsStoreTests.cs
A	windows/tests/Amanu.Core.Tests/AppSettingsTests.cs
A	windows/tests/Amanu.Core.Tests/AutoRecordPolicyTests.cs
A	windows/tests/Amanu.Core.Tests/CallProcessMatcherTests.cs
A	windows/tests/Amanu.Core.Tests/CommandLineToolLocatorTests.cs
A	windows/tests/Amanu.Core.Tests/CpuTranscriptionGateTests.cs
A	windows/tests/Amanu.Core.Tests/EgressTests.cs
A	windows/tests/Amanu.Core.Tests/GlobalUsings.cs
A	windows/tests/Amanu.Core.Tests/ModelManagerTests.cs
A	windows/tests/Amanu.Core.Tests/ProcessingContractTests.cs
A	windows/tests/Amanu.Core.Tests/ProcessingFailureTests.cs
A	windows/tests/Amanu.Core.Tests/RecordingCoordinatorTests.cs
A	windows/tests/Amanu.Core.Tests/RecordingDisplayTests.cs
A	windows/tests/Amanu.Core.Tests/SessionInventoryTests.cs
A	windows/tests/Amanu.Core.Tests/SessionStoreTests.cs
A	windows/tests/Amanu.Core.Tests/SettingsSchemaTests.cs
A	windows/tests/Amanu.Core.Tests/SetupChoiceTests.cs
A	windows/tests/Amanu.Core.Tests/SummaryProviderTests.cs
A	windows/tests/Amanu.Core.Tests/TemporaryDirectory.cs
A	windows/tests/Amanu.Core.Tests/TranscriptVersionsTests.cs
A	windows/tests/Amanu.Live.Harness/Amanu.Live.Harness.csproj
A	windows/tests/Amanu.Live.Harness/CaptureValidation.cs
A	windows/tests/Amanu.Live.Harness/Program.cs
A	windows/tests/Amanu.Live.Tests/Amanu.Live.Tests.csproj
A	windows/tests/Amanu.Live.Tests/AssemblyAiRequestTests.cs
A	windows/tests/Amanu.Live.Tests/ClickCheckBoxThemeTests.cs
A	windows/tests/Amanu.Live.Tests/LiveAudioTests.cs
A	windows/tests/Amanu.Live.Tests/LivePreloadTests.cs
A	windows/tests/Amanu.Live.Tests/LongAudioChunkTests.cs
A	windows/tests/Amanu.Live.Tests/MarkdownPreviewTests.cs
A	windows/tests/Amanu.Live.Tests/ProcessingHookTests.cs
A	windows/tests/Amanu.Live.Tests/RecordingActionsTests.cs
A	windows/tests/Amanu.Live.Tests/RecordingQueueTests.cs
A	windows/tests/Amanu.Live.Tests/RetranscriptionTests.cs
A	windows/tests/Test-NativeUnicodePaths.ps1
A	windows/tests/Test-ReleaseInstallerName.ps1
A	windows/tests/test_workflow_safety.py
```

## Verification and remaining acceptance

- Source/index blob and mode comparison: passed for all 110 files.
- Source/working-file blob comparison: passed for all 110 files.
- Source/index tree or blob IDs: passed for all eight import-scope paths.
- Authored-file whitespace check: passed. The raw staged `git diff --cached
  --check` retains eight inherited warnings: seven patch context blank lines in
  `windows/patches/transcribe-cli-unicode-paths.patch` (7, 24, 33, 36, 38, 76, 98)
  and an intentional two-space Markdown hard-break fixture in
  `windows/tests/Amanu.Live.Tests/MarkdownPreviewTests.cs` (53). These bytes remain
  unchanged to preserve the exact source import and fixture/patch semantics.
- `git diff --exit-code 542f492 -- Sources Tests/amanuTests Package.swift Makefile VERSION`: passed.
- No connected Windows host was accessible to this task; only the local Mac was
  available. Windows acceptance remains open. No Windows build, tests, GUI,
  installer or native runtime validation is claimed by this source import.
- On an accessible Windows host, run `dotnet restore windows/Amanu.Windows.slnx`,
  `dotnet build windows/Amanu.Windows.slnx -c Release --no-restore`,
  `dotnet test windows/tests/Amanu.Core.Tests/Amanu.Core.Tests.csproj -c Release --no-restore`,
  `dotnet test windows/tests/Amanu.Live.Tests/Amanu.Live.Tests.csproj -c Release --no-restore`,
  and `windows/tests/Test-ReleaseInstallerName.ps1` before subsequent renaming.

The imported code deliberately retains Amanu names and behavior for the next
implementation stages. It is not a prepared Verbemo release and must not be
published using the inherited release scripts or destinations.
