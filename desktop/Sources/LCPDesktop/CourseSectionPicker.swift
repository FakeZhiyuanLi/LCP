import SwiftUI

enum CourseSection: String, CaseIterable {
    case planner = "Plan"
    case materials = "Materials"
    case history = "History"
    case coursework = "Coursework"
    case search = "Search Sources"
    case lectures = "Lectures"
    case capture = "Capture"

    var symbol: String {
        switch self {
        case .planner: "sparkles"
        case .materials: "doc.on.doc"
        case .history: "clock"
        case .coursework: "checklist"
        case .search: "magnifyingglass"
        case .lectures: "waveform"
        case .capture: "mic"
        }
    }
}

struct CourseSectionPicker: View {
    @Binding var selection: CourseSection
    @FocusState private var focused: CourseSection?

    var body: some View {
        HStack {
            ViewThatFits(in: .horizontal) {
                row(showsSymbols: true)
                row(showsSymbols: false)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Class sections")
    }

    private func row(showsSymbols: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(CourseSection.allCases, id: \.self) { section in
                Button {
                    selection = section
                } label: {
                    HStack(spacing: 5) {
                        if showsSymbols { Image(systemName: section.symbol).accessibilityHidden(true) }
                        Text(section.rawValue)
                    }
                    .font(.system(size: 12, weight: section == selection ? .semibold : .regular))
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .foregroundStyle(section == selection ? WorkspacePalette.accent : WorkspacePalette.ink)
                    .background(section == selection ? WorkspacePalette.tintSurface : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(true, interactions: .edit)
                .focused($focused, equals: section)
                .accessibilityAddTraits(section == selection ? .isSelected : [])
                .onKeyPress(.leftArrow) { move(from: section, by: -1) }
                .onKeyPress(.rightArrow) { move(from: section, by: 1) }
            }
        }
        .fixedSize().padding(3)
        .background(WorkspacePalette.surface, in: Capsule())
        .overlay { Capsule().strokeBorder(WorkspacePalette.line).allowsHitTesting(false) }
    }

    private func move(from section: CourseSection, by offset: Int) -> KeyPress.Result {
        let choices = CourseSection.allCases
        guard let index = choices.firstIndex(of: section) else { return .ignored }
        let next = choices[(index + offset + choices.count) % choices.count]
        selection = next
        focused = next
        return .handled
    }
}
