import SwiftUI

struct InspectorSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(display)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Slider(value: $value, in: range)
                    .accessibilityLabel(title)
                    .accessibilityValue(display)
            }
        }
    }
}
