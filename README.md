# vision-ai-android

# Vision AI — Offline Camera Assistant

A privacy-first, open-source visual AI assistant built with Flutter and Google's LiteRT-LM.

Vision AI runs **SmolVLM2-500M directly on Android devices**, enabling users to analyze images and ask follow-up questions without relying on cloud AI inference.

## Features

- On-device image understanding
- Camera and gallery image input
- Streaming text generation
- Multi-turn visual question answering using recent conversation context
- Automatic model downloading on first launch
- Persistent local model storage
- Background inference using Dart isolates
- Material 3 Flutter interface

## Technology

- Flutter and Dart
- LiteRT-LM
- SmolVLM2-500M
- Android
- Hugging Face for model distribution

## Getting Started

### Requirements

- Flutter SDK
- Android SDK
- Compatible Android device or emulator
- Internet connection for the initial model download

### Installation

```bash
git clone https://github.com/YOUR_USERNAME/vision-ai-offline.git
cd vision-ai-offline
flutter pub get
flutter run
```

The application automatically downloads the model on first launch. Once downloaded, image inference runs locally.

## Download Android App

Prebuilt Android APKs will be available under GitHub Releases.

## Architecture

The Flutter interface communicates with a persistent Dart background isolate that manages the LiteRT-LM inference engine.

Generated text fragments stream from the inference worker back to the UI, allowing responses to appear progressively.

For follow-up questions, the application includes recent conversational context alongside the selected image.

## Privacy

Images and questions are processed locally during inference. An internet connection is required to download the AI model initially.

## Limitations

- Small models may occasionally generate inaccurate or repetitive responses.
- Conversation history is currently session-based.
- Performance varies by hardware.
- Physical Android device compatibility is still being validated.

## Model Attribution

SmolVLM2 is developed by Hugging Face. The LiteRT-LM-compatible model is provided through the litert-community Hugging Face repository.

The model and third-party dependencies retain their respective licenses.

## Contributing

Contributions, bug reports, and feature requests are welcome. Please open a GitHub issue before proposing significant architectural changes.

## License

The application source code is released under the Apache License 2.0 license. Third-party models and libraries are governed by their own licenses.
