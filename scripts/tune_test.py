#!/usr/bin/env python3
"""Tests for tune.py. Run with /usr/bin/python3 -I scripts/tune_test.py

Murmur (canonicalize, transcribe) is replaced by a small Python stand-in and `claude` by a stub script,
so nothing here runs the real tools or touches the real tuning folder."""
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tune  # noqa: E402


def fake_canonicalize(cfg, texts, user_file):
    """Applies `Term | mishearing` rules from the user file, whole words, ignoring case."""
    rules = []
    for line in tune.vocabulary_lines(tune.read_text(user_file)):
        parts = [p.strip() for p in line.split("|")]
        rules += [(m.lstrip("!"), parts[0]) for m in parts[1:]]
    out = []
    for text in texts:
        text = tune.flatten(text)
        for heard, term in rules:
            text = re.sub(r"\b%s\b" % re.escape(heard), term, text, flags=re.I)
        out.append(text)
    return out


def fake_transcribe(cfg, wavs, user_file):
    """The recognizer hears what <id>.heard says, whatever the vocabulary."""
    return {w: tune.read_text(w[:-4] + ".heard").strip() for w in wavs}, "dictation"


D1, D2, D3 = "2026-01-05T10:00:00Z", "2026-01-05T11:00:00Z", "2026-01-06T09:00:00Z"
HISTORY = [
    {"app": "Notes", "date": D1, "heard": "open the bloo widjet panel", "text": "open the bloo widjet panel"},
    {"app": "Notes", "date": D2, "heard": "ship the bloo widjet today", "text": "ship the bloo widjet today"},
    {"app": "Notes", "date": D3, "heard": "the sky is blue today", "text": "the sky is blue today"},
    {"app": "Private", "date": "2026-01-06T10:00:00Z", "heard": "skip me", "text": "skip me"},
]
CLAUDE_RESULT = {
    "type": "result", "is_error": False, "total_cost_usd": 0.5,
    "structured_output": {
        "flags": [
            {"date": D1, "heard": "bloo widjet", "meant": "BluWidget", "confidence": "high", "kind": "term"},
            {"date": D3, "heard": "blue", "meant": "Zed", "confidence": "low", "kind": "term"},
            {"date": D1, "heard": "not in the text", "meant": "x", "confidence": "high", "kind": "term"},
            {"date": "2020-01-01T00:00:00Z", "heard": "open", "meant": "x", "confidence": "high", "kind": "term"},
        ],
        "proposals": [
            {"line": "BluWidget | bloo widjet", "reason": "product name", "dates": [D1, D2]},
            {"line": "Zed | blue", "reason": "too broad", "dates": [D3]},
            {"line": "Fawx | fox", "reason": "breaks a guard sentence", "dates": [D1]},
            {"line": "Bad # comment", "reason": "invalid", "dates": []},
        ],
    },
}
STUB = """#!/bin/sh
# Stand-in for claude: ignores its arguments and prints a fixed result.
cat > /dev/null
echo call >> "$(dirname "$0")/calls.log"
cat "$(dirname "$0")/result.json"
"""


