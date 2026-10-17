# Mac 素材工作台 · 光集

Mac 原生调色与 Live Photo 制作原型，Swift 6 / SwiftUI / AppKit，最低 **macOS 15**，当前无第三方依赖。最新功能与缺口见 [基础调色与功能补齐](docs/workbench-completion-2026-10-05.html)。

当前可用：

- 16 项基础调色：曝光 / 鲜明度 / 高光 / 阴影 / 亮度 / 对比 / 白色 / 黑点、暖色 / 色调 / 饱和度 / 自然饱和度、清晰度 / 锐度 / 降噪 / 暗角；RGB SDR 显示直方图。
- 90°旋转、镜像、比例裁切与位置调整；当前素材撤销 / 重做、连续拖动合并一步、原子配方自动保存与恢复、命名参数快照。
- 多文件 / 文件夹列表、收藏、混合选择、按参数组同步与当前会话撤回最近一次同步、批量另存和导出取消；结果目录含逐项导出记录。

- 图片、视频打开；同名 JPEG / HEIC + MOV 的 Live 配对通过系统检查后可从动态部分重新制作。
- `.cube` 创意 LUT 导入、暖调 / 柔和预设、强度、原片对比；图片自动调正、图片 / 视频手动调正和安全裁切。
- HDR 增益图读取、浮点 Metal / EDR 图片画布、原生 HDR 视频预览；显示能力不足时适配 SDR。
- 视频播放、定位、片段起止点、封面选择；选取框整体拖动保持长度与封面相对位置；原声静音 / 音量、单段本地 BGM 与音量。
- 0.5–4 倍速度、显示原片与输出长度；6 秒原片可按 2 倍速生成 3 秒 Live，BGM 保持原节奏。
- 另存 SDR PNG / MOV；按输出长度 0.5–3 秒生成 Live Photo，系统配对验证后保存资源、参数记录与 LUT 副本。
- 默认关闭的实验性 HDR 效果：扩展 SDR 视频高光，另存 HEVC Main10 / Rec.2020 HLG；Live 使用增益图 HEIC + HLG MOV。

创意 LUT 默认按非线性 sRGB 输入处理，导入后可按作者说明明确选择 Rec.709，支持 `.cube` 的 DOMAIN_MIN / DOMAIN_MAX；不自动判断 DJI D-Log / D-Log2 / D-Log M、Apple Log 或 LUT 输入空间。默认编辑与导出仍使用 SDR。实验性 HDR 效果扩展现有高光亮度，无法恢复拍摄时已经丢失的细节；相机原生 HDR 的完整保真编辑管线与 iPhone HDR Live 导入兼容性仍待验收。

已有 Live 的重制封面从动态视频提取，可能低于原静态图片的分辨率；原静态资源保留，不宣称无损保留 Live 封面。原件不改、目标已存在时拒绝覆盖。Live 参数文件是导出记录；编辑草稿与参数快照另存应用支持目录 Guangji。撤销栈与最近一次批量撤回仅在当前会话保留，跨会话数据库历史、设备直接导入与文件内容去重 / 路径合并仍未实现。

启动：

```sh
bash scripts/run-workbench.sh
```

脚本构建 Release 并生成 `.build/MediaWorkbench.app`，可在 Finder 中打开。`--build-only` 只构建打包。当前为本机开发原型；尚未验证应用沙盒、签名与分发配置。脚本关闭 SwiftPM 嵌套编译沙盒以兼容受限宿主，未修改系统保护设置。

2026-10-04 原生控件修正：参数已改用系统 Slider，保留直接输入、范围限制、右键复位，支持方向键微调；macOS 26 及以上的双向参数提供零点语义。通过“开发 → 原生控件样板…”查看真实系统按钮、工具栏、滑块、深浅外观和禁用状态。样板不处理或导出素材。拖动位置与调色参数分开保存，参数以 33 ms 间隔合并更新，松手立即提交最终值；移除叠加的双击手势以减少拖动竞争。已完成样板交互检查，真实素材预览帧率尚未测量。

