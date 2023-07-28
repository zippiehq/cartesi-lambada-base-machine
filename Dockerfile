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
RUN find "/replicate/release" \
	-newermt "@1689943775" \
	-exec touch --no-dereference --date="@1689943775" '{}' +
RUN SOURCE_DATE_EPOCH=1689943775 genext2fs -N 1638400 -f -d /replicate/release -b 2097152 /replicate/image.ext2
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
RUN sha256sum /image.ext2
FROM busybox
COPY --from=debootstrap /image.ext2 /image.ext2
