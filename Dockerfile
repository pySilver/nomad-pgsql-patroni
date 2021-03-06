############################
# Build tools binaries in separate image
############################
ARG GO_VERSION=1.12.7
FROM golang:${GO_VERSION} AS tools

ENV TOOLS_VERSION 0.7.0

RUN mkdir -p ${GOPATH}/src/github.com/timescale/ \
    && cd ${GOPATH}/src/github.com/timescale/ \
    && git clone https://github.com/timescale/timescaledb-tune.git \
    && git clone https://github.com/timescale/timescaledb-parallel-copy.git \
    # Build timescaledb-tune
    && cd timescaledb-tune/cmd/timescaledb-tune \
    && git fetch && git checkout --quiet $(git describe --abbrev=0) \
    && go get -d -v \
    && go build -o /go/bin/timescaledb-tune \
    # Build timescaledb-parallel-copy
    && cd ${GOPATH}/src/github.com/timescale/timescaledb-parallel-copy/cmd/timescaledb-parallel-copy \
    && git fetch && git checkout --quiet $(git describe --abbrev=0) \
    && go get -d -v \
    && go build -o /go/bin/timescaledb-parallel-copy

############################
# Build TimescaleDB
############################
ARG PG_MAJOR=11
FROM postgres:11.7 AS build

ENV TIMESCALEDB_VERSION 1.6.0

RUN \
    set -x \
    && buildDeps="curl build-essential ca-certificates git python gnupg libc++-dev libc++abi-dev pkg-config glib2.0 cmake libssl-dev" \
    && apt-get update -y \
    && apt-get install -y --no-install-recommends ${buildDeps} \
    && apt-get install -y --no-install-recommends postgresql-server-dev-$PG_MAJOR \
    && mkdir -p /tmp/build \
    && curl -o /tmp/build/timescaledb-${TIMESCALEDB_VERSION}.tar.lzma -SL "https://github.com/timescale/timescaledb/releases/download/${TIMESCALEDB_VERSION}/timescaledb-${TIMESCALEDB_VERSION}.tar.lzma" \
    && cd /tmp/build \
    && tar xf /tmp/build/timescaledb-${TIMESCALEDB_VERSION}.tar.lzma -C /tmp/build/ \
    && cd /tmp/build/timescaledb \
    && ./bootstrap -DPROJECT_INSTALL_METHOD="docker" -DAPACHE_ONLY=1 -DREGRESS_CHECKS=OFF \
    && cd build \
    && make \
    && make install \
    && ls -l /usr/lib/postgresql/${PG_MAJOR}/lib/ \
    && strip /usr/lib/postgresql/${PG_MAJOR}/lib/timescaledb.so \
    && strip /usr/lib/postgresql/${PG_MAJOR}/lib/timescaledb-${TIMESCALEDB_VERSION}.so
    # && strip /usr/lib/postgresql/${PG_MAJOR}/lib/timescaledb-tsl-${TIMESCALEDB_VERSION}.so

############################
# Final image with Patroni
############################
FROM postgres:11.7

ENV POSTGIS_MAJOR 3
ENV TIMESCALEDB_VERSION 1.6.0

COPY --from=tools /go/bin/* /usr/local/bin/
COPY --from=build /usr/lib/postgresql/${PG_MAJOR}/lib/timescale*.so /usr/lib/postgresql/${PG_MAJOR}/lib/
COPY --from=build /usr/share/postgresql/${PG_MAJOR}/extension/timescaledb.control /usr/share/postgresql/${PG_MAJOR}/extension/timescaledb.control
COPY --from=build /usr/share/postgresql/${PG_MAJOR}/extension/timescaledb--${TIMESCALEDB_VERSION}.sql /usr/share/postgresql/${PG_MAJOR}/extension/timescaledb--${TIMESCALEDB_VERSION}.sql

RUN set -x \
    && apt-get update -y \
    && apt-cache showpkg postgresql-$PG_MAJOR-postgis-$POSTGIS_MAJOR \
    && apt-get install -y --no-install-recommends \
        postgresql-$PG_MAJOR-postgis-$POSTGIS_MAJOR \
        postgresql-$PG_MAJOR-postgis-$POSTGIS_MAJOR-scripts \
        postgis \
        postgresql-$PG_MAJOR-pgrouting \
        gcc curl python3-dev libpython3-dev libyaml-dev \
    \
    # Install Patroni
    && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-setuptools \
    && pip3 install awscli python-consul psycopg2-binary \
    && pip3 install https://github.com/zalando/patroni/archive/v1.6.4.zip \
    \
    # Install WAL-G
    && curl -LO https://github.com/wal-g/wal-g/releases/download/v0.2.14/wal-g.linux-amd64.tar.gz \
    && tar xf wal-g.linux-amd64.tar.gz \
    && rm -f wal-g.linux-amd64.tar.gz \
    && mv wal-g /usr/local/bin/ \
    \
    # Cleanup
    && rm -rf /var/lib/apt/lists/* \
    \
    # Specify UID/GID
    # && usermod -u 70 postgres \
    # && groupmod -g 70 postgres \
    && gpasswd -a postgres root
    # && chown --recursive 70:70 /var/run/postgresql \
    # && chown --recursive 70:70 /var/lib/postgresql

RUN mkdir -p /docker-entrypoint-initdb.d
COPY ./files/000_shared_libs.sh /docker-entrypoint-initdb.d/000_shared_libs.sh
COPY ./files/001_initdb_postgis.sh /docker-entrypoint-initdb.d/001_initdb_postgis.sh
COPY ./files/002_install_timescaledb.sh /docker-entrypoint-initdb.d/002_install_timescaledb.sh
COPY ./files/003_timescaledb_tune.sh /docker-entrypoint-initdb.d/003_timescaledb_tune.sh

COPY ./files/update-postgis.sh /usr/local/bin
COPY ./files/docker-initdb.sh /usr/local/bin

EXPOSE 8008
EXPOSE 5432

USER postgres
CMD ["patroni", "/secrets/patroni.yml"]
