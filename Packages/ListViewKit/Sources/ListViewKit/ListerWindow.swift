// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import FileOpsKit
import Foundation

// Contract: docs/SDD/06 §6.7 v1 (T-13) — Lister-lite (F-8): streamed window
// reads over a `ListerByteSource`, text (UTF-8/16 auto-detect) / hex (⌃H) /
// image modes, PageUp/Down + Space/⇧Space, ⌃Home/⌃End jumps, position status.
// Quick Look (F-9) and the F4 editor flow live in App on top of
// `PreviewMaterializer` (FileOpsKit).

// MARK: - Modes and encodings

/// Display mode (§6.7 «text / hex / image»).
public enum ListerMode: Sendable, Equatable {
    case text
    case hex
    case image

    /// Auto-choice: declared image extensions → image; a NUL byte in the
    /// sample (first 4 KB) → binary → hex; otherwise text.
    public static func automatic(name: String, sample: Data) -> ListerMode {
        let ext = ((name as NSString).pathExtension as String).lowercased()
        if Self.imageExtensions.contains(ext) { return .image }
        if bytes(of: sample).contains(0) { return .hex }
        return .text
    }

    static let imageExtensions: Set<String> = [
        "bmp", "gif", "heic", "jpeg", "jpg", "png", "tif", "tiff", "webp"
    ]

    private static func bytes(of data: Data) -> [UInt8] {
        [UInt8](data)
    }
}

/// Text encoding (§6.7 «кодировка авто: UTF-8/16»).
public enum ListerEncoding: String, Sendable, Equatable, CaseIterable {
    case utf8
    case utf16LE
    case utf16BE

    /// BOM first; then structural UTF-16 suspicion (text without BOM), then
    /// the null-parity check (Latin UTF-16 keeps zeros on one side), then
    /// strict UTF-8 validity. Everything else falls back lossily to UTF-8.
    public static func detect(sample: Data) -> ListerEncoding {
        let bytes = [UInt8](sample)
        if bytes.first == 0xFF, bytes.count > 1, bytes[1] == 0xFE { return .utf16LE }
        if bytes.first == 0xFE, bytes.count > 1, bytes[1] == 0xFF { return .utf16BE }
        if bytes.first == 0xEF, bytes.count > 2, bytes[1] == 0xBB, bytes[2] == 0xBF { return .utf8 }

        // Structural UTF-16: byte pairs with a fixed control-zoned «high» side
        // (Cyrillic zones 0x04xx, Latin 0x00xx) betray UTF-16 without BOM —
        // such samples are usually still *valid* UTF-8 (control code points).
        var pairs = 0
        var oddControl = 0
        var evenControl = 0
        var oddZero = 0
        var evenZero = 0
        var index = 0
        while index + 1 < bytes.count {
            let low = bytes[index]
            let high = bytes[index + 1]
            if high <= 0x1F { oddControl += 1 }
            if low <= 0x1F { evenControl += 1 }
            if high == 0 { oddZero += 1 }
            if low == 0 { evenZero += 1 }
            pairs += 1
            index += 2
        }
        if pairs > 2 {
            let n = Double(pairs)
            if Double(oddControl) / n >= 0.75, Double(evenControl) / n <= 0.05 { return .utf16LE }
            if Double(evenControl) / n >= 0.75, Double(oddControl) / n <= 0.05 { return .utf16BE }
            if Double(oddZero) / n >= 0.4, Double(evenZero) / n <= 0.05 { return .utf16LE }
            if Double(evenZero) / n >= 0.4, Double(oddZero) / n <= 0.05 { return .utf16BE }
        }

        let strictUTF8 = String(bytes: bytes, encoding: .utf8) != nil
        if strictUTF8 { return .utf8 }
        return .utf8
    }

    /// Stable display label for the status line (not localized — encoding names).
    public var label: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        }
    }
}

// MARK: - Codec (pure, testable)

/// One decoded text window (F-8: файлы «без newline» и границы символов).
public struct ListerTextPage: Sendable, Equatable {
    public let text: String
    /// Absolute byte offset where the next window continues (char-aligned).
    public let nextOffset: Int64
}

