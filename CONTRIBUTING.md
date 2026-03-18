# Contributing to Dockwright

Thanks for your interest in contributing!

## Getting Started

1. **Fork & clone** the repo
2. **Open** `Dockwright.xcodeproj` in Xcode 16+
3. **Build** with `Cmd+B` (or `xcodebuild -scheme Dockwright -configuration Debug build`)
4. **Run** the app, enter your Anthropic API key, and start chatting

## Requirements

- macOS 14.0+
- Xcode 16.0+
- Swift 6.0+
- An Anthropic API key (or Claude OAuth token)

## Project Structure

See `CLAUDE.md` for the full architecture overview. Key directories:

- `App/` — App entry point, AppState (central state)
- `Core/LLM/` — Multi-provider LLM streaming
- `Core/Tools/` — All 27 tool implementations
- `Core/Sensory/` — Screen capture, OCR, browser tab watching
- `Core/Voice/` — Speech-to-text, text-to-speech
- `UI/` — All SwiftUI views

## Concurrency Model

This project uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. All types are MainActor-isolated by default. Non-UI types must be explicitly marked `nonisolated` or `@unchecked Sendable`.

## How to Contribute

### Bug Reports
- Open an issue with steps to reproduce
- Include macOS version, Xcode version, and relevant logs
- Console logs: `log show --predicate 'subsystem == "com.Aatje.Dockwright"' --last 5m --info`

### Pull Requests
1. Create a feature branch from `main`
2. Keep changes focused — one feature or fix per PR
3. Build must pass: `xcodebuild -scheme Dockwright -configuration Debug build`
4. No stubs — every function must have real implementation
5. Match existing code style (no SwiftLint, just be consistent)

### Adding a New Tool
1. Create a new file in `Core/Tools/`
2. Conform to the `Tool` protocol (see `ToolRegistry.swift`)
3. Register it in `AppState.init()`
4. The LLM will automatically see it in its tool definitions

## Code Style

- No external dependencies for core functionality (Apple frameworks only)
- Use `os.Logger` for logging (subsystem: `com.Aatje.Dockwright`)
- Prefer `async/await` over callbacks
- Keep tool implementations self-contained

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
