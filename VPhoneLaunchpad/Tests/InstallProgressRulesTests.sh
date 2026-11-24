#!/bin/zsh
set -euo pipefail

launchpad="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$temporary"' EXIT

/usr/bin/xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -parse-as-library \
    "$launchpad/VPhoneLaunchpadShared/VPhoneLaunchpadInstallProgressRules.swift" \
    "$launchpad/Tests/InstallProgressRulesTests.swift" \
    -o "$temporary/install-progress-rules-tests"
"$temporary/install-progress-rules-tests" "$@"
