import SwiftUI
import LCPContextServices

/// Foundation supplies CommonMark block identities and inline styling. Keep the
/// blocks separate so SwiftUI can lay out and navigate headings, lists and figures.
enum AgentOutputBlock: Equatable, Sendable {
    case text(AttributedString, heading: Int?, marker: String?, depth: Int, quote: Bool)
    case code(String)
    case visual(AgentVisual)
    case table([[AttributedString]])

    nonisolated static func prepare(_ source: String) async -> [Self] {
        if Task.isCancelled { return [] }
        return parse(source)
    }

    static func parse(_ source: String) -> [Self] {
        guard !source.isEmpty else { return [] }
        let plain = Self.text(AttributedString(source), heading: nil, marker: nil, depth: 0, quote: false)
        guard source.utf8.count <= 262_144, let parsed = try? AttributedString(markdown: source) else { return [plain] }
        var blocks: [Self] = []
        var tableID: Int?
        var rowID: Int?
        var rows: [[AttributedString]] = []
        var previousListItem: Int?
        func finishTable() {
            if !rows.isEmpty { blocks.append(.table(rows)) }
            rows = []; tableID = nil; rowID = nil
        }
        for (intent, range) in parsed.runs[\.presentationIntent] {
            if Task.isCancelled { return [] }
            guard blocks.count < 512 else { return [plain] }
            var text = AttributedString(parsed[range])
            let parts = intent?.components ?? []
            text.presentationIntent = nil
            text.imageURL = nil
            for (link, range) in text.runs[\.link] {
                if let link, !allowsLink(link) { text[range].link = nil }
            }
            if case .tableCell(let column) = parts.first?.kind, parts.count >= 3 {
                if tableID != parts[2].identity { finishTable(); tableID = parts[2].identity }
                if rowID != parts[1].identity { rows.append([]); rowID = parts[1].identity }
                guard (0..<24).contains(column), rows.count <= 128 else { return [plain] }
                let last = rows.count - 1
                while rows[last].count <= column { rows[last].append(AttributedString()) }
                rows[last][column].append(text)
                continue
            }
            finishTable()
            if case .codeBlock(let language) = parts.first?.kind {
                let body = String(text.characters)
                if language == AgentVisual.fence, let visual = try? AgentVisual.decodeBlock(body) {
                    blocks.append(.visual(visual))
                } else { blocks.append(.code(body.hasSuffix("\n") ? String(body.dropLast()) : body)) }
                continue
            }
            var heading: Int?
            var marker: String?
            var itemID: Int?
            var ordinal = 0
            var depth = 0
            var quote = false
            for part in parts {
                switch part.kind {
                case .header(let level): heading = level
                case .listItem(let number) where itemID == nil: itemID = part.identity; ordinal = number
                case .orderedList:
                    if depth == 0 { marker = "\(ordinal)." }
                    depth += 1
                case .unorderedList:
                    if depth == 0 { marker = "•" }
                    depth += 1
                case .blockQuote: quote = true
                default: break
                }
            }
            if previousListItem == itemID { marker = nil }
            previousListItem = itemID
            blocks.append(.text(text, heading: heading, marker: marker, depth: depth, quote: quote))
        }
        finishTable()
        return blocks.isEmpty ? [plain] : blocks
    }

    static func allowsLink(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "lcp" { return (try? CitationLink.decode(url)) != nil }
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty else { return false }
        return url.user == nil && url.password == nil
    }
}

struct AgentOutputView: View {
    let source: String
    @State private var blocks: [AgentOutputBlock] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                block(blocks[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .task(id: source) {
            let prepared = await AgentOutputBlock.prepare(source)
            if !Task.isCancelled { blocks = prepared }
        }
        .environment(\.openURL, OpenURLAction { url in
            AgentOutputBlock.allowsLink(url) ? .systemAction : .discarded
        })
    }

    @ViewBuilder private func block(_ block: AgentOutputBlock) -> some View {
        switch block {
        case let .text(content, heading, marker, depth, quote):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if depth > 0 {
                    Text(verbatim: marker ?? " ").font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary).frame(minWidth: 16, alignment: .trailing)
                }
                if let heading {
                    Text(content).font(heading < 3 ? .title3.weight(.semibold) : .headline)
                        .accessibilityAddTraits(.isHeader)
                } else { Text(content) }
            }
            .padding(.leading, CGFloat(min(6, max(0, depth - 1))) * 14 + (quote ? 10 : 0))
            .overlay(alignment: .leading) { if quote { Rectangle().fill(WorkspacePalette.accent).frame(width: 2) } }
        case .code(let code):
            Text(verbatim: code)
                .font(.system(.callout, design: .monospaced))
                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        case .table(let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(rows[row].indices, id: \.self) { col in
                                Text(rows[row][col]).font(row == 0 ? .callout.weight(.semibold) : .callout)
                            }
                        }
                        if row == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                    }
                }.padding(.vertical, 4)
            }
        case .visual(let visual): AgentVisualView(visual: visual)
        }
    }
}

private struct AgentVisualView: View {
    let visual: AgentVisual

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(visual.title, systemImage: visual.tool == .barChart ? "chart.bar.xaxis" : "list.number")
                .font(.headline).accessibilityAddTraits(.isHeader)
            switch visual.tool {
            case .barChart:
                let maximum = visual.items.compactMap(\.value).max() ?? 0
                ForEach(visual.items.indices, id: \.self) { index in
                    let item = visual.items[index]
                    let value = item.value ?? 0
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: item.label)
                            Spacer(minLength: 8)
                            Text(verbatim: value.formatted(.number.precision(.significantDigits(1...12))) + " " + (visual.unit ?? ""))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }.font(.callout)
                        GeometryReader { area in
                            ZStack(alignment: .leading) {
                                Capsule().fill(WorkspacePalette.line.opacity(0.55))
                                Capsule().fill(WorkspacePalette.accent)
                                    .frame(width: area.size.width * (maximum > 0 ? value / maximum : 0))
                            }
                        }.frame(height: 6).accessibilityHidden(true)
                    }.accessibilityElement(children: .combine)
                }
            case .timeline:
                ForEach(visual.items.indices, id: \.self) { index in
                    let item = visual.items[index]
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .frame(width: 24, height: 24)
                            .background(WorkspacePalette.tintSurface, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: item.label).font(.callout.weight(.semibold))
                            Text(verbatim: item.detail ?? "").font(.callout).foregroundStyle(.secondary)
                        }
                    }.accessibilityElement(children: .combine)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(WorkspacePalette.line) }
    }
}
