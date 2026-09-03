# Axur pre-meeting report

One script asks Axur what it knows about a prospect and writes the answer as a
report you can send. Five numbers: leaked credentials, readable passwords,
impersonation sites, lookalike domains, and the lookalikes that can send mail.

You need an Axur API key, and Chrome or Edge for the PDF.

Nothing to install: the Mac script uses curl, sed and perl, all of which ship
with macOS, and the Windows script is PowerShell only.

## Get a key

In Axur: gear icon, **My preferences**, **API keys**, Generate New Key.
Copy it once. Axur never shows it again.

## Run it

It asks for anything you leave off, and hides the key as you type.

```bash
bash axur-report.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File axur-report.ps1
```

Skip the questions:

```bash
bash axur-report.sh --brand "BRAND" --domain customer.com --key YOUR_API_KEY
```

| Flag | PowerShell | What it does |
|---|---|---|
| `--brand "BRAND"` | `-Brand` | Brand, as Axur spells it |
| `--domain customer.com` | `-Domain` | Customer domain |
| `--key` | `-ApiKey` | Your API key |
| `--rows 50` | `-Rows` | Rows listed under each count |
| `--min-score N` | `-MinScore` | Drop rows scoring below N |
| `--exclude LIST` | `-Exclude` | Drop rows matching these, comma separated. Repeatable |
| `--exclude-file F` | `-ExcludeFile` | Same, read from a file or CSV |
| `--out FILE` | `-Out` | Output file |
| `--no-pdf` | `-NoPdf` | Write the HTML only |
| `--no-open` | `-NoOpen` | Print the path instead of opening it |

## Dropping rows you already know about

A customer's own `.au` domain is not a lookalike, and a score of 12 is noise.
Both flags take them out:

```bash
bash axur-report.sh --domain customer.com --min-score 50 --exclude ".au,partner.com"
```

A customer's own domains run to dozens, so keep them in a file instead of on
the command line. One per line, or the first column of a CSV — a `domain`
header row is skipped, so a sheet exported from Excel works as it is, and `#`
starts a comment:

```
domain,note
xyz.com,ours
.au,customer region
partner.co.uk,"reseller, agreed"
```

```bash
bash axur-report.sh --domain customer.com --exclude-file known-good.csv
```

`--exclude` can be given more than once, and adds to whatever the file holds.

The headline number is recounted over the rows that survive, so the count and
the table below it always agree. To count over the whole result rather than the
first page, the script walks the pages while a filter is on. If it reaches its
page cap it says so, and that count came from a partial pull.

Filters only touch the three domain searches. A leaked credential has no score
and no domain to exclude on.

## What you get

A summary page, the records behind each number, and a PDF. It opens when it is
done. Passwords are never written to the file.

Read the Impersonated brand column before you send it: that search matches any
brand containing the word, so Delta returns Delta Cafés.

## Files

| | |
|---|---|
| `axur-report.sh` | The Mac script |
| `axur-report.ps1` | The Windows script. Generated, do not edit by hand |
| `docs/index.html` | The SE guide, with both scripts embedded in its download buttons |
| `docs/hosting.md` | How to host the guide |
| `tools/build.py` | Rebuilds the PowerShell and the guide's download buttons |

The report's HTML lives once, in `axur-report.sh`. After editing it, run both
generators or the other copies serve stale code:

```bash
python3 tools/build.py
```
