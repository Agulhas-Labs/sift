//
// Copyright © Agulhas Labs
//

import Foundation

/// What step of a `DurableFile.replace` failed, so a caller can report it the way its own errors read.
enum DurableFileError: Error {
    /// The temporary file could not be created.
    case create(temporary: String)
    /// The rename into place failed, with the system's reason.
    case rename(temporary: String, reason: String)
}
