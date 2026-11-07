#!/bin/bash
set -euo pipefail

usage () {
	echo "usage: $0 <macos|linux|windows> [dependency ...]" >&2
	exit 2
}

[ $# -ge 1 ] || usage
os=$1
shift

here=$(cd "$(dirname "$0")" && pwd)
. "$here/include/depinfo.sh"

case "$(uname -m)" in
	arm64|aarch64) arch=arm64 ;;
	x86_64|amd64) arch=x86_64 ;;
	*) echo "unsupported host architecture $(uname -m)" >&2; exit 1 ;;
esac

case $os in
	macos) [ "$(uname -s)" = Darwin ] || { echo "macos builds run on macOS" >&2; exit 1; } ;;
	linux) [ "$(uname -s)" = Linux ] || { echo "linux builds run on Linux" >&2; exit 1; } ;;
	windows)
		[[ "$(uname -s)" == MINGW64* ]] || { echo "windows builds run in an MSYS2 UCRT64 shell" >&2; exit 1; }
		[ "$arch" = x86_64 ] || { echo "windows builds target x86_64 only" >&2; exit 1; }
		;;
	*) usage ;;
esac

target=$os-$arch
deps="$here/deps"
build_root="$here/build/$target"
prefix="$here/prefix/$target"
# MinGW gcc does not understand MSYS paths such as /d/a/..., which reach it through CFLAGS.
[ "$os" = windows ] && prefix=$(cygpath -m "$prefix")
mkdir -p "$build_root" "$prefix/lib/pkgconfig" "$prefix/include"

export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
if command -v nproc >/dev/null; then jobs=$(nproc); else jobs=$(sysctl -n hw.ncpu); fi

cflags="-O2"
ldflags=""
case $os in
	macos)
		export MACOSX_DEPLOYMENT_TARGET=13.0
		export CC=clang CXX=clang++
		cflags="$cflags -arch $arch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
		ldflags="-arch $arch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
		;;
	linux)
		export CC=gcc CXX=g++
		cflags="$cflags -fPIC"
		system_pc=$(pkg-config --variable pc_path pkg-config 2>/dev/null || true)
		[ -n "$system_pc" ] || system_pc=/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig
		export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig:$system_pc"
		;;
	windows)
		export CC=gcc CXX=g++
		ldflags="-static-libgcc -static-libstdc++"
		;;
esac
export CFLAGS="$cflags -I$prefix/include"
export CXXFLAGS="$cflags -I$prefix/include"
export LDFLAGS="$ldflags -L$prefix/lib"

meson_common=(
	--prefix "$prefix" --libdir lib --buildtype release
	--default-library static -Db_staticpic=true --wrap-mode nodownload
)
cmake_common=(
	-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix"
	-DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_PREFIX_PATH="$prefix"
	-DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
)
[ "$os" = macos ] && cmake_common+=(-DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET")

srcdir () {
	local d="$deps/$1"
	[ -d "$d" ] || { echo "missing $d; run buildscripts/include/download-deps.sh" >&2; exit 1; }
	echo "$d"
}

fresh_build_dir () {
	rm -rf "$build_root/$1"
	mkdir -p "$build_root/$1"
	echo "$build_root/$1"
}

copy_tree () {
	local b
	b=$(fresh_build_dir "$1")
	tar -C "$(srcdir "$1")" --exclude=.git -cf - . | tar -C "$b" -xf -
	echo "$b"
}

meson_build () {
	local name=$1
	shift
	local b
	b=$(fresh_build_dir "$name")
	meson setup "$b" "$(srcdir "$name")" "${meson_common[@]}" "$@"
	meson compile -C "$b"
	meson install -C "$b" --no-rebuild
}

build_zlib () {
	local b
	b=$(copy_tree zlib)
	make -C "$b" -f win32/Makefile.gcc -j"$jobs" libz.a CFLAGS="$CFLAGS"
	cp "$b/zlib.h" "$b/zconf.h" "$prefix/include/"
	cp "$b/libz.a" "$prefix/lib/"
	cat >"$prefix/lib/pkgconfig/zlib.pc" <<-PC
	prefix=$prefix
	libdir=\${prefix}/lib
	includedir=\${prefix}/include
	Name: zlib
	Description: zlib compression library
	Version: $v_zlib
	Cflags: -I\${includedir}
	Libs: -L\${libdir} -lz
	PC
}

build_libiconv () {
	local b
	b=$(copy_tree libiconv)
	(cd "$b" && ./configure --prefix="$prefix" --disable-shared --enable-static --disable-nls && make -j"$jobs" && make install-lib)
}

build_mbedtls () {
	local b
	b=$(fresh_build_dir mbedtls)
	cmake -S "$(srcdir mbedtls)" -B "$b" "${cmake_common[@]}" \
		-DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF -DMBEDTLS_FATAL_WARNINGS=OFF
	cmake --build "$b"
	cmake --install "$b"
}

build_dav1d () {
	meson_build dav1d -Denable_tools=false -Denable_tests=false -Denable_examples=false
}

build_nv-codec-headers () {
	local b
	b=$(copy_tree nv-codec-headers)
	make -C "$b" PREFIX="$prefix" install
}

build_ffmpeg () {
	local b
	b=$(fresh_build_dir ffmpeg)
	local args=(
		--prefix="$prefix" --pkg-config=pkg-config --pkg-config-flags=--static
		--extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS"
		--enable-shared --disable-static --enable-version3
		--disable-autodetect --disable-programs --disable-doc --disable-debug
		--disable-encoders --enable-encoder=mjpeg,png
		--disable-muxers --enable-muxer=mov,matroska,mpegts
		--disable-devices
		--enable-libdav1d --enable-zlib
	)
	case $os in
		macos)
			args+=(--cc=clang --enable-videotoolbox --enable-audiotoolbox --enable-securetransport)
			;;
		linux)
			args+=(--enable-vaapi --enable-libdrm --enable-ffnvcodec --enable-nvdec --enable-cuvid
				--enable-mbedtls --enable-pthreads)
			;;
		windows)
			args+=(--enable-d3d11va --enable-dxva2 --enable-ffnvcodec --enable-nvdec --enable-cuvid
				--enable-schannel --enable-w32threads)
			;;
	esac
	(cd "$b" && "$(srcdir ffmpeg)/configure" "${args[@]}") || { tail -n 60 "$b/ffbuild/config.log"; exit 1; }
	make -C "$b" -j"$jobs"
	make -C "$b" install
}

