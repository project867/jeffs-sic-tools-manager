#!/bin/bash
# Watches ~/Desktop/Screenshots for new files and opens/focuses the folder in Finder

WATCH_DIR="$HOME/Desktop/Screenshots"

# Cache screen resolution at startup (avoids querying every screenshot)
SCREEN_BOUNDS=$(/usr/bin/osascript -e 'tell application "Finder" to get bounds of window of desktop')
SCREEN_W=$(echo "$SCREEN_BOUNDS" | awk -F', ' '{print $3}')
SCREEN_H=$(echo "$SCREEN_BOUNDS" | awk -F', ' '{print $4}')

"$HOME/.local/bin/sic-watcher" -0 "$WATCH_DIR" | while IFS= read -r -d '' filepath; do
    filename=$(basename "$filepath")
    case "$filename" in .*) continue ;; esac
    case "$filename" in *.png|*.jpg|*.jpeg|*.tiff|*.bmp|*.gif) ;; *) continue ;; esac
    [ -f "$filepath" ] || continue

    # Single JXA process: set up window + activate only key window
    /usr/bin/osascript -l JavaScript - "$WATCH_DIR" "$filepath" "$SCREEN_W" "$SCREEN_H" <<'JXA'
ObjC.import("Cocoa");

function run(argv) {
    var watchDir = argv[0];
    var filePath = argv[1];
    var screenW = parseInt(argv[2]);
    var screenH = parseInt(argv[3]);
    var winW = 800, winH = 500, pad = 20;
    var x = screenW - winW - pad;
    var y = screenH - winH - pad;

    var finder = Application("Finder");

    // Find existing Screenshots window
    var targetWin = null;
    var wins = finder.windows();
    for (var i = 0; i < wins.length; i++) {
        try {
            if (wins[i].name() === "Screenshots") {
                targetWin = wins[i];
                break;
            }
        } catch(e) {}
    }

    // Open if not found
    if (!targetWin) {
        finder.open(Path(watchDir));
        targetWin = finder.windows[0];
    }

    // Position in bottom-right, make frontmost Finder window
    targetWin.index = 1;
    targetWin.bounds = {x: x, y: y, width: winW, height: winH};

    // Select the new screenshot
    finder.select(Path(filePath));

    // Bring ONLY the key Finder window to front (not all windows)
    var f = $.NSRunningApplication.runningApplicationsWithBundleIdentifier("com.apple.finder").objectAtIndex(0);
    f.activateWithOptions(2);
}
JXA

done
