# AuroraMPVKit-Desktop

LGPL builds of libmpv and FFmpeg for Aurora Media Center on macOS, Windows and Linux. mpv is built with `-Dgpl=false` and FFmpeg without `--enable-gpl` or `--enable-nonfree`, so the desktop app can link them dynamically without GPL obligations. Lua (LuaJIT) and JavaScript (MuJS) stay on for user scripts and the stats overlay.

## Kit archives

Each build produces one archive per platform, `aurora-mpv-desktop-<version>-<target>.tar.xz`:

| Target | Libraries | Built on |
| --- | --- | --- |
| `macos-arm64`, `macos-x86_64`, `macos-universal` | `lib/libmpv.2.dylib` and the FFmpeg `.dylib` files, install names `@rpath/...`, minimum macOS 13.0 | `macos-15`, `macos-15-intel` |
| `linux-x86_64` | `lib/libmpv.so.2` and the FFmpeg `.so` files, RUNPATH `$ORIGIN`, glibc 2.35 | `ubuntu:22.04` container |
| `windows-x86_64` | `bin/libmpv-2.dll` and the FFmpeg DLLs, import libraries `lib/libmpv.dll.a` and `lib/mpv.lib` | MSYS2 UCRT64 (GCC) |

Every archive also holds `include/mpv/`, a relocatable `lib/pkgconfig/mpv.pc`, `NOTICES.txt`, `licenses/`, `check-license.sh` and `BUILDINFO.txt`.

Aurora's release scripts read the kit from `third_party/mpv-kit/<platform>` in the app checkout, or from the folder in `AURORA_MPV_KIT`.

## Sources

| Component | Version | Source | License |
| --- | --- | --- | --- |
| mpv | `v0.42.0` (`b0841e8c`) | https://github.com/mpv-player/mpv | LGPL-2.1-or-later (`-Dgpl=false`) |
| FFmpeg | `n9.0.2` (`946fcce0`) | https://github.com/FFmpeg/FFmpeg | LGPL-3.0-or-later (`--enable-version3`) |
| libplacebo | `v7.387.0` (`275f7dea`) | https://github.com/haasn/libplacebo | LGPL-2.1-or-later |
| dav1d | `1.5.4` (`54706fc6`) | https://github.com/videolan/dav1d | BSD-2-Clause |
| libass | `0.17.5` (`4a05d812`) | https://github.com/libass/libass | ISC |
| FreeType | `VER-2-15-0` (`37515cf5`) | https://gitlab.freedesktop.org/freetype/freetype | FTL |
| HarfBuzz | `15.0.0` (release tarball) | https://github.com/harfbuzz/harfbuzz | MIT |
| FriBidi | `1.0.17` (release tarball) | https://github.com/fribidi/fribidi | LGPL-2.1-or-later |
| libunibreak | `8.0` (release tarball) | https://github.com/adah1972/libunibreak | Zlib |
| Little CMS | `lcms2.19.1` (`21c582a5`) | https://github.com/mm2/Little-CMS | MIT (GPL plugins off) |
| uchardet | `v0.0.8` (`ae6302a0`) | https://gitlab.freedesktop.org/uchardet/uchardet | MPL-1.1, GPL-2.0+ or LGPL-2.1+ (used under LGPL-2.1+) |
| LuaJIT | `v2.1` branch (`ea9eb7ed`) | https://github.com/LuaJIT/LuaJIT | MIT |
| MuJS | `1.3.7` (`05cd646b`) | https://github.com/ccxvii/mujs | ISC |
| nv-codec-headers | `n13.1.15.0` (`0a6fba9a`), Windows and Linux | https://github.com/FFmpeg/nv-codec-headers | MIT |
| libdrm | `libdrm-2.4.134` (`e984d448`), Linux | https://gitlab.freedesktop.org/mesa/drm | MIT |
| libdisplay-info | `0.4.0` (`c67a3e9b`), Linux | https://gitlab.freedesktop.org/emersion/libdisplay-info | MIT (PNP table from hwdata, used under XFree86) |
| Mbed TLS | `3.6.7` (release tarball), Linux | https://github.com/Mbed-TLS/mbedtls | Apache-2.0 |
| zlib | `1.3.1` (release tarball), Windows | https://github.com/madler/zlib | Zlib |
| ANGLE EGL headers | commit `c966e752` (files pinned by SHA-256), Windows, compile time only | https://github.com/google/angle | BSD-3-Clause |
| GNU libiconv | `1.18` (release tarball), Windows | https://ftp.gnu.org/pub/gnu/libiconv/ | LGPL-2.1-or-later (library) |