public enum ListerCodec {
    /// Decodes a raw window into a displayable text page. A page never
    /// starts/ends mid-character: mid-char leading bytes are skipped (they
    /// belong to the character opened by the previous window), an incomplete
    /// trailing char is trimmed away (re-read with the next window).
    public static func decodeTextPage(
        _ raw: Data,
        offset: Int64,
        encoding: ListerEncoding
    ) -> ListerTextPage {
        let units = [UInt8](raw)
        var start = 0
        var end = units.count

        // Strip the BOM of the very first window (it is metadata, not content).
        if offset == 0 {
            let bom: [UInt8] = switch encoding {
            case .utf8: [0xEF, 0xBB, 0xBF]
            case .utf16LE: [0xFF, 0xFE]
            case .utf16BE: [0xFE, 0xFF]
            }
            if units.count >= bom.count, Array(units[..<bom.count]) == bom {
                start = bom.count
            }
        }

        switch encoding {
        case .utf8:
            while start < end, (units[start] & 0b1100_0000) == 0b1000_0000 { start += 1 }
            // Trim an incomplete trailing char: walk back through continuation
            // bytes, check whether the lead byte's declared length is complete.
            var continuations = 0
            while end - continuations - 1 >= start, (units[end - continuations - 1] & 0b1100_0000) == 0b1000_0000 {
                continuations += 1
            }
            let leadIndex = end - continuations - 1
            if leadIndex >= start {
                if let declared = utf8LeadLength(units[leadIndex]), declared > continuations + 1 {
                    end = leadIndex
                }
            }
        case .utf16LE, .utf16BE:
            // Alignment is even within the FILE (the page offset decides which
            // side of an odd boundary the window starts on).
            while start < end, (offset + Int64(start)) % 2 != 0 { start += 1 }
            if (end - start) % 2 != 0 { end -= 1 }
            // A window-final high surrogate whose low half lives in the next
            // window is re-read there (not consumed here).
            if end - start >= 2 {
                let bigEndian = encoding == .utf16BE
                let tail = utf16Unit(units[end - 2], units[end - 1], bigEndian: bigEndian)
                if tail >= 0xD800 && tail <= 0xDBFF { end -= 2 }
            }
        }

        let slice = Array(units[start ..< end])
        let text: String
        switch encoding {
        case .utf8:
            text = String(bytes: slice, encoding: .utf8) ?? String(decoding: slice, as: UTF8.self)
        case .utf16LE:
            text = utf16String(slice, bigEndian: false)
        case .utf16BE:
            text = utf16String(slice, bigEndian: true)
        }
        return ListerTextPage(text: text, nextOffset: offset + Int64(end))
    }

    private static func utf8LeadLength(_ lead: UInt8) -> Int? {
        switch lead {
        case 0x00 ... 0x7F: return 1
        case 0xC0 ... 0xDF: return 2
        case 0xE0 ... 0xEF: return 3
        case 0xF0 ... 0xF7: return 4
        default: return nil
        }
    }

    private static func utf16String(_ bytes: [UInt8], bigEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = bytes.startIndex
        while index + 1 < bytes.endIndex {
            units.append(utf16Unit(bytes[index], bytes[index + 1], bigEndian: bigEndian))
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func utf16Unit(_ first: UInt8, _ second: UInt8, bigEndian: Bool) -> UInt16 {
        bigEndian ? (UInt16(first) << 8) | UInt16(second) : (UInt16(second) << 8) | UInt16(first)
    }

    /// Hex window (§6.7 «колонки offset/hex/ascii», 16 bytes per row).
    public static func hexPage(_ raw: Data, offset: Int64) -> String {
        let bytes = [UInt8](raw)
        guard !bytes.isEmpty else { return "" }
        var lines: [String] = []
        lines.reserveCapacity(bytes.count / 16 + 1)
        var index = 0
        while index < bytes.count {
            let row = Array(bytes[index ..< min(index + 16, bytes.count)])
            var line = paddedHex(UInt64(bitPattern: offset + Int64(index)), width: 8)
            line += "  "
            for columnIndex in 0 ..< 16 {
                if columnIndex > 0 { line += " " }
                line += columnIndex < row.count ? paddedHex(UInt64(row[columnIndex]), width: 2) : ".."
            }
            line += "  "
            for byte in row {
                line += byte >= 0x20 && byte <= 0x7E ? String(UnicodeScalar(byte)) : "·"
            }
            lines.append(line)
            index += row.count
        }
        return lines.joined(separator: "\n")
    }

    private static func paddedHex(_ value: UInt64, width: Int) -> String {
        let raw = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, width - raw.count)) + raw
    }
}

// MARK: - Keys (pure classifier, PanelKeys-style)

public enum ListerKeyCommand: Equatable {
    case pageDown
    case pageUp
    case toggleHex
    case jumpToStart
    case jumpToEnd
    /// Not a Lister command — AppKit continues.
    case passToSuper
}

public enum ListerKeys {
    private static let pageUpKeyCode: UInt16 = 116
    private static let pageDownKeyCode: UInt16 = 121
    private static let homeKeyCode: UInt16 = 115
    private static let endKeyCode: UInt16 = 119
    private static let spaceKeyCode: UInt16 = 49   // §6.7: Space/⇧Space page

