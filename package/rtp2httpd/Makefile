include $(TOPDIR)/rules.mk

PKG_NAME:=rtp2httpd
PKG_VERSION:=3.17.1
PKG_RELEASE:=r1

# rtp2httpd is written in Rust. Compiling it from source inside the OpenWrt build
# would pull in the rust/host toolchain and re-trigger the download-ci-llvm 404 /
# slow-LLVM problem we already fixed. Instead we ship the official prebuilt musl
# binary published on the upstream release page (immutable, SHA256-pinned below).
# Build target: aarch64_cortex-a53 (MediaTek MT7981 / Oray X1 Pro).
PKG_SOURCE:=$(PKG_NAME)_$(PKG_VERSION)-$(PKG_RELEASE)_aarch64_cortex-a53.ipk
PKG_SOURCE_URL:=https://github.com/stackia/rtp2httpd/releases/download/v$(PKG_VERSION)
PKG_HASH:=4ad830b9e1d45318ef6bc659b9a404b22ac2dd103ab35e50aca470d66cd4f1bd

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/rtp2httpd
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Multicast RTP/RTSP to Unicast HTTP stream converter (prebuilt)
  URL:=https://github.com/stackia/rtp2httpd
endef

define Package/rtp2httpd/description
  rtp2httpd converts RTP/UDP/RTSP media into HTTP stream and acts as a tiny HTTP
  server for IPTV multicast-to-unicast forwarding. This package ships the official
  prebuilt musl binary for aarch64_cortex-a53; no Rust compilation is performed.
endef

define Package/rtp2httpd/conffiles
/etc/config/rtp2httpd
/etc/rtp2httpd.conf
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)/ipk
	tar -xzf $(DL_DIR)/$(PKG_SOURCE) -C $(PKG_BUILD_DIR)/ipk
	mkdir -p $(PKG_BUILD_DIR)/root
	tar -xzf $(PKG_BUILD_DIR)/ipk/data.tar.gz -C $(PKG_BUILD_DIR)/root
endef

define Build/Compile
endef

define Package/rtp2httpd/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/bin/rtp2httpd $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/etc/init.d/rtp2httpd $(1)/etc/init.d/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/root/etc/config/rtp2httpd $(1)/etc/config/
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/root/etc/rtp2httpd.conf $(1)/etc/
endef

$(eval $(call BuildPackage,rtp2httpd))
