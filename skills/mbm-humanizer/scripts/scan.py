#!/usr/bin/env python3
"""List the tells of generated text in an English (US) or Turkish file.

    python3 scan.py --lang en FILE
    python3 scan.py --lang tr FILE
    python3 scan.py --lang auto FILE      # guess from Turkish letters

Prints each hit with its line number, then counts for the habits a phrase list cannot
see (em dashes per paragraph, title-case headings, bold inline-header list items,
sentence-initial transitions, emoji, a closing summary section), and checks every date
that carries a weekday name against the calendar (English and Turkish names, and ISO
dates). It is a hint list for the humanizer skill, not a
verdict: a hit can be fine in context, and a clean scan does not mean the text reads
well. Exit status is always 0.
"""
import argparse
import datetime
import re
import sys
from collections import Counter

EN_PHRASES = [
    # significance inflation
    r"\bstands? as\b", r"\bserves? as\b", r"\bis a testament\b", r"\ba testament to\b",
    r"\b(?:plays?|played) an? (?:pivotal|crucial|vital|key|significant|important) role\b",
    r"\bunderscores?\b", r"\bunderscoring\b", r"\bpivotal\b", r"\bin today's (?:fast-paced|rapidly|ever)",
    r"\bevolving landscape\b", r"\bindelible mark\b", r"\bdeeply rooted\b", r"\bsetting the stage\b",
    r"\bmarks? a (?:significant |major )?(?:shift|milestone|turning point)\b", r"\breflects? broader\b",
    # vocabulary
    r"\bdelve[sd]?\b", r"\bdelving\b", r"\bdeep dive\b", r"\bleverag(?:e|es|ed|ing)\b", r"\butiliz(?:e|es|ed|ing)\b",
    r"\bseamless(?:ly)?\b", r"\brobust\b", r"\bcomprehensive\b", r"\bcrucial\b", r"\bshowcas(?:e|es|ed|ing)\b",
    r"\bfoster(?:s|ed|ing)?\b", r"\bgarner(?:s|ed|ing)?\b", r"\bboasts?\b", r"\btapestry\b", r"\brealm\b",
    r"\bintricate\b", r"\bmultifaceted\b", r"\bmeticulous(?:ly)?\b", r"\bvibrant\b", r"\brenowned\b",
    r"\bnestled\b", r"\bempower(?:s|ed|ing)?\b", r"\bunlock(?:s|ed|ing)?\b", r"\bstreamlin(?:e|es|ed|ing)\b",
    r"\bgame[- ]changer\b", r"\bcutting[- ]edge\b", r"\bvaluable insights\b", r"\bactionable insights\b",
    r"\balign(?:s|ed)? with\b", r"\bresonat(?:e|es|ed) with\b", r"\bnavigat(?:e|ing) the\b", r"\bjourney\b",
    r"\belevat(?:e|es|ed|ing)\b", r"\benhanc(?:e|es|ed|ing)\b", r"\binterplay\b",
    # sentence patterns
    r"\bnot (?:just|only|merely)\b[^.]{0,80}\b(?:but|it's|it is)\b", r"\bit's not (?:just )?about\b",
    r"\bit(?:'s| is) (?:important|worth) (?:to note|noting|mentioning)\b", r"\bnotably,", r"\bsimply put\b",
    r"\bin essence\b", r"\blet's (?:dive|delve|explore|take a look)\b", r"\bhere's the thing\b",
    r"\bfrom \w+ to \w+(?: alike)?\b", r", (?:highlighting|underscoring|emphasizing|ensuring|reflecting|showcasing|fostering)\b",
    # formulaic endings and hedges
    r"\bin conclusion\b", r"\bin summary\b", r"^\s*overall,", r"\bdespite (?:these|its|the) challenges\b",
    r"\blooking ahead\b", r"\bwhile specific details are limited\b", r"\bbased on (?:the )?available information\b",
    r"\bexperts (?:say|argue|agree)\b", r"\bindustry reports\b",
    # chatbot residue
    r"\bcertainly!", r"\babsolutely!", r"\bgreat question\b", r"\bi hope this helps\b",
    r"\blet me know if\b", r"\bfeel free to\b", r"\bhere's an? (?:breakdown|overview|quick)\b",
    r"\bas an ai\b", r"\bas of my last (?:update|knowledge)\b", r"\[(?:your|insert) [^\]]+\]",
]
EN_TRANSITIONS = ["additionally", "moreover", "furthermore", "in addition", "notably", "importantly", "overall", "ultimately"]

