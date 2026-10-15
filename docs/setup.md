# Setting up Readlet

Readlet works without any setup for reading, excerpts, mind maps and narration with the macOS system voice. AI features — bilingual translation, AI Narration scripts, the AI Assistant, flashcards and AI mind maps — need a model. This guide covers every way to connect one, plus online voices.

The first launch opens a **setup guide** (Help → Welcome & Setup Guide… reopens it). Everything below can also be done in **Settings (⌘,)** or in a [config file](#config-file).

## 1. Choose where AI comes from

| Option | Best for | What you need |
|---|---|---|
| **Your own gateway / API** | Anthropic, OpenAI or any compatible API, or a company gateway | Base URL + API key |
| **Local model** | Offline use, privacy | [Ollama](https://ollama.com) or [LM Studio](https://lmstudio.ai) running on your Mac |
| **ChatGPT account** | ChatGPT Plus / Pro subscribers | A ChatGPT account — no API key |

### Your own gateway

*Settings → General → Gateway*

1. **Base URL** — the server root, **without** `/v1` (Readlet adds the paths). Examples:
   - Anthropic: `https://api.anthropic.com` (protocol *Anthropic Messages*)
   - OpenAI: `https://api.openai.com` (protocol *OpenAI Responses* or *Chat Completions*)
   - OpenRouter: `https://openrouter.ai/api` (protocol *Chat Completions*)
   - DeepSeek: `https://api.deepseek.com` (protocol *Chat Completions*)
   - Alibaba Cloud Model Studio (Qwen): `https://dashscope.aliyuncs.com/compatible-mode` (protocol *Chat Completions*)
2. **API key** — stored in the macOS Keychain.
3. Click **Refresh Models**, then choose a model for **Translation** and one for **AI Assistant / Narration / Flashcards**. AI Narration sends page images, so that model must accept images (e.g. Claude, GPT‑4o / GPT‑5 class, Gemini, Qwen‑VL).
4. **Test Connection** (bottom of Settings) checks both models.

Errors explain themselves: `401/403` → key or permission; `404` → URL or model name; `429` → rate limit or quota.

### Local model

1. Install and start Ollama (`ollama serve`) or LM Studio's local server.
2. Pull a model, e.g. `ollama pull qwen3:8b`; for AI Narration a vision model such as `qwen2.5vl` or `gemma3`.
3. *Settings → General → Gateway → Local Models* fills in `http://localhost:11434` (Ollama) or `http://localhost:1234` (LM Studio) and selects the Chat Completions protocol.

### ChatGPT account (Sign in with ChatGPT)

*Settings → General → ChatGPT Account → Continue with ChatGPT* opens your browser; sign in and allow Readlet to use your plan. Then choose *ChatGPT account* as the protocol (or click **Use ChatGPT for Translation & Assistant**). Usage counts toward your plan; *Manage Usage* opens ChatGPT's usage page.

## 2. Voice for AI Narration

*Settings → Voice & Narration → Speech Engine*

- **System voice** (default, free, offline). For a natural sound download a **Premium** or **Enhanced** voice: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices. Readlet shows a hint when only compact voices are installed and picks the best installed voice for the narration language automatically.
- **Online voices** — each service has its own URL, key, model and voice; see [Online voices](tts-providers.md) for step-by-step instructions (OpenAI, Gemini, Qwen‑TTS, Azure, ElevenLabs, MiniMax, Volcengine).
- **Preview** plays a sample with the current choice. If an online service rejects requests (no model, bad key), narration falls back to the system voice and tells you why.

## 3. Narration style

*Settings → Voice & Narration → AI Narration Style*: Podcast (default), Storyteller, Technical Deep Dive, Popular Science or Quick Summary, plus optional extra instructions (“explain with code examples”, “end each page with a one-line summary”…). Scripts are cached per style.

## 4. Costs and storage

*Settings → Storage & Usage* shows model calls and tokens per feature and, if you enter your provider's prices, an estimated cost. *Prepare All* in the narration player estimates the calls, tokens and speech before it starts. Narration audio is cached as AAC under a size limit (default 3 GB).

## Config file

Everything above can live in a text file — handy for several Macs or for keeping secrets out of the UI.

- Location: `~/.config/readlet/config.toml` (App Store edition: inside the app's container — use *Settings → General → Config File → Create / Open*).
- Start from [`config.example.toml`](../config.example.toml), or click **Create Config File** in Settings (writes your current settings, never the key).
- Values in the file win over the Settings window; saving in Settings writes back to the file and keeps your comments. Changes apply without restarting.
- Keys: leave them in the Keychain (Settings), or use `api_key_command = "security find-generic-password -s readlet -w"` (direct edition), `api_key_env`, or `api_key` (plain text — keep the file `chmod 600`).

```toml
[gateway]
base_url = "https://api.anthropic.com"

[translate]
model = "claude-haiku-5-5"
protocol = "anthropic"          # anthropic | chat | responses | chatgpt
target_language = "简体中文"

[assistant]
model = "claude-haiku-5-5"
protocol = "anthropic"

[tts]
provider = "qwen"               # system | gateway | openai | gemini | qwen | azure | elevenlabs | minimax | volcengine

[tts.qwen]
model = "qwen3-tts-flash"
voice = "Cherry"
```

## Privacy

Readlet has no account, no analytics and no tracking. Page text (and, for narration, page images) goes only to the AI service you configure; online speech sends script text only to the voice service you choose. See the [privacy policy](https://readit.novarock.io/privacy.html).
