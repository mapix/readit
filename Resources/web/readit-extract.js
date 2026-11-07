/*
 * Readit web import — runs inside the loaded page (WKWebView), after Mozilla Readability.
 * window.__readitExtract() → JSON string:
 *   { ok, reason?, title, byline, site, date, lang, url, textLength, words, images, html }
 * `html` is a complete, self-contained print document (clean article + Readit print CSS).
 * The same file is exercised by the test harness in node (jsdom) and headless Chromium.
 */
(function () {
  "use strict";

  var BOILERPLATE = [
    "script", "style", "noscript:not(:has(img))", "template", "iframe:not([src*='youtube']):not([src*='vimeo']):not([src*='bilibili'])",
    "nav", "[role=navigation]", "[role=banner]", "[role=contentinfo]", "[role=complementary]", "[role=search]",
    "article aside", "main aside", "[class*=ConstellationPanel i]", "[class*=TableOfContents i]",
    "[aria-label*=cookie i]", "[id*=cookie i]", "[class*=cookie i]", "[class*=consent i]", "[id*=consent i]",
    "[class*=newsletter i]", "[id*=newsletter i]", "[class*=subscribe i]:not(article):not(main)",
    "[class*=share-] ", "[class*=sharing i]", "[class*=social i]:not(article):not(main)",
    "[class*=related i]:not(article):not(main):not(body)", "[class*=recommend i]:not(article):not(main):not(body)",
    "[id*=comments i]", "[class*=comments i]:not(article):not(main):not(body)", "#disqus_thread", ".giscus", ".utterances",
    "[class*=advert i]", "[id*=advert i]", "[class*=sponsor i]", "ins.adsbygoogle", "[class*=popup i]", "[class*=modal i]",
    "[class*=sidebar i]:not(body):not(main):not(article)", "[id*=sidebar i]", "[class*=breadcrumb i]",
    "[class*=toolbar i]", "[class*=paywall i]", "[class*=signup i]", "[class*=login i]:not(article)",
    "button", "form", "input", "select", "textarea", "dialog", "[hidden]", "[aria-hidden=true]:not(svg):not(.katex-html):not(mjx-container *)"
  ];

  var PRESERVED_CLASSES = ["footnotes", "caption", "readit-fig-label", "readit-cover", "readit-appendix", "readit-inline"];

  // short blocks whose whole text is UI chrome (share / follow / like …)
  var CHROME_TEXT = /^(share|share this|tweet|follow|subscribe|sign up|log in|like|comment|comments|reply|copy link|read more|related posts?|you may also like|recommended|advertisement|see more\.{0,3}|分享|分享到|关注|点赞|在看|收藏|评论|打赏|赞赏|相关阅读|相关文章|推荐阅读|阅读原文|上一篇|下一篇|返回顶部|扫码|扫一扫)[\s:：·|\d]*$/i;

  // UI chrome that may appear inside the article body
  var CHROME_LINE = /^(press enter or click to view image in full size|\d+\s*min read(\s*·?\s*\S+\s+\d{1,2},?\s+\d{4})?|listen|share|follow|member-only story|阅读时长.*|\d+\s*分钟阅读.*)$/i;

  function q(root, sel) { try { return Array.prototype.slice.call(root.querySelectorAll(sel)); } catch (e) { return []; } }
  function text(el) { return (el && (el.textContent || "")).replace(/\s+/g, " ").trim(); }
  function abs(u, base) { try { return new URL(u, base).href; } catch (e) { return u; } }

  /** Unwrap Next.js / Vercel image optimization URLs (/_next/image?url=...) to the original high-res asset URL */
  function unwrapImageProxy(u, base) {
    if (!u) return u;
    var resolved = abs(u, base);
    try {
      var parsed = new URL(resolved);
      if (/\/_(next|vercel)\/image\/?$/i.test(parsed.pathname)) {
        var inner = parsed.searchParams.get("url");
        if (inner) return abs(inner, base);
      }
    } catch (e) {}
    return resolved;
  }

  /** Unhide scroll-reveal elements (e.g. style="visibility:hidden" or "opacity:0") inside article/main before Readability checks _isProbablyVisible */
  function unhideScrollReveal(root) {
    q(root, "[style]").forEach(function (el) {
      if (el.hasAttribute("hidden") || el.getAttribute("aria-hidden") === "true") return;
      var st = el.getAttribute("style") || "";
      if (/display\s*:\s*none/i.test(st)) return;
      if (/visibility\s*:\s*hidden|opacity\s*:\s*0(?:\.0+)?(?:\s*;|\s*$)/i.test(st)) {
        var cleaned = st
          .replace(/visibility\s*:\s*hidden\s*;?/gi, "")
          .replace(/opacity\s*:\s*0(?:\.0+)?\s*;?/gi, "")
          .trim();
        if (cleaned) el.setAttribute("style", cleaned);
        else el.removeAttribute("style");
      }
    });
  }

  /** Materialize CSS custom property figure labels (e.g. <figcaption style="--figure-label:&quot;Figure 1&quot;">) into DOM spans before styles are stripped */
  function preserveFigureLabels(root) {
    var doc = root.ownerDocument || root;
    q(root, "figcaption[style*='--figure-label'], [style*='--figure-label']").forEach(function (el) {
      if (el.querySelector && el.querySelector(".readit-fig-label")) return;
      var st = el.getAttribute("style") || "";
      var m = st.match(/--figure-label\s*:\s*(?:["']|&quot;)?([^"';&]+)(?:["']|&quot;)?/i);
      if (!m || !m[1]) return;
      var label = m[1].trim();
      if (!label) return;
      var existing = text(el);
      if (existing.toLowerCase().indexOf(label.toLowerCase()) === 0) return;
      var span = doc.createElement("span");
      span.className = "readit-fig-label";
      span.textContent = label;
      el.insertBefore(span, el.firstChild);
    });
  }

  /** lazy-loaded images: promote data-* sources and the largest srcset candidate */
  function fixImages(root, base) {
    q(root, "img").forEach(function (img) {
      var cands = ["data-src", "data-original", "data-lazy-src", "data-actualsrc", "data-url", "data-hi-res-src", "data-full-src", "data-lazyload"];
      var src = img.getAttribute("src") || "";
      var placeholder = !src || /^data:image\/(gif|svg)/.test(src) || /(blank|placeholder|spacer|loading|lazy)\.(gif|png|svg)/i.test(src);
      for (var i = 0; i < cands.length; i++) {
        var v = img.getAttribute(cands[i]);
        if (v && !/^data:/.test(v)) { if (placeholder || cands[i] === "data-original") src = v; placeholder = false; break; }
      }
      var ss = img.getAttribute("srcset") || img.getAttribute("data-srcset");
      if (ss) {
        var best = null, bw = 0;
        ss.split(",").forEach(function (part) {
          var m = part.trim().split(/\s+/); if (!m[0]) return;
          var w = parseFloat(m[1] || "1") || 1; if (/x$/.test(m[1] || "")) w *= 1000;
          if (w >= bw) { bw = w; best = m[0]; }
        });
        if (best && (placeholder || !src || bw >= 600)) src = best;
        img.removeAttribute("srcset"); img.removeAttribute("data-srcset"); img.removeAttribute("sizes");
      }
      if (src) img.setAttribute("src", unwrapImageProxy(src, base));
      // icons / avatars / emoji: tiny declared size or typical URL patterns
      var w = parseInt(img.getAttribute("width") || "0", 10), h = parseInt(img.getAttribute("height") || "0", 10);
      var hint = (src + " " + (img.getAttribute("class") || "") + " " + (img.getAttribute("alt") || "")).toLowerCase();
      if ((w && w < 48) || (h && h < 48) || /avatar|gravatar|profile_images|resize:fill:\d{2}:\d{2}\/|\/emoji\/|badge\.svg|shields\.io/.test(hint)) {
        img.setAttribute("data-readit-tiny", "1");
      }
      img.removeAttribute("loading"); img.removeAttribute("decoding");
      img.removeAttribute("width"); img.removeAttribute("height"); img.removeAttribute("style");
    });
    // <picture>: keep the <img>
    q(root, "picture source").forEach(function (s) { s.remove(); });
  }

  /** math: keep native MathML (WebKit renders it) instead of KaTeX / MathJax HTML that needs their CSS */
  function fixMath(root) {
    var doc = root.ownerDocument || root;
    q(root, ".katex-display, .katex").forEach(function (k) {
      if (!root.contains(k)) return;
      var m = k.querySelector("math");
      if (m) {
        var display = k.classList.contains("katex-display") || (k.parentElement && k.parentElement.classList.contains("katex-display"));
        if (display) m.setAttribute("display", "block");
        k.replaceWith(m);
      } else {
        var tex = k.querySelector("annotation[encoding='application/x-tex']");
        if (tex) { var c = doc.createElement("code"); c.textContent = tex.textContent; k.replaceWith(c); }
      }
    });
    q(root, "mjx-container").forEach(function (c) {
      var m = c.querySelector("mjx-assistive-mml math, math");
      if (m) { if (c.getAttribute("display") === "true") m.setAttribute("display", "block"); c.replaceWith(m); }
    });
    q(root, "script[type^='math/tex']").forEach(function (s) {
      var c = doc.createElement("code"); c.textContent = s.textContent; s.replaceWith(c);
    });
  }

  /** embedded video → a link line */
  function fixEmbeds(root, base) {
    var doc = root.ownerDocument || root;
    q(root, "iframe, video").forEach(function (f) {
      var src = f.getAttribute("src") || (f.querySelector("source") && f.querySelector("source").getAttribute("src")) || "";
      var p = doc.createElement("p"); p.className = "readit-embed";
      p.textContent = "▶ " + (src ? abs(src, base) : "video");
      f.replaceWith(p);
    });
  }

  function preClean(doc) {
    BOILERPLATE.forEach(function (sel) {
      q(doc, sel).forEach(function (el) {
        // never remove the main content container itself
        if (el.querySelector && (el.querySelector("article") || q(el, "p").length > 12)) return;
        el.remove();
      });
    });
  }

  function postClean(root, title) {
    q(root, "p, div, section, span, li, a, ul, aside, footer, header").forEach(function (el) {
      if (!root.contains(el)) return;          // removed with an ancestor (root may be detached)
      if (el.classList && (el.classList.contains("readit-fig-label") || el.classList.contains("readit-cover") || el.classList.contains("readit-appendix"))) return;
      var t = text(el);
      if (t.length < 60 && (CHROME_TEXT.test(t) || CHROME_LINE.test(t)) && !el.querySelector("img, math, pre, table")) { el.remove(); return; }
      if (!t && !el.querySelector("img, math, svg, pre, table, hr, br, video, canvas")) el.remove();
    });
    // the title is printed in our header; drop a duplicate first heading
    var h = root.querySelector("h1, h2");
    if (h && title && text(h).toLowerCase() === title.trim().toLowerCase()) h.remove();
    // code blocks: keep text, drop line-number gutters
    q(root, "pre").forEach(function (pre) {
      q(pre, ".linenos, .lineno, .line-numbers-rows, .gutter, td.gutter").forEach(function (g) { g.remove(); });
    });
    q(root, "table.highlighttable, table.rouge-table").forEach(function (t) {
      var code = t.querySelector("td.code pre, td.rouge-code pre");
      if (code) t.replaceWith(code);
    });
    q(root, "a").forEach(function (a) {
      var href = a.getAttribute("href") || "";
      if (/^javascript:/i.test(href)) a.removeAttribute("href");
    });
    q(root, "img[data-readit-tiny]").forEach(function (img) {
      // keep inline icons that sit inside text (e.g. emoji in a sentence), drop standalone ones
      var p = img.parentElement;
      if (p && text(p).length > 40 && p.tagName !== "FIGURE") { img.removeAttribute("data-readit-tiny"); img.setAttribute("class", "readit-inline"); return; }
      img.remove();
    });
    q(root, "*").forEach(function (el) {
      el.removeAttribute("style"); el.removeAttribute("onclick");
      if (el.tagName === "IMG" && !el.getAttribute("src")) el.remove();
    });
  }

  function meta(doc, names) {
    for (var i = 0; i < names.length; i++) {
      var el = doc.querySelector("meta[property='" + names[i] + "'], meta[name='" + names[i] + "'], meta[itemprop='" + names[i] + "']");
      if (el && el.getAttribute("content")) return el.getAttribute("content").trim();
    }
    return "";
  }
  function jsonLD(doc, key) {
    var out = "";
    q(doc, "script[type='application/ld+json']").forEach(function (s) {
      if (out) return;
      try {
        var j = JSON.parse(s.textContent); var arr = Array.isArray(j) ? j : (j["@graph"] || [j]);
        arr.forEach(function (o) { if (!out && o && o[key]) out = typeof o[key] === "string" ? o[key] : (o[key].name || ""); });
      } catch (e) {}
    });
    return out;
  }

  function fallbackContent(doc) {
    var sels = ["article", "main article", "[itemprop=articleBody]", ".post-content", ".entry-content", ".article-content",
                ".post-body", ".markdown-body", "#js_content", ".rich_media_content", "main", "[role=main]", "#content", ".content"];
    for (var i = 0; i < sels.length; i++) {
      var el = doc.querySelector(sels[i]);
      if (el && text(el).length > 300) return el;
    }
    return null;
  }

  function esc(s) { return String(s || "").replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }

  function cleanFontFamily(raw, fallbackKind) {
    var s = String(raw || "").trim();
    // Strip Next.js synthetic metric-override fallback font names (e.g. "anthropicSerif Fallback" which maps to local(Arial))
    var parts = s ? s.split(",").map(function (p) { return p.trim(); }).filter(function (p) {
      return p && !/\bFallback["']?$/i.test(p);
    }) : [];
    var joined = parts.join(", ");
    var isSerif = fallbackKind === "serif" || (/\bserif\b/i.test(joined) && !/\bsans-serif\b/i.test(joined));
    var isMono = fallbackKind === "mono" || /\b(mono|monospace|consolas|menlo)\b/i.test(joined);
    if (isMono) {
      var monoTail = "'JetBrains Mono', 'SF Mono', Menlo, Monaco, Consolas, 'Liberation Mono', monospace";
      return joined ? (joined + ", " + monoTail) : monoTail;
    }
    if (isSerif) {
      var serifTail = "Charter, 'Iowan Old Style', Georgia, 'Source Serif 4', 'Songti SC', 'Hiragino Mincho ProN', 'Noto Serif CJK SC', serif";
      return joined ? (joined + ", " + serifTail) : serifTail;
    }
    var sansTail = "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', 'PingFang SC', 'Hiragino Sans GB', 'Noto Sans CJK SC', 'Microsoft YaHei', sans-serif";
    return joined ? (joined + ", " + sansTail) : sansTail;
  }

  function clampNum(v, lo, hi, dflt) {
    var n = parseFloat(v);
    if (isNaN(n) || !isFinite(n)) return dflt;
    return Math.min(hi, Math.max(lo, n));
  }

  /** Capture @font-face rules from live stylesheets and rewrite font URLs to readit-font-N tokens */
  function captureFontFaces(doc, pageURL) {
    var fontURLs = [];
    var rulesOut = [];
    var seenRuleKey = {};

    function processRuleText(cssText, baseHref) {
      if (!cssText || !/@font-face/i.test(cssText)) return;
      var famMatch = cssText.match(/font-family\s*:\s*([^;\}]+)/i);
      var fam = famMatch ? famMatch[1].replace(/["']/g, "").trim() : "";
      if (!fam || /\bFallback$/i.test(fam)) return;
      if (!/url\s*\(/i.test(cssText)) return;

      var ruleIdxs = [];
      var rewritten = cssText.replace(/url\(\s*(?:["']([^"']+)["']|([^)"'\s]+))\s*\)/gi, function (full, qUrl, bareUrl) {
        var rawU = (qUrl || bareUrl || "").trim();
        if (!rawU || /^data:/i.test(rawU)) return full;
        var effBase = baseHref || pageURL;
        if (/^\.\.\/media\//i.test(rawU) && effBase.indexOf("/_next/static/") < 0) {
          rawU = "/_next/static/media/" + rawU.slice("../media/".length);
        }
        var resolved = abs(rawU, effBase);
        if (!/^https?:/i.test(resolved)) return full;
        var idx = fontURLs.indexOf(resolved);
        if (idx < 0) {
          idx = fontURLs.length;
          fontURLs.push(resolved);
        }
        ruleIdxs.push(idx);
        return 'url("readit-font-' + idx + '")';
      });
      if (!ruleIdxs.length) return;
      rewritten = rewritten.replace(/font-display\s*:\s*[^;\}]+/gi, "font-display: block");
      if (!/font-weight\s*:/i.test(rewritten)) {
        rewritten = rewritten.replace(/\}\s*$/, "; font-weight: 100 900; }");
      }
      var key = fam.toLowerCase() + "|" + ruleIdxs.join(",");
      if (!seenRuleKey[key]) {
        seenRuleKey[key] = 1;
        rulesOut.push(rewritten);
      }
    }

    if (doc.styleSheets) {
      for (var i = 0; i < doc.styleSheets.length; i++) {
        var sheet = doc.styleSheets[i];
        var baseHref = (sheet && sheet.href) || pageURL;
        var rules;
        try { rules = sheet.cssRules || sheet.rules; } catch (e) { rules = null; }
        if (!rules) continue;
        for (var j = 0; j < rules.length; j++) {
          var r = rules[j];
          if (r && (r.type === 5 || (r.cssText && /^@font-face/i.test(r.cssText)))) {
            processRuleText(r.cssText, baseHref);
          }
        }
      }
    }
    q(doc, "style").forEach(function (st) {
      var txt = st.textContent || "";
      var matches = txt.match(/@font-face\s*\{[^}]+\}/gi) || [];
      matches.forEach(function (m) { processRuleText(m, pageURL); });
    });

    return { fontURLs: fontURLs, css: rulesOut.join("\n") };
  }

  /** Sample computed typography (font-family, font-size, line-height, weights, spacing, caption layout) from the live DOM */
  function captureTypography(doc) {
    if (typeof window === "undefined" || typeof window.getComputedStyle !== "function") return null;
    try {
      var liveRoot = doc.querySelector("article, main article, [itemprop=articleBody], .post-content, .entry-content, .article-content, .post-body, .markdown-body, #js_content, .rich_media_content, main, [role=main]") || doc.body;
      if (!liveRoot) return null;

      var bodyPs = q(liveRoot, "p").filter(function (p) {
        return !p.closest("header, footer, nav, aside, figcaption, blockquote, [class*=meta i], [class*=caption i], [class*=Constellation i]") && text(p).length >= 60;
      });
      var sampleP = bodyPs[0] || liveRoot.querySelector("p");
      var sampleTitle = doc.querySelector("article h1, main h1, h1");
      var sampleH2 = q(liveRoot, "h2").filter(function (h) { return !h.closest("header, footer, nav, aside") && text(h).length > 2; })[0];
      var sampleH3 = q(liveRoot, "h3").filter(function (h) { return !h.closest("header, footer, nav, aside") && text(h).length > 2; })[0];
      var sampleH4 = q(liveRoot, "h4").filter(function (h) { return !h.closest("header, footer, nav, aside") && text(h).length > 2; })[0];
      var sampleCode = liveRoot.querySelector("p code, li code, code:not(pre code)");
      var samplePre = liveRoot.querySelector("pre");
      var sampleCap = liveRoot.querySelector("figcaption [data-component='Caption'], figcaption [class*=caption i], figcaption > div") || liveRoot.querySelector("figcaption");

      function cs(el) { return el ? window.getComputedStyle(el) : null; }
      var pStyle = cs(sampleP);
      if (!pStyle) return null;

      var bodySizePx = clampNum(pStyle.fontSize, 15, 19.5, 17);
      var rawLH = parseFloat(pStyle.lineHeight);
      var bodyLineHeight = (!isNaN(rawLH) && rawLH > 8) ? clampNum(rawLH / bodySizePx, 1.48, 1.82, 1.62) : 1.62;
      var bodyFont = cleanFontFamily(pStyle.fontFamily, "");

      var pGapPx = Math.max(parseFloat(pStyle.marginTop) || 0, parseFloat(pStyle.marginBottom) || 0);
      if (pGapPx < 4 && bodyPs.length >= 2) {
        var p2Style = cs(bodyPs[1]);
        if (p2Style) pGapPx = Math.max(parseFloat(p2Style.marginTop) || 0, parseFloat(p2Style.marginBottom) || 0);
      }
      var pGapEm = pGapPx > 4 ? clampNum(pGapPx / bodySizePx, 0.85, 1.5, 1.25) : 1.2;

      var hRefStyle = cs(sampleH3 || sampleH2 || sampleTitle);
      var headingFont = hRefStyle ? cleanFontFamily(hRefStyle.fontFamily, "sans") : bodyFont;
      var tStyle = cs(sampleTitle);
      var titleFont = tStyle ? cleanFontFamily(tStyle.fontFamily, "sans") : headingFont;
      var titleSizePx = tStyle ? clampNum(parseFloat(tStyle.fontSize), 26, 36, 32) : 32;
      var titleWeight = (tStyle && tStyle.fontWeight) || "600";
      var rawTitleLH = tStyle ? parseFloat(tStyle.lineHeight) : NaN;
      var titleLH = (!isNaN(rawTitleLH) && rawTitleLH > 10 && tStyle) ? clampNum(rawTitleLH / parseFloat(tStyle.fontSize), 1.1, 1.32, 1.18) : 1.18;

      var h2Style = cs(sampleH2);
      var h3Style = cs(sampleH3);
      var h4Style = cs(sampleH4);
      var h3SizePx = h3Style ? clampNum(parseFloat(h3Style.fontSize), bodySizePx * 1.15, 25, 21.5) : Math.round(bodySizePx * 1.26 * 10) / 10;
      var h3Weight = (h3Style && h3Style.fontWeight) || "700";
      var h2SizePx = h2Style ? clampNum(parseFloat(h2Style.fontSize), Math.max(h3SizePx + 2, bodySizePx * 1.3), 29, 25) : Math.round(Math.max(h3SizePx + 3, bodySizePx * 1.45) * 10) / 10;
      var h2Weight = (h2Style && h2Style.fontWeight) || "700";
      var h4SizePx = h4Style ? clampNum(parseFloat(h4Style.fontSize), bodySizePx * 1.05, h3SizePx, bodySizePx * 1.1) : Math.round(bodySizePx * 1.1 * 10) / 10;

      var codeStyle = cs(sampleCode || samplePre);
      var monoFont = codeStyle ? cleanFontFamily(codeStyle.fontFamily, "mono") : cleanFontFamily("", "mono");

      var capStyle = cs(sampleCap);
      var capFont = capStyle ? cleanFontFamily(capStyle.fontFamily, "sans") : headingFont;
      var capSizePx = capStyle ? clampNum(parseFloat(capStyle.fontSize), 12, 14.5, 13) : 13;

      return {
        bodyFont: bodyFont,
        bodySizePx: Math.round(bodySizePx * 10) / 10,
        bodyLineHeight: Math.round(bodyLineHeight * 100) / 100,
        pGapEm: Math.round(pGapEm * 100) / 100,
        headingFont: headingFont,
        titleFont: titleFont,
        titleSizePx: Math.round(titleSizePx * 10) / 10,
        titleWeight: titleWeight,
        titleLH: Math.round(titleLH * 100) / 100,
        h2SizePx: Math.round(h2SizePx * 10) / 10,
        h2Weight: h2Weight,
        h3SizePx: Math.round(h3SizePx * 10) / 10,
        h3Weight: h3Weight,
        h4SizePx: Math.round(h4SizePx * 10) / 10,
        monoFont: monoFont,
        capFont: capFont,
        capSizePx: Math.round(capSizePx * 10) / 10
      };
    } catch (e) {
      return null;
    }
  }

  var CSS = [
    "@page { size: A4; }",   // margins come from the print settings (NSPrintInfo in the app)
    "html { -webkit-text-size-adjust: 100%; }",
    ":root {",
    "  --readit-body-font: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', 'PingFang SC', 'Hiragino Sans GB', 'Noto Sans CJK SC', 'Microsoft YaHei', sans-serif;",
    "  --readit-heading-font: var(--readit-body-font);",
    "  --readit-title-font: var(--readit-heading-font);",
    "  --readit-mono-font: 'JetBrains Mono', 'SF Mono', Menlo, Consolas, monospace;",
    "  --readit-cap-font: var(--readit-heading-font);",
    "  --readit-body-size: 16.5px;",
    "  --readit-body-lh: 1.62;",
    "  --readit-p-gap: 1.25em;",
    "  --readit-title-size: 32px;",
    "  --readit-title-weight: 600;",
    "  --readit-title-lh: 1.18;",
    "  --readit-h2-size: 24px;",
    "  --readit-h2-weight: 700;",
    "  --readit-h3-size: 21px;",
    "  --readit-h3-weight: 700;",
    "  --readit-h4-size: 18px;",
    "  --readit-cap-size: 13px;",
    "}",
    "body { margin: 0 auto; max-width: 640px; padding: 0 4px; color: #141413; background: #fff;",
    "  font-family: var(--readit-body-font); font-size: var(--readit-body-size); line-height: var(--readit-body-lh);",
    "  font-feature-settings: 'pnum' on, 'lnum' on, 'liga' on; -webkit-font-smoothing: antialiased;",
    "  -webkit-print-color-adjust: exact; print-color-adjust: exact; word-wrap: break-word; overflow-wrap: anywhere; }",
    "header.readit { margin: 0 0 26px; padding-bottom: 16px; border-bottom: 1px solid #e5e4dd; }",
    "header.readit h1 { font-family: var(--readit-title-font); font-size: var(--readit-title-size); font-weight: var(--readit-title-weight);",
    "  line-height: var(--readit-title-lh); margin: 0 0 12px; letter-spacing: -0.015em; color: #141413; }",
    "header.readit .meta { font-family: var(--readit-cap-font); color: #5e5d59; font-size: 13px; line-height: 1.5; }",
    "header.readit .src { font-family: var(--readit-cap-font); color: #87867f; font-size: 11.5px; margin-top: 4px; word-break: break-all; }",
    "article h1 { font-size: calc(var(--readit-h2-size) + 2px); font-weight: var(--readit-h2-weight); }",
    "article h2 { font-size: var(--readit-h2-size); font-weight: var(--readit-h2-weight); }",
    "article h3 { font-size: var(--readit-h3-size); font-weight: var(--readit-h3-weight); }",
    "article h4, article h5, article h6 { font-size: var(--readit-h4-size); font-weight: 600; }",
    "h1, h2, h3, h4, h5, h6 { font-family: var(--readit-heading-font); color: #141413; line-height: 1.25; margin: 2.0em 0 0.85em; font-synthesis: none; break-after: avoid; page-break-after: avoid; }",
    "p { margin: 0 0 var(--readit-p-gap); orphans: 3; widows: 3; }",
    "ul, ol { padding-left: 1.5em; margin: 0 0 var(--readit-p-gap); } li { margin: 0.35em 0; }",
    "img, svg, canvas { max-width: 100% !important; height: auto !important; break-inside: avoid; page-break-inside: avoid; }",
    "img { display: block; margin: 1.1em auto; border-radius: 4px; }",
    "p img, li img { display: inline-block; margin: 0.4em auto; vertical-align: middle; }",
    "img.readit-inline { display: inline; height: 1.2em !important; width: auto; margin: 0 0.1em; vertical-align: -0.2em; }",
    "figure { margin: 2.0em 0; break-inside: avoid; page-break-inside: avoid; }",
    "figure.readit-cover { margin: 0 0 2.0em; }",
    "figure img { width: 100%; margin: 0 auto 12px; border-radius: 4px; }",
    "figcaption, .caption { font-family: var(--readit-cap-font); color: #5e5d59; font-size: var(--readit-cap-size); line-height: 1.54; text-align: left; }",
    "figcaption:has(.readit-fig-label) { display: flex; align-items: baseline; gap: 20px; }",
    ".readit-fig-label { font-family: var(--readit-mono-font); font-size: 11px; line-height: 1.5; letter-spacing: 0.02em; text-transform: uppercase; color: #5e5d59; min-width: 64px; flex-shrink: 0; }",
    "blockquote { margin: 1.3em 0; padding: 0.25em 0 0.25em 16px; border-left: 3px solid #d5d3c8; color: #3d3d3a; }",
    "pre { white-space: pre-wrap; word-break: break-word; background: #f5f4ef; border: 1px solid #e6e4dc; border-radius: 6px;",
    "  padding: 12px 14px; font-family: var(--readit-mono-font); font-size: 12.5px; line-height: 1.55; margin: 1.2em 0; }",
    "code, kbd, samp { font-family: var(--readit-mono-font); font-size: 0.82em; }",
    ":not(pre) > code { background: #f3f2ec; border: 1px solid #e2e0d6; color: #3d3d3a; padding: 0.14em 0.35em; border-radius: 4px; }",
    "pre code { background: none; border: 0; padding: 0; font-size: inherit; color: inherit; }",
    "table { border-collapse: collapse; width: 100%; margin: 1.4em 0; font-family: var(--readit-cap-font); font-size: 13px; break-inside: auto; }",
    "th, td { border: 1px solid #dcdad0; padding: 6px 8px; text-align: left; vertical-align: top; } th { background: #f5f4ef; font-weight: 600; }",
    "tr { break-inside: avoid; page-break-inside: avoid; }",
    "hr { border: 0; border-top: 1px solid #e5e4dd; margin: 2.0em 0; }",
    "section.readit-appendix { margin-top: 2.6em; padding-top: 1.4em; border-top: 1px solid #e5e4dd; font-family: var(--readit-cap-font); font-size: 13.5px; line-height: 1.56; color: #4a4945; }",
    "section.readit-appendix h2, section.readit-appendix h3 { font-size: 16px; margin: 0.8em 0 0.4em; }",
    "a { color: inherit; text-decoration: underline; text-underline-offset: 0.18em; text-decoration-color: rgba(20, 20, 19, 0.35); }",
    "math { overflow-wrap: normal; word-break: normal; white-space: nowrap; }",
    "math[display=block] { margin: 0.8em 0; }",   // never override display: it must stay \"block math\"
    ".readit-embed { color: #5e5d59; font-size: 13px; word-break: break-all; }",
    "sup, sub { line-height: 0; }",
    "@media print { a { color: inherit; } }"
  ].join("\n");

  function typographyVarsCSS(t) {
    if (!t) return "";
    return [
      ":root {",
      "  --readit-body-font: " + t.bodyFont + ";",
      "  --readit-heading-font: " + t.headingFont + ";",
      "  --readit-title-font: " + t.titleFont + ";",
      "  --readit-mono-font: " + t.monoFont + ";",
      "  --readit-cap-font: " + t.capFont + ";",
      "  --readit-body-size: " + t.bodySizePx + "px;",
      "  --readit-body-lh: " + t.bodyLineHeight + ";",
      "  --readit-p-gap: " + t.pGapEm + "em;",
      "  --readit-title-size: " + t.titleSizePx + "px;",
      "  --readit-title-weight: " + t.titleWeight + ";",
      "  --readit-title-lh: " + t.titleLH + ";",
      "  --readit-h2-size: " + t.h2SizePx + "px;",
      "  --readit-h2-weight: " + t.h2Weight + ";",
      "  --readit-h3-size: " + t.h3SizePx + "px;",
      "  --readit-h3-weight: " + t.h3Weight + ";",
      "  --readit-h4-size: " + t.h4SizePx + "px;",
      "  --readit-cap-size: " + t.capSizePx + "px;",
      "}"
    ].join("\n");
  }

  function build(info) {
    var seen = {};
    var metaLine = [info.byline, info.site, info.date].filter(function (x) {
      var k = (x || "").toLowerCase(); if (!k || seen[k]) return false; seen[k] = 1; return true;
    }).map(esc).join(" · ");
    var extraCSS = (info.fontFacesCSS ? (info.fontFacesCSS + "\n") : "") + typographyVarsCSS(info.typography);
    return "<!DOCTYPE html><html lang=\"" + esc(info.lang || "") + "\"><head><meta charset=\"utf-8\">" +
      "<meta name=\"viewport\" content=\"width=device-width\"><base href=\"" + esc(info.url) + "\">" +
      "<title>" + esc(info.title) + "</title><style>" + CSS + (extraCSS ? ("\n" + extraCSS) : "") + "</style></head><body>" +
      "<header class=\"readit\"><h1>" + esc(info.title) + "</h1>" +
      (metaLine ? "<div class=\"meta\">" + metaLine + "</div>" : "") +
      "<div class=\"src\">" + esc(info.url) + "</div></header>" +
      "<article>" + info.content + "</article></body></html>";
  }

  /** "Post title - Blog name" → "Post title": prefer a page <h1> that matches the first part */
  function cleanTitle(title, doc, site) {
    var t = (title || "").trim().replace(/^GitHub\s+-\s+/, "");
    var parts = t.split(/\s+[|\-–—·»:\\]\s+|\s*[|｜–—_\\]\s*/);
    if (parts.length < 2) return t;
    var h1s = q(doc, "h1, h2").map(text).filter(function (x) { return x.length > 3; });
    for (var i = 0; i < h1s.length; i++) {
      var h = h1s[i];
      if (t.indexOf(h) === 0 && h.length < t.length) return h;
    }
    var last = parts[parts.length - 1];
    var generic = /anthropic|openai|deepmind|wikipedia|blog|博客|网络日志|日志|知乎|csdn|博客园|掘金|medium|substack|github|微信|公众号|官网|news|新闻/i;
    if ((site && last.toLowerCase() === site.toLowerCase()) || generic.test(last)) return parts.slice(0, -1).join(" - ");
    return t;
  }

  /** JSON for the app: lone UTF-16 surrogates (cut emoji) would make strict JSON decoders reject everything */
  function out(o) {
    return JSON.stringify(o, function (k, v) {
      if (typeof v !== "string") return v;
      if (v.toWellFormed) return v.toWellFormed();
      return v.replace(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(^|[^\uD800-\uDBFF])[\uDC00-\uDFFF]/g, "$1\uFFFD");
    });
  }

  function fmtDate(s) {
    if (!s) return "";
    var d = new Date(s);
    if (isNaN(d.getTime())) return String(s).slice(0, 40);
    function p(n) { return (n < 10 ? "0" : "") + n; }
    return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate());
  }

  /** Recover hero/cover illustration from <article> header if Readability selected only the inner body container */
  function recoverCoverImage(clone, holder) {
    var doc = clone.ownerDocument || clone;
    var existingSrcs = q(holder, "img").map(function (i) { return i.getAttribute("src") || ""; });
    var coverCands = q(clone, "article header img, main header img, article [class*='Cover' i] img, [class*='CoverImage' i]");
    for (var i = 0; i < coverCands.length; i++) {
      var img = coverCands[i];
      if (img.hasAttribute("data-readit-tiny")) continue;
      var src = img.getAttribute("src") || "";
      if (!/^https?:/i.test(src) || existingSrcs.indexOf(src) >= 0) continue;
      var fig = doc.createElement("figure");
      fig.className = "readit-cover";
      var newImg = doc.createElement("img");
      newImg.setAttribute("src", src);
      if (img.getAttribute("alt")) newImg.setAttribute("alt", img.getAttribute("alt"));
      fig.appendChild(newImg);
      holder.insertBefore(fig, holder.firstChild);
      break;
    }
  }

  /** Recover trailing article sections (e.g. Authors & acknowledgements, Footnotes, References) inside <article> that sat outside topCandidate */
  function recoverTrailingSections(clone, holder) {
    var doc = clone.ownerDocument || clone;
    var holderText = text(holder).toLowerCase();
    var sections = q(clone, "article > section, article section, main article > footer");
    sections.forEach(function (sec) {
      if (sec.closest("aside, nav, header")) return;
      var secText = text(sec);
      if (secText.length < 30 || secText.length > 6000) return;
      var heading = text(sec.querySelector("h1, h2, h3, h4"));
      if (!/acknowledg|authors?\b|footnotes?|references|appendix|citation|致谢|参考文献|附录/i.test(heading + " " + secText.slice(0, 120))) return;
      if (/related|recommend|more from|subscribe|newsletter/i.test(heading)) return;
      var probe = secText.slice(Math.min(20, secText.length - 1), Math.min(90, secText.length)).toLowerCase();
      if (probe.length > 15 && holderText.indexOf(probe) >= 0) return;

      var wrap = doc.createElement("section");
      wrap.className = "readit-appendix";
      wrap.innerHTML = sec.innerHTML;
      preClean(wrap);
      // Drop duplicate outer h2 if there is already an inner h3 with the same word (e.g. "Authors & acknowledgements" + "Acknowledgements")
      var h2 = wrap.querySelector("h2"), h3 = wrap.querySelector("h3");
      if (h2 && h3 && /acknowledg/i.test(text(h2)) && /acknowledg/i.test(text(h3))) {
        h3.remove();
      }
      holder.appendChild(wrap);
      holderText += " " + secText.toLowerCase();
    });
  }

  function extract(doc, url) {
    url = url || (doc.location && doc.location.href) || "";
    var typography = captureTypography(doc);
    var fontsInfo = captureFontFaces(doc, url);

    var clone = doc.cloneNode(true);
    unhideScrollReveal(clone);
    preserveFigureLabels(clone);
    fixImages(clone, url);
    fixMath(clone);
    var lang = (doc.documentElement.getAttribute("lang") || "").trim();
    var title0 = meta(doc, ["og:title", "twitter:title"]) || jsonLD(doc, "headline") || (doc.title || "").trim();
    var site = meta(doc, ["og:site_name", "application-name"]) || "";
    if (!site && /anthropic\.com/i.test(url)) site = "Anthropic";
    var date = meta(doc, ["article:published_time", "datePublished", "pubdate", "publishdate", "date", "DC.date.issued"]) || jsonLD(doc, "datePublished");
    if (!date) { var t = doc.querySelector("time[datetime]"); if (t) date = t.getAttribute("datetime"); }
    var author = meta(doc, ["author", "article:author", "twitter:creator"]) || jsonLD(doc, "author");

    // 1) Readability on a pre-cleaned clone
    var work = clone.cloneNode(true);
    preClean(work);
    var art = null;
    try {
      if (typeof Readability === "function") {
        art = new Readability(work, { charThreshold: 400, nbTopCandidates: 6, keepClasses: false,
                                      classesToPreserve: PRESERVED_CLASSES }).parse();
      }
    } catch (e) { art = null; }

    var holder = (clone.createElement ? clone : doc).createElement("div");
    var how = "readability";
    if (art && art.content && (art.textContent || "").replace(/\s+/g, "").length > 250) {
      holder.innerHTML = art.content;
    } else {
      // 2) common article containers on the un-pre-cleaned clone (Readability can be too strict on short posts)
      var el = fallbackContent(clone);
      if (!el) return out({ ok: false, reason: "no-article", title: title0, url: url });
      holder.innerHTML = el.innerHTML;
      preClean(holder);
      how = "container";
    }
    recoverCoverImage(clone, holder);
    recoverTrailingSections(clone, holder);
    fixImages(holder, url);
    fixEmbeds(holder, url);
    postClean(holder, (art && art.title) || title0);

    var plain = text(holder);
    var title = ((art && art.title) || title0 || plain.slice(0, 60)).trim();
    // strip " | Site" / " - Site" / " \ Site" suffixes that come from <title>
    if (site && title.length > site.length + 3) {
      var re = new RegExp("\\s*[|\\-–—·:\\\\]\\s*" + site.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\s*$", "i");
      title = title.replace(re, "");
    }
    title = cleanTitle(title, doc, site);
    var byline = ((art && art.byline) || author || "").replace(/\s+/g, " ").trim()
      .replace(/^(by|written by|作者|文|撰文|author)\s*[:：]?\s*/i, "");
    if (/^@[A-Za-z0-9_]+$/.test(byline)) {
      var writtenByMatch = plain.match(/\bWritten by\s+([A-Z][a-zA-Z.\-']+(?:\s+[A-Z][a-zA-Z.\-']+){0,3})/);
      if (writtenByMatch && writtenByMatch[1]) {
        byline = writtenByMatch[1];
      } else if (site && byline.toLowerCase().indexOf(site.toLowerCase()) >= 0) {
        byline = "";
      }
    }
    if (/\[bot\]|dependabot|renovate/i.test(byline)) byline = "";
    if (byline.length > 80) byline = byline.slice(0, 80) + "…";
    var info = {
      ok: plain.length > 200, reason: plain.length > 200 ? "" : "too-short", how: how,
      title: title, byline: byline, site: (art && art.siteName) || site, date: fmtDate((art && art.publishedTime) || date),
      lang: (art && art.lang) || lang, url: url,
      textLength: plain.length,
      words: (plain.match(/[一-鿿]|[A-Za-z0-9]+/g) || []).length,
      images: q(holder, "img").length,
      typography: typography,
      fontFacesCSS: fontsInfo.css,
      fontURLs: fontsInfo.fontURLs
    };
    // images are fetched by the app (with the page as Referer, so hotlink-protected CDNs work) and stored next
    // to the print document; the HTML refers to them by token: src="readit-img-N"
    var imageURLs = [];
    q(holder, "img").forEach(function (img) {
      var u = img.getAttribute("src") || "";
      if (/^file:/i.test(u)) return;                 // local document (saved page): read directly
      if (!/^https?:/i.test(u) || /(pixel|beacon|analytics|tracking|\/1x1\.)/i.test(u)) { if (!/^data:image\/(png|jpe?g|webp|gif)/.test(u)) img.remove(); return; }
      var k = imageURLs.indexOf(u);
      if (k < 0) { k = imageURLs.length; imageURLs.push(u); }
      img.setAttribute("src", "readit-img-" + k);
    });
    info.imageURLs = imageURLs;
    info.images = imageURLs.length;
    info.content = holder.innerHTML;
    info.html = build(info);
    delete info.content;
    delete info.typography;
    delete info.fontFacesCSS;
    return out(info);
  }

  /** scroll through the page so lazy loaders fire; resolves after reaching the bottom (max ~8 s) */
  function primeLazy() {
    return new Promise(function (resolve) {
      var y = 0, steps = 0, h = function () { return Math.max(document.body.scrollHeight, document.documentElement.scrollHeight); };
      (function tick() {
        y += Math.max(600, window.innerHeight * 0.9); steps++;
        window.scrollTo(0, y);
        if (y >= h() || steps > 60) { window.scrollTo(0, 0); setTimeout(resolve, 400); return; }
        setTimeout(tick, 120);
      })();
    });
  }

  var api = { extract: extract, build: build, primeLazy: primeLazy, css: CSS };
  if (typeof window !== "undefined") {
    window.__readit = api;
    window.__readitExtract = function () {
      try { return extract(document, location.href); }
      catch (e) {
        var where = String((e && e.stack) || "").split("\n").slice(0, 2).join(" | ");
        return out({ ok: false, reason: "exception: " + (e && e.message) + (where ? " @ " + where : ""), title: document.title || "", url: location.href });
      }
    };
  }
  if (typeof module === "object" && module.exports) module.exports = api;
})();