class Folder(unittest.TestCase):
    """A temporary Murmur folder: Vocabulary.txt, History.jsonl and Tuning/."""

    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root)
        self.tuning = os.path.join(self.root, "Murmur", "Tuning")
        rec = os.path.join(self.tuning, "eval", "recordings")
        os.makedirs(rec)
        bin_dir = os.path.join(self.root, "bin")
        os.makedirs(bin_dir)
        self.claude = os.path.join(bin_dir, "claude")
        self.write(self.claude, STUB)
        os.chmod(self.claude, 0o755)
        self.write(os.path.join(bin_dir, "result.json"), json.dumps(CLAUDE_RESULT))
        murmur = os.path.join(bin_dir, "Murmur")
        self.write(murmur, "")
        t3 = os.path.join(self.root, "t3.sqlite")
        con = sqlite3.connect(t3)
        con.execute("create table orchestration_v2_projection_messages "
                    "(message_id, thread_id, created_at, role, payload_json)")
        con.execute("insert into orchestration_v2_projection_messages values (?, ?, ?, ?, ?)",
                    ("m1", "t1", "2026-01-05T11:00:30.000Z", "user", json.dumps({"text": "ship the BluWidget today please"})))
        con.commit()
        con.close()
        self.write(os.path.join(self.tuning, "config.json"), json.dumps({
            "t3_databases": [t3], "ssh_hosts": [], "claude": self.claude, "murmur": murmur,
            "max_rules_per_week": 5, "exclude_apps": ["Private"]}))
        self.write(os.path.join(self.tuning, "about-me.md"), "A test speaker.\n")
        self.write(os.path.join(self.tuning, "guard.txt"), "# never change these\nThe quick fox naps.\n")
        self.write(os.path.join(self.tuning, "state.json"), json.dumps({"labelled_through": "2026-01-01T00:00:00Z"}))
        self.write(os.path.join(self.tuning, "eval", "prompts.tsv"), "P01\ttune\tA plain sentence.\nT01\theldout\tUse BluWidget now.\n")
        for rid, ref, heard in (("P01", "A plain sentence.", "A plain sentence."),
                                ("T01", "Use BluWidget now.", "Use bloo widjet now.")):
            self.write(os.path.join(rec, rid + ".wav"), "RIFF")
            self.write(os.path.join(rec, rid + ".txt"), ref + "\n")
            self.write(os.path.join(rec, rid + ".heard"), heard + "\n")
        self.vocabulary = os.path.join(self.root, "Murmur", "Vocabulary.txt")
        self.write(self.vocabulary, "# mine\nKnownTerm\n")
        self.write(os.path.join(self.root, "Murmur", "History.jsonl"), "".join(json.dumps(h) + "\n" for h in HISTORY))

        env = {"MURMUR_TUNING_DIR": self.tuning, "MURMUR_TUNE_QUIET": "1"}
        old_env = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        self.addCleanup(lambda: [os.environ.pop(k) if v is None else os.environ.__setitem__(k, v)
                                 for k, v in old_env.items()])
        for name, fake in (("canonicalize", fake_canonicalize), ("transcribe", fake_transcribe)):
            self.addCleanup(setattr, tune, name, getattr(tune, name))
            setattr(tune, name, fake)
        paths = tune.tuning_paths()
        for p in (paths.tuning, paths.user_vocabulary, paths.history):
            self.assertTrue(p.startswith(self.root + os.sep), p)

    def write(self, path, text):
        with open(path, "w") as f:
            f.write(text)

    def read(self, path):
        with open(path) as f:
            return f.read()

    def jsonl(self, name):
        return tune.read_jsonl(os.path.join(self.tuning, name))

    def run_tune(self, dry_run):
        return tune.run(dry_run, log=lambda *a: None)


class ClassifyTests(unittest.TestCase):
    def test_hand_corrected_when_sent_has_new_words_and_not_old(self):
        self.assertEqual(tune.classify("blue widget", "BluWidget", "ship the BluWidget today", []), "hand-corrected")

    def test_sent_with_old_words_is_not_evidence(self):
        self.assertEqual(tune.classify("blue", "Zed", "the Zed is blue", []), "unverified")

    def test_capitals_only_count_when_they_are_the_change(self):
        self.assertEqual(tune.classify("PRS.", "PRs.", "merge the PRs", []), "hand-corrected")
        self.assertEqual(tune.classify("PRS.", "PRs.", "merge the PRS", []), "unverified")

    def test_flagged_by_a_label_that_overlaps_the_old_words(self):
        label = {"heard": "GPT 6.1 soul", "meant": "GPT-6.1 Sol", "confidence": "medium"}
        self.assertEqual(tune.classify("6.1 soul", "6.1 Sol", None, [label]), "flagged")

    def test_low_confidence_or_unrelated_labels_do_not_verify(self):
        low = {"heard": "blue", "meant": "Zed", "confidence": "low"}
        other = {"heard": "panel", "meant": "Zed", "confidence": "high"}
        self.assertEqual(tune.classify("blue", "Zed", None, [low, other]), "unverified")

    def test_a_deletion_is_never_verified(self):
        label = {"heard": "um", "meant": "", "confidence": "high"}
        self.assertEqual(tune.classify("um", "", "hello", [label]), "unverified")


