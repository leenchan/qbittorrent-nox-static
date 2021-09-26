#!/bin/sh -e
# This scrip is for cross compilations
# Please run this scrip in docker image: alpine:latest
# E.g: docker run -e CROSS_HOST=arm-linux-musleabi -e OPENSSL_COMPILER=linux-armv4 -e QT_DEVICE=linux-arm-generic-g++ --rm -v `git rev-parse --show-toplevel`:/build alpine /build/.github/workflows/cross_build.sh
# Artifacts will copy to the same directory.

# alpine repository mirror for local building
# sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/' /etc/apk/repositories

# value from: https://musl.cc/ (without -cross or -native)
export CROSS_HOST="${CROSS_HOST:-arm-linux-musleabi}"
# value from openssl source: ./Configure LIST
export OPENSSL_COMPILER="${OPENSSL_COMPILER:-linux-armv4}"
# value from https://github.com/qt/qtbase/tree/dev/mkspecs/
export QT_XPLATFORM="${QT_XPLATFORM}"
# value from https://github.com/qt/qtbase/tree/dev/mkspecs/devices/
export QT_DEVICE="${QT_DEVICE}"
# match qt version prefix. E.g 5 --> 5.15.2, 5.12 --> 5.12.10
export QT_VER_PREFIX="5"
export BOOST_VERSION="${BOOST_VERSION}"
export LIBTORRENT_VERSION="${LIBTORRENT_VERSION}"
export QBITTORRENT_VERSION="${QBITTORRENT_VERSION}"
[ -z "$QBITTORRENT_VERSION" ] && export QBITTORRENT_VERSION=$(curl -skL https://github.com/c0re100/qBittorrent-Enhanced-Edition/releases/latest | grep -Eo 'tag/release-[0-9.]+' | head -n1 | awk -F'-' '{print $2}')
export CROSS_ROOT="${CROSS_ROOT:-/cross_root}"

apk add gcc \
	g++ \
	make \
	file \
	perl \
	autoconf \
	automake \
	libtool \
	tar \
	jq \
	pkgconfig \
	linux-headers \
	zip \
	xz \
	curl \
	upx \
	aria2

TARGET_ARCH="${CROSS_HOST%%-*}"
TARGET_HOST="${CROSS_HOST#*-}"
case "${TARGET_HOST}" in
*"mingw"*)
	TARGET_HOST=win
	apk add wine
	export WINEPREFIX=/tmp/
	RUNNER_CHECKER="wine64"
	;;
*)
	TARGET_HOST=linux
	apk add "qemu-${TARGET_ARCH}"
	RUNNER_CHECKER="qemu-${TARGET_ARCH}"
	;;
esac

export PATH="${CROSS_ROOT}/bin:${PATH}"
export CROSS_PREFIX="${CROSS_ROOT}/${CROSS_HOST}"
export PKG_CONFIG_PATH="${CROSS_PREFIX}/opt/qt/lib/pkgconfig:${CROSS_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH}"
SELF_DIR="$(dirname "$(readlink -f "${0}")")"
DL_DIR="/tmp/download"

mkdir -p "${CROSS_ROOT}" \
	${DL_DIR} \
	/usr/src/zlib \
	/usr/src/openssl \
	/usr/src/boost \
	/usr/src/libiconv \
	/usr/src/libtorrent \
	/usr/src/qtbase \
	/usr/src/qttools \
	/usr/src/qbittorrent

dl_file() {
	aria2c -c -x 16 -d "${DL_DIR}" -o "$2" "$1" || exit 1
}

