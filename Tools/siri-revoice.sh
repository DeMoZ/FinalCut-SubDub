#!/bin/zsh
# Re-voice a SubDub dub track with a Siri voice (developer tool: requires Xcode).
#   Tools/siri-revoice.sh --list
#   Tools/siri-revoice.sh "<~/Movies/SubDub/… output folder>" th Male
# Then in Final Cut Pro: if the dub clip still sounds like the old voice, use File ▸ Relink Files
# (or restart Final Cut Pro) so it re-reads dub-<lang>.wav.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
exec swift "${0:A:h}/SiriRevoice/siri-revoice.swift" "$@"
