#!/usr/bin/env python3
"""
Generate a Markdown quiz-activity report from an e-learning platform database dump.

Usage:
    elearn-quiz-report.py <dump-or-sql-file> [--out <file.md>]

Input may be either a PostgreSQL custom-format dump (pg_dump -Fc, magic "PGDMP")
or a plain-text SQL dump. Custom dumps are converted to SQL on the fly with
`pg_restore -f -`.

The script is deliberately schema-tolerant: it discovers the quiz-attempt table
and the user table by inspecting the columns present in the dump's COPY blocks
rather than hard-coding table/column names, so it keeps working as the Prisma
schema evolves (new columns added, tables renamed to contain "attempt"/"user",
timestamp column renamed, etc.). When something can't be found it degrades
gracefully and notes the assumption in the report instead of crashing.

Semantics:
    questions answered (per attempt) = the attempt's "total" column
                                       (number of questions in that quiz attempt)
    correct                          = the attempt's "score" column
    accuracy                         = correct / answered
"""

import os
import re
import sys
import subprocess
from datetime import datetime, timezone
from collections import defaultdict

# ----------------------------------------------------------------------------
# Loading: get plain SQL text from a .dump (custom) or .sql file
# ----------------------------------------------------------------------------

def load_sql(path):
    with open(path, "rb") as fh:
        head = fh.read(5)
    if head == b"PGDMP":
        pg_restore = which_pg_restore()
        if not pg_restore:
            sys.exit("error: input is a custom-format dump but `pg_restore` was "
                     "not found on PATH. Install postgresql client tools.")
        try:
            out = subprocess.run([pg_restore, "-f", "-", path],
                                 check=True, capture_output=True)
        except subprocess.CalledProcessError as e:
            sys.exit(f"error: pg_restore failed: {e.stderr.decode(errors='replace')}")
        return out.stdout.decode("utf-8", errors="replace")
    # plain SQL
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def which_pg_restore():
    from shutil import which
    found = which("pg_restore")
    if found:
        return found
    # common Homebrew locations
    import glob
    for pat in ("/opt/homebrew/opt/postgresql@*/bin/pg_restore",
                "/usr/local/opt/postgresql@*/bin/pg_restore",
                "/opt/homebrew/bin/pg_restore",
                "/usr/local/bin/pg_restore"):
        hits = sorted(glob.glob(pat))
        if hits:
            return hits[-1]
    return None


# ----------------------------------------------------------------------------
# Parsing: COPY blocks -> list of dict rows, keyed by table name
# ----------------------------------------------------------------------------

COPY_RE = re.compile(
    r'COPY\s+(?:public\.)?"?(?P<table>[^"\s(]+)"?\s*\((?P<cols>[^)]*)\)\s+FROM\s+stdin;')


def _unquote_col(c):
    c = c.strip()
    if c.startswith('"') and c.endswith('"'):
        c = c[1:-1]
    return c


def _unescape(val):
    # COPY text format escapes; handle the common ones
    if "\\" not in val:
        return val
    return (val.replace("\\t", "\t").replace("\\n", "\n")
               .replace("\\r", "\r").replace("\\\\", "\\"))


def parse_copy_blocks(sql):
    """Return {table_name: {'cols': [...], 'rows': [ {col: val|None}, ... ]}}"""
    tables = {}
    lines = sql.splitlines()
    i = 0
    n = len(lines)
    while i < n:
        m = COPY_RE.search(lines[i])
        if not m:
            i += 1
            continue
        table = m.group("table")
        cols = [_unquote_col(c) for c in m.group("cols").split(",")]
        rows = []
        i += 1
        while i < n and lines[i] != r"\.":
            parts = lines[i].split("\t")
            row = {}
            for idx, col in enumerate(cols):
                raw = parts[idx] if idx < len(parts) else None
                if raw == r"\N" or raw is None:
                    row[col] = None
                else:
                    row[col] = _unescape(raw)
            rows.append(row)
            i += 1
        tables[table] = {"cols": cols, "rows": rows}
        i += 1
    return tables


# ----------------------------------------------------------------------------
# Schema discovery: find the attempt table, user table, course table
# ----------------------------------------------------------------------------

