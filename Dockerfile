# syntax=docker/dockerfile:1.4

# This is intended **DEVELOPMENT ONLY**, i.e. so that proxy developers can
# easily test the proxy in the context of the larger `linkerd2` project.

ARG RUST_IMAGE=ghcr.io/linkerd/dev:v47-rust

# Use an arbitrary ~recent edge release image to get the proxy
# identity-initializing and linkerd-await wrappers.
ARG LINKERD2_IMAGE=ghcr.io/linkerd/proxy:edge-23.11.2

FROM $LINKERD2_IMAGE as linkerd2

FROM --platform=$BUILDPLATFORM $RUST_IMAGE as fetch

ARG PROXY_FEATURES=""
# apt-get step removed (INFRA-19879 custom build): it only installed `time`
# (verbose build timing) and golang (meshtls-boring only, unused here), and the
# dev image's Debian snapshot fails GPG verification in 2026.

ENV CARGO_NET_RETRY=10
ENV RUSTUP_MAX_RETRIES=10

WORKDIR /src
COPY . .
RUN --mount=type=cache,id=cargo,target=/usr/local/cargo/registry \
    just fetch

# Build the proxy.
FROM fetch as build
ENV CARGO_INCREMENTAL=0
ENV RUSTFLAGS="-D warnings -A deprecated --cfg tokio_unstable"
ARG TARGETARCH="amd64"
ARG PROFILE="release"
ARG LINKERD2_PROXY_VERSION=""
ARG LINKERD2_PROXY_VENDOR=""
SHELL ["/bin/bash", "-c"]
RUN --mount=type=cache,id=cargo,target=/usr/local/cargo/registry \
    if [[ "$PROXY_FEATURES" =~ .*pprof.* ]] ; then cmd=build-debug ; else cmd=build ; fi ; \
    just arch="$TARGETARCH" features="$PROXY_FEATURES" profile="$PROFILE" "$cmd" && \
    ( mkdir -p /out ; \
        mv $(just --evaluate profile="$PROFILE" _target_bin) /out/ ; \
        du -sh /out/* )

# Install the proxy binary into a base image that we can at least get a shell
# for debugging.
FROM docker.io/library/debian:bookworm-slim as runtime
WORKDIR /linkerd
COPY --from=linkerd2 /usr/lib/linkerd/* /usr/lib/linkerd/
COPY --from=build /out/* /usr/lib/linkerd/
ENTRYPOINT ["/usr/lib/linkerd/linkerd2-proxy-identity"]