#==================== Download ====================
##### Download qbittorrent ####
QBITTORRENT_DL_URL="https://github.com/qbittorrent/qBittorrent/archive/refs/tags/release-${QBITTORRENT_VERSION}.tar.gz"
[ "$QBITTORRENT_ENHANCED" = "true" ] && QBITTORRENT_DL_URL="https://github.com/c0re100/qBittorrent-Enhanced-Edition/archive/refs/tags/release-${QBITTORRENT_VERSION}.tar.gz"
# wget -c -O "${DL_DIR}/release-${QBITTORRENT_VERSION}.tar.gz" "${QBITTORRENT_DL_URL}" || exit 1
dl_file "${QBITTORRENT_DL_URL}" "release-${QBITTORRENT_VERSION}.tar.gz"
tar -zxf "${DL_DIR}/release-${QBITTORRENT_VERSION}.tar.gz" --strip-components=1 -C /usr/src/qbittorrent

#### Download libtorrent
LIBTORRENT_VERSION_MAX=$(echo "${QBITTORRENT_VERSION}" | awk -F'.' '{if ($1<=4 && $2 <=1) {print "libtorrent-1_1_14"}}')
[ -z "$LIBTORRENT_VERSION_MAX" ] || LIBTORRENT_VERSION="${LIBTORRENT_VERSION_MAX}"
LIBTORRENT_DL_URL="https://github.com/arvidn/libtorrent/archive/RC_1_2.tar.gz"
[ -z "$LIBTORRENT_VERSION" ] || LIBTORRENT_DL_URL="https://github.com/arvidn/libtorrent/archive/refs/tags/${LIBTORRENT_VERSION}.tar.gz"
if [ ! -f "${DL_DIR}/libtorrent.tar.gz" ]; then
	# wget -c -O "${DL_DIR}/libtorrent.tar.gz" "${LIBTORRENT_DL_URL}" || exit 1
	dl_file "${LIBTORRENT_DL_URL}" "libtorrent.tar.gz"
fi
tar -zxf "${DL_DIR}/libtorrent.tar.gz" --strip-components=1 -C /usr/src/libtorrent

#### Download toolchain ####
if [ ! -f "${DL_DIR}/${CROSS_HOST}-cross.tgz" ]; then
	# wget -c -O "${DL_DIR}/${CROSS_HOST}-cross.tgz" "https://musl.cc/${CROSS_HOST}-cross.tgz" || exit 1
	dl_file "https://musl.cc/${CROSS_HOST}-cross.tgz" "${CROSS_HOST}-cross.tgz"
