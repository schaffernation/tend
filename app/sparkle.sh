#!/bin/zsh
# Make sure the pinned Sparkle release is in app/build/cache, and set
# $sparkle to its folder: Sparkle.framework, and bin/ with generate_appcast
# and sign_update. build.sh and appcast.sh source this file after they set
# $here to the app folder.
#
# To move to a new Sparkle, change both lines below. Take the SHA-256 from
# the release's asset on github.com/sparkle-project/Sparkle/releases, or from
#   gh api repos/sparkle-project/Sparkle/releases/tags/VERSION --jq '.assets[].digest'

sparkle_version=2.10.1
sparkle_sha256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27

sparkle=${here:?}/build/cache/Sparkle-$sparkle_version
if [[ ! -d $sparkle/Sparkle.framework ]]; then
  () {
    emulate -L zsh
    setopt err_exit no_unset pipe_fail
    local cache=${sparkle:h} url=https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz
    mkdir -p $cache
    # Download into a new, empty folder, and use it only after the checksum
    # matches.
    local dl=$(mktemp -d $cache/download.XXXXXX)
    print "Downloading Sparkle $sparkle_version…"
    curl -fsSL --retry 3 -o $dl/Sparkle.tar.xz $url
    local actual=$(shasum -a 256 $dl/Sparkle.tar.xz | awk '{print $1}')
    if [[ $actual != $sparkle_sha256 ]]; then
      print -u2 "sparkle.sh: $url has SHA-256 $actual, but sparkle.sh expects $sparkle_sha256."
      rm -rf $dl
      exit 1
    fi
    mkdir $dl/Sparkle
    tar -xJf $dl/Sparkle.tar.xz -C $dl/Sparkle
    rm -rf $sparkle
    mv $dl/Sparkle $sparkle
    rm -rf $dl
  }
fi