build_freetype2 () {
	meson_build freetype2 -Dharfbuzz=disabled -Dpng=disabled -Dbzip2=disabled -Dbrotli=disabled \
		-Dzlib=disabled -Dtests=disabled
}

build_fribidi () {
	meson_build fribidi -Ddocs=false -Dtests=false -Dbin=false
}

build_harfbuzz () {
	meson_build harfbuzz -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
		-Dicu=disabled -Dtests=disabled -Ddocs=disabled -Dutilities=disabled -Dintrospection=disabled \
		-Dchafa=disabled -Dpng=disabled -Dzlib=disabled -Dcoretext=disabled -Ddirectwrite=disabled \
		-Dgdi=disabled -Dgraphite2=disabled -Dfontations=disabled -Draster=disabled -Dvector=disabled \
		-Dsubset=disabled
}

build_unibreak () {
	local b
	b=$(copy_tree unibreak)
	(cd "$b" && ./configure --prefix="$prefix" --disable-shared --enable-static && make -j"$jobs" && make install)
}

build_libass () {
	local args=(-Dlibunibreak=enabled -Dtest=disabled -Dcompare=disabled -Dprofile=disabled -Dfuzz=disabled)
	case $os in
		macos) args+=(-Dcoretext=enabled -Dfontconfig=disabled -Ddirectwrite=disabled) ;;
		linux) args+=(-Dfontconfig=enabled -Dcoretext=disabled -Ddirectwrite=disabled) ;;
		windows) args+=(-Ddirectwrite=enabled -Dfontconfig=disabled -Dcoretext=disabled) ;;
	esac
	meson_build libass "${args[@]}"
}

build_lcms2 () {
	meson_build lcms2 -Dutils=false -Dtests=disabled -Djpeg=disabled -Dtiff=disabled -Dfastfloat=false -Dthreaded=false
}

build_libplacebo () {
	meson_build libplacebo -Dvulkan=disabled -Dopengl=enabled -Dd3d11=disabled -Dglslang=disabled \
		-Dshaderc=disabled -Dlcms=enabled -Ddovi=enabled -Dlibdovi=disabled -Dxxhash=disabled \
		-Dunwind=disabled -Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false
}

build_uchardet () {
	local b
	b=$(fresh_build_dir uchardet)
	cmake -S "$(srcdir uchardet)" -B "$b" "${cmake_common[@]}" -DBUILD_BINARY=OFF -DBUILD_STATIC=ON \
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5
	cmake --build "$b"
	cmake --install "$b"
}

build_luajit () {
	local b
	b=$(copy_tree luajit)
	local args=(PREFIX="$prefix" BUILDMODE=static XCFLAGS=-DLUAJIT_ENABLE_LUA52COMPAT)
	case $os in
		macos) args+=(TARGET_CFLAGS="-arch $arch" TARGET_LDFLAGS="-arch $arch") ;;
		windows) args+=(TARGET_SYS=Windows) ;;
	esac
	# LuaJIT reads its version from git, which the copied tree lacks.
	echo "$c_luajit" >"$b/.relver"
	make -C "$b" -j"$jobs" amalg "${args[@]}"
	make -C "$b" install "${args[@]}"
}

