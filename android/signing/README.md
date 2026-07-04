# LLB upload signing

`llb-upload.jks` is the **stable** keystore for every `LLB.apk` published from CI.

Android only installs an APK as an **update** (keeping data) when the package id
and the signing certificate match the installed app. This keystore must not be
rotated casually — changing it forces users to uninstall and lose local data.

Passwords live in `keystore.properties` (committed on purpose for this personal
sideload pipeline). Do not reuse this key for Play Store publishing.
