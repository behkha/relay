import SwiftUI
import AppKit

/// The inbox card: one agent's question, permission prompt or finished turn at a time.
/// Every action runs after a short "esc to undo" countdown, like One.
struct CardView: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState
    @ObservedObject private var look = Appearance.shared
    var onClose: () -> Void
    var onVoiceReply: (InboxItem) -> Void
    @FocusState private var replyFocus: Bool

    var body: some View {
        Group {
            if let item = ui.currentItem(in: store) {
                content(item).id(item.id)
                    .transition(.opacity)
                    .onAppear { if item.kind == .finished { store.requestNextSteps(item.id) } }
            } else {
                emptyState
            }
        }
        .animation(.easeOut(duration: 0.16), value: ui.currentItem(in: store)?.id)
        .frame(width: 360 * look.textScale, alignment: .leading)
        .background(Glass(cornerRadius: 20))
        .floatingPanelShadow()
        // Opens out of the pill: a quick grow from its right edge.
        .scaleEffect(ui.cardOpen ? 1 : 0.92, anchor: .trailing)
        .opacity(ui.cardOpen ? 1 : 0)
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: ui.cardOpen)
        .preferredColorScheme(.dark)
        .onChange(of: replyFocus) { ui.replyFocused = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .relayFocusReply)) { _ in replyFocus = true }
    }

    // MARK: Layout

    private func content(_ item: InboxItem) -> some View {
        let committing = ui.commit?.itemId == item.id
        return VStack(alignment: .leading, spacing: 10) {
            if showsFilterBar { InboxFilterBar(store: store) }
            header(item)
            if ui.showKeys { KeyMap(finished: !item.isActionable).transition(.opacity) }
            subheader(item, committing: committing)
            if let p = item.prompt, !p.isEmpty { promptBubble(p) }
            if item.isActionable, let said = item.said, !said.isEmpty {
                agentBubble(said)
            } else if let a = item.activity, !a.isEmpty, item.isActionable {
                activityLine(a)
            }
            switch item.kind {
            case .question: questionBody(item)
            case .permission: permissionBody(item)
            case .waiting, .finished: messageBody(item)
            }
            if committing, let c = ui.commit {
                CommitBar(commit: c) { ui.undo() }
                    .transition(.asymmetric(insertion: .scale(scale: 0.97).combined(with: .opacity), removal: .opacity))
            } else {
                composer(item)
                if item.isActionable {
                    HStack { Spacer(); discardButton(item, light: false) }
                } else {
                    finishedActions(item)
                }
            }
            if let toast = store.toast, !committing {
                Text(toast).font(look.font(10.5, .medium)).foregroundStyle(Color.white.opacity(0.75))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 13)
        .animation(.easeOut(duration: 0.16), value: committing)
        .animation(.easeOut(duration: 0.16), value: ui.questionStep)
        .animation(.easeOut(duration: 0.14), value: ui.showKeys)
    }

    /// The All · Asking · Done chips only earn their row when there is something to filter.
    private var showsFilterBar: Bool {
        store.inboxFilter != .all || (store.count(.asking) > 0 && store.count(.done) > 0)
    }

    private func header(_ item: InboxItem) -> some View {
        let items = store.filteredItems
        let index = items.firstIndex { $0.id == item.id } ?? 0
        return HStack(spacing: 5) {
            Text(title(item))
                .font(look.font(13.5, .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if items.count > 1 {
                if items.count > 7 {
                    Text("\(index + 1) of \(items.count)").font(look.font(10.5, .medium).monospacedDigit())
                        .foregroundStyle(Theme.textDim)
                } else {
                    PageDots(count: items.count, index: index).padding(.trailing, 2)
                }
                HeaderButton(systemName: "chevron.left", key: ui.cardIsKey ? "J" : nil) { ui.move(-1, store: store) }
                HeaderButton(systemName: "chevron.right", key: ui.cardIsKey ? "K" : nil) { ui.move(1, store: store) }
            }
            HeaderButton(systemName: "questionmark", key: nil, filled: true, selected: ui.showKeys) { ui.showKeys.toggle() }
                .help("Keyboard shortcuts  (?)")
            HeaderButton(systemName: "xmark", key: ui.cardIsKey ? "esc" : nil, action: onClose)
        }
    }

    private func subheader(_ item: InboxItem, committing: Bool) -> some View {
        let s = store.session(for: item)
        let ws = store.workspace(item.workspaceId)
        return HStack(spacing: 7) {
            AgentMark(status: s?.shownStatus ?? .ready, size: 14)
            Text([statusPhrase(item, committing: committing), s?.folderName].compactMap { $0 }.joined(separator: " · "))
                .font(look.font(11.5))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
                .contentTransition(.opacity)
            Spacer(minLength: 4)
            if let ws, store.workspaces.count > 1 { WorkspaceChip(workspace: ws) }
        }
        .contentShape(Rectangle())
        .onTapGesture { NotificationCenter.default.post(name: .relayViewSession, object: item.sessionId) }
        .help("View this agent's session")
    }

    private func promptBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(look.font(12, .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .truncationMode(.tail)
                .padding(.horizontal, 11).padding(.vertical, 6.5)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.promptBubble))
        }
    }

    /// What the agent said before it asked, in a grey bubble on the left.
    private func agentBubble(_ text: String) -> some View {
        HStack {
            Text(MarkdownInline.plain(text))
                .font(look.font(12))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.agentBubble))
            Spacer(minLength: 40)
        }
    }

    private func activityLine(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "gearshape").font(look.font(8.5))
            Text(text).lineLimit(1).truncationMode(.tail)
        }
        .font(look.font(10.5))
        .foregroundStyle(Theme.textFaint)
    }

    // MARK: Bodies

    private func questionBody(_ item: InboxItem) -> some View {
        let qs = item.questions
        let step = min(ui.questionStep, qs.count)
        return VStack(alignment: .leading, spacing: 7) {
            if qs.count > 1 { stepper(qs, step: step) }
            if step < qs.count {
                let q = qs[step]
                Text(q.question).font(look.font(13, .semibold)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1).padding(.bottom, 1)
                VStack(spacing: 5) {
                    ForEach(Array(q.options.enumerated()), id: \.offset) { i, opt in
                        ChoiceRow(number: i + 1, label: opt.label, detail: opt.description,
                                  selected: q.multiSelect ? ui.multiSelection.contains(i) : ui.flashSelected == i,
                                  dimmed: ui.flashSelected != nil && ui.flashSelected != i && !q.multiSelect,
                                  danger: false) {
                            CardLogic.choose(i, item: item, store: store, ui: ui)
                        }
                    }
                }
                if q.multiSelect {
                    HStack {
                        Text("Pick any, then press ⏎").font(look.font(10)).foregroundStyle(Theme.textFaint)
                        Spacer()
                        Button("Next") { CardLogic.submitMulti(item: item, store: store, ui: ui) }
                            .buttonStyle(PillButtonStyle(prominent: true))
                            .focusable(false)
                            .disabled(ui.multiSelection.isEmpty)
                    }
                }
            } else {
                // Review step for multi-question cards.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ready to submit your answers?").font(look.font(13, .semibold)).foregroundStyle(.white)
                    Text("Review your answers").font(look.font(11)).foregroundStyle(Theme.textDim)
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(qs.enumerated()), id: \.offset) { _, q in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(q.header ?? "Answer").font(look.font(10.5, .medium)).foregroundStyle(Theme.textFaint)
                            Text(ui.collected[q.question].map(CardLogic.cleanLabel) ?? "—").font(look.font(11.5)).foregroundStyle(.white).lineLimit(2)
                        }
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
                VStack(spacing: 5) {
                    ChoiceRow(number: 1, label: "Submit answers", detail: nil,
                              selected: ui.flashSelected == 0, dimmed: ui.flashSelected == 1, danger: false) {
                        CardLogic.choose(0, item: item, store: store, ui: ui)
                    }
                    ChoiceRow(number: 2, label: "Cancel", detail: nil,
                              selected: false, dimmed: ui.flashSelected == 0, danger: false) {
                        CardLogic.choose(1, item: item, store: store, ui: ui)
                    }
                }
            }
        }
    }

    private func stepper(_ qs: [AgentQuestion], step: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(Array(qs.enumerated()), id: \.offset) { i, q in
                    StepChip(label: q.header ?? "Question \(i + 1)", state: i < step ? .done : (i == step ? .current : .todo))
                }
                StepChip(label: "Submit", state: step >= qs.count ? .current : .todo)
            }
        }
    }

    private func permissionBody(_ item: InboxItem) -> some View {
        let opts = KeyActions.permissionOptions(item)
        return VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Do you want to proceed?").font(look.font(13, .semibold)).foregroundStyle(.white)
                Text(!item.isLive ? "Claude Code is asking in its window"
                     : item.toolName == "Bash" ? "This command requires approval" : "\(item.title) requires approval")
                    .font(look.font(11)).foregroundStyle(Theme.textDim).lineLimit(1)
            }
            if !item.body.isEmpty {
                ScrollView {
                    Text(item.body)
                        .font(look.font(11, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 84)
                .fixedSize(horizontal: false, vertical: true)
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.45)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.75))
            }
            VStack(spacing: 5) {
                ForEach(Array(opts.enumerated()), id: \.offset) { i, opt in
                    ChoiceRow(number: i + 1, label: opt.0, detail: nil,
                              selected: ui.flashSelected == i,
                              dimmed: ui.flashSelected != nil && ui.flashSelected != i,
                              danger: opt.1 == .deny) {
                        CardLogic.choose(i, item: item, store: store, ui: ui)
                    }
                }
            }
            if !item.isLive {
                Text("Relay started after this prompt appeared, so your choice is typed into the terminal.")
                    .font(look.font(10)).foregroundStyle(Theme.textFaint)
            }
        }
    }

    /// The agent's reply in a grey bubble: short ones hug their text, long ones scroll.
    private func messageBody(_ item: InboxItem) -> some View {
        let text = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = text.count <= 120 && !text.contains("\n")
        return Group {
            if text.isEmpty {
                EmptyView()
            } else if short {
                agentBubble(text)
            } else {
                ScrollView {
                    MarkdownView(text: item.body, fontSize: 12 * look.textScale)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                }
                .frame(maxHeight: 230)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.agentBubble))
            }
        }
    }

    // MARK: Composer and actions

    private func composer(_ item: InboxItem) -> some View {
        let name = title(item)
        let short = name.count > 18 ? String(name.prefix(17)) + "…" : name
        let placeholder = item.isActionable ? "Type your answer…" : "Reply to \(short)"
        let empty = ui.replyText.trimmingCharacters(in: .whitespaces).isEmpty
        let hints = ui.cardIsKey && !replyFocus
        return HStack(spacing: 6) {
            Button { ui.attachShot.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "camera")
                        .font(look.font(11.5))
                        .foregroundStyle(ui.attachShot ? Theme.blue : Color.white.opacity(0.8))
                    if hints { KeyHint(key: "S") }
                }
                .padding(.horizontal, hints ? 6 : 0)
                .frame(minWidth: 28, minHeight: 28)
                .background(Capsule().fill(Color.white.opacity(ui.attachShot ? 0.14 : 0.07)))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(ui.attachShot ? "A screenshot will be attached" : "Attach a screenshot  (S)")

            HStack(spacing: 5) {
                TextField(placeholder, text: $ui.replyText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(look.font(12))
                    .lineLimit(1...4)
                    .focused($replyFocus)
                    .onSubmit { send(item) }
                if hints && empty { KeyHint(key: "space") }
                IconButton(systemName: "mic", size: 11.5) { onVoiceReply(item) }
                    .help("Say it  (V)")
                if hints { KeyHint(key: "V") }
            }
            .padding(.leading, 11).padding(.trailing, 5).padding(.vertical, 3)
            .frame(minHeight: 28)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .overlay(Capsule().stroke(replyFocus ? Color.white.opacity(0.2) : Color.clear, lineWidth: 1))

            Button { send(item) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up").font(look.font(10.5, .bold))
                    Image(systemName: "return").font(look.font(9.5, .semibold)).opacity(empty ? 0.6 : 0.85)
                }
                .foregroundStyle(empty ? Theme.textFaint : .white)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(Capsule().fill(empty ? Color.white.opacity(0.05) : Theme.blue))
                .animation(.easeOut(duration: 0.15), value: empty)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(empty)
        }
    }

    private func discardButton(_ item: InboxItem, light: Bool) -> some View {
        Button { CardLogic.discard(item, store: store, ui: ui) } label: {
            HStack(spacing: 5) {
                Text("Discard")
                if ui.cardIsKey { KeyHint(key: "E", onLight: light) }
            }
        }
        .buttonStyle(PillButtonStyle(light: light, hint: ui.cardIsKey))
        .focusable(false)
    }

    /// Below a finished turn: "Next steps" with Kill agent and Discard on the same line, then the steps.
    private func finishedActions(_ item: InboxItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.75).padding(.top, 2)
            HStack(spacing: 6) {
                if store.nextStepsEnabled || item.nextStepsState != .none {
                    Text("Next steps").font(look.font(12, .semibold)).foregroundStyle(Color.white.opacity(0.5))
                }
                Spacer()
                if store.canKill(item.sessionId) {
                    Button { CardLogic.kill(item, store: store, ui: ui) } label: {
                        HStack(spacing: 5) {
                            Text("Kill agent")
                            if ui.cardIsKey { KeyHint(key: "⇧X") }
                        }
                    }
                    .buttonStyle(PillButtonStyle(destructive: true, hint: ui.cardIsKey))
                    .focusable(false)
                }
                discardButton(item, light: true)
            }
            nextSteps(item)
        }
    }

    private func nextSteps(_ item: InboxItem) -> some View {
        Group {
            switch item.nextStepsState {
            case .loading:
                ShimmerText(text: "Thinking of next steps…").padding(.leading, 2)
            case .ready where !item.nextSteps.isEmpty:
                VStack(spacing: 5) {
                    ForEach(Array(item.nextSteps.enumerated()), id: \.offset) { i, step in
                        NextStepRow(number: i + 1, text: step,
                                    onEdit: { ui.replyText = step; NotificationCenter.default.post(name: .relayFocusReply, object: nil) },
                                    onSend: { CardLogic.sendText(step, item: item, store: store, ui: ui) })
                    }
                }
            default:
                EmptyView()
            }
        }
    }

    private func send(_ item: InboxItem) {
        let text = ui.replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        replyFocus = false
        CardLogic.sendText(text, item: item, store: store, ui: ui)
    }

    // MARK: Helpers

    private func title(_ item: InboxItem) -> String {
        store.session(for: item)?.displayName ?? item.title
    }

    private func statusPhrase(_ item: InboxItem, committing: Bool) -> String {
        if committing, let c = ui.commit {
            switch c.kind {
            case .sent: return c.label
            case .discarded: return "Discarded"
            case .killed: return "Agent killed"
            }
        }
        switch item.kind {
        case .question:
            return ui.questionStep > 0 ? "Waiting for the next question" : "Waiting for your answer"
        case .permission: return "Waiting for your answer"
        case .waiting: return "Waiting for you"
        case .finished: return "Finished " + Self.relative(item.createdAt)
        }
    }

    static func relative(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        return "\(Int(s / 86400))d ago"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Inbox").font(look.font(13.5, .semibold)).foregroundStyle(.white)
                Spacer()
                HeaderButton(systemName: "xmark", key: nil, filled: true, action: onClose)
            }
            if !store.visibleItems.isEmpty { InboxFilterBar(store: store) }
            HStack(alignment: .top, spacing: 12) {
                Mascot(size: 30).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(emptyTitle).font(look.font(13, .semibold)).foregroundStyle(.white)
                    Text(emptyDetail)
                        .font(look.font(12)).foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 15).padding(.top, 13).padding(.bottom, 14)
    }

    private var emptyTitle: String {
        if store.visibleItems.isEmpty { return "Nothing needs you." }
        return store.inboxFilter == .asking ? "No agent is asking you anything." : "No finished turns to show."
    }

    private var emptyDetail: String {
        if store.visibleSessions.isEmpty {
            return "Start Claude Code in any terminal or the Claude app. Agents show up here on their own."
        }
        return store.visibleItems.isEmpty ? "Suspiciously quiet. Questions and finished work land here."
                                          : "Pick another filter to see the rest."
    }
}

