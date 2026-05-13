#!/usr/bin/env bats

# Unit tests for substitution helpers in scripts/gh_template.sh
#
# Requires bats-core: https://github.com/bats-core/bats-core
# Run: bats tests/gh_template_substitute.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"

setup() {
	export HOME="$BATS_TEST_TMPDIR"
	export _GH_TEMPLATE_SCRIPT="$REPO_ROOT/scripts/gh_template.sh"
	export _GH_TEMPLATE_PERL_SCRIPT="$REPO_ROOT/scripts/gh_template.pl"

	gum() { if [[ "$1" == "log" ]]; then shift; shift; shift; echo "$@"; fi; }
	export -f gum

	# shellcheck disable=SC2155
	eval "$(
		# shellcheck source=../scripts/gh_template.sh
		source "$REPO_ROOT/scripts/gh_template.sh"
		declare -f _gh_template_case_variants _gh_template_path_ignored \
			_gh_template_substitute_content _gh_template_substitute_paths \
			_is_binary_file
	)"
}

# ---------------------------------------------------------------------------
# _gh_template_case_variants (integration — requires ccase)
# ---------------------------------------------------------------------------

@test "_gh_template_case_variants: emits all four variants for 'my api'" {
	run _gh_template_case_variants "my api" "snake,kebab,camel,pascal"
	[[ "$status" -eq 0 ]]
	[[ "$output" == *"snake	my_api"* ]]
	[[ "$output" == *"kebab	my-api"* ]]
	[[ "$output" == *"camel	myApi"* ]]
	[[ "$output" == *"pascal	MyApi"* ]]
}

@test "_gh_template_case_variants: handles kebab input" {
	run _gh_template_case_variants "template-api" "pascal,snake"
	[[ "$output" == *"pascal	TemplateApi"* ]]
	[[ "$output" == *"snake	template_api"* ]]
}

@test "_gh_template_case_variants: errors on unsupported case" {
	run _gh_template_case_variants "my api" "nonsense_case"
	[[ "$status" -ne 0 ]]
}

# ---------------------------------------------------------------------------
# _is_binary_file
# ---------------------------------------------------------------------------

@test "_is_binary_file: returns 1 for plain text" {
	echo "hello world" >"$BATS_TEST_TMPDIR/text.txt"
	run _is_binary_file "$BATS_TEST_TMPDIR/text.txt"
	[[ "$status" -eq 1 ]]
}

