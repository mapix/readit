# Readlet

A native macOS app (SwiftUI + PDFKit) for reading PDFs, EPUBs and web articles bilingually with the original layout preserved, listening to an AI explain every page, and taking MarginNote-style notes — excerpts, mind maps and links across documents. Bring your own AI: any Anthropic / OpenAI-compatible gateway, a local model, or your ChatGPT plan.

- **Get it** (free, open source): [Mac App Store](https://readlet.novarock.io/#download) (sandboxed, updates through the store) or the direct download from <https://readlet.novarock.io>. Both editions have the same features apart from the [differences listed here](AppStore/README.md#7-differences-of-the-app-store-edition).
- **Set up**: the first launch opens a short guide; details in [docs/setup.md](docs/setup.md) and [docs/tts-providers.md](docs/tts-providers.md).
- **Source**: https://github.com/mapix/readit (MIT licensed).
- **Build**: `./build_app.sh` (direct edition → `/Applications/Readlet.app`, `dist/Readlet-<version>.zip`) · `./build_mas.sh` (App Store package) — see [Building](#building).

## Interface & Windows

- **Main window (Library)**
  - The **Study** tab groups PDFs by notebook; click a notebook to see its PDFs.
  - The **Documents** tab lists all PDFs; double-click a name or right-click to rename.
- **One window per PDF**
  - Clicking a PDF opens it in its own window; several can be open at once.
  - Each PDF has at most one window — clicking it again brings the existing window to the front.
  - Open windows are remembered on quit and restored on next launch.
- **Toolbar**
  - Read mode: plain text selection, no annotation toolbar.
  - Annotate mode: MarginNote-style excerpts and annotations.
  - Original / Bilingual, AI Narration, Flashcards, AI Assistant, and Collapse to Desktop Widget.
- **Themes**
  - Three themes: Light, Sepia (warm paper), and Dark (inverted). Switch from the Library top bar or the ⋯ menu in a document window.
  - PDF pages are tinted to match the theme while text stays crisp vector.
- **Desktop widget** (⌘⇧M)
  - Hides all Readlet windows and leaves a floating, always-on-top, draggable player on the desktop.
  - Compact mode looks like a music player: progress, previous / play / next segment, and a mic button for questions.
  - Expand the transcript to see every segment; click one to jump to it.
  - ⤢ restores the real PDF window.
- **Data**: imported PDFs are copied into Readlet's own data directory, so moving or deleting the original file has no effect.

## Models

- **Translation & AI features**: choose separate models for *Translation* and for *AI Assistant / Narration / Flashcards* in Settings.
  - Protocols: Anthropic Messages, OpenAI Chat Completions, OpenAI Responses, and **ChatGPT account**.
  - The model list comes from the gateway's `/v1/models` (or your ChatGPT account's models).
- **Sign in with ChatGPT**: ChatGPT Plus / Pro users can run Readlet's AI on their plan, no API key. *Settings → General → ChatGPT Account → Continue with ChatGPT* opens the browser (OAuth + PKCE with a loopback callback); the ID token is verified against OpenAI's keys, tokens refresh automatically and are stored in `~/.config/readlet/chatgpt-auth.json` (0600). Usage limits and the *Manage Usage* link follow OpenAI's guidelines.
- **Local models**: `http://` servers on your Mac or LAN work (Ollama `http://localhost:11434`, LM Studio `http://localhost:1234`) with the OpenAI Chat Completions protocol.
- **Keys** entered in Settings are kept in the macOS Keychain.
- **Speech (TTS)** — pick an engine in *Settings → Voice & Narration*:
  - **System voice** (default): macOS `AVSpeechSynthesizer` — free, offline, no model. Nicer voices: *System Settings → Accessibility → Spoken Content → System Voice → Manage Voices* (Premium / Enhanced).
  - **Main gateway**: OpenAI-compatible `POST /v1/audio/speech` with the gateway's URL and key.
  - **Own services, each with its own base URL and key**: OpenAI (or any `/v1/audio/speech`-compatible server), Google Gemini, **Qwen-TTS** (Alibaba Cloud Model Studio / DashScope), Microsoft Azure Speech, ElevenLabs, MiniMax, Volcengine (豆包语音).
  - Requests that fail with a configuration error (no model, bad key, 401/404…) switch narration to the system voice; **Preview** tests the chosen voice.
  - Clips are cached as AAC (about 1/8 of WAV) under a size limit; the least recently narrated documents are dropped first.

## AI Features

- **AI Assistant** (⌘J)
  - Summarize the current page or the whole document, explain key concepts.
  - Select text and choose **Ask AI**, or ask anything; page numbers in answers are clickable.
  - Conversations are saved per document.
- **AI-generated mind map** (bottom-right of the mind map, or the ⋯ menu)
  - The AI reads the whole document and produces a structured mind map.
  - Every point is anchored to the source: it leaves a highlight in the PDF, and double-clicking a node jumps back to it.
- **Flashcards** (⌘⇧K)
  - Structured cards in four types — Concept, Understanding, Application, Data — each citing its source page.
  - Flip cards and mark them *Got It* / *Review Again*; progress is saved.
- **AI Narration** (⌘⇧L)
  - **Style**: a conversational, page-by-page walkthrough that also covers figures and tables, turning pages automatically.
  - **Buffering**: scripts for the next 3 pages are written in parallel, and about 5 minutes of upcoming audio (at the current speed, 12–60 segments) is synthesized ahead with several requests in flight, so playback rarely waits. Tune with `tts.buffer_seconds` and `tts.script_pages_ahead`.
  - **Follow along**: the paragraph or figure being narrated gets a soft "breathing" outline and is smoothly scrolled to the center.
  - **Styles**: pick *Podcast* (default), *Storyteller* (评书), *Technical Deep Dive*, *Popular Science* or *Quick Summary* in Settings or from the player, and add your own extra instructions. Scripts and audio are cached per style, so switching back reuses them.
  - **Prepare All**: one click (tray button in the player) writes the scripts and synthesizes the audio for the whole document in the background, starting at the current page, so playback never waits. Before it starts you see an estimate of model calls, tokens, speech characters and — with your prices set — cost. Already-generated parts are skipped; it can be cancelled anytime.
  - **Start from here**: scroll or jump to any page while narrating and a **Narrate from page N** button appears in the player; one click continues from the top of that page.
  - **Controls**: adjustable speed and voice; hold the mic button (or ⌃Space) to interrupt with a spoken question at any time.
  - **Time left**: the player, the minimized pill, and the desktop widget show an estimate of the remaining listening time for the whole document at the current speed. It is based on the scripts already written plus the speaking pace learned from synthesized audio, and gets more accurate as you listen.

## Reading Tools

- **Find** (⌘F, ⌘G / ⇧⌘G): full-text search in the original or bilingual view — both languages are searchable; all matches are highlighted.
- **Contents**: the side pane's *Contents* tab shows the PDF's own table of contents and the chapter you are in.
- **Undo / Redo** (⌘Z / ⇧⌘Z) for deleting cards, comments, topics and notebooks and for moving topics.
- **Keyboard shortcuts**: Help → Keyboard Shortcuts (⌘/).

## Import & Export

- **Files**: ⌘O imports PDFs as they are and converts **EPUB** (chapters in order, with images), **Markdown**, **Word / RTF / ODT**, saved **HTML** pages and **TXT** into clean PDFs with the same print style as web articles. Drag files onto the library or use *Open With* in Finder.
- **Export**: File → *Export Excerpts as Markdown* (Obsidian / Logseq friendly: quotes, translations, comments, links, page numbers, colour tags) and *Export to Anki* (flashcards and excerpts as an Anki text file with tags).
- Bilingual PDF and mind-map Markdown export as before.

## Import from the Web

Many sources are web pages, not PDFs. **File → Import from Web…** (⌘⇧O), or the *Import from Web* tile in the library, takes a link and adds a clean PDF of the article:

- The page is opened in a real (hidden) WebKit view, so JavaScript-rendered sites work, and logins in that view persist between imports.
- Readlet scrolls through the page so lazy images load, then keeps only the main content using [Mozilla Readability](https://github.com/mozilla/readability) plus its own clean-up: navigation, sidebars, comments, share and subscribe bars, cookie banners, related posts, ads, avatars and similar chrome are dropped.
- Images are downloaded with the article as Referer, so hotlink-protected CDNs work. KaTeX and MathJax formulas are kept as native MathML, code blocks keep their formatting, and embedded videos become links.
- The article is laid out with Readlet's print style (title, author, site, date, source URL) and printed to A4. Bilingual view, narration and notes then work as with any PDF.
- Direct links to `.pdf` files are downloaded as they are.
- If a site asks for a login or a human check, choose **Open in a window**: sign in or verify there, then click **Extract & Import**.
- The source URL is remembered: right-click the document for **Open Original Page** or **Re-import from Web**.

The extractor lives in `Resources/web/readit-extract.js`. `Tests/webimport/e2e.py` runs the same pipeline in headless Chromium over a set of blogs (English and Chinese, MathJax, SPA, Medium, GitHub, Wikipedia) and writes the PDFs plus a contact sheet.

## Excerpts & Notes (modeled on MarginNote 3)

1. **Select text**: when you release the mouse, a floating toolbar appears above the selection.
   - Eight color dots — click one to excerpt the selection into a card in that color.
   - Plus **Copy** and **Translate** buttons.
2. **After excerpting**, a card popover appears next to the highlight, where you can:
   - change the color
   - add comments (multiple allowed)
   - add a title (shown as the card title in the mind map)
   - link to other cards (including cards in other PDFs)
   - locate it in the mind map, copy, or delete
3. **Click an existing highlight** on the page to reopen its card.
4. **Auto-excerpt** (highlighter button in the toolbar): when on, any selection immediately becomes a card in the current color, with no toolbar.
5. **Area capture** (dashed-rectangle button): drag a rectangle on the page to capture that region as an image card — handy for formulas and figures.
6. **Cards and the mind map**: new cards are attached under the currently selected mind-map node.
   - Nodes are tinted with a light version of the card color and show the excerpt, its translation, and comments.
   - Double-click a node to jump to its location in the document.
   - Drag nodes to change hierarchy.
   - Shortcuts: Tab adds a child, Return adds a sibling, Space edits the title, ⌘ + arrow keys move nodes and change level.
7. **Outline / card list** (left toolbar button): searchable; clicking an item locates it in both the document and the mind map; cards can be dragged into the mind map.

## Bilingual View

- **Layout preserved**: every page is drawn from the original PDF's vector content — formulas, figures, fonts, and layout are untouched.
- **Paragraph-by-paragraph**: each translated paragraph is inserted directly below its source paragraph; works for single- and two-column layouts.
- **Smart skipping**: formulas, pseudocode, tables, tables of contents, and author blocks are not translated.
- **Background translation**: translation starts at the current page and covers the whole book; finished pages are swapped in place without moving your reading position.

## Configuration

Readlet can be configured either in the **Settings** window (⌘,) or with a plain-text file at `~/.config/readlet/config.toml` (override the path with the `READLET_CONFIG` environment variable). The file is optional — start from [`config.example.toml`](config.example.toml):

```bash
mkdir -p ~/.config/readlet
cp config.example.toml ~/.config/readlet/config.toml
chmod 600 ~/.config/readlet/config.toml
```

or click **Create Config File** in Settings, which writes your current settings (without the API key).

```toml
[gateway]
base_url = "https://gateway.example.com"      # no trailing /v1
api_key_command = "security find-generic-password -s readlet -w"

[translate]
model = "claude-haiku-5-5"
protocol = "anthropic"                         # anthropic | chat | responses
target_language = "简体中文"
lookahead_pages = 2

[assistant]                                    # AI Assistant / Narration / Flashcards
model = "claude-haiku-5-5"
protocol = "anthropic"

[narration]
style = "podcast"                              # podcast | storyteller | deep | popular | brief
extra_prompt = ""                              # extra instructions for the narration scripts

[tts]
provider = "system"                            # system (macOS voices) | gateway
system_voice = ""                              # empty = best installed voice for the language
speed = 1.5
# for provider = "gateway":
# model = "gemini-3.8-flash-tts"
# voice = "Zephyr"
```

**Precedence**: config file → Settings window / legacy preferences → environment variables (`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`) → built-in defaults. Keys you leave out of the file fall back to the next source, so existing setups keep working unchanged. Edits to the file are picked up without restarting; when the file exists, saving in the Settings window writes the changes back into it, keeping your comments.

**API key**: the app never writes your key into the file. Choose one of:

- `api_key_command` — run a command and use its output; recommended with the macOS Keychain. Store the key once with `security add-generic-password -s readlet -a "$USER" -w`.
- `api_key_env` — read an environment variable. This only works when Readlet is launched from a shell that exports it; apps opened from Finder or the Dock don't inherit shell variables.
- `api_key` — plain text in the file; keep the file `chmod 600` and never commit it.
- none of the above — the key entered in the Settings window is used, as before.

**Gateway TTS request** — Readlet sends a standard OpenAI Audio Speech request, so any compatible gateway works:

```http
POST {base_url}/v1/audio/speech
Authorization: Bearer <key>
Content-Type: application/json

{"model": "gemini-3.8-flash-tts", "input": "…", "voice": "Zephyr", "instructions": "…", "response_format": "wav"}
```

The response must be audio (16-bit PCM WAV). Voices are model-specific. Existing installs that already set a TTS model keep using the gateway; new installs default to the system voice.

**Legacy preferences** are still honored. They live in the `local.bireader.app` defaults domain, for example:

```bash
defaults write local.bireader.app baseURL -string "https://gateway.example.com"
defaults write local.bireader.app model.tts -string "gemini-3.8-flash-tts"
```

## Usage & Storage

*Settings → Storage & Usage* shows model calls and tokens per feature for today / 7 / 30 days (reported by the API, or estimated when a gateway doesn't report them), cost estimates at your own unit prices, and disk usage — narration audio, bilingual pages, PDFs, notes — with buttons to clear caches or compress WAV clips from older versions.

## Updates

Readlet checks the website for a new release at most once a day (Readlet → Check for Updates…; turn off with `[app] check_updates = false`).

## Data Location

Data lives in `~/Library/Application Support/Readlet/` (automatically migrated from `~/Library/Application Support/BiReader/`), including the library, mind maps, cards, translation cache, and bilingual page cache.

## Building

Requires macOS 14+ and Swift 5.9+.

```bash
./build_app.sh                 # universal (Apple Silicon + Intel) when Xcode is installed, else native; installs /Applications/Readlet.app
UNIVERSAL=0 ./build_app.sh     # native only
swift test                     # unit tests (config, TTS requests/parsing, script parser, EPUB, …)
```

For distribution, sign with a Developer ID and notarize (needs an Apple Developer account):

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=readlet-notary ./build_app.sh
```

GitHub Actions (`.github/workflows/ci.yml`) builds, runs the tests and uploads the app zip for every push.

## License

MIT — see [LICENSE](LICENSE).
