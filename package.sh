#!/bin/bash
# Produces build/MissionControlCloser.zip — the file to hand to a friend.
set -e
cd "$(dirname "$0")"

./build.sh

APP="build/MissionControlCloser.app"
ZIP="build/MissionControlCloser.zip"

cat > build/INSTALL.txt <<'TXT'
Mission Control Closer — install
================================
Adds a ✕ button to every window preview in Mission Control.
Click it to quit that app. Option-click closes just that one window.

Requires macOS 13 or later. Works on both Apple Silicon and Intel.

1. Drag MissionControlCloser.app into your Applications folder.

2. Open it. macOS WILL refuse the first time, saying it cannot verify the
   developer. This is expected: the app is not signed with a paid Apple
   Developer certificate. To allow it:

       System Settings ▸ Privacy & Security
       scroll to the bottom, find the message about MissionControlCloser
       click "Open Anyway"

   Or, in Terminal:
       xattr -dr com.apple.quarantine /Applications/MissionControlCloser.app

3. Grant Accessibility permission when asked. The app cannot see Mission
   Control's window previews without it:

       System Settings ▸ Privacy & Security ▸ Accessibility
       enable MissionControlCloser

4. A ✕ icon appears in the menu bar. Use it to enable "Launch at Login".

Then swipe up with three fingers — every preview gets a ✕ in its corner.

Note: closing a window from Mission Control leaves an empty slot where it was.
Mission Control lays its tiles out once when it opens and never rearranges
them, so the gap is covered with a "quit" marker instead. Exit and re-enter
Mission Control to get a clean layout.

Uninstall: quit from the menu bar icon and drag the app to the Bin.
TXT

rm -f "$ZIP"
# ditto preserves the bundle's structure and signature; zip -r does not.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo
echo "Ready to share:"
echo "  $ZIP  ($(du -h "$ZIP" | cut -f1))"
echo "  build/INSTALL.txt  (send this alongside it)"