class GateTests(unittest.TestCase):
    dictations = [{"date": D1, "sent": None}, {"date": D3, "sent": None}]
    labels = {D1: [{"heard": "blue widget", "meant": "BluWidget", "confidence": "high"}]}
    guard = ["The quick fox naps."]

    def judge(self, candidate, guard_after=None, eval_after=3):
        baseline = ["open the blue widget panel", "the sky is blue today"]
        return tune.text_gate(self.dictations, baseline, candidate, self.labels, self.guard, self.guard,
                              guard_after or self.guard, 3, eval_after)

    def test_a_verified_fix_passes(self):
        v = self.judge(["open the BluWidget panel", "the sky is blue today"])
        self.assertIsNone(v["why"])
        self.assertEqual(len(v["fixes"]), 1)

    def test_a_rule_with_an_unverified_change_is_rejected(self):
        v = self.judge(["open the Zed widget panel", "the sky is Zed today"])
        self.assertIn("unverified", v["why"])

    def test_a_rule_that_touches_a_guard_sentence_is_rejected(self):
        v = self.judge(["open the BluWidget panel", "the sky is blue today"], guard_after=["The quick Fawx naps."])
        self.assertIn("guard", v["why"])

    def test_a_rule_that_lowers_the_recordings_score_is_rejected(self):
        v = self.judge(["open the BluWidget panel", "the sky is blue today"], eval_after=4)
        self.assertIn("recordings", v["why"])

    def test_without_a_recordings_score_nothing_passes(self):
        v = self.judge(["open the BluWidget panel", "the sky is blue today"], eval_after=None)
        self.assertIsNotNone(v["why"])


class LineTests(unittest.TestCase):
    existing = {"Tailscale", "TouchDeck | touch desk"}

    def test_valid_lines(self):
        for line in ("Ollama", "Ollama | all up | a llama", "Murmur | !mural", "GPT-6.1 Sol | GPT 6.1 soul"):
            self.assertIsNone(tune.line_problem(line, self.existing), line)

    def test_invalid_lines(self):
        for line in ("", "Two\nlines", "x" * 121, "Term # note", "| orphan", "Term | ", "Term | !",
                     "Term | term", "Term | a | b | c | d | e | f | g", "Tailscale", "TouchDeck | touch desk", None):
            self.assertIsNotNone(tune.line_problem(line, self.existing), repr(line))


class SafeLineTests(unittest.TestCase):
    vocabulary = "Murmur | !mural\nTouchDeck | touch desk\nTailscale"

    def test_a_model_rule_never_fixes_ordinary_english_everywhere(self):
        self.assertEqual(tune.safe_line("Murmur | !mamma", self.vocabulary), "Murmur | mamma")

    def test_made_up_words_keep_their_bang(self):
        self.assertEqual(tune.safe_line("Murmur | !murmr", self.vocabulary), "Murmur | !murmr")

    def test_known_mishearings_are_dropped_so_their_setting_stays(self):
        self.assertEqual(tune.safe_line("Murmur | !mural | !mamma", self.vocabulary), "Murmur | mamma")
        self.assertIsNone(tune.safe_line("TouchDeck | !touch desk", self.vocabulary))

    def test_mixed_mishearings_that_would_fire_everywhere_are_dropped(self):
        self.assertEqual(tune.safe_line("Fable 5.2 | paper v5.2 | fabel", self.vocabulary),
                         "Fable 5.2 | fabel")

    def test_a_word_before_the_terms_own_version_is_the_model_name(self):
        self.assertEqual(tune.safe_line("Fable 5.2 | favorable 5.2 | paper 5.2 | paper 6.2", self.vocabulary),
                         "Fable 5.2 | favorable 5.2 | paper 5.2")

    def test_a_new_term_without_mishearings_is_kept(self):
        self.assertEqual(tune.safe_line("Ollama", self.vocabulary), "Ollama")


class ScoreTests(unittest.TestCase):
    def test_counts_word_errors_against_the_reference(self):
        self.assertEqual(tune.word_errors("Open a pull request on GitHub.", "Open a pull request on GitHub."), (0, 6))
        self.assertEqual(tune.word_errors("Open a full request on github", "Open a pull request on GitHub."), (2, 6))
        self.assertEqual(tune.word_errors("open a request", "Open a pull request."), (1, 4))

    def test_ignores_what_the_scorer_treats_as_the_same(self):
        self.assertEqual(tune.word_errors("The train leaves at 9:45 p.m. today", "The train leaves at 9 45 PM today."), (0, 8))
        self.assertEqual(tune.word_errors("one two-three, off-line", "1 2 3 offline"), (0, 4))
        self.assertEqual(tune.word_errors("GPT 6.1", "GPT-6.1"), (0, 2))

    def test_capitals_count_except_on_the_first_word(self):
        self.assertEqual(tune.word_errors("hello World", "Hello world"), (1, 2))


