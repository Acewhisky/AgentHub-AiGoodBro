# README 图片 · 0909v4

本版相对 0907v3：新增中英文大字封面；界面图由 9.5.15 (29) 最终源码重新原生渲染，显示当前默认 Astra / Low / 标准速度、问题日志与优先选号说明。历史图片保留原路径。

| 顺序 | 中文 | English | 来源 |
|---|---|---|---|
| 1 | [封面](01-readme-cover-zh.png) | [Cover](01-readme-cover-en.png) | 内置生图工具；英文由中文图翻译排版 |
| 2 | [卡片工作台](02-workspace-cards-zh-dark@2x.png) | [Account cards](02-workspace-cards-en-dark@2x.png) | 生产 SwiftUI 组件，九个演示账号，深色，2× |
| 3 | [列表工作台](03-workspace-list-zh-light@2x.png) | [Account list](03-workspace-list-en-light@2x.png) | 生产 SwiftUI 组件，九个演示账号，浅色，2× |

原生界面图不读取真实账号凭据，不连接 Hub、不访问 Keychain、不调用模型。未知状态和按钮门禁保持真实组件行为；截图不能证明真实切号、派单、暖号或通知送达。

封面沿用大字、奶油白、蓝色主体和少量积木装饰的系列风格，内容为当前产品重新撰写。[完整生图提示词](PROMPT.md)单独保存；尺寸、文件大小和 SHA-256 见 [manifest.json](manifest.json)。

原生渲染入口：

```sh
build/CodexAccountManagerNext.app/Contents/MacOS/CodexAccountManagerNext --render-workspace-previews <output-directory>
build/CodexAccountManagerNext.app/Contents/MacOS/CodexAccountManagerNext --render-workspace-previews <output-directory> --preview-english
```

这些入口只运行隔离演示渲染，不启动日常实例。README 使用第 1、2 张，详细使用说明补充第 3 张。
