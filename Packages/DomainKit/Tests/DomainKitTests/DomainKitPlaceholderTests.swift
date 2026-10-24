import Testing
@testable import DomainKit

@Test func moduleMarker() {
    #expect(DomainKitBuildInfo.moduleName == "DomainKit")
}
