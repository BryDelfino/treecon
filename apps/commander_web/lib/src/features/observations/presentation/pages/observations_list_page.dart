import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'package:shared_services/shared_services.dart';
import 'observation_details_page.dart';

class ObservationsListPage extends StatefulWidget {
  final bool isExpertOnly;

  const ObservationsListPage({
    super.key,
    required this.isExpertOnly,
  });

  @override
  State<ObservationsListPage> createState() => _ObservationsListPageState();
}

class _ObservationsListPageState extends State<ObservationsListPage> {
  RealtimeChannel? _subscription;
  List<Map<String, dynamic>> _observations = [];
  bool _isLoading = true;
  String? _error;

  DateTime? _filterStartDate;
  DateTime? _filterEndDate;
  String _searchUserName = '';
  bool? _filterIsVerified; // true for Verified, false for Unverified, null for All
  bool _sortAscending = false;
  
  final int _pageSize = 21;
  int _currentPage = 0;
  int _totalCount = 0;
  int get _totalPages {
    final pages = (_totalCount / _pageSize).ceil();
    return pages > 0 ? pages : 1;
  }

  @override
  void initState() {
    super.initState();
    _fetchObservations(resetPage: true);
    _setupRealtime();
  }

  void _setupRealtime() {
    if (widget.isExpertOnly) return; // Only notify global queue viewers

    _subscription = Supabase.instance.client
        .channel('public:observations')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'observations',
          callback: (payload) {
            final newRow = payload.newRecord;
            if (newRow['under_verification'] == true && newRow['verification_result'] == 'PENDING') {
              if (mounted) {
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

  Future<void> _fetchObservations({bool resetPage = false}) async {
    if (!mounted) return;
    
    if (resetPage) {
      _currentPage = 0;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        throw Exception('User not authenticated');
      }

      var query = Supabase.instance.client.from('observations').select('*, users!observations_user_id_fkey!inner(user_name)');

      if (widget.isExpertOnly) {
        query = query.eq('user_id', user.id);
      } else {
        query = query.eq('under_verification', true).eq('is_public', true);
        if (_searchUserName.isNotEmpty) {
          query = query.ilike('users.user_name', '%$_searchUserName%');
        }
      }
      
      if (_filterStartDate != null) {
        query = query.gte('observation_timestamp', _filterStartDate!.toUtc().toIso8601String());
      }
      if (_filterEndDate != null) {
        // Add 1 day to include the end date fully
        query = query.lte('observation_timestamp', _filterEndDate!.add(const Duration(days: 1)).toUtc().toIso8601String());
      }
      
      if (_filterIsVerified != null) {
        if (_filterIsVerified!) {
          query = query.eq('is_verified', true);
        } else {
          // Unverified can mean is_verified is false or null
          query = query.or('is_verified.eq.false,is_verified.is.null');
        }
      }

      final response = await query
          .order('observation_timestamp', ascending: _sortAscending)
          .range(_currentPage * _pageSize, ((_currentPage + 1) * _pageSize) - 1)
          .count(CountOption.exact);

      if (mounted) {
        setState(() {
          final data = response.data;
          _totalCount = response.count;
          _observations = (data as List<dynamic>).map((e) => e as Map<String, dynamic>).toList();
          
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

  Color _getSeverityColor(String? severity) {
    switch (severity?.toLowerCase()) {
      case 'healthy':
        return Colors.green;
      case 'low':
        return Colors.blue;
      case 'moderate':
        return Colors.orange;
      case 'high':
        return Colors.deepOrange;
      case 'severe':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  void _showFilterModal() {
    DateTime? tempStart = _filterStartDate;
    DateTime? tempEnd = _filterEndDate;
    final searchController = TextEditingController(text: _searchUserName);
    bool? tempIsVerified = _filterIsVerified;

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
                    if (!widget.isExpertOnly) ...[
                      const Text('Search by User', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: searchController,
                        decoration: InputDecoration(
                          hintText: 'Enter user name',
                          prefixIcon: const Icon(Icons.person_search, size: 20),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                    const Text('Verification Status', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<bool?>(
                      initialValue: tempIsVerified,
                      decoration: InputDecoration(
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                      items: const [
                        DropdownMenuItem(value: null, child: Text('All Statuses')),
                        DropdownMenuItem(value: true, child: Text('Verified Only')),
                        DropdownMenuItem(value: false, child: Text('Unverified Only')),
                      ],
                      onChanged: (value) {
                        setModalState(() => tempIsVerified = value);
                      },
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
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      _filterStartDate = null;
                      _filterEndDate = null;
                      _searchUserName = '';
                      _filterIsVerified = null;
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
                      _searchUserName = searchController.text.trim();
                      _filterIsVerified = tempIsVerified;
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

  void _showAddObservationPlaceholder() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(Icons.add_photo_alternate_outlined, color: Colors.green[700]),
              const SizedBox(width: 10),
              const Text('Add Observation'),
            ],
          ),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This is a placeholder for adding new Falcata tree observations.',
                style: TextStyle(fontSize: 14, color: Colors.black87),
              ),
              SizedBox(height: 12),
              Text(
                'In the final release, this will allow experts to upload field photographs, specify coordinates, and classify the gall rust severity manually or automatically.',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Close', style: TextStyle(color: Colors.green[700], fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.isExpertOnly ? "My Observations" : "All System Observations";

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
                onPressed: _showAddObservationPlaceholder,
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
                  crossAxisSpacing: 20,
                  mainAxisSpacing: 20,
                  mainAxisExtent: 180,
                ),
                itemCount: _observations.length,
                itemBuilder: (context, index) {
            final obs = _observations[index];
            final severity = obs['confidence_score'] != null ? 'high' : 'unknown';
            final severityColor = _getSeverityColor(severity);
            final rawTimestamp = obs['observation_timestamp'] ?? obs['upload_timestamp'];
            final dateStr = rawTimestamp != null
                ? DateTime.tryParse(rawTimestamp.toString())?.toLocal().toString().substring(0, 16) ?? rawTimestamp.toString()
                : 'N/A';
            final coords = _parseCoordinates(obs['coordinates']);
            final latStr = coords != null ? coords['lat']!.toStringAsFixed(6) : 'N/A';
            final lngStr = coords != null ? coords['lng']!.toStringAsFixed(6) : 'N/A';
            final captureMethod = obs['source']?.toString() ?? 'UPLOAD';
            const evaluationMethod = 'MANUAL';
            final imageUrl = obs['image_url']?.toString();
            final isVerified = obs['verification_result'] == 'APPROVED' || obs['verification_result'] == 'REJECTED';
            final contributorName = obs['users'] != null && obs['users'] is Map
                ? (obs['users'] as Map)['user_name']?.toString() ?? 'Unknown User'
                : 'Unknown User';

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
                      ),
                    ),
                  ).then((value) {
                    if (value == true && !widget.isExpertOnly) {
                      setState(() {
                        _observations.removeWhere((item) => item['observation_id'] == obs['observation_id']);
                      });
                    }
                    _fetchObservations();
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
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 4.0),
                                decoration: BoxDecoration(
                                  color: severityColor.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(100.0),
                                ),
                                child: Text(
                                  severity.toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: severityColor,
                                  ),
                                ),
                              ),
                              Text(
                                dateStr,
                                style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                              ),
                            ],
                          ),
                          const Spacer(),
                          Row(
                            children: [
                              Icon(Icons.location_on_outlined, size: 14, color: Colors.green[700]),
                              const SizedBox(width: 4.0),
                              Expanded(
                                child: Text(
                                  'Lat: $latStr, Lng: $lngStr',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.black87,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4.0),
                          Row(
                            children: [
                              Icon(Icons.camera_alt_outlined, size: 14, color: Colors.grey[600]),
                              const SizedBox(width: 4.0),
                              Text(
                                'Method: $captureMethod ($evaluationMethod)',
                                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4.0),
                          Row(
                            children: [
                              Icon(Icons.person_outline, size: 14, color: Colors.grey[600]),
                              const SizedBox(width: 4.0),
                              Text(
                                'By: $contributorName',
                                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                              ),
                            ],
                          ),
                          const Spacer(),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              if (isVerified)
                                const Row(
                                  children: [
                                    Icon(Icons.verified_rounded, color: Colors.blue, size: 16),
                                    SizedBox(width: 4),
                                    Text(
                                      'Verified',
                                      style: TextStyle(
                                        color: Colors.blue,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                )
                              else if (!widget.isExpertOnly)
                                const Row(
                                  children: [
                                    Icon(Icons.pending_actions_outlined, color: Colors.orange, size: 16),
                                    SizedBox(width: 4),
                                    Text(
                                      'Needs Verification',
                                      style: TextStyle(
                                        color: Colors.orange,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                )
                              else
                                const Row(
                                  children: [
                                    Icon(Icons.pending_actions_outlined, color: Colors.orange, size: 16),
                                    SizedBox(width: 4),
                                    Text(
                                      'Unverified',
                                      style: TextStyle(
                                        color: Colors.orange,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
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
