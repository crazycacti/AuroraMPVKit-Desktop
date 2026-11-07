#!/bin/bash
set -euo pipefail

usage () {
	echo "usage: $0 <macos-arm64|macos-x86_64|linux-x86_64|windows-x86_64> <version>" >&2
	exit 2
}
[ $# -eq 2 ] || usage
target=$1
version=$2

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/buildscripts/include/depinfo.sh"
prefixes="$root/buildscripts/prefix"
deps="$root/buildscripts/deps"
dist="$root/dist"
name="aurora-mpv-desktop-$version-$target"

stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
out="$stage/$name"
mkdir -p "$out/include" "$out/lib/pkgconfig" "$out/licenses"

ffmpeg_libs=(avutil avcodec avformat avfilter swscale swresample avdevice)

source_prefix () {
	local p="$prefixes/$1"
	[ -f "$p/include/mpv/client.h" ] || { echo "no mpv build in $p; run buildscripts/build.sh first" >&2; exit 1; }
	echo "$p"
}

macos_libs () {
	local p=$1
	local lib
	for lib in mpv "${ffmpeg_libs[@]}"; do
		local f
		f=$(ls "$p"/lib/lib$lib.[0-9]*.dylib | awk '{ print length, $0 }' | sort -n | head -n1 | cut -d' ' -f2-)
		[ -n "$f" ] || { echo "lib$lib missing in $p" >&2; exit 1; }
		basename "$f"
	done
}

macos_relink () {
	local file=$1 p=$2 base=$3
	install_name_tool -id "@rpath/$base" "$file"
	local rpath
	while IFS= read -r rpath; do
		case "$rpath" in
			/usr/lib/swift) ;;
			*) install_name_tool -delete_rpath "$rpath" "$file" ;;
		esac
	done < <(otool -l "$file" | awk '$1 == "path" && prev ~ /LC_RPATH/ { print $2 } { if ($1 == "cmd") prev = $2 }')
	local dep
	while IFS= read -r dep; do
		case "$dep" in
			"$p"/lib/*) install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$file" ;;
		esac
	done < <(otool -L "$file" | tail -n +2 | awk '{print $1}')
}

package_macos () {
	local p
	p=$(source_prefix "$target")
	cp -R "$p/include/mpv" "$out/include/"
	local base
	for base in $(macos_libs "$p"); do
		cp -L "$p/lib/$base" "$out/lib/$base"
		chmod u+w "$out/lib/$base"
		macos_relink "$out/lib/$base" "$p" "$base"
		codesign --force --sign - "$out/lib/$base"
		ln -sf "$base" "$out/lib/${base%%.*}.dylib"
	done
}

package_linux () {
	local p
	p=$(source_prefix "$target")
	cp -R "$p/include/mpv" "$out/include/"
	local lib
	for lib in mpv "${ffmpeg_libs[@]}"; do
		local soname
		soname=$(objdump -p "$p/lib/lib$lib.so" | sed -n -E 's/^[[:space:]]*SONAME[[:space:]]+(.*)$/\1/p')
		[ -n "$soname" ] || { echo "no SONAME for lib$lib.so" >&2; exit 1; }
		cp -L "$p/lib/$soname" "$out/lib/$soname"
		chmod u+w "$out/lib/$soname"
		patchelf --set-rpath '$ORIGIN' "$out/lib/$soname"
		ln -sf "$soname" "$out/lib/lib$lib.so"
	done
}

package_windows () {
	local p
	p=$(source_prefix "$target")
	cp -R "$p/include/mpv" "$out/include/"
	mkdir -p "$out/bin"
	local dll
	for dll in "$p"/bin/libmpv-2.dll "$p"/bin/av*-[0-9]*.dll "$p"/bin/sw*-[0-9]*.dll; do
		cp "$dll" "$out/bin/"
	done
	cp "$p/lib/libmpv.dll.a" "$out/lib/libmpv.dll.a"
	cp "$p/lib/libmpv.dll.a" "$out/lib/mpv.lib"
	local missing=0
	for dll in "$out"/bin/*.dll; do
		local dep
		while IFS= read -r dep; do
			[ -f "$out/bin/$dep" ] && continue
			case "$(tr "[:upper:]" "[:lower:]" <<<"$dep")" in
				lib*.dll|zlib1.dll)
					echo "$(basename "$dll") needs $dep, which is not in the kit" >&2
					missing=1
					;;
			esac
		done < <(objdump -p "$dll" | sed -n -E 's/^[[:space:]]*DLL Name: (.*)$/\1/p')
	done
	[ $missing -eq 0 ] || exit 1
}

case $target in
	macos-*) package_macos ;;
	linux-x86_64) package_linux ;;
	windows-x86_64) package_windows ;;
	*) usage ;;
esac

mpv_api=$(sed -n -E 's/^Version: (.*)$/\1/p' "$prefixes/$target/lib/pkgconfig/mpv.pc")
cat >"$out/lib/pkgconfig/mpv.pc" <<EOF
prefix=\${pcfiledir}/../..
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: mpv
Description: mpv media player client library (Aurora LGPL build)
Version: $mpv_api
Libs: -L\${libdir} -lmpv
Cflags: -I\${includedir}
EOF

license () {
	cp "$deps/$1" "$out/licenses/$2"
}
license mpv/LICENSE.LGPL mpv-LGPL-2.1.txt
license mpv/Copyright mpv-Copyright.txt
license ffmpeg/COPYING.LGPLv3 FFmpeg-LGPL-3.0.txt
license ffmpeg/COPYING.GPLv3 FFmpeg-GPL-3.0.txt
license libplacebo/LICENSE libplacebo-LGPL-2.1.txt
license dav1d/COPYING dav1d-BSD-2-Clause.txt
license libass/COPYING libass-ISC.txt
license freetype2/LICENSE.TXT freetype-LICENSE.txt
license freetype2/docs/FTL.TXT freetype-FTL.txt
license harfbuzz/COPYING harfbuzz-MIT.txt
license fribidi/COPYING fribidi-LGPL-2.1.txt
license unibreak/LICENCE libunibreak-Zlib.txt
license lcms2/LICENSE lcms2-MIT.txt
license uchardet/COPYING uchardet-MPL-1.1.txt
license luajit/COPYRIGHT LuaJIT-MIT.txt
license mujs/COPYING MuJS-ISC.txt
nv_license () {
	sed -n '2,25p' "$deps/nv-codec-headers/include/ffnvcodec/dynlink_loader.h" | sed -E 's/^ \* ?//' >"$out/licenses/nv-codec-headers-MIT.txt"
}
case $target in
	linux-*)
		license mbedtls/LICENSE mbedtls-LICENSE.txt
		license libdisplay-info/LICENSE libdisplay-info-MIT.txt
		awk '/Copyright 1999/{f=1} f{print} f&&/\*\//{exit}' "$deps/libdrm/xf86drm.h" | sed -E 's/^ ?\* ?//; s#\*/##' >"$out/licenses/libdrm-MIT.txt"
		cp /usr/share/doc/hwdata/copyright "$out/licenses/hwdata-copyright.txt"
		nv_license
		;;
	windows-*)
		license angle-headers/LICENSE ANGLE-BSD-3-Clause.txt
		nv_license
		license zlib/LICENSE zlib-LICENSE.txt
		license libiconv/COPYING.LIB libiconv-LGPL-2.1.txt
		;;
esac

cp "$root/NOTICES" "$out/NOTICES.txt"
cp "$root/LICENSE" "$out/LICENSE.txt"
cp "$root/scripts/check-license.sh" "$out/check-license.sh"
{
	echo "AuroraMPVKit-Desktop $version ($target)"
	echo "revision: $(git -C "$root" rev-parse HEAD 2>/dev/null || cat "$root/REVISION")"
	echo "mpv $v_mpv, FFmpeg $v_ffmpeg, libplacebo $v_libplacebo"
} >"$out/BUILDINFO.txt"

mkdir -p "$dist"
XZ_OPT=-T0 tar -C "$stage" -cJf "$dist/$name.tar.xz" "$name"
echo "Wrote $dist/$name.tar.xz"
