# Online voices

Each service has its own section in *Settings → Voice & Narration* (and `[tts.<provider>]` in the config file). Leave **Base URL** empty to use the default shown. Keys are stored in the macOS Keychain. **Preview** tests the voice.

<a id="tts-openai"></a>
## OpenAI (or any compatible server)

1. Create a key at <https://platform.openai.com/api-keys>.
2. Model `gpt-4o-mini-tts`; voices `marin` and `cedar` sound best (also alloy, ash, ballad, coral, echo, fable, nova, onyx, sage, shimmer, verse).
3. Any server implementing `POST /v1/audio/speech` works with its own Base URL — e.g. SiliconFlow or a local Kokoro server.

<a id="tts-gemini"></a>
## Google Gemini

1. Get a key at <https://aistudio.google.com/apikey>.
2. Model `gemini-3.8-flash-tts` (or `gemini-3.8-flash-lite-tts`); voices such as Kore, Zephyr, Puck, Charon, Leda, Aoede, Fenrir, Orus.
3. Readlet uses the Interactions API and passes the narration's speaking style.

<a id="tts-qwen"></a>
## Qwen‑TTS (Alibaba Cloud Model Studio / 阿里云百炼)

1. Create an API key in the Model Studio console (<https://bailian.console.aliyun.com/?apiKey=1>). Keys are per region.
2. Base URL: leave empty for the **Beijing** region (`https://dashscope.aliyuncs.com`); for **Singapore** use `https://dashscope-intl.aliyuncs.com`.
3. Model `qwen3-tts-flash`; voices include Cherry, Serena, Ethan, Chelsie, Momo, Vivian, Moon, Kai, Jennifer, Ryan and dialect voices Dylan (Beijing), Sunny (Sichuan), Rocky (Cantonese).
4. Text longer than the API limit (600 characters) is split automatically; the language is set from the translation target language.

<a id="tts-azure"></a>
## Microsoft Azure AI Speech

1. Create a *Speech* resource in the Azure portal; copy **Key 1** and the **Region** (e.g. `eastasia`).
2. Enter the key and region; the endpoint `https://<region>.tts.speech.microsoft.com` is derived automatically.
3. Voice: the full name, e.g. `zh-CN-XiaoxiaoNeural`, `zh-CN-YunxiNeural`, `en-US-AvaMultilingualNeural`, `ja-JP-NanamiNeural`.

<a id="tts-elevenlabs"></a>
## ElevenLabs

1. Create a key at <https://elevenlabs.io/app/settings/api-keys>.
2. Model `eleven_multilingual_v2`; voice = a **Voice ID** copied from the Voice Library (e.g. `21m00Tcm4TlvDXrnALMq`).

<a id="tts-minimax"></a>
## MiniMax

1. Create a key on the MiniMax platform.
2. Base URL: empty for mainland-China accounts (`https://api.minimaxi.com`), `https://api.minimax.io` for international accounts.
3. Model `speech-02-hd`; voices such as `female-shaonv`, `male-qn-jingying`, `presenter_female`.

<a id="tts-volcengine"></a>
## Volcengine · Doubao speech (火山引擎 · 豆包语音)

1. In the Volcengine console create a speech-synthesis application; note its **App ID** and **Access Token**.
2. Enter the token as the key and fill in **App ID**; the cluster (model field) is `volcano_tts`.
3. Voices such as `zh_female_shuangkuaisisi_moon_bigtts`, `zh_male_wennuanahu_moon_bigtts`, `BV700_streaming`.

<a id="tts-gateway"></a>
## Main gateway

Uses the gateway from *Settings → General* (same URL and key) with `POST /v1/audio/speech`. Fill in the model and voice your gateway supports.

<a id="tts-system"></a>
## System voice

Free and offline. Download a Premium or Enhanced voice for a natural sound: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices. Readlet synthesizes at the narration speed for natural prosody (`tts.system_native_rate = false` restores playback-rate speed changes).
