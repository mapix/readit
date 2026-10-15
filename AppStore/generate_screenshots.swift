#!/usr/bin/env swift
import AppKit
import CoreGraphics

let W = 2880
let H = 1800

struct LocaleCopy {
    let code: String
    let slides: [(badge: String, title: String, subtitle: String)]
}

let copies: [LocaleCopy] = [
    LocaleCopy(code: "en-US", slides: [
        ("BILINGUAL & MIND MAP", "Understand Every Page, Keep Every Thought", "Layout-preserving bilingual PDFs paired with MarginNote-style excerpts & mind maps."),
        ("LAYOUT PRESERVED", "Under Every Paragraph, Its Translation", "Vector-sharp formulas, figures, fonts, and two-column layouts stay completely intact."),
        ("AI VOICE NARRATION", "AI Walks You Through Every Page Out Loud", "5 narration styles, figure explanations, voice Q&A interruptions, and desktop mini-player."),
        ("AI STUDY COMPANION", "Ask Anything, Auto-Map & Quiz Yourself", "Clickable page references, one-click AI mind maps, flashcards, and clean web article import.")
    ]),
    LocaleCopy(code: "zh-Hans", slides: [
        ("双语精读 · 摘录脑图", "读懂每一页，留下每一处思考", "保留原排版的双语 PDF 对照，配合 MarginNote 式八色摘录、卡片批注与知识脑图。"),
        ("原样矢量排版", "每段原文下面，就是它的译文", "公式、图表、字体、双栏排版原封不动；自动跳过公式与参考文献，翻页预译不抖动。"),
        ("AI 逐页语音解读", "不只是翻译，AI 会一页一页讲给你听", "五种讲解风格、看图讲表、按住麦克风随时插话提问，还可收起为桌面悬浮小组件。"),
        ("AI 助手 · 脑图 · 闪卡", "随时提问跳回原文，一键成图与自测", "带页码锚点的 AI 问答、全文自动生成结构化脑图、学习闪卡与网页文章一键转纯净 PDF。")
    ]),
    LocaleCopy(code: "ja", slides: [
        ("対訳リーディング · マインドマップ", "すべてのページを理解し、思考を残す", "元のレイアウトを保つ対訳 PDF と、MarginNote スタイルの抜粋・マインドマップ。"),
        ("レイアウトそのまま", "各段落のすぐ下に、その訳文を表示", "ベクター品質の数式・図表・フォント・2段組を維持。数式や参考文献は自動でスキップ。"),
        ("AI ページごとの音声解説", "翻訳だけでなく、AI が声でわかりやすく解説", "5つの解説スタイル、図表の説明、マイク長押しで割り込み質問、デスクトップミニプレーヤー。"),
        ("AI アシスタント · 単語帳", "ページ番号付き回答、自動マップ＆理解度チェック", "クリックで原文へ飛べる AI 回答、全文マインドマップ自動生成、フラッシュカード、Web 記事取り込み。")
    ])
]

func loadCGImage(_ path: String) -> CGImage? {
    guard let img = NSImage(contentsOfFile: path) else { return nil }
    var rect = NSRect(origin: .zero, size: img.size)
    return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

func makeContext() -> CGContext {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    return CGContext(
        data: nil,
        width: W,
        height: H,
        bitsPerComponent: 8,
        bytesPerRow: W * 4,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
}

func drawBackground(_ ctx: CGContext) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let colors = [
        CGColor(srgbRed: 0.996, green: 0.968, blue: 0.945, alpha: 1.0),
        CGColor(srgbRed: 0.976, green: 0.976, blue: 0.968, alpha: 1.0)
    ] as CFArray
    let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
    
    // Subtle warm radial glow near top
    let glowColors = [
        CGColor(srgbRed: 0.92, green: 0.38, blue: 0.14, alpha: 0.08),
        CGColor(srgbRed: 0.92, green: 0.38, blue: 0.14, alpha: 0.0)
    ] as CFArray
    let glow = CGGradient(colorsSpace: cs, colors: glowColors, locations: [0.0, 1.0])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: Double(W)/2.0, y: Double(H)*0.82), startRadius: 10, endCenter: CGPoint(x: Double(W)/2.0, y: Double(H)*0.82), endRadius: 900, options: [])
}

