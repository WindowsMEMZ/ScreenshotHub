import AppKit
import SwiftUI

enum InspectorTab: Int, CaseIterable {
    case device
    case content

    var label: String { self == .device ? "Device" : "Content" }
    var symbol: String { self == .device ? "iphone" : "text.below.photo" }
}

struct InspectorSelection {
    private static let visibilityKey = "workspaceInspectorVisible"

    static func load(from defaults: UserDefaults = .standard) -> Self {
        var selection = Self()
        selection.setVisible(defaults.object(forKey: visibilityKey) as? Bool ?? true)
        return selection
    }

    private(set) var tab: InspectorTab? = .device
    private var lastTab: InspectorTab = .device

    var displayedTab: InspectorTab { tab ?? lastTab }
    var isVisible: Bool { tab != nil }

    mutating func select(_ tab: InspectorTab?) {
        self.tab = tab
        if let tab { lastTab = tab }
    }

    mutating func setVisible(_ visible: Bool) {
        select(visible ? displayedTab : nil)
    }

    mutating func toggleVisibility() { setVisible(!isVisible) }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(isVisible, forKey: Self.visibilityKey)
    }
}

struct InspectorTabPicker: NSViewRepresentable {
    @Binding var selection: InspectorTab?

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = InspectorTab.allCases.count
        // selectAny permits deselecting the active tab; the action enforces exclusivity.
        control.trackingMode = .selectAny
        control.segmentStyle = .automatic
        // Icon-only segments use the native picker's selection artwork.
        control.role = .valueSelection
        control.selectedSegmentBezelColor = .secondaryLabelColor
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectTab(_:))
        control.setAccessibilityLabel("Inspector")
        control.setAccessibilityIdentifier("InspectorTabs")
        for tab in InspectorTab.allCases {
            control.setLabel("", forSegment: tab.rawValue)
            control.setImage(NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.label),
                             forSegment: tab.rawValue)
            control.setToolTip("\(tab.label) settings — click again to hide", forSegment: tab.rawValue)
        }
        control.sizeToFit()
        updateNSView(control, context: context)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        for tab in InspectorTab.allCases {
            control.setSelected(selection == tab, forSegment: tab.rawValue)
        }
    }

    final class Coordinator: NSObject {
        var selection: Binding<InspectorTab?>

        init(selection: Binding<InspectorTab?>) { self.selection = selection }

        @objc func selectTab(_ control: NSSegmentedControl) {
            let index = control.selectedSegment
            let tab = index >= 0 && control.isSelected(forSegment: index) ? InspectorTab(rawValue: index) : nil
            selection.wrappedValue = tab
            for candidate in InspectorTab.allCases {
                control.setSelected(candidate == tab, forSegment: candidate.rawValue)
            }
        }
    }
}

private struct InspectorToggleKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var toggleInspector: (() -> Void)? {
        get { self[InspectorToggleKey.self] }
        set { self[InspectorToggleKey.self] = newValue }
    }
}

struct InspectorCommands: Commands {
    @FocusedValue(\.toggleInspector) private var toggleInspector

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Show/Hide Inspector") { toggleInspector?() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(toggleInspector == nil)
        }
    }
}
