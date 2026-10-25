// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

// Contract: docs/SDD/06 §6.8 «Контракт v1 (T-14)» — command bar (⌘L, F-17а).
// Pure logic (parser/placeholders/history) carries no AppKit and no VFS: the
// widget submits the typed line, the App driver (PanelsCoordinator) expands
// tokens with panel state and executes cd/mkdir/open/! against the VFS.

// MARK: - Placeholder context (App supplies, parser consumes)

/// Panel state snapshot for `%`-placeholders (docs/SDD/07, «Command bar»).
public struct CommandPlaceholderContext: Sendable, Equatable {
    /// Substitution of `%f` — the visible item under the cursor (nil = none).
    public let cursorName: String?
    /// Substitution of `%F` — its full path (with directory).
    public let cursorPath: String?
    /// Substitution of `%d` — the active panel's directory.
    public let activeDirectory: String
    /// Substitution of `%D` — the opposite panel's directory.
    public let oppositeDirectory: String
    /// Substitution of `%s` — selected names in visible order; when the
    /// selection is empty the cursor item steps in (F-3 semantics).
    public let selectionNames: [String]

    public init(
        cursorName: String?,
        cursorPath: String?,
        activeDirectory: String,
        oppositeDirectory: String,
        selectionNames: [String]
    ) {
        self.cursorName = cursorName
        self.cursorPath = cursorPath
        self.activeDirectory = activeDirectory
        self.oppositeDirectory = oppositeDirectory
        self.selectionNames = selectionNames
    }
}