`buildscripts/include/download-deps.sh` checks every git tag against the commit above and every tarball against the SHA-256 in `buildscripts/include/depinfo.sh`, and stops on a mismatch.

### Patch

`buildscripts/patches/mpv/0001-mac-view-check-cametallayer.patch` changes one line in mpv's `video/out/mac/view.swift`: the view checks for `CAMetalLayer` instead of mpv's `MetalLayer` subclass, which only exists in Vulkan builds. Without it mpv 0.42.0 does not compile on macOS with Cocoa and without Vulkan. Cocoa is needed for `gl-cocoa`, which gives `videotoolbox-gl` (zero-copy VideoToolbox with the OpenGL render API). The patch is applied to a copy of the source in the build folder; the downloaded tree stays as upstream ships it.

## Configure flags

FFmpeg (`buildscripts/build.sh`, `build_ffmpeg`):

```
--enable-shared --disable-static --enable-version3
--disable-autodetect --disable-programs --disable-doc --disable-debug
--disable-encoders --enable-encoder=mjpeg,png
--disable-muxers --enable-muxer=mov,matroska,mpegts
--disable-devices --enable-libdav1d --enable-zlib
macOS:   --enable-videotoolbox --enable-audiotoolbox --enable-securetransport
Linux:   --enable-vaapi --enable-libdrm --enable-ffnvcodec --enable-nvdec --enable-cuvid --enable-mbedtls --enable-pthreads
Windows: --enable-d3d11va --enable-dxva2 --enable-ffnvcodec --enable-nvdec --enable-cuvid --enable-schannel --enable-w32threads
```

mpv (`build_mpv`):

```
--default-library shared -Dgpl=false -Dlibmpv=true -Dcplayer=false -Dbuild-date=false
-Dlibcurl=disabled -Drubberband=disabled -Dvapoursynth=disabled -Dzimg=disabled
-Ddvbin=disabled -Ddvdnav=disabled -Dcdda=disabled -Djack=disabled -Doss-audio=disabled
-Dlibarchive=disabled -Dlibbluray=disabled -Djpeg=disabled -Dopenal=disabled -Dsdl2-*=disabled
-Dlua=luajit -Djavascript=enabled -Duchardet=enabled -Dlcms2=enabled -Dzlib=enabled
-Dvulkan=disabled -Dshaderc=disabled -Dspirv-cross=disabled
macOS:   -Dcocoa=enabled -Dgl-cocoa=enabled -Dvideotoolbox-gl=enabled -Dcoreaudio=enabled -Davfoundation=enabled -Dswift-build=enabled
Linux:   -Dvaapi=enabled -Dvaapi-drm=enabled -Ddrm=enabled (needs libdrm 2.4.114 and libdisplay-info, built from source and hidden inside libmpv) -Degl=enabled -Dwayland=disabled -Dx11=disabled -Dcuda-hwaccel=enabled -Dcuda-interop=enabled -Dpulse=enabled -Dalsa=enabled
Windows: -Dgl-win32=enabled -Degl-angle=enabled -Degl-angle-lib=disabled -Dgl-dxinterop=enabled -Dd3d-hwaccel=enabled -Dd3d9-hwaccel=enabled -Dgl-dxinterop-d3d9=enabled -Dcuda-hwaccel=enabled -Dcuda-interop=enabled -Dwasapi=enabled -Diconv=enabled
```

Other libraries are static and linked into libmpv or FFmpeg; their flags are in `build.sh`.

