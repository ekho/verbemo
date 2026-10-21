## [0.3.1](https://github.com/ekho/verbemo/compare/verbemo-v0.3.0...verbemo-v0.3.1) (2026-10-21)

### Bug Fixes

* **macos:** finish unified workspace UX ([c273958](https://github.com/ekho/verbemo/commit/c273958b1d215bb15304b2a7648f6679048bb254)), closes [#24](https://github.com/ekho/verbemo/issues/24)
* **macos:** finish unified workspace UX ([#25](https://github.com/ekho/verbemo/issues/25)) ([c3a7743](https://github.com/ekho/verbemo/commit/c3a7743599230ef3dc8ea655f62202820e23b854)), closes [#24](https://github.com/ekho/verbemo/issues/24)

## [0.3.0](https://github.com/ekho/verbemo/compare/verbemo-v0.2.3...verbemo-v0.3.0) (2026-10-20)

### Features

* add Windows meeting cards and unified guarded actions ([7473682](https://github.com/ekho/verbemo/commit/7473682bcfbf0be10eb0cfd2f4d7cb3a0861428a))
* finish native recording states and preserve settings edits ([df482cd](https://github.com/ekho/verbemo/commit/df482cdddd0d5609466a1354b19ed8cf9c9cd08c))
* guard meeting actions and regenerate summaries safely ([d1041b3](https://github.com/ekho/verbemo/commit/d1041b3bdf8a9785a2f201466b11fc338047248b)), closes [#21](https://github.com/ekho/verbemo/issues/21)
* guard Windows meeting actions and regenerate summaries safely ([2ef45c5](https://github.com/ekho/verbemo/commit/2ef45c50c9ca336461a1571223227fa9e84dc00f))
* host meetings and settings in one macOS window ([db5672c](https://github.com/ekho/verbemo/commit/db5672cbf571e43c06f8b346ad54974f3420ed47)), closes [#21](https://github.com/ekho/verbemo/issues/21)
* keep recording controls and live text in the shared workspace ([46169ef](https://github.com/ekho/verbemo/commit/46169ef12f0e86844e67d7e16d92f6aecbeb672c)), closes [#21](https://github.com/ekho/verbemo/issues/21)
* manage Windows models and map saved calendar participants ([b485451](https://github.com/ekho/verbemo/commit/b48545162490554ccfe546ddcbad04df4869dbcf))
* organize macOS settings by task and support app themes ([1c7c5c0](https://github.com/ekho/verbemo/commit/1c7c5c02b96e510650e5f90fd3214daaef25d8a3))
* partition Windows settings and persist app theme and live titles ([b5dc3da](https://github.com/ekho/verbemo/commit/b5dc3dadd6402e6715771415da9bef750f90a648))
* preserve calendar context and map participants per transcript version ([848bf90](https://github.com/ekho/verbemo/commit/848bf90d8397c67ed9a21a179c54e0e067adcfec))
* route Windows surfaces through one workspace ([b20bf9f](https://github.com/ekho/verbemo/commit/b20bf9f63f39c6f98a837a123b18e0e904a118fe))
* share model downloads and resume the saved speaker request ([aa5c3d4](https://github.com/ekho/verbemo/commit/aa5c3d4690da42cac65a057614deff8fdc48fcd0))
* unify meeting library actions and recoverable deletion ([c51b84b](https://github.com/ekho/verbemo/commit/c51b84b73a3522c374749ea0572164d63da0fa03))
* unify Verbemo workspace around the approved UX ([2b05aa0](https://github.com/ekho/verbemo/commit/2b05aa0403abee3f891f8d03c79603ef1a3a7f0a))

### Bug Fixes

* align Windows meeting controls and shared download states ([ccc5a94](https://github.com/ekho/verbemo/commit/ccc5a94e4feca41205d6ddcb1a977eef70dfa5f6))
* close native interface review regressions ([6b711b2](https://github.com/ekho/verbemo/commit/6b711b26cd91d727d4c22a2524d49611b6b345ae))
* **windows:** await hook startup before cleanup and restore releases ([1988fd2](https://github.com/ekho/verbemo/commit/1988fd29db8147cca1599839a1611f1d427ff729)), closes [#19](https://github.com/ekho/verbemo/issues/19)
* **windows:** reject null transcript entries before summary generation ([0c0f756](https://github.com/ekho/verbemo/commit/0c0f756475a3f0dd5570c5125da6ba06cd4753e1))

## [0.2.3](https://github.com/ekho/verbemo/compare/verbemo-v0.2.2...verbemo-v0.2.3) (2026-10-20)

### Bug Fixes

* **windows:** fix hook cleanup and restore release builds ([82d6f58](https://github.com/ekho/verbemo/commit/82d6f58b7f8990101199ae5bf1bd8c8d4f3ae37c)), closes [#19](https://github.com/ekho/verbemo/issues/19)

## [0.2.2](https://github.com/ekho/verbemo/compare/verbemo-v0.2.1...verbemo-v0.2.2) (2026-10-20)

### Bug Fixes

* **ci:** temporarily pause Windows builds ([5c020b7](https://github.com/ekho/verbemo/commit/5c020b725f4f507aca76b482fc157f6b484cc6d6)), closes [#19](https://github.com/ekho/verbemo/issues/19) [#19](https://github.com/ekho/verbemo/issues/19)

## [0.2.1](https://github.com/ekho/verbemo/compare/verbemo-v0.2.0...verbemo-v0.2.1) (2026-10-20)

### Bug Fixes

* **release:** accept GitHub Actions repository metadata ([54c58d5](https://github.com/ekho/verbemo/commit/54c58d50841cd93995efa53287cddfb84ebc78f7))

## [0.2.0](https://github.com/ekho/verbemo/compare/1e8ed82d9a83cbd5686c145c4ca61d4f7ee9a701...verbemo-v0.2.0) (2026-10-20)

### Features

* **branding:** adopt the selected wave icon ([02fded1](https://github.com/ekho/verbemo/commit/02fded12e8d867a852c43f598bb2e6da8d83dbd2))
* **ci:** automate SemVer releases after merges ([8fd4ce9](https://github.com/ekho/verbemo/commit/8fd4ce9ffcf35287f00ee3571e311af5fbf270c4))
* **macos:** copy selected summaries and fix nested lists ([3d7e887](https://github.com/ekho/verbemo/commit/3d7e8874c25b572f33bad25a490fdc89ed564987))
* **macos:** copy summaries and preserve nested lists ([#13](https://github.com/ekho/verbemo/issues/13)) ([bdae823](https://github.com/ekho/verbemo/commit/bdae823301490d36c3301995323b6d4fa634c70b))
* **release:** publish unsigned previews without certificates ([6f7672b](https://github.com/ekho/verbemo/commit/6f7672b7e59d8934651c69da640f748620bc219f))

### Bug Fixes

* **macos:** allow idle sleep between meetings ([3a180f5](https://github.com/ekho/verbemo/commit/3a180f5956eeecf9206cb6ed3cfccffcc49844be))
* **macos:** allow idle sleep between meetings ([#12](https://github.com/ekho/verbemo/issues/12)) ([35ef682](https://github.com/ekho/verbemo/commit/35ef682d561a6bb227ff3366023419a011a802f3))
* **macos:** match calendar titles for early joins ([#15](https://github.com/ekho/verbemo/issues/15)) ([d3da787](https://github.com/ekho/verbemo/commit/d3da787fb5ef3dff4c8cb266fe29ca8ab9b91227)), closes [#14](https://github.com/ekho/verbemo/issues/14)
* **windows:** stop packaging nonexistent release notes ([4cd22f5](https://github.com/ekho/verbemo/commit/4cd22f51bd31b561379caabd3d518cf0d7a03f8a))

