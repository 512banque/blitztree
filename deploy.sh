#!/bin/zsh
# Deploy: rebuild and update the FDA-granted /Applications copy in place.
set -e; cd "$(dirname "$0")"; ./build.sh
# Clean replace: a ditto-merge over an old bundle can corrupt the signature,
# and an invalid signature makes TCC silently ignore the FDA grant.
rm -rf /Applications/BlitzTree.app
ditto build/BlitzTree.app /Applications/BlitzTree.app
codesign --verify --strict /Applications/BlitzTree.app
echo "==> Deployed to /Applications/BlitzTree.app (signature verified)"
