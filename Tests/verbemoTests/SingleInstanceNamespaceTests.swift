import Foundation
import Testing
@testable import verbemo

struct SingleInstanceNamespaceTests {
    @Test func previewCannotActivateOrReplaceTheInstalledProduct() {
        let production = SingleInstance.notifications(for: "name.ekho.verbemo")
        let preview = SingleInstance.notifications(for: "name.ekho.verbemo.ux-preview")
        #expect(production.0.rawValue == "name.ekho.verbemo.activate")
        #expect(production.1.rawValue == "name.ekho.verbemo.activate-ack")
        #expect(preview.0 != production.0)
        #expect(preview.1 != production.1)
    }
}
