#!/bin/zsh
# Runs the offline regression suite with either Command Line Tools or Xcode.
cd "${0:A:h}/.."

if [[ -z "${CLANG_MODULE_CACHE_PATH:-}" ]]; then
  export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
fi
mkdir -p "$CLANG_MODULE_CACHE_PATH"

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
