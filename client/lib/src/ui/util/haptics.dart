import 'package:flutter/services.dart';

/// Centralized haptic feedback controller that respects the user's preference.
abstract final class ZHaptics {
  static bool enabled = true;

  static void selection() {
    if (!enabled) return;
    HapticFeedback.selectionClick();
  }

  static void light() {
    if (!enabled) return;
    HapticFeedback.lightImpact();
  }

  static void medium() {
    if (!enabled) return;
    HapticFeedback.mediumImpact();
  }

  static void heavy() {
    if (!enabled) return;
    HapticFeedback.heavyImpact();
  }
}
