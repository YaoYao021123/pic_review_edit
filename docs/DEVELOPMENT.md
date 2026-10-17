# 开发说明

面向想构建、修改或贡献光集的人。用户文档见 [README](../README.md)。

## 构建与测试

```sh
bash scripts/run-workbench.sh              # 构建 Release 并打开 .build/MediaWorkbench.app
bash scripts/run-workbench.sh --build-only
bash scripts/test-workbench.sh             # 155 项测试
bash scripts/dev-build.sh                  # 快速 Debug 构建，输出可执行文件路径
bash scripts/package-release.sh            # 生成 dist/Lucet-<版本>-arm64.zip（临时签名，未公证）
```

要求：macOS 15+、Apple 芯片、Xcode 命令行工具（不需要完整 Xcode）。最低系统 macOS 15；在 macOS 26 上使用 Liquid Glass。无第三方依赖。

命令行工具：

```sh
swift run media-probe details <素材>        # 打印「信息」页的全部内容
swift run media-probe analyze <图片>        # 画面统计与教练提示
swift run media-probe auto <图片> [对比.jpg] # 「自动」的取值，可输出前后对比图
swift run media-probe similar <文件夹>       # 相似照片与连拍分组（含指纹用时）
swift run media-probe labels <图片>         # 按内容搜索用的画面标签（Vision）
swift run media-probe ailook <图片> <输出.jpg> [长边]   # AI 调色（75%），并打印三张基础 LUT 的混合权重
swift run media-probe render <图片> <配方.json|-> <输出.jpg> [长边]   # 套用配方（含局部调整）导出
swift run media-probe match <图片> <参考图> <输出.jpg> [长边]          # 「匹配色调」的结果
swift run --configuration release media-benchmark
```

## 界面语言（简体中文 / English）

界面跟随系统语言；菜单栏「Lucet 光集 › Language · 语言」可以单独切换（会重新打开 App）。

- **中文就是 key**：代码里写中文原文。SwiftUI 的 `Text("…")`、`Button("…")` 等自动查表；其他地方（模型、提示、错误信息）用 `L("…")`（MediaCore 的 `Localization.swift`），插值写法照常：`L("已添加 \(n) 项")`。
- **英文**在 `Localization/en.lproj/Localizable.strings`；需要单复数的放在同目录的 `Localizable.stringsdict`。`Info.plist` 的文字在各语言的 `InfoPlist.strings`。
- **检查**：`python3 scripts/localize.py check` 用编译器导出代码实际查找的全部 key（`-emit-localized-strings`，不需要完整 Xcode），列出：没有包进 `L()` 的中文、缺英文的 key、占位符不一致的译文、已不用的译文。必须保持中文的行（例如发给 API 的内容）在行尾加 `// loc:ignore`。
- **新增文字的流程**：写中文 → `check` 列出缺的 key → 把英文写进 JSON（`{"中文": "English"}`）→ `python3 scripts/localize.py merge 文件.json`（按源文件分组重写 .strings）。
- 同一个中文在不同位置需要不同英文时（如筛选里的「照片」= Photos，类型里的「照片」= Photo），用显式 key：`String(localized: "filter.photos", defaultValue: "照片")`。
- 看英文界面：`"$(bash scripts/dev-build.sh)" -AppleLanguages '(en)'`，截图模式同样适用。测试环境没有语言包，`L()` 返回中文原文，所以测试里的中文断言不受影响。

## 发布

1. `bash scripts/package-release.sh`，得到 `dist/Lucet-<版本>-arm64.zip` 与 SHA-256。
2. 在 GitHub 新建 Release，上传 zip，把 SHA-256 写进说明。
3. 当前只有临时签名，系统会要求用户手动放行一次（网站「常见问题」已写明步骤）。要让用户直接双击打开，需要 Apple Developer ID 签名并公证。

## 网站

`website/` 是纯静态页面（无构建步骤、无外部依赖）：中文在 `website/index.html`，英文在 `website/en/index.html`，两页内容要一起更新。浏览器语言不是中文的访客第一次会被带到英文页；导航栏的「English / 中文」会记住选择。本地预览：`python3 -m http.server --directory website`。推送到 `main` 或 `improve-workbench`（默认分支）后由 `.github/workflows/pages.yml` 发布到 GitHub Pages（需在仓库 Settings › Pages 把来源设为 GitHub Actions）。