TR_PHRASES = [
    # önem şişirme
    r"\b(?:önemli|kritik|hayati|kilit) bir rol (?:oynamaktadır|oynar|oynuyor|üstlenmektedir)",
    r"\bkritik öneme sahip", r"\bbüyük önem (?:taşımaktadır|taşır|arz etmektedir)", r"\bönem arz et",
    r"\baltını çiz(?:mektedir|er|iyor|mek)", r"\bbir dönüm noktası", r"\bbir kanıtıdır",
    r"günümüzün hızla değişen", r"\bdijital dönüşüm yolculuğu", r"\byolculuğun(?:uz|da)", r"\bmanzara(?:sı|sında)\b",
    r"\bzengin bir doku", r"\boyunun kurallarını değiştir", r"\bbir sonraki seviyeye", r"\bgünün sonunda",
    r"\bderinlemesine dal", r"\bkutunun dışında",
    # çeviri kalıpları
    r"\bolarak hizmet ver(?:mektedir|ir|iyor)", r"\bolarak işlev gör(?:mektedir|ür|üyor)",
    r"\brolünü üstlen(?:mektedir|ir)", r"\bsahiptir\b", r"\bsahip olmaktadır", r"\bimkânı sunmaktadır",
    r"\bimkanı sunmaktadır", r"\bgerçekleştir(?:mektedir|in|iniz|ilmektedir)", r"\bsağlamaktadır",
    r"\bkolaylık sağla", r"\btarafından (?:\w+ ){0,2}\w*(?:ılmaktadır|ilmektedir|ulmaktadır|ülmektedir)",
    r"\bsizin \w+(?:ınız|iniz|unuz|ünüz)\b", r"\bbu bağlamda\b", r"\bbu doğrultuda\b", r"\bbu çerçevede\b",
    r"\bteşkil et", r"\bmevcut bulunmaktadır", r"\bsöz konusu\b",
    r"\bönemle belirtmek gerekir", r"\bbelirtmekte fayda var", r"\bunutulmamalıdır ki", r"\baltını çizmek gerekir",
    # kelime dağarcığı
    r"\bsorunsuz\b", r"\bzahmetsiz(?:ce)?\b", r"\bkapsamlı\b", r"\byenilikçi\b", r"\bçığır açan\b",
    r"\bdönüştürücü\b", r"\bdevrim niteliğinde\b", r"\beşsiz bir deneyim\b", r"\bdeğer kat(?:ar|maktadır|mak)",
    r"\betkili ve verimli\b", r"\bson derece\b", r"\bekosistem",
    # cümle kalıpları
    r"\b(?:sadece|yalnızca) [^.]{0,60} değil,? (?:aynı zamanda|ayrıca)\b",
    r"\bpeki (?:ama|ya)\b[^.?]{0,60}\?", r"\bhaydi\b", r"\bgelin birlikte\b",
    r"\bsonuç olarak\b", r"\bözetle\b", r"\btüm bunlar göz önünde bulundurulduğunda\b",
    r"\bmevcut bilgilere göre\b", r"\bbildiğim kadarıyla\b", r"\buzmanlara göre\b", r"\baraştırmalar gösteriyor ki\b",
    r", bu da [^.]{0,80}(?:göstermektedir|sağlamaktadır)",
    # sohbet kalıntısı
    r"\belbette!", r"\btabii ki!", r"\bharika bir soru\b", r"\bumarım (?:bu bilgiler )?(?:işinize yarar|yardımcı olur)",
    r"\bçekinmeden sor", r"\byardımcı olmaktan memnuniyet", r"\bbir yapay zek[aâ] (?:modeli )?olarak\b",
    r"^\s*işte\b[^.]*:", r"\[(?:adınız|isminiz|tarih)[^\]]*\]",
]
TR_TRANSITIONS = ["ayrıca", "bunun yanı sıra", "buna ek olarak", "öte yandan", "bu bağlamda", "bu doğrultuda", "sonuç olarak", "özetle"]

