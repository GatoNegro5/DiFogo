import 'audio_path.dart';
import 'gatomix_radio.dart';

/// Índice de la cabeza de la cola: la primera pista que no es la que suena.
/// 3.1.84: con la radio apagada esa cabeza es SIEMPRE la siguiente, en
/// cualquier tecnica de mezcla (DNA, Phrase 8 o Stealth, fija o AUTO).
int queueHeadIndex(List<String> paths, String? currentPath) {
  for (var i = 0; i < paths.length; i++) {
    if (currentPath == null || currentPath.isEmpty) return i;
    if (!sameAudioPath(paths[i], currentPath)) return i;
  }
  return -1;
}

/// Siguiente con la radio apagada: la cabeza de la cola anunciada.
/// 3.1.84 (salto fantasma Teddy Swims -> Shakira -> Daddy Yankee): ningun
/// modo de mezcla elige por cercania de BPM ni salta la cabeza; Stealth y
/// genre_mix_fx solo cambian curva, ventana y filtro del cruce hacia ella.
/// -1 si no hay cola.
int offAirNextIndex({
  required List<String> paths,
  required String? currentPath,
}) {
  if (paths.isEmpty) return -1;
  return queueHeadIndex(paths, currentPath);
}

/// Lo que muestra la barra «siguiente».
///
/// Radio encendida: la pista que la radio ya eligió. Radio apagada: la
/// cabeza de la cola en cualquier tecnica (3.1.84). Si todavía no hay
/// canción sonando, la cola muestra la primera como actual y la barra la
/// segunda.
String? liveDjFollowingLabel({
  required bool radioOn,
  required String? radioNextPath,
  required List<String> queuePaths,
  required String? currentPath,
}) {
  if (radioOn) {
    if (radioNextPath == null || radioNextPath.isEmpty) {
      return 'RADIO ▸ eligiendo…';
    }
    return 'RADIO ▸ ${_base(radioNextPath)}';
  }
  if (queuePaths.isEmpty) return null;
  if (currentPath == null || currentPath.isEmpty) {
    if (queuePaths.length < 2) return null;
    return _base(queuePaths[1]);
  }
  final int i = queueHeadIndex(queuePaths, currentPath);
  if (i < 0 || i >= queuePaths.length) return null;
  return _base(queuePaths[i]);
}

/// Barra «siguiente»: la misma pista que entra al deck (3.1.84: cabeza de
/// la cola en cualquier tecnica; sin lectura de BPM).
class LiveDjNextLabel {
  String? text({
    required bool radioOn,
    required String? radioNextPath,
    required List<String> queuePaths,
    required String? currentPath,
  }) => liveDjFollowingLabel(
    radioOn: radioOn,
    radioNextPath: radioNextPath,
    queuePaths: queuePaths,
    currentPath: currentPath,
  );
}

/// Panel derecho. Radio encendida: la lista de la opción, ya en memoria.
/// Radio apagada: la cola de Live DJ, intacta.
List<String> liveDjSidePaths({
  required bool radioOn,
  required List<String> queuePaths,
  required List<String> radioUpcoming,
}) {
  if (radioOn) return radioUpcoming;
  return queuePaths;
}

/// Siguientes de la radio desde la posición del plan (la que dice la barra).
/// Con plan válido: SIEMPRE el plan entero desde su posición hasta el final;
/// [ahead] no lo recorta. No incluye lo ya consumido. Sin plan se usa
/// [ahead] (la próxima ya precalculada) o [nextPath].
List<String> radioUpcomingPaths({
  RadioPlan? plan,
  String? nextPath,
  List<String> ahead = const <String>[],
}) {
  if (plan != null && plan.order.isNotEmpty && !plan.finished) {
    final int start = plan.position.clamp(0, plan.order.length);
    if (start < plan.order.length) {
      return List<String>.from(plan.order.sublist(start));
    }
  }
  if (ahead.isNotEmpty) return List<String>.from(ahead);
  if (nextPath != null && nextPath.isNotEmpty) return <String>[nextPath];
  return const <String>[];
}

/// Un armado de radio que ya salió no puede cambiar la siguiente.
bool radioArmStillValid({
  required bool radioOn,
  required int epoch,
  required int armEpoch,
}) {
  return radioOn && epoch == armEpoch;
}

/// El pre-armado sigue valiendo al volver de un await solo si el deck
/// capturado sigue siendo el standby, el listener sigue en el deck activo,
/// la pista del tick no cambió y no hay cruce. Si la entrante es la que
/// ya suena, abrirla mezclaría la pista consigo misma.
bool armStillValid({
  required String? tickPath,
  required String? currentPath,
  required String? armPath,
  required bool isCrossfading,
  required bool sameActive,
  required bool sameDeck,
}) {
  if (isCrossfading || currentPath != tickPath || !sameActive || !sameDeck) {
    return false;
  }
  if (sameAudioPath(armPath, currentPath)) return false;
  return true;
}

/// Efecto de apagar la radio. No toca el deck: la canción que suena sigue
/// y la cola congelada vuelve a ser la visible. [nextPath] es la cabeza de
/// esa cola; si el tipo es Stealth el motor vuelve a elegir por BPM.
class RadioOffEffect {
  final bool touchDeck;
  final List<String> deckCommands;
  final bool radioOn;
  final List<String> queue;
  final String? playing;
  final String? nextPath;

  const RadioOffEffect({
    required this.touchDeck,
    required this.deckCommands,
    required this.radioOn,
    required this.queue,
    required this.playing,
    required this.nextPath,
  });
}

RadioOffEffect effectOfRadioOff({
  required List<String> queue,
  required List<String>? frozenQueue,
  required String? playing,
}) {
  final List<String> kept = frozenQueue ?? queue;
  final int i = queueHeadIndex(kept, playing);
  return RadioOffEffect(
    touchDeck: false,
    deckCommands: const <String>[],
    radioOn: false,
    queue: kept,
    playing: playing,
    nextPath: i < 0 ? null : kept[i],
  );
}

String _base(String path) => path.replaceAll('\\', '/').split('/').last;

/// Un pending de radio solo se puede usar o guardar si no es la pista que
/// suena ni la que acaba de sonar. Una tarea tardía no debe devolverla.
bool radioPendingUsable(String? pending, {String? playing, String? previous}) {
  if (pending == null || pending.isEmpty) return false;
  if (playing != null && sameAudioPath(pending, playing)) return false;
  if (previous != null && sameAudioPath(pending, previous)) return false;
  return true;
}
