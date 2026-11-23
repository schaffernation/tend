#!/bin/zsh
# Compile the layered app icon, app/AppIcon.icon, into the files the build
# uses. They're committed, so build.sh needs only the command-line tools.
#
#   app/Assets.car    The layered icon, which macOS 26 and later render as
#                     Liquid Glass, in light, dark, clear, and tinted. actool
#                     also puts flat renderings in it for macOS 14 and 15.
#   app/AppIcon.icns  The flat icon, for CFBundleIconFile and the disk
#                     image's volume icon (make-dmg.sh).
#   app/AppIcon.png   The flat icon at 1024 pixels, for the README and the
#                     website.
#
# Usage: app/make-icon-assets.sh
#
# Run it after swift app/make-icon.swift, or after you change AppIcon.icon in
# Icon Composer. It needs Xcode 26 or later: actool's .icon support, and
# Icon Composer's ictool, which renders the icon. To see another appearance,
# change --rendition below to Dark, ClearLight, ClearDark, TintedLight, or
# TintedDark.

emulate -L zsh
setopt err_exit no_unset pipe_fail

here=${0:A:h}
ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x $ictool ]] || { print -u2 "make-icon-assets.sh: no Icon Composer at $ictool. Install Xcode 26 or later."; exit 1 }
work=$(mktemp -d "${TMPDIR:-/tmp}/tend-icon.XXXXXX")
trap 'rm -rf $work' EXIT INT TERM

xcrun actool $here/AppIcon.icon --compile $work \
  --platform macosx --target-device mac --minimum-deployment-target 14.0 \
  --app-icon AppIcon --output-partial-info-plist $work/partial.plist \
  --errors --warnings --output-format human-readable-text >$work/actool.log
if grep -q -e 'error:' -e 'warning:' $work/actool.log; then
  cat $work/actool.log >&2
  exit 1
fi
cp $work/Assets.car $here/Assets.car

# actool's own .icns stops at 128 points, and its flat renderings are soft,
# so draw the .icns and the PNG from Icon Composer's rendering instead.
$ictool $here/AppIcon.icon --export-image --output-file $work/render.png \
  --platform macOS --rendition Default --width 1648 --height 1648 --scale 1 >/dev/null
[[ -s $work/render.png ]] || { print -u2 "make-icon-assets.sh: ictool didn't render the icon."; exit 1 }
swift $here/flatten-icon.swift $work/render.png $work/AppIcon.iconset $here/AppIcon.png
iconutil -c icns $work/AppIcon.iconset -o $here/AppIcon.icns
print "Wrote $here/Assets.car, AppIcon.icns, and AppIcon.png"
