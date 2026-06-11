import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_models/shared_models.dart';

class TodoService {
  final SupabaseClient _client;

  TodoService(this._client);

  Stream<List<Todo>> getTodosStream() {
    return _client
        .from('todos')
        .stream(primaryKey: ['id'])
        .map((list) => list.map(Todo.fromJson).toList());
  }
}
