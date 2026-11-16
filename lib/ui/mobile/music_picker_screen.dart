import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../../core/audio_path.dart';
import '../../core/lan_sync_plan.dart';
import '../../core/track_name_clean.dart';
import '../../djiphone/iphone_library.dart';
import '../widgets/hover_marquee_text.dart';

const Color _bg = Color(0xFF121212);
const Color _card = Color(0xFF1E1E1E);
const Color _text = Color(0xFFFFFFFF);
const Color _muted = Color(0xFFB3B3B3);

const TextStyle _titleStyle = TextStyle(color: _text, fontSize: 16);
const TextStyle _metaStyle = TextStyle(color: _muted, fontSize: 14);

// 3.1.50: paleta Pro DJ (crates grafito, activo y acentos neon).
const Color _crateBg = Color(0xFF0E1117);
const Color _activeBg = Color(0xFF1A222D);
const Color _neon = Color(0xFF00E676);
const Color _cyan = Color(0xFF00E5FF);
const TextStyle _countStyle = TextStyle(color: _muted, fontSize: 12);

String gatomixMusicRoot() {
  if (Platform.isIOS) return IphoneLibrary.musicRoot;
  if (Platform.isWindows) {
    final String? userProfile = Platform.environment['USERPROFILE'];
    return userProfile != null ? '$userProfile\\Music' : 'C:\\Music';
  }
  if (Platform.isAndroid) return '/storage/emulated/0/Music';
  final String? home = Platform.environment['HOME'];
  return home != null ? '$home/Music' : '/';
}

bool musicPickerShowsFile(String path) {
  final String lower = path.toLowerCase();
  final bool audio =
      lower.endsWith('.mp3') ||
      lower.endsWith('.m4a') ||
      lower.endsWith('.wav') ||
      lower.endsWith('.webm');
  if (!audio) return false;
  return !isKaraokeAudioPath(path);
}

bool musicPickerHasLrc(String path) {
  final String lrc = path.replaceFirst(RegExp(r'\.[^.]+$'), '.lrc');
  return File(lrc).existsSync();
}

String musicPickerTitle(String path) => formatTrackTitle(path);

List<String> queueWithPlayNext(
  List<String> queue,
  String? current,
  String path,
) {
  final List<String> next = <String>[
    for (final String item in queue)
      if (!sameAudioPath(item, path)) item,
  ];
  var at = next.length;
  if (current != null && !sameAudioPath(current, path)) {
    final int i = next.indexWhere(
      (String item) => sameAudioPath(item, current),
    );
    if (i >= 0) at = i + 1;
  }
  next.insert(at, path);
  return next;
}

List<File> musicPickerSongsUnder(Directory dir, {int depth = 0}) {
  if (depth > 8) return <File>[];
  final List<File> out = <File>[];
  List<FileSystemEntity> entities;
  try {
    entities = dir.listSync(followLinks: false);
  } catch (_) {
    return out;
  }
  for (final FileSystemEntity entity in entities) {
    if (entity is Directory) {
      final String name = entity.path.split(Platform.pathSeparator).last;
      if (name.startsWith('.') || name.startsWith(r'$')) continue;
      out.addAll(musicPickerSongsUnder(entity, depth: depth + 1));
    } else if (entity is File && musicPickerShowsFile(entity.path)) {
      out.add(entity);
    }
  }
  out.sort(
    (File a, File b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()),
  );
  return out;
}

/// Filtra canciones (lista recursiva) por texto en la ruta relativa a [base].
List<File> musicPickerFilterSongs(List<File> all, String base, String query) {
  final String q = query.trim().toLowerCase();
  if (q.isEmpty) return List<File>.of(all);
  return all.where((File f) {
    String rel = f.path;
    if (rel.startsWith(base)) rel = rel.substring(base.length);
    return rel.toLowerCase().contains(q);
  }).toList();
}

/// Lista recursiva fuera del hilo de UI.
Future<List<File>> musicPickerSongsUnderAsync(String dirPath) async {
  final List<String> paths = await Isolate.run(
    () => musicPickerSongsUnder(
      Directory(dirPath),
    ).map((File f) => f.path).toList(),
  );
  return paths.map((String p) => File(p)).toList();
}

String _pickerName(String path) => path.split(Platform.pathSeparator).last;

bool _pickerHidden(String path) {
  final String name = _pickerName(path);
  return name.startsWith('.') || name.startsWith(r'$');
}

int _pickerCompare(String a, String b) =>
    a.toLowerCase().compareTo(b.toLowerCase());

