# EndTranslate — 边读边译的 PDF 翻译标注 Mac 应用（Swift 原生版）

> 本文档是完整的实现规格。按 M1→M5 阶段顺序实现。
> v2：技术栈从 Tauri+Web 改为 Swift 原生（用户要求：不做几百 MB 的 web 封包，只做 Mac）。
> v3：公式渲染从 SwiftMath 改为调用本机 typst CLI + mitex（用户本人日常用 typst；不考虑分发给其他用户）。

## 背景与核心理念

BabelDoc / pdf2zh 等工具解析 PDF 内部排版结构再重排，排版问题严重。本项目换思路：

- **把 PDF 当扫描件对待**：每页渲染为图像，完全不解析内嵌文本/排版。
- **框选式交互翻译**：不是一次性整本翻译。用户边阅读边用鼠标拖拽框选区域，该区域截图直接发给多模态 LLM（视觉模型）翻译 en→zh，绕开 OCR。
- **译文标注在原文上方**：译文框紧贴选区上沿（拼音标注位置），**不覆盖原文**；框高随译文自适应（≥选区高，页顶空间不足则改放选区下方），点击可隐藏/显示译文。
- **公式处理**：提示词要求 LLM 将公式输出为 LaTeX（`$...$` / `$$...$$`），渲染时调用本机 typst（mitex 包）编译为 PNG 嵌入译文。
- **可编辑、可持久化、可导出**：译文可编辑；标注存为 PDF 旁 sidecar JSON 自动保存；可导出最终标注 PDF。

仅支持 macOS，原生 UI。

## 技术栈

- **Swift 5.9 / SwiftUI + AppKit**，SwiftPM 构建（Command Line Tools 即可，无需完整 Xcode）
- **PDFKit**：PDF 渲染、滚动缩放、坐标转换、标注、导出（替代 pdf.js / pdf-lib）
- **本机 typst CLI + mitex**（M4 引入）：LaTeX → typst math → PNG。查找顺序：`/usr/bin/env typst` → `/opt/homebrew/bin/typst` → `/usr/local/bin/typst`；不考虑分发，本机已装 typst 0.15.1
- **URLSession**：OpenAI 兼容视觉 API
- **Codable**：sidecar JSON
- 本体无二进制依赖，产物 ~10MB 级

## 目录结构

```
Package.swift
Sources/EndTranslate/
  EndTranslateApp.swift        # @main，激活策略
  ContentView.swift            # 工具栏 + 主区
  PDF/
    PDFDocumentView.swift      # PDFView 的 NSViewRepresentable 封装
    PDFViewModel.swift         # document/缩放/页码状态
    SelectionOverlay.swift     # 拖拽框选透明覆盖层（NSView）
  Annotations/
    TranslationAnnotation.swift # PDFAnnotation 子类，draw(with:in:) 自绘译文框
    AnnotationEditorView.swift  # 双击标注 → markdown 编辑 + typst 实时预览
    AnnotationStore.swift       # CRUD + sidecar 同步
  LLM/
    LLMClient.swift            # OpenAI 兼容 /chat/completions，image base64，非流式
    SettingsView.swift         # base URL / key / model + 测试连接
  Render/
    MarkdownToTypst.swift      # markdown-lite → typst 源码（mitex 承载 LaTeX 公式）
    TypstRenderer.swift        # 调用本机 typst CLI 编译为单页 PDF（矢量），按内容哈希缓存
  Persist/
    Sidecar.swift              # <file>.etr.json，防抖自动保存，pdfSha256 校验
  Export/
    PDFExporter.swift          # 导出最终标注 PDF
```

## 数据模型

```swift
struct Annotation: Codable {
    var id: UUID
    var page: Int                    // 0-based
    var rect: CGRect                 // PDF pt，PDFKit 页面坐标系（左下原点）
    var translationMd: String        // markdown-lite，公式 LaTeX $...$
    var createdAt: Date
}
struct Sidecar: Codable {
    var version: Int = 1
    var pdfSha256: String
    var annotations: [Annotation]
}
```

设置（base URL / key / model）存 UserDefaults + Keychain，不进 sidecar。

