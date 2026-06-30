## 0.0.2

* Enhanced biometric lockout handling for both iOS and Android.
* Added support for distinguishing between temporary (30s) and permanent lockouts on Android.
* Implemented proactive lockout detection that alerts users immediately on page load.
* Added a unified "Unlock with Passcode" recovery flow for both simple and encrypted authentication.
* Refined native iOS mapping for biometric lockout codes (-7 and -8).
* Fixed UI overflow issues in the example app and improved status reporting.
* Improved Android build configuration with unified JVM targets and modern Kotlin DSL.

## 0.0.1

* Initial release of `local_biometric`.
* Added support for Simple Biometric Authentication (`verifyPresence`).
* Added support for Encrypted Biometric Authentication with RSA/ECDSA signatures.
* Added multi-page example app.
* Standardized error codes across platforms.
