import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class FullscreenReturnNavigation {
  const FullscreenReturnNavigation._();

  /// Close overlays belonging to the player before removing the player route.
  /// A native fullscreen exit can arrive while a popup or dialog is open.
  static void returnToCaller(BuildContext context) {
    final owner = ModalRoute.of(context);
    if (owner != null) {
      Navigator.of(context).popUntil((route) => identical(route, owner));
    }
    final router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
    } else {
      router.go('/');
    }
  }
}
