// Hand-written DTOs that mirror the proto3-JSON shapes the backend emits.
//
// We deliberately go DTO-by-hand rather than running protoc here — the user
// authorized MVP-first and the message shapes are small. When `protoc_plugin`
// is wired up later, these can be replaced by generated code without UI churn:
// every UI component reads the camelCase getters defined below.

class User {
  User({
    required this.id,
    required this.handle,
    required this.displayName,
    required this.avatarColor,
    this.lastSeenAt,
    this.bio = '',
  });

  final String id;
  final String handle;
  final String displayName;
  final String avatarColor;
  final DateTime? lastSeenAt;
  final String bio;

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: (j['id'] as String?) ?? '',
        handle: (j['handle'] as String?) ?? '',
        displayName: (j['displayName'] as String?) ?? '',
        avatarColor: (j['avatarColor'] as String?) ?? '#6F7180',
        lastSeenAt: _parseTs(j['lastSeenAt']),
        bio: (j['bio'] as String?) ?? '',
      );
}

class Presence {
  Presence({required this.userId, required this.online, this.lastSeenAt});
  final String userId;
  final bool online;
  final DateTime? lastSeenAt;

  factory Presence.fromJson(Map<String, dynamic> j) => Presence(
        userId: (j['userId'] as String?) ?? '',
        online: (j['online'] as bool?) ?? false,
        lastSeenAt: _parseTs(j['lastSeenAt']),
      );
}

class Message {
  Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.body,
    required this.createdAt,
    this.status = MessageStatus.sent,
    this.tempId,
  });

  final String id;
  final String conversationId;
  final String senderId;
  final String body;
  final DateTime createdAt;
  final MessageStatus status;
  // Local-only: tempId is set on optimistic stubs awaiting server ack.
  final String? tempId;

  Message copyWith({
    String? id,
    MessageStatus? status,
    DateTime? createdAt,
  }) =>
      Message(
        id: id ?? this.id,
        conversationId: conversationId,
        senderId: senderId,
        body: body,
        createdAt: createdAt ?? this.createdAt,
        status: status ?? this.status,
        tempId: tempId,
      );

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        id: (j['id'] as String?) ?? '',
        conversationId: (j['conversationId'] as String?) ?? '',
        senderId: (j['senderId'] as String?) ?? '',
        body: (j['body'] as String?) ?? '',
        createdAt: _parseTs(j['createdAt']) ?? DateTime.now(),
      );
}

enum MessageStatus { pending, sent, read, failed }

class Conversation {
  Conversation({
    required this.id,
    required this.type,
    required this.title,
    this.peer,
    this.lastMessageAt,
    this.preview,
    this.unreadCount = 0,
    this.memberCount = 0,
    this.avatarColor = '#6F7180',
    this.myRole = '',
  });

  final String id;
  final String type;
  final String title;
  final User? peer;
  final DateTime? lastMessageAt;
  final Message? preview;
  final int unreadCount;
  final int memberCount;
  final String avatarColor;
  final String myRole;

  String displayTitle() {
    if (peer != null) {
      final n = peer!.displayName;
      return n.isNotEmpty ? n : '@${peer!.handle}';
    }
    return title.isNotEmpty ? title : 'Conversation';
  }

  String avatarSeed() => peer?.displayName.isNotEmpty == true
      ? peer!.displayName
      : (title.isNotEmpty ? title : id);

  String avatarColorHex() {
    final c = peer?.avatarColor ?? avatarColor;
    return c.isNotEmpty ? c : '#6F7180';
  }

  Conversation copyWith({
    int? unreadCount,
    Message? preview,
    DateTime? lastMessageAt,
  }) =>
      Conversation(
        id: id,
        type: type,
        title: title,
        peer: peer,
        lastMessageAt: lastMessageAt ?? this.lastMessageAt,
        preview: preview ?? this.preview,
        unreadCount: unreadCount ?? this.unreadCount,
        memberCount: memberCount,
        avatarColor: avatarColor,
        myRole: myRole,
      );

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: (j['id'] as String?) ?? '',
        type: (j['type'] as String?) ?? 'dm',
        title: (j['title'] as String?) ?? '',
        peer: j['peer'] is Map<String, dynamic>
            ? User.fromJson(j['peer'] as Map<String, dynamic>)
            : null,
        lastMessageAt: _parseTs(j['lastMessageAt']),
        preview: j['preview'] is Map<String, dynamic>
            ? Message.fromJson(j['preview'] as Map<String, dynamic>)
            : null,
        unreadCount: _intOr(j['unreadCount'], 0),
        memberCount: _intOr(j['memberCount'], 0),
        avatarColor: (j['avatarColor'] as String?) ?? '#6F7180',
        myRole: (j['myRole'] as String?) ?? '',
      );
}

// Proto3 JSON encodes Timestamp as an RFC3339 string (e.g. "2026-05-26T04:07:20Z").
// Some clients also emit `{seconds, nanos}` objects; tolerate both.
DateTime? _parseTs(dynamic v) {
  if (v == null) return null;
  if (v is String) {
    if (v.isEmpty) return null;
    return DateTime.tryParse(v)?.toLocal();
  }
  if (v is Map<String, dynamic>) {
    final s = _intOr(v['seconds'], 0);
    final n = _intOr(v['nanos'], 0);
    if (s == 0 && n == 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(s * 1000 + n ~/ 1_000_000)
        .toLocal();
  }
  return null;
}

int _intOr(dynamic v, int fallback) {
  if (v is int) return v;
  if (v is String) return int.tryParse(v) ?? fallback;
  if (v is num) return v.toInt();
  return fallback;
}
