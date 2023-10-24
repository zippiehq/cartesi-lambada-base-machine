FROM ubuntu:jammy@sha256:b060fffe8e1561c9c3e6dea6db487b900100fc26830b9ea2ec966c151ab4c020 AS genext2fs-build
RUN apt-get update && apt-get install -y ca-certificates
RUN printf "deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/20230928T000000Z jammy main restricted universe multiverse\ndeb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/20230928T000000Z jammy-updates main restricted universe multiverse\n" > /etc/apt/sources.list
RUN apt-get update && apt-get install -y git=1:2.34.1-1ubuntu1.10
RUN git clone https://github.com/cartesi/genext2fs /genext2fs && cd /genext2fs && git checkout v1.5.2 && ./make-debian

FROM golang:1.21 as kubo-build
RUN apt-get update && apt-get install -y llvm

WORKDIR /app

RUN git clone https://github.com/ipfs/kubo -b v0.23.0

WORKDIR /app/kubo
RUN go mod download
COPY ./sys_linux_riscv64.go /go/pkg/mod/github.com/marten-seemann/tcp\@v0.0.0-20210406111302-dfbc87cc63fd/sys_linux_riscv64.go
RUN GOOS=linux GOARCH=riscv64 CGO_ENABLED=0 GOFLAGS="-ldflags=-s-w -trimpath" make nofuse
RUN sha256sum /app/kubo/cmd/ipfs/ipfs
RUN llvm-strip -s /app/kubo/cmd/ipfs/ipfs

FROM ubuntu:jammy@sha256:b060fffe8e1561c9c3e6dea6db487b900100fc26830b9ea2ec966c151ab4c020 AS build
RUN apt-get update && apt-get install -y ca-certificates
RUN printf "deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/20230928T000000Z jammy main restricted universe multiverse\ndeb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/20230928T000000Z jammy-updates main restricted universe multiverse\n" > /etc/apt/sources.list
RUN apt-get update && apt-get install -y debootstrap=1.0.126+nmu1ubuntu0.5 patch=2.7.6-7build2 libarchive13 e2tools
ENV TZ=UTC
ENV LC_ALL=C
ENV LANG=C.UTF-8
ENV LC_CTYPE=C.UTF-8
ENV SOURCE_DATE_EPOCH=1695938400

COPY --from=genext2fs-build /genext2fs/genext2fs.deb /genext2fs.deb
RUN dpkg -i /genext2fs.deb
RUN debootstrap --include=wget --foreign --arch riscv64 jammy /replicate/release https://snapshot.ubuntu.com/ubuntu/20230928T000000Z
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
RUN tar --sort=name -C /replicate/release -cf - . > /replicate/release.tar
RUN HOSTNAME=linux SOURCE_DATE_EPOCH=1695938400 genext2fs -z -v -v -f -a /replicate/release.tar -B 4096 /replicate/source.ext2 2>&1 > /tool-image.gen
RUN ls -al /replicate/source.ext2
RUN rm -rf /replicate/release /replicate/release.tar

COPY extract-tar /tool-image/install
RUN tar --sort=name -C /tool-image -cf - . > /tool-image.tar && rm -rf /tool-image
RUN HOSTNAME=linux SOURCE_DATE_EPOCH=1695938400 genext2fs -z -v -v -f -a /tool-image.tar -B 4096 /extract-rootfs.img 2>&1 > /tool-image.gen
RUN rm /tool-image.tar

COPY --from=cartesi/linux-kernel:0.16.0 /opt/riscv/kernel/artifacts/linux-5.15.63-ctsi-2.bin /usr/share/cartesi-machine/images/linux.bin
RUN wget -O /usr/share/cartesi-machine/images/rom.bin https://github.com/cartesi/machine-emulator-rom/releases/download/v0.16.0/rom-v0.16.0.bin
#20230928T000000Z
FROM cartesi/machine-emulator:0.15.2@sha256:bc4e65ed6dde506b7476a751ad9cda2fb136cbad655ff80df3180ca45444e440 AS cartesi-base
COPY --from=build /replicate/source.ext2 /source.ext2
COPY --from=build /usr/share/cartesi-machine/images /usr/share/cartesi-machine/images
USER root

