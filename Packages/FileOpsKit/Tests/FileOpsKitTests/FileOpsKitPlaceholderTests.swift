import Testing
@testable import FileOpsKit

@Test func moduleMarker() {
    #expect(FileOpsKitBuildInfo.moduleName == "FileOpsKit")
}