分段切换新增点击平滑过渡、连续拖动与松手吸附；拖动期间只移动高亮，松手才切换面板。该交互由应用实现，高亮使用系统玻璃材质，并响应“减少动态效果”和“降低透明度”。普通按钮使用系统 Regular 玻璃样式与胶囊 / 圆形边框，文字 13 pt、操作图标 16 pt；仅主要 Live 操作使用强调色。已在样板及主工作台验证点击、跨段拖动与面板切换，并保存[深色实机截图](docs/ui-concepts/2026-10-04/native-controls-interaction-v3-dark.png)和[浅色实机截图](docs/ui-concepts/2026-10-04/native-controls-interaction-v3-light.png)。

主工作台控件已统一：LUT 风格按钮、Live 确认按钮、导入 / 归零 / 音乐操作采用同一按钮规范；HDR 与网格开关使用 Small 尺寸，顶部采用单行素材标题避免玻璃底座内裁切。视频工具栏按可用宽度自动切换单排 / 两排，保留完整标签与 16 pt 操作图标。Release 编译及合成视频上的分段切换、LUT / 音量滑块、逐帧、静音、片段选择、Live 保存面板已验证；本轮未重新验证媒体导出或测量帧率。见[主窗口实机截图](docs/ui-concepts/2026-10-04/workbench-controls-v4-color.png)、[窄窗口截图](docs/ui-concepts/2026-10-04/workbench-controls-v4-narrow-audio.png)和[施工记录](docs/ui-concepts/2026-10-04/workbench-controls-v4-record.json)。

本日后续：移除顶部标题的玻璃底座；修复切换视频时缩略图数组更新引起的崩溃。选取框拖动仅更新轻量草稿，松手再重建视频预览。已使用获授权的真实 4K DJI 素材验证整体移动、加速预览、官方创意 LUT 与完整视频 / SDR Live / HDR Live 导出；结果、对比图和官方 Pocket 4P LUT 下载记录见[真实素材验证报告](media-tests/2026-10-04/test-report.html)。实际导出通过与窗口相同的 MediaCore 管线执行，未将 CLI 导出记为窗口导出点击验收。

当前 CLT 的默认 Swift Build 引擎将应用的 SDK 元数据错误记录为 15.0，会使控件使用旧外观；运行脚本暂用 SwiftPM native 引擎并显式选择实际 SDK，已核对二进制为 SDK 27.0、最低系统 15.0。native 引擎已被 SwiftPM 标为弃用，后续切换完整 Xcode / 修复后的构建引擎时，应再次核对二进制 SDK 元数据。见 [构建记录](docs/ui-concepts/2026-10-04/native-controls-build-record.json)。

检查：

```sh
bash scripts/test-workbench.sh
```

**46 项 Swift Testing 测试、10 个套件通过**，新增调色方向与细节、旋转镜像 / 裁切、配方旧版本、原件变化保护、命名快照和分组历史；包含 PQ / HLG 视频、增益图 HEIC、明确的 LUT 传递函数、预览 / 导出像素、范围移动与速度限制、加速后音频 / 封面时间、HDR 实际亮像素和 Photos 系统配对识别。自动化套件仅使用合成素材，不调用模型 API；另有获授权的真实 4K 视频测试，两个 Live 均为 3.000 秒，完整解码与系统配对检查通过。新增复用视频滤镜、预览尺寸上限与原尺寸导出隔离测试。端到端预览帧率未测量，真实手机 / Pocket 设备读取、iPhone 导入与外接 HDR 屏视觉验收仍待完成。当前屏幕仅有 SDR 亮度范围，格式与像素检查不代表 HDR 显示效果验收。

可选保存测试素材到指定的新目录：

```sh
WORKBENCH_TEST_ARTIFACTS="$PWD/.build/my-fixtures" bash scripts/test-workbench.sh
```

Vision、Core Image、视频编码和 Photos 集成测试需要能调用系统媒体框架的普通本机环境。测试脚本自动定位 Swift Testing 宏插件，当前 CLT 缺少 XCTest，已关闭 XCTest 运行器。

原有检查 CLI 保留：