## LLM 调用规格

- 端点：`{baseURL}/chat/completions`（OpenAI 兼容），非流式。
- **已验证**（DeepSeek 官方 vision 指南，https://api-docs.deepseek.com/zh-cn/guides/vision ）：模型 `deepseek-flash`；`content` 数组含 `text` + `image_url` 块；**base64 dataURL 受支持**（另有外部 URL / Files API）；格式 JPEG/PNG/GIF/WebP；长边上限 8192px；支持多图；**单图视觉编码上限 1024 token**（超出模型内部降采样）；不支持 PDF 输入。→ 截图按"长边 ≤ 2048px"控制像素预算，超出只是浪费带宽和延迟，不提升识别质量。
- user message 含文本提示词 + `image_url: { url: "data:image/png;base64,..." }`。
- 设置页提供"测试连接"按钮：发一张小图验证 API 对 image_url dataURL 的兼容性。
- 参考提示词：

```
你是学术论文翻译助手。图片是英文 PDF 的一个选区。请：
1. 将其中英文内容忠实翻译为中文，输出 GitHub Flavored Markdown；
2. 数学公式一律用 LaTeX 表示，行内 $...$，独立公式 $$...$$，不要翻译公式内的符号；
3. 保留段落结构，不要输出原文，不要加解释或前后缀。
```

## 关键设计决策（不要随意更改）

1. **PDFView 系统组件**：渲染/滚动/缩放/坐标转换全用 PDFKit 自带 API（`convert(_:to:)` / `convert(_:from:)`），不手写 dpr 换算。框选用加在 documentView 上的透明 overlay NSView。
2. **标注模型与显示分离（M5 后定稿）**：`TranslationAnnotation` 仅作**模型载体**（bounds/rendered/status/showsOriginal），**不再 addAnnotation 到页面**；译文框由 `SelectionOverlay`（视口固定、覆盖 PDFView 的自绘 NSView）以**矢量**画进实时 Retina 上下文 → 任意缩放下都清晰，绕开 PDFKit 对自绘 annotation 的光栅化缓存（此前"贴到 PDF 上比预览糊"的根因）。`bounds` = 显示框，`model.rect` = 原始选区，框体位于选区上方（拼音标注位）。编辑：overlay 命中测试 → 单击切换原文/译文、双击弹编辑器。**已实验确认（2026-09-25）**：
   - 文本使用 **CoreText** 绘制：`context.textMatrix = .identity`，并明确区分上下文方向。导出 PDF 的 y-up 上下文无需翻转；屏幕 overlay 的 y-down 上下文必须在文字框内反翻。文字布局和字号以 PDF pt 计算，再按页面缩放绘制。`NSString.draw` 在旧 PDFAnnotation 的显示与 /AP 生成路径中依赖 `NSGraphicsContext.current`，曾出现静默丢字。
   - 刷新方式：`SelectionOverlay.requestInvalidate()`；不再向 PDF 页面添加自绘 annotation。
   - `PDFDocument.write(to:)` 在 CoreText 下已验证可用：矢量内容 + 译文文本 + **嵌入字体**（/FontFile*，含 CJK 子集）全部保留。
   - **但 M4 复测（2026-09-25）**：自绘内容若为**嵌套的 PDF 页**（`CGContextDrawPDFPage`），`write(to:)` 生成的 /AP 外观流会**错乱字形**（文本 operator 被重编码到错误的字体，位图/offscreen PDFView 两条显示路径正常）。→ **M5 导出改为自建 CGPDFContext 逐页扁平化**：`beginPDFPage` → `drawPDFPage(原页)`（矢量原样）→ 对每个标注 `drawPDFPage(typst 页)` 画到其 bounds。不经过 PDFKit 的 /AP 生成，也就不会重编码。
