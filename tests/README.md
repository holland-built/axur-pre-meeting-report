# The test kit

One command, from anywhere:

```bash
bash tests/run.sh
```

It runs both report scripts end to end against a stand-in Axur API and checks
what came out. It never talks to Axur, and it needs no API key of yours.

## What it needs

| Thing | Why | Without it |
|---|---|---|
| `python3` | runs the stand-in API | nothing runs |
| `/usr/bin/perl` | the scripts use it to filter and trim | some checks fail |
| `curl` | the scripts use it, and the runner waits on the stand-in with it | nothing runs |
| PowerShell 7 | runs `axur-report.ps1` | those checks say `skip`, and the summary counts them |

The runner looks for PowerShell in `$PWSH`, then on the `PATH`, then in
`~/.local/pwsh/pwsh`. Set `PWSH` to point it somewhere else.

## What it does

`tests/mkfake.sh` copies both scripts and changes one line in each: the API
base URL becomes `http://127.0.0.1:8731`. It refuses to write a copy that
still names `api.axur.com`, so a test can never reach the real API.

`tests/fakeapi.py` is the stand-in. It listens on 127.0.0.1 only. Environment
variables steer it, so one server covers every case:

| Variable | What the stand-in then does |
|---|---|
| `FAKE_PAGES=N` | each search has N pages of results |
| `FAKE_CLAMP=1` | a page past the end returns the last page again |
| `FAKE_BADJSON=N` | search N answers with malformed JSON |
| `FAKE_TRUNC=N` | search N's reply is cut off mid-array |
| `FAKE_NODATE=1` | the API refuses any query with a date clause |
| `FAKE_SHAPE=reference` | rows name the site in `reference`, with no `domain` |
| `FAKE_NOSCORE=1` | rows carry no risk score |
| `FAKE_SLOW=N` | every read takes N seconds |

Set `PORT` to move the stand-in off 8731. The runner stops if something is
already listening there, and says what.

## How it stays honest

The old version of this suite reported 30 passes while every run was exiting
1. It called the scripts with `--key K`, a flag that no longer exists, and it
searched output files an earlier run had left in a directory it never cleared.
Five rules keep that from happening again.

1. Every run works in a directory `mktemp` makes and the runner removes on the
   way out. A file left by an earlier run cannot be there to be read.
2. The API key goes in a file, as both scripts now require.
3. Every run gets a word of its own, and the runner puts that word in the brand
   it passes. The brand is written into the report, so the word comes back out
   in the file. `wrote` fails when the exit status was not 0, when the file is
   empty, or when the file does not carry that word, and it prints the last
   lines of the run. A file date would not do this job: a script that rewrote
   an old file in place would give it a new date and stale content.
4. Only `wrote` opens a report for reading, and the word is looked for again
   on every read, in the file itself. A check that reads a report the runner
   never signed off gets `not-verified`. So does one that reads a report that
   is not there, and one that reads a name that was signed off earlier but
   holds something else now. None of those is a number, so none can match what
   a check wants, not even a check wanting 0.

5. Counting happens inside the helpers, never in a pipe at the check. Writing
   `"$(qy f.html | grep -c 'x')"` would count the sentinel as zero matches, and
   zero is exactly what some checks want. `qyc` hands the sentinel back instead
   of counting it.

The last seven checks in the suite are the suite testing itself. A report that
does not carry this run's word is refused. An unsigned report and a missing one
both read as `not-verified`, and both fail a check that wants zero. A signed
report and a signed query still read normally. A name that was read once, then
overwritten with something else, closes again.