func drawHeader(in ctx: CGContext, badge: String, title: String, subtitle: String, icon: CGImage?) {
    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    
    // Draw badge pill with icon
    let badgeFont = NSFont.systemFont(ofSize: 24, weight: .bold)
    let badgeAttrs: [NSAttributedString.Key: Any] = [
        .font: badgeFont,
        .foregroundColor: NSColor(srgbRed: 0.886, green: 0.337, blue: 0.122, alpha: 1.0),
        .kern: 1.8
    ]
    let badgeStr = NSAttributedString(string: badge, attributes: badgeAttrs)
    let badgeSize = badgeStr.size()
    let pillW = badgeSize.width + (icon != nil ? 86 : 48)
    let pillH: CGFloat = 52
    let pillX = (CGFloat(W) - pillW) / 2.0
    let pillY = CGFloat(H) - 120
    
    let pillPath = NSBezierPath(roundedRect: NSRect(x: pillX, y: pillY, width: pillW, height: pillH), xRadius: 26, yRadius: 26)
    NSColor.white.setFill()
    pillPath.fill()
    NSColor(srgbRed: 0.886, green: 0.337, blue: 0.122, alpha: 0.25).setStroke()
    pillPath.lineWidth = 2
    pillPath.stroke()
    
    if let ic = icon {
        ctx.saveGState()
        let icRect = CGRect(x: pillX + 16, y: pillY + 8, width: 36, height: 36)
        let clipPath = CGPath(roundedRect: icRect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(clipPath)
        ctx.clip()
        ctx.draw(ic, in: icRect)
        ctx.restoreGState()
        badgeStr.draw(at: NSPoint(x: pillX + 60, y: pillY + (pillH - badgeSize.height) / 2.0 - 1))
    } else {
        badgeStr.draw(at: NSPoint(x: pillX + 24, y: pillY + (pillH - badgeSize.height) / 2.0 - 1))
    }
    
    // Title
    let titleFont = NSFont.systemFont(ofSize: 64, weight: .heavy)
    let pStyle = NSMutableParagraphStyle()
    pStyle.alignment = .center
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: titleFont,
        .foregroundColor: NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1.0),
        .paragraphStyle: pStyle
    ]
    let titleStr = NSAttributedString(string: title, attributes: titleAttrs)
    let titleSize = titleStr.size()
    titleStr.draw(in: NSRect(x: 100, y: CGFloat(H) - 218, width: CGFloat(W) - 200, height: titleSize.height + 10))
    
    // Subtitle
    let subFont = NSFont.systemFont(ofSize: 32, weight: .regular)
    let subAttrs: [NSAttributedString.Key: Any] = [
        .font: subFont,
        .foregroundColor: NSColor(srgbRed: 0.33, green: 0.34, blue: 0.37, alpha: 1.0),
        .paragraphStyle: pStyle
    ]
    let subStr = NSAttributedString(string: subtitle, attributes: subAttrs)
    let subSize = subStr.size()
    subStr.draw(in: NSRect(x: 140, y: CGFloat(H) - 280, width: CGFloat(W) - 280, height: subSize.height + 10))
    
    NSGraphicsContext.restoreGraphicsState()
}

func drawCardImage(_ ctx: CGContext, image: CGImage, rect: CGRect, radius: CGFloat = 24, shadowBlur: CGFloat = 50) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: shadowBlur, color: CGColor(srgbRed: 0.05, green: 0.08, blue: 0.18, alpha: 0.22))
    let bgPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(bgPath)
    ctx.fillPath()
    ctx.restoreGState()
    
    ctx.saveGState()
    let clipPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(clipPath)
    ctx.clip()
    
    // Aspect-fill or fit nicely
    let imgW = CGFloat(image.width)
    let imgH = CGFloat(image.height)
    let scale = max(rect.width / imgW, rect.height / imgH)
    let drawW = imgW * scale
    let drawH = imgH * scale
    let drawX = rect.minX + (rect.width - drawW) / 2.0
    let drawY = rect.minY + (rect.height - drawH) // align top
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
    ctx.restoreGState()
    
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.08))
    ctx.setLineWidth(2)
    ctx.addPath(clipPath)
    ctx.strokePath()
    ctx.restoreGState()
}

func savePNG(_ ctx: CGContext, to path: String) {
    guard let cgImg = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: cgImg)
    rep.size = NSSize(width: W, height: H)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try! data.write(to: URL(fileURLWithPath: path))
}

