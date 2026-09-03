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
| `--wait 300` | `-Wait` | Seconds to let each search finish before reading its count |
| `--drop-own` | `-DropOwn` | Drop the customer's own domain from the results |
| `--min-score N` | `-MinScore` | Drop rows scoring below N |
| `--exclude LIST` | `-Exclude` | Drop rows matching these, comma separated. Repeatable |
| `--exclude-file F` | `-ExcludeFile` | Same, read from a file or CSV |
| `--logo SRC` | `-Logo` | Use this image instead of looking one up. A file or a URL |
| `--no-logo` | `-NoLogo` | Look up nothing. The names are written instead |
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
page cap it says so on the terminal and in the report footer, and that count
came from a partial pull.

The customer's own sites match these searches without impersonating anyone.
`--drop-own` removes them. It is not the default, because any filter forces the
full page walk.

## Counts that are still climbing

Axur answers with a total long before it has finished searching. The script
waits for the search to report itself finished, up to `--wait` seconds, and
prints "at least N" for any that had not. Those also carry a line in the report
footer, so the customer is not shown a fraction as if it were the whole. A large
tenant needs a longer wait.

Filters only touch the three domain searches. A leaked credential has no score
and no domain to exclude on.

## Logos

The cover looks the customer's logo up by domain. When that finds nothing, or
finds the wrong thing, hand it one:

```bash
bash axur-report.sh --domain customer.com --logo ~/Desktop/customer-logo.png
```

It takes a URL just as happily, and `--no-logo` skips the lookup altogether and
writes the company names instead.

## What you get

A summary page, the records behind each number, and a PDF. It opens when it is
done. Passwords are never written to the file.

Read the Impersonated brand column before you send it: that search matches any
brand whose name contains the word, so a one-word brand picks up
unrelated companies that share it.

## Files

| | |
|---|---|
| `axur-report.sh` | The Mac script |
| `axur-report.ps1` | The Windows script. Generated, do not edit by hand |
| `docs/guide.html` | The SE guide, with both scripts embedded in its download buttons |
| `docs/DEPLOY.md` | How to host the guide |
| `tools/build.py` | Rebuilds the PowerShell and the guide's download buttons |

The report's HTML lives once, in `axur-report.sh`. After editing it, run both
generators or the other copies serve stale code:

```bash
python3 tools/build.py
```
