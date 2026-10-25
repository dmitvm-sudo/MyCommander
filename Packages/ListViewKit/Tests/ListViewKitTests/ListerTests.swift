// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import FileOpsKit
import Foundation
import Testing
import DomainKit
@testable import ListViewKit

// T-13: Lister-lite (F-8) — auto modes, encoding detection, windowed text
// decoding (boundary-safe pages, no-newline files), hex grid, key classifier
// and the paging model. Helpers use the `lw` name-space (the test module
// compiles neighbouring files together).

private func lwPatternText(_ count: Int) -> Data {
    Data("αβγδ".utf8) + Data("Hello, мир — файлы без newline".utf8) + Data((0 ..< count).map { UInt8(0x30 + ($0 % 10)) })
}

private func lwUTF16Bytes(_ text: String, bigEndian: Bool, bom: Bool) -> Data {
    var bytes: [UInt8] = []
    if bom {
        bytes += bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]
    }
    for unit in text.utf16 {
        let high = UInt8(truncatingIfNeeded: unit >> 8)
        let low = UInt8(truncatingIfNeeded: unit)
        bytes += bigEndian ? [high, low] : [low, high]
    }
    return Data(bytes)
}

@Test func lwAutomaticModes() {
    #expect(ListerMode.automatic(name: "photo.PNG", sample: Data("fff".utf8)) == .image)
    #expect(ListerMode.automatic(name: "blob.bin", sample: Data([0x10, 0x00, 0x41])) == .hex)
    #expect(ListerMode.automatic(name: "readme.md", sample: Data("plain text".utf8)) == .text)
    #expect(ListerMode.automatic(name: "no-extension", sample: Data()) == .text)
}

@Test func lwEncodingDetect() {
    let le = Data([0xFF, 0xFE, 0x41, 0x00])
    #expect(ListerEncoding.detect(sample: le) == .utf16LE)
    let be = Data([0xFE, 0xFF, 0x00, 0x41])
    #expect(ListerEncoding.detect(sample: be) == .utf16BE)
    #expect(ListerEncoding.detect(sample: Data([0xEF, 0xBB, 0xBF]) + Data("ok".utf8)) == .utf8)
    #expect(ListerEncoding.detect(sample: Data("ascii text".utf8)) == .utf8)

    // UTF-16 text without BOM: zeros stack on one side of the pairs.
    #expect(ListerEncoding.detect(sample: lwUTF16Bytes("привет мир", bigEndian: false, bom: false)) == .utf16LE)
    #expect(ListerEncoding.detect(sample: lwUTF16Bytes("привет мир", bigEndian: true, bom: false)) == .utf16BE)
}

@Test func lwDecodeUTF8PagesAtCharBoundaries() {
    let content = Data("αβγδ".utf8)   // each α is 2 bytes
    // A window that ends mid-char trims the incomplete char away.
    let page1 = ListerCodec.decodeTextPage(content.prefix(7), offset: 0, encoding: .utf8)
    #expect(page1.text == "αβγ" as String)   // 6 complete bytes
    #expect(page1.nextOffset == 6)           // the stray δ lead byte is re-read

    // The follow-up window starts exactly at the δ lead byte.
    let suffix = content.subdata(in: 6 ..< content.count)
    let page2 = ListerCodec.decodeTextPage(suffix, offset: 6, encoding: .utf8)
    #expect(page2.text == "δ" as String)
    #expect(page2.nextOffset == Int64(content.count))
}

@Test func lwDecodeUTF8NoNewlineStitched() {
    // Long one-line file: windows join back into the original text.
    let text = String(repeating: "0123456789", count: 5000)   // 50_000 bytes, no newline
    let content = Data(text.utf8)
    var stitched = ""
    var offset: Int64 = 0
    let windowStride: Int64 = 100
    while offset < Int64(content.count) {
        let upper = min(offset + windowStride, Int64(content.count))
        let page = ListerCodec.decodeTextPage(content.subdata(in: Int(offset) ..< Int(upper)), offset: offset, encoding: .utf8)
        #expect(page.nextOffset > offset, "windows must make progress")
        offset = page.nextOffset
        stitched += page.text
    }
    #expect(stitched == text)
}

@Test func lwDecodeUTF16WithAlignment() throws {
    let text = "Привет, мир без newline"
    let content = lwUTF16Bytes(text, bigEndian: false, bom: false)

    let page = ListerCodec.decodeTextPage(content, offset: 0, encoding: .utf16LE)
    #expect(page.text == text)
    #expect(page.nextOffset == Int64(content.count))

    // Window split inside a multi-unit char (emoji needs a surrogate pair):
    let pair = "🚀"
    let pairBytes = lwUTF16Bytes(pair, bigEndian: false, bom: false)   // 4 bytes
    let first = ListerCodec.decodeTextPage(pairBytes.prefix(2), offset: 0, encoding: .utf16LE)
    #expect(first.nextOffset == 0)                                    // high surrogate re-read
    let second = ListerCodec.decodeTextPage(pairBytes, offset: 0, encoding: .utf16LE)
    #expect(second.text == pair)

    let beBytes = lwUTF16Bytes(text, bigEndian: true, bom: false)
    let bePage = ListerCodec.decodeTextPage(beBytes, offset: 0, encoding: .utf16BE)
    #expect(bePage.text == text)

    let beBOM = lwUTF16Bytes(text, bigEndian: true, bom: true)
    let beBOMPage = ListerCodec.decodeTextPage(beBOM, offset: 0, encoding: .utf16BE)
    #expect(beBOMPage.text == text)
    #expect(beBOMPage.nextOffset == Int64(beBOM.count))
}

