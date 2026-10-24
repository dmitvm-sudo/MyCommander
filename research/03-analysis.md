# Фаза 2 — Анализ и проектные решения

## 1. Сравнительная матрица (фичи × решения)

| Фича | TC (реф.) | Nimble | DoubleCmd | muCmd | ForkLift | Cmdr One | Path Finder | **Наша цель** |
|---|---|---|---|---|---|---|---|---|
| Нативность macOS (Swift/AppKit) | — | ✔ (C++) | ✘ Pascal | ✘ Java | ✔ | ✔ | ✔ | ✔✔ |
| Open source | ✘ | ✔ GPL3 | ✔ GPL2 | ✔ GPL3-подоб. | ✘ | ✘ | ✘ | **решение ADR-6** |
| 2 панели + табы | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ± | ✔ |
| TC-горячие клавиши (F3–F8, Ins, Alt+) | ✔ | ✔ | ✔ | ✔ | ± | ✔ (F8) | ✘ | ✔ |
| Ops с очередью/паузой/конфликтами | ✔ | ± (нет очереди) | ✔ | ✔ | ✔✔ лучший | ✔ | ± | ✔✔ |
| Undo операций | ± | ✔ | ± | ✘ | ✘ | ✘ | ✓ | ✔ (детермин.) |
| Архивы как папки | ✔✔ | ✔ (встроен.) | ✔ | ✔ | ✔ | ✔ | ✘ | ✔ MVP zip/tar/gz/xz, 7z read |
| SFTP | via плагин (WFX) | ✔ | ✔ | ✔ | ✔✔ | ✔ Pro | ✘ | ✔ (Citadel) |
| SMB | ✔ | ± | ± | ✔ | ✔ | ✔ | ✔ | post-MVP |
| FTP | ✔✔ | ✔ | ✔ | ✔ | ✔ | ✔ Pro | ✘ | post-MVP (нет либы) |
| Облачные диски | WFX Cloud | ✘ | ✘ | ✔ | ✔ | ✔ Pro | ✘ | post-MVP (S3) |
| Встроенный requestов terminal | ✘ | ✘ | ✘ | ✘ | ✘ | ✔ Pro | ✘ | ✔ дифференциатор |
| Git-awareness | ✘ | ✘ | ✘ | ✘ | ✘ | ✘ | ✘ | ✔ дифференциатор |
| Quick Look нативный | (Win аналог) | ✔ | ✘ | ± | ✔ | ✔ | ✔ | ✔ |
| Spotlight/тэги macOS | ✘ | ± | ✘ | ✘ | ± | ± | ✔ | ✔ дифференциатор |
| Multi-rename | ✔✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| Sync/compare dirs | ✔✔ | ✔ | ✔ | ✔ | ✔✔ | ✔ | ✔ | ✔ (v1) |
| FDA/права UX | — | ✔ | ✘ (не sandbox всё равно) | ✘ | ✔ | ✔ | ✔ | ✔✔ onboarding |
| Плugins-система | ✔✔ (WCX/WDX/WLX/WFX) | ✔ (C++ API) | ✔ TC-совместим | ✔ Java | ✘ | ± | modules | ✔ v1.x (свой контракт) |

## 2. Топ-10 фич «table stakes» (без которых продукт не TC-подобен)
1. Двухпанельный UI с табами, фокусом, сортировками, brief/full/custom-columns, thumbnails.
2. Копировать/переместить/удалить/переименовать: очередь передач, прогресс, конфликт-решения (overwrite/skip/rename-for-all/cancel), пауза/отмена, фоновый режим.
3. Клавиатура TC/NC: F3 вид, F4 редакт, F5 copy, F6 move, F7 mkdir, F8 delete, Ins/Space select, quick search «на лету», Alt+F(1..) hotlist дисков/закладок.
4. VFS: локальный том + архивы-как-папки + сетевые (SFTP) через единый интерфейс.
5. Встроенный просмотр (text/hex/image; большие файлы стримом) + Quick Look + редактирование во внешнем редакторе.
6. Быстрый фильтр по текущей папке + полнотекстовый поиск с фильтрами; результаты как виртуальная папка.
7. Multi-rename с правилами и предпросмотром.
8. Compare & sync каталогов; compare by content.
9. Favorites/history/hotlist + connection manager (SFTP-хосты, пароли в Keychain).
10. Drag&Drop с Finder в обе стороны, «Terminal here», «Reveal in Finder», Open with.