3. **截图**：选区 rect（PDF pt）→ 用 PDFPage `draw(with:to:)` 直接绘制到 NSBitmapImageRep 位图上下文（像素尺寸确定，不受屏幕 Retina 缩放影响）→ PNG data。scale 3x，长边上限 2048px，超出按比例降低 scale（见 LLM 规格的 1024 token/图约束）。
4. **公式与正文一体渲染（M4 定稿）**：不再"正文用 CoreText + 公式单独出 PNG 再拼行"（行内公式基线对齐是手工排版地狱）。改为**整个标注用 typst 渲染成一页 PDF**：
   - `MarkdownToTypst` 把 markdown-lite 转成 typst 源码：标题/列表/嵌套列表/表格/引用/分隔线/围栏代码/粗斜体/行内代码，行内与独立公式分别为 `#mi("...")` / `$ #mi("...") $`。文本中的 typst 特殊字符（`\ ` ` * _ # $ < > @ ~`）逐个转义（已实测）。
   - 页面 `#set page(width: <标注宽>pt, height: auto, margin: 4pt)`：编译结果页宽 == 标注宽、页高 == 需要的高度 → **标注高度不再靠估算**，`displayBounds` 直接用 `RenderedDoc.size`，需要压高度时按 √(h/H) 加宽重排（≤4 次）。
   - 渲染结果是**矢量**（内嵌 PingFang SC + NewCM + NewCM Math 字体），`RenderedDoc.draw` 以左上角对齐、等比缩放画进 bounds（放不下就裁切而非压扁）。
   - **坐标系方向**：PDF 页和 CoreText 都按 y-up 绘制。`RenderedDoc.draw` 与 `TranslationAnnotation.drawText` 默认用于 y-up 的导出上下文；屏幕 overlay 是 `isFlipped = true`（y-down），两者都必须传 `yDown: true` 在 rect 内反翻，否则文字上下镜像。`drawText` 还需传实际显示比例，并同步缩放内边距。此前文档称 CoreText 在 y-down 下无需翻转，这是错误的；回归测试比较两条路径在多个缩放级别的像素结果。
   - **已验证**：typst 0.15.1 + `@preview/mitex:0.2.7`（0.2.4 与 0.15 不兼容，报 `unknown variable: kai`）；12 个常见论文公式 12/12 成功，单次编译约 105ms。
   - **降级链**：① 整篇编译 → ② 失败时逐个公式单独试编译（结果按哈希缓存），把 mitex 拒绝的公式挑出来，仅这些以原样 LaTeX 文本重排整篇 → ③ 仍失败则整篇退化为去除 markdown 标记的纯文本（CoreText 绘制）。不崩溃、不整篇降级。
   - 缓存键 = `templateVersion | mitexVersion | width | fontSize | markdown` 的 sha256（改了模板必须 bump `templateVersion`，否则命中旧图）；磁盘缓存 `~/Library/Caches/EndTranslate/typst/<key>.pdf`，内存 LRU 200 条，14 天未用清理。
5. **LLM 非流式**，UI 骨架加载态。
6. **sidecar 自动保存**：防抖写盘，启动时按 pdfSha256 校验。
7. **编辑交互**：单击标注 = 切换显示原文/译文；双击 = 打开编辑器（左 markdown 文本域、右 typst 实时预览，350ms 防抖，保存后重排该标注）。Option+拖拽 = 在已有标注上强制开新选区。
8. **防误操作（2026-09-25 加）**：框选松手**不立即翻译**，截图先缓存，选区右下角浮出确认 chip（`翻译`/`取消`，越界自动翻到选区上方/夹在视口内）；点 chip 外任意处 = 取消并照常处理该次点击。删除译文框两个入口：右键标注 → 菜单「删除译文框」；编辑器左下角删除按钮。删除 = `store.remove` + `scheduleSave` + overlay 重绘；进行中的 LLM 任务对已删 id 的 `store.update` 是 no-op，不会复活。
9. **框选稳健性（M5 后）**：选区以**页面坐标**记录锚点（非视口坐标），触摸板惯性滚动不会使选区错位；拖拽接近视口上/下边缘 28pt 时**自动滚动**（28→0 线性加速），使高于视口的区域也能一次框全；松手时按页面坐标 clamp 到该页并校验 ≥3pt。

## 实施阶段