/// A header control: a chevron, "?" or close, with its key beside it while the card has focus.
private struct HeaderButton: View {
    var systemName: String
    var key: String?
    var filled = false
    var selected = false
    var action: () -> Void
    @ViewState private var hover = false
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(look.font(systemName == "questionmark" ? 10 : 10.5, .bold))
                    .foregroundStyle(Color.white.opacity(hover || selected ? 1 : 0.75))
                    .frame(width: 13)
                if let key { KeyHint(key: key) }
            }
            .padding(.leading, key == nil ? 0 : 6).padding(.trailing, key == nil ? 0 : 3)
            .frame(minWidth: 23, minHeight: 23)
            .background(Capsule().fill(Color.white.opacity(selected ? 0.2 : (hover ? 0.13 : (filled || key != nil ? 0.08 : 0)))))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .focusable(false)
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hover = h } }
    }
}

/// The card's "?" panel: every key it understands.
private struct KeyMap: View {
    var finished: Bool
    @ObservedObject private var look = Appearance.shared

    private var rows: [(String, String)] {
        var r: [(String, String)] = finished ? [] : [("1–9", "Pick an answer")]
        r += [
            ("J  K", "Previous · next"),
            ("space", "Type a reply"),
            ("V", "Say it"),
            ("S", "Attach a screenshot"),
            ("E", "Discard"),
        ]
        if finished { r.append(("⇧X", "Kill the agent")) }
        r += [("O", "Open its session"), ("T", "Go to its terminal"), ("esc", "Undo · close")]
        return r
    }

