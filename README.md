# Run the Axur report script

One command pulls all five numbers for a customer. Worth it for several
customers, or a scheduled run. For a single meeting the Copy buttons in the
guide are quicker.

## 1. Get an API key

In Axur: gear icon, **My preferences**, **API keys**, Generate New Key.
Copy it once. Axur never shows it again.

## 2. Get the script

Open the guide and use the download button for your platform. It arrives with
the customer already filled in.

If the download is blocked, use the Copy button instead and paste the text into
a new file: `axur-report.sh` on a Mac, `axur-report.ps1` on Windows. Save it in
your Downloads folder.

## 3. Run one line

It asks for anything it needs, and hides the key as you type.

macOS:

```bash
bash ~/Downloads/axur-report.sh
```

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File $env:USERPROFILE\Downloads\axur-report.ps1
```

## Flags, to skip the questions

macOS only.

| Flag | What it does |
|---|---|
| `--brand "BRAND"` | Brand, as Axur spells it. Quote it only if it has a space |
| `--domain customer.com` | Customer domain |
| `--key YOUR_API_KEY` | Your API key |
| `--rows 50` | Rows listed under each count |
| `--no-pdf` | Write the HTML only |
| `--no-open` | Print the path instead of opening it |

```bash
bash ~/Downloads/axur-report.sh --brand BRAND --domain customer.com --key YOUR_API_KEY
```

## What you get

A summary page, then the records behind each number, and a PDF if Chrome or
Edge is installed. Passwords are never included.

The Windows version prints the counts only. No report, no PDF.
