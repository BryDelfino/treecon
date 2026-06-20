import 'package:flutter/material.dart';
import 'package:shared_services/shared_services.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;
    final email = user?.email ?? 'Unknown User';
    final Future<Map<String, dynamic>?> profileFuture = user != null
        ? Supabase.instance.client
            .from('users')
            .select('role, user_name, avatar_url')
            .eq('user_id', user.id)
            .maybeSingle()
        : Future.value(null);

    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: const Text(
          'Treecon Scout',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: Colors.green[700],
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white),
            tooltip: 'Sign Out',
            onPressed: () => _signOut(context),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16.0),
              // Dynamic Success Card
              Card(
                elevation: 2.0,
                shadowColor: Colors.black.withValues(alpha: 0.05),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20.0),
                ),
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
                  child: FutureBuilder<Map<String, dynamic>?>(
                    future: profileFuture,
                    builder: (context, snapshot) {
                      final profile = snapshot.data;
                      final userName = profile?['user_name'] as String? ?? 'User';
                      final rawRole = profile?['role'] as String? ?? 'COMMUNITY';
                      final avatarUrl = profile?['avatar_url'] as String?;
                      final defaultAvatar = 'https://ui-avatars.com/api/?name=${Uri.encodeComponent(userName)}&background=4CAF50&color=FFFFFF&size=128';
                      final displayAvatarUrl = avatarUrl != null && avatarUrl.isNotEmpty ? avatarUrl : defaultAvatar;

                      // Format role to Title Case (e.g., 'COMMUNITY' -> 'Community')
                      final formattedRole = rawRole.isNotEmpty 
                          ? '${rawRole[0].toUpperCase()}${rawRole.substring(1).toLowerCase()}'
                          : 'Community';

                      final isLoading = snapshot.connectionState == ConnectionState.waiting;

                      return Column(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.08),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: CircleAvatar(
                              radius: 40,
                              backgroundColor: Colors.green[50],
                              backgroundImage: NetworkImage(displayAvatarUrl),
                            ),
                          ),
                          const SizedBox(height: 20.0),
                          Text(
                            isLoading ? 'Loading profile...' : 'Welcome, $userName',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8.0),
                          Text(
                            email,
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey[600],
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 16.0),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
                            decoration: BoxDecoration(
                              color: isLoading ? Colors.grey[200] : Colors.green[100],
                              borderRadius: BorderRadius.circular(100.0),
                            ),
                            child: Text(
                              isLoading ? 'Role: --' : 'Role: $formattedRole',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: isLoading ? Colors.grey[600] : Colors.green[800],
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 24.0),
              
              // Mobile Dashboard Quick Actions Placeholder
              const Text(
                'QUICK ACTIONS',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 12.0),
              
              // Quick action buttons
              _buildDashboardButton(
                icon: Icons.map_outlined,
                label: 'View Map Observations',
                color: Colors.blue[600]!,
              ),
              const SizedBox(height: 12.0),
              _buildDashboardButton(
                icon: Icons.add_a_photo_outlined,
                label: 'Collect New Observation',
                color: Colors.green[600]!,
              ),
              
              const Spacer(),
              
              // Logout Button
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red[700],
                  side: BorderSide(color: Colors.red[200]!),
                  padding: const EdgeInsets.symmetric(vertical: 16.0),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16.0),
                  ),
                ),
                onPressed: () => _signOut(context),
                icon: const Icon(Icons.logout),
                label: const Text(
                  'Sign Out',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 16.0),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDashboardButton({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16.0),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(8.0),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10.0),
          ),
          child: Icon(icon, color: color),
        ),
        title: Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        trailing: const Icon(Icons.chevron_right, color: Colors.grey),
        onTap: () {}, // Action placeholder
      ),
    );
  }

  Future<void> _signOut(BuildContext context) async {
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {}
    if (context.mounted) {
      Navigator.of(context).pushReplacementNamed('/');
    }
  }
}
