#!/bin/sh
# Regenerates Sources/ArrdeckAPI/openapi.json from the pinned backend's spec.
# See Scripts/derive-spec.jq for why the two differ. CI fails when the
# committed copy is out of date, so run this after bumping the submodule.
set -e
cd "$(dirname "$0")/.."
jq -S -f Scripts/derive-spec.jq arrdeck/openapi.json > Sources/ArrdeckAPI/openapi.json
