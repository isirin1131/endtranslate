# EndTranslate

在 Mac 上边读边译 PDF。拖拽框选英文段落，确认后由视觉模型翻译，中文译文插在原文上方。支持数学公式、编辑译文、自动保存和导出。

A native macOS PDF reader with inline translation, LaTeX math rendering, and annotated PDF export. Built with SwiftUI, AppKit, and PDFKit.

当前版本 **1.0.0**。可从 [GitHub Releases](https://github.com/isirin1131/endtranslate/releases/latest) 下载 Apple Silicon 版应用；Intel Mac 请从源码构建。下载包采用本地签名，尚未经过 Apple 公证。

## 环境

- macOS 14 或更新版本。
- 从源码构建需要 Swift Command Line Tools；运行自动测试需要带 Swift Testing 的 Swift 6 工具链。
- 支持图片输入的 OpenAI 兼容接口，地址、模型和 API Key 在应用设置中填写。
- 本机 Typst 用于中文与公式排版；不可用时译文以纯文本显示和导出。

应用不依赖第三方 Swift 包，也不需要完整 Xcode。Typst 首次排版可能需要下载 `@preview/mitex:0.2.7`。

## 构建和运行

先安装 Command Line Tools；需要公式排版时，使用 Homebrew 安装 Typst：

```sh
xcode-select --install
brew install typst
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
- 在顶部页码框输入页数，按 Return 跳转；⌘L 可直接选中页码。左右箭头按钮或 ⌥⌘← / ⌥⌘→ 切换上一页、下一页。页码从 PDF 的第一页开始计数。
- 点击工具栏“目录”或按 ⌥⌘1 展开侧栏，点击章节跳转。支持分层目录；插入或收起译文后，目录仍定位到对应原文。没有内嵌目录的 PDF 可使用页码跳转。
- 单击译文收起或展开，双击编辑；编辑器中按 ⌘Return 保存。
- 按住 Option 拖拽，可以在已有译文上重新框选。
- 右键可以重新翻译、拷贝、删除；删除支持 ⌘Z 撤销。
- ⌘O 打开文件，⌘, 配置服务，⇧⌘E 导出 PDF。

如果翻译出现 HTTP 401，打开设置，核对 Base URL 和 API Key 是否属于同一服务商，并重新填写有效的 Key；HTTP 403 则需要检查模型权限或账户限制。先用“测试连接”验证，再点击失败的译文框重试。Key 只需填在应用中。

确认翻译后，应用会把选区截图发送到你配置的 API 服务。PDF 和译注在本机保存；API 服务的费用和数据处理规则由所选服务商决定。

## 译注保存

例如 `paper.pdf` 的译注保存在同目录的 `paper.etr.json`。移动或备份阅读资料时，把这两个文件放在一起。API Key 保存在 macOS 钥匙串，不写入译注文件。

译注修改后自动保存；切换文件、关闭窗口和退出前会再次保存。保存失败时，底部持续显示提示和“重试保存”，改动仍留在内存中；保存成功后才能切换或关闭当前文档。

如果已有译注损坏、属于另一个 PDF 版本，或使用了应用不支持的数据版本，应用会提示并保留原文件。再次保存前，先备份为 `.etr.json.bak`；已有备份不会被覆盖，后续备份使用 `.bak.1`、`.bak.2` 等后缀。备份失败时不会覆盖原译注。

导出包含当前展开且已完成的译文，包括 Typst 不可用时的纯文本译文；收起、翻译中或失败的译文不写入导出的 PDF。

## 回归测试

```sh
zsh scripts/test.sh
```

脚本自动处理 Command Line Tools 的 Testing 框架路径。31 项测试使用临时文件和合成 PDF，不调用翻译 API，也不依赖 Typst。覆盖保存/删除失败与重试、损坏文件备份、PDF 校验、纯文本与矢量导出、不同缩放下的文字绘制、选区移动和八方向缩放边界、页码校验、切换文档后的页码同步、分层目录，以及插入或移除译文后的跳转坐标。权限测试需要普通用户运行；root 运行时会跳过这些用例。

完整设计和历史实现说明见 [PLAN.md](PLAN.md)。

## 许可证

源码使用 [MIT License](LICENSE)。Typst 和 mitex 作为外部工具使用，遵循各自的许可证。
