#!/bin/zsh
# Point the Homebrew cask at a new release: set its version and the disk
# image's SHA-256 in packaging/homebrew/tend.rb. Commit and push the change;
# the schaffernation/homebrew-apps tap copies the cask from this repository.
#
# Usage: app/update-cask.sh VERSION DMG
#   VERSION  The release version, like 0.2. The cask downloads
#            Tend-VERSION.dmg from the vVERSION release on GitHub.
#   DMG      The disk image you upload to that release. The cask's checksum
#            must match the uploaded file byte for byte.

emulate -L zsh
setopt err_exit no_unset pipe_fail

if (( $# != 2 )); then
  print -u2 "Usage: app/update-cask.sh VERSION DMG"
  exit 2
fi

here=${0:A:h}
cask=$here/../packaging/homebrew/tend.rb
version=$1 dmg=$2

if [[ ! $version =~ '^[0-9]+(\.[0-9]+)*$' ]]; then
  print -u2 "update-cask.sh: $version isn't a version like 0.2."
  exit 2
fi
if [[ ! -f $dmg ]]; then
  print -u2 "update-cask.sh: $dmg doesn't exist."
  exit 1
fi

sha=$(shasum -a 256 $dmg | awk '{print $1}')
sed -E -i '' \
  -e "s/^  version \"[^\"]*\"/  version \"$version\"/" \
  -e "s/^  sha256 \"[^\"]*\"/  sha256 \"$sha\"/" \
  $cask
grep -q "^  version \"$version\"" $cask
grep -q "^  sha256 \"$sha\"" $cask
print "Updated ${cask:A} to $version ($sha)."
print "Commit and push it. The schaffernation/homebrew-apps tap picks it up within an hour."