public enum CommandPlaceholders {
    /// Expands `%f %F %d %D %s` in one left-to-right pass; `%%` stays a
    /// literal `%`; unknown `%x` copies through. With `context == nil` the
    /// line is returned untouched (the history preview keeps tokens).
    ///
    /// Substituted paths get shell quotation when they contain spaces or
    /// quotes — one algorithm for both vfs-style commands and `!` runs; the
    /// vfs-style call sites unquote via `CommandBarParser.unquote`.
    public static func expand(_ line: String, context: CommandPlaceholderContext?) -> String {
        guard let context else { return line }
        var result = ""
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            guard character == "%" else {
                result.append(character)
                index = line.index(after: index)
                continue
            }
            // A trailing `%` copies through (there is no token after it).
            guard let next = line.index(index, offsetBy: 1, limitedBy: line.endIndex), next != line.endIndex else {
                result.append(character)
                index = line.index(after: index)
                continue
            }
            let token = line[next]
            let tokenStart = line.index(after: next)
            switch token {
            case "f":
                result.append(quoteIfNeeded(context.cursorName ?? ""))
            case "F":
                result.append(quoteIfNeeded(context.cursorPath ?? ""))
            case "d":
                result.append(quoteIfNeeded(context.activeDirectory))
            case "D":
                result.append(quoteIfNeeded(context.oppositeDirectory))
            case "s":
                let names = context.selectionNames.isEmpty ? [context.cursorName ?? ""] : context.selectionNames
                result.append(names.map { quoteIfNeeded($0) }.joined(separator: " "))
            case "%":
                result.append("%")
            default:
                // Unknown token keeps both characters verbatim.
                result.append("%")
                result.append(token)
            }
            index = tokenStart
        }
        return result
    }

    /// Single-quote wrapping per POSIX: spaces/quotes trigger wrapping, the
    /// inner `'` becomes the `'…'` interleave.
    static func quoteIfNeeded(_ value: String) -> String {
        if value.isEmpty { return "" }
        let needsQuoting = value.contains { $0.isWhitespace || $0 == "'" || $0 == "\"" }
        guard needsQuoting else { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Parser (pure)

/// The interpreted command (expanded argument strings, no quoting left for
/// the vfs-style commands; `.shell` keeps everything after `!` verbatim).
public enum CommandBarCommand: Equatable {
    case cd(path: String)
    case mkdir(name: String)
    case open(path: String)
    case shell(command: String)
}

/// Parse result: `.empty` (Enter on empty line — the driver behaves like the
/// collapse/Esc contract) and human-readable failure messages.
public enum CommandBarParse: Equatable {
    case empty
    case command(CommandBarCommand)
    case invalid(message: String)
}

public enum CommandBarParser {
    /// Keyword routes the FIRST word before any `%`-expansion (spaces inside
    /// substituted paths must not break tokenization, 06 §6.8 v1).
    public static func parse(line raw: String, context: CommandPlaceholderContext?) -> CommandBarParse {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return .empty }

        guard let firstSpace = line.firstIndex(where: { $0.isWhitespace }) else {
            switch line.lowercased() {
            case "cd", "mkdir", "open":
                return .invalid(message: String(localized: "commandBar.error.missingArgument \(line)"))
            default:
                return line.hasPrefix("!")
                    ? expandShell(line, context: context)
                    : .invalid(message: String(localized: "commandBar.error.unknownCommand \(line)"))
            }
        }
        let keyword = String(line[..<firstSpace]).lowercased()
        let argumentStartOffset = line.index(after: firstSpace)
        let argument = String(line[argumentStartOffset ..< line.endIndex]).trimmingCharacters(in: .whitespaces)

        switch keyword {
        case "cd":
            guard let context else { return .invalid(message: "cd: no context") }
            let expanded = CommandPlaceholders.expand(argument, context: context)
            let path = unquote(expanded.trimmingCharacters(in: .whitespaces))
            guard !path.isEmpty else {
                return .invalid(message: String(localized: "commandBar.error.missingArgument cd"))
            }
            return .command(.cd(path: path))
        case "mkdir":
            guard let context else { return .invalid(message: "mkdir: no context") }
            let expanded = CommandPlaceholders.expand(argument, context: context)
            let name = unquote(expanded.trimmingCharacters(in: .whitespaces))
            guard !name.isEmpty else {
                return .invalid(message: String(localized: "commandBar.error.missingArgument mkdir"))
            }
            return .command(.mkdir(name: name))
        case "open":
            guard let context else { return .invalid(message: "open: no context") }
            let expanded = CommandPlaceholders.expand(argument, context: context)
            let path = unquote(expanded.trimmingCharacters(in: .whitespaces))
            guard !path.isEmpty else {
                return .invalid(message: String(localized: "commandBar.error.missingArgument open"))
            }
            return .command(.open(path: path))
        case "!":
            guard let context else { return .invalid(message: "! no context") }
            let expanded = CommandPlaceholders.expand(argument, context: context)
            guard !expanded.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .invalid(message: String(localized: "commandBar.error.missingArgument !"))
            }
            return .command(.shell(command: expanded))
        default:
            if line.hasPrefix("!") {
                // `!/cmd` or `!!` glued forms: the whole line (after «!») runs.
                return expandShell(line, context: context)
            }
            return .invalid(message: String(localized: "commandBar.error.unknownCommand \(line)"))
        }
    }

    private static func expandShell(_ line: String, context: CommandPlaceholderContext?) -> CommandBarParse {
        guard let context else { return .invalid(message: "! no context") }
        let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else {
            return .invalid(message: String(localized: "commandBar.error.missingArgument !"))
        }
        return .command(.shell(command: CommandPlaceholders.expand(body, context: context)))
    }

    /// Shell unquoting of one argument produced by `quoteIfNeeded`: removes a
    /// single or double quote wrap and processes `"`-escapes / `\`-escapes.
    public static func unquote(_ argument: String) -> String {
        var output = ""
        var inSingle = false
        var inDouble = false
        var index = argument.startIndex
        while index < argument.endIndex {
            let character = argument[index]
            switch character {
            case "'" where !inDouble:
                inSingle.toggle()
            case "\"" where !inSingle:
                inDouble.toggle()
            case "\\" where inDouble || (!inSingle && !inDouble):
                guard let next = argument.index(index, offsetBy: 1, limitedBy: argument.endIndex), next != index else {
                    output.append(character)
                    index = argument.endIndex
                    continue
                }
                output.append(argument[next])
                index = next
            default:
                output.append(character)
            }
            index = argument.index(after: index)
        }
        return output
    }
}

// MARK: - History (pure)

/// `↑`/`↓` cycling with a draft (CommandHistory with the typed-not-sent text,
/// 06 §6.8 v1): `↑` from the draft opens the newest entry, further presses go
/// older (clamped), `↓` walks back and finally returns the draft.
public struct CommandHistory: Equatable {
    public private(set) var entries: [String]
    /// `nil` = at the draft; otherwise an entry index.
    private var browsingIndex: Int?

    public init() {
        entries = []
    }

    /// Commit one line: empties drop, consecutive duplicates skip, the
    /// browsing position resets to the draft.
    public mutating func record(_ raw: String) {
        let command = raw.trimmingCharacters(in: .whitespaces)
        browsingIndex = nil
        guard !command.isEmpty else { return }
        if entries.last != command {
            entries.append(command)
        }
    }

    /// One step to the older entry; `nil` = nothing to show.
    public mutating func up() -> String? {
        guard !entries.isEmpty else { return nil }
        switch browsingIndex {
        case .none:
            browsingIndex = entries.count - 1
        case .some(let current):
            browsingIndex = max(0, current - 1)
        }
        return entries[browsingIndex!]
    }

    /// One step to the newer entry; when past the newest the draft comes
    /// back. `nil` = already at the empty draft (nothing to change).
    public mutating func down(_ draft: String) -> String? {
        switch browsingIndex {
        case .none:
            return nil
        case .some(let current):
            if current + 1 >= entries.count {
                browsingIndex = nil
                return draft
            }
            browsingIndex = current + 1
            return entries[browsingIndex!]
        }
    }
}

