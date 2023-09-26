FROM ubuntu:jammy@sha256:b060fffe8e1561c9c3e6dea6db487b900100fc26830b9ea2ec966c151ab4c020 AS genext2fs-build
RUN apt-get update && apt-get install -y git=1:2.34.1-1ubuntu1.10
RUN git clone https://github.com/cartesi/genext2fs /genext2fs && cd /genext2fs && git checkout v1.5.2 && ./make-debian

FROM ubuntu:jammy@sha256:b060fffe8e1561c9c3e6dea6db487b900100fc26830b9ea2ec966c151ab4c020 AS build
ENV TZ=UTC
ENV LC_ALL=C
ENV LANG=C.UTF-8
ENV LC_CTYPE=C.UTF-8
ENV SOURCE_DATE_EPOCH=1689943775

RUN apt-get update && apt-get install -y debootstrap=1.0.126+nmu1ubuntu0.5 patch=2.7.6-7build2 libarchive13 e2tools
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
RUN cd / && \
    wget -O /replicate/release/sbin/repro-get https://github.com/reproducible-containers/repro-get/releases/download/v0.4.0/repro-get-v0.4.0.linux-riscv64 && \
    echo "adce2c200d53774517c4c1d9a659e4f5a889dae8b74f1e01eac3af80322c32bb  /replicate/release/sbin/repro-get" | sha256sum -c - && \
    chmod 755 /replicate/release/sbin/repro-get

RUN find "/replicate/release" \
	-newermt "@1689943775" \
	-exec touch --no-dereference --date="@1689943775" '{}' +
RUN tar --sort=name -C /replicate/release -cf - . > /replicate/release.tar
RUN HOSTNAME=linux SOURCE_DATE_EPOCH=1689943775 genext2fs -z -v -v -N 1638400 -f -a /replicate/release.tar -B 4096 -b 2097152 /replicate/image.ext2 2>&1 > /tool-image.gen
RUN ls -al /replicate/image.ext2
RUN rm -rf /replicate/release /replicate/release.tar

COPY extract-tar /tool-image/install
RUN tar --sort=name -C /tool-image -cf - . > /tool-image.tar && rm -rf /tool-image
RUN HOSTNAME=linux SOURCE_DATE_EPOCH=1689943775 genext2fs -z -v -v -N 1638400 -f -a /tool-image.tar -B 4096 -b 2097152 /extract-rootfs.img 2>&1 > /tool-image.gen
RUN rm /tool-image.tar

COPY --from=cartesi/linux-kernel:0.16.0 /opt/riscv/kernel/artifacts/linux-5.15.63-ctsi-2.bin /usr/share/cartesi-machine/images/linux.bin
RUN wget -O /usr/share/cartesi-machine/images/rom.bin https://github.com/cartesi/machine-emulator-rom/releases/download/v0.16.0/rom-v0.16.0.bin

FROM cartesi/machine-emulator:0.15@sha256:bc4e65ed6dde506b7476a751ad9cda2fb136cbad655ff80df3180ca45444e440 AS cartesi-base
COPY --from=build /replicate/image.ext2 /image.ext2
COPY --from=build /usr/share/cartesi-machine/images /usr/share/cartesi-machine/images
USER root

FROM cartesi-base AS debootstrap-image
RUN cartesi-machine --skip-root-hash-check --append-rom-bootargs="loglevel=8 init=/debootstrap/bootstrap" --flash-drive=label:root,filename:/image.ext2,shared --ram-length=2Gi
RUN sha256sum /image.ext2

FROM debootstrap-image AS extract-rootfs-image
COPY --from=build /extract-rootfs.img /extract-rootfs.img
RUN cartesi-machine --skip-root-hash-check --append-rom-bootargs="loglevel=8 init=/sbin/install-from-mtdblock1" --flash-drive=label:root,filename:/image.ext2 --flash-drive=label:out,filename:/extract-rootfs.img,shared --ram-length=2Gi

