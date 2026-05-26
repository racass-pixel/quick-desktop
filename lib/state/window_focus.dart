// Tracks whether the Quick window is the foreground window. Fed by main.dart's
// WindowListener (onWindowFocus / onWindowBlur). Consumed by the notifications
// bridge to suppress in-app toasts when the relevant chat is already visible.

import 'package:flutter_riverpod/flutter_riverpod.dart';

final windowFocusedProvider = StateProvider<bool>((_) => true);
