//
// Copyright © Agulhas Labs
//

import Foundation

/// Reads a scheme's `TestAction` in one pass, and nothing else in the document.
///
/// A `BuildableReference` appears under the build, launch, profile and archive actions too, so one is read only while a `TestableReference` inside the test action is open — otherwise the app target a scheme launches would be counted as a test target it runs.
final class SchemeTestActionReader: NSObject, XMLParserDelegate {
    private var sawTestAction = false
    private var insideTestAction = false
    private var openTestable: (isSkipped: Bool, target: String?)?
    private var testables: [SchemeFile.Testable] = []
    private var planReferences: [SchemeFile.PlanReference] = []

    /// What the document's test action names, and `nil` where it carries none.
    var testAction: SchemeFile.TestAction? {
        sawTestAction ? SchemeFile.TestAction(testables: testables, planReferences: planReferences) : nil
    }

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes: [String: String] = [:]
    ) {
        switch elementName {
        case "TestAction":
            sawTestAction = true
            insideTestAction = true
        case "TestableReference" where insideTestAction:
            openTestable = (isSkipped: attributes["skipped"] == "YES", target: nil)
        case "BuildableReference" where openTestable?.target == nil:
            openTestable?.target = attributes["BlueprintName"]
        case "TestPlanReference" where insideTestAction:
            guard let reference = attributes["reference"] else { return }
            planReferences.append(SchemeFile.PlanReference(reference: reference, isDefault: attributes["default"] == "YES"))
        default:
            return
        }
    }

    func parser(_: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?) {
        switch elementName {
        case "TestAction":
            insideTestAction = false
        case "TestableReference":
            if let target = openTestable?.target, let isSkipped = openTestable?.isSkipped {
                testables.append(SchemeFile.Testable(target: target, isSkipped: isSkipped))
            }
            openTestable = nil
        default:
            return
        }
    }
}
