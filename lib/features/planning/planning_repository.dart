import '../../core/api_client.dart';

/// Une vacation de l'agent, telle que renvoyée par /api/scheduling/me/shifts.
class MyShift {
  const MyShift({
    required this.assignmentId,
    required this.shiftId,
    required this.startsAt,
    required this.endsAt,
    required this.siteName,
    required this.postName,
    required this.role,
    required this.status,
  });

  final String assignmentId;
  final String shiftId;
  final DateTime startsAt;
  final DateTime endsAt;
  final String siteName;
  final String postName;

  /// titulaire | remplacant | renfort
  final String role;

  /// planned | confirmed
  final String status;

  bool get isNow {
    final now = DateTime.now();
    return !now.isBefore(startsAt) && now.isBefore(endsAt);
  }

  static MyShift fromJson(Map<String, dynamic> j) => MyShift(
        assignmentId: j['assignment_id'] as String,
        shiftId: j['shift_id'] as String,
        startsAt: DateTime.parse(j['starts_at'] as String).toLocal(),
        endsAt: DateTime.parse(j['ends_at'] as String).toLocal(),
        siteName: (j['site_name'] as String?) ?? '',
        postName: (j['post_name'] as String?) ?? '',
        role: (j['role'] as String?) ?? 'titulaire',
        status: (j['status'] as String?) ?? 'planned',
      );
}

class PlanningRepository {
  PlanningRepository({required this.api});

  final ApiClient api;

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Vacations de l'agent qui chevauchent aujourd'hui (locale du téléphone).
  Future<List<MyShift>> today() async {
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day);
    final to = from.add(const Duration(days: 1));
    final rows = await api.getList(
      '/api/scheduling/me/shifts?from=${_ymd(from)}&to=${_ymd(to)}',
    );
    return rows
        .whereType<Map<String, dynamic>>()
        .map(MyShift.fromJson)
        .toList()
      ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
  }
}
