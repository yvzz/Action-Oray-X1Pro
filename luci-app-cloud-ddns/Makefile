include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI Support for Cloud DDNS (DNSPod + AliDNS)
LUCI_DEPENDS:=+openssl-util +curl +bash
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-cloud-ddns
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=yvzz

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=$(LUCI_TITLE)
  DEPENDS:=$(LUCI_DEPENDS)
  PKGARCH:=$(LUCI_PKGARCH)
endef

define Package/$(PKG_NAME)/description
  LuCI application for managing DDNS with DNSPod (Tencent Cloud) and AliDNS (Alibaba Cloud).
  Pure ucode implementation, compatible with OpenWrt 24.10+ and ImmortalWrt 25.12+.
endef

define Build/Compile
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

define Package/$(PKG_NAME)/conffiles
/etc/config/cloud-ddns
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/share/ucode/luci/controller
	$(INSTALL_DIR) $(1)/usr/share/ucode/luci/template/cloud-ddns
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/usr/share/cloud-ddns
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_DATA) ./root/usr/share/ucode/luci/controller/cloud-ddns.uc $(1)/usr/share/ucode/luci/controller/
	$(INSTALL_DATA) ./root/usr/share/ucode/luci/template/cloud-ddns/cloud-ddns.ut $(1)/usr/share/ucode/luci/template/cloud-ddns/
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-cloud-ddns.json $(1)/usr/share/luci/menu.d/
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-cloud-ddns.json $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_BIN) ./root/etc/init.d/cloud-ddns $(1)/etc/init.d/
	$(INSTALL_DATA) ./root/etc/config/cloud-ddns $(1)/etc/config/
	$(INSTALL_BIN) ./root/usr/share/cloud-ddns/cloud-ddns.sh $(1)/usr/share/cloud-ddns/
	$(INSTALL_BIN) ./root/etc/uci-defaults/luci-cloud-ddns $(1)/etc/uci-defaults/
	$(INSTALL_BIN) ./root/etc/hotplug.d/iface/96-cloud-ddns $(1)/etc/hotplug.d/iface/
endef

$(eval $(call BuildPackage,$(PKG_NAME)))