include $(TOPDIR)/rules.mk

PKG_NAME:=luci-i18n-rtp2httpd-zh-cn
PKG_VERSION:=3.17.1
PKG_RELEASE:=r1

# Chinese (zh-cn) translation for luci-app-rtp2httpd, shipped as the upstream prebuilt
# .ipk (compiled .lmo + uci-defaults). No compilation required.
PKG_SOURCE:=$(PKG_NAME)_$(PKG_VERSION)-$(PKG_RELEASE)_all.ipk
PKG_SOURCE_URL:=https://github.com/stackia/rtp2httpd/releases/download/v$(PKG_VERSION)
PKG_HASH:=af9139dde605fa1636acbf4e8d4268af2d892cbeda17b8dd046202331be052ca

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=4. Translations
  TITLE:=Translation for rtp2httpd (Chinese)
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  Chinese (zh-cn) translation files for luci-app-rtp2httpd.
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
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/usr/lib/lua/luci/i18n/rtp2httpd.zh-cn.lmo $(1)/usr/lib/lua/luci/i18n/
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/etc/uci-defaults/luci-i18n-rtp2httpd-zh-cn $(1)/etc/uci-defaults/
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
