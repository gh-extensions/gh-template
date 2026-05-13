#!/usr/bin/env bats

# Integration tests for scripts/gh_template.sh
#
# Requires bats-core: https://github.com/bats-core/bats-core
# Run: bats tests/gh_template.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"

setup() {
	export HOME="$BATS_TEST_TMPDIR"
	export _GH_TEMPLATE_SCRIPT="$REPO_ROOT/scripts/gh_template.sh"
	export _GH_TEMPLATE_PERL_SCRIPT="$REPO_ROOT/scripts/gh_template.pl"

	gum() {
		case "$1" in
		log) shift; shift; shift; echo "$@" ;;
		spin)
			# Skip everything up to and including --, then run the rest.
			while [[ $# -gt 0 && "$1" != "--" ]]; do shift; done
			shift || true
			"$@"
			;;
		input)
			# Default mock: echo the placeholder so tests can drive prompts via overrides.
			while [[ $# -gt 0 ]]; do
				if [[ "$1" == "--placeholder" ]]; then
					shift
					echo "$1"
					return 0
				fi
				shift
			done
			;;
		esac
	}
	export -f gum

	gh() { echo ""; }
	export -f gh

	# shellcheck disable=SC2155
	eval "$(
		# shellcheck source=../scripts/gh_template.sh
		source "$REPO_ROOT/scripts/gh_template.sh"
		declare -f _gh_template_parse_config _gh_template_parse_ignore \
			_gh_template_path_ignored \
			_gh_template_case_variants _gh_template_prompt_variables \
			_gh_template_build_replacements _gh_template_substitute_content \
			_gh_template_substitute_paths _gh_template_apply \
			_gh_template_run_substitution \
			_gh_template_apply_cmd _gh_template_clone_source \
			_gh_template_clone_overlay _gh_template_spin \
			_show_apply_help _is_binary_file
	)"
}

_make_config() {
	local path="$1"
	mkdir -p "$(dirname "$path")"
	cat >"$path" <<'EOF'
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
EOF
}

_init_repo() {
	local dir="$1"
	mkdir -p "$dir"
	git -C "$dir" init -q -b main
	git -C "$dir" config user.email "test@test.com"
	git -C "$dir" config user.name "Test"
	git -C "$dir" config commit.gpgsign false
}

# ---------------------------------------------------------------------------
# _gh_template_parse_config
# ---------------------------------------------------------------------------

@test "_gh_template_parse_config: emits one TSV row per variable" {
	local cfg="$BATS_TEST_TMPDIR/template.yml"
	_make_config "$cfg"

	run _gh_template_parse_config "$cfg"

	[[ "$status" -eq 0 ]]
	local lines
	lines=$(printf '%s\n' "$output" | grep -c '^template')
	[[ "$lines" -eq 3 ]]
	[[ "$output" == *"template-org"*"camel,snake,kebab,pascal"*"path,content"* ]]
	[[ "$output" == *"template-api"* ]]
}

@test "_gh_template_parse_config: handles missing case/scope as empty" {
	local cfg="$BATS_TEST_TMPDIR/template.yml"
	mkdir -p "$(dirname "$cfg")"
	cat >"$cfg" <<'EOF'
variables:
  - text: "Name?"
    name: foo
EOF

	run _gh_template_parse_config "$cfg"
	[[ "$status" -eq 0 ]]
	[[ "$output" == *"foo"* ]]
}

# ---------------------------------------------------------------------------
# _gh_template_build_replacements
# ---------------------------------------------------------------------------

@test "_gh_template_build_replacements: orders longer froms before shorter overlapping ones" {
	local cfg="$BATS_TEST_TMPDIR/template.yml"
	_make_config "$cfg"

	local values=$'template-org\tmy org
template-api\tmy api
template\tmy svc'

	run _gh_template_build_replacements "$cfg" "$values"
	[[ "$status" -eq 0 ]]

	# 'template-api' (length 12) and 'TemplateApi' (length 11) must precede
	# bare 'template' (length 8) so that overlapping replacements do not
	# corrupt the longer placeholders.
	local idx_long idx_short
	idx_long=$(printf '%s\n' "$output" | grep -nE '^template-api	' | head -1 | cut -d: -f1)
	idx_short=$(printf '%s\n' "$output" | grep -nE '^template	' | head -1 | cut -d: -f1)
	[[ -n "$idx_long" ]]
	[[ -n "$idx_short" ]]
	[[ "$idx_long" -lt "$idx_short" ]]
}

