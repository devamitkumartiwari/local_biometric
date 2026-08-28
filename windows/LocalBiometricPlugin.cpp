#include "local_biometric_api.g.h"

#include <flutter/plugin_registrar_windows.h>
#include <windows.h>

#include <memory>
#include <string>
#include <vector>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Security.Credentials.h>
#include <winrt/Windows.Security.Cryptography.h>
#include <winrt/Windows.Storage.Streams.h>

#include "LocalNCryptDecryptor.h"

using namespace winrt::Windows::Security::Credentials;
using namespace winrt::Windows::Security::Cryptography;
using namespace winrt::Windows::Storage::Streams;

namespace local_biometric {

namespace {

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return std::wstring();
  int size = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), result.data(), size);
  return result;
}

std::string WideToUtf8(std::wstring_view s) {
  if (s.empty()) return std::string();
  int size = WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0, nullptr, nullptr);
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), result.data(), size, nullptr, nullptr);
  return result;
}

std::wstring KeyAliasToName(const std::string* key_alias) {
  return key_alias ? Utf8ToWide(*key_alias) : L"LocalDefault";
}

std::string PemWrap(const std::string& base64_body, const char* label) {
  std::string pem = "-----BEGIN ";
  pem += label;
  pem += "-----\n";
  for (size_t i = 0; i < base64_body.size(); i += 64) {
    pem += base64_body.substr(i, 64);
    pem += "\n";
  }
  pem += "-----END ";
  pem += label;
  pem += "-----\n";
  return pem;
}

std::string HexEncode(const std::vector<uint8_t>& bytes) {
  static const char kHex[] = "0123456789abcdef";
  std::string out;
  out.reserve(bytes.size() * 2);
  for (uint8_t b : bytes) {
    out.push_back(kHex[b >> 4]);
    out.push_back(kHex[b & 0xF]);
  }
  return out;
}

std::vector<uint8_t> HexDecode(const std::string& hex) {
  auto hex_val = [](char c) -> int {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return 0;
  };
  std::vector<uint8_t> out;
  out.reserve(hex.size() / 2);
  for (size_t i = 0; i + 1 < hex.size(); i += 2) {
    out.push_back(static_cast<uint8_t>((hex_val(hex[i]) << 4) | hex_val(hex[i + 1])));
  }
  return out;
}

std::vector<uint8_t> BufferToBytes(IBuffer const& buffer) {
  auto reader = DataReader::FromBuffer(buffer);
  std::vector<uint8_t> bytes(buffer.Length());
  if (!bytes.empty()) {
    reader.ReadBytes(bytes);
  }
  return bytes;
}

IBuffer BytesToBuffer(const std::vector<uint8_t>& bytes) {
  DataWriter writer;
  writer.WriteBytes(bytes);
  return writer.DetachBuffer();
}

std::string Base64Encode(const std::vector<uint8_t>& bytes) {
  return WideToUtf8(CryptographicBuffer::EncodeToBase64String(BytesToBuffer(bytes)).c_str());
}

std::vector<uint8_t> Base64Decode(const std::string& s) {
  return BufferToBytes(CryptographicBuffer::DecodeFromBase64String(winrt::to_hstring(s)));
}

// Formats key/signature bytes per an IdentityKeyFormat/IdentitySignatureFormat
// ordinal. `has_pem` distinguishes IdentityKeyFormat (0=base64,1=pem,2=hex,3=raw)
// from IdentitySignatureFormat/IdentityPayloadFormat (0=base64,1=hex,2=raw).
// "raw" is treated the same as base64 for this String-typed output, matching
// the Android/iOS convention (real raw bytes are only exposed via the
// separate *_bytes fields, which this plugin does not yet populate -- see
// the file-level TODO note near IdentitySignatureResult below).
std::string FormatBytes(const std::vector<uint8_t>& bytes, int format_ordinal, bool has_pem,
                         const char* pem_label) {
  if (has_pem) {
    switch (format_ordinal) {
      case 1:  // pem
        return PemWrap(Base64Encode(bytes), pem_label);
      case 2:  // hex
        return HexEncode(bytes);
      default:  // base64 or raw
        return Base64Encode(bytes);
    }
  }
  switch (format_ordinal) {
    case 1:  // hex
      return HexEncode(bytes);
    default:  // base64 or raw
      return Base64Encode(bytes);
  }
}

