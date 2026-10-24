import Testing
@testable import EnginesKit

@Test func moduleMarker() {
    #expect(EnginesKitBuildInfo.moduleName == "EnginesKit")
}
