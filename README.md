# EndTranslate

在 Mac 上边读边译 PDF。拖拽框选英文段落，确认后由视觉模型翻译，中文译文以悬浮卡片形式统一显示在右侧边栏，并通过连线与被框选的原文关联，轻松应对多栏、图文混排等复杂版式。支持数学公式、编辑译文、自动保存和导出。

A native macOS PDF reader with inline translation, LaTeX math rendering, and annotated PDF export. Built with SwiftUI, AppKit, and PDFKit.

当前版本 **1.3.0**。可从 [GitHub Releases](https://github.com/isirin1131/endtranslate/releases/latest) 下载 Apple Silicon 版应用；Intel Mac 请从源码构建。下载包采用本地签名，尚未经过 Apple 公证。

## 环境

- macOS 14 或更新版本。
- 从源码构建需要 Swift Command Line Tools；运行自动测试需要带 Swift Testing 的 Swift 6 工具链。
- 支持图片输入的 OpenAI 兼容接口，地址、模型和 API Key 在应用设置中填写。
- Markdown 和 LaTeX 公式在应用内排版，无需安装额外工具或下载字体。

应用使用系统自带的 PDFKit 和 WebKit，内置 Markdown 解析器、MathJax 和数学字体。公式渲染资源随应用提供，不访问 CDN。

## 构建和运行

从源码构建时，先安装 Command Line Tools：

```sh
xcode-select --install
```

获取源码：

```sh
gh repo clone isirin1131/endtranslate
cd endtranslate
```

编译并打开 PDF：

```sh
swift build
swift run EndTranslate /path/to/paper.pdf
```

也可以直接运行 `swift run EndTranslate`，再从窗口打开 PDF。

生成可双击的应用：

```sh
zsh scripts/make-app.sh
```

产物位于 `build/EndTranslate.app`。需要安装到个人应用目录时，运行 `zsh scripts/make-app.sh --install`。

## 阅读和翻译

- 拖拽框选后，可以拖动四角或边缘调整范围，也可以拖动框内移动整个选区。按 Return 或点击“翻译”才会提交；Esc 或“取消”放弃选区。
- 左侧 PDF 视图保持原文档排版，右侧只显示当前窗口内可见原文对应的译文；卡片按内容权重撑满侧边栏宽度，稀疏时自动舒展、密集时压缩至一屏内，并通过连线关联对应段落；即使在已有高亮框内也可直接再次拖拽框选。
- 鼠标移到原文高亮框或译文卡片上时，成对的两框会同步高亮，并只显示这一对之间的引线；空闲时引线会随可见卡片数量自动变淡或隐藏，避免密集排版被连线淹没。
- 在顶部页码框输入页数，按 Return 跳转；⌘L 可直接选中页码。左右箭头按钮或 ⌥⌘← / ⌥⌘→ 切换上一页、下一页。页码从 PDF 的第一页开始计数。
- 点击工具栏“目录”或按 ⌥⌘1 展开侧栏，点击章节跳转。支持分层目录；没有内嵌目录的 PDF 可使用页码跳转。
- 双击译文卡片或原文高亮框可编辑译文；编辑器中按 ⌘Return 保存。
- 右键可以重新翻译、拷贝、删除；删除支持 ⌘Z 撤销。
- ⌘O 打开文件，⌘, 配置服务，⇧⌘E 导出 PDF。

如果翻译出现 HTTP 401，打开设置，核对 Base URL 和 API Key 是否属于同一服务商，并重新填写有效的 Key；HTTP 403 则需要检查模型权限或账户限制。先用“测试连接”验证，再点击失败的译文框重试。Key 只需填在应用中。遇到 429、可恢复的 5xx、超时或连接中断时，应用会自动做有限次重试；如果译文超出模型输出上限，会提示内容可能不完整，而不是当作成功保存。

确认翻译后，应用会把选区截图发送到你配置的 API 服务。PDF 和译注在本机保存；API 服务的费用和数据处理规则由所选服务商决定。

## 译注保存

例如 `paper.pdf` 的译注保存在同目录的 `paper.etr.json`。移动或备份阅读资料时，把这两个文件放在一起。API Key 保存在 macOS 钥匙串，不写入译注文件。

译注修改后自动保存；切换文件、关闭窗口和退出前会再次保存。保存失败时，底部持续显示提示和“重试保存”，改动仍留在内存中；保存成功后才能切换或关闭当前文档。

如果已有译注损坏、属于另一个 PDF 版本，或使用了应用不支持的数据版本，应用会提示并保留原文件。再次保存前，先备份为 `.etr.json.bak`；已有备份不会被覆盖，后续备份使用 `.bak.1`、`.bak.2` 等后缀。备份失败时不会覆盖原译注。

重新打开已有译注时，应用只排版当前视口内的译文卡片；滚动到其他位置时再按需排版，因此打开大量译注的文档不会先卡住。导出前会补齐所有已完成译文，排版失败时回退为文本。

导出包含当前已完成的译文卡片与连线，正文和公式保持矢量。导出过程显示进度，可随时取消；取消或失败不会留下半个 PDF 文件。排版暂不可用时仍可导出译文文本；翻译中或失败的译文不写入导出的 PDF。

## 公式与排版

正文使用 Markdown，公式使用 LaTeX：行内 `$...$` 或 `\(...\)`，独立公式 `$$...$$` 或 `\[...\]`。支持常见数学环境、分式、矩阵、求和、积分和公式编号标记。代码块中的公式示例保持原样。

模型输出、编辑器内容和译注文件使用同一种格式。正文由 markdown-it 解析，公式由 MathJax 直接排版成 SVG，再由系统 WebKit 生成矢量译文。阅读、编辑预览和 PDF 导出使用同一份排版结果。

不支持的公式会显示其 LaTeX 源码，其余公式和正文继续正常排版。支持范围是 MathJax 的数学语法；自定义 TeX 宏包和完整 LaTeX 文档不属于输入格式。译文中的 HTML 按文字显示，外部图片不会下载。

已有 `.etr.json` 译注可直接打开，无需重译或转换。

## 回归测试

```sh
zsh scripts/test.sh
```

脚本自动处理 Command Line Tools 的 Testing 框架路径。测试使用临时文件和合成 PDF，不调用翻译 API。覆盖保存与恢复、文本和矢量导出、缩放与坐标、可调整选区、页码和目录导航，以及真实 WebKit 公式渲染、并发排版和缓存。权限测试需要普通用户运行；root 运行时会跳过这些用例。

当前架构、资源更新方式和验证流程见 [DEVELOPMENT.md](DEVELOPMENT.md)。

## 许可证

应用源码使用 [MIT License](LICENSE)。内置第三方组件及其许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
