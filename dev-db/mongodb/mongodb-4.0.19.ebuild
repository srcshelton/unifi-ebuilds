# Copyright 1999-2020 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=7

PYTHON_COMPAT=( python2_7 )

SCONS_MIN_VERSION="2.5.0"
CHECKREQS_DISK_BUILD="2400M"
CHECKREQS_DISK_USR="512M" # Less if stripped binaries are installed
CHECKREQS_MEMORY="640M" # Default 1024M, but builds on RPi with ~700M available...

inherit check-reqs flag-o-matic multiprocessing pax-utils python-any-r1 scons-utils systemd toolchain-funcs

MY_P=${PN}-src-r${PV/_rc/-rc}

DESCRIPTION="A high-performance, open source, schema-free document-oriented database"
HOMEPAGE="https://www.mongodb.com"
SRC_URI="https://fastdl.mongodb.org/src/${MY_P}.tar.gz"

LICENSE="Apache-2.0 SSPL-1"
SLOT="0"
KEYWORDS="amd64"
IUSE="debug kerberos libressl lto mms-agent mongos ssl systemd test +tools"
RESTRICT="!test? ( test )"

RDEPEND="acct-group/mongodb
	acct-user/mongodb
	>=app-arch/snappy-1.1.3
	>=dev-cpp/yaml-cpp-0.5.3:=
	>=dev-libs/boost-1.60:=[threads(+)]
	>=dev-libs/libpcre-8.41[cxx]
	=dev-libs/snowball-stemmer-0*
	net-libs/libpcap
	net-misc/curl
	>=sys-libs/zlib-1.2.11:=
	kerberos? ( dev-libs/cyrus-sasl[kerberos] )
	mms-agent? ( app-admin/mms-agent )
	ssl? (
		!libressl? ( >=dev-libs/openssl-1.0.1g:0= )
		libressl? ( dev-libs/libressl:0= )
	)"
