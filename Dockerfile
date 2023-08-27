FROM ubuntu:jammy@sha256:b060fffe8e1561c9c3e6dea6db487b900100fc26830b9ea2ec966c151ab4c020 AS genext2fs-build
RUN apt-get update && apt-get install -y git
RUN git clone https://github.com/cartesi/genext2fs /genext2fs && cd /genext2fs && git checkout v1.5.2 && ./make-debian

FROM ubuntu:jammy@sha256:b060fffe8e1561c9c3e6dea6db487b900100fc26830b9ea2ec966c151ab4c020 AS build

RUN apt-get update && apt-get install -y debootstrap=1.0.126+nmu1ubuntu0.5 patch=2.7.6-7build2 libarchive13
COPY --from=genext2fs-build /genext2fs/genext2fs.deb /genext2fs.deb
RUN dpkg -i /genext2fs.deb
COPY debootstrap.patch /debootstrap.patch
RUN patch -p1 < /debootstrap.patch
RUN rm -rf /debootstrap.patch*
COPY InRelease /replicate/InRelease
RUN LOCAL_INRELEASE_PATH=/replicate/InRelease debootstrap --include psmisc --foreign --arch riscv64 jammy /replicate/release
RUN rm -rf /replicate/release/debootstrap/debootstrap.log
RUN touch /replicate/release/debootstrap/debootstrap.log
RUN echo -n "ubuntu" > /replicate/release/etc/hostname
COPY bootstrap /replicate/release/debootstrap/bootstrap
RUN chmod 755 /replicate/release/debootstrap/bootstrap
RUN echo "nameserver 127.0.0.1" > /replicate/release/etc/resolv.conf
RUN rm -df /replicate/release/proc
RUN mkdir -p /replicate/release/proc
RUN chmod 555 /replicate/release/proc
COPY additional /replicate/release/sbin/install-from-mtdblock1
RUN chmod 755 /replicate/release/sbin/install-from-mtdblock1
RUN cd / && wget -O /replicate/release/sbin/repro-get https://github.com/reproducible-containers/repro-get/releases/download/v0.4.0/repro-get-v0.4.0.linux-riscv64 && chmod 755 /replicate/release/sbin/repro-get

RUN find "/replicate/release" \
	-newermt "@1689943775" \
	-exec touch --no-dereference --date="@1689943775" '{}' +
RUN SOURCE_DATE_EPOCH=1689943775 genext2fs -N 1638400 -f -d /replicate/release -B 4096 -b 4194304 /replicate/image.ext2
RUN sha256sum /replicate/image.ext2

FROM ubuntu:22.04 AS debootstrap

