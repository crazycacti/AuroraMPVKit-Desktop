#!/bin/bash
set -euo pipefail

if [ $# -ne 3 ]; then
	echo "usage: $0 <macos-arm64 kit .tar.xz> <macos-x86_64 kit .tar.xz> <version>" >&2
	exit 2
fi
arm=$1
intel=$2
version=$3
root=$(cd "$(dirname "$0")/.." && pwd)
dist="$root/dist"
name="aurora-mpv-desktop-$version-macos-universal"

stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
mkdir "$stage/arm64" "$stage/x86_64"
tar -xJf "$arm" -C "$stage/arm64"
tar -xJf "$intel" -C "$stage/x86_64"
arm_dir=$(echo "$stage"/arm64/*/)
intel_dir=$(echo "$stage"/x86_64/*/)

cp -R "$arm_dir" "$stage/$name"
out="$stage/$name"
for f in "$out"/lib/*.[0-9]*.dylib; do
	base=$(basename "$f")
	[ -L "$f" ] && continue
	[ -f "$intel_dir/lib/$base" ] || { echo "$base missing from the x86_64 kit" >&2; exit 1; }
	lipo -create "$arm_dir/lib/$base" "$intel_dir/lib/$base" -output "$f"
	codesign --force --sign - "$f"
done
sed -i '' -E "s/^(AuroraMPVKit-Desktop .*) \\(macos-arm64\\)$/\\1 (macos-universal)/" "$out/BUILDINFO.txt"

mkdir -p "$dist"
XZ_OPT=-T0 tar -C "$stage" -cJf "$dist/$name.tar.xz" "$name"
echo "Wrote $dist/$name.tar.xz"
