#!/usr/bin/env bash
eval "$(homebrew/bin/brew shellenv)"
wg-quick "$@"
