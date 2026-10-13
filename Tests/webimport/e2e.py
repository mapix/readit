#!/usr/bin/env python3
"""
End-to-end check of Readit's web import pipeline in headless Chromium.

It mirrors what WebImporter.swift does in WKWebView:
  live page → scroll (lazy images) → Readability + readit-extract.js → download images with Referer
  → local index.html → print A4 PDF
and writes one PDF per URL plus a contact sheet (first pages) to the output directory.

  pip install playwright pillow && python3 -m playwright install chromium
  python3 Tests/webimport/e2e.py                # default set of blogs
  python3 Tests/webimport/e2e.py https://…      # your own URLs
  OUT=/tmp/readit-web python3 Tests/webimport/e2e.py

Exit status is non-zero when an article that should be found is not.
"""
import asyncio, concurrent.futures, json, os, pathlib, re, sys, urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
WEB = ROOT / "Resources" / "web"
JS = (WEB / "Readability.js").read_text() + "\n;\n" + (WEB / "readit-extract.js").read_text()
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
OUT = pathlib.Path(os.environ.get("OUT", "/tmp/readit-webimport"))

DEFAULT = [
    ("jvns", "https://jvns.ca/blog/2024/11/26/terminal-rules/"),                     # plain blog
    ("pg", "https://www.paulgraham.com/greatwork.html"),                              # table layout, no <article>
    ("lilian-math", "https://lilianweng.github.io/posts/2021-07-11-diffusion-models/"),  # MathJax + figures
    ("ruanyf", "https://www.ruanyifeng.com/blog/2019/09/react-hooks.html"),           # Chinese blog
    ("sspai", "https://sspai.com/post/61479"),                                        # Chinese, hotlink-protected images
    ("juejin", "https://juejin.cn/post/7016520448204603423"),                         # JS-rendered SPA
    ("medium", "https://medium.com/@karpathy/software-2-0-a64152b37c35"),             # Medium
    ("cloudflare", "https://blog.cloudflare.com/how-we-built-pingora-the-proxy-that-connects-cloudflare-to-the-internet/"),
    ("github", "https://github.com/mozilla/readability"),                             # README
    ("wikipedia", "https://en.wikipedia.org/wiki/Transformer_(deep_learning_architecture)"),
]

BOILERPLATE_WORDS = re.compile(r"(cookie (settings|policy)|accept all cookies|subscribe to our newsletter|sign up for|share on (twitter|facebook)|leave a comment|related posts)", re.I)


async def one(browser, name, url):
    ctx = await browser.new_context(user_agent=UA, viewport={"width": 1100, "height": 1400}, locale="zh-CN")
    page = await ctx.new_page()
    try:
        await page.goto(url, wait_until="load", timeout=45000)
    except Exception as e:
        print(f"  {name}: load warning {str(e)[:80]}")
    await page.wait_for_timeout(1200)
    await page.evaluate(JS)
    await page.evaluate("window.__readit.primeLazy()")
    info = json.loads(await page.evaluate("window.__readitExtract()"))
    html = info.pop("html", "")
    urls = info.pop("imageURLs", [])
    if not info.get("ok"):
        await ctx.close()
        return {"name": name, "ok": False, **info}

    d = OUT / f"{name}_files"
    d.mkdir(parents=True, exist_ok=True)

    def dl(item):
        i, u = item
        try:
            r = urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent": UA, "Referer": info["url"]}), timeout=25)
            (d / f"img-{i}").write_bytes(r.read())
            return i, f"img-{i}"
        except Exception:
            return i, None

    with concurrent.futures.ThreadPoolExecutor(6) as ex:
        files = dict(ex.map(dl, enumerate(urls)))

    def sub(m):
        i = int(m.group(1))
        return 'src="%s"' % (files.get(i) or urls[i].replace("&", "&amp;").replace('"', "&quot;"))

    html = re.sub(r'src="readit-img-(\d+)"', sub, html).replace("<base href=", '<meta name="readit-source" content=', 1)
    (d / "index.html").write_text(html)
    out = await ctx.new_page()
    await out.goto((d / "index.html").as_uri(), wait_until="load", timeout=45000)
    await out.wait_for_timeout(600)
    pdf = OUT / f"{name}.pdf"
    await out.pdf(path=str(pdf), format="A4", print_background=True,
                  margin={"top": "16mm", "bottom": "17.6mm", "left": "16mm", "right": "16mm"})
    body_text = await out.evaluate("document.querySelector('article').innerText")
    await ctx.close()
    leaks = sorted(set(m.group(0).lower() for m in BOILERPLATE_WORDS.finditer(body_text)))
    return {"name": name, "ok": True, "title": info["title"], "byline": info.get("byline"), "chars": info["textLength"],
            "images": f"{sum(1 for v in files.values() if v)}/{len(urls)}", "leaks": leaks, "pdf": str(pdf)}


def contact_sheet(results):
    try:
        from PIL import Image
        import subprocess
    except ImportError:
        return
    tiles = []
    for r in results:
        if not r.get("ok"):
            continue
        prefix = OUT / f"_thumb_{r['name']}"
        subprocess.run(["pdftoppm", "-r", "40", "-png", "-f", "1", "-l", "1", r["pdf"], str(prefix)], check=False)
        for p in sorted(OUT.glob(f"_thumb_{r['name']}*.png")):
            tiles.append(Image.open(p))
    if not tiles:
        return
    cols = 5
    w, h = max(t.width for t in tiles), max(t.height for t in tiles)
    rows = (len(tiles) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * w, rows * h), "white")
    for i, t in enumerate(tiles):
        sheet.paste(t, ((i % cols) * w, (i // cols) * h))
    sheet.save(OUT / "contact-sheet.png")
    print(f"contact sheet: {OUT / 'contact-sheet.png'}")


async def main():
    from playwright.async_api import async_playwright
    args = sys.argv[1:]
    targets = [(f"url{i}", u) for i, u in enumerate(args)] if args else DEFAULT
    OUT.mkdir(parents=True, exist_ok=True)
    results = []
    async with async_playwright() as pw:
        browser = await pw.chromium.launch()
        for name, url in targets:
            try:
                r = await one(browser, name, url)
            except Exception as e:
                r = {"name": name, "ok": False, "reason": str(e)[:200]}
            results.append(r)
            mark = "PASS" if r.get("ok") and not r.get("leaks") else ("WARN" if r.get("ok") else "FAIL")
            print(f"{mark} {name}: " + json.dumps({k: v for k, v in r.items() if k not in ("name", "pdf")}, ensure_ascii=False))
        await browser.close()
    contact_sheet(results)
    sys.exit(0 if all(r.get("ok") for r in results) else 1)


asyncio.run(main())
