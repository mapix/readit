# MarginNote 3 · 沉浸式翻译（Immersive Translate for MarginNote）

在 MarginNote 3 里复刻浏览器「沉浸式翻译」的段落级双语对照体验，翻译模型默认 **Claude Haiku 5.5**。

## 三种用法

| 模式 | 效果 | 适合 |
| --- | --- | --- |
| **双语对照**（默认，点工具栏「译」） | 原 PDF 原样渲染（公式、图表、排版全保留），每段原文下方插入独立的译文段落，滚动时 PDF 同步翻页 | 快速通读 |
| **生成双语 PDF**（对照视图右上角按钮） | 把全文翻译后生成一份真实的双语 PDF（原页矢量内容按段切开，译文排在段落下方），自动存进 MarginNote 文档库，名为 `xxx（双语）.pdf` | **精读 + 批注**：在这份 PDF 上可以用 MarginNote 所有原生功能，包括高亮、摘录、脑图、卡片、复习 |
| **原版 PDF**（对照视图中切换） | 关闭对照视图，回到原 PDF；段落上叠加译文，点段落或左侧「译」徽标可在原文/译文之间切换 | 在原文上批注、偶尔看译文 |

此外，启用后在任意模式下选中文字都会弹出划词翻译卡片。

## 安装

```bash
./install.sh
```

脚本会复制插件到 `~/Library/Containers/QReader.MarginStudyMac/Data/Library/MarginNote Extensions/`，开启「允许未认证插件」，从环境变量 `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_BASE_URL` 写入 API 配置，然后重启 MarginNote。也可以直接双击 `ImmersiveTranslate.mnaddon` 安装。

每次启动 MarginNote 会弹一次「未认证插件」警告，点 OK 即可；未认证插件都会有这个提示，无法关闭。

## 设置（对照视图 →「设置」）

翻译引擎（Claude / Google 免费）、目标语言、模型（默认 `claude-haiku-5-5`）、API Base URL / Key、译文样式（竖线 / 下划线 / 模糊遮罩学习模式）、自动翻译、预翻译后续页。

译文按文档缓存在插件目录的 `cache/` 下，重复打开不会再次消耗额度。

## 已知限制

- 扫描版 PDF 没有文本层，无法识别段落（需要先 OCR）。
- 「双语 PDF」中原页被切成多个横条，跨段的图片若被切到会显示在两条之间（切点总是选在段落之间，不会切开文字行）。
- 仅支持 PDF；EPUB 文档不可用。
