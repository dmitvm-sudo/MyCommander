# Фаза 1 — Исследование аналогов (собрано 24.10.2026)

## 1. Референс-эталон: Total Commander (Windows, proprietary)

Источник: ghisler.com/featurel.htm (Feature list), ghisler.com/plugins.htm

Ключевые фичи, вокруг которых формируется «TC-подобный» продукт:
- Две панели, drag & drop с Explorer, командная строка (Ctrl+Enter / Ctrl+Shift+Enter подстановка имени/пути), user-defined commands, настраиваемые меню и кнопочная панель.
- Lister (встроенный просмотрщик): файлы любого размера, text/ASCII/hex/binary, Unicode/HTML, просмотр внутри архивов.
- Файловые операции над деревьями: копирование/перемещение/удаление/переименование; compare by content; синхронизация каталогов (и каталог ↔ ZIP); split/combine; encode/decode UUE/XXE/MIME; поиск дубликатов.
- Поиск: маски, размер, дата, содержимое, полнотекстовый по нескольким дискам и внутри архивов; «показать/выделить по шаблону»; restore selection.
- Multi-rename tool (Ctrl+M) — пакетное переименование с правилами и предпросмотром.
- Thumbnails view, custom columns, настраиваемая сортировка.
- FTP-клиент: FTPS, FXP, докачка, фоновые загрузки, очередь.
- Архивы «как каталоги»: ZIP (встроенный packer на zlib/libdeflate), внутр. распаковка ARJ/LZH/TAR/GZ/CAB/RAR/ACE; фоновая упаковка; копирование архив→архив.
- **Плагины (эко-система из сотен расширений):**
  - **WCX** — packer-расширения (форматы архивов)
  - **WFX** — file system расширения (реестр, облака, FTP, мобильные устройства)
  - **WDX** — content/columns расширения (EXIF, ID3, размеры, MIME...)
  - **WLX** — lister-расширения (просмотрщики)
- Горячие клавиши F3–F8 (view/edit/copy/move/mkdir/delete) и лента Alt-комбинаций — «мышечная память» пользователей.

## 2. Open-source аналоги

### Nimble Commander — github.com/mikekazakov/nimble-commander
- C++ / Objective-C++ (AppKit), macOS-only, **GPLv3**, free & open-source (открыт в ~2024).
- Активная разработка: Sep 2026 — переход на Xcode 27 / macOS 27 SDK, дроп Big Sur.
- Есть и App Store-версия, и direct-сборки.
- Отзывы: лучший «чистый» TC-стиль, клавиатура, скорость; кастомизация. Слабости: международная «steep learning curve», слабый UI прогресса передач (нет панели очереди передач), пауза при открытии папок.
- Клиника для нас: доказывает жизнеспособность нативного AppKit-подхода и что прогресс/очередь передач — больная точка конкурента.

### Double Commander — github.com/doublecmd/doublecmd
- **4 674 ⭐**, GPL-2.0, **Free Pascal/Lazarus (Pascal)**, кроссплатформенный; активен (push 24.10.2026), 649 open issues, 367 forks.
- Максимальная совместимость с TC: плагины WCX/WDX/WLX/WFX, Command-line, встроенный viewer/editor, двойные панели.
- Слабости: не нативный для macOS (вид/поведение «из 90-х», GTK/LCL-эстетика), медленные релизы.

### muCommander — github.com/mucommander/mucommander
- **1 290 ⭐**, Java, лицензия «Other» (GPL-3-подобная), кроссплатформенный.
- С.getHours: богатая сетевая абстракция — SMB, WebDAV, FTP/SFTP, S3, NFS, HTTP через единое дерево.
- Слабости: Java-UI, не нативный, воспринимается медленным; производительность.
- Ценность: архитектурный образец «моно-VFS над разнородными протоколами».

### Files (files-community/Files) — референс, не конкурент
- **46 183 ⭐**, C# / WinUI 3, MIT, Windows-only.
- Ценность: образец современной модульной архитектуры (MVVM, DI, подписки сервисов), продукта-комьюнити.

### Midnight Commander (GNU mc)
- C, GPL-3, TUI. Референс клавиатурных конвенций и внутренней VFS (ftpfs/smbfs через libvfs).

## 3. Коммерческие аналоги macOS

| Продукт | Цена / модель | Ключевое | Слабое |
|---|---|---|---|
| **ForkLift 4** (BinaryNights) | $19.95 + 1 год обновлений / $34.95 + 2 года, триал 14 дней | Самый «отшлифованный»: SFTP/FTP/SMB/AFP/WebDAV/S3/NFS, Google Drive/B2; Sync & Compare, transfer queue с логом, App Deleter, Disklet (mount volume в Finder), multi-rename, версии каталогов | Нет free tier; нет встроенного terminal; платно навсегда |
| **Commander One** (Eltima) | Free tier + PRO $29.99 разово ($99.99 / 5 Mac) | F-клавиши «по-нортоновски», unlimited tabs, темы, ZIP бесплатно; в PRO — FTP/SFTP, облака (Dropbox/Drive/OneDrive/S3), встроенный terminal, root | Жалобы на скорость/лаги, захламлённый UI; критичная часть фич за плату |
| **Path Finder** (Cocoatech) | $2.95/мес или $29.95/год (бывшие lifetime — недовольны) | Глубина нативного Finder-замещения: Drop Stack, ACL editor, Inspector, Tags, Smart Folders | Двухпанельность «прикручена»; подписка frustrates |
| **One Commander** | Free / Pro | Современный UI, multi-pane | Ограничения Pro |
| **Marta** (marta.sh) | Free | Клавиатура-first, мгновенный запуск, минимализм | Нет превью, конфиг только текстовым файлом, «не для GUI- addicts» |
| **Captain's Deck** | €19.99 разово, €69.99 семенйный | Уникально: встроенный PTY terminal, inline Git-статусы, vim-навигация, Synclets, transfer queue | Молодой продукт, догоняет по polish |
| **QSpace Pro** | $13.99 | 12 layout-пресетов мульти-панелей, SFTP/WebDAV | Меньше известности |
| Прочее | TotalFinder, XtraFinder (по сути мертвы: SIP-хаки), DCommander, Crax, fman | — | — |

Источники: captains-deck.com/compare/forklift-vs-commander-one.html, fileminutes.com 2026 review, applefritter.com сравнение удалённого доступа, medium.com (Path Finder vs alternatives, март 2026), reddit r/macapps.

## 4. Сигналы от пользователей (паттерны недовольства)
1. «Не нативно/не быстро» — самые частые претензии к muCommander и Commander One.
2. «Нет очереди передач / прогресс уродует» — претензия к Nimble Commander; ForkLift здесь лидер.
3. «Мы хотим free или разовую цену» — подписка Path Finder вызывает неудовольствие; разовые/lifetime — ценятся.
4. «Hotkeys как в TC» — для мигрантов с Windows критично (Norton F-клавиши).
5. Встроенный terminal + Git — редкий дифференциатор (Captain's Deck).
6. Нет ни одного нативного Swift-двухпанельника в open source: ниша свободна.
