# AGENTS.md

MyCommander — двухпанельный файловый менеджер для macOS (Swift 6, AppKit). Open source, GPL-3.0-or-later. Репозиторий ведётся по строгому процессу; следование ему — часть каждой задачи.

## Спецификация — единственный источник истины
- Впервые в репозитории → прочитай `docs/SDD/README.md` (индекс SDD) целиком.
- Возвращаешься к работе → открой `docs/SDD/09-Milestones-Roadmap.md` (текущий milestone и его exit-критерии) и `docs/SDD/12-VibeCoding-TaskPlan.md` (правила выполнения задач).

## Процесс задачи
1. Возьми ровно одну задачу `T-xx` из `docs/SDD/12-VibeCoding-TaskPlan.md` в порядке следования внутри milestone.
2. Контракты типов — из `docs/SDD/05-DataModel-VFS.md` и `docs/SDD/06-Subsystems-Design.md`; семантика контрактов не меняется молча.
3. Нужна правка публичного контракта → сначала правка SDD (коммит `docs: …`), затем код.
4. Критерий «Готово» из задачи — граница работы; смежная проблема оформляется issue/заметкой.

## Гейты качества
- Тесты: уровни и бюджеты — `docs/SDD/08-Test-Plan.md`; `swift build && swift test` зелёные до конца задачи.
- Ошибки — типами из `docs/SDD/05-DataModel-VFS.md` (`MCError` и производные); UI-строки — через Localizable; секреты (пароли/ключи) — только Keychain.
- Производительность: бюджеты `docs/SDD/03-Requirements-NonFunctional.md`; perf-тесты обязательны с M1.

## Зависимости и лицензия (N-10)
- Новая сторонняя зависимость → сначала строка в `NOTICE.md` (разрешены MIT / Apache-2.0 / BSD), затем `Package.swift`; гейт: `Tools/license-check.sh` + CI.

## Layout и команды
- Карта файлов и ответственность каждого модуля: `docs/SDD/11-Project-Layout.md`.
- Команды: `swift build` · `swift test` · `./Tools/license-check.sh`.
