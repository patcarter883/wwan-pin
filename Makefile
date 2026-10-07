include $(TOPDIR)/rules.mk

PKG_NAME:=wwan-pin
PKG_VERSION:=1.0.0
PKG_RELEASE:=3
include $(INCLUDE_DIR)/package.mk

define Package/wwan-pin
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Stable interface names for cellular modems
  # ip-full is what /sbin/ip already points at on the target, so this is
  # satisfiable for an offline install. rename_netdev does not exist in the
  # kernel; the rename itself is a plain RTM_NEWLINK via `ip link set name`.
  DEPENDS:=+ip-full
  PKGARCH:=all
endef

define Package/wwan-pin/description
  Names each cellular modem's netdev after the UCI interface that declares its
  USB port, so the name follows the physical port rather than the kernel's probe
  order. Without this the same modem can come up as wwan1 after a replug, which
  silently points rist2rist's miface= (the interface the encoder selects as its
  output destination) and wan-failover's member list at the wrong radio.
endef

# No build step: this is shell only.
define Build/Compile
endef

define Package/wwan-pin/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/wwan-pin $(1)/usr/sbin/wwan-pin

	$(INSTALL_DIR) $(1)/etc/hotplug.d/net
	$(INSTALL_BIN) ./files/30-wwan-pin $(1)/etc/hotplug.d/net/30-wwan-pin
endef

$(eval $(call BuildPackage,wwan-pin))