FROM build AS extracted-rootfs
COPY --from=extract-rootfs-image /extract-rootfs.img /extract-rootfs.img
RUN e2cp /extract-rootfs.img:/rootfs.tar /rootfs.tar && mkdir -p /rootfs && cd /rootfs && tar xf /rootfs.tar && rm -rf /rootfs.tar

FROM scratch AS riscv-base
COPY --from=extracted-rootfs /rootfs /
RUN apt-get update && apt-get install -y build-essential git strace
RUN mkdir -p /etc/repro-get
RUN repro-get hash generate --dedupe=/etc/repro-get/SHA256SUMS-riscv64 > /etc/repro-get/SHA256SUMS-riscv64-new
RUN GOMAXPROCS=1 repro-get download /etc/repro-get/SHA256SUMS-riscv64-new

FROM build AS aptget-setup
RUN rm -rf /tool-image
COPY install-pkgs /tool-image/install
RUN chmod 755 /tool-image/install

COPY --from=riscv-base /var/cache/repro-get /tool-image/repro-get-cache
COPY --from=riscv-base /etc/repro-get/SHA256SUMS-riscv64-new /tool-image/SHA256SUMS-riscv64-new
RUN find /tool-image -exec touch --no-dereference --date="@1689943775" '{}' +
RUN tar --sort=name -C /tool-image -cf - . > /tool-image.tar && rm -rf /tool-image && HOSTNAME=linux SOURCE_DATE_EPOCH=1689943775 genext2fs -z -v -v -N 1638400 -f -a /tool-image.tar -B 4096 -b 2097152 /tool-image.img 2>&1 > /tool-image.gen
RUN sha256sum /tool-image.img

FROM cartesi-base AS aptget-image
COPY --from=debootstrap-image /image.ext2 /image.ext2
COPY --from=aptget-setup /tool-image.img /tool-image.img
RUN cartesi-machine --skip-root-hash-check --append-rom-bootargs="loglevel=8 init=/sbin/install-from-mtdblock1" --flash-drive=label:root,filename:/image.ext2,shared --flash-drive=label:out,filename:/tool-image.img --ram-length=2Gi
RUN rm -rf /tool-image.img
RUN sha256sum /image.ext2

FROM build AS rust-image-prep
RUN wget https://github.com/cartesi/machine-emulator-tools/releases/download/v0.12.0/machine-emulator-tools-v0.12.0.deb && \
     echo "901e8343f7f2fe68555eb9f523f81430aa41487f9925ac6947e8244432396b3a machine-emulator-tools-v0.12.0.deb" | sha256sum -c -
RUN wget https://static.rust-lang.org/dist/rust-1.71.1-riscv64gc-unknown-linux-gnu.tar.gz && \
     echo "fcb67647b764669f3b4e61235fbdc0eca287229adf9aed8c41ce20ffaad4a3ea  rust-1.71.1-riscv64gc-unknown-linux-gnu.tar.gz" | sha256sum -c -

 RUN mkdir -p /tool-image
 RUN echo '#!/bin/sh\n\
export PATH=/bin:/usr/bin:/sbin:/usr/sbin\n\
dpkg -i /mnt/machine-emulator-tools-v0.12.0.deb\n\
tar -xzf /mnt/rust-1.71.1-riscv64gc-unknown-linux-gnu.tar.gz\n\
sh /rust-1.71.1-riscv64gc-unknown-linux-gnu/install.sh\n\
rm -rf /rust-1.71.1-riscv64gc-unknown-linux-gnu/' > /tool-image/install \
     && chmod +x /tool-image/install
