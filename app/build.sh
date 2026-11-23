#!/bin/zsh
# Build Tend.app, a universal (Apple silicon and Intel) app with the tend CLI
# inside it, and install it in /Applications, where every account on this Mac
# can open it.
#
# Usage: app/build.sh [--no-install] [--release]
#   --no-install  Build app/build/Tend.app only.
#   --release     Fail if no Developer ID certificate is available.
#                 release.sh uses this flag.
#
# The build is signed with your Developer ID and the hardened runtime when the
# certificate is in your keychain, and ad hoc otherwise. A Developer ID
# signature stays the same across builds, so macOS keeps each account's
# notification and automation permissions. Set TEND_SIGN_IDENTITY to choose a
# certificate. Otherwise, the first Developer ID Application certificate that
# matches TEND_SIGN_PREFER wins (by default, the maintainer's, SchafferNation),
# and then the first one in your keychain.
#
# The first build downloads Sparkle, the update framework, into
# app/build/cache (see sparkle.sh).

emulate -L zsh
setopt err_exit no_unset

here=${0:A:h}
build=$here/build
app=$build/Tend.app
install=1 release=0
for arg in "$@"; do
  case $arg in
    --no-install) install=0 ;;
    --release) release=1 ;;
    *) print -u2 "build.sh: unknown option $arg"; exit 2 ;;
  esac
done

source $here/sparkle.sh

rm -rf $app $build/arch
mkdir -p $app/Contents/MacOS $app/Contents/Resources $app/Contents/Frameworks $build/arch
cp $here/Info.plist $app/Contents/Info.plist
# The icon, compiled from AppIcon.icon by make-icon-assets.sh.
cp $here/Assets.car $here/AppIcon.icns $app/Contents/Resources/
cp $here/../bin/tend $app/Contents/Resources/tend
chmod 755 $app/Contents/Resources/tend

# Sparkle's XPC services are only for sandboxed apps, and Tend isn't one, so
# leave them out, as Sparkle's sandboxing guide describes. The headers are
# only for compiling.
framework=$app/Contents/Frameworks/Sparkle.framework
ditto $sparkle/Sparkle.framework $framework
for part in XPCServices Headers PrivateHeaders Modules; do
  rm -rf $framework/$part $framework/Versions/B/$part
done

for arch in arm64 x86_64; do
  swiftc -parse-as-library -O -warnings-as-errors \
    -target $arch-apple-macos14 \
    -F $sparkle -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o $build/arch/Tend-$arch \
    $here/Tend.swift $here/Glass.swift $here/Updates.swift
done
lipo -create -output $app/Contents/MacOS/Tend $build/arch/Tend-arm64 $build/arch/Tend-x86_64

identities=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2}')
identity=${TEND_SIGN_IDENTITY:-$(print -r -- $identities | grep -i -- "${TEND_SIGN_PREFER:-schaffernation}" | head -1)}
identity=${identity:-$(print -r -- $identities | head -1)}
# Sign from the inside out, without --deep, as Sparkle's documentation
# describes: Sparkle's helpers, then the framework, then the app.
sparkle_parts=($framework/Versions/B/Autoupdate $framework/Versions/B/Updater.app $framework)
if [[ -n $identity ]]; then
  for part in $sparkle_parts; do
    codesign --force --options runtime --timestamp --sign $identity $part
  done
  codesign --force --options runtime --timestamp \
    --entitlements $here/Tend.entitlements \
    --sign $identity $app
  codesign --verify --deep --strict $app
  print "Signed with $identity"
elif (( release )); then
  print -u2 "build.sh: no Developer ID Application certificate in your keychain."
  exit 1
else
  for part in $sparkle_parts; do
    codesign --force --sign - $part
  done
  codesign --force --sign - $app
  codesign --verify --deep --strict $app
  print "Signed ad hoc. It runs only on this Mac."
fi

if (( install )); then
  # Only your own Tend quits. Other accounts keep running theirs until they
  # next open it.
  pkill -x -u $(id -u) Tend 2>/dev/null || true
  rm -rf /Applications/Tend.app
  cp -R $app /Applications/
  open /Applications/Tend.app
  print "Installed /Applications/Tend.app and opened it."
else
  print "Built $app"
fi
