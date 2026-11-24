#!/usr/bin/env python3
"""Shows what Whisper outputs for an audio file, with the model and settings of hau-di:
the probability of each word and the text with the uncertain words marked ⟦...⟧.

Usage:
    python3 whisper-probe.py recording.m4a [threshold] [--no-dictionary]

- threshold: below which a word is "uncertain" (default 0.5; 50 also works);
- --no-dictionary: without the Dictionary terms, to see the difference.

Requires whisperkit-cli (the same WhisperKit version as the app, 1.1.1):
    brew install whisperkit-cli
Uses the model hau-di has already downloaded; it does not download anything.
The WhisperKit results (the full JSON and an .srt) stay in the
whisper-probe/ folder next to the audio file.

Differences from the app: here the timing and probability of each word are also
requested (--word-timestamps), and the dictionary is not cut at 120 tokens (the app
cuts it; with up to ~30 terms it is the same).
"""

import json
import os
import plistlib
import shutil
import subprocess
import sys
import time
from pathlib import Path

BUNDLE_ID = "ro.cx.app.hau-di"
DEFAULT_VARIANT = "large-v3-v20240930_turbo"
LANGUAGES = {"ro", "en", "de", "fr", "es", "it", "hu"}
OPEN, CLOSE = "⟦", "⟧"  # ⟦ ⟧
TRAILING_PUNCTUATION = ".,;:!?…\"')"


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def app_settings():
    """The hau-di settings; {} if the app has not run on this Mac yet."""
    try:
        data = subprocess.run(["defaults", "export", BUNDLE_ID, "-"],
                              capture_output=True, check=True).stdout
    except Exception:
        # Fallback: the preferences file on disk.
        try:
            data = (Path.home() / "Library/Preferences" / (BUNDLE_ID + ".plist")).read_bytes()
        except OSError:
            return {}
    try:
        settings = plistlib.loads(data)
    except Exception:
        return {}
    return settings if isinstance(settings, dict) else {}


def language_of(settings):
    """Like DictationLanguage.fromStored: "ro+en", "auto" or nothing means Romanian."""
    stored = settings.get("language")
    return stored if stored in LANGUAGES else "ro"


def dictionary_prompt(settings):
    """Like WhisperKitEngine: the first 60 terms, separated by commas."""
    if not settings.get("whisperDictionaryHint", True):
        return "", 0
    terms = [t.strip() for t in settings.get("dictionary", []) if isinstance(t, str) and t.strip()]
    return ", ".join(terms[:60]), len(terms)


def find_cli():
    found = shutil.which("whisperkit-cli")
    if found:
        return found
    for path in ("/opt/homebrew/bin/whisperkit-cli", "/usr/local/bin/whisperkit-cli"):
        if os.path.exists(path):
            return path
    return None


def parse_args(argv):
    # --fara-dictionar: the old (Romanian) name of the flag, still accepted.
    flags = ("--no-dictionary", "--fara-dictionar")
    without_dictionary = any(flag in argv for flag in flags)
    rest = [a for a in argv if a not in flags]
    if not rest or rest[0] in ("-h", "--help"):
        fail(__doc__.strip())
    audio = Path(rest[0]).expanduser().resolve()
    threshold = 0.5
    if len(rest) > 1:
        try:
            threshold = float(rest[1].replace(",", "."))
        except ValueError:
            fail("The threshold must be a number (e.g. 0.5 or 50).")
        if threshold > 1:
            threshold /= 100
    return audio, threshold, without_dictionary


def marked_text(words, threshold):
    """The text with the words below the threshold marked; adjacent uncertain words go into the same ⟦...⟧."""
    out, run = [], []

    def flush():
        if not run:
            return
        text = "".join(w.get("word", "") for w in run)
        lead = text[:len(text) - len(text.lstrip())]
        core = text.strip()
        body = core.rstrip(TRAILING_PUNCTUATION)
        out.append(lead + OPEN + body + CLOSE + core[len(body):] if body else text)
        run.clear()

    for word in words:
        if word.get("probability", 1.0) < threshold:
            run.append(word)
        else:
            flush()
            out.append(word.get("word", ""))
    flush()
    return "".join(out).strip()


def json_sample(result):
    """A shortened copy of the JSON, to show its structure."""
    def head(items, count):
        items = items or []
        return items[:count] + (["..."] if len(items) > count else [])

    sample = {}
    for key, value in result.items():
        if key == "segments" and isinstance(value, list):
            segments = []
            for segment in value[:1]:
                segment = dict(segment)
                segment["tokens"] = head(segment.get("tokens"), 6)
                segment["tokenLogProbs"] = head(segment.get("tokenLogProbs"), 3)
                segment["words"] = head(segment.get("words"), 2)
                segments.append(segment)
            if len(value) > 1:
                segments.append("... %d more segments" % (len(value) - 1))
            sample[key] = segments
        elif key == "timings" and isinstance(value, dict):
            sample[key] = "{ ... %d execution timings ... }" % len(value)
        else:
            sample[key] = value
    return compact_json(sample)


def compact_json(value, indent=0):
    """Like json.dumps(indent=2), but whatever fits on one line (a word, a short list) stays on one line."""
    inline = json.dumps(value, ensure_ascii=False)
    if len(inline) <= 100 or not isinstance(value, (dict, list)):
        return inline
    pad = "  " * (indent + 1)
    if isinstance(value, dict):
        items = ["%s%s: %s" % (pad, json.dumps(k, ensure_ascii=False), compact_json(v, indent + 1))
                 for k, v in value.items()]
        return "{\n" + ",\n".join(items) + "\n" + "  " * indent + "}"
    items = [pad + compact_json(v, indent + 1) for v in value]
    return "[\n" + ",\n".join(items) + "\n" + "  " * indent + "]"


