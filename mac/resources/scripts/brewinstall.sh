#!/usr/bin/env bash
set -euo pipefail

homedir="/var/lib/gnosis_vpn"
pushd "$homedir" || exit 1
rm -rf homebrew

mkdir homebrew && curl -L https://github.com/Homebrew/brew/tarball/main | tar xz --strip-components 1 -C homebrew
eval "$(homebrew/bin/brew shellenv)"
brew update --force --quiet
chmod -R go-w "$(brew --prefix)/share/zsh"
brew install wireguard-tools
popd
