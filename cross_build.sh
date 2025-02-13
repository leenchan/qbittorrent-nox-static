#!/bin/sh -e

CUR_DIR="$(dirname "$(readlink -f "${0}")")"
CROSS_ROOT="/cross_root"
DL_DIR="/tmp/download"
TARGET_HOST="linux"

case "$BUILD_TARGET" in
"arm")
	CROSS_HOST="arm-linux-musleabi"
	OPENSSL_COMPILER="linux-armv4"
	QT_DEVICE="linux-arm-generic-g++"
	;;
"aarch64")
	CROSS_HOST="aarch64-linux-musl"
	OPENSSL_COMPILER="linux-aarch64"
	QT_DEVICE="linux-arm-generic-g++"
	;;
"mips")
	CROSS_HOST="mips-linux-musln32sf"
	OPENSSL_COMPILER="linux-mips32"
	QT_DEVICE="linux-generic-g++"
	;;
"mipsel")
	CROSS_HOST="mipsel-linux-musln32sf"
	OPENSSL_COMPILER="linux-mips32"
	QT_DEVICE="linux-generic-g++"
	;;
"mips64")
	CROSS_HOST="mips64-linux-musl"
	OPENSSL_COMPILER="linux64-mips64"
	QT_DEVICE="linux-generic-g++"
	;;
"x86_64")
	CROSS_HOST="x86_64-linux-musl"
	OPENSSL_COMPILER="linux-x86_64"
	QT_DEVICE="linux-generic-g++"
	;;
"x86_64_win")
	CROSS_HOST="x86_64-w64-mingw32"
	OPENSSL_COMPILER="mingw64"
	QT_XPLATFORM="win32-g++"
	TARGET_HOST="win"
	;;
*)
	exit 1
	;;
esac

_init() {
	[ -z "$BUILD_TARGET_INCLUDE" ] || {
		echo "$BUILD_TARGET_INCLUDE" | tr -d ' ' | tr ',' '\n' | grep -q "^${BUILD_TARGET}$" || exit 1
	}
	cat <<-EOF >>$GITHUB_ENV
		CROSS_HOST=$CROSS_HOST
		OPENSSL_COMPILER=$OPENSSL_COMPILER
		QT_DEVICE=$QT_DEVICE
		QT_XPLATFORM=$QT_XPLATFORM
		QT_VER_PREFIX=${QT_VER_PREFIX:-5}
		TARGET_HOST=$TARGET_HOST
		CROSS_PREFIX=$CROSS_ROOT/$CROSS_HOST
	EOF
	[ -z "$QBITTORRENT_VERSION" ] && echo "QBITTORRENT_VERSION=$(curl -skL https://github.com/c0re100/qBittorrent-Enhanced-Edition/releases/latest | grep -Eo 'tag/release-[0-9.]+' | head -n1 | awk -F'-' '{print $2}')" >>$GITHUB_ENV
	LIBTORRENT_VERSION_MAX=$(echo "${QBITTORRENT_VERSION}" | awk -F'.' '{if ($1<=4 && $2 <=1) {print "libtorrent-1_1_14"}}')
	[ -z "$LIBTORRENT_VERSION_MAX" ] || echo "LIBTORRENT_VERSION=${LIBTORRENT_VERSION_MAX}" >>$GITHUB_ENV
	BOOST_VERSION_MAX=$(echo "${QBITTORRENT_VERSION}" | awk -F'.' '{if ($1<=4 && $2 <=1) {print "1.68.0"}}')
	[ -z "$BOOST_VERSION_MAX" ] || echo "BOOST_VERSION=${BOOST_VERSION_MAX}" >>$GITHUB_ENV

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
}

_download_file() {
	aria2c -m 3 -c -x 16 -d "${DL_DIR}" -o "$2" "$1" || wget -O "${DL_DIR}/${2}" "$1" || {
		echo "[ERR] Failed to download: $1"
		exit 1
	}
}