Not included: x264, x265, libpostproc, rubberband, vapoursynth, libcurl, DVD and CD support, Vulkan, any `--enable-nonfree` component.

### Behavior changes against GPL builds

- `-Dgpl=false` turns off X11 in mpv, which also turns off VAAPI and VDPAU interop under X11. On Linux, `hwdec=auto-safe` then falls back to `vaapi-copy` or `nvdec`/`nvdec-copy`. macOS (VideoToolbox) and Windows (D3D11VA copy, DXVA2, NVDEC) keep hardware decoding.
- libcurl is off, so http and https go through FFmpeg and `stream-lavf-o` reconnect options apply.
- TLS goes through FFmpeg, which verifies certificates by default. macOS (Secure Transport) and Windows (Schannel) use the system trust store. Linux uses Mbed TLS, which has no system store: the app has to pass the distribution CA bundle with mpv's `tls-ca-file`.

## License check

`scripts/check-license.sh` fails when anything GPL or nonfree is in a kit or an application bundle:

```sh
scripts/check-license.sh dist/aurora-mpv-desktop-<version>-<target>.tar.xz [mpv config.h ffmpeg config.h]
scripts/check-license.sh path/to/Aurora.app
```

It finds every Mach-O, PE and ELF file and checks:

- the license string of each FFmpeg library (`LGPL version 3 or later`) and the configure line in libavutil (`--enable-version3`, no GPL or nonfree flags);
- mpv's feature list: no `gpl`, `x11`, `vdpau`, `libcurl`, `rubberband` and similar, and `luajit`, `javascript`, `uchardet`, `lcms2` present;
- linked libraries and file names against GPL libraries (x264, x265, postproc, rubberband, vidstab, frei0r, cdio, dvdnav, xvid, fdk-aac and others) and GPL-only Qt modules (QtVirtualKeyboard, QtHunspellInputMethod, QtQuickTimeline, QtQmlDesignSupport, QtQuick3D, QtCharts, QtGraphs, QtDataVisualization, QtLottie, QtHttpServer, QtNetworkAuth, QtCanvasPainter, QtGrpc, QtQmlCompiler);
- known exported symbols of those GPL libraries;
- on macOS, load commands that still point at the build host (`/opt/homebrew`, `/usr/local`) and rpaths outside the bundle and system folders;
- given the build `config.h` files, `HAVE_GPL 0` in mpv and `CONFIG_GPL 0`, `CONFIG_NONFREE 0`, `CONFIG_VERSION3 1` in FFmpeg.

It runs on macOS, Linux and MSYS2 with `file`, `strings`, `objdump` and (macOS) `otool`.

## Building

CI (`.github/workflows/build.yml`) builds each platform, packages it, runs the license check and uploads the archives. A package job adds the universal macOS kit, the sources archive, `license-check.txt`, `NOTICES.txt` and `SHA256SUMS`. A `v*` tag also creates a GitHub release with those files.

Locally:

```sh
buildscripts/include/download-deps.sh
buildscripts/build.sh macos            # or linux (Ubuntu 22.04), or windows (MSYS2 UCRT64 shell)
scripts/package.sh macos-arm64 <version>
scripts/check-license.sh dist/aurora-mpv-desktop-<version>-macos-arm64.tar.xz
scripts/source-archive.sh <version>
```

macOS needs Xcode, meson, ninja, nasm and pkgconf. Linux packages are in `buildscripts/ci/linux-packages.sh`; the Linux build also runs in Docker on any host:

```sh
docker run --rm --platform=linux/amd64 -v "$PWD:/kit" -w /kit ubuntu:22.04 \
  bash -c 'buildscripts/ci/linux-packages.sh && buildscripts/build.sh linux'
```

To rebuild from a sources archive, unpack it and run the same commands from its top folder; `download-deps.sh` skips sources that are already present.

## License

The build scripts are MIT (see `LICENSE`). The patch is under mpv's license. The libraries in the kit archives keep their own licenses; see `NOTICES` and the `licenses/` folder in each archive.
