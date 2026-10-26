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
DMG (drag MyCommander.app в Applications) + EdDSA-подписанный appcast для автообновлений
(Sparkle 2; автопроверку можно отключить в настройках — сеть не трогается до явного запроса, N-9).
Сборка ad-hoc, без Apple notarization: на чужой машине первый запуск требует
Gatekeeper-разрешения — macOS 14: правый клик по MyCommander.app → «Открыть»;
macOS 15+: Системные настройки → Конфиденциальность и безопасность → «Всё равно открыть».
Автообновления через Sparkle карантин не ставят и этого шага не требуют.
- `Tools/release/build-app.sh` — сборка `MyCommander.app` (бинарный + ресурсы + Sparkle; подпись через `SIGN_IDENTITY`, EdDSA-ключ через `SPARKLE_EDDSA_KEY`);
- `Tools/release/make-dmg.sh` — UDZO-образ;
- `Tools/release/notarize.sh` — notarization + staple (нужны учётные данные Apple Developer Program — сейчас не применяются);
- `Tools/release/update-appcast.sh` — обновление `appcast.xml` (beta-канал по `-betaN`), EdDSA-подпись читается из Keychain;
- протокол публикации: тег `v*` в CI создаёт DRAFT-релиз; релиз-дес собирает и подписывает локально, затем `gh release upload --clobber` + `gh release edit --draft=false` (ключи всегда вне CI — supply-chain).

## Структура
- `Packages/` — модули SPM (карта и ответственность каждого файла: `docs/SDD/11-Project-Layout.md`)
- `App/` — точка входа приложения
- `docs/SDD/` — спецификация · `research/` — фактура исследования · `Tools/` — гейты
- `Tools/release/` — релизная конвейерка: .app → DMG → notarization → appcast → GitHub Release

## Помощь
Русская справка — в приложении: меню «Справка» → «Справка MyCommander онлайн» (этот README).
Горячие клавиши: профили Total Commander-стиль (defaults) или macOS-нативный — переключаются в настройках (⌘,).
Бета-фидбек: «Справка» → «Экспорт отчёта беты…» — локальная сводка сессий и крашей (без сети,
N-9); приложите файл к задаче на GitHub.

## Участие
- PR: тесты зелёные; новая зависимость — сначала запись в `NOTICE.md` (только MIT / Apache-2.0 / BSD).
- Открытые вопросы продукта — `docs/SDD/10-Risks-Open-Questions.md`.

## Лицензия
GPL-3.0-or-later — [`LICENSE`](LICENSE). Сторонние компоненты: [`NOTICE.md`](NOTICE.md).
