import SwiftUI

public struct AudioLevelMeter: View {
    private let levels: CaptureLevels?

    public init(levels: CaptureLevels?) { self.levels = levels }

    private let floor: Float = -60

    private var average: Float? { levels.map(\.averageDBFS).flatMap { $0.isFinite ? $0 : nil } }
    private var peak: Float? { levels.map(\.peakDBFS).flatMap { $0.isFinite ? $0 : nil } }
    private var nearClip: Bool { (peak ?? floor) >= -1 }

    private func fraction(_ value: Float?) -> CGFloat {
        CGFloat((min(0, max(floor, value ?? floor)) - floor) / -floor)
    }

    private func reading(_ value: Float?) -> String {
        guard let value else { return "—" }
        if value < floor { return "< −60 dBFS" }
        return "\(value.formatted(.number.precision(.fractionLength(1)))) dBFS"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Input level").font(.subheadline.weight(.semibold))
                Spacer()
                if nearClip {
                    Label("Near clipping", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(nearClip ? Color.red : Color.accentColor)
                        .frame(width: geometry.size.width * fraction(average))
                    if peak != nil {
                        Rectangle()
                            .fill(.primary)
                            .frame(width: 2)
                            .offset(x: max(0, (geometry.size.width - 2) * fraction(peak)))
                    }
                }
            }
            .frame(height: 12)
            .accessibilityHidden(true)

            HStack {
                Text("−60")
                Spacer()
                Text("−30")
                Spacer()
                Text("0")
            }
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

            HStack {
                Text("Avg \(reading(average))")
                Spacer()
                Text("Peak \(reading(peak))")
            }
            .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Input level")
        .accessibilityValue(average == nil ? "No reading" : "Average \(reading(average)), peak \(reading(peak))" + (nearClip ? ", near clipping" : ""))
        .font(.caption)
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