/// 3.1.24: carpeta leida fuera del hilo de UI (subcarpetas, canciones
/// directas, portada y .lrc de cada cancion).
class MusicPickerListing {
  final bool readable;
  final List<String> folders;
  final List<String> songs;
  final Map<String, String?> covers;
  final Set<String> lrc;

  const MusicPickerListing({
    required this.readable,
    required this.folders,
    required this.songs,
    required this.covers,
    required this.lrc,
  });
}

/// 3.1.24: canciones recursivas de una carpeta y de cada subcarpeta.
class MusicPickerDeepScan {
  final List<String> all;
  final Map<String, List<String>> byFolder;
  final Map<String, String?> covers;
  final Set<String> lrc;

  const MusicPickerDeepScan({
    required this.all,
    required this.byFolder,
    required this.covers,
    required this.lrc,
  });
}

/// Portada y .lrc a partir del listado ya leido: 0 llamadas extra a disco.
/// Windows y macOS no distinguen mayusculas, igual que el `existsSync` de
/// antes.
void _pickerSidecars(
  List<FileSystemEntity> entities,
  Map<String, String?> covers,
  Set<String> lrc,
) {
  final bool fold = Platform.isWindows || Platform.isMacOS;
  final Map<String, String> files = <String, String>{};
  for (final FileSystemEntity entity in entities) {
    if (entity is File) {
      files[fold ? entity.path.toLowerCase() : entity.path] = entity.path;
    }
  }
  String? find(String path) => files[fold ? path.toLowerCase() : path];
  for (final FileSystemEntity entity in entities) {
    if (entity is! File || !musicPickerShowsFile(entity.path)) continue;
    final String stem = entity.path.replaceFirst(RegExp(r'\.[^.]+$'), '');
    String? cover;
    for (final String ext in <String>['.jpg', '.jpeg', '.png', '.webp']) {
      cover = find('$stem$ext');
      if (cover != null) break;
    }
    covers[entity.path] = cover;
    if (find('$stem.lrc') != null) lrc.add(entity.path);
  }
}

MusicPickerListing musicPickerReadFolder(String dirPath) {
  final Directory dir = Directory(dirPath);
  if (!dir.existsSync()) {
    return const MusicPickerListing(
      readable: false,
      folders: <String>[],
      songs: <String>[],
      covers: <String, String?>{},
      lrc: <String>{},
    );
  }
  List<FileSystemEntity> entities;
  try {
    entities = dir.listSync(followLinks: false);
  } catch (_) {
    entities = <FileSystemEntity>[];
  }
  entities.sort(
    (FileSystemEntity a, FileSystemEntity b) => _pickerCompare(a.path, b.path),
  );
  final List<String> folders = <String>[];
  final List<String> songs = <String>[];
  for (final FileSystemEntity entity in entities) {
    if (_pickerHidden(entity.path)) continue;
    if (entity is Directory) {
      folders.add(entity.path);
    } else if (entity is File && musicPickerShowsFile(entity.path)) {
      songs.add(entity.path);
    }
  }
  final Map<String, String?> covers = <String, String?>{};
  final Set<String> lrc = <String>{};
  _pickerSidecars(entities, covers, lrc);
  return MusicPickerListing(
    readable: true,
    folders: folders,
    songs: songs,
    covers: covers,
    lrc: lrc,
  );
}

void _pickerWalk(
  Directory dir,
  int depth,
  List<String> out,
  Map<String, String?> covers,
  Set<String> lrc,
) {
  if (depth > 8) return;
  List<FileSystemEntity> entities;
  try {
    entities = dir.listSync(followLinks: false);
  } catch (_) {
    return;
  }
  _pickerSidecars(entities, covers, lrc);
  for (final FileSystemEntity entity in entities) {
    if (entity is Directory) {
      if (_pickerHidden(entity.path)) continue;
      _pickerWalk(entity, depth + 1, out, covers, lrc);
    } else if (entity is File && musicPickerShowsFile(entity.path)) {
      out.add(entity.path);
    }
  }
}

