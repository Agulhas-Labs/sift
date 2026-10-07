//
// Copyright © Agulhas Labs
//

import Foundation

/// The compiler and linker diagnostics a run's output states, in the order it printed them and each one once.
///
/// ``RunOutputFilter`` hands it every line no reader of a test's own output claimed. Most of what it reads is one line to one diagnostic; the rest is the lines that belong to a diagnostic without being one — the symbol list under an `Undefined symbols` header, the cause indented beneath a heading that ends in `:`, and the note naming the source line a macro expansion sits at.
struct RunDiagnosticRecord {
    /// How many indented lines beneath an error line ending in `:` are kept as its cause.
    ///
    /// A heading is not itself bounded — `xcodebuild` and SwiftPM cap nothing, so without a limit here a block that never closes (a runaway command dump wrongly read as a continuation) could grow without bound. Six is enough for every cause this filter has had to carry: the package-resolution failure this exists for is three lines.
    private static let colonContinuationCap = 6

    private(set) var errors: [RunDiagnostic] = []
    private(set) var warnings: [RunDiagnostic] = []
    private var seenErrors: Set<RunDiagnostic.Identity> = []
    private var seenWarnings: Set<RunDiagnostic.Identity> = []
    private var linkerBlock: [String] = []
    /// The index in ``errors`` of the most recently recorded error whose message ends in `:`, while its indented continuation is still arriving.
    ///
    /// A line ending in `:` is a heading — its message names only that resolution failed, and the reason is what a reader needs next. `xcodebuild` and SwiftPM both print that reason as further lines indented beneath the heading, so this is how they are folded into the same diagnostic's `detail` rather than dropped by ``RunDiagnostic/parse(_:)``, which reads an indented line as never a diagnostic header of its own.
    private var openColonError: Int?
    /// The most recently recorded diagnostic located in a macro expansion's buffer, while the compiler's note naming the source line the expansion sits at may still arrive — see ``recordExpansionSite(_:)``.
    private var openExpansion: (severity: RunDiagnostic.Severity, index: Int)?
}

// MARK: - Linker blocks

extension RunDiagnosticRecord {
    /// An `Undefined symbols` header means nothing without the symbol list indented beneath it, so the block is kept whole.
    mutating func startLinkerBlock(_ line: String) -> Bool {
        guard line.hasPrefix("Undefined symbols") else {
            return false
        }
        closeExpansion()
        linkerBlock = [line]
        return true
    }

    mutating func continueLinkerBlock(_ line: String) -> Bool {
        guard !linkerBlock.isEmpty else {
            return false
        }
        // SwiftPM 6.4 names the manifest and the product before the linker's closing line: `…/Package.swift: WidgetTests-product: clang: error: …` —
        // and the manifest is named with or without a directory, so both `Package.swift: ` at the start of the line and `/Package.swift: ` anywhere in it count.
        let namesTheManifest = line.hasPrefix("Package.swift: ") || line.contains("/Package.swift: ")
        let isContinuation = line.first?.isWhitespace == true
            || line.hasPrefix("ld: ")
            || line.hasPrefix("clang: error:")
            || namesTheManifest && line.contains(": clang: error:")
        guard isContinuation else {
            closeLinkerBlock()
            return false
        }
        linkerBlock.append(line)
        return true
    }

    mutating func closeLinkerBlock() {
        guard let header = linkerBlock.first else {
            return
        }
        let diagnostic = RunDiagnostic(
            severity: .error,
            message: header,
            detail: Array(linkerBlock.dropFirst())
        )
        linkerBlock = []
        guard seenErrors.insert(diagnostic.identity).inserted else {
            return
        }
        errors.append(diagnostic)
    }
}

// MARK: - Diagnostics

extension RunDiagnosticRecord {
    mutating func record(_ line: String) {
        guard let diagnostic = RunDiagnostic.parse(line) else {
            if !recordExpansionSite(line) {
                appendColonContinuation(line)
            }
            return
        }
        closeExpansion()
        openColonError = nil
        // A diagnostic inside a macro expansion is recorded now, in its place, and judged a copy only once its
        // note has said where it stands: until then two different `#require`s failing the same way look alike.
        let deferred = diagnostic.isInMacroExpansion
        switch diagnostic.severity {
        case .error:
            guard deferred || seenErrors.insert(diagnostic.identity).inserted else {
                return
            }
            errors.append(diagnostic)
            if deferred {
                openExpansion = (.error, errors.count - 1)
            }
            if diagnostic.message.hasSuffix(":") {
                openColonError = errors.count - 1
            }
        case .warning:
            guard deferred || seenWarnings.insert(diagnostic.identity).inserted else {
                return
            }
            warnings.append(diagnostic)
            if deferred {
                openExpansion = (.warning, warnings.count - 1)
            }
        }
    }

    /// Ends the open heading's continuation: a line another reader claimed stands between it and whatever follows.
    mutating func endColonContinuation() {
        openColonError = nil
    }

    /// Settles the open macro expansion's diagnostic as the copy of an earlier one or as new, with whatever site its notes gave it.
    ///
    /// It is always the last one recorded of its severity: every path that records another closes this first.
    mutating func closeExpansion() {
        guard let open = openExpansion else {
            return
        }
        openExpansion = nil
        switch open.severity {
        case .error:
            if !seenErrors.insert(errors[open.index].identity).inserted {
                errors.remove(at: open.index)
                if openColonError == open.index {
                    openColonError = nil
                }
            }
        case .warning:
            if !seenWarnings.insert(warnings[open.index].identity).inserted {
                warnings.remove(at: open.index)
            }
        }
    }

    /// Reads the compiler's note naming the source line the open macro expansion sits at, and whether `line` was one.
    ///
    /// A note naming another expansion's buffer is a level of a nested expansion (`-diagnostic-style=llvm` prints one per level, innermost first), so the walk goes on to the next; the first note naming a source file is the outermost, and closes it. Everything between — the source excerpt, the expansion's own text — passes by untouched, as it always has.
    private mutating func recordExpansionSite(_ line: String) -> Bool {
        guard let open = openExpansion, let site = RunDiagnostic.expansionSite(inNote: line) else {
            return false
        }
        guard !RunDiagnostic.isMacroExpansionBuffer(site.path) else {
            return true
        }
        switch open.severity {
        case .error:
            errors[open.index] = errors[open.index].expanded(at: site)
        case .warning:
            warnings[open.index] = warnings[open.index].expanded(at: site)
        }
        closeExpansion()
        return true
    }

    /// Folds `line` into the open colon-error's `detail`, while it is still indented and the cap has not been reached — the same fold ``closeLinkerBlock()`` does for an `Undefined symbols` header, for the same reason: the heading means nothing without it.
    private mutating func appendColonContinuation(_ line: String) {
        guard let index = openColonError else {
            return
        }
        guard line.first?.isWhitespace == true else {
            openColonError = nil
            return
        }
        guard errors[index].detail.count < Self.colonContinuationCap else {
            openColonError = nil
            return
        }
        errors[index] = errors[index].appending(detail: [line])
    }
}
