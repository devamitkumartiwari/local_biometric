import 'package:flutter/material.dart';
import 'package:local_biometric/local_biometric.dart';

import 'simple_auth_page.dart';
import 'encrypted_auth_page.dart';
import 'management_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _plugin = LocalBiometric();
  IdentityAvailability? _availability;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    final availability = await _plugin.checkAvailability();
    if (mounted) {
      setState(() => _availability = availability);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Local Biometric'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshStatus,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildStatusCard(),
          const SizedBox(height: 24),
          const Text(
            'Features',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          _buildFeatureTile(
            title: 'Simple Authentication',
            subtitle: 'Verify presence using biometrics (no keys)',
            icon: Icons.fingerprint,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SimpleAuthPage()),
            ),
          ),
          _buildFeatureTile(
            title: 'Encrypted Authentication',
            subtitle: 'Enroll identities and sign payloads with keys',
            icon: Icons.enhanced_encryption,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const EncryptedAuthPage()),
            ),
          ),
          _buildFeatureTile(
            title: 'Management',
            subtitle: 'Check identity status and revoke keys',
            icon: Icons.manage_accounts,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ManagementPage()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.info_outline, color: Colors.blue),
                SizedBox(width: 8),
                Text(
                  'System Status',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const Divider(),
            _buildStatusRow('Can Authenticate', _availability?.canAuthenticate),
            _buildStatusRow(
              'Biometrics Enrolled',
              _availability?.hasEnrolledBiometrics,
            ),
            _buildStatusRow(
              'Biometric Types',
              _availability?.availableBiometrics?.join(', ') ?? 'None',
            ),
            if (_availability?.reason != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Reason: ${_availability!.reason}',
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusRow(String label, dynamic value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          const Spacer(),
          Flexible(
            child: Text(
              value?.toString() ?? '...',
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(child: Icon(icon)),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
