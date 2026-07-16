import 'package:flutter/material.dart';
import 'package:shared_services/shared_services.dart';
import 'package:commander_web/src/features/observations/presentation/pages/observations_list_page.dart';
import 'package:commander_web/src/features/map/presentation/pages/map.dart';
import 'package:commander_web/src/features/profile/presentation/pages/profile_page.dart';
import 'package:commander_web/src/features/auth/presentation/pages/sign_in_page.dart';

class DashboardLayout extends StatefulWidget {
  const DashboardLayout({super.key});

  @override
  State<DashboardLayout> createState() => _DashboardLayoutState();
}

class _DashboardLayoutState extends State<DashboardLayout> {
  int _selectedIndex = 0;
  Map<String, dynamic>? _profile;
  int _pendingCount = 0;
  RealtimeChannel? _queueSubscription;
  Map<String, dynamic>? _mapHighlightObservation;
  int _mapHighlightNonce = 0;

  /// Switches to the Spatial Map tab (keeping the sidebar/shell visible)
  /// and highlights the given observation, instead of pushing a full-screen
  /// route that would hide the dashboard navigation.
  void _navigateToMapWithHighlight(Map<String, dynamic> obs) {
    setState(() {
      _selectedIndex = 2;
      _mapHighlightObservation = obs;
      _mapHighlightNonce++;
    });
  }

  @override
  void initState() {
    super.initState();
    _fetchProfile();
    _fetchPendingCount();
    _setupQueueListener();
  }

  @override
  void dispose() {
    if (_queueSubscription != null) {
      Supabase.instance.client.removeChannel(_queueSubscription!);
    }
    super.dispose();
  }

  Future<void> _fetchPendingCount() async {
    try {
      final res = await Supabase.instance.client
          .from('observations')
          .select('observation_id')
          .eq('under_verification', true)
          .eq('is_public', true)
          .eq('verification_result', 'PENDING')
          .or('is_deleted.eq.false,is_deleted.is.null')
          .count(CountOption.exact);
      if (mounted) {
        setState(() {
          _pendingCount = res.count;
        });
      }
    } catch (_) {}
  }

  void _setupQueueListener() {
    _queueSubscription = Supabase.instance.client
        .channel('public:observations_queue_badge')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'observations',
          callback: (payload) {
            _fetchPendingCount();
          },
        )
        .subscribe();
  }

  Future<void> _fetchProfile() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        final profileData = await Supabase.instance.client
            .from('users')
            .select('role, user_name, avatar_url, email')
            .eq('user_id', user.id)
            .maybeSingle();

        if (mounted && profileData != null) {
          setState(() {
            _profile = profileData;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _signOut() async {
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {}
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => const SignInPage(),
        ),
      );
    }
  }

  Widget _getSelectedPage() {
    switch (_selectedIndex) {
      case 0:
        return ObservationsListPage(isExpertOnly: true, onViewOnMap: _navigateToMapWithHighlight);
      case 1:
        return ObservationsListPage(isExpertOnly: false, onViewOnMap: _navigateToMapWithHighlight);
      case 2:
        return MapPage(
          key: ValueKey('map_$_mapHighlightNonce'),
          highlightObservation: _mapHighlightObservation,
        );
      case 3:
        return const ProfilePage();
      default:
        return const ObservationsListPage(isExpertOnly: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final userName = _profile?['user_name'] ?? 'Expert User';
    final email = _profile?['email'] ?? Supabase.instance.client.auth.currentUser?.email ?? '';
    final avatarUrl = _profile?['avatar_url'] as String?;
    final defaultAvatar = 'https://ui-avatars.com/api/?name=${Uri.encodeComponent(userName)}&background=4CAF50&color=FFFFFF&size=128';
    final displayAvatar = avatarUrl != null && avatarUrl.isNotEmpty ? avatarUrl : defaultAvatar;

    return Scaffold(
      body: Row(
        children: [
          // Sidebar
          Container(
            width: 280,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(
                right: BorderSide(color: Colors.grey[200]!, width: 1),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Brand Header
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.green[50],
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.park, color: Colors.green[700], size: 28),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'TREECON',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.green,
                                letterSpacing: 1.2,
                              ),
                            ),
                            Text(
                              'COMMANDER',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.black54,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                const SizedBox(height: 16),

                // Navigation Items
                _buildNavItem(0, Icons.assignment_outlined, Icons.assignment, 'My Observations'),
                _buildNavItem(1, Icons.verified_outlined, Icons.verified, 'Verify Observations', badgeCount: _pendingCount),
                _buildNavItem(2, Icons.map_outlined, Icons.map, 'Spatial Map'),
                _buildNavItem(3, Icons.person_outline, Icons.person, 'My Profile'),

                const Spacer(),
                const Divider(height: 1),

                // User Info & Sign Out section
                Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 20,
                            backgroundColor: Colors.green[50],
                            backgroundImage: NetworkImage(displayAvatar),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  userName,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black87,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  email,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey[500],
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red[700],
                            side: BorderSide(color: Colors.red[100]!),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: _signOut,
                          icon: const Icon(Icons.logout, size: 16),
                          label: const Text(
                            'Sign Out',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Main Page View Content
          Expanded(
            child: _getSelectedPage(),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(int index, IconData outlineIcon, IconData filledIcon, String label, {int? badgeCount}) {
    final isSelected = _selectedIndex == index;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: isSelected ? Colors.green[50] : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: () {
            setState(() {
              _selectedIndex = index;
              // Manually switching tabs (rather than "View on Map") should
              // land on the plain map, not re-apply a stale highlight.
              _mapHighlightObservation = null;
            });
          },
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(
                  isSelected ? filledIcon : outlineIcon,
                  color: isSelected ? Colors.green[700] : Colors.grey[600],
                  size: 22,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                      color: isSelected ? Colors.green[800] : Colors.grey[700],
                    ),
                  ),
                ),
                if (badgeCount != null && badgeCount > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.red[600],
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      badgeCount > 99 ? '99+' : badgeCount.toString(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
