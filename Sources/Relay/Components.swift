import SwiftUI
import AppKit

// MARK: - Pieces

struct OptionRow: View {
    var number: Int
    var label: String
    var detail: String?
    var recommended: Bool
    var selected: Bool
    var checkbox: Bool
    var action: () -> Void
    @ViewState private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                ZStack {
                    if selected {
                        RoundedRectangle(cornerRadius: 4).fill(Theme.green)
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                    } else {
                        RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08))
                        Text("\(number)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textDim)
                    }
                }
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textFaint)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 4)
                if recommended {
                    Text("Recommended")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.amber)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.amber.opacity(0.14)))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Theme.selectedFill : (hover ? Color.white.opacity(0.08) : Theme.row)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Theme.selectedBorder : Theme.rowBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
                .focusable(false)
        .onHover { hover = $0 }
    }
}

struct PageDots: View {
    var count: Int
    var index: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<min(count, 7), id: \.self) { i in
                Capsule()
                    .fill(i == min(index, 6) ? Theme.blue : Color.white.opacity(0.25))
                    .frame(width: i == min(index, 6) ? 12 : 4, height: 4)
            }
        }
        .opacity(count > 1 ? 1 : 0)
    }
}

struct AgentAvatar: View {
    var color: Color
    var status: AgentStatus

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(hex: "#D97757").opacity(0.18))
                .overlay(
                    Text("✻").font(.system(size: 14, weight: .bold)).foregroundStyle(Color(hex: "#D97757"))
                )
                .frame(width: 26, height: 26)
            Circle().fill(status.color).frame(width: 8, height: 8)
                .overlay(Circle().stroke(Theme.card, lineWidth: 1.5))
                .offset(x: 2, y: 2)
        }
    }
}

struct WorkspaceChip: View {
    var workspace: Workspace

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(workspace.color).frame(width: 6, height: 6)
            Text(workspace.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(Theme.textDim)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .help(workspace.email ?? "Not signed in")
    }
}

struct SessionRow: View {
    var session: AgentSession
    var workspace: Workspace?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                StatusRing(status: session.status, workspaceColor: nil)
                    .scaleEffect(0.8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("@\(session.handle)").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    Text("\(session.shortPath) · \(session.status.label)")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.textFaint).lineLimit(1)
                }
                Spacer()
                if let workspace { WorkspaceChip(workspace: workspace) }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.row))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
                .focusable(false)
    }
}

/// Renders inline markdown (bold, code, links) from agent messages.
struct MessageText: View {
    var text: String
    var lineLimit: Int?

    var body: some View {
        Group {
            if let attr = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attr)
            } else {
                Text(text)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.white.opacity(0.92))
        .lineLimit(lineLimit)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.75 : 0.95)))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.88))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .overlay(Capsule().stroke(Theme.rowBorder, lineWidth: 1))
    }
}
