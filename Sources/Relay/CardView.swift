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
                    .onAppear { if item.kind == .finished { store.requestNextSteps(item.id) } }
            } else {
                emptyState
            }
        }
        .frame(width: 344 * look.textScale, alignment: .leading)
        .background(Glass())
        .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
        .padding(16)
        .preferredColorScheme(.dark)
        .onChange(of: replyFocus) { ui.replyFocused = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .relayFocusReply)) { _ in replyFocus = true }
    }

    // MARK: Layout

    private func content(_ item: InboxItem) -> some View {
        let committing = ui.commit?.itemId == item.id
        return VStack(alignment: .leading, spacing: 9) {
            InboxFilterBar(store: store)
            header(item)
            subheader(item, committing: committing)
            if let p = item.prompt, !p.isEmpty { promptBubble(p) }
            if let a = item.activity, !a.isEmpty { activityLine(a) }
            switch item.kind {
            case .question: questionBody(item)
            case .permission: permissionBody(item)
            case .waiting, .finished: messageBody(item)
            }
            if committing, let c = ui.commit {
                CommitBar(commit: c) { ui.undo() }
            } else {
                composer(item)
                actions(item)
                if item.kind == .finished { nextSteps(item) }
            }
            if let toast = store.toast, !committing {
                Text(toast).font(look.font(10.5, .medium)).foregroundStyle(Color.white.opacity(0.75))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .animation(.easeOut(duration: 0.14), value: committing)
        .animation(.easeOut(duration: 0.14), value: ui.questionStep)
    }

    private func header(_ item: InboxItem) -> some View {
        let items = store.filteredItems
        let index = items.firstIndex { $0.id == item.id } ?? 0
        return HStack(spacing: 6) {
            Text(title(item))
                .font(look.font(13.5, .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if items.count > 1 {
                if ui.cardIsKey {
                    Text("\(index + 1) of \(items.count)").font(look.font(10.5, .medium)).foregroundStyle(Theme.textDim)
                } else {
                    PageDots(count: items.count, index: index)
                }
                navButton("chevron.left", key: "J") { ui.move(-1, store: store) }
                navButton("chevron.right", key: "K") { ui.move(1, store: store) }
            }
            HStack(spacing: 3) {
                IconButton(systemName: "xmark", size: 10.5, action: onClose)
                if ui.cardIsKey { KeyHint(key: "esc") }
            }
            .padding(.trailing, ui.cardIsKey ? 3 : 0)
            .background(ui.cardIsKey ? Capsule().fill(Color.white.opacity(0.06)) : nil)
        }
    }

    private func navButton(_ icon: String, key: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 3) {
            IconButton(systemName: icon, size: 10.5, action: action)
            if ui.cardIsKey { KeyHint(key: key) }
        }
        .padding(.trailing, ui.cardIsKey ? 3 : 0)
        .background(ui.cardIsKey ? Capsule().fill(Color.white.opacity(0.06)) : nil)
    }

    private func subheader(_ item: InboxItem, committing: Bool) -> some View {
        let s = store.session(for: item)
        let ws = store.workspace(item.workspaceId)
        return HStack(spacing: 7) {
            AgentMark(status: s?.shownStatus ?? .ready, size: 15)
            Text([statusPhrase(item, committing: committing), s?.folderName].compactMap { $0 }.joined(separator: " · "))
                .font(look.font(11.5))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let ws, store.workspaces.count > 1 { WorkspaceChip(workspace: ws) }
        }
        .contentShape(Rectangle())
        .onTapGesture { NotificationCenter.default.post(name: .relayViewSession, object: item.sessionId) }
        .help("View this agent's session")
    }

    private func promptBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 36)
            Text(text)
                .font(look.font(11.5, .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .truncationMode(.tail)
                .padding(.horizontal, 10).padding(.vertical, 5.5)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(hex: "#2D6BDB")))
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
                    .padding(.top, 2)
                VStack(spacing: 5) {
                    ForEach(Array(q.options.enumerated()), id: \.offset) { i, opt in
                        ChoiceRow(number: i + 1, label: CardLogic.cleanLabel(opt.label), detail: opt.description,
                                  recommended: CardLogic.isRecommended(opt.label),
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
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.05)))
                VStack(spacing: 5) {
                    ChoiceRow(number: 1, label: "Submit answers", detail: nil, recommended: false,
                              selected: ui.flashSelected == 0, dimmed: ui.flashSelected == 1, danger: false) {
                        CardLogic.choose(0, item: item, store: store, ui: ui)
                    }
                    ChoiceRow(number: 2, label: "Cancel", detail: nil, recommended: false,
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
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.32)))
            }
            VStack(spacing: 5) {
                ForEach(Array(opts.enumerated()), id: \.offset) { i, opt in
                    ChoiceRow(number: i + 1, label: opt.0, detail: nil, recommended: false,
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

    private func messageBody(_ item: InboxItem) -> some View {
        Group {
            if !item.body.isEmpty {
                ScrollView {
                    MarkdownView(text: item.body, fontSize: 12 * look.textScale)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 230)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.06)))
            }
        }
    }

    // MARK: Composer and actions

    private func composer(_ item: InboxItem) -> some View {
        let name = title(item)
        let short = name.count > 16 ? String(name.prefix(15)) + "…" : name
        let placeholder = item.isActionable ? "Type your answer…" : "Reply to \(short)"
        let empty = ui.replyText.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: 7) {
            Button { ui.attachShot.toggle() } label: {
                Image(systemName: "camera")
                    .font(look.font(11.5))
                    .foregroundStyle(ui.attachShot ? Theme.blue : Color.white.opacity(0.75))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(ui.attachShot ? 0.14 : 0.07)))
            }
            .buttonStyle(.plain)
                .focusable(false)
            .help(ui.attachShot ? "A screenshot will be attached" : "Attach a screenshot  (S)")
            if ui.cardIsKey && !replyFocus { KeyHint(key: "S") }

            HStack(spacing: 6) {
                TextField(placeholder, text: $ui.replyText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(look.font(12))
                    .lineLimit(1...4)
                    .focused($replyFocus)
                    .onSubmit { send(item) }
                if ui.cardIsKey && !replyFocus && empty { KeyHint(key: "space") }
                IconButton(systemName: "mic", size: 11.5) { onVoiceReply(item) }
                    .help("Say it  (V)")
                if ui.cardIsKey && !replyFocus { KeyHint(key: "V") }
                Button { send(item) } label: {
                    Image(systemName: "arrow.up")
                        .font(look.font(10.5, .bold))
                        .foregroundStyle(empty ? Theme.textFaint : .white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(empty ? Color.white.opacity(0.06) : Theme.blue))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .disabled(empty)
            }
            .padding(.leading, 11).padding(.trailing, 4).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .overlay(Capsule().stroke(replyFocus ? Color.white.opacity(0.22) : Color.clear, lineWidth: 1))
        }
    }

    private func actions(_ item: InboxItem) -> some View {
        HStack(spacing: 6) {
            Spacer()
            if !item.isActionable && store.canKill(item.sessionId) {
                Button { CardLogic.kill(item, store: store, ui: ui) } label: {
                    HStack(spacing: 4) {
                        Text("Kill agent")
                        if ui.cardIsKey { KeyHint(key: "⇧X") }
                    }
                }
                .buttonStyle(PillButtonStyle(destructive: true))
                .focusable(false)
            }
            Button { CardLogic.discard(item, store: store, ui: ui) } label: {
                HStack(spacing: 4) {
                    Text("Discard")
                    if ui.cardIsKey { KeyHint(key: "E", onLight: true) }
                }
            }
            .buttonStyle(PillButtonStyle(light: true))
                .focusable(false)
        }
    }

    private func nextSteps(_ item: InboxItem) -> some View {
        Group {
            switch item.nextStepsState {
            case .loading:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Next steps").font(look.font(11.5, .semibold)).foregroundStyle(Color.white.opacity(0.85))
                    ShimmerText(text: "Thinking of next steps…")
                }
            case .ready where !item.nextSteps.isEmpty:
                VStack(alignment: .leading, spacing: 5) {
                    Text("Next steps").font(look.font(11.5, .semibold)).foregroundStyle(Color.white.opacity(0.85))
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
        .padding(.top, 2)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Inbox").font(look.font(13.5, .semibold)).foregroundStyle(.white)
                Spacer()
                IconButton(systemName: "xmark", size: 10.5, action: onClose)
            }
            if store.visibleItems.isEmpty {
                Text("Nothing is waiting on you.").font(look.font(12)).foregroundStyle(Theme.textDim)
            } else {
                InboxFilterBar(store: store)
                Text(store.inboxFilter == .asking ? "No agent is asking you anything." : "No finished turns to show.")
                    .font(look.font(12)).foregroundStyle(Theme.textDim)
            }
            if store.visibleSessions.isEmpty {
                Text("Start Claude Code in any terminal or the Claude app. Agents show up here on their own.")
                    .font(look.font(11)).foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
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

    static func isRecommended(_ s: String) -> Bool { s.lowercased().contains("(recommended)") }

    /// True while the card still shows this item.
    static func stillShowing(_ item: InboxItem, store: Store, ui: UIState) -> Bool {
        store.items.contains { $0.id == item.id } && ui.currentItem(in: store)?.id == item.id
    }

    static func choose(_ index: Int, item: InboxItem, store: Store, ui: UIState) {
        // Same guard for clicks as for keys: nothing lands on a card that just replaced another.
        guard ui.acceptsChoiceKeys, stillShowing(item, store: store, ui: ui) else { return }
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
        ui.schedule(itemId: item.id, label: answering ? "Answer sent" : "Message sent") {
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
    var recommended: Bool
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
                    RoundedRectangle(cornerRadius: 4.5).fill(selected ? Theme.green : Color.white.opacity(0.09))
                    if selected {
                        Image(systemName: "checkmark").font(look.font(8.5, .heavy)).foregroundStyle(.black)
                    } else {
                        Text("\(number)").font(look.font(9.5, .semibold)).foregroundStyle(Theme.textDim)
                    }
                }
                .frame(width: 17, height: 17)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(look.font(12, .medium))
                        .foregroundStyle(danger ? Color(hex: "#FF6B6B") : .white)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(look.font(10.5)).foregroundStyle(Theme.textFaint)
                            .multilineTextAlignment(.leading).lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                if recommended {
                    Text("Recommended")
                        .font(look.font(9, .semibold)).foregroundStyle(Theme.amber)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.amber.opacity(0.15)))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color(hex: "#1E5B33").opacity(0.85) : Color.white.opacity(hover ? 0.1 : 0.055))
            )
            .opacity(dimmed ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
                .focusable(false)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: selected)
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
                icon.font(look.font(13))
                Text(commit.label).font(look.font(12, .semibold)).foregroundStyle(.white).lineLimit(1)
                Spacer()
                Button(action: onUndo) {
                    HStack(spacing: 4) {
                        KeyHint(key: "esc")
                        Text("to undo").font(look.font(10.5, .medium)).foregroundStyle(Theme.textDim)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            TimelineView(.animation) { ctx in
                let f = max(0, 1 - ctx.date.timeIntervalSince(commit.started) / commit.duration)
                GeometryReader { geo in
                    Capsule().fill(Theme.blue).frame(width: geo.size.width * f, height: 2)
                }
                .frame(height: 2)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    @ViewBuilder private var icon: some View {
        switch commit.kind {
        case .sent: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
        case .discarded: Image(systemName: "circle.slash").foregroundStyle(Theme.blue)
        case .killed: Image(systemName: "xmark.circle.fill").foregroundStyle(Color(hex: "#FF5F5F"))
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
                .background(RoundedRectangle(cornerRadius: 4.5).fill(Color.white.opacity(0.09)))
            Text(text).font(look.font(12, .medium)).foregroundStyle(.white).lineLimit(2)
            Spacer(minLength: 4)
            IconButton(systemName: "arrow.up.left.and.arrow.down.right", size: 9.5, action: onEdit).help("Edit before sending")
            IconButton(systemName: "arrow.right", size: 10.5, action: onSend).help("Send")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hover ? 0.1 : 0.055)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSend)
        .onHover { hover = $0 }
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

    func makeBody(configuration: Configuration) -> some View {
        let look = Appearance.shared
        return configuration.label
            .font(look.font(11, .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(light ? Color.black.opacity(0.85) : (destructive ? Color(hex: "#FF6B6B") : .white))
            .padding(.horizontal, 10).padding(.vertical, 4.5)
            .background(
                Capsule().fill(light ? Color.white.opacity(configuration.isPressed ? 0.7 : 0.92)
                               : prominent ? Theme.blue.opacity(configuration.isPressed ? 0.7 : 1)
                               : Color.white.opacity(configuration.isPressed ? 0.16 : (destructive ? 0.06 : 0.09)))
            )
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
