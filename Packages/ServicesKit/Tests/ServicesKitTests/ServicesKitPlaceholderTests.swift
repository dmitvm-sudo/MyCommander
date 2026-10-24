import Testing
@testable import ServicesKit

@Test func moduleMarker() {
    #expect(ServicesKitBuildInfo.moduleName == "ServicesKit")
}
