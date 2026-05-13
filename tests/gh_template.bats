#!/usr/bin/env bats

# Integration tests for scripts/gh_template.sh
#
# Requires bats-core: https://github.com/bats-core/bats-core
# Run: bats tests/gh_template.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"

setup() {
	export HOME="$BATS_TEST_TMPDIR"

	gum() {
		case "$1" in
		log) shift; shift; shift; echo "$@" ;;
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
		declare -f _gh_template_parse_config \
			_gh_template_case_variants _gh_template_prompt_variables \
			_gh_template_build_replacements _gh_template_substitute_content \
			_gh_template_substitute_paths _gh_template_apply \
			_gh_template_apply_cmd _gh_template_clone_source \
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

@test "_gh_template_apply: end-to-end on a fixture" {
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

	local commits
	commits=$(git -C "$repo" rev-list --count HEAD)
	[[ "$commits" -eq 2 ]]
	local msg
	msg=$(git -C "$repo" log -1 --pretty=%s)
	[[ "$msg" == *"apply template"* ]]
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
	mkdir -p "$src"
	echo "hello" >"$src/file.txt"

	local dst="$BATS_TEST_TMPDIR/dst"
	_gh_template_clone_source "$src" "$dst"

	[[ -f "$dst/file.txt" ]]
	[[ ! -d "$dst/.git" ]]
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

	# Should have an extra commit on top of the source's history
	local commits
	commits=$(git -C "./dst" rev-list --count HEAD)
	[[ "$commits" -eq 2 ]]
	local msg
	msg=$(git -C "./dst" log -1 --pretty=%s)
	[[ "$msg" == *"apply template from"* ]]
}

@test "_gh_template_apply_cmd: --source refuses non-empty existing target without --force" {
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
