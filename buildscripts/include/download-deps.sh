#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
. ./include/depinfo.sh

sha256 () {
	if command -v sha256sum >/dev/null; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

fetch_tarball () {
	local file="$1.download"
	curl -fsSL --retry 3 "$2" -o "$file"
	local got
	got=$(sha256 "$file")
	if [ "$got" != "$3" ]; then
		echo >&2 "Checksum mismatch for $2: expected $3, got $got"
		rm -f "$file"
		exit 1
	fi
	mkdir "$1"
	tar "-x$4" -f "$file" -C "$1" --strip-components=1
	rm "$file"
}

fetch_git () {
	local dir=$1 url=$2 tag=$3 commit=$4
	shift 4
	git -c advice.detachedHead=false clone -q --depth 1 -b "$tag" "$@" "$url" "$dir"
	local got
	got=$(git -C "$dir" rev-parse HEAD)
	if [ "$got" != "$commit" ]; then
		echo >&2 "Tag $tag of $url resolved to $got, expected $commit"
		rm -rf "$dir"
		exit 1
	fi
}

fetch_commit () {
	local dir=$1 url=$2 commit=$3
	git init -q "$dir"
	git -C "$dir" fetch -q --depth 1 "$url" "$commit"
	git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
	local got
	got=$(git -C "$dir" rev-parse HEAD)
	if [ "$got" != "$commit" ]; then
		echo >&2 "$url fetched $got, expected $commit"
		rm -rf "$dir"
		exit 1
	fi
}

fetch_angle_headers () {
	local dir=$1 entry path sum got
	mkdir -p "$dir.download"
	for entry in "${angle_files[@]}"; do
		path=${entry% *}
		sum=${entry#* }
		mkdir -p "$dir.download/$(dirname "$path")"
		curl -fsSL --retry 3 "https://raw.githubusercontent.com/google/angle/$c_angle/$path" -o "$dir.download/$path"
		got=$(sha256 "$dir.download/$path")
		if [ "$got" != "$sum" ]; then
			echo >&2 "Checksum mismatch for ANGLE $path: expected $sum, got $got"
			rm -rf "$dir.download"
			exit 1
		fi
	done
	mv "$dir.download" "$dir"
}

mkdir -p deps && cd deps

[ -d zlib ] || fetch_tarball zlib \
	"https://github.com/madler/zlib/releases/download/v$v_zlib/zlib-$v_zlib.tar.xz" \
	$s_zlib J
[ -d libiconv ] || fetch_tarball libiconv \
	"https://ftp.gnu.org/pub/gnu/libiconv/libiconv-$v_libiconv.tar.gz" \
	$s_libiconv z
[ -d mbedtls ] || fetch_tarball mbedtls \
	"https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$v_mbedtls/mbedtls-$v_mbedtls.tar.bz2" \
	$s_mbedtls j
[ -d dav1d ] || fetch_git dav1d https://github.com/videolan/dav1d $v_dav1d $c_dav1d
[ -d ffmpeg ] || fetch_git ffmpeg https://github.com/FFmpeg/FFmpeg $v_ffmpeg $c_ffmpeg
[ -d nv-codec-headers ] || fetch_git nv-codec-headers https://github.com/FFmpeg/nv-codec-headers $v_nvcodec $c_nvcodec
[ -d freetype2 ] || fetch_git freetype2 https://gitlab.freedesktop.org/freetype/freetype.git \
	"VER-${v_freetype//./-}" $c_freetype --recurse-submodules
[ -d fribidi ] || fetch_tarball fribidi \
	"https://github.com/fribidi/fribidi/releases/download/v$v_fribidi/fribidi-$v_fribidi.tar.xz" \
	$s_fribidi J
[ -d harfbuzz ] || fetch_tarball harfbuzz \
	"https://github.com/harfbuzz/harfbuzz/releases/download/$v_harfbuzz/harfbuzz-$v_harfbuzz.tar.xz" \
	$s_harfbuzz J
[ -d unibreak ] || fetch_tarball unibreak \
	"https://github.com/adah1972/libunibreak/releases/download/libunibreak_${v_unibreak//./_}/libunibreak-$v_unibreak.tar.gz" \
	$s_unibreak z
[ -d libass ] || fetch_git libass https://github.com/libass/libass $v_libass $c_libass
[ -d lcms2 ] || fetch_git lcms2 https://github.com/mm2/Little-CMS "lcms$v_lcms2" $c_lcms2
[ -d libplacebo ] || fetch_git libplacebo https://github.com/haasn/libplacebo $v_libplacebo $c_libplacebo \
	--recurse-submodules --shallow-submodules
[ -d uchardet ] || fetch_git uchardet https://gitlab.freedesktop.org/uchardet/uchardet.git "v$v_uchardet" $c_uchardet
[ -d luajit ] || fetch_commit luajit https://github.com/LuaJIT/LuaJIT $c_luajit
[ -d mujs ] || fetch_git mujs https://github.com/ccxvii/mujs $v_mujs $c_mujs
[ -d libdrm ] || fetch_git libdrm https://gitlab.freedesktop.org/mesa/drm.git "libdrm-$v_libdrm" $c_libdrm
[ -d libdisplay-info ] || fetch_git libdisplay-info https://gitlab.freedesktop.org/emersion/libdisplay-info.git \
	$v_libdisplay_info $c_libdisplay_info
[ -d angle-headers ] || fetch_angle_headers angle-headers
[ -d mpv ] || fetch_git mpv https://github.com/mpv-player/mpv $v_mpv $c_mpv

echo "All sources present and verified."
