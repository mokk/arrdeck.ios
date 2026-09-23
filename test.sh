#!/bin/sh
# `swift test`, workable with or without full Xcode.
#
# Under Xcode a plain `swift test` just works and that is what runs. With only
# Command Line Tools, Testing.framework sits outside the toolchain's search
# path and the Testing+Foundation cross-import overlay does not resolve from
# there — so the framework directory is passed explicitly and the overlay
# (whose conveniences these tests do not use) is disabled.
set -e
cd "$(dirname "$0")"

# The generator's spec is derived from the submodule's; a stale copy would
# type the client against a backend other than the pinned one.
./Scripts/derive-spec.sh
if ! git diff --quiet -- Sources/ArrdeckAPI/openapi.json; then
    echo "Sources/ArrdeckAPI/openapi.json was out of date; regenerated — commit it." >&2
    exit 1
fi

# The string catalog is generated from what the compiler finds localisable;
# a new Text("…") without a Danish entry, or a stale catalog, fails here.
./Scripts/localize.py --check

case "$(xcode-select -p 2>/dev/null)" in
*CommandLineTools*)
    FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
    exec swift test \
        -Xswiftc -F"$FW" \
        -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
        -Xlinker -F"$FW" \
        -Xlinker -rpath -Xlinker "$FW" \
        "$@"
    ;;
*)
    exec swift test "$@"
    ;;
esac
