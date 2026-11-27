#!/usr/bin/env bash
# Prints the version for the commit being built, from git tags and commit messages.
#
#   - HEAD already tagged vX.Y.Z      -> X.Y.Z (re-running a release build)
#   - no vX.Y.Z tag yet               -> 0.1.0
#   - otherwise bump the latest tag by BUMP (auto | patch | minor | major, default auto).
#     auto reads the commits since that tag, Conventional Commits style:
#       "type!:" or "BREAKING CHANGE" -> major (minor while still 0.x)
#       "feat:" / "feat(scope):"      -> minor
#       anything else                  -> patch
set -euo pipefail
BUMP="${BUMP:-auto}"

head_tag="$(git tag --points-at HEAD --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n1)"
if [ -n "$head_tag" ]; then
  echo "${head_tag#v}"
  exit 0
fi

last_tag="$(git tag --merged HEAD --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n1)"
if [ -z "$last_tag" ]; then
  echo "0.1.0"
  exit 0
fi

IFS=. read -r major minor patch <<<"${last_tag#v}"
patch="${patch%%[!0-9]*}"

if [ "$BUMP" = "auto" ]; then
  log="$(git log --format='%s%n%b' "$last_tag..HEAD")"
  if grep -qE '^[a-zA-Z]+(\([^)]*\))?!:|BREAKING[ -]CHANGE' <<<"$log"; then
    BUMP=major
  elif grep -qE '^feat(\([^)]*\))?:' <<<"$log"; then
    BUMP=minor
  else
    BUMP=patch
  fi
  # Before 1.0, breaking changes only bump the minor version.
  if [ "$BUMP" = "major" ] && [ "$major" = "0" ]; then BUMP=minor; fi
fi

case "$BUMP" in
  major) echo "$((major + 1)).0.0" ;;
  minor) echo "$major.$((minor + 1)).0" ;;
  patch) echo "$major.$minor.$((patch + 1))" ;;
  *) echo "unknown BUMP '$BUMP'" >&2; exit 1 ;;
esac
