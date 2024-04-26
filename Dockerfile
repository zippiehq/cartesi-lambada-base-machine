FROM --platform=linux/amd64 ghcr.io/zippiehq/cartesi-lambada-kernel:main AS kernel

FROM ubuntu:jammy@sha256:b060fffe8e1561c9c3e6dea6db487b900100fc26830b9ea2ec966c151ab4c020 AS genext2fs-build
RUN apt-get update && apt-get install -y ca-certificates
RUN printf "deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/20231201T000000Z jammy main restricted universe multiverse\ndeb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/20231201T000000Z jammy-updates main restricted universe multiverse\n" > /etc/apt/sources.list
RUN apt-get update && apt-get install -y git
RUN git clone https://github.com/cartesi/genext2fs /genext2fs && cd /genext2fs && git checkout v1.5.2 && ./make-debian

FROM golang:1.21 as kubo-build
RUN apt-get update && apt-get install -y llvm libgpgme-dev libassuan-dev libbtrfs-dev libdevmapper-dev pkg-config

WORKDIR /app

RUN git clone https://github.com/zippiehq/cartesi-kubo -b ipfs-cartesi kubo && cd kubo && git checkout a9042bef91cf09f140bbf38034dca486d752d3f8

RUN git clone https://github.com/containerd/nerdctl && cd nerdctl && git checkout v1.7.3 && GOOS=linux GOARCH=riscv64 make binaries

RUN git clone https://github.com/containerd/stargz-snapshotter && cd stargz-snapshotter && git checkout v0.15.1 && GOOS=linux GOARCH=riscv64 make containerd-stargz-grpc && GOOS=linux GOARCH=riscv64 make ctr-remote 

RUN llvm-strip -s /app/nerdctl/_output/nerdctl
RUN llvm-strip -s /app/stargz-snapshotter/out/containerd-stargz-grpc
RUN llvm-strip -s /app/stargz-snapshotter/out/ctr-remote

WORKDIR /app/kubo
RUN go mod download
COPY ./sys_linux_riscv64.go /go/pkg/mod/github.com/marten-seemann/tcp\@v0.0.0-20210406111302-dfbc87cc63fd/sys_linux_riscv64.go
RUN GOOS=linux GOARCH=riscv64 CGO_ENABLED=0 GOFLAGS="-ldflags=-s-w -trimpath" make nofuse IPFS_PLUGINS="ds_http"
RUN llvm-strip -s /app/kubo/cmd/ipfs/ipfs


FROM ubuntu:jammy@sha256:b060fffe8e1561c9c3e6dea6db487b900100fc26830b9ea2ec966c151ab4c020 AS build
RUN apt-get update && apt-get install -y ca-certificates
RUN printf "deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/20231201T000000Z jammy main restricted universe multiverse\ndeb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/20231201T000000Z jammy-updates main restricted universe multiverse\n" > /etc/apt/sources.list
RUN apt-get update && apt-get install -y debootstrap patch libarchive13 e2tools
ENV TZ=UTC
ENV LC_ALL=C
ENV LANG=C.UTF-8
ENV LC_CTYPE=C.UTF-8
ENV SOURCE_DATE_EPOCH=1695938400

COPY --from=genext2fs-build /genext2fs/genext2fs.deb /genext2fs.deb
RUN dpkg -i /genext2fs.deb
RUN debootstrap --include=wget,busybox-static --foreign --arch riscv64 jammy /replicate/release https://snapshot.ubuntu.com/ubuntu/20231201T000000Z
RUN rm -rf /replicate/release/debootstrap/debootstrap.log
RUN touch /replicate/release/debootstrap/debootstrap.log
RUN echo -n "ubuntu" > /replicate/release/etc/hostname
COPY bootstrap /replicate/release/debootstrap/bootstrap
COPY copy /replicate/release/debootstrap/copy
RUN chmod 755 /replicate/release/debootstrap/bootstrap
RUN chmod 755 /replicate/release/debootstrap/copy
RUN echo "nameserver 127.0.0.1" > /replicate/release/etc/resolv.conf
RUN rm -df /replicate/release/proc
RUN mkdir -p /replicate/release/proc
RUN chmod 555 /replicate/release/proc
COPY additional /replicate/release/sbin/install-from-mtdblock1
RUN chmod 755 /replicate/release/sbin/install-from-mtdblock1

RUN find "/replicate/release" \
	-newermt "@1695938400" \
	-exec touch --no-dereference --date="@1695938400" '{}' +