def find_col(cols, *, exact=None, contains=None):
    """Case-insensitive column lookup. `exact` is a list of candidate names tried
    first; `contains` is a list of substrings tried next. Returns actual col name."""
    lc = {c.lower(): c for c in cols}
    for cand in (exact or []):
        if cand.lower() in lc:
            return lc[cand.lower()]
    for sub in (contains or []):
        for c in cols:
            if sub.lower() in c.lower():
                return c
    return None


def pick_attempt_table(tables):
    """The table that records quiz attempts: must expose a user id, a score and a
    total/questions column, plus a timestamp. Prefer a name containing 'attempt'."""
    candidates = []
    for name, t in tables.items():
        cols = t["cols"]
        user_c = find_col(cols, exact=["userId", "user_id"], contains=["userid", "user"])
        score_c = find_col(cols, exact=["score"], contains=["score", "correct"])
        total_c = find_col(cols, exact=["total"],
                           contains=["total", "questions", "numquestions", "questioncount"])
        ts_c = pick_timestamp_col(cols)
        if user_c and score_c and total_c:
            rank = 0
            if "attempt" in name.lower():
                rank += 2
            if "quiz" in name.lower():
                rank += 1
            candidates.append((rank, name, user_c, score_c, total_c, ts_c))
    if not candidates:
        return None
    candidates.sort(reverse=True)
    rank, name, user_c, score_c, total_c, ts_c = candidates[0]
    t = tables[name]
    return {
        "name": name,
        "rows": t["rows"],
        "cols": t["cols"],
        "user": user_c,
        "score": score_c,
        "total": total_c,
        "ts": ts_c,
        "pct": find_col(t["cols"], exact=["percentage", "percent", "pct"]),
        "title": find_col(t["cols"], exact=["title", "quizTitle"], contains=["title"]),
        "quiz": find_col(t["cols"], exact=["quizId", "quiz_id"], contains=["quizid", "quizslug", "quiz"]),
        "course": find_col(t["cols"], exact=["courseId", "course_id"], contains=["courseid"]),
    }


def pick_timestamp_col(cols):
    return find_col(cols,
                    exact=["createdAt", "created_at", "submittedAt", "takenAt", "completedAt"],
                    contains=["created", "submitted", "taken", "completed", "_at", "date", "time"])


def pick_user_table(tables):
    best = None
    for name, t in tables.items():
        cols = t["cols"]
        email_c = find_col(cols, exact=["email"], contains=["email", "mail"])
        id_c = find_col(cols, exact=["id"], contains=["id"])
        if id_c and (email_c or "user" in name.lower()):
            rank = (2 if name.lower() == "user" else (1 if "user" in name.lower() else 0))
            if best is None or rank > best[0]:
                best = (rank, name, id_c, email_c)
    if not best:
        return None
    _, name, id_c, email_c = best
    cols = tables[name]["cols"]
    return {
        "name": name,
        "rows": tables[name]["rows"],
        "id": id_c,
        "email": email_c,
        "first": find_col(cols, exact=["firstName", "first_name"], contains=["first", "given"]),
        "last": find_col(cols, exact=["lastName", "last_name"], contains=["last", "family", "surname"]),
        "name_col": find_col(cols, exact=["name", "fullName", "displayName"]),
    }


def pick_course_table(tables):
    for name, t in tables.items():
        if name.lower() == "course" or "course" in name.lower():
            cols = t["cols"]
            id_c = find_col(cols, exact=["id"])
            title_c = find_col(cols, exact=["title", "name"], contains=["title", "name"])
            slug_c = find_col(cols, exact=["slug"])
            if id_c:
                return {"name": name, "rows": t["rows"], "id": id_c,
                        "title": title_c, "slug": slug_c}
    return None


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

def to_int(v, default=0):
    try:
        return int(v)
    except (TypeError, ValueError):
        try:
            return int(float(v))
        except (TypeError, ValueError):
            return default


def parse_ts(v):
    if not v:
        return None
    s = v.strip()
    # normalise: drop timezone offset if present, keep up to microseconds
    s = re.sub(r"[+-]\d{2}(:?\d{2})?$", "", s).strip()
    for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S",
                "%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S",
                "%Y-%m-%d"):
        try:
            return datetime.strptime(s, fmt)
        except ValueError:
            continue
    return None


