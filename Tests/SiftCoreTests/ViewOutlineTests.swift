//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the view outline: the one body a digest reads, because for view code the body *is* the declaration surface.
struct ViewOutlineTests {
    /// The outline recorded for a named member of a parsed source.
    private static func outline(for member: String, in source: String) throws -> String? {
        try TestSources.parsed(source, path: "Screen.swift").symbols
            .first { $0.name == member || $0.name.hasPrefix(member + "(") }?
            .viewOutline
    }

    /// Every statement in a builder block is a view by construction, so a call to one of the screen's own `some View` methods counts exactly as `VStack` does.
    ///
    /// A rule that only takes capitalised constructions drops them, and in a codebase that decomposes screens into methods that is most of the structure.
    @Test
    func aScreensOwnViewMethodsAppearAlongsideTheStandardContainers() throws {
        let outline = try #require(try Self.outline(for: "body", in: """
        struct Screen: View {
            var body: some View {
                VStack {
                    hero()
                    Text("hello")
                }
            }
        }
        """))

        #expect(outline == """
        VStack :3
          hero :4
          Text :5
        """)
    }

    /// A view method that computes something before returning is the common shape in real screens, and an explicit `return` is a statement kind of its own — unhandled, it drops the entire outline rather than one line of it.
    @Test
    func anExplicitReturnIsOutlined() throws {
        let outline = try #require(try Self.outline(for: "sections", in: """
        struct Screen: View {
            private func sections(_ catalogue: Catalogue) -> some View {
                let visible = catalogue.sections.filter(\\.isActive)
                return VStack {
                    ForEach(visible) { TileCard($0) }
                }
            }
        }
        """))

        #expect(outline.contains("VStack :4"))
        #expect(outline.contains("ForEach :5"))
        #expect(outline.contains("TileCard :5"))
    }

    /// A conditional view arrives in statement position wrapped rather than as an expression, which, unhandled, silently drops every branch.
    @Test
    func conditionalBranchesAreOutlined() throws {
        let outline = try #require(try Self.outline(for: "body", in: """
        struct Screen: View {
            var body: some View {
                VStack {
                    if isReady {
                        Badge()
                    } else {
                        Spinner()
                    }
                }
            }
        }
        """))

        #expect(outline.contains("if :4"))
        #expect(outline.contains("Badge :5"))
        #expect(outline.contains("Spinner :7"))
    }

    /// `.task { await store.refresh() }` and `.overlay { Badge() }` are the same shape syntactically.
    ///
    /// Walking the first would put `store` into the outline as though it were a view.
    @Test
    func actionClosuresAreNotWalkedAsContent() throws {
        let outline = try #require(try Self.outline(for: "body", in: """
        struct Screen: View {
            var body: some View {
                VStack {
                    Badge()
                }
                .task { await store.refresh() }
                .onAppear { store.begin() }
            }
        }
        """))

        #expect(outline.contains("Badge"))
        #expect(!outline.contains("store"))
    }

    /// A labelled closure argument is followed, because it is as often content as it is an action — but a `Task` inside one is work, not a view, and must not appear in an outline as though it were a subview.
    @Test
    func nonViewConstructionsInsideClosureArgumentsAreSkipped() throws {
        let outline = try #require(try Self.outline(for: "body", in: """
        struct Screen: View {
            var body: some View {
                PlaceholderView(retry: { Task { await store.reload() } })
            }
        }
        """))

        #expect(outline == "PlaceholderView :3")
    }

    /// Both spellings of `Button` put their work in the plain trailing closure and their content behind `label:`, so walking it would emit the action as a subview.
    @Test
    func aButtonsActionIsNotWalkedButItsLabelIs() throws {
        let outline = try #require(try Self.outline(for: "body", in: """
        struct Screen: View {
            var body: some View {
                VStack {
                    Button("Save") { store.save() }
                    Button { store.undo() } label: { Icon("undo") }
                }
            }
        }
        """))

        #expect(!outline.contains("store"))
        #expect(outline.contains("Icon :5"))
    }

    /// A modifier's plain trailing closure is content even when a second labelled one follows — `.alert(…) { Button(…) } message: { … }` — and treating a companion closure as proof the first one acts would hide every alert's buttons.
    @Test
    func aTrailingContentClosureSurvivesACompanionLabelledClosure() throws {
        let outline = try #require(try Self.outline(for: "body", in: """
        struct Screen: View {
            var body: some View {
                Panel()
                    .alert("Delete", isPresented: $asking) {
                        Confirm()
                    } message: {
                        Caption()
                    }
            }
        }
        """))

        // And in source order: a chain's base comes before its modifiers, and one call's own closures
        // stay as written — the alert's content above its message, not below.
        #expect(outline == """
        Panel :3
          Confirm :5
          Caption :7
        """)
    }

    /// Branches are alternatives, and rendering them as a plain child list would say the opposite: that the view contains both.
    @Test
    func conditionalAlternativesAreLabelledRatherThanMerged() throws {
        let outline = try #require(try Self.outline(for: "body", in: """
        struct Screen: View {
            var body: some View {
                if isLoading {
                    ProgressView()
                } else {
                    List { Row() }
                }
            }
        }
        """))

        #expect(outline.contains("if :3"))
        #expect(outline.contains("else :5"))
        // The alternatives sit at the same depth as the words that introduce them.
        #expect(outline.contains("  ProgressView :4"))
        #expect(outline.contains("  List :6"))
    }

    /// Rendered as a flat list of siblings, a switch's cases would say nothing about which case produced which view.
    @Test
    func switchCasesCarryTheirLabels() throws {
        let outline = try #require(try Self.outline(for: "body", in: """
        struct Screen: View {
            var body: some View {
                switch phase {
                case .loading:
                    Spinner()
                case .ready:
                    Content()
                default:
                    Empty()
                }
            }
        }
        """))

        #expect(outline.contains("case .loading"))
        #expect(outline.contains("case .ready"))
        #expect(outline.contains("default"))
        #expect(outline.contains("Spinner"))
    }

    /// `Path { path in path.move(…) }` and `ForEach(items) { item in Row(item) }` are the same shape — a closure taking a parameter — and only the second builds views.
    ///
    /// The first roots its statements at the parameter, which is the tell.
    @Test
    func statementsRootedAtAClosureParameterAreNotViews() throws {
        let outline = try #require(try Self.outline(for: "body", in: """
        struct Screen: View {
            var body: some View {
                Canvas { context, size in
                    context.draw(text, at: .zero)
                    context.stroke(path, with: .color(.red))
                }
            }
        }
        """))

        #expect(outline == "Canvas :3")
    }

    /// The loop variable binds too, so a `for` body that only mutates it contributes nothing.
    @Test
    func aLoopVariableBindsLikeAClosureParameter() throws {
        let outline = try #require(try Self.outline(for: "shape", in: """
        struct Screen: View {
            private func shape() -> some View {
                Path { path in
                    for point in points {
                        path.addLine(to: point)
                    }
                }
            }
        }
        """))

        #expect(!outline.contains("path"))
        #expect(!outline.contains("point"))
    }

    /// A local `let` binds for the statements after it — `var linePath = Path(); linePath.addLine(…)` would otherwise contribute `linePath` as a subview.
    @Test
    func aLocalBindingIsNotAViewWhenItIsLaterMutated() throws {
        let outline = try #require(try Self.outline(for: "chart", in: """
        struct Screen: View {
            private func chart() -> some View {
                Canvas { ctx, size in
                    var linePath = Path()
                    linePath.addLine(to: .zero)
                    ctx.stroke(linePath, with: .color(.blue))
                }
            }
        }
        """))

        #expect(outline == "Canvas :3")
    }

    /// The binding rule must not swallow real content: a `ForEach` parameter used *inside* a view construction is not the root of that statement.
    @Test
    func aParameterUsedInsideAViewStillLeavesTheViewOutlined() throws {
        let outline = try #require(try Self.outline(for: "body", in: """
        struct Screen: View {
            var body: some View {
                ForEach(items) { item in
                    BayCard(item)
                }
            }
        }
        """))

        #expect(outline == """
        ForEach :3
          BayCard :4
        """)
    }

    /// A modifier chain is collapsed into what it decorates: modifiers are the bulk of view source and never the reason someone opens the file.
    @Test
    func modifierChainsCollapseIntoTheirRoot() throws {
        let outline = try #require(try Self.outline(for: "body", in: """
        struct Screen: View {
            var body: some View {
                Text("hello")
                    .padding()
                    .foregroundStyle(.red)
            }
        }
        """))

        #expect(outline == "Text :3")
    }

    /// A screen built as `private func card(…) -> some View` puts almost none of its structure in `body`, so functions are outlined too.
    @Test
    func viewReturningFunctionsAreOutlinedAsWellAsBody() throws {
        let outline = try #require(try Self.outline(for: "card", in: """
        struct Screen: View {
            var body: some View {
                card()
            }

            private func card() -> some View {
                HStack {
                    Icon()
                    Label()
                }
            }
        }
        """))

        #expect(outline == """
        HStack :7
          Icon :8
          Label :9
        """)
    }

    /// A `for` loop in a builder is repetition; its body is the repeated view.
    @Test
    func loopsAreOutlinedWithTheirRepeatedContent() throws {
        let outline = try #require(try Self.outline(for: "body", in: """
        struct Screen: View {
            var body: some View {
                VStack {
                    for item in items {
                        BayCard(item)
                    }
                }
            }
        }
        """))

        #expect(outline.contains("for :4"))
        #expect(outline.contains("BayCard :5"))
    }

    /// Only an opaque `View` annotation qualifies.
    ///
    /// Nothing else in the codebase grows a body in its digest, and a property whose type is left to the compiler is not worth guessing at from a syntax tree.
    @Test
    func nonViewMembersCarryNoOutline() throws {
        let source = """
        struct Model {
            var total: Int {
                values.reduce(0, +)
            }

            func summary() -> String {
                Formatter().string(from: total)
            }
        }
        """

        #expect(try Self.outline(for: "total", in: source) == nil)
        #expect(try Self.outline(for: "summary", in: source) == nil)
    }

    /// A stored property has no body to outline and must not acquire one.
    @Test
    func storedPropertiesCarryNoOutline() throws {
        #expect(try Self.outline(for: "name", in: """
        struct Screen: View {
            let name: String
        }
        """) == nil)
    }

    /// A digest must stay a digest: a view with hundreds of leaves truncates rather than turning the answer into the file.
    @Test
    func aVeryLargeViewTruncatesRatherThanPrintingEverything() throws {
        let leaves = (0 ..< 60).map { "        Row\($0)()" }.joined(separator: "\n")
        let outline = try #require(try Self.outline(for: "body", in: """
        struct Screen: View {
            var body: some View {
                VStack {
        \(leaves)
                }
            }
        }
        """))

        #expect(outline.contains("… "))
        #expect(outline.split(separator: "\n").count <= ViewOutline.entryLimit + 1)
    }
}
