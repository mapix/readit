(() => {
  'use strict';
  const $ = selector => document.querySelector(selector);
  const $$ = selector => [...document.querySelectorAll(selector)];
  let language = 'zh';
  const t = (zh, en) => language === 'en' ? en : zh;
  const pairs = new Map($$('[data-en]').map(node => [node, node.innerHTML]));

  const chapters = [
    ['bilingual', ['双语精读', 'Bilingual'], ['保留原 PDF 矢量排版与网页交互结构，每段原文下方紧贴精准译文。', 'Preserve vector PDF layout and live web interactivity with paragraph-by-paragraph bilingual translation.'], 'file'],
    ['web', ['动态网页', 'Live Web'], ['粘贴网址即可导入可交互网页，默认移除周边非正文干扰，无分页连续锚点跨端同步。', 'Import live interactive webpages by URL, auto-declutter peripheral chrome, and sync continuous 0%–100% anchors.'], 'search'],
    ['notes', ['摘录与脑图', 'Notes & Map'], ['八色高亮、框选截图、MarginNote 式思维导图与跨文档双向卡片链接。', 'Eight-color highlights, area snapshots, MarginNote-style mind maps, and cross-document card links.'], 'grid'],
    ['narrate', ['语音与对话', 'Narration & Chat'], ['AI 看着页面原图逐页口语化讲解，支持按住麦克风打断追问与页码溯源对话。', 'Multimodal page-by-page AI voice narration with live mic interruption and page-cited Copilot Q&A.'], 'spark'],
    ['flashcards', ['闪卡记忆', 'Flashcards'], ['AI 自动提炼概念、理解、应用、数据四类闪卡，配合 SM-2 间隔重复算法巩固记忆。', 'AI-generated Concept, Comprehension, Application, and Data flashcards with SM-2 spaced repetition.'], 'spark'],
    ['responders', ['净化与编辑', 'Clean & Edit'], ['网页非正文自动净化可按篇开关，PDF 无损截断、区域擦除与删除页随时一键还原。', 'Per-article non-destructive web decluttering plus lossless PDF truncation, region erase, and instant restore.'], 'file'],
    ['models', ['模型与语音', 'Models & TTS'], ['Anthropic、OpenAI、ChatGPT OAuth 与 9 大 TTS 引擎自由组合，支持系统离线零配置朗读。', 'Bring your own Anthropic/OpenAI gateway, native ChatGPT OAuth, and 9 TTS engines or offline system voice.'], 'spark'],
    ['native', ['原生双端', 'Mac & iOS'], ['macOS 与 iOS / iPadOS 原生构建，iCloud 容器与局域网 Bonjour 点对点直连同步。', 'Native macOS and iOS/iPadOS apps with iCloud ubiquity sync and LAN Bonjour peer-to-peer transfer.'], 'grid']
  ];

  const features = {
    bilingual: {
      chapter: 0,
      icon: 'file',
      title: ['每段原文下面，就是它的译文。', 'Under every paragraph, its translation.'],
      description: ['每一页都按原 PDF 的矢量内容绘制，公式、图表、字体、分栏都与原文一致。读到哪一页就翻译到哪一页并预翻后两页；在动态网页中则直接原位注入双语段落，跳过动态图表不破坏交互。', 'Every PDF page is drawn from vector content so formulas, figures, fonts, and columns stay intact. In live web documents, translations are injected in-place beneath each paragraph without disturbing interactive charts.'],
      notes: [
        ['原文 / 双语 ⌘1 · ⌘2 一键切换，阅读位置保持不变。', 'Switch Original / Bilingual with ⌘1 / ⌘2 without losing your reading position.'],
        ['公式、代码块、表格与伪代码自动识别跳过，不做冗余翻译。', 'Formulas, code blocks, tables, and pseudo-code are skipped automatically.'],
        ['支持导出完整保留排版的双语对照 PDF。', 'Export a complete layout-preserving bilingual PDF anytime.']
      ]
    },
    accounts: {
      chapter: 0,
      icon: 'file',
      title: ['矢量级版面重构', 'Vector- true layout reconstruction'],
      description: ['基于 CoreGraphics 与 PDFKit 底层字形流分析，自动识别单栏、双栏、标题、图注与脚注。译文按最佳字号与行距嵌入原文段落下方，缩放至 400% 依然锐利清晰。', 'Powered by low-level CoreGraphics glyph stream analysis to detect single/double columns, headings, captions, and footnotes—staying razor-sharp at any zoom level.'],
      notes: [
        ['译文缓存按文档与模型持久化，已翻译页面零等待秒开。', 'Translations are cached per document and model for instant reopening.'],
        ['跟随亮色、护眼羊皮纸、深色夜间三种阅读主题自动着色。', 'Adapts seamlessly to Light, Sepia, and Night reading themes.']
      ]
    },
    compose: {
      chapter: 0,
      icon: 'spark',
      title: ['按需预取，省时省额度', 'Smart look-ahead prefetching'],
      description: ['默认仅翻译当前正在阅读的页面并向后预翻 2 页（网页模式下随滚动视口 IntersectionObserver 自动按段翻译），无需等待数百页长文档全量跑完即可立即开始精读。', 'Translates the current page plus two pages ahead by default (or visible viewport paragraphs in web mode), saving both time and token quota.'],
      notes: [
        ['支持划词即译与单页一键重新翻译。', 'Includes instant selection translation and one-click page retranslation.'],
        ['翻译结果通过 iCloud 自动同步到 iPhone 与 iPad。', 'Cached translations sync automatically to iPhone and iPad via iCloud.']
      ]
    },
    translation: {
      chapter: 0,
      icon: 'spark',
      title: ['多模型自由切换', 'Any model gateway you trust'],
      description: ['兼容 Anthropic Messages、OpenAI Chat Completions、OpenAI Responses 以及 ChatGPT Plus/Pro OAuth 原生登录。可使用 Claude、GPT、DeepSeek、Qwen 等任意模型进行学术翻译。', 'Supports Anthropic Messages, OpenAI Chat Completions, OpenAI Responses, and native ChatGPT OAuth—use Claude, GPT, DeepSeek, or Qwen.'],
      notes: [
        ['支持 ~/.config/readlet/config.toml 与图形化设置双轨配置。', 'Configure via GUI Settings or ~/.config/readlet/config.toml.'],
        ['API 密钥安全存储于系统 Keychain。', 'API credentials are stored securely in Keychain.']
      ]
    },
    search: {
      chapter: 1,
      icon: 'search',
      title: ['输入网址，把动态交互好文装进书库。', 'Paste a URL. Keep every chart interactive.'],
      description: ['针对 Hugging Face Spaces、Distill 等包含 D3 / Canvas / WebGL / iframe 交互图表的现代技术长文，Readlet 支持以「可交互网页（DocKind.web）」模式直接入库：仅保存网址与你的批注、朗读、脑图、闪卡和阅读锚点，完整保留页面实时交互。', 'Built for interactive tech articles like Hugging Face Spaces and Distill: Readlet stores only the URL plus your personal overlays while keeping live D3, Canvas, and iframe visualizations 100% interactive.'],
      notes: [
        ['自动解包 Hugging Face Spaces 外壳直达真实内容源。', 'Automatically unwraps Hugging Face Spaces outer frames to load the live document directly.'],
        ['默认开启非破坏性「移除周边非正文」，可按篇文章随时一键开关。', 'Non-destructively hides peripheral navbars, sidebars, and TOCs by default—toggleable per article.'],
        ['同时支持一键提取为干净的静态 A4 PDF 归档。', 'Also supports one-click static A4 PDF extraction when you prefer fixed pages.']
      ]
    },
    people: {
      chapter: 2,
      icon: 'grid',
      title: ['选中即摘录，自动挂载思维导图', 'Select to excerpt, auto-linked to your mind map'],
      description: ['在标注模式下选中 PDF 或动态网页中的任意段落，点击八色圆点即可创建摘录卡片并自动加入当前笔记本脑图；使用拖拽框选工具还可直接截取复杂公式或交互图表当前状态。', 'Select text in any PDF or live webpage to create an 8-color highlight card automatically attached to your notebook mind map, or drag-capture formulas and live charts as image cards.'],
      notes: [
        ['脑图支持拖拽重组、Tab / Return 快捷键建节点与折叠展开。', 'Organize mind maps by drag-and-drop or Tab / Return keyboard shortcuts.'],
        ['双击脑图节点或卡片即可精准跳回 PDF 页码或网页语义锚点。', 'Double-click any node or card to jump straight back to the exact PDF page or web anchor.']
      ]
    },
    attachments: {
      chapter: 2,
      icon: 'file',
      title: ['一张卡片，贯通原文、脑图与闪卡', 'One card across source, mind map, and flashcards'],
      description: ['每条摘录不仅在原文留下高亮，还自动附带译文、支持多条批注评论，并可跨文档建立双向链接。网页高亮采用 W3C TextQuoteSelector 语义锚点，即使窗口缩放或重排也能精准还原。', 'Every excerpt highlights the source, attaches its translation, supports multi-comment notes, and links across documents. Web highlights use W3C TextQuoteSelector anchors that survive layout resizes.'],
      notes: [
        ['支持 TODO / DOING / DONE 阅读状态看板与自定义标签过滤。', 'Includes TODO / DOING / DONE status tags and custom tag filtering.'],
        ['支持导出 Markdown 读书笔记与双语 PDF。', 'Export structured Markdown notes or annotated PDFs.']
      ]
    },
    chat: {
      chapter: 3,
      icon: 'spark',
      title: ['看着页面原图讲给你听，随时打断提问。', 'Multimodal page-by-page voice narration & Copilot.'],
      description: ['AI 语音解读会将当前页面渲染为高清图像连同文本一起送入多模态模型，像播客搭档一样逐段讲解正文、图表趋势与公式含义，讲完自动翻页或滚屏。遇到疑问按住麦克风即可语音打断追问，答完自动续讲。', 'AI Narration sends both the rendered page image and text to multimodal models, explaining paragraphs, chart trends, and equations aloud while auto-advancing pages. Hold the mic anytime to interrupt with a question.'],
      notes: [
        ['首段未缓存时独占通道合成，杜绝预取抢占连接导致首字等待。', 'Exclusive first-segment synthesis channel ensures instant voice startup without prefetch contention.'],
        ['AI 助手回答自动标注 [p.X] 页码引用，点击直接跳回原文。', 'AI Copilot answers cite [p.X] page numbers you can click to jump back to the source.'],
        ['支持锁屏媒体控制中心（MPNowPlayingInfoCenter）与后台保活播放。', 'Integrates with system Now Playing controls and background audio keep-alive on iOS.']
      ]
    },
    multimodal: {
      chapter: 3,
      icon: 'spark',
      title: ['五种讲解风格与自定义提示词', 'Five narration styles & custom instructions'],
      description: ['内置「双人播客」「说书评书」「技术深度」「科普通俗」「精简速览」五种解读风格，并可附加你的专属补充提示词与朗读语言。每种风格的讲稿与音频独立缓存，切换无需重新生成。', 'Choose from Podcast, Storyteller, Deep Tech, Popular Science, or Executive Brief—plus custom prompt instructions. Each style caches its scripts and audio independently.'],
      notes: [
        ['支持 0.75× – 2.0× 无级倍速播放与分句呼吸框高亮跟随。', '0.75×–2.0× playback speed with sentence-level breathing highlight sync.'],
        ['支持一键「准备全部讲解」后台全量预生成整本书的讲稿与语音。', 'One-click "Prepare All Narration" pre-renders scripts and audio for the entire document.']
      ]
    },
    analysis: {
      chapter: 3,
      icon: 'file',
      title: ['导出竖屏字幕讲解视频', 'Export vertical subtitled narration videos'],
      description: ['在 macOS 上可将任意章节或整篇论文的 AI 语音讲解一键渲染为带页面高亮呼吸框、底部动态字幕与高品质 AAC 音轨的竖屏 MP4 视频，方便在手机上复盘或分享。', 'Render AI voice narration into a vertical MP4 video complete with synchronized page highlights, dynamic subtitles, and AAC audio on macOS.'],
      notes: [
        ['收起主窗口后可保留桌面悬浮迷你播放器，边听讲解边写代码。', 'Collapse into a floating desktop mini-player widget while you work in other apps.'],
        ['内置音视频缓存配额管理，可按单篇文档一键清理语音缓存。', 'Built-in storage manager lets you inspect and clear audio/video cache per document.']
      ]
    },
    openui: {
      chapter: 3,
      icon: 'grid',
      title: ['文档 AI 助手（Copilot）', 'Context-aware Document AI Copilot'],
      description: ['针对当前页或整篇文档一键生成结构化导读、核心贡献总结或公式推导拆解。选中原文任意句子即可直接「问 AI」，支持粘贴或附带页面截图进行多模态视觉追问。', 'Summarize the current page or full document, break down equations, or select any passage to Ask AI—complete with multimodal screenshot attachments.'],
      notes: [
        ['每篇文档的对话历史独立保存并通过 iCloud 跨端同步。', 'Conversation history is saved per document and synced via iCloud.'],
        ['回答中的所有页码标记均可点击回跳核验原文。', 'Every page citation in Copilot responses is a live link back to the source page.']
      ]
    },
    memory: {
      chapter: 4,
      icon: 'spark',
      title: ['读完一章，用 3D 闪卡检验是否真正读懂。', 'Turn chapters into 3D SM-2 flashcards.'],
      description: ['AI 通读全文或当前章节，自动生成「概念」「理解」「应用」「数据」四类结构化问答闪卡，每张卡片均记录原文出处页码。翻转卡片后标记「记住了」或「再看看」，由 SM-2 算法科学安排复习周期。', 'AI generates Concept, Comprehension, Application, and Data flashcards with source page citations. Flip cards in 3D and rate your recall with SM-2 spaced repetition scheduling.'],
      notes: [
        ['支持「只看未掌握」过滤与键盘 Space / 1 / 2 快捷刷卡。', 'Filter by unmastered cards and review rapidly with Space / 1 / 2 shortcuts.'],
        ['在 Mac 上生成闪卡，通勤路上拿起 iPhone 即可无缝刷卡复习。', 'Generate flashcards on Mac and review them on iPhone on the go via iCloud sync.']
      ]
    },
    responders: {
      chapter: 5,
      icon: 'file',
      title: ['非破坏性网页净化 & 无损 PDF 截断擦除。', 'Non-destructive Web Clean Mode & Lossless PDF Editing.'],
      description: ['动态网页默认开启智能净化（通过 CSS 属性隐藏顶栏、侧边目录、分享浮层与推荐栏，绝不破坏 DOM 树与交互脚本），并支持按篇文章随时关闭或用点选橡皮擦隐藏任意区块；PDF 文档则支持一键截断尾部冗余页、框选擦除区域与一键还原。', 'Web Clean Mode hides outer chrome via non-destructive CSS rules so live scripts never break—toggleable per article or customizable with the element eraser. PDFs support one-click tail truncation, region erase, and instant lossless restore.'],
      notes: [
        ['WebReadingAnchor 通过语义节点 ID + 段内偏移 + 百分比，在不同尺寸屏幕间精准还原进度。', 'WebReadingAnchor combines semantic DOM IDs, intra-element offsets, and scroll fraction across window sizes.'],
        ['超宽交互图表（.viz-box）在窄窗口、iPad 分屏与 iPhone 上自适应等比缩放。', 'Wide interactive charts (.viz-box) scale responsively across narrow windows, iPad Split View, and iPhone.']
      ]
    },
    models: {
      chapter: 6,
      icon: 'spark',
      title: ['你的阅读工作台，你自主选择的模型与声音。', 'Your reading workbench. Your choice of models & voices.'],
      description: ['支持系统离线语音（零配置开箱即讲）、主网关 TTS、OpenAI、Gemini、通义千问 Qwen-TTS、Azure、ElevenLabs、MiniMax 与火山引擎豆包语音合成；所有音频统一规范化为干净的 16-bit PCM WAV 播放并以 AAC .m4a 落盘缓存。', 'Works out of the box with offline system voices, or connect OpenAI, Gemini, Qwen-TTS, Azure, ElevenLabs, MiniMax, and Volcengine TTS—normalized to clean 16-bit PCM playback and cached as AAC .m4a.'],
      notes: [
        ['网关配置与各语音服务商 Key 可通过 iCloud Keychain 安全同步至 iOS 端。', 'Gateway settings and TTS provider keys sync securely to iOS via iCloud.'],
        ['远程 TTS 失败或超时时自动使用独立连接重试并平滑回退系统语音。', 'Remote TTS automatically retries on an isolated connection and falls back gracefully to system voice.']
      ]
    },
    appearance: {
      chapter: 7,
      icon: 'grid',
      title: ['亮色、护眼、夜间三套 MarginNote 风格主题', 'Light, Sepia, and Night themes'],
      description: ['界面采用经典高密度 MarginNote 阅读器美学，提供亮色、护眼羊皮纸与深色夜间三套配色，并完整支持简体中文、English 与日本語多语言界面。', 'Crafted with a focused MarginNote-inspired aesthetic in Light, Sepia, and Night palettes, with full Simplified Chinese, English, and Japanese localization.'],
      notes: [
        ['网页顶部的三色圆点可实时切换本次展览页面的视觉主题。', 'Use the three color swatches in the hero to switch this exhibition page’s palette live.'],
        ['支持多文档独立窗口与全局快捷键操作。', 'Supports multi-document windows and keyboard-first shortcuts.']
      ]
    },
    icloud: {
      chapter: 7,
      icon: 'file',
      title: ['iCloud 自动同步 + 局域网 Bonjour 点对点加速', 'iCloud auto-sync + LAN Bonjour peer-to-peer transfer'],
      description: ['通过 iCloud 自动同步 PDF 原文、动态网页地址與进度锚点（WebReadingAnchor）、摘录卡片、思维导图、闪卡与讲解文稿；同一局域网下 Mac 与 iPhone / iPad 还可通过 Bonjour (_readlet-sync._tcp) 点对点直连秒传大体积 PDF。', 'Syncs PDFs, live web URLs & anchors, excerpts, mind maps, flashcards, and narration scripts via iCloud—accelerated on local networks by peer-to-peer Bonjour (_readlet-sync._tcp) transfer.'],
      notes: [
        ['跨设备阅读进度冲突自动检测，支持一键跳回另一台设备的最新进度。', 'Detects cross-device progress conflicts and lets you jump to another device’s latest position.'],
        ['合成音频与导出视频仅存本地，不挤占你的 iCloud 存储空间。', 'Synthesized audio clips and exported videos stay local so they never bloat your iCloud storage.']
      ]
    },
    opensource: {
      chapter: 7,
      icon: 'grid',
      title: ['Apple 公证签名 · 源码完全开放', 'Apple Notarized & Open Source'],
      description: ['macOS 安装包均经过 Apple Developer ID 签名、Hardened Runtime 公证（Notarized）与票据订合（Stapled），解压拖入「应用程序」即可直接运行；同时全套 SwiftPM 跨平台源码在 GitHub 开放。', 'Every macOS release is signed with Apple Developer ID, notarized, and stapled. The unified Swift Package codebase for macOS and iOS is open source on GitHub.'],
      notes: [
        ['内置后台更新检查器，发现新版本可一键下载更新。', 'Built-in update checker notifies you when a new notarized release is available.'],
        ['欢迎在 GitHub 查看源码、提交 Issue 或参与贡献。', 'Explore the source, report issues, or contribute on GitHub.']
      ]
    }
  };

  let selectedQuery = 'delivery', selectedSession = 'delivery', selectedContact = 'lin', selectedModel = 'local', responseMode = 'draft', expoIndex = 0;
  let memoryPaused = false, customMemory = '', currentFeature = null, downloadManifest = null, downloadState = 'pending';

  const queryData = {
    delivery: {
      query: ['https://huggingface.co/spaces/huggingface/moe-blogpost#s-1', 'https://huggingface.co/spaces/huggingface/moe-blogpost#s-1'],
      rows: [
        ['WEB', ['可交互网页模式（DocKind.web）· 零体积入库', 'Interactive Web Mode (DocKind.web) · Zero-bloat storage'], ['自动解包 HF Spaces 外壳 · 保留 30+ 处 D3 / iframe 动态图表交互', 'Unwraps HF Spaces shell · Preserves 30+ live D3 / iframe interactive charts'], ['仅在 library.json 保存网址与批注叠加层，不落地整页 HTML 快照或静态 PDF。', 'Saves only the URL and your annotation overlay in library.json—no heavy HTML snapshots.'], '0%–100%'],
        ['CLN', ['默认移除周边非正文（webCleanMode = true）', 'Auto-declutter peripheral chrome (webCleanMode = true)'], ['非破坏性隐藏顶栏、侧边浮动目录与页脚，正文居中自适应 780px', 'Non-destructively hides top navbars, sticky TOCs, and footers while centering the article'], ['可按篇文章在顶栏随时一键关闭净化，还原原始网页完整周边布局。', 'Toggle Clean Mode on or off per article anytime from the reader toolbar.'], ['可按篇开关', 'Per-article']]
      ]
    },
    file: {
      query: ['跨窗口缩放 & Mac / iPad / iPhone 连续进度锚点协同', 'Cross-window resize & Mac / iPad / iPhone anchor sync'],
      rows: [
        ['ANC', ['WebReadingAnchor 语义锚点定位', 'WebReadingAnchor semantic DOM positioning'], ['anchorId (#s-1) + intraOffset (0.38) + scrollFraction (42%)', 'anchorId (#s-1) + intraOffset (0.38) + scrollFraction (42%)'], ['无论从 27 寸 Mac 窄窗切到全屏，还是在 iPhone 上接着读，均精准落回同一自然段。', 'Lands on the exact same paragraph across 27" Mac monitors, iPad Split View, and iPhone.'], '42%'],
        ['VIZ', ['超宽交互图表自适应缩放（fitWideVisualizations）', 'Responsive wide chart scaling (fitWideVisualizations)'], ['自动检测 .viz-box 与内嵌 iframe 原始宽高比，窄屏下等比缩放不裁切', 'Detects .viz-box and iframe aspect ratios, scaling smoothly on narrow screens without clipping'], ['完美兼容页面原生 viz-fit 脚本，滑动流畅无闪烁、无阅读主题色遮挡。', 'Works harmoniously with native page resize scripts for butter-smooth scrolling.'], ['自适应', 'Responsive']]
      ]
    },
    person: {
      query: ['动态网页原位双语对照 + W3C 语义高亮 + AI 语音解读', 'In-place bilingual translation + W3C highlights + AI Narration'],
      rows: [
        ['BI2', ['视口段落自动双语注入（跳过交互图表）', 'Viewport-driven in-place bilingual injection'], ['随滚动自动翻译当前可见段落，不触碰 figure.viz / canvas / svg 内部节点', 'Translates visible paragraphs as you scroll while leaving figure.viz / canvas / svg untouched'], ['支持八色高亮（W3C TextQuoteSelector 锚点）与拖拽框选截取动态图表加入脑图。', 'Supports 8-color W3C TextQuoteSelector highlights and area snapshots straight into your mind map.'], '⌘2'],
        ['NAR', ['按 DOM 章节（h1 / h2 / h3）逐节语音讲解', 'Section-by-section AI voice narration (h1 / h2 / h3)'], ['自动提取章节文本与视口快照生成多模态口语讲稿，边听边自动滚屏高亮', 'Extracts section text and viewport snapshots for multimodal voice narration with auto-scroll'], ['同样支持 AI 助手提问、一键生成脑图与 SM-2 闪卡自测。', 'Full support for AI Copilot Q&A, one-click mind maps, and SM-2 flashcards.'], '⌘⇧L']
      ]
    }
  };

  const sessionData = {
    delivery: {
      question: ['请结合本页 Figure 2 讲解 MoE 专家路由的负载均衡机制。', 'Explain the MoE routing load-balancing mechanism shown in Figure 2 on this page.'],
      heading: ['正在看图逐段讲解 · 第 3 节 Figure 2', 'Narrating with page vision · Section 3, Figure 2'],
      answer: ['“我们先看中间这张交互图：横轴是 Token 批次，纵轴代表 8 个专家网络的负载占比。当你拖动滑块增加辅助损失系数时，可以看到原本挤在 Expert 1 的 Token 被均匀分散到了其他专家……”', '“Look at the interactive chart in the center: the x-axis shows token batches and the y-axis shows load across 8 experts. As you drag the auxiliary loss slider, tokens crowding Expert 1 redistribute evenly…”'],
      action: ['按住麦克风打断追问', 'Simulate mic interruption'],
      result: ['🎙️ 已响应语音打断：“如果彻底去掉辅助损失（Aux Loss = 0）会发生路由坍缩吗？” → AI 已结合第 4 节的无辅助损失路由算法给出解答，并自动恢复原段落继续朗读。', '🎙️ Answered voice interruption: “Does removing Aux Loss cause routing collapse?” → Explained loss-free balancing from Section 4, then resumed narration seamlessly.']
    },
    billing: {
      question: ['帮我总结这篇论文的核心贡献，并标出关键实验所在的页码。', 'Summarize the core contributions of this paper and cite the pages for key experiments.'],
      heading: ['全文结构化导读已生成（含页码锚点）', 'Structured document guide with page citations'],
      answer: ['本文提出因果编码器-解码器（CED）架构 [p.2]，在 552B 总参数下每 Token 仅激活 16B 参数 [p.4]；长上下文推理吞吐量对比见实验部分 [p.7]，消融实验见 [p.11]。', 'Introduces the Causal Encoder-Decoder (CED) architecture [p.2], activating only 16B of 552B parameters per token [p.4]; long-context throughput benchmarks are on [p.7] and ablations on [p.11].'],
      action: ['测试点击 [p.7] 跳回原文', 'Test jumping to [p.7]'],
      result: ['已精准定位并滚动至第 7 页（Figure 4：1M 上下文解码 FLOPs 对比图），原文对应段落已呼吸高亮。', 'Jumped directly to Page 7 (Figure 4: 1M context decode FLOPs comparison) with breathing highlight on the source paragraph.']
    },
    planning: {
      question: ['把这一章整理成层级清晰的思维导图，并挂接原文锚点。', 'Build a hierarchical mind map for this chapter anchored to the source text.'],
      heading: ['AI 文档脑图已生成 · 共 14 个锚定节点', 'AI Mind Map generated · 14 anchored nodes'],
      answer: ['已按「问题背景 → 路由机制 → 专家容量 → 负载均衡实验」建立四级脑图节点。每个节点均绑定原文页码或网页 W3C 文本锚点，双击任意节点即可回跳原文。', 'Organized into a 4-level hierarchy: Motivation → Routing → Capacity Factor → Load Balancing. Every node is bound to its PDF page or W3C web text anchor.'],
      action: ['一键同步生成本章闪卡', 'Generate flashcards from map'],
      result: ['已基于当前章节脑图生成 6 张结构化闪卡（含 2 张概念卡、2 张理解卡、1 张应用卡、1 张数据卡），已同步至 iCloud。', 'Generated 6 structured flashcards (2 Concept, 2 Comprehension, 1 Application, 1 Data) and synced to iCloud.']
    }
  };

  const contactData = {
    lin: [
      ['八色高亮 & 区域框选摘录', '8-Color Highlights & Area Capture'],
      ['PDF 矢量矩形锚点 + 网页 W3C TextQuoteSelector', 'PDF vector rect anchors + Web W3C TextQuoteSelector'],
      ['选中文字一点即生成带译文的摘录卡片；按 ⌘4 拖拽框选即可把复杂公式或动态图表当前状态截为图片卡片，自动挂入脑图。', 'Select text and tap a color dot to create a bilingual excerpt card, or press ⌘4 to drag-capture formulas and live interactive charts straight into your mind map.']
    ],
    alex: [
      ['MarginNote 式大纲与脑图画布', 'MarginNote-style Outline & Mind Map Canvas'],
      ['拖拽整理层级 · Tab / Return 快速建节点 · 跨文档双链', 'Drag to reorganize · Tab / Return shortcuts · Cross-doc links'],
      ['同一笔记本可容纳多篇 PDF 与动态网页，不同文档的卡片可建立双向链接，双击节点瞬间跳回对应文档的原位置。', 'Combine multiple PDFs and live webpages in one notebook, link cards bidirectionally across documents, and double-click any node to jump back to the exact source.']
    ]
  };

  const modelData = {
    local: [
      ['系统离线语音，零配置开箱即讲。', 'Built-in offline system voices. Zero setup required.'],
      ['默认使用 macOS / iOS 系统自带高品质离线语音朗读，无需配置任何 TTS 模型即可免费开讲；主模型支持本地 Ollama 或自定义网关，配置可统一写入 ~/.config/readlet/config.toml。', 'Uses built-in macOS and iOS voices offline by default so narration works immediately with zero TTS setup. Connect local Ollama or any gateway via Settings or ~/.config/readlet/config.toml.'],
      '⌘'
    ],
    api: [
      ['Anthropic / OpenAI 网关 + 9 大远程 TTS 引擎。', 'Anthropic / OpenAI gateways + 9 remote TTS engines.'],
      ['全面兼容 Anthropic Messages、OpenAI Chat Completions 与 Responses 接口；语音合成支持主网关、OpenAI、Gemini、通义千问 Qwen-TTS、Azure、ElevenLabs、MiniMax 与火山引擎豆包。', 'Supports Anthropic Messages, OpenAI Chat Completions, and Responses APIs—paired with OpenAI, Gemini, Qwen-TTS, Azure, ElevenLabs, MiniMax, or Volcengine Doubao TTS.'],
      'API'
    ],
    chatgpt: [
      ['原生登录 ChatGPT Plus / Pro 账号。', 'Native ChatGPT Plus / Pro OAuth sign-in.'],
      ['无需手动申请 API Key，支持直接在应用内通过 OAuth 登录你的 ChatGPT 账号用于双语翻译、AI 语音解读讲稿生成、脑图提炼与 AI 助手问答，凭据安全保存在系统钥匙串。', 'Sign in directly with your ChatGPT account via native OAuth for bilingual translation, narration script generation, mind maps, and Copilot Q&A—stored safely in Keychain.'],
      '✳'
    ]
  };

  function pair(value) { return Array.isArray(value) ? value[language === 'en' ? 1 : 0] : value; }
  function element(tag, text, className) { const node = document.createElement(tag); if (text !== undefined) node.textContent = text; if (className) node.className = className; return node; }

  function renderQuery() {
    const data = queryData[selectedQuery];
    $('#search-query').textContent = pair(data.query);
    $('#search-results').replaceChildren(...data.rows.map((row, index) => {
      const result = element('div', undefined, 'mail-result');
      const copy = element('div');
      copy.append(element('strong', pair(row[1])), element('span', pair(row[2])), element('p', pair(row[3])));
      result.append(element('span', row[0], 'avatar' + (index ? ' pale' : '')), copy, element('time', pair(row[4])));
      return result;
    }));
  }

  function renderSession() {
    const data = sessionData[selectedSession];
    $('#chat-question').textContent = pair(data.question);
    const source = element('button', t('查看原文页码与图表依据', 'Inspect source page & chart evidence'), 'source-reference');
    source.id = 'source-reference';
    source.addEventListener('click', showSource);
    $('#chat-answer').replaceChildren(element('strong', pair(data.heading)), element('p', pair(data.answer)), source);
    $('#chat-run span').textContent = pair(data.action);
    $('#chat-result').hidden = true;
    $('#chat-run').disabled = false;
  }

  function renderContact() {
    const data = contactData[selectedContact];
    const strip = element('div', undefined, 'color-palette-strip');
    ['#ffe35c', '#8cdb78', '#73b8ff', '#ff8c8c', '#c299f7', '#ffab59', '#66d9d9', '#b8b8bd'].forEach(c => {
      const dot = element('i');
      dot.style.background = c;
      strip.append(dot);
    });
    $('#contact-excerpt').replaceChildren(element('strong', pair(data[0])), element('span', pair(data[1])), element('p', pair(data[2])), strip);
    $$('[data-contact]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.contact === selectedContact)));
  }

  function renderModel() {
    const data = modelData[selectedModel];
    $('#model-heading').textContent = pair(data[0]);
    $('#model-description').textContent = pair(data[1]);
    $('.model-path-target').textContent = data[2];
  }

  function renderMemory() {
    const defaultQ = t('DeepSeek-V4.1-Flash 是什么类型的模型？解码阶段每 Token 激活多少参数？', 'What type of model is DeepSeek-V4.1-Flash, and how many parameters are active per token during decoding?');
    const defaultA = t('✓ 答案：多模态 MoE 模型（552B 骨干参数，1M 上下文）；通过因果编码器-解码器（CED），解码阶段每 Token 仅激活 16B 参数。', '✓ Answer: A multimodal MoE model (552B backbone, 1M context); with its Causal Encoder-Decoder (CED), only 16B parameters are active per token.');
    $('#memory-example').textContent = memoryPaused ? defaultA : (customMemory || defaultQ);
    $('#memory-pause').textContent = memoryPaused ? t('翻回问题面', 'Flip to Question') : t('点击翻看答案', 'Flip to Answer');
    $('#memory-pause').setAttribute('aria-pressed', String(memoryPaused));
    $('.memory-sheet').classList.toggle('flipped', memoryPaused);
  }

  function renderResponse() {
    $('#rule-result').classList.remove('tested');
    $('#rule-result').textContent = responseMode === 'draft'
      ? t('当前模式：默认开启非破坏性「移除周边非正文」（webCleanMode = true），隐藏导航、浮动目录与页脚，保留全部 D3 / iframe 交互。点击下方按钮试跑。', 'Current mode: Non-destructive Web Clean Mode (webCleanMode = true) hides navbars, sticky TOCs, and footers while keeping all D3 / iframe charts live. Click below to test.')
      : t('当前模式：按篇关闭净化（还原网页原始周边布局），或对 PDF 执行无损尾部截断与区域框选擦除（随时可一键还原原文件）。点击下方按钮试跑。', 'Current mode: Restore original webpage chrome per article, or apply lossless PDF tail truncation & region erase (with 1-click original restore). Click below to test.');
  }

  function applyLanguage(next) {
    language = next === 'en' ? 'en' : 'zh';
    document.documentElement.lang = language === 'en' ? 'en' : 'zh-Hans';
    pairs.forEach((zh, node) => { node.innerHTML = language === 'en' ? node.dataset.en : zh; });
    $('#language-toggle').textContent = language === 'en' ? '中文' : 'EN';
    $('#language-toggle').setAttribute('aria-label', language === 'en' ? '切换到中文' : 'Switch to English');
    $('#feature-search').placeholder = t('搜索功能：双语、动态网页、语音解读、脑图、闪卡…', 'Search features: bilingual, live web, narration, mind map, flashcards…');
    document.title = t('Readlet — 读懂每一页，留下每一处思考。', 'Readlet — Understand every page. Keep every thought.');
    const description = t(
      'Readlet：macOS 与 iOS / iPadOS 原生 AI 双语深度阅读器。支持保留原排版双语 PDF、动态交互网页 URL 导入与自动净化、MarginNote 式摘录脑图、AI 逐页语音解读与 SM-2 闪卡，iCloud 自动同步。',
      'Readlet: Native AI bilingual deep reader for macOS and iOS/iPadOS. Layout-preserving bilingual PDFs, live interactive webpage import with auto-decluttering, MarginNote-style mind maps, AI voice narration, and SM-2 flashcards.'
    );
    $('meta[name="description"]').content = description;
    $('meta[property="og:description"]').content = description;
    $('meta[property="og:title"]').content = document.title;
    $('#preview-open').setAttribute('aria-label', t('查看 Readlet 原生界面与实机演示', 'View the native Readlet workspace & live demo'));
    renderQuery(); renderSession(); renderContact(); renderModel(); renderMemory(); renderResponse(); renderSearch(); renderExpo(); updateDownload();
    if (currentFeature && $('#feature-dialog').open) populateFeature(features[currentFeature]);
    try { localStorage.setItem('readlet-language', language); } catch (_) { /* Storage is optional. */ }
  }

  let previousFocus = null;
  function openDialog(id) {
    if (!document.querySelector('dialog[open]')) previousFocus = document.activeElement;
    $$('dialog[open]').forEach(dialog => dialog.close());
    const dialog = document.getElementById(id);
    dialog.showModal();
    document.body.classList.add('modal-open');
    if (id === 'search-dialog') $('#feature-search').focus();
  }

  $$('dialog').forEach(dialog => {
    dialog.addEventListener('close', () => {
      if (dialog.id === 'preview-dialog') {
        const v = $('#preview-video');
        if (v && !v.paused) v.pause();
      }
      if (!document.querySelector('dialog[open]')) document.body.classList.remove('modal-open');
    });
    dialog.addEventListener('click', event => {
      const rect = dialog.getBoundingClientRect();
      if (event.target === dialog && (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom)) dialog.close();
    });
  });

  $$('[data-close]').forEach(button => button.addEventListener('click', () => {
    document.getElementById(button.dataset.close).close();
    if (previousFocus?.isConnected) previousFocus.focus({ preventScroll: true });
  }));

  function populateDetail(category, title, description, notes, icon, doc) {
    $('#detail-category').textContent = category;
    $('#detail-title').textContent = title;
    $('#detail-description').textContent = description;
    $('#detail-notes').replaceChildren(...notes.map(note => element('p', note)));
    $('#detail-art use').setAttribute('href', '#i-' + icon);
    $('#detail-doc').href = doc;
  }

  function populateFeature(data) {
    populateDetail(
      pair(chapters[data.chapter][1]),
      pair(data.title),
      pair(data.description),
      data.notes.map(pair),
      data.icon,
      'https://github.com/mapix/readit'
    );
  }

  function showFeature(key) {
    if (!features[key]) return;
    currentFeature = key;
    populateFeature(features[key]);
    openDialog('feature-dialog');
  }

  $$('[data-feature]').forEach(button => button.addEventListener('click', () => showFeature(button.dataset.feature)));

  function showSource() {
    currentFeature = null;
    populateDetail(
      t('原文页码与语义锚点溯源', 'Source Page & Semantic Anchor Citation'),
      t('每一句解答与讲解，都锚定在原文上。', 'Every explanation stays anchored to the source.'),
      t('无论是多模态逐页语音讲解，还是 AI 助手（Copilot）的回答，Readlet 都会将结论与 PDF 原文页码 [p.X] 或动态网页的 DOM 章节锚点关联起来，点击即可回跳核对。', 'Whether in multimodal voice narration or AI Copilot answers, Readlet links every conclusion to its exact PDF page [p.X] or live web DOM section anchor for instant verification.'),
      [
        t('PDF 模式：自动定位至目标页并高亮对应矢量段落矩形。', 'PDF mode: Jumps to the target page and highlights the exact vector paragraph rectangle.'),
        t('动态网页模式：通过 WebReadingAnchor 与 W3C TextQuoteSelector 滚动至对应章节与句子。', 'Live Web mode: Scrolls to the exact section and sentence via WebReadingAnchor and W3C TextQuoteSelector.')
      ],
      'file',
      'https://github.com/mapix/readit'
    );
    openDialog('feature-dialog');
  }

  function renderSearch() {
    const query = $('#feature-search').value.trim().toLowerCase();
    const matches = Object.entries(features).filter(([, data]) => [...data.title, ...data.description, ...chapters[data.chapter][1]].join(' ').toLowerCase().includes(query));
    $('#search-empty').hidden = !!matches.length;
    $('#feature-search-results').replaceChildren(...matches.map(([key, data]) => {
      const button = element('button', undefined, 'search-result');
      const copy = element('span');
      copy.append(element('strong', pair(data.title)), element('small', pair(chapters[data.chapter][1])));
      const icon = element('span', '+');
      button.append(copy, icon);
      button.addEventListener('click', () => showFeature(key));
      return button;
    }));
  }

  $('#feature-search').addEventListener('input', renderSearch);
  $('#search-open').addEventListener('click', () => { renderSearch(); openDialog('search-dialog'); });
  $('#menu-toggle').addEventListener('click', () => {
    const open = $('#chapter-menu').hidden;
    $('#chapter-menu').hidden = !open;
    $('#menu-toggle').setAttribute('aria-expanded', String(open));
  });
  $('#chapter-menu').addEventListener('click', event => {
    if (event.target.closest('a')) {
      $('#chapter-menu').hidden = true;
      $('#menu-toggle').setAttribute('aria-expanded', 'false');
    }
  });
  document.addEventListener('click', event => {
    if (!event.target.closest('#chapter-menu,#menu-toggle')) {
      $('#chapter-menu').hidden = true;
      $('#menu-toggle').setAttribute('aria-expanded', 'false');
    }
  });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape') {
      $('#chapter-menu').hidden = true;
      $('#menu-toggle').setAttribute('aria-expanded', 'false');
    }
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
      event.preventDefault();
      renderSearch();
      openDialog('search-dialog');
    }
    if (event.key === '/' && !event.metaKey && !event.ctrlKey && !event.target.closest('input,textarea,dialog')) {
      event.preventDefault();
      renderSearch();
      openDialog('search-dialog');
    }
  });

  function bindTabs(attribute, callback, panelId) {
    const buttons = $$('[' + attribute + ']');
    function select(button, focus = false) {
      buttons.forEach(item => {
        const active = item === button;
        item.setAttribute('aria-selected', String(active));
        item.tabIndex = active ? 0 : -1;
      });
      document.getElementById(panelId).setAttribute('aria-labelledby', button.id);
      callback(button);
      if (focus) button.focus({ preventScroll: true });
    }
    buttons.forEach((button, index) => {
      button.tabIndex = index ? -1 : 0;
      button.addEventListener('click', () => select(button));
      button.addEventListener('keydown', event => {
        let next;
        if (['ArrowRight', 'ArrowDown'].includes(event.key)) next = (index + 1) % buttons.length;
        if (['ArrowLeft', 'ArrowUp'].includes(event.key)) next = (index - 1 + buttons.length) % buttons.length;
        if (event.key === 'Home') next = 0;
        if (event.key === 'End') next = buttons.length - 1;
        if (next !== undefined) { event.preventDefault(); select(buttons[next], true); }
      });
    });
  }

  bindTabs('data-query', button => { selectedQuery = button.dataset.query; renderQuery(); }, 'search-results');
  bindTabs('data-session', button => { selectedSession = button.dataset.session; renderSession(); }, 'chat-panel');
  bindTabs('data-model', button => { selectedModel = button.dataset.model; renderModel(); }, 'model-panel');

  $$('[data-contact]').forEach(button => button.addEventListener('click', () => {
    selectedContact = button.dataset.contact;
    renderContact();
  }));

  $$('[data-file]').forEach(button => button.addEventListener('click', () => {
    const files = {
      brief: [
        ['保留原排版双语 PDF（DocKind.pdf）', 'Layout-preserving Bilingual PDF (DocKind.pdf)'],
        ['基于原 PDF 矢量字形流重排，公式、图表、分栏与字号原汁原味保留，同时支持 EPUB / Markdown / TXT 自动排版转入。', 'Reconstructed from original PDF vector glyph streams so formulas, figures, and columns stay intact—also supports importing EPUB, Markdown, and TXT.']
      ],
      budget: [
        ['动态交互网页（DocKind.web）', 'Live Interactive Webpage (DocKind.web)'],
        ['仅保存网址与你的批注、脑图、朗读、闪卡与阅读进度锚点（WebReadingAnchor），保留 D3 / Canvas / iframe 实时交互并默认净化周边非正文。', 'Stores only the URL and your personal overlays while keeping D3 / Canvas / iframe charts interactive and peripheral clutter hidden by default.']
      ],
      design: [
        ['无损 PDF 截断、擦除与多端同步', 'Lossless PDF Truncation, Erase & Cloud Sync'],
        ['一键截断网页转 PDF 尾部的评论区或框选擦除杂讯，随时可一键还原原始文件；所有进度与笔记通过 iCloud 及局域网 Bonjour 自动同步。', 'Truncate trailing clutter or drag-erase regions with one-click lossless restore; syncs automatically across Mac, iPhone, and iPad via iCloud and LAN Bonjour.']
      ]
    };
    const data = files[button.dataset.file];
    currentFeature = null;
    populateDetail(t('文档形态与能力细节', 'Document Modality & Capabilities'), pair(data[0]), pair(data[1]), [t('所有個人批注、脑图与进度均保存在本机与私有 iCloud 容器中。', 'All personal annotations, mind maps, and reading progress stay on your device and private iCloud container.')], 'file', 'https://github.com/mapix/readit');
    openDialog('feature-dialog');
  }));

  $('#chat-run').addEventListener('click', () => {
    $('#chat-result').textContent = pair(sessionData[selectedSession].result);
    $('#chat-result').hidden = false;
  });

  $$('[data-response]').forEach(button => button.addEventListener('click', () => {
    responseMode = button.dataset.response;
    $$('[data-response]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
    renderResponse();
  }));

  $('#rule-run').addEventListener('click', () => {
    $('#rule-result').classList.add('tested');
    $('#rule-result').textContent = responseMode === 'draft'
      ? t('✓ 净化试跑完成：已非破坏性隐藏顶栏导航、固定侧边目录（.table-of-contents）与底部推荐，正文居中为 780px，30+ 个交互式 iframe 图表全部保持可拖拽、可缩放，进度锚点已锁定在 #s-1 (42%)。', '✓ Declutter test complete: Top nav, sticky .table-of-contents, and footer hidden non-destructively; article centered at 780px while all 30+ interactive iframe charts remain live and anchor #s-1 (42%) stays locked.')
      : t('✓ 编辑与还原试跑完成：网页可按篇一键切回原始完整布局；PDF 截断/框选擦除已生成轻量编辑层，点击「恢复原 PDF」即可 100% 无损还原。', '✓ Edit & restore test complete: Webpage toggled back to full original layout per article; PDF truncation/erase applied non-destructively with instant 1-click original restore.');
  });

  $('#memory-pause').addEventListener('click', event => {
    event.stopPropagation();
    memoryPaused = !memoryPaused;
    renderMemory();
    $('#memory-status').textContent = memoryPaused ? t('已翻转至闪卡答案面', 'Flipped to flashcard answer') : t('已翻转至闪卡问题面', 'Flipped to flashcard question');
  });
  $('.memory-sheet').addEventListener('click', event => {
    if (event.target.closest('button')) return;
    memoryPaused = !memoryPaused;
    renderMemory();
  });
  $('#memory-edit').addEventListener('click', event => {
    event.stopPropagation();
    $('#memory-input').value = customMemory || t('DeepSeek-V4.1-Flash 是什么类型的模型？解码阶段每 Token 激活多少参数？', 'What type of model is DeepSeek-V4.1-Flash, and how many parameters are active per token during decoding?');
    openDialog('memory-dialog');
  });
  $('#memory-form').addEventListener('submit', event => {
    event.preventDefault();
    const value = $('#memory-input').value.trim();
    if (!value) return;
    customMemory = value;
    memoryPaused = false;
    renderMemory();
    $('#memory-dialog').close();
    $('#memory-edit').focus({ preventScroll: true });
  });

  $('#language-toggle').addEventListener('click', () => applyLanguage(language === 'zh' ? 'en' : 'zh'));
  $('#preview-open').addEventListener('click', () => openDialog('preview-dialog'));
  $$('[data-open-preview]').forEach(btn => btn.addEventListener('click', () => openDialog('preview-dialog')));

  function renderExpo() {
    const data = chapters[expoIndex];
    $('#expo-number').textContent = String(expoIndex + 1).padStart(2, '0') + ' / 08';
    $('#expo-title').textContent = pair(data[1]);
    $('#expo-description').textContent = pair(data[2]);
    $('#expo-icon use').setAttribute('href', '#i-' + data[3]);
    $('#expo-dots').replaceChildren(...chapters.map((chapter, index) => {
      const button = element('button');
      button.setAttribute('aria-label', pair(chapter[1]));
      button.setAttribute('aria-pressed', String(index === expoIndex));
      button.addEventListener('click', () => {
        expoIndex = index;
        renderExpo();
        $('#expo-dots').children[index].focus();
      });
      return button;
    }));
  }

  function moveExpo(delta) {
    const focusDots = $('#expo-dots').contains(document.activeElement);
    expoIndex = (expoIndex + delta + chapters.length) % chapters.length;
    renderExpo();
    if (focusDots) $('#expo-dots').children[expoIndex].focus();
  }

  $('#expo-open').addEventListener('click', () => { renderExpo(); openDialog('expo-dialog'); });
  $('#expo-prev').addEventListener('click', () => moveExpo(-1));
  $('#expo-next').addEventListener('click', () => moveExpo(1));
  $('#expo-dialog').addEventListener('keydown', event => {
    if (event.key === 'ArrowRight') { event.preventDefault(); moveExpo(1); }
    if (event.key === 'ArrowLeft') { event.preventDefault(); moveExpo(-1); }
  });
  $('#expo-detail').addEventListener('click', () => {
    $('#expo-dialog').close();
    const target = document.getElementById(chapters[expoIndex][0]);
    target.scrollIntoView();
    target.querySelector('h2').tabIndex = -1;
    target.querySelector('h2').focus({ preventScroll: true });
  });

  function updateDownload() {
    const ver = downloadManifest?.version || '1.0.0';
    const size = downloadManifest?.size || '7.2 MB';
    const file = downloadManifest?.file || 'Readlet-1.0.0.zip';
    const iosFile = downloadManifest?.ios_file || 'Readlet-1.0.0-iOS.ipa';
    const sha = typeof downloadManifest?.sha256 === 'string' && /^[a-f\d]{64}$/i.test(downloadManifest.sha256) ? downloadManifest.sha256 : '';
    const qs = sha ? ('?v=' + sha.slice(0, 12)) : '';
    const macUrl = '/download/' + file + qs;
    const iosUrl = '/download/' + iosFile + qs;

    const macBtn = $('#download-action');
    if (macBtn) {
      macBtn.href = macUrl;
      macBtn.removeAttribute('aria-busy');
    }
    const iosBtn = $('#download-ios-action');
    if (iosBtn) {
      iosBtn.href = iosUrl;
    }
    $$('[data-dl]').forEach(a => { a.href = macUrl; });
    $$('[data-dl-ios]').forEach(a => { a.href = iosUrl; });

    $('#download-retry').hidden = downloadState !== 'unavailable';
    $('#download-status').textContent = downloadState === 'ready'
      ? t('✓ Apple Developer ID 签名与公证（Notarized & Stapled）已校验通过，解压拖入「应用程序」即可运行。', '✓ Signed with Apple Developer ID, Notarized & Stapled — unzip, drag to Applications, and open.')
      : downloadState === 'unavailable'
        ? t('已使用默认公开版本链接（v1.0.0）。你也可以前往 GitHub Releases 查看。', 'Using default release links (v1.0.0). You can also check GitHub Releases.')
        : t('正在读取公开版本校验信息…', 'Loading release verification metadata…');

    $('#download-meta').textContent = `v${ver} / ${size} / macOS 14+ (Apple Silicon & Intel) · iOS & iPadOS 17+`;
    $('#checksum').hidden = !sha;
    $('#checksum-value').textContent = sha ? 'SHA-256 (macOS Notarized ZIP): ' + sha : '';
  }

  async function readDownloadManifest() {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 5000);
    downloadState = 'pending';
    $('#download-retry').disabled = true;
    updateDownload();
    try {
      const response = await fetch('/download/latest.json', { cache: 'no-store', credentials: 'omit', signal: controller.signal });
      if (!response.ok) throw new Error('Unavailable');
      const manifest = await response.json();
      if (!manifest || !manifest.file) throw new Error('Invalid');
      downloadManifest = manifest;
      downloadState = 'ready';
    } catch (_) {
      downloadState = 'unavailable';
    } finally {
      clearTimeout(timer);
      $('#download-retry').disabled = false;
      updateDownload();
    }
  }

  $('#download-retry').addEventListener('click', readDownloadManifest);

  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const canvas = $('#constellation'), ctx = canvas.getContext('2d'), universe = $('#universe');
  let width = 0, height = 0, canvasColors = {}, pointer = { x: .5, y: .5 }, scenePointer = { x: .5, y: .5 }, canvasVisible = false, frameId = 0;
  const stars = Array.from({ length: 66 }, (_, index) => ({ x: ((index * 73 + 31) % 997) / 997, y: ((index * 139 + 83) % 991) / 991, size: index % 7 === 0 ? 2 : 1, phase: index * .7 }));

  function readCanvasColors() {
    const style = getComputedStyle(document.documentElement);
    canvasColors = {
      line: style.getPropertyValue('--color-soft').trim(),
      point: style.getPropertyValue('--color-fg').trim(),
      highlight: style.getPropertyValue('--color-highlight').trim()
    };
  }

  function resizeCanvas() {
    const bounds = universe.getBoundingClientRect();
    width = bounds.width;
    height = bounds.height;
    const dpr = Math.min(devicePixelRatio || 1, 2);
    canvas.width = Math.round(width * dpr);
    canvas.height = Math.round(height * dpr);
    ctx?.setTransform(dpr, 0, 0, dpr, 0, 0);
    drawCanvas(performance.now());
  }

  function drawCanvas(time) {
    if (!ctx || !width || !height) return;
    ctx.clearRect(0, 0, width, height);
    scenePointer.x += (pointer.x - scenePointer.x) * .09;
    scenePointer.y += (pointer.y - scenePointer.y) * .09;
    const shiftX = reducedMotion.matches ? 0 : (scenePointer.x - .5) * 40;
    const shiftY = reducedMotion.matches ? 0 : (scenePointer.y - .5) * 40;
    const center = { x: width * .43 + shiftX, y: height * .35 + shiftY };
    const nodes = [
      { x: .17, y: .23 }, { x: .8, y: .19 }, { x: .82, y: .43 }, { x: .55, y: .74 },
      { x: .2, y: .5 }, { x: .92, y: .75 }, { x: .72, y: .06 }, { x: .08, y: .68 }
    ];
    ctx.strokeStyle = canvasColors.line;
    ctx.lineWidth = .7;
    ctx.globalAlpha = .27;
    nodes.forEach((point, index) => {
      const x = point.x * width, y = point.y * height;
      ctx.beginPath(); ctx.moveTo(center.x, center.y); ctx.lineTo(x, y); ctx.stroke();
      ctx.beginPath(); ctx.arc(x, y, index < 5 ? 4 : 2, 0, Math.PI * 2); ctx.stroke();
    });
    ctx.beginPath(); ctx.ellipse(center.x, center.y, width * .27, height * .21, -.4, 0, Math.PI * 2); ctx.stroke();
    ctx.beginPath(); ctx.ellipse(center.x, center.y, width * .18, height * .31, .5, 0, Math.PI * 2); ctx.stroke();
    ctx.fillStyle = canvasColors.point;
    stars.forEach(star => {
      ctx.globalAlpha = reducedMotion.matches ? .3 : .12 + (.5 + .5 * Math.sin(time * .0005 + star.phase)) * .3;
      ctx.fillRect(star.x * width + shiftX * .5, star.y * height + shiftY * .5, star.size, star.size);
    });
    if (!reducedMotion.matches) {
      ctx.fillStyle = canvasColors.highlight;
      ctx.globalAlpha = .8;
      nodes.slice(0, 5).forEach((point, index) => {
        const progress = (time * .00007 + index * .2) % 1;
        const x = center.x + (point.x * width - center.x) * progress;
        const y = center.y + (point.y * height - center.y) * progress;
        ctx.beginPath(); ctx.arc(x, y, 1.5, 0, Math.PI * 2); ctx.fill();
      });
    }
    ctx.globalAlpha = 1;
  }

  function animate(time) {
    drawCanvas(time);
    frameId = canvasVisible && !reducedMotion.matches && !document.hidden ? requestAnimationFrame(animate) : 0;
  }

  function startCanvas() {
    if (canvasVisible && !reducedMotion.matches && !document.hidden && !frameId) frameId = requestAnimationFrame(animate);
    else drawCanvas(performance.now());
  }

  if (ctx) {
    readCanvasColors();
    new ResizeObserver(resizeCanvas).observe(universe);
    new IntersectionObserver(entries => {
      canvasVisible = entries[0].isIntersecting;
      if (!canvasVisible && frameId) { cancelAnimationFrame(frameId); frameId = 0; }
      else startCanvas();
    }, { threshold: 0 }).observe(universe);
    universe.addEventListener('pointermove', event => {
      const rect = universe.getBoundingClientRect();
      pointer = { x: (event.clientX - rect.left) / rect.width, y: (event.clientY - rect.top) / rect.height };
    }, { passive: true });
    universe.addEventListener('pointerleave', () => { pointer = { x: .5, y: .5 }; });
    reducedMotion.addEventListener('change', () => {
      if (frameId) { cancelAnimationFrame(frameId); frameId = 0; }
      startCanvas();
    });
  }

  document.addEventListener('visibilitychange', () => {
    if (document.hidden && frameId) { cancelAnimationFrame(frameId); frameId = 0; }
    else startCanvas();
  });

  function applyTheme(theme) {
    document.documentElement.dataset.theme = ['blue', 'pink', 'orange'].includes(theme) ? theme : 'blue';
    $$('[data-theme-choice]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.themeChoice === theme)));
    if (ctx) { readCanvasColors(); drawCanvas(performance.now()); }
    try { localStorage.setItem('readlet-theme', theme); } catch (_) { /* Storage is optional. */ }
  }

  $$('[data-theme-choice]').forEach(button => button.addEventListener('click', () => applyTheme(button.dataset.themeChoice)));

  const headingObserver = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        entry.target.classList.add('is-visible');
        entry.target.classList.remove('is-waiting');
        headingObserver.unobserve(entry.target);
      }
    });
  }, { threshold: .2 });

  $$('.chapter-heading').forEach(heading => {
    if (!reducedMotion.matches) heading.classList.add('is-waiting');
    headingObserver.observe(heading);
  });

  let scrollScheduled = false;
  function updateReading() {
    scrollScheduled = false;
    let active = 'bilingual';
    const line = innerHeight * .4;
    $$('.chapter').forEach(chapter => {
      if (chapter.getBoundingClientRect().top <= line) active = chapter.id;
    });
    const stage = scrollY < $('.hero').offsetHeight * .75 ? 'hero' : active;
    if (document.documentElement.dataset.stage !== stage) {
      document.documentElement.dataset.stage = stage;
      if (ctx) { readCanvasColors(); drawCanvas(performance.now()); }
    }
    $$('[data-chapter]').forEach(link => {
      if (link.dataset.chapter === active) link.setAttribute('aria-current', 'location');
      else link.removeAttribute('aria-current');
    });
    const max = document.documentElement.scrollHeight - innerHeight;
    $('#reading-progress').style.transform = 'scaleX(' + Math.max(0, Math.min(1, scrollY / Math.max(1, max))) + ')';
  }

  addEventListener('scroll', () => {
    if (!scrollScheduled) {
      scrollScheduled = true;
      requestAnimationFrame(updateReading);
    }
  }, { passive: true });

  let preferredLanguage = 'zh', preferredTheme = 'blue';
  try {
    preferredLanguage = new URLSearchParams(location.search).get('lang') || localStorage.getItem('readlet-language') || localStorage.getItem('readit-lang') || 'zh';
    preferredTheme = localStorage.getItem('readlet-theme') || 'blue';
  } catch (_) { /* Keep defaults. */ }
  applyLanguage(preferredLanguage);
  applyTheme(preferredTheme);
  updateReading();
  readDownloadManifest();
})();