_download() {
	##### Download qbittorrent ####
	QBITTORRENT_DL_URL="https://github.com/qbittorrent/qBittorrent/archive/refs/tags/release-${QBITTORRENT_VERSION}.tar.gz"
	[ "$QBITTORRENT_ENHANCED" = "true" ] && QBITTORRENT_DL_URL="https://github.com/c0re100/qBittorrent-Enhanced-Edition/archive/refs/tags/release-${QBITTORRENT_VERSION}.tar.gz"
	_download_file "${QBITTORRENT_DL_URL}" "release-${QBITTORRENT_VERSION}.tar.gz"
	tar -zxf "${DL_DIR}/release-${QBITTORRENT_VERSION}.tar.gz" --strip-components=1 -C /usr/src/qbittorrent

	#### Download libtorrent
	LIBTORRENT_DL_URL="https://github.com/arvidn/libtorrent/archive/RC_1_2.tar.gz"
	[ -z "$LIBTORRENT_VERSION" ] || LIBTORRENT_DL_URL="https://github.com/arvidn/libtorrent/archive/refs/tags/${LIBTORRENT_VERSION}.tar.gz"
	if [ ! -f "${DL_DIR}/libtorrent.tar.gz" ]; then
		_download_file "${LIBTORRENT_DL_URL}" "libtorrent.tar.gz"
	fi
	tar -zxf "${DL_DIR}/libtorrent.tar.gz" --strip-components=1 -C /usr/src/libtorrent

	#### Download toolchain ####
	if [ ! -f "${DL_DIR}/${CROSS_HOST}-cross.tgz" ]; then
		_download_file "https://musl.cc/${CROSS_HOST}-cross.tgz" "${CROSS_HOST}-cross.tgz"
	fi
	tar -zxf "${DL_DIR}/${CROSS_HOST}-cross.tgz" --transform='s|^\./||S' --strip-components=1 -C "${CROSS_ROOT}"
	# mingw does not contains posix thread support: https://github.com/meganz/mingw-std-threads
	if [ "${TARGET_HOST}" = 'win' ]; then
		if [ ! -f "${DL_DIR}/mingw-std-threads.tar.gz" ]; then
			_download_file "https://github.com/meganz/mingw-std-threads/archive/master.tar.gz" "mingw-std-threads.tar.gz"
		fi
		mkdir -p /usr/src/mingw-std-threads/
		tar -zxf "${DL_DIR}/mingw-std-threads.tar.gz" --strip-components=1 -C "/usr/src/mingw-std-threads/"
		cp -fv /usr/src/mingw-std-threads/*.h "${CROSS_PREFIX}/include"
	fi

	#### Download zlib ####
	if [ ! -f "${DL_DIR}/zlib.tar.gz" ]; then
		zlib_latest_url="$(curl -skL https://api.github.com/repos/madler/zlib/tags | jq -r '.[0].tarball_url')"
		_download_file "${zlib_latest_url}" "zlib.tar.gz"
	fi
	tar -zxf "${DL_DIR}/zlib.tar.gz" --strip-components=1 -C /usr/src/zlib

	#### Download openssl ####
	if [ ! -f "${DL_DIR}/openssl.tar.gz" ]; then
		openssl_filename="$(curl -skL https://www.openssl.org/source/ | grep -o 'href="openssl-1.*tar.gz"' | grep -o '[^"]*.tar.gz')"
		openssl_latest_url="https://www.openssl.org/source/${openssl_filename}"
		_download_file "${openssl_latest_url}" "openssl.tar.gz"
	fi
	tar -zxf "${DL_DIR}/openssl.tar.gz" --strip-components=1 -C /usr/src/openssl

	#### Download boost ####
	if [ ! -f "${DL_DIR}/boost.tar.bz2" ]; then
		boost_url="$(curl -skL https://www.boost.org/users/download/ | grep -o 'http[^"]*.tar.bz2' | head -1)"
		[ -z "$BOOST_VERSION" ] || boost_url="https://boostorg.jfrog.io/artifactory/main/release/${BOOST_VERSION}/source/boost_$(echo "${BOOST_VERSION}" | tr "." "_").tar.bz2"
		_download_file "${boost_url}" "boost.tar.bz2"
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
		_download_file "${qtbase_url}" "${qtbase_filename}"
	fi
	if [ ! -f "${DL_DIR}/${qttools_filename}" ]; then
		_download_file "${qttools_url}" "${qttools_filename}"
	fi
	tar -Jxf "${DL_DIR}/${qtbase_filename}" --strip-components=1 -C /usr/src/qtbase
	tar -Jxf "${DL_DIR}/${qttools_filename}" --strip-components=1 -C /usr/src/qttools

	#### Download libiconv ####
	if [ ! -f "${DL_DIR}/libiconv.tar.gz" ]; then
		libiconv_latest_url="$(curl -skL https://www.gnu.org/software/libiconv/ | grep -o '[^>< "]*ftp.gnu.org/pub/gnu/libiconv/.[^>< "]*' | head -1)"
		_download_file "${libiconv_latest_url}" "libiconv.tar.gz"
	fi
	tar -zxf "${DL_DIR}/libiconv.tar.gz" --strip-components=1 -C /usr/src/libiconv/

	#### Check ####
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
}

_compile() {
	# export CROSS_ROOT="${CROSS_ROOT:-/cross_root}"
	# export CROSS_HOST="$CROSS_HOST"
	# export OPENSSL_COMPILER="$OPENSSL_COMPILER"
	# export QT_DEVICE="$QT_DEVICE"
	# export QT_XPLATFORM="$QT_XPLATFORM"
	# export QT_VER_PREFIX="${QT_VER_PREFIX:-5}"
	# export LIBTORRENT_VERSION="$LIBTORRENT_VERSION"
	# export QBITTORRENT_VERSION="$QBITTORRENT_VERSION"
	# export CROSS_PREFIX="${CROSS_ROOT}/${CROSS_HOST}"
	# export PKG_CONFIG_PATH="${CROSS_PREFIX}/opt/qt/lib/pkgconfig:${CROSS_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH}"
	# [ -z "$QBITTORRENT_VERSION" ] && export QBITTORRENT_VERSION=$(curl -skL https://github.com/c0re100/qBittorrent-Enhanced-Edition/releases/latest | grep -Eo 'tag/release-[0-9.]+' | head -n1 | awk -F'-' '{print $2}')
	# export PATH="${CROSS_ROOT}/bin:${PATH}"
	export PKG_CONFIG_PATH="${CROSS_PREFIX}/opt/qt/lib/pkgconfig:${CROSS_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH}"
	export PATH="${CROSS_ROOT}/bin:${PATH}"
	case "$1" in
	"zlib")
		#### Compile zlib ####
		cd /usr/src/zlib
		if [ "${TARGET_HOST}" = 'win' ]; then
			make -f win32/Makefile.gcc BINARY_PATH="${CROSS_PREFIX}/bin" INCLUDE_PATH="${CROSS_PREFIX}/include" LIBRARY_PATH="${CROSS_PREFIX}/lib" SHARED_MODE=0 PREFIX="${CROSS_HOST}-" -j$(nproc) install || exit 1
		else
			CHOST="${CROSS_HOST}" ./configure --prefix="${CROSS_PREFIX}" --static || exit 1
			make -j$(nproc) || exit 1
			make install
		fi
		;;
	"openssl")
		#### Compile openssl ####
		cd /usr/src/openssl
		./Configure -static --cross-compile-prefix="${CROSS_HOST}-" --prefix="${CROSS_PREFIX}" "${OPENSSL_COMPILER}" || exit 1
		make depend || exit 1
		make -j$(nproc) || exit 1
		make install_sw
		;;
	"boost")
		#### Compile boost ####
		cd /usr/src/boost
		./bootstrap.sh || exit 1
		sed -i "s/using gcc.*/using gcc : cross : ${CROSS_HOST}-g++ ;/" project-config.jam
		[ -z "$BOOST_VERSION" ] || boost_with_libs=$(echo "$BOOST_VERSION" | awk -F'.' '{if ($1<=1 && $2<=68) {print "--with-chrono --with-random"}}')
		./b2 install --prefix="${CROSS_PREFIX}" --with-system $boost_with_libs toolset=gcc-cross variant=release link=static runtime-link=static || exit 1
		;;
	"qtbase")
		#### Compile qtbase ####
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
			-sysroot "${CROSS_PREFIX}" || exit 1
		make -j$(nproc) || exit 1
		make install
		;;
	"qttools")
		#### Compile qttools ####
		cd /usr/src/qttools
		qmake -set prefix "${CROSS_ROOT}" || exit 1
		qmake || exit 1
		# Remove some options no support by this toolchain
		find -name '*.conf' -print0 | xargs -0 -r sed -i 's/-fno-fat-lto-objects//g'
		find -name '*.conf' -print0 | xargs -0 -r sed -i 's/-fuse-linker-plugin//g'
		find -name '*.conf' -print0 | xargs -0 -r sed -i 's/-mfloat-abi=softfp//g'
		make -j$(nproc) install
		cd "${CROSS_ROOT}/bin"
		ln -sf lrelease "lrelease-qt$(echo "${QT_VER_PREFIX}" | grep -Eo "^[1-9]")"
		;;
	"libiconv")
		#### Compile libiconv ####
		cd /usr/src/libiconv/
		./configure CXXFLAGS="-std=c++17" --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-static --disable-shared --enable-silent-rules || exit 1
		make -j$(nproc) || exit 1
		make install
		;;
	"libtorrent")
		#### Compile libtorrent ####
		cd /usr/src/libtorrent
		if [ "${TARGET_HOST}" = 'win' ]; then
			export LIBS="-lcrypt32 -lws2_32"
			# musl.cc x86_64-w64-mingw32 toolchain not supports thread local
			export CPPFLAGS='-D_WIN32_WINNT=0x0602 -DBOOST_NO_CXX11_THREAD_LOCAL'
		fi
		./bootstrap.sh CXXFLAGS="-std=c++17" --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-static --disable-shared --enable-silent-rules --with-boost="${CROSS_PREFIX}" --with-libiconv || exit 1
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
		;;
	"qbittorrent")
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
			# -Wno-deprecated-declarations
		fi
		LIBS="${LIBS} -liconv" ./configure --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --disable-gui --with-boost="${CROSS_PREFIX}" CXXFLAGS="-std=c++17 ${CPPFLAGS}" LDFLAGS='-s -static --static' || exit 1
		make -j$(nproc) || exit 1
		make install
		unset LIBS CPPFLAGS
		if [ "${TARGET_HOST}" = 'win' ]; then
			cp -fv "src/release/qbittorrent-nox.exe" /tmp/
		else
			cp -fv "${CROSS_PREFIX}/bin/qbittorrent-nox" /tmp/
		fi
		;;
	esac
}

