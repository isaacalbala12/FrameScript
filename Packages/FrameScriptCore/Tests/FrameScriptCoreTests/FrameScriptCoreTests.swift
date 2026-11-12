import Testing
@testable import FrameScriptCore

@Test func coreVersionIsSet() {
    #expect(!FrameScriptCore.version.isEmpty)
}
