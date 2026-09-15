

---

**Скачать (Windows x64):**

| Файл | Что это |
|---|---|
| [FlClashGH-VERSION-windows-amd64-setup.exe](https://github.com/wintergenius/FLClash_GH/releases/download/vVERSION/FlClashGH-VERSION-windows-amd64-setup.exe) | установщик, ставится с правами администратора |
| [FlClashGH-VERSION-windows-amd64.zip](https://github.com/wintergenius/FLClash_GH/releases/download/vVERSION/FlClashGH-VERSION-windows-amd64.zip) | portable, распаковать в любую папку |
| SHA256SUMS | контрольные суммы всех файлов релиза |

**Скачать (Android):**

| Файл | Что это |
|---|---|
| [FlClashGH-VERSION-android-arm64-v8a.apk](https://github.com/wintergenius/FLClash_GH/releases/download/vVERSION/FlClashGH-VERSION-android-arm64-v8a.apk) | большинство телефонов 2017+ (64-бит ARM) |
| [FlClashGH-VERSION-android-armeabi-v7a.apk](https://github.com/wintergenius/FLClash_GH/releases/download/vVERSION/FlClashGH-VERSION-android-armeabi-v7a.apk) | старые 32-битные телефоны |
| [FlClashGH-VERSION-android-x86_64.apk](https://github.com/wintergenius/FLClash_GH/releases/download/vVERSION/FlClashGH-VERSION-android-x86_64.apk) | эмуляторы и ПК на Android |

**Установка на Android.** Разрешить установку из этого источника (браузер или файловый менеджер), открыть APK. Сборка подписана нашим ключом и использует тот же идентификатор пакета, что оригинальный FlClash, поэтому поверх оригинала не встанет: сначала удалить FlClash из магазина, затем поставить эту сборку и заново добавить профиль. Обновления между версиями FlClash GH ставятся поверх.

**SmartScreen.** Сборка не подписана сертификатом, поэтому при первом запуске Windows покажет «Система Windows защитила ваш компьютер». Нажмите «Подробнее» → «Выполнить в любом случае». Перед этим можно сверить SHA256 файла с `SHA256SUMS` из этого релиза: `certutil -hashfile <файл> SHA256`.

**Первый запуск сплита по приложениям.** Инструменты → «Приложения через VPN» → включить. Один раз появится запрос UAC: ставится служба Helper, после этого TUN и списки работают без прав. Изменения списков применяются кнопкой «Сохранить».

Исходный код форка: https://github.com/wintergenius/FLClash_GH (GPL-3.0, на базе [FlClash](https://github.com/chen08209/FlClash)).
