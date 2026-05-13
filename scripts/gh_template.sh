#!/usr/bin/env bash

[ -z "${DEBUG:-}" ] || set -x

set -euo pipefail

# Absolute path to this script, exported so that subprocesses spawned by
# `gum spin` can re-source it and invoke functions from this file.
_GH_TEMPLATE_SCRIPT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")
export _GH_TEMPLATE_SCRIPT

# Run a function inside `gum spin` so the user sees a progress spinner
# while a long-running step (clone, substitution) executes.
#
# gum spin invokes its command in a separate process, so we spawn a
# fresh bash that re-sources this script before invoking the named
# function. _GH_TEMPLATE_SCRIPT is inherited via env.
#
# Usage: _gh_template_spin <title> <function-name> [args...]
_gh_template_spin() {
	local title="$1"
	shift
	# shellcheck disable=SC2016 # intentional: vars expand in the spawned bash
	gum spin --show-error --title "$title" -- \
		bash -c 'set -euo pipefail; source "$_GH_TEMPLATE_SCRIPT"; "$@"' bash "$@"
}

# Parse the template config into TSV rows.
#
# Each row: <name>\t<text>\t<cases_csv>\t<scopes_csv>
#
# Usage: _gh_template_parse_config <config_path>
_gh_template_parse_config() {
	local config="$1"
	yq '.variables[] | [.name, .text, ((.case // []) | join(",")), ((.scope // []) | join(","))] | @tsv' "$config"
}

# Parse the top-level ignore list from the template config.
# Emits one glob pattern per line.
#
# Usage: _gh_template_parse_ignore <config_path>
_gh_template_parse_ignore() {
	local config="$1"
	yq '(.ignore // []) | .[]' "$config"
}

