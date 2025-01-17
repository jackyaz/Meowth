FROM python:3.10.13-slim-bookworm as s2geometry
LABEL maintainer="Jack Yaz <jackyaz@outlook.com>"


### START S2GEOMETRY BUILD AND SETUP ###

RUN apt-get update && \
	apt-get install -y --no-install-recommends \
	build-essential \
	git \
	libgflags-dev \
	libgoogle-glog-dev \
	libgtest-dev \
	libssl-dev \
	swig \
	cmake \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*

RUN mkdir /app
RUN python3 -m venv /app/venv
ENV PATH="/app/venv/bin:$PATH"
RUN python3 -m pip install --upgrade pip

WORKDIR /src
RUN git clone https://github.com/abseil/abseil-cpp --branch 20230802.1
WORKDIR /src/abseil-cpp/build
RUN cmake -S /src/abseil-cpp -B /build/abseil-cpp -DCMAKE_INSTALL_PREFIX=/output -DABSL_BUILD_TESTING=OFF -DABSL_ENABLE_INSTALL=ON -DCMAKE_CXX_STANDARD=17 -DCMAKE_POSITION_INDEPENDENT_CODE=ON
RUN cmake --build /build/abseil-cpp --target install

WORKDIR /src
RUN git clone https://github.com/google/s2geometry.git
WORKDIR /src/s2geometry/
RUN cmake -DCMAKE_PREFIX_PATH=/output/lib/cmake/absl -DCMAKE_CXX_STANDARD=17 -DWITH_PYTHON=ON -DBUILD_TESTS=OFF
RUN make -j $(nproc)
RUN make install -j $(nproc)

WORKDIR /src/s2geometry/

RUN sed -i "s/'-DWITH_PYTHON=ON'/'-DWITH_PYTHON=ON',/" /src/s2geometry/setup.py
RUN sed -i "/'-DWITH_PYTHON=ON',/a \                                        '-DCMAKE_PREFIX_PATH=/output/lib/cmake'" /src/s2geometry/setup.py
RUN sed -i "/'-DWITH_PYTHON=ON',/a \                                        '-DCMAKE_CXX_STANDARD=17'," /src/s2geometry/setup.py
RUN sed -i "/'-DWITH_PYTHON=ON',/a \                                        '-DBUILD_TESTS=OFF'," /src/s2geometry/setup.py
RUN sed -i 's/install_prefix="s2geometry"/install_prefix="pywraps2"/' /src/s2geometry/setup.py

RUN python3 -m pip install cmake_build_extension wheel
RUN python3 setup.py bdist_wheel

### END S2GEOMETRY BUILD AND SETUP ###

### START POSTGRES BUILD AND SETUP ###

FROM python:3.10.13-slim-bookworm as meowth
LABEL maintainer="Jack Yaz <jackyaz@outlook.com>"

# explicitly set user/group IDs
RUN set -eux; \
	groupadd -r postgres --gid=999; \
	# https://salsa.debian.org/postgresql/postgresql-common/blob/997d842ee744687d99a2b2d95c1083a2615c79e8/debian/postgresql-common.postinst#L32-35
	useradd -r -g postgres --uid=999 --home-dir=/var/lib/postgresql --shell=/bin/bash postgres; \
	# also create the postgres user's home directory with appropriate permissions
	# see https://github.com/docker-library/postgres/issues/274
	mkdir -p /var/lib/postgresql; \
	chown -R postgres:postgres /var/lib/postgresql

