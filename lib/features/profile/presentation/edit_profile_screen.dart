import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';

import '../../../core/auth/app_user.dart';
import '../../../core/auth/session_controller.dart';
import '../../../core/media/audio_message_player.dart';
import '../../../core/media/media_permission_service.dart';
import '../../../core/media/media_utils.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../auth/data/signup_options.dart';
import '../data/profile_repository.dart';
import 'profile_screen.dart' show profileBaseProvider, profileProvider;

class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  static const List<String> _relationshipStatusOptions = <String>[
    'Married',
    'Single',
    'Divorced',
    'Searching',
    'Widowed',
  ];

  final _displayNameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _bioTextController = TextEditingController();
  final _dateOfBirthController = TextEditingController();
  final _picker = ImagePicker();
  final _audioRecorder = AudioRecorder();
  final _permissionService = MediaPermissionService();

  Timer? _usernameDebounce;
  Timer? _recordingTimer;

  String _initialUsername = '';
  String _nationalityCode = '';
  String _firstLanguage = '';
  String _learnLanguage = '';
  List<String> _meetLanguages = <String>[];
  String _relationshipStatus = '';
  bool _relationshipStatusVisible = false;
  String _dateOfBirth = '';
  String _gender = '';

  String? _pendingPhotoPath;
  bool _removePhoto = false;

  String? _pendingAudioPath;
  int _pendingAudioDuration = 0;
  bool _removeAudio = false;

  bool _saving = false;
  bool _checkingUsername = false;
  bool? _usernameAvailable;
  String _usernameMessage = '';

  bool _recording = false;
  int _recordingSeconds = 0;

  @override
  void initState() {
    super.initState();
    final user = ref.read(sessionControllerProvider).user;
    if (user != null) {
      _seedFromUser(user);
    }
    _usernameController.addListener(_scheduleUsernameCheck);
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _usernameController.removeListener(_scheduleUsernameCheck);
    _usernameController.dispose();
    _bioTextController.dispose();
    _dateOfBirthController.dispose();
    _usernameDebounce?.cancel();
    _recordingTimer?.cancel();
    _audioRecorder.dispose();
    final pendingAudioPath = _pendingAudioPath;
    if (pendingAudioPath != null) {
      unawaited(_deleteFileIfPresent(pendingAudioPath));
    }
    super.dispose();
  }

  AppUser? get _currentUser => ref.read(sessionControllerProvider).user;

  void _seedFromUser(AppUser user) {
    _displayNameController.text = user.displayName;
    _usernameController.text = user.username;
    _bioTextController.text = user.bioText;
    _initialUsername = user.username.trim().toLowerCase();
    _nationalityCode = _normalizeCountryCode(
      user.nationalityCode,
      fallbackLabel: user.nationalityName,
    );
    _firstLanguage = user.firstLanguage;
    _learnLanguage = user.learnLanguage;
    _meetLanguages = user.meetLanguages
        .where((value) => value.trim().isNotEmpty)
        .toSet()
        .toList();
    _relationshipStatus = user.relationshipStatus;
    _relationshipStatusVisible = user.relationshipStatusVisible;
    _dateOfBirth = user.dateOfBirth;
    _dateOfBirthController.text = _dateOfBirth;
    _gender = user.gender.trim().toLowerCase();
    _usernameAvailable = true;
    _usernameMessage = '';
  }

  String _normalizeCountryCode(String code, {String fallbackLabel = ''}) {
    final trimmedCode = code.trim().toUpperCase();
    if (trimmedCode.isNotEmpty &&
        countryOptions.any((item) => item['code'] == trimmedCode)) {
      return trimmedCode;
    }
    final trimmedLabel = fallbackLabel.trim();
    if (trimmedLabel.isEmpty) return '';
    final match = countryOptions.firstWhere(
      (item) =>
          item['label'] == trimmedLabel ||
          item['code'] == trimmedLabel.toUpperCase(),
      orElse: () => const <String, String>{},
    );
    return match['code'] ?? '';
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _deleteFileIfPresent(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  String _errorMessage(Object error) {
    return error.toString().replaceFirst('Exception: ', '').trim();
  }

  String _currentLocationLabel(AppUser user) {
    final parts = <String>[
      if (user.city.trim().isNotEmpty) user.city.trim(),
      if (user.country.trim().isNotEmpty) user.country.trim(),
    ];
    if (parts.isNotEmpty) {
      return parts.join(', ');
    }
    final code = user.countryCode.trim().toUpperCase();
    if (code.isEmpty) {
      return 'Location unavailable';
    }
    final match = countryOptions.firstWhere(
      (item) => item['code'] == code,
      orElse: () => const <String, String>{},
    );
    return match['label'] ?? code;
  }

  void _scheduleUsernameCheck() {
    _usernameDebounce?.cancel();
    final current = _usernameController.text.trim().toLowerCase();
    if (current.isEmpty) {
      setState(() {
        _usernameAvailable = false;
        _usernameMessage = 'Username is required.';
      });
      return;
    }
    if (current == _initialUsername) {
      setState(() {
        _usernameAvailable = true;
        _usernameMessage = '';
      });
      return;
    }
    _usernameDebounce = Timer(const Duration(milliseconds: 420), () {
      unawaited(_checkUsernameAvailability());
    });
  }

  Future<void> _checkUsernameAvailability() async {
    final username = _usernameController.text.trim().toLowerCase();
    if (username.isEmpty || username == _initialUsername) {
      return;
    }
    setState(() {
      _checkingUsername = true;
      _usernameMessage = '';
    });
    try {
      final result = await ref
          .read(profileRepositoryProvider)
          .checkUsernameAvailability(username);
      if (!mounted ||
          _usernameController.text.trim().toLowerCase() != username) {
        return;
      }
      setState(() {
        _usernameAvailable = result.available;
        _usernameMessage = result.available
            ? 'Username is available.'
            : (result.reason.isEmpty
                  ? 'That username is not available.'
                  : result.reason);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _usernameAvailable = null;
        _usernameMessage = _errorMessage(error);
      });
    } finally {
      if (mounted &&
          _usernameController.text.trim().toLowerCase() == username) {
        setState(() => _checkingUsername = false);
      }
    }
  }

  Future<void> _pickProfilePhoto(ImageSource source) async {
    final file = await _picker.pickImage(
      source: source,
      maxWidth: 1600,
      imageQuality: 88,
    );
    if (!mounted || file == null) return;
    setState(() {
      _pendingPhotoPath = file.path;
      _removePhoto = false;
    });
  }

  Future<void> _showPhotoOptions() async {
    final user = _currentUser;
    if (user == null) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Choose from library'),
                onTap: () => Navigator.of(context).pop('gallery'),
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Take photo'),
                onTap: () => Navigator.of(context).pop('camera'),
              ),
              if (_pendingPhotoPath != null ||
                  (!_removePhoto && user.profilePhotoUrl.trim().isNotEmpty))
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('Remove profile photo'),
                  onTap: () => Navigator.of(context).pop('remove'),
                ),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    if (action == 'gallery') {
      await _pickProfilePhoto(ImageSource.gallery);
      return;
    }
    if (action == 'camera') {
      await _pickProfilePhoto(ImageSource.camera);
      return;
    }
    setState(() {
      _pendingPhotoPath = null;
      _removePhoto = true;
    });
  }

  Future<void> _pickDateOfBirth() async {
    final now = DateTime.now();
    final initialDate = _dateOfBirth.isNotEmpty
        ? DateTime.tryParse(_dateOfBirth) ?? DateTime(now.year - 18)
        : DateTime(now.year - 18);
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(1900),
      lastDate: DateTime(now.year - 13, now.month, now.day),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _dateOfBirth = picked.toIso8601String().split('T').first;
      _dateOfBirthController.text = _dateOfBirth;
    });
  }

  Future<void> _showMeetLanguagesEditor() async {
    final unlimitedLanguages = _currentUser?.isProLike == true;
    final initialSelections = _meetLanguages
        .where((item) => item != _learnLanguage)
        .toSet();
    final next = Set<String>.from(initialSelections);
    final applied = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateSheet) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Open to practice'),
                      subtitle: Text(
                        _learnLanguage.isEmpty
                            ? 'Pick your learning language first.'
                            : unlimitedLanguages
                            ? 'Your learning language ($_learnLanguage) is always included. Add as many practice languages as you want.'
                            : 'Your learning language ($_learnLanguage) is always included. Add up to 2 more.',
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        children: [
                          for (final language in languageOptions)
                            CheckboxListTile(
                              value: next.contains(language),
                              enabled:
                                  language != _learnLanguage &&
                                  (unlimitedLanguages ||
                                      next.contains(language) ||
                                      next.length < 2),
                              title: Text(language),
                              onChanged: language == _learnLanguage
                                  ? null
                                  : (selected) {
                                      setStateSheet(() {
                                        if (selected == true) {
                                          if (unlimitedLanguages ||
                                              next.length < 2) {
                                            next.add(language);
                                          }
                                        } else {
                                          next.remove(language);
                                        }
                                      });
                                    },
                            ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => Navigator.of(context).pop(next),
                        child: const Text('Done'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (!mounted || applied == null) return;
    setState(() {
      _meetLanguages = <String>[
        if (_learnLanguage.isNotEmpty) _learnLanguage,
        ...applied,
      ];
    });
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      try {
        final path = await _audioRecorder.stop();
        _recordingTimer?.cancel();
        if (path == null || path.isEmpty) {
          setState(() {
            _recording = false;
            _recordingSeconds = 0;
          });
          return;
        }
        setState(() {
          _recording = false;
          _pendingAudioPath = path;
          _pendingAudioDuration = _recordingSeconds.clamp(1, 60);
          _recordingSeconds = 0;
          _removeAudio = false;
        });
      } catch (_) {
        setState(() {
          _recording = false;
          _recordingSeconds = 0;
        });
        _showSnack('Could not finish that recording.');
      }
      return;
    }

    final hasPermission = await _audioRecorder.hasPermission();
    final allowed =
        hasPermission || await _permissionService.ensureMicrophone();
    final recorderAllowed = allowed && await _audioRecorder.hasPermission();
    if (!recorderAllowed) {
      _showSnack('Microphone permission is required to record a voice bio.');
      return;
    }

    try {
      final path =
          '${Directory.systemTemp.path}/profile_bio_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _audioRecorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000),
        path: path,
      );
      final started = await _audioRecorder.isRecording();
      if (!started) {
        _showSnack('Could not start recording right now.');
        return;
      }
      setState(() {
        _recording = true;
        _recordingSeconds = 0;
      });
      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (_recordingSeconds >= 60) {
          unawaited(_toggleRecording());
          return;
        }
        setState(() => _recordingSeconds += 1);
      });
    } catch (_) {
      _showSnack('Could not start recording right now.');
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_checkingUsername) {
      await _checkUsernameAvailability();
    }

    final user = _currentUser;
    if (user == null) return;
    final displayName = _displayNameController.text.trim();
    final username = _usernameController.text.trim().toLowerCase();
    final bioText = _bioTextController.text.trim();
    final nationalityCode = _nationalityCode.trim().toUpperCase();
    final meetLanguages = <String>[
      if (_learnLanguage.isNotEmpty) _learnLanguage,
      ..._meetLanguages.where((item) => item != _learnLanguage),
    ];

    if (displayName.isEmpty) {
      _showSnack('Display name is required.');
      return;
    }
    if (username.isEmpty) {
      _showSnack('Username is required.');
      return;
    }
    if (_usernameAvailable == false) {
      _showSnack(
        _usernameMessage.isEmpty
            ? 'Choose a different username.'
            : _usernameMessage,
      );
      return;
    }
    if (_firstLanguage.isEmpty || _learnLanguage.isEmpty) {
      _showSnack('Choose both first and learning languages.');
      return;
    }
    if (_nationalityCode.isEmpty) {
      _showSnack('Nationality is required.');
      return;
    }
    if (_dateOfBirth.isEmpty) {
      _showSnack('Date of birth is required.');
      return;
    }
    if (_gender != 'male' && _gender != 'female') {
      _showSnack('Choose a gender.');
      return;
    }
    if (_relationshipStatusVisible && _relationshipStatus.isEmpty) {
      _showSnack('Choose a relationship status before showing it.');
      return;
    }

    setState(() => _saving = true);
    try {
      await ref
          .read(profileRepositoryProvider)
          .updateProfile(
            displayName: displayName,
            username: username,
            bioText: bioText,
            nationalityCode: nationalityCode,
            firstLanguage: _firstLanguage,
            learnLanguage: _learnLanguage,
            meetLanguages: meetLanguages,
            relationshipStatus: _relationshipStatus,
            relationshipStatusVisible: _relationshipStatusVisible,
            dateOfBirth: _dateOfBirth,
            gender: _gender,
          );

      if (_pendingPhotoPath != null) {
        await ref
            .read(profileRepositoryProvider)
            .uploadProfilePhoto(imagePath: _pendingPhotoPath!);
      } else if (_removePhoto && user.profilePhotoUrl.trim().isNotEmpty) {
        await ref.read(profileRepositoryProvider).removeProfilePhoto();
      }

      if (_pendingAudioPath != null) {
        await ref
            .read(profileRepositoryProvider)
            .uploadProfileBioAudio(
              audioPath: _pendingAudioPath!,
              durationSeconds: _pendingAudioDuration.clamp(1, 60),
            );
      } else if (_removeAudio && user.bioAudioUrl.trim().isNotEmpty) {
        await ref.read(profileRepositoryProvider).removeProfileBioAudio();
      }

      await ref.read(sessionControllerProvider.notifier).refreshProfile();
      ref.invalidate(profileBaseProvider(null));
      ref.invalidate(profileProvider(null));
      ref.invalidate(profileBaseProvider(user.id));
      ref.invalidate(profileProvider(user.id));
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      _showSnack(_errorMessage(error));
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(sessionControllerProvider).user;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Edit profile')),
        body: const Center(child: Text('No active profile.')),
      );
    }

    final remoteVoiceBioVisible =
        !_removeAudio &&
        _pendingAudioPath == null &&
        user.bioAudioUrl.isNotEmpty;
    final localVoiceBioVisible =
        _pendingAudioPath != null && _pendingAudioDuration > 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit profile'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving...' : 'Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _EditSection(
            title: 'Profile photo',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: _buildPhotoPreview(user)),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _saving ? null : _showPhotoOptions,
                        icon: const Icon(Icons.camera_alt_outlined),
                        label: const Text('Change photo'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _EditSection(
            title: 'Profile',
            child: Column(
              children: [
                TextField(
                  controller: _displayNameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Display name'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _usernameController,
                  autocorrect: false,
                  textCapitalization: TextCapitalization.none,
                  decoration: InputDecoration(
                    labelText: 'Username',
                    prefixText: '@',
                    suffixIcon: _checkingUsername
                        ? const Padding(
                            padding: EdgeInsets.all(14),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : _usernameAvailable == null
                        ? null
                        : Icon(
                            _usernameAvailable == true
                                ? Icons.check_circle_outline
                                : Icons.error_outline,
                            color: _usernameAvailable == true
                                ? Colors.green
                                : scheme.error,
                          ),
                    helperText: _usernameMessage.isEmpty
                        ? null
                        : _usernameMessage,
                    helperStyle: TextStyle(
                      color: _usernameAvailable == false
                          ? scheme.error
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _bioTextController,
                  minLines: 3,
                  maxLines: 5,
                  maxLength: 150,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Bio',
                    alignLabelWithHint: true,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _EditSection(
            title: 'Voice bio',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_recording) ...[
                  Row(
                    children: [
                      const Icon(
                        Icons.fiber_manual_record_rounded,
                        color: Colors.redAccent,
                      ),
                      const SizedBox(width: 8),
                      Text('Recording ${_recordingSeconds}s / 60s'),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                if (localVoiceBioVisible) ...[
                  AudioMessagePlayer(
                    source: _pendingAudioPath!,
                    durationSeconds: _pendingAudioDuration,
                  ),
                  const SizedBox(height: 12),
                ] else if (remoteVoiceBioVisible) ...[
                  AudioMessagePlayer(
                    source: user.bioAudioUrl,
                    durationSeconds: user.bioAudioDuration,
                  ),
                  const SizedBox(height: 12),
                ],
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: _saving ? null : _toggleRecording,
                        icon: Icon(
                          _recording
                              ? Icons.stop_circle_outlined
                              : Icons.mic_none_rounded,
                        ),
                        label: Text(
                          _recording ? 'Stop recording' : 'Record voice bio',
                        ),
                      ),
                    ),
                  ],
                ),
                if (localVoiceBioVisible || remoteVoiceBioVisible)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: TextButton.icon(
                      onPressed: _saving
                          ? null
                          : () {
                              setState(() {
                                _pendingAudioPath = null;
                                _pendingAudioDuration = 0;
                                _removeAudio = true;
                              });
                            },
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Remove voice bio'),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _EditSection(
            title: 'About',
            child: Column(
              children: [
                TextField(
                  controller: _dateOfBirthController,
                  readOnly: true,
                  decoration: const InputDecoration(labelText: 'Date of birth'),
                  onTap: _saving ? null : _pickDateOfBirth,
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'male', label: Text('Male')),
                    ButtonSegment(value: 'female', label: Text('Female')),
                  ],
                  selected: _gender.isEmpty
                      ? const <String>{}
                      : <String>{_gender},
                  onSelectionChanged: _saving
                      ? null
                      : (selection) {
                          if (selection.isEmpty) return;
                          setState(() => _gender = selection.first);
                        },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _relationshipStatus.isEmpty
                      ? null
                      : _relationshipStatus,
                  items: _relationshipStatusOptions
                      .map(
                        (option) => DropdownMenuItem<String>(
                          value: option,
                          child: Text(option),
                        ),
                      )
                      .toList(),
                  onChanged: _saving
                      ? null
                      : (value) {
                          setState(() => _relationshipStatus = value ?? '');
                        },
                  decoration: const InputDecoration(
                    labelText: 'Relationship status',
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _relationshipStatusVisible,
                  onChanged: _saving
                      ? null
                      : (value) {
                          setState(() => _relationshipStatusVisible = value);
                        },
                  title: const Text('Show relationship status'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _EditSection(
            title: 'Languages',
            child: Column(
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _firstLanguage.isEmpty ? null : _firstLanguage,
                  items: languageOptions
                      .map(
                        (option) => DropdownMenuItem<String>(
                          value: option,
                          child: Text(option),
                        ),
                      )
                      .toList(),
                  onChanged: _saving
                      ? null
                      : (value) {
                          setState(() => _firstLanguage = value ?? '');
                        },
                  decoration: const InputDecoration(
                    labelText: 'First language',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _learnLanguage.isEmpty ? null : _learnLanguage,
                  items: languageOptions
                      .map(
                        (option) => DropdownMenuItem<String>(
                          value: option,
                          child: Text(option),
                        ),
                      )
                      .toList(),
                  onChanged: _saving
                      ? null
                      : (value) {
                          setState(() {
                            _learnLanguage = value ?? '';
                            _meetLanguages = <String>[
                              if (_learnLanguage.isNotEmpty) _learnLanguage,
                              ..._meetLanguages.where(
                                (item) => item != _learnLanguage,
                              ),
                            ];
                          });
                        },
                  decoration: const InputDecoration(
                    labelText: 'Language to learn',
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Open to practice'),
                  subtitle: Text(
                    _meetLanguages.isEmpty
                        ? 'Choose your practice languages'
                        : _meetLanguages.join(', '),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _saving ? null : _showMeetLanguagesEditor,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _EditSection(
            title: 'Location',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.my_location_outlined),
                  title: const Text('Current location'),
                  subtitle: Text(
                    _currentLocationLabel(user),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                Text(
                  'Location updates automatically from device and IP data. It cannot be edited here.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _nationalityCode.isEmpty
                      ? null
                      : _nationalityCode,
                  items: countryOptions
                      .map(
                        (option) => DropdownMenuItem<String>(
                          value: option['code'],
                          child: Text(option['label']!),
                        ),
                      )
                      .toList(),
                  onChanged: _saving
                      ? null
                      : (value) {
                          setState(() => _nationalityCode = value ?? '');
                        },
                  decoration: const InputDecoration(labelText: 'Nationality'),
                  menuMaxHeight: 360,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoPreview(AppUser user) {
    final pendingPhotoPath = _pendingPhotoPath;
    if (_removePhoto) {
      return AppAvatar(label: user.displayName, radius: 44);
    }
    if (pendingPhotoPath != null) {
      return CircleAvatar(
        radius: 44,
        backgroundImage: FileImage(File(pendingPhotoPath)),
      );
    }
    return AppAvatar(
      label: user.displayName,
      imageUrl: user.profilePhotoUrl.trim().isEmpty
          ? null
          : resolveMediaUrl(user.profilePhotoUrl),
      radius: 44,
    );
  }
}

class _EditSection extends StatelessWidget {
  const _EditSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}
