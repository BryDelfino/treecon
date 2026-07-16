import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'package:intl/intl.dart';
import 'package:shared_services/shared_services.dart';
import 'add_observation_page.dart';
import 'observation_details_page.dart';

class ObservationsListPage extends StatefulWidget {
  final bool isExpertOnly;
  /// When set, "View on Map" switches to the dashboard's Spatial Map tab
  /// and highlights the observation instead of pushing a full-screen route.
  final void Function(Map<String, dynamic> obs)? onViewOnMap;

  const ObservationsListPage({
    super.key,
    required this.isExpertOnly,
    this.onViewOnMap,
  });

  @override
  State<ObservationsListPage> createState() => _ObservationsListPageState();
}

class _ObservationsListPageState extends State<ObservationsListPage> {
  final Set<String> _knownQueuedIds = {};
  RealtimeChannel? _subscription;
  List<Map<String, dynamic>> _observations = [];
  bool _isLoading = true;
  String? _error;

  DateTime? _filterStartDate;
  DateTime? _filterEndDate;
  String _filterProvince = 'All';
  String _filterSource = 'All'; // All, Mobile, Web
  bool _filterAnonymousOnly = false;
  bool _sortAscending = false;
  String? _currentUserRole;

  // "My Observations" (isExpertOnly) filters only — not applicable to the
  // verify queue, where every row is always under_verification/PENDING.
  String _filterVerificationState = 'All'; // All, Verified, Unverified
  String _filterVerificationStatus = 'All'; // All, Pending, Approved, Rejected
  String _filterVisibility = 'All'; // All, Public, Private
  
  final int _pageSize = 30;
  int _currentPage = 0;
  int _totalCount = 0;
  int get _totalPages {
    final pages = (_totalCount / _pageSize).ceil();
    return pages > 0 ? pages : 1;
  }

