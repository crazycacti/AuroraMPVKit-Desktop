#!/bin/bash
set -euo pipefail

if [ $# -ne 1 ]; then
	echo "usage: $0 <version>" >&2
	exit 2
fi
version=$1
root=$(cd "$(dirname "$0")/.." && pwd)
deps="$root/buildscripts/deps"
dist="$root/dist"
name="aurora-mpv-desktop-$version-sources"

for dep in zlib libiconv mbedtls dav1d ffmpeg nv-codec-headers freetype2 fribidi harfbuzz unibreak libass lcms2 libplacebo uchardet luajit mujs libdrm libdisplay-info angle-headers mpv; do
	if [ ! -d "$deps/$dep" ]; then
		echo "missing $deps/$dep; run buildscripts/include/download-deps.sh first" >&2
		exit 1
	fi
done

stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$stage/$name/buildscripts/deps"

git -C "$root" archive --format=tar HEAD | tar -x -C "$stage/$name"
git -C "$root" rev-parse HEAD >"$stage/$name/REVISION"
tar -C "$deps" --exclude='.git' -cf - . | tar -x -C "$stage/$name/buildscripts/deps"

mkdir -p "$dist"
XZ_OPT=-T0 tar -C "$stage" -cJf "$dist/$name.tar.xz" "$name"
echo "Wrote $dist/$name.tar.xz"