RUN tar --sort=name -C /replicate/release -vcf - . > /replicate/release.tar
RUN HOSTNAME=linux SOURCE_DATE_EPOCH=1695938400 genext2fs -z -v -v -f -a /replicate/release.tar -B 4096 /replicate/source.ext2 2>&1 > /tool-image.gen
RUN ls -al /replicate/source.ext2
RUN rm -rf /replicate/release /replicate/release.tar

COPY extract-tar /tool-image/install
RUN tar --sort=name -C /tool-image -cf - . > /tool-image.tar && rm -rf /tool-image
RUN HOSTNAME=linux SOURCE_DATE_EPOCH=1695938400 genext2fs -z -v -v -f -a /tool-image.tar -B 4096 /extract-rootfs.img 2>&1 > /tool-image.gen
RUN rm /tool-image.tar


COPY --from=kernel /opt/riscv/kernel/artifacts/linux-6.5.13-ctsi-1-v0.20.0.bin /usr/share/cartesi-machine/images/linux.bin
#20231201T000000Z
FROM cartesi/machine-emulator:0.17.0 AS cartesi-base
COPY --from=build /replicate/source.ext2 /source.ext2
COPY --from=build /usr/share/cartesi-machine/images /usr/share/cartesi-machine/images
USER root

FROM cartesi-base AS debootstrap-image
RUN truncate -s 2G /image.ext2
# run copy
RUN cartesi-machine --skip-root-hash-check --append-bootargs="loglevel=8 init=/debootstrap/copy ro" --flash-drive=label:root,filename:/source.ext2 --flash-drive=label:dest,filename:/image.ext2,shared --ram-length=2Gi || true
# actually debootstrap
RUN cartesi-machine --skip-root-hash-check --append-bootargs="loglevel=8 init=/debootstrap/bootstrap" --flash-drive=label:root,filename:/image.ext2,shared --ram-length=2Gi

FROM debootstrap-image AS extract-rootfs-image
COPY --from=build /extract-rootfs.img /extract-rootfs.img
RUN truncate -s 2G /extracted-rootfs.img
RUN cartesi-machine --skip-root-hash-check --append-bootargs="loglevel=8 init=/sbin/install-from-mtdblock1" --flash-drive=label:root,filename:/image.ext2 --flash-drive=label:install,filename:/extract-rootfs.img --flash-drive=label:out,filename:/extracted-rootfs.img,shared --ram-length=2Gi

FROM build AS extracted-rootfs
COPY --from=extract-rootfs-image /extracted-rootfs.img /extracted-rootfs.img
RUN e2cp /extracted-rootfs.img:/rootfs.tar /rootfs.tar && mkdir -p /rootfs && cd /rootfs && tar xf /rootfs.tar && rm -rf /rootfs.tar && rm -f /extracted-rootfs.img

FROM --platform=linux/riscv64 scratch AS riscv-base
COPY --from=extracted-rootfs /rootfs /
RUN printf "deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/20231201T000000Z jammy main restricted universe multiverse\ndeb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/20231201T000000Z jammy-updates main restricted universe multiverse\n" > /etc/apt/sources.list
RUN mkdir -p /mirror && cd /mirror && apt-get update --print-uris | cut -d "'" -f 2 | wget -nv --mirror -i - || true && cd /
RUN cd /mirror && apt-get update && apt-get install -qq --print-uris --no-install-recommends containerd fuse3 crun curl strace jq | cut -d "'" -f 2 | wget -nv --mirror -i - || true && cd /

FROM build AS aptget-setup
RUN rm -rf /tool-image
COPY install-pkgs /tool-image/install
RUN chmod 755 /tool-image/install
COPY --from=kubo-build /app/kubo/cmd/ipfs/ipfs /tool-image/ipfs
COPY ipfs-config /tool-image/ipfs-config
RUN chmod 555 /tool-image/ipfs-config
RUN chmod 755 /tool-image/ipfs
COPY --from=riscv-base /mirror /tool-image/mirror

