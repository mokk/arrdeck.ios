#!/bin/sh
# `swift test`, workable with or without full Xcode.
#
# Under Xcode a plain `swift test` just works and that is what runs. With only
# Command Line Tools, Testing.framework sits outside the toolchain's search
# path and the Testing+Foundation cross-import overlay does not resolve from
# there — so the framework directory is passed explicitly and the overlay
# (whose conveniences these tests do not use) is disabled.
set -e
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
