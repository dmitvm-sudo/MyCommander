import Testing
@testable import TerminalKit

@Test func moduleMarker() {
    #expect(TerminalKitBuildInfo.moduleName == "TerminalKit")
}