社交分享预览（`<head>` 里的 `og:` / `twitter:` 标签）使用绝对地址，默认假定站点在 `https://yaoyao021123.github.io/lucet/`；换域名时请把 `website/index.html` 中该块的所有地址一起改掉。分享图是 `website/assets/og.jpg`（1200×630）。发布后可以用 opengraph.xyz 之类的预览工具检查；各平台会缓存预览，改图后可能要等一会儿或在平台的调试工具里刷新。

页面和 README 里的截图由应用自带的快照模式生成：`bash scripts/make-site-screenshots.sh <示例照片文件夹> <主图> [示例视频] [自动对比用的照片]`。`SHOT_LANG=en` 生成英文界面（放在 `website/assets/en/`，建议用英文文件名的示例照片）；`SKY_PHOTO`（局部调整截图和天空前后对比）、`MATCH_REFERENCE`（匹配色调的参考图）、`SIMILAR_DIR` 与 `COMPARE_FILES`（重复与相似、并排选片）、`REMOVE_RECIPE`（「去除」前后对比，`scripts/site-remove.json` 对应官网那张日落照片）可选。前后对比图和 README 里的 GIF 不含文字，两种语言共用。快照无法呈现 Liquid Glass 材质，想要真实玻璃效果，可以自己截一张图替换 `website/assets/shot-edit.jpg`（文件名不变即可）。示例照片会公开展示，请只用你有权公开的照片。

## 宣传视频

`docs/marketing/xiaohongshu/video.html` 是一段 1080×1920、约 49 秒的竖屏视频，所有动画由同一个时钟驱动，可以实时播放、拖到任意时间，也可以逐帧渲染。`bash scripts/render-xiaohongshu-video.sh` 用无头 Chrome 渲染每一帧、再用 ffmpeg 合成 `dist/xiaohongshu.mp4`（无声，约 5 分钟，需要 Chrome 和 ffmpeg）；`... still <秒数>…` 只渲染指定时刻的静帧用于检查。口播稿、剪辑与发布文案见 `docs/marketing/xiaohongshu/script.md`。

同一套做法还生成小红书的**图文 / 实况图**：`docs/marketing/xiaohongshu/slides.html` 是 8 张 1080×1440 的卡片（图片在中间、文字在下面，每张带 3 秒动效）。`bash scripts/render-xiaohongshu-slides.sh` 输出静态图 `dist/xhs-slides/*.jpg`，以及用光集自己的实况图代码合成的 Live Photo 配对 `dist/xhs-slides/live/*.jpg + *.mov`（`media-probe live <视频> <新文件夹>` 可单独把一段 ≤3 秒的视频变成实况图）。两个渲染脚本共用 `scripts/lib/render-frame.sh`（无头 Chrome 逐帧截图）。

**声音**：`bash scripts/render-xiaohongshu-audio.sh` 生成背景音乐和配音版（见 `docs/marketing/xiaohongshu/script.md` 第 1b 节）。`scripts/audio/make-voiceover.py` 把 `narration.json` 的台词转成语音（`--engine edge|melo|say|files`），用 whisper-cli 做语音识别核对，并按配音长度算出每个场景的时长（写入 `timeline.json`，视频渲染通过 `DURS` 环境变量读取）；`scripts/audio/make-music.py` 按这份时间线合成原创音乐。需要 `.venv-audio`（numpy、edge-tts、sherpa-onnx，首次运行自动创建）和 `brew install whisper-cpp` 加一个 Whisper 模型（`~/.cache/whisper-cpp/ggml-small.bin`）。

## 代码结构

