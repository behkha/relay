import SwiftUI
import AppKit

/// Block-level Markdown for agent messages: headings, paragraphs, bullet/numbered/task lists (nested),
/// fenced code, block quotes, tables and rules. Inline styles (bold, italic, `code`, links, strikethrough)
/// come from Foundation's Markdown parser.
struct MarkdownView: View {
    let text: String
    var fontSize: CGFloat = 13

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, fontSize: fontSize)
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

indirect enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String, code: String)
    case quote([MarkdownBlock])
    case list(ordered: Bool, start: Int, items: [MarkdownListItem])
    case table(header: [String], alignments: [HorizontalAlignment], rows: [[String]])
    case rule
}

struct MarkdownListItem {
    var text: String
    var checked: Bool?          // task list state, nil for plain items
    var children: [MarkdownBlock]
}

enum MarkdownParser {
    static let maxDepth = 6
    static let maxLength = 40_000

    static func parse(_ source: String) -> [MarkdownBlock] {
        var text = source
        if text.count > maxLength { text = String(text.prefix(maxLength)) + "\n…" }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        return parseBlocks(lines, &i, depth: 0)
    }

    private static func parseBlocks(_ lines: [String], _ i: inout Int, depth: Int) -> [MarkdownBlock] {
        // Deeply nested quotes/lists are flattened to text so hostile input can't exhaust the stack.
        if depth > maxDepth {
            let rest = lines[i...].joined(separator: "\n")
            i = lines.count
            return rest.isEmpty ? [] : [.paragraph(rest)]
        }
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { flush(); i += 1; continue }

            // Fenced code
            if let fence = fenceMarker(trimmed) {
                flush()
                let lang = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                let indent = line.prefix { $0 == " " }.count
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(fence) && t.trimmingCharacters(in: CharacterSet(charactersIn: String(fence.first!))).isEmpty { i += 1; break }
                    var l = lines[i]
                    var drop = indent
                    while drop > 0, l.hasPrefix(" ") { l.removeFirst(); drop -= 1 }
                    code.append(l)
                    i += 1
                }
                blocks.append(.code(language: lang, code: code.joined(separator: "\n")))
                continue
            }

            // Heading
            if let (level, text) = heading(trimmed) {
                flush()
                blocks.append(.heading(level: level, text: text))
                i += 1
                continue
            }

            // Horizontal rule
            if isRule(trimmed) {
                flush()
                blocks.append(.rule)
                i += 1
                continue
            }

            // Table: a row followed by a separator row
            if trimmed.contains("|"), i + 1 < lines.count, let aligns = tableSeparator(lines[i + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, t.contains("|") else { break }
                    rows.append(cells(t))
                    i += 1
                }
                let n = max(header.count, aligns.count)
                func pad(_ r: [String]) -> [String] { r.count >= n ? Array(r.prefix(n)) : r + Array(repeating: "", count: n - r.count) }
                let al = aligns.count >= n ? Array(aligns.prefix(n)) : aligns + Array(repeating: .leading, count: n - aligns.count)
                blocks.append(.table(header: pad(header), alignments: al, rows: rows.map(pad)))
                continue
            }

