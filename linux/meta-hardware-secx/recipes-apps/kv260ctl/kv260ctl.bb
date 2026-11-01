SUMMARY = "KV260 INT8 correctness and isolated E1 experiment tool"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6"
FILESEXTRAPATHS:prepend := "${THISDIR}/../../../../sw/user:${THISDIR}/../../../../sw/include:"
SRC_URI = "file://kv260ctl.c file://kv260_uapi.h file://kv260_contract.h"
S = "${WORKDIR}/sources"
UNPACKDIR = "${S}"
do_compile() {
    ${CC} ${CFLAGS} ${CPPFLAGS} -std=c11 -Wall -Wextra -I${S} ${S}/kv260ctl.c ${LDFLAGS} -o kv260ctl
}
do_install() {
    install -d ${D}${bindir}
    install -m 0755 kv260ctl ${D}${bindir}/kv260ctl
}