RUN wget https://github.com/zippiehq/cartesi-lambada-guest-tools/releases/download/v0.15.0.1/machine-emulator-tools-v0.15.0.deb && mv machine-emulator-tools-v0.15.0.deb /tool-image/
RUN find /tool-image -exec touch --no-dereference --date="@1695938400" '{}' +
RUN tar --sort=name -C /tool-image -cf - . > /tool-image.tar && rm -rf /tool-image && HOSTNAME=linux SOURCE_DATE_EPOCH=1695938400 genext2fs -z -v -v -f -a /tool-image.tar -B 4096 -b 524288 /tool-image.img 2>&1 > /tool-image.gen
COPY ./install-pkgs-2 /tool-image/install
COPY --from=kubo-build /app/nerdctl/_output/nerdctl /tool-image/nerdctl
COPY --from=kubo-build /app/stargz-snapshotter/out/containerd-stargz-grpc /tool-image/containerd-stargz-grpc
COPY --from=kubo-build /app/stargz-snapshotter/out/ctr-remote /tool-image/ctr-remote
COPY --from=kubo-build /app/stargz-snapshotter/script/config /tool-image/stargz-config
RUN du -s -h /tool-image

RUN chmod 755 /tool-image/install
RUN find /tool-image -exec touch --no-dereference --date="@1695938400" '{}' +
RUN du -s -h /tool-image
RUN tar --sort=name -C /tool-image -cf - . > /tool-image.tar && rm -rf /tool-image && HOSTNAME=linux SOURCE_DATE_EPOCH=1695938400 genext2fs -z -v -v -f -a /tool-image.tar -B 4096 -b 524288 /tool-image2.img 2>&1 > /tool-image.gen

FROM debootstrap-image AS aptget-image
COPY --from=aptget-setup /tool-image.img /tool-image.img
COPY --from=kernel /opt/riscv/kernel/artifacts/linux-6.5.13-ctsi-1-v0.20.0.bin ./artifacts/linux.bin
RUN cartesi-machine --ram-image=./artifacts/linux.bin --skip-root-hash-check --append-bootargs="loglevel=8 init=/sbin/install-from-mtdblock1" --flash-drive=label:root,filename:/image.ext2,shared --flash-drive=label:out,filename:/tool-image.img --ram-length=2Gi
COPY --from=aptget-setup /tool-image2.img /tool-image2.img
RUN truncate -s 800M /clean-image.ext2 && cartesi-machine --skip-root-hash-check --append-bootargs="loglevel=8 init=/sbin/install-from-mtdblock1" --flash-drive=label:root,filename:/image.ext2 --flash-drive=label:out,filename:/tool-image2.img --flash-drive=label:clean,filename:/clean-image.ext2,shared --ram-length=2Gi && rm -rf /tool-image.img && rm -rf /tool-image2.img && rm -rf /image.ext2

RUN cartesi-machine --skip-root-hash-check --append-bootargs="no4lvl loglevel=8 init=/usr/sbin/lambada-preinit systemd.unified_cgroup_hierarchy=0 rootfstype=ext4 ro CARTESI_TMPFS_SIZE=1G systemd.journald.forward_to_console=1" \
     --ram-image=./artifacts/linux.bin --flash-drive="label:root,filename:/clean-image.ext2" --flash-drive="label:app,length:10Mi"  --ram-length=2Gi --store=/lambada-base-machine-presparse \
     --max-mcycle=0 && \
     cp -v --sparse=always -r /lambada-base-machine-presparse /lambada-base-machine && rm -rf /lambada-base-machine-presparse && \
     tar --sparse --hole-detection=seek -zvcf /lambada-base-machine.tar.gz /lambada-base-machine && rm -rf /lambada-base-machine /tool-image* && \
     du -s -h /lambada-base-machine.tar.gz
RUN tar -zcf /base-machine.tar.gz ./artifacts /clean-image.ext2
ARG ARCH=amd64
RUN apt-get update && apt-get install -y curl && curl -LO https://github.com/ipfs/kubo/releases/download/v0.24.0/kubo_v0.24.0_linux-$ARCH.tar.gz && tar -xvzf kubo_v0.24.0_linux-$ARCH.tar.gz && bash kubo/install.sh && rm -rf kubo kubo_v0.24.0_linux-$ARCH.tar.gz
RUN cd / && tar -vxf /lambada-base-machine.tar.gz && ipfs init && ipfs add --cid-version=1 --raw-leaves=false -r -Q /lambada-base-machine > /tmp/cid && (ipfs dag export `cat /tmp/cid` | gzip -9c > /lambada-base-machine.car.gz) && rm -rf $HOME/.ipfs && rm -rf /lambada-machine
FROM busybox
COPY --from=aptget-image /lambada-base-machine.tar.gz /lambada-base-machine.tar.gz
COPY --from=aptget-image /base-machine.tar.gz /base-machine.tar.gz
COPY --from=aptget-image /lambada-base-machine.car.gz /lambada-base-machine.car.gz
#RUN sha256sum /image.ext2

#FROM busybox
#COPY --from=aptget-image /image.ext2 /image.ext2