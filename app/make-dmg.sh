#!/bin/zsh
# Package Tend.app as a disk image with a designed Finder window: Tend on the
# left, an Applications link on the right, a background with a drag arrow, and
# the Tend volume icon. release.sh runs this script, then signs and notarizes
# the result. You can run it on its own to check the layout:
#
#   app/build.sh --no-install && app/make-dmg.sh app/build/Tend.app /tmp/Tend.dmg
#
# Usage: app/make-dmg.sh APP OUT
#
# The script writes the window layout (.DS_Store) itself, with
# make-dsstore.py, instead of scripting Finder, so it needs no Automation
# permission and works over SSH, in tmux, and in CI. It builds a read-write
# image, mounts it privately, lays it out, and converts it to a compressed,
# read-only ULFO image. ULFO (LZFSE) opens on macOS 10.11 and later, well below
# Tend's minimum of macOS 14, and is smaller and faster to open than UDZO.

emulate -L zsh
setopt err_exit no_unset pipe_fail

if (( $# != 2 )); then
  print -u2 "Usage: app/make-dmg.sh APP OUT"
  exit 2
fi
here=${0:A:h}
app=${1:A}
out=${2:A}
volname=Tend
# Window content size, icon size, and icon centers. make-dmg-background.swift
# draws the arrow between these centers, so change both together.
width=640 height=400 icon=128
app_at=160,160 applications_at=480,160

[[ -d $app/Contents ]] || { print -u2 "make-dmg.sh: $app isn't an app"; exit 1 }

work=$(mktemp -d "${TMPDIR:-/tmp}/tend-dmg.XXXXXX")
mnt=$work/mnt
mounted=0
cleanup() {
  if (( mounted )); then
    hdiutil detach $mnt -quiet 2>/dev/null || hdiutil detach $mnt -force -quiet 2>/dev/null || true
  fi
  rm -rf $work
}
trap cleanup EXIT INT TERM

print "Drawing the background…"
swift $here/make-dmg-background.swift $work/background.png >/dev/null

# Room for the app plus a few megabytes for the background and metadata.
size=$(( $(du -sm $app | cut -f1) + 16 ))
hdiutil create -quiet -size ${size}m -fs HFS+ -volname $volname -type UDIF -layout NONE $work/rw.dmg
mkdir $mnt
hdiutil attach $work/rw.dmg -readwrite -noverify -noautoopen -nobrowse -owners off \
  -mountpoint $mnt -quiet
mounted=1

ditto $app $mnt/${app:t}
ln -s /Applications $mnt/Applications
mkdir $mnt/.background
cp $work/background.png $mnt/.background/background.png
cp $here/AppIcon.icns $mnt/.VolumeIcon.icns
SetFile -a C $mnt
python3 $here/make-dsstore.py $mnt $volname .background/background.png \
  $width $height $icon "${app:t}=$app_at" "Applications=$applications_at"
rm -rf $mnt/.fseventsd $mnt/.Trashes

# Detach, retrying while Spotlight or fseventsd lets go of the volume.
for try in 1 2 3 4 5; do
  hdiutil detach $mnt -quiet 2>/dev/null && { mounted=0; break }
  sleep 1
done
if (( mounted )); then
  hdiutil detach $mnt -force -quiet
  mounted=0
fi

print "Compressing ${out:t}…"
mkdir -p ${out:h}
rm -f $out
hdiutil convert $work/rw.dmg -quiet -format ULFO -o $out
print "Built $out"