def build_user_map(user_tbl):
    """id(str) -> {'label': 'First Last', 'email': ...}"""
    out = {}
    if not user_tbl:
        return out
    for r in user_tbl["rows"]:
        uid = r.get(user_tbl["id"])
        if uid is None:
            continue
        first = r.get(user_tbl["first"]) if user_tbl["first"] else None
        last = r.get(user_tbl["last"]) if user_tbl["last"] else None
        name = r.get(user_tbl["name_col"]) if user_tbl["name_col"] else None
        email = r.get(user_tbl["email"]) if user_tbl["email"] else None
        if name:
            label = name
        elif first or last:
            label = " ".join(p for p in (first, last) if p)
        elif email:
            label = email
        else:
            label = f"user {uid}"
        out[str(uid)] = {"label": label, "email": email or ""}
    return out


def build_course_map(course_tbl):
    out = {}
    if not course_tbl:
        return out
    for r in course_tbl["rows"]:
        cid = r.get(course_tbl["id"])
        if cid is None:
            continue
        title = (r.get(course_tbl["title"]) if course_tbl["title"] else None) \
            or (r.get(course_tbl["slug"]) if course_tbl["slug"] else None) \
            or f"course {cid}"
        out[str(cid)] = title
    return out


def md_escape(s):
    return (s or "").replace("|", "\\|")


# ----------------------------------------------------------------------------
# Report generation
# ----------------------------------------------------------------------------