def main():
    audio, threshold, without_dictionary = parse_args(sys.argv[1:])
    if not audio.is_file():
        fail("Cannot find the audio file: %s" % audio)

    cli = find_cli()
    if not cli:
        fail("whisperkit-cli is missing. Install it with:\n"
             "    brew install whisperkit-cli\n"
             "(Homebrew: https://brew.sh)")

    settings = app_settings()
    variant = settings.get("whisperModel") or DEFAULT_VARIANT
    language = language_of(settings)
    prompt, term_count = ("", 0) if without_dictionary else dictionary_prompt(settings)

    base = Path.home() / "Library/Application Support/hau-di/WhisperKit"
    model = base / "models/argmaxinc/whisperkit-coreml" / ("openai_whisper-" + variant)
    if not (model / "TextDecoder.mlmodelc").is_dir():
        fail("Cannot find the app's Whisper model:\n    %s\n"
             "Start hau-di once, so that it downloads it." % model)

    # whisperkit-cli writes <name>.json and <name>.srt into an empty work folder; then we move them with the
    # variant suffix, so that the runs with and without the dictionary do not overwrite each other.
    out_dir = audio.parent / "whisper-probe"
    work = out_dir / ".work"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    suffix = "-no-dictionary" if without_dictionary else ""

    command = [
        cli, "transcribe",
        "--audio-path", str(audio),
        "--model-path", str(model),
        "--download-tokenizer-path", str(base),
        "--language", language,
        # As in the app (WhisperKitEngine.transcribe).
        "--temperature-fallback-count", "3",
        "--first-token-log-prob-threshold=-1.5",
        "--skip-special-tokens",
        "--without-timestamps",
        "--chunking-strategy", "vad",
        # Extra: the timing and probability of each word.
        "--word-timestamps",
        "--report", "--report-path", str(work),
    ]
    if prompt:
        command.append("--prompt=" + prompt)

    dictionary = ("%d terms" % min(term_count, 60)) if prompt else "none"
    print("File: %s | language: %s | model: %s | dictionary: %s"
          % (audio.name, language, variant, dictionary))
    print("Running Whisper (the first run can take 1-2 minutes, while Core ML prepares the model)...")
    sys.stdout.flush()

    started = time.time()
    run = subprocess.run(command, capture_output=True, text=True)
    elapsed = time.time() - started

    written = work / (audio.stem + ".json")
    if run.returncode != 0 or not written.exists():
        output = (run.stdout + run.stderr).strip().splitlines()
        fail("whisperkit-cli did not write the result (code %d). Last lines:\n%s"
             % (run.returncode, "\n".join(output[-20:])))

    report = out_dir / (audio.stem + suffix + ".json")
    written.replace(report)
    if (work / (audio.stem + ".srt")).exists():
        (work / (audio.stem + ".srt")).replace(out_dir / (audio.stem + suffix + ".srt"))
    shutil.rmtree(work, ignore_errors=True)

    result = json.loads(report.read_text(encoding="utf-8"))
    segments = result.get("segments") or []
    words = [w for s in segments for w in (s.get("words") or [])]
    timings = result.get("timings") or {}

    print("\nDone in %.1f s (including loading the model)." % elapsed)
    if timings.get("fullPipeline"):
        print("Transcription: %.2f s for %.1f s of audio, of which word probabilities: %.2f s."
              % (timings.get("fullPipeline", 0), timings.get("inputAudioSeconds", 0),
                 timings.get("decodingWordTimestamps", 0)))

    print("\n== Whisper's text ==\n%s" % (result.get("text") or "").strip())

    if not words:
        print("\nWhisper returned no words with probabilities (the \"words\" field is missing).")
    else:
        print("\n== Each word: time, probability (below %d%% is marked) ==" % round(threshold * 100))
        for word in words:
            probability = float(word.get("probability", 0.0))
            filled = int(round(probability * 10))
            bar = "#" * filled + "." * (10 - filled)
            text = word.get("word", "").strip()
            label = OPEN + text + CLOSE if probability < threshold else text
            print("  %5.2f-%5.2f s  %5.1f%%  %s  %s"
                  % (word.get("start", 0), word.get("end", 0), probability * 100, bar, label))

        unsure = sum(1 for w in words if w.get("probability", 1.0) < threshold)
        marked = marked_text(words, threshold)
        print("\n== What Claude would get (%d of %d words below %d%%) ==\n%s"
              % (unsure, len(words), round(threshold * 100), marked))
        (report.with_name(report.stem + "-marked.txt")).write_text(marked + "\n", encoding="utf-8")

    print("\n== Per segment ==")
    for segment in segments:
        temperature = segment.get("temperature", 0) or 0
        print("  %.2f-%.2f s: avgLogprob %.3f, noSpeechProb %.3f, compressionRatio %.2f, temperature %.1f%s"
              % (segment.get("start", 0), segment.get("end", 0), segment.get("avgLogprob", 0),
                 segment.get("noSpeechProb", 0), segment.get("compressionRatio", 0), temperature,
                 " (decoding was retried: the first attempt was too uncertain)" if temperature > 0 else ""))

    print("\n== JSON structure (shortened) ==\n%s" % json_sample(result))
    print("\nFull JSON: %s" % report)


if __name__ == "__main__":
    main()
