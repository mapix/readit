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

  // short blocks whose whole text is UI chrome (share / follow / like …)
  var CHROME_TEXT = /^(share|share this|tweet|follow|subscribe|sign up|log in|like|comment|comments|reply|copy link|read more|related posts?|you may also like|recommended|advertisement|分享|分享到|关注|点赞|在看|收藏|评论|打赏|赞赏|相关阅读|相关文章|推荐阅读|阅读原文|上一篇|下一篇|返回顶部|扫码|扫一扫)[\s:：·|\d]*$/i;

  // UI chrome that may appear inside the article body
  var CHROME_LINE = /^(press enter or click to view image in full size|\d+\s*min read(\s*·?\s*\S+\s+\d{1,2},?\s+\d{4})?|listen|share|follow|member-only story|阅读时长.*|\d+\s*分钟阅读.*)$/i;

  function q(root, sel) { try { return Array.prototype.slice.call(root.querySelectorAll(sel)); } catch (e) { return []; } }
  function text(el) { return (el && (el.textContent || "")).replace(/\s+/g, " ").trim(); }
  function abs(u, base) { try { return new URL(u, base).href; } catch (e) { return u; } }

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
        if (best && (placeholder || !src)) src = best;
        img.removeAttribute("srcset"); img.removeAttribute("data-srcset"); img.removeAttribute("sizes");
      }
      if (src) img.setAttribute("src", abs(src, base));
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

  var CSS = [
    "@page { size: A4; }",   // margins come from the print settings (NSPrintInfo in the app)
    "html { -webkit-text-size-adjust: 100%; }",
    "body { margin: 0 auto; max-width: 680px; padding: 0 4px; color: #1d1d1f; background: #fff;",
    "  font: 11pt/1.68 -apple-system, BlinkMacSystemFont, 'Helvetica Neue', 'PingFang SC', 'Hiragino Sans GB', 'Noto Sans CJK SC', 'Microsoft YaHei', sans-serif;",
    "  -webkit-print-color-adjust: exact; print-color-adjust: exact; word-wrap: break-word; overflow-wrap: anywhere; }",
    "header.readit { margin: 0 0 22px; padding-bottom: 14px; border-bottom: 1px solid #e5e5e5; }",
    "header.readit h1 { font-size: 22pt; line-height: 1.25; margin: 0 0 10px; letter-spacing: -0.01em; }",
    "header.readit .meta { color: #6e6e73; font-size: 9.5pt; }",
    "header.readit .src { color: #8e8e93; font-size: 8.5pt; margin-top: 3px; word-break: break-all; }",
    "article h1 { font-size: 17pt; } article h2 { font-size: 15pt; } article h3 { font-size: 13pt; } article h4, article h5, article h6 { font-size: 11.5pt; }",
    "h1, h2, h3, h4, h5, h6 { line-height: 1.3; margin: 1.4em 0 0.5em; break-after: avoid; page-break-after: avoid; }",
    "p { margin: 0 0 0.85em; orphans: 3; widows: 3; }",
    "ul, ol { padding-left: 1.6em; margin: 0 0 0.9em; } li { margin: 0.2em 0; }",
    "img, svg, canvas { max-width: 100% !important; height: auto !important; break-inside: avoid; page-break-inside: avoid; }",
    "img { display: block; margin: 0.9em auto; border-radius: 3px; }",
    "p img, li img { display: inline-block; margin: 0.4em auto; vertical-align: middle; }",
    "img.readit-inline { display: inline; height: 1.2em !important; width: auto; margin: 0 0.1em; vertical-align: -0.2em; }",
    "figure { margin: 1.1em 0; break-inside: avoid; page-break-inside: avoid; } figure img { margin: 0 auto 0.4em; }",
    "figcaption, .caption { color: #6e6e73; font-size: 9pt; text-align: center; line-height: 1.45; }",
    "blockquote { margin: 1em 0; padding: 0.2em 0 0.2em 14px; border-left: 3px solid #d2d2d7; color: #3a3a3c; }",
    "pre { white-space: pre-wrap; word-break: break-word; background: #f5f5f7; border: 1px solid #e8e8ed; border-radius: 6px;",
    "  padding: 10px 12px; font: 8.8pt/1.5 'SF Mono', Menlo, Consolas, monospace; margin: 0.9em 0; }",
    "code, kbd, samp { font-family: 'SF Mono', Menlo, Consolas, monospace; font-size: 0.88em; }",
    ":not(pre) > code { background: #f2f2f4; padding: 0.08em 0.32em; border-radius: 4px; }",
    "pre code { background: none; padding: 0; font-size: inherit; }",
    "table { border-collapse: collapse; width: 100%; margin: 1em 0; font-size: 9.5pt; break-inside: auto; }",
    "th, td { border: 1px solid #d9d9de; padding: 5px 7px; text-align: left; vertical-align: top; } th { background: #f5f5f7; }",
    "tr { break-inside: avoid; page-break-inside: avoid; }",
    "hr { border: 0; border-top: 1px solid #e5e5e5; margin: 1.6em 0; }",
    "a { color: #0b57d0; text-decoration: none; }",
    "math { overflow-wrap: normal; word-break: normal; white-space: nowrap; }",
    "math[display=block] { margin: 0.8em 0; }",   // never override display: it must stay \"block math\"
    ".readit-embed { color: #6e6e73; font-size: 9.5pt; word-break: break-all; }",
    "sup, sub { line-height: 0; }",
    "@media print { a { color: #1d1d1f; } }"
  ].join("\n");

  function build(info) {
    var seen = {};
    var metaLine = [info.byline, info.site, info.date].filter(function (x) {
      var k = (x || "").toLowerCase(); if (!k || seen[k]) return false; seen[k] = 1; return true;
    }).map(esc).join(" · ");
    return "<!DOCTYPE html><html lang=\"" + esc(info.lang || "") + "\"><head><meta charset=\"utf-8\">" +
      "<meta name=\"viewport\" content=\"width=device-width\"><base href=\"" + esc(info.url) + "\">" +
      "<title>" + esc(info.title) + "</title><style>" + CSS + "</style></head><body>" +
      "<header class=\"readit\"><h1>" + esc(info.title) + "</h1>" +
      (metaLine ? "<div class=\"meta\">" + metaLine + "</div>" : "") +
      "<div class=\"src\">" + esc(info.url) + "</div></header>" +
      "<article>" + info.content + "</article></body></html>";
  }

  /** "Post title - Blog name" → "Post title": prefer a page <h1> that matches the first part */
  function cleanTitle(title, doc, site) {
    var t = (title || "").trim().replace(/^GitHub\s+-\s+/, "");
    var parts = t.split(/\s+[|\-–—·»:]\s+|\s*[|｜–—_]\s*/);
    if (parts.length < 2) return t;
    var h1s = q(doc, "h1, h2").map(text).filter(function (x) { return x.length > 3; });
    for (var i = 0; i < h1s.length; i++) {
      var h = h1s[i];
      if (t.indexOf(h) === 0 && h.length < t.length) return h;
    }
    var last = parts[parts.length - 1];
    var generic = /wikipedia|blog|博客|网络日志|日志|知乎|csdn|博客园|掘金|medium|substack|github|微信|公众号|官网|news|新闻/i;
    if ((site && last.toLowerCase() === site.toLowerCase()) || generic.test(last)) return parts.slice(0, -1).join(" - ");
    return t;
  }

  function fmtDate(s) {
    if (!s) return "";
    var d = new Date(s);
    if (isNaN(d.getTime())) return String(s).slice(0, 40);
    function p(n) { return (n < 10 ? "0" : "") + n; }
    return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate());
  }

  function extract(doc, url) {
    url = url || (doc.location && doc.location.href) || "";
    var clone = doc.cloneNode(true);
    fixImages(clone, url);
    fixMath(clone);
    var lang = (doc.documentElement.getAttribute("lang") || "").trim();
    var title0 = meta(doc, ["og:title", "twitter:title"]) || jsonLD(doc, "headline") || (doc.title || "").trim();
    var site = meta(doc, ["og:site_name", "application-name"]) || "";
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
                                      classesToPreserve: ["footnotes", "caption"] }).parse();
      }
    } catch (e) { art = null; }

    var holder = (clone.createElement ? clone : doc).createElement("div");
    var how = "readability";
    if (art && art.content && (art.textContent || "").replace(/\s+/g, "").length > 250) {
      holder.innerHTML = art.content;
    } else {
      // 2) common article containers on the un-pre-cleaned clone (Readability can be too strict on short posts)
      var el = fallbackContent(clone);
      if (!el) return JSON.stringify({ ok: false, reason: "no-article", title: title0, url: url });
      holder.innerHTML = el.innerHTML;
      preClean(holder);
      how = "container";
    }
    fixImages(holder, url);
    fixEmbeds(holder, url);
    postClean(holder, (art && art.title) || title0);

    var plain = text(holder);
    var title = ((art && art.title) || title0 || plain.slice(0, 60)).trim();
    // strip " | Site" / " - Site" suffixes that come from <title>
    if (site && title.length > site.length + 3) {
      var re = new RegExp("\\s*[|\\-–—·:]\\s*" + site.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\s*$", "i");
      title = title.replace(re, "");
    }
    title = cleanTitle(title, doc, site);
    var byline = ((art && art.byline) || author || "").replace(/\s+/g, " ").trim()
      .replace(/^(by|written by|作者|文|撰文|author)\s*[:：]?\s*/i, "");
    if (/\[bot\]|dependabot|renovate/i.test(byline)) byline = "";
    if (byline.length > 80) byline = byline.slice(0, 80) + "…";
    var info = {
      ok: plain.length > 200, reason: plain.length > 200 ? "" : "too-short", how: how,
      title: title, byline: byline, site: (art && art.siteName) || site, date: fmtDate((art && art.publishedTime) || date),
      lang: (art && art.lang) || lang, url: url,
      textLength: plain.length,
      words: (plain.match(/[一-鿿]|[A-Za-z0-9]+/g) || []).length,
      images: q(holder, "img").length
    };
    // images are fetched by the app (with the page as Referer, so hotlink-protected CDNs work) and stored next
    // to the print document; the HTML refers to them by token: src="readit-img-N"
    var imageURLs = [];
    q(holder, "img").forEach(function (img) {
      var u = img.getAttribute("src") || "";
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
    return JSON.stringify(info);
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
    window.__readitExtract = function () { return extract(document, location.href); };
  }
  if (typeof module === "object" && module.exports) module.exports = api;
})();
