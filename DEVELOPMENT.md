# 开发说明

本文说明当前实现。用户操作和构建入口见 [README.md](README.md)，历史方案通过 Git 历史查看。

## 数据与显示

- `Annotation` 保存原始页索引、PDF 页面坐标中的选区、Markdown/LaTeX 译文及创建时间。
- `AnnotationStore` 管理译注和临时显示状态。`TranslationAnnotation` 是普通 Swift 对象。
- `ReaderWorkspaceView` 采用窗口左右独立面板布局：左侧为保持原始版式不变的 `PDFView`，右侧为存放译文悬浮卡片的侧边栏（可拖拽分栏线调整宽度）。
- `SelectionOverlay` 跨越左右面板，在左侧绘制原文高亮框，在右侧根据译文内容自适应计算卡片宽高。只有原文高亮框当前位于 PDF 可视区域内时，对应译文才参与侧边栏排版；离屏译文立即清空 `bounds` 并释放空间。`CardSidebarLayout` 先用 Knuth-Plass 动态规划分行（行内按权重 100% 撑满侧边栏宽度，短标签可在高卡片旁堆叠为子列），再用 Box-and-Glue 规则放大或压缩行高，确保所有在屏译文完整装入侧边栏，最后由 PAVA 保序回归贴近原文锚点且不重叠；`CardConnector` 绘制三次贝塞尔连线将原文框与译文卡片关联起来。
- 连线按可见配对数分层：≤4 对画一条 0.16 透明度的合并细线，5–7 对降到 0.09，≥8 对完全隐藏；鼠标悬停任一侧时只画当前配对，并同时增强原文框与卡片。原文框锚点圆点在连线隐藏时仍然保留。`ReaderTheme` 区分白纸表面（固定深靛蓝）和侧栏表面（亮/暗动态色），译文卡片始终保持白纸。
- 待确认选区只有在点击“翻译”或按 Return 后才截图和提交。移动、缩放及取消都在本机完成。

## 渲染

`MarkdownRenderer` 使用系统 WebKit 和随应用提供的资源，解析 Markdown 并直接排版 LaTeX 数学公式。源码中的 `Resources/Renderer` 是可直接使用的运行时资源；普通 Swift 构建不需要 Node.js 或联网安装依赖。

1. Markdown 解析规则先识别公式，使 Markdown 的转义和强调规则不会改写 LaTeX。
2. MathJax 把每条公式排成 SVG；无法识别的公式单独保留源码。每条译文开始前重置公式编号和自定义宏，避免影响下一条译文。
3. WebKit 按选区宽度生成单页矢量 PDF，`RenderedTranslation` 提供统一绘制接口，供屏幕、预览及导出调用。

排版任务串行使用一个按需创建的 WebKit 视图，相同内容合并请求。空闲一分钟后释放视图。内存缓存最多 64 条、32 MiB，磁盘缓存位于应用缓存目录的 `translations-v2`；启动时清理超过 14 天未使用的条目。修改排版代码、样式或第三方资源后，应更新 `MarkdownRenderer.cacheVersion`。

打开已有译注时只排版当前视口内的卡片；其余译注在滚动进入视口时按需排版，导出前再补齐。失败过的按需排版不会逐帧重试，编辑或重新翻译会重置该状态。

渲染页面使用非持久化网站数据存储，禁止网络连接、外部图片和导航。Markdown 中的 HTML 按文本处理，链接只保留标签。数学扩展采用固定列表，不允许公式动态加载宏包。WebKit 操作有超时处理，失败后重建渲染视图并保留译文文本。

屏幕 overlay 的坐标向下，PDF 的坐标向上。`RenderedTranslation.draw` 与 `TranslationAnnotation.drawText` 根据 `yDown` 参数处理方向；文本与内边距按 PDF 页面缩放。

## 保存与导出

- `AnnotationPersistence` 只在写入或删除成功后清除未保存标记。切换文档、关窗和退出前均检查保存结果；失败时保留内存中的改动并提供重试。
- `SidecarIO` 检查 PDF 的 SHA-256 和数据版本。已有文件损坏或不匹配时，覆盖前必须先成功备份，已存在的备份不会覆盖。
- `PDFExporter` 使用 Core Graphics 按页绘制原始 PDF 与右侧栏已完成译文卡片及连线。公式保持矢量，渲染尚未完成的译文可按文本导出。导出按页异步让出主线程，显示进度并支持取消；先写入同目录临时文件，成功后再替换目标文件，取消或失败不会留下半个 PDF。
- `LLMClient` 对 429、500/502/503/504、超时和连接中断做有限指数退避重试，遵守 `Retry-After`；不重试 4xx 认证/参数错误。`finish_reason` 为 `length`/`max_tokens` 时视为截断并提示重试。删除、重新翻译或切换文档时会取消在途请求。
- API Key 只存入钥匙串，按应用 bundle ID 隔离。命令行构建转为正式应用时，仍保留设置和阅读历史迁移。
- 运行日志使用 macOS 统一日志，动态消息默认私有；不记录 API 响应正文。

## 更新内置资源

仅在修改 Markdown 解析规则、排版脚本或升级组件时需要 Node.js：

```sh
cd scripts/render-assets
npm ci --ignore-scripts
npm test
npm run build
```

依赖版本由 `package-lock.json` 固定。构建脚本打包 Markdown 代码、MathJax 运行时、选用的数学扩展和字体，并生成许可证及 SHA-256 清单。提交资源更新时，一并提交源脚本、锁文件、生成资源和清单。`scripts/make-app.sh` 会将资源直接复制到应用的 `Contents/Resources/Renderer`，使发布包可独立运行。

## 验证

```sh
zsh scripts/test.sh
zsh scripts/make-app.sh
```

回归使用 Swift Testing，包括真实 WebKit 排版；不需要 Xcode 的 XCTest 运行时。窗口验收使用合成 PDF、本地模拟翻译接口和独立 bundle ID，避免接触真实 API Key 或阅读资料。验证重点包括公式与正文布局、编辑后重新排版、现有译注重新打开、多个请求并行返回，以及导出 PDF 中的文字和矢量公式。

在受限环境或沙箱中执行构建/测试若出现模块缓存或嵌套沙箱权限报错（`Operation not permitted`），可为 `swift` 命令添加 `--disable-sandbox` 参数，或设置 `export CLANG_MODULE_CACHE_PATH=.build/module-cache` 隔离 Clang 模块缓存路径。
