# Branded macOS DMG — Issue #48

The user approved implementing the proposed DMG customization through PR and
merge. The implementation choice is a light Journal background: cream paper,
green accents and a quiet wave motif, with Verbemo on the left and Applications
on the right. A central arrow and Russian/English instructions explain copying.

## Approaches

- Use pinned `dmgbuild` with one shared layout for both packaging scripts.
  Chosen: it writes Finder metadata without requiring a GUI during CI.
- Drive Finder through AppleScript: fewer Python dependencies, but requires a
  Finder session and waiting for asynchronous metadata writes.
- A dark teal background was considered; the light Journal palette is the
  implementation choice because it continues the application's visual style.

## Scope and constraints

- Initial window size 660 × 420 points; icon centers (170, 210) and
  (490, 210), icons 96 points. Keep labels clear of the arrow and instructions.
- Generate a TIFF with 1× and 2× representations from an AppKit drawing source.
  Use the existing `Resources/Verbemo.icns` as the volume icon.
- Exact copy: “Перетащите Verbemo в Applications” and
  “Drag Verbemo to Applications”. Use real Finder icons and labels.
- Both preview and signed paths call the shared builder before any DMG signing,
  notarization, Sparkle signing or receipt hashing. Keep existing filenames and
  the Preview suffix in the preview volume name.
- Packaging dependencies belong only to build tools. No app dependency, new
  installation wizard, application redesign, Windows changes or publishing bypass.
- Refuse overwriting an existing output. Preserve app signatures, executable
  permissions and symlinks. Build tools must clean their temporary work.

## Acceptance

Build and mount a real image, inspect its contents and Finder metadata, verify
the copied app signature, and inspect Finder in light and dark appearance on a
Retina display. CI builds the exact PR source. Signed release wiring is reviewed;
actual Developer ID signing/notarization remains unavailable without credentials.