            // Block quote
            if trimmed.hasPrefix(">") {
                flush()
                var inner: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var rest = t.dropFirst()
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    inner.append(String(rest))
                    i += 1
                }
                var j = 0
                blocks.append(.quote(parseBlocks(inner, &j, depth: depth + 1)))
                continue
            }

            // List
            if listMarker(line) != nil {
                flush()
                blocks.append(parseList(lines, &i, depth: depth))
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flush()
        return blocks
    }

    // MARK: Lists

    private struct Marker { var indent: Int; var ordered: Bool; var number: Int; var content: String }

    private static func listMarker(_ line: String) -> Marker? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        if let f = rest.first, "-*+".contains(f), rest.dropFirst().first == " " {
            if isRule(String(rest)) { return nil }
            return Marker(indent: indent, ordered: false, number: 0, content: String(rest.dropFirst(2)))
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let after = rest.dropFirst(digits.count)
            if let p = after.first, p == "." || p == ")", after.dropFirst().first == " " {
                return Marker(indent: indent, ordered: true, number: Int(digits) ?? 1, content: String(after.dropFirst(2)))
            }
        }
        return nil
    }

    private static func parseList(_ lines: [String], _ i: inout Int, depth: Int) -> MarkdownBlock {
        guard let first = listMarker(lines[i]) else { return .paragraph(lines[i]) }
        let base = first.indent
        var items: [MarkdownListItem] = []
        while i < lines.count {
            guard let m = listMarker(lines[i]), m.indent >= base, m.indent < base + 2, m.ordered == first.ordered else { break }
            var text = m.content
            var checked: Bool?
            if text.hasPrefix("[ ] ") { checked = false; text = String(text.dropFirst(4)) }
            else if text.lowercased().hasPrefix("[x] ") { checked = true; text = String(text.dropFirst(4)) }
            i += 1
            // Continuation lines and nested blocks (indented deeper than the marker).
            var nested: [String] = []
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                let ind = l.prefix { $0 == " " || $0 == "\t" }.count
                if t.isEmpty {
                    // A blank line ends the item unless more indented content follows.
                    if i + 1 < lines.count, lines[i + 1].prefix(while: { $0 == " " }).count > base, !lines[i + 1].trimmingCharacters(in: .whitespaces).isEmpty {
                        nested.append(""); i += 1; continue
                    }
                    break
                }
                if ind > base {
                    if nested.isEmpty && listMarker(l) == nil && fenceMarker(t) == nil {
                        text += "\n" + t
                    } else {
                        nested.append(String(l.dropFirst(min(ind, base + 2))))
                    }
                    i += 1
                } else { break }
            }
            var j = 0
            let children = nested.isEmpty ? [] : parseBlocks(nested, &j, depth: depth + 1)
            items.append(MarkdownListItem(text: text, checked: checked, children: children))
            // Skip a single blank line between items of the same list.
            if i + 1 < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
               let next = listMarker(lines[i + 1]), next.indent >= base, next.indent < base + 2, next.ordered == first.ordered {
                i += 1
            }
        }
        return .list(ordered: first.ordered, start: first.number, items: items)
    }

    // MARK: Helpers

    private static func fenceMarker(_ t: String) -> String? {
        if t.hasPrefix("```") { return String(t.prefix { $0 == "`" }) }
        if t.hasPrefix("~~~") { return String(t.prefix { $0 == "~" }) }
        return nil
    }

    private static func heading(_ t: String) -> (Int, String)? {
        let hashes = t.prefix { $0 == "#" }.count
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = t.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ t: String) -> Bool {
        let s = t.replacingOccurrences(of: " ", with: "")
        guard s.count >= 3, let c = s.first, "-*_".contains(c) else { return false }
        return s.allSatisfy { $0 == c }
    }

    private static func cells(_ row: String) -> [String] {
        var r = row.trimmingCharacters(in: .whitespaces)
        if r.hasPrefix("|") { r.removeFirst() }
        if r.hasSuffix("|") && !r.hasSuffix("\\|") { r.removeLast() }
        // Split on unescaped pipes.
        var out: [String] = []
        var cur = ""
        var prev: Character = " "
        for ch in r {
            if ch == "|" && prev != "\\" { out.append(cur); cur = "" } else { cur.append(ch) }
            prev = ch
        }
        out.append(cur)
        return out.map { $0.replacingOccurrences(of: "\\|", with: "|").trimmingCharacters(in: .whitespaces) }
    }

    private static func tableSeparator(_ line: String) -> [HorizontalAlignment]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix(":") || t.hasPrefix("-") else { return nil }
        let parts = cells(t)
        guard !parts.isEmpty else { return nil }
        var aligns: [HorizontalAlignment] = []
        for p in parts {
            let s = p.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, s.allSatisfy({ $0 == "-" || $0 == ":" }), s.contains("-") else { return nil }
            if s.hasPrefix(":") && s.hasSuffix(":") { aligns.append(.center) }
            else if s.hasSuffix(":") { aligns.append(.trailing) }
            else { aligns.append(.leading) }
        }
        return aligns
    }
}

