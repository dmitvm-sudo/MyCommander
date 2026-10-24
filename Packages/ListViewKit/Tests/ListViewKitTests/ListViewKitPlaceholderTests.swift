import Testing
@testable import ListViewKit

@Test func moduleMarker() {
    #expect(ListViewKitBuildInfo.moduleName == "ListViewKit")
}
