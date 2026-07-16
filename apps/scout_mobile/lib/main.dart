import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_services/shared_services.dart';
import 'package:scout_mobile/src/app.dart';
import 'package:scout_mobile/src/core/services/network_service.dart';
import 'package:scout_mobile/src/features/observations/data/observation_local_db.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  await dotenv.load(fileName: '.env');

  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL'] ?? '',
    publishableKey: dotenv.env['SUPABASE_PUBLISHABLE_KEY'] ?? '',
  );

  // Initialize NetworkService & local database wrapper
  await NetworkService.instance.init();
  await ObservationLocalDb.instance.open();

  runApp(const MyApp());
}