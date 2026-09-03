# Redesign notes

`mockup.html` is self-contained. Open it in a browser, or print it to PDF with the
headless-Chrome recipe. Dummy customer: Larkspur Financial (fictional).

## What changed, and why

### Summary cards
- Number first, story second. Each card is a two-column grid: figures on the left
  (fixed 250px), text on the right, one vertical rule between them. The old layout
  pushed text to the left wall and tiles to the right wall; the middle was dead.
- A subset ("2,906 of them readable") sits under its parent number with a small
  proportion bar. The relationship "part of" is now visible, not implied by two tiles.
- Severity moved from the tile background to the number itself: red = usable today,
  amber = one more step. One key line above the cards explains the two colours.
- Each card ends with "Section 01 · See the records". The same section number appears
  on the detail page strip, so the link survives on paper.
- A section list at the foot of the cover doubles as a table of contents for the PDF.

### Detail tables
- Row number column, stronger zebra (`#f6f6f3`), and 8px vertical padding with
  `vertical-align: top`. Rows read as rows.
- Column widths are declared per column (`w` for screen, `wp` for paper) in the
  `COLS` table in the script. A date gets 10%, an account gets 30%. Nothing is
  equal-width any more.
- Nothing is truncated. Long values wrap; identifiers get soft break points before
  `@` and after `. / - ? & =` (`<wbr>`) so an email breaks at the `@`, not inside a
  word. Query strings are dropped from URLs (a session token tells the reader nothing).
- Column order per table: the thing itself, then who it is for or pretends to be,
  then how bad, then when. Dates are last because they are the least important.
- Identifiers (accounts, domains, URL paths) are in JetBrains Mono; prose (source,
  brand names, kind of page) in Inter. The path part of a URL is a quieter grey.

### Values rendered for a human (the `F` formatters in the script)
| Raw | Shown |
|---|---|
| `969235200000` | `17 Sep 2000` plus "25 years ago" underneath |
| `["Larkspur Financial","Norton"]` | "**Larkspur Financial** and Norton" (customer name bold) |
| `riskScore: 4.7` / `92.1` | number plus a 56px meter; grey under 40, amber 40–69, red 70+ |
| `contentType: "Other"` | "Not classified" (map in `CONTENT`) |
| `passwordType: "PLAIN"` | red dot "Readable"; anything else grey dot "Hashed" |
| `credentialRequested` / `paymentRequested` | "Login details", "Payment (probable)", or "Nothing" |
| `dnsEntriesRecordMX: [...]` | red "Yes" plus the first mail host, "+1" if more |
| `registrantOrganization: "Domains By Proxy LLC"` | "Hidden" plus the proxy name in small text |
| `sourceName: "Deep/Dark Web - Telegram"` | "Telegram channel" (map in `SOURCE`) |
| empty | "Not recorded" / "Not disclosed" / an em dash, never blank |

### Way back to the top
- Every section starts with a thin strip: `01 / 05 · Exposed credentials · Larkspur
  Financial · threat exposure · [↑ Summary]`. On screen it is `position: sticky`, so
  the pill is always in view while scrolling a long table, and the table header
  sticks under it. On paper it prints once as a running header. No floating button.
- The trail at the foot of each table ("↑ Back to the summary" / "02 · Next →") stays
  on screen and is hidden in print.

### Print
- `@page cover { margin: 0 }` (a Chrome named page) keeps the cover full-bleed dark;
  all other pages get 15mm/13mm white margins. Verified: the cover fits on one A4 page.
- Every section starts on a new page. `thead` repeats when a table breaks across
  pages; rows never split.
- The old `max-width: 760px` breakpoint fired in print (A4 is 794px wide) and switched
  tables to auto layout. It is now `@media screen and (max-width: 820px)`.
- Fonts load with `display=swap` instead of `optional`, so headless Chrome waits for
  them within the virtual-time budget rather than silently falling back.

### Palette
- Brand tokens throughout: `#101820` cover, `#F0EFE9` cards, `#D9E1E2` table lines and
  meter tracks, `#00E2EC` for the fact values and kicker, green→cyan rule.
- Severity: `#ff5a52` / `#f5c518` on the dark cover as before. On white paper red is
  `#c9362d` and amber `#8a6300`; the originals fail 4.5:1 as text on white.

## Things the owner may disagree with
1. Big numbers are coloured by severity (red/amber). The amber on off-white reads as
   dark mustard. The alternative is black numbers with a coloured dot in the label.
   Easy swap: drop the `sev-*` classes on `.big`.
2. The title is a sentence ("What is visible about Larkspur Financial from the outside")
   with "Executive summary" demoted to a kicker. The old report led with the label.
3. Query strings are stripped from URLs. If a path is evidence, the SE may want it whole.
4. Section 02 and 05 are subsets of 01 and 04 and mostly repeat rows. In the real
   report they might be better as a filter on the parent table, or dropped.
5. `SOURCE` and `CONTENT` maps are hand-written for the values in the Equifax sample.
   Unknown values fall through unchanged, so nothing breaks, but the list needs
   growing as new values appear.
6. The `.txt .go` link text ("See the records") prints on paper. It still makes sense
   there because it names the section number, but it is a link that cannot be clicked.
7. The Equifax sample has "Mail-enabled lookalikes" (385) larger than "Lookalike
   domains" (78) because the two queries use different fields
   (`domainLabel` vs `sanitizedDomainLabel`). The card presents one as a subset of the
   other, which the meter would then draw at more than 100%. The script clamps it, but
   the queries should agree.

## Not resolved
- Sticky behaviour on screen was not screenshotted (headless Chrome captures scroll
  position 0). It is standard CSS and I expect it to work; worth a manual scroll.
- No page numbers in the cover's section list. Chrome does not support
  `target-counter()`, so "Section 03" is the reference, not "page 6".
- Print widths (`wp`) are tuned for A4 portrait. US Letter is 0.9mm narrower per
  side, which should be fine, but I did not test it.
