#!/usr/bin/env -S uv run --quiet python
# /// script
# requires-python = ">=3.10"
# ///
"""
Score actual extracted bookquotes vs expectations.

Compares MARK TYPE, TITLE and PASSAGE (not CONTEXT / WHY NOTABLE).

Per-example score is a weighted blend reflecting the tuning priorities:
  1/2. RECALL      — did we find each expected passage? Importance-weighted: an
                     expected mark tagged `IMPORTANT: yes` counts IMP_WEIGHT x,
                     so missing an important passage hurts most.
  3.   EXTENT      — for found passages, word precision: penalises bloat and
                     included non-underlined sub-spans (the `[...]` gaps).
       NO-SPURIOUS — fraction of our marks that matched a real one.
  4.   MARK TYPE   — word overlap (minor).
  5.   TITLE       — word overlap (minor; only scored where a reference title exists).

Matching is GLOBAL greedy one-to-one by passage word-recall (best pairs first),
so merging several distinct expected marks into one blob is penalised (the others
go unmatched), and an early expected mark cannot steal a later one's better match.

Examples whose output is an API / content-filter error are excluded from the
average and listed separately (not a prompt problem).
"""

from __future__ import annotations

import os
import re
from pathlib import Path
from dataclasses import dataclass, field

ROOT = Path(__file__).parent
EXPECTATIONS = ROOT.parent / "rhizome-books-test-catalogue" / "expectations.md"
# OUT_DIR overridable so a saved run (e.g. a baseline snapshot) can be re-scored
# under the current metric for a fair before/after comparison.
OUT_DIR = Path(os.environ.get("OUT_DIR", ROOT / "test-catalogue-out"))

WORD_RE = re.compile(r"[a-z0-9]+")
ELIPSIS_RE = re.compile(r"\[\s*…\s*\]|\[\s*\.\.\.\s*\]")

# Per-example component weights. Renormalised over whichever components apply to
# an example (e.g. title is dropped when no reference title is present).
WEIGHTS = {
    "recall": 0.45,       # priorities 1 & 2 — don't miss passages (important ones weigh more)
    "extent": 0.20,       # priority 3 — right extent, no bloat, sub-spans omitted
    "no_spurious": 0.15,  # don't invent passages
    "importance": 0.10,   # bot must flag IMPORTANT passages; a miss is heavy, a false one mild
    "mark_type": 0.05,    # minor
    "title": 0.05,        # minor
}
IMP_FALSE_POS = 0.8       # credit for a wrongly-flagged-important match (false positive = "not so bad")
NONE_FP_PENALTY = 0.1     # per false passage on a NONE page (recall-first: over-detection is mild)
IMP_WEIGHT = 3.0          # an IMPORTANT expected mark counts this many times in recall
MATCH_THRESHOLD = 0.3     # min passage word-recall to treat an actual as the same mark

ERROR_MARKERS = ("content filtering", "API Error", "Output blocked")


@dataclass
class Mark:
    mark_type: str = ""
    important: bool = False
    title: str = ""
    passage: str = ""


@dataclass
class Example:
    name: str
    subject: str
    marks: list[Mark] = field(default_factory=list)


def normalise(text: str) -> list[str]:
    text = ELIPSIS_RE.sub(" ", text)
    text = text.replace("**", " ").replace("[emphasis mine]", " ")
    return WORD_RE.findall(text.lower())


def _overlap(a: list[str], b: list[str]) -> int:
    a_count: dict[str, int] = {}
    for w in a:
        a_count[w] = a_count.get(w, 0) + 1
    b_count: dict[str, int] = {}
    for w in b:
        b_count[w] = b_count.get(w, 0) + 1
    return sum(min(c, b_count.get(w, 0)) for w, c in a_count.items())


def recall_of(expected: list[str], actual: list[str]) -> float:
    if not expected or not actual:
        return 0.0
    return _overlap(expected, actual) / len(expected)


