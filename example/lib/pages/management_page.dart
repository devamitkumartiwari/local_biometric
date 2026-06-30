import 'package:flutter/material.dart';
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
          _buildKeyActionCard(),
          const SizedBox(height: 16),
          _buildGlobalActionCard(),
          const SizedBox(height: 16),
          _buildResultSection(),
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
            const Text('Single Key Actions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            TextField(
              controller: _aliasController,
              decoration: const InputDecoration(labelText: 'Key Alias', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _runAction(() => _plugin.getIdentityStatus(keyAlias: _aliasController.text, checkValidity: true)),
                    child: const Text('Check Status'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _runAction(() => _plugin.revokeIdentity(keyAlias: _aliasController.text)),
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.orange),
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
            const Text('Global Actions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.red)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => _runAction(() => _plugin.revokeAllIdentities()),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
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
