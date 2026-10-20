# Verbemo wave icon

The app uses the selected “Quiet voice” concept: an ivory wave on a dark jade tile.

- Source artwork: `Resources/Verbemo-wave-master.png`, generated with image_gen and selected on 2026-10-20.
- Run `make icon` on macOS to regenerate the classic ICNS, Icon Composer foreground, Windows ICO (16–256 px), and website PNGs.
- `scripts/make-icon.swift` crops the opaque tile, clips its outer edge to the existing macOS icon grid, and separates the pale ribbon from the jade background for Icon Composer. The extraction is specific to this approved artwork; review it if the source palette changes.
- `Resources/Verbemo.icon/icon.json` supplies the adaptive jade background. Its foreground scale is 0.98 because the source image is 1254 px wide on Icon Composer’s 1024 pt canvas.
- `WaveIcon` draws a simplified monochrome version for the menu bar and status window. Idle uses the system template color; recording is red and pause is orange.
- The About window displays the actual application icon.

Check with `python3 -m unittest discover -s Tests/scripts -p test_app_icon.py -v`, `python3 landing/tests/check.py`, and `swift test -c release --arch arm64 --no-parallel --filter NativeAppTests`.

Local installation uses ad-hoc signing. Resource generation on macOS does not establish Windows build or GUI acceptance.