class StoreTests(Folder):
    def test_sync_twice_gives_the_same_store(self):
        paths, cfg = tune.tuning_paths(), tune.load_config(tune.tuning_paths())
        first = tune.sync(paths, cfg)
        once = self.read(paths.dictations)
        second = tune.sync(paths, cfg)
        self.assertEqual(self.read(paths.dictations), once)
        self.assertEqual(first, second)
        self.assertEqual([d["date"] for d in first], [D1, D2, D3])


class RunTests(Folder):
    def test_dry_run_never_writes_the_vocabulary_file(self):
        before = self.read(self.vocabulary)
        self.assertEqual(self.run_tune(dry_run=True), 0)
        self.assertEqual(self.read(self.vocabulary), before)
        self.assertFalse(os.path.exists(os.path.join(self.tuning, "backups")))
        self.assertEqual({p["status"] for p in self.jsonl("proposals.jsonl")}, {"pending"})
        self.assertEqual([p["line"] for p in self.jsonl("proposals.jsonl")],
                         ["BluWidget | bloo widjet", "Zed | blue", "Fawx | fox"])
        report = self.read(os.path.join(self.tuning, "reports", os.listdir(os.path.join(self.tuning, "reports"))[0]))
        self.assertIn("dry run", report)
        self.assertIn("BluWidget | bloo widjet", report.split("## Would apply")[1].split("##")[0])
        self.assertEqual(json.loads(self.read(os.path.join(self.tuning, "state.json")))["labelled_through"], D3)

    def test_a_real_run_after_a_dry_run_reuses_the_labels_and_applies_only_safe_rules(self):
        self.run_tune(dry_run=True)
        self.assertEqual(self.run_tune(dry_run=False), 0)
        self.assertEqual(self.read(os.path.join(self.root, "bin", "calls.log")).count("call"), 1)
        vocabulary = self.read(self.vocabulary)
        self.assertIn("BluWidget | bloo widjet\n", vocabulary)
        self.assertNotIn("Zed", vocabulary)
        self.assertNotIn("Fawx", vocabulary)
        status = {p["line"]: p["status"] for p in self.jsonl("proposals.jsonl")}
        self.assertEqual(status, {"BluWidget | bloo widjet": "applied", "Zed | blue": "pending", "Fawx | fox": "pending"})

    def test_a_failed_labelling_call_does_not_advance(self):
        self.write(self.claude, "#!/bin/sh\ncat > /dev/null\necho 'boom' >&2\nexit 1\n")
        self.assertEqual(self.run_tune(dry_run=False), 1)
        self.assertEqual(json.loads(self.read(os.path.join(self.tuning, "state.json")))["labelled_through"],
                         "2026-01-01T00:00:00Z")
        report = os.listdir(os.path.join(self.tuning, "reports"))
        self.assertIn("Labelling stopped", self.read(os.path.join(self.tuning, "reports", report[0])))

    def test_an_edit_made_during_the_run_is_never_overwritten(self):
        self.write(self.claude, STUB + 'echo "MyEdit" >> "%s"\n' % self.vocabulary)
        self.assertEqual(self.run_tune(dry_run=False), 0)
        self.assertEqual(self.read(self.vocabulary), "# mine\nKnownTerm\nMyEdit\n")
        self.assertEqual({p["status"] for p in self.jsonl("proposals.jsonl")}, {"pending"})

    def test_undo_restores_the_backup(self):
        before = self.read(self.vocabulary)
        self.run_tune(dry_run=False)
        self.assertNotEqual(self.read(self.vocabulary), before)
        self.assertEqual(tune.undo(log=lambda *a: None), 0)
        self.assertEqual(self.read(self.vocabulary), before)
        status = {p["line"]: p["status"] for p in self.jsonl("proposals.jsonl")}
        self.assertEqual(status["BluWidget | bloo widjet"], "undone")
        self.assertEqual(tune.undo(log=lambda *a: None), 1)
        self.assertEqual(self.read(self.vocabulary), before)


class ScheduleTests(unittest.TestCase):
    def test_launch_agent_runs_weekly_with_claude_on_the_path(self):
        agent = tune.launch_agent("/opt/murmur/scripts/tune.py", "/opt/tools/bin/claude")
        self.assertEqual(agent["ProgramArguments"], ["/usr/bin/python3", "-I", "/opt/murmur/scripts/tune.py", "run"])
        self.assertEqual(agent["StartCalendarInterval"], {"Weekday": 0, "Hour": 10, "Minute": 0})
        self.assertIn("/opt/tools/bin", agent["EnvironmentVariables"]["PATH"].split(":"))


if __name__ == "__main__":
    unittest.main()
