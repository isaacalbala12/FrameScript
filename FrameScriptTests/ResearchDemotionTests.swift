import XCTest
@testable import FrameScript

/// «La casilla manda»: demoting a confirmed claim makes it unverified again,
/// so it returns to every pending list.
@MainActor
final class ResearchDemotionTests: XCTestCase {
    func testDemotingAConfirmedClaimTicksVerificationAgain() throws {
        let harness = try BoardTestHarness()
        addTeardownBlock { harness.tearDown() }
        let appState = harness.appState
        let claim = appState.addResearchClaim(text: "Dato degradado", status: .probable)
        appState.setResearchClaimStatus(id: claim.id, status: .confirmed)
        XCTAssertFalse(appState.project.claims.first { $0.id == claim.id }!.needsVerification)
        appState.setResearchClaimStatus(id: claim.id, status: .rumor)
        let after = appState.project.claims.first { $0.id == claim.id }!
        XCTAssertTrue(after.needsVerification)
        XCTAssertTrue(after.needsResearch)
        XCTAssertEqual(appState.researchCounts().pending, 1)
    }

    func testDemotingThroughUpdateAlsoTicksVerification() throws {
        let harness = try BoardTestHarness()
        addTeardownBlock { harness.tearDown() }
        let appState = harness.appState
        let claim = appState.addResearchClaim(text: "Otro dato", status: .probable)
        appState.setResearchClaimStatus(id: claim.id, status: .confirmed)
        var edited = appState.project.claims.first { $0.id == claim.id }!
        edited.status = .communityOpinion
        appState.updateResearchClaim(edited)
        XCTAssertTrue(appState.project.claims.first { $0.id == claim.id }!.needsVerification)
    }

    func testUntickingANonConfirmedClaimStillAcceptsIt() throws {
        let harness = try BoardTestHarness()
        addTeardownBlock { harness.tearDown() }
        let appState = harness.appState
        let claim = appState.addResearchClaim(text: "Rumor aceptado", status: .rumor)
        appState.toggleResearchClaimVerification(id: claim.id)
        XCTAssertEqual(appState.researchCounts().pending, 0)
    }
}
