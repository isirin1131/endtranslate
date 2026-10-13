# 第三方组件

EndTranslate 的应用源码采用 MIT 许可证。下列组件随应用本地提供，各自保留原许可证：

| 组件 | 版本 | 许可证 |
| --- | --- | --- |
| [MathJax](https://github.com/mathjax/MathJax) | 4.1.3 | Apache-2.0 |
| [MathJax TeX 数学字体](https://github.com/mathjax/MathJax-fonts) | 4.1.3 | Apache-2.0 |
| [markdown-it](https://github.com/markdown-it/markdown-it) | 15.0.2 | MIT |
| mdurl、uc.micro、linkify-it、punycode.js | 版本见资源清单 | MIT |
| entities | 版本见资源清单 | BSD-2-Clause |

完整许可证文本位于 [THIRD_PARTY_NOTICES.txt](Sources/EndTranslate/Resources/Renderer/vendor/THIRD_PARTY_NOTICES.txt)，也包含在应用资源中。精确版本和每个资源文件的 SHA-256 见 [manifest.json](Sources/EndTranslate/Resources/Renderer/manifest.json)。

第三方代码由其上游维护；本项目的 Markdown 公式识别规则、排版样式和 WebKit 集成位于 `scripts/render-assets` 与 `Sources/EndTranslate/Render`。更新方法见 [DEVELOPMENT.md](DEVELOPMENT.md)。
