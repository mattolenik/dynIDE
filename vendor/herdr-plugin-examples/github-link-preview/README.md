# GitHub Link Preview

Bash Herdr plugin that routes clicked GitHub issue and pull request links into a
right-side pane powered by the GitHub CLI.

## Setup

Install and authenticate GitHub CLI:

```sh
gh auth login
```

Install locally while developing:

```sh
herdr plugin link .
```

Or install from the examples repo once published:

```sh
herdr plugin install ogulcancelik/herdr-plugin-examples/github-link-preview
```

## Behavior

Clicking a matching URL opens a right split and runs one of:

```sh
gh issue view 123 --repo owner/repo --comments
gh pr view 123 --repo owner/repo --comments
```

Matched URLs:

```text
https://github.com/owner/repo/issues/123
https://github.com/owner/repo/pull/123
```
