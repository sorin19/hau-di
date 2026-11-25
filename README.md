# hau-di

Voice dictation for macOS in the style of Wispr Flow: hold down a key combination (fn, ⌃, ⌥, ⌘, ⇧ - your choice), speak, release, and the text appears in the active field of any app.

- **100% local transcription with open models**, optimized for Apple Silicon (Neural Engine on M3): **Whisper Large v3 Turbo** via [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (the default; best accuracy for Romanian, 99 languages), plus its compressed variant and Small.
- **Correction by Claude** (Anthropic API): text (recognition errors, correct ș/ț diacritics, punctuation), data (amounts, calendar dates, times, phone numbers, emails, URLs) and intent (removes hesitations, applies self-corrections like "at 5, no, at 6", formats dictated lists). If the API does not respond in time, the raw text is inserted.
- Push-to-talk, **double-tap for hands-free**, **Esc** cancels, floating pill with a waveform, personal dictionary, voice snippets.
- **History of the last 3 months** with the transcribed text, the final text, the Claude model and **the cost of each correction**; *Today*, *This week* (from Monday), *This month* and *All time* ranges, totals and CSV export.
- **Dictation language** (*Transcription* or the menu bar menu): Romanian, English, German, French, Spanish, Italian or Hungarian, plus a **+ English** checkbox for people who mix in English terms (Romglish, Hunglish). Whisper always transcribes in the chosen language: it does not guess the language, so it does not translate a sentence with many English words by mistake. With *+ English*, Claude writes the words spoken in English correctly, in English (in Romanian: "diploi" → "deploy", "mitingul" → "meeting-ul"), and the rest stays in the chosen language, without translation. For text entirely in English, choose *English*.
- **With or without diacritics**, from the menu bar menu: without diacritics, Claude is instructed not to use them, and the final text is cleaned up locally anyway (even when Claude is turned off).

---

## Requirements

- A MacBook with Apple Silicon (tested target: M3), **macOS 14 Sonoma or later**
- **Xcode 16 or later** (Xcode 26 recommended)
- ~3 GB of free space for the models (Whisper Large v3 Turbo is 1.6 GB)
- Optional: an Anthropic API key from the [Claude Console](https://console.anthropic.com/settings/keys) for AI correction

## Steps in Xcode

1. **Get the source:** clone this repository (`git clone` with the URL from the green *Code* button on GitHub) or download it as a ZIP and unzip it. If you plan to commit, run `git config filter.noteam.clean Tools/git-clean-team.sh` and `git config filter.noteam.smudge cat` once in the clone: the signing Team you choose in Xcode then stays out of your commits.
2. **Open `hau-di.xcodeproj`** (double-click). Xcode automatically downloads the Swift package `argmax-oss-swift` 1.1.x (WhisperKit). Wait until "Resolving Package Graph" / "Fetching" disappears from the top bar (1-3 minutes the first time).
3. **Signing (important):** in the navigator on the left, click the **hau-di** project → target **hau-di** → **Signing & Capabilities** tab → **Team** → choose *Personal Team* (your Apple ID; if it is missing: Xcode → Settings → Accounts → +).
   Why: macOS ties the Accessibility and Microphone permissions to the app's signature. Without a Team, every rebuild looks like a new app and the permissions "disappear".
4. **Run: ⌘R** (Product → Run). The scheme runs in the *Release* configuration so that transcription is as fast as possible (for debugging: Product → Scheme → Edit Scheme → Run → Build Configuration → Debug).
5. **First launch** - the *Start* window opens:
   1. **Microphone** → *Allow*.
   2. **Accessibility** → *Request permission* → in System Settings → Privacy & Security → Accessibility, turn on **hau-di**. Come back to the app: key listening starts by itself (row 3 turns green).
   3. **The model** is downloaded and optimized for the Neural Engine. The first time this takes a few minutes (1.6 GB download + Core ML compilation); after that it starts in a few seconds.
   4. **Claude key** → *AI Correction* tab → paste the key → *Save* (it is tested automatically and kept in the Keychain).
6. **If you use fn (the default):** System Settings → Keyboard → **"Press 🌐 key to" → "Do Nothing"**, otherwise fn also opens Apple's Emoji/Dictation.
7. Try it in the *Try it here* box, then in any app: hold **fn**, speak, release.

### Permanent install (without Xcode open)

The app started with ⌘R runs under the Xcode debugger and quits along with it. For a standalone copy:

```
./Tools/install.sh                          # from the project folder: builds (Release, arm64) and installs into /Applications
./Tools/install.sh ~/Downloads/hau-di.zip   # first updates the sources from a new zip (the Team chosen in Xcode is kept)
```

- The script stops the running instance, copies `hau-di.app` into `/Applications` and launches it.
- Then turn on *General → Launch hau-di at login*.
- If the keys do not respond in the installed copy, remove hau-di from the Accessibility list (the − button), add it again and restart the app.
- Only one instance runs: the one started last (e.g. from Xcode) quits the old one.
- Alternatively, from Xcode: Product → **Archive** → Distribute App → **Custom → Copy App** → move `hau-di.app` to `/Applications`.

## Usage

| Action | What it does |
|---|---|
| Hold the key combination | Records; on release, transcribes, corrects and inserts |
| Double-tap the key combination | Hands-free: records until you press the key combination again |
| Esc | Cancels the recording or the processing in progress (nothing is inserted) |
| Short press / the key combination + another key | Ignored (does not interfere with your shortcuts, e.g. fn + arrow keys) |

The key combination is changed in *General*: presets (fn, right ⌥, right ⌘, ⌃⌥, fn⌃, ⌘⌥) or *Record a new hotkey…* (press any combination of fn/⌃/⌥/⌘/⇧, including the right-hand keys). A single left ⌘/⌃/⌥/⇧ is not recommended (you use it all the time in shortcuts).

The menu bar icon is the cx.ro logo drawn with stripes (white/black, like the rest of the menu bar); only the rhombus in the middle changes color with the state: white/black = ready, red = recording, green = transcribing locally, orange = correcting with Claude, purple = the text was inserted. The same rhombus, in the same color, is the status icon in the pill at the bottom. When idle, the icon is just the shape, without the rhombus. Clicking it shows the status and the last dictated text, with a copy button.

**Whisper's per-word confidence:** in *Transcription*, the *Last dictation* section shows what Whisper heard in the last dictation: each word with its probability (red below 50%, orange below 80%). A word's probability is the geometric mean of its tokens' probabilities; it comes with every transcription, so it adds no time. It is also kept in the history (the `raw_text_marked` and `word_probabilities` columns in the CSV). It is not sent to Claude: in the A/B test of 2026-11-24 (312 corrections), marking the uncertain words did not reduce errors, while the dictionary reduced them by ~25%.

**Dictionary:** terms appear as tags; × deletes, and dragging moves a term in front of the one you drop it on (right-click: to the start / to the end). Claude gets all the terms; Whisper only the first ones, as many as fit whole in ~110 tokens (marked in blue), so new terms go at the start. The *Suggestions from your dictations* section proposes terms from the history: words that Whisper misheard and Claude corrected (e.g. "clod" → Claude), with how many times they appeared and Whisper's average score; + adds, the pencil lets you edit the term in place first, × hides it.

**Long dictations:** Whisper writes the text of each piece of audio in a context of 224 tokens, which also holds the dictionary (up to 111 tokens). With a full dictionary, about 107 tokens are left for the text, roughly 18 s of fast speech. So hau-di splits longer recordings into pieces of up to ~18 s (up to 28 s with a short dictionary): as few pieces as possible, each cut in the longest pause available, which is usually the end of a sentence. If a piece still fills its tokens, it is split in two and transcribed again. Each piece is transcribed on its own, so Whisper doesn't see the text of the piece before it; WhisperKit's own split didn't pass it on either, and Claude's correction sees the whole text. Before this, WhisperKit's 30 s pieces could silently lose their end.

**⌘Q in the settings window only closes the window**: hau-di stays in the menu bar. To quit the app: the menu bar icon → *Quit* (or Quit from the Dock).

## Correction with Claude

- Default model: **Claude Opus 5.5** (`claude-opus-5-5`), *Medium* effort, no fast mode: in the test on 50 real dictations, the best balance of quality, time and cost without fast mode (on *Low*, ~3 times as many serious errors). In *AI Correction*, the model list comes from Anthropic (`GET /v1/models`, the models your key has access to, reloaded daily), grouped by family (Opus, Sonnet, Haiku, Fable), with the list price next to each. You can choose a specific model or "Latest Opus / Sonnet / ...", which switches to the new model by itself when one comes out. A retired model is automatically replaced with the newest one from the same family.
- **Effort:** only the levels the chosen model has (from `/v1/models`: from *Low* to *Max*; some older models have fewer or none). If the chosen level does not exist on the model, the closest lower one is used.
- **Fast mode** (up to ~2.5x faster, double the price): only on the models that have it. `/v1/models` does not say this, so the information comes from the price list (below); if the API still rejects fast mode or the fallback on a model, the app remembers and stops sending them.
- **Price list:** [pay.cx.ro/hau-di/pricing/](https://pay.cx.ro/hau-di/pricing/), maintained by the author from [Anthropic's pricing page](https://platform.claude.com/docs/en/about-claude/pricing) and fetched once a week. The settings show only the models that have a price there. Until the first fetch, or without a network connection, the copy in the app is used. The request sends the installation ID (a UUID v7 generated on first launch: the generation time plus random bits, unrelated to you or your Mac) and the app version, and the server records the date and the IP address; this is how the author sees how many installations use the app. Nothing else is sent to pay.cx.ro.
- Levels: **Minimal** (only errors, diacritics, punctuation, data formatting), **Standard** (+ hesitations, self-corrections, lists), **Polished** (+ rephrasing and a tone adapted to the app).
- What is sent: only the transcribed text, plus (optionally) the app name/window title and the text before the cursor. The audio never leaves the Mac. Password fields are not read.
- Technical details: Messages API (`anthropic-version: 2026-10-21`), JSON response guaranteed by *structured outputs*, cached system prompt (prompt caching), server-side fallback if the model refuses a request (`server-side-fallback-2026-07-01`, on the models marked in the price list), with a fallback to the raw text if the response is late.
- **Maximum wait time**, separate for short and long dictations (*AI Correction*): by default, for up to 5 s of audio it waits 5 s, and for more than 5 s it waits 20 s. All three values can be changed.
- Approximate cost: under 1 cent per dictation with Opus 5.5; fractions of a cent with Haiku 5.5.
- **Monthly budget** (*AI Correction*, default $20): in the menu bar menu, a row shows today's dictations and Claude corrections and, on the right, the cost *today / this month / budget* (the month turns orange at 80%, red at 100%). The spending is estimated from tokens × list price and includes rejected corrections (they are paid for too) and the test in the settings; it is tracked separately from the history. At 80% a warning appears on the pill, and at 100% correction stops until the 1st of the next month (the text is inserted as Whisper transcribed it). If you raise the budget, correction resumes immediately. For a hard limit, also set a spend limit in the Claude Console.
- The *AI Correction* tab has a **Test the correction (no microphone)** field so you can see the result on a raw text.
- **Cost:** the API returns the tokens used (input, cache read/write, output); hau-di saves them and calculates the cost with the prices from the price list (Opus 5.5: $4 / $20 per million, cache read $0.20; Sonnet 5.5: $2 / $10; Haiku 5.5: $0.10 / $0.50; fast mode x2). The bundled copy is in `hau-di/Core/Pricing.swift` (identical to `price.json` on the server, served at `/hau-di/pricing/`, as of the date in `updated`); a model without a price shows its cost as "—". The exact billed amount is in the Console, under the dedicated API key.

## Project structure

```
hau-di.xcodeproj           Xcode project (synchronized folders: any file in hau-di/ is included in the build automatically)
Config/hau-di.entitlements no App Sandbox (required for CGEventTap + Accessibility)
hau-di/
  App/            HauDiApp (MenuBarExtra + service composition), DictationController (the full flow), AppSettings
  Core/           portable code, also tested on Linux: key combinations + state machine, prompt + Claude client, history
                  (BrandMark.swift = the cx.ro logo data, excluded from the license)
  Audio/          AVAudioEngine → 16 kHz mono, microphone selection (Core Audio)
  Transcription/  WhisperKitEngine, TranscriptionService (model download/loading)
  System/         HotkeyMonitor (CGEventTap on a dedicated thread), text insertion (⌘V with clipboard restore / Unicode typing), Accessibility, Keychain, permissions
  UI/             floating pill, menu bar menu, settings window, the logo drawings (BrandArt)
  Resources/Legal the license and the third-party notices, shown in Settings → General → About
Tools/
  linux-check/    checks without a Mac: swiftc -parse on all the code + unit tests for hau-di/Core
  make_icon.py    regenerates the app icon (blue variant, opaque over the whole surface, so that macOS 26 crops it itself)
  whisper-probe.py  runs Whisper (the app's model and settings) on an audio file and shows each word's probability; requires `brew install whisperkit-cli`
  publish.sh      commits and pushes your changes to GitHub, after checking that no signing Team, keys or private files go out
  git-clean-team.sh  git filter that keeps the signing Team (DEVELOPMENT_TEAM) out of commits (see .gitattributes)
```

The models are saved in `~/Library/Application Support/hau-di/WhisperKit`. The history: `~/Library/Application Support/hau-di/history.jsonl` (one entry per line, the last 3 months). Bundle ID: `ro.cx.app.hau-di`.

**The old name.** Until 2026-11-23 the app was called Haudi (`ro.cx.app.haudi`, before that `ro.haudi.app`). On first
launch, the settings, the API key and the old data folder `~/Library/Application Support/Haudi` (models and history)
are moved automatically; `Tools/install.sh` deletes `Haudi.app`, clears the old permissions and takes the signing Team
from the old `Haudi/` project, if it is next to it. Microphone and Accessibility have to be granted again, and
*Launch hau-di at login* has to be turned on again.

## Troubleshooting

- **Nothing happens when I hold fn** → check *Start*: Accessibility checked and "Key listener" green. After a rebuild without a Team (or after moving the app), remove hau-di from the Accessibility list and add it again, then *Retry*.
- **fn opens Emoji / Dictation** → System Settings → Keyboard → "Press 🌐 key to" → Do Nothing.
- **The text does not appear in a particular app** → *General → Method: Type character by character*. Fields with "secure input" (passwords, `sudo` in Terminal) block any synthetic text.
- **"Nothing heard"** → choose the right microphone in *Transcription*. Bluetooth headphones (AirPods) switch to call mode when you use their microphone; the MacBook's microphone is usually better.
- **The first dictation takes a long time** → the model is still loading (see the status in the menu bar menu).
- **"Inserted without AI correction"** → missing/invalid key, timeout or network error; the reason appears in the menu and in *History*. For "timed out", increase the time for short or long dictations in *AI Correction*.
- **Logs:** Console.app → filter by `ro.cx.app.hau-di`.

## Checks run on Linux (without a Mac)

`Tools/linux-check/run.sh` checks the syntax of all the Swift files and runs the unit tests for the portable logic (the key combination state machine, building the request and parsing Claude's response with a simulated HTTP server, transcript cleanup, the history). The macOS-specific code (AppKit, SwiftUI, Core ML) cannot be compiled on Linux - if Xcode reports build errors, please report the exact messages.

## License

Copyright (C) 2026 CEXA DIGITAL SRL [CIF 35370537] (https://cx.ro). Author: Sorin Buturugeanu.

hau-di is free software, released under the **GNU General Public License v3** (version 3 only). You can use, study,
modify and redistribute it; modified versions that you distribute must also stay under GPL v3, with the source code
available. hau-di comes **without any warranty**. Full text: [`LICENSE`](LICENSE).

**The cx.ro logo and the hau-di icons are excluded from the license** and may not be used: see [`BRANDING.md`](BRANDING.md).

Third-party components (WhisperKit and the components included in it) and their licenses: [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
In the app, the same texts are in *Settings → General → About*.

## Author

**Sorin Buturugeanu**, [CEXA DIGITAL SRL](https://cx.ro) [CIF 35370537] · made with [Claude Code](https://claude.com/claude-code).

If hau-di is useful to you, you can support its development: [pay.cx.ro/hau-di/](https://pay.cx.ro/hau-di/).