build_mujs () {
	local b
	b=$(copy_tree mujs)
	local args=(prefix="$prefix" VERSION="$v_mujs" CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS")
	make -C "$b" -j"$jobs" build/release/libmujs.a build/release/mujs.pc "${args[@]}"
	install -d "$prefix/include" "$prefix/lib/pkgconfig"
	install -m 644 "$b/mujs.h" "$prefix/include/"
	install -m 644 "$b/build/release/libmujs.a" "$prefix/lib/"
	install -m 644 "$b/build/release/mujs.pc" "$prefix/lib/pkgconfig/"
}

build_libdrm () {
	meson_build libdrm -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled \
		-Dvmwgfx=disabled -Domap=disabled -Dexynos=disabled -Dfreedreno=disabled -Dtegra=disabled \
		-Dvc4=disabled -Detnaviv=disabled -Dcairo-tests=disabled -Dman-pages=disabled \
		-Dvalgrind=disabled -Dtests=false -Dinstall-test-programs=false
}

build_libdisplay-info () {
	meson_build libdisplay-info
}

build_angle-headers () {
	cp -R "$(srcdir angle-headers)/include/." "$prefix/include/"
}

build_mpv () {
	local args=(
		--default-library shared
		-Dgpl=false -Dlibmpv=true -Dcplayer=false -Dtests=false -Dfuzzers=false -Dbuild-date=false
		-Dlibcurl=disabled -Drubberband=disabled -Dvapoursynth=disabled -Dzimg=disabled
		-Ddvbin=disabled -Ddvdnav=disabled -Dcdda=disabled -Djack=disabled -Doss-audio=disabled
		-Dlibarchive=disabled -Dlibbluray=disabled -Djpeg=disabled -Dopenal=disabled
		-Dsdl2-audio=disabled -Dsdl2-video=disabled -Dsdl2-gamepad=disabled
		-Dlua=luajit -Djavascript=enabled -Duchardet=enabled -Dlcms2=enabled -Dzlib=enabled
		-Dvulkan=disabled -Dshaderc=disabled -Dspirv-cross=disabled -Dcaca=disabled -Dsixel=disabled
		-Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled
	)
	case $os in
		macos)
			args+=(-Dcocoa=enabled -Dgl-cocoa=enabled -Dvideotoolbox-gl=enabled
				-Dcoreaudio=enabled -Daudiounit=disabled -Davfoundation=enabled
				-Dswift-build=enabled -Dmacos-cocoa-cb=disabled -Dmacos-media-player=disabled
				-Dmacos-touchbar=disabled)
			;;
		linux)
			args+=(-Dvaapi=enabled -Dvaapi-drm=enabled -Ddrm=enabled -Degl=enabled -Dgbm=disabled
				-Degl-drm=disabled -Dwayland=disabled -Dx11=disabled
				-Dcuda-hwaccel=enabled -Dcuda-interop=enabled
				-Dpulse=enabled -Dalsa=enabled -Dpipewire=disabled -Dsndio=disabled)
			;;
		windows)
			args+=(-Dgl-win32=enabled -Dgl-dxinterop=enabled -Dd3d-hwaccel=enabled -Dd3d9-hwaccel=enabled
				-Dgl-dxinterop-d3d9=enabled -Dd3d11=disabled -Ddirect3d=disabled
				-Degl-angle=enabled -Degl-angle-lib=disabled -Degl-angle-win32=enabled
				-Dcuda-hwaccel=enabled -Dcuda-interop=enabled -Dwasapi=enabled -Diconv=enabled
				-Dwin32-smtc=disabled)
			;;
	esac
	local src b
	src=$(copy_tree mpv)
	local patch
	for patch in "$here"/patches/mpv/*.patch; do
		[ -f "$patch" ] || continue
		echo "applying $(basename "$patch")"
		patch -d "$src" -p1 --forward --fuzz=0 <"$patch"
	done
	b="$build_root/mpv-build"
	rm -rf "$b"
	local mpv_ldflags=$LDFLAGS
	case $os in
		macos) mpv_ldflags="$LDFLAGS -lc++" ;;
		# Static libraries inside libmpv must not export symbols that clash with the host's libdrm and freetype.
		linux) mpv_ldflags="$LDFLAGS -Wl,--exclude-libs,ALL -lstdc++" ;;
		windows) mpv_ldflags="$LDFLAGS -Wl,-Bstatic -lstdc++ -lwinpthread -Wl,-Bdynamic" ;;
	esac
	LDFLAGS=$mpv_ldflags meson setup "$b" "$src" "${meson_common[@]}" "${args[@]}" || {
		tail -n 80 "$b/meson-logs/meson-log.txt"
		exit 1
	}
	meson compile -C "$b"
	meson install -C "$b" --no-rebuild
}

order=()
case $os in
	macos) order=(dav1d ffmpeg freetype2 fribidi harfbuzz unibreak libass lcms2 libplacebo uchardet luajit mujs mpv) ;;
	linux) order=(mbedtls dav1d nv-codec-headers ffmpeg freetype2 fribidi harfbuzz unibreak libass lcms2 libplacebo uchardet luajit mujs libdrm libdisplay-info mpv) ;;
	windows) order=(zlib libiconv dav1d nv-codec-headers ffmpeg freetype2 fribidi harfbuzz unibreak libass lcms2 libplacebo uchardet luajit mujs angle-headers mpv) ;;
esac
[ $# -gt 0 ] && order=("$@")

for dep in "${order[@]}"; do
	echo "==> $target: $dep"
	"build_$dep"
done
echo "Built ${order[*]} into $prefix"
