#include "local_biometric_api.g.h"
#include <winrt/Windows.Security.Credentials.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.Foundation.h>
#include <flutter/plugin_registrar_windows.h>
#include <memory>

using namespace winrt::Windows::Security::Credentials;
using namespace winrt::Windows::Storage::Streams;

namespace local_biometric {

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

    void EnrollIdentity(const std::string* keyAlias, const IdentityEnrollmentConfig* config, const IdentityKeyFormat& keyFormat, const std::string* promptMessage, std::function<void(ErrorOr<IdentityEnrollmentResult> reply)> result) override {
        std::wstring name = keyAlias ? std::wstring(keyAlias->begin(), keyAlias->end()) : L"LocalDefault";
        auto option = (config && config->fail_if_exists() && *config->fail_if_exists()) ? KeyCredentialCreationOption::FailIfExists : KeyCredentialCreationOption::ReplaceExisting;

        KeyCredentialManager::RequestCreateAsync(name, option).Completed([result](auto const& op, auto status) {
            IdentityEnrollmentResult res;
            if (status == winrt::Windows::Foundation::AsyncStatus::Completed) {
                auto createResult = op.GetResults();
                if (createResult.Status() == KeyCredentialStatus::Success) {
                    res.set_code(IdentityError::kSuccess);
                    res.set_algorithm("RSA");
                    res.set_key_size(2048);
                } else {
                    res.set_code(IdentityError::kUnknown);
                }
            }
            result(res);
        });
    }

    void SignPayload(const std::string& payload, const std::string* keyAlias, const IdentitySignatureConfig* config, const IdentitySignatureFormat& signatureFormat, const IdentityKeyFormat& keyFormat, const std::string* promptMessage, std::function<void(ErrorOr<IdentitySignatureResult> reply)> result) override {
        std::wstring name = keyAlias ? std::wstring(keyAlias->begin(), keyAlias->end()) : L"LocalDefault";
        KeyCredentialManager::OpenAsync(name).Completed([result, payload](auto const& op, auto status) {
            if (status == winrt::Windows::Foundation::AsyncStatus::Completed) {
                auto openRes = op.GetResults();
                if (openRes.Status() == KeyCredentialStatus::Success) {
                    auto cred = openRes.Credential();
                    DataWriter writer;
                    writer.WriteBytes(std::vector<uint8_t>(payload.begin(), payload.end()));
                    cred.RequestSignAsync(writer.DetachBuffer()).Completed([result](auto const& signOp, auto signStatus) {
                        IdentitySignatureResult res;
                        if (signStatus == winrt::Windows::Foundation::AsyncStatus::Completed) {
                            auto signRes = signOp.GetResults();
                            if (signRes.Status() == KeyCredentialStatus::Success) {
                                res.set_code(IdentityError::kSuccess);
                            }
                        }
                        result(res);
                    });
                    return;
                }
            }
            result(IdentitySignatureResult());
        });
    }

    void SignPayloadBytes(const std::vector<uint8_t>& payload, const std::string* keyAlias, const IdentitySignatureConfig* config, const IdentitySignatureFormat& signatureFormat, const IdentityKeyFormat& keyFormat, const std::string* promptMessage, std::function<void(ErrorOr<IdentitySignatureResult> reply)> result) override {}
    void DecryptPayload(const std::string& payload, const std::string* keyAlias, const IdentityPayloadFormat& payloadFormat, const IdentityDecryptConfig* config, const std::string* promptMessage, std::function<void(ErrorOr<IdentityDecryptResult> reply)> result) override {}
    void RevokeIdentity(const std::string* keyAlias, std::function<void(ErrorOr<bool> reply)> result) override { result(true); }
    void RevokeAllIdentities(std::function<void(ErrorOr<bool> reply)> result) override { result(true); }
    void GetIdentityStatus(const std::string* keyAlias, bool checkValidity, const IdentityKeyFormat& keyFormat, std::function<void(ErrorOr<IdentityInfo> reply)> result) override { result(IdentityInfo()); }
    void VerifyPresence(const std::string& promptMessage, const PresencePromptConfig* config, std::function<void(ErrorOr<PresencePromptResult> reply)> result) override { result(PresencePromptResult()); }
    void IsDeviceSecure(std::function<void(ErrorOr<bool> reply)> result) override { result(true); }
    void AcknowledgeIdentityChange(std::function<void(ErrorOr<void> reply)> result) override { result(ErrorOr<void>()); }
};

} // namespace local_biometric
