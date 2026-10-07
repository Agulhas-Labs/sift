//
// Copyright © Agulhas Labs
//

extension Result where Failure == any Error {
    /// A result caught from an asynchronous body, as `Result(catching:)` catches one from a synchronous body.
    init(_ body: () async throws -> Success) async {
        do {
            self = try await .success(body())
        } catch {
            self = .failure(error)
        }
    }
}
