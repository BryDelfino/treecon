import 'dart:io';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ObservationDetailsPage extends StatefulWidget {
  final Map<String, dynamic> obs;
  final bool isCached;

  const ObservationDetailsPage({super.key, required this.obs, this.isCached = false});

  @override
  State<ObservationDetailsPage> createState() => _ObservationDetailsPageState();
}

class _ObservationDetailsPageState extends State<ObservationDetailsPage> {
  bool _isLoading = false;
  bool _wasModified = false;
  RealtimeChannel? _subscription;

  @override
  void initState() {
    super.initState();
    if (!widget.isCached) {
      _syncLatestState();
      _setupRealtime();
    }
  }

  void _setupRealtime() {
    final observationId = widget.obs['observation_id'];
    _subscription = Supabase.instance.client
        .channel('public:observations:detail:$observationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'observations',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'observation_id',
            value: observationId,
          ),
          callback: (payload) async {
            if (mounted) {
              final oldResult = widget.obs['verification_result'];
              await _syncLatestState();
              setState(() {
                _wasModified = true;
              });
              
              final newResult = widget.obs['verification_result'];
              if (oldResult != newResult) {
                if (newResult == 'APPROVED') {
                  _showToast('✅ Your observation was just Approved by an expert!');
                } else if (newResult == 'REJECTED') {
                  _showToast('❌ Your observation was just Rejected by an expert.');
                }
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

  void _showToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<bool> _syncLatestState() async {
    if (widget.isCached) return true;
    try {
      final id = widget.obs['observation_id'];
      final latest = await Supabase.instance.client
          .from('observations')
          .select('is_public, under_verification, verification_result, remarks, verification_timestamp, verifier:users!observations_verifier_id_fkey(user_name)')
          .eq('observation_id', id)
          .maybeSingle();
      if (latest != null && mounted) {
        setState(() {
          widget.obs['is_public'] = latest['is_public'];
          widget.obs['under_verification'] = latest['under_verification'];
          widget.obs['verification_result'] = latest['verification_result'];
          widget.obs['remarks'] = latest['remarks'];
          widget.obs['verification_timestamp'] = latest['verification_timestamp'];
          if (latest['verifier'] != null) {
            widget.obs['verifier'] = latest['verifier'];
          }
        });
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> _handleDelete() async {
    if (widget.isCached) {
      Navigator.pop(context, 'DELETE');
    } else {
      setState(() => _isLoading = true);
      try {
        final id = widget.obs['observation_id'];
        await Supabase.instance.client
            .from('observations')
            .update({'is_deleted': true})
            .eq('observation_id', id);
        if (mounted) {
          _showToast('Observation deleted successfully.');
          Navigator.pop(context, 'DELETED_SYSTEM');
        }
      } catch (e) {
        _showToast('Failed to delete: $e');
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _handleUpload() async {
    Navigator.pop(context, 'UPLOAD');
  }

  Future<void> _handleRequestVerification() async {
    setState(() => _isLoading = true);
    await _syncLatestState();
    setState(() => _isLoading = false);

    if (widget.obs['under_verification'] == true || widget.obs['verification_result'] == 'APPROVED' || widget.obs['verification_result'] == 'REJECTED') {
      _showToast('Observation is already under verification or verified.');
      return;
    }

    final isPublic = widget.obs['is_public'] == true;
    
    if (!isPublic) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Make Public?'),
          content: const Text('For your observation to be verified by experts, its visibility must be set to public. Do you want to proceed and make this observation public?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Proceed', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );

      if (confirm != true) return;
    }

    setState(() => _isLoading = true);
    try {
      final id = widget.obs['observation_id'];
      await Supabase.instance.client
          .from('observations')
          .update({
            'is_public': true,
            'under_verification': true,
            'verification_result': 'PENDING'
          })
          .eq('observation_id', id);
          
      if (mounted) {
        _showToast('Verification requested successfully.');
        setState(() {
          widget.obs['is_public'] = true;
          widget.obs['under_verification'] = true;
          widget.obs['verification_result'] = 'PENDING';
        });
        _wasModified = true;
      }
    } catch (e) {
      _showToast('Failed to request verification: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleCancelVerification() async {
    setState(() => _isLoading = true);
    await _syncLatestState();
    setState(() => _isLoading = false);

    if (widget.obs['under_verification'] != true) {
      _showToast('Observation is no longer pending verification.');
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Request?'),
        content: const Text('Are you sure you want to cancel your request for expert verification?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes, Cancel', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isLoading = true);
    try {
      final id = widget.obs['observation_id'];
      await Supabase.instance.client
          .from('observations')
          .update({
            'under_verification': false,
            'verification_result': null,
          })
          .eq('observation_id', id);
          
      if (mounted) {
        _showToast('Verification request cancelled.');
        setState(() {
          widget.obs['under_verification'] = false;
          widget.obs['verification_result'] = null;
        });
        _wasModified = true;
      }
    } catch (e) {
      _showToast('Failed to cancel request: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleToggleVisibility() async {
    setState(() => _isLoading = true);
    await _syncLatestState();
    setState(() => _isLoading = false);

    final isPublic = widget.obs['is_public'] == true;
    final underVerification = widget.obs['under_verification'] == true;

    if (isPublic && underVerification) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Warning'),
          content: const Text('Setting this observation to private will also remove it from the expert verification queue. Do you want to proceed?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Proceed', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

    setState(() => _isLoading = true);
    try {
      final id = widget.obs['observation_id'];
      final updates = <String, dynamic>{'is_public': !isPublic};
      if (isPublic && underVerification) {
        updates['under_verification'] = false;
        updates['verification_result'] = null;
      }

      await Supabase.instance.client
          .from('observations')
          .update(updates)
          .eq('observation_id', id);
          
      if (mounted) {
        _showToast(isPublic ? 'Observation is now private.' : 'Observation is now public.');
        setState(() {
          widget.obs['is_public'] = !isPublic;
          if (isPublic && underVerification) {
            widget.obs['under_verification'] = false;
            widget.obs['verification_result'] = null;
          }
        });
        _wasModified = true;
      }
    } catch (e) {
      _showToast('Failed to toggle visibility: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateStr = widget.obs['observation_timestamp'] != null
        ? DateTime.tryParse(widget.obs['observation_timestamp'])?.toLocal().toString().split('.')[0] ?? widget.obs['observation_timestamp']
        : 'Unknown Date';
    final uploadStr = widget.obs['upload_timestamp'] != null
        ? DateTime.tryParse(widget.obs['upload_timestamp'])?.toLocal().toString().split('.')[0] ?? widget.obs['upload_timestamp']
        : 'Not Uploaded Yet';
        
    final source = widget.obs['source']?.toString() ?? 'N/A';
    final isPublic = widget.obs['is_public'] == true;
    final isVerified = widget.obs['verification_result'] == 'APPROVED' || widget.obs['verification_result'] == 'REJECTED';
    final verificationResult = widget.obs['verification_result']?.toString() ?? 'NONE';
    final underVerification = widget.obs['under_verification'] == true;
    
    final imageUrl = widget.obs['image_url']?.toString();
    final localImagePath = widget.obs['image_path']?.toString();
    final isOwner = widget.obs['user_id'] == Supabase.instance.client.auth.currentUser?.id;

    String verifyStatusText = 'Unverified';
    Color verifyColor = Colors.orange;
    
    if (isVerified) {
      if (verificationResult == 'APPROVED') {
        verifyStatusText = 'Verified (Approved)';
        verifyColor = Colors.blue;
      } else if (verificationResult == 'REJECTED') {
        verifyStatusText = 'Verified (Rejected)';
        verifyColor = Colors.red;
      } else {
        verifyStatusText = 'Verified';
        verifyColor = Colors.blue;
      }
    } else if (underVerification) {
      verifyStatusText = 'Pending Verification';
      verifyColor = Colors.purple;
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.pop(context, _wasModified ? 'MODIFIED' : null);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Observation Details', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          backgroundColor: Colors.white,
          foregroundColor: Colors.green[800],
          elevation: 1,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context, _wasModified ? 'MODIFIED' : null),
          ),
        ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(16.0),
            children: [
              // Image
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: localImagePath != null && localImagePath.isNotEmpty && File(localImagePath).existsSync()
                    ? Image.file(
                        File(localImagePath),
                        height: 250,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      )
                    : (imageUrl != null && imageUrl.isNotEmpty
                        ? Image.network(
                            imageUrl,
                            height: 250,
                            width: double.infinity,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => Container(
                              height: 250,
                              color: Colors.green[50],
                              child: Icon(Icons.broken_image, color: Colors.green[200], size: 64),
                            ),
                          )
                        : Container(
                            height: 250,
                            color: Colors.green[50],
                            child: Icon(Icons.park_outlined, color: Colors.green[200], size: 64),
                          )),
              ),
              const SizedBox(height: 24),
              
              // Metadata
              _buildMetaRow(Icons.calendar_today, 'Observation Date', dateStr),
              _buildMetaRow(Icons.cloud_upload, 'Upload Date', widget.isCached ? 'Not Uploaded' : uploadStr),
              _buildMetaRow(Icons.device_hub, 'Source', source),
              _buildMetaRow(
                Icons.analytics_outlined,
                'Confidence Score',
                widget.obs['confidence_score']?.toString() ?? 'N/A',
              ),
              _buildMetaRow(
                isPublic ? Icons.public : Icons.lock, 
                'Visibility', 
                isPublic ? (underVerification ? 'Public (For Verification)' : 'Public') : 'Private',
                color: isPublic ? Colors.blue : Colors.grey
              ),
              _buildMetaRow(
                isVerified ? Icons.verified : (underVerification ? Icons.pending_actions : Icons.new_releases), 
                'Status', 
                verifyStatusText,
                color: verifyColor
              ),
              if (isVerified) ...[
                _buildMetaRow(Icons.person_pin, 'Verified By', widget.obs['verifier']?['user_name']?.toString() ?? 'Unknown Expert'),
                _buildMetaRow(Icons.access_time, 'Verification Time', widget.obs['verification_timestamp'] != null ? DateTime.tryParse(widget.obs['verification_timestamp'])?.toLocal().toString().split('.')[0] ?? 'Unknown Date' : 'Unknown Date'),
              ],
              
              if (widget.obs['remarks'] != null && widget.obs['remarks'].toString().isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(top: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.grey[300]!)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Remarks', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
                      const SizedBox(height: 4),
                      Text(widget.obs['remarks'].toString(), style: const TextStyle(color: Colors.black87)),
                    ],
                  ),
                ),

              const SizedBox(height: 32),
              
              // Action Buttons
              if (widget.isCached)
                ElevatedButton.icon(
                  onPressed: _handleUpload,
                  icon: const Icon(Icons.cloud_upload),
                  label: const Text('Upload to System'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
                
              if (!widget.isCached && !isVerified && !underVerification && isOwner) ...[
                ElevatedButton.icon(
                  onPressed: _handleRequestVerification,
                  icon: const Icon(Icons.fact_check),
                  label: const Text('Request Expert Verification'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.purple,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ],
              
              if (!widget.isCached && underVerification && isOwner) ...[
                OutlinedButton.icon(
                  onPressed: _handleCancelVerification,
                  icon: const Icon(Icons.cancel_schedule_send),
                  label: const Text('Cancel Verification Request'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.orange,
                    side: const BorderSide(color: Colors.orange),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ],

              if (!widget.isCached && isOwner && verificationResult != 'REJECTED') ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _handleToggleVisibility,
                  icon: Icon(isPublic ? Icons.lock : Icons.public),
                  label: Text(isPublic ? 'Set to Private' : 'Set to Public'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: isPublic ? Colors.grey : Colors.blue,
                    side: BorderSide(color: isPublic ? Colors.grey : Colors.blue),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ],
                
              const SizedBox(height: 12),
              
              if (isOwner || widget.isCached)
                OutlinedButton.icon(
                  onPressed: _handleDelete,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete Observation'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
            ],
          ),
          if (_isLoading)
            Container(
              color: Colors.black.withOpacity(0.3),
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    ));
  }

  Widget _buildMetaRow(IconData icon, String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color ?? Colors.grey[600]),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[600], fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(value, style: TextStyle(fontSize: 15, color: color ?? Colors.black87)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
