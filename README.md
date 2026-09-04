# Axur pre-meeting report

One script asks Axur what it knows about a prospect. It writes a report you can
send, as HTML and as a PDF: the counts on a cover page, the records behind each
count after it.

| The number | What it counts |
|---|---|
| Leaked credentials | Accounts on the domain found in breaches and dumps |
| Readable passwords | The subset whose password was stored in clear text |
| Impersonation sites | Pages built to look like the brand |
| Lookalike domains | Names one character away from theirs |
| Mail-enabled lookalikes | Of those, the ones set up to receive mail |

> [!WARNING]
> The report holds the leaked passwords in clear text. Every account in it needs
> a reset. Send the file the way you would send a password, and delete it after.
> `--mask-passwords` prints `h*****2` instead, when the count is the point.

## Run it

You need an Axur API key, and Chrome or Edge for the PDF. Nothing to install.
The script asks for anything you leave off, and hides the key as you type.

| Platform | Command |
|---|---|
| Mac | `bash axur-report.sh` |
| Windows | `powershell -ExecutionPolicy Bypass -File axur-report.ps1` |

Tested on PowerShell 7.6.5, the current release. Not tested on Windows
PowerShell 5.1, the one `powershell.exe` starts.

Get a key in Axur: gear icon, **My preferences**, **API keys**, Generate New
Key. Axur shows it once.

<details>
<summary><b>Flags</b></summary>

| Flag | PowerShell | What it does |
|---|---|---|
| `--config larkspur.conf` | `-Config larkspur.conf` | Read customer settings from a config file; command-line flags override it |
| `--save-config larkspur.conf` | `-SaveConfig larkspur.conf` | Save this run's customer settings, never the API key |
| `--brand "BRAND"` | `-Brand` | Brand, as Axur spells it |
| `--domain customer.com` | `-Domain` | Customer domain |
| `--key` | `-ApiKey` | Your API key |
| `--rows 50` | `-Rows` | Rows listed under each count |
| `--wait 300` | `-Wait` | Seconds to let each search finish before reading its count |
| `--days 30` | `-Days` | Only records Axur saw in the last N days. Default 30 |
| `--all-time` | `-AllTime` | No date limit. Slower, and the counts run higher |
| `--mask-passwords` | `-MaskPasswords` | Print `h*****2` instead of the password |
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

</details>

<details>
<summary><b>Config file</b></summary>

A config file carries the settings that stay the same between meetings.
`--save-config customer.conf` writes one. `--config customer.conf` reads it.
A flag on the command line beats the file. The script never stores the API key.

```text
brand        = Larkspur Financial
domain       = larkspurfinancial.com
min-score    = 50
exclude-file = ~/known/larkspur-owned.csv
```

</details>

<details>
<summary><b>Worth knowing</b></summary>

| Topic | Note |
|---|---|
| Filters | Filters touch the three domain searches only. A credential has no score. |
| Date window | The run covers the last 30 days by default, which keeps it quick. `--all-time` drops the limit. If Axur rejects the date clause the script says so once and covers all time anyway. |
| Filtered counts | The script recounts a filtered headline over the rows that survive, so the number and the table agree. |
| `--wait` | `--wait` bounds each search. The script reports anything still running as "at least N", on the terminal and in the report. |
| Impersonated brand | Read the Impersonated brand column before sending. That search matches any brand whose name contains the word. |
| PDF bookmarks | The PDF has no bookmark pane, because Chrome writes no outline. Every table header carries a "Top" link instead. |
| Windows | Tested on PowerShell 7.6.5, the current release. Not tested on Windows PowerShell 5.1, the one `powershell.exe` starts. |

</details>

<details>
<summary><b>Files</b></summary>

| Path | What it is |
|---|---|
| `axur-report.sh` | The Mac script |
| `axur-report.ps1` | The Windows script. Generated, do not edit by hand |
| `docs/index.html` | The SE guide, with both scripts embedded in its download buttons |
| `docs/hosting.md` | How to host the guide |
| `docs/redesign/` | An earlier look for the report, kept for reference |
| `tools/build.py` | Rebuilds `axur-report.ps1` and the guide's download buttons. Run it after every edit to `axur-report.sh` |

`axur-report.sh` holds the report's HTML. `tools/build.py` generates
`axur-report.ps1` and the guide's download buttons from it. Rebuild both after
every edit:

```bash
python3 tools/build.py
```

</details>