    static func classify(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String?
    ) -> ListerKeyCommand {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        switch keyCode {
        case pageDownKeyCode:
            return modifiers == [.control] ? .jumpToEnd : .pageDown
        case pageUpKeyCode:
            return modifiers == [.control] ? .jumpToStart : .pageUp
        case spaceKeyCode:
            return modifiers.isEmpty ? .pageDown : (modifiers == .shift ? .pageUp : .passToSuper)
        case homeKeyCode:
            return modifiers.subtracting(.shift).isEmpty ? .jumpToStart : .passToSuper
        case endKeyCode:
            return modifiers.subtracting(.shift).isEmpty ? .jumpToEnd : .passToSuper
        default:
            if modifiers == .control, characters?.lowercased() == "h" { return .toggleHex }
            return .passToSuper
        }
    }
}

// MARK: - Model (main-actor paging over the byte source)

@MainActor
public final class ListerModel {
    public let name: String
    public let source: ListerByteSource
    public let stride: Int64
    /// Materialized URL for image mode (nil for text/hex/image-less sources).
    public let imageURL: URL?
    public private(set) var mode: ListerMode
    public private(set) var encoding: ListerEncoding?
    public private(set) var pageIndex: Int64 = 0
    public private(set) var text: String = ""
    public private(set) var loadFailed = false
    /// View hook (the window refreshes on every model update).
    public var onUpdated: (@MainActor () -> Void)?

    /// Text window (256 KB) keeps «одна строка размером с окно» renderable —
    /// hex windows are smaller per design; the image file is a single page.
    static let textStride: Int64 = 256 * 1024
    static let hexStride: Int64 = 64 * 1024

    init(
        name: String,
        source: ListerByteSource,
        mode: ListerMode,
        encoding: ListerEncoding?,
        imageURL: URL?,
        strideOverride: Int64? = nil
    ) {
        self.name = name
        self.source = source
        self.mode = mode
        self.encoding = encoding
        self.imageURL = imageURL
        switch mode {
        case .text: self.stride = strideOverride ?? Self.textStride
        case .hex: self.stride = strideOverride ?? Self.hexStride
        case .image: self.stride = max(source.totalSize, 1)
        }
    }

    public var pageCount: Int64 {
        max(1, (source.totalSize + stride - 1) / stride)
    }

    /// Absolute byte offset of the current window's start.
    public var positionBytes: Int64 { pageIndex * stride }

    public func loadFirstPage() async {
        await reload(index: pageIndex)
    }

    public func pageDown() async {
        await reload(index: pageIndex + 1)
    }

    public func pageUp() async {
        await reload(index: pageIndex - 1)
    }

    public func jumpToEnd() async {
        await reload(index: pageCount - 1)
    }

    public func jumpToStart() async {
        await reload(index: 0)
    }

    public func jump(toPage index: Int64) async {
        await reload(index: index)
    }

    /// ⌃H (§6.7): hex ↔ previous mode, keeping the byte position.
    public func toggleHex() async {
        let wasHex = mode == .hex
        // Encoding stays for the return trip; hex reuses the same offsets.
        let savedEncoding = savedTextEncoding
        mode = wasHex ? (savedEncoding == nil ? .hex : .text) : .hex
        if !wasHex { savedTextEncoding = encoding } else { encoding = savedEncoding }
        await reload(index: pageIndex)
    }

    private var savedTextEncoding: ListerEncoding?

    private func reload(index: Int64) async {
        if mode != .image {
            let clamped = min(max(index, 0), pageCount - 1)
            let windowOffset = clamped * stride
            do {
                let data = try await source.read(windowOffset, stride)
                switch mode {
                case .text:
                    text = ListerCodec.decodeTextPage(data, offset: windowOffset, encoding: encoding ?? .utf8).text
                case .hex:
                    text = ListerCodec.hexPage(data, offset: windowOffset)
                case .image:
                    break
                }
                pageIndex = clamped
                loadFailed = false
            } catch {
                loadFailed = true
            }
        }
        onUpdated?()
    }
}

/// Opens a Lister model: auto-mode sniff (first 4 KB), encoding detect for
/// text, windowing strides per mode.
@MainActor
public enum ListerBootstrap {
    /// `imageURL` provider is called only when the sniffed mode is image.
    public static func open(
        name: String,
        source: ListerByteSource,
        imageURL: @escaping @Sendable () async -> URL?
    ) async -> ListerModel {
        let sampleSize = min(4096, source.totalSize)
        let sample = (try? await source.read(0, sampleSize)) ?? Data()
        let mode = ListerMode.automatic(name: name, sample: sample)

        switch mode {
        case .image:
            let prepared = await imageURL()
            if prepared != nil {
                let model = ListerModel(name: name, source: source, mode: .image, encoding: nil, imageURL: prepared)
                await model.loadFirstPage()
                return model
            }
            // Unreadable image data — fall through to hex (binary content).
            let model = ListerModel(name: name, source: source, mode: .hex, encoding: nil, imageURL: nil)
            await model.loadFirstPage()
            return model
        case .text:
            let encoding = ListerEncoding.detect(sample: sample)
            let model = ListerModel(name: name, source: source, mode: .text, encoding: encoding, imageURL: nil)
            await model.loadFirstPage()
            return model
        case .hex:
            let model = ListerModel(name: name, source: source, mode: .hex, encoding: nil, imageURL: nil)
            await model.loadFirstPage()
            return model
        }
    }
}