  @override
  void initState() {
    super.initState();
    _fetchCurrentUserRole();
    _fetchObservations(resetPage: true);
    _setupRealtime();
    ProvinceLookup.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _fetchCurrentUserRole() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;
      final profile = await Supabase.instance.client
          .from('users')
          .select('role')
          .eq('user_id', user.id)
          .maybeSingle();
      if (mounted && profile != null) {
        setState(() {
          _currentUserRole = profile['role']?.toString().toUpperCase();
        });
      }
    } catch (_) {}
  }

  void _setupRealtime() async {
    if (widget.isExpertOnly) return; // Only notify global queue viewers

    try {
      final res = await Supabase.instance.client
          .from('observations')
          .select('observation_id')
          .eq('under_verification', true)
          .eq('verification_result', 'PENDING');
      for (var rawRow in res as List<dynamic>) {
        final row = rawRow as Map<String, dynamic>;
        _knownQueuedIds.add(row['observation_id'].toString());
      }
    } catch (_) {}

    _subscription = Supabase.instance.client
        .channel('public:observations')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'observations',
          callback: (payload) {
            final newRow = payload.newRecord;
            final obsId = newRow['observation_id'].toString();
            final isQueued = newRow['under_verification'] == true && newRow['verification_result'] == 'PENDING';
            final isEligible = newRow['under_verification'] == true && newRow['is_public'] == true && newRow['is_deleted'] != true;

            final index = _observations.indexWhere((o) => o['observation_id'].toString() == obsId);
            if (index != -1 && mounted) {
              setState(() {
                if (!isEligible) {
                  _observations.removeAt(index);
                  if (_totalCount > 0) _totalCount--;
                } else {
                  _observations[index] = {
                    ..._observations[index],
                    ...newRow,
                  };
                }
              });
            }

            if (isQueued) {
              if (!_knownQueuedIds.contains(obsId)) {
                _knownQueuedIds.add(obsId);
                if (mounted) {
                  if (ModalRoute.of(context)?.isCurrent == true) {
                    ScaffoldMessenger.of(context).clearSnackBars();
                    final screenWidth = MediaQuery.of(context).size.width;
                    final leftMargin = screenWidth > 400 ? screenWidth - 360.0 : 16.0;

                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Row(
                          children: [
                            const Icon(
                              Icons.notifications_active_outlined,
                              color: Colors.white,
                              size: 20,
                            ),
                            const SizedBox(width: 12.0),
                            const Expanded(
                              child: Text(
                                'A new observation has been queued for verification!',
                                style: TextStyle(fontWeight: FontWeight.w500, color: Colors.white),
                              ),
                            ),
                            const SizedBox(width: 8.0),
                            IconButton(
                              icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 18),
                              onPressed: () {
                                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                              },
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              splashRadius: 16.0,
                            ),
                          ],
                        ),
                        backgroundColor: Colors.blue[800],
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10.0),
                        ),
                        margin: EdgeInsets.only(
                          bottom: 24,
                          right: 16,
                          left: leftMargin,
                        ),
                        duration: const Duration(seconds: 5),
                      ),
                    );
                  }
                }
            }
          } else {
            _knownQueuedIds.remove(obsId);
          }
          },
        )
        .subscribe();
  }

  @override
  void dispose() {
    if (_subscription != null) {
      Supabase.instance.client.removeChannel(_subscription!);
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ObservationsListPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isExpertOnly != widget.isExpertOnly) {
      _fetchObservations(resetPage: true);
      
      if (widget.isExpertOnly) {
        if (_subscription != null) {
          Supabase.instance.client.removeChannel(_subscription!);
          _subscription = null;
        }
      } else {
        _setupRealtime();
      }
    }
  }

  Future<void> _fetchObservations({bool resetPage = false, bool isSilent = false}) async {
    if (!mounted) return;
    
    if (resetPage) {
      _currentPage = 0;
    }

    if (!isSilent) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    } else {
      setState(() => _error = null);
    }

    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        throw Exception('User not authenticated');
      }

      var query = Supabase.instance.client.from('observations').select('*, users!observations_user_id_fkey!inner(user_name)');

      if (widget.isExpertOnly) {
        query = query.eq('user_id', user.id).or('is_deleted.eq.false,is_deleted.is.null');
      } else {
        query = query
            .eq('under_verification', true)
            .eq('is_public', true)
            .or('is_deleted.eq.false,is_deleted.is.null');
      }

      if (_filterStartDate != null) {
        query = query.gte('observation_timestamp', _filterStartDate!.toUtc().toIso8601String());
      }
      if (_filterEndDate != null) {
        // Add 1 day to include the end date fully
        query = query.lte('observation_timestamp', _filterEndDate!.add(const Duration(days: 1)).toUtc().toIso8601String());
      }

      if (widget.isExpertOnly) {
        if (_filterVerificationState == 'Unverified') {
          query = query.or('under_verification.eq.false,under_verification.is.null').isFilter('verification_result', null);
        } else if (_filterVerificationState == 'Verified') {
          query = query.or('under_verification.eq.true,verification_result.not.is.null');
        }

        if (_filterVerificationState != 'Unverified') {
          if (_filterVerificationStatus == 'Pending') {
            query = query.eq('under_verification', true);
          } else if (_filterVerificationStatus == 'Approved') {
            query = query.eq('verification_result', 'APPROVED');
          } else if (_filterVerificationStatus == 'Rejected') {
            query = query.eq('verification_result', 'REJECTED');
          }
        }

        if (_filterVisibility == 'Public') {
          query = query.eq('is_public', true);
        } else if (_filterVisibility == 'Private') {
          query = query.eq('is_public', false);
        }
      }

      if (_filterAnonymousOnly) {
        query = query.eq('is_anonymous', true);
      }

      if (_currentUserRole == 'EXPERT' && widget.isExpertOnly && _filterSource != 'All') {
        query = query.eq('source', _filterSource.toUpperCase());
      }

      final response = await query
          .order('observation_timestamp', ascending: _sortAscending)
          .range(_currentPage * _pageSize, ((_currentPage + 1) * _pageSize) - 1)
          .count(CountOption.exact);

      if (mounted) {
        setState(() {
          final data = response.data;
          _totalCount = response.count;
          var observations = (data as List<dynamic>).map((e) => e as Map<String, dynamic>).toList();

          // Province has no DB column; filter this page's rows client-side via point-in-polygon lookup.
          if (_filterProvince != 'All') {
            observations = observations.where((obs) {
              final coords = _parseCoordinates(obs['coordinates']);
              if (coords == null) return false;
              return ProvinceLookup.provinceForPoint(coords['lat']!, coords['lng']!) == _filterProvince;
            }).toList();
          }

          _observations = observations;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Map<String, double>? _parseCoordinates(dynamic coords) {
    if (coords == null) return null;
    if (coords is Map) {
      final map = coords.cast<String, dynamic>();
      final list = map['coordinates'];
      if (list is List && list.length >= 2) {
        return {
          'lng': (list[0] as num).toDouble(),
          'lat': (list[1] as num).toDouble(),
        };
      }
    } else if (coords is String) {
      final trimmed = coords.trim();
      
      // Check if it is a hex string (WKB/EWKB format)
      final hexRegex = RegExp(r'^(0x)?[0-9a-fA-F]+$');
      if (hexRegex.hasMatch(trimmed)) {
        return _parseEWKB(trimmed);
      }

      final match = RegExp(r'POINT\s*\(\s*([-\d.]+)\s+([-\d.]+)\s*\)', caseSensitive: false).firstMatch(trimmed);
      if (match != null) {
        return {
          'lng': double.tryParse(match.group(1) ?? '') ?? 0.0,
          'lat': double.tryParse(match.group(2) ?? '') ?? 0.0,
        };
      }
    }
    return null;
  }

  Map<String, double>? _parseEWKB(String hex) {
    try {
      String cleanHex = hex.startsWith('0x') ? hex.substring(2) : hex;
      if (cleanHex.length < 42) return null;
      
      final byteOrder = cleanHex.substring(0, 2);
      final isLittleEndian = byteOrder == '01';
      
      final typeHex = cleanHex.substring(2, 10);
      final hasSrid = typeHex.toLowerCase() == '01000020' || typeHex.toLowerCase() == '20000001';
      
      final int startX = hasSrid ? 18 : 10;
      final int startY = hasSrid ? 34 : 26;
      
      final double lng = _hexToDouble(cleanHex.substring(startX, startX + 16), isLittleEndian);
      final double lat = _hexToDouble(cleanHex.substring(startY, startY + 16), isLittleEndian);
      
      return {'lng': lng, 'lat': lat};
    } catch (_) {
      return null;
    }
  }

  double _hexToDouble(String hex, bool isLittleEndian) {
    final bytes = Uint8List(8);
    for (int i = 0; i < 8; i++) {
      final idx = isLittleEndian ? (i * 2) : ((7 - i) * 2);
      bytes[i] = int.parse(hex.substring(idx, idx + 2), radix: 16);
    }
    return ByteData.sublistView(bytes).getFloat64(0, Endian.little);
  }

  void _showFilterModal() {
    DateTime? tempStart = _filterStartDate;
    DateTime? tempEnd = _filterEndDate;
    String tempProvince = _filterProvince;
    bool tempAnonymousOnly = _filterAnonymousOnly;
    String tempVerificationState = _filterVerificationState;
    String tempVerificationStatus = _filterVerificationStatus;
    String tempVisibility = _filterVisibility;
    String tempSource = _filterSource;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Icon(Icons.filter_list, color: Colors.green[700]),
                  const SizedBox(width: 8),
                  const Text('Filter Observations', style: TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.isExpertOnly) ...[
                      const Text('Verification State', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        initialValue: tempVerificationState,
                        decoration: InputDecoration(
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'All', child: Text('All')),
                          DropdownMenuItem(value: 'Verified', child: Text('Verified')),
                          DropdownMenuItem(value: 'Unverified', child: Text('Unverified')),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setModalState(() {
                            tempVerificationState = value;
                            if (value == 'Unverified') tempVerificationStatus = 'All';
                          });
                        },
                      ),
                      const SizedBox(height: 20),
                      const Text('Verification Status', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        initialValue: tempVerificationStatus,
                        decoration: InputDecoration(
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'All', child: Text('All')),
                          DropdownMenuItem(value: 'Pending', child: Text('Pending')),
                          DropdownMenuItem(value: 'Approved', child: Text('Approved')),
                          DropdownMenuItem(value: 'Rejected', child: Text('Rejected')),
                        ],
                        onChanged: tempVerificationState == 'Unverified'
                            ? null
                            : (value) {
                                if (value != null) setModalState(() => tempVerificationStatus = value);
                              },
                      ),
                      const SizedBox(height: 20),
                      const Text('Visibility', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        initialValue: tempVisibility,
                        decoration: InputDecoration(
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'All', child: Text('All')),
                          DropdownMenuItem(value: 'Public', child: Text('Public')),
                          DropdownMenuItem(value: 'Private', child: Text('Private')),
                        ],
                        onChanged: (value) {
                          if (value != null) setModalState(() => tempVisibility = value);
                        },
                      ),
                      const SizedBox(height: 20),
                    ],
                    if (_currentUserRole == 'EXPERT' && widget.isExpertOnly) ...[
                      const Text('Source', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        initialValue: tempSource,
                        decoration: InputDecoration(
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'All', child: Text('All')),
                          DropdownMenuItem(value: 'Mobile', child: Text('Mobile')),
                          DropdownMenuItem(value: 'Web', child: Text('Web')),
                        ],
                        onChanged: (value) {
                          if (value != null) setModalState(() => tempSource = value);
                        },
                      ),
                      const SizedBox(height: 20),
                    ],
                    const Text('Province', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                    const SizedBox(height: 8),
                    InputDecorator(
                      decoration: InputDecoration(
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: tempProvince,
                          isExpanded: true,
                          items: ProvinceLookup.buildDropdownItems(),
                          onChanged: (value) {
                            if (value != null && !value.startsWith('HEADER_')) {
                              setModalState(() => tempProvince = value);
                            }
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text('Date Range', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                    const SizedBox(height: 8),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.calendar_today, color: Colors.green[700], size: 20),
                      title: Text(tempStart != null ? tempStart!.toLocal().toString().substring(0, 10) : 'Start Date'),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: tempStart ?? DateTime.now(),
                          firstDate: DateTime(2020),
                          lastDate: DateTime.now(),
                        );
                        if (picked != null) setModalState(() => tempStart = picked);
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.event, color: Colors.green[700], size: 20),
                      title: Text(tempEnd != null ? tempEnd!.toLocal().toString().substring(0, 10) : 'End Date'),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: tempEnd ?? DateTime.now(),
                          firstDate: DateTime(2020),
                          lastDate: DateTime.now(),
                        );
                        if (picked != null) setModalState(() => tempEnd = picked);
                      },
                    ),
                    const SizedBox(height: 12),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: CheckboxListTile(
                        controlAffinity: ListTileControlAffinity.trailing,
                        title: const Text('Anonymous Only', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                        subtitle: const Text('Show only observations submitted anonymously', style: TextStyle(fontSize: 11)),
                        value: tempAnonymousOnly,
                        activeColor: Colors.green.shade700,
                        onChanged: (val) {
                          setModalState(() => tempAnonymousOnly = val ?? false);
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      _filterStartDate = null;
                      _filterEndDate = null;
                      _filterProvince = 'All';
                      _filterSource = 'All';
                      _filterAnonymousOnly = false;
                      _filterVerificationState = 'All';
                      _filterVerificationStatus = 'All';
                      _filterVisibility = 'All';
                    });
                    Navigator.pop(context);
                    _fetchObservations(resetPage: true);
                  },
                  child: Text('Clear', style: TextStyle(color: Colors.grey[700])),
                ),
                FilledButton(
                  onPressed: () {
                    setState(() {
                      _filterStartDate = tempStart;
                      _filterEndDate = tempEnd;
                      _filterProvince = tempProvince;
                      _filterSource = tempSource;
                      _filterAnonymousOnly = tempAnonymousOnly;
                      _filterVerificationState = tempVerificationState;
                      _filterVerificationStatus = tempVerificationStatus;
                      _filterVisibility = tempVisibility;
                    });
                    Navigator.pop(context);
                    _fetchObservations(resetPage: true);
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.green[700],
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Apply'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _openAddObservationPage() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (context) => const AddObservationPage()),
    );
    if (result == true) {
      _fetchObservations(resetPage: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.isExpertOnly ? "My Observations" : "Verify Observations";

    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87),
        ),
        backgroundColor: Colors.white,
        elevation: 1,
        actions: [
          IconButton(
            icon: Icon(_sortAscending ? Icons.arrow_upward : Icons.arrow_downward, color: Colors.black54),
            onPressed: () {
              setState(() {
                _sortAscending = !_sortAscending;
              });
              _fetchObservations(resetPage: true);
            },
            tooltip: _sortAscending ? 'Sort by date of observation (Newest first)' : 'Sort by date of observation (Oldest first)',
          ),
          IconButton(
            icon: const Icon(Icons.filter_list, color: Colors.black54),
            onPressed: _showFilterModal,
            tooltip: 'Filter',
          ),
          if (!widget.isExpertOnly)
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.blue),
              onPressed: () => _fetchObservations(resetPage: true),
              tooltip: 'Refresh Queue',
            ),
          if (widget.isExpertOnly) ...[
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green[700],
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: _openAddObservationPage,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add Observation', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ] else ...[
            const SizedBox(width: 12), // Adds padding to the right of the filter button
          ],
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.green),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline_rounded, color: Colors.red, size: 64),
              const SizedBox(height: 16),
              Text(
                'Failed to load observations',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.grey[800]),
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[600]),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _fetchObservations,
                icon: const Icon(Icons.refresh),
                label: const Text('Try Again'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green[700],
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_observations.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.assignment_outlined, size: 80, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text(
              'No Observations Found',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.grey[700]),
            ),
            const SizedBox(height: 8),
            Text(
              widget.isExpertOnly
                  ? 'Your submitted observations will appear here.'
                  : 'System observations will show up here.',
              style: TextStyle(color: Colors.grey[500]),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Responsive grid view for Web
        final crossAxisCount = constraints.maxWidth > 1200
            ? 3
            : constraints.maxWidth > 800
                ? 2
                : 1;

        return Column(
          children: [
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(24.0),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                  mainAxisExtent: 150,
                ),
                itemCount: _observations.length,
                itemBuilder: (context, index) {
            final obs = _observations[index];
            final rawTimestamp = obs['observation_timestamp'] ?? obs['upload_timestamp'];
            final rawDate = rawTimestamp != null ? DateTime.tryParse(rawTimestamp.toString()) : null;
            final dateStr = rawDate != null ? DateFormat.yMMMd().add_jm().format(rawDate.toLocal()) : 'N/A';
            final source = obs['source']?.toString().toUpperCase() ?? 'UPLOAD';
            final imageUrl = obs['image_url']?.toString();
            final isVerified = obs['verification_result'] == 'APPROVED' || obs['verification_result'] == 'REJECTED';
            final isPending = obs['under_verification'] == true && obs['verification_result'] == 'PENDING';
            final isPublic = obs['is_public'] == true;
            final isAnonymous = obs['is_anonymous'] == true;
            final isOwner = obs['user_id'] == Supabase.instance.client.auth.currentUser?.id;
            final contributorName = (isPublic && isAnonymous && !isOwner)
                ? 'Anonymous Scout'
                : (obs['users'] != null && obs['users'] is Map
                    ? (obs['users'] as Map)['user_name']?.toString() ?? 'Unknown User'
                    : 'Unknown User');

            String verifyText = 'UNVERIFIED';
            Color verifyBg = Colors.grey[100]!;
            Color verifyTextCol = Colors.grey[700]!;
            if (obs['verification_result'] == 'APPROVED') {
              verifyText = 'APPROVED';
              verifyBg = Colors.green[50]!;
              verifyTextCol = Colors.green[800]!;
            } else if (obs['verification_result'] == 'REJECTED') {
              verifyText = 'REJECTED';
              verifyBg = Colors.red[50]!;
              verifyTextCol = Colors.red[800]!;
            } else if (isPending) {
              verifyText = 'PENDING';
              verifyBg = Colors.purple[50]!;
              verifyTextCol = Colors.purple[800]!;
            }

            return Card(
              elevation: 2,
              shadowColor: Colors.black.withValues(alpha: 0.05),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16.0),
              ),
              color: Colors.white,
              child: InkWell(
                borderRadius: BorderRadius.circular(16.0),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ObservationDetailsPage(
                        obs: obs,
                        isVerifyMode: !widget.isExpertOnly,
                        showViewOnMapButton: widget.isExpertOnly,
                        currentUserRole: _currentUserRole,
                        onViewOnMap: widget.onViewOnMap,
                      ),
                    ),
                  ).then((value) {
                    if (value == true && !widget.isExpertOnly) {
                      setState(() {
                        _observations.removeWhere((item) => item['observation_id'] == obs['observation_id']);
                        if (_totalCount > 0) _totalCount--;
                      });
                    }
                    // Always refresh on return so newly queued/changed observations
                    // that arrived while viewing details show up immediately.
                    _fetchObservations(isSilent: true);
                  });
                },
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Image Preview
                  ClipRRect(
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(16.0),
                      bottomLeft: Radius.circular(16.0),
                    ),
                    child: SizedBox(
                      width: 130,
                      child: imageUrl != null && imageUrl.isNotEmpty
                          ? Image.network(
                              imageUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) => Container(
                                color: Colors.green[50],
                                child: Icon(Icons.image_not_supported_outlined, color: Colors.green[200]),
                              ),
                            )
                          : Container(
                              color: Colors.green[50],
                              child: Icon(Icons.park_outlined, color: Colors.green[200], size: 40),
                            ),
                    ),
                  ),
                  // Details
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            dateStr,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4.0),
                          if (!widget.isExpertOnly) ...[
                            Row(
                              children: [
                                Icon(Icons.person_outline, size: 14, color: Colors.grey[600]),
                                const SizedBox(width: 4.0),
                                Expanded(
                                  child: Text(
                                    'By: $contributorName',
                                    style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (isAnonymous && isOwner) ...[
                                  const SizedBox(width: 4.0),
                                  Icon(Icons.visibility_off_rounded, size: 12, color: Colors.purple[700]),
                                ],
                              ],
                            ),
                            const SizedBox(height: 4.0),
                          ],
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              if (widget.isExpertOnly) ...[
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: Colors.blue[50],
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: Colors.blue[200]!),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.camera_alt_outlined, size: 11, color: Colors.blue[700]),
                                      const SizedBox(width: 4),
                                      Text(
                                        source,
                                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.blue[700], letterSpacing: 0.5),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: verifyBg,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: verifyTextCol.withValues(alpha: 0.3)),
                                  ),
                                  child: Text(
                                    verifyText,
                                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: verifyTextCol, letterSpacing: 0.5),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: isPublic ? Colors.teal[50] : Colors.grey[100],
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: isPublic ? Colors.teal[200]! : Colors.grey[300]!),
                                  ),
                                  child: Text(
                                    isPublic ? 'PUBLIC' : 'PRIVATE',
                                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: isPublic ? Colors.teal[700] : Colors.grey[600], letterSpacing: 0.5),
                                  ),
                                ),
                                if (isAnonymous)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: Colors.purple[50],
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: Colors.purple[200]!),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.visibility_off_rounded, size: 11, color: Colors.purple[700]),
                                        const SizedBox(width: 4),
                                        Text(
                                          'ANONYMOUS',
                                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.purple[700], letterSpacing: 0.5),
                                        ),
                                      ],
                                    ),
                                  ),
                              ] else if (isVerified)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: Colors.blue[50],
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: Colors.blue[200]!),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.verified_rounded, color: Colors.blue, size: 12),
                                      const SizedBox(width: 4),
                                      Text('VERIFIED', style: TextStyle(color: Colors.blue[800], fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                                    ],
                                  ),
                                )
                              else
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: Colors.orange[50],
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: Colors.orange[200]!),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.pending_actions_outlined, color: Colors.orange[800], size: 12),
                                      const SizedBox(width: 4),
                                      Text(
                                        (isPending ? 'PENDING' : 'NEEDS VERIFICATION'),
                                        style: TextStyle(color: Colors.orange[800], fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.5),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  ],
                ),
              ),
            );
          },
        ),
            ),
            if (_totalPages > 1)
              Padding(
                padding: const EdgeInsets.only(right: 24.0, bottom: 24.0, top: 8.0),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: _currentPage > 0 ? () { setState(() => _currentPage = 0); _fetchObservations(); } : null,
                        icon: const Icon(Icons.first_page),
                        tooltip: 'First Page',
                        style: IconButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                      ),
                      IconButton(
                        onPressed: _currentPage > 0 ? () { setState(() => _currentPage--); _fetchObservations(); } : null,
                        icon: const Icon(Icons.chevron_left),
                        tooltip: 'Previous Page',
                        style: IconButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                      ),
                      
                      ...List.generate(_totalPages, (index) {
                        if (index == 0 || index == _totalPages - 1 || (index >= _currentPage - 2 && index <= _currentPage + 2)) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2.0),
                            child: ElevatedButton(
                              onPressed: _currentPage == index ? null : () {
                                setState(() => _currentPage = index);
                                _fetchObservations();
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _currentPage == index ? Colors.green[700] : Colors.white,
                                foregroundColor: _currentPage == index ? Colors.white : Colors.black87,
                                minimumSize: const Size(36, 36),
                                padding: EdgeInsets.zero,
                                elevation: _currentPage == index ? 2 : 0,
                                side: BorderSide(color: Colors.grey[300]!),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              child: Text('${index + 1}'),
                            ),
                          );
                        } else if (index == _currentPage - 3 || index == _currentPage + 3) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 4.0),
                            child: Text('...'),
                          );
                        }
                        return const SizedBox.shrink();
                      }),

                      IconButton(
                        onPressed: _currentPage < _totalPages - 1 ? () { setState(() => _currentPage++); _fetchObservations(); } : null,
                        icon: const Icon(Icons.chevron_right),
                        tooltip: 'Next Page',
                        style: IconButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                      ),
                      IconButton(
                        onPressed: _currentPage < _totalPages - 1 ? () { setState(() => _currentPage = _totalPages - 1); _fetchObservations(); } : null,
                        icon: const Icon(Icons.last_page),
                        tooltip: 'Last Page',
                        style: IconButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