RUN mv rust-1.71.1-riscv64gc-unknown-linux-gnu.tar.gz /tool-image/
RUN mv machine-emulator-tools-v0.12.0.deb /tool-image
RUN find /tool-image -exec touch --no-dereference --date="@1689943775" '{}' +
RUN tar --sort=name -C /tool-image -cf - . > /tool-image.tar && rm -rf /tool-image
RUN HOSTNAME=linux SOURCE_DATE_EPOCH=1689943775 genext2fs -z -v -v -N 1638400 -f -a /tool-image.tar -B 4096 -b 2097152 /install-disk.img 2>&1 > /tool-image.gen
RUN rm -rf /tool-image /tool-image.tar

FROM cartesi-base AS rust-install-image
COPY --from=aptget-image /image.ext2 /image.ext2
COPY --from=rust-image-prep /install-disk.img /install-disk.img
RUN cartesi-machine \
    --skip-root-hash-check \
    --append-rom-bootargs="loglevel=8 init=/sbin/install-from-mtdblock1" \
    --flash-drive="label:root,filename:/image.ext2,shared" \
    --flash-drive="label:install,filename:/install-disk.img" \
    --ram-length=2Gi | tee /log
RUN rm -rf /install-disk.img
RUN sha256sum /image.ext2

FROM rust:1.58 AS rust-build

RUN mkdir -p /tool-image

RUN apt-get update && apt-get install -y git=1:2.30.2-1+deb11u2 && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN git clone --bare https://github.com/nyakiomaina/reproducible-builds.git /tool-image/bare-repo && \
     ls -al /tool-image

RUN find /tool-image/bare-repo -exec touch --no-dereference --date="@1689943775" '{}' +

RUN git clone /tool-image/bare-repo /my-workspace && \
     cd /my-workspace && \
     curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- --default-toolchain 1.58.0 -y

ENV PATH="/root/.cargo/bin:${PATH}"

RUN cd /my-workspace && cargo vendor

#transfer everything to the /tool-image directory
RUN cp -R /my-workspace/vendor /tool-image/vendored-sources && \
    echo '#!/bin/sh\nexport PATH=/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin\n\
/opt/cartesi/bin/rndaddentropy < /opt/cartesi/bin/rndaddentropy\n\
git clone /mnt/bare-repo /build-workspace\n\
mkdir -p /build-workspace/.cargo && \
echo "[source.crates-io]" > /build-workspace/.cargo/config.toml && \
echo "replace-with = \"vendored-sources\"" >> /build-workspace/.cargo/config.toml && \
echo "" >> /build-workspace/.cargo/config.toml && \
echo "[source.vendored-sources]" >> /build-workspace/.cargo/config.toml && \
echo "directory = \"vendor\"" >> /build-workspace/.cargo/config.toml && \
mkdir -p /build-workspace/vendor\n\
cp -Rv /mnt/vendored-sources/* /build-workspace/vendor\n\
echo building\n\
cd /build-workspace && cargo build --release --locked --verbose && echo Done' > /tool-image/install &&\
    chmod +x /tool-image/install


FROM build AS rust-build-image-prep
COPY --from=rust-build /tool-image /tool-image

RUN find /tool-image -exec touch --no-dereference --date="@1689943775" '{}' +
RUN tar --sort=name -C /tool-image -cf - . > /tool-image.tar && rm -rf /tool-image
RUN HOSTNAME=linux SOURCE_DATE_EPOCH=1689943775 genext2fs -z -v -v -N 1638400 -f -a /tool-image.tar -B 4096 -b 2097152 /install-disk.img 2>&1 > /tool-image.gen

FROM cartesi-base AS rust-build-image
COPY --from=rust-install-image /image.ext2 /image.ext2
COPY --from=rust-build-image-prep /install-disk.img /install-disk.img

RUN cartesi-machine \
    --skip-root-hash-check \
    --append-rom-bootargs="loglevel=8 init=/sbin/install-from-mtdblock1" \
    --flash-drive="label:root,filename:/image.ext2,shared" \
    --flash-drive="label:install,filename:/install-disk.img" \
    --ram-length=2Gi | tee /log

RUN sha256sum /image.ext2

FROM busybox
COPY --from=rust-build-image /image.ext2 /image.ext2