DEPEND="${RDEPEND}
	${PYTHON_DEPS}
	$(python_gen_any_dep '
		test? ( dev-python/pymongo[${PYTHON_USEDEP}] )
		>=dev-util/scons-2.5.0[${PYTHON_USEDEP}]
		dev-python/cheetah[${PYTHON_USEDEP}]
		dev-python/pyyaml[${PYTHON_USEDEP}]
		dev-python/typing[${PYTHON_USEDEP}]
	')
	sys-libs/ncurses:0=
	sys-libs/readline:0=
	debug? ( dev-util/valgrind )"
PDEPEND="tools? ( >=app-admin/mongo-tools-${PV} )"

PATCHES=(
	"${FILESDIR}/${PN}-3.6.1-fix-scons.patch"
	"${FILESDIR}/${PN}-4.0.0-no-compass.patch"
	"${FILESDIR}/${PN}-4.0.12-boost-1.71-cxxabi-include.patch"
)

S="${WORKDIR}/${MY_P}"

pkg_pretend() {
	if [[ -n ${REPLACING_VERSIONS} ]]; then
		if ver_test "$REPLACING_VERSIONS" -lt 3.6; then
			ewarn "To upgrade from a version earlier than the 3.6-series, you must"
			ewarn "successively upgrade major releases until you have upgraded"
			ewarn "to 3.6-series. Then upgrade to 4.0 series."
		else
			ewarn "Be sure to set featureCompatibilityVersion to 3.6 before upgrading."
			ewarn
			ewarn "e.g. mongo mongodb://127.0.0.1:27117"
			ewarn "     > db.adminCommand( { getParameter: 1, featureCompatibilityVersion: 3.6 } )"
		fi
	fi
}

python_check_deps() {
	if use test; then
		has_version "dev-python/pymongo[${PYTHON_USEDEP}]" ||
			return 1
	fi

	has_version ">=dev-util/scons-2.5.0[${PYTHON_USEDEP}]" &&
	has_version "dev-python/cheetah[${PYTHON_USEDEP}]" &&
	has_version "dev-python/pyyaml[${PYTHON_USEDEP}]" &&
	has_version "dev-python/typing[${PYTHON_USEDEP}]"
}

src_prepare() {
	default

	# remove bundled libs
	rm -r src/third_party/{boost-*,pcre-*,scons-*,snappy-*,yaml-cpp-*,zlib-*} || die

	# remove compass
	rm -r src/mongo/installer/compass || die
}

src_configure() {
	# https://github.com/mongodb/mongo/wiki/Build-Mongodb-From-Source
	# --use-system-icu fails tests
	# --use-system-tcmalloc is strongly NOT recommended
	scons_opts=(
		CC="$(tc-getCC)"
		CXX="$(tc-getCXX)"

		--disable-warnings-as-errors
		--use-system-boost
		--use-system-pcre
		--use-system-snappy
		--use-system-stemmer
		--use-system-yaml
		--use-system-zlib
	)

	# wiredtiger not supported on 32bit platforms #572166
	if use x86 || use arm; then
		scons_opts+=( --wiredtiger=off --mmapv1=on )
	fi

	if use prefix; then
		scons_opts+=(
			--cpppath="${EPREFIX%/}/usr/include"
			--libpath="${EPREFIX%/}/usr/$(get_libdir)"
		)
	fi

	if use arm || use arm64; then
		# FIXME:
		# When targeting 64-bit ARM systems (aarch64) you must either
		# explicitly select a CPU targeting that includes CRC32 support by
		# adding CCFLAGS=-march=armv8-a+crc to your SCons invocation, or
		# disable hardware CRC32 acceleration with the
		# flag --use-hardware-crc32=off. Note that on older branches this flag
		# may be somewhat confusingly called --use-s390x-crc32=off, but will
		# still affect ARM builds.
		if ! [[ "${CCFLAGS}" == *crc* ]]; then
			scons_opts+=( --use-hardware-crc32=off )
		fi
	fi

	use debug && scons_opts+=( --dbg=on )
	use kerberos && scons_opts+=( --use-sasl-client )
	use lto && scons_opts+=( --lto=on )
	use ssl && scons_opts+=( --ssl )

	# respect mongoDB upstream's basic recommendations
	# see bug #536688 and #526114
	if ! use debug; then
		use arm || filter-flags '-m*' # ... but not on ARM, where flags such as -march/-mtune, -mfpu,
									  # and -mfloat-abi, etc. are *essential* in order to produce
									  # working code.
		filter-flags '-O?'
	fi

	default
}

src_compile() {
	escons "${scons_opts[@]}" core tools || die
}

# FEATURES="test -usersandbox" emerge dev-db/mongodb
src_test() {
	"${EPYTHON}" ./buildscripts/resmoke.py --dbpathPrefix=test --suites core --jobs=$(makeopts_jobs) || die "Tests failed"
}

src_install() {
	escons "${scons_opts[@]}" --nostrip install --prefix="${ED}"/usr || die

	doman debian/mongo*.1
	#dodoc README docs/building.md

	newinitd "${FILESDIR}/${PN}.initd-r3" ${PN}
	newconfd "${FILESDIR}/${PN}.confd-r3" ${PN}
	newinitd "${FILESDIR}/mongos.initd-r3" mongos
	newconfd "${FILESDIR}/mongos.confd-r3" mongos

	insinto /etc
	newins "${FILESDIR}/${PN}.conf-r3" ${PN}.conf
	newins "${FILESDIR}/mongos.conf-r2" mongos.conf

	use systemd && systemd_dounit "${FILESDIR}/${PN}.service"

	insinto /etc/logrotate.d/
	newins "${FILESDIR}/${PN}.logrotate" ${PN}

	# see bug #526114
	pax-mark emr "${ED}"/usr/bin/{mongo,mongod,mongos}

	if ! use mongos; then
		rm "${ED}"/etc/mongos.conf "${ED}"/etc/init.d/mongos "${ED}"/usr/share/man/man1/mongos.1* "${ED}"/usr/bin/mongos ||
			die "Error removing mongo shard elements: ${?}"
	fi

	local x
	for x in /var/{lib,log}/${PN}; do
		diropts -m0750 -o mongodb -g mongodb
		keepdir "${x}"
	done
}

pkg_postinst() {
	ewarn "Make sure to read the release notes and follow the upgrade process:"
	ewarn "  https://docs.mongodb.com/manual/release-notes/$(ver_cut 1-2)/"
	ewarn "  https://docs.mongodb.com/manual/release-notes/$(ver_cut 1-2)/#upgrade-procedures"
}
