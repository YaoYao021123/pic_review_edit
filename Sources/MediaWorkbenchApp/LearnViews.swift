import MediaCore
import SwiftUI

/// Coach output for the open photo, computed from the latest scope analysis.
@MainActor
struct CoachState {
    let insights: [CoachInsight]
    let resolved: [CoachInsight]

    init(app: AppModel) {
        let editor = app.editor
        guard let analysis = editor.scopes?.analysis else { insights = []; resolved = []; return }
        let current = PhotoCoach.insights(for: analysis, original: editor.originalAnalysis, faces: editor.faceAnalysis,
                                          edits: editor.edits, profile: app.learner, tilt: editor.horizonTilt,
                                          isVideo: editor.isVideo)
        insights = current
        // Issues present in the untouched photo that the edits have fixed.
        if let original = editor.originalAnalysis, editor.edits.hasGrade || editor.edits.hasGeometry {
            let before = PhotoCoach.insights(for: original, original: original, edits: MediaEdits(), profile: app.learner,
                                             tilt: editor.horizonTilt, isVideo: editor.isVideo)
            let now = Set(current.map(\.id))
            resolved = before.filter { !now.contains($0.id) && $0.id != "skin-ok" && $0.suggestion != nil }
        } else {
            resolved = []
        }
    }
}

/// The most relevant tip, one line, at the top of the color tab.
struct InsightStrip: View {
    let app: AppModel
    var editor: EditorModel { app.editor }

    var body: some View {
        let state = CoachState(app: app)
        Group {
            if let top = state.insights.first, top.severity >= 0.3 {
                HStack(spacing: 6) {
                    Image(systemName: top.symbol).foregroundStyle(.secondary).frame(width: 16)
                    Button { app.inspectorTab = .learn } label: {
                        Text(top.title).font(.caption.weight(.semibold)).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(top.observation + L("\n点按查看讲解"))
                    Spacer(minLength: 4)
                    if top.influence != nil || top.showsClipping {
                        Button("显示") { showArea(top) }.buttonStyle(.borderless).font(.caption)
                    }
                    if let suggestion = top.suggestion {
                        Button("修复") { app.trySuggestion(suggestion, concept: top.concept) }
                            .buttonStyle(.borderless).font(.caption.weight(.semibold))
                            .help("试一试：\(suggestion.label)（可撤销）")
                    }
                }
                .padding(.horizontal, 8).frame(height: 24)
                .background(WorkbenchTheme.well, in: RoundedRectangle(cornerRadius: 6))
                .padding(.bottom, 2)
            }
        }
        .task(id: editor.documentID) { editor.requestHorizon() }
    }

    private func showArea(_ insight: CoachInsight) {
        if insight.showsClipping { editor.showClipping.toggle() }
        else { editor.pinnedInfluence = editor.pinnedInfluence == insight.influence ? nil : insight.influence }
    }
}

struct LearnPanel: View {
    let app: AppModel
    var editor: EditorModel { app.editor }
    @UIState private var showAll = false
    @UIState private var expanded: Concept?