# Check whether a relative path matches any ignore pattern.
#
# Patterns containing '/' are matched against the full relative path.
# Patterns without '/' are matched against the basename only, so e.g.
# "*.tmpl" matches any .tmpl file at any depth.
#
# Returns 0 if any pattern matches, 1 otherwise.
#
# Usage: _gh_template_path_ignored <rel_path> <patterns_newline_separated>
_gh_template_path_ignored() {
	local rel="$1"
	local patterns="$2"
	[[ -z "$patterns" ]] && return 1
	local base pattern
	base=$(basename "$rel")
	while IFS= read -r pattern; do
		[[ -z "$pattern" ]] && continue
		if [[ "$pattern" == */* ]]; then
			# shellcheck disable=SC2053 # intentional glob match on RHS
			[[ "$rel" == $pattern ]] && return 0
		else
			# shellcheck disable=SC2053
			[[ "$base" == $pattern ]] && return 0
		fi
	done <<<"$patterns"
	return 1
}

# Emit case variants for a string given a comma-separated case list.
#
# Each line: <case_name>\t<value>
#
# Usage: _gh_template_case_variants <input> <cases_csv>
_gh_template_case_variants() {
	local input="$1"
	local cases_csv="$2"
	local case_name value
	local cases=()
	IFS=',' read -ra cases <<<"$cases_csv"
	for case_name in "${cases[@]}"; do
		[[ -z "$case_name" ]] && continue
		if ! value=$(ccase -t "$case_name" -- "$input" 2>&1); then
			gum log --level error "ccase failed for case '$case_name': $value"
			return 1
		fi
		printf '%s\t%s\n' "$case_name" "$value"
	done
}

# Prompt the user for each variable declared in the config.
#
# Honors overrides via the global associative array
# _gh_template_var_overrides (key = variable name).
#
# Emits one line per variable: <name>\t<value>
#
# Usage: _gh_template_prompt_variables <config_path>
_gh_template_prompt_variables() {
	local config="$1"
	local name text cases scopes value row
	# Buffer the entire config first. If we ran `gum input` inside a
	# `while read … < <(parse_config)` loop, gum would inherit the process
	# substitution as its stdin, go non-interactive, and consume the
	# remaining TSV as the "value" for the first variable.
	local rows=()
	while IFS= read -r row; do
		rows+=("$row")
	done < <(_gh_template_parse_config "$config")

	for row in "${rows[@]}"; do
		[[ -z "$row" ]] && continue
		IFS=$'\t' read -r name text cases scopes <<<"$row"
		[[ -z "$name" ]] && continue
		if [[ -n "${_gh_template_var_overrides[$name]+x}" ]]; then
			value="${_gh_template_var_overrides[$name]}"
		else
			value=$(gum input --prompt "$text > " --placeholder "$name")
		fi
		if [[ -z "$value" ]]; then
			gum log --level error "empty value for variable '$name'"
			return 1
		fi
		printf '%s\t%s\n' "$name" "$value"
	done
}

# Build the ordered replacement list.
#
# Emits one line per replacement: <from>\t<to>\t<scopes_csv>
# Ordered by descending length of <from>, ties broken by config order
# then case order. The ordering ensures longer placeholders are replaced
# before shorter overlapping ones (e.g. template-api before template).
#
# Usage: _gh_template_build_replacements <config_path> <values_input>
#   values_input: newline-separated "<name>\t<value>" pairs
_gh_template_build_replacements() {
	local config_path="$1"
	local values_input="$2"

	local -A values_map=()
	local name value
	while IFS=$'\t' read -r name value; do
		[[ -z "$name" ]] && continue
		values_map["$name"]="$value"
	done <<<"$values_input"

	local idx=0
	local text cases scopes
	local raw
	raw=$(
		while IFS=$'\t' read -r name text cases scopes; do
			[[ -z "$name" ]] && continue
			value="${values_map[$name]:-}"
			[[ -z "$value" ]] && continue

			local -A placeholder_variants=()
			local -A value_variants=()
			local case_name v
			while IFS=$'\t' read -r case_name v; do
				placeholder_variants["$case_name"]="$v"
			done < <(_gh_template_case_variants "$name" "$cases")
			while IFS=$'\t' read -r case_name v; do
				value_variants["$case_name"]="$v"
			done < <(_gh_template_case_variants "$value" "$cases")

			local case_order=0
			local case_list=()
			IFS=',' read -ra case_list <<<"$cases"
			local from to len_key
			for case_name in "${case_list[@]}"; do
				[[ -z "$case_name" ]] && continue
				from="${placeholder_variants[$case_name]:-}"
				to="${value_variants[$case_name]:-}"
				[[ -z "$from" || -z "$to" || "$from" == "$to" ]] && continue
				len_key=$((999999 - ${#from}))
				printf '%06d\t%06d\t%06d\t%s\t%s\t%s\n' \
					"$len_key" "$idx" "$case_order" "$from" "$to" "$scopes"
				((case_order++))
			done
			((idx++))
		done < <(_gh_template_parse_config "$config_path")
	)

	# Deduplicate identical (from,to,scope) triples that occur across variables
	# (e.g. kebab-case of "template" inside "template-api" path replacement
	# would already be covered by the longer variant). Sort then awk-uniq on
	# the from column keeps the first (longest) occurrence.
	printf '%s\n' "$raw" \
		| sort -t$'\t' -k1,1n -k2,2n -k3,3n \
		| awk -F'\t' '!seen[$4]++' \
		| cut -f4-
}

# Test whether a file is binary (skip during content substitution).
#
# Usage: _is_binary_file <path>
# Returns 0 if binary, 1 otherwise.
_is_binary_file() {
	local f="$1"
	local enc
	enc=$(file -b --mime-encoding "$f" 2>/dev/null || echo "binary")
	[[ "$enc" == "binary" ]]
}

# Substitute file contents in the repo.
#
# Walks every regular non-symlink, non-binary file under <root> (excluding
# .git/) and applies each replacement whose scope includes "content".
# Files matching <ignore> patterns are skipped entirely.
#
# Usage: _gh_template_substitute_content <root> <pairs_input> [<dry_run>] [<ignore>]
#   pairs_input: newline-separated "<from>\t<to>\t<scopes_csv>" rows
#   dry_run: non-empty string enables dry-run mode (print only)
#   ignore: newline-separated glob patterns to skip
_gh_template_substitute_content() {
	local root="$1"
	local pairs_input="$2"
	local dry_run="${3:-}"
	local ignore="${4:-}"

	local -a froms=() tos=()
	local from to scopes
	while IFS=$'\t' read -r from to scopes; do
		[[ -z "$from" ]] && continue
		[[ ",$scopes," == *,content,* ]] || continue
		froms+=("$from")
		tos+=("$to")
	done <<<"$pairs_input"

	[[ ${#froms[@]} -eq 0 ]] && return 0

	local f i rel
	while IFS= read -r -d '' f; do
		[[ -L "$f" ]] && continue
		_is_binary_file "$f" && continue
		rel="${f#"$root"/}"
		if _gh_template_path_ignored "$rel" "$ignore"; then
			[[ -n "$dry_run" ]] && printf 'content: ignored %s\n' "$f"
			continue
		fi
		for i in "${!froms[@]}"; do
			from="${froms[$i]}"
			to="${tos[$i]}"
			if [[ -n "$dry_run" ]]; then
				if grep -qF -- "$from" "$f" 2>/dev/null; then
					printf 'content: %s : %s -> %s\n' "$f" "$from" "$to"
				fi
			else
				perl -i -pe 'BEGIN{$f=shift @ARGV;$t=shift @ARGV} s/\Q$f\E/$t/g' "$from" "$to" "$f"
			fi
		done
	done < <(find "$root" -type f -not -path "*/.git" -not -path "*/.git/*" -print0)
}

# Substitute file and directory names in the repo.
#
# Uses find -depth so deeper paths are renamed first, preventing parent
# rename from invalidating child paths. Paths matching <ignore> patterns
# are skipped.
#
# Usage: _gh_template_substitute_paths <root> <pairs_input> [<dry_run>] [<ignore>]
_gh_template_substitute_paths() {
	local root="$1"
	local pairs_input="$2"
	local dry_run="${3:-}"
	local ignore="${4:-}"

	local from to scopes
	while IFS=$'\t' read -r from to scopes; do
		[[ -z "$from" ]] && continue
		[[ ",$scopes," == *,path,* ]] || continue

		local p base dir new rel
		while IFS= read -r -d '' p; do
			rel="${p#"$root"/}"
			if _gh_template_path_ignored "$rel" "$ignore"; then
				continue
			fi
			base=$(basename "$p")
			dir=$(dirname "$p")
			new="${base//${from}/${to}}"
			if [[ "$new" != "$base" ]]; then
				if [[ -n "$dry_run" ]]; then
					printf 'path: %s -> %s/%s\n' "$p" "$dir" "$new"
				else
					mv -- "$p" "$dir/$new"
				fi
			fi
		done < <(find "$root" -depth -not -path "*/.git" -not -path "*/.git/*" -name "*${from}*" -print0)
	done <<<"$pairs_input"
}

# Internal helper that runs the slow part of the apply flow: build the
# replacement list, then perform content + path substitution. Wrapped in
# `gum spin` by _gh_template_apply so the user sees progress.
#
# Usage: _gh_template_run_substitution <repo_dir> <config_path> <values> <ignore>
_gh_template_run_substitution() {
	local repo_dir="$1"
	local config_path="$2"
	local values="$3"
	local ignore="$4"

	local replacements
	replacements=$(_gh_template_build_replacements "$config_path" "$values")
	if [[ -z "$replacements" ]]; then
		return 0
	fi

	_gh_template_substitute_content "$repo_dir" "$replacements" "" "$ignore"
	_gh_template_substitute_paths "$repo_dir" "$replacements" "" "$ignore"
}

# Apply template substitutions to a directory.
#
# Reads the config, prompts (or uses overrides from
# _gh_template_var_overrides), builds the replacement list, performs
# content then path substitution, and deletes the config file. Leaves
# the working tree dirty so the user can review and commit themselves.
#
# Usage: _gh_template_apply <repo_dir> [<config_path>] [<dry_run>]
_gh_template_apply() {
	local repo_dir="$1"
	local config_path="${2:-$repo_dir/.github/template.yml}"
	local dry_run="${3:-}"

	if [[ ! -f "$config_path" ]]; then
		gum log --level info "no template config at $config_path — nothing to apply"
		return 0
	fi

	local values
	values=$(_gh_template_prompt_variables "$config_path") || return 1

	local ignore
	ignore=$(_gh_template_parse_ignore "$config_path")

	if [[ -n "$dry_run" ]]; then
		gum log --level info "Dry run — no changes will be made"
		local replacements
		replacements=$(_gh_template_build_replacements "$config_path" "$values")
		if [[ -z "$replacements" ]]; then
			gum log --level warn "no replacements computed"
			return 0
		fi
		_gh_template_substitute_content "$repo_dir" "$replacements" "$dry_run" "$ignore"
		_gh_template_substitute_paths "$repo_dir" "$replacements" "$dry_run" "$ignore"
		printf 'config: would remove %s\n' "$config_path"
		return 0
	fi

	_gh_template_spin "Substituting template variables..." \
		_gh_template_run_substitution "$repo_dir" "$config_path" "$values" "$ignore"

	rm -f "$config_path"

	if git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
		gum log --level info "Done — review with 'git status' / 'git diff' and commit when ready"
	else
		gum log --level info "Done"
	fi
}

# Populate <dir> with the contents of a template source.
#
# Source may be either:
#   - "owner/repo"     — fetched via `gh repo clone`
#   - a local path     — cloned via `git clone` if it's a git repo,
#                        otherwise copied with `cp -R`
#
# The source's contents are placed directly inside <dir>; no extra
# subdirectory is created. <dir> must be empty (or not exist yet).
#
# Detects local paths by a leading `./`, `../`, `/`, or `~`.
#
# Usage: _gh_template_clone_source <source> <dir>
_gh_template_clone_source() {
	local source="$1"
	local dir="$2"

	case "$source" in
	./* | ../* | /* | ~*)
		local expanded="${source/#\~/$HOME}"
		if [[ ! -d "$expanded" ]]; then
			gum log --level error "source directory not found: $source"
			return 1
		fi
		if git -C "$expanded" rev-parse --git-dir >/dev/null 2>&1; then
			git clone --quiet "$expanded" "$dir"
		else
			mkdir -p "$dir"
			cp -R "$expanded"/. "$dir"/
		fi
		;;
	*/*)
		gh repo clone "$source" "$dir" -- --quiet
		;;
	*)
		gum log --level error "invalid --source '$source' (expected owner/repo or a local path)"
		return 1
		;;
	esac
}

