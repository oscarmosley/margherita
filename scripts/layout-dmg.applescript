-- Paths arrive as argv, never interpolated as AppleScript source.
on run argv
    set mountPath to item 1 of argv
    set volName to item 2 of argv
    with timeout of 60 seconds
        tell application "Finder"
            tell disk volName
                open
                delay 1
                set current view of container window to icon view
                try
                    set toolbar visible of container window to false
                end try
                try
                    set statusbar visible of container window to false
                end try
                try
                    set pathbar visible of container window to false
                end try
                try
                    set sidebar width of container window to 0
                end try
                set bounds of container window to {120, 120, 920, 588}
                delay 1
                set viewOptions to the icon view options of container window
                try
                    set arrangement of viewOptions to not arranged
                end try
                try
                    set icon size of viewOptions to 128
                end try
                try
                    set text size of viewOptions to 14
                end try
                try
                    set shows item info of viewOptions to false
                end try
                try
                    set shows icon preview of viewOptions to false
                end try
                set background picture of viewOptions to file ".background:background.tiff"
                -- Wells span y=174...308, optical centre 241. Finder uses icon centres.
                -- Keep the icons on that centre, not the earlier y=198 offset.
                set position of item "Margherita.app" of container window to {220, 242}
                set position of item "Applications" of container window to {580, 242}
                close
                open
                -- Do not silently ship a layout Finder failed to retain.
                if position of item "Margherita.app" of container window is not {220, 242} then
                    error "Finder did not retain the Margherita icon position."
                end if
                if position of item "Applications" of container window is not {580, 242} then
                    error "Finder did not retain the Applications icon position."
                end if
                update without registering applications
                delay 2
                close
            end tell
        end tell
    end timeout
end run
