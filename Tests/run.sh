#!/bin/zsh
# End-to-end test without Final Cut Pro: transcribes the fixture project and writes captions to out/.
#   Tests/run.sh [source-locale] [targets]     e.g. Tests/run.sh ru-RU en,th
set -euo pipefail
cd "${0:A:h}/.."
./build.sh cli >/dev/null
mkdir -p out
# FCPXML needs absolute media URLs: point the fixture at this checkout.
sed "s|__FIXTURES__|$PWD/Tests/Fixtures|g" Tests/Fixtures/test-project.fcpxml > out/test-project.fcpxml
./build/fcpautosubs out/test-project.fcpxml "${1:-ru-RU}" "${2:-}"
