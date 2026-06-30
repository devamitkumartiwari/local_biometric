import 'package:flutter/material.dart';
import 'package:local_biometric/local_biometric.dart';

class SimpleAuthPage extends StatefulWidget {
  const SimpleAuthPage({super.key});

  @override
  State<SimpleAuthPage> createState() => _SimpleAuthPageState();
}

class _SimpleAuthPageState extends State<SimpleAuthPage> {
  final _plugin = LocalBiometric();
  bool _isLoading = false;
  String _lastResult = 'Ready.';
  bool _allowPasscode = false;
  bool _isLockedOut = false;

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
        // iOS specifically sets canAuthenticate to false and provides a reason when locked out
        _isLockedOut = availability.canAuthenticate == false && 
                      (availability.reason?.toLowerCase().contains('lockout') ?? false);
        if (_isLockedOut) {
          _lastResult = 'System detects biometric lockout.';
        }
      });

      if (_isLockedOut && !wasLockedOut) {
        _showLockoutAlert();
      }
    }
  }

  Future<void> _showLockoutAlert() async {
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
                _verify(recover: true);
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _verify({bool recover = false}) async {
    setState(() {
      _isLoading = true;
      _lastResult = recover ? 'Verifying passcode to unlock...' : 'Authenticating...';
    });

    try {
      final result = await _plugin.verifyPresence(
        promptMessage: recover ? 'Verify passcode to re-enable biometrics' : 'Confirm your identity',
        config: PresencePromptConfig(
          allowDeviceCredentials: recover || _allowPasscode,
        ),
      );
      
      setState(() {
        if (result.success == true) {
          _lastResult = 'Success! Authenticated via ${result.authenticationType}';
          _isLockedOut = false;
        } else {
          _lastResult = 'Failed: ${result.code}\nError: ${result.error}';
          if (result.code == IdentityError.lockedOut) {
            _isLockedOut = true;
          }
        }
      });
    } catch (e) {
      setState(() => _lastResult = 'Error: $e');
    } finally {
      setState(() => _isLoading = false);
      // Proactively check status again after any attempt
      if (!recover) _checkLockout();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Simple Authentication')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Simple authentication verifies the user\'s presence using biometrics or device credentials. It does not involve cryptographic keys.',
                ),
              ),
            ),
            if (_isLockedOut) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red),
                ),
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
                      onPressed: () => _verify(recover: true),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                      child: const Text('UNLOCK WITH PASSCODE'),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text('Allow Passcode Fallback'),
              subtitle: const Text('If biometrics fail or are unavailable, allow using the device passcode.'),
              value: _allowPasscode,
              onChanged: (v) => setState(() => _allowPasscode = v),
            ),
            const Spacer(),
            if (_isLoading)
              const Center(child: CircularProgressIndicator())
            else
              ElevatedButton.icon(
                onPressed: _isLockedOut ? null : _verify,
                icon: const Icon(Icons.fingerprint),
                label: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('Verify Presence', style: TextStyle(fontSize: 18)),
                ),
              ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[200],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _lastResult,
                textAlign: TextAlign.center,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