EN_MONTHS = ["january", "february", "march", "april", "may", "june", "july", "august",
             "september", "october", "november", "december"]
TR_MONTHS = ["ocak", "şubat", "mart", "nisan", "mayıs", "haziran", "temmuz", "ağustos",
             "eylül", "ekim", "kasım", "aralık"]
EN_DAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
TR_DAYS = ["pazartesi", "salı", "çarşamba", "perşembe", "cuma", "cumartesi", "pazar"]
SUMMARY_HEADINGS = {"conclusion", "conclusions", "summary", "in summary", "in conclusion", "final thoughts",
                    "wrapping up", "wrap-up", "key takeaways", "sonuç", "sonuçlar", "özet", "sonuç olarak",
                    "genel değerlendirme", "son söz"}

EMOJI = re.compile("[\U0001F300-\U0001FAFF☀-➿⭐✅]")
EN_SMALL = {"a", "an", "the", "and", "or", "but", "of", "in", "on", "at", "to", "for", "with", "by", "vs", "via"}
TR_SMALL = {"ve", "ile", "ya", "da", "de", "ki", "mi", "mı", "veya", "için"}


def tr_lower(s):
    return s.replace("I", "ı").replace("İ", "i").lower()


def guess_lang(text):
    return "tr" if len(re.findall(r"[çğışöüÇĞİŞÖÜ]", text)) > len(text) / 400 else "en"


