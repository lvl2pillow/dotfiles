#!/bin/bash
# Unit tests for the attribute-parsing helpers in the cleanup script.
#
# Sources the cleanup script with IS_TEST set so cleanup_main
# (the destructive git/cd/rm logic) is suppressed and only the parsing
# helpers are loaded. This keeps tests free of chezmoi and state locks.
#
# Run: bash .chezmoiscripts/tests/test_cleanup.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP="$SCRIPT_DIR/../../.chezmoiscripts/run_after_01_cleanup.sh.tmpl"

IS_TEST=1
export IS_TEST
# shellcheck source=/dev/null
. "$CLEANUP"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %s\n      expected: <%s>\n      actual:   <%s>\n' \
            "$desc" "$expected" "$actual"
    fi
}

# get_target_path / parse_file_name return 1 with no output for skippable
# entries; this asserts exactly that (empty output, regardless of status).
expect_skip() {
    local desc="$1" src="$2" out
    out="$(get_target_path "$src" 2>/dev/null)"
    if [ -z "$out" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %s (expected skip, got <%s>)\n' "$desc" "$out"
    fi
}

# --- parse_dir_name: directory prefixes -------------------------------------
assert_eq "plain dir"                "foo"        "$(parse_dir_name foo)"
assert_eq "dot_ dir"                 ".config"    "$(parse_dir_name dot_config)"
assert_eq "exact_ dir"               "foo"        "$(parse_dir_name exact_foo)"
assert_eq "private_ dir"             "foo"        "$(parse_dir_name private_foo)"
assert_eq "readonly_ dir"            "foo"        "$(parse_dir_name readonly_foo)"
assert_eq "external_ dir"            "foo"        "$(parse_dir_name external_foo)"
assert_eq "remove_ dir"              "foo"        "$(parse_dir_name remove_foo)"
assert_eq "exact_private_dot_ dir"   ".foo"       "$(parse_dir_name exact_private_dot_foo)"
assert_eq "remove_external_dot_ dir" ".foo"       "$(parse_dir_name remove_external_dot_foo)"
assert_eq "literal_ dir stops dot"   "dot_foo"    "$(parse_dir_name literal_dot_foo)"
assert_eq "literal_ dir stops exact" "exact_foo"  "$(parse_dir_name literal_exact_foo)"
assert_eq "exact_then_literal_ dir"  "foo"        "$(parse_dir_name exact_literal_foo)"

# --- parse_file_name: file prefixes -----------------------------------------
assert_eq "plain file"               "foo"        "$(parse_file_name foo)"
assert_eq "dot_ file"                ".gitconfig" "$(parse_file_name dot_gitconfig)"
assert_eq "empty_dot_ file"          ".hushlogin" "$(parse_file_name empty_dot_hushlogin)"
assert_eq "create_dot_ file"         ".foo"       "$(parse_file_name create_dot_foo)"
assert_eq "executable_dot_ file"     ".foo"       "$(parse_file_name executable_dot_foo)"
assert_eq "private_dot_ file"        ".foo"       "$(parse_file_name private_dot_foo)"
assert_eq "readonly_dot_ file"       ".foo"       "$(parse_file_name readonly_dot_foo)"
assert_eq "modify_dot_ file"         ".foo"       "$(parse_file_name modify_dot_foo)"
assert_eq "symlink_dot_ file"        ".foo"       "$(parse_file_name symlink_dot_foo)"
assert_eq "encrypted_dot_ file"      ".foo"       "$(parse_file_name encrypted_dot_foo)"
assert_eq "all create attrs + dot"   ".foo"       \
    "$(parse_file_name create_encrypted_private_readonly_empty_executable_dot_foo)"
assert_eq "all file attrs + dot"     ".foo"       \
    "$(parse_file_name encrypted_private_readonly_empty_executable_dot_foo)"
assert_eq "literal_ file stops dot"  "dot_foo"    "$(parse_file_name literal_dot_foo)"

# --- parse_file_name: suffixes ----------------------------------------------
assert_eq "tmpl suffix"              ".zshrc"     "$(parse_file_name dot_zshrc.tmpl)"
assert_eq "literal suffix"           "foo"        "$(parse_file_name foo.literal)"
assert_eq "dot_ + tmpl"              ".gitconfig" "$(parse_file_name dot_gitconfig.tmpl)"
assert_eq "tmpl then literal suffix" "foo.tmpl"   "$(parse_file_name foo.tmpl.literal)"
assert_eq "literal then tmpl suffix" "foo"        "$(parse_file_name foo.literal.tmpl)"
assert_eq "encrypted_dot_ age"       ".foo"       "$(parse_file_name encrypted_dot_foo.age)"
assert_eq "encrypted_dot_ asc"       ".foo"       "$(parse_file_name encrypted_dot_foo.asc)"
assert_eq "encrypted_dot_ tmpl+age"  ".foo"       "$(parse_file_name encrypted_dot_foo.tmpl.age)"
assert_eq "encrypted_dot_ tmpl+asc"  ".foo"       "$(parse_file_name encrypted_dot_foo.tmpl.asc)"
assert_eq "non-encrypted keeps .age" "foo.age"    "$(parse_file_name foo.age)"
assert_eq "non-encrypted keeps .asc" "foo.asc"    "$(parse_file_name foo.asc)"
assert_eq "all attrs + tmpl + age"   ".foo"       \
    "$(parse_file_name encrypted_private_readonly_empty_executable_dot_foo.tmpl.age)"

# --- parse_file_name: scripts & remove_ have no managed target --------------
expect_skip "run_ script"            "run_foo.sh"
expect_skip "run_once_ script"       "run_once_foo.sh"
expect_skip "run_onchange_ script"   "run_onchange_foo.sh"
expect_skip "run_after_ script"      "run_after_foo.sh"
expect_skip "run_once_before_ script" "run_once_before_foo.sh"
expect_skip "run_onchange_after_ tmpl" "run_onchange_after_foo.sh.tmpl"
expect_skip "remove_ file"           "remove_dot_foo"
expect_skip "remove_dot_ file"       "remove_dot_foo"

# --- get_target_path: multi-component paths ---------------------------------
assert_eq "single dot_ file tmpl"    ".gitconfig" "$(get_target_path dot_gitconfig.tmpl)"
assert_eq "single empty_dot_"        ".hushlogin" "$(get_target_path empty_dot_hushlogin)"
assert_eq "two nested dot_ dirs"     ".config/.nvim/init.lua" \
    "$(get_target_path dot_config/dot_nvim/init.lua)"
assert_eq "nested dot_ then plain"   ".zsh/completions/_foo" \
    "$(get_target_path dot_zsh/completions/_foo)"
assert_eq "tmpl at depth"            ".config/foo/bar.conf" \
    "$(get_target_path dot_config/foo/bar.conf.tmpl)"
assert_eq "exact_ dir in path"       ".config/foo" \
    "$(get_target_path exact_dot_config/foo)"
assert_eq "literal_ dir in path"     "dot_foo/bar" \
    "$(get_target_path literal_dot_foo/bar)"
assert_eq "encrypted file at depth"  ".config/.secret" \
    "$(get_target_path dot_config/encrypted_dot_secret.age)"

# --- get_target_path: chezmoi-meta & ignored entries have no target ---------
expect_skip "chezmoi meta file"      ".chezmoi.json.tmpl"
expect_skip "chezmoiscripts dir"     ".chezmoiscripts/run_foo.sh"
expect_skip "chezmoiignore nested"   "dot_config/.chezmoiignore"
expect_skip "gitignore"              ".gitignore"
expect_skip "dot-prefixed source"    ".foo"

echo ""
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
