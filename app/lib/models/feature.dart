/// The toggleable buttons on the remote's feature bar, in display order.
/// Used by Settings (the show/hide chips) and the remote screen (which cells to
/// render). Keys are persisted in [Settings.hiddenFeatures] — keep them stable.
class FeatureDef {
  final String key;
  final String label;
  const FeatureDef(this.key, this.label);
}

const List<FeatureDef> kFeatures = [
  FeatureDef('media', 'Media'),
  FeatureDef('keyboard', 'Keyboard'),
  FeatureDef('gamepad', 'Gamepad'),
  FeatureDef('apps', 'Apps'),
  FeatureDef('macros', 'Macros'),
  FeatureDef('present', 'Presentation'),
  FeatureDef('clipboard', 'Clipboard'),
  FeatureDef('files', 'Files'),
  FeatureDef('power', 'Power'),
];