fi
tar -zxf "${DL_DIR}/${CROSS_HOST}-cross.tgz" --transform='s|^\./||S' --strip-components=1 -C "${CROSS_ROOT}"
# mingw does not contains posix thread support: https://github.com/meganz/mingw-std-threads
if [ "${TARGET_HOST}" = 'win' ]; then
	if [ ! -f "${DL_DIR}/mingw-std-threads.tar.gz" ]; then
		# wget -c -O "${DL_DIR}/mingw-std-threads.tar.gz" "https://github.com/meganz/mingw-std-threads/archive/master.tar.gz" || exit 1
		dl_file "https://github.com/meganz/mingw-std-threads/archive/master.tar.gz" "mingw-std-threads.tar.gz"
	fi
	mkdir -p /usr/src/mingw-std-threads/
	tar -zxf "${DL_DIR}/mingw-std-threads.tar.gz" --strip-components=1 -C "/usr/src/mingw-std-threads/"
	cp -fv /usr/src/mingw-std-threads/*.h "${CROSS_PREFIX}/include"
fi

#### Download zlib ####
if [ ! -f "${DL_DIR}/zlib.tar.gz" ]; then
	zlib_latest_url="$(curl -skL https://api.github.com/repos/madler/zlib/tags | jq -r '.[0].tarball_url')"
	# wget -c -O "${DL_DIR}/zlib.tar.gz" "${zlib_latest_url}" || exit 1
	dl_file "${zlib_latest_url}" "zlib.tar.gz"
fi
tar -zxf "${DL_DIR}/zlib.tar.gz" --strip-components=1 -C /usr/src/zlib

#### Download openssl ####
if [ ! -f "${DL_DIR}/openssl.tar.gz" ]; then
	openssl_filename="$(curl -skL https://www.openssl.org/source/ | grep -o 'href="openssl-1.*tar.gz"' | grep -o '[^"]*.tar.gz')"
	openssl_latest_url="https://www.openssl.org/source/${openssl_filename}"
	# wget -c -O "${DL_DIR}/openssl.tar.gz" "${openssl_latest_url}" || exit 1
	dl_file "${openssl_latest_url}" "openssl.tar.gz"
fi
tar -zxf "${DL_DIR}/openssl.tar.gz" --strip-components=1 -C /usr/src/openssl

#### Download boost ####
BOOST_VERSION_MAX=$(echo "${QBITTORRENT_VERSION}" | awk -F'.' '{if ($1<=4 && $2 <=1) {print "1.68.0"}}')
[ -z "$BOOST_VERSION_MAX" ] || BOOST_VERSION="${BOOST_VERSION_MAX}"
if [ ! -f "${DL_DIR}/boost.tar.bz2" ]; then
	boost_url="$(curl -skL https://www.boost.org/users/download/ | grep -o 'http[^"]*.tar.bz2' | head -1)"
	[ -z "$BOOST_VERSION" ] || boost_url="https://boostorg.jfrog.io/artifactory/main/release/${BOOST_VERSION}/source/boost_$(echo "${BOOST_VERSION}" | tr "." "_").tar.bz2"
	# wget -c -O "${DL_DIR}/boost.tar.bz2" "${boost_url}" || exit 1
	dl_file "${boost_url}" "boost.tar.bz2"
fi
tar -jxf "${DL_DIR}/boost.tar.bz2" --strip-components=1 -C /usr/src/boost

#### Download qt ####
qt_major_ver="$(curl -skL https://download.qt.io/official_releases/qt/ | sed -nr 's@.*href="([0-9]+(\.[0-9]+)*)/".*@\1@p' | grep "^${QT_VER_PREFIX}" | head -1)"
qt_ver="$(curl -skL https://download.qt.io/official_releases/qt/${qt_major_ver}/ | sed -nr 's@.*href="([0-9]+(\.[0-9]+)*)/".*@\1@p' | grep "^${QT_VER_PREFIX}" | head -1)"
echo "Using qt version: ${qt_ver}"
qtbase_url="https://download.qt.io/official_releases/qt/${qt_major_ver}/${qt_ver}/submodules/qtbase-everywhere-src-${qt_ver}.tar.xz"
qtbase_filename="qtbase-everywhere-src-${qt_ver}.tar.xz"
qttools_url="https://download.qt.io/official_releases/qt/${qt_major_ver}/${qt_ver}/submodules/qttools-everywhere-src-${qt_ver}.tar.xz"
qttools_filename="qttools-everywhere-src-${qt_ver}.tar.xz"
if [ ! -f "${DL_DIR}/${qtbase_filename}" ]; then
	# wget -c -O "${DL_DIR}/${qtbase_filename}" "${qtbase_url}" || exit 1
	dl_file "${qtbase_url}" "${qtbase_filename}"
fi
if [ ! -f "${DL_DIR}/${qttools_filename}" ]; then
	# wget -c -O "${DL_DIR}/${qttools_filename}" "${qttools_url}" || exit 1
	dl_file "${qttools_url}" "${qttools_filename}"
fi
tar -Jxf "${DL_DIR}/${qtbase_filename}" --strip-components=1 -C /usr/src/qtbase
tar -Jxf "${DL_DIR}/${qttools_filename}" --strip-components=1 -C /usr/src/qttools

#### Download libiconv ####
if [ ! -f "${DL_DIR}/libiconv.tar.gz" ]; then
	libiconv_latest_url="$(curl -skL https://www.gnu.org/software/libiconv/ | grep -o '[^>< "]*ftp.gnu.org/pub/gnu/libiconv/.[^>< "]*' | head -1)"
	# wget -c -O "${DL_DIR}/libiconv.tar.gz" "${libiconv_latest_url}" || exit 1
	dl_file "${libiconv_latest_url}" "libiconv.tar.gz"
fi
tar -zxf "${DL_DIR}/libiconv.tar.gz" --strip-components=1 -C /usr/src/libiconv/

#### Download End / Check ####
rm -rf "${DL_DIR}"
while read DIR; do
	echo "Checking /usr/src/$DIR"
	[ -z "$(ls /usr/src/$DIR)" ] && {
		ls "/usr/src/$DIR"
		echo "[ERR] Failed to download $DIR"
		exit 1
	}
done <<-EOF
	$(ls /usr/src)
EOF

#==================== Compile ====================
#### List boost library ####
# cd /usr/src/boost
# ./bootstrap.sh
# sed -i "s/using gcc.*/using gcc : cross : ${CROSS_HOST}-g++ ;/" project-config.jam
# ./b2 --show-libraries
# exit 1

