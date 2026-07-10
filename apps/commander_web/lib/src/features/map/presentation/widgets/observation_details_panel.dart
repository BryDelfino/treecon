import 'package:flutter/material.dart';

class ObservationDetailsPanel extends StatefulWidget {
  final Map<String, dynamic> obs;
  final VoidCallback onClose;
  final Future<void> Function() onDelete;

  const ObservationDetailsPanel({
    super.key,
    required this.obs,
    required this.onClose,
    required this.onDelete,
  });

  @override
  State<ObservationDetailsPanel> createState() => _ObservationDetailsPanelState();
}

class _ObservationDetailsPanelState extends State<ObservationDetailsPanel> {
  bool _isDeleting = false;

  Future<void> _handleDelete() async {
    setState(() => _isDeleting = true);
    try {
      await widget.onDelete();
    } finally {
      if (mounted) setState(() => _isDeleting = false);
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
    final isVerified = widget.obs['is_verified'] == true || widget.obs['sync_status'] == 'verified';
    final verificationResult = widget.obs['verification_result']?.toString() ?? 'NONE';
    final underVerification = widget.obs['under_verification'] == true;
    
    final imageUrl = widget.obs['image_url']?.toString();

    String verifyStatusText = 'Unverified';
    Color verifyColor = Colors.orange;
    
    if (isVerified) {
      verifyStatusText = 'Verified';
      verifyColor = Colors.blue;
    } else if (underVerification) {
      verifyStatusText = 'Pending Verification';
      verifyColor = Colors.purple;
    } else if (verificationResult == 'FAILED') {
      verifyStatusText = 'Verification Rejected';
      verifyColor = Colors.red;
    }
    
    final contributorName = widget.obs['users'] != null && widget.obs['users'] is Map
        ? (widget.obs['users'] as Map)['user_name']?.toString() ?? 'Unknown User'
        : 'Unknown User';

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        width: 400,
        margin: const EdgeInsets.only(left: 16, top: 16, bottom: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 15,
              offset: const Offset(0, 4),
            )
          ],
        ),
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  Icon(Icons.person_pin_circle, color: Colors.blue[700]),
                  const SizedBox(width: 8),
                  const Text('Observation Details', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Body
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16.0),
                children: [
                  if (imageUrl != null && imageUrl.isNotEmpty) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.network(
                        imageUrl,
                        height: 250,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => Container(
                          height: 250,
                          color: Colors.grey[100],
                          child: const Center(child: Icon(Icons.broken_image, size: 64, color: Colors.grey)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ] else ...[
                    Container(
                      height: 250,
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Center(child: Icon(Icons.park, size: 64, color: Colors.grey)),
                    ),
                    const SizedBox(height: 16),
                  ],
                  
                  _buildMetaRow(Icons.person, 'Observer', contributorName),
                  _buildMetaRow(Icons.calendar_today, 'Observation Date', dateStr),
                  _buildMetaRow(Icons.cloud_upload, 'Upload Date', uploadStr),
                  _buildMetaRow(Icons.device_hub, 'Source', source),
                  _buildMetaRow(
                    isPublic ? Icons.public : Icons.lock, 
                    'Visibility', 
                    isPublic ? 'Public' : 'Private',
                    color: isPublic ? Colors.blue : Colors.grey
                  ),
                  _buildMetaRow(
                    isVerified ? Icons.verified : (underVerification ? Icons.pending_actions : Icons.new_releases), 
                    'Status', 
                    verifyStatusText,
                    color: verifyColor
                  ),
                  
                  if (verificationResult == 'FAILED' && widget.obs['remarks'] != null)
                    Container(
                      margin: const EdgeInsets.only(top: 16),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: Colors.red[50], borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.red[200]!)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Rejection Remarks', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
                          const SizedBox(height: 4),
                          Text(widget.obs['remarks'].toString(), style: const TextStyle(color: Colors.black87)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Actions
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: _isDeleting
                  ? const Center(child: CircularProgressIndicator())
                  : SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _handleDelete,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Delete Observation'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          side: const BorderSide(color: Colors.red),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
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
                Text(value, style: TextStyle(fontSize: 14, color: color ?? Colors.black87)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
