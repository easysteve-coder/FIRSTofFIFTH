#!/bin/zsh
# Exports the committed state of the private FIRSTofFIFTH repository into this
# public repository, minus internal material, and creates one commit per version.
#
#   .publish/publish.sh            # prepare and commit, no push
#   .publish/publish.sh --push     # additionally push to origin/main
#
# Only HEAD of the private repo is exported (git archive), never the working
# tree: uncommitted or untracked files there cannot leak.
set -euo pipefail

PUBLIC="${0:A:h:h}"
PRIVATE="${FOF_PRIVATE:-${PUBLIC:h}/FIRSTofFIFTH}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Paths of the private repo that are published. Everything else stays private.
INCLUDE=(
  .gitignore
  LICENSE
  FoF_icon_bold.svg
  Docs/USER_MANUAL.md
  Docs/GUI_DESIGN_SYSTEM.md
  VintageSequencer/VERSION
  VintageSequencer/CHANGELOG.md
  VintageSequencer/CHANGELOG.en.md
  VintageSequencer/ENGINEERING.md
  VintageSequencer/PROJECT_LOG.md
  VintageSequencer/Tools
  VintageSequencer/VintageSequencer
  VintageSequencer/VintageSequencerTests
  VintageSequencer/VintageSequencerUITests
  VintageSequencer/FIRSTofFIFTH.xcodeproj
)
# Removed again after export (user-specific Xcode state).
EXCLUDE_GLOBS=( '*/xcuserdata' )

git -C "$PRIVATE" diff --quiet HEAD -- "${INCLUDE[@]}" ':!*/xcuserdata/*' || \
  print -u2 "Hinweis: uncommittete Änderungen in veröffentlichten Pfaden werden NICHT übernommen."

VERSION="$(git -C "$PRIVATE" show HEAD:VintageSequencer/VERSION | tr -d '[:space:]')"
SUBJECT="$(git -C "$PRIVATE" log -1 --format=%s)"

git -C "$PRIVATE" archive HEAD -- "${INCLUDE[@]}" | tar -x -C "$STAGE"
for g in "${EXCLUDE_GLOBS[@]}"; do
  find "$STAGE" -path "$STAGE/$g" -prune -exec rm -rf {} +
done

# Public build settings: no personal Apple team, ad-hoc signing ("Sign to Run
# Locally"), so a fresh clone builds without any signing setup. Release builds
# with Developer ID and notarisation are made from the private repository.
PBX="$STAGE/VintageSequencer/FIRSTofFIFTH.xcodeproj/project.pbxproj"
sed -E -i '' \
  -e 's/("?DEVELOPMENT_TEAM(\[[^]]*\])?"?) = [A-Z0-9]+;/\1 = "";/' \
  -e 's/("CODE_SIGN_IDENTITY\[sdk=macosx\*\]") = "Developer ID Application";/\1 = "-";/' \
  "$PBX"
if grep -qE 'DEVELOPMENT_TEAM[^=]*= [A-Z0-9]{10};' "$PBX"; then
  print -u2 "Abbruch: Team-ID im Export."; exit 1
fi

# Replace the published tree; keep files that exist only in the public repo.
cd "$PUBLIC"
for p in "${INCLUDE[@]}"; do rm -rf -- "$p"; done
rsync -a "$STAGE"/ "$PUBLIC"/

git add -A
if git diff --cached --quiet; then
  print "Nichts zu veröffentlichen (v$VERSION ist schon drin)."
  exit 0
fi
git commit -q -m "$SUBJECT"
print "Commit für v$VERSION angelegt: $(git log -1 --format='%h %s')"

if [[ "${1:-}" == "--push" ]]; then
  git push -u origin main
fi
