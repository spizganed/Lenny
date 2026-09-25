import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'brand.dart';
import 'theme/lenny_colors.dart';
import 'ui/screens/receiver_screen.dart';
import 'ui/screens/sender_screen.dart';

void main() => runApp(const ProviderScope(child: LennyApp()));

class LennyApp extends StatelessWidget {
  const LennyApp({super.key});

  // Phones send, desktops receive (architecture.md §10).
  static final bool isSender = Platform.isAndroid || Platform.isIOS;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: isSender ? Brand.appName : Brand.desktopAppName,
        theme: lennyTheme(),
        debugShowCheckedModeBanner: false,
        home: isSender ? const SenderScreen() : const ReceiverScreen(),
      );
}