def precision_of(expected: list[str], actual: list[str]) -> float:
    if not expected or not actual:
        return 0.0
    return _overlap(expected, actual) / len(actual)


def f1_of(expected: list[str], actual: list[str]) -> float:
    p = precision_of(expected, actual)
    r = recall_of(expected, actual)
    return 2 * p * r / (p + r) if (p + r) else 0.0


def _is_yes(v: str) -> bool:
    return v.strip().lower() in ("yes", "y", "true", "1", "high", "important")


def parse_expectations(path: Path) -> list[Example]:
    text = path.read_text()
    examples: list[Example] = []
    current: Example | None = None
    pending: dict[str, str] = {}

    def flush_pending():
        if current is None or not pending:
            return
        if pending.get("MARK TYPE") or pending.get("PASSAGE"):
            current.marks.append(
                Mark(
                    mark_type=pending.get("MARK TYPE", "").strip(),
                    important=_is_yes(pending.get("IMPORTANT", "")),
                    title=pending.get("TITLE", "").strip(),
                    passage=pending.get("PASSAGE", "").strip(),
                )
            )
        pending.clear()

    for raw in text.splitlines():
        line = raw.rstrip()
        m = re.match(r"^#\s*(example-\d+)\s*-\s*subject:\s*p\.(\S+)", line)
        if m:
            flush_pending()
            if current:
                examples.append(current)
            current = Example(name=m.group(1), subject=m.group(2))
            continue
        if line.startswith("MARK TYPE:"):
            flush_pending()
            pending["MARK TYPE"] = line.split(":", 1)[1].strip()
        elif line.startswith("IMPORTANT:"):
            pending["IMPORTANT"] = line.split(":", 1)[1].strip()
        elif line.startswith("TITLE:"):
            pending["TITLE"] = line.split(":", 1)[1].strip()
        elif line.startswith("PASSAGE:"):
            pending["PASSAGE"] = line.split(":", 1)[1].strip()
        elif line == "" and pending:
            flush_pending()
        else:
            # continuation of the passage (wrapped lines)
            if "PASSAGE" in pending and line.strip():
                pending["PASSAGE"] = pending["PASSAGE"] + " " + line.strip()
    flush_pending()
    if current:
        examples.append(current)
    return examples


def parse_actual(path: Path) -> list[Mark]:
    if not path.exists():
        return []
    text = path.read_text()
    marks: list[Mark] = []
    pending: dict[str, str] = {}

    def flush():
        if pending.get("MARK TYPE") or pending.get("PASSAGE"):
            marks.append(
                Mark(
                    mark_type=pending.get("MARK TYPE", "").strip(),
                    important=_is_yes(pending.get("IMPORTANT", "")),
                    title=pending.get("TITLE", "").strip(),
                    passage=pending.get("PASSAGE", "").strip(),
                )
            )
        pending.clear()

    last_key: str | None = None
    for raw in text.splitlines():
        line = raw.rstrip()
        if line.startswith("PAGE:"):
            flush()
            last_key = None
            continue
        if line.startswith("MARK TYPE:"):
            pending["MARK TYPE"] = line.split(":", 1)[1].strip()
            last_key = "MARK TYPE"
        elif line.startswith("IMPORTANT:"):
            pending["IMPORTANT"] = line.split(":", 1)[1].strip()
            last_key = None
        elif line.startswith("TITLE:"):
            pending["TITLE"] = line.split(":", 1)[1].strip()
            last_key = "TITLE"
        elif line.startswith("PASSAGE:"):
            pending["PASSAGE"] = line.split(":", 1)[1].strip()
            last_key = "PASSAGE"
        elif line.startswith("CONTEXT:") or line.startswith("WHY NOTABLE:") or line == "-----":
            last_key = None
        elif line == "":
            continue
        else:
            if last_key in ("MARK TYPE", "TITLE", "PASSAGE") and line.strip():
                pending[last_key] = pending[last_key] + " " + line.strip()
    flush()
    return marks