/// Mismo recorrido que [musicPickerSongsUnder] (8 niveles por subcarpeta).
MusicPickerDeepScan musicPickerDeepScan(String dirPath) {
  final Map<String, String?> covers = <String, String?>{};
  final Set<String> lrc = <String>{};
  final Map<String, List<String>> byFolder = <String, List<String>>{};
  final List<String> all = <String>[];
  List<FileSystemEntity> entities;
  try {
    entities = Directory(dirPath).listSync(followLinks: false);
  } catch (_) {
    entities = <FileSystemEntity>[];
  }
  _pickerSidecars(entities, covers, lrc);
  for (final FileSystemEntity entity in entities) {
    if (entity is Directory) {
      if (_pickerHidden(entity.path)) continue;
      final List<String> songs = <String>[];
      _pickerWalk(entity, 0, songs, covers, lrc);
      songs.sort(_pickerCompare);
      byFolder[entity.path] = songs;
      all.addAll(songs);
    } else if (entity is File && musicPickerShowsFile(entity.path)) {
      all.add(entity.path);
    }
  }
  all.sort(_pickerCompare);
  return MusicPickerDeepScan(
    all: all,
    byFolder: byFolder,
    covers: covers,
    lrc: lrc,
  );
}

Future<MusicPickerListing> musicPickerReadFolderAsync(String dirPath) =>
    Isolate.run(() => musicPickerReadFolder(dirPath));

Future<MusicPickerDeepScan> musicPickerDeepScanAsync(String dirPath) =>
    Isolate.run(() => musicPickerDeepScan(dirPath));

File? musicPickerCover(File audio) {
  final String stem = audio.path.replaceFirst(RegExp(r'\.[^.]+$'), '');
  for (final String ext in <String>['.jpg', '.jpeg', '.png', '.webp']) {
    final File image = File('$stem$ext');
    if (image.existsSync()) return image;
  }
  return null;
}

/// 3.1.38: carpetas tecnicas del selector (fuera del total de "Musica").
/// Mismo conjunto que DESTINO de LAN Sync: Descargas, DjPlaylists y LAB.
bool musicPickerTechFolder(String path) =>
    lanHiddenDestFolders.contains(_pickerName(path).toLowerCase());

String _pickerParent(String path) {
  final int cut = path.lastIndexOf(Platform.pathSeparator);
  return cut <= 0 ? path : path.substring(0, cut);
}

/// 3.1.38: crate de primer nivel bajo [root] que contiene [path]; null si
/// [path] es la raiz o esta fuera.
String? musicPickerTopCrate(String root, String path, String sep) {
  if (path == root || !path.startsWith('$root$sep')) return null;
  final String rel = path.substring(root.length + sep.length);
  final int cut = rel.indexOf(sep);
  return '$root$sep${cut < 0 ? rel : rel.substring(0, cut)}';
}

/// 3.1.38: orden de la cinta: "Musica" (raiz), ReGenial, generos con pistas,
/// Descargas y al final las tecnicas (DjPlaylists, LAB); sin carpetas con 0
/// canciones. Las subcarpetas de [parent] van justo despues de el (con
/// conteo aun sin llegar se muestran; con 0 se ocultan).
List<String> musicPickerCrates({
  required String root,
  required List<String> top,
  required Map<String, int> counts,
  String? parent,
  List<String> subs = const <String>[],
}) {
  int rank(String p) {
    final String n = _pickerName(p).toLowerCase();
    if (n == 'regenial') return 0;
    if (n == 'descargas') return 2;
    if (musicPickerTechFolder(p)) return 3;
    return 1;
  }

  final List<String> level =
      top.where((String p) => (counts[p] ?? 0) > 0).toList()
        ..sort((String a, String b) {
          final int r = rank(a).compareTo(rank(b));
          return r != 0 ? r : _pickerCompare(a, b);
        });
  final List<String> out = <String>[root];
  for (final String p in level) {
    out.add(p);
    if (p == parent) {
      out.addAll(subs.where((String s) => (counts[s] ?? 1) > 0));
    }
  }
  return out;
}

/// 3.1.38: biblioteca limpia para el crate "Musica" (total y Mezclar todo):
/// sin pistas dentro de Descargas, DjPlaylists ni LAB.
List<File> musicPickerCleanLibrary(List<File> all, String root) {
  final String sep = Platform.pathSeparator;
  return all.where((File f) {
    final String? top = musicPickerTopCrate(root, f.path, sep);
    return top == null || f.path == top || !musicPickerTechFolder(top);
  }).toList();
}

/// 3.1.25: ancho del panel lateral (45 % de la pantalla, 340..420 dp).
double musicPickerPanelWidth(double screenWidth) =>
    (screenWidth * 0.45).clamp(340.0, 420.0).toDouble();

