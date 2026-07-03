import 'package:flutter/material.dart';
import 'package:shared_services/shared_services.dart';
import 'package:scout_mobile/src/app.dart';
import 'package:scout_mobile/src/core/services/network_service.dart';
import 'package:scout_mobile/src/features/observations/data/observation_local_db.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  await Supabase.initialize(
    url: const String.fromEnvironment('SUPABASE_URL'),
    publishableKey: const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
  );

  // Initialize NetworkService & local database wrapper
  await NetworkService.instance.init();
  await ObservationLocalDb.instance.open();
  
  final pending = await ObservationLocalDb.instance.getPending();
  final hasPending = pending.isNotEmpty;

  runApp(MyApp(hasPending: hasPending));
}