obj-m += kv260_lab.o
ccflags-y += -I$(src)/../include -I$(src)
KDIR ?= $(if $(KERNEL_SRC),$(KERNEL_SRC),/lib/modules/$(shell uname -r)/build)
all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
modules_install:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules_install