// MARK: - Window

/// Text area that classifies keystrokes through `ListerKeys`.
@MainActor
final class ListerTextView: NSTextView {
    var onCommand: (@MainActor (ListerKeyCommand) -> Void)?

    override func keyDown(with event: NSEvent) {
        let command = ListerKeys.classify(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            characters: event.characters
        )
        switch command {
        case .passToSuper:
            super.keyDown(with: event)
        default:
            onCommand?(command)
        }
    }
}

/// The Lister window (F-8): text/hex view + image pane + slider/status row.
/// Non-blocking (F-5 background semantics): the panel keeps working while it
/// is open; a second F3 call replaces the content (`reset(to:)`).
@MainActor
public final class ListerWindowController: NSWindowController {
    private var model: ListerModel
    private let textView: ListerTextView
    private let imageView: NSImageView
    private let statusLine: NSTextField
    private let slider: NSSlider

    public init(model: ListerModel) {
        self.model = model
        let textView = ListerTextView(frame: NSRect(x: 0, y: 0, width: 780, height: 540))
        self.textView = textView
        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 780, height: 540))
        self.imageView = imageView
        let statusLine = NSTextField(labelWithString: "")
        self.statusLine = statusLine
        let slider = NSSlider(value: 0, minValue: 0, maxValue: 0, target: nil, action: nil)
        self.slider = slider

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "lister.title \(model.name)")
        super.init(window: window)

        textView.isEditable = false
        textView.isRichText = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        slider.target = self
        slider.action = #selector(sliderChanged(_:))

        let controlsRow = NSStackView(views: [slider, statusLine])
        controlsRow.orientation = .horizontal
        controlsRow.spacing = 10
        let stack = NSStackView(views: [scroll, imageView, controlsRow])
        stack.orientation = .vertical
        imageView.isHidden = true
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -8),
            scroll.widthAnchor.constraint(equalTo: imageView.widthAnchor),
            scroll.heightAnchor.constraint(equalTo: imageView.heightAnchor)
        ])

        textView.onCommand = { [weak self] command in
            Task { [weak self] in
                await self?.handle(command)
            }
        }
        bind(to: model)
    }

    required init?(coder: NSCoder) {
        fatalError("ListerWindowController is created programmatically only")
    }

    /// Replaces the content (a second F3 call): the window stays reusable.
    public func reset(to model: ListerModel) {
        bind(to: model)
        window?.title = String(localized: "lister.title \(model.name)")
    }

    /// Brings the (already created) window to front.
    public func activate() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func bind(to model: ListerModel) {
        self.model = model
        model.onUpdated = { [weak self] in
            self?.refresh()
        }
        slider.maxValue = Double(max(0, model.pageCount - 1))
        slider.doubleValue = Double(min(model.pageIndex, model.pageCount - 1))
        slider.isHidden = model.mode == .image
        imageView.isHidden = model.mode != .image
        refresh()
    }

    private func refresh() {
        if model.mode == .image {
            if let imageURL = model.imageURL, imageView.image === nil {
                imageView.image = NSImage(contentsOf: imageURL)
            }
        } else {
            imageView.image = nil
            textView.string = model.loadFailed ? String(localized: "lister.error") : model.text
        }
        slider.doubleValue = Double(min(model.pageIndex, model.pageCount - 1))

        let position = ByteCountFormatter.string(fromByteCount: model.positionBytes, countStyle: .memory)
        let total = ByteCountFormatter.string(fromByteCount: model.source.totalSize, countStyle: .memory)
        let modeLabel = switch model.mode {
        case .text: String(localized: "lister.mode.text")
        case .hex: String(localized: "lister.mode.hex")
        case .image: String(localized: "lister.mode.image")
        }
        statusLine.stringValue = model.loadFailed
            ? String(localized: "lister.error")
            : String(localized: "lister.status \(position) \(total) \(modeLabel)")
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let page = Int64(sender.intValue)
        Task { [weak self] in
            await self?.model.jump(toPage: page)
        }
    }

    private func handle(_ command: ListerKeyCommand) async {
        switch command {
        case .pageDown: await model.pageDown()
        case .pageUp: await model.pageUp()
        case .jumpToStart: await model.jumpToStart()
        case .jumpToEnd: await model.jumpToEnd()
        case .toggleHex: await model.toggleHex()
        case .passToSuper: break
        }
    }
}
