//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A test that makes a `RunIndexState` without a registry reads none of this machine's, so its answers do not change with what the machine has registered.
@Suite(.hermeticIndexes)
struct HermeticIndexesTests {
    @Test
    func aStateMadeWithoutARegistryInAHermeticSuiteSeesNoRoots() {
        #expect(RunIndexState().registeredRoots.isEmpty)
    }

    private static let bound: @Sendable () -> [String] = { ["/depot/orchard"] }

    @Test
    func aStateTakesTheRegistryBoundWhereItWasMade() {
        let roots = RunIndexState.$scopedRegistry.withValue(Self.bound) { RunIndexState().registeredRoots }

        #expect(roots == ["/depot/orchard"])
    }

    @Test
    func aRegistryOfItsOwnBeatsTheOneBoundForTheScope() {
        let roots = RunIndexState.$scopedRegistry.withValue(Self.bound) { RunIndexState(registry: { ["/depot/gizmo"] }).registeredRoots }

        #expect(roots == ["/depot/gizmo"])
    }

    @Test
    func theRegistryBoundForTheScopeReachesTheThreadOutsideThePool() async {
        let roots = await RunIndexState.$scopedRegistry.withValue(Self.bound) {
            await InPlaceAnswerTests.onItsOwnThread { RunIndexState().registeredRoots }
        }

        #expect(roots == ["/depot/orchard"])
    }
}