def generate(dump_path, out_path):
    sql = load_sql(dump_path)
    tables = parse_copy_blocks(sql)
    attempt = pick_attempt_table(tables)
    if not attempt:
        sys.exit("error: could not locate a quiz-attempt table (need user id + "
                 "score + total columns) in the dump. Tables found: "
                 + ", ".join(tables.keys()))
    users = build_user_map(pick_user_table(tables))
    courses = build_course_map(pick_course_table(tables))

    # Normalise attempts into a tidy list
    rows = []
    undated = 0
    for r in attempt["rows"]:
        uid = str(r.get(attempt["user"]))
        answered = to_int(r.get(attempt["total"]))
        correct = to_int(r.get(attempt["score"]))
        pct = to_int(r.get(attempt["pct"])) if attempt["pct"] else (
            round(correct / answered * 100) if answered else 0)
        ts = parse_ts(r.get(attempt["ts"])) if attempt["ts"] else None
        if ts is None:
            undated += 1
        rows.append({
            "uid": uid,
            "answered": answered,
            "correct": correct,
            "pct": pct,
            "ts": ts,
            "title": r.get(attempt["title"]) if attempt["title"] else None,
            "quiz": r.get(attempt["quiz"]) if attempt["quiz"] else None,
            "course": r.get(attempt["course"]) if attempt["course"] else None,
        })
    rows.sort(key=lambda x: (x["uid"], x["ts"] or datetime.min))

    gen_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")

    def user_label(uid):
        return users.get(uid, {}).get("label", f"user {uid}")

    def user_email(uid):
        return users.get(uid, {}).get("email", "")

    # ----- Aggregations -----
    per_user = defaultdict(lambda: {"attempts": 0, "answered": 0, "correct": 0})
    for r in rows:
        u = per_user[r["uid"]]
        u["attempts"] += 1
        u["answered"] += r["answered"]
        u["correct"] += r["correct"]

    tot_attempts = sum(u["attempts"] for u in per_user.values())
    tot_answered = sum(u["answered"] for u in per_user.values())
    tot_correct = sum(u["correct"] for u in per_user.values())

    def bucket_key(ts, gran):
        if ts is None:
            return "(undated)"
        if gran == "day":
            return ts.strftime("%Y-%m-%d")
        if gran == "month":
            return ts.strftime("%Y-%m")
        if gran == "week":
            iso = ts.isocalendar()
            return f"{iso[0]}-W{iso[1]:02d}"
        return ""

    # overall per-period and per-user-per-period
    overall = {g: defaultdict(lambda: {"attempts": 0, "answered": 0, "correct": 0})
               for g in ("day", "week", "month")}
    per_user_period = {g: defaultdict(lambda: defaultdict(
        lambda: {"attempts": 0, "answered": 0})) for g in ("day", "week", "month")}
    periods = {g: set() for g in ("day", "week", "month")}
    for r in rows:
        for g in ("day", "week", "month"):
            k = bucket_key(r["ts"], g)
            periods[g].add(k)
            ob = overall[g][k]
            ob["attempts"] += 1
            ob["answered"] += r["answered"]
            ob["correct"] += r["correct"]
            pb = per_user_period[g][r["uid"]][k]
            pb["attempts"] += 1
            pb["answered"] += r["answered"]

    # date range
    dated = [r["ts"] for r in rows if r["ts"]]
    date_lo = min(dated).strftime("%Y-%m-%d %H:%M") if dated else "n/a"
    date_hi = max(dated).strftime("%Y-%m-%d %H:%M") if dated else "n/a"

    # ----- Markdown -----
    L = []
    L.append(f"# Quiz Activity Report")
    L.append("")
    L.append(f"- **Source dump:** `{os.path.basename(dump_path)}`")
    L.append(f"- **Generated:** {gen_at}")
    L.append(f"- **Attempt table:** `{attempt['name']}`  ·  "
             f"questions answered = `{attempt['total']}`, correct = `{attempt['score']}`, "
             f"timestamp = `{attempt['ts']}`")
    L.append(f"- **Date range:** {date_lo} → {date_hi}")
    if undated:
        L.append(f"- **Note:** {undated} attempt(s) had no parseable timestamp and "
                 f"are bucketed as `(undated)`.")
    L.append("")
    L.append("> **questions answered** = number of questions in each attempt "
             "(`total`). **correct** = `score`. Re-takes count every time, so the "
             "same question answered in two attempts counts twice.")
    L.append("")

    # Summary
    acc = round(tot_correct / tot_answered * 100) if tot_answered else 0
    L.append("## Summary")
    L.append("")
    L.append(f"- Active users: **{len(per_user)}**")
    L.append(f"- Total attempts: **{tot_attempts}**")
    L.append(f"- Total questions answered: **{tot_answered}**")
    L.append(f"- Total correct: **{tot_correct}**  (overall accuracy **{acc}%**)")
    L.append("")

    # Per-user totals
    L.append("## Questions answered per user")
    L.append("")
    L.append("| User | Email | Attempts | Questions answered | Correct | Accuracy |")
    L.append("|------|-------|---------:|-------------------:|--------:|---------:|")
    for uid in sorted(per_user, key=lambda u: per_user[u]["answered"], reverse=True):
        u = per_user[uid]
        a = round(u["correct"] / u["answered"] * 100) if u["answered"] else 0
        L.append(f"| {md_escape(user_label(uid))} | {md_escape(user_email(uid))} "
                 f"| {u['attempts']} | {u['answered']} | {u['correct']} | {a}% |")
    L.append(f"| **TOTAL** | | **{tot_attempts}** | **{tot_answered}** "
             f"| **{tot_correct}** | **{acc}%** |")
    L.append("")

    # Per user, per attempt
    L.append("## Per user, per attempt")
    L.append("")
    by_user_rows = defaultdict(list)
    for r in rows:
        by_user_rows[r["uid"]].append(r)
    for uid in sorted(by_user_rows, key=lambda u: user_label(u).lower()):
        L.append(f"### {md_escape(user_label(uid))}"
                 + (f" — {md_escape(user_email(uid))}" if user_email(uid) else "")
                 + f"  (id {uid})")
        L.append("")
        L.append("| When | Quiz | Questions | Score | % |")
        L.append("|------|------|----------:|------:|--:|")
        for r in sorted(by_user_rows[uid], key=lambda x: x["ts"] or datetime.min):
            when = r["ts"].strftime("%Y-%m-%d %H:%M") if r["ts"] else "(undated)"
            quiz = r["title"] or r["quiz"] or "(quiz)"
            if r["course"] and courses.get(str(r["course"])):
                quiz = f"{quiz}"
            L.append(f"| {when} | {md_escape(str(quiz))} | {r['answered']} "
                     f"| {r['correct']} | {r['pct']} |")
        ut = per_user[uid]
        L.append(f"| **subtotal** | | **{ut['answered']}** | **{ut['correct']}** | |")
        L.append("")

    # Activity over time — overall
    def overall_table(gran, heading):
        L.append(f"### Overall — {heading}")
        L.append("")
        L.append("| Period | Attempts | Questions answered | Correct | Accuracy |")
        L.append("|--------|---------:|-------------------:|--------:|---------:|")
        for k in sorted(periods[gran]):
            b = overall[gran][k]
            a = round(b["correct"] / b["answered"] * 100) if b["answered"] else 0
            L.append(f"| {k} | {b['attempts']} | {b['answered']} | {b['correct']} | {a}% |")
        L.append(f"| **TOTAL** | **{tot_attempts}** | **{tot_answered}** "
                 f"| **{tot_correct}** | **{acc}%** |")
        L.append("")

    # Activity over time — per user matrix (cell = answered (attempts))
    def per_user_matrix(gran, heading):
        cols = sorted(periods[gran])
        L.append(f"### Per user — {heading}")
        L.append("")
        L.append("> Each cell is **questions answered** with **(attempts)** in parentheses.")
        L.append("")
        header = "| User | " + " | ".join(cols) + " | **Total** |"
        sep = "|------|" + "|".join(["---:"] * len(cols)) + "|---:|"
        L.append(header)
        L.append(sep)
        for uid in sorted(per_user, key=lambda u: user_label(u).lower()):
            cells = []
            row_ans = 0
            row_att = 0
            for k in cols:
                b = per_user_period[gran][uid].get(k)
                if b:
                    cells.append(f"{b['answered']} ({b['attempts']})")
                    row_ans += b["answered"]
                    row_att += b["attempts"]
                else:
                    cells.append("·")
            L.append(f"| {md_escape(user_label(uid))} | " + " | ".join(cells)
                     + f" | **{row_ans} ({row_att})** |")
        # totals row
        tot_cells = []
        for k in cols:
            b = overall[gran][k]
            tot_cells.append(f"**{b['answered']} ({b['attempts']})**")
        L.append(f"| **TOTAL** | " + " | ".join(tot_cells)
                 + f" | **{tot_answered} ({tot_attempts})** |")
        L.append("")

    L.append("## Activity over time")
    L.append("")
    overall_table("day", "by day")
    overall_table("week", "by week (ISO)")
    overall_table("month", "by month")
    per_user_matrix("day", "by day")
    per_user_matrix("week", "by week (ISO)")
    per_user_matrix("month", "by month")

    L.append("---")
    L.append(f"_Generated by `elearn-quiz-report.py` from `{os.path.basename(dump_path)}` "
             f"at {gen_at}._")
    L.append("")

    report = "\n".join(L)
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(report)

    # brief stdout summary for the caller
    print(f"Wrote report: {out_path}")
    print(f"  users={len(per_user)} attempts={tot_attempts} "
          f"answered={tot_answered} correct={tot_correct} accuracy={acc}%")
    print(f"  attempt_table={attempt['name']} ts_col={attempt['ts']} "
          f"date_range={date_lo}..{date_hi}")


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    out = None
    for i, a in enumerate(argv):
        if a == "--out" and i + 1 < len(argv):
            out = argv[i + 1]
    if not args:
        sys.exit("usage: elearn-quiz-report.py <dump-or-sql-file> [--out <file.md>]")
    dump_path = os.path.abspath(args[0])
    if not os.path.exists(dump_path):
        sys.exit(f"error: file not found: {dump_path}")
    if out is None:
        # Name the report after the dump it actually points to, so running on the
        # `latest.dump` symlink writes e.g. `elearn-…Z.report.md`, not `latest.report.md`.
        real = os.path.realpath(dump_path)
        d = os.path.dirname(real)
        stem = re.sub(r"\.(dump|sql)$", "", os.path.basename(real))
        out = os.path.join(d, f"{stem}.report.md")
    out = os.path.abspath(out)
    generate(dump_path, out)


if __name__ == "__main__":
    main(sys.argv)
