SUMMARY = "KV260 private-buffer DMA lifecycle laboratory driver"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6"
inherit module
FILESEXTRAPATHS:prepend := "${THISDIR}/../../../../sw/kernel:${THISDIR}/../../../../sw/include:"
SRC_URI = "file://kv260_lab.c file://Makefile file://kv260_uapi.h file://kv260_contract.h"
S = "${WORKDIR}/sources"
UNPACKDIR = "${S}"
EXTRA_OEMAKE += "KDIR=${STAGING_KERNEL_DIR}"
# Deliberate: do not autoload until matching FPGA image/DT has been installed.
