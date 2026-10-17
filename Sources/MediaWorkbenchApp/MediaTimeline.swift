import MediaCore
import SwiftUI

/// Source-time ruler: trim, playhead and Live cover share one coordinate space.
/// Playhead and timecode are separate views so 30 Hz playback updates stay small.
struct MediaTimeline: View {
    let app: AppModel
    var editor: EditorModel { app.editor }
    @UIState private var zoomSelection = false

    var body: some View {
        VStack(spacing: 0) {
            WorkbenchTheme.hairline.frame(height: 1)
            TransportBar(app: app, zoomSelection: $zoomSelection)
                .padding(.horizontal, 14).padding(.vertical, 7)
            TimelineTrack(editor: editor, zoomSelection: zoomSelection)
                .padding(.horizontal, 22).frame(height: 92)
            if let music = editor.musicURL {
                HStack(spacing: 8) {
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                    Text(music.lastPathComponent).lineLimit(1)
                    Spacer()
                    Text("背景音乐 \(Int(editor.musicVolume * 100))%").foregroundStyle(.secondary)
                }
                .font(.caption).padding(.horizontal, 10).frame(height: 22)
                .background(WorkbenchTheme.well, in: RoundedRectangle(cornerRadius: 4))
                .padding(.horizontal, 22).padding(.bottom, 6)
            }
            HStack(spacing: 14) {
                Text("入点 \(timeLabel(editor.clipStart))  出点 \(timeLabel(editor.clipEnd))")
                Spacer(minLength: 0)
                Text("封面 \(timeLabel(editor.cover))").foregroundStyle(.primary)
                Text(String(format: L("原片 %.2f 秒 → 输出 %.2f 秒"), editor.clipEnd - editor.clipStart, editor.clip.outputDuration)
                     + (editor.liveIsValid ? "" : L(" · Live 需 0.5–3 秒")))
            }
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            .padding(.horizontal, 22).padding(.bottom, 9)
        }
        .background(WorkbenchTheme.panel)
    }
}

private struct TransportBar: View {
    let app: AppModel
    @Binding var zoomSelection: Bool
    var editor: EditorModel { app.editor }
    private static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3, 4]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                playback.fixedSize()
                Spacer(minLength: 4)
                live.fixedSize()
            }
            VStack(spacing: 8) {
                HStack { playback; Spacer(minLength: 0) }
                HStack { Spacer(minLength: 0); live }
            }
        }
    }

    private var playback: some View {
        HStack(spacing: 4) {
            IconButton(title: L("上一帧（←）"), icon: "backward.frame") { editor.stepFrame(-1) }
            IconButton(title: L("播放 / 暂停（空格）"), icon: editor.playing ? "pause.fill" : "play.fill", action: editor.togglePlayback)
            IconButton(title: L("下一帧（→）"), icon: "forward.frame") { editor.stepFrame(1) }
            TimecodeLabel(editor: editor).padding(.horizontal, 6)
            IconButton(title: zoomSelection ? L("显示完整素材") : L("放大选取范围"), icon: "arrow.left.and.right", active: zoomSelection) { zoomSelection.toggle() }
            IconButton(title: L("静音原声"), icon: editor.originalVolume == 0 ? "speaker.slash" : "speaker.wave.2", active: editor.originalVolume == 0) {
                editor.originalVolume = editor.originalVolume == 0 ? 1 : 0
            }
        }
    }

    private var live: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(Self.speeds, id: \.self) { speed in
                    Button(String(format: "%g×", speed)) { editor.setSpeed(speed) }
                }
                Divider()
                Button("适配 3 秒 Live", action: editor.fitLiveSpeed)
            } label: {
                Text(String(format: L("速度 %.2g×"), editor.playbackSpeed)).monospacedDigit()
            }
            .fixedSize()
            .help("变速后视频与原声同步变化，背景音乐保持原节奏")
            Button("选取 3 秒", action: editor.selectLiveRange).glassButton().help(L("以播放头为中心选取 3 秒输出"))
            Button("设为封面", action: editor.setCoverAtPlayhead).glassButton().help(L("把播放头位置设为 Live 封面（C）"))
            Button(action: app.makeLive) {
                Label("制作 Live", systemImage: "livephoto")
            }
            .primaryButton()
            .help(editor.liveIsValid ? L("生成 Live Photo（在后台进行）") : L("Live Photo 最长 3 秒；点按可选择如何缩短"))
        }
        .controlSize(.regular)
    }
}

