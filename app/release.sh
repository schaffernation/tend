#!/bin/zsh
# Build, sign, and notarize Tend, and package it as a disk image you can put
# on GitHub Releases. Gatekeeper opens the result on any Mac without a warning.
#
# Usage: app/release.sh
#
# Before the first release, store your notarization credentials in the
# keychain. Use an app-specific password from https://account.apple.com:
#
#   xcrun notarytool store-credentials tend-notary \
#     --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
#
# Your team ID is the 10 characters in parentheses at the end of your
# certificate's name. To see it, run:
#
#   security find-identity -v -p codesigning
#
# Set TEND_NOTARY_PROFILE to use a different keychain profile name.

emulate -L zsh
setopt err_exit no_unset pipe_fail

here=${0:A:h}
build=$here/build
app=$build/Tend.app
profile=${TEND_NOTARY_PROFILE:-tend-notary}
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $here/Info.plist)
dmg=$build/Tend-$version.dmg
latest=$build/Tend.dmg

$here/build.sh --no-install --release

# Notarize the app and staple its ticket, so it opens offline after you copy
# it out of the disk image.
print "Notarizing Tend.app…"
ditto -c -k --keepParent $app $build/Tend.zip
xcrun notarytool submit $build/Tend.zip --keychain-profile $profile --wait
xcrun stapler staple $app
rm $build/Tend.zip

# Package the app in a disk image with a designed window (see make-dmg.sh),
# then sign and notarize the disk image too.
print "Building $dmg…"
$here/make-dmg.sh $app $dmg
codesign --force --timestamp --sign ${TEND_SIGN_IDENTITY:-"Developer ID Application"} $dmg

print "Notarizing $dmg…"
xcrun notarytool submit $dmg --keychain-profile $profile --wait
xcrun stapler staple $dmg
spctl --assess --type open --context context:primary-signature --verbose=2 $dmg

# A copy with a name that doesn't change, for the
# releases/latest/download/Tend.dmg link.
cp $dmg $latest

# The Sparkle feed, in site/appcast.xml.
$here/appcast.sh $dmg

print
print "Built $dmg and $latest"
print "To publish them, in this order:"
print "1. Publish the GitHub release, so the feed's download link works:"
print "     gh release create v$version $dmg $latest --title 'Tend $version' --generate-notes"
print "2. Update the Homebrew cask:"
print "     $here/update-cask.sh $version $dmg"
print "3. Commit the feed and the cask, and push. Pushing deploys the site, so"
print "   installed copies of Tend see the update right away:"
print "     git add site/appcast.xml packaging/homebrew/tend.rb"
print "     git commit -m 'Release Tend $version' && git push"
