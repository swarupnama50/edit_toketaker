import 'package:flutter/material.dart';
import 'package:token_taker/cloud_sync.dart'; // NEW
import 'package:token_taker/first_screen.dart';

Future<void> main() async {
  // CHANGED: async
  WidgetsFlutterBinding.ensureInitialized(); // NEW
  await CloudSync.init(); // NEW

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: FirstScreen(),
    );
  }
}
