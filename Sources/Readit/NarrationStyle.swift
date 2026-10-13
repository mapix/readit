import Foundation

/// How AI Narration talks: a built-in style plus an optional extra prompt from Settings / config.toml
/// (`[narration] style = "…"`, `extra_prompt = "…"`).
///
/// Scripts and audio are cached per style: the default style with no extra prompt keeps the original
/// cache names (`p12.json`), every other combination gets its own suffix, so switching back and forth
/// reuses what was already generated.
enum NarrationStyle: String, CaseIterable, Identifiable {
    case podcast, storyteller, deep, popular, brief
    var id: String { rawValue }

    /// Chinese source label (localized with L())
    var title: String {
        switch self {
        case .podcast: return "默认 · 播客讲解"
        case .storyteller: return "评书"
        case .deep: return "技术深度"
        case .popular: return "科普"
        case .brief: return "精简速览"
        }
    }
    /// compact label for the player
    var shortTitle: String {
        switch self {
        case .podcast: return "播客"
        case .storyteller: return "评书"
        case .deep: return "深度"
        case .popular: return "科普"
        case .brief: return "速览"
        }
    }
    var subtitle: String {
        switch self {
        case .podcast: return "像朋友聊天一样把每页讲明白"
        case .storyteller: return "说书人口吻，有悬念有节奏"
        case .deep: return "面向工程师，讲机制、取舍和细节"
        case .popular: return "面向大众，多用类比、少用术语"
        case .brief: return "每页只讲最关键的一两点"
        }
    }

    init?(configName s: String) {
        switch s.lowercased() {
        case "podcast", "default", "默认": self = .podcast
        case "storyteller", "pingshu", "评书": self = .storyteller
        case "deep", "technical", "技术深度": self = .deep
        case "popular", "popsci", "科普": self = .popular
        case "brief", "concise", "精简速览": self = .brief
        default: return nil
        }
    }

    /// persona + style rules (the JSON / focus format is shared and appended by `systemPrompt`)
    func persona(title t: String, lang: String) -> String {
        switch self {
        case .podcast:
            return """
            你是一位擅长把学术论文讲给普通人听的讲解员，正在以播客口吻逐页讲解《\(t)》。用\(lang)口语讲解。
            要求：
            - 不要逐句翻译，而是用人能轻松听懂的方式解释本页在讲什么、为什么重要；术语第一次出现时用一句话解释。
            - 页面上的图表、表格、公式要专门讲：它展示了什么、怎么看、得出什么结论。
            - 分成 3–7 段，每段 2–4 句话（适合朗读，避免括号、符号、长串数字和网址；公式用口语表达）。
            - 自然衔接上一页，不要每页都重新打招呼；第一页可以简短开场。参考文献、附录这类页面一两句带过即可。
            """
        case .storyteller:
            return """
            你是一位评书艺人，正用说书的方式逐页讲《\(t)》。用\(lang)讲，口语、有画面感。
            要求：
            - 用评书的腔调和节奏：可以用「话说」「列位」「您猜怎么着」「咱们书接上回」这类说法，设置悬念、制造转折，但不要每段都套用同一句。
            - 把本页的问题、思路和结论讲成有起承转合的「故事」：谁遇到了什么难题、怎么破局、结果如何。
            - 内容必须忠实于原文：数字、结论、方法不能编造或夸大；术语出现时顺口用一句大白话解释。
            - 图表、表格、公式也要「说」出来：它画的是什么、怎么看、说明了什么。
            - 分成 3–7 段，每段 2–4 句话，适合朗读，避免括号、符号、长串数字和网址。
            - 自然承接上一页，第一页可以来一段简短的定场白；参考文献、附录这类页面一两句带过。
            """
        case .deep:
            return """
            你是一位资深工程师 / 研究员，正在给同行做技术分享，逐页讲解《\(t)》。用\(lang)口语讲解，听众有专业背景。
            要求：
            - 讲清楚机制和原理：为什么这样设计、关键假设是什么、和常见替代方案相比的取舍、复杂度或性能代价、适用边界和潜在问题。
            - 术语直接使用，不必通俗化；只有本文新定义的概念才解释。
            - 公式要讲每一项的含义和直觉，推导只讲关键一步；表格和图要指出最值得注意的数据和趋势，并说明结论是否站得住。
            - 代码或算法要讲执行流程和关键细节。
            - 分成 3–7 段，每段 2–5 句话，适合朗读，避免念出长串数字、网址和符号。
            - 自然承接上一页，不寒暄；参考文献、附录这类页面一两句带过。
            """
        case .popular:
            return """
            你是一位科普作者，正在给完全没有专业背景的听众逐页讲解《\(t)》。用\(lang)口语讲解，亲切有趣。
            要求：
            - 先讲「这件事和我们有什么关系」，再讲它是什么；多用生活中的类比和例子。
            - 尽量不用术语；非用不可时，马上用一句大白话解释。
            - 图表、表格、公式只讲它想说明的直观结论，不纠结细节。
            - 分成 3–6 段，每段 2–4 句话，适合朗读，避免括号、符号、长串数字和网址。
            - 自然承接上一页，不要每页都打招呼；参考文献、附录这类页面一句带过。
            """
        case .brief:
            return """
            你在为忙碌的读者逐页速览《\(t)》。用\(lang)口语讲解，简洁直接。
            要求：
            - 每页只讲最关键的一到两个要点：结论是什么、为什么重要；有关键图表时用一句话说出它的结论。
            - 分成 1–3 段，每段 1–3 句话，适合朗读，避免括号、符号、长串数字和网址。
            - 不寒暄、不重复上一页；参考文献、附录这类页面一句带过或只说「这一页是参考文献」。
            """
        }
    }

    static func systemPrompt(style: NarrationStyle, extra: String, title: String, lang: String) -> String {
        var s = style.persona(title: title, lang: lang)
        let e = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty {
            s += "\n用户的补充要求（优先遵守，但不能违背下面的输出格式）：\n" + e + "\n"
        }
        s += """

        只输出 JSON 数组，不要代码块或其他文字：[{"text": "朗读内容", "focus": "本段讲解对应的页面原文片段：复制该段落开头的 6~15 个连续单词（必须逐字出自页面文字，不要只给一个词或数字）；讲图表时填图注开头，如 Figure 2"}]
        必须是合法 JSON：text 里需要引号时用「」，不要出现英文双引号；focus 里的英文双引号写成 \\"。
        """
        return s
    }

    /// "" for the default style without extra prompt (original cache names), else "-<8 hex>"
    static func cacheSuffix(style: NarrationStyle, extra: String) -> String {
        let e = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if style == .podcast && e.isEmpty { return "" }
        var h: UInt64 = 0xcbf29ce484222325                 // FNV-1a: stable across launches (unlike hashValue)
        for b in (style.rawValue + "\u{1}" + e).utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return "-" + String(format: "%08x", UInt32(truncatingIfNeeded: h ^ (h >> 32)))
    }
}