FROM cartesi-base AS debootstrap-image
RUN truncate -s 8G /image.ext2
# run copy
RUN cartesi-machine --skip-root-hash-check --append-rom-bootargs="loglevel=8 init=/debootstrap/copy" --flash-drive=label:root,filename:/source.ext2 --flash-drive=label:dest,filename:/image.ext2,shared --ram-length=2Gi
# actually debootstrap
RUN cartesi-machine --skip-root-hash-check --append-rom-bootargs="loglevel=8 init=/debootstrap/bootstrap" --flash-drive=label:root,filename:/image.ext2,shared --ram-length=2Gi

FROM debootstrap-image AS extract-rootfs-image
COPY --from=build /extract-rootfs.img /extract-rootfs.img
RUN truncate -s 5G /extracted-rootfs.img
RUN cartesi-machine --skip-root-hash-check --append-rom-bootargs="loglevel=8 init=/sbin/install-from-mtdblock1" --flash-drive=label:root,filename:/image.ext2 --flash-drive=label:install,filename:/extract-rootfs.img --flash-drive=label:out,filename:/extracted-rootfs.img,shared --ram-length=2Gi

FROM build AS extracted-rootfs
COPY --from=extract-rootfs-image /extracted-rootfs.img /extracted-rootfs.img
RUN e2cp /extracted-rootfs.img:/rootfs.tar /rootfs.tar && mkdir -p /rootfs && cd /rootfs && tar xf /rootfs.tar && rm -rf /rootfs.tar && rm -f /extracted-rootfs.img

FROM scratch AS riscv-base
COPY --from=extracted-rootfs /rootfs /
RUN printf "deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/20230928T000000Z jammy main restricted universe multiverse\ndeb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/20230928T000000Z jammy-updates main restricted universe multiverse\n" > /etc/apt/sources.list
RUN mkdir -p /mirror && cd /mirror && apt-get update --print-uris | cut -d "'" -f 2 | wget -nv --mirror -i - || true && cd /
RUN cd /mirror && apt-get update && apt-get install -qq --print-uris docker.io curl busybox python3-requests | cut -d "'" -f 2 | wget -nv --mirror -i - || true && cd /

FROM build AS aptget-setup
RUN rm -rf /tool-image
COPY install-pkgs /tool-image/install
RUN chmod 755 /tool-image/install
COPY --from=kubo-build /app/kubo/cmd/ipfs/ipfs /tool-image/ipfs
RUN chmod 755 /tool-image/ipfs
COPY --from=riscv-base /mirror /tool-image/mirror

#RUN wget https://github.com/cartesi/machine-emulator-tools/releases/download/v0.12.0/machine-emulator-tools-v0.12.0.deb && \
#     echo "901e8343f7f2fe68555eb9f523f81430aa41487f9925ac6947e8244432396b3a machine-emulator-tools-v0.12.0.deb" | sha256sum -c -
#RUN mv machine-emulator-tools-v0.12.0.deb /tool-image
COPY ./machine-emulator-tools-v0.12.0.deb /tool-image/machine-emulator-tools-v0.12.0.deb
RUN find /tool-image -exec touch --no-dereference --date="@1695938400" '{}' +
RUN tar --sort=name -C /tool-image -cf - . > /tool-image.tar && rm -rf /tool-image && HOSTNAME=linux SOURCE_DATE_EPOCH=1695938400 genext2fs -z -v -v -f -a /tool-image.tar -B 4096 -b 2097152 /tool-image.img 2>&1 > /tool-image.gen

FROM debootstrap-image AS aptget-image
COPY --from=aptget-setup /tool-image.img /tool-image.img
RUN cartesi-machine --skip-root-hash-check --append-rom-bootargs="loglevel=8 init=/sbin/install-from-mtdblock1" --flash-drive=label:root,filename:/image.ext2,shared --flash-drive=label:out,filename:/tool-image.img --ram-length=2Gi
RUN rm -rf /tool-image.img
RUN sha256sum /image.ext2

FROM busybox
COPY --from=aptget-image /image.ext2 /image.ext2