private struct TimecodeLabel: View {
    let editor: EditorModel
    var body: some View {
        Text(timeLabel(editor.clipStart + editor.position))
            .font(.system(.body, design: .monospaced).weight(.medium))
            .accessibilityLabel("播放时间")
    }
}

private struct TimelineTrack: View {
    let editor: EditorModel
    let zoomSelection: Bool
    @UIState private var draftStart: Double?
    @UIState private var draftEnd: Double?
    @UIState private var draftCover: Double?
    @UIState private var rangeOrigin: ClipSettings?

    private var start: Double { draftStart ?? editor.clipStart }
    private var end: Double { draftEnd ?? editor.clipEnd }
    private var cover: Double { draftCover ?? editor.cover }
    private var span: ClosedRange<Double> {
        guard zoomSelection else { return 0...max(0.1, editor.duration) }
        let padding = max(0.1, (editor.clipEnd - editor.clipStart) * 0.25)
        return max(0, editor.clipStart - padding)...min(editor.duration, editor.clipEnd + padding)
    }
    private var frameRate: Double { max(1, Double(editor.metadata?.nominalFrameRate ?? 30)) }

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let lower = span.lowerBound, seconds = max(0.1, span.upperBound - span.lowerBound)
            let left = x(start, width, lower, seconds), right = x(end, width, lower, seconds)
            ZStack(alignment: .topLeading) {
                TimelineRuler(lower: lower, duration: seconds).frame(height: 22).allowsHitTesting(false)
                Filmstrip(editor: editor, span: span).frame(width: width, height: 46).offset(y: 26)
                Rectangle().fill(Color.black.opacity(0.6)).frame(width: left, height: 46).offset(y: 26).allowsHitTesting(false)
                Rectangle().fill(Color.black.opacity(0.6)).frame(width: max(0, width - right), height: 46).offset(x: right, y: 26).allowsHitTesting(false)
                Rectangle().strokeBorder(Color(white: 0.88), lineWidth: 1.5)
                    .frame(width: max(1, right - left), height: 46).offset(x: left, y: 26).allowsHitTesting(false)
                Rectangle().fill(.clear).frame(width: width, height: 72).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { event in editor.scrubSeek(time(event.location.x, width, lower, seconds) - editor.clipStart) }
                        .onEnded { event in editor.scrubSeek(time(event.location.x, width, lower, seconds) - editor.clipStart, exact: true) })
                    .accessibilityElement().accessibilityLabel("播放位置")
                    .accessibilityAdjustableAction { editor.stepFrame($0 == .increment ? 1 : -1) }
                Playhead(editor: editor, width: width, lower: lower, seconds: seconds)
                Rectangle().fill(.clear).frame(width: max(1, right - left - 14), height: 46)
                    .contentShape(Rectangle()).offset(x: left + 7, y: 26)
                    .gesture(moveGesture(width, lower, seconds))
                    .help("拖动整体移动选取范围；点按定位播放头")
                    .accessibilityLabel("选取范围")
                    .accessibilityAdjustableAction { editor.moveRange(by: $0 == .increment ? 1 : -1) }
                TrimHandle(isStart: true).position(x: left, y: 49)
                    .gesture(trimGesture(true, width, lower, seconds))
                    .accessibilityLabel("入点").accessibilityValue(timeLabel(start))
                TrimHandle(isStart: false).position(x: right, y: 49)
                    .gesture(trimGesture(false, width, lower, seconds))
                    .accessibilityLabel("出点").accessibilityValue(timeLabel(end))
                Image(systemName: "diamond.fill").font(.system(size: 10)).foregroundStyle(.white)
                    .frame(width: 24, height: 18).contentShape(Rectangle())
                    .position(x: x(cover, width, lower, seconds), y: 82)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { event in draftCover = time(event.location.x, width, lower, seconds); editor.moveCover(to: draftCover!, exact: false) }
                        .onEnded { event in editor.moveCover(to: time(event.location.x, width, lower, seconds)); draftCover = nil })
                    .help("拖动选择 Live 封面")
                    .accessibilityLabel("封面位置").accessibilityValue(timeLabel(cover))
            }
        }
    }

    private func time(_ location: CGFloat, _ width: CGFloat, _ lower: Double, _ seconds: Double) -> Double {
        lower + min(1, max(0, location / width)) * seconds
    }

    private func x(_ time: Double, _ width: CGFloat, _ lower: Double, _ seconds: Double) -> CGFloat {
        min(width, max(0, width * (time - lower) / seconds))
    }

    private func moveGesture(_ width: CGFloat, _ lower: Double, _ seconds: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { event in
                guard abs(event.translation.width) >= 2 || rangeOrigin != nil else { return }
                if rangeOrigin == nil { rangeOrigin = editor.clip }
                guard let origin = rangeOrigin else { return }
                let delta = (event.translation.width / width * seconds * frameRate).rounded() / frameRate
                let next = origin.shifted(by: delta, duration: editor.duration)
                draftStart = next.start; draftEnd = next.end; draftCover = next.cover
            }
            .onEnded { event in
                if let origin = rangeOrigin { editor.moveRange(by: start - origin.start) }
                else { editor.seek(time(event.location.x, width, lower, seconds) - editor.clipStart) }
                draftStart = nil; draftEnd = nil; draftCover = nil; rangeOrigin = nil
            }
    }

    private func trimGesture(_ isStart: Bool, _ width: CGFloat, _ lower: Double, _ seconds: Double) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { event in
                let value = (time(event.location.x, width, lower, seconds) * frameRate).rounded() / frameRate
                if isStart { draftStart = min(max(0, value), end - 0.1) }
                else { draftEnd = max(start + 0.1, min(editor.duration, value)) }
            }
            .onEnded { _ in
                editor.setRange(start: start, end: end)
                draftStart = nil; draftEnd = nil
            }
    }
}

