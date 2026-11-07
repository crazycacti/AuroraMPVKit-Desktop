#!/bin/bash
set -euo pipefail
export LC_ALL=C

usage () {
	cat >&2 <<-EOF
	usage: $0 <dir | .tar.* | .zip | .dmg> [mpv-config.h ffmpeg-config.h]

	Checks every Mach-O, PE and ELF binary under the input: FFmpeg license
	strings and configure line, mpv's feature list, linked libraries, known
	GPL symbols, and file names of GPL libraries and GPL-only Qt modules.
	EOF
	exit 2
}

[ $# -eq 1 ] || [ $# -eq 3 ] || usage
input=$1

failures=0
fail () {
	echo "FAIL: $*"
	failures=$((failures + 1))
}

workdir=
mountpoint=
cleanup () {
	if [ -n "$mountpoint" ]; then hdiutil detach -quiet "$mountpoint" || true; fi
	if [ -n "$workdir" ]; then rm -rf -- "$workdir"; fi
}
trap cleanup EXIT

if [ -d "$input" ]; then
	root=$input
elif [ -f "$input" ]; then
	workdir=$(mktemp -d)
	case "$input" in
		*.dmg)
			mountpoint="$workdir/mnt"
			mkdir "$mountpoint"
			hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mountpoint" "$input"
			root=$mountpoint
			;;
		*.zip) unzip -q "$input" -d "$workdir/x"; root="$workdir/x" ;;
		*.tar|*.tar.*|*.tgz) mkdir "$workdir/x"; tar -xf "$input" -C "$workdir/x"; root="$workdir/x" ;;
		*) echo "unsupported input: $input" >&2; exit 2 ;;
	esac
else
	echo "not found: $input" >&2
	exit 2
fi

gpl_ffmpeg_flags='--enable-(gpl|nonfree|libx264|libx265|libxvid|librubberband|libsmbclient|libvidstab|frei0r|avisynth|libcdio|libdvdnav|libdvdread|libdavs2|libxavs2?|libfdk-aac|decklink|libcodec2|libzvbi|postproc)( |$)'
forbidden_mpv_features='^(gpl|x11|dvbin|dvdnav|dvda|cdda|jack|oss-audio|caca|direct3d|vdpau|rubberband|vapoursynth|libcurl)$'
required_mpv_features=(ffmpeg libass libplacebo luajit javascript uchardet lcms2 zlib)
forbidden_names='(x264|x265|postproc|rubberband|vidstab|frei0r|cdio|dvdnav|dvdread|xvid|davs2|xavs|smbclient|fdk-aac|vapoursynth|Qt6?VirtualKeyboard|Qt6?HunspellInputMethod|Qt6?QuickTimeline|Qt6?QmlDesignSupport|Qt6?Quick3D|Qt6?Charts|Qt6?Graphs|Qt6?DataVisualization|Qt6?Lottie|Qt6?Bodymovin|Qt6?HttpServer|Qt6?NetworkAuth|Qt6?CanvasPainter|Qt6?Grpc|Qt6?QmlCompiler|qtvirtualkeyboard|hunspellinputmethod|QtQuick/VirtualKeyboard|QtQuick/Timeline|QtQuick3D|QtCharts|QtGraphs|QtDataVisualization|labs/lottieqt)'
gpl_symbols='(x264_encoder_open|x265_encoder_open|x265_api_get|rubberband_new|pp_postprocess|vsMotionDetectInit|f0r_init|cdio_open|dvdnav_open|DVDOpen|xvid_global|davs2_decoder_open|smbc_init|aacEncOpen|getVapourSynthAPI)'

echo "== input: $input"

matches=$(cd "$root" && find . -mindepth 1 | sed 's|^\./||' | grep -i -E "$forbidden_names" || true)
if [ -n "$matches" ]; then
	while IFS= read -r m; do fail "forbidden file: $m"; done < <(sed -E 's#^(.*[.](framework|app))/.*$#\1#' <<<"$matches" | sort -u)
fi

binaries=()
macho=0 pe=0 elf=0
while IFS= read -r -d '' f; do
	[ -L "$f" ] && continue
	kind=$(file -b "$f" 2>/dev/null || true)
	case "$kind" in
		Mach-O*) macho=$((macho + 1)); binaries+=("$f") ;;
		PE32*) pe=$((pe + 1)); binaries+=("$f") ;;
		ELF*) elf=$((elf + 1)); binaries+=("$f") ;;
	esac
done < <(find "$root" -type f \( -name '*.dylib' -o -name '*.so' -o -name '*.so.*' -o -name '*.dll' -o -name '*.exe' -o -perm -u+x \) -print0)
echo "binaries: ${#binaries[@]} (Mach-O $macho, PE $pe, ELF $elf)"
[ ${#binaries[@]} -gt 0 ] || fail "no Mach-O, PE or ELF binaries found"

linked_libs () {
	case "$(file -b "$1")" in
		Mach-O\ universal*) otool -L "$1" | grep -E '^[[:space:]]' | awk '{print $1}' | sort -u ;;
		Mach-O*) otool -L "$1" | tail -n +2 | awk '{print $1}' ;;
		PE32*) objdump -p "$1" | sed -n -E 's/^[[:space:]]*DLL Name: (.*)$/\1/p' ;;
		ELF*) objdump -p "$1" | sed -n -E 's/^[[:space:]]*NEEDED[[:space:]]+(.*)$/\1/p' ;;
	esac
}

