// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import DomainKit

private let testInstance = VFSInstanceID(kind: .localDisk, specID: "test-volume")

@Test func dotDotPopsPreviousSegment() {
    let path = VFSPath.local(URL(fileURLWithPath: "/a/b/../c"))
    #expect(path.components == ["a", "c"])
}

@Test func duplicateSeparatorsAndDotsAreDropped() {
    let path = VFSPath.local(URL(fileURLWithPath: "/a//./b"))
    #expect(path.components == ["a", "b"])
}

@Test func dotDotClampsAtRoot() {
    #expect(VFSPath.normalizedComponents(from: URL(fileURLWithPath: "/../x")) == ["x"])
    #expect(VFSPath.normalizedComponents(from: URL(fileURLWithPath: "/a/..")) == [])
    #expect(VFSPath.normalizedComponents(from: URL(fileURLWithPath: "/")) == [])
}

@Test func nfcAndNfdSpellingsNormalizeToIdenticalComponents() {
    let nfc = "\u{00E9}"          // precomposed é
    let nfd = "e\u{0301}"         // e + combining acute
    let pathNFC = VFSPath.local(URL(fileURLWithPath: "/dir/\(nfc).txt"))
    let pathNFD = VFSPath.local(URL(fileURLWithPath: "/dir/\(nfd).txt"))
    #expect(pathNFD.components == ["dir", "\(nfc).txt"])
    #expect(pathNFC.components == pathNFD.components)
}

@Test func nfcAndNfdPathsAreEqualForTheSameDisplayURL() {
    let display = URL(fileURLWithPath: "/dir")
    let composed = VFSPath(root: testInstance, components: ["\u{00E9}.txt"], displayURL: display)
    let decomposed = VFSPath(root: testInstance, components: ["e\u{0301}.txt"], displayURL: display)
    #expect(composed == decomposed)
    #expect(composed.hashValue == decomposed.hashValue)
}

@Test func localPathCarriesRootAndDisplayURL() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let path = VFSPath.local(directory)
    #expect(path.root.kind == .localDisk)
    #expect(!path.root.specID.isEmpty)
    #expect(path.displayURL == directory)
    #expect(path.components.isEmpty == (directory.path == "/" || directory.pathComponents == ["/"]))
}