@test "_gh_template_build_replacements: emits scope per row" {
	local cfg="$BATS_TEST_TMPDIR/template.yml"
	_make_config "$cfg"
	local values=$'template-org\torg
template-api\tapi
template\tsvc'

	run _gh_template_build_replacements "$cfg" "$values"
	[[ "$output" == *$'\tpath,content' ]]
}

# ---------------------------------------------------------------------------
# _gh_template_prompt_variables
# ---------------------------------------------------------------------------

@test "_gh_template_prompt_variables: calls gum input once per variable when no override is given" {
	local cfg="$BATS_TEST_TMPDIR/template.yml"
	_make_config "$cfg"
	declare -gA _gh_template_var_overrides=()

	# Mock gum so it errors if stdin is not a TTY — this guards against
	# the regression where gum inherited a process substitution as stdin
	# and consumed the whole config as its value.
	gum() {
		case "$1" in
		log) shift; shift; shift; echo "$@" ;;
		input)
			if [[ ! -t 0 ]] && [[ -s /dev/stdin ]] && read -t 0 -N 0 <&0 2>/dev/null; then
				echo "STDIN_LEAKED" >&2
				return 1
			fi
			local placeholder=""
			while [[ $# -gt 0 ]]; do
				if [[ "$1" == "--placeholder" ]]; then
					shift
					placeholder="$1"
				fi
				shift
			done
			echo "input-for-${placeholder}"
			;;
		esac
	}
	export -f gum

	run _gh_template_prompt_variables "$cfg"
	[[ "$status" -eq 0 ]]
	[[ "$output" == *"template-org"$'\t'"input-for-template-org"* ]]
	[[ "$output" == *"template-api"$'\t'"input-for-template-api"* ]]
	[[ "$output" == *"template"$'\t'"input-for-template"* ]]
}

@test "_gh_template_prompt_variables: honors --var overrides" {
	local cfg="$BATS_TEST_TMPDIR/template.yml"
	_make_config "$cfg"
	declare -gA _gh_template_var_overrides=(
		[template-org]="acme"
		[template-api]="billing api"
		[template]="billing"
	)

	run _gh_template_prompt_variables "$cfg"
	[[ "$status" -eq 0 ]]
	[[ "$output" == *"template-org	acme"* ]]
	[[ "$output" == *"template-api	billing api"* ]]
	[[ "$output" == *"template	billing"* ]]
}

@test "_gh_template_prompt_variables: errors on empty value" {
	local cfg="$BATS_TEST_TMPDIR/template.yml"
	mkdir -p "$(dirname "$cfg")"
	cat >"$cfg" <<'EOF'
variables:
  - text: "Name?"
    name: foo
    case: [snake_case]
    scope: [content]
EOF
	gum() {
		case "$1" in
		log) shift; shift; shift; echo "$@" ;;
		input) echo "" ;;
		esac
	}
	export -f gum

	run _gh_template_prompt_variables "$cfg"
	[[ "$status" -ne 0 ]]
	[[ "$output" == *"empty value"* ]]
}

# ---------------------------------------------------------------------------
# _gh_template_apply
# ---------------------------------------------------------------------------

@test "_gh_template_apply: end-to-end on a fixture leaves changes uncommitted" {
	local repo="$BATS_TEST_TMPDIR/repo"
	_init_repo "$repo"
	_make_config "$repo/.github/template.yml"

	mkdir -p "$repo/src/template-api"
	cat >"$repo/src/template-api/template_api.go" <<'EOF'
package templateApi

// TemplateApi is the type for template-api in the template service.
type TemplateApi struct{}
EOF

	git -C "$repo" add -A
	git -C "$repo" commit -q -m "initial"

	declare -gA _gh_template_var_overrides=(
		[template-org]="acme"
		[template-api]="billing api"
		[template]="billing"
	)

	_gh_template_apply "$repo"

	[[ ! -f "$repo/.github/template.yml" ]]
	[[ ! -d "$repo/src/template-api" ]]
	[[ -d "$repo/src/billing-api" ]]
	[[ -f "$repo/src/billing-api/billing_api.go" ]]
	run cat "$repo/src/billing-api/billing_api.go"
	[[ "$output" == *"package billingApi"* ]]
	[[ "$output" == *"BillingApi"* ]]
	[[ "$output" == *"billing-api"* ]]
	[[ "$output" == *"billing service"* ]]
	[[ "$output" != *"template-api"* ]]
	[[ "$output" != *"TemplateApi"* ]]

	# No commit was created — just the original initial commit.
	local commits
	commits=$(git -C "$repo" rev-list --count HEAD)
	[[ "$commits" -eq 1 ]]
	# Working tree carries the template changes.
	[[ -n "$(git -C "$repo" status --porcelain)" ]]
}