// MARK: - View (bar + console)

/// The bottom command bar of the main window (07 §7.2): prompt + input line
/// + the collapsible mini console. Key handling goes through the text field
/// delegate (`doCommandBy`); Enter/Esc/↑/↓ do not leak into the panel keys.
@MainActor
public final class CommandBarView: NSView {
    /// Fires with the raw typed line; the driver parses/appends output back.
    public var onSubmit: (@MainActor (String) -> Void)?
    /// Esc contract rides in the driver: clear-or-collapse.
    public var onEscape: (@MainActor () -> Void)?

    private let promptLabel = NSTextField(labelWithString: String(localized: "commandBar.prompt"))
    private let inputField = NSTextField()
    private let toggleButton = NSButton(title: "⌃", target: nil, action: nil)
    private let console = NSTextView()
    private let consoleScroll = NSScrollView()
    private var history = CommandHistory()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        fatalError("CommandBarView is created programmatically only")
    }

    private func setUp() {
        promptLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        promptLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        inputField.isBordered = false
        inputField.backgroundColor = .clear
        inputField.focusRingType = .none
        inputField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        inputField.usesSingleLineMode = true
        inputField.cell?.isScrollable = true
        inputField.placeholderString = String(localized: "commandBar.placeholder")
        inputField.delegate = self

        toggleButton.bezelStyle = .recessed
        toggleButton.isBordered = false
        toggleButton.controlSize = .small
        toggleButton.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        toggleButton.target = self
        toggleButton.action = #selector(toggleConsoleAction(_:))

        console.isEditable = false
        console.isSelectable = true
        console.drawsBackground = true
        console.backgroundColor = NSColor.textBackgroundColor
        console.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        console.autoresizingMask = [.width]
        console.isVerticallyResizable = true
        console.textContainer?.widthTracksTextView = true

        consoleScroll.documentView = console
        consoleScroll.hasVerticalScroller = true
        consoleScroll.borderType = .lineBorder
        consoleScroll.translatesAutoresizingMaskIntoConstraints = false
        consoleScroll.isHidden = true

        let inputRow = NSStackView(views: [promptLabel, inputField, toggleButton])
        inputRow.orientation = .horizontal
        inputRow.alignment = .firstBaseline
        inputRow.spacing = 6
        inputRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [inputRow, consoleScroll])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            consoleScroll.heightAnchor.constraint(equalToConstant: 130),
        ])

        // The input line owns keyboard focus on activation; the bar itself is
        // not a first-responder surface.
        wantsLayer = true
    }

    // MARK: Public surface (App driver)

    /// Current typed text (the Esc driver decides clear-or-collapse).
    public var inputText: String { inputField.stringValue }

    public func clearInput() {
        inputField.stringValue = ""
    }

    /// ⌘L contract: the bar shows up (already in the layout) and takes focus.
    public func focusInput() {
        window?.makeFirstResponder(inputField)
    }

    /// Prompt over the active panel's directory (driver updates on changes).
    public func updatePrompt(displayPath: String) {
        promptLabel.stringValue = String(localized: "commandBar.prompt \(displayPath)")
    }

    /// Appends one block to the mini console; the console opens itself.
    public func appendOutput(_ text: String, isError: Bool = false) {
        consoleScroll.isHidden = false
        toggleButton.title = "⌃"
        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: isError ? NSColor.systemRed : NSColor.secondaryLabelColor,
            ]
        )
        console.textStorage?.append(attributedText)
        console.textStorage?.append(NSAttributedString(string: "\n"))
        trimConsole()
        console.scrollRangeToVisible(NSRange(location: (console.string as NSString).length, length: 0))
    }

    public func clearOutput() {
        console.string = ""
        consoleScroll.isHidden = true
        toggleButton.title = "⌃"
    }

    @objc private func toggleConsoleAction(_ sender: NSButton) {
        consoleScroll.isHidden.toggle()
        toggleButton.title = consoleScroll.isHidden ? "⌃" : "⌄"
    }

    private func trimConsole(cap: Int = 1000) {
        let lines = console.string.components(separatedBy: "\n")
        guard lines.count > cap else { return }
        console.string = lines.suffix(cap).joined(separator: "\n")
    }
}

extension CommandBarView: NSTextFieldDelegate {
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:))
            || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            submit()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:))
            || commandSelector == #selector(NSResponder.complete(_:)) {
            onEscape?()
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            let entry = history.up()
            if let entry { control.stringValue = entry }
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            let entry = history.down(control.stringValue)
            if let entry { control.stringValue = entry }
            return true
        }
        return false
    }

    private func submit() {
        let raw = inputField.stringValue
        history.record(raw)
        inputField.stringValue = ""
        onSubmit?(raw)
    }
}
