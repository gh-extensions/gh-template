# gh-template

> Scaffold a new GitHub repository from a template and apply variable substitutions across paths and contents — without leaving the terminal.

[![CI](https://github.com/gh-extensions/gh-template/actions/workflows/ci.yml/badge.svg)](https://github.com/gh-extensions/gh-template/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/gh-extensions/gh-template)](https://github.com/gh-extensions/gh-template/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

`gh template` post-processes a directory based on a `.github/template.yml`
config that lives in the template repo. It prompts for each declared variable,
generates every requested case variant via
[`ccase`](https://github.com/stringcase/ccase), and performs case-aware
find-and-replace across file names and contents. The config file is then
removed and the working tree is left for you to review and commit.

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
gh template apply [DIR] [--config <path>] [--var name=value]... [--dry-run] [--force]
gh template apply --source <owner/repo | path> [DIR] [--var name=value]... [--dry-run]
```

```bash
gh template --help               # show help
gh template --version            # print version
gh template apply --help         # apply subcommand help
```

### Apply in place

Runs the substitution against `DIR` (default: the current working directory).
Useful when you've already cloned the template repo yourself and want to
bootstrap it in place, or to preview the planned changes with `--dry-run`.

```bash
gh template apply                   # interactive prompts on CWD
gh template apply ./my-svc          # apply on ./my-svc
gh template apply --dry-run         # show planned changes only
gh template apply --var template-org=acme --var template-api='billing api' --var template=billing
```

`apply` refuses to run on a dirty working tree unless `--force` is given, and
is a no-op (exit 0) when `.github/template.yml` is already gone.

### Apply from a source

With `--source`, `gh template` populates `DIR` with the contents of the source
— either a GitHub repo (`owner/repo`) or a local path — and then applies the
substitution there. The source's files land directly inside `DIR`; no extra
subdirectory is created. `DIR` defaults to the current working directory.

```bash
# Apply into an empty target directory
gh template apply --source acme/sample-template ./my-svc

# Or from inside an empty directory
mkdir my-svc && cd my-svc && gh template apply --source acme/sample-template

# Apply from a local template (handy for offline iteration)
gh template apply --source ./local/template ./my-svc

# Non-interactive
gh template apply --source acme/sample-template ./my-svc \
  --var template-org=acme --var template-api='billing api' --var template=billing
```

By default `DIR` must be empty. Use `--force` to overlay the source onto a
non-empty `DIR` — the source's `.git` is dropped and its files are laid down
on top of whatever already exists, preserving `DIR`'s existing `.git` and any
files not present in the source. This is the natural fit for bootstrapping a
freshly-created remote repo:

```bash
gh repo create acme/my-svc --clone --private
cd my-svc
gh template apply --source acme/sample-template --force
git diff                                  # review
git add -A && git commit -m "bootstrap from template"
git push
```

`gh template apply` itself never commits — the working tree is left dirty so
you can review (`git status`, `git diff`) and commit however you prefer.

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

# Optional. Glob patterns of files/dirs to leave untouched.
ignore:
  - "*.tmpl"
  - "vendor/*"
```

Each variable accepts:

| Field   | Type     | Description                                                                                                                                                |
| ------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `name`  | string   | The placeholder string as it appears in template files. Used as the source for every case variant.                                                         |
| `text`  | string   | Prompt text shown to the user via `gum input`.                                                                                                             |
| `case`  | string[] | Case variants to generate. Any [ccase](https://github.com/stringcase/ccase) target token is accepted — e.g. `camel`, `snake`, `kebab`, `pascal`, `title`. |
| `scope` | string[] | Where substitutions apply. Supported: `path` (file/dir names), `content` (file contents).                                                                  |

The top-level `ignore` array takes glob patterns. Patterns without `/` match
the basename anywhere (e.g. `*.tmpl` matches any `.tmpl` file at any depth);
patterns with `/` match the path relative to the repo root (e.g. `vendor/*`).
Matching paths are skipped during both the content and path passes. Useful for
files that legitimately contain the placeholder strings — runtime templates,
test fixtures, vendored dependencies, etc.

For each variable, `gh template` runs every case in `case` through `ccase`
against both the `name` placeholder and the user-supplied value. Each
(placeholder-variant, value-variant) pair becomes one find-and-replace.
Example for `name: template-api`, user input `billing api`, all four cases:

| Case          | Placeholder    | Replacement   |
| ------------- | -------------- | ------------- |
| `kebab`  | `template-api` | `billing-api` |
| `snake`  | `template_api` | `billing_api` |
| `pascal` | `TemplateApi`  | `BillingApi`  |
| `camel`  | `templateApi`  | `billingApi`  |

Both placeholders and values are normalized through `ccase`. `TemplateAPI`
written in a template file will not match — use `TemplateApi` (the pascal-case
form `ccase` produces). The same goes for other acronyms.

Replacements are applied in **descending order of placeholder length**, so
longer placeholders (`template-api`) are never partially consumed by shorter
overlapping ones (`template`).

### Hierarchical (slash-bearing) values

A value may contain `/`. During the **path pass** the placeholder component is
expanded into nested directories (the intermediate parents are created), so a
single template directory can fan out into a deeper tree:

```text
proto/org/template/v1/        --var template=billing/invoice
        ↓
proto/org/billing/invoice/v1/
```

This is the right tool for hierarchical proto package paths
(`google/spanner/admin/database/v1` style), where the directory layout mirrors
the dotted package name.

**Caveat — a slash value is a path, not an identifier.** The same `/`-bearing
value is *also* pasted into file contents wherever the placeholder appears, and
`billing/invoice` is not a valid Go/Java/etc. identifier. A blind
find-and-replace cannot tell an import-path string from a package selector —
both are just text — so it cannot give them different forms.

The fix is to model the two roles as **two variables**, mirroring how code
generators actually work (the import path is the *full* hierarchy; the package
name is the *last* segment):

```yaml
variables:
  # Full hierarchy — used in directory names, import-path strings, and the
  # dotted proto package. Slash-bearing.
  - text: "Proto package path?"
    name: template-pkg-path        # e.g. billing/invoice
    scope: [path, content]
    case: [kebab]
  # Last segment only — used as the Go package alias / selector. Slash-free,
  # so it stays a valid identifier.
  - text: "Proto package name?"
    name: templatepkg              # e.g. invoice  ->  invoicev1
    scope: [content]
    case: [camel, snake, kebab, pascal]
```

Author the source so the import path uses `template-pkg-path` and the alias
uses `templatepkg` (e.g. `templatepkgv1`); they then never collide. Keep
slash values out of any single-token identifier context.

## How it works

1. If `--source` is given, the source is cloned (via `gh repo clone` for a
   GitHub repo, or `git clone` / `cp -R` for a local path) into `DIR`.
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
   and directory names. When a value contains `/`, the intermediate parent
   directories are created first so a single component can expand into a nested
   tree.
8. `.github/template.yml` is removed and the working tree is left dirty for
   the user to review with `git diff` and commit however they prefer.

## Limitations

- Only the four case variants listed above are supported. Special casings like
  `SCREAMING_SNAKE_CASE` or `Train-Case` are not generated.
- Acronym preservation (`TemplateAPI` vs `TemplateApi`) follows `ccase`'s
  conventions — author template files using `ccase`-compatible casing.
- Symlinks are not followed during content substitution; the link itself is
  renamed during the path pass but its target is left untouched.
- macOS filename normalization (NFC vs NFD) is not handled — stick to ASCII
  placeholders.
- A `/`-bearing value is treated as a literal everywhere it matches. It is
  correct for paths and import-path strings but invalid in single-token
  identifier contexts — see [Hierarchical (slash-bearing) values](#hierarchical-slash-bearing-values).

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