RUN apt-get update && DEBIAN_FRONTEND="noninteractive" apt-get install -y \
    libboost-coroutine1.74.0 \
    libboost-context1.74.0 \
    libboost-filesystem1.74.0 \
    libreadline8 \
    openssl \
    libc-ares2 \
    zlib1g \
    ca-certificates \
    libgomp1 \
    lua5.3 \
    genext2fs \
    libb64-0d \
    libcrypto++8 \
    wget \
    && rm -rf /var/lib/apt/lists/*

COPY --from=cartesi/machine-emulator@sha256:02fede36987b5eb5cc698f9fe281eb1ef2c56cd07cdbf982a4401095ffe0129b /opt/cartesi /opt/cartesi
COPY --from=cartesi/machine-emulator@sha256:02fede36987b5eb5cc698f9fe281eb1ef2c56cd07cdbf982a4401095ffe0129b /usr/local/lib/lua /usr/local/lib/lua
COPY --from=cartesi/machine-emulator@sha256:02fede36987b5eb5cc698f9fe281eb1ef2c56cd07cdbf982a4401095ffe0129b /usr/local/share/lua /usr/local/share/lua
COPY --from=cartesi/toolchain:0.14.0 /opt/riscv /opt/riscv
COPY --from=cartesi/linux-kernel:0.16.0 /opt/riscv/kernel/artifacts/linux-5.15.63-ctsi-2.bin /opt/cartesi/share/images/linux.bin
RUN \
    wget -O /opt/cartesi/share/images/rom.bin https://github.com/cartesi/machine-emulator-rom/releases/download/v0.16.0/rom-v0.16.0.bin

COPY --from=build /replicate/image.ext2 /image.ext2
RUN /opt/cartesi/bin/cartesi-machine --append-rom-bootargs="loglevel=8 init=/debootstrap/bootstrap" --flash-drive=label:root,filename:/image.ext2,shared --ram-length=2Gi

RUN apt-get update && apt-get install -y e2tools
COPY extract-tar /tool-image/install

RUN SOURCE_DATE_EPOCH=1689943775 genext2fs -N 1638400 -f -d /tool-image -b 2097152 /tool-image.img
RUN /opt/cartesi/bin/cartesi-machine --append-rom-bootargs="loglevel=8 init=/sbin/install-from-mtdblock1" --flash-drive=label:root,filename:/image.ext2 --flash-drive=label:out,filename:/tool-image.img,shared --ram-length=2Gi
RUN e2cp tool-image.img:/rootfs.tar /rootfs.tar
RUN mkdir -p /rootfs && cd /rootfs && tar xf /rootfs.tar

FROM scratch AS riscv-base
COPY --from=debootstrap /rootfs /
FROM riscv-base AS riscv-install
RUN apt-get update && apt-get install -y build-essential git
RUN mkdir -p /etc/repro-get
RUN repro-get hash generate --dedupe=/etc/repro-get/SHA256SUMS-riscv64 > /etc/repro-get/SHA256SUMS-riscv64-new
RUN repro-get download /etc/repro-get/SHA256SUMS-riscv64-new
FROM debootstrap AS pkg-install
COPY install-pkgs /tool-image/install
COPY --from=riscv-install /var/cache/repro-get /tool-image/repro-get-cache
COPY --from=riscv-install /etc/repro-get/SHA256SUMS-riscv64-new /tool-image/SHA256SUMS-riscv64-new

RUN SOURCE_DATE_EPOCH=1689943775 genext2fs -N 1638400 -f -d /tool-image -b 2097152 /tool-image.img
RUN /opt/cartesi/bin/cartesi-machine --append-rom-bootargs="loglevel=8 init=/sbin/install-from-mtdblock1" --flash-drive=label:root,filename:/image.ext2,shared --flash-drive=label:out,filename:/tool-image.img --ram-length=2Gi
RUN rm -rf /tool-image /tool-image.img

# ---- install rust here
RUN wget https://static.rust-lang.org/dist/rust-1.71.1-riscv64gc-unknown-linux-gnu.tar.gz
RUN echo "fcb67647b764669f3b4e61235fbdc0eca287229adf9aed8c41ce20ffaad4a3ea  rust-1.71.1-riscv64gc-unknown-linux-gnu.tar.gz" | sha256sum -c -

RUN mkdir -p /tool-image
RUN echo '#!/bin/sh\n\
tar -xzf /mnt/rust-1.71.1-riscv64gc-unknown-linux-gnu.tar.gz\n\
sh /rust-1.71.1-riscv64gc-unknown-linux-gnu/install.sh\n\
rm -rf /rust-1.71.1-riscv64gc-unknown-linux-gnu/' > /tool-image/install \
    && chmod +x /tool-image/install
RUN mv rust-1.71.1-riscv64gc-unknown-linux-gnu.tar.gz /tool-image/

RUN SOURCE_DATE_EPOCH=1689943775 genext2fs -N 1638400 -f -d /tool-image -b 2097152 /install-disk.img

RUN /opt/cartesi/bin/cartesi-machine \
    --append-rom-bootargs="loglevel=8 init=/sbin/install-from-mtdblock1" \
    --flash-drive="label:root,filename:/image.ext2",shared \
    --flash-drive="label:install,filename:/install-disk.img" \
    --ram-length=2Gi | tee /log

RUN sha256sum /image.ext2

FROM rust:1.58 AS rust-build

RUN mkdir -p /tool-image

RUN apt-get update && apt-get install -y git

RUN git clone --bare https://github.com/nyakiomaina/reproducible-builds.git /tool-image/bare-repo && \
    ls -al /tool-image

RUN git clone /tool-image/bare-repo /my-workspace && \
    cd /my-workspace && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

ENV PATH="/root/.cargo/bin:${PATH}"

RUN cd /my-workspace && cargo vendor

#transfer everything to the /tool-image directory
RUN cp -R /my-workspace/vendor /tool-image/vendored-sources && \
    echo '#!/bin/sh\nexport PATH=/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin\n\
git clone /mnt/bare-repo /build-workspace\n\
mkdir -p /build-workspace/.cargo && \
echo "[source.crates-io]" > /build-workspace/.cargo/config.toml && \
echo "replace-with = \"vendored-sources\"" >> /build-workspace/.cargo/config.toml && \
echo "" >> /build-workspace/.cargo/config.toml && \
echo "[source.vendored-sources]" >> /build-workspace/.cargo/config.toml && \
echo "directory = \"vendor\"" >> /build-workspace/.cargo/config.toml && \
cp -R /mnt/vendored-sources/* /build-workspace/vendor/\n\
echo building\n\
cd /build-workspace && cargo build --release --verbose && echo Done' > /tool-image/install &&\
    chmod +x /tool-image/install
FROM pkg-install

COPY --from=rust-build /tool-image /tool-image

RUN SOURCE_DATE_EPOCH=1689943775 genext2fs -N 1638400 -f -d /tool-image -b 2097152 /install-disk.img

RUN /opt/cartesi/bin/cartesi-machine \
    --append-rom-bootargs="loglevel=8 init=/sbin/install-from-mtdblock1" \
    --flash-drive="label:root,filename:/image.ext2" \
    --flash-drive="label:install,filename:/install-disk.img" \
    --ram-length=2Gi | tee /log