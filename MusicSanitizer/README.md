# Music Sanitizer

A native macOS app (Swift + SwiftUI) that cleans up your music library — fixing tags, 
standardising filenames, and organising folder structure.

## Features

### Tag Cleaning
- Detects and fills missing title, artist, album, year, genre, track number
- MusicBrainz lookup to fill gaps automatically (free, no API key needed)
- Strips/shrinks oversized embedded album artwork (configurable limit)
- Fetches missing cover art from the Cover Art Archive

### Filename & Folder Sanitisation
- Removes illegal characters (`/\:*?"<>|`)
- Applies a consistent naming pattern (e.g. `01 - Artist - Title.mp3`)
- Organises files into `Artist/Album` or `Artist/Year - Album` hierarchy
- Optional title-casing and underscore replacement

### Duplicate Detection
- Three methods: file hash, hash + duration, or duration + file size
- Groups duplicates visually for manual review

### Safety
- **Backup before modify** — originals are copied to a `_MusicSanitizer_Backup/` folder
- **Preview before apply** — diff sheet shows every proposed change before anything is touched
- **CSV/report export** — full log of what was changed

### Watch Folder Mode
- Monitors a folder using FSEvents (zero polling overhead)
- Auto-processes new files as soon as they're fully written
- Optionally auto-applies fixes and sends a macOS notification
- Configurable from the Settings → Watch Folder tab

## Requirements

- macOS 13.0 Ventura or later
- Xcode 15 or later
- **ffmpeg** — required for tag writing and artwork operations
  ```
  brew install ffmpeg
  ```
  The app will detect ffmpeg at `/usr/local/bin/ffmpeg` or `/opt/homebrew/bin/ffmpeg`,
  or you can bundle a static build inside the app's Resources folder.

## Building

1. Open `MusicSanitizer.xcodeproj` in Xcode
2. Set your Team in Signing & Capabilities
3. Update `PRODUCT_BUNDLE_IDENTIFIER` if needed
4. ⌘B to build, ⌘R to run

## Architecture

```
MusicSanitizer/
├── Models/
│   ├── AudioFile.swift        # AudioFile, AudioTags, FileIssue, AudioFormat
│   └── ScanSettings.swift     # All user-configurable settings, naming patterns
├── Services/
│   ├── TagService.swift       # AVFoundation tag reading; ffmpeg tag writing
│   ├── ScanService.swift      # Directory walk, issue detection, duplicate finder
│   ├── MusicBrainzService.swift # MusicBrainz + Cover Art Archive API client
│   ├── FixService.swift       # Applies fixes: tags, filenames, moves, backup
│   └── WatchFolderService.swift # FSEvents-based folder watcher + auto-fix
├── ViewModels/
│   └── AppState.swift         # Central @MainActor ViewModel
└── Views/
    ├── ContentView.swift       # NavigationSplitView shell + toolbar
    ├── SidebarView.swift       # Stats + issue filters + selection shortcuts
    ├── FileListView.swift      # File table with checkboxes and issue badges
    ├── FileDetailView.swift    # Tag grid, issue list, proposed path diff
    ├── DiffPreviewSheet.swift  # Git-diff-style change preview before applying
    ├── ReportSheet.swift       # Post-fix summary with error log
    └── SettingsView.swift      # All settings tabs including Watch Folder
```

## Notes on Tag Writing

AVFoundation can **read** tags from all formats but has limited **write** support. This app
delegates all tag writing to `ffmpeg`, which handles ID3v2 (MP3), Vorbis comments (FLAC/OGG),
and iTunes atoms (M4A) uniformly. A temp file is written then atomically renamed, so a failed
write never leaves a half-written file.

## MusicBrainz Rate Limiting

MusicBrainz's free tier allows 1 request/second for anonymous clients. The `MusicBrainzService`
enforces this automatically with a 1.1-second inter-request delay.

## Roadmap ideas

- [ ] Batch re-encode to a target format/bitrate (via ffmpeg)
- [ ] Last.fm scrobble history import to fill play counts
- [ ] Smart playlist generation from cleaned library
- [ ] ReplayGain normalisation
- [ ] iOS companion app via iCloud sync
