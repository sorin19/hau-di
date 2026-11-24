#!/bin/sh
# Git "clean" filter for project.pbxproj (see .gitattributes). The signing Team you pick in Xcode (or that
# Tools/install.sh restores) stays in your working copy, but commits keep DEVELOPMENT_TEAM empty, so your Team ID
# never ends up in the repository. Enable it once per clone:
#   git config filter.noteam.clean Tools/git-clean-team.sh
#   git config filter.noteam.smudge cat
exec sed -E 's/DEVELOPMENT_TEAM = [A-Z0-9]{10};/DEVELOPMENT_TEAM = "";/'