_check() {
	# check qbittorrent version
	echo "Checking qBittorrent Version ... (${CROSS_HOST})"
	if [ "${TARGET_HOST}" = 'win' ]; then
		apk add wine
		export WINEPREFIX=/tmp/
		wine64 /tmp/qbittorrent-nox.exe --version 2>/dev/null || exit 1
	else
		TARGET_ARCH="${CROSS_HOST%%-*}"
		apk add qemu-${TARGET_ARCH}
		qemu-${TARGET_ARCH} /tmp/qbittorrent-nox --version 2>/dev/null || exit 1
	fi
}

_compress() {
	if [ "${TARGET_HOST}" = 'win' ]; then
		upx --force --lzma --best -o /tmp/qbittorrent-nox_upx.exe /tmp/qbittorrent-nox.exe
	else
		upx --lzma --best -o /tmp/qbittorrent-nox_upx /tmp/qbittorrent-nox
	fi
}

_archive() {
	# archive qbittorrent
	ls /tmp | grep -q "qbittorrent-nox" || exit 1
	zip -j9v "${CUR_DIR}/qbittorrent-nox_${BUILD_TARGET}_static.zip" /tmp/qbittorrent-nox* || exit 1
	echo "${CUR_DIR}/qbittorrent-nox_${BUILD_TARGET}_static.zip"
}

case "$1" in
"init")
	_init
	;;
"download")
	_download
	;;
"compile" | "c")
	shift
	_compile "$@"
	;;
"check")
	_check
	;;
"compress")
	_compress
	;;
"archive")
	_archive
	;;
esac

exit 0