- **M1 骨架**：SwiftPM executable + SwiftUI 窗口；NSOpenPanel 打开 PDF；PDFView 连续滚动 + 缩放（按钮 + 触控板捏合）。
- **M2 框选截图**：SelectionOverlay 拖拽框选；选区 → 高清 PNG 并预览确认清晰。
- **M3 LLM 打通**：设置页（base URL/key/model + 测试连接）；框选松手 → 截图 → API → TranslationAnnotation 覆盖原文；点击切换看原文。
- **M4 渲染管线（已完成）**：MarkdownToTypst + TypstRenderer（typst + mitex 0.2.7 编译为单页矢量 PDF）；标注按渲染尺寸自动定位/加宽；双击编辑（markdown 文本域 + typst 实时预览）。spike 结论见决策 4。
- **M5 持久化 + 导出（已完成）**：sidecar 自动保存/加载校验；导出标注 PDF（**CGPDFContext 逐页扁平化**，见决策 2 的实测结论）。已 headless 验证：导出页尺寸与原页一致、原页矢量完整、CJK/公式字形无错乱；sidecar save→load 往返一致、sha 不匹配时拒绝加载。
  - **实测坑（2026-09-25）**：`beginPDFPage` 的 `kCGPDFContextMediaBox` **只认 CFData 装的裸 CGRect 字节**（`Data(bytes:&box, count: MemoryLayout<CGRect>.size)`）；直接传 `CGRect` 或 `CGRectCreateDictionaryRepresentation` 都会被**静默忽略**，页面回落到 context 默认 612×792。
- **M6 体验打磨（2026-09-28）**：见下节。

## M6 体验打磨（2026-09-28）

目标：打开即读、操作有反馈、出错能恢复、不丢数据。