std::vector<uint8_t> DecodePayload(const std::string& payload, int payload_format_ordinal) {
  switch (payload_format_ordinal) {
    case 1:  // hex
      return HexDecode(payload);
    case 2:  // raw (utf8 bytes)
      return std::vector<uint8_t>(payload.begin(), payload.end());
    default:  // base64
      return Base64Decode(payload);
  }
}

IdentityError MapKeyCredentialStatus(KeyCredentialStatus status) {
  switch (status) {
    case KeyCredentialStatus::Success:
      return IdentityError::kSuccess;
    case KeyCredentialStatus::UserCanceled:
      return IdentityError::kUserCanceled;
    case KeyCredentialStatus::UserPrefersPassword:
      return IdentityError::kNotSupported;
    case KeyCredentialStatus::CredentialAlreadyExists:
      return IdentityError::kKeyAlreadyExists;
    case KeyCredentialStatus::SecurityDeviceLocked:
      return IdentityError::kLockedOut;
    case KeyCredentialStatus::NotFound:
      return IdentityError::kKeyNotFound;
    case KeyCredentialStatus::UnknownError:
    default:
      return IdentityError::kUnknown;
  }
}

}  // namespace

class LocalBiometricPlugin : public flutter::Plugin, public LocalBiometricApi {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
    auto plugin = std::make_unique<LocalBiometricPlugin>();
    LocalBiometricApi::SetUp(registrar->messenger(), plugin.get());
    registrar->AddPlugin(std::move(plugin));
  }

  LocalBiometricPlugin() {}

  void CheckAvailability(std::function<void(ErrorOr<IdentityAvailability> reply)> result) override {
    KeyCredentialManager::IsSupportedAsync().Completed([result](auto const& op, auto status) {
      IdentityAvailability res;
      if (status == winrt::Windows::Foundation::AsyncStatus::Completed) {
        bool supported = op.GetResults();
        res.set_can_authenticate(supported);
        res.set_has_enrolled_biometrics(supported);
      }
      result(res);
    });
  }

  void EnrollIdentity(const std::string* keyAlias, const IdentityEnrollmentConfig* config,
                       const IdentityKeyFormat& keyFormat, const std::string* promptMessage,
                       std::function<void(ErrorOr<IdentityEnrollmentResult> reply)> result) override {
    auto name = KeyAliasToName(keyAlias);
    auto option = (config && config->fail_if_exists() && *config->fail_if_exists())
                      ? KeyCredentialCreationOption::FailIfExists
                      : KeyCredentialCreationOption::ReplaceExisting;

    KeyCredentialManager::RequestCreateAsync(name, option).Completed([result](auto const& op, auto status) {
      IdentityEnrollmentResult res;
      if (status == winrt::Windows::Foundation::AsyncStatus::Completed) {
        auto createResult = op.GetResults();
        if (createResult.Status() == KeyCredentialStatus::Success) {
          res.set_code(IdentityError::kSuccess);
          res.set_algorithm("RSA");
          res.set_key_size(2048);
        } else {
          res.set_code(MapKeyCredentialStatus(createResult.Status()));
        }
      } else {
        res.set_code(IdentityError::kUnknown);
      }
      result(res);
    });
  }

  // NOTE: `signature`/`public_key` are populated as formatted strings
  // (base64/pem/hex per the requested format) rather than via the separate
  // *_bytes Uint8List fields -- KeyCredential's WinRT surface only exposes
  // IBuffer results, and wiring those into the pigeon-generated *_bytes
  // setters is not covered by this fix; the String fields are what every
  // existing example/README usage on this plugin already reads.
  void SignPayload(const std::string& payload, const std::string* keyAlias,
                    const IdentitySignatureConfig* config, const IdentitySignatureFormat& signatureFormat,
                    const IdentityKeyFormat& keyFormat, const std::string* promptMessage,
                    std::function<void(ErrorOr<IdentitySignatureResult> reply)> result) override {
    SignInternal(std::vector<uint8_t>(payload.begin(), payload.end()), keyAlias, signatureFormat,
                 keyFormat, result);
  }

  void SignPayloadBytes(const std::vector<uint8_t>& payload, const std::string* keyAlias,
                         const IdentitySignatureConfig* config, const IdentitySignatureFormat& signatureFormat,
                         const IdentityKeyFormat& keyFormat, const std::string* promptMessage,
                         std::function<void(ErrorOr<IdentitySignatureResult> reply)> result) override {
    SignInternal(payload, keyAlias, signatureFormat, keyFormat, result);
  }

  // Real RSA-OAEP-SHA256 decryption via the low-level CNG NCrypt API.
  // WARNING: this relies on an undocumented Windows property to arm the
  // Windows Hello prompt -- see LocalNCryptDecryptor.h for the full risk
  // disclosure. `promptMessage`/`config` are accepted for API symmetry with
  // the other platforms but are not used: NCrypt's Passport-provider prompt
  // UI is controlled by Windows itself, the same as it is for the existing
  // KeyCredentialManager-based sign path.
  void DecryptPayload(const std::string& payload, const std::string* keyAlias,
                       const IdentityPayloadFormat& payloadFormat, const IdentityDecryptConfig* config,
                       const std::string* promptMessage,
                       std::function<void(ErrorOr<IdentityDecryptResult> reply)> result) override {
    auto ciphertext = DecodePayload(payload, static_cast<int>(payloadFormat));
    auto name = KeyAliasToName(keyAlias);

    auto decryptResult = NCryptDecryptWithPassportKey(name, ciphertext);

    IdentityDecryptResult res;
    if (decryptResult.success) {
      // Matches Android's convention (LocalBiometricPlugin.kt: `String(decrypted)`):
      // the plaintext bytes are interpreted directly as a UTF-8 string, not
      // base64-encoded, since the caller already knows the plaintext's shape.
      res.set_decrypted_data(std::string(decryptResult.plaintext.begin(), decryptResult.plaintext.end()));
      res.set_code(IdentityError::kSuccess);
    } else {
      res.set_error(decryptResult.error_message);
      if (decryptResult.error_kind == "user_canceled") {
        res.set_code(IdentityError::kUserCanceled);
      } else if (decryptResult.error_kind == "not_found") {
        res.set_code(IdentityError::kKeyNotFound);
      } else if (decryptResult.error_kind == "not_supported") {
        res.set_code(IdentityError::kNotSupported);
      } else {
        res.set_code(IdentityError::kUnknown);
      }
    }
    result(res);
  }

  void RevokeIdentity(const std::string* keyAlias, std::function<void(ErrorOr<bool> reply)> result) override {
    result(true);
  }
  void RevokeAllIdentities(std::function<void(ErrorOr<bool> reply)> result) override { result(true); }
  void GetIdentityStatus(const std::string* keyAlias, bool checkValidity, const IdentityKeyFormat& keyFormat,
                          std::function<void(ErrorOr<IdentityInfo> reply)> result) override {
    result(IdentityInfo());
  }
  void VerifyPresence(const std::string& promptMessage, const PresencePromptConfig* config,
                       std::function<void(ErrorOr<PresencePromptResult> reply)> result) override {
    result(PresencePromptResult());
  }
  void IsDeviceSecure(std::function<void(ErrorOr<bool> reply)> result) override { result(true); }
  void AcknowledgeIdentityChange(std::function<void(ErrorOr<void> reply)> result) override {
    result(ErrorOr<void>());
  }

  // `KeyCredentialManager`/the CNG NCrypt path this plugin uses both drive their prompt UI
  // entirely inside Windows Hello itself, with no cancellation handle exposed back to the
  // caller -- there is nothing here to cancel.
  //
  // `requireAuthentication` (IdentityEnrollmentConfig), `persistAcrossBackgrounding` (all four
  // configs), and `sensitiveTransaction` (PresencePromptConfig) are likewise not read anywhere
  // in this file: Windows Hello always requires its own gating with no opt-out, backgrounding
  // interruption/retry has no Windows analog in this plugin's current implementation, and there
  // is no Windows Hello equivalent of Android's passive-match confirmation step.
  void StopAuthentication(std::function<void(ErrorOr<bool> reply)> result) override { result(false); }

 private:
  // Shared by SignPayload/SignPayloadBytes (previously SignPayloadBytes was
  // an empty-body stub that never called `result`, hanging the Dart Future
  // forever; SignPayload "succeeded" without ever populating the signature/
  // public key it claimed to produce).
  void SignInternal(std::vector<uint8_t> payload, const std::string* keyAlias,
                     const IdentitySignatureFormat& signatureFormat, const IdentityKeyFormat& keyFormat,
                     std::function<void(ErrorOr<IdentitySignatureResult> reply)> result) {
    auto name = KeyAliasToName(keyAlias);
    KeyCredentialManager::OpenAsync(name).Completed(
        [result, payload = std::move(payload), signatureFormat, keyFormat](auto const& op, auto status) {
          if (status != winrt::Windows::Foundation::AsyncStatus::Completed) {
            IdentitySignatureResult res;
            res.set_code(IdentityError::kUnknown);
            result(res);
            return;
          }
          auto openRes = op.GetResults();
          if (openRes.Status() != KeyCredentialStatus::Success) {
            IdentitySignatureResult res;
            res.set_code(MapKeyCredentialStatus(openRes.Status()));
            result(res);
            return;
          }

          auto cred = openRes.Credential();
          auto messageBuffer = BytesToBuffer(payload);

          cred.RetrievePublicKeyAsync().Completed(
              [result, cred, messageBuffer, signatureFormat, keyFormat](auto const& pubOp, auto pubStatus) {
                std::string publicKeyStr;
                if (pubStatus == winrt::Windows::Foundation::AsyncStatus::Completed) {
                  auto pubKeyBuffer = pubOp.GetResults();
                  publicKeyStr = FormatBytes(BufferToBytes(pubKeyBuffer), static_cast<int>(keyFormat),
                                              /*has_pem=*/true, "PUBLIC KEY");
                }

                cred.RequestSignAsync(messageBuffer)
                    .Completed([result, publicKeyStr, signatureFormat](auto const& signOp, auto signStatus) {
                      IdentitySignatureResult res;
                      if (signStatus == winrt::Windows::Foundation::AsyncStatus::Completed) {
                        auto signRes = signOp.GetResults();
                        if (signRes.Status() == KeyCredentialStatus::Success) {
                          auto sigBytes = BufferToBytes(signRes.Signature());
                          res.set_code(IdentityError::kSuccess);
                          res.set_signature(
                              FormatBytes(sigBytes, static_cast<int>(signatureFormat), /*has_pem=*/false, nullptr));
                          if (!publicKeyStr.empty()) {
                            res.set_public_key(publicKeyStr);
                          }
                          res.set_algorithm("RSA");
                          res.set_key_size(2048);
                        } else {
                          res.set_code(MapKeyCredentialStatus(signRes.Status()));
                        }
                      } else {
                        res.set_code(IdentityError::kUnknown);
                      }
                      result(res);
                    });
              });
        });
  }
};

}  // namespace local_biometric
