import Testing
@testable import VFSKit

@Test func moduleMarker() {
    #expect(VFSKitBuildInfo.moduleName == "VFSKit")
}
