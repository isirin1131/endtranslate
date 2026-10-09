# EndTranslate

在 Mac 上边读边译 PDF。拖拽框选英文段落，确认后由视觉模型翻译，中文译文插在原文上方。支持数学公式、编辑译文、自动保存和导出。

## 环境

- macOS 14 或更新版本。
- Swift Command Line Tools；运行自动测试需要带 Swift Testing 的 Swift 6 工具链。
- 支持图片输入的 OpenAI 兼容接口，地址、模型和 API Key 在应用设置中填写。
- 本机 Typst 用于中文与公式排版；不可用时译文以纯文本显示和导出。

应用不依赖第三方 Swift 包，也不需要完整 Xcode。Typst 首次排版可能需要下载 `@preview/mitex:0.2.7`。

## 构建和运行

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

- 拖拽框选，按 Return 或点击“翻译”确认；Esc 取消。
- 单击译文收起或展开，双击编辑；编辑器中按 ⌘Return 保存。
- 按住 Option 拖拽，可以在已有译文上重新框选。
- 右键可以重新翻译、拷贝、删除；删除支持 ⌘Z 撤销。
- ⌘O 打开文件，⌘, 配置服务，⇧⌘E 导出 PDF。

## 译注保存

例如 `paper.pdf` 的译注保存在同目录的 `paper.etr.json`。移动或备份阅读资料时，把这两个文件放在一起。API Key 保存在 macOS 钥匙串，不写入译注文件。

译注修改后自动保存；切换文件、关闭窗口和退出前会再次保存。保存失败时，底部持续显示提示和“重试保存”，改动仍留在内存中；保存成功后才能切换或关闭当前文档。

如果已有译注损坏、属于另一个 PDF 版本，或使用了应用不支持的数据版本，应用会提示并保留原文件。再次保存前，先备份为 `.etr.json.bak`；已有备份不会被覆盖，后续备份使用 `.bak.1`、`.bak.2` 等后缀。备份失败时不会覆盖原译注。

导出包含当前展开且已完成的译文，包括 Typst 不可用时的纯文本译文；收起、翻译中或失败的译文不写入导出的 PDF。

## 回归测试

```sh
zsh scripts/test.sh
```

脚本自动处理 Command Line Tools 的 Testing 框架路径。测试使用临时文件和合成 PDF，不调用翻译 API，也不依赖 Typst。覆盖保存/删除失败与重试、损坏文件备份、PDF 校验、纯文本与矢量导出等路径。权限测试需要普通用户运行；root 运行时会跳过这些用例。

完整设计和历史实现说明见 [PLAN.md](PLAN.md)。