let icon = loadCGImage("AppStore/AppIcon-1024.png")
let shotSplit = loadCGImage("landing/assets/shot-split.jpg")!
let shotBilingual = loadCGImage("landing/assets/shot-bilingual.jpg")!
let shotNarrate = loadCGImage("landing/assets/shot-narrate.jpg")!
let uiWidget = loadCGImage("landing/assets/ui-widget.jpg")!
let uiCopilot = loadCGImage("landing/assets/ui-copilot.jpg")!
let uiMindmap = loadCGImage("landing/assets/ui-mindmap.jpg")!

let fm = FileManager.default

for loc in copies {
    let outDir = "AppStore/screenshots/\(loc.code)"
    try! fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    
    // Slide 1: Split view
    do {
        let ctx = makeContext()
        drawBackground(ctx)
        drawHeader(in: ctx, badge: loc.slides[0].badge, title: loc.slides[0].title, subtitle: loc.slides[0].subtitle, icon: icon)
        let cardH: CGFloat = 1360
        let cardW: CGFloat = cardH * (1800.0 / 1234.0) // ~1983.8
        let rect = CGRect(x: (CGFloat(W) - cardW) / 2.0, y: 76, width: cardW, height: cardH)
        drawCardImage(ctx, image: shotSplit, rect: rect, radius: 26)
        savePNG(ctx, to: "\(outDir)/01-bilingual-split.png")
    }
    
    // Slide 2: Bilingual layout
    do {
        let ctx = makeContext()
        drawBackground(ctx)
        drawHeader(in: ctx, badge: loc.slides[1].badge, title: loc.slides[1].title, subtitle: loc.slides[1].subtitle, icon: icon)
        let cardH: CGFloat = 1360
        let cardW: CGFloat = cardH * (1800.0 / 1234.0)
        let rect = CGRect(x: (CGFloat(W) - cardW) / 2.0, y: 76, width: cardW, height: cardH)
        drawCardImage(ctx, image: shotBilingual, rect: rect, radius: 26)
        savePNG(ctx, to: "\(outDir)/02-bilingual-layout.png")
    }
    
    // Slide 3: AI Narration + Mini Widget overlay
    do {
        let ctx = makeContext()
        drawBackground(ctx)
        drawHeader(in: ctx, badge: loc.slides[2].badge, title: loc.slides[2].title, subtitle: loc.slides[2].subtitle, icon: icon)
        let mainH: CGFloat = 1320
        let mainW: CGFloat = mainH * (1800.0 / 1234.0) // ~1925
        let mainRect = CGRect(x: 180, y: 90, width: mainW, height: mainH)
        drawCardImage(ctx, image: shotNarrate, rect: mainRect, radius: 26)
        
        let widH: CGFloat = 820
        let widW: CGFloat = widH * (1423.0 / 1800.0) // ~648
        let widRect = CGRect(x: CGFloat(W) - widW - 190, y: 150, width: widW, height: widH)
        drawCardImage(ctx, image: uiWidget, rect: widRect, radius: 32, shadowBlur: 65)
        savePNG(ctx, to: "\(outDir)/03-ai-narration.png")
    }
    
    // Slide 4: AI Assistant + MindMap showcase
    do {
        let ctx = makeContext()
        drawBackground(ctx)
        drawHeader(in: ctx, badge: loc.slides[3].badge, title: loc.slides[3].title, subtitle: loc.slides[3].subtitle, icon: icon)
        
        let mapW: CGFloat = 1620
        let mapH: CGFloat = mapW * (994.0 / 1400.0) // ~1150
        let mapRect = CGRect(x: 200, y: 170, width: mapW, height: mapH)
        drawCardImage(ctx, image: uiMindmap, rect: mapRect, radius: 26)
        
        let copH: CGFloat = 1340
        let copW: CGFloat = copH * (674.0 / 1800.0) // ~501.7 -> make slightly wider fit
        let copRect = CGRect(x: CGFloat(W) - copW - 240, y: 80, width: copW, height: copH)
        drawCardImage(ctx, image: uiCopilot, rect: copRect, radius: 26, shadowBlur: 60)
        savePNG(ctx, to: "\(outDir)/04-ai-copilot-mindmap.png")
    }
}
print("Generated all 12 screenshots (2880x1800 RGB PNG).")
