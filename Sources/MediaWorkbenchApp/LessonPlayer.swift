import MediaCore
import SwiftUI

/// A lesson in a large sheet: the interactive scene on the left, the step's words, a check
/// question and navigation on the right.
struct LessonPlayer: View {
    let app: AppModel
    let lesson: Lesson
    @UIState private var index = LessonPlayer.debugStartStep
    /// Developer snapshots open a lesson at a given step.
    nonisolated(unsafe) static var debugStartStep = 0
    @UIState private var photo: LessonPhoto?
    @UIState private var started = Date()
    @UIState private var chosen: Int?

    private var step: LessonStep { lesson.steps[index] }

    var body: some View {
        VStack(spacing: 0) {
            header
            WorkbenchTheme.hairline.frame(height: 1)
            HStack(spacing: 0) {
                ZStack {
                    WorkbenchTheme.canvas
                    if let photo {
                        LessonSceneView(scene: step.scene, photo: photo, started: started)
                            .id("\(lesson.id)-\(index)-\(started.timeIntervalSince1970)")
                            .padding(20)
                            .transition(.opacity)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                WorkbenchTheme.hairline.frame(width: 1)
                side.frame(width: 290)
            }
        }
        .frame(width: 980, height: 640)
        .task { if photo == nil { photo = LessonPhoto.make(from: app.editor) } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(lesson.unit.title).font(.caption).foregroundStyle(.secondary)
                Text(lesson.title).font(.headline)
            }
            Spacer()
            HStack(spacing: 5) {
                ForEach(lesson.steps.indices, id: \.self) { i in
                    Capsule().fill(i == index ? Color.primary : i < index ? Color.secondary : Color.secondary.opacity(0.3))
                        .frame(width: i == index ? 18 : 7, height: 7)
                }
            }
            .animation(.snappy, value: index)
            Spacer()
            Button("关闭") { app.sheet = nil }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18).frame(height: 54)
    }

    private var side: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("第 \(index + 1) 步，共 \(lesson.steps.count) 步").font(.caption).foregroundStyle(.secondary)
            Text(step.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text(step.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
            if let photo, !photo.isUsersPhoto, index == 0 {
                Label("打开一张自己的照片再上课，演示就会用你的照片。", systemImage: "photo")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if let question = step.question, let photo { questionView(question, photo) }
            Spacer()
            HStack {
                Button { restart() } label: { Label("重播", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                Spacer()
                if index > 0 { Button("上一步") { go(index - 1) }.glassButton() }
                if index < lesson.steps.count - 1 {
                    Button("下一步") { go(index + 1) }.primaryButton().keyboardShortcut(.defaultAction)
                } else {
                    Button("完成") { finish() }.primaryButton().keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
    }

    private func questionView(_ question: LessonQuestion, _ photo: LessonPhoto) -> some View {
        let correct = question.correctIndex(zoneShares: ToneZone.shares(photo.histogram))
        return VStack(alignment: .leading, spacing: 6) {
            Text("想一想").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
            Text(question.prompt).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            ForEach(question.options.indices, id: \.self) { i in
                Button { withAnimation(.snappy) { chosen = i } } label: {
                    HStack {
                        Text(question.options[i]).font(.callout).multilineTextAlignment(.leading)
                        Spacer()
                        if let chosen, i == correct { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        else if chosen == i { Image(systemName: "xmark.circle").foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(chosen == i ? WorkbenchTheme.selection : WorkbenchTheme.well))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let chosen {
                Text((chosen == correct ? L("答对了。") : L("再看看画面。")) + question.explanation)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func go(_ next: Int) {
        withAnimation(.easeInOut(duration: 0.2)) { index = next; chosen = nil; started = Date() }
    }
    private func restart() { started = Date() }
    private func finish() {
        app.completeLesson(lesson)
        app.sheet = nil
    }
}

/// Picks the scene implementation.
struct LessonSceneView: View {
    let scene: LessonScene
    let photo: LessonPhoto
    let started: Date

    var body: some View {
        switch scene {
        case .pixelGrid, .brightnessOnly: PixelScene(scene: scene, photo: photo, started: started)
        case .brightnessRelief: BrightnessReliefScene(photo: photo, started: started)
        case .histogramBuild: HistogramPileScene(photo: photo, started: started)
        case .histogramRead: HistogramReadScene(photo: photo)
        case .zoneExplorer: ZoneExplorerScene(photo: photo)
        case .keyStyles: KeyStylesScene(photo: photo)
        case .clippingDemo: ClippingScene(photo: photo)
        case .exposureVsBrightness: ExposureBrightnessScene(photo: photo)
        case .toneControl: ToneControlScene(photo: photo)
        case .curveAxes, .curveShapes: CurveScene(photo: photo, started: started, shapes: scene == .curveShapes)
        case .apertureOpening: ApertureScene(photo: photo)
        case .depthOfField: DepthOfFieldScene()
        case .shutterMotion: ShutterScene(photo: photo, started: started)
        case .isoNoise: ISOScene(photo: photo, started: started)
        case .exposureTriangle: ExposureTriangleScene(photo: photo, started: started)
        case .colorTemperature: ColorTemperatureScene(photo: photo)
        case .whitePicker: WhitePickerScene(photo: photo)
        case .colorThreeNumbers: ColorThreeNumbersScene(photo: photo)
        case .hslBand: HSLBandScene(photo: photo)
        case .fieldOfView: FieldOfViewScene(photo: photo)
        case .perspective: PerspectiveScene()
        case .frameRate: FrameRateScene()
        case .shutterAngle: ShutterAngleScene()
        case .logCurve: LogCurveScene()
        case .logConversion: LogConversionScene(photo: photo)
        }
    }
}

// MARK: - Shared pieces

/// A photo that fits its space, with a caption under it.
struct LessonImage: View {
    let image: CGImage
    var caption: String?
    var body: some View {
        VStack(spacing: 6) {
            Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// A labelled slider for scenes.
struct LessonSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%+.0f", $0) }
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.callout).frame(width: .label(64), alignment: .leading)
            Slider(value: $value, in: range).controlSize(.small).tint(WorkbenchTheme.control)
            Text(format(value)).font(.callout.monospacedDigit()).frame(width: 64, alignment: .trailing)
        }
    }
}