RUN set -ex; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
	gnupg \
	; \
	rm -rf /var/lib/apt/lists/*

# grab gosu for easy step-down from root
# https://github.com/tianon/gosu/releases
ENV GOSU_VERSION 1.17
RUN set -eux; \
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get update; \
	apt-get install -y --no-install-recommends ca-certificates wget; \
	rm -rf /var/lib/apt/lists/*; \
	dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
	wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch"; \
	wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc"; \
	export GNUPGHOME="$(mktemp -d)"; \
	gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \
	gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \
	gpgconf --kill all; \
	rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc; \
	apt-mark auto '.*' > /dev/null; \
	[ -z "$savedAptMark" ] || apt-mark manual $savedAptMark > /dev/null; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
	chmod +x /usr/local/bin/gosu; \
	gosu --version; \
	gosu nobody true

# make the "en_US.UTF-8" locale so postgres will be utf-8 enabled by default
RUN set -eux; \
	if [ -f /etc/dpkg/dpkg.cfg.d/docker ]; then \
	# if this file exists, we're likely in "debian:xxx-slim", and locales are thus being excluded so we need to remove that exclusion (since we need locales)
	grep -q '/usr/share/locale' /etc/dpkg/dpkg.cfg.d/docker; \
	sed -ri '/\/usr\/share\/locale/d' /etc/dpkg/dpkg.cfg.d/docker; \
	! grep -q '/usr/share/locale' /etc/dpkg/dpkg.cfg.d/docker; \
	fi; \
	apt-get update; apt-get install -y --no-install-recommends locales; rm -rf /var/lib/apt/lists/*; \
	localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8
ENV LANG en_US.utf8

RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
	libnss-wrapper \
	xz-utils \
	zstd \
	; \
	rm -rf /var/lib/apt/lists/*

RUN mkdir /docker-entrypoint-initdb.d

RUN set -ex; \
	# pub   4096R/ACCC4CF8 2011-10-13 [expires: 2019-07-02]
	#       Key fingerprint = B97B 0AFC AA1A 47F0 44F2  44A0 7FCC 7D46 ACCC 4CF8
	# uid                  PostgreSQL Debian Repository
	key='B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8'; \
	export GNUPGHOME="$(mktemp -d)"; \
	mkdir -p /usr/local/share/keyrings/; \
	gpg --batch --keyserver keyserver.ubuntu.com --recv-keys "$key"; \
	gpg --batch --export --armor "$key" > /usr/local/share/keyrings/postgres.gpg.asc; \
	gpgconf --kill all; \
	rm -rf "$GNUPGHOME"

ENV PG_MAJOR 15
ENV PATH $PATH:/usr/lib/postgresql/$PG_MAJOR/bin

ENV PG_VERSION 15.6-1.pgdg120+2

RUN set -ex; \
	\
	# see note below about "*.pyc" files
	export PYTHONDONTWRITEBYTECODE=1; \
	\
	dpkgArch="$(dpkg --print-architecture)"; \
	aptRepo="[ signed-by=/usr/local/share/keyrings/postgres.gpg.asc ] http://apt.postgresql.org/pub/repos/apt/ bookworm-pgdg main $PG_MAJOR"; \
	case "$dpkgArch" in \
	amd64 | arm64 | ppc64el | s390x) \
	# arches officialy built by upstream
	echo "deb $aptRepo" > /etc/apt/sources.list.d/pgdg.list; \
	apt-get update; \
	;; \
	*) \
	# we're on an architecture upstream doesn't officially build for
	# let's build binaries from their published source packages
	echo "deb-src $aptRepo" > /etc/apt/sources.list.d/pgdg.list; \
	\
	savedAptMark="$(apt-mark showmanual)"; \
	\
	tempDir="$(mktemp -d)"; \
	cd "$tempDir"; \
	\
	# create a temporary local APT repo to install from (so that dependency resolution can be handled by APT, as it should be)
	apt-get update; \
	apt-get install -y --no-install-recommends dpkg-dev; \
	echo "deb [ trusted=yes ] file://$tempDir ./" > /etc/apt/sources.list.d/temp.list; \
	_update_repo() { \
	dpkg-scanpackages . > Packages; \
	# work around the following APT issue by using "Acquire::GzipIndexes=false" (overriding "/etc/apt/apt.conf.d/docker-gzip-indexes")
	#   Could not open file /var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages - open (13: Permission denied)
	#   ...
	#   E: Failed to fetch store:/var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages  Could not open file /var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages - open (13: Permission denied)
	apt-get -o Acquire::GzipIndexes=false update; \
	}; \
	_update_repo; \
	\
	# build .deb files from upstream's source packages (which are verified by apt-get)
	nproc="$(nproc)"; \
	export DEB_BUILD_OPTIONS="nocheck parallel=$nproc"; \
	# we have to build postgresql-common first because postgresql-$PG_MAJOR shares "debian/rules" logic with it: https://salsa.debian.org/postgresql/postgresql/-/commit/99f44476e258cae6bf9e919219fa2c5414fa2876
	# (and it "Depends: pgdg-keyring")
	apt-get build-dep -y postgresql-common pgdg-keyring; \
	apt-get source --compile postgresql-common pgdg-keyring; \
	_update_repo; \
	apt-get build-dep -y "postgresql-$PG_MAJOR=$PG_VERSION"; \
	apt-get source --compile "postgresql-$PG_MAJOR=$PG_VERSION"; \
	\
	# we don't remove APT lists here because they get re-downloaded and removed later
	\
	# reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
	# (which is done after we install the built packages so we don't have to redownload any overlapping dependencies)
	apt-mark showmanual | xargs apt-mark auto > /dev/null; \
	apt-mark manual $savedAptMark; \
	\
	ls -lAFh; \
	_update_repo; \
	grep '^Package: ' Packages; \
	cd /; \
	;; \
	esac; \
	\
	apt-get install -y --no-install-recommends postgresql-common; \
	sed -ri 's/#(create_main_cluster) .*$/\1 = false/' /etc/postgresql-common/createcluster.conf; \
	apt-get install -y --no-install-recommends \
	"postgresql-$PG_MAJOR=$PG_VERSION" \
	; \
	\
	rm -rf /var/lib/apt/lists/*; \
	\
	if [ -n "$tempDir" ]; then \
	# if we have leftovers from building, let's purge them (including extra, unnecessary build deps)
	apt-get purge -y --auto-remove; \
	rm -rf "$tempDir" /etc/apt/sources.list.d/temp.list; \
	fi; \
	\
	# some of the steps above generate a lot of "*.pyc" files (and setting "PYTHONDONTWRITEBYTECODE" beforehand doesn't propagate properly for some reason), so we clean them up manually (as long as they aren't owned by a package)
	find /usr -name '*.pyc' -type f -exec bash -c 'for pyc; do dpkg -S "$pyc" &> /dev/null || rm -vf "$pyc"; done' -- '{}' +; \
	\
	postgres --version

# make the sample config easier to munge (and "correct by default")
RUN set -eux; \
	dpkg-divert --add --rename --divert "/usr/share/postgresql/postgresql.conf.sample.dpkg" "/usr/share/postgresql/$PG_MAJOR/postgresql.conf.sample"; \
	cp -v /usr/share/postgresql/postgresql.conf.sample.dpkg /usr/share/postgresql/postgresql.conf.sample; \
	ln -sv ../postgresql.conf.sample "/usr/share/postgresql/$PG_MAJOR/"; \
	sed -ri "s!^#?(listen_addresses)\s*=\s*\S+.*!\1 = '*'!" /usr/share/postgresql/postgresql.conf.sample; \
	grep -F "listen_addresses = '*'" /usr/share/postgresql/postgresql.conf.sample

RUN mkdir -p /var/run/postgresql && chown -R postgres:postgres /var/run/postgresql && chmod 2777 /var/run/postgresql

ENV PGDATA /var/lib/postgresql/data
# this 777 will be replaced by 700 at runtime (allows semi-arbitrary "--user" values)
RUN mkdir -p "$PGDATA" && chown -R postgres:postgres "$PGDATA" && chmod 777 "$PGDATA"

# We set the default STOPSIGNAL to SIGINT, which corresponds to what PostgreSQL
# calls "Fast Shutdown mode" wherein new connections are disallowed and any
# in-progress transactions are aborted, allowing PostgreSQL to stop cleanly and
# flush tables to disk, which is the best compromise available to avoid data
# corruption.
#
# Users who know their applications do not keep open long-lived idle connections
# may way to use a value of SIGTERM instead, which corresponds to "Smart
# Shutdown mode" in which any existing sessions are allowed to finish and the
# server stops when all sessions are terminated.
#
# See https://www.postgresql.org/docs/12/server-shutdown.html for more details
# about available PostgreSQL server shutdown signals.
#
# See also https://www.postgresql.org/docs/12/server-start.html for further
# justification of this as the default value, namely that the example (and
# shipped) systemd service files use the "Fast Shutdown mode" for service
# termination.
#
STOPSIGNAL SIGINT
#
# An additional setting that is recommended for all users regardless of this
# value is the runtime "--stop-timeout" (or your orchestrator/runtime's
# equivalent) for controlling how long to wait between sending the defined
# STOPSIGNAL and sending SIGKILL (which is likely to cause data corruption).
#
# The default in most runtimes (such as Docker) is 10 seconds, and the
# documentation at https://www.postgresql.org/docs/12/server-start.html notes
# that even 90 seconds may not be long enough in many instances.

### END POSTGRES BUILD AND SETUP ###

### START MEOWTH BUILD AND SETUP ###

RUN mkdir /app
COPY --from=s2geometry /src/s2geometry/dist/*.whl /app/.

RUN apt-get update && \
	apt-get install -y --no-install-recommends \
	git \
	sudo \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*

RUN echo 'postgres  ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

RUN python3 -m venv /app/venv
ENV PATH="/app/venv/bin:$PATH"
RUN python3 -m pip install --upgrade pip

RUN python3 -m pip install /app/*.whl

COPY config /app/config
COPY database /app/database
COPY meowth /app/meowth
COPY requirements.txt /app/
COPY setup.py /app/
COPY README.md /app/
COPY LICENSE /app/

WORKDIR /app

RUN python3 -m pip install -r requirements.txt
RUN python3 setup.py install

RUN ln -s /app/config/config.py /app/meowth/config.py

WORKDIR /

### END MEOWTH BUILD AND SETUP ###

ENV PYTHONPATH="/app"

COPY entry.sh /
RUN chmod 0755 /entry.sh

VOLUME /app/config
VOLUME /var/lib/postgresql/data

EXPOSE 5432

ENTRYPOINT ["/entry.sh"]

CMD ["postgres"]