/// Inline Markdown (bold, italic, `code`, links, ~~strike~~) as a styled Text.
enum InlineMarkdown {
    static func text(_ s: String, size: CGFloat, weight: Font.Weight = .regular, color: Color = Color.white.opacity(0.92)) -> Text {
        var attr = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                                       failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(s)
        for run in attr.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                attr[run.range].font = .system(size: size - 1, design: .monospaced)
                attr[run.range].foregroundColor = Color(hex: "#E9B97A")
            }
            if run.link != nil {
                attr[run.range].foregroundColor = Theme.blue
                attr[run.range].underlineStyle = .single
            }
        }
        return Text(attr).font(.system(size: size, weight: weight)).foregroundColor(color)
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let fontSize: CGFloat

    var body: some View {
        switch block {
        case .heading(let level, let text):
            InlineMarkdown.text(text, size: headingSize(level), weight: level <= 2 ? .bold : .semibold, color: .white)
                .padding(.top, level <= 2 ? 4 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .paragraph(let text):
            InlineMarkdown.text(text, size: fontSize)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .code(let language, let code):
            CodeBlockView(language: language, code: code, fontSize: fontSize)

        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.white.opacity(0.25)).frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(inner.enumerated()), id: \.offset) { _, b in
                        MarkdownBlockView(block: b, fontSize: fontSize).opacity(0.8)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        marker(ordered: ordered, number: start + idx, checked: item.checked)
                        VStack(alignment: .leading, spacing: 4) {
                            InlineMarkdown.text(item.text, size: fontSize)
                                .strikethrough(item.checked == true, color: Theme.textFaint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                                MarkdownBlockView(block: child, fontSize: fontSize)
                            }
                        }
                    }
                }
            }

        case .table(let header, let alignments, let rows):
            TableBlockView(header: header, alignments: alignments, rows: rows, fontSize: fontSize)

        case .rule:
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func marker(ordered: Bool, number: Int, checked: Bool?) -> some View {
        if let checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: fontSize - 1))
                .foregroundStyle(checked ? Theme.green : Theme.textDim)
        } else if ordered {
            Text("\(number).").font(.system(size: fontSize, design: .monospaced)).foregroundStyle(Theme.textDim)
                .frame(minWidth: 16, alignment: .trailing)
        } else {
            Text("•").font(.system(size: fontSize, weight: .bold)).foregroundStyle(Theme.textDim)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return fontSize + 5
        case 2: return fontSize + 3
        case 3: return fontSize + 1.5
        default: return fontSize
        }
    }
}

private struct CodeBlockView: View {
    let language: String
    let code: String
    let fontSize: CGFloat
    @ViewState private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textFaint)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                }
                .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.white.opacity(0.04))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: fontSize - 1.5, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rowBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct TableBlockView: View {
    let header: [String]
    let alignments: [HorizontalAlignment]
    let rows: [[String]]
    let fontSize: CGFloat

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { c, cell in
                        cellView(cell, column: c, bold: true)
                    }
                }
                .background(Color.white.opacity(0.07))
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { c, cell in
                            cellView(cell, column: c, bold: false)
                        }
                    }
                    .background(r % 2 == 1 ? Color.white.opacity(0.025) : Color.clear)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.rowBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func cellView(_ text: String, column: Int, bold: Bool) -> some View {
        let align = column < alignments.count ? alignments[column] : .leading
        return InlineMarkdown.text(text, size: fontSize - 1, weight: bold ? .semibold : .regular)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 40, maxWidth: 280, alignment: Alignment(horizontal: align, vertical: .center))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .overlay(Rectangle().stroke(Theme.rowBorder, lineWidth: 0.5))
    }
}
