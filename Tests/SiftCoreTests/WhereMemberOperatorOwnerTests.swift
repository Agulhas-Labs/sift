//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A member operator's sites by written name are any type's, since an applied operator writes no receiver: the count says so, and every site stays listed.
@Suite(.temporaryDirectories)
struct WhereMemberOperatorOwnerTests {
    /// The heading clause a member `+` of `Vault` carries.
    static var anyTypes: String {
        "any type's +, as an applied operator writes no receiver to tell Vault's apart"
    }

    /// `Vault.+`, asked by its owner, says its sites are any type's, and still lists an `Int` sum, which the scan cannot tell from a use.
    @Test
    func aQualifiedMemberOperatorsSitesAreSaidToBeAnyTypes() async throws {
        let plus = try await WhereOperatorUseTests.answer("Vault.+")

        #expect(plus.contains("\"+\" (4 call sites by name, \(Self.anyTypes), in 1 file):"), "\(plus)")
        #expect(plus.contains("    :2  in stock(_:).sum  | let sum = vault + vault"), "\(plus)")
        #expect(plus.contains("    :6 (×2)  in stock(_:)  | return (sum <~> flipped) + squared.weight + all.weight"), "\(plus)")
    }

    /// A bare `+` that one type alone declares is that type's member too, so its sites carry the same clause.
    @Test
    func aBareMemberOperatorsSitesAreSaidToBeAnyTypes() async throws {
        let plus = try await WhereOperatorUseTests.answer("+")

        #expect(plus.contains(Self.anyTypes), "\(plus)")
    }

    /// An operator declared outside every type has no owner to tell apart, so its heading is as before.
    @Test
    func aFreeOperatorsSitesCarryNoOwnerClause() async throws {
        let custom = try await WhereOperatorUseTests.answer("<~>")

        #expect(custom.contains("\"<~>\" (1 call site in 1 file — for both):"), "\(custom)")
        #expect(!custom.contains("any type's"), "\(custom)")
    }
}
