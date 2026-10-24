# Фаза 1 — Платформа macOS и Swift-экосистема (собрано 24.10.2026)

## 1. Права доступа к файлам — главный платформенный риск

Факты:
- Apple: «Accessing files from the macOS App Sandbox» (developer.apple.com/documentation/security):
  - Даже при разрешённом sandbox-доступе POS states/TCC-ограничения могут блокировать файл.
  - **Full Disk Access (FDA, TCC kTCCServiceSystemPolicyAllFiles) нельзя получить программно** — пользователь вручную выдаёт в System Settings → Privacy & Security.
  - Sandboxed-приложение **не может** получить FDA: sandbox остаётся. Доступ к внешним файлам — только NSOpenPanel/NSSavePanel (sandbox extensions), **security-scoped bookmarks**, entitlements.
- Oct 2026 — Apple Developer News «Updates to Full Disk Access in macOS»: Apple **ужесточает контроль** FDA (риск раскрытия mail/messages/истории). Тренд на гранулярные разрешения вместо «всё или ничего». Контейнеры даже для FDA-приложений уже ограничиваются в macOS 27.
- Для не-sandboxed приложений существуют отдельные TCC-разрешения на Desktop/Documents/Downloads, FDA — «everything else».

Выводы (перефирменное требование в SDD):
- Продуктовый путь: **не-sandboxed приложение, direct-дистрибуция + notarization**. При первом запуске — понятный onboarding-экран «grants FDA», плюс graceful degradation: если доступ не выдан — работа только с granted-папками (Desktop/Documents/Downloads, панели open/save).
- App Store-версия полноценного файл-менеджера практически невозможна sandbox-моделью → в MVP исключаем; допускаем потом «Lite» вариант.
- Проверка FDA в runtime: мягкая (access check по маркерам, например чтение непубличного пути с fallback), никаких жёстких блокировок.

## 2. UI: AppKit против SwiftUI

- Nimble Commander (Obj-C++/AppKit), ForkLift, Path Finder, QSpace — все нативные AppKit. Не нативные (muCommander/Java, cross-плейфы) постоянно критикуют за «peformance и вид».
- Панели файлов = плотные списки на 10 000–200 000 строк, мгновенная реакция клавиатуры, переиспользуемые ячейки, горизонтальные скроллы + синхронизируемая разблокировка.
- Вывод: **панели — NSTableView** (cell-based) с custom cell views + NSFlippedView**;** SwiftUI — только для «chrome»: окна настроек, диалоги, onboarding, возможно toolbar. Практика рынка подтверждает AppKit для core-UI.

## 3. Наблюдение за файловой системой
- **FSEvents** — Mac-native механизм потоков изменений (быстрый, иерархический, с coalescing); fallback: kqueue/DispatchSource на отдельные каталоги.
- Требование SDD: панель обновляет список диффом (нет полного reload), debounce латентности ~0.5–1 c, отсечка «чужих» операций (echo-filter по ТЗ на свои перемещения).

## 4. Операции с файлами
- `copyfile()/fcopyfile` — быстрые системные копии с метаданными/xattr.
- **APFS `clonefile()`** — мгновенное «копирование» на том же томе (zero-copy) — обязательная оптимизация.
- Атомарность: rename(2) внутри тома; перемещения между томами = copy+delete через временную папку.
-Удаление в корзину: FileManager.trashItem; восстановление из корзины.
- Очередь передач: настройки по файлам (partial copy + rename), pause/resume, отмена, retry; лог операций.

## 5. Поиск/Preview/метаданные
- Quick Look: QLPreviewPanel/QLPreviewView (просмотр любых документов), QLThumbnailGenerator (thumbs) — бесплатно получаем «Lister-lite».
- Spotlight: NSMetadataQuery (поиск + колонки вида тэги/дата; при FDA — индекс полный).
- Tags/comments файлов macOS (xattr `com.apple.metadata:_kMDItemUserTags` и др.) — нативная фича, у TC-аналогов её нет.

## 6. Готовые Swift-библиотеки (проверены активности/лицензии)

| Библиотека | Назначение | Статус |
|---|---|---|
| **apple/swift-nio-ssh** (523★, Apache-2.0, active) | SSH-транспорт (без SFTP верхнего уровня) | Основа низкого уровня |
| **orlandos-nl/Citadel** | SSH client + **SFTP client** на SwiftNIO: listDirectory, getRealPath, createDirectory, чтение/запись файлов, close | PRIMARY для SFTP |
| **amosavian/AMSMB2** | SMB2/3 через wraps libsmb2; async/await, listDirectory/moveItem/... | PRIMARY для SMB (позднее) |
| **kishikawakatsumi/SMBClient** | Pure Swift SMB client + файл-браузер | Альтернатива «без C» |
| **weichsel/ZIPFoundation** (2 745★, MIT, active) | ZIP чтение/запись, progressives, AES | PRIMARY для ZIP |
| **tsolomko/SWCompression** | Pure Swift: архивы и контейнеры — ZIP/TAR/GZ/XZ/BZip2/7z (чтение), **запись: ZIP, TAR** | PRIMARY для TAR/7z-read/GZ/XZ |
| **everpcpc/libarchive-swift** | Swift 6 wrapper над libarchive C API (zlib по умолчанию) | Опция для широкого формата |
| **libarchive** (3.8.10) | C-мультиформат (7z/tar/xz/...), vendoring или brew | Запасной вариант |
| Compression.framework (Apple) | Рaw-потоки zlib/bz2/lzma/zstd (без контейнеров) | Для codestream |
| FTP | **Зрелой Swift- FTP-клиент-библиотекой не располагаем** | Отложить FTP, приоритет SFTP |
| aws-sdk-swift | S3 (официально Apple-supported) | После MVP |
| Sparkle 2 | Обновления для не-App Store дистрибуции | Да |

## 7. Прочие решения платформы
- Онлайн-сертификация: хардень signing + notarytool; DMG + auto-update через Sparkle.
- Persistence настроек: JSON/SQLite в ~/Library/Application Support + UserDefaults; Keychain для паролей хостов.
- Локализация: нат人就 String Catalogs; минимум EN+RU на старте.
- Concurrency: Swift 6 strict concurrency; операции на actor'ах, UI на MainActor.
