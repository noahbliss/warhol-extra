# warhol_asi

Installs Google's Android System Intelligence as a privileged `/product` app together with its stock
privapp-permissions allowlist (see `module.prop` for what it enables).

**The APK is not included.** It is Google's and is not redistributed here. Copy it
from the stock HyperOS `product` image (same path, minus `system/product/`) to
`system/product/priv-app/AndroidSystemIntelligence/AndroidSystemIntelligence.apk`
before zipping the module.
