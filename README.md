# MyCommander

Двухпанельный файловый менеджер для macOS в традиции Norton / Windows / Total Commander: клавиатура-first, очереди передач, архивы «как папки», SFTP. Нативный Swift 6 + AppKit. Лицензия GPL-3.0-or-later.

Статус: **M0 — скелет репозитория** (SPM-граф, CI, гейты). Реализация идёт по плану задач.

## Документация
- Спецификация (SDD): [`docs/SDD/README.md`](docs/SDD/README.md)
- Правила для AI-агентов: [`AGENTS.md`](AGENTS.md)
- План задач: [`docs/SDD/12-VibeCoding-TaskPlan.md`](docs/SDD/12-VibeCoding-TaskPlan.md)
- Исследование рынка/технологий: [`research/`](research/)

## Сборка
```bash
git clone <repo-url> mycommander && cd mycommander
swift build
swift test                     # тесты всех SPM-модулей
swift run MyCommander          # запуск (SPM dev-сборка: updater/локализации через Bundle.main)
./Tools/license-check.sh       # гейт лицензий (N-10)
```

## Установка (релиз)
Релизы публикуются на [GitHub Releases](https://github.com/dmitvm-sudo/MyCommander/releases):
notarized DMG (drag MyCommander.app в Applications) + подписанный appcast для автообновлений
(Sparkle 2, EdDSA; пользователь может отключить автопроверку в Sparkle-настройках —
сеть не трогается до явного запроса, N-9).
- `Tools/release/build-app.sh` — сборка `MyCommander.app` (бинарный + ресурсы + Sparkle; подпись через `SIGN_IDENTITY`);
- `Tools/release/make-dmg.sh` — UDZO-образ;
- `Tools/release/notarize.sh` — notarization + staple (нужны учётные данные Apple);
- `Tools/release/update-appcast.sh` — обновление `appcast.xml` (beta-канал по `-betaN`).
Тег `v*` запускает это всё в CI (`.github/workflows/release.yml`).

## Структура
- `Packages/` — модули SPM (карта и ответственность каждого файла: `docs/SDD/11-Project-Layout.md`)
- `App/` — точка входа приложения
- `docs/SDD/` — спецификация · `research/` — фактура исследования · `Tools/` — гейты
- `Tools/release/` — релизная конвейерка: .app → DMG → notarization → appcast → GitHub Release

## Помощь
Русская справка — в приложении: меню «Справка» → «Справка MyCommander онлайн» (этот README).
Горячие клавиши: профили Total Commander-стиль (defaults) или macOS-нативный — переключаются в настройках (⌘,).

## Участие
- PR: тесты зелёные; новая зависимость — сначала запись в `NOTICE.md` (только MIT / Apache-2.0 / BSD).
- Открытые вопросы продукта — `docs/SDD/10-Risks-Open-Questions.md`.

## Лицензия
GPL-3.0-or-later — [`LICENSE`](LICENSE). Сторонние компоненты: [`NOTICE.md`](NOTICE.md).
