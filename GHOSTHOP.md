# FlClash GH — форк FlClash со сплитом по приложениям на Windows

Этот репозиторий — форк [chen08209/FlClash](https://github.com/chen08209/FlClash) под лицензией
GPL-3.0. Апстрим не изменён по существу: ядро (`core/`, сабмодуль `core/Clash.Meta`), Helper-сервис
и движок те же. Добавлено одно: вкладка **«Приложения через VPN»** на Windows — выбор программ,
папок и процессов, которые идут через туннель, в духе WireSock.

## Что добавлено

- `lib/views/access_desktop.dart` — вкладка (Инструменты → «Приложения через VPN»): два списка,
  «через туннель» и «мимо туннеля», кнопки «запущенный процесс / .exe / папка / по имени»,
  тумблер, который проходит авторизацию TUN (Helper за UAC, один раз), кнопка «Сохранить».
- `lib/common/access_rules.dart` — рендер списков в правила mihomo поверх правил профиля:
  список «через туннель» непустой → `NOT,((OR,(...))),DIRECT` (перечисленные проваливаются к
  правилам профиля, остальное напрямую; второй список при этом не учитывается, как в WireSock);
  только «мимо туннеля» → `PROCESS-*,DIRECT` на каждую запись. Имя без слэшей = имя процесса
  (`.exe` дописывается), путь с `.exe` = точное совпадение, папка = `PROCESS-PATH-WILDCARD,<папка>\*`,
  `*`/`?` включают wildcard. Регистр не важен.
- `lib/common/windows_process.dart` — список процессов через `kernel32` (ToolHelp snapshot +
  `QueryFullProcessImageNameW`) без прав администратора; у чужих и повышенных процессов путь
  недоступен, они добавляются по имени.
- «Сохранить» = `applyProfile()` (горячая перезагрузка правил, TUN и слушатели не трогаются) плюс
  сброс открытых соединений, чтобы приложения переподключились уже по новым правилам.

Идентичность форка: отображаемое имя `FlClash GH` (`displayName`), User-Agent подписки
`FlClashGH/v<версия> clash-verge Platform/windows` (`uaName`), проверка обновлений смотрит на
`wintergenius/FLClash_GH` (`repository`). Внутренние имена (`appName = FlClash`, `com.follow.clash`,
папка данных `%APPDATA%\com.follow\clash`, имена exe) оставлены как у апстрима, чтобы дифф был
минимальным.

## Ветки и релизы

- `upstream` — зеркало `chen08209/FlClash` `main`, без правок.
- `ghosthop` — ветка форка (по умолчанию): коммиты апстрима + наши поверх.
- Версии свои: `1.0.x`; база апстрима указывается в changelog. Тег `v1.0.x` запускает
  `.github/workflows/release.yaml`: сборка Windows amd64 (`dart setup.dart windows`), установщик
  Inno Setup + portable zip + `SHA256SUMS`, релиз на GitHub. Сборки не подписаны (SmartScreen —
  см. заметки релиза).
- Обновление апстрима: `git fetch upstream-remote && git rebase <тег>` в `ghosthop`; точки
  конфликтов — `lib/common/task.dart` (сборка правил), `lib/providers/actions/setup.dart`,
  `lib/providers/state/profile.dart`, `lib/views/tools.dart`, `lib/models/state.dart`. Ядро приходит
  с апстримом сабмодулем; при срочной нужде бампается сабмодуль и пересобирается всё.

## Сборка локально (Windows)

Flutter ≥ 3.47 (Dart ≥ 3.10), Go ≥ 1.21, Rust stable, Visual Studio Build Tools 2022 (C++ +
CMake + Windows SDK), для установщика — Inno Setup 6.

```
git clone --recurse-submodules https://github.com/wintergenius/FLClash_GH.git
cd FLClash_GH
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # после правок моделей/провайдеров
flutter build windows --release                            # portable в build\windows\x64\runner\Release
dart setup.dart windows                                    # установщик + zip в dist\
```

Если выключен Developer Mode, Flutter не может создать симлинки плагинов
(`windows\flutter\ephemeral\.plugin_symlinks`). Их можно один раз создать junction'ами
(`mklink /J`) по списку из `.flutter-plugins-dependencies` после `flutter pub get`; Flutter
существующие ссылки не трогает.
