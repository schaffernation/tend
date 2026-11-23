#!/bin/zsh
# Make the Sparkle appcast for a release: appcast.xml, which tells Tend that
# a new version exists, where to download it, and what changed. release.sh
# runs this at the end. You can also run it on its own.
#
# Usage: app/appcast.sh [DMG]
#   DMG  The release's disk image. By default, app/build/Tend-VERSION.dmg,
#        with VERSION from Info.plist.
#
# The script signs the update with the private EdDSA key that
# generate_keys stored in your keychain (see "Build a release" in
# README.md). To use a key file instead, set TEND_ED_KEY_FILE to its path.
#
# The release notes come from the "## VERSION" section of CHANGELOG.md, so
# rename "Unreleased" to the version before you release.
#
# The script starts from the published appcast at SUFeedURL in Info.plist, so
# earlier releases stay in the feed, and writes app/build/appcast/appcast.xml.
# Upload that file to SUFeedURL after you publish the GitHub release, because
# its download link points at the release's disk image. Set
# TEND_DOWNLOAD_URL_PREFIX to download from somewhere other than GitHub
# Releases.

emulate -L zsh
setopt err_exit no_unset pipe_fail

here=${0:A:h}
build=$here/build
source $here/sparkle.sh

plist=$here/Info.plist
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $plist)
feed=$(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' $plist)
dmg=${1:-$build/Tend-$version.dmg}
prefix=${TEND_DOWNLOAD_URL_PREFIX:-https://github.com/schaffernation/tend/releases/download/v$version/}
[[ $prefix == */ ]] || prefix=$prefix/

if [[ ! -f $dmg ]]; then
  print -u2 "appcast.sh: $dmg doesn't exist. Run app/release.sh first, or pass the disk image's path."
  exit 1
fi
key=$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' $plist)
if [[ $(print -rn -- $key | base64 -d 2>/dev/null | wc -c) -ne 32 ]]; then
  print -u2 "appcast.sh: SUPublicEDKey in Info.plist isn't a public key yet. See \"Build a release\" in README.md."
  exit 1
fi

out=$build/appcast
rm -rf $out
mkdir -p $out
cp $dmg $out/

# Release notes: the CHANGELOG.md section for this version, without its
# heading. generate_appcast pairs Tend-VERSION.md with Tend-VERSION.dmg.
notes=$out/${${dmg:t}:r}.md
awk -v v="$version" '
  /^## / { if (found) exit; if ($0 == "## " v) { found = 1; next } }
  found { print }
' $here/../CHANGELOG.md > $notes
if [[ ! -s $notes ]]; then
  print -u2 "appcast.sh: CHANGELOG.md has no \"## $version\" section. Add one, and then run app/appcast.sh again."
  exit 1
fi

if curl -fsSL -o $out/appcast.xml $feed 2>/dev/null && grep -q '<rss' $out/appcast.xml; then
  print "Adding Tend $version to the appcast at $feed."
else
  rm -f $out/appcast.xml
  print "No appcast at $feed yet. Starting a new one."
fi

args=(--download-url-prefix $prefix --embed-release-notes
      --link https://github.com/schaffernation/tend)
if [[ -n ${TEND_ED_KEY_FILE:-} ]]; then
  args+=(--ed-key-file $TEND_ED_KEY_FILE)
fi
$sparkle/bin/generate_appcast $args $out

# generate_appcast skips the signature when the app in the disk image has a
# different SUPublicEDKey from your private key, and Tend would refuse that
# update.
if ! grep -q "url=\"$prefix${dmg:t}\".*sparkle:edSignature=" $out/appcast.xml; then
  print -u2 "appcast.sh: generate_appcast didn't sign ${dmg:t}. Check that SUPublicEDKey in the app matches your private key: generate_keys -p prints the public key."
  exit 1
fi

print
print "Built $out/appcast.xml"
print "After you publish the GitHub release, upload it to $feed."
