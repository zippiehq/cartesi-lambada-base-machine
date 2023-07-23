FROM ubuntu:jammy@sha256:b060fffe8e1561c9c3e6dea6db487b900100fc26830b9ea2ec966c151ab4c020

RUN apt-get update && apt-get install -y debootstrap=1.0.126+nmu1ubuntu0.5 genext2fs=1.5.0-2
COPY functions /usr/share/debootstrap/functions
COPY InRelease /replicate/InRelease
RUN LOCAL_INRELEASE_PATH=/replicate/InRelease debootstrap --foreign --arch riscv64 jammy /replicate/release
RUN rm -rf /replicate/release/debootstrap/debootstrap.log
RUN touch /replicate/release/debootstrap/debootstrap.log
RUN echo -n "ubuntu" > /replicate/release/etc/hostname
COPY bootstrap /replicate/release/debootstrap/bootstrap
RUN chmod +x /replicate/release/debootstrap/bootstrap
RUN find "/replicate/release" \
	-newermt "@1689943775" \
	-exec touch --no-dereference --date="@1689943775" '{}' +
RUN SOURCE_DATE_EPOCH=1689943775 genext2fs -N 1638400 -f -d /replicate/release -b 2097152 /replicate/image.ext2
RUN sha256sum /replicate/image.ext2

#RUN mksquashfs /replicate/release /replicate/release.squashfs -all-time 1689943775 -reproducible -mkfs-time 0
#RUN sha256sum /replicate/release.squashfs
