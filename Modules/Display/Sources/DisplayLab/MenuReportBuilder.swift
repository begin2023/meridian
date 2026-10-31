import AppKit
import DisplayCore
import Foundation

/// Serializes the status menu tree to JSON for structural smoke assertions
/// (submenu presence, mode counts, slider view wiring) without opening it.
enum MenuReportBuilder {
    struct Item: Encodable {
        let title: String
        let state: String
        let childCount: Int
        let hasSliderView: Bool
        let children: [Item]?
    }

    struct Report: Encodable {
        let generatedAt: Date
        let items: [Item]
    }

    static func build(menu: NSMenu) -> Report {
        Report(generatedAt: Date(), items: menu.items.map(describe))
    }

    private static func describe(_ item: NSMenuItem) -> Item {
        let state: String
        switch item.state {
        case .on: state = "on"
        case .off: state = "off"
        default: state = "mixed"
        }
        let children: [Item]?
        if let submenu = item.submenu {
            children = submenu.items.map(describe)
        } else {
            children = nil
        }
        return Item(
            title: item.title,
            state: state,
            childCount: item.submenu?.items.count ?? 0,
            hasSliderView: item.view is BrightnessSliderRow,
            children: children
        )
    }
}
