#!/usr/bin/env python3
"""Murmur weekly tune: find what Murmur misheard this week, propose vocabulary rules, prove each one
safe, add the safe ones to your vocabulary file and write a report.

    /usr/bin/python3 -I scripts/tune.py run [--dry-run]   the weekly run
    /usr/bin/python3 -I scripts/tune.py undo              restore the vocabulary from before the last run
    /usr/bin/python3 -I scripts/tune.py eval              score the eval recordings with the current vocabulary
    /usr/bin/python3 -I scripts/tune.py schedule [--remove]   run it every Sunday at 10:00 (launchd)

Private data lives in ~/Library/Application Support/Murmur/Tuning (or $MURMUR_TUNING_DIR). Its parent
folder holds the user's Vocabulary.txt and Murmur's History.jsonl. Python 3.9, standard library only.
"""
import argparse
import collections
import datetime as dt
import difflib
import hashlib
import json
import os
import plistlib
import re
import shutil
import sqlite3
import subprocess
import sys

DEFAULT_TUNING = os.path.expanduser("~/Library/Application Support/Murmur/Tuning")
LABEL = "io.github.garfield-oo7.Murmur.tune"
PREFERENCES = os.path.expanduser("~/Library/Preferences/io.github.garfield-oo7.Murmur.plist")
TARGET = 0.97
CHUNK = 120
CLAUDE_TIMEOUT = 20 * 60
MAX_TRIES = 4
TOKEN_CHARS = re.compile(r"[^0-9a-z]")


# ---------------------------------------------------------------- files

class Paths:
    """Every file a run reads or writes. The vocabulary and history sit next to the tuning folder,
    so a test copy (MURMUR_TUNING_DIR) never touches the real ones."""

    def __init__(self, tuning):
        self.tuning = os.path.abspath(tuning)
        root = os.path.dirname(self.tuning)
        self.user_vocabulary = os.path.join(root, "Vocabulary.txt")
        self.history = os.path.join(root, "History.jsonl")
        t = lambda *p: os.path.join(self.tuning, *p)
        self.config, self.about, self.guard = t("config.json"), t("about-me.md"), t("guard.txt")
        self.dictations, self.labels, self.proposals = t("dictations.jsonl"), t("labels.jsonl"), t("proposals.jsonl")
        self.state, self.cache, self.prompts = t("state.json"), t("eval", "cache.json"), t("eval", "prompts.tsv")
        self.recordings, self.backups, self.reports = t("eval", "recordings"), t("backups"), t("reports")
        self.accuracy = t("accuracy.csv")


def tuning_paths():
    return Paths(os.environ.get("MURMUR_TUNING_DIR") or DEFAULT_TUNING)


def read_text(path, default=""):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return default


def read_json(path, default):
    text = read_text(path, None)
    return default if text is None else json.loads(text)


def read_jsonl(path):
    return [json.loads(line) for line in read_text(path).splitlines() if line.strip()]


