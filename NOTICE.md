# NOTICE — сторонние компоненты

Политика (docs/SDD, N-10): сторонняя зависимость попадает в `Package.swift` только после записи здесь.
Разрешённые лицензии: MIT, Apache-2.0, BSD (GPL-3.0-совместимые). Гейт: `Tools/license-check.sh` + CI.

## Порядок добавления
1. Оценить лицензию и активность поддержки пакета (см. исследование: `research/02-ecosystem.md`).
2. Заполнить таблицу ниже: пакет, лицензия, назначение, задача-инициатор (T-xx).
3. Добавить зависимость в `Package.swift`; закоммитить обновлённый `Package.resolved`.

## Текущие зависимости сборки
| Пакет | Лицензия | Назначение | Появился в |
|---|---|---|---|
| weichsel/ZIPFoundation | MIT | ZIP read (T-21), ZIP write (T-22) (F-12) | M2 (T-21) |
| tsolomko/SWCompression | MIT | tar/gz/xz/bz2 read (F-12; 7z-read — v1.0 SHOULD) | M2 (T-21) |
| tsolomko/BitByteData | MIT | транзитивная зависимость SWCompression (bit readers) | M2 (T-21) |
| orlandos-nl/Citadel | MIT | SSH/SFTP-клиент + in-process SFTP-сервер тест-стенда (F-13) | M2 (T-23) |
| Wellz26/swift-nio-ssh | Apache-2.0 | SSH-транспорт; прямая пин-зависимость Citadel 0.12.1 (замороженный apple/swift-nio-ssh подменён форком апстримом — supply-chain риск отмечен, версия пинится Citadel-ом) | M2 (T-23) |
| apple/swift-nio | Apache-2.0 | NIO-транспорт Citadel | M2 (T-23) |
| apple/swift-log | Apache-2.0 | Logging Citadel | M2 (T-23) |
| attaswift/BigInt | MIT | BigInt Citadel | M2 (T-23) |
| apple/swift-crypto | Apache-2.0* | Crypto Citadel (*внутри — BoringSSL, dual OpenSSL/Apache-2.0) | M2 (T-23) |
| mtynior/ColorizeSwift | MIT | объявленная dep Citadel (подключает executable-пример; попадает в resolved) | M2 (T-23) |
| apple/swift-asn1 | Apache-2.0 | транзитивная dep swift-crypto | M2 (T-23) |
| apple/swift-atomics | Apache-2.0 | транзитивная dep swift-nio | M2 (T-23) |
| apple/swift-collections | Apache-2.0 | транзитивная dep swift-nio | M2 (T-23) |
| apple/swift-system | Apache-2.0 | транзитивная dep swift-nio | M2 (T-23) |
| apple/swift-argument-parser | Apache-2.0 | транзитивная dep SwiftTerm (CLI-парсер) | M3 (T-31) |
| tayloraswift/swift-png | Apache-2.0 | транзитивная dep SwiftTerm | M3 (T-31) |
| rarestype/h | Apache-2.0 | транзитивная dep SwiftTerm | M3 (T-31) |
| migueldeicaza/SwiftTerm | MIT | встроенный PTY-terminal (F-17: SwiftTerm-хост, resize/copy/paste, tmux/ssh/vim) | M3 (T-31) |

## Запланировано (лицензию подтвердить при добавлении)
| Пакет | Лицензия | Назначение | Появится в |
|---|---|---|---|
| Sparkle | MIT | автообновления | v1.0 (T-37) |

## Явно исключено
- unrar / RAR-код — лицензионные ограничения (docs/SDD, риск R5); в core не включается.
