# Axur pre-meeting report

One script asks Axur what it knows about a prospect and writes the answer as a
report you can send. Five numbers: leaked credentials, readable passwords,
impersonation sites, lookalike domains, and the lookalikes that can send mail.

You need an Axur API key, and Chrome or Edge for the PDF. Nothing else.

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
| `--exclude LIST` | `-Exclude` | Drop rows matching these, comma separated |
| `--out FILE` | `-Out` | Output file |
| `--no-pdf` | `-NoPdf` | Write the HTML only |
| `--no-open` | `-NoOpen` | Print the path instead of opening it |

## Dropping rows you already know about

A customer's own `.au` domain is not a lookalike, and a score of 12 is noise.
Both flags take them out:

```bash
bash axur-report.sh --domain customer.com --min-score 50 --exclude ".au,partner.com"
```

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
| `guide.html` | The SE guide, with both scripts embedded in its download buttons |
| `build-ps1.py` | Rebuilds the PowerShell from the shell script's HTML |
| `embed-scripts.py` | Pushes both scripts back into `guide.html` |

The report's HTML lives once, in `axur-report.sh`. After editing it, run both
generators or the other copies serve stale code:

```bash
python3 build-ps1.py && python3 embed-scripts.py
```
