# PhotoDiff

A Mac app that opens your old `.photoslibrary` bundles and shows you, as actual
pictures, which photos they contain that your current Photos library doesn't.

It never writes to a photo library. That's the point of it, and it's enforced by the
build rather than promised — see [Read-only, enforced](#read-only-enforced).

## Why

If you have a stack of old Photos libraries on a drive somewhere, the usual options are
to merge them into your current library (and inherit thousands of duplicates), pay for
PowerPhotos, or read a terminal tool's text output. PhotoDiff shows you the pictures
and lets you take only the ones you want.

## What it does

- Opens every `.photoslibrary` in a folder **at once**, concurrently.
- Compares all of them against your current library.
- Shows one combined grid of what's missing, with duplicates between old libraries
  folded into a single entry.
- Recovers a picture for each missing photo and keeps it in the app's own store, so you
  can delete the library copies afterwards and still browse and export.
- Exports the ones you tick to a plain folder. You decide whether to import them.

## Read-only, enforced

Five mechanisms, because "we were careful" isn't a guarantee:

1. **One chokepoint.** `ReadOnlyLibrary` is the only type in the project that can hold
   a `.photoslibrary` path, and it has no write API at all.
2. **Read-only at the syscall.** Bytes leave a library only through an `O_RDONLY` file
   descriptor. SQLite is opened with `SQLITE_OPEN_READONLY` and nothing else.
3. **The database is copied out first.** A library closed mid-session keeps real data
   in `Photos.sqlite-wal`. Opening it in place would let SQLite recover that log and
   write into the library, so the database and its log are copied to scratch space and
   only the copy is ever opened.
4. **A tripwire that ships.** Every file in the bundle is recorded before a scan and
   re-checked after. Any change in size, modification time or inode stops the scan with
   a visible error. This runs in release builds, not just tests.
5. **A test that reads the source.** `swift test` scans the source tree, strips
   comments, and fails the build if a write API appears in any file that can name a
   library — or if any PhotoKit change API appears anywhere.

Your current library is read through Apple's Photos API. PhotoKit's only read access
level is named `.readWrite`; the app never calls a change API, and mechanism 5 enforces
that.

**It also never opens an old library in Photos.app**, which would silently upgrade the
bundle to a newer format.

## How matching works

Most of these libraries ran with iCloud "Optimize Mac Storage", so the full-size
originals usually aren't on disk. Hashing file bytes is therefore impossible, and
matching uses metadata in four tiers. The first one that hits wins, and the grid shows
which tier decided each result:

| Tier | Basis | Catches |
|---|---|---|
| 1 | Apple's content fingerprint | Exact, when the library recorded one |
| 2 | Capture second (±1s) + pixel dimensions | The great majority |
| 3 | Capture second + import filename | Re-encodes where dimensions changed |
| 4 | Import filename + byte size | Assets with no usable date |

Videos additionally have to agree on length, so two clips shot in the same second at
the same resolution aren't collapsed into one.

Uncertain cases are biased toward "already present", because a false "missing" leads to
a duplicate import, which is the more annoying mistake.

## Privacy

The app makes no network calls and collects nothing. There's no telemetry and no
analytics. Everything it writes goes to `~/Library/Application Support/PhotoDiff/` and
wherever you choose to export.

## Requirements

macOS 14 or later, Apple silicon or Intel. No third-party dependencies.

## Build

```
./bundle.sh release
open build/PhotoDiff.app
```

Release builds are attached to GitHub releases. They're ad-hoc signed rather than
notarized, so the first launch needs **right-click → Open** instead of a double-click.

## Tests

```
swift test
```

The read-only suite builds a synthetic library fixture, takes a byte-level fingerprint,
runs a full scan, and asserts the fixture is unchanged — then tampers with it to prove
the tripwire actually fires. No real photo library is used in any test.

## Known limits

- **The packed thumbnail cache isn't read yet.** Photos keeps small thumbnails for
  nearly every asset in `resources/derivatives/thumbs/*.ithmb`, including photos whose
  originals were never downloaded. The layout has to be confirmed against a real
  library before it can be decoded without producing garbled images, so for now photos
  with no original and no derivative JPEG appear as a metadata tile instead of a
  picture. The sidebar reports how many that is.
- Shared-album photos are excluded by default, since PhotoKit's view of your current
  library excludes them too and counting them would flood the result.
- Albums, keywords, faces and edits aren't compared. Identity and pixels only.
