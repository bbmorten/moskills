# English (US) — patterns of generated text, and what to write instead

Grounded in Wikipedia's "Signs of AI writing" (the editors' field guide, read
2026-11-06) and in US editorial norms. Each pattern says what it looks like, why it
reads as generated, and the fix. Fix the pattern, not the word.

Contents: 1 Content · 2 Vocabulary · 3 Sentence patterns · 4 Rhythm · 5 Chatbot
residue · 6 Formatting · 7 US conventions · 8 What NOT to change · 9 Worked example

## 1. Content habits

**Inflated significance.** Tying an ordinary fact to legacy, trends or importance:
"stands as a testament to", "plays a pivotal/crucial/vital role", "underscores the
importance of", "marks a significant shift", "reflects broader trends", "setting the
stage for", "a key turning point", "the evolving landscape of", "leaves an indelible
mark", "deeply rooted". *Fix:* state the fact. If the importance is real, show it with
a specific consequence the original already gives; never invent one.

> The update plays a pivotal role in enhancing security. → The update improves
> security. (If the original goes on to name the two login bugs it fixes, the rewrite
> can lead with them; it never supplies details the original lacks.)

**Trailing "-ing" commentary.** ", highlighting its importance", ", ensuring a seamless
experience", ", reflecting the team's commitment to", ", contributing to the overall".
*Fix:* delete it, or turn a real claim into its own sentence.

**Vague attribution.** "Experts say", "Industry reports suggest", "Many users find",
"Observers note" with no source. *Fix:* name the source the text already gives, or
state the claim as the author's own; do not invent a source.

**Vague connection.** "in connection with", "associated with", "in relation to" used
to hint at a link instead of stating it. *Fix:* say what the relationship is
("caused by", "part of", "used for") — only if the text supports it.

**Formulaic endings.** "Despite these challenges, X continues to...", "Looking ahead,
...", "In conclusion/In summary/Overall, ...", a final sentence that restates the
paragraph. *Fix:* end on the last real point. The same habit at page scale is a closing
"## Conclusion" / "## Summary" / "## Key takeaways" section that repeats the page:
move any claim in it that the page does not already make into the section it belongs
to, then delete the section.

**Hedging disclaimers.** "While specific details are limited", "based on available
information", "it's worth noting that information may vary". *Fix:* remove unless the
author genuinely means the caveat; then make it specific.

## 2. Vocabulary that clusters in generated text

One of these is fine. A paragraph with three is a tell. Replace with the plain word
that says what is meant, or remove.

| Instead of | Usually write |
| --- | --- |
| delve into, deep dive | look at, examine, cover (or just start) |
| leverage, utilize | use |
| facilitate, enable | help, let, allow (or the specific verb) |
| enhance, elevate, bolster | improve, raise, strengthen — or the specific change |
| robust, seamless, comprehensive | (say what makes it so: "handles X", "covers A, B") |
| crucial, pivotal, vital, key (adj.) | important — or drop it and show why |
| showcase, highlight (verb), underscore | show |
| foster, cultivate | build, encourage |
| garner | get, win, attract |
| boast, feature (= has) | has, includes |
| landscape, realm, tapestry, ecosystem (abstract) | field, area, world — or name the thing |
| navigate (a problem), journey | handle, deal with; process, path |
| intricate, multifaceted, nuanced | complex, detailed — or say how |
| meticulous(ly), vibrant, renowned, nestled | careful(ly); (drop promotional adjectives) |
| empower, unlock, streamline, game-changer, cutting-edge | (say the concrete effect) |
| Additionally, Moreover, Furthermore (stacked) | also, and — or no connector |
| align with, resonate with | match, fit, appeal to |
| valuable insights, actionable insights | (name the finding) |

## 3. Sentence patterns

**Copula avoidance.** "serves as", "stands as", "functions as", "acts as",
"represents", "boasts", "features", "offers a" where "is"/"has" is meant.
*Fix:* "The dashboard serves as the central hub for monitoring" → "The dashboard is
where you monitor ..."

**Negative parallelism.** "It's not just X, it's Y", "Not only X but also Y", "This
isn't about X — it's about Y", "Y rather than X" as a set-piece. *Fix:* state Y; keep
X only if the contrast is real and the author meant it.

**Rule of three.** Adjective triplets ("fast, secure, and reliable") and three-part
lists in sentence after sentence. *Fix:* keep the items the text supports; two is
fine; one strong word beats three weak ones. Never drop an item that carries a fact.