    var body: some View {
        let state = CoachState(app: app)
        let profile = app.learner
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection(L("这张照片"), help: L("根据这张照片当前的样子给出建议；修改后会实时更新。")) {
                VStack(alignment: .leading, spacing: 6) {
                    if editor.scopes == nil {
                        Text("正在分析画面…").font(.caption).foregroundStyle(.secondary)
                    } else if state.insights.isEmpty {
                        Label("没有发现明显的问题。可以从下面的学习路径挑一个技巧，在这张照片上试试。", systemImage: "checkmark.seal")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(showAll ? state.insights : Array(state.insights.prefix(3))) { insight in
                        InsightCard(app: app, insight: insight)
                    }
                    if state.insights.count > 3 {
                        Button(showAll ? L("收起") : L("还有 \(state.insights.count - 3) 条")) { showAll.toggle() }
                            .buttonStyle(.borderless).font(.caption)
                    }
                    if !state.resolved.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(state.resolved) { item in
                                Label(L("已改善：") + item.title, systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(WorkbenchTheme.pick)
                            }
                        }
                        .font(.caption)
                    }
                }
            }
            LessonList(app: app)
            AskSection(app: app)
            InspectorSection(L("我的学习"), help: L("选择水平和感兴趣的方向，讲解和推荐会随之调整。")) {
                VStack(alignment: .leading, spacing: 6) {
                    if !profile.onboarded {
                        Text("告诉我你的水平和想学什么，讲解会更适合你。").font(.caption).foregroundStyle(.secondary)
                    }
                    GlassSegmentedControl(options: LearningLevel.allCases,
                                          selection: Binding(get: { profile.level }, set: { app.learner.level = $0; app.learner.onboarded = true }),
                                          title: { $0.title }, size: .small, accessibilityTitle: L("学习水平"))
                        .frame(maxWidth: AppLanguage.current == .chinese ? 200 : .infinity)
                    FlowLayout(spacing: 4) {
                        ForEach(LearningTopic.allCases, id: \.self) { topic in
                            let on = profile.topics.contains(topic)
                            Button {
                                if on { app.learner.topics.remove(topic) } else { app.learner.topics.insert(topic) }
                                app.learner.onboarded = true
                            } label: {
                                Text(topic.title).font(.caption)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .foregroundStyle(on ? Color.black : .primary)
                                    .background(Capsule().fill(on ? Color.white.opacity(0.85) : WorkbenchTheme.well))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    Toggle("悬停参数名时，在画面上显示影响范围", isOn: Binding(get: { profile.hoverHints }, set: { app.learner.hoverHints = $0 }))
                        .toggleStyle(.checkbox).font(.caption)
                }
            }
            InspectorSection(L("学习路径"), help: L("按你选的方向排列；在照片上演示过或常用的技巧会打勾。")) {
                VStack(alignment: .leading, spacing: 2) {
                    let path = profile.path
                    ProgressView(value: Double(profile.learnedInPath), total: Double(max(1, path.count)))
                        .controlSize(.small).tint(WorkbenchTheme.control)
                    Text("已掌握 \(profile.learnedInPath) / \(path.count)").font(.caption2).foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                    ForEach(path, id: \.self) { concept in
                        ConceptRow(app: app, concept: concept, expanded: expanded == concept) {
                            expanded = expanded == concept ? nil : concept
                        }
                    }
                }
            }
            let muted = Concept.allCases.filter { profile.state($0).muted }
            if !muted.isEmpty {
                Button("恢复已关闭的提示（\(muted.count)）", action: app.unmuteAll)
                    .buttonStyle(.borderless).font(.caption).padding(.top, 8)
            }
        }
        .task(id: editor.documentID) {
            editor.requestHorizon()
            try? await Task.sleep(for: .seconds(1.5))
            app.markShown(Array(CoachState(app: app).insights.prefix(3)))
        }
    }
}

struct InsightCard: View {
    let app: AppModel
    let insight: CoachInsight
    @UIState private var showWhy = false
    var editor: EditorModel { app.editor }

    var body: some View {
        let learned = app.learner.isLearned(insight.concept)
        let areaOn = insight.showsClipping ? editor.showClipping : editor.pinnedInfluence == insight.influence && insight.influence != nil
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: insight.symbol).foregroundStyle(.secondary).frame(width: 16)
                Text(insight.title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Menu {
                    Button("👍 有帮助") { app.feedback(.helpful, on: insight.concept) }
                    Button("我已经了解「\(insight.concept.title)」") { app.feedback(.known, on: insight.concept) }
                    Button("不再提示这类内容") { app.feedback(.mute, on: insight.concept) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("告诉我这条提示是否有用，之后的推荐会随之调整")
            }
            Text(insight.observation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !learned || showWhy {
                Text(insight.why).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            if let suggestion = insight.suggestion, suggestion.changesEdits {
                Label(suggestion.label, systemImage: "wand.and.stars").font(.caption.weight(.medium)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if insight.influence != nil || insight.showsClipping {
                    Button(areaOn ? L("隐藏区域") : L("显示区域")) {
                        if insight.showsClipping { editor.showClipping.toggle() }
                        else { editor.pinnedInfluence = areaOn ? nil : insight.influence }
                    }
                }
                if let suggestion = insight.suggestion {
                    Button(suggestion.changesEdits ? L("试一试") : suggestion.label) { app.trySuggestion(suggestion, concept: insight.concept) }
                        .help("作为一步应用，左右对比查看效果；⌘Z 撤销")
                }
                if learned, !showWhy {
                    Button("为什么？") { showWhy = true }.buttonStyle(.borderless)
                }
            }
            .glassButton().controlSize(.mini).font(.caption)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(WorkbenchTheme.well))
    }
}

struct ConceptRow: View {
    let app: AppModel
    let concept: Concept
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        let learned = app.learner.isLearned(concept)
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: learned ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(learned ? WorkbenchTheme.pick : .secondary).font(.caption)
                    Text(concept.title).font(.caption)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(height: 20)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(concept.explanation(for: app.learner.level))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let demo = concept.demo {
                        Label(L("演示：") + demo.label, systemImage: "wand.and.stars").font(.caption.weight(.medium)).foregroundStyle(.primary)
                    }
                    HStack(spacing: 6) {
                        if let demo = concept.demo {
                            Button("演示") { app.trySuggestion(demo, concept: concept) }
                                .disabled(!app.editor.isLoaded)
                                .help("在这张照片上演示：\(demo.label)（可撤销）")
                        }
                        if let influence = concept.influence, !app.editor.isVideo {
                            let on = app.editor.pinnedInfluence == influence
                            Button(on ? L("隐藏区域") : L("看它影响哪里")) { app.editor.pinnedInfluence = on ? nil : influence }
                        }
                        if !learned { Button("已了解") { app.feedback(.known, on: concept) }.buttonStyle(.borderless) }
                    }
                    .glassButton().controlSize(.mini).font(.caption)
                }
                .padding(.leading, 20).padding(.bottom, 4)
            }
        }
    }
}

// MARK: - Ask about this photo (optional, cloud)

struct AskSection: View {
    let app: AppModel
    var tutor: TutorModel { app.tutor }

