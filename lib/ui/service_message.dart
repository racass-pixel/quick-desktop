// Centered pill-style system event rendered inline in the thread. Replaces
// the usual bubble layout for messages whose `kind == 'service'` OR whose
// body parses as JSON with a top-level `type` field.
//
// Mirrors the web client's ServiceMessage.tsx. The wire `body` is JSON of a
// structured payload that varies by `type`. Parsing is defensive — an
// unrecognised or malformed payload renders as a short "system message"
// fallback so we don't blow up the thread.
//
// Handled types:
//   * member_joined / joined         — "<name> joined the group"
//   * member_left / left             — "<name> left"
//   * member_added                   — "<by> added <user>"
//   * member_removed                 — "<by> removed <user>"
//   * call_ended                     — "Call - mm:ss" (Video call - mm:ss)
//   * call_missed                    — "Missed call" (err tone)
//   * voice_chat_started / _ended    — "Voice chat started" / "Voice chat ended"
//   * title_changed                  — "<by> changed group name to "<new>""
//
// When a referenced user_id is not known locally we fall back to a truncated
// id; the chats controller doesn't yet maintain a full members cache, so
// "Someone" style placeholders are sometimes the best we can do.

import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/dto.dart';
import '../theme/theme.dart';

/// True when [body] looks like a service-payload JSON envelope (`{"type": ...}`).
/// Used by the message renderer to sniff messages whose `kind` field was lost
/// over HTTP (ListMessages strips fields not in the proto).
bool looksLikeServicePayload(String body) {
  if (body.isEmpty) return false;
  final t = body.trimLeft();
  if (!t.startsWith('{')) return false;
  try {
    final parsed = json.decode(body);
    return parsed is Map && parsed['type'] is String;
  } catch (_) {
    return false;
  }
}

Map<String, dynamic>? _parseEvent(String body) {
  if (body.isEmpty) return null;
  try {
    final parsed = json.decode(body);
    if (parsed is Map && parsed['type'] is String) {
      return parsed.cast<String, dynamic>();
    }
  } catch (_) {
    // not JSON — fall through
  }
  return null;
}

String _fmtDuration(int secs) {
  if (secs <= 0) return '0:00';
  final m = secs ~/ 60;
  final s = secs % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

String _shortId(String? id) {
  if (id == null || id.isEmpty) return 'someone';
  return id.length > 8 ? '${id.substring(0, 8)}…' : id;
}

/// Optional resolver that the host can pass to turn a user id into a display
/// label. The chats store doesn't ship a members cache yet — when absent we
/// fall back to a truncated id.
typedef NameResolver = String Function(String userId);

class ServiceMessageBubble extends StatelessWidget {
  const ServiceMessageBubble({
    super.key,
    required this.message,
    this.resolveName,
  });

  final Message message;
  final NameResolver? resolveName;

  String _name(String? userId) {
    if (userId == null || userId.isEmpty) return 'someone';
    final r = resolveName;
    if (r != null) {
      final n = r(userId);
      if (n.isNotEmpty) return n;
    }
    return _shortId(userId);
  }

  @override
  Widget build(BuildContext context) {
    final event = _parseEvent(message.body);

    String text = 'system message';
    Color borderColor = AppColors.line;
    Color textColor = AppColors.ink3;

    if (event != null) {
      final type = event['type'] as String? ?? '';
      switch (type) {
        case 'member_joined':
        case 'joined':
          {
            final uid =
                (event['user_id'] as String?) ?? (event['by_user_id'] as String?);
            text = '${_name(uid)} joined the group';
            break;
          }
        case 'member_left':
        case 'left':
          {
            final uid =
                (event['user_id'] as String?) ?? (event['by_user_id'] as String?);
            text = '${_name(uid)} left';
            break;
          }
        case 'member_added':
          {
            final by = event['by_user_id'] as String?;
            final uid = event['user_id'] as String?;
            text = '${_name(by)} added ${_name(uid)}';
            break;
          }
        case 'member_removed':
          {
            final by = event['by_user_id'] as String?;
            final uid = event['user_id'] as String?;
            text = '${_name(by)} removed ${_name(uid)}';
            break;
          }
        case 'call_ended':
          {
            final rawDur = event['duration_seconds'];
            final secs = rawDur is int
                ? rawDur
                : (rawDur is num
                    ? rawDur.toInt()
                    : int.tryParse(rawDur?.toString() ?? '') ?? 0);
            final kind = (event['call_type'] as String?) ??
                (event['kind'] as String?) ??
                'audio';
            final label = kind == 'video' ? 'Video call' : 'Call';
            text = secs > 0
                ? '$label - ${_fmtDuration(secs)}'
                : '$label ended';
            break;
          }
        case 'call_missed':
          {
            final kind = (event['call_type'] as String?) ??
                (event['kind'] as String?);
            text = kind == 'video' ? 'Missed video call' : 'Missed call';
            borderColor = AppColors.err.withValues(alpha: 0.4);
            textColor = AppColors.err;
            break;
          }
        case 'voice_chat_started':
          text = 'Voice chat started';
          break;
        case 'voice_chat_ended':
          text = 'Voice chat ended';
          break;
        case 'title_changed':
          {
            final by = event['by_user_id'] as String?;
            final newTitle = event['new_title'] as String?;
            text = newTitle != null && newTitle.isNotEmpty
                ? '${_name(by)} changed group name to "$newTitle"'
                : '${_name(by)} changed the group name';
            break;
          }
        default:
          // Render the raw type with underscores swapped to spaces so a new
          // backend event still surfaces as something human-ish.
          text = type.isEmpty
              ? 'system message'
              : type.replaceAll('_', ' ');
          break;
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.raised.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: borderColor),
          ),
          child: Text(
            text,
            style: TextStyle(
              color: textColor,
              fontSize: 12,
              fontFamily: 'Consolas',
            ),
          ),
        ),
      ),
    );
  }
}
