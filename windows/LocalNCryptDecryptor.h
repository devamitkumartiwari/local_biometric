#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace local_biometric {

struct NCryptDecryptResult {
  bool success = false;
  std::vector<uint8_t> plaintext;
  // One of: "user_canceled", "not_found", "not_supported", "unknown".
  std::string error_kind;
  std::string error_message;
};

// Attempts RSA-OAEP-SHA256 decryption of `ciphertext` using the Windows
// Hello-gated key identified by `key_name`, via the low-level CNG NCrypt API
// against the "Microsoft Passport Key Storage Provider" (the same provider
// `Windows.Security.Credentials.KeyCredentialManager` uses under the hood).
//
// WARNING: unlike the rest of this plugin's Windows implementation,
// this function is NOT built on a documented, supported Microsoft API.
// KeyCredentialManager (the WinRT surface used elsewhere in this file) is
// sign-only by design and exposes no decrypt/unwrap primitive at all. Getting
// a Windows Hello-gated decrypt operation requires bypassing that WinRT
// projection and calling NCrypt directly, which in turn requires setting an
// UNDOCUMENTED property ("NgcCacheType") to arm the biometric/PIN prompt --
// there is no official Microsoft API reference for this usage. The only
// precedent for it is third-party reverse engineering of how
// KeyCredentialManager itself talks to this provider. Microsoft's own stated
// guidance is to use KeyCredentialManager instead (sign-only).
//
// This means: this code path may behave inconsistently across Windows
// versions/builds, and may stop working entirely after a future Windows
// update, without any changelog entry warning of the change. Callers
// (including this plugin's own DecryptPayload) must treat failures here as
// expected/possible, not as bugs, and must not assume this path is as
// reliable as the KeyCredentialManager-based sign path.
NCryptDecryptResult NCryptDecryptWithPassportKey(
    const std::wstring& key_name, const std::vector<uint8_t>& ciphertext);

}  // namespace local_biometric
