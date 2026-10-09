#!/bin/zsh
# Runs the offline regression suite with either Command Line Tools or Xcode.
set -euo pipefail
cd "${0:A:h}/.."

et_frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
et_testing_flags=()
if [[ -d "$et_frameworks/Testing.framework" ]]; then
  # Some CLT releases pass this framework directory as -I/-L instead of -F.
  et_testing_flags=(
    -Xswiftc "-F$et_frameworks"
    -Xlinker "-F$et_frameworks"
    -Xlinker -rpath -Xlinker "$et_frameworks"
    -Xlinker -rpath -Xlinker "$et_frameworks/../usr/lib"
  )
fi

swift test --disable-xctest "${et_testing_flags[@]}" "$@"