```sh
swift run media-probe inspect /absolute/path/to/file.mov
swift run media-probe lut /absolute/path/to/filter.cube
swift run media-probe straighten /absolute/path/to/image.jpg
swift run media-probe rotate /absolute/path/to/image.jpg 3 /absolute/path/to/new.png
```

CLI `lut` 只检查表结构；实际 LUT 调色在原生窗口执行。旧 CLI 图片导出仍是独立 SDR 调正工具。完整 Xcode、真实设备测试、权限与签名随后配置，当前目录尚未初始化 Git。

性能（2026-10-05 修正）：图片缓存一次浮点预览，复用 Metal / Core Image 渲染器；视频调色 / 角度直接更新线程安全滤镜快照，复用播放器资源，交互渲染最长边 1600px。音量直接更新混音，速度松手才重建；拖动定位单次飞行、保留最新请求，松手精确定位。导出继续使用原尺寸管线。实际 DJI 4K 画面 LUT + HDR + 旋转的浮点位图处理基准：中位数 10.04 → 5.81 ms，P95 16.43 → 8.87 ms，各预热后 24 次；不包含视频解码、seek 或屏幕显示。最新构建已完成，已在真实 DJI 4K 窗口检查曝光滑块、撤销/重做、固定三秒范围整体移动、快照恢复和播放响应；未测量连续拖动帧率。新增拼图窗口复验时 Mac 再次锁定，界面交互仍待检查。暂停画面刷新参考 [Apple QA1966](https://developer.apple.com/library/archive/qa/qa1966/_index.html)。基准运行 `swift run --configuration release media-benchmark`，范围与历史测量见 [性能记录](docs/development-readiness.html#preview-performance)。旧版 31.63 → 2.76 ms 是 SDR 调正管线测量，不能当成当前 HDR / LUT 画布帧率。

2026-10-05 拼图 Live：素材栏勾选 1–3 个视频或配对 Live，打开“拼图 Live…”。每格继承已保存的调色与裁切，可设置起点、0.5–4 倍速度和上下顺序，统一导出 3 秒静音 SDR；窗口显示各格中间帧。双拼为 1080×1216，三拼为 1080×1824，单画面保留原尺寸。新建资源目录，原件和已有输出不覆盖，Photos 配对通过后才发布。自由布局、实时合成播放、拼图 HDR、独立音轨和拼图项目自动保存尚未接入。新增测试覆盖独立调色、上下位置、各格时间与速度记录、资源配对、取消清理和无覆盖保护。

[秋日行旅 · 九张单/双/三画面 Live 成品画廊](media-tests/2026-10-05/nine-live-mixed/index.html)：18 个原始镜头，3 单画面 / 3 双拼 / 3 三拼，雪景仅 1 张。全部 3 秒，调色采用 DJI 官方 Rec.709 创意 LUT 与基础参数；9 项系统配对、时长、封面及完整解码通过。iPhone 实际导入未验收。

工作区维护（2026-10-05）：已清理 2.16 GiB 可重建 Swift / SDK 编译缓存，工作区约 3.28 → 1.12 GiB。保留 App、全部原片、两版 Live 成品、LUT、预览和验证日志；333 个媒体文件 SHA256 与 App 二进制校验一致。后续先运行 `python3 scripts/clean-workspace.py` 预览，需清理时加 `--apply`；下次构建会自动重建必要缓存。目录用途及体积详见 [工作区整理记录](docs/workspace-cleanup-2026-10-05.html)。

主视觉接入（2026-10-05）：[完整主视觉资产页](assets/brand/preview.html)。保留四片光圈母版，新增深浅色主视觉、竖版海报、透明标志、转曲字标、空状态插画、16–1024 px iconset 与 ICNS；应用图标、原生工具栏无底色标志与空状态已接入。Release 构建、打包一致性、NSImage 资源解码和原生窗口目验通过；Dock/Finder 缓存外观未单独验收。Icon Composer SVG 分层源已提供，尚未构建系统 Liquid Glass `.icon`。重导出用 `bash scripts/generate-brand.sh`。
