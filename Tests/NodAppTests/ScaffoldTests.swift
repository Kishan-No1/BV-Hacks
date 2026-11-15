// OWNER: workstream C (app-ui).
import Testing
@testable import Nod

@Test func appTargetIsTestable() {
    #expect(!NodMain.version.isEmpty)
}