@Test func lwHexPageGrid() {
    let bytes = Data([0x41, 0x42, 0x0A])
    let page = ListerCodec.hexPage(bytes, offset: 4096)
    #expect(page == "00001000  41 42 0A .. .. .. .. .. .. .. .. .. .. .. .. ..  AB·")
}

@Test func lwKeysClassify() {
    #expect(ListerKeys.classify(keyCode: 121, modifiers: [], characters: "\u{F72D}") == .pageDown)
    #expect(ListerKeys.classify(keyCode: 116, modifiers: [], characters: "") == .pageUp)
    #expect(ListerKeys.classify(keyCode: 121, modifiers: [.control], characters: "") == .jumpToEnd)
    #expect(ListerKeys.classify(keyCode: 116, modifiers: [.control], characters: "") == .jumpToStart)
    #expect(ListerKeys.classify(keyCode: 49, modifiers: [], characters: " ") == .pageDown)
    #expect(ListerKeys.classify(keyCode: 49, modifiers: [.shift], characters: " ") == .pageUp)
    #expect(ListerKeys.classify(keyCode: 4, modifiers: [.control], characters: "h") == .toggleHex)
    #expect(ListerKeys.classify(keyCode: 120, modifiers: [], characters: "") == .passToSuper)
}

@MainActor
@Test func lwModelPagingAndFailure() async throws {
    let content = Data((0 ..< 10_000).map { UInt8(0x40 + ($0 % 26)) })
    let total = Int64(content.count)
    func source() -> ListerByteSource {
        ListerByteSource(totalSize: total) { offset, length in
            let start = min(max(offset, 0), total)
            let end = min(start + max(length, 0), total)
            return content.subdata(in: Int(start) ..< Int(end))
        }
    }

    let model = ListerModel(
        name: "pages.txt",
        source: source(),
        mode: .text,
        encoding: .utf8,
        imageURL: nil,
        strideOverride: 1000
    )
    await model.pageDown()
    #expect(model.pageIndex == 1)
    #expect(model.positionBytes == 1000)
    #expect(model.text == String(decoding: content.subdata(in: 1000 ..< 2000), as: UTF8.self))
    await model.jumpToEnd()
    #expect(model.pageIndex == 9)
    await model.pageUp()
    #expect(model.pageIndex == 8)
    // Slider jumps clamp into range.
    await model.jump(toPage: 100)
    #expect(model.pageIndex == 9)
    await model.jumpToStart()
    #expect(model.pageIndex == 0)

    // Reader failure surfaces as the localized placeholder (not a crash).
    let failing = ListerModel(
        name: "fail.dat",
        source: ListerByteSource(totalSize: 500) { _, _ in
            struct Forced: Error {}
            throw Forced()
        },
        mode: .text,
        encoding: .utf8,
        imageURL: nil,
        strideOverride: 100
    )
    await failing.loadFirstPage()
    #expect(failing.loadFailed)
}

@MainActor
@Test func lwBootstrapAutoDecidesTextHexImageFallback() async throws {
    let plain = Data("журнал записи".utf8)
    let textModel = await ListerBootstrap.open(
        name: "заметка.txt",
        source: ListerByteSource(totalSize: Int64(plain.count)) { a, b in plain.subdata(in: Int(a) ..< min(Int(a + b), plain.count)) },
        imageURL: { nil }
    )
    #expect(textModel.mode == .text)
    #expect(textModel.encoding == .utf8)
    #expect(textModel.text == "журнал записи")

    let binary = Data([0x11, 0x00, 0x42] + Array(repeating: 0x61, count: 100))
    let hexModel = await ListerBootstrap.open(
        name: "raw.bin",
        source: ListerByteSource(totalSize: Int64(binary.count)) { a, b in binary.subdata(in: Int(a) ..< min(Int(a + b), binary.count)) },
        imageURL: { nil }
    )
    #expect(hexModel.mode == .hex)
    #expect(hexModel.text.contains("00"))

    // An image extension with an unreadable provider falls back to hex too.
    let imageModel = await ListerBootstrap.open(
        name: "shot.png",
        source: ListerByteSource(totalSize: 4) { _, _ in Data([0x89, 0x50, 0x4E, 0x47]) },
        imageURL: { nil }
    )
    #expect(imageModel.mode == .hex)
}
