import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:local_biometric/local_biometric.dart';

class EncryptedAuthPage extends StatefulWidget {
  const EncryptedAuthPage({super.key});

  @override
  State<EncryptedAuthPage> createState() => _EncryptedAuthPageState();
}

class _EncryptedAuthPageState extends State<EncryptedAuthPage> {
  final _plugin = LocalBiometric();
  final _aliasController = TextEditingController(text: 'secure_key_1');
  final _payloadController = TextEditingController(
    text: 'Sensitive data to sign',
  );
  final _ciphertextController = TextEditingController();

  bool _isLoading = false;
  String _lastResult = 'Ready.';
  bool _isLockedOut = false;

  // Config
  IdentitySignatureType _sigType = IdentitySignatureType.rsa;
  bool _enforceBio = true;
  bool _useDeviceCredentials = false;
  bool _requireAuthentication = true;
  // Shared across enrollment/signing/decryption below, to keep the demo UI to one switch rather
  // than three -- it still exercises persistAcrossBackgrounding on all three config classes.
  bool _persistAcrossBackgrounding = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkLockout();
    });
  }

  @override
  void dispose() {
    _aliasController.dispose();
    _payloadController.dispose();
    _ciphertextController.dispose();
    super.dispose();
  }

  Future<void> _checkLockout() async {
    final availability = await _plugin.checkAvailability();
    debugPrint(
      '[LocalBiometric] Page Status: canAuth=${availability.canAuthenticate}, reason=${availability.reason}',
    );
    if (mounted) {
      final wasLockedOut = _isLockedOut;
      setState(() {
        _isLockedOut =
            availability.canAuthenticate == false &&
            (availability.reason?.toLowerCase().contains('lockout') ?? false);
        if (_isLockedOut) {
          _lastResult =
              'System detects biometric lockout (${availability.reason}).';
        }
      });

      // Only show alert if it's a new lockout detection to avoid duplicate dialogs
      if (_isLockedOut && !wasLockedOut) {
        debugPrint(
          '[LocalBiometric] Triggering Lockout Alert from background check',
        );
        _showLockoutAlert(
          isPermanent: availability.reason == 'lockedOutPermanent',
        );
      }
    }
  }

  Future<void> _showLockoutAlert({bool isPermanent = false}) async {
    if (!mounted) return;
    debugPrint('[LocalBiometric] Showing Lockout Alert Dialog');
    final bool isIOS = Platform.isIOS;
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(
            isPermanent || isIOS
                ? 'Biometrics Locked'
                : 'Biometrics Temporarily Locked',
          ),
          content: Text(
            isPermanent || isIOS
                ? 'Biometric authentication is locked. Passcode verification is required to re-enable it.'
                : 'Biometric authentication is temporarily locked (30s). You can wait or verify with your passcode to unlock immediately.',
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            TextButton(
              child: const Text('Verify with Passcode'),
              onPressed: () {
                Navigator.of(context).pop();
                _runAction(
                  () => _plugin.verifyPresence(
                    promptMessage: 'Verify passcode to unlock biometrics',
                    config: PresencePromptConfig(allowDeviceCredentials: true),
                  ),
                  isRecovery: true,
                );
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _runAction(
    Future<dynamic> Function() action, {
    bool isRecovery = false,
  }) async {
    setState(() {
      _isLoading = true;
      _lastResult = isRecovery ? 'Unlocking biometrics...' : 'Processing...';
    });
    try {
      final result = await action();
      debugPrint('[LocalBiometric] Action Result: $result');
      setState(() {
        if (result is IdentitySignatureResult) {
          _lastResult =
              'Signature Result: code=${result.code}, algo=${result.algorithm}';
        } else {
          _lastResult = result.toString();
        }

        // Improved lockout detection for Encrypted Auth
        bool locked = false;
        bool permanent = false;
        if (result is IdentitySignatureResult) {
          if (result.code == IdentityError.lockedOut) locked = true;
          if (result.code == IdentityError.lockedOutPermanent) {
            locked = true;
            permanent = true;
          }
        } else if (result is IdentityEnrollmentResult) {
          if (result.code == IdentityError.lockedOut) locked = true;
          if (result.code == IdentityError.lockedOutPermanent) {
            locked = true;
            permanent = true;
          }
        } else if (result is PresencePromptResult) {
          if (result.code == IdentityError.lockedOut) locked = true;
          if (result.code == IdentityError.lockedOutPermanent) {
            locked = true;
            permanent = true;
          }
        } else if (result is IdentityDecryptResult) {
          if (result.code == IdentityError.lockedOut) locked = true;
          if (result.code == IdentityError.lockedOutPermanent) {
            locked = true;
            permanent = true;
          }
        }

        if (locked) {
          _isLockedOut = true;
          _lastResult =
              'Biometric Lockout Detected (${permanent ? "Permanent" : "Temporary"})';
          _showLockoutAlert(isPermanent: permanent);
        } else if (isRecovery &&
            result is PresencePromptResult &&
            result.success == true) {
          _isLockedOut = false;
          _lastResult = 'Biometrics unlocked! You can now use biometrics.';
        }
      });
    } catch (e) {
      setState(() => _lastResult = 'Error: $e');
    } finally {
      setState(() => _isLoading = false);
      // Proactively refresh lockout state from system
      if (!isRecovery) _checkLockout();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Encrypted Auth')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_isLockedOut) _buildLockoutRecoveryCard(),
          _buildEnrollmentSection(),
          const SizedBox(height: 16),
          _buildSigningSection(),
          const SizedBox(height: 16),
          _buildDecryptSection(),
          const SizedBox(height: 16),
          _buildResultSection(),
        ],
      ),
    );
  }

  Widget _buildLockoutRecoveryCard() {
    return Card(
      color: Colors.red[50],
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: Colors.red),
        borderRadius: BorderRadius.circular(8),
      ),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Row(
              children: [
                Icon(Icons.lock_outline, color: Colors.red),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Biometrics Locked. Passcode verification required to re-enable.',
                    style: TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => _runAction(
                () => _plugin.verifyPresence(
                  promptMessage: 'Verify passcode to unlock biometrics',
                  config: PresencePromptConfig(allowDeviceCredentials: true),
                ),
                isRecovery: true,
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text('UNLOCK WITH PASSCODE'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEnrollmentSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '1. Enrollment',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _aliasController,
              decoration: const InputDecoration(
                labelText: 'Key Alias',
                border: OutlineInputBorder(),
              ),
            ),
            RadioGroup<IdentitySignatureType>(
              groupValue: _sigType,
              onChanged: (v) => setState(() => _sigType = v!),
              child: const Row(
                children: [
                  Text('Algorithm: '),
                  Radio<IdentitySignatureType>(
                    value: IdentitySignatureType.rsa,
                  ),
                  Text('RSA'),
                  Radio<IdentitySignatureType>(
                    value: IdentitySignatureType.ecdsa,
                  ),
                  Text('ECDSA'),
                ],
              ),
            ),
            SwitchListTile(
              title: const Text('Enforce Biometric'),
              value: _enforceBio,
              onChanged: (v) => setState(() => _enforceBio = v),
            ),
            SwitchListTile(
              title: const Text('Use Device Credentials'),
              subtitle: const Text('Allow using passcode for enrollment'),
              value: _useDeviceCredentials,
              onChanged: (v) => setState(() => _useDeviceCredentials = v),
            ),
            SwitchListTile(
              title: const Text('Require Authentication'),
              subtitle: const Text(
                'Off = the key can sign/decrypt with NO biometric or passcode gating at all ("device has the key" only). Security-sensitive -- see the doc comment on IdentityEnrollmentConfig.requireAuthentication before using this off in a real app.',
              ),
              value: _requireAuthentication,
              onChanged: (v) => setState(() => _requireAuthentication = v),
            ),
            SwitchListTile(
              title: const Text('Persist Across Backgrounding'),
              subtitle: const Text(
                'Applies to enroll/sign/decrypt below. If the app is backgrounded mid-prompt, automatically retries the whole call from scratch on foreground.',
              ),
              value: _persistAcrossBackgrounding,
              onChanged: (v) => setState(() => _persistAcrossBackgrounding = v),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isLockedOut
                    ? null
                    : () => _runAction(
                        () => _plugin.enrollIdentity(
                          keyAlias: _aliasController.text,
                          config: IdentityEnrollmentConfig(
                            signatureType: _sigType,
                            enforceBiometric: _enforceBio,
                            useDeviceCredentials: _useDeviceCredentials,
                            requireAuthentication: _requireAuthentication,
                            persistAcrossBackgrounding:
                                _persistAcrossBackgrounding,
                          ),
                        ),
                      ),
                child: const Text('Enroll Key'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSigningSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '2. Signing',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Note: Signing is biometric-only. If locked out, use the recovery button at the top.',
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _payloadController,
              decoration: const InputDecoration(
                labelText: 'Payload',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isLockedOut
                        ? null
                        : () => _runAction(
                            () => _plugin.signPayload(
                              payload: _payloadController.text,
                              keyAlias: _aliasController.text,
                              config: IdentitySignatureConfig(
                                allowDeviceCredentials: false,
                                persistAcrossBackgrounding:
                                    _persistAcrossBackgrounding,
                              ),
                            ),
                          ),
                    child: const Text('Sign String'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isLockedOut
                        ? null
                        : () => _runAction(
                            () => _plugin.signPayloadBytes(
                              payload: Uint8List.fromList(
                                _payloadController.text.codeUnits,
                              ),
                              keyAlias: _aliasController.text,
                              config: IdentitySignatureConfig(
                                allowDeviceCredentials: false,
                                persistAcrossBackgrounding:
                                    _persistAcrossBackgrounding,
                              ),
                            ),
                          ),
                    child: const Text('Sign Bytes'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDecryptSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '3. Decrypt',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Paste base64 ciphertext encrypted externally against the public key from enrollment '
              '(RSA-OAEP-SHA256 for RSA identities, ECIES-X963-SHA256-AESGCM for EC-only identities '
              '-- see README.md). Invalid input still exercises the native decrypt path end-to-end '
              '(prompt -> attempt -> mapped error) even without a real ciphertext.',
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _ciphertextController,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Ciphertext (base64)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isLockedOut
                    ? null
                    : () => _runAction(
                        () => _plugin.decryptPayload(
                          payload: _ciphertextController.text,
                          keyAlias: _aliasController.text,
                          config: IdentityDecryptConfig(
                            allowDeviceCredentials: false,
                            persistAcrossBackgrounding:
                                _persistAcrossBackgrounding,
                          ),
                        ),
                      ),
                child: const Text('Decrypt'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Last Result:',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
          ),
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : SelectableText(
                  _lastResult,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
        ),
      ],
    );
  }
}