#### Compile zlib ####
cd /usr/src/zlib
if [ "${TARGET_HOST}" = win ]; then
 make -f win32/Makefile.gcc BINARY_PATH="${CROSS_PREFIX}/bin" INCLUDE_PATH="${CROSS_PREFIX}/include" LIBRARY_PATH="${CROSS_PREFIX}/lib" SHARED_MODE=0 PREFIX="${CROSS_HOST}-" -j$(nproc) install
else
 CHOST="${CROSS_HOST}" ./configure --prefix="${CROSS_PREFIX}" --static
 make -j$(nproc)
 make install
fi

#### Compile openssl ####
cd /usr/src/openssl
./Configure -static --cross-compile-prefix="${CROSS_HOST}-" --prefix="${CROSS_PREFIX}" "${OPENSSL_COMPILER}"
make depend
make -j$(nproc)
make install_sw

#### Compile boost ####
cd /usr/src/boost
./bootstrap.sh
sed -i "s/using gcc.*/using gcc : cross : ${CROSS_HOST}-g++ ;/" project-config.jam
[ -z "$BOOST_VERSION" ] || boost_with_libs=$(echo "$BOOST_VERSION" | awk -F'.' '{if ($1<=1 && $2<=68) {print "--with-chrono --with-random"}}')
./b2 install --prefix="${CROSS_PREFIX}" --with-system $boost_with_libs toolset=gcc-cross variant=release link=static runtime-link=static

#### Compile qt ####
cd /usr/src/qtbase
# Remove some options no support by this toolchain
find -name '*.conf' -print0 | xargs -0 -r sed -i 's/-fno-fat-lto-objects//g'
find -name '*.conf' -print0 | xargs -0 -r sed -i 's/-fuse-linker-plugin//g'
find -name '*.conf' -print0 | xargs -0 -r sed -i 's/-mfloat-abi=softfp//g'
if [ "${TARGET_HOST}" = 'win' ]; then
 export OPENSSL_LIBS="-lssl -lcrypto -lcrypt32 -lws2_32"
 # musl.cc x86_64-w64-mingw32 toolchain not supports thread local
 sed -i '/define\s*Q_COMPILER_THREAD_LOCAL/d' src/corelib/global/qcompilerdetection.h
fi
./configure --prefix=/opt/qt/ -optimize-size -silent --openssl-linked \
 -static -opensource -confirm-license -release -c++std c++17 -no-opengl \
 -no-dbus -no-widgets -no-gui -no-compile-examples -ltcg -make libs -no-pch \
 -nomake tests -nomake examples -no-xcb -no-feature-testlib \
 -hostprefix "${CROSS_ROOT}" ${QT_XPLATFORM:+-xplatform "${QT_XPLATFORM}"} \
 ${QT_DEVICE:+-device "${QT_DEVICE}"} -device-option CROSS_COMPILE="${CROSS_HOST}-" \
 -sysroot "${CROSS_PREFIX}"
