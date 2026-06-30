import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:local_biometric/local_biometric.dart';

class EncryptedAuthPage extends StatefulWidget {
  const EncryptedAuthPage({super.key});

  @override
  State<EncryptedAuthPage> createState() => _EncryptedAuthPageState();
}

class _EncryptedAuthPageState extends State<EncryptedAuthPage> {
  final _plugin = LocalBiometric();
  final _aliasController = TextEditingController(text: 'secure_key_1');
  final _payloadController = TextEditingController(text: 'Sensitive data to sign');
  
  bool _isLoading = false;
  String _lastResult = 'Ready.';
  bool _isLockedOut = false;
  
  // Config
  IdentitySignatureType _sigType = IdentitySignatureType.rsa;
  bool _enforceBio = true;
  bool _useDeviceCredentials = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkLockout();
    });
  }

  Future<void> _checkLockout() async {
    final availability = await _plugin.checkAvailability();
    debugPrint('[LocalBiometric] Page Status: canAuth=${availability.canAuthenticate}, reason=${availability.reason}');
    if (mounted) {
      final wasLockedOut = _isLockedOut;
      setState(() {
        _isLockedOut = availability.canAuthenticate == false && 
                      (availability.reason?.toLowerCase().contains('lockout') ?? false);
        if (_isLockedOut) {
          _lastResult = 'System detects biometric lockout.';
        }
      });

      // Only show alert if it's a new lockout detection to avoid duplicate dialogs
      if (_isLockedOut && !wasLockedOut) {
        debugPrint('[LocalBiometric] Triggering Lockout Alert from background check');
        _showLockoutAlert();
      }
    }
  }

  Future<void> _showLockoutAlert() async {
    if (!mounted) return;
    debugPrint('[LocalBiometric] Showing Lockout Alert Dialog');
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Biometrics Locked'),
          content: const Text('Biometric authentication is currently locked out. Would you like to verify with your passcode to re-enable it?'),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            TextButton(
              child: const Text('Verify with Passcode'),
              onPressed: () {
                Navigator.of(context).pop();
                _runAction(() => _plugin.verifyPresence(
                  promptMessage: 'Verify passcode to unlock biometrics',
                  config: PresencePromptConfig(allowDeviceCredentials: true),
                ), isRecovery: true);
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _runAction(Future<dynamic> Function() action, {bool isRecovery = false}) async {
    setState(() {
      _isLoading = true;
      _lastResult = isRecovery ? 'Unlocking biometrics...' : 'Processing...';
    });
    try {
      final result = await action();
      debugPrint('[LocalBiometric] Action Result: $result');
      setState(() {
        if (result is IdentitySignatureResult) {
          _lastResult = 'Signature Result: code=${result.code}, algo=${result.algorithm}';
        } else {
          _lastResult = result.toString();
        }
        
        // Improved lockout detection for Encrypted Auth
        bool locked = false;
        if (result is IdentitySignatureResult) {
          if (result.code == IdentityError.lockedOut) locked = true;
        } else if (result is IdentityEnrollmentResult) {
          if (result.code == IdentityError.lockedOut) locked = true;
        } else if (result is PresencePromptResult) {
          if (result.code == IdentityError.lockedOut) locked = true;
        }
        
        if (locked) {
          _isLockedOut = true;
          _lastResult = 'Biometric Lockout Detected (Code: lockedOut)';
          _showLockoutAlert();
        } else if (isRecovery && result is PresencePromptResult && result.success == true) {
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
          _buildResultSection(),
        ],
      ),
    );
  }

  Widget _buildLockoutRecoveryCard() {
    return Card(
      color: Colors.red[50],
      shape: RoundedRectangleBorder(side: const BorderSide(color: Colors.red), borderRadius: BorderRadius.circular(8)),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Row(
              children: [
                Icon(Icons.lock_outline, color: Colors.red),
                SizedBox(width: 8),
                Expanded(child: Text('Biometrics Locked. Passcode verification required to re-enable.', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold))),
              ],
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => _runAction(() => _plugin.verifyPresence(
                promptMessage: 'Verify passcode to unlock biometrics',
                config: PresencePromptConfig(allowDeviceCredentials: true),
              ), isRecovery: true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
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
            const Text('1. Enrollment', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _aliasController,
              decoration: const InputDecoration(labelText: 'Key Alias', border: OutlineInputBorder()),
            ),
            Row(
              children: [
                const Text('Algorithm: '),
                Radio<IdentitySignatureType>(
                  value: IdentitySignatureType.rsa,
                  groupValue: _sigType,
                  onChanged: (v) => setState(() => _sigType = v!),
                ),
                const Text('RSA'),
                Radio<IdentitySignatureType>(
                  value: IdentitySignatureType.ecdsa,
                  groupValue: _sigType,
                  onChanged: (v) => setState(() => _sigType = v!),
                ),
                const Text('ECDSA'),
              ],
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
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isLockedOut ? null : () => _runAction(() => _plugin.enrollIdentity(
                  keyAlias: _aliasController.text,
                  config: IdentityEnrollmentConfig(
                    signatureType: _sigType,
                    enforceBiometric: _enforceBio,
                    useDeviceCredentials: _useDeviceCredentials,
                  ),
                )),
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
            const Text('2. Signing', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Note: Signing is biometric-only. If locked out, use the recovery button at the top.', style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: Colors.grey)),
            const SizedBox(height: 8),
            TextField(
              controller: _payloadController,
              decoration: const InputDecoration(labelText: 'Payload', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isLockedOut ? null : () => _runAction(() => _plugin.signPayload(
                      payload: _payloadController.text,
                      keyAlias: _aliasController.text,
                      config: IdentitySignatureConfig(
                        allowDeviceCredentials: false,
                      ),
                    )),
                    child: const Text('Sign String'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isLockedOut ? null : () => _runAction(() => _plugin.signPayloadBytes(
                      payload: Uint8List.fromList(_payloadController.text.codeUnits),
                      keyAlias: _aliasController.text,
                      config: IdentitySignatureConfig(
                        allowDeviceCredentials: false,
                      ),
                    )),
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

  Widget _buildResultSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Last Result:', style: TextStyle(fontWeight: FontWeight.bold)),
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
            : SelectableText(_lastResult, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
      ],
    );
  }
}