host_paths='^(/opt/homebrew|/usr/local|/opt/local|/ucrt64|/mingw64|[A-Za-z]:[/\\]msys64)'
for f in "${binaries[@]}"; do
	rel=${f#"$root"/}
	deps=$(linked_libs "$f" || true)
	bad=$(grep -E -i "$forbidden_names" <<<"$deps" || true)
	[ -z "$bad" ] || fail "$rel links $(tr '\n' ' ' <<<"$bad")"
	if [[ "$(file -b "$f")" == Mach-O* ]]; then
		leak=$(grep -E "$host_paths" <<<"$deps" || true)
		[ -z "$leak" ] || fail "$rel loads a library from the build host: $(tr '\n' ' ' <<<"$leak")"
		rpaths=$(otool -l "$f" | awk '$1 == "path" && prev ~ /LC_RPATH/ { print $2 } { if ($1 == "cmd") prev = $2 }' | grep -v -E '^(@|/usr/lib|/System/)' || true)
		[ -z "$rpaths" ] || fail "$rel searches libraries outside the bundle: $(tr '\n' ' ' <<<"$rpaths")"
	fi
	sym=$(strings -a "$f" | grep -o -E "\\b$gpl_symbols\\b" | sort -u || true)
	[ -z "$sym" ] || fail "$rel contains GPL library symbols: $(tr '\n' ' ' <<<"$sym")"
done

find_lib () {
	local base=$1
	local f
	for f in "${binaries[@]}"; do
		case "$(basename "$f")" in
			"$base".dylib|"$base".[0-9]*.dylib|"$base".so|"$base".so.[0-9]*|"${base#lib}"-[0-9]*.dll|"$base"-[0-9]*.dll)
				echo "$f"
				;;
		esac
	done
}

ffmpeg_libs=(libavutil libavcodec libavformat libavfilter libswscale libswresample libavdevice)
found_ffmpeg=0
for lib in "${ffmpeg_libs[@]}"; do
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		found_ffmpeg=$((found_ffmpeg + 1))
		license=$(strings -a "$f" | sed -n -E "s/^$lib license: (.*)$/\1/p" | sort -u)
		if [ "$license" != "LGPL version 3 or later" ]; then
			fail "${f#"$root"/}: license string is '${license:-none}', expected 'LGPL version 3 or later'"
		fi
	done < <(find_lib "$lib")
done

while IFS= read -r f; do
	[ -n "$f" ] || continue
	rel=${f#"$root"/}
	echo "== $rel"
	echo "avutil_license(): $(strings -a "$f" | sed -n -E 's/^libavutil license: (.*)$/\1/p' | head -n1)"
	config=$(strings -a "$f" | grep -m1 -e '--prefix=' || true)
	if [ -z "$config" ]; then
		fail "$rel: FFmpeg configuration string not found"
		continue
	fi
	echo "avutil_configuration(): $config"
	[[ " $config " == *" --enable-version3 "* ]] || fail "$rel: FFmpeg not configured with --enable-version3"
	if grep -q -E -e "$gpl_ffmpeg_flags" <<<"$config"; then
		fail "$rel: FFmpeg configured with GPL or nonfree flags: $(grep -o -E -e "$gpl_ffmpeg_flags" <<<"$config" | tr '\n' ' ')"
	fi
done < <(find_lib libavutil)

found_mpv=0
while IFS= read -r f; do
	[ -n "$f" ] || continue
	found_mpv=$((found_mpv + 1))
	rel=${f#"$root"/}
	echo "== $rel"
	mpv_version=$(strings -a "$f" | grep -m1 -o -E 'mpv v[0-9][^ ]*' || true)
	echo "mpv: ${mpv_version:-version string not found}"
	features=$(strings -a "$f" | sed -n -E 's/^List of enabled features: (.*)$/\1/p' | head -n1)
	if [ -z "$features" ]; then
		fail "$rel: mpv feature list not found"
		continue
	fi
	echo "mpv features: $features"
	for feature in $features; do
		[[ "$feature" =~ $forbidden_mpv_features ]] && fail "$rel: mpv built with feature '$feature'"
	done
	for feature in "${required_mpv_features[@]}"; do
		[[ " $features " == *" $feature "* ]] || fail "$rel: mpv built without feature '$feature'"
	done
	echo "mpv links: $(linked_libs "$f" | tr '\n' ' ')"
done < <(find_lib libmpv)

if [ $found_mpv -eq 0 ] && [ $found_ffmpeg -eq 0 ]; then
	echo "no libmpv or FFmpeg libraries in this input; checked names, links and symbols only"
elif [ $found_mpv -eq 0 ] || [ $found_ffmpeg -lt ${#ffmpeg_libs[@]} ]; then
	fail "found libmpv x$found_mpv and $found_ffmpeg of ${#ffmpeg_libs[@]} FFmpeg libraries"
fi

if [ $# -eq 3 ]; then
	mpv_config=$2
	ffmpeg_config=$3
	echo "== build configs"
	grep -q -x '#define HAVE_GPL 0' "$mpv_config" || fail "$mpv_config: HAVE_GPL is not 0"
	grep -q -x '#define CONFIG_GPL 0' "$ffmpeg_config" || fail "$ffmpeg_config: CONFIG_GPL is not 0"
	grep -q -x '#define CONFIG_NONFREE 0' "$ffmpeg_config" || fail "$ffmpeg_config: CONFIG_NONFREE is not 0"
	grep -q -x '#define CONFIG_VERSION3 1' "$ffmpeg_config" || fail "$ffmpeg_config: CONFIG_VERSION3 is not 1"
	grep -E '#define HAVE_GPL ' "$mpv_config"
	grep -E '#define CONFIG_(GPL|NONFREE|VERSION3) ' "$ffmpeg_config"
fi

if [ $failures -ne 0 ]; then
	echo "License check failed with $failures problem(s)."
	exit 1
fi
echo "License check passed."
