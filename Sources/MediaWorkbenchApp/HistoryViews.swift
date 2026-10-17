import MediaCore
import SwiftUI

/// Toolbar button with the History list: every settled edit of this photo, newest first.
struct HistoryButton: View {
    let editor: EditorModel
    @UIState private var shown = false

    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "clock.arrow.circlepath") }
            .help("历史记录：回到之前的任意一步")
            .disabled(editor.historyLog == nil)
            .popover(isPresented: $shown, arrowEdge: .bottom) { HistoryList(editor: editor) }
    }
}

struct HistoryList: View {
    let editor: EditorModel

    var body: some View {
        let log = editor.historyLog
        let steps = log?.steps ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("历史记录").font(.headline)
                Spacer()
                Button("清除") { editor.clearHistory() }
                    .buttonStyle(.borderless).disabled(steps.count <= 1)
                    .help("只保留当前这一步")
            }
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(steps.enumerated()).reversed(), id: \.element.id) { index, step in
                        row(step, label: log?.label(index) ?? "", index: index, position: log?.position ?? 0)
                    }
                }
            }
            .frame(height: min(CGFloat(max(steps.count, 1)) * 31, 372))
            Text("关闭光集后仍会保留，每张最多 80 步。点一步就回到那时；之后再修改，会替换它后面的步骤。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300)
    }

    private func row(_ step: HistoryStep, label: String, index: Int, position: Int) -> some View {
        let current = index == position
        return Button { editor.jumpToHistory(index) } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.caption.weight(.semibold)).opacity(current ? 1 : 0).frame(width: 12)
                Text(label).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Text(Self.time(step.date)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(current ? WorkbenchTheme.selection : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Steps after the current one are what redo or a click brings back.
        .opacity(index > position ? 0.5 : 1)
    }

    private static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