    var body: some View {
        let half = (rows.count + 1) / 2
        HStack(alignment: .top, spacing: 12) {
            column(Array(rows.prefix(half)))
            column(Array(rows.dropFirst(half)))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    private func column(_ items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 7) {
                    KeyHint(key: row.0).frame(minWidth: 34, alignment: .leading)
                    Text(row.1).font(look.font(10.5)).foregroundStyle(Theme.textDim).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Markdown markers stripped for one-line previews.
enum MarkdownInline {
    static func plain(_ s: String) -> String {
        var t = s
        for m in ["**", "__", "`"] { t = t.replacingOccurrences(of: m, with: "") }
        return t.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// All · Asking · Done, with counts. Picks which inbox items the card pages through.
struct InboxFilterBar: View {
    @ObservedObject var store: Store
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        HStack(spacing: 4) {
            ForEach(InboxFilter.allCases, id: \.self) { f in
                FilterChip(label: f.label, count: store.count(f), selected: store.inboxFilter == f) {
                    store.inboxFilter = f
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct FilterChip: View {
    var label: String
    var count: Int
    var selected: Bool
    var action: () -> Void
    @ObservedObject private var look = Appearance.shared
    @ViewState private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label).font(look.font(10.5, .semibold))
                Text("\(count)").font(look.font(10, .medium).monospacedDigit())
                    .foregroundStyle(selected ? Color.black.opacity(0.55) : Theme.textFaint)
            }
            .foregroundStyle(selected ? Color.black : (hover ? Color.white : Theme.textDim))
            .padding(.horizontal, 8).padding(.vertical, 3.5)
            .background(Capsule().fill(selected ? Color.white : Color.white.opacity(hover ? 0.1 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hover = $0 }
    }
}

// MARK: - Actions

/// What the card's clicks and keys do. Choices run through the undo window.
enum CardLogic {
    static func cleanLabel(_ s: String) -> String {
        s.replacingOccurrences(of: "(Recommended)", with: "").replacingOccurrences(of: "(recommended)", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// True while the card still shows this item.
    static func stillShowing(_ item: InboxItem, store: Store, ui: UIState) -> Bool {
        store.items.contains { $0.id == item.id } && ui.currentItem(in: store)?.id == item.id
    }

    static func choose(_ index: Int, item: InboxItem, store: Store, ui: UIState) {
        // Same guard for clicks as for keys: nothing lands on a card that just replaced another.
        guard ui.acceptsChoiceKeys, stillShowing(item, store: store, ui: ui) else { return }
        ui.autoOpened = false
        switch item.kind {
        case .question:
            let qs = item.questions
            let step = min(ui.questionStep, qs.count)
            if step >= qs.count {
                // Review step: 1 submits, 2 starts over.
                if index == 0 {
                    ui.flashSelected = 0
                    let answers = ui.collected
                    ui.schedule(itemId: item.id, label: "Answer sent") { store.answerQuestion(item, answers: answers) }
                } else if index == 1 {
                    ui.questionStep = 0
                    ui.collected = [:]
                    ui.multiSelection = []
                }
                return
            }
            let q = qs[step]
            guard index < q.options.count else { return }
            if q.multiSelect {
                if ui.multiSelection.contains(index) { ui.multiSelection.remove(index) } else { ui.multiSelection.insert(index) }
                return
            }
            ui.flashSelected = index
            ui.collected[q.question] = q.options[index].label
            advance(item: item, store: store, ui: ui)
        case .permission:
            let opts = KeyActions.permissionOptions(item)
            guard index < opts.count else { return }
            ui.flashSelected = index
            let choice = opts[index].1
            if !item.isLive {
                // Fallback cards type a key into the terminal; no countdown, so it can't land late.
                store.answerPermission(item, choice: choice)
                ui.resetItemState()
                return
            }
            ui.schedule(itemId: item.id, label: "Answer sent") { store.answerPermission(item, choice: choice) }
        default:
            break
        }
    }

    static func submitMulti(item: InboxItem, store: Store, ui: UIState) {
        guard ui.acceptsChoiceKeys, stillShowing(item, store: store, ui: ui) else { return }
        let step = min(ui.questionStep, item.questions.count)
        guard step < item.questions.count else { return }
        let q = item.questions[step]
        let labels = ui.multiSelection.sorted().compactMap { $0 < q.options.count ? q.options[$0].label : nil }
        guard !labels.isEmpty else { return }
        ui.collected[q.question] = labels.joined(separator: ", ")
        ui.multiSelection = []
        ui.flashSelected = -1
        advance(item: item, store: store, ui: ui)
    }

    /// Next question, the review step (several questions), or send (a single question).
    private static func advance(item: InboxItem, store: Store, ui: UIState) {
        if item.questions.count <= 1 {
            let answers = ui.collected
            ui.schedule(itemId: item.id, label: "Answer sent") { store.answerQuestion(item, answers: answers) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            guard stillShowing(item, store: store, ui: ui) else { ui.resetItemState(); return }
            ui.flashSelected = nil
            ui.questionStep += 1
        }
    }

    static func sendText(_ raw: String, item: InboxItem, store: Store, ui: UIState) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, ui.commit == nil else { return }
        let withShot = ui.attachShot && item.kind != .permission
        ui.draftBeforeSend = ui.replyText.isEmpty ? raw : ui.replyText
        ui.replyText = ""
        let answering = item.isActionable
        // Take the screenshot now (what you're looking at), not when the countdown ends.
        let shot = ShotBox()
        if withShot { DispatchQueue.global(qos: .userInitiated).async { shot.path = Screenshot.capture() } }
        // A message shows its own words in the undo bar ("✓ push to prod"); an answer says "Answer sent".
        ui.schedule(itemId: item.id, label: answering ? "Answer sent" : "Message sent", barText: answering ? nil : text) {
            if let path = shot.path { text += "\n\n(Screenshot of what I'm looking at: \(path))" }
            store.reply(to: item, text: text)
        }
    }

    static func discard(_ item: InboxItem, store: Store, ui: UIState) {
        guard stillShowing(item, store: store, ui: ui), ui.commit == nil else { return }
        ui.schedule(itemId: item.id, label: "Discarded", kind: .discarded) { store.dismiss(item) }
    }

    static func kill(_ item: InboxItem, store: Store, ui: UIState) {
        guard stillShowing(item, store: store, ui: ui), ui.commit == nil, store.canKill(item.sessionId) else { return }
        let sid = item.sessionId
        ui.schedule(itemId: item.id, label: "Agent killed", kind: .killed, duration: 2.5) { store.killAgent(sid) }
    }
}

/// Permission options built from what Claude Code offered (rules, directories, modes).
enum KeyActions {
    static func permissionOptions(_ item: InboxItem) -> [(String, Store.PermissionChoice)] {
        var opts: [(String, Store.PermissionChoice)] = [("Yes", .allow)]
        if item.isLive, let sugg = Store.parseJSONArray(item.permissionSuggestionsJSON) {
            for (i, raw) in sugg.enumerated() {
                guard let s = raw as? [String: Any], let label = suggestionLabel(s) else { continue }
                opts.append((label, .allowWith(i)))
            }
        }
        opts.append(("No", .deny))
        return opts
    }

    private static func suggestionLabel(_ s: [String: Any]) -> String? {
        let scope: String
        switch s["destination"] as? String ?? "" {
        case "session": scope = " for this session"
        case "projectSettings", "localSettings": scope = " in this project"
        case "userSettings": scope = " everywhere"
        default: scope = ""
        }
        switch s["type"] as? String ?? "" {
        case "addRules", "replaceRules":
            guard (s["behavior"] as? String ?? "allow") == "allow" else { return nil }
            let rules = (s["rules"] as? [[String: Any]] ?? []).map { r -> String in
                if let c = r["ruleContent"] as? String, !c.isEmpty { return c }
                return r["toolName"] as? String ?? ""
            }.filter { !$0.isEmpty }
            return "Yes, and don't ask again for: " + (rules.isEmpty ? "this" : rules.joined(separator: ", ")) + scope
        case "addDirectories":
            let dirs = (s["directories"] as? [String] ?? []).map { ($0 as NSString).lastPathComponent }
            return "Yes, and allow access to " + (dirs.isEmpty ? "this folder" : dirs.joined(separator: ", ")) + scope
        case "setMode":
            switch s["mode"] as? String ?? "" {
            case "acceptEdits": return "Yes, and switch to accept-edits mode · edits won't ask"
            case "bypassPermissions": return "Yes, and switch to bypass mode · nothing will ask"
            case "plan": return "Yes, and switch to plan mode"
            case "auto": return "Yes, and switch to auto mode · auto mode handles these prompts for you"
            case let m: return "Yes, and switch to \(m) mode"
            }
        default:
            return nil
        }
    }
}

// MARK: - Pieces

struct ChoiceRow: View {
    var number: Int
    var label: String
    var detail: String?
    var selected: Bool
    var dimmed: Bool
    var danger: Bool
    var action: () -> Void
    @ViewState private var hover = false
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(selected ? Theme.green : Color.white.opacity(0.09))
                    if selected {
                        Image(systemName: "checkmark").font(look.font(9, .heavy)).foregroundStyle(.black)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    } else {
                        Text("\(number)").font(look.font(9.5, .semibold)).foregroundStyle(Theme.textDim)
                    }
                }
                .frame(width: 17, height: 17)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(look.font(12.5))
                        .foregroundStyle(danger ? Theme.red : .white)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(look.font(10.5)).foregroundStyle(Theme.textFaint)
                            .multilineTextAlignment(.leading).lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Theme.selectedFill : Color.white.opacity(hover ? 0.1 : 0.055))
            )
            .opacity(dimmed ? 0.4 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selected)
        .animation(.easeOut(duration: 0.18), value: dimmed)
    }
}

struct StepChip: View {
    enum Phase { case done, current, todo }
    var label: String
    var state: Phase
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        HStack(spacing: 4) {
            switch state {
            case .done: Image(systemName: "checkmark").font(look.font(8, .bold)).foregroundStyle(Theme.green)
            case .current: Circle().fill(Theme.amber).frame(width: 6, height: 6)
            case .todo: Circle().stroke(Color.white.opacity(0.45), lineWidth: 1).frame(width: 6, height: 6)
            }
            Text(label).font(look.font(10.5, .medium))
                .foregroundStyle(state == .todo ? Theme.textDim : .white)
                .lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 3.5)
        .background(Capsule().fill(Color.white.opacity(state == .current ? 0.13 : 0.05)))
    }
}

/// "✓ Answer sent · esc to undo" with a draining progress line.
struct CommitBar: View {
    let commit: UIState.Commit
    var onUndo: () -> Void
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                icon.font(look.font(14))
                Text(commit.barText ?? commit.label).font(look.font(12.5, .medium)).foregroundStyle(.white).lineLimit(1)
                Spacer()
                Button(action: onUndo) {
                    HStack(spacing: 5) {
                        KeyHint(key: "esc")
                        Text("to undo").font(look.font(11, .medium)).foregroundStyle(Color.white.opacity(0.85))
                    }
                    .padding(.leading, 3).padding(.trailing, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
            .padding(.horizontal, 11).padding(.top, 9).padding(.bottom, 7)
            TimelineView(.animation) { ctx in
                let f = max(0, 1 - ctx.date.timeIntervalSince(commit.started) / commit.duration)
                GeometryReader { geo in
                    Capsule().fill(Theme.blue).frame(width: geo.size.width * f, height: 2.5)
                }
                .frame(height: 2.5)
            }
            .padding(.horizontal, 9)
            .padding(.bottom, 3)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    @ViewBuilder private var icon: some View {
        switch commit.kind {
        case .sent: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
        case .discarded: Image(systemName: "circle.slash").foregroundStyle(Theme.blue)
        case .killed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.red)
        }
    }
}

struct NextStepRow: View {
    var number: Int
    var text: String
    var onEdit: () -> Void
    var onSend: () -> Void
    @ViewState private var hover = false
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        HStack(spacing: 8) {
            Text("\(number)").font(look.font(9.5, .semibold)).foregroundStyle(Theme.textDim)
                .frame(width: 17, height: 17)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.09)))
            Text(text).font(look.font(12.5)).foregroundStyle(.white).lineLimit(2)
            Spacer(minLength: 4)
            if hover {
                IconButton(systemName: "arrow.up.left.and.arrow.down.right", size: 9.5, action: onEdit).help("Edit before sending")
                    .transition(.opacity)
            }
            Image(systemName: "arrow.right").font(look.font(10.5, .semibold))
                .foregroundStyle(Color.white.opacity(hover ? 0.9 : 0.45))
                .offset(x: hover ? 2 : 0)
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hover ? 0.1 : 0.055)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSend)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help("Send")
    }
}

struct ShimmerText: View {
    var text: String
    @ViewState private var phase = false
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        Text(text).font(look.font(11.5)).foregroundStyle(Theme.textFaint)
            .opacity(phase ? 0.45 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { phase = true } }
    }
}

struct IconButton: View {
    var systemName: String
    var size: CGFloat = 11
    var action: () -> Void
    @ViewState private var hover = false
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(look.font(size, .semibold))
                .foregroundStyle(Color.white.opacity(hover ? 1 : 0.7))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(hover ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
                .focusable(false)
        .onHover { hover = $0 }
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var light = false
    var destructive = false
    /// The label ends with a key hint, which sits closer to the edge.
    var hint = false

    func makeBody(configuration: Configuration) -> some View {
        let look = Appearance.shared
        return configuration.label
            .font(look.font(11.5, .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(light ? Color.black.opacity(0.88) : (destructive ? Theme.red : .white))
            .padding(.leading, 10).padding(.trailing, hint ? 4 : 10).padding(.vertical, 3)
            .frame(minHeight: 25)
            .background(
                Capsule().fill(light ? Color.white.opacity(configuration.isPressed ? 0.7 : 0.94)
                               : prominent ? Theme.blue.opacity(configuration.isPressed ? 0.7 : 1)
                               : destructive ? Theme.red.opacity(configuration.isPressed ? 0.22 : 0.12)
                               : Color.white.opacity(configuration.isPressed ? 0.16 : 0.09))
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

extension Notification.Name {
    static let relayFocusReply = Notification.Name("relayFocusReply")
}

/// Holds a screenshot path filled in on a background thread.
final class ShotBox {
    private let lock = NSLock()
    private var _path: String?
    var path: String? {
        get { lock.lock(); defer { lock.unlock() }; return _path }
        set { lock.lock(); _path = newValue; lock.unlock() }
    }
}
