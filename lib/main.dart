import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'core/storage.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = AppStorage(await SharedPreferences.getInstance());
  runApp(QuotaApp(storage: storage));
}
