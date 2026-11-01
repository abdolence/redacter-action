# Redacter action

GitHub Action that runs [redacter](https://github.com/abdolence/redacter-rs) in a workflow. It detects secrets and
personal data (PII) in the files of a repository and fails the build when it finds any, redacts files before they are
published or uploaded as artefacts, and reports both to GitHub code scanning as SARIF, so findings appear on the
Security tab and on pull requests.

## Status

No release exists yet. The first release follows the `redacter` release that ships SARIF output, and the action is not
available in the Marketplace until then.

## Planned usage

The inputs and outputs below are planned and may change before the first release. A single action covers both
operations, selected with the `command` input.

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
          path: .
          redacters: local-rules
          fail-on: findings
      - uses: github/codeql-action/upload-sarif@v4
        if: always()
        with:
          sarif_file: ${{ steps.redacter.outputs.sarif-file }}
```

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

## What runs where

The action installs a pinned `redacter` release binary on the runner. By default it uses the local redacters
(`local-rules`, and `local-credential-ml` once it is released), which run on the runner: no data leaves it and no cloud
credentials are needed. The cloud redacters (GCP DLP, AWS Comprehend, AWS Bedrock and Guardrails, Presidio, Vertex AI,
Gemini, OpenAI) run only when they are configured with credentials. Model addons are cached with `actions/cache`.

## More about redacter

- [redacter-rs](https://github.com/abdolence/redacter-rs): the command line tool;
- [Scan command](https://github.com/abdolence/redacter-rs#scan-command): reports, scores and exit codes;
- [DLP comparison](https://github.com/abdolence/redacter-rs/blob/master/docs/dlp-comparison.md): measured quality and
  speed of every redacter.

## Licence

Apache License 2.0, see [LICENSE](LICENSE).
