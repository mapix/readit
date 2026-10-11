// Immersive Translate for MarginNote 3
// In-document bilingual translation of PDF pages, side-by-side panel, selection translation.
JSB.newAddon = function (mainPath) {
  var UD = NSUserDefaults.standardUserDefaults();
  var TAG_MIN = 77000, TAG_MAX = 77999, TAG_KEY = 77000, TAG_CHIP = 77001;
  var DEFAULTS = {
    engine: 'claude',            // claude | google
    baseURL: 'https://api.anthropic.com',
    apiKey: '',
    model: 'claude-haiku-5-5',
    targetLang: '简体中文',
    mode: 'cover',               // cover: translation covers paragraph | bilingual: original visible, tap badge to show
    auto: true,
    prefetch: true,
    fontScale: 1.0,
    view: 'reflow'               // reflow: full bilingual reading view | side: side panel + in-page overlay
  };

  // ---------- utils ----------
  var LOGS = [];
  function log(s) { LOGS.push(new Date().toISOString().slice(11, 19) + ' ' + s); if (LOGS.length > 200) LOGS.shift(); UD.setObjectForKey(LOGS.join('\n'), 'imt_debug_log'); }
  function cfg(k) { var v = UD.objectForKey('imt_' + k); return (v === null || v === undefined) ? DEFAULTS[k] : v; }
  function setCfg(k, v) { UD.setObjectForKey(v, 'imt_' + k); }
  function allCfg() { var o = {}; for (var k in DEFAULTS) o[k] = cfg(k); return o; }
  function later(sec, fn) { return NSTimer.scheduledTimerWithTimeInterval(sec, false, fn); }
  function hud(self, text) { try { Application.sharedInstance().showHUD(text, self.window, 1.5); } catch (e) {} }
  function rgba(r, g, b, a) { return UIColor.colorWithRedGreenBlueAlpha(r / 255, g / 255, b / 255, a); }

  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function b64dec(s) { var o = '', bits = 0, n = 0; for (var i = 0; i < s.length; i++) { var v = B64.indexOf(s[i]); if (v < 0) continue; n = ((n << 6) | v) & 0xffffff; bits += 6; if (bits >= 8) { bits -= 8; o += String.fromCharCode((n >> bits) & 255); } } return o; }
  // char rects come back as opaque NSValue(CGRect); decode via keyed archive ("{{x, y}, {w, h}}")
  function rectOf(v) {
    try {
      var s = b64dec(NSKeyedArchiver.archivedDataWithRootObject(v).base64Encoding());
      var m = s.match(/\{\{([-\d.e]+), ([-\d.e]+)\}, \{([-\d.e]+), ([-\d.e]+)\}\}/);
      return m ? { x: +m[1], y: +m[2], w: +m[3], h: +m[4] } : null;
    } catch (e) { return null; }
  }

  // ---------- storage ----------
  var cacheDir = mainPath + '/cache';
  try { NSFileManager.defaultManager().createDirectoryAtPathWithIntermediateDirectoriesAttributes(cacheDir, true, null); } catch (e) {}
  var memCache = {};   // md5 -> { 'lang|text': translation }
  function cacheFor(md5) {
    if (memCache[md5]) return memCache[md5];
    var c = {};
    try { var d = NSData.dataWithContentsOfFile(cacheDir + '/' + md5 + '.json'); if (d) c = NSJSONSerialization.JSONObjectWithDataOptions(d, 0) || {}; } catch (e) {}
    memCache[md5] = c; return c;
  }
  var saveTimers = {};
  function saveCache(md5) {
    if (saveTimers[md5]) return;
    saveTimers[md5] = later(2, function () {
      saveTimers[md5] = null;
      try { NSJSONSerialization.dataWithJSONObjectOptions(memCache[md5], 0).writeToFileAtomically(cacheDir + '/' + md5 + '.json', true); } catch (e) { log('save err ' + e); }
    });
  }

  // ---------- page size ----------
  var mediaBoxes = {};  // md5 -> [[w,h],...] unique
  function pageSizeFor(doc, md5, aspect) {
    if (!mediaBoxes[md5]) {
      var boxes = [];
      boxes.push([612, 792], [595.276, 841.89], [419.53, 595.28], [792, 612], [841.89, 595.276]);
      mediaBoxes[md5] = boxes;
    }
    var best = null, bd = 1e9;
    mediaBoxes[md5].forEach(function (b, i) { var dd = Math.abs(b[1] / b[0] - aspect) + i * 1e-4; if (dd < bd) { bd = dd; best = b; } });
    return best;
  }

  // ---------- layout analysis: lines -> paragraphs ----------
  var pageCache = {}; // md5|pageNo -> paragraphs
  function isCJK(c) { return /[぀-ヿ㐀-鿿가-힯]/.test(c); }
  function extractParagraphs(doc, md5, pageNo) {
    var key = md5 + '|' + pageNo;
    if (pageCache[key]) return pageCache[key];
    var t = doc.textContentsForPageNo(pageNo);
    if (!t || !t.length) { pageCache[key] = []; return []; }
    var lines = [];
    for (var i = 0; i < t.length; i++) {
      var ln = t[i]; if (!ln || !ln.length) continue;
      var s = '', a = -1, z = -1;
      for (var j = 0; j < ln.length; j++) { var ch = String.fromCharCode(ln[j].char); s += ch; if (!/\s/.test(ch)) { if (a < 0) a = j; z = j; } }
      if (a < 0) continue;
      var ra = rectOf(ln[a].rect), rz = rectOf(ln[z].rect), rm = rectOf(ln[Math.floor((a + z) / 2)].rect);
      if (!ra || !rz) continue;
      var h = Math.max(ra.h, rz.h, rm ? rm.h : 0);
      var bottom = Math.min(ra.y, rz.y, rm ? rm.y : 1e9);
      lines.push({ text: s.trim(), x0: Math.min(ra.x, rz.x), x1: Math.max(rz.x + rz.w, ra.x + ra.w), y0: bottom, y1: bottom + h, h: h });
    }
    var paras = [], cur = null;
    function close() { if (cur) paras.push(cur); cur = null; }
    lines.forEach(function (L) {
      if (cur) {
        var last = cur.lines[cur.lines.length - 1];
        var hRef = cur.h;
        var gap = last.y0 - L.y1;                    // PDF coords: next line lies below
        var ov = Math.min(L.x1, cur.x1) - Math.max(L.x0, cur.x0);
        var sameSize = Math.abs(L.h - hRef) <= 0.35 * hRef;
        var lastShort = cur.lines.length >= 1 && last.x1 < cur.x1 - 2.5 * hRef && cur.lines.length > 1;
        var ok = sameSize && gap > -0.6 * hRef && gap < 0.85 * hRef && ov > 0.3 * Math.min(L.x1 - L.x0, cur.x1 - cur.x0) && !lastShort;
        if (!ok) close();
      }
      if (!cur) { cur = { lines: [L], x0: L.x0, x1: L.x1, y0: L.y0, y1: L.y1, h: L.h, text: L.text }; return; }
      var prev = cur.text;
      if (/[a-z]-$/.test(prev) && /^[a-z]/.test(L.text)) cur.text = prev.slice(0, -1) + L.text;
      else if (isCJK(prev.slice(-1)) || isCJK(L.text[0])) cur.text = prev + L.text;
      else cur.text = prev + ' ' + L.text;
      cur.lines.push(L);
      cur.x0 = Math.min(cur.x0, L.x0); cur.x1 = Math.max(cur.x1, L.x1); cur.y0 = Math.min(cur.y0, L.y0); cur.y1 = Math.max(cur.y1, L.y1);
    });
    close();
    var out = [];
    paras.forEach(function (p, i) {
      var words = (p.text.match(/[A-Za-zÀ-ɏ]{2,}/g) || []).length;
      var cjk = (p.text.match(/[㐀-鿿]/g) || []).length;
      var translatable = words >= 2 && cjk < p.text.length * 0.3 && !/^[\w.+-]+@[\w.-]+$/.test(p.text);
      out.push({ id: i, text: p.text, x0: p.x0, x1: p.x1, y0: p.y0, y1: p.y1, h: p.h, n: p.lines.length, translatable: translatable });
    });
    pageCache[key] = out;
    return out;
  }

  // ---------- translation engines ----------
  function httpJSON(url, method, headers, body, cb) {
    var req = NSMutableURLRequest.requestWithURL(NSURL.URLWithString(url));
    req.setHTTPMethod(method);
    req.setTimeoutInterval(90);
    for (var h in headers) req.setValueForHTTPHeaderField(headers[h], h);
    if (body) req.setHTTPBody(NSJSONSerialization.dataWithJSONObjectOptions(body, 0));
    NSURLConnection.sendAsynchronousRequestQueueCompletionHandler(req, NSOperationQueue.mainQueue(), function (res, data, err) {
      if (!data || !data.length()) { cb('网络错误' + (err ? ': ' + err.localizedDescription : ''), null); return; }
      var j = null;
      try { j = NSJSONSerialization.JSONObjectWithDataOptions(data, 0); } catch (e) {}
      var code = res ? res.statusCode() : 0;
      if (!j) { cb('响应解析失败 (HTTP ' + code + ')', null); return; }
      if (code >= 400) { cb('HTTP ' + code + ': ' + ((j.error && (j.error.message || j.error.type)) || JSON.stringify(j).slice(0, 200)), null); return; }
      cb(null, j);
    });
  }

  function claudeTranslate(texts, cb) {
    var lang = cfg('targetLang');
    var key = cfg('apiKey');
    if (!key) { cb('未设置 API Key（在面板 ⚙︎ 设置中填写）'); return; }
    var sys = 'You are a professional academic translator. Translate every item of the JSON array the user sends into ' + lang + '.\n' +
      'Rules: keep the meaning precise and fluent, idiomatic ' + lang + '; keep person names, emails, affiliations, math, formulas, variable names, citations like [12], URLs, code and proper nouns (model names, datasets) as is; ' +
      'PDF extraction may break words or include stray symbols, fix them silently; never add explanations.\n' +
      'Output ONLY a JSON array of strings with exactly the same length and order as the input.';
    var base = String(cfg('baseURL')).replace(/\/+$/, '');
    httpJSON(base + '/v1/messages', 'POST', {
      'Content-Type': 'application/json', 'anthropic-version': '2023-06-01', 'x-api-key': key, 'Authorization': 'Bearer ' + key
    }, { model: cfg('model'), max_tokens: 8192, system: sys, messages: [{ role: 'user', content: JSON.stringify(texts) }] }, function (err, j) {
      if (err) { cb(err); return; }
      var txt = '';
      (j.content || []).forEach(function (c) { if (c.type === 'text') txt += c.text; });
      txt = txt.trim().replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '');
      var arr = null;
      try { arr = JSON.parse(txt); } catch (e) { var m = txt.match(/\[[\s\S]*\]/); if (m) try { arr = JSON.parse(m[0]); } catch (e2) {} }
      if (!arr || arr.length !== texts.length) {
        if (texts.length === 1) { cb(null, [txt]); return; }
        log('batch mismatch, splitting ' + texts.length);
        var mid = Math.ceil(texts.length / 2), res = [], pending = 2, failed = null;
        [[0, texts.slice(0, mid)], [mid, texts.slice(mid)]].forEach(function (part) {
          claudeTranslate(part[1], function (e, r) { if (e) failed = e; else for (var i = 0; i < r.length; i++) res[part[0] + i] = r[i]; if (--pending === 0) cb(failed, failed ? null : res); });
        });
        return;
      }
      cb(null, arr.map(String));
    });
  }

  function googleLang() { var l = cfg('targetLang'); return /繁/.test(l) ? 'zh-TW' : /中/.test(l) ? 'zh-CN' : /日/.test(l) ? 'ja' : /韩|한/.test(l) ? 'ko' : /英|English/i.test(l) ? 'en' : 'zh-CN'; }
  function googleTranslate(texts, cb) {
    var res = [], pending = texts.length, failed = null;
    texts.forEach(function (t, i) {
      httpJSON('https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=' + googleLang() + '&dt=t&q=' + encodeURIComponent(t), 'GET', {}, null, function (e, j) {
        if (e) failed = e; else res[i] = (j[0] || []).map(function (s) { return s[0]; }).join('');
        if (--pending === 0) cb(failed, failed ? null : res);
      });
    });
  }
  function engineTranslate(texts, cb) { (cfg('engine') === 'google' ? googleTranslate : claudeTranslate)(texts, cb); }
  function ckey(text) { return cfg('engine') + '|' + cfg('targetLang') + '|' + text; }

  // ---------- page translation jobs ----------
  var jobs = {};   // md5|pageNo -> {state:'running'|'done'|'error', err}
  function translatePage(self, ctx, pageNo, force, done) {
    var key = ctx.md5 + '|' + pageNo;
    if (jobs[key] && jobs[key].state === 'running') return;
    var paras = extractParagraphs(ctx.doc, ctx.md5, pageNo);
    var cache = cacheFor(ctx.md5);
    var todo = paras.filter(function (p) { return p.translatable && (force || !cache[ckey(p.text)]); });
    if (force) todo.forEach(function (p) { delete cache[ckey(p.text)]; });
    if (!todo.length) { jobs[key] = { state: 'done' }; if (done) done(); return; }
    jobs[key] = { state: 'running', total: todo.length, finished: 0 };
    log('translate page ' + pageNo + ' paras ' + todo.length);
    self.refreshUI();
    // batch by size, run batches concurrently and render progressively
    var batches = [], b = [], size = 0;
    todo.forEach(function (p) { if (b.length && (size + p.text.length > 3500 || b.length >= 20)) { batches.push(b); b = []; size = 0; } b.push(p); size += p.text.length; });
    if (b.length) batches.push(b);
    var pending = batches.length, lastErr = null;
    batches.forEach(function (batch) {
      engineTranslate(batch.map(function (p) { return p.text; }), function (err, arr) {
        if (err) { lastErr = err; log('translate err ' + err); }
        else { batch.forEach(function (p, i) { cache[ckey(p.text)] = arr[i]; }); saveCache(ctx.md5); jobs[key].finished += batch.length; }
        log('batch done p' + pageNo + ' ' + (err || 'ok'));
        if (--pending === 0) { jobs[key] = lastErr ? { state: 'error', err: lastErr } : { state: 'done' }; if (lastErr) hud(self, '翻译失败：' + lastErr); if (done) done(); }
        self.invalidate(); self.refreshUI(); self.sendPage(ctx, pageNo);
      });
    });
  }

  // ---------- reader context ----------
  function readerCtx(self) {
    try {
      var sc = Application.sharedInstance().studyController(self.window);
      if (!sc) return null;
      var dc = sc.readerController.currentDocumentController;
      if (!dc) return null;
      var doc = dc.document;
      if (!doc || !dc.docMd5) return null;
      return { sc: sc, dc: dc, doc: doc, md5: String(dc.docMd5), pageNo: dc.currPageNo, pageCount: doc.pageCount };
    } catch (e) { return null; }
  }
  function pageViews(dc) {
    var out = [];
    (function walk(v, d) { if (d > 7 || !v) return; var ss = v.subviews; if (!ss) return; for (var i = 0; i < ss.length; i++) { var s = String(ss[i]); if (s.indexOf('PDFPageView') >= 0) out.push(ss[i]); else walk(ss[i], d + 1); } })(dc.view, 0);
    return out;
  }
  function clearOverlays(pv) {
    var ss = pv.subviews; for (var i = ss.length - 1; i >= 0; i--) { var t = ss[i].tag; if (t >= TAG_MIN && t <= TAG_MAX) ss[i].removeFromSuperview(); }
  }

  // ---------- in-page overlays ----------
  var userToggled = {};  // md5|page|id -> bool (shown state override)
  var cjkFont = null;
  function font(size, bold) {
    var f = null;
    try { f = UIFont.fontWithNameSize(bold ? 'PingFangSC-Medium' : 'PingFangSC-Regular', size); } catch (e) {}
    return f || UIFont.systemFontOfSize(size);
  }
  function fitLabel(label, w, h, startSize) {
    var size = Math.min(startSize, 22), minSize = Math.max(4.5, startSize * 0.45);
    for (var k = 0; k < 24; k++) {
      label.font = font(size);
      var fit = null;
      try { fit = label.sizeThatFits({ width: w, height: 100000 }); } catch (e) {}
      var fh = fit && fit.height ? fit.height : estimateHeight(label.text, w, size);
      if (fh <= h + 0.5 || size <= minSize) break;
      size = Math.max(minSize, size * Math.max(0.82, Math.sqrt(h / fh)));
    }
    return size;
  }
  function estimateHeight(text, w, size) {
    var units = 0; for (var i = 0; i < text.length; i++) units += isCJK(text[i]) || /[，。：；！？（）、]/.test(text[i]) ? 1 : 0.55;
    return Math.ceil(units * size / Math.max(10, w)) * size * 1.35;
  }

  function renderPage(self, ctx, pv, pageNo, scale, pageH, modeKey) {
    clearOverlays(pv);
    var keyLabel = new UILabel({ x: 0, y: 0, width: 1, height: 1 });
    keyLabel.tag = TAG_KEY; keyLabel.hidden = true; keyLabel.text = modeKey; keyLabel.userInteractionEnabled = false;
    pv.addSubview(keyLabel);
    var paras = extractParagraphs(ctx.doc, ctx.md5, pageNo);
    var cache = cacheFor(ctx.md5);
    var mode = cfg('mode');
    var job = jobs[ctx.md5 + '|' + pageNo];
    var tagN = 2;
    paras.forEach(function (p) {
      if (!p.translatable) return;
      var tr = cache[ckey(p.text)];
      var pad = 1.5;
      var x = (p.x0 - pad) * scale, y = (pageH - p.y1 - pad) * scale, w = (p.x1 - p.x0 + 2 * pad) * scale, h = (p.y1 - p.y0 + 2 * pad) * scale;
      var uk = ctx.md5 + '|' + pageNo + '|' + p.id;
      if (!tr) {
        if (job && job.state === 'running') {
          // loading shimmer bar at paragraph left edge (Immersive-style "translating" hint)
          var bar = new UIView({ x: Math.max(0, x - 6), y: y, width: 3, height: h });
          bar.tag = TAG_MIN + (tagN++); bar.backgroundColor = rgba(234, 76, 137, 0.55); bar.userInteractionEnabled = false;
          pv.addSubview(bar);
        }
        return;
      }
      var shown = userToggled[uk] !== undefined ? userToggled[uk] : (mode === 'cover');
      // translated block
      var box = new UIView({ x: x, y: y, width: w, height: h });
      box.tag = TAG_MIN + (tagN++);
      box.backgroundColor = rgba(255, 253, 246, 0.985);
      box.layer.cornerRadius = 2;
      box.layer.borderWidth = 0.5; box.layer.borderColor = rgba(234, 76, 137, 0.28).CGColor;
      var lab = new UILabel({ x: 2, y: 1, width: w - 4, height: h - 2 });
      lab.numberOfLines = 0; lab.text = tr; lab.textColor = rgba(28, 28, 30, 1);
      lab.backgroundColor = UIColor.clearColor();
      lab.userInteractionEnabled = false;
      fitLabel(lab, w - 4, h - 2, p.h * scale * 0.86 * cfg('fontScale'));
      lab.lineBreakMode = 0;
      try {
        var fit = lab.sizeThatFits({ width: w - 4, height: 100000 });
        if (fit && fit.height) {
          lab.frame = { x: 2, y: 1, width: w - 4, height: Math.max(fit.height, 1) };
          if (fit.height > h - 2) { h = fit.height + 2; box.frame = { x: x, y: y, width: w, height: h }; }
        }
      } catch (e) {}
      box.addSubview(lab);
      box.userInteractionEnabled = true;
      box.addGestureRecognizer(new UITapGestureRecognizer(self, 'onBlockTap:'));
      box.hidden = !shown;
      pv.addSubview(box);
      // badge (tap to toggle this paragraph between original / translation)
      var bs = Math.max(10, Math.min(16, p.h * scale * 0.9));
      var bx = x - bs - 2; if (bx < 0) bx = Math.max(0, x + w - bs);
      var badge = new UILabel({ x: bx, y: y, width: bs, height: bs });
      badge.tag = TAG_MIN + (tagN++);
      badge.text = '译'; badge.textAlignment = 1; badge.font = font(bs * 0.62, true);
      badge.textColor = UIColor.whiteColor();
      badge.backgroundColor = shown ? rgba(234, 76, 137, 0.85) : rgba(120, 120, 128, 0.55);
      badge.layer.cornerRadius = bs / 2; badge.clipsToBounds = true;
      badge.userInteractionEnabled = true;
      badge.addGestureRecognizer(new UITapGestureRecognizer(self, 'onBadgeTap:'));
      pv.addSubview(badge);
      self.blockMap[box.tag + '@' + pageNo] = { uk: uk };
      self.blockMap[badge.tag + '@' + pageNo] = { uk: uk };
    });
    if (job && job.state === 'running') {
      var chip = new UILabel({ x: pv.bounds.width - 128, y: 8, width: 118, height: 22 });
      chip.tag = TAG_CHIP; chip.text = '  ✦ 翻译中 ' + (job.finished || 0) + '/' + job.total; chip.font = font(11, true);
      chip.textColor = UIColor.whiteColor(); chip.backgroundColor = rgba(234, 76, 137, 0.9);
      chip.layer.cornerRadius = 11; chip.clipsToBounds = true; chip.userInteractionEnabled = false;
      pv.addSubview(chip);
    }
  }

  // ---------- side panel (bilingual, paragraph by paragraph) ----------
  var PANEL_W = 400;

  var M = {
    invalidate: function () { this.version++; },
    tick: function () {
      var self = this;
      try { self.tick2(); } catch (e) { if (!self.tickErr) log('tick err ' + e + ' line ' + e.line); self.tickErr = 1; }
    },
    tick2: function () {
      var self = this;
      var ctx = readerCtx(self);
      if (!ctx) { if (!self.noCtx) log('no ctx'); self.noCtx = 1; return; }
      var pvs = pageViews(ctx.dc);
      if (!self.seenCtx) { self.seenCtx = 1; log('ctx page ' + ctx.pageNo + ' pvs ' + pvs.length + ' enabled ' + self.enabled); }
      if (!self.enabled) { pvs.forEach(clearOverlays); return; }
      // auto translate current page (+ prefetch next)
      if (cfg('auto')) {
        var cur = ctx.pageNo;
        var j = jobs[ctx.md5 + '|' + cur];
        if (!j) translatePage(self, ctx, cur, false, function () {
          if (cfg('prefetch') && cur + 1 <= ctx.pageCount && !jobs[ctx.md5 + '|' + (cur + 1)]) translatePage(self, ctx, cur + 1, false, function () {
            if (cur + 2 <= ctx.pageCount && !jobs[ctx.md5 + '|' + (cur + 2)]) translatePage(self, ctx, cur + 2, false);
          });
        });
      }
      var modeKey = [self.version, cfg('mode'), cfg('engine'), cfg('targetLang'), cfg('fontScale')].join('|');
      pvs.forEach(function (pv) {
        try {
          var sup = pv.superview, sf = sup.frame, b = pv.bounds;
          if (!b.width || !b.height) return;
          var idx = Math.round(sf.y / sf.height) + Math.round(sf.x / Math.max(1, sf.width) * 0);
          var pageNo = ctx.dc.pageNoFromIndex(idx);
          if (!pageNo) return;
          var size = pageSizeFor(ctx.doc, ctx.md5, b.height / b.width);
          var scale = b.width / size[0];
          var key = modeKey + '|' + pageNo + '|' + Math.round(b.width);
          var kl = pv.viewWithTag(TAG_KEY);
          if (kl && String(kl.text) === key) return;
          renderPage(self, ctx, pv, pageNo, scale, size[1], key);
          // auto translate any visible page too
          if (cfg('auto') && !jobs[ctx.md5 + '|' + pageNo]) translatePage(self, ctx, pageNo, false);
        } catch (e) { log('render err ' + e + ' ' + e.line); }
      });
      if (self.panelOpen && (self.lastPage !== ctx.md5 + '|' + ctx.pageNo)) { self.lastPage = ctx.md5 + '|' + ctx.pageNo; self.refreshUI(); }
      if (self.panelOpen) self.pollPanel();
    },
    toggleBlock: function (v) {
      var ctx = readerCtx(this); if (!ctx) return;
      var pv = v.superview;
      var kl = pv.viewWithTag(TAG_KEY); if (!kl) return;
      var parts = String(kl.text).split('|'); var pageNo = +parts[parts.length - 2];
      var info = this.blockMap[v.tag + '@' + pageNo]; if (!info) return;
      var mode = cfg('mode');
      var curShown = userToggled[info.uk] !== undefined ? userToggled[info.uk] : (mode === 'cover');
      userToggled[info.uk] = !curShown;
      this.invalidate();
    },

    // ---------- selection translation ----------,
    translateSelection: function (text) {
      var self = this;
      self.showSelCard(text, '翻译中…');
      var md5 = 'selection';
      var c = cacheFor(md5);
      if (c[ckey(text)]) { self.showSelCard(text, c[ckey(text)]); return; }
      engineTranslate([text], function (err, arr) {
        if (err) { self.showSelCard(text, '⚠️ ' + err); return; }
        c[ckey(text)] = arr[0]; saveCache(md5);
        self.showSelCard(text, arr[0]);
      });
    },
    showSelCard: function (orig, tr) {
      var sc = Application.sharedInstance().studyController(this.window);
      var root = sc.view;
      if (this.panelOpen && this.panel) { this.panelSend({ type: 'selection', orig: orig, tr: tr }); return; }
      var W = Math.min(460, root.bounds.width - 40);
      if (!this.selCard) {
        var card = new UIView({ x: 0, y: 0, width: W, height: 80 });
        card.backgroundColor = rgba(255, 253, 248, 0.98);
        card.layer.cornerRadius = 10; card.layer.borderWidth = 1; card.layer.borderColor = rgba(234, 76, 137, 0.45).CGColor;
        card.layer.shadowOpacity = 0.18; card.layer.shadowRadius = 8; card.layer.shadowOffset = { width: 0, height: 3 };
        var lab = new UILabel({ x: 14, y: 10, width: W - 28, height: 60 });
        lab.numberOfLines = 0; lab.tag = 1; card.addSubview(lab);
        card.addGestureRecognizer(new UITapGestureRecognizer(M.obj, 'onSelCardTap:'));
        this.selCard = card;
      }
      var card = this.selCard, lab = card.viewWithTag(1);
      lab.font = font(14); lab.textColor = rgba(28, 28, 30, 1);
      lab.text = tr + '\n\n' + (orig.length > 300 ? orig.slice(0, 300) + '…' : orig);
      var fit = lab.sizeThatFits({ width: W - 28, height: 10000 });
      var H = Math.min(Math.max(40, fit.height), root.bounds.height * 0.5);
      lab.frame = { x: 14, y: 10, width: W - 28, height: H };
      card.frame = { x: (root.bounds.width - W) / 2, y: root.bounds.height - H - 20 - 60, width: W, height: H + 20 };
      if (!card.superview) root.addSubview(card);
      root.bringSubviewToFront(card);
    },
    openPanel: function () {
      var sc = Application.sharedInstance().studyController(this.window);
      var root = sc.view;
      if (!this.panel) {
        var wv = new UIWebView({ x: 0, y: 0, width: PANEL_W, height: 600 });
        wv.backgroundColor = UIColor.clearColor();
        wv.opaque = false;
        wv.layer.cornerRadius = 12; wv.layer.masksToBounds = true;
        wv.layer.borderWidth = 1; wv.layer.borderColor = rgba(0, 0, 0, 0.12).CGColor;
        wv.loadFileURLAllowingReadAccessToURL(NSURL.fileURLWithPath(mainPath + '/panel.html'), NSURL.fileURLWithPath(mainPath));
        this.panel = wv;
        this.panelReady = false;
      }
      this.layoutPanel();
      root.addSubview(this.panel);
      this.panelOpen = true;
      this.lastPage = null;
    },
    layoutPanel: function () {
      if (!this.panel) return;
      var root = Application.sharedInstance().studyController(this.window).view;
      var b = root.bounds;
      if (cfg('view') === 'reflow') {
        var ctx = readerCtx(this), r = null;
        try { if (ctx) r = ctx.dc.view.convertRectToView(ctx.dc.view.bounds, root); } catch (e) {}
        if (!r || r.width < 200) r = { x: 0, y: 44, width: b.width, height: b.height - 44 };
        if (!this.loggedR) { this.loggedR = 1; log('reader rect ' + JSON.stringify(r) + ' root ' + JSON.stringify(b)); }
        this.panel.frame = { x: r.x, y: r.y, width: r.width, height: r.height };
        this.panel.layer.cornerRadius = 0;
      } else {
        var w = Math.min(PANEL_W, b.width * 0.42);
        this.panel.frame = { x: b.width - w - 12, y: 64, width: w, height: b.height - 64 - 40 };
        this.panel.layer.cornerRadius = 12;
      }
    },
    closePanel: function () { if (this.panel) this.panel.removeFromSuperview(); this.panelOpen = false; },
    panelSend: function (msg) {
      if (!this.panel) return;
      var js = 'window.IMT && IMT.recv(' + JSON.stringify(JSON.stringify(msg)) + ')';
      this.panel.evaluateJavaScript(js, function () {});
    },
    pollPanel: function () {
      var self = this;
      if (!self.panel || self.polling) return;
      self.polling = true;
      self.layoutPanel();
      self.panel.evaluateJavaScript('window.IMT ? IMT.drain() : "__notready"', function (r) {
        self.polling = false;
        if (r === '__notready' || r === null || r === undefined) return;
        if (!self.panelReady && UD.objectForKey('imt_autobuild')) { UD.removeObjectForKey('imt_autobuild'); later(4, function () { var c = readerCtx(self); if (c) self.makeBilingual(c); }); }
        if (!self.panelReady) { self.panelReady = true; self.docSent = null; self.fontSent = false; self.refreshUI(); }
        r = String(r); if (!r) return;
        r.split('\n').forEach(function (line) { if (!line) return; try { self.onPanelMsg(JSON.parse(line)); } catch (e) { log('panel msg err ' + e); } });
      });
    },
    onPanelMsg: function (m) {
      var ctx = readerCtx(this);
      switch (m.type) {
        case 'ready': this.panelReady = true; this.docSent = null; this.fontSent = false; this.refreshUI(); break;
        case 'close': this.closePanel(); break;
        case 'translatePage': if (ctx) translatePage(this, ctx, ctx.pageNo, !!m.force); break;
        case 'translateRange':
          if (ctx) { var self = this, p = ctx.pageNo, end = Math.min(ctx.pageCount, p + (m.count || 5) - 1);
            (function next() { if (p > end) { hud(self, '已完成 ' + (m.count || 5) + ' 页翻译'); return; } var cp = p++; translatePage(self, ctx, cp, false, next); })(); }
          break;
        case 'setCfg':
          for (var k in m.cfg) setCfg(k, m.cfg[k]);
          if (m.cfg.view === 'side') { this.closePanel(); hud(this, '原版 PDF 页内翻译；点工具栏「译」回到双语对照'); }
          if (m.reset) userToggled = {};
          this.invalidate(); this.refreshUI(); break;
        case 'showAll': case 'hideAll':
          if (ctx) { var paras = extractParagraphs(ctx.doc, ctx.md5, ctx.pageNo); paras.forEach(function (pp) { userToggled[ctx.md5 + '|' + ctx.pageNo + '|' + pp.id] = m.type === 'showAll'; }); }
          this.invalidate(); break;
        case 'toggleOverlay':
          if (!ctx) break; var key = ctx.md5 + '|' + ctx.pageNo + '|' + m.id;
          var cur = userToggled[key] !== undefined ? userToggled[key] : cfg('mode') === 'cover';
          userToggled[key] = !cur; this.invalidate(); break;
        case 'clearCache':
          if (ctx) { memCache[ctx.md5] = {}; saveCache(ctx.md5); for (var jk in jobs) if (jk.indexOf(ctx.md5) === 0) delete jobs[jk]; }
          this.invalidate(); this.refreshUI(); break;
        case 'gotoPage': if (ctx) { try { ctx.dc.setPageAtIndex(ctx.dc.indexFromPageNo(m.page)); } catch (e) { log('goto err ' + e); } } break;
        case 'need':
          if (ctx) { var me = this; (m.pages || []).forEach(function (n) { if (n < 1 || n > ctx.pageCount) return; me.sendPage(ctx, n); if (cfg('auto') && !jobs[ctx.md5 + '|' + n]) translatePage(me, ctx, n, false); }); }
          break;
        case 'retranslate': if (ctx) translatePage(this, ctx, m.page, true); break;
        case 'makeBilingual': if (ctx) this.makeBilingual(ctx); break;
        case 'outChunk': (this.outChunks = this.outChunks || []).push(m.data); break;
        case 'outEnd': this.saveBilingual(m.name); break;
        case 'buildFailed': this.building = null; hud(this, '生成失败：' + m.err); break;
        case 'copy': UIPasteboard.generalPasteboard().string = m.text; hud(this, '已复制'); break;
      }
    },
    makeBilingual: function (ctx) {
      var self = this;
      if (self.building) { hud(self, '双语 PDF 正在生成中…'); return; }
      self.building = { md5: ctx.md5, done: 0 };
      var total = ctx.pageCount, next = 1, active = 0, finished = 0;
      self.panelSend({ type: 'buildProgress', stage: 'translate', done: 0, total: total });
      function pump() {
        while (active < 3 && next <= total) {
          (function (pn) {
            active++;
            var j = jobs[ctx.md5 + '|' + pn];
            var fin = function () { active--; finished++; self.panelSend({ type: 'buildProgress', stage: 'translate', done: finished, total: total }); if (finished === total) assemble(); else pump(); };
            if (j && j.state === 'done') { var c = cacheFor(ctx.md5), miss = extractParagraphs(ctx.doc, ctx.md5, pn).some(function (p) { return p.translatable && !c[ckey(p.text)]; }); if (!miss) { fin(); return; } delete jobs[ctx.md5 + '|' + pn]; }
            if (j && j.state === 'running') { var w = NSTimer.scheduledTimerWithTimeInterval(0.5, true, function () { var jj = jobs[ctx.md5 + '|' + pn]; if (!jj || jj.state !== 'running') { w.invalidate(); fin(); } }); return; }
            translatePage(self, ctx, pn, false, fin);
          })(next++);
        }
      }
      function assemble() {
        var cache = cacheFor(ctx.md5), pages = {};
        for (var pn = 1; pn <= total; pn++) {
          pages[pn] = extractParagraphs(ctx.doc, ctx.md5, pn).map(function (p) { return { x0: p.x0, x1: p.x1, y0: p.y0, y1: p.y1, h: p.h, n: p.n, text: p.text, translatable: p.translatable, tr: p.translatable ? (cache[ckey(p.text)] || null) : null }; });
        }
        self.outChunks = [];
        if (!self.fontSent) {
          var fd = NSData.dataWithContentsOfFile(mainPath + '/vendor/cjk.ttf'), fb = String(fd.base64Encoding()), CH = 400000;
          for (var i = 0; i < fb.length; i += CH) self.panelSend({ type: 'fontChunk', data: fb.slice(i, i + CH) });
          self.fontSent = true;
        }
        self.panelSend({ type: 'build', md5: ctx.md5, title: String(ctx.doc.docTitle || 'document'), pages: pages });
      }
      pump();
    },
    saveBilingual: function (name) {
      var self = this;
      var b64 = (self.outChunks || []).join(''); self.outChunks = [];
      self.building = null;
      var data = null;
      var tries = [
        function () { return NSData.alloc().initWithBase64Encoding(b64); },
        function () { return NSData.dataWithContentsOfURL(NSURL.URLWithString('data:application/pdf;base64,' + b64)); }
      ];
      for (var ti = 0; ti < tries.length && !data; ti++) { try { data = tries[ti](); } catch (e) { log('b64 try ' + ti + ' ' + e); } }
      if (!data) { hud(self, '保存失败'); return; }
      var dir = mainPath.replace(/\/Library\/MarginNote Extensions\/.*$/, '/Documents/');
      var safe = String(name).replace(/[\/:*?"<>|]/g, '_');
      var path = dir + safe + '（双语）.pdf';
      data.writeToFileAtomically(path, true);
      log('saved bilingual ' + path + ' ' + data.length());
      self.panelSend({ type: 'buildProgress', stage: 'saved', path: path });
      hud(self, '双语 PDF 已生成：' + safe + '（双语）.pdf');
    },
    docPath: function (ctx) {
      var p = String(ctx.doc.pathFile || '');
      if (p && p[0] !== '/') p = mainPath.replace(/\/Library\/MarginNote Extensions\/.*$/, '/Documents/') + p;
      return p;
    },
    sendDoc: function (ctx) {
      var self = this;
      self.docSent = ctx.md5;
      var d = null;
      try { d = NSData.dataWithContentsOfFile(self.docPath(ctx)); } catch (e) {}
      if (!d) { log('cannot read pdf ' + self.docPath(ctx)); self.panelSend({ type: 'doc', md5: ctx.md5, pageCount: ctx.pageCount, page: ctx.pageNo, error: '无法读取 PDF 文件' }); return; }
      var b64 = String(d.base64Encoding());
      log('send pdf ' + b64.length);
      self.panelSend({ type: 'doc', md5: ctx.md5, pageCount: ctx.pageCount, page: ctx.pageNo, title: String(ctx.doc.docTitle || '') });
      var CH = 400000;
      for (var i = 0; i < b64.length; i += CH) self.panelSend({ type: 'pdfChunk', md5: ctx.md5, data: b64.slice(i, i + CH) });
      self.panelSend({ type: 'pdfEnd', md5: ctx.md5 });
    },
    sendPage: function (ctx, pageNo) {
      if (!this.panelOpen || !this.panelReady || !ctx) return;
      var paras = extractParagraphs(ctx.doc, ctx.md5, pageNo), cache = cacheFor(ctx.md5), jb = jobs[ctx.md5 + '|' + pageNo];
      this.panelSend({ type: 'pageData', md5: ctx.md5, no: pageNo, running: !!(jb && jb.state === 'running'), err: jb && jb.state === 'error' ? jb.err : null,
        paras: paras.map(function (p) { return { id: p.id, text: p.text, x0: p.x0, x1: p.x1, y0: p.y0, y1: p.y1, h: p.h, n: p.n, translatable: p.translatable, tr: p.translatable ? (cache[ckey(p.text)] || null) : null }; }) });
    },
    refreshUI: function () {
      if (!this.panelOpen || !this.panel || !this.panelReady) return;
      var ctx = readerCtx(this);
      var msg = { type: 'state', cfg: allCfg(), enabled: !!this.enabled };
      msg.cfg.apiKey = msg.cfg.apiKey ? '••••' + String(msg.cfg.apiKey).slice(-4) : '';
      if (ctx) {
        var paras = extractParagraphs(ctx.doc, ctx.md5, ctx.pageNo);
        var cache = cacheFor(ctx.md5);
        var job = jobs[ctx.md5 + '|' + ctx.pageNo];
        msg.page = { no: ctx.pageNo, count: ctx.pageCount, title: String(ctx.doc.docTitle || ''), job: job || null };
        if (this.docSent !== ctx.md5) this.sendDoc(ctx);
        msg.paras = paras.map(function (p) {
          var k = ctx.md5 + '|' + ctx.pageNo + '|' + p.id;
          return { id: p.id, text: p.text, tr: p.translatable ? (cache[ckey(p.text)] || null) : null, translatable: p.translatable, shown: userToggled[k] !== undefined ? userToggled[k] : cfg('mode') === 'cover' };
        });
      }
      this.panelSend(msg);
    }
  };

  return JSB.defineClass('ImmersiveTranslate : JSExtension', {
    sceneWillConnect: function () {
      M.window = this.window; M.obj = this;
      var self = M;
      self.enabled = !!UD.objectForKey('imt_enabled');
      self.panelOpen = false;
      self.version = 1;
      self.blockMap = {};
      self.lastPage = null;
      self.timer = NSTimer.scheduledTimerWithTimeInterval(0.5, true, function () { if (!self.tc) { log('timer fired'); self.tc = 1; } try { self.tick(); } catch (e) { log('tick call err ' + e); } });
      log('timer ' + self.timer);
      NSNotificationCenter.defaultCenter().addObserverSelectorName(self, 'onSelection:', 'PopupMenuOnSelection');
      if (self.enabled && cfg('view') === 'reflow') later(1.5, function () { try { self.openPanel(); } catch (e) { log('panel err ' + e); } });
      log('scene connected');
    },
    sceneDidDisconnect: function () {
      if (M.timer) M.timer.invalidate();
      NSNotificationCenter.defaultCenter().removeObserverName(this, 'PopupMenuOnSelection');
    },
    notebookWillOpen: function () { M.invalidate(); },
    documentDidOpen: function () { M.invalidate(); },
    queryAddonCommandStatus: function () {
      return { image: 'logo.png', object: this, selector: 'toggle:', checked: !!M.enabled };
    },
    toggle: function () {
      if (M.enabled && !M.panelOpen) { setCfg('view', 'reflow'); M.openPanel(); return; }
      M.enabled = !M.enabled;
      UD.setObjectForKey(M.enabled, 'imt_enabled');
      if (M.enabled) { setCfg('view', 'reflow'); M.openPanel(); hud(this, '沉浸式翻译：开启'); }
      else { M.closePanel(); hud(this, '沉浸式翻译：关闭'); }
      M.invalidate();
      Application.sharedInstance().studyController(this.window).refreshAddonCommands();
    },
    onBlockTap: function (gr) { M.toggleBlock(gr.view); },
    onBadgeTap: function (gr) { M.toggleBlock(gr.view); },
    onSelection: function (sender) {
      if (!M.enabled) return;
      var self = M;
      try {
        if (sender.object && sender.object.window && sender.object.window !== self.window) {}
        var text = sender.userInfo.documentController.selectionText;
        if (!text) return;
        text = String(text).trim();
        if (text.length < 2 || text.length > 4000) return;
        if (self.selTimer) self.selTimer.invalidate();
        self.selTimer = later(0.35, function () { self.translateSelection(text); });
      } catch (e) { log('sel err ' + e); }
    },
    onSelCardTap: function () { if (M.selCard) M.selCard.removeFromSuperview(); },

    // ---------- panel ----------
  }, {
    addonDidConnect: function () {},
    addonWillDisconnect: function () {}
  });
};