    var body: some View {
        InspectorSection(L("问问这张照片"), help: L("用 AI 回答关于这张照片的任何问题；回答会结合画面和你的水平。只有你提问时才会发送数据。")) {
            if tutor.isReady {
                conversation
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("想知道这张照片的任何事，都可以直接问，比如「天空为什么发灰？」「怎么调出胶片感？」。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("需要你自己的 Anthropic API 密钥；默认关闭，只在你提问时发送。")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Button("设置…") { app.sheet = .tutorSettings }.glassButton().controlSize(.small)
                }
            }
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(tutor.turns) { turn in TurnView(app: app, turn: turn) }
            if tutor.isAsking {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在看这张照片…").font(.caption).foregroundStyle(.secondary) }
            }
            if tutor.turns.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(quickQuestions, id: \.self) { question in
                        Button(question) { app.askTutor(question) }
                            .buttonStyle(.plain).font(.caption)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(WorkbenchTheme.well))
                    }
                }
            }
            if tutor.turns.count < TutorModel.maxTurns {
                HStack(alignment: .bottom, spacing: 6) {
                    TextField("问点什么…", text: Binding(get: { tutor.draft }, set: { tutor.draft = $0 }), axis: .vertical)
                        .lineLimit(1...4).textFieldStyle(.roundedBorder).font(.caption)
                        .onSubmit { app.askTutor(tutor.draft) }
                    Button { app.askTutor(tutor.draft) } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 18)) }
                        .buttonStyle(.plain).foregroundStyle(.primary)
                        .disabled(tutor.isAsking || tutor.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("提问（⏎）")
                }
            } else {
                Text("这段对话已经很长了，开始新对话可以更聚焦。").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(tutor.modelTitle + L(" · 发送") + (tutor.settings.sendPreview ? L("预览图、") : "") + L("画面统计与参数"))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 4)
                if !tutor.turns.isEmpty { Button("新对话", action: tutor.reset).buttonStyle(.borderless).font(.caption2) }
                Button("设置") { app.sheet = .tutorSettings }.buttonStyle(.borderless).font(.caption2)
            }
        }
    }

    /// Starter questions adapted to the photo's top tip, the level and the chosen topics.
    private var quickQuestions: [String] {
        var list = [L("这张照片最该先调什么？")]
        if let top = CoachState(app: app).insights.first { list.append(L("「\(top.title)」是怎么回事？")) }
        let profile = app.learner
        if profile.topics.contains(.portrait) { list.append(L("肤色怎么调得更自然？")) }
        if profile.topics.contains(.landscape) { list.append(L("天空怎么更有层次？")) }
        if profile.topics.contains(.cinematic) { list.append(L("怎么调出电影感？")) }
        switch profile.level {
        case .beginner: list.append(L("直方图怎么看？"))
        case .intermediate: list.append(L("这张适合用曲线吗？"))
        case .advanced: list.append(L("从示波器看，这张还有什么问题？"))
        }
        return Array(list.prefix(4))
    }
}

private struct TurnView: View {
    let app: AppModel
    let turn: TutorTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Spacer(minLength: 24)
                Text(turn.question).font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .fixedSize(horizontal: false, vertical: true)
                    .help(turn.sentPreview ? L("已附带当时的预览图") : L("未附带预览图"))
            }
            if let answer = turn.answer {
                Text(answer.answer).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(answer.suggestions.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 6) {
                        Label(item.label, systemImage: "wand.and.stars").font(.caption.weight(.medium)).foregroundStyle(.primary)
                        Spacer(minLength: 4)
                        Button("试一试") { app.tryTutorSuggestion(item) }.glassButton().controlSize(.mini).font(.caption)
                            .help("作为一步应用，左右对比查看效果；⌘Z 撤销")
                    }
                }
                if !answer.followUps.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(answer.followUps, id: \.self) { question in
                            Button(question) { app.askTutor(question) }
                                .buttonStyle(.plain).font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().strokeBorder(WorkbenchTheme.hairline))
                                .disabled(app.tutor.isAsking)
                        }
                    }
                }
            } else if let error = turn.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 互动课: short animated lessons that run on the open photo.
struct LessonList: View {
    let app: AppModel
    var body: some View {
        let done = app.learner.lessonsDone
        InspectorSection(L("互动课"), help: L("几分钟一课：用动画和你的照片讲清原理，边看边动手。")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("已完成 \(Lesson.catalog.filter { done.contains($0.id) }.count) / \(Lesson.catalog.count) 课")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(LessonUnit.allCases, id: \.self) { unit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(unit.title).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        ForEach(Lesson.catalog.filter { $0.unit == unit }) { lesson in
                            Button { app.openLesson(lesson.id) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: done.contains(lesson.id) ? "checkmark.circle.fill" : "play.circle")
                                        .foregroundStyle(done.contains(lesson.id) ? Color.secondary : Color.primary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(lesson.title).font(.callout)
                                        Text(lesson.hook).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    Text("\(lesson.minutes) 分钟").font(.caption2).foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(lesson.hook)
                        }
                    }
                }
            }
        }
    }
}