make -j$(nproc)
make install
cd /usr/src/qttools
qmake -set prefix "${CROSS_ROOT}"
qmake
# Remove some options no support by this toolchain
find -name '*.conf' -print0 | xargs -0 -r sed -i 's/-fno-fat-lto-objects//g'
find -name '*.conf' -print0 | xargs -0 -r sed -i 's/-fuse-linker-plugin//g'
find -name '*.conf' -print0 | xargs -0 -r sed -i 's/-mfloat-abi=softfp//g'
make -j$(nproc) install
cd "${CROSS_ROOT}/bin"
ln -sf lrelease "lrelease-qt$(echo "${qt_ver}" | grep -Eo "^[1-9]")"

#### Compile libiconv ####
cd /usr/src/libiconv/
./configure CXXFLAGS="-std=c++17" --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-static --disable-shared --enable-silent-rules
make -j$(nproc)
make install

#### Compile libtorrent ####
cd /usr/src/libtorrent
if [ "${TARGET_HOST}" = 'win' ]; then
 export LIBS="-lcrypt32 -lws2_32"
 # musl.cc x86_64-w64-mingw32 toolchain not supports thread local
 export CPPFLAGS='-D_WIN32_WINNT=0x0602 -DBOOST_NO_CXX11_THREAD_LOCAL'
fi
./bootstrap.sh CXXFLAGS="-std=c++17" --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-static --disable-shared --enable-silent-rules --with-boost="${CROSS_PREFIX}" --with-libiconv
# fix x86_64-w64-mingw32 build
if [ "${TARGET_HOST}" = 'win' ]; then
 find -type f \( -name '*.cpp' -o -name '*.hpp' \) -print0 |
  xargs -0 -r sed -i 's/include\s*<condition_variable>/include "mingw.condition_variable.h"/g;
                        s/include\s*<future>/include "mingw.future.h"/g;
                        s/include\s*<invoke>/include "mingw.invoke.h"/g;
                        s/include\s*<mutex>/include "mingw.mutex.h"/g;
                        s/include\s*<shared_mutex>/include "mingw.shared_mutex.h"/g;
                        s/include\s*<thread>/include "mingw.thread.h"/g'
fi
make -j$(nproc) || exit 1
make install
unset LIBS CPPFLAGS

#### Compile qbittorrent ####
cd /usr/src/qbittorrent
if [ "${TARGET_HOST}" = 'win' ]; then
 find \( -name '*.cpp' -o -name '*.h' \) -type f -print0 |
  xargs -0 -r sed -i 's/Windows\.h/windows.h/g;
      s/Shellapi\.h/shellapi.h/g;
      s/Shlobj\.h/shlobj.h/g;
      s/Ntsecapi\.h/ntsecapi.h/g'
 export LIBS="-lmswsock"
 export CPPFLAGS='-std=c++17 -D_WIN32_WINNT=0x0602'
fi
LIBS="${LIBS} -liconv" ./configure --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --disable-gui --with-boost="${CROSS_PREFIX}" CXXFLAGS="-std=c++17 ${CPPFLAGS}" LDFLAGS='-s -static --static'
make -j$(nproc)
make install
unset LIBS CPPFLAGS
if [ "${TARGET_HOST}" = 'win' ]; then
 cp -fv "src/release/qbittorrent-nox.exe" /tmp/
else
 cp -fv "${CROSS_PREFIX}/bin/qbittorrent-nox" /tmp/
fi
# compression
[ "$UPX_COMPRESSION" = "true" ] && upx --lzma --best /tmp/qbittorrent-nox

# check
"${RUNNER_CHECKER}" /tmp/qbittorrent-nox* --version 2>/dev/null
# ls -al "${CROSS_ROOT}/bin"
# echo "qt_ver: ${qt_ver}"

# archive qbittorrent
zip -j9v "${SELF_DIR}/qbittorrent-nox_${CROSS_HOST}_static.zip" /tmp/qbittorrent-nox*