/// 3.1.25: explorador movil como panel derecho de alto completo. La barrera
/// translucida deja ver el deck y tocar fuera cierra. El panel trae su propio
/// ScaffoldMessenger para que "Deshacer" salga dentro del panel.
Future<void> showMusicPickerPanel(
  BuildContext context, {
  required Widget Function(VoidCallback onClose) child,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Cerrar',
    barrierColor: const Color(0x66000000),
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (BuildContext ctx, Animation<double> _, Animation<double> _) {
      final double width = musicPickerPanelWidth(MediaQuery.sizeOf(ctx).width);
      return Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: width,
          height: double.infinity,
          child: ScaffoldMessenger(
            child: Scaffold(
              backgroundColor: _bg,
              body: SafeArea(
                left: false,
                child: child(() => Navigator.of(ctx).pop()),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder:
        (
          BuildContext ctx,
          Animation<double> animation,
          Animation<double> _,
          Widget panel,
        ) {
          return SlideTransition(
            position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
                .animate(
                  CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                  ),
                ),
            child: panel,
          );
        },
  );
}

/// 3.1.25: "+ Agregar canciones" de 48 px para la fila de cabecera de
/// Automix y Live DJ (sin densidad compacta).
class MusicPickerAddButton extends StatelessWidget {
  final VoidCallback onPressed;

  const MusicPickerAddButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(48, 48),
        tapTargetSize: MaterialTapTargetSize.padded,
      ),
      child: const Text(
        '+ Agregar canciones',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class MusicPickerScreen extends StatefulWidget {
  final String rootPath;
  final List<String> queuePaths;
  final ScrollController? scrollController;
  final void Function(File file) onEnqueue;
  final void Function(File file) onUndo;
  final void Function(File file) onPlayNext;
  final Future<void> Function(List<File> files) onMixFolder;
  final VoidCallback? onClose;

  const MusicPickerScreen({
    super.key,
    required this.rootPath,
    required this.queuePaths,
    required this.onEnqueue,
    required this.onUndo,
    required this.onPlayNext,
    required this.onMixFolder,
    this.scrollController,
    this.onClose,
  });

  @override
  State<MusicPickerScreen> createState() => _MusicPickerScreenState();
}

class _PickerFolder {
  final bool readable;
  final List<String> folders;
  final List<File> songs;

  const _PickerFolder(this.readable, this.folders, this.songs);
}

class _MusicPickerScreenState extends State<MusicPickerScreen> {
  // 3.1.38: carpeta (crate) activa; la raiz es el crate "Musica".
  late String _current;
  final TextEditingController _search = TextEditingController();

  // 3.1.24: todo lo que lee disco corre en Isolate y build() solo lee estos
  // mapas en memoria. _loadEpoch descarta respuestas de una carpeta que ya se
  // dejo (o del widget cerrado).
  int _loadEpoch = 0;
  final Map<String, _PickerFolder> _folders = <String, _PickerFolder>{};
  final Map<String, List<File>> _deep = <String, List<File>>{};
  final Set<String> _scanned = <String>{};
  final Map<String, int> _counts = <String, int>{};
  final Map<String, File?> _covers = <String, File?>{};
  final Set<String> _lrc = <String>{};
  final Set<String> _mixing = <String>{};
  // 3.1.50: arbol vertical plegado por defecto en la vista compacta.
  bool _treeOpen = false;

  @override
  void initState() {
    super.initState();
    _current = widget.rootPath;
    _load();
  }

  @override
  void dispose() {
    _loadEpoch++;
    _search.dispose();
    super.dispose();
  }

  void _absorb(Map<String, String?> covers, Set<String> lrc) {
    covers.forEach((String song, String? cover) {
      _covers[song] = cover == null ? null : File(cover);
    });
    _lrc.addAll(lrc);
  }

  /// 3.1.38: crate de primer nivel que contiene a [_current] (null en raiz).
  String? get _parentCrate =>
      musicPickerTopCrate(widget.rootPath, _current, Platform.pathSeparator);

  /// 3.1.38: carga el crate activo y, si es una subcarpeta, tambien su crate
  /// padre (para las subcarpetas de la cinta), con el mismo epoch.
  void _load() {
    final int epoch = ++_loadEpoch;
    final String? parent = _parentCrate;
    for (final String path in <String>{widget.rootPath, ?parent, _current}) {
      _loadPath(path, epoch);
    }
  }

  void _loadPath(String path, int epoch) {
    if (!_folders.containsKey(path)) {
      musicPickerReadFolderAsync(path).then(
        (MusicPickerListing data) {
          if (!mounted || epoch != _loadEpoch) return;
          setState(() {
            _folders[path] = _PickerFolder(data.readable, data.folders, <File>[
              for (final String song in data.songs) File(song),
            ]);
            _absorb(data.covers, data.lrc);
          });
        },
        onError: (Object _) {
          if (!mounted || epoch != _loadEpoch) return;
          setState(() {
            _folders[path] = const _PickerFolder(false, <String>[], <File>[]);
          });
        },
      );
    }
    if (!_scanned.contains(path)) {
      musicPickerDeepScanAsync(path).then(
        (MusicPickerDeepScan scan) {
          if (!mounted || epoch != _loadEpoch) return;
          setState(() {
            _scanned.add(path);
            _deep[path] = <File>[
              for (final String song in scan.all) File(song),
            ];
            scan.byFolder.forEach((String folder, List<String> songs) {
              _deep[folder] = <File>[
                for (final String song in songs) File(song),
              ];
              _counts[folder] = songs.length;
            });
            _absorb(scan.covers, scan.lrc);
          });
        },
        onError: (Object _) {
          if (!mounted || epoch != _loadEpoch) return;
          setState(() {
            _scanned.add(path);
            _deep[path] = <File>[];
          });
        },
      );
    }
  }

  void _enqueue(File file) {
    widget.onEnqueue(file);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        persist: false,
        duration: const Duration(milliseconds: 1500),
        content: const Text(
          'Agregada a la cola',
          style: TextStyle(fontSize: 14),
        ),
        action: SnackBarAction(
          label: 'Deshacer',
          onPressed: () => widget.onUndo(file),
        ),
      ),
    );
  }

  /// 3.1.38: pistas de un crate; en "Musica" la biblioteca limpia (sin
  /// Descargas, DjPlaylists ni LAB). null mientras el escaneo no llega.
  List<File>? _crateSongs(String path) {
    final List<File>? deep = _deep[path];
    if (deep == null) return null;
    if (path != widget.rootPath) return deep;
    return musicPickerCleanLibrary(deep, widget.rootPath);
  }

  /// Usa la lista ya leida; si aun no llego, la lee en Isolate. Un segundo
  /// toque mientras resuelve se ignora (sin doble toque).
  Future<void> _mix(String path) async {
    if (_mixing.contains(path)) return;
    setState(() => _mixing.add(path));
    try {
      List<File>? files = _crateSongs(path);
      if (files == null) {
        final List<File> read = await musicPickerSongsUnderAsync(path);
        files = path == widget.rootPath
            ? musicPickerCleanLibrary(read, widget.rootPath)
            : read;
      }
      if (!mounted) return;
      await widget.onMixFolder(List<File>.of(files));
    } finally {
      if (mounted) setState(() => _mixing.remove(path));
    }
  }

  void _selectCrate(String path) {
    if (path == _current) return;
    setState(() => _current = path);
    _load();
  }

  int? _crateCount(String path) =>
      path == widget.rootPath ? _crateSongs(path)?.length : _counts[path];

  @override
  Widget build(BuildContext context) {
    final String root = widget.rootPath;
    final String query = _search.text.trim().toLowerCase();
    final _PickerFolder? rootFolder = _folders[root];
    final bool readable = rootFolder?.readable ?? true;
    final String? parent = _parentCrate;
    final List<String> crates = musicPickerCrates(
      root: root,
      top: rootFolder?.folders ?? const <String>[],
      counts: _counts,
      parent: parent,
      subs: parent == null
          ? const <String>[]
          : (_folders[parent]?.folders ?? const <String>[]),
    );
    final List<File>? crateSongs = _crateSongs(_current);
    final bool pending = rootFolder == null || crateSongs == null;
    final List<File> songs = crateSongs == null
        ? const <File>[]
        : musicPickerFilterSongs(crateSongs, _current, query);
    final String here = _current == root
        ? 'M\u00fasica'
        : _pickerName(_current);

    final List<Widget> songSlivers = <Widget>[
      if (!readable)
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text(
              'No se pudo leer la carpeta de m\u00fasica',
              style: _metaStyle,
            ),
          ),
        )
      else if (pending)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator(color: _muted)),
          ),
        )
      else
        SliverList(
          delegate: SliverChildBuilderDelegate((
            BuildContext context,
            int index,
          ) {
            final File song = songs[index];
            return _SongRow(
              file: song,
              cover: _covers[song.path],
              lrc: _lrc.contains(song.path),
              onTap: () => _enqueue(song),
              onPlayNext: () => widget.onPlayNext(song),
            );
          }, childCount: songs.length),
        ),
      // Espacio para que el aviso "Agregada a la cola" no tape la ultima
      // cancion.
      const SliverToBoxAdapter(child: SizedBox(height: 72)),
    ];

    return Scaffold(
      backgroundColor: _bg,
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          // 3.1.50: Split Crate Browser (34 % arbol / 66 % pistas) desde
          // 560 dp; el panel movil (340..420 dp) usa la vista compacta.
          if (box.maxWidth >= 560) {
            final double left = (box.maxWidth * 0.34).floorToDouble();
            return Row(
              children: <Widget>[
                SizedBox(
                  width: left,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      color: _crateBg,
                      border: Border(right: BorderSide(color: Colors.white10)),
                    ),
                    child: Column(
                      children: <Widget>[
                        _breadcrumb(parent),
                        Expanded(
                          child: ListView.builder(
                            key: const ValueKey<String>('crate-strip'),
                            padding: const EdgeInsets.only(bottom: 8),
                            itemCount: crates.length,
                            itemBuilder: (BuildContext context, int index) =>
                                _crateRow(crates[index], parent),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        child: SizedBox(
                          height: 48,
                          child: Row(
                            children: <Widget>[
                              const SizedBox(width: 6),
                              Expanded(flex: 4, child: _crateTitle(here)),
                              const SizedBox(width: 8),
                              Expanded(flex: 5, child: _searchField(here)),
                              const SizedBox(width: 8),
                              _mixPill(),
                              if (widget.onClose != null) _closeButton(),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: CustomScrollView(
                          controller: widget.scrollController,
                          slivers: songSlivers,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }
          // 3.1.50: vista compacta (panel movil 340..420 dp): carril de
          // crates de 52 px (garantia de 4.5 filas a 360 dp de alto) y arbol
          // vertical plegable con el boton de la izquierda.
          final bool tree = _treeOpen && query.isEmpty;
          final int? n = _crateCount(_current);
          return Column(
            children: <Widget>[
              // 3.1.38: barra de 48 px (buscador y Cerrar).
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: SizedBox(
                  height: 48,
                  child: Row(
                    children: <Widget>[
                      Expanded(child: _searchField(here)),
                      if (widget.onClose != null) _closeButton(),
                    ],
                  ),
                ),
              ),
              ColoredBox(
                color: _crateBg,
                child: SizedBox(
                  height: 52,
                  child: Row(
                    children: <Widget>[
                      IconButton(
                        onPressed: () => setState(() => _treeOpen = !_treeOpen),
                        style: IconButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        icon: Icon(
                          _treeOpen ? Icons.expand_less : Icons.account_tree,
                          color: _treeOpen ? _neon : _muted,
                          size: 20,
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          key: const ValueKey<String>('crate-strip'),
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.only(right: 6),
                          itemCount: crates.length,
                          itemBuilder: (BuildContext context, int index) =>
                              _crateChip(crates[index], parent),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: CustomScrollView(
                  controller: widget.scrollController,
                  slivers: <Widget>[
                    if (tree)
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (BuildContext context, int index) =>
                              _crateRow(crates[index], parent),
                          childCount: crates.length,
                        ),
                      ),
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _PinnedBar(
                        height: 48,
                        child: ColoredBox(
                          color: _bg,
                          child: Row(
                            children: <Widget>[
                              Expanded(child: _breadcrumb(parent)),
                              if (n != null)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: Text('$n pistas', style: _countStyle),
                                ),
                              _mixPill(),
                              const SizedBox(width: 4),
                            ],
                          ),
                        ),
                      ),
                    ),
                    ...songSlivers,
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _searchField(String here) {
    return TextField(
      controller: _search,
      style: _titleStyle,
      cursorColor: _neon,
      decoration: InputDecoration(
        hintText: 'Buscar en $here',
        hintStyle: _metaStyle.copyWith(overflow: TextOverflow.ellipsis),
        hintMaxLines: 1,
        prefixIcon: const Icon(Icons.search, color: _muted, size: 20),
        prefixIconConstraints: const BoxConstraints(
          minWidth: 36,
          minHeight: 36,
        ),
        filled: true,
        fillColor: _activeBg,
        border: const OutlineInputBorder(
          borderSide: BorderSide.none,
          borderRadius: BorderRadius.all(Radius.circular(10)),
        ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
      ),
      onChanged: (String _) => setState(() {}),
    );
  }

  Widget _closeButton() {
    return IconButton(
      tooltip: 'Cerrar',
      onPressed: widget.onClose,
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
      icon: const Icon(Icons.close, color: _text),
    );
  }

  /// 3.1.50: titulo del crate activo + contador (un solo Text, no repite el
  /// nombre del arbol ni el "N canciones" de su badge).
  Widget _crateTitle(String here) {
    final int? n = _crateCount(_current);
    return Text(
      n == null ? here : '$here  \u00b7  $n pistas',
      style: const TextStyle(
        color: _text,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// 3.1.50: "+ Mezclar todo" en pastilla de alto contraste (48 px; toma el
  /// toque aunque este resolviendo, sin doble toque).
  Widget _mixPill() {
    final bool mixing = _mixing.contains(_current);
    final String path = _current;
    return TextButton(
      style: TextButton.styleFrom(
        backgroundColor: mixing ? _activeBg : _neon,
        foregroundColor: mixing ? _muted : Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        minimumSize: const Size(48, 48),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
      onPressed: () => _mix(path),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.add, size: 18),
          SizedBox(width: 4),
          Text('Mezclar todo', maxLines: 1),
        ],
      ),
    );
  }

  /// 3.1.50: ruta interactiva (Musica > crate > subcarpeta); cada tramo
  /// salta a ese nivel en un toque.
  Widget _breadcrumb(String? parent) {
    final String root = widget.rootPath;
    final List<String> path = <String>[
      root,
      ?parent,
      if (_current != root && _current != parent) _current,
    ];
    return SizedBox(
      height: 36,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: <Widget>[
            for (final String p in path)
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _selectCrate(p),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 8,
                  ),
                  child: Text(
                    p == root
                        ? '\u{1F3B5} M\u00fasica'
                        : '\u203a  ${_pickerName(p)}',
                    style: TextStyle(
                      color: p == _current ? _cyan : _muted,
                      fontSize: 13,
                      fontWeight: p == _current
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                    maxLines: 1,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 3.1.50: crate del carril compacto: barra neon y fondo en el activo,
  /// marca de subcarpeta y badge con el numero de pistas.
  Widget _crateChip(String path, String? parent) {
    final bool active = path == _current;
    final bool isRoot = path == widget.rootPath;
    final bool isSub =
        !isRoot &&
        parent != null &&
        path != parent &&
        _pickerParent(path) == parent;
    final int? n = _crateCount(path);
    return Padding(
      padding: const EdgeInsets.only(left: 6, top: 2, bottom: 2),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Material(
          color: active ? _activeBg : Colors.white10,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _selectCrate(path),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(width: 3, color: active ? _neon : Colors.transparent),
                const SizedBox(width: 8),
                if (isSub)
                  const Padding(
                    padding: EdgeInsets.only(right: 2),
                    child: Text(
                      '\u251c',
                      style: TextStyle(
                        color: Colors.white24,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                Icon(
                  isRoot
                      ? Icons.library_music
                      : (isSub ? Icons.queue_music : Icons.folder),
                  color: active ? _neon : _muted,
                  size: 16,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        isRoot ? 'M\u00fasica' : _pickerName(path),
                        style: TextStyle(
                          color: active ? _text : _muted,
                          fontSize: 13,
                          fontWeight: active
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        n == null ? '...' : '$n canciones',
                        style: TextStyle(
                          color: active ? _neon : _muted,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 3.1.50: fila del arbol de crates: barra neon y fondo en el activo,
  /// subcarpetas con sangria de 14 px y guia, badge con el numero de pistas.
  Widget _crateRow(String path, String? parent) {
    final bool active = path == _current;
    final bool isRoot = path == widget.rootPath;
    final bool isSub =
        !isRoot &&
        parent != null &&
        path != parent &&
        _pickerParent(path) == parent;
    final bool open = !isRoot && !isSub && path == parent;
    final int? n = _crateCount(path);
    final double indent = isRoot ? 0 : (isSub ? 28 : 14);
    return Material(
      color: active ? _activeBg : _crateBg,
      child: InkWell(
        onTap: () => _selectCrate(path),
        child: SizedBox(
          height: 48,
          child: Row(
            children: <Widget>[
              Container(width: 3, color: active ? _neon : Colors.transparent),
              SizedBox(width: 8 + indent),
              if (isSub)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Text(
                    '\u251c\u2500',
                    style: TextStyle(
                      color: Colors.white24,
                      fontSize: 13,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              Icon(
                isRoot
                    ? Icons.library_music
                    : (isSub
                          ? Icons.queue_music
                          : (open ? Icons.folder_open : Icons.folder)),
                color: active ? _neon : _muted,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isRoot ? 'M\u00fasica' : _pickerName(path),
                  style: TextStyle(
                    color: active ? _text : _muted,
                    fontSize: 14,
                    fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: active ? const Color(0x2200E676) : Colors.white10,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  n == null ? '...' : '$n canciones',
                  style: TextStyle(
                    color: active ? _neon : _muted,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// 3.1.50: barra fija (Mezclar todo) dentro del scroll de la vista compacta.
class _PinnedBar extends SliverPersistentHeaderDelegate {
  final double height;
  final Widget child;

  const _PinnedBar({required this.height, required this.child});

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(BuildContext context, double shrink, bool overlaps) =>
      SizedBox.expand(child: child);

  @override
  bool shouldRebuild(covariant _PinnedBar old) =>
      old.height != height || old.child != child;
}

/// 3.1.50: partes de una fila: BPM del nombre, artista y titulo.
/// "Cantante (128) - Cancion" -> (128, Cantante, Cancion); sin " - " el
/// titulo va completo y artista queda vacio.
({int? bpm, String artist, String title}) musicPickerRowParts(
  String formatted,
) {
  String name = formatted.trim();
  int? bpm;
  final RegExpMatch? m = RegExp(r'\s\((\d{2,3})\)(?=\s-\s|$)').firstMatch(name);
  if (m != null) {
    bpm = int.tryParse(m.group(1)!);
    name = (name.substring(0, m.start) + name.substring(m.end)).trim();
  }
  final int sep = name.indexOf(' - ');
  if (sep <= 0) return (bpm: bpm, artist: '', title: name);
  return (
    bpm: bpm,
    artist: name.substring(0, sep).trim(),
    title: name.substring(sep + 3).trim(),
  );
}

/// 3.1.24: portada y .lrc llegan ya resueltos (sin disco en build).
/// 3.1.50: fila estilo Rekordbox / djay Pro: badge de BPM, artista en
/// negrita, titulo en white70 y boton "+" a la derecha.
class _SongRow extends StatelessWidget {
  final File file;
  final File? cover;
  final bool lrc;
  final VoidCallback onTap;
  final VoidCallback onPlayNext;

  const _SongRow({
    required this.file,
    required this.cover,
    required this.lrc,
    required this.onTap,
    required this.onPlayNext,
  });

  @override
  Widget build(BuildContext context) {
    final CleanTrackName meta = cleanTrackFileName(file.path);
    final parts = musicPickerRowParts(musicPickerTitle(file.path));
    final int? bpm =
        parts.bpm ?? ((meta.bpmHint ?? 0) > 0 ? meta.bpmHint!.round() : null);
    final String key = meta.camelot ?? '';
    final bool split = parts.artist.isNotEmpty;
    final String line1 = split ? parts.artist : parts.title;
    final String line2 = <String>[
      if (split) parts.title,
      if (key.isNotEmpty) key,
    ].join('  \u00b7  ');
    final File? image = cover;

    return Material(
      color: _bg,
      child: InkWell(
        onTap: onTap,
        onLongPress: onPlayNext,
        child: SizedBox(
          height: 56,
          child: Row(
            children: <Widget>[
              const SizedBox(width: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: image == null
                      ? const ColoredBox(
                          color: _card,
                          child: Icon(
                            Icons.music_note,
                            color: _muted,
                            size: 22,
                          ),
                        )
                      : Image.file(image, fit: BoxFit.cover),
                ),
              ),
              const SizedBox(width: 8),
              if (bpm != null)
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x1A00E5FF),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0x5500E5FF)),
                  ),
                  child: Text(
                    '$bpm',
                    style: const TextStyle(
                      color: _cyan,
                      fontSize: 12,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    HoverMarqueeText(
                      line1,
                      style: const TextStyle(
                        color: _text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (line2.isNotEmpty)
                      HoverMarqueeText(
                        line2,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                  ],
                ),
              ),
              if (lrc)
                const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Text('\u{1F3A4}', style: TextStyle(fontSize: 18)),
                ),
              IconButton(
                onPressed: onTap,
                style: IconButton.styleFrom(
                  minimumSize: const Size(44, 44),
                  backgroundColor: const Color(0x1400E676),
                ),
                icon: const Icon(Icons.add, color: _neon, size: 20),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}