@test "_gh_template_apply: honors top-level ignore globs" {
	local repo="$BATS_TEST_TMPDIR/repo"
	_init_repo "$repo"
	mkdir -p "$repo/.github"
	cat >"$repo/.github/template.yml" <<'EOF'
variables:
  - text: "Name?"
    name: template-api
    case: [kebab]
    scope: [path, content]
ignore:
  - "*.tmpl"
EOF
	echo "template-api" >"$repo/keep.tmpl"
	echo "template-api" >"$repo/replace.txt"
	git -C "$repo" add -A
	git -C "$repo" commit -q -m "initial"

	declare -gA _gh_template_var_overrides=(
		[template-api]="billing-api"
	)

	_gh_template_apply "$repo"

	run cat "$repo/replace.txt"
	[[ "$output" == "billing-api" ]]
	run cat "$repo/keep.tmpl"
	[[ "$output" == "template-api" ]]
}

@test "_gh_template_apply: no-op when config missing" {
	local repo="$BATS_TEST_TMPDIR/repo"
	_init_repo "$repo"

	run _gh_template_apply "$repo"
	[[ "$status" -eq 0 ]]
	[[ "$output" == *"nothing to apply"* ]]
}

@test "_gh_template_apply: dry-run does not modify files or commit" {
	local repo="$BATS_TEST_TMPDIR/repo"
	_init_repo "$repo"
	_make_config "$repo/.github/template.yml"
	mkdir -p "$repo/src"
	echo "template-api" >"$repo/src/code.txt"
	git -C "$repo" add -A
	git -C "$repo" commit -q -m "initial"

	declare -gA _gh_template_var_overrides=(
		[template-org]="acme"
		[template-api]="billing api"
		[template]="billing"
	)

	_gh_template_apply "$repo" "$repo/.github/template.yml" "1"

	[[ -f "$repo/.github/template.yml" ]]
	run cat "$repo/src/code.txt"
	[[ "$output" == "template-api" ]]
	local commits
	commits=$(git -C "$repo" rev-list --count HEAD)
	[[ "$commits" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# Help output
# ---------------------------------------------------------------------------

@test "_show_apply_help: mentions apply usage" {
	run _show_apply_help
	[[ "$output" == *"gh template apply"* ]]
	[[ "$output" == *"--dry-run"* ]]
	[[ "$output" == *"--var"* ]]
	[[ "$output" == *"--source"* ]]
}

@test "_gh_template_apply_cmd: --help prints usage" {
	run _gh_template_apply_cmd --help
	[[ "$status" -eq 0 ]]
	[[ "$output" == *"gh template apply"* ]]
}

@test "_gh_template_apply_cmd: rejects unknown flag" {
	cd "$BATS_TEST_TMPDIR"
	run _gh_template_apply_cmd --bogus
	[[ "$status" -ne 0 ]]
	[[ "$output" == *"unknown flag"* ]]
}

@test "_gh_template_apply_cmd: rejects malformed --var" {
	cd "$BATS_TEST_TMPDIR"
	run _gh_template_apply_cmd --var "noequalsign"
	[[ "$status" -ne 0 ]]
	[[ "$output" == *"name=value"* ]]
}

@test "_gh_template_apply_cmd: rejects unknown positional after DIR" {
	cd "$BATS_TEST_TMPDIR"
	run _gh_template_apply_cmd ./a ./b
	[[ "$status" -ne 0 ]]
	[[ "$output" == *"unexpected"* ]]
}

# ---------------------------------------------------------------------------
# _gh_template_parse_ignore / _gh_template_path_ignored
# ---------------------------------------------------------------------------

@test "_gh_template_parse_ignore: emits each pattern on its own line" {
	local cfg="$BATS_TEST_TMPDIR/template.yml"
	mkdir -p "$(dirname "$cfg")"
	cat >"$cfg" <<'EOF'
variables: []
ignore:
  - "*.tmpl"
  - "vendor/*"
EOF
	run _gh_template_parse_ignore "$cfg"
	[[ "$status" -eq 0 ]]
	[[ "$output" == *"*.tmpl"* ]]
	[[ "$output" == *"vendor/*"* ]]
}

@test "_gh_template_parse_ignore: empty when no ignore key" {
	local cfg="$BATS_TEST_TMPDIR/template.yml"
	mkdir -p "$(dirname "$cfg")"
	cat >"$cfg" <<'EOF'
variables: []
EOF
	run _gh_template_parse_ignore "$cfg"
	[[ "$status" -eq 0 ]]
	[[ -z "$output" ]]
}

@test "_gh_template_path_ignored: basename pattern matches at any depth" {
	run _gh_template_path_ignored "deep/nested/file.tmpl" "*.tmpl"
	[[ "$status" -eq 0 ]]
}

@test "_gh_template_path_ignored: basename pattern does not match different extension" {
	run _gh_template_path_ignored "deep/nested/file.go" "*.tmpl"
	[[ "$status" -eq 1 ]]
}

@test "_gh_template_path_ignored: path pattern matches relative path" {
	run _gh_template_path_ignored "vendor/lib/file.go" "vendor/*"
	[[ "$status" -eq 0 ]]
}

@test "_gh_template_path_ignored: path pattern does not match outside its prefix" {
	run _gh_template_path_ignored "src/lib/file.go" "vendor/*"
	[[ "$status" -eq 1 ]]
}

@test "_gh_template_path_ignored: empty patterns never match" {
	run _gh_template_path_ignored "anything" ""
	[[ "$status" -eq 1 ]]
}

@test "_gh_template_substitute_content: skips files matching ignore globs" {
	local root="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$root"
	echo "template-api" >"$root/code.txt"
	echo "template-api" >"$root/skip.tmpl"
	local pairs=$'template-api\tbilling-api\tcontent'

	_gh_template_substitute_content "$root" "$pairs" "" "*.tmpl"

	run cat "$root/code.txt"
	[[ "$output" == "billing-api" ]]
	run cat "$root/skip.tmpl"
	[[ "$output" == "template-api" ]]
}

@test "_gh_template_substitute_paths: skips paths matching ignore globs" {
	local root="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$root"
	touch "$root/template-api.go"
	touch "$root/template-api.tmpl"
	local pairs=$'template-api\tbilling-api\tpath'

	_gh_template_substitute_paths "$root" "$pairs" "" "*.tmpl"

	[[ -f "$root/billing-api.go" ]]
	[[ -f "$root/template-api.tmpl" ]]
}

# ---------------------------------------------------------------------------
# _gh_template_clone_source
# ---------------------------------------------------------------------------

@test "_gh_template_clone_source: clones a local git repo" {
	local src="$BATS_TEST_TMPDIR/src"
	_init_repo "$src"
	echo "hello" >"$src/file.txt"
	git -C "$src" add -A
	git -C "$src" commit -q -m "initial"

	local dst="$BATS_TEST_TMPDIR/dst"
	_gh_template_clone_source "$src" "$dst"

	[[ -d "$dst/.git" ]]
	[[ -f "$dst/file.txt" ]]
}

@test "_gh_template_clone_source: copies a non-git local directory" {
	local src="$BATS_TEST_TMPDIR/plain"
	mkdir -p "$src/nested"
	echo "hello" >"$src/file.txt"
	echo "deep" >"$src/nested/inner.txt"

	local dst="$BATS_TEST_TMPDIR/dst"
	_gh_template_clone_source "$src" "$dst"

	# Contents land directly in $dst, not in $dst/plain
	[[ -f "$dst/file.txt" ]]
	[[ -f "$dst/nested/inner.txt" ]]
	[[ ! -d "$dst/plain" ]]
	[[ ! -d "$dst/.git" ]]
}

@test "_gh_template_clone_source: copies a non-git source into a pre-existing empty dir" {
	local src="$BATS_TEST_TMPDIR/plain"
	mkdir -p "$src"
	echo "hello" >"$src/file.txt"

	local dst="$BATS_TEST_TMPDIR/dst"
	mkdir -p "$dst"

	_gh_template_clone_source "$src" "$dst"

	[[ -f "$dst/file.txt" ]]
	[[ ! -d "$dst/plain" ]]
}

@test "_gh_template_clone_source: errors on nonexistent local path" {
	run _gh_template_clone_source "./does-not-exist" "$BATS_TEST_TMPDIR/dst"
	[[ "$status" -ne 0 ]]
	[[ "$output" == *"not found"* ]]
}

@test "_gh_template_clone_source: errors on malformed source" {
	run _gh_template_clone_source "plain-string" "$BATS_TEST_TMPDIR/dst"
	[[ "$status" -ne 0 ]]
	[[ "$output" == *"invalid"* ]]
}

# ---------------------------------------------------------------------------
# _gh_template_apply_cmd with --source
# ---------------------------------------------------------------------------

@test "_gh_template_apply_cmd: --source local-repo end-to-end" {
	local src="$BATS_TEST_TMPDIR/src"
	_init_repo "$src"
	_make_config "$src/.github/template.yml"
	mkdir -p "$src/src/template-api"
	echo "template-api TemplateApi" >"$src/src/template-api/code.txt"
	git -C "$src" add -A
	git -C "$src" commit -q -m "initial"

	cd "$BATS_TEST_TMPDIR"
	_gh_template_apply_cmd --source "$src" ./dst \
		--var template-org=acme \
		--var template-api='billing api' \
		--var template=billing

	[[ -d "./dst" ]]
	[[ ! -f "./dst/.github/template.yml" ]]
	[[ -d "./dst/src/billing-api" ]]
	[[ -f "./dst/src/billing-api/code.txt" ]]
	run cat "./dst/src/billing-api/code.txt"
	[[ "$output" == "billing-api BillingApi" ]]

	# Source's history is preserved, changes left uncommitted for the user.
	local commits
	commits=$(git -C "./dst" rev-list --count HEAD)
	[[ "$commits" -eq 1 ]]
	[[ -n "$(git -C "./dst" status --porcelain)" ]]
}

@test "_gh_template_apply_cmd: --source refuses non-empty target without --force" {
	local src="$BATS_TEST_TMPDIR/src"
	_init_repo "$src"
	_make_config "$src/.github/template.yml"
	git -C "$src" add -A
	git -C "$src" commit -q -m "initial"

	cd "$BATS_TEST_TMPDIR"
	mkdir -p ./dst
	touch ./dst/existing

	run _gh_template_apply_cmd --source "$src" ./dst
	[[ "$status" -ne 0 ]]
	[[ "$output" == *"not empty"* ]]
}

@test "_gh_template_apply_cmd: --source --force overlays onto non-empty target, preserving .git" {
	local src="$BATS_TEST_TMPDIR/src"
	_init_repo "$src"
	_make_config "$src/.github/template.yml"
	echo "template-api" >"$src/code.txt"
	git -C "$src" add -A
	git -C "$src" commit -q -m "src initial"

	# Target: a fresh repo with its own .git and an existing file
	local dst="$BATS_TEST_TMPDIR/dst"
	_init_repo "$dst"
	echo "preserved" >"$dst/keep.txt"
	git -C "$dst" add -A
	git -C "$dst" commit -q -m "dst initial"
	local dst_initial
	dst_initial=$(git -C "$dst" rev-parse HEAD)

	cd "$BATS_TEST_TMPDIR"
	_gh_template_apply_cmd --source "$src" "$dst" --force \
		--var template-org=acme \
		--var template-api='billing api' \
		--var template=billing

	# Source's content landed inside dst
	[[ -f "$dst/code.txt" ]]
	run cat "$dst/code.txt"
	[[ "$output" == "billing-api" ]]

	# dst's pre-existing file survived
	[[ -f "$dst/keep.txt" ]]

	# dst's history is untouched (still just the initial commit)
	run git -C "$dst" log --pretty=%s
	[[ "$output" == "dst initial" ]]
	[[ "$(git -C "$dst" rev-parse HEAD)" == "$dst_initial" ]]

	# But the template changes are staged in the working tree
	[[ -n "$(git -C "$dst" status --porcelain)" ]]
}

@test "_gh_template_apply_cmd: --source with no DIR defaults to CWD" {
	local src="$BATS_TEST_TMPDIR/src"
	_init_repo "$src"
	_make_config "$src/.github/template.yml"
	echo "template-api" >"$src/code.txt"
	git -C "$src" add -A
	git -C "$src" commit -q -m "initial"

	mkdir -p "$BATS_TEST_TMPDIR/work"
	cd "$BATS_TEST_TMPDIR/work"

	_gh_template_apply_cmd --source "$src" \
		--var template-org=acme \
		--var template-api='billing api' \
		--var template=billing

	# Contents in CWD, no subdirectory
	[[ -f "./code.txt" ]]
	[[ ! -d "./src" ]]
	[[ ! -f "./.github/template.yml" ]]
	run cat ./code.txt
	[[ "$output" == "billing-api" ]]
}
