include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-cloud-ddns
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=yvzz

LUCI_TITLE:=LuCI Support for Cloud DDNS (DNSPod + AliDNS)
LUCI_DEPENDS:=+openssl-util +curl +bash
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/conffiles
/etc/config/cloud-ddns
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] || exit 0
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
/etc/init.d/cloud-ddns stop >/dev/null 2>&1
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