private struct Playhead: View {
    let editor: EditorModel
    let width: CGFloat
    let lower: Double
    let seconds: Double
    var body: some View {
        let x = min(width, max(0, width * (editor.clipStart + editor.position - lower) / seconds))
        ZStack(alignment: .top) {
            Rectangle().fill(Color.white).frame(width: 1.5, height: 54).offset(y: 8)
            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9)).foregroundStyle(.white)
        }
        .frame(width: 12, height: 62).offset(x: x - 6, y: 18).allowsHitTesting(false)
    }
}

private struct Filmstrip: View {
    let editor: EditorModel
    let span: ClosedRange<Double>
    var body: some View {
        GeometryReader { geometry in
            let frames = editor.filmstrip
            let duration = editor.duration
            if !frames.isEmpty {
                let count = max(1, Int(geometry.size.width / 64))
                HStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { index in
                        let time = span.lowerBound + (span.upperBound - span.lowerBound) * (Double(index) + 0.5) / Double(count)
                        let source = min(frames.count - 1, max(0, Int((time / max(0.1, duration) * Double(frames.count - 1)).rounded())))
                        Image(decorative: frames[source], scale: 1).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width / Double(count), height: 46).clipped()
                    }
                }
                .accessibilityHidden(true)
            } else {
                HStack {
                    if editor.filmstripLoading { ProgressView().controlSize(.mini) }
                    Text(editor.filmstripLoading ? L("正在生成缩略图…") : L("视频片段")).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(WorkbenchTheme.well)
            }
        }
    }
}

private struct TrimHandle: View {
    let isStart: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.88)).frame(width: 8, height: 46)
            Capsule().fill(Color.black.opacity(0.7)).frame(width: 1.5, height: 16)
        }
        .frame(width: 22, height: 52).contentShape(Rectangle())
        .help(isStart ? L("拖动调整入点（I）") : L("拖动调整出点（O）"))
    }
}

private struct TimelineRuler: View {
    let lower: Double
    let duration: Double
    var body: some View {
        Canvas { context, size in
            let desired = duration / max(2, size.width / 85)
            let magnitude = pow(10, floor(log10(max(0.01, desired))))
            let step = [1.0, 2, 5, 10].map { $0 * magnitude }.first { $0 >= desired } ?? magnitude * 10
            let first = ceil(lower / step) * step
            for index in 0..<min(Int(ceil(duration / step)) + 1, 100) {
                let time = first + Double(index) * step
                let position = (time - lower) / duration * size.width
                guard position <= size.width + 1 else { continue }
                var tick = Path(); tick.move(to: CGPoint(x: position, y: 16)); tick.addLine(to: CGPoint(x: position, y: 22))
                context.stroke(tick, with: .color(.white.opacity(0.25)), lineWidth: 0.5)
                let label = Text(timeLabel(time)).font(.system(size: 9, design: .monospaced)).foregroundColor(Color(white: 0.58))
                context.draw(label, at: CGPoint(x: min(size.width - 25, max(25, position)), y: 7))
            }
        }
        .accessibilityHidden(true)
    }
}
