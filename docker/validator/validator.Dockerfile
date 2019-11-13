FROM debian:buster AS toolchain

# To use http/https proxy while building, use:
# docker build --build-arg https_proxy=http://fwdproxy:8080 --build-arg http_proxy=http://fwdproxy:8080

RUN echo "deb http://deb.debian.org/debian buster-backports main" > /etc/apt/sources.list.d/backports.list \
    && apt-get update && apt-get install -y cmake curl clang git \
    && apt-get clean && rm -r /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain none
ENV PATH "$PATH:/root/.cargo/bin"

WORKDIR /libra
COPY rust-toolchain /libra/rust-toolchain
RUN rustup install $(cat rust-toolchain)

FROM toolchain AS builder

# Do docker dependency only build
# This uses a custom plugin that creates a "shadow" copy of the repository
# that only includes the dependencies.
# This allows us to cache the dependencies in a docker layer for faster builds.

# To generate new shadow check in, follow these steps:
# 1) Install plugin:
#    cargo install --force --git https://github.com/metajack/cargo-create-deponly-shadow
# 2) Run it from the repo root to create shadow files:
#    cargo create-deponly-shadow --output-dir docker/shadow
# 
# For now we will just run this periodically by hand

# Copy shadow files into docker
COPY docker/shadow /libra

# Run shadow build using custom target-dir
RUN cargo build --release --target-dir /tmp/docker-target -p libra-node

# Cleanup just in case
RUN rm -rf /libra/*

# Copy in source and remove shadow files
COPY . /libra
RUN rm -rf docker/shadow

# This is needed to force cargo to rebuild everything, otherwise
# it sometimes thinks files are old and haven't changed
# (The + tells find to use the maximum command line length)
RUN find /libra -exec touch {} +


# Do real final build
RUN cargo build --release --target-dir /tmp/docker-target -p libra-node
# Trim down image size
RUN cd /tmp/docker-target/release && rm -rf build deps examples incremental


### Production Image ###
FROM debian:buster AS prod

RUN mkdir -p /opt/libra/bin /opt/libra/etc
COPY docker/install-tools.sh /root
COPY --from=builder /tmp/docker-target/release/libra-node /opt/libra/bin

# Admission control
EXPOSE 8000
# Validator network
EXPOSE 6180
# Metrics
EXPOSE 9101

# Capture backtrace on error
ENV RUST_BACKTRACE 1

# Define SEED_PEERS, NODE_CONFIG, NETWORK_KEYPAIRS, CONSENSUS_KEYPAIR, GENESIS_BLOB and PEER_ID environment variables when running
COPY docker/validator/docker-run.sh /
CMD /docker-run.sh

ARG BUILD_DATE
ARG GIT_REV
ARG GIT_UPSTREAM

LABEL org.label-schema.schema-version="1.0"
LABEL org.label-schema.build-date=$BUILD_DATE
LABEL org.label-schema.vcs-ref=$GIT_REV
LABEL vcs-upstream=$GIT_UPSTREAM
