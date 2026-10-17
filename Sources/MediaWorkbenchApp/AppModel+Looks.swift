import AppKit
import MediaCore
import UniformTypeIdentifiers

/// Looks that travel: export the current grade as a .cube for other apps, and match
/// this photo's colors to another photo in the library (both adapted from the Lucet web edition).
extension AppModel {
    /// Saves the color part of the current grade as a 33-point .cube LUT.
    func exportGradeLUT() {
        guard editor.isLoaded, let url = editor.url else { return }
        let edits = editor.edits
        guard edits.hasGrade else { show(L("还没有调色，没有可导出的 LUT。")); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .plainText]
        let stem = url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = stem + " · Lucet.cube"
        panel.message = L("导出调色为 LUT：可在 DaVinci Resolve、Final Cut Pro、Premiere 等软件里套用到 Rec.709 / sRGB 素材。")
        present(panel) { [weak self] urls in
            guard let self, let target = urls.first else { return }
            Task {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        let cube = try LUTBaker.bake(edits, size: 33, title: "\(stem) · Lucet")
                        try Data(cube.textRepresentation().utf8).write(to: target, options: .atomic)
                    }.value
                    self.show(L("已导出 LUT。降噪、去雾、清晰度、锐度、暗角和颗粒依赖周围像素，不在 LUT 里。"),
                              actions: [.init(title: L("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([target]) }])
                } catch { self.fail(L("无法导出 LUT"), error) }
            }
        }
    }

    /// AI Look: a grade made for this photo by the bundled Image-Adaptive-3DLUT model, applied like
    /// a preset (from the original, at 75 %, one undo step). `ready` is the tile's LUT when it has
    /// one already.
    func aiLook(_ ready: CreativeLUT? = nil) {
        guard editor.isLoaded, !editor.isVideo, let frame = editor.frame, let model = AdaptiveLUT.shared else { return }
        let source = frame.original, headroom = frame.sourceHeadroom, drafts = self.drafts
        Task {
            do {
                let (lut, reference) = try await Task.detached(priority: .userInitiated) { () throws -> (CreativeLUT, LUTReference) in
                    let lut = try ready ?? {
                        guard let cube = model.lut(for: source, headroom: headroom, title: "AI Look") else {
                            throw VideoWorkError.failed(L("无法分析画面颜色。"))
                        }
                        return CreativeLUT(cube: cube, name: L("AI 调色"))
                    }()
                    return (lut, try drafts.storeLUT(lut))
                }.value
                var recipe = EditRecipe()
                recipe.lut = reference
                recipe.strength = 0.75
                editor.applyLook(recipe, lut: lut, name: L("AI 调色"))
                let editor = self.editor
                show(L("已套用为这张照片生成的 AI 调色（强度 \(Int((recipe.strength * 100).rounded()))%）。在「风格 LUT」里调整强度。"), actions: [.init(title: L("撤销")) { editor.undo() }])
            } catch { fail(L("无法生成 AI 调色"), error) }
        }
    }

    /// Library photos that can serve as a color reference for the current one.
    var matchCandidates: [LibraryEntry] {
        library.entries.filter { !$0.isVideo && $0.id != library.currentID }
    }

    /// Moves this photo's overall colors toward another photo's (as edited), as a LUT that
    /// the Strength slider can dial back. One undo step.
    func matchLook(to referenceID: String) {
        guard editor.isLoaded, !editor.isVideo, let frame = editor.frame, let entry = library.entry(referenceID) else { return }
        var withoutLUT = editor.edits
        withoutLUT.lut = nil
        let edits = withoutLUT, original = frame.original
        let name = L("匹配：\(entry.url.deletingPathExtension().lastPathComponent)")
        let drafts = self.drafts
        sheet = nil
        Task {
            guard let loaded = await thumbnails.load(entry) else {
                show(L("无法读取「\(entry.url.lastPathComponent)」。")); return
            }
            let reference = ThumbnailBox(loaded)
            do {
                let lut = try await Task.detached(priority: .userInitiated) { () throws -> CreativeLUT in
                    let source = try ColorPipeline.sdrBitmap(try ColorPipeline.grade(original, edits: edits))
                    guard let from = LookMatch.statistics(source), let to = LookMatch.statistics(reference.image) else {
                        throw VideoWorkError.failed(L("无法分析画面颜色。"))
                    }
                    let lut = CreativeLUT(cube: LookMatch.lut(from: from, to: to, title: name), name: name)
                    _ = try drafts.storeLUT(lut) // the recipe refers to it by file
                    return lut
                }.value
                // Full transfer can be strong; start at 80% and let the slider decide.
                editor.group { editor.selectLUT(lut); editor.strength = 0.8 }
                let editor = self.editor
                show(L("已向「\(entry.url.deletingPathExtension().lastPathComponent)」的色调靠拢。在「风格 LUT」里用强度调整多少。"),
                     actions: [.init(title: L("撤销")) { editor.undo() }])
            } catch { fail(L("无法匹配色调"), error) }
        }
    }
}

extension AppModel {
    /// Selected photos in library order, for side-by-side culling (videos left out, at most 8).
    var compareSelection: [String] {
        library.visible.filter { library.selection.contains($0.id) && !$0.isVideo }.prefix(8).map(\.id)
    }
}