# Overlay a source onto a non-empty target directory.
#
# Clones the source into <tmp>/clone, removes the cloned .git, then
# copies the remaining contents onto <target>. The target's existing
# .git and any files not present in the source are preserved.
#
# Caller is responsible for cleaning up <tmp>.
#
# Usage: _gh_template_clone_overlay <source> <tmp_dir> <target>
_gh_template_clone_overlay() {
	local source="$1"
	local tmp="$2"
	local target="$3"
	_gh_template_clone_source "$source" "$tmp/clone" || return 1
	rm -rf "$tmp/clone/.git"
	cp -R "$tmp/clone"/. "$target"/
}

# Print usage for the apply subcommand.
_show_apply_help() {
	cat <<'EOF'
gh template apply — apply template.yml substitutions to a directory

USAGE:
    gh template apply [DIR] [--config <path>] [--var name=value]... [--dry-run] [--force]
    gh template apply --source <owner/repo | path> [DIR] [--var name=value]... [--dry-run]

DESCRIPTION:
    Reads .github/template.yml (or --config <path>), prompts for each
    variable via gum (or accepts --var name=value pairs non-interactively),
    performs case-aware substitution across file contents and paths,
    deletes the config file, and creates a single commit.

    DIR defaults to the current working directory. When --source is given,
    the source's contents are placed directly inside DIR (no extra
    subdirectory is created); DIR must be empty (or not exist yet).

