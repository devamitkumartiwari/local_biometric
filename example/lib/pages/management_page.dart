import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:local_biometric/local_biometric.dart';

class ManagementPage extends StatefulWidget {
  const ManagementPage({super.key});

  @override
  State<ManagementPage> createState() => _ManagementPageState();
}

class _ManagementPageState extends State<ManagementPage> {
  final _plugin = LocalBiometric();
  final _aliasController = TextEditingController(text: 'secure_key_1');

  bool _isLoading = false;
  String _lastResult = 'Ready.';
  IdentityStatus _identityStatus = IdentityStatus.valid;
  StreamSubscription<IdentityStatus>? _statusSub;

  @override
  void initState() {
    super.initState();
    _statusSub = _plugin.onIdentityChanged.listen((status) {
      if (mounted) setState(() => _identityStatus = status);
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _aliasController.dispose();
    super.dispose();
  }

  Future<void> _acknowledgeChange() async {
    await _plugin.acknowledgeIdentityChange();
  }

  Future<void> _runAction(Future<dynamic> Function() action) async {
    setState(() {
      _isLoading = true;
      _lastResult = 'Processing...';
    });
    try {
      final result = await action();
      setState(() => _lastResult = result.toString());
    } catch (e) {
      setState(() => _lastResult = 'Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Key Management')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildIdentityStatusBanner(),
          const SizedBox(height: 16),
          _buildKeyActionCard(),
          const SizedBox(height: 16),
          _buildGlobalActionCard(),
          const SizedBox(height: 16),
          _buildResultSection(),
        ],
      ),
    );
  }

  Widget _buildIdentityStatusBanner() {
    final (
      Color color,
      IconData icon,
      String label,
    ) = switch (_identityStatus) {
      IdentityStatus.valid => (
        Colors.green,
        Icons.check_circle_outline,
        'Valid',
      ),
      IdentityStatus.changed => (
        Colors.orange,
        Icons.warning_amber_outlined,
        'Changed',
      ),
      IdentityStatus.unavailable => (
        Colors.grey,
        Icons.help_outline,
        'Unavailable',
      ),
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Identity status: $label\n(from onIdentityChanged; flips to "Changed" after re-enrolling a biometric in Settings)',
              style: TextStyle(color: color, fontWeight: FontWeight.bold),
            ),
          ),
          if (_identityStatus == IdentityStatus.changed)
            TextButton(
              onPressed: _acknowledgeChange,
              child: const Text('Acknowledge'),
            ),
        ],
      ),
    );
  }

  Widget _buildKeyActionCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Single Key Actions',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _aliasController,
              decoration: const InputDecoration(
                labelText: 'Key Alias',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _runAction(
                      () => _plugin.getIdentityStatus(
                        keyAlias: _aliasController.text,
                        checkValidity: true,
                      ),
                    ),
                    child: const Text('Check Status'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _runAction(
                      () => _plugin.revokeIdentity(
                        keyAlias: _aliasController.text,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.orange,
                    ),
                    child: const Text('Revoke Key'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGlobalActionCard() {
    return Card(
      color: Colors.red[50],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Global Actions',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.red,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () =>
                    _runAction(() => _plugin.revokeAllIdentities()),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                child: const Text('REVOKE ALL IDENTITIES'),
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
