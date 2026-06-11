// for sample run.

class Todo {
  final int id;
  final String name;

  Todo({
    required this.id,
    required this.name,
  });

  factory Todo.fromJson(Map<String, Object?> json) {
    return Todo(
      id: json['id'] as int,
      name: json['name'] as String,
    );
  }
}