def score_example(expected: Example, actual: list[Mark]) -> dict:
    # Negative example: expectations list no marks. Score is purely "did we avoid
    # inventing passages" — empty actual is perfect; each spurious mark costs only
    # NONE_FP_PENALTY (recall-first: over-detection on a clean page is a mild error).
    if not expected.marks:
        n_actual = len(actual)
        score = 1.0 if n_actual == 0 else round(max(0.0, 1.0 - NONE_FP_PENALTY * n_actual), 3)
        return {
            "negative": True, "n_expected": 0, "n_actual": n_actual,
            "recall": None, "extent": None, "no_spurious": round(score, 3),
            "importance": None, "mark_type": None, "title": None, "score": score, "per_expected": [],
        }

    exp_words = [normalise(mk.passage) for mk in expected.marks]
    act_words = [normalise(mk.passage) for mk in actual]

    # Global greedy one-to-one assignment by passage word-recall: score every
    # expected-actual pair, then assign the highest-scoring pairs first.
    pairs = []
    for i, ew in enumerate(exp_words):
        for j, aw in enumerate(act_words):
            r = recall_of(ew, aw)
            if r > 0:
                pairs.append((r, i, j))
    pairs.sort(key=lambda t: t[0], reverse=True)
    match_for = [-1] * len(exp_words)
    exp_taken = [False] * len(exp_words)
    act_taken = [False] * len(act_words)
    for r, i, j in pairs:
        if exp_taken[i] or act_taken[j]:
            continue
        match_for[i] = j
        exp_taken[i] = True
        act_taken[j] = True

    per_expected = []
    for i, ew in enumerate(exp_words):
        j = match_for[i]
        rec = recall_of(ew, act_words[j]) if j >= 0 else 0.0
        prec = precision_of(ew, act_words[j]) if j >= 0 else 0.0
        confident = j >= 0 and rec >= MATCH_THRESHOLD   # enough overlap to call it the same mark
        mt = ti = 0.0
        if confident:
            mt = f1_of(normalise(expected.marks[i].mark_type), normalise(actual[j].mark_type))
            ti = f1_of(normalise(expected.marks[i].title), normalise(actual[j].title))
        per_expected.append({
            "exp_passage": expected.marks[i].passage[:70],
            "important": expected.marks[i].important,
            "recall": round(rec, 3),
            "extent": round(prec, 3),
            "mark_type": round(mt, 3),
            "title": round(ti, 3),
            "has_title": bool(expected.marks[i].title),
            "confident": confident,
            "matched_actual_idx": j if confident else -1,
        })

    # Recall (priorities 1 & 2): importance-weighted mean coverage. Partial credit,
    # so even a weakly-matched expected passage contributes its coverage.
    wsum = sum(IMP_WEIGHT if p["important"] else 1.0 for p in per_expected)
    rsum = sum((IMP_WEIGHT if p["important"] else 1.0) * p["recall"] for p in per_expected)
    recall = rsum / wsum if wsum else 0.0

    conf = [p for p in per_expected if p["confident"]]
    # Extent (priority 3): precision of confidently-matched passages (bloat penalty).
    extent = sum(p["extent"] for p in conf) / len(conf) if conf else 0.0
    mark_type = sum(p["mark_type"] for p in conf) / len(conf) if conf else 0.0
    titled = [p for p in conf if p["has_title"]]
    title = (sum(p["title"] for p in titled) / len(titled)) if titled else None

    # Importance (asymmetric): an expected-important passage the bot did not find
    # AND flag scores 0 (heavy); a passage the bot wrongly flags important is mild.
    imp_items = []
    for p in per_expected:
        j = p["matched_actual_idx"]
        if p["important"]:
            imp_items.append(1.0 if (j >= 0 and actual[j].important) else 0.0)
        elif j >= 0:
            imp_items.append(IMP_FALSE_POS if actual[j].important else 1.0)
    importance = (sum(imp_items) / len(imp_items)) if imp_items else None

    n_actual = len(actual)
    no_spurious = (len(conf) / n_actual) if n_actual else 1.0

    comps = {"recall": recall, "extent": extent, "no_spurious": no_spurious,
             "importance": importance, "mark_type": mark_type, "title": title}
    num = den = 0.0
    for k, w in WEIGHTS.items():
        if comps[k] is None:
            continue
        num += w * comps[k]
        den += w
    score = num / den if den else 0.0

    return {
        "negative": False,
        "n_expected": len(expected.marks),
        "n_actual": n_actual,
        "recall": round(recall, 3),
        "extent": round(extent, 3),
        "no_spurious": round(no_spurious, 3),
        "importance": round(importance, 3) if importance is not None else None,
        "mark_type": round(mark_type, 3),
        "title": round(title, 3) if title is not None else None,
        "score": round(score, 3),
        "per_expected": per_expected,
    }