def strip_code(text):
    """Blank out fenced and inline code so commands and identifiers are not scanned."""
    text = re.sub(r"```.*?```", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return re.sub(r"`[^`\n]+`", "``", text)


def check_weekdays(low_lines):
    """Find dates that carry a weekday name and compare the weekday with the calendar.

    Reads English and Turkish month and day names together, so a mixed text is covered.
    Returns (number checked, list of (line, quoted text, problem))."""
    months = {m: i for i, m in enumerate(EN_MONTHS, 1)}
    months.update({m: i for i, m in enumerate(TR_MONTHS, 1)})
    day_index = {d: i for i, d in enumerate(EN_DAYS)}
    day_index.update({d: i for i, d in enumerate(TR_DAYS)})
    mon = "|".join(sorted(months, key=len, reverse=True))
    day_rx = re.compile(r"\b(" + "|".join(sorted(day_index, key=len, reverse=True)) + r")\b")
    date_rxs = [
        (re.compile(r"\b(" + mon + r")\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\b"), ("m", "d", "y")),
        (re.compile(r"\b(\d{1,2})(?:st|nd|rd|th)?\.?\s+(?:of\s+)?(" + mon + r")\s*,?\s+(\d{4})\b"), ("d", "m", "y")),
        (re.compile(r"\b(\d{4})-(\d{2})-(\d{2})\b"), ("y", "mn", "d")),
    ]
    checked, problems = 0, []
    for i, ln in enumerate(low_lines, 1):
        for rx, order in date_rxs:
            for m in rx.finditer(ln):
                parts = dict(zip(order, m.groups()))
                month = int(parts["mn"]) if "mn" in parts else months[parts["m"]]
                before, after = ln[max(0, m.start() - 25):m.start()], ln[m.end():m.end() + 25]
                near = [(len(before) - d.end(), d.group(1)) for d in day_rx.finditer(before)]
                near += [(d.start(), d.group(1)) for d in day_rx.finditer(after)]
                if not near:
                    continue
                checked += 1
                _, said = min(near)
                quoted = m.group(0)
                try:
                    real = datetime.date(int(parts["y"]), month, int(parts["d"])).weekday()
                except ValueError:
                    problems.append((i, quoted, "is not a real date"))
                    continue
                if day_index[said] != real:
                    names = TR_DAYS if said in TR_DAYS else EN_DAYS
                    problems.append((i, f"{quoted} … {said}", f"that date is a {names[real]}, not a {said}"))
    return checked, problems


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--lang", choices=["en", "tr", "auto"], default="auto")
    ap.add_argument("file")
    a = ap.parse_args()
    raw = open(a.file, encoding="utf-8").read()
    lang = guess_lang(raw) if a.lang == "auto" else a.lang
    text = strip_code(raw)
    low = tr_lower(text) if lang == "tr" else text.lower()
    lines = text.split("\n")
    low_lines = low.split("\n")
    phrases = TR_PHRASES if lang == "tr" else EN_PHRASES
    transitions = TR_TRANSITIONS if lang == "tr" else EN_TRANSITIONS
    small = TR_SMALL if lang == "tr" else EN_SMALL

    print(f"scan.py — {a.file} — language: {lang}")
    hits = []
    for pat in phrases:
        rx = re.compile(pat, re.M)
        for i, ln in enumerate(low_lines, 1):
            for m in rx.finditer(ln):
                hits.append((i, m.group(0).strip()))
    hits.sort()
    print(f"\nPhrases ({len(hits)}):")
    for i, h in hits:
        print(f"  line {i}: {h}")

    # sentence-initial transitions
    starts = Counter()
    for sent in re.split(r"(?<=[.!?])\s+|\n", low):
        s = sent.strip().lstrip("-*> ").strip()
        for t in transitions:
            if s.startswith(t + ",") or s.startswith(t + " "):
                starts[t] += 1
    print(f"\nSentence-initial transitions: {sum(starts.values())}" + (f" ({', '.join(f'{k} ×{v}' for k, v in starts.most_common())})" if starts else ""))

    # em dashes per paragraph
    paras = [p for p in re.split(r"\n\s*\n", text) if p.strip()]
    dash_total = text.count("—")
    heavy = sum(1 for p in paras if p.count("—") >= 2)
    print(f"Em dashes: {dash_total} in {len(paras)} paragraph(s); paragraphs with 2 or more: {heavy}")

    # title-case headings
    tc = []
    for i, ln in enumerate(lines, 1):
        m = re.match(r"^#{1,6}\s+(.*)$", ln)
        if not m:
            continue
        words = [w for w in re.findall(r"[^\W\d_][\w'’-]*", m.group(1))]
        rest = [w for w in words[1:] if (tr_lower(w) if lang == "tr" else w.lower()) not in small or w[0].isupper()]
        caps = [w for w in rest if w[0].isupper() and not w.isupper()]
        small_caps = [w for w in words[1:] if (tr_lower(w) if lang == "tr" else w.lower()) in small and w[0].isupper()]
        if (len(rest) >= 2 and len(caps) >= max(2, int(0.6 * len(rest)))) or small_caps:
            tc.append((i, m.group(1).strip()))
    print(f"Title-case headings: {len(tc)}")
    for i, h in tc:
        print(f"  line {i}: {h}")

    inline_hdr = sum(1 for ln in lines if re.match(r"^\s*[-*+]\s+\*\*[^*]+:\*\*|^\s*[-*+]\s+\*\*[^*]+\*\*:", ln))
    bold_prose = sum(len(re.findall(r"\*\*[^*\n]+\*\*", ln)) for ln in lines if not re.match(r"^\s*([-*+]|\d+\.|#)", ln))
    emoji = len(EMOJI.findall(text))
    print(f"Bold inline-header list items: {inline_hdr}")
    print(f"Bold spans in running prose: {bold_prose}")
    print(f"Emoji: {emoji}")
    # a closing section that only summarizes the page
    heads = [(i, re.match(r"^#{1,6}\s+(.*)$", ln).group(1).strip()) for i, ln in enumerate(lines, 1)
             if re.match(r"^#{1,6}\s+", ln)]
    if len(heads) >= 2:
        i, h = heads[-1]
        if (tr_lower(h) if lang == "tr" else h.lower()).strip(" :.") in SUMMARY_HEADINGS:
            print(f"Closing summary section: line {i}: {h} (remove it only after moving any claim it "
                  f"carries that the page does not already state)")

    # dates whose weekday does not match the calendar: report them, never fix them
    checked, problems = check_weekdays(low_lines)
    print(f"Dates with a weekday: {checked} checked, {len(problems)} inconsistent")
    for i, q, p in problems:
        print(f"  line {i}: {q!r}: {p} (keep it as written and mention it in the note)")

    words = len(re.findall(r"\w+", text))
    print(f"\nWords: {words}; phrase hits per 100 words: {100 * len(hits) / max(words, 1):.1f}")


if __name__ == "__main__":
    sys.exit(main())