- **应用外壳**：单窗口（`Window` 场景，关窗即退出）；工具栏只放图标按钮（打开 / 缩放 / 收起展开全部译文 / 导出 / 设置），标题 = 文件名、副标题 = 页码；标题栏代理图标（`representedURL`）。设置改为独立 Settings 窗口（⌘,）。
- **打开**：⌘O、拖入窗口、「打开最近使用」菜单、空状态页最近文件列表、Finder「打开方式」（`scripts/make-app.sh` 打包 .app 并注册 PDF 文档类型）、`swift run EndTranslate x.pdf`。启动时自动打开上次的文件。
- **阅读位置**：按**原始页坐标**（去掉译文槽）记录视口顶端 + 缩放（nil = 适应宽度），滚动停止 0.4s 后存 UserDefaults；重开同一文件回到原处。恢复完成前不记录，避免 PDFView 装载文档时的「第 1 页」通知覆盖。
- **反馈**：底部状态胶囊：翻译进行中计数 / 结果 toast（成功 2s、错误 5s、带操作 6s）；toast 可带操作按钮（撤销、在 Finder 中显示）。
- **翻译中**：确认后译文槽立即按预估高度（选区高 ×0.6，夹在 22–120pt）展开并显示骨架动画，结果到达后替换为 typst 渲染，减少页面跳动。
- **失败与恢复**：失败框为红底红字，错误信息映射为人话（401/403/404/429/5xx、超时、断网、DNS…）+「点击重试」；单击失败框 = 重试。重启后译文为空的标注显示「上次未完成」，同样可点击重试。未配置翻译服务时点「翻译」→ 提示并打开设置，选区保留不丢。
- **选区确认 chip**：Return 确认、Esc 取消（拖拽中 Esc 放弃）；悬停高亮。
- **单击 / 双击**：单击立即切换原文/译文（不等待双击超时）；若紧接着第二击构成双击，则撤销第一击的切换并打开编辑器——避免「第一击收起译文框，第二击落空」。编辑器保存改为 ⌘↩（↩ 留给文本输入）。
- **悬停与光标**：译文框悬停加深底色与左侧色条 + 手型光标；页面上十字光标；页外箭头；⌥ 按住时在译文框上也显示十字（强制框选）。
- **右键菜单**：编辑译文 / 拷贝译文（markdown 原文）/ 重新翻译 / 收起展开 / 删除。删除可撤销（⌘Z 或 toast「撤销」），恢复到原顺序。
- **全局**：⇧⌘T 收起/展开全部译文；⌘= / ⌘- / ⌘0 / ⌘9 缩放；⇧⌘E 导出。
- **重绘策略**：覆盖层由通知驱动重绘（PDFView 内部视图 bounds/frame 变化、缩放、文档变化），计时器只在需要时运行（拖拽中、有骨架动画、视口变化后 0.25s），空闲阅读零唤醒；骨架动画只重绘各自矩形，绘制时按 dirtyRect 跳过不相交的译文框。覆盖层不拦截滚动条点击。
- **导出**：保存面板以 sheet 弹出，默认同目录 `<名>-译注.pdf`；导出样式与屏幕一致（浅蓝底 + 左侧色条，不再描边）；绘制原页前平移 mediaBox 原点（与 PageGapper 同一处理），修正原点非零的 PDF 内容偏移。
- **数据安全**：防抖保存（0.5s）在关窗、退出、切换文件时立即落盘，保存任务强引用模型以免窗口关闭后丢失；标注全部删除时移除 sidecar 文件；sidecar 与 PDF 版本不匹配时不加载、提示，并在首次覆盖前备份为 `<名>.etr.json.bak`。
- **LLM**：模型若把整段答复包进 ```markdown 围栏则剥除（其他语言的代码块保留）；Base URL 为 localhost / 127.0.0.1 时允许不填 API Key；设置页提供 OpenAI / DeepSeek 预设。

## 验收标准

### 可靠性收尾（2026-10-09）

- `AnnotationPersistence` 按文档管理保存状态：只有写入或删除真正成功后才清除未保存标记；保存失败持续提示，可重试，切换文件、关窗和退出均先检查保存结果。
- 损坏、不可读或版本不支持的 sidecar 与“文件不存在”分开处理。覆盖前必须先成功备份；旧 `.bak` 保留，后续使用编号后缀。
- 导出包含纯文本降级译文；已加载、仍待 Typst 排版的译注先用纯文本计算位置，避免此时导出漏掉内容。
- 打开 PDF 的哈希准备期间保留待确认选区，加载完成后再允许创建译注；异步回调按文档会话检查，切换文件清空撤销历史。
- 自动回归测试使用 Swift Testing；`zsh scripts/test.sh` 兼容仅装 Command Line Tools 的环境。使用方法见 `README.md`。
- v0.6.1 验证：17 项自动回归通过；独立应用窗口内模拟只读目录，确认保存错误持续显示、关闭/退出/切换文件均被阻止，恢复权限后重试保存的内容与编辑稿完全一致，窗口随后正常关闭。发布构建和 `.app` 打包通过。真实翻译 API 与 500 页文档性能仍需单独验收。
- v0.6.2 修正错误/纯文本的方向、字号与内边距缩放；401 与 403 分别提示认证与权限问题，配置类失败提供“打开设置”入口。钥匙串服务按 bundle ID 隔离，正式应用继续使用原来的 `app.endtranslate` 条目。
- v0.6.2 验证：19 项自动回归通过，其中错误和纯文本各比较 50%、100%、200% 缩放的屏幕与 PDF 绘制像素；独立原生窗口确认实际大小和适应宽度下文字正向、字号同步，模拟 401 后可打开设置、查看 403 提示，服务恢复后测试连接及原选区重试成功，译文已保存。模拟流程仅使用合成 PDF、本机接口和独立钥匙串；发布构建与签名检查通过。真实服务最近返回 Key 无效，仍需在应用内填写对应服务商的有效 Key 才能验证真实翻译。

### 手动验收

1. `swift build` 通过，运行后窗口正常打开 PDF、滚动缩放流畅。
2. 500 页扫描版 PDF 连续滚动浏览流畅、内存正常（PDFKit 自管理缓存）。
3. 端到端：打开真实英文论文 PDF → 框选段落 → 译文框出现在选区上方（拼音标注位，原文完整可见）→ 双击编辑译文并实时预览 → 重启应用标注仍在 → 导出 PDF 在 macOS Preview 打开，译文（含公式）清晰、原页内容完整。
4. 公式：含行内与独立公式的选区渲染成功（矢量）；失败公式回退原样文本不崩，且不牵连同框其他公式。
