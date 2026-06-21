# Makefile -- cp210x out-of-tree kernel module
#
# Build:  make                 (builds against the running kernel)
# Clean:  make clean
# Override target kernel:  make KREL=6.12.75+rpt-rpi-2712
#                          make KDIR=/lib/modules/<ver>/build
 
obj-m += cp210x.o
 
# Running kernel by default; overridable on the command line (used by the
# /etc/kernel/postinst.d hook to build for a freshly installed kernel).
KREL ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KREL)/build
 
# $(CURDIR) is a GNU Make built-in (the working directory). Unlike $(PWD) it
# does not depend on the PWD environment variable being exported.
SRCDIR := $(CURDIR)
 
all:
	$(MAKE) -C $(KDIR) M=$(SRCDIR) modules
 
clean:
	$(MAKE) -C $(KDIR) M=$(SRCDIR) clean
 
.PHONY: all clean
