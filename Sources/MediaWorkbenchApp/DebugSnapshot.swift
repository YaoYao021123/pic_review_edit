import AppKit
import MediaCore
import SwiftUI

/// Developer-only layout check. Launch with
/// `GUANGJI_SNAPSHOT_DIR=/tmp/shots GUANGJI_SNAPSHOT_STEPS="open:/a.jpg;wait:2;shot:edit;quit"`
/// to save PNGs of the app's own window without screen-recording permission.
/// Metal and video layers are not captured by AppKit's view cache.
@MainActor
enum DebugSnapshot {
    /// Snapshot runs only: a folder that stands in for the Photos library in the import browser,
    /// so it can be checked without asking for Photos access (GUANGJI_PHOTOS_FOLDER).
    static var photosFolder: URL? {
        guard directory != nil, let path = ProcessInfo.processInfo.environment["GUANGJI_PHOTOS_FOLDER"] else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var directory: URL? {
        ProcessInfo.processInfo.environment["GUANGJI_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func runIfRequested(_ perform: @escaping @MainActor (String, String) -> Void) {
        guard directory != nil, let script = ProcessInfo.processInfo.environment["GUANGJI_SNAPSHOT_STEPS"] else { return }
        let steps = script.split(separator: ";").map { step -> (String, String) in
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            for (command, argument) in steps {
                switch command {
                case "wait": try? await Task.sleep(for: .seconds(Double(argument) ?? 1))
                case "shot": capture(named: argument)
                case "size":
                    let values = argument.split(separator: "x").compactMap { Double($0) }
                    if values.count == 2, let window = workbenchWindow {
                        window.setContentSize(NSSize(width: values[0], height: values[1]))
                    }
                // An open sheet would hold up terminate(); snapshot runs have nothing to save.
                case "quit": exit(0)
                case "panel":
                    // The inspector isn't always presented for an accessory-policy window,
                    // so render it in its own offscreen window: "panel:name" or "panel:name@1600".
                    let parts = argument.split(separator: "@").map(String.init)
                    perform(parts[0].hasPrefix("history") ? "panel-open-history" : "panel-open", parts.count > 1 ? parts[1] : "1400")
                    try? await Task.sleep(for: .seconds(1.5))
                    if let window = panelWindow, let view = window.contentView { write(view, named: parts[0]) }
                    panelWindow?.close(); panelWindow = nil
                case "dump":
                    // Prints the window's view tree (class, frame) to find views a capture misses.
                    func dump(_ view: NSView, _ depth: Int) {
                        guard depth < Int(argument) ?? 12 else { return }
                        print(String(repeating: "  ", count: depth) + "\(type(of: view)) \(view.frame.integral) hidden=\(view.isHidden)")
                        view.subviews.forEach { dump($0, depth + 1) }
                    }
                    if let frame = workbenchWindow?.contentView?.superview { dump(frame, 0) }
                    for child in workbenchWindow?.childWindows ?? [] { print("child window", type(of: child), child.frame) }
                default: perform(command, argument)
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    /// Maps script commands onto app actions.
    static func perform(_ command: String, _ argument: String, app: AppModel) {
        switch command {
        case "import": app.importURLs(argument.split(separator: ",").map { URL(fileURLWithPath: String($0)) })
        case "open":
            let id = URL(fileURLWithPath: argument).standardizedFileURL.path
            if app.library.entry(id) == nil { app.library.add([URL(fileURLWithPath: argument)]) }
            app.open(id)
        case "mode": app.mode = argument == "edit" ? .edit : .browse
        case "panel-open", "panel-open-history":
            let size = NSSize(width: command == "panel-open" ? 330 : 300, height: Double(argument) ?? 1400)
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: 0), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = workbenchWindow?.effectiveAppearance
            window.backgroundColor = .windowBackgroundColor
            window.isReleasedWhenClosed = false
            let content: AnyView = command == "panel-open" ? AnyView(InspectorView(app: app)) : AnyView(HistoryList(editor: app.editor))
            window.contentView = NSHostingView(rootView: content
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .underPageBackgroundColor)))
            window.orderFront(nil)
            panelWindow = window
        case "inspector": app.showInspector = argument != "off"
        case "auto": app.autoEnhance()
        case "match": app.matchLook(to: URL(fileURLWithPath: argument).standardizedFileURL.path)
        case "groups": app.mode = .browse; app.showGroups = argument != "off"
        case "local": if let shape = LocalAdjustment.Shape(rawValue: argument) { app.editor.addLocal(shape) }
        case "localmask": app.editor.showMask = argument != "off"
        case "localset":
            // "start=0.5,0|end=0.5,0.5|exposure=-0.7|highlights=-40" on the selected layer
            guard let id = app.editor.selectedLocalID else { break }
            for pair in argument.split(separator: "|") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                let numbers = kv[1].split(separator: ",").compactMap { Double($0) }
                app.editor.updateLocal(id) { layer in
                    switch kv[0] {
                    case "start" where numbers.count == 2: layer.start = CGPoint(x: numbers[0], y: numbers[1])
                    case "end" where numbers.count == 2: layer.end = CGPoint(x: numbers[0], y: numbers[1])
                    case "center" where numbers.count == 2: layer.center = CGPoint(x: numbers[0], y: numbers[1])
                    case "radii" where numbers.count == 2: layer.radii = CGSize(width: numbers[0], height: numbers[1])
                    case "feather" where numbers.count == 1: layer.feather = numbers[0]
                    default:
                        if let parameter = AdjustmentParameter(rawValue: kv[0]), numbers.count == 1 { layer.adjustments[parameter] = numbers[0] }
                    }
                }
            }
        case "localstroke":
            // "x1,y1,x2,y2,…" normalized, added to the selected layer
            let v = argument.split(separator: ",").compactMap { Double($0) }
            let points = stride(from: 0, to: v.count - 1, by: 2).map { CGPoint(x: v[$0], y: v[$0 + 1]) }
            if let id = app.editor.selectedLocalID, !points.isEmpty {
                app.editor.updateLocal(id) { $0.strokes.append(BrushStroke(points: points, radius: app.editor.brushRadius)) }
            }
        case "compare":
            // "a.jpg,b.jpg" or "zoom:a.jpg,b.jpg"
            let zoom = argument.hasPrefix("zoom:")
            CullingSheet.debugZoomed = zoom
            let paths = (zoom ? String(argument.dropFirst(5)) : argument).split(separator: ",")
            app.sheet = .compare(paths.map { URL(fileURLWithPath: String($0)).standardizedFileURL.path })
        case "focus": app.editor.focusParameter = AdjustmentParameter(rawValue: argument)
        case "lesson":
            // "id" or "id@step"
            let parts = argument.split(separator: "@").map(String.init)
            app.sheet = nil
            LessonPlayer.debugStartStep = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            // Let the previous sheet close first, or SwiftUI keeps it (same lesson id).
            Task { @MainActor in try? await Task.sleep(for: .milliseconds(700)); app.openLesson(parts[0]) }
        case "crop":
            // "scale,horizontal,vertical,ratio"
            let v = argument.split(separator: ",").compactMap { Double($0) }
            if v.count == 4 { var g = app.editor.geometry; g.cropScale = v[0]; g.horizontal = v[1]; g.vertical = v[2]; g.aspectRatio = v[3]; app.editor.geometry = g }
        case "panels": app.showSidebar = argument != "off"; app.showInspector = argument != "off"
        case "colormode": app.colorMode = ColorMode(rawValue: argument) ?? .simple
        case "relocate":
            let parts = argument.split(separator: "|").map(String.init)
            if parts.count == 2 { app.relocate(URL(fileURLWithPath: parts[0]).standardizedFileURL.path, to: URL(fileURLWithPath: parts[1])) }
        case "tab": app.inspectorTab = InspectorTab(rawValue: argument) ?? .color
        case "scope": UserDefaults.standard.set(argument, forKey: "scope.kind"); app.editor.scopeKind = ScopeKind(rawValue: argument) ?? app.editor.scopeKind
        case "expand": UserDefaults.standard.set(false, forKey: "section.collapsed.\(argument)")
        case "collapse": UserDefaults.standard.set(true, forKey: "section.collapsed.\(argument)")
        case "compare": app.editor.compareMode = CompareMode(rawValue: argument) ?? .off
        case "clipping": app.editor.showClipping = argument == "on"
        case "zoom": if argument == "100" { app.editor.zoomToActualPixels() } else { app.editor.zoomToFit() }
        case "select": app.library.select(URL(fileURLWithPath: argument).standardizedFileURL.path)
        case "rate": app.rate(Int(argument) ?? 0)
        case "flag": app.flag(argument == "pick" ? .pick : argument == "reject" ? .reject : .none)
        case "preset": if let preset = app.presets.first(where: { $0.name == argument }) { app.applyPreset(preset) }
        case "adjust":
            let parts = argument.split(separator: "=")
            if parts.count == 2, let parameter = AdjustmentParameter(rawValue: String(parts[0])), let value = Double(parts[1]) {
                app.editor.setAdjustment(parameter, value)
            }
        case "export": app.enqueueCurrentExport(to: URL(fileURLWithPath: argument))
        case "watermark": app.exportSettings.image.watermark = argument == "off" ? nil : Watermark(text: argument.replacingOccurrences(of: "\\n", with: "\n"))
        case "naming": app.exportSettings.naming = argument
        case "search": app.search(argument)
        case "selectall": app.library.selection = Set(app.library.visible.map(\.id))
        case "newproject": app.createProject(named: argument, from: app.library.visible.map(\.id).filter(app.library.selection.contains))
        case "project": app.currentProjectID = app.projects.first { $0.name == argument }?.id
        case "projectscope": app.projectPhotoOnly = argument == "photo"
        case "evenout": app.evenOutProject()
        case "photos": app.sheet = .photosImport
        case "live":
            app.editor.selectLiveRange()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                app.enqueueLive(to: URL(fileURLWithPath: argument))
            }
        case "influence":
            let kinds: [String: InfluenceKind] = ["highlights": .highlights, "shadows": .shadows, "sky": .sky, "skin": .skin,
                                                  "neutral": .neutral, "blue": .hue(.blue), "lift": .lift, "none": .neutral]
            app.editor.pinnedInfluence = argument == "none" ? nil : kinds[argument]
        case "try":
            let insights = CoachState(app: app).insights
            if let index = Int(argument), insights.indices.contains(index), let suggestion = insights[index].suggestion {
                app.trySuggestion(suggestion, concept: insights[index].concept)
            }
        case "level": app.learner.level = LearningLevel(rawValue: argument) ?? .beginner
        case "topics": app.learner.topics = Set(argument.split(separator: ",").compactMap { LearningTopic(rawValue: String($0)) })
        case "insights":
            for insight in CoachState(app: app).insights {
                NSLog("insight %@ sev=%.2f %@ | %@", insight.id, insight.severity, insight.title, insight.suggestion?.label ?? "-")
            }
        case "ask": app.askTutor(argument)
        case "sheet-tutor": app.sheet = .tutorSettings
        case "jobs":
            for job in app.exports.jobs { NSLog("job %@ state=%@ detail=%@", job.title, String(describing: job.state), job.detail) }
        case "sheet":
            switch argument {
            case "export": app.exportCurrent()
            case "shortcuts": app.sheet = .shortcuts
            case "sync": app.sheet = .sync
            default: app.sheet = nil
            }
        case "key":
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                            context: nil, characters: argument, charactersIgnoringModifiers: argument,
                                            isARepeat: false, keyCode: 0) {
                _ = app.handleKey(event)
            }
        default: break
        }
    }

    static var workbenchWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains("workbench") == true && $0.isVisible }
            ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil }
    }

    static var panelWindow: NSWindow?

    static func capture(named name: String) {
        let main = workbenchWindow
        guard let window = main?.attachedSheet ?? main, let content = window.contentView else { return }
        write(content.superview ?? content, named: name)
    }

    private static func write(_ view: NSView, named name: String) {
        guard let directory, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
