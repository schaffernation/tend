#!/bin/zsh
# Point the Homebrew cask at a new release: set its version and the disk
# image's SHA-256 in packaging/homebrew/Casks/tend.rb.
#
# Usage: app/update-cask.sh VERSION DMG [TAP]
#   VERSION  The release version, like 0.2. The cask downloads
#            Tend-VERSION.dmg from the vVERSION release on GitHub.
#   DMG      The disk image you upload to that release. The cask's checksum
#            must match the uploaded file byte for byte.
#   TAP      Optional. A local clone of schaffernation/homebrew-tend. The
#            script copies the cask to TAP/Casks/tend.rb and commits it
#            there. It doesn't push.

emulate -L zsh
setopt err_exit no_unset pipe_fail

if (( $# < 2 || $# > 3 )); then
  print -u2 "Usage: app/update-cask.sh VERSION DMG [TAP]"
  exit 2
fi

here=${0:A:h}
cask=$here/../packaging/homebrew/Casks/tend.rb
version=$1 dmg=$2 tap=${3:-}

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

if [[ -n $tap ]]; then
  if [[ ! -d $tap/.git ]]; then
    print -u2 "update-cask.sh: $tap isn't a git clone of the tap."
    exit 1
  fi
  mkdir -p $tap/Casks
  cp $cask $tap/Casks/tend.rb
  git -C $tap add Casks/tend.rb
  git -C $tap commit -m "tend $version"
  print "Committed tend $version in $tap. To publish it, run: git -C $tap push"
fi
