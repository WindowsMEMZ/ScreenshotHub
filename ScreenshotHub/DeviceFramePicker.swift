import SwiftUI

nonisolated struct DeviceFrameGroup: Identifiable {
    let name: String
    var frames: [DeviceFrame]

    var id: String { name }

    static func groups(for frames: [DeviceFrame]) -> [Self] {
        var groups: [Self] = []
        var indices: [String: Int] = [:]
        for frame in frames {
            let name = deviceName(for: frame)
            if let index = indices[name] {
                groups[index].frames.append(frame)
            } else {
                indices[name] = groups.count
                groups.append(.init(name: name, frames: [frame]))
            }
        }
        return groups
    }

    private static func deviceName(for frame: DeviceFrame) -> String {
        let name = frame.displayName.components(separatedBy: " · ")[0]
        let components = name.components(separatedBy: " - ")
        if components.count > 1 {
            if frame.family == .appleWatch {
                // Watch case sizes are distinct devices; finishes and bands are variants.
                return components.prefix(2).joined(separator: " - ")
            }
            if frame.family == .iPad, components.count > 2,
               components[1].range(of: #"^M\d+(?: Pro| Max| Ultra)?$"#, options: .regularExpression) != nil {
                return components.prefix(2).joined(separator: " - ")
            }
            return components[0]
        }
        // Mac catalog names use spaces for finishes and display background variants.
        if frame.family == .mac {
            for suffix in [" On Dark Background", " On Light Background", " Space Black", " Space Gray",
                           " Sky Blue", " Midnight", " Starlight", " Silver", " Blue", " Green",
                           " Orange", " Pink", " Purple", " Yellow"] where name.hasSuffix(suffix) {
                return String(name.dropLast(suffix.count))
            }
        }
        return name
    }
}

struct DeviceFramePicker: View {
    let title: String
    @Binding var selection: String
    let frames: [DeviceFrame]

    private var currentName: String {
        frames.first { $0.id == selection }?.displayName ?? "Select a Frame"
    }

    var body: some View {
        Picker(selection: $selection) {
            Section {
                // Keep the current value in the outer picker, including embedded document frames.
                Text(currentName).tag(selection)
            }
            ForEach(DeviceFrameGroup.groups(for: frames)) { group in
                if group.frames.count > 1 {
                    Menu {
                        Picker(selection: $selection) {
                            ForEach(group.frames) { frame in
                                Text(frame.displayName).tag(frame.id)
                            }
                        } label: {
                            EmptyView()
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        Text(group.name)
                    }
                } else if let frame = group.frames.first {
                    Text(frame.displayName).tag(frame.id)
                }
            }
        } label: {
            Text(title)
        } currentValueLabel: {
            Text(currentName)
        }
        .pickerStyle(.menu)
        .disabled(frames.isEmpty)
    }
}
