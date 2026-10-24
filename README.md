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
swift run MyCommander          # smoke-запуск (граф модулей; UI появится в T-05)
./Tools/license-check.sh       # гейт лицензий (N-10)
```

## Структура
- `Packages/` — модули SPM (карта и ответственность каждого файла: `docs/SDD/11-Project-Layout.md`)
- `App/` — точка входа приложения
- `docs/SDD/` — спецификация · `research/` — фактура исследования · `Tools/` — гейты

## Участие
- PR: тесты зелёные; новая зависимость — сначала запись в `NOTICE.md` (только MIT / Apache-2.0 / BSD).
- Открытые вопросы продукта — `docs/SDD/10-Risks-Open-Questions.md`.

## Лицензия
GPL-3.0-or-later — [`LICENSE`](LICENSE). Сторонние компоненты: [`NOTICE.md`](NOTICE.md).
