#!/bin/bash
set -euo pipefail
version=${1:?Usage: bash packaging/release.sh VERSION}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 64
mkdir -p dist
git archive --format=tar --prefix="agent-beacon-$version/" HEAD | gzip -n > "dist/agent-beacon-$version.tar.gz"
shasum -a 256 "dist/agent-beacon-$version.tar.gz" > "dist/SHA256SUMS"
/usr/bin/ruby -rdigest -e '
  version = ARGV.fetch(0)
  digest = Digest::SHA256.file("dist/agent-beacon-#{version}.tar.gz").hexdigest
  template = File.read("packaging/agent-beacon.rb.in")
  File.write("dist/agent-beacon.rb", template.gsub("@VERSION@", version).gsub("@SHA256@", digest))
' "$version"