def write_atomic(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp-{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def write_jsonl(path, rows):
    write_atomic(path, "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))


def write_json(path, value):
    write_atomic(path, json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def load_config(paths):
    raw = read_json(paths.config, None)
    if raw is None:
        sys.exit(f"missing {paths.config}")
    home = lambda p: os.path.expanduser(p) if p else p
    murmur = home(raw.get("murmur") or "~/Applications/Murmur.app/Contents/MacOS/Murmur")
    return {
        "t3_databases": list(raw.get("t3_databases") or []),
        "ssh_hosts": list(raw.get("ssh_hosts") or []),
        "claude": home(raw.get("claude") or "claude"),
        "murmur": murmur,
        "bundled_vocabulary": os.path.join(os.path.dirname(os.path.dirname(murmur)), "Resources", "Vocabulary.txt"),
        "max_rules": int(raw.get("max_rules_per_week", 10)),
        "exclude_apps": set(raw.get("exclude_apps") or []),
    }


# ---------------------------------------------------------------- vocabulary format

def vocabulary_lines(text):
    return [l.strip() for l in text.splitlines() if l.strip() and not l.strip().startswith("#")]


def vocabulary_terms(text):
    """Terms in file order, as Murmur reads them (the part before the first bar)."""
    out = []
    for line in vocabulary_lines(text):
        term = line.split("|")[0].strip()
        if term and term not in out:
            out.append(term)
    return out


def rule_term(line):
    return line.split("|")[0].strip()


def line_problem(line, existing_lines):
    """Why a proposed vocabulary line is unusable, or None. `existing_lines` holds the stripped
    lines of both vocabulary files."""
    if not isinstance(line, str) or "\n" in line or "\r" in line:
        return "not one line"
    line = line.strip()
    if not line or len(line) > 120:
        return "empty or longer than 120 characters"
    if "#" in line:
        return "contains #"
    parts = [p.strip() for p in line.split("|")]
    term, mishearings = parts[0], parts[1:]
    if not term or term.startswith("!"):
        return "no term"
    if len(mishearings) > 6:
        return "more than 6 mishearings"
    for m in mishearings:
        bare = m[1:].strip() if m.startswith("!") else m
        if not bare:
            return "empty mishearing"
        if bare.lower() == term.lower():
            return "mishearing equals the term"
    if line in existing_lines:
        return "already in a vocabulary file"
    return None


_DICTIONARY = None


def is_dictionary_word(word):
    """Same test as Murmur's Vocabulary.isDictionaryWord: the system word list plus simple inflections."""
    global _DICTIONARY
    if _DICTIONARY is None:
        _DICTIONARY = {w.strip().lower() for w in read_text("/usr/share/dict/words").splitlines()}
    w = re.sub(r"[ ._/-]", "", word.lower())
    if not w:
        return False
    if w in _DICTIONARY:
        return True
    for suffix in ("s", "es", "ed", "d", "ing"):
        if w.endswith(suffix) and len(w) > len(suffix) + 2:
            stem = w[:-len(suffix)]
            if stem in _DICTIONARY or stem + "e" in _DICTIONARY:
                return True
            if len(stem) > 1 and stem[-1] == stem[-2] and stem[:-1] in _DICTIONARY:
                return True
    return False


def safe_line(line, vocabulary_text):
    """The proposal as the tuner may apply it, or None if it adds nothing. A rule written by the model must
    never rewrite ordinary speech, so:
    - mishearings either file already has are dropped (restating one would override its setting);
    - a "!" on a mishearing made only of English words is removed, so it only fixes technical sentences
      ("my mamma made dinner" stays);
    - a mishearing mixing English words with anything else is dropped, because Murmur fixes those in every
      sentence and the line format can't say otherwise. The exception is a version number the term also has
      ("Fable 5.2 | paper 5.2"): a word followed by that exact version is the model name."""
    known = set()
    for existing in vocabulary_lines(vocabulary_text):
        for m in existing.split("|")[1:]:
            known.add(m.strip().lstrip("!").strip().lower())
    term, *mishearings = [x.strip() for x in line.split("|")]
    versions = {w for w in term.split() if re.fullmatch(r"\d+(\.\d+)+", w)}
    keep = []
    for m in mishearings:
        bare = m.lstrip("!").strip()
        if bare.lower() in known:
            continue
        english = [is_dictionary_word(w) for w in bare.split()]
        if all(english):
            keep.append(bare)
        elif not any(english):
            keep.append(m)
        elif all(e or w in versions for w, e in zip(bare.split(), english)):
            keep.append(bare)
    if not keep and term in vocabulary_terms(vocabulary_text):
        return None
    return " | ".join([term] + keep)


def rule_format(bundled_text):
    """The header comment of the bundled list, which documents the format."""
    header = []
    for line in bundled_text.splitlines():
        if not line.startswith("#"):
            break
        header.append(line)
    return "\n".join(header) or (
        "One rule per line. `Term` adds a term spelled exactly like that. `Term | heard as | ...` also rewrites "
        "those mishearings to Term. Mishearings made only of real English words are only fixed in technical "
        "sentences unless prefixed with ! (`Murmur | !mural`). Lines starting with # are comments.")


# ---------------------------------------------------------------- Murmur and Claude (the only external tools)

def flatten(text):
    return re.sub(r"[\r\n  ]+", " ", text or "")


def canonicalize(cfg, texts, user_file):
    """What Murmur types for each raw recognition, with `user_file` as the user's vocabulary."""
    if not texts:
        return []
    proc = subprocess.run([cfg["murmur"], "--canonicalize", "--user-vocabulary", user_file],
                          input="".join(flatten(t) + "\n" for t in texts), capture_output=True, text=True, timeout=600)
    out = proc.stdout.split("\n")
    if proc.returncode != 0 or len(out) != len(texts) + 1 or out[-1] != "":
        raise RuntimeError(f"murmur --canonicalize failed ({proc.returncode}, {len(out) - 1} lines for {len(texts)}): "
                           f"{proc.stderr.strip()[:300]}")
    return out[:-1]


def transcribe(cfg, wavs, user_file):
    """Raw recognition for each audio file: {path: heard}, plus the engine used."""
    proc = subprocess.run([cfg["murmur"], "--transcribe", "--json", "--user-vocabulary", user_file] + wavs,
                          capture_output=True, text=True, timeout=1800)
    rows = [json.loads(l) for l in proc.stdout.splitlines() if l.startswith("{")]
    heard = {r["file"]: r["heard"] for r in rows}
    if proc.returncode != 0 or set(heard) != set(wavs):
        raise RuntimeError(f"murmur --transcribe failed ({proc.returncode}): {proc.stderr.strip()[:300]}")
    return heard, (rows[0]["engine"] if rows else "")


def call_claude(cfg, cwd, prompt, system, schema, data):
    """One labelling call. Returns (structured_output, cost in USD)."""
    args = [cfg["claude"], "-p", prompt, "--model", "opus", "--effort", "high", "--tools", "",
            "--no-session-persistence", "--system-prompt", system, "--output-format", "json",
            "--json-schema", json.dumps(schema)]
    try:
        proc = subprocess.run(args, input=data, capture_output=True, text=True, cwd=cwd, timeout=CLAUDE_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise RuntimeError(f"claude did not run: {e}")
    try:
        result = json.loads(proc.stdout)
    except ValueError:
        raise RuntimeError(f"claude exited {proc.returncode} without JSON: {(proc.stderr or proc.stdout).strip()[:300]}")
    output = result.get("structured_output")
    if proc.returncode != 0 or result.get("is_error") or not isinstance(output, dict):
        raise RuntimeError(f"claude failed ({proc.returncode}): {str(result.get('result') or proc.stderr)[:300]}")
    return output, float(result.get("total_cost_usd") or 0)


# ---------------------------------------------------------------- sync and match

def sync(paths, cfg):
    """Adds History.jsonl rows that aren't stored yet. Returns the store, oldest first."""
    store = read_jsonl(paths.dictations)
    seen = {d["date"] for d in store}
    added = [h for h in read_jsonl(paths.history)
             if h.get("date") and h["date"] not in seen and h.get("app") not in cfg["exclude_apps"]]
    unique = {h["date"]: h for h in added}
    if unique:
        store = sorted(store + list(unique.values()), key=lambda d: d["date"])
        write_jsonl(paths.dictations, store)
    return store


def parse_time(ts):
    t = dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)


def norm_word(w):
    return w.lower().strip(".,!?;:'\"")


def message(at, text, env):
    w = [x for x in text.split() if norm_word(x)]
    return {"at": parse_time(at), "w": w, "n": [norm_word(x) for x in w], "env": env}


QUERY = ("select message_id, thread_id, created_at, json_extract(payload_json,'$.text') "
         "from orchestration_v2_projection_messages where role='user' and "
         "coalesce(json_extract(payload_json,'$.createdBy'),'user')='user' and created_at >= ? order by created_at")

REMOTE = """
import json, os, sqlite3, sys
for path in {paths!r}:
    path = os.path.expanduser(path)
    if not os.path.exists(path):
        continue
    con = sqlite3.connect("file:" + path + "?mode=ro", uri=True)
    for mid, tid, at, text in con.execute({query!r}, ({since!r},)):
        if text:
            print(json.dumps({{"at": at, "text": text}}))
"""


def load_messages(cfg, since):
    """User messages sent from `since` on, from every T3 database. Returns (messages, unreachable hosts)."""
    bound = since.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    msgs, unreachable = [], []
    for path in cfg["t3_databases"]:
        path = os.path.expanduser(path)
        if not os.path.exists(path):
            continue
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            msgs += [message(at, text, "local") for _, _, at, text in con.execute(QUERY, (bound,)) if text]
        finally:
            con.close()
    script = REMOTE.format(paths=cfg["t3_databases"], query=QUERY, since=bound)
    for host in cfg["ssh_hosts"]:
        try:
            proc = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, "python3", "-"],
                                  input=script, capture_output=True, text=True, timeout=300)
        except (OSError, subprocess.TimeoutExpired) as e:
            unreachable.append(f"{host} ({e})")
            continue
        if proc.returncode != 0:
            last = (proc.stderr.strip().splitlines() or [f"exit {proc.returncode}"])[-1]
            unreachable.append(f"{host} ({last})")
            continue
        for line in proc.stdout.splitlines():
            if line.startswith("{"):
                r = json.loads(line)
                msgs.append(message(r["at"], r["text"], host))
    msgs.sort(key=lambda m: m["at"])
    return msgs, unreachable


def align(dn, mn):
    sm = difflib.SequenceMatcher(None, dn, mn, autojunk=False)
    blocks = [b for b in sm.get_matching_blocks() if b.size]
    if not blocks:
        return None
    strong = [b for b in blocks if b.size >= 2] or blocks
    lo = max(strong[0].b - strong[0].a, 0)
    hi = min(strong[-1].b + strong[-1].size + (len(dn) - strong[-1].a - strong[-1].size), len(mn))
    return sum(b.size for b in blocks) / max(len(dn), 1), lo, hi


def match(dictation, msgs):
    """The part of a sent message that came from this dictation: (span, score, env), or None."""
    dn = [norm_word(x) for x in (dictation.get("text") or "").split() if norm_word(x)]
    if len(dn) < 4:
        return None
    t = parse_time(dictation["date"])
    best = None
    for m in msgs:
        if m["at"] < t - dt.timedelta(seconds=5):
            continue
        if m["at"] > t + dt.timedelta(hours=3):
            break
        a = align(dn, m["n"])
        if a and (best is None or a[0] > best[0][0]):
            best = (a, m)
    if not best or best[0][0] < 0.55:
        return None
    (score, lo, hi), m = best
    return " ".join(m["w"][lo:hi]), round(score, 3), m["env"]


# ---------------------------------------------------------------- labelling

SYSTEM = """You review speech-recognition output from an on-device dictation app for one speaker. You get
what the app typed for each dictation and, when known, the part of the message the speaker actually sent
after editing it. You flag recognition errors and propose vocabulary rules that fix recurring ones. You
answer only through the requested JSON."""

PROMPT = """The data is on stdin as JSON: who the speaker is (about_me), the bundled and personal vocabulary
files with their rule format, recurring errors that are still unfixed, and this week's dictations.

flags: one per word or phrase in `typed` that is very likely not what was said, when the intended words
are clear (from `sent`, the context or about_me). Also flag wrong capitals or spacing of technical terms and
wrong number formats. Do not flag grammar, filler words, missing punctuation or odd-but-plausible wording.
`heard` must be copied exactly from `typed` (an exact substring), `meant` is what was said. confidence: high
when `sent` or the context makes it certain, medium when very likely, low otherwise. kind: term, name,
common-word, capitalisation or number-format.

proposals: vocabulary lines in the rule format that would fix errors you flagged or the recurring errors.
`line` is one line of the file, `reason` says why, `dates` lists the dictations it fixes. Propose only
what a rule can fix safely: a technical term or name, or a mishearing of one. Never propose a rule for an
ordinary word misheard as another ordinary word ("whether" for "weather") unless the phrase only occurs in
technical talk, because it would rewrite normal speech. Do not repeat a line already in either vocabulary
file. Prefer adding a mishearing to an existing term over adding a new term."""

SCHEMA = {
    "type": "object",
    "properties": {
        "flags": {"type": "array", "items": {
            "type": "object",
            "properties": {"date": {"type": "string"}, "heard": {"type": "string"}, "meant": {"type": "string"},
                           "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
                           "kind": {"type": "string"}},
            "required": ["date", "heard", "meant", "confidence", "kind"], "additionalProperties": False}},
        "proposals": {"type": "array", "items": {
            "type": "object",
            "properties": {"line": {"type": "string"}, "reason": {"type": "string"},
                           "dates": {"type": "array", "items": {"type": "string"}}},
            "required": ["line", "reason", "dates"], "additionalProperties": False}},
    },
    "required": ["flags", "proposals"], "additionalProperties": False,
}


def recurring_errors(labels, typed_by_date, minimum=2):
    """High and medium labels whose words Murmur still types, grouped by what was meant."""
    groups = collections.OrderedDict()
    for l in labels:
        if l.get("confidence") in ("high", "medium") and l["heard"] in typed_by_date.get(l["date"], ""):
            g = groups.setdefault(l["meant"], {"meant": l["meant"], "heard": [], "dates": set()})
            if l["heard"] not in g["heard"]:
                g["heard"].append(l["heard"])
            g["dates"].add(l["date"])
    out = [{"meant": g["meant"], "heard": g["heard"], "dictations": len(g["dates"])}
           for g in groups.values() if len(g["dates"]) >= minimum]
    return sorted(out, key=lambda g: -g["dictations"])


def checked_flags(raw, typed_by_date):
    out = []
    for f in raw or []:
        typed = typed_by_date.get(f.get("date"))
        if (typed is not None and isinstance(f.get("heard"), str) and f["heard"] and f["heard"] in typed
                and isinstance(f.get("meant"), str) and f.get("confidence") in ("high", "medium", "low")):
            out.append({"date": f["date"], "heard": f["heard"], "meant": f["meant"], "confidence": f["confidence"],
                        "kind": str(f.get("kind") or "")})
    return out


def checked_proposals(raw, existing_lines, known_lines, dates, vocabulary_text=""):
    out = []
    for p in raw or []:
        line = p.get("line")
        if line_problem(line, existing_lines):
            continue
        line = safe_line(line.strip(), vocabulary_text)
        if not line or line in existing_lines or line in known_lines:
            continue
        known_lines.add(line.strip())
        out.append({"line": line.strip(), "reason": str(p.get("reason") or ""),
                    "dates": [d for d in p.get("dates") or [] if d in dates]})
    return out


# ---------------------------------------------------------------- the gate

def letters(s):
    return TOKEN_CHARS.sub("", s.lower())


def plain_words(text):
    return [w.strip(".,!?;:\"'()") for w in text.split() if w.strip(".,!?;:\"'()")]


def contains_words(haystack, needle, case):
    if not needle:
        return False
    if not case:
        haystack, needle = [w.lower() for w in haystack], [w.lower() for w in needle]
    n = len(needle)
    return any(haystack[i:i + n] == needle for i in range(len(haystack) - n + 1))


def classify(old, new, sent, labels):
    """Is a changed span backed by evidence? hand-corrected: the sent message has the new words and not
    the old ones. flagged: a high or medium label's heard overlaps the old words and its meant contains
    the new ones. Otherwise unverified. A span that only deletes words is always unverified."""
    if not plain_words(new):
        return "unverified"
    if sent:
        old_w, new_w, sent_w = plain_words(old), plain_words(new), plain_words(sent)
        case = " ".join(old_w).lower() == " ".join(new_w).lower()
        if contains_words(sent_w, new_w, case) and not contains_words(sent_w, old_w, case):
            return "hand-corrected"
    o, n = letters(old), letters(new)
    for l in labels:
        h, m = letters(l["heard"]), letters(l["meant"])
        if l.get("confidence") in ("high", "medium") and o and h and (h in o or o in h) and n and n in m:
            return "flagged"
    return "unverified"


def changed_spans(before, after):
    a, b = before.split(), after.split()
    for tag, a0, a1, b0, b1 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag != "equal":
            yield " ".join(a[a0:a1]), " ".join(b[b0:b1])


def text_gate(dictations, baseline, candidate, labels_by_date, guard, guard_before, guard_after,
              eval_before, eval_after):
    """Judges one proposal from the typed text it would change. `baseline`/`candidate` hold what Murmur
    types for each dictation without and with it, guard_* the same for the guard sentences, and eval_* the
    recordings' word errors (lower is better; None when they couldn't be scored)."""
    fixes, unverified = [], []
    for d, old_text, new_text in zip(dictations, baseline, candidate):
        if old_text == new_text:
            continue
        for old, new in changed_spans(old_text, new_text):
            kind = classify(old, new, d.get("sent"), labels_by_date.get(d["date"], []))
            (unverified if kind == "unverified" else fixes).append(
                {"date": d["date"], "old": old, "new": new, "kind": kind})
    broken = [g for g, before, after in zip(guard, guard_before, guard_after) if before != after]
    why = None
    if broken:
        why = f"changes a guard sentence: {broken[0]!r}"
    elif unverified:
        u = unverified[0]
        why = f"{len(unverified)} unverified change(s), e.g. {u['old']!r} → {u['new']!r}"
    elif eval_after is None:
        why = "no recordings score"
    elif eval_after > eval_before:
        why = f"recordings score drops ({eval_before} → {eval_after} errors)"
    elif not fixes:
        why = "fixes nothing"
    return {"fixes": fixes, "unverified": unverified, "why": why}


# ---------------------------------------------------------------- recordings

NUMBERS = dict(zip("zero one two three four five six seven eight nine ten".split(), map(str, range(11))), twenty="20")
SAME = [(r"\boff[- ]line\b", "offline"), (r"\bInternet\b", "internet"), (r"\bsummarize\b", "summarise"),
        (r"\bhandover\b", "hand over"), (r"\b[pP]\.?[mM]\b\.?", "pm"), (r"(\d):(\d\d)\b", r"\1 \2")]


def score_words(text):
    for pattern, spelling in SAME:
        text = re.sub(pattern, spelling, text)
    text = text.replace("-", " ").replace("/", " ")
    out = []
    for w in text.split():
        core = w.strip(".,!?;:\"'()")
        if core:
            out.append(NUMBERS.get(core.lower(), core))
    return out


def word_errors(hyp, ref):
    """Word edit distance, ignoring edge punctuation, hyphen versus space, digits versus number words,
    the SAME spellings, and capitals on the first word only. Returns (errors, reference words)."""
    h, r = score_words(hyp), score_words(ref)
    same = lambda a, b, first: a == b or (first and a.lower() == b.lower())
    prev = list(range(len(h) + 1))
    for i in range(len(r)):
        cur = [i + 1] + [0] * len(h)
        for j in range(len(h)):
            cur[j + 1] = min(prev[j] + (0 if same(h[j], r[i], i == 0 or j == 0) else 1), prev[j + 1] + 1, cur[j] + 1)
        prev = cur
    return prev[len(h)], len(r)


def recordings(paths):
    """[(id, set, wav, reference text)] for every recording that has both files."""
    out = []
    for line in read_text(paths.prompts).splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        rid, part = line.split("\t")[:2]
        wav, txt = os.path.join(paths.recordings, rid + ".wav"), os.path.join(paths.recordings, rid + ".txt")
        if os.path.exists(wav) and os.path.exists(txt):
            out.append((rid, part, wav, read_text(txt).strip()))
    return out


def fingerprint(cfg, recs, user_text, bundled_text):
    """Everything that changes what the recognizer hears: binary, engine, term list, audio."""
    engine = "dictation"
    try:
        with open(PREFERENCES, "rb") as f:
            engine = plistlib.load(f).get("recognitionEngine", engine)
    except (OSError, plistlib.InvalidFileException):
        pass
    terms = vocabulary_terms(bundled_text + "\n" + user_text)
    st = os.stat(cfg["murmur"])
    parts = [cfg["murmur"], str(st.st_size), str(int(st.st_mtime)), engine, "\n".join(terms)]
    parts += [f"{rid}:{os.path.getsize(wav)}:{int(os.path.getmtime(wav))}" for rid, _, wav, _ in recs]
    return hashlib.sha256("\x00".join(parts).encode()).hexdigest()[:20]


class Eval:
    """Scores the recordings with a vocabulary file. Raw recognition is cached per fingerprint."""

    def __init__(self, paths, cfg, bundled_text):
        self.paths, self.cfg, self.bundled = paths, cfg, bundled_text
        self.recs = recordings(paths)
        self.cache = read_json(paths.cache, {})

    def heard(self, user_file):
        key = fingerprint(self.cfg, self.recs, read_text(user_file), self.bundled)
        if key not in self.cache:
            heard, engine = transcribe(self.cfg, [w for _, _, w, _ in self.recs], user_file)
            self.cache[key] = {"engine": engine, "at": now_iso(),
                               "heard": {rid: heard[w] for rid, _, w, _ in self.recs}}
            keep = sorted(self.cache.items(), key=lambda kv: kv[1]["at"])[-12:]
            self.cache = dict(keep)
            write_json(self.paths.cache, self.cache)
        return self.cache[key]["heard"]

    def score(self, user_file, heard_file=None):
        """{id: (errors, words, typed)}: recognition with `heard_file` (default `user_file`), typed with
        `user_file`. None when there are no recordings or the recognizer fails."""
        if not self.recs:
            return None
        heard = self.heard(heard_file or user_file)
        ids = [rid for rid, _, _, _ in self.recs]
        typed = canonicalize(self.cfg, [heard[rid] for rid in ids], user_file)
        return {rid: word_errors(t, ref) + (t,) for (rid, _, _, ref), t in zip(self.recs, typed)}


def eval_table(recs, scores):
    sets = {rid: part for rid, part, _, _ in recs}
    rows = []
    for key, name in (("all", f"all {len(recs)}"), ("T", "term sentences"), ("P", "plain sentences"),
                      ("tune", "tuning half"), ("heldout", "held-out half")):
        picked = [s for rid, s in scores.items() if key == "all" or rid[0] == key or sets[rid] == key]
        if not picked:
            continue
        e, n = sum(s[0] for s in picked), sum(s[1] for s in picked)
        exact = sum(1 for s in picked if s[0] == 0)
        rows.append(f"  {name:16} {n - e}/{n} words right = {100 * (1 - e / max(n, 1)):.1f}%   "
                    f"{exact}/{len(picked)} sentences perfect")
    return "\n".join(rows)


def eval_summary(scores):
    e, n = sum(s[0] for s in scores.values()), sum(s[1] for s in scores.values())
    return {"errors": e, "words": n, "accuracy": 1 - e / max(n, 1),
            "perfect": sum(1 for s in scores.values() if s[0] == 0), "count": len(scores)}


# ---------------------------------------------------------------- the run

def now_iso():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class TempVocabulary:
    """A vocabulary file next to the backups, for trying candidate rules. Never the user's file."""

    def __init__(self, paths, text, name):
        self.path = os.path.join(paths.tuning, f".candidate-{name}-{os.getpid()}.txt")
        self.text = text

    def __enter__(self):
        write_atomic(self.path, self.text)
        return self.path

    def __exit__(self, *exc):
        if os.path.exists(self.path):
            os.remove(self.path)


def with_lines(text, lines, heading=None):
    if not lines:
        return text
    head = f"\n## {heading}\n" if heading else "\n"
    return text.rstrip("\n") + ("\n" if text.strip() else "") + head + "".join(l + "\n" for l in lines)


def label(paths, cfg, pending, typed_by_date, labels, proposals, user_text, bundled_text, run_date, log):
    """Labels pending dictations in chunks, storing results and advancing labelled_through after each.
    Returns (labelled dictations, flags, cost, error)."""
    existing = set(vocabulary_lines(user_text)) | set(vocabulary_lines(bundled_text))
    known = {p["line"] for p in proposals}
    labelled, flags, cost = [], [], 0.0
    for start in range(0, len(pending), CHUNK):
        chunk = pending[start:start + CHUNK]
        chunk_typed = {d["date"]: typed_by_date[d["date"]] for d in chunk}
        data = {
            "about_me": read_text(paths.about),
            "rule_format": rule_format(bundled_text),
            "bundled_vocabulary": bundled_text,
            "personal_vocabulary": user_text,
            "recurring_errors": recurring_errors(labels, typed_by_date)[:60],
            "dictations": [{"date": d["date"], "app": d.get("app"), "typed": chunk_typed[d["date"]],
                            "sent": d.get("sent")} for d in chunk],
        }
        log(f"labelling {len(chunk)} dictations")
        try:
            output, c = call_claude(cfg, paths.tuning, PROMPT, SYSTEM, SCHEMA, json.dumps(data, ensure_ascii=False))
        except RuntimeError as e:
            return labelled, flags, cost, str(e)
        cost += c
        new_flags = checked_flags(output.get("flags"), chunk_typed)
        source = f"weekly-{run_date}"
        have = {json.dumps(l, sort_keys=True) for l in labels}
        for f in new_flags:
            row = dict(f, against=chunk_typed[f["date"]], source=source)
            if json.dumps(row, sort_keys=True) not in have:
                labels.append(row)
        for p in checked_proposals(output.get("proposals"), existing, known, set(chunk_typed),
                                   bundled_text + "\n" + user_text):
            proposals.append(dict(p, proposed_at=run_date, status="pending", why="", tries=0))
        write_jsonl(paths.labels, labels)
        write_jsonl(paths.proposals, proposals)
        write_json(paths.state, {"labelled_through": chunk[-1]["date"]})
        labelled += chunk
        flags += new_flags
    return labelled, flags, cost, None


def gate(paths, cfg, store, typed_all, labels, pending_props, user_text, bundled_text, ev, log):
    """Judges every pending proposal by code. Returns (accepted, verdict by line)."""
    with_heard = [d for d in store if (d.get("heard") or "").strip()]
    heard = [d["heard"] for d in with_heard]
    baseline = [typed_all[d["date"]] for d in with_heard]
    guard = [g.strip() for g in read_text(paths.guard).splitlines() if g.strip() and not g.startswith("#")]
    by_date = collections.defaultdict(list)
    for l in labels:
        by_date[l["date"]].append(l)

    with TempVocabulary(paths, user_text, "base") as base_file:
        guard_base = canonicalize(cfg, guard, base_file)
        try:
            base_scores = ev.score(base_file)
            eval_heard = ev.heard(base_file) if base_scores else {}
        except RuntimeError as e:
            log(f"recordings unavailable: {e}")
            base_scores, eval_heard = None, {}
    eval_refs = {rid: ref for rid, _, _, ref in ev.recs}
    eval_ids = sorted(eval_heard)
    base_errors = sum(s[0] for s in base_scores.values()) if base_scores else None

    verdicts = {}
    for p in pending_props:
        with TempVocabulary(paths, with_lines(user_text, [p["line"]]), "one") as candidate:
            out = canonicalize(cfg, heard + guard + [eval_heard[rid] for rid in eval_ids], candidate)
        cand, cand_guard, cand_eval = out[:len(heard)], out[len(heard):len(heard) + len(guard)], out[len(heard) + len(guard):]
        cand_errors = sum(word_errors(t, eval_refs[rid])[0] for rid, t in zip(eval_ids, cand_eval)) if base_scores else None
        v = text_gate(with_heard, baseline, cand, by_date, guard, guard_base, cand_guard, base_errors, cand_errors)
        v["adds_term"] = rule_term(p["line"]) not in set(vocabulary_terms(bundled_text + "\n" + user_text))
        verdicts[p["line"]] = v

    term_lines = [l for l, v in verdicts.items() if not v["why"] and v["adds_term"]]
    if term_lines:
        log(f"audio gate for {len(term_lines)} new term(s)")
        why = None
        try:
            with TempVocabulary(paths, with_lines(user_text, term_lines), "terms") as candidate:
                scores = ev.score(candidate)
            changed = [rid for rid in scores if rid.startswith("P") and scores[rid][2] != base_scores[rid][2]]
            if sum(s[0] for s in scores.values()) > base_errors:
                why = "audio gate: recordings score drops"
            elif changed:
                why = f"audio gate: plain recording {changed[0]} changes"
        except RuntimeError as e:
            why = f"audio gate: {e}"
        for l in term_lines:
            verdicts[l]["why"] = why

    passing = sorted((l for l, v in verdicts.items() if not v["why"]), key=lambda l: -len(verdicts[l]["fixes"]))
    for l in passing[cfg["max_rules"]:]:
        verdicts[l]["why"] = "over the weekly limit"
    return passing[:cfg["max_rules"]], verdicts


def run(dry_run, log=print):
    paths = tuning_paths()
    cfg = load_config(paths)
    run_date = dt.date.today().isoformat()
    for name in os.listdir(paths.tuning):  # left behind by a run that crashed
        if name.startswith(".candidate-") or ".tmp-" in name:
            os.remove(os.path.join(paths.tuning, name))
    bundled_text = read_text(cfg["bundled_vocabulary"])
    user_text = read_text(paths.user_vocabulary)

    store = sync(paths, cfg)
    state = read_json(paths.state, {})
    through = state.get("labelled_through", "")
    pending = [d for d in store if d["date"] > through and (d.get("heard") or "").strip()]
    log(f"{len(store)} dictations stored, {len(pending)} to label")

    with TempVocabulary(paths, user_text, "base") as base_file:
        typed = canonicalize(cfg, [d.get("heard") or "" for d in store], base_file)
    typed_by_date = {d["date"]: t for d, t in zip(store, typed)}

    unreachable = []
    if pending:
        msgs, unreachable = load_messages(cfg, parse_time(pending[0]["date"]) - dt.timedelta(seconds=5))
        for d in pending:
            m = match(d, msgs)
            if m:
                d["sent"], d["sent_score"], d["sent_env"] = m
        write_jsonl(paths.dictations, store)

    labels, proposals = read_jsonl(paths.labels), read_jsonl(paths.proposals)
    labelled, flags, cost, error = label(paths, cfg, pending, typed_by_date, labels, proposals,
                                         user_text, bundled_text, run_date, log)
    report = {"run_date": run_date, "dry_run": dry_run, "labelled": labelled, "flags": flags, "cost": cost,
              "error": error, "unreachable": unreachable, "typed_by_date": typed_by_date}
    if error:
        return finish(paths, cfg, report, labels, store, user_text, bundled_text, None, [], {}, {}, log)

    # A crash between writing the vocabulary and marking proposals applied leaves them pending.
    in_file = set(vocabulary_lines(user_text))
    for p in proposals:
        if p["status"] == "pending" and p["line"] in in_file and not dry_run:
            p["status"], p["why"] = "applied", "found in the vocabulary file"
    for p in proposals:  # proposals stored before safe_line existed, or made redundant since
        if p["status"] == "pending":
            line = safe_line(p["line"], bundled_text + "\n" + user_text)
            if not line and not dry_run:
                p["status"], p["why"] = "rejected", "adds nothing the vocabulary lacks"
            elif line:
                p["line"] = line
    to_gate = [p for p in proposals if p["status"] == "pending" and p["line"] not in in_file]
    ev = Eval(paths, cfg, bundled_text)
    accepted, verdicts = gate(paths, cfg, store, typed_by_date, labels, to_gate, user_text, bundled_text, ev, log)

    rejected = []
    if not dry_run:
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup = f"Vocabulary-{stamp}.txt"
        if accepted and read_text(paths.user_vocabulary) != user_text:
            for line in accepted:
                verdicts[line]["why"] = "the vocabulary file changed during the run"
            accepted = []
        if accepted:
            write_atomic(os.path.join(paths.backups, backup), user_text)
            write_atomic(paths.user_vocabulary, with_lines(user_text, accepted, f"Weekly tune {run_date}"))
        for p in to_gate:
            v = verdicts[p["line"]]
            if p["line"] in accepted:
                p.update(status="applied", why="", backup=backup, applied_at=run_date)
            else:
                p["tries"] = p.get("tries", 0) + 1
                p["why"] = v["why"]
                if p["tries"] >= MAX_TRIES:
                    p["status"] = "rejected"
                    rejected.append(p)
        write_jsonl(paths.proposals, proposals)
    return finish(paths, cfg, report, labels, store, user_text, bundled_text, ev, accepted, verdicts,
                  {p["line"]: p for p in to_gate}, log, rejected)


# ---------------------------------------------------------------- report

def finish(paths, cfg, report, labels, store, user_text, bundled_text, ev, accepted, verdicts, gated, log,
           rejected=()):
    run_date, dry = report["run_date"], report["dry_run"]
    typed_by_date = report["typed_by_date"]
    labelled = report["labelled"]
    serious = [f for f in report["flags"] if f["confidence"] in ("high", "medium")]
    words = sum(len(typed_by_date[d["date"]].split()) for d in labelled)
    flagged_words = sum(len(f["heard"].split()) for f in serious)
    est = 1 - flagged_words / words if words else None

    new_text = with_lines(user_text, accepted, f"Weekly tune {run_date}")
    est_after, eval_before, eval_after, after_typed = est, None, None, typed_by_date
    if ev is not None:
        with TempVocabulary(paths, user_text, "base") as base_file, TempVocabulary(paths, new_text, "new") as new_file:
            if accepted:
                after = canonicalize(cfg, [d.get("heard") or "" for d in store], new_file)
                after_typed = {d["date"]: t for d, t in zip(store, after)}
                words_after = sum(len(after_typed[d["date"]].split()) for d in labelled)
                left = sum(len(f["heard"].split()) for f in serious if f["heard"] in after_typed[f["date"]])
                est_after = 1 - left / words_after if words_after else None
            try:
                before_scores = ev.score(base_file)
                after_scores = ev.score(new_file)
                eval_before = eval_summary(before_scores) if before_scores else None
                eval_after = eval_summary(after_scores) if after_scores else None
            except RuntimeError as e:
                log(f"recordings unavailable: {e}")

    pct = lambda x: "n/a" if x is None else f"{100 * x:.1f}%"
    title = f"# Murmur weekly tune {run_date}" + (" (dry run: nothing applied)" if dry else "")
    lines = [title, ""]
    if report["error"]:
        lines += ["**Labelling stopped:** " + report["error"],
                  "labelled_through was not advanced past the failed chunk; the next run retries it.", ""]
    apps = collections.Counter(d.get("app") for d in labelled)
    lines += [f"Labelled {len(labelled)} dictations ({words} words) from: "
              + (", ".join(f"{a} {n}" for a, n in apps.most_common()) or "none")
              + f". Labelling cost ${report['cost']:.2f}.",
              f"Flags: {len(serious)} high or medium, {len(report['flags']) - len(serious)} low."]
    if report["unreachable"]:
        lines.append("Unreachable hosts (their messages weren't matched): " + ", ".join(report["unreachable"]) + ".")
    lines += ["", "## Accuracy", "",
              f"Estimated by a model, not measured: {pct(est)} of typed words were right this week "
              f"(target {pct(TARGET)}), {pct(est_after)} with this run's rules."]
    if eval_before and eval_after:
        lines.append(f"Recordings: {eval_after['words'] - eval_after['errors']}/{eval_after['words']} words right "
                     f"({pct(eval_after['accuracy'])}), {eval_after['perfect']}/{eval_after['count']} sentences "
                     f"perfect with the new vocabulary (before: {pct(eval_before['accuracy'])}, "
                     f"{eval_before['perfect']} perfect).")
    else:
        lines.append("Recordings: not scored.")

    lines += ["", "## Would apply" if dry else "## Applied", ""]
    for l in accepted:
        fixes = verdicts[l]["fixes"]
        examples = "; ".join(f"{f['old']!r} → {f['new']!r} ({f['kind']})" for f in fixes[:2])
        lines.append(f"- `{l}`: fixes {len(fixes)}. {examples}")
    if not accepted:
        lines.append("- nothing")
    gone = {p["line"] for p in rejected}
    waiting = [(l, v["why"]) for l, v in verdicts.items() if l not in accepted and l not in gone]
    if waiting:
        lines += ["", "## Still pending", ""]
        lines += [f"- `{l}`: {why}" + (f" (try {gated[l].get('tries', 0)})" if l in gated else "") for l, why in waiting]
    if rejected:
        lines += ["", "## Rejected after 4 runs", ""] + [f"- `{p['line']}`: {p['why']}" for p in rejected]
    common = recurring_errors(labels, after_typed)[:10]
    if common:
        lines += ["", "## Most common errors still unfixed", ""]
        lines += [f"- {', '.join(repr(h) for h in g['heard'][:3])} for {g['meant']!r}: {g['dictations']} dictations"
                  for g in common]
    text = "\n".join(lines) + "\n"
    write_atomic(os.path.join(paths.reports, f"{run_date}.md"), text)

    row = [run_date, str(dry).lower(), str(len(labelled)), str(words), str(flagged_words),
           "" if est is None else f"{est:.4f}", "" if not eval_after else f"{eval_after['accuracy']:.4f}",
           str(0 if dry else len(accepted)), f"{report['cost']:.4f}"]
    header = "run_date,dry_run,dictations,words,flagged_words,est_accuracy,eval_accuracy,rules_added,cost_usd"
    rows = [r for r in read_text(paths.accuracy).splitlines()[1:] if r and r.split(",")[:2] != row[:2]]
    write_atomic(paths.accuracy, "\n".join([header] + rows + [",".join(row)]) + "\n")

    if not os.environ.get("MURMUR_TUNE_QUIET"):
        summary = (f"{'Dry run: ' if dry else ''}{len(accepted)} rule(s), estimated accuracy {pct(est_after)}"
                   if not report["error"] else "Labelling failed, see the report")
        subprocess.run(["osascript", "-e", f"display notification {json.dumps(summary)} with title \"Murmur tune\""],
                       capture_output=True)
    log(text)
    return 1 if report["error"] else 0


# ---------------------------------------------------------------- undo, eval, schedule

def undo(log=print):
    paths = tuning_paths()
    backups = sorted(f for f in os.listdir(paths.backups) if re.fullmatch(r"Vocabulary-\d{8}T\d{6}Z\.txt", f)) \
        if os.path.isdir(paths.backups) else []
    if not backups:
        log("nothing to undo")
        return 1
    newest = backups[-1]
    source = os.path.join(paths.backups, newest)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    write_atomic(os.path.join(paths.backups, f"Vocabulary-{stamp}.before-undo.txt"), read_text(paths.user_vocabulary))
    write_atomic(paths.user_vocabulary, read_text(source))
    proposals = read_jsonl(paths.proposals)
    undone = [p for p in proposals if p.get("status") == "applied" and p.get("backup") == newest]
    for p in undone:
        p["status"], p["why"] = "undone", f"undo on {dt.date.today().isoformat()}"
    write_jsonl(paths.proposals, proposals)
    os.replace(source, source[:-len(".txt")] + ".undone.txt")
    log(f"restored {newest}; {len(undone)} rule(s) marked undone")
    return 0


def evaluate(log=print):
    paths = tuning_paths()
    cfg = load_config(paths)
    ev = Eval(paths, cfg, read_text(cfg["bundled_vocabulary"]))
    try:
        scores = ev.score(paths.user_vocabulary)
    except RuntimeError as e:
        log(str(e))
        return 1
    if not scores:
        log("no recordings")
        return 1
    log(eval_table(ev.recs, scores))
    return 0


def launch_agent(script, claude):
    path = os.pathsep.join([os.path.dirname(claude), "/usr/local/bin", "/opt/homebrew/bin",
                            "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    log_file = os.path.expanduser("~/Library/Logs/Murmur/tune.log")
    return {
        "Label": LABEL,
        "ProgramArguments": ["/usr/bin/python3", "-I", os.path.abspath(script), "run"],
        "StartCalendarInterval": {"Weekday": 0, "Hour": 10, "Minute": 0},
        "StandardOutPath": log_file,
        "StandardErrorPath": log_file,
        "EnvironmentVariables": {"PATH": path},
    }


def schedule(remove, log=print):
    plist = os.path.expanduser(f"~/Library/LaunchAgents/{LABEL}.plist")
    domain = f"gui/{os.getuid()}"
    subprocess.run(["launchctl", "bootout", f"{domain}/{LABEL}"], capture_output=True)
    if remove:
        if os.path.exists(plist):
            os.remove(plist)
        log(f"removed {plist}")
        return 0
    cfg = load_config(tuning_paths())
    agent = launch_agent(__file__, cfg["claude"])
    os.makedirs(os.path.dirname(agent["StandardOutPath"]), exist_ok=True)
    os.makedirs(os.path.dirname(plist), exist_ok=True)
    tmp = plist + ".tmp"
    with open(tmp, "wb") as f:
        plistlib.dump(agent, f)
    os.replace(tmp, plist)
    proc = subprocess.run(["launchctl", "bootstrap", domain, plist], capture_output=True, text=True)
    if proc.returncode != 0:
        log(f"launchctl bootstrap failed: {proc.stderr.strip()}")
        return 1
    log(f"scheduled: Sundays 10:00, log in {agent['StandardOutPath']}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("run").add_argument("--dry-run", action="store_true")
    sub.add_parser("undo")
    sub.add_parser("eval")
    sub.add_parser("schedule").add_argument("--remove", action="store_true")
    args = parser.parse_args(argv)
    if args.command == "run":
        try:
            return run(args.dry_run)
        except Exception as e:  # a scheduled run must never fail silently
            if not os.environ.get("MURMUR_TUNE_QUIET"):
                text = f"Failed: {str(e)[:120]}. See ~/Library/Logs/Murmur/tune.log"
                subprocess.run(["osascript", "-e", f"display notification {json.dumps(text)} with title \"Murmur tune\""],
                               capture_output=True)
            raise
    if args.command == "undo":
        return undo()
    if args.command == "eval":
        return evaluate()
    return schedule(args.remove)


if __name__ == "__main__":
    sys.exit(main())
