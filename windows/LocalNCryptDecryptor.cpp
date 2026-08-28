#include "LocalNCryptDecryptor.h"

#include <bcrypt.h>
#include <ncrypt.h>
#include <windows.h>

#pragma comment(lib, "ncrypt.lib")
#pragma comment(lib, "bcrypt.lib")

namespace local_biometric {

namespace {

constexpr wchar_t kPassportProviderName[] = L"Microsoft Passport Key Storage Provider";

// Undocumented NCrypt property name. Per third-party reverse engineering of
// KeyCredentialManager's own internal behavior, setting this property on a
// key handle opened against the Passport Key Storage Provider is what causes
// the Windows Hello biometric/PIN prompt to be surfaced on subsequent key
// operations. It does not appear in any current Microsoft header or public
// documentation. See LocalNCryptDecryptor.h for the full risk disclosure.
constexpr wchar_t kNgcCacheTypeProperty[] = L"NgcCacheType";

constexpr SECURITY_STATUS kNteUserCancelled = static_cast<SECURITY_STATUS>(0x8009000C);
constexpr SECURITY_STATUS kNteNotFound = static_cast<SECURITY_STATUS>(0x80090011);
constexpr SECURITY_STATUS kNteBadKeySet = static_cast<SECURITY_STATUS>(0x80090016);

}  // namespace

NCryptDecryptResult NCryptDecryptWithPassportKey(
    const std::wstring& key_name, const std::vector<uint8_t>& ciphertext) {
  NCryptDecryptResult out;

  NCRYPT_PROV_HANDLE h_provider = 0;
  SECURITY_STATUS status =
      NCryptOpenStorageProvider(&h_provider, kPassportProviderName, 0);
  if (status != ERROR_SUCCESS) {
    out.error_kind = "not_supported";
    out.error_message =
        "Unable to open the Microsoft Passport Key Storage Provider (status=" +
        std::to_string(status) +
        "). Windows Hello decryption relies on an unsupported Windows API and "
        "is not available on this device/OS build.";
    return out;
  }

  NCRYPT_KEY_HANDLE h_key = 0;
  status = NCryptOpenKey(h_provider, &h_key, key_name.c_str(), 0, 0);
  if (status != ERROR_SUCCESS) {
    NCryptFreeObject(h_provider);
    out.error_kind =
        (status == kNteNotFound || status == kNteBadKeySet) ? "not_found" : "unknown";
    out.error_message =
        "No decryption-capable Windows Hello key found for this alias (status=" +
        std::to_string(status) + ").";
    return out;
  }

  // Best-effort attempt to arm the biometric/PIN prompt via the undocumented
  // property described above. If a future Windows build rejects this
  // property outright, fail loudly rather than silently decrypting without
  // ever having required user presence.
  DWORD cache_type = 1;  // Observed value from third-party reverse engineering; unconfirmed by Microsoft.
  SECURITY_STATUS prop_status = NCryptSetProperty(
      h_key, kNgcCacheTypeProperty, reinterpret_cast<PBYTE>(&cache_type),
      sizeof(cache_type), 0);
  if (prop_status != ERROR_SUCCESS) {
    NCryptFreeObject(h_key);
    NCryptFreeObject(h_provider);
    out.error_kind = "not_supported";
    out.error_message =
        "This Windows build rejected the undocumented Windows Hello prompt "
        "property (status=" +
        std::to_string(prop_status) + "); decryption is not available here.";
    return out;
  }

  BCRYPT_OAEP_PADDING_INFO padding_info = {};
  padding_info.pszAlgId = BCRYPT_SHA256_ALGORITHM;
  padding_info.pbLabel = nullptr;
  padding_info.cbLabel = 0;

  DWORD result_size = 0;
  status = NCryptDecrypt(h_key, const_cast<PBYTE>(ciphertext.data()),
                          static_cast<DWORD>(ciphertext.size()), &padding_info,
                          nullptr, 0, &result_size, NCRYPT_PAD_OAEP_FLAG);
  if (status != ERROR_SUCCESS || result_size == 0) {
    NCryptFreeObject(h_key);
    NCryptFreeObject(h_provider);
    out.error_kind =
        status == kNteUserCancelled ? "user_canceled" : "unknown";
    out.error_message =
        "NCryptDecrypt failed while sizing the output buffer (status=" +
        std::to_string(status) + ").";
    return out;
  }

  std::vector<uint8_t> plaintext(result_size);
  DWORD actual_size = 0;
  status = NCryptDecrypt(h_key, const_cast<PBYTE>(ciphertext.data()),
                          static_cast<DWORD>(ciphertext.size()), &padding_info,
                          plaintext.data(), result_size, &actual_size,
                          NCRYPT_PAD_OAEP_FLAG);

  NCryptFreeObject(h_key);
  NCryptFreeObject(h_provider);

  if (status != ERROR_SUCCESS) {
    out.error_kind = status == kNteUserCancelled ? "user_canceled" : "unknown";
    out.error_message = "NCryptDecrypt failed (status=" + std::to_string(status) + ").";
    return out;
  }

  plaintext.resize(actual_size);
  out.success = true;
  out.plaintext = std::move(plaintext);
  return out;
}

}  // namespace local_biometric
