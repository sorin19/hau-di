#!/bin/bash
# Publishes this project folder to GitHub: commits everything that changed and pushes it (remote "origin").
# Run it after updating the project from a new hau-di.zip (Tools/install.sh):
#   bash Tools/publish.sh                       # default commit message (the date)
#   bash Tools/publish.sh "Short description"   # your own commit message
# Before committing it makes sure nothing private goes out: the signing Team stays out of project.pbxproj
# (Tools/git-clean-team.sh), and no keys, .env files, CSV exports, archives, Xcode user data or big files are
# committed. If GitHub has commits that are not here (e.g. a file edited on the website), it stops without changing
# anything.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PBX="hau-di.xcodeproj/project.pbxproj"
MAX_BYTES=$((5 * 1024 * 1024))

die() {
  echo "Stopped: $*" >&2
  exit 1
}
# Something is wrong with what would be committed: unstage it (the files stay as they are) and stop.
refuse() {
  git reset --quiet
  die "$@"
}

command -v git >/dev/null || die "git is missing. Install Xcode's command line tools: xcode-select --install"
[ -d .git ] || die "$ROOT is not a git repository."
git remote get-url origin >/dev/null 2>&1 || die "there is no GitHub remote (origin)."

# Keeps the signing Team out of commits (once per clone is enough; repeating it is harmless).
git config filter.noteam.clean Tools/git-clean-team.sh
git config filter.noteam.smudge cat

BRANCH="$(git rev-parse --abbrev-ref HEAD)"

echo "-> Checking GitHub..."
git fetch --quiet origin
if git rev-parse --verify --quiet "origin/$BRANCH" >/dev/null; then
  BEHIND="$(git rev-list --count "HEAD..origin/$BRANCH")"
  if [ "$BEHIND" != "0" ]; then
    die "GitHub has $BEHIND commit(s) that are not in this folder (edited on the website?). Nothing was changed."
  fi
fi

trap 'echo; git reset --quiet; echo "Canceled: nothing was committed or pushed."; exit 1' INT
git add -A

# 1. The signing Team must not be in the committed project file.
if git cat-file -e ":$PBX" 2>/dev/null && git show ":$PBX" | grep -qE 'DEVELOPMENT_TEAM = [A-Z0-9]{10};'; then
  refuse "the signing Team would be committed in $PBX (is Tools/git-clean-team.sh executable?)."
fi

# 2. No private files.
PRIVATE="$(git diff --cached --name-only --diff-filter=AM \
  | grep -E '(^|/)\.env|\.(csv|zip|p12|pem|key|mobileprovision|xcuserstate)$|(^|/)xcuserdata/' || true)"
if [ -n "$PRIVATE" ]; then
  refuse "these files look private, so nothing was committed:
$PRIVATE"
fi

# 3. No real-looking keys in the added or changed files: a Claude API key, a Stripe live key or a Stripe webhook
#    secret. Only the real formats (prefix + a long random part) count, so the "sk-ant-…" placeholder in the app and
#    the patterns written in this script do not.
SECRET='sk-ant-[A-Za-z0-9]{2,}-[A-Za-z0-9_-]{20,}|(sk|rk|pk)_live_[A-Za-z0-9]{16,}|whsec_[A-Za-z0-9]{16,}'
LEAKS="$(git diff --cached --name-only -z --diff-filter=AM | xargs -0 -r git grep --cached -l -E "$SECRET" -- || true)"
if [ -n "$LEAKS" ]; then
  refuse "these files contain what looks like an API key or Stripe secret, so nothing was committed:
$LEAKS"
fi

# 4. No big files.
BIG=""
while IFS= read -r file; do
  [ -f "$file" ] || continue
  size="$(wc -c < "$file" | tr -d ' ')"
  if [ "$size" -gt "$MAX_BYTES" ]; then BIG="$BIG$file ($((size / 1024 / 1024)) MB)"$'\n'; fi
done < <(git diff --cached --name-only --diff-filter=AM)
if [ -n "$BIG" ]; then
  refuse "these files are over 5 MB, so nothing was committed:
$BIG"
fi

if git diff --cached --quiet; then
  echo "Nothing new to commit."
else
  MSG="${1:-Update $(date '+%Y-%m-%d %H:%M')}"
  echo
  echo "Changes to publish (A = added, M = modified, D = deleted):"
  git status --short
  echo
  echo "Commit message: $MSG"
  read -r -p "Press Enter to commit and push, or Ctrl+C to cancel. " _
  git commit --quiet -m "$MSG"
  echo "-> Committed."
fi

AHEAD="$(git rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo 1)"
if [ "$AHEAD" = "0" ]; then
  echo "GitHub is already up to date."
  exit 0
fi
echo "-> Pushing to GitHub..."
git push --quiet -u origin "$BRANCH"
echo "Done: $(git remote get-url origin | sed -e 's/\.git$//')"