@test "_is_binary_file: returns 0 for binary content" {
	printf '\x00\x01\x02\x03\x04\x05' >"$BATS_TEST_TMPDIR/binary.bin"
	run _is_binary_file "$BATS_TEST_TMPDIR/binary.bin"
	[[ "$status" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# _gh_template_substitute_content
# ---------------------------------------------------------------------------

@test "_gh_template_substitute_content: replaces all case variants in a single file" {
	local root="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$root"
	cat >"$root/code.txt" <<'EOF'
TemplateApi templateApi template-api template_api
EOF
	local pairs=$'TemplateApi\tBillingApi\tcontent
templateApi\tbillingApi\tcontent
template-api\tbilling-api\tcontent
template_api\tbilling_api\tcontent'

	_gh_template_substitute_content "$root" "$pairs"

	run cat "$root/code.txt"
	[[ "$output" == "BillingApi billingApi billing-api billing_api" ]]
}

@test "_gh_template_substitute_content: skips files in .git/" {
	local root="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$root/.git"
	echo "template-api" >"$root/.git/config"
	local pairs=$'template-api\tbilling-api\tcontent'

	_gh_template_substitute_content "$root" "$pairs"

	run cat "$root/.git/config"
	[[ "$output" == "template-api" ]]
}

@test "_gh_template_substitute_content: skips binary files" {
	local root="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$root"
	printf 'template-api\x00\x01\x02' >"$root/bin.dat"
	local pairs=$'template-api\tbilling-api\tcontent'

	local before
	before=$(md5sum "$root/bin.dat" 2>/dev/null || md5 -q "$root/bin.dat")

	_gh_template_substitute_content "$root" "$pairs"

	local after
	after=$(md5sum "$root/bin.dat" 2>/dev/null || md5 -q "$root/bin.dat")
	[[ "$before" == "$after" ]]
}

@test "_gh_template_substitute_content: skips symlinks" {
	local root="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$root"
	echo "template-api" >"$root/real.txt"
	ln -s real.txt "$root/link.txt"
	local pairs=$'template-api\tbilling-api\tcontent'

	_gh_template_substitute_content "$root" "$pairs"

	run cat "$root/real.txt"
	[[ "$output" == "billing-api" ]]
	[[ -L "$root/link.txt" ]]
}

@test "_gh_template_substitute_content: ignores pairs without content scope" {
	local root="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$root"
	echo "template-api" >"$root/code.txt"
	local pairs=$'template-api\tbilling-api\tpath'

	_gh_template_substitute_content "$root" "$pairs"

	run cat "$root/code.txt"
	[[ "$output" == "template-api" ]]
}

@test "_gh_template_substitute_content: dry-run prints planned changes without modifying" {
	local root="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$root"
	echo "template-api" >"$root/code.txt"
	local pairs=$'template-api\tbilling-api\tcontent'

	run _gh_template_substitute_content "$root" "$pairs" "1"
	[[ "$output" == *"template-api -> billing-api"* ]]

	run cat "$root/code.txt"
	[[ "$output" == "template-api" ]]
}

@test "_gh_template_substitute_content: applies replacements in the given order" {
	local root="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$root"
	echo "template-api template" >"$root/code.txt"
	# Longer pair first ensures template-api is replaced before bare template
	local pairs=$'template-api\tbilling-api\tcontent
template\tbilling\tcontent'

	_gh_template_substitute_content "$root" "$pairs"

	run cat "$root/code.txt"
	[[ "$output" == "billing-api billing" ]]
}

# ---------------------------------------------------------------------------
# _gh_template_substitute_paths
# ---------------------------------------------------------------------------

@test "_gh_template_substitute_paths: renames nested file path" {
	local root="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$root/src/template-api"
	touch "$root/src/template-api/template_api.go"
	local pairs=$'template-api\tbilling-api\tpath
template_api\tbilling_api\tpath'

	_gh_template_substitute_paths "$root" "$pairs"

	[[ -d "$root/src/billing-api" ]]
	[[ -f "$root/src/billing-api/billing_api.go" ]]
}

@test "_gh_template_substitute_paths: no-op when 'from' absent" {
	local root="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$root/src"
	touch "$root/src/keep.go"
	local pairs=$'nonexistent\tirrelevant\tpath'

	_gh_template_substitute_paths "$root" "$pairs"

	[[ -f "$root/src/keep.go" ]]
}

@test "_gh_template_substitute_paths: skips paths under .git/" {
	local root="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$root/.git"
	touch "$root/.git/template-api.cfg"
	local pairs=$'template-api\tbilling-api\tpath'

	_gh_template_substitute_paths "$root" "$pairs"

	[[ -f "$root/.git/template-api.cfg" ]]
}

@test "_gh_template_substitute_paths: ignores pairs without path scope" {
	local root="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$root"
	touch "$root/template-api.txt"
	local pairs=$'template-api\tbilling-api\tcontent'

	_gh_template_substitute_paths "$root" "$pairs"

	[[ -f "$root/template-api.txt" ]]
}

@test "_gh_template_substitute_paths: dry-run prints planned renames without moving" {
	local root="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$root"
	touch "$root/template-api.txt"
	local pairs=$'template-api\tbilling-api\tpath'

	run _gh_template_substitute_paths "$root" "$pairs" "1"
	[[ "$output" == *"template-api.txt"* ]]
	[[ "$output" == *"billing-api.txt"* ]]
	[[ -f "$root/template-api.txt" ]]
}