## 3. Дифференциация (чем берём)
- Нативный Swift 6 + мгновенный запуск; ни одного кроссплатформенного кэша.
- Полноценная **очередь передач** с предысторией/логом (фиксированная боль Nimble).
- **Встроенный PTY-terminal** в нижней панели (есть только у Commander One Pro и Captain's Deck).
- **Git-осведомлённость панелей** (статусы файлов в репозиториях) — есть лишь у Captain's Deck; для разработчиков-аудитории критично.
- macOS-native фичи: тэги/Spotlight-колонки, Quick Look, APFS clonefile — мгновенные копии на томе.
- Прозрачность прав: красивый onboarding по FDA и working без него.

## 4. Риски и митигации

| # | Риск | Влияние | Митигация |
|---|---|---|---|
| R1 | Apple ужесточает FDA (Oct 2026 news) | Поломка core-сценария | Не-sandboxed + graceful degradation; мониторинг бета-версий; granular-запросы Desktop/Documents/Downloads отдельно |
| R2 | App Store несовместим с продуктом | Ограничение канала | Direct + notarization + Sparkle; App Store-«Lite» — не MVP |
| R3 | FTP: нет зрелой Swift-библиотеки | Задержка фичи | Отложить в post-MVP; SFTP (Citadel) закрывает 90% серверных сценариев |
| R4 | 7z write недоступен в SWCompression | Ограничение архиватора | 7z — read-only; write = zip/tar; libarchive как опция позже |
| R5 | RAR: юридические ограничения распаковки | Формат «вне корзины» | Не включаем в core; документируем причину (лицензия) |
| R6 | Большие папки (100k+) в NSTableView | Лаги, потеря доверия | Инкрементальные diff-обновления, фоновая загрузка, спиннер в панели вместо полного блокнота |
| R7 | Надёжность кросс-томных переносов | Потеря данных | Temp-file + atomic rename, транзакционная очередь, resume, тест матрицы томов (APFS/HFS+/exFAT/SMB) |
| R8 | Скоуп-крип при вайбкодинге | Строительство «вечного MVP» | Жёсткие milestone-границы (M1 core → M2 archive/SFTP → M3 diff-синхр+terminal); плагины после v1 |
| R9 | Качество Citadel/AMSMB2 (непроизводственные проекты) | Обрыв загрузок | Обёртки reconnect/retry, fallback логика, таймауты; изоляция за протоколом VFS |

## 5. Architecture Decision Records (черновики)

- **ADR-1 Стек**: Swift 6 + Xcode 27 SDK, deployment target macOS 14+ (Sonomа) — консервативно; AppKit для панелей, SwiftUI для настроек/диалогов/onboarding. Не кроссплатформен.
- **ADR-2 Дистрибуция**: не-sandboxed, direct (notarized DMG) + Sparkle; запрашивать FDA с объяснением; работа без FDA обязательна.
- **ADR-3 Архитектура**: SPM-модули (Domain / FileOps / VFS-адаптеры / UI / Services), протоколы вместо конкретики — читаемость для AI-агентов и тестов; DI конструкторами; строгая main actor UI / actor- boiled engines.
- **ADR-4 Архивы**: единый VFS; MVP: read zip/tar/gz/xz via SWCompression, zip write via ZIPFoundation; 7z read-only; бренд «архив открывается в панели».
- **ADR-5 Сеть**: SFTP через Citadel (SwiftNIO SSH); SMB через AMSMB2 — post-MVP; FTP — отложено; S3 — post-MVP (aws-sdk-swift).
- **ADR-6 Лицензия/модель**: открыть исходники (рекомендация GPLv3) — потребность подтвердить у владельца;商业模式: free core, разовая Pro-опция позднее.
- **ASSUMPTION**: целевая аудитория v1 — разработчики/sysadmins; локализации EN + RU.

## 6. Вывод для SDD
Ниша свободна: «нативный dục-манагер TC-стиля на Swift, open-source, с очередью передач уровня ForkLift, встроенным terminal и Git-awareness». Стек и библиотеки проверены. Основные платформенные риски (FDA/sandbox/FTP/RAR) имеют описанные митигации.
