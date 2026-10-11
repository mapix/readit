// Builds a real bilingual PDF: every original page keeps its vector content (embedded, clipped
// into horizontal bands at paragraph boundaries) and the translation is typeset right below each
// paragraph, like Immersive Translate's bilingual layout. The result is an ordinary PDF, so all of
// MarginNote's native highlighting / excerpt / mind-map features work on it.
(function (root) {
  function isCJK(c) { return /[぀-ヿ㐀-鿿가-힯＀-￯　-〿]/.test(c); }
  function norm(x) { return String(x || '').toLowerCase().replace(/[^a-z0-9]/g, ''); }
  function median(a) { a = a.slice().sort(function (x, y) { return x - y; }); return a.length ? a[a.length >> 1] : 10; }

  // break text into lines that fit width (CJK per char, latin per word)
  function wrap(font, text, size, width) {
    var tokens = [], buf = '';
    for (var i = 0; i < text.length; i++) {
      var c = text[i];
      if (c === '\n') { if (buf) tokens.push(buf); buf = ''; tokens.push('\n'); continue; }
      if (isCJK(c)) { if (buf) tokens.push(buf); buf = ''; tokens.push(c); }
      else if (c === ' ') { buf += c; tokens.push(buf); buf = ''; }
      else buf += c;
    }
    if (buf) tokens.push(buf);
    var lines = [], line = '', lw = 0;
    tokens.forEach(function (t) {
      if (t === '\n') { lines.push(line); line = ''; lw = 0; return; }
      var w = font.widthOfTextAtSize(t, size);
      // CJK closing punctuation never starts a line
      if (lw + w > width && line && !/^[，。、；：！？）》」』,.;:!?)]/.test(t)) {
        lines.push(line.replace(/\s+$/, '')); line = t.replace(/^\s+/, ''); lw = font.widthOfTextAtSize(line, size);
        if (lw > width) { // very long token: hard split
          var chunk = '';
          for (var k = 0; k < line.length; k++) { if (font.widthOfTextAtSize(chunk + line[k], size) > width && chunk) { lines.push(chunk); chunk = ''; } chunk += line[k]; }
          line = chunk; lw = font.widthOfTextAtSize(line, size);
        }
      } else { line += t; lw += w; }
    });
    if (line) lines.push(line.replace(/\s+$/, ''));
    return lines;
  }

  function safeText(font, s) {
    // drop characters the subset font cannot draw
    var out = '';
    for (var i = 0; i < s.length; i++) { var c = s[i]; try { font.encodeText(c); out += c; } catch (e) { out += ' '; } }
    return out;
  }

  /**
   * opts: { PDFLib, fontkit, srcBytes, fontBytes, pages: {pageNo: [para...]}, onProgress }
   * para: { x0,x1,y0,y1,h,n,text,tr,translatable } in PDF user space (origin bottom-left of page box)
   */
  async function build(opts) {
    var PDFLib = opts.PDFLib;
    var src = await PDFLib.PDFDocument.load(opts.srcBytes, { ignoreEncryption: true });
    var out = await PDFLib.PDFDocument.create();
    out.registerFontkit(opts.fontkit);
    var font = await out.embedFont(opts.fontBytes, { subset: false });
    var accent = PDFLib.rgb(0.918, 0.298, 0.537), ink = PDFLib.rgb(0.11, 0.11, 0.12);
    var n = src.getPageCount();
    var srcPages = src.getPages();
    for (var pi = 0; pi < n; pi++) {
      var pageNo = pi + 1;
      var sp = srcPages[pi];
      var box = sp.getCropBox ? sp.getCropBox() : sp.getMediaBox();
      var W = box.width, H = box.height, X0 = box.x, Y0 = box.y;
      var paras = (opts.pages[pageNo] || []).map(function (p) {
        // convert to top-down coordinates relative to the crop box
        return { p: p, t: (Y0 + H) - p.y1, b: (Y0 + H) - p.y0, l: p.x0 - X0, r: p.x1 - X0 };
      });
      var trs = paras.filter(function (q) { return q.p.translatable && q.p.tr && norm(q.p.tr) !== norm(q.p.text); });
      if (!trs.length || sp.getRotation().angle) { // nothing to add (or rotated page): copy as is
        var cp = await out.copyPages(src, [pi]); out.addPage(cp[0]);
        if (opts.onProgress) opts.onProgress(pageNo, n);
        continue;
      }
      function valid(y) { for (var i = 0; i < paras.length; i++) { var q = paras[i]; if (q.t < y - 0.8 && q.b > y + 0.8) return false; } return true; }
      var cuts = {};
      trs.forEach(function (q) {
        var cands = paras.map(function (o) { return o.b + 1.5; }).filter(function (c) { return c >= q.b + 1; }).sort(function (a, b) { return a - b; });
        var c = null; for (var i = 0; i < cands.length; i++) if (valid(cands[i])) { c = cands[i]; break; }
        if (c === null) c = H;
        c = Math.min(H, c);
        (cuts[c] = cuts[c] || []).push(q);
      });
      var ys = Object.keys(cuts).map(Number).sort(function (a, b) { return a - b; });
      var hs = []; trs.forEach(function (q) { for (var i = 0; i < Math.min(6, q.p.n); i++) hs.push(q.p.h); });
      var base = median(hs);
      // lay out translation blocks first to know the output page height
      var blocks = ys.map(function (y) {
        var group = cuts[y].sort(function (a, b) { return a.t - b.t; });
        var cols = [];
        group.forEach(function (q) {
          var col = null;
          for (var i = 0; i < cols.length; i++) { var cc = cols[i]; if (Math.min(cc.r, q.r) - Math.max(cc.l, q.l) > 0.3 * Math.min(cc.r - cc.l, q.r - q.l)) { col = cc; break; } }
          if (!col) { col = { l: q.l, r: q.r, items: [] }; cols.push(col); }
          col.l = Math.min(col.l, q.l); col.r = Math.max(col.r, q.r); col.items.push(q);
        });
        var height = 0;
        cols.forEach(function (col) {
          var cy = 2;
          col.items.forEach(function (q) {
            var heading = q.p.h > base * 1.2 && q.p.n <= 3;
            var size = Math.max(5.5, Math.min(heading ? 20 : 14, q.p.h * (heading ? 0.8 : 0.74)));
            var pc = (q.l + q.r) / 2;
            var centered = q.p.n <= 3 && Math.abs(pc - W / 2) < W * 0.03 && (q.r - q.l) < W * 0.72;
            var indent = centered ? 0 : Math.max(2.2, size * 0.45);
            var width = Math.max(30, col.r - col.l - indent);
            var lines = wrap(font, safeText(font, q.p.tr), size, width);
            var lh = size * (heading ? 1.32 : 1.48);
            q.lay = { y: cy, size: size, lines: lines, lh: lh, centered: centered, indent: indent, heading: heading, width: width };
            cy += lines.length * lh + size * 0.35;
          });
          col.height = cy + 1.5;
          height = Math.max(height, col.height);
        });
        return { y: y, cols: cols, height: height };
      });
      var extra = blocks.reduce(function (a, b) { return a + b.height; }, 0);
      var page = out.addPage([W, H + extra]);
      var OH = H + extra;
      var cur = 0, y0 = 0;
      async function band(a, b) {
        if (b - a < 0.3) return;
        var emb = await out.embedPage(sp, { left: X0, right: X0 + W, top: Y0 + H - a, bottom: Y0 + H - b });
        page.drawPage(emb, { x: 0, y: OH - cur - (b - a), width: W, height: b - a });
        cur += b - a;
      }
      for (var bi = 0; bi < blocks.length; bi++) {
        var blk = blocks[bi];
        await band(y0, blk.y); y0 = blk.y;
        blk.cols.forEach(function (col) {
          col.items.forEach(function (q) {
            var L = q.lay, topY = OH - cur - L.y;
            if (!L.centered && !L.heading) {
              page.drawRectangle({ x: col.l, y: topY - L.lines.length * L.lh + L.lh * 0.12, width: 0.9, height: L.lines.length * L.lh - L.lh * 0.08, color: accent, opacity: 0.75 });
            }
            L.lines.forEach(function (ln, k) {
              var x = col.l + L.indent;
              if (L.centered) x = col.l + (col.r - col.l - font.widthOfTextAtSize(ln, L.size)) / 2;
              page.drawText(ln, { x: x, y: topY - (k + 1) * L.lh + (L.lh - L.size) * 0.62, size: L.size, font: font, color: ink });
            });
          });
        });
        cur += blk.height;
      }
      await band(y0, H);
      if (opts.onProgress) opts.onProgress(pageNo, n);
    }
    out.setTitle((opts.title || 'document') + ' (双语)');
    out.setProducer('MarginNote Immersive Translate');
    return await out.save({ useObjectStreams: true });
  }

  root.IMTBilingual = { build: build, wrap: wrap };
  if (typeof module !== 'undefined') module.exports = root.IMTBilingual;
})(typeof window !== 'undefined' ? window : globalThis);
