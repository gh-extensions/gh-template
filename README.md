# gh-template

> Scaffold a new GitHub repository from a template and apply variable substitutions across paths and contents — without leaving the terminal.

[![CI](https://github.com/gh-extensions/gh-template/actions/workflows/ci.yml/badge.svg)](https://github.com/gh-extensions/gh-template/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/gh-extensions/gh-template)](https://github.com/gh-extensions/gh-template/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

`gh template` wraps `gh repo create --template` and post-processes the clone
based on a `.github/template.yml` config that lives in the template repo. It
prompts for each declared variable, generates every requested case variant via
[`ccase`](https://github.com/stringcase/ccase), and performs case-aware
find-and-replace across file names and contents. The config file is then
deleted and the result is committed and pushed in one go.

## Requirements

- [GitHub CLI](https://cli.github.com/) (`gh`)
- [Bash](https://www.gnu.org/software/bash/) 4.4+ (`bash`)
- [Gum](https://github.com/charmbracelet/gum) (`gum`)
- [yq](https://github.com/mikefarah/yq) (`yq` — mikefarah's Go implementation)
- [ccase](https://github.com/stringcase/ccase) (`ccase`)
- `perl`, `file`, `git`

**Nix (recommended):**

```bash
nix develop
```

**macOS (Homebrew):**

```bash
brew install gh bash gum yq
cargo install ccase
```

## Installation

```bash
gh extension install gh-extensions/gh-template --pin v0.1.0  # recommended: pin to a stable release
gh extension install gh-extensions/gh-template                # installs from main (unstable)
```

## Usage

```bash
gh template create <new-repo> --template <owner/repo> [--var name=value]...
gh template apply [--config <path>] [--var name=value]... [--dry-run] [--force]
```

```bash
gh template --help               # show help
gh template --version            # print version
gh template create --help        # create subcommand help
gh template apply --help         # apply subcommand help
```

### Create

Creates a new GitHub repository from the given template, clones it locally,
applies the substitutions declared in `.github/template.yml`, removes the
config, and commits + pushes the result.

```bash
gh template create my-new-svc --template my-org/sample-template
gh template create acme/billing-api --template my-org/sample-template --var template=billing
```

By default the new repo is created `--private`. Override with `--public` or
`--internal`.

### Apply

Runs the substitution against the current working directory. Useful when you
already have an empty repo cloned locally and want to bootstrap from a template
manually, or to dry-run the changes before committing.

```bash
gh template apply                   # interactive prompts
gh template apply --dry-run         # show planned changes only
gh template apply --var template-org=acme --var template-api='billing api' --var template=billing
```

`apply` refuses to run on a dirty working tree unless `--force` is given, and
is a no-op (exit 0) when `.github/template.yml` is already gone.

## Config schema

The template repo must contain a `.github/template.yml` file declaring the
variables to be substituted:

```yaml
variables:
  - text: "What is the organization name?"
    name: template-org
    case: [camel, snake, kebab, pascal]
    scope: [path, content]
  - text: "What is the repository name?"
    name: template-api
    scope: [path, content]
    case: [camel, snake, kebab, pascal]
  - text: "What is the service name?"
    name: template
    scope: [path, content]
    case: [camel, snake, kebab, pascal]
```

| Field   | Type     | Description                                                                                                                                                |
| ------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `name`  | string   | The placeholder string as it appears in template files. Used as the source for every case variant.                                                         |
| `text`  | string   | Prompt text shown to the user via `gum input`.                                                                                                             |
| `case`  | string[] | Case variants to generate. Any [ccase](https://github.com/stringcase/ccase) target token is accepted — e.g. `camel`, `snake`, `kebab`, `pascal`, `title`. |
| `scope` | string[] | Where substitutions apply. Supported: `path` (file/dir names), `content` (file contents).                                                                  |

For each variable, `gh template` runs every case in `case` through `ccase`
against both the `name` placeholder and the user-supplied value. Each
(placeholder-variant, value-variant) pair becomes one find-and-replace.
Example for `name: template-api`, user input `billing api`, all four cases:

| Case          | Placeholder    | Replacement   |
| ------------- | -------------- | ------------- |
| `kebab_case`  | `template-api` | `billing-api` |
| `snake_case`  | `template_api` | `billing_api` |
| `pascal_case` | `TemplateApi`  | `BillingApi`  |
| `camel_case`  | `templateApi`  | `billingApi`  |

Both placeholders and values are normalized through `ccase`. `TemplateAPI`
written in a template file will not match — use `TemplateApi` (the pascal-case
form `ccase` produces). The same goes for other acronyms.

Replacements are applied in **descending order of placeholder length**, so
longer placeholders (`template-api`) are never partially consumed by shorter
overlapping ones (`template`).

## How it works

1. `gh repo create --template --clone` creates and clones the new repo.
2. `.github/template.yml` is parsed via `yq`.
3. Each variable is prompted via `gum input` (or supplied via `--var`).
4. `ccase` generates every requested case variant of the placeholder and the
   user-supplied value.
5. Replacements are sorted by descending placeholder length.
6. **Content pass** — every regular non-symlink, non-binary file outside
   `.git/` is rewritten with `perl -i -pe` (using `\Q…\E` so the placeholder is
   treated as a literal string, not a regex).
7. **Path pass** — `find -depth` walks deepest-first so parent renames don't
   invalidate child paths; `mv` is used to apply the same substitution to file
   and directory names.
8. `.github/template.yml` is removed and the working tree committed as
   `chore: apply template from <owner>/<repo>`.
9. The commit is pushed.

## Limitations

- Only the four case variants listed above are supported. Special casings like
  `SCREAMING_SNAKE_CASE` or `Train-Case` are not generated.
- Acronym preservation (`TemplateAPI` vs `TemplateApi`) follows `ccase`'s
  conventions — author template files using `ccase`-compatible casing.
- Symlinks are not followed during content substitution; the link itself is
  renamed during the path pass but its target is left untouched.
- macOS filename normalization (NFC vs NFD) is not handled — stick to ASCII
  placeholders.

## The gh-extensions Ecosystem

| Repo                                                        | What it provides                                          |
| ----------------------------------------------------------- | --------------------------------------------------------- |
| [gh-ai](https://github.com/gh-extensions/gh-ai)             | AI-powered copilot for the GitHub CLI                     |
| [gh-fzf](https://github.com/gh-extensions/gh-fzf)           | Fuzzy finder for GitHub CLI                               |
| [gh-worktree](https://github.com/gh-extensions/gh-worktree) | Isolated git worktrees for PRs, issues, and workflow runs |
| **gh-template** ← you are here                              | Repository scaffolding from GitHub templates              |

## License

[MIT](LICENSE) — Copyright (c) 2026 gh-extensions

<!-- markdownlint-disable-file MD013 MD036 -->
