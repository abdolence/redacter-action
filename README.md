# Redacter action

GitHub Action that runs [redacter](https://github.com/abdolence/redacter-rs) in a workflow. It detects secrets and
personal data (PII) in the files of a repository and fails the build when it finds any, redacts files before they are
published or uploaded as artefacts, and reports both as SARIF, the format GitHub code scanning reads, so findings appear
on the Security tab and on pull requests.

## Status

No release exists yet, and the action is not available in the Marketplace. The examples below use `@v1`, the tag of
the first release.

## Usage

A single action covers both operations, selected with the `command` input.

Scan gate on pull requests, with the findings uploaded to code scanning:

```yaml
name: Scan for secrets
on: pull_request

jobs:
  scan:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      security-events: write
    steps:
      - uses: actions/checkout@v7
      - id: redacter
        uses: abdolence/redacter-action@v1
        with:
          command: scan
          categories: secrets
      - uses: github/codeql-action/upload-sarif@v4
        if: always() && steps.redacter.outputs.sarif-file != ''
        with:
          sarif_file: ${{ steps.redacter.outputs.sarif-file }}
          category: redacter-scan
```

- `categories: secrets` limits the scan to credentials. Source code holds many strings that match the personal data
  rules, such as IPv6 addresses in Rust paths and Unix timestamps in the shape of a Swedish personal number;
- the step fails when redacter finds something, and the upload still runs: the action sets `sarif-file` before it
  fails;
- the scan reads the `.git` directory of the checkout too, and the reflog there holds the email address of the
  runner, a finding whenever the scan looks for contact data, as it does by default. A `.redacterignore` file at the
  root of the repository with the line `.git/` leaves the directory out. The same file keeps the mock keys of test
  fixtures out of the scan, see [Ignoring files and findings](https://github.com/abdolence/redacter-rs#ignoring-files-and-findings).

Redaction of files before they are uploaded:

```yaml
jobs:
  redact:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: abdolence/redacter-action@v1
        with:
          command: cp
          path: logs/
          destination: redacted-logs/
      - uses: actions/upload-artifact@v7
        with:
          name: redacted-logs
          path: redacted-logs/
```

A file that no redacter reads is left out of the copy, and so is a file that fails.

## Inputs

| Input | Default | Description |
|---|---|---|
| `command` | Required | `scan` reports the secrets and personal data it finds, `cp` copies files with them redacted |
| `path` | `.` | File or directory to scan or copy, relative to the workspace |
| `destination` | | Where `cp` writes the redacted copy, ending with `/` for a directory. `cp` only |
| `redacters` | `local-rules,local-credential-ml` | Redacters to run, separated by commas or new lines, see [What runs where](#what-runs-where) |
| `categories` | Every category | Data categories to look for, such as `secrets`, or only exclusions such as `!other`, see [Limiting to data categories](https://github.com/abdolence/redacter-rs#limiting-to-data-categories) |
| `fail-on` | `findings` | What makes `scan` fail: `findings`, `unconfirmed` or `never`. `scan` only |
| `addons` | `auto` | Addons to install and cache: `auto`, `none`, or a list such as `ocr,pdf` |
| `version` | `0.22.0` | The redacter release to install, 0.22.0 or later |
| `args` | | Further redacter arguments, one per line, such as `--local-rules=secrets,url` |

Addons are the files redacter needs and does not bundle: the OCR models (`ocr`), the Pdfium library that renders PDF
pages (`pdf`), and the models of `local-ner`, `local-gliner` and `local-credential-ml`. `auto` installs `ocr`, `pdf`
and the models of the redacters in `redacters`. With `none` the action installs nothing, and redacter looks for addons
in its default directory or in `REDACTER_ADDONS_DIR`.

The default `version` is the release the action was tested with, so a workflow that pins a release of the action
installs the same redacter on every run.

The action passes `--unsupported-as-text`, so `.env` files, keys and source code are read as text, and writes the
SARIF report with `--report-file` and `--report-format`. `args` cannot set these options again, as redacter rejects a
repeated option. `args` does not accept `--show-values` either: it writes the values found to the log of the run, which
everyone with read access to the repository can see.

## Outputs

| Output | Description |
|---|---|
| `sarif-file` | Path of the SARIF report in the temporary directory of the runner, for `github/codeql-action/upload-sarif`. Set when the step fails too |
| `findings` | Number of findings in the SARIF report: what `scan` found, or what `cp` redacted. A SARIF report keeps at most 5000 results |
| `exit-code` | Exit code of redacter: `0`, `2` when `scan` reported findings, or `1` on an error |
| `cache-hit` | `true` when the addons were restored from the cache |

The step fails when the exit code is not `0`. See [Exit codes](https://github.com/abdolence/redacter-rs#exit-codes)
for what each one means for `scan`. `cp` exits with `0` unless an error stops the copy.

## What runs where

- The action downloads the redacter release archive for the runner from
  [the releases of redacter-rs](https://github.com/abdolence/redacter-rs/releases), and checks it against the SHA-256
  digest GitHub records for the file before it extracts it. On github.com it reads the release with the token of the
  workflow, since the API allows anonymous requests only 60 an hour for each IP address;
- `redacter addons install` downloads the addons from the same releases and checks every file against a digest pinned
  in redacter. `actions/cache` keeps them under a key of the runner, the redacter version and the addon list, and later
  runs restore them instead. The cache is saved before redacter runs, so a scan that fails on findings still fills it;
- the local redacters run on the runner, and no data leaves it. The default, `local-rules` and `local-credential-ml`,
  needs no credentials and downloads a model of about 130 MB on the first run. `local-gliner` downloads a model of
  about 1.17 GB;
- the cloud redacters (GCP DLP, AWS Comprehend, AWS Bedrock and Guardrails, Presidio, Vertex AI, Gemini, OpenAI) send
  the content of the files to their provider. They take credentials as the command line tool does, for example from
  `google-github-actions/auth` or `aws-actions/configure-aws-credentials`, and their options through `args`;
- the log and the SARIF report show values masked, such as `A******************E` for an AWS access key. The report
  stays on the runner until a step such as `github/codeql-action/upload-sarif` uploads it.

The action runs on Linux X64 and ARM64, macOS X64 and ARM64, and Windows X64 runners, such as `ubuntu-latest`,
`ubuntu-24.04-arm`, `macos-latest`, `macos-15-intel` and `windows-latest`, and fails on other runners. It reads the
release and the SARIF report with `jq`, which GitHub-hosted runners have.

## More about redacter

- [redacter-rs](https://github.com/abdolence/redacter-rs): the command line tool;
- [Scan command](https://github.com/abdolence/redacter-rs#scan-command): reports, scores and exit codes;
- [DLP comparison](https://github.com/abdolence/redacter-rs/blob/master/docs/dlp-comparison.md): measured quality and
  speed of every redacter.

## Licence

Apache License 2.0, see [LICENSE](LICENSE).