def main() -> None:
    examples = parse_expectations(EXPECTATIONS)
    total = 0.0
    n = 0
    errored: list[str] = []
    print(f"Scoring {len(examples)} example(s) from expectations.md\n")
    for ex in examples:
        actual_path = OUT_DIR / f"{ex.name}.md"
        status_path = OUT_DIR / f"{ex.name}.status.tsv"
        raw = actual_path.read_text() if actual_path.exists() else ""
        # Quarantine infra failures: prefer the per-page ledger (the extract script
        # records content-filter / outage / error there); fall back to error markers
        # in the output text for older runs.
        bad_status = ""
        if status_path.exists():
            for ln in status_path.read_text().splitlines():
                parts = ln.split("\t")
                if len(parts) >= 2 and parts[1].strip() in ("content-filter", "outage", "error"):
                    bad_status = parts[1].strip()
                    break
        print(f"=== {ex.name} (subject p.{ex.subject}) ===")
        if bad_status or any(mk in raw for mk in ERROR_MARKERS):
            errored.append(ex.name)
            print(f"  ERRORED ({bad_status or 'output marker'}) — excluded from average\n")
            continue
        actual = parse_actual(actual_path)
        r = score_example(ex, actual)
        if r["negative"]:
            print(f"  NEGATIVE  n_actual={r['n_actual']}  no_spurious={r['no_spurious']} -> score={r['score']}")
        else:
            t = r["title"] if r["title"] is not None else "n/a"
            imp = r["importance"] if r["importance"] is not None else "n/a"
            print(f"  n_expected={r['n_expected']} n_actual={r['n_actual']}  recall={r['recall']} "
                  f"extent={r['extent']} no_spurious={r['no_spurious']} importance={imp} "
                  f"mark_type={r['mark_type']} title={t} -> score={r['score']}")
            for p in r["per_expected"]:
                imp = " [IMPORTANT]" if p["important"] else ""
                print(f"    - {p['exp_passage']!r:<72}{imp}  recall={p['recall']} extent={p['extent']} "
                      f"-> actual #{p['matched_actual_idx']}")
        print()
        total += r["score"]
        n += 1
    avg = total / max(n, 1)
    print(f"OVERALL average score: {round(avg, 3)}  over {n} scored example(s)  (1.0 = perfect)")
    print(f"  weights: recall {WEIGHTS['recall']} / extent {WEIGHTS['extent']} / "
          f"no-spurious {WEIGHTS['no_spurious']} / importance {WEIGHTS['importance']} / "
          f"mark-type {WEIGHTS['mark_type']} / title {WEIGHTS['title']};  IMPORTANT recall weight x{IMP_WEIGHT}")
    if errored:
        print(f"  EXCLUDED {len(errored)} errored example(s) (API/content-filter, not a prompt problem): "
              f"{', '.join(errored)}")


if __name__ == "__main__":
    main()
