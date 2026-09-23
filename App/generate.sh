#!/bin/sh
# Regenerates Arrdeck.xcodeproj and makes it resolve packages to the versions
# the package itself pins. xcodegen writes a project with no Package.resolved,
# so Xcode resolved every dependency fresh — and picked up a swift-collections
# release that the simulator runtime could not load. Always use this instead
# of bare `xcodegen`.
set -e
cd "$(dirname "$0")"
xcodegen "$@"
mkdir -p Arrdeck.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp ../Package.resolved Arrdeck.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
