#!/bin/sh
# `swift test`, workable on a machine with only Command Line Tools.
#
# CLT ships Testing.framework outside the toolchain's search path, and the
# Testing+Foundation cross-import overlay does not resolve from there — so the
# framework directory is passed explicitly and the overlay (whose conveniences
# these tests do not use) is disabled. Under full Xcode a plain `swift test`
# works and this script is just a slower way to spell it.
set -e
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
exec swift test \
  -Xswiftc -F"$FW" \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -F"$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  "$@"