- `Sources/MediaCore`：引擎，可单独测试。包括调色管线（`ColorPipeline`、`GradeStages`、`BasicAdjustments`）、局部调整（`LocalAdjustments`：蒙版、画布坐标映射；`SubjectMask`：Vision 主体蒙版）、去除（`Inpainting`：多尺度 PatchMatch 补全；`Retouch`：接入管线与缓存）、胶片效果（`FilmEffects`：暗通道去雾、褪色、颗粒、黑白）、`CubeLUT`、导出 LUT 与匹配色调（`LookTransfer`）、相似照片与连拍（`SimilarPhotos`）、完全相同的文件（`ExactDuplicates`）、按内容搜索（`ContentLabels`）、`Scopes`、`ImageExport`（含 HDR 增益图导出 `HDRGain`）、导出预设外的命名与水印（`ExportExtras`）、历史记录（`HistoryLog`）、项目（`Projects`：共用的调色 + 每张照片的偏移、裁剪与蒙版，统一明暗与色温 `ProjectEvenOut`；界面在 `AppModel+Projects`、`ProjectViews`）、AI 调色（`AdaptiveLUT`：Image-Adaptive-3DLUT 的网络，用 Accelerate 计算；权重 `assets/models/adaptive-lut.bin` 由 `scripts/convert-adaptive-lut.py` 从原始 .pth 转换，来源与许可见 `assets/models/NOTICE.md`）、视频与 Live（`VideoPipeline`、`LivePhotoPipeline`、`LiveCollagePipeline`）、配方 / 预设 / LUT 缓存（`EditRecipe`）、界面语言（`Localization`）。
- 移植自合作伙伴网页版 Lucet（Apache-2.0）的算法：相似照片分组（`review.py`）、色彩迁移与导出 LUT（`engine.py`）、局部蒙版（`masks.py`）。参考源码放在 `reference/`（不进 Git）；各文件开头注明了来源和改动。
- `Sources/MediaWorkbenchApp`：界面。
  - 模型：`AppModel` 负责协调（导入、导出、同步、快捷键），`LibraryModel` 管理素材库，`EditorModel` 管理当前文档，`ExportQueue` 是导出队列，`ThumbnailStore` 生成缩略图。
  - 视图：`WorkbenchView`、`LibraryViews`、`InspectorView`、`GradeControls`、`MediaCanvas`、`MediaTimeline`、`Sheets`、`LocalAdjustmentViews`（局部调整面板与画布控制点）、`CullingViews`（重复与相似、并排选片）、`HistoryViews`（历史记录）、`LanguageMenu`。
- 数据位置：`~/Library/Application Support/Guangji`（素材库 `library.json`、配方、快照、预设、LUT、相似照片指纹 `fingerprints.json`）。

### 开发：无屏幕录制权限的界面截图

```sh
GUANGJI_DATA_DIR=/tmp/guangji-dev GUANGJI_SNAPSHOT_DIR=/tmp/shots \
GUANGJI_SNAPSHOT_STEPS="import:/path/to/folder;wait:3;shot:browse;open:/path/a.jpg;wait:2;shot:edit;quit" \
"$(bash scripts/dev-build.sh)"
```

脚本命令见 `DebugSnapshot.swift`；`panel:名称@高度` 在单独的离屏窗口中渲染检查器（在部分系统版本上，辅助模式运行时窗口内的检查器不会显示），`dump` 打印窗口的视图层级。`GUANGJI_DATA_DIR` 使开发运行与正式素材库隔离；Metal、视频和 Liquid Glass 材质无法被视图缓存截取，截图只用于检查布局。


## 品牌资产

`assets/brand/`（见其中的 README 与 `preview.html`）。`bash scripts/generate-brand.sh` 重建矢量、PNG 与 ICNS。

## 与 ChatGPT 原型相比（2026-10-06）

| 项目 | 原型 | 现在 |
|---|---|---|
| 导入 2000 个文件的文件夹 | 主线程卡顿 6.9 s（O(n²)） | 4.5 ms |
| 解析 64³ LUT（DJI Winter Pro） | 609 ms，且每次打开文件都在主线程重复解析 | 20 ms，并全局缓存 |
| DJI Pocket 3 Spring / Winter Pro LUT | 无法导入（GBK 标题） | 正常导入 |
| 拖动一个滑块时重绘 | 侧栏、全部 16 个滑块、工具栏和菜单栏 | 只重绘该滑块与画面（已测量） |
| 预览分辨率 | 上限 1600 px，Retina 下发虚，不能缩放 | 按屏幕（≤3200 px），100% 时载入原尺寸 |
| 全部调色阶段渲染（2560 px） | — | 中位数 7.8 ms / P95 9.5 ms |
| 视频对比原片 / 首次调色 | 每次重建播放器 | 只更新滤镜参数（HDR 素材首次调色时切换一次 SDR 预览） |
| 播放头 | 10 Hz，并重绘整条时间线 | 30 Hz，独立小视图 |
| 照片导出 | 仅 PNG，丢失全部 EXIF | JPEG / HEIC / PNG，保留拍摄信息 |
| 导出时 | 整个应用锁定 | 后台队列 |
| 素材浏览 | 只有文件名列表 | 缩略图网格、评级、标记、筛选、键盘浏览 |

基准：`swift run --configuration release media-benchmark`（合成 12MP 图片；仅测渲染，不含显示）。


原型阶段的文档与验证记录保留在 `docs/` 与 `docs/archive/`。
