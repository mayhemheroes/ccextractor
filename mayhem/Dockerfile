# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile for ccextractor (small form, on the org C/C++ base).
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile --build-arg COMMIT=$(git rev-parse HEAD) -t mytag .
FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# ccextractor needs: tesseract/leptonica (OCR), lzma (pulled in by gpac), pkg-config,
# git+curl+ca-certificates for the pinned gpac clone and rustup below.
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
      libtesseract-dev libleptonica-dev liblzma-dev pkg-config git curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Pinned Rust toolchain (the project links a Rust staticlib; upstream CI tests with cargo).
ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
 && sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal --default-toolchain 1.89.0 \
 && rm /tmp/rustup-init.sh \
 && chown -R 2000:2000 /opt/toolchains/rust

# GPAC (MP4 demux) is not packaged in debian trixie — build a pinned static libgpac in-image.
# --static-build --static-modules yields a self-consistent monolithic archive; ssl/nghttp2
# disabled so the only external deps are lzma/m/pthread/dl.
RUN git clone --depth 1 --branch v2.4.0 https://github.com/gpac/gpac.git /tmp/gpac \
 && cd /tmp/gpac \
 && ./configure --static-build --static-modules --use-zlib=no --disable-x11 --use-ssl=no --use-nghttp2=no \
 && make -j"$(nproc)" lib \
 && { make install-lib || true; } \
 && test -f /usr/local/lib/libgpac_static.a \
 && test -f /usr/local/include/gpac/isomedia.h \
 && rm -rf /tmp/gpac

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populate the cargo cache ONLINE once, so build.sh/test.sh run fully --offline
# (air-gapped re-runs use this baked cache).
RUN cd src/rust && cargo fetch && cd lib_ccxr && cargo fetch

RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
