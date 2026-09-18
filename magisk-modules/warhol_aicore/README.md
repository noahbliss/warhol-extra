# warhol_aicore

Installs Google's AiCore stub as a privileged `/product` app together with its stock
privapp-permissions allowlist (see `module.prop` for what it enables).

**The APK is not included.** It is Google's and is not redistributed here. Copy it
from the stock HyperOS `product` image (same path, minus `system/product/`) to
`system/product/priv-app/AiCore/AiCore.apk`
before zipping the module.
