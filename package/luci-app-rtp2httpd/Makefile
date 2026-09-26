include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-rtp2httpd
PKG_VERSION:=3.17.1
PKG_RELEASE:=r1

# Pure JavaScript LuCI app (menu + ACL + view) shipped as the upstream prebuilt .ipk.
# No Rust, no compilation. Depends on the prebuilt rtp2httpd package below.
PKG_SOURCE:=$(PKG_NAME)_$(PKG_VERSION)-$(PKG_RELEASE)_all.ipk
PKG_SOURCE_URL:=https://github.com/stackia/rtp2httpd/releases/download/v$(PKG_VERSION)
PKG_HASH:=f8292be44c77569efe124888dc09ed5b9dcbe4547f8e0f3b557ee984d0be5327

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

LUCI_DEPENDS:=+rtp2httpd

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI Support for rtp2httpd
  DEPENDS:=$(LUCI_DEPENDS)
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  LuCI web interface for rtp2httpd (IPTV multicast-to-HTTP converter). Appears under
  the "Services" menu once the rtp2httpd service package is installed.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)/ipk
	tar -xzf $(DL_DIR)/$(PKG_SOURCE) -C $(PKG_BUILD_DIR)/ipk
	mkdir -p $(PKG_BUILD_DIR)/root
	tar -xzf $(PKG_BUILD_DIR)/ipk/data.tar.gz -C $(PKG_BUILD_DIR)/root
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/root/usr/share/luci/menu.d/luci-app-rtp2httpd.json $(1)/usr/share/luci/menu.d/
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/root/usr/share/rpcd/acl.d/luci-app-rtp2httpd.json $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/www/luci-static/resources/view/rtp2httpd.js $(1)/www/luci-static/resources/view/
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