FLAGS:
    --source <repo|path> Populate DIR with the contents of the given GitHub
                         repo or local path before applying.
    --config <path>      Use a different config file (default: .github/template.yml)
    --var name=value     Provide variable values non-interactively (repeatable)
    --dry-run            Print planned changes without modifying anything
    --force              With --source: overlay the source on top of a
                         non-empty DIR (preserving DIR's existing .git).
                         Without --source: run on a dirty working tree.

EXAMPLES:
    gh template apply
    gh template apply ./my-svc
    mkdir my-svc && cd my-svc && gh template apply --source acme/sample-template
    gh template apply --source acme/sample-template ./my-svc --var template-org=acme
    gh template apply --source ./local/template ./my-svc --dry-run
EOF
}

# Apply subcommand entrypoint.
#
# Parses argv, optionally clones a source repo, then invokes
# _gh_template_apply against the target directory.
#
# Usage: _gh_template_apply_cmd [args...]
_gh_template_apply_cmd() {
	local source=""
	local target_dir=""
	local config_path=""
	local dry_run=""
	local force=""
	declare -gA _gh_template_var_overrides=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--help | -h | help)
			_show_apply_help
			return 0
			;;
		--source)
			shift
			[[ $# -eq 0 ]] && {
				gum log --level error "--source requires a value"
				return 1
			}
			source="$1"
			;;
		--config)
			shift
			[[ $# -eq 0 ]] && {
				gum log --level error "--config requires a value"
				return 1
			}
			config_path="$1"
			;;
		--var)
			shift
			[[ $# -eq 0 ]] && {
				gum log --level error "--var requires name=value"
				return 1
			}
			local pair="$1"
			if [[ "$pair" != *=* ]]; then
				gum log --level error "--var expects name=value (got '$pair')"
				return 1
			fi
			_gh_template_var_overrides["${pair%%=*}"]="${pair#*=}"
			;;
		--dry-run) dry_run="1" ;;
		--force) force="1" ;;
		-*)
			gum log --level error "unknown flag '$1'"
			return 1
			;;
		*)
			if [[ -z "$target_dir" ]]; then
				target_dir="$1"
			else
				gum log --level error "unexpected argument '$1'"
				return 1
			fi
			;;
		esac
		shift
	done

	target_dir="${target_dir:-$(pwd)}"

	if [[ -n "$source" ]]; then
		local target_has_content=""
		if [[ -d "$target_dir" && -n "$(ls -A "$target_dir" 2>/dev/null)" ]]; then
			target_has_content="1"
		fi

		if [[ -n "$target_has_content" && -z "$force" ]]; then
			gum log --level error "target '$target_dir' is not empty — pick an empty directory or pass --force"
			return 1
		fi

		if [[ -z "$target_has_content" ]]; then
			if ! _gh_template_spin "Cloning '$source' into '$target_dir'..." \
				_gh_template_clone_source "$source" "$target_dir"; then
				return 1
			fi
		else
			# Overlay mode: clone to a temp directory, drop the source's
			# .git, then copy the remaining contents on top of the target.
			# The target's existing .git (and any other files not present
			# in the source) are preserved.
			local tmp
			tmp=$(mktemp -d)
			if ! _gh_template_spin "Overlaying '$source' onto '$target_dir'..." \
				_gh_template_clone_overlay "$source" "$tmp" "$target_dir"; then
				rm -rf "$tmp"
				return 1
			fi
			rm -rf "$tmp"
		fi
	else
		if [[ ! -d "$target_dir" ]]; then
			gum log --level error "directory not found: $target_dir"
			return 1
		fi
		if [[ -z "$force" ]] && git -C "$target_dir" rev-parse --git-dir >/dev/null 2>&1; then
			if [[ -n "$(git -C "$target_dir" status --porcelain 2>/dev/null)" ]]; then
				gum log --level error "working tree is dirty — commit or use --force"
				return 1
			fi
		fi
	fi

	if [[ -z "$config_path" ]]; then
		config_path="$target_dir/.github/template.yml"
	fi

	_gh_template_apply "$target_dir" "$config_path" "$dry_run"
}

