# Axur pre-meeting report

One script asks Axur what it knows about a prospect and writes the answer as a
report you can send. Five numbers: leaked credentials, readable passwords,
impersonation sites, lookalike domains, and the lookalikes that can send mail.

You need an Axur API key, and Chrome or Edge for the PDF.

Nothing to install: the Mac script uses curl, sed and perl, all of which ship
with macOS, and the Windows script is PowerShell only.

The Windows script has been run end to end on PowerShell 7.6.5. It has not been
run on Windows PowerShell 5.1, the one `powershell.exe` starts, so treat that as
untested rather than supported.

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
| `--config larkspur.conf` | `-Config larkspur.conf` | Read customer settings from a config file; command-line flags override it |
| `--save-config larkspur.conf` | `-SaveConfig larkspur.conf` | Save this run's customer settings, never the API key |
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
| `--brandfetch ID` | _(none)_ | A Brandfetch client id, if the plain lookup is rate limited |
| `--out FILE` | `-Out` | Output file |
| `--no-pdf` | `-NoPdf` | Write the HTML only |
| `--no-open` | `-NoOpen` | Print the path instead of opening it |
| `--debug` | `-ShowRaw` | Print the raw replies |

## Save customer settings

Keep the settings that stay the same from one meeting to the next in a simple
config file:

```text
brand        = Larkspur Financial
domain       = larkspurfinancial.com
logo         = ~/logos/larkspur.png
min-score    = 50
exclude-file = ~/known/larkspur-owned.csv
rows         = 100
```

Then the next run is just the config flag; the script still prompts for the API
key:

```bash
bash axur-report.sh --config larkspur.conf
```

```powershell
powershell -ExecutionPolicy Bypass -File axur-report.ps1 -Config larkspur.conf
```

Command-line flags override the file, wherever `--config` or `-Config` appears.
Unknown keys produce a warning and are ignored. A missing config file stops the
run with a clear message. The API key is never read from or written to a config
file.

To create the file from a successful command, add `--save-config larkspur.conf`
(PowerShell: `-SaveConfig larkspur.conf`). It saves `brand`, `domain`, `logo`,
`min-score`, `exclude-file`, and `rows`; run-control choices such as opening the
report or making a PDF stay on the command line.

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
done. The leaked passwords are written to the file in full, so treat the report
as you would treat the credentials themselves: send it the way you would send a
password, and delete it once the accounts are reset.

Read the Impersonated brand column before you send it: that search matches any
brand whose name contains the word, so a one-word brand picks up
unrelated companies that share it.

The PDF has no bookmark pane. Chrome writes page breaks and working links but no
outline, so every section table carries a small "Top" link in its header, on
every page, back to the summary.

## Files

| | |
|---|---|
| `axur-report.sh` | The Mac script |
| `axur-report.ps1` | The Windows script. Generated, do not edit by hand |
| `docs/index.html` | The SE guide, with both scripts embedded in its download buttons |
| `docs/hosting.md` | How to host the guide |
| `docs/redesign/` | An earlier look for the report, kept for reference |
| `tools/build.py` | Rebuilds the PowerShell and the guide's download buttons |

The report's HTML lives once, in `axur-report.sh`. After editing it, run the
generator or the other copies serve stale code:

```bash
python3 tools/build.py
```