**False range.** "From startups to enterprises", "from X to Y" that names no real
range. *Fix:* say who or what, or drop it.

**Synonym cycling (elegant variation).** Calling the same thing "the tool", "the
platform", "the solution", "the offering" in successive sentences. *Fix:* pick one
name and repeat it — readers prefer the same word for the same thing.

**Signposting.** "Let's dive in", "Here's the thing", "It's important to note that",
"It's worth mentioning that", "Notably,", "Simply put,", "In essence,". *Fix:* delete
the signpost and say the thing.

**Over-qualified claims.** "can potentially help to somewhat improve". *Fix:* keep
exactly one hedge if the author hedged; remove stacked ones.

## 4. Rhythm

Generated prose has an even beat: sentences of similar length, each opening with a
transition or "This", paragraphs that each end with a one-line summary. *Fix:* vary
length (a short sentence after two long ones), start some sentences with the subject,
merge two thin sentences, split one overloaded one, and remove paragraph-closing
summaries. Do not add rhetorical questions or exclamation marks to sound lively.

## 5. Chatbot residue

Delete outright: "Certainly!", "Absolutely!", "Great question!", "I hope this
helps", "Let me know if you have any questions", "Feel free to reach out", "Here's a
breakdown/overview of", "As an AI language model", "As of my last update", bracketed
placeholders ("[Your Name]", "[insert date]"), and any sentence addressed to the
reader of a chat rather than of the document. If a placeholder holds a real gap, keep
it visible and mention it in your note rather than inventing a value.

## 6. Formatting

- **Title Case Headings** → sentence case ("Getting started with the API"), unless the
  document's house style is title case; keep product names capitalized.
- **Bold scattered through prose** → bold only UI labels and the one term a reader must
  not miss.
- **Inline-header lists** ("- **Speed:** It is fast.") → a plain list or a short
  paragraph when the labels add nothing; keep them in reference material where they
  aid scanning.
- **Emoji** as bullets or heading decorations → remove (unless the source is a chat
  post that clearly wants them).
- **Em dashes.** Readers still notice prose with an em dash in every other sentence.
  Keep one where it does real work (an aside, a sharp turn); otherwise use a comma,
  colon, parentheses or a new sentence. Aim for at most about one per paragraph.
- **Curly vs straight quotes**: leave as the source has them; consistency matters more.
- Do not add Markdown to text that had none (an email stays plain text).

## 7. US English conventions

US spelling (organize, color, center, defense, catalog, toward, analyze), the serial
comma in lists of three or more, double quotation marks with periods and commas inside
them, "e.g.," and "i.e.," followed by a comma. Dates as the source writes them. Keep
the source's spelling if it is consistently British and the person did not ask for US
English (see SKILL.md).

## 8. What NOT to change

These are not reliable signs, and "fixing" them damages good writing:

- correct grammar and a formal or technical register;
- a single transition word ("However,", "Additionally,") where it helps;
- a genuine list of three, a precise technical term, a necessary passive ("the key is
  stored encrypted");
- headings and lists in reference documentation that the reader scans;
- domain vocabulary that happens to overlap the table above ("a robust estimator" in
  statistics, "leverage" in finance, "landscape" in geography).

## 9. Worked example

> **Before:** In today's rapidly evolving digital landscape, our new reporting feature
> serves as a game-changer for teams of all sizes. It's not just a dashboard — it's a
> comprehensive solution that empowers users to unlock valuable insights, streamline
> workflows, and make data-driven decisions. Additionally, it boasts seamless
> integration with Slack, ensuring that critical updates are never missed. Overall,
> this release underscores our commitment to innovation.

> **After:** Our new reporting feature is built for teams of any size. It is more than
> a dashboard: it helps people find useful insights in their data, simplify their
> workflows, and base decisions on data. It also connects to Slack, so nobody misses an
> important update. We see this release as part of our commitment to innovation.

452 characters in, 318 out (−30%; `check_preserved.py`: OK). Every statement a reader
could check or the author chose to make is still there: any team size, more than a dashboard, insights, simpler workflows,
data-based decisions, the Slack connection, important updates, the commitment line.
What went is what stated nothing: the "evolving landscape" opener, "game-changer",
"comprehensive", "seamless", "boasts", the em-dash contrast, the "-ing" tail and
"Overall,". Note what the rewrite did NOT do: it did not invent a concrete benefit
("saves you an hour a day") to replace the vague one — that would be a new claim.
