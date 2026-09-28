class EntryPhoto {
  const EntryPhoto({required this.id, required this.url, this.caption});

  final String id;
  final String url;
  final String? caption;

  factory EntryPhoto.fromJson(Map<String, dynamic> json) => EntryPhoto(
        id: json['id'] as String,
        url: json['url'] as String,
        caption: json['caption'] as String?,
      );
}
