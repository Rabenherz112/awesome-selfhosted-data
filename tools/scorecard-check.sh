#!/usr/bin/env bash
# OpenSSF Scorecard gate for awesome-selfhosted-data submissions.
#
# Runs OpenSSF Scorecard (https://github.com/ossf/scorecard) against the
# source_code_url of software entries and fails when the aggregate score is below
# SCORECARD_THRESHOLD. Invoked by `make scorecard` - see the Makefile for the
# configurable variables.
#
# By default it checks the software/*.yml files added between SCORECARD_BASE and
# HEAD (i.e. the current pull request). Set SCORECARD_REPO to check a single
# repository instead (handy for reviewing one submission locally).
#
# Only GitHub and GitLab are supported by Scorecard; entries on other forges are
# skipped (not failed). Tooling/evaluation errors (network, auth, 404, rate limit)
# are also skipped unless SCORECARD_STRICT is set to a non-empty value.
#
# Authentication is read from the environment by the scorecard binary itself:
#   - GitHub App:  GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, GITHUB_APP_KEY_PATH
#   - or PAT:      GITHUB_TOKEN / GITHUB_AUTH_TOKEN
#   - GitLab:      GITLAB_AUTH_TOKEN
set -euo pipefail

SCORECARD_BIN="${SCORECARD_BIN:-./bin/scorecard}"
SCORECARD_THRESHOLD="${SCORECARD_THRESHOLD:-5.0}"
SCORECARD_BASE="${SCORECARD_BASE:-origin/master}"
SCORECARD_REPO="${SCORECARD_REPO:-}"
SCORECARD_STRICT="${SCORECARD_STRICT:-}"
SCORECARD_DIFF_FILTER="${SCORECARD_DIFF_FILTER:-A}" # Only check by default git diff statuses. "A" (added)

files=()   # yml paths, index-aligned with repos[]
repos=()   # normalized host/owner/repo
 
# List software/*.yml paths added between SCORECARD_BASE and HEAD.
# NUL-delimited and quotePath=false so non-ASCII names (baikal, pønskelisten,
# µtask...) are not returned C-quoted and unreadable.
list_changed_files() {
  git -c core.quotePath=false diff -z --name-only \
    --diff-filter="$SCORECARD_DIFF_FILTER" "$SCORECARD_BASE...HEAD" -- software/ 2>/dev/null || true
}
 
# Print the source_code_url value of a yml file.
read_source_url() {
  sed -n 's/^source_code_url:[[:space:]]*//p' "$1" | head -n1 | tr -d '\r"'
}
 
# Strip the scheme and trailing slashes to get the host/owner/repo form Scorecard expects.
normalize_repo() {
  echo "$1" | sed -E 's#^https?://##; s#/+$##'
}
 
# Print a classification for a normalized repo: supported, unsupported, or malformed.
# GitHub must be exactly owner/repo; GitLab may nest subgroups (owner/sub/repo).
classify_repo() {
  local segments; segments=$(echo "$1" | awk -F/ '{print NF}')
  case "$1" in
    github.com/*) [ "$segments" -eq 3 ] && echo supported || echo malformed ;;
    gitlab.com/*) [ "$segments" -ge 3 ] && echo supported || echo malformed ;;
    *) echo unsupported ;;
  esac
}
 
# Populate files[]/repos[] from SCORECARD_REPO or from the git diff, deduplicated.
collect_targets() {
  if [ -n "$SCORECARD_REPO" ]; then
    files+=("(manual)"); repos+=("$(normalize_repo "$SCORECARD_REPO")")
    return
  fi
  local f url repo
  while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    url=$(read_source_url "$f")
    [ -n "$url" ] || continue
    repo=$(normalize_repo "$url")
    case " ${repos[*]:-} " in *" $repo "*) continue ;; esac
    files+=("$f"); repos+=("$repo")
  done < <(list_changed_files)
}
 
# Print the aggregate score from a Scorecard JSON document, or "-1" if absent.
parse_score() {
  printf '%s' "$1" | python3 -c 'import sys,json
d = json.load(sys.stdin); s = d.get("score")
print(s if isinstance(s, (int, float)) else -1)' 2>/dev/null || echo "-1"
}
 
# Print the per-check breakdown of a Scorecard JSON document, lowest scores first.
print_checks() {
  printf '%s' "$1" | python3 -c 'import sys,json
for c in sorted(json.load(sys.stdin).get("checks", []), key=lambda x: x.get("score") if isinstance(x.get("score"), int) and x.get("score") >= 0 else 99):
    s = c.get("score")
    s = "?" if not isinstance(s, int) or s < 0 else str(s)
    print("        %-22s %3s  %s" % (c.get("name", "?"), s, c.get("reason") or ""))' 2>/dev/null || true
}
 
# Record a non-fatal evaluation problem, escalating to a failure under strict mode.
warn_or_fail() {
  echo "WARN  $1"
  [ -n "$SCORECARD_STRICT" ] && { echo "STRICT: treating as failure."; fail=1; }
  return 0
}
 
collect_targets
 
if [ "${#repos[@]}" -eq 0 ]; then
  echo "OpenSSF Scorecard: no added software entries to check."
  exit 0
fi
 
echo "OpenSSF Scorecard: ${#repos[@]} entries, threshold >= $SCORECARD_THRESHOLD (strict=${SCORECARD_STRICT:-off})"
 
fail=0
for i in "${!repos[@]}"; do
  file="${files[$i]}"; repo="${repos[$i]}"
  case "$(classify_repo "$repo")" in
    unsupported)
      echo "SKIP  $file -> $repo (Scorecard supports GitHub/GitLab only)"; continue ;;
    malformed)
      echo "SKIP  $file -> $repo (not a host/owner/repo URL)"
      [ -n "$SCORECARD_STRICT" ] && { echo "STRICT: treating as failure."; fail=1; }
      continue ;;
  esac
 
  echo "----------------------------------------------------------------------"
  echo "CHECK $file -> $repo"
 
  # Scorecard exits non-zero if any single check errors, but it writes the full
  # result to stdout first. Individual failed checks score -1 and drop out of the
  # aggregate, so judge on the JSON rather than the exit code.
  json=$("$SCORECARD_BIN" --repo="$repo" --format=json) || true
  score=$(parse_score "$json")
  print_checks "$json"
 
  if awk "BEGIN{exit !($score < 0)}"; then
    warn_or_fail "$repo: no usable result (network/auth/404/rate-limit?)"; continue
  fi
  if awk "BEGIN{exit !($score < $SCORECARD_THRESHOLD)}"; then
    echo "FAIL  $repo: score $score < threshold $SCORECARD_THRESHOLD"; fail=1
  else
    echo "PASS  $repo: score $score >= threshold $SCORECARD_THRESHOLD"
  fi
done
 
echo "----------------------------------------------------------------------"
if [ "$fail" -ne 0 ]; then
  echo "OpenSSF Scorecard gate: FAILED"
  echo "See https://github.com/ossf/scorecard/blob/main/docs/checks.md for remediation."
  exit 1
fi
echo "OpenSSF Scorecard gate: PASSED"
exit 0
