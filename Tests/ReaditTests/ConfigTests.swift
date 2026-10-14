import XCTest
@testable import Readit

final class ConfigTests: XCTestCase {
    func testParseEdgeCases() {
        let p = TOML.parse("a = 'lit # x' # c\n[s]\n\"q k\" = true\nn = 3 # c\nurl = \"http://x/#y\"\n[tts.qwen]\nvoice = \"Cherry\"")
        XCTAssertEqual(p["a"], "lit # x")
        XCTAssertEqual(p["s.q k"], "true")
        XCTAssertEqual(p["s.n"], "3")
        XCTAssertEqual(p["s.url"], "http://x/#y")
        XCTAssertEqual(p["tts.qwen.voice"], "Cherry")
    }

    func testUpdateKeepsCommentsAndAppendsSections() {
        let src = "[tts]\nvoice = \"Zephyr\"   # comment\n"
        let out = TOML.update(src, ["tts.voice": TOML.quote("Kore"), "tts.speed": "2.0", "tts.qwen.model": TOML.quote("qwen3-tts-flash")])
        XCTAssertTrue(out.contains("voice = \"Kore\"   # comment"))
        let p = TOML.parse(out)
        XCTAssertEqual(p["tts.speed"], "2.0")
        XCTAssertEqual(p["tts.qwen.model"], "qwen3-tts-flash")
    }

    func testQuoteRoundTrip() {
        let v = "第一行\n第二行 \"引号\" \\ tab\t"
        XCTAssertEqual(TOML.parse("k = " + TOML.quote(v))["k"], v)
    }
}

final class NarrationStyleTests: XCTestCase {
    func testCacheSuffixStable() {
        XCTAssertEqual(NarrationStyle.cacheSuffix(style: .podcast, extra: "  "), "")
        XCTAssertEqual(NarrationStyle.cacheSuffix(style: .storyteller, extra: ""), NarrationStyle.cacheSuffix(style: .storyteller, extra: ""))
        XCTAssertNotEqual(NarrationStyle.cacheSuffix(style: .storyteller, extra: ""), NarrationStyle.cacheSuffix(style: .storyteller, extra: "x"))
        XCTAssertEqual(NarrationStyle.hash("abc").count, 9)
    }

    func testPromptLanguage() {
        XCTAssertTrue(NarrationStyle.systemPrompt(style: .deep, extra: "多结合代码", title: "T", lang: "简体中文").contains("多结合代码"))
        XCTAssertTrue(NarrationStyle.systemPrompt(style: .deep, extra: "more code", title: "T", lang: "English").contains("senior engineer"))
    }
}

final class ScriptParserTests: XCTestCase {
    func testInnerQuotesAndTruncation() {
        let bad = #"[{"text": "作者说"不要改"，然后释放。", "focus": "Launch"}, {"text": "这一段讲了很多重要的内容和细节"#
        let r = ScriptParser.parse(bad)!
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].text, "作者说\"不要改\"，然后释放。")
        XCTAssertEqual(r[0].focus, "Launch")
    }

    func testSalvageNeverReturnsJSON() {
        let s = ScriptParser.salvage(#"[{"text": 123}]"#)
        XCTAssertFalse(s.contains { $0.text.contains("{") || $0.text.contains("\"") })
    }
}

final class MiscTests: XCTestCase {
    func testVersionCompare() {
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2.0", than: "0.2.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0", than: "0.99.1"))
    }

    func testTokenEstimate() {
        XCTAssertEqual(UsageStore.estimateTokens("你好世界"), 4)
        XCTAssertEqual(UsageStore.estimateTokens("abcdefgh"), 2)
        XCTAssertEqual(UsageStore.estimateTokens("", images: 1), 1100)
    }

    func testOAuthEncoding() {
        XCTAssertEqual(ChatGPTAuth.formEncode("a b+c/d"), "a%20b%2Bc%2Fd")
        XCTAssertFalse(ChatGPTAuth.base64url(Data([0xfb, 0xff])).contains("+"))
        XCTAssertEqual(ChatGPTAuth.random(32).count, 43)
    }

    func testWebImportHelpers() {
        XCTAssertEqual(WebImporter.normalize("jvns.ca/blog")?.absoluteString, "https://jvns.ca/blog")
        XCTAssertNil(WebImporter.normalize("hello"))
        XCTAssertTrue(WebImporter.looksBlocked("Just a moment..."))
        XCTAssertEqual(WebImporter.fileName("a/b: c"), "a b  c")
    }
}
