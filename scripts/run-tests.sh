#!/bin/bash
# The test suite. There is no XCTest target: each harness compiles the shipped sources it guards,
# so a harness that stops compiling means a decision leaked out of a pure layer. See docs/testing.md.
#
# Never join a compile and its run with `&&`: `set -e` ignores a failure in a non-final AND-OR list
# member, which is how CI reported success over a harness that had not compiled since phase 10.

set -uo pipefail

# Absolute: the workers re-enter this script after the cd, where a relative $0 would not resolve.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.." || exit 1

BIN="${TMPDIR:-/tmp}/ollie-harness"
mkdir -p "$BIN"

# `--exec` is the worker half: xargs re-enters here once per queued harness.
if [ "${1:-}" = "--exec" ]; then
    shift
    name=$1 opt=$2
    shift 2
    : > "$BIN/$name.running"
    trap 'rm -f "$BIN/$name.running" "$BIN/$name.time"' EXIT
    fail() {
        printf '\033[31mFAIL\033[0m  %-25s %s\n' "$name" "$1"
        : > "$BIN/$name.failed"
        exit 0
    }
    TIMEFORMAT=%1R
    if ! compiled=$( { time swiftc -swift-version 6 "$opt" "$@" "Tests/$name.swift" -o "$BIN/$name" > "$BIN/$name.log" 2>&1; } 2>&1 ); then
        fail "did not compile"
    fi
    { time "$BIN/$name" > "$BIN/$name.log" 2>&1; } 2> "$BIN/$name.time" &
    pid=$!
    # macOS ships no `timeout`, so the worker polls; a wedged harness must fail, not stall the suite.
    ticks=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge $((OLLIE_TEST_TIMEOUT * 5)) ]; then
            { pkill -KILL -P "$pid"; kill -KILL "$pid"; wait "$pid"; } 2>/dev/null
            printf '\n[run-tests] killed after %ss without finishing\n' "$OLLIE_TEST_TIMEOUT" >> "$BIN/$name.log"
            fail "timed out after ${OLLIE_TEST_TIMEOUT}s"
        fi
        ticks=$((ticks + 1))
        sleep 0.2
    done
    wait "$pid"
    status=$?
    took=$(< "$BIN/$name.time")
    if [ "$status" -gt 128 ]; then fail "crashed (signal $((status - 128))) after ${took}s"; fi
    if [ "$status" -ne 0 ]; then fail "assertion failed after ${took}s"; fi
    printf '\033[32mok\033[0m    %-25s %5ss  \033[2m(compile %ss)\033[0m\n' "$name" "$took" "$compiled"
    exit 0
fi

QUEUE="$BIN/queue"
: > "$QUEUE"
rm -f "$BIN"/*.failed "$BIN"/*.running

failed=()
ran=0
only="${1:-}"

# `--index` merges each harness's compile command into .compile instead of running anything.
# xcodebuild never compiles the harnesses, so without this nothing in Tests/ resolves in an editor.
# The source lists below are the only copy, which is why this lives here rather than in its own script.
emit_db=0
DB="${TMPDIR:-/tmp}/ollie-compile-db.json"
if [ "$only" = "--index" ]; then
    emit_db=1
    only=""
    printf '[' > "$DB"
fi

# run [slow] [-O] [index] <name> <source...> — queue the harness. `slow` dispatches it in the first
# wave; `index` claims editor flags for a harness that is compiled by hand rather than by the suite.
run() {
    local opt=-Onone pri=1 index_only=0
    while :; do
        case "$1" in
            slow)  pri=0; shift;;
            -O)    opt=-O; shift;;
            index) index_only=1; shift;;
            *)     break;;
        esac
    done
    local name=$1
    shift
    if [ -n "$only" ] && [ "$name" != "$only" ]; then return 0; fi
    if [ "$index_only" -eq 1 ] && [ "$emit_db" -eq 0 ]; then return 0; fi
    ran=$((ran + 1))

    # Absolute paths throughout: sourcekit-lsp resolves the command itself and does not apply
    # `directory` to relative arguments, so a relative path there silently yields no index.
    if [ "$emit_db" -eq 1 ]; then
        local sources=()
        for source in "$@" "Tests/$name.swift"; do sources+=("$PWD/$source"); done
        [ "$ran" -gt 1 ] && printf ',' >> "$DB"
        printf '{"directory":"%s","command":"swiftc -swift-version 6 -sdk %s' \
            "$PWD" "$(xcrun --show-sdk-path --sdk macosx)" >> "$DB"
        printf ' %s' "${sources[@]}" >> "$DB"
        # Claim every file under `Tests/`: the harness and any helper compiled beside it. A shipped
        # source stays unclaimed, because it would get this short command instead of the app's full
        # one and `.compile` is last-wins — but the app never compiles anything in `Tests/`.
        local claimed=""
        for source in "${sources[@]}"; do
            case "$source" in *"/Tests/"*) claimed="$claimed${claimed:+,}\"$source\"";; esac
        done
        printf '","files":[%s]}' "$claimed" >> "$DB"
        return 0
    fi

    # xargs splits the queue on whitespace, so no harness source path may contain a space.
    printf '%s %s %s %s\n' "$pri" "$name" "$opt" "$*" >> "$QUEUE"
}

L=Ollie/Features/Launcher/Model
run slow -O fuzz-test      $L/SearchRelevance.swift $L/ScriptRomanization.swift \
                           $L/LauncherMatch.swift $L/EntryNaming.swift $L/LauncherOrder.swift \
                           $L/LauncherRankingStore.swift $L/LauncherSuggestions.swift
run file-search-test       $L/SearchRelevance.swift \
                           Ollie/Features/FileSearch/Model/*.swift
run file-search-session-test Ollie/Platform/Diagnostics.swift Ollie/Platform/Signposts.swift \
                             $L/SearchRelevance.swift \
                             Ollie/Features/FileSearch/Model/*.swift \
                             Ollie/Features/FileSearch/Service/*.swift
run menu-search-test       $L/SearchRelevance.swift \
                           Ollie/Features/MenuSearch/Model/*.swift \
                           Ollie/Features/MenuSearch/Service/*.swift
run index file-search-performance Ollie/Platform/Diagnostics.swift Ollie/Platform/Signposts.swift \
                           $L/SearchRelevance.swift \
                           Ollie/Features/FileSearch/Model/*.swift \
                           Ollie/Features/FileSearch/Service/FileSearchService.swift
run launcher-apps-test     $L/SearchRelevance.swift $L/ScriptRomanization.swift \
                           $L/LauncherMatch.swift $L/EntryNaming.swift $L/LauncherOrder.swift \
                           $L/LauncherRankingStore.swift $L/LauncherAppResults.swift
run ranking-test           $L/SearchRelevance.swift $L/ScriptRomanization.swift \
                           $L/LauncherMatch.swift $L/LauncherRankingStore.swift
run scopes-test            $L/SearchScopes.swift
run app-name-test          Ollie/Platform/AppDisplayName.swift \
                           Ollie/Platform/BundleLocalization.swift \
                           $L/SearchRelevance.swift
run favorites-test         $L/FavoriteSlots.swift
run launcher-file-test     $L/LauncherFileFormat.swift \
                           Ollie/Features/Settings/Model/SettingsFileJSON.swift
run launcher-settings-file-test \
                           $L/LauncherFileFormat.swift $L/CommandID.swift $L/CommandCatalog.swift \
                           Ollie/Features/Launcher/Service/LauncherSettingsFile.swift \
                           Ollie/Features/Launcher/Service/AliasStore.swift \
                           Ollie/Features/Launcher/Service/VisibilityStore.swift \
                           Ollie/Features/Settings/SettingsTab.swift \
                           Ollie/Features/Settings/Model/*.swift \
                           Ollie/Features/HotKeys/Service/HotKeySettingsFile.swift \
                           Ollie/Features/HotKeys/Service/KeyShortcut.swift \
                           Ollie/Features/HotKeys/Model/HotKeyAction.swift \
                           Ollie/Features/HotKeys/Model/HotKeyBinding.swift \
                           Ollie/Features/HotKeys/Model/HotKeySpelling.swift \
                           Ollie/Features/HotKeys/Model/DoubleTapModifier.swift \
                           Ollie/Features/HotKeys/Model/ModifierKey.swift \
                           Ollie/Platform/ASCIIKeyboardLayout.swift \
                           Ollie/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Ollie/Features/Quicklinks/Model/Quicklink.swift \
                           Ollie/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Ollie/Features/SystemActions/Model/SystemAction.swift \
                           Ollie/Features/WindowManagement/Model/WindowCommand.swift
run apple-shortcut-test    Ollie/Features/AppleShortcuts/Model/*.swift
run calc-test              Ollie/Features/Calculator/Model/*.swift
run index calc-performance Ollie/Features/Calculator/Model/*.swift
run calendar-test          Ollie/Features/Calendar/Model/*.swift
# `Q` is the URL detector a drag payload builds its link with, rather than a second one.
Q=Ollie/Features/Quicklinks/Model/QuicklinkDestination.swift
run emoji-test             Ollie/Features/Emoji/Model/EmojiCatalog.swift \
                           Ollie/Features/Emoji/Model/EmojiGridGeometry.swift \
                           Ollie/Features/Emoji/Model/EmojiData.generated.swift
run emoji-search-test      Ollie/Features/Emoji/Model/EmojiCatalog.swift \
                           Ollie/Features/Emoji/Model/EmojiData.generated.swift \
                           Ollie/Features/Emoji/Service/EmojiIndex.swift \
                           Ollie/Features/Emoji/Service/FrequentEmojiStore.swift \
                           Ollie/Features/Emoji/Service/PinnedEmojiStore.swift \
                           Ollie/Features/Launcher/Model/SearchRelevance.swift \
                           Ollie/Platform/AppPaths.swift Ollie/Platform/Memo.swift
run index emoji-search-performance \
                           Ollie/Features/Emoji/Model/EmojiCatalog.swift \
                           Ollie/Features/Emoji/Model/EmojiData.generated.swift \
                           Ollie/Features/Emoji/Service/EmojiIndex.swift \
                           Ollie/Features/Emoji/Service/FrequentEmojiStore.swift \
                           Ollie/Features/Launcher/Model/SearchRelevance.swift \
                           Ollie/Platform/AppPaths.swift Ollie/Platform/Memo.swift
run palette-selection-test Ollie/Features/PaletteRowIndex.swift \
                           Ollie/Features/Emoji/Model/EmojiGridGeometry.swift
run appearance-test        Ollie/Platform/Appearance.swift \
                           Ollie/DesignSystem/Theme.swift \
                           Ollie/DesignSystem/InterfaceMetrics.swift \
                           Ollie/Features/Settings/AppAppearance.swift
run interface-size-test    Ollie/Platform/Appearance.swift \
                           Ollie/DesignSystem/Theme.swift \
                           Ollie/DesignSystem/InterfaceMetrics.swift \
                           Ollie/Features/Settings/InterfaceSize.swift \
                           Ollie/Features/Extensions/Model/ExtensionFormMetrics.swift
run palette-placement-test Ollie/Platform/Appearance.swift \
                           Ollie/DesignSystem/Theme.swift \
                           Ollie/DesignSystem/InterfaceMetrics.swift \
                           Ollie/Features/Settings/InterfaceSize.swift \
                           Ollie/Palette/PalettePlacement.swift
run palette-surface-test   Ollie/Platform/Appearance.swift \
                           Ollie/DesignSystem/Theme.swift \
                           Ollie/DesignSystem/InterfaceMetrics.swift \
                           Ollie/Features/Settings/InterfaceSize.swift \
                           Ollie/Palette/PaletteSurface.swift \
                           Ollie/Palette/PaletteMode.swift \
                           Ollie/Features/Settings/SettingsTab.swift \
                           Ollie/Features/Settings/Model/FeatureAvailability.swift \
                           Ollie/Features/Quicklinks/Model/Quicklink.swift \
                           Ollie/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Ollie/Features/CustomCommands/Model/CustomCommand.swift
run scroll-reveal-test     Ollie/DesignSystem/Scrolling/SelectionReveal.swift
run redaction-test         Ollie/DesignSystem/RedactedPlaceholder.swift
run keyboard-focus-test    Ollie/DesignSystem/Interaction/KeyboardFocus.swift
run ai-instructions-test   Ollie/Features/AI/Model/AIInstructions.swift \
                           Ollie/Features/AI/Model/AIPreamble.swift
run hover-arming-test      Ollie/Palette/HoverArming.swift \
                           Ollie/Palette/PaletteState.swift \
                           Ollie/Palette/PaletteMode.swift \
                           Ollie/Features/Settings/SettingsTab.swift \
                           Ollie/Features/Settings/Model/FeatureAvailability.swift \
                           Ollie/Features/Emoji/Model/EmojiCatalog.swift \
                           Ollie/Features/FileSearch/Model/FileSearchFilter.swift \
                           Ollie/Features/Calculator/Model/ColorValue.swift \
                           Ollie/Features/Calculator/Model/ColorFormat.swift \
                           Ollie/Features/Calculator/Model/ColorSpaces.swift \
                           Ollie/Features/Quicklinks/Model/Quicklink.swift \
                           Ollie/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Ollie/Features/CustomCommands/Model/CustomCommand.swift
run palette-escape-test    Ollie/Palette/PaletteMode.swift \
                           Ollie/Features/Settings/SettingsTab.swift \
                           Ollie/Features/Settings/Model/FeatureAvailability.swift \
                           Ollie/Palette/PaletteEscapeAction.swift \
                           Ollie/Palette/CommandEscapeTap.swift \
                           Ollie/Features/Settings/EscapeKeyBehavior.swift \
                           Ollie/Features/Quicklinks/Model/Quicklink.swift \
                           Ollie/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Ollie/Features/CustomCommands/Model/CustomCommand.swift
run palette-navigation-test Ollie/Palette/PaletteState.swift \
                           Ollie/Palette/PaletteFieldBoundary.swift \
                           Ollie/Palette/PaletteMode.swift \
                           Ollie/Features/Settings/SettingsTab.swift \
                           Ollie/Features/Settings/Model/FeatureAvailability.swift \
                           Ollie/Palette/HoverArming.swift \
                           Ollie/Features/Emoji/Model/EmojiCatalog.swift \
                           Ollie/Features/FileSearch/Model/FileSearchFilter.swift \
                           Ollie/Features/Calculator/Model/ColorValue.swift \
                           Ollie/Features/Calculator/Model/ColorFormat.swift \
                           Ollie/Features/Calculator/Model/ColorSpaces.swift \
                           Ollie/Features/Quicklinks/Model/Quicklink.swift \
                           Ollie/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Ollie/Features/CustomCommands/Model/CustomCommand.swift
run palette-filter-test    Ollie/Palette/PaletteMode.swift \
                           Ollie/Features/Settings/SettingsTab.swift \
                           Ollie/Features/Settings/Model/FeatureAvailability.swift \
                           Ollie/Palette/PaletteFilterAction.swift \
                           Ollie/Features/Quicklinks/Model/Quicklink.swift \
                           Ollie/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Ollie/Features/CustomCommands/Model/CustomCommand.swift
run action-menu-search-test Ollie/Palette/ActionMenuSearchQuery.swift \
                            Ollie/Features/Launcher/Model/SearchRelevance.swift
run palette-shortcut-test  Ollie/Palette/PaletteShortcut.swift
run ascii-layout-test      Ollie/Platform/ASCIIKeyboardLayout.swift
run palette-tab-test       Ollie/Palette/PaletteMode.swift \
                           Ollie/Features/Settings/SettingsTab.swift \
                           Ollie/Features/Settings/Model/FeatureAvailability.swift \
                           Ollie/Palette/PaletteTabAction.swift \
                           Ollie/Features/Quicklinks/Model/Quicklink.swift \
                           Ollie/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Ollie/Features/CustomCommands/Model/CustomCommand.swift
run fallback-test          Ollie/Features/Launcher/Model/Fallback.swift \
                           Ollie/Features/Launcher/Model/CommandID.swift \
                           Ollie/Features/HotKeys/Model/HotKeyAction.swift \
                           Ollie/Features/QuickActions/Model/QuickAction.swift \
                           Ollie/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Ollie/Features/QuickActions/Model/CustomQuickAction.swift \
                           Ollie/Features/Quicklinks/Model/Quicklink.swift \
                           Ollie/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Ollie/Features/SystemActions/Model/SystemAction.swift \
                           Ollie/Features/WindowManagement/Model/WindowCommand.swift
run dictionary-test        Ollie/Features/Dictionary/Model/DictionaryEntry.swift \
                           Ollie/Features/Dictionary/Model/DictionaryMarkup.swift
run hotkey-test            Ollie/Features/HotKeys/Model/DoubleTapModifier.swift \
                           Ollie/Features/HotKeys/Model/ModifierKey.swift \
                           Ollie/Features/HotKeys/Model/ModifierKeyDetector.swift \
                           Ollie/Features/HotKeys/Model/DoubleTapDetector.swift \
                           Ollie/Features/HotKeys/Model/HotKeyBinding.swift \
                           Ollie/Features/HotKeys/Model/HotKeySpelling.swift \
                           Ollie/Platform/ASCIIKeyboardLayout.swift \
                           Ollie/Features/HotKeys/Service/KeyShortcut.swift \
                           Ollie/Features/HotKeys/Model/HotKeyAction.swift \
                           Ollie/Features/QuickActions/Model/QuickAction.swift \
                           Ollie/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Ollie/Features/QuickActions/Model/CustomQuickAction.swift \
                           Ollie/Features/Launcher/Model/CommandID.swift \
                           Ollie/Features/Quicklinks/Model/Quicklink.swift \
                           Ollie/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Ollie/Features/SystemActions/Model/SystemAction.swift \
                           Ollie/Features/WindowManagement/Model/WindowCommand.swift
run callout-test          Ollie/Platform/Appearance.swift \
                           Ollie/DesignSystem/Theme.swift \
                           Ollie/DesignSystem/InterfaceMetrics.swift \
                           Ollie/Features/HotKeys/UI/CalloutPlacement.swift
run icon-cache-test        Ollie/Platform/Appearance.swift \
                           Ollie/Platform/Images/IconCache.swift
run entry-icon-test        Ollie/Platform/Appearance.swift \
                           Ollie/Platform/Images/IconCache.swift \
                           Ollie/Platform/Images/FileIconStamp.swift
run ext-icon-test          Ollie/Platform/Appearance.swift \
                           Ollie/Platform/AppDisplayName.swift \
                           Ollie/Platform/Images/IconCache.swift \
                           Ollie/Platform/Compression/Zlib.swift \
                           Ollie/DesignSystem/Theme.swift \
                           Ollie/DesignSystem/InterfaceMetrics.swift \
                           Ollie/Features/Extensions/Model/ExtensionBootConfig.swift \
                           Ollie/Features/Extensions/Model/ExtensionLaunchType.swift \
                           Ollie/Features/Extensions/Model/ExtensionManifest.swift \
                           Ollie/Features/Extensions/Model/ExtensionRefreshPolicy.swift \
                           Ollie/Features/Extensions/Model/ExtensionRefreshState.swift \
                           Ollie/Features/Extensions/Model/RenderNode.swift \
                           Ollie/Features/Extensions/Service/ExtensionCatalog.swift \
                           Ollie/Features/Extensions/Service/ExtensionFetcher.swift \
                           Ollie/Platform/ProcessExit.swift \
                           Ollie/Features/Extensions/Service/ExtensionNodeShims.swift \
                           Ollie/Features/Extensions/Service/ExtensionOAuthKeychain.swift \
                           Ollie/Features/Extensions/Service/ExtensionOAuthSession.swift \
                           Ollie/Features/Extensions/Service/ExtensionRuntime.swift \
                           Ollie/Features/Extensions/Service/ExtensionIconCache.swift \
                           Ollie/Features/Extensions/UI/ExtensionAnimatedImage.swift \
                           Ollie/Features/Extensions/UI/ExtensionImage.swift \
                           Ollie/Features/Calculator/Model/ColorValue.swift \
                           Ollie/Features/Calculator/Model/ColorSpaces.swift
run system-action-test     Ollie/Features/SystemActions/Model/SystemAction.swift
run microphone-mute-test   Ollie/Features/SystemActions/Service/SystemActionFailure.swift \
                           Ollie/Features/SystemActions/Service/SystemActionRunner+Microphone.swift
run volume-test            Ollie/Features/SystemActions/Model/VolumeLevel.swift
run window-command-test    Ollie/Features/WindowManagement/Model/WindowCommand.swift \
                           Ollie/Features/WindowManagement/Model/WindowCycle.swift \
                           Ollie/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Ollie/Features/WindowManagement/Model/WindowActionMemory.swift
run window-preset-test     Ollie/Features/WindowManagement/Model/WindowCommand.swift \
                           Ollie/Features/WindowManagement/Model/WindowShortcutPreset.swift \
                           Ollie/Features/HotKeys/Model/DoubleTapModifier.swift \
                           Ollie/Features/HotKeys/Model/ModifierKey.swift \
                           Ollie/Features/HotKeys/Model/HotKeyBinding.swift \
                           Ollie/Platform/ASCIIKeyboardLayout.swift \
                           Ollie/Features/HotKeys/Service/KeyShortcut.swift
run spaces-test           Ollie/Features/WindowManagement/Model/WindowCommand.swift \
                           Ollie/Features/WindowManagement/Model/SpaceGesture.swift \
                           Ollie/Features/Spaces/Model/SpaceSwipeState.swift \
                           Ollie/Features/Spaces/Model/SpaceBoundaryState.swift \
                           Ollie/Features/Spaces/Model/SpaceTransitionSpeed.swift

run space-gesture-test     Ollie/Features/WindowManagement/Model/WindowCommand.swift \
                           Ollie/Features/WindowManagement/Model/SpaceGesture.swift
run window-layout-test     Ollie/Features/WindowManagement/Model/WindowCommand.swift \
                           Ollie/Features/WindowManagement/Model/WindowCycle.swift \
                           Ollie/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Ollie/Features/WindowManagement/Model/WindowLayoutAnchor.swift \
                           Ollie/Features/WindowManagement/Model/WindowLayoutDisplay.swift \
                           Ollie/Features/WindowManagement/Model/WindowLayout.swift \
                           Ollie/Features/WindowManagement/Model/WindowLayoutGeometry.swift \
                           Ollie/Features/WindowManagement/Model/WindowLayoutPlan.swift \
                           Ollie/Features/WindowManagement/Model/WindowLayoutStore.swift \
                           Ollie/Features/WindowManagement/Model/CustomWindowSize.swift \
                           Ollie/Features/WindowManagement/Model/CustomWindowSizeStore.swift
run window-room-test       Ollie/Features/WindowManagement/Model/WindowCommand.swift \
                           Ollie/Features/WindowManagement/Model/WindowCycle.swift \
                           Ollie/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Ollie/Features/WindowManagement/Model/WindowLayoutAnchor.swift \
                           Ollie/Features/WindowManagement/Model/WindowLayoutDisplay.swift \
                           Ollie/Features/WindowManagement/Model/WindowLayout.swift \
                           Ollie/Features/WindowManagement/Model/WindowLayoutGeometry.swift \
                           Ollie/Features/WindowManagement/Model/WindowLayoutPlan.swift \
                           Ollie/Features/WindowManagement/Model/RoomLayoutKind.swift \
                           Ollie/Features/WindowManagement/Model/RoomLayoutEngine.swift \
                           Ollie/Features/WindowManagement/Model/RoomGrid.swift \
                           Ollie/Features/WindowManagement/Model/RoomWindow.swift \
                           Ollie/Features/WindowManagement/Model/Room.swift \
                           Ollie/Features/WindowManagement/Model/RoomWindowMatcher.swift \
                           Ollie/Features/WindowManagement/Model/RoomParking.swift \
                           Ollie/Features/WindowManagement/Model/RoomPlan.swift \
                           Ollie/Features/WindowManagement/Model/RoomArrangement.swift \
                           Ollie/Features/WindowManagement/Model/RoomStore.swift \
                           Ollie/Features/WindowManagement/Model/RoomMinimumSizeStore.swift \
                           Ollie/Features/WindowManagement/Model/RoomParkingLedger.swift
run window-file-test       Ollie/Features/WindowManagement/Model/WindowCommand.swift \
                           Ollie/Features/WindowManagement/Model/WindowCycle.swift \
                           Ollie/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Ollie/Features/WindowManagement/Model/WindowLayoutAnchor.swift \
                           Ollie/Features/WindowManagement/Model/WindowLayoutDisplay.swift \
                           Ollie/Features/WindowManagement/Model/WindowLayout.swift \
                           Ollie/Features/WindowManagement/Model/WindowLayoutGeometry.swift \
                           Ollie/Features/WindowManagement/Model/CustomWindowSize.swift \
                           Ollie/Features/WindowManagement/Model/Room.swift \
                           Ollie/Features/WindowManagement/Model/RoomWindow.swift \
                           Ollie/Features/WindowManagement/Model/RoomLayoutKind.swift \
                           Ollie/Features/WindowManagement/Model/RoomGrid.swift \
                           Ollie/Features/WindowManagement/Model/RoomLayoutEngine.swift \
                           Ollie/Features/WindowManagement/Model/WindowManagementFileFormat.swift \
                           Ollie/Features/Settings/Model/SettingsFileJSON.swift \
                           Ollie/Features/Settings/Model/SettingsFileIdentity.swift
run custom-command-test    Ollie/Platform/PseudoTerminal.swift \
                           Ollie/Platform/ProcessExit.swift \
                           Ollie/Features/CustomCommands/Model/CustomCommand.swift \
                           Ollie/Features/CustomCommands/Model/RaycastScriptImport.swift \
                           Ollie/Features/CustomCommands/Service/ShellCommandRunner.swift
run uninstall-test         Ollie/Features/Uninstall/Model/UninstallTarget.swift \
                           Ollie/Features/Uninstall/Model/UninstallSearchRoot.swift \
                           Ollie/Features/Uninstall/Model/UninstallRules.swift \
                           Ollie/Features/Uninstall/Model/UninstallProtection.swift \
                           Ollie/Features/Uninstall/Model/UninstallPlan.swift
run text-injection-test Ollie/Features/TextInjection/Service/*.swift \
    Ollie/Features/Quicklinks/Model/QuicklinkTemplateEngine.swift \
    Ollie/Platform/{Paster,PasteboardFiles,Permissions,AccessibilityText,CalendarAccess,CameraAccess}.swift

run quicklink-template-test Ollie/Features/Quicklinks/Model/QuicklinkTemplateEngine.swift

run quicklink-test         Ollie/Features/Quicklinks/Model/Quicklink.swift \
                           Ollie/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Ollie/Features/Quicklinks/Model/QuicklinkStore.swift \
                           Ollie/Features/Quicklinks/Model/QuicklinkArchive.swift \
                           Ollie/Features/Quicklinks/Model/RaycastQuicklinkImport.swift
run quicklink-coordinator-test Ollie/Features/Quicklinks/Model/Quicklink.swift \
                           Ollie/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Ollie/Features/Quicklinks/Model/QuicklinkStore.swift \
                           Ollie/Features/Quicklinks/Model/QuicklinkArchive.swift \
                           Ollie/Features/Quicklinks/UI/QuicklinkCoordinator.swift \
                           Ollie/Features/Quicklinks/UI/QuicklinkArgumentsAccessory.swift \
                           Ollie/Features/Quicklinks/Model/QuicklinkTemplateEngine.swift
run notes-test             Ollie/Platform/Diagnostics.swift Ollie/Platform/Signposts.swift \
                           $L/SearchRelevance.swift \
                           Ollie/Features/Notes/Model/*.swift \
                           Ollie/Features/Notes/Service/*.swift
run notes-editor-test      Ollie/Platform/Diagnostics.swift Ollie/Platform/Signposts.swift \
                           Ollie/Platform/Appearance.swift \
                           Ollie/DesignSystem/Theme.swift \
                           Ollie/DesignSystem/InterfaceMetrics.swift \
                           Ollie/Platform/NotificationToken.swift \
                           Ollie/Features/TextInjection/Service/InjectableTextView.swift \
                           Ollie/Features/Notes/Model/NoteDocument.swift \
                           Ollie/Features/Notes/Model/NoteMarkdown.swift \
                           Ollie/Features/Notes/Model/NoteMarkdownParser.swift \
                           Ollie/Features/Notes/Model/NoteInlineScanner.swift \
                           Ollie/Features/Notes/Model/NoteEditPlan.swift \
                           Ollie/Features/Notes/Model/NoteEditAction.swift \
                           Ollie/Features/Notes/Model/NoteFormatting.swift \
                           Ollie/Features/Notes/Model/NoteMarkdownEditing.swift \
                           Ollie/Features/Notes/Model/NoteRevealPolicy.swift \
                           Ollie/Features/Notes/UI/NoteMarkdownTypography.swift \
                           Ollie/Features/Notes/UI/NoteBlockDecoration.swift \
                           Ollie/Features/Notes/UI/NoteMarkdownStyler.swift \
                           Ollie/Features/Notes/UI/NoteMarkdownRenderer.swift \
                           Ollie/Features/Notes/UI/NoteCheckboxGeometry.swift \
                           Ollie/Features/Notes/UI/NoteBlockLayoutFragment.swift \
                           Ollie/Features/Notes/UI/NoteLayoutFragmentProvider.swift \
                           Ollie/Features/Notes/UI/NoteTextViewEditing.swift \
                           Ollie/Features/Notes/UI/NoteTextView.swift \
                           Ollie/Features/Notes/UI/NoteEditorView.swift
run -O index notes-editor-performance \
                           Ollie/Platform/Diagnostics.swift Ollie/Platform/Signposts.swift \
                           Ollie/Platform/Appearance.swift \
                           Ollie/DesignSystem/Theme.swift \
                           Ollie/DesignSystem/InterfaceMetrics.swift \
                           Ollie/Platform/NotificationToken.swift \
                           Ollie/Features/TextInjection/Service/InjectableTextView.swift \
                           Ollie/Features/Notes/Model/NoteDocument.swift \
                           Ollie/Features/Notes/Model/NoteMarkdown.swift \
                           Ollie/Features/Notes/Model/NoteMarkdownParser.swift \
                           Ollie/Features/Notes/Model/NoteInlineScanner.swift \
                           Ollie/Features/Notes/Model/NoteEditPlan.swift \
                           Ollie/Features/Notes/Model/NoteEditAction.swift \
                           Ollie/Features/Notes/Model/NoteFormatting.swift \
                           Ollie/Features/Notes/Model/NoteMarkdownEditing.swift \
                           Ollie/Features/Notes/Model/NoteRevealPolicy.swift \
                           Ollie/Features/Notes/UI/NoteMarkdownTypography.swift \
                           Ollie/Features/Notes/UI/NoteBlockDecoration.swift \
                           Ollie/Features/Notes/UI/NoteMarkdownStyler.swift \
                           Ollie/Features/Notes/UI/NoteMarkdownRenderer.swift \
                           Ollie/Features/Notes/UI/NoteCheckboxGeometry.swift \
                           Ollie/Features/Notes/UI/NoteBlockLayoutFragment.swift \
                           Ollie/Features/Notes/UI/NoteLayoutFragmentProvider.swift \
                           Ollie/Features/Notes/UI/NoteTextViewEditing.swift \
                           Ollie/Features/Notes/UI/NoteTextView.swift \
                           Ollie/Features/Notes/UI/NoteEditorView.swift
run slow -O raycast-test   Ollie/Features/Backup/Model/RaycastImportError.swift \
                           Ollie/Features/Backup/Service/RaycastDecoder.swift \
                           Ollie/Features/Backup/Service/Scrypt.swift \
                           Ollie/Platform/Compression/Zlib.swift \
                           Ollie/Features/Calculator/Model/ColorValue.swift \
                           Ollie/Features/Calculator/Model/ColorFormat.swift \
                           Ollie/Features/Calculator/Model/ColorSpaces.swift
run settings-backup-test   Ollie/Features/Settings/AppSettingsKey.swift \
                           Ollie/Features/Backup/Model/SettingsBackupCoverage.swift
run settings-file-test     Ollie/Features/Settings/Model/*.swift \
                           Ollie/Features/Settings/Service/SettingsFileMonitor.swift \
                           Ollie/Features/Settings/Service/SettingsFileRepository.swift \
                           Ollie/Platform/AppPaths.swift
run backup-archive-test    Ollie/Platform/AppPaths.swift \
                           Ollie/Features/Backup/Model/BackupArchive.swift \
                           Ollie/Features/Backup/Model/BackupBundle.swift \
                           Ollie/Features/Backup/Model/BackupCategory.swift \
                           Ollie/Features/Backup/Model/BackupManifest.swift \
                           Ollie/Features/Backup/Service/BackupStaging.swift
E=Ollie/Features/Extensions
run symbols-test           $E/Service/SymbolCatalog.swift
run ext-cleanup-test       $E/Service/ExtensionCleanup.swift \
                           $E/Service/ExtensionCatalog.swift \
                           Ollie/Platform/AppDisplayName.swift \
                           $E/Model/ExtensionManifest.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift
run ext-refresh-test       $E/Model/ExtensionManifest.swift \
                           Ollie/Platform/AppDisplayName.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift
run ext-metadata-test      $E/Model/ExtensionCommandMetadata.swift \
                           $E/Model/ExtensionMenuBarSnapshot.swift \
                           $E/Service/ExtensionCommandMetadataStore.swift
run ext-version-test       $E/Model/ExtensionListing.swift \
                           $E/Service/ExtensionVersionStore.swift
run ext-store-test         $E/Model/ExtensionGitHubSource.swift \
                           $E/Model/ExtensionListing.swift \
                           $E/Model/ExtensionPackageManager.swift \
                           $E/Model/ExtensionStoreResponse.swift
run ext-form-test          $E/Model/ExtensionFormMetrics.swift \
                           $E/Model/ExtensionFormField.swift \
                           $E/UI/ExtensionFormKey.swift \
                           $E/Model/ExtensionDateExpression.swift \
                           $E/UI/ExtensionListKey.swift \
                           Tests/ext-list-key-test.swift
run ext-image-size-test   $E/Model/ExtensionImageSize.swift
run ext-accessory-test     $E/Model/RenderNode.swift \
                           $E/Model/ExtensionPickerItem.swift \
                           $E/Model/ExtensionSearchAccessory.swift \
                           $E/Service/ExtensionStorage.swift
run slow ext-test          -parse-as-library \
                           Tests/ext-menu-bar-test.swift \
                           Tests/ext-fetch-test.swift \
                           $E/Model/ExtensionLaunchError.swift \
                           $E/Model/ExtensionMenuBarSnapshot.swift \
                           $E/Service/ExtensionStorage.swift \
                           $E/Service/ExtensionMenuBarManager.swift \
                           Ollie/Platform/Diagnostics.swift \
                           $E/Model/ExtensionCommandMetadata.swift \
                           $E/Service/ExtensionCommandMetadataStore.swift \
                           $E/UI/ExtensionMenuBarController.swift \
                           $E/UI/ExtensionMenuBarImage.swift \
                           Ollie/Platform/Appearance.swift \
                           Ollie/Platform/AppDisplayName.swift \
                           Ollie/Platform/Images/IconCache.swift \
                           Ollie/DesignSystem/Theme.swift \
                           Ollie/DesignSystem/InterfaceMetrics.swift \
                           $E/Model/ExtensionBootConfig.swift \
                           $E/Model/ExtensionDeepLink.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionFormField.swift \
                           $E/Model/ExtensionGridLayout.swift \
                           $E/Model/ExtensionManifest.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift \
                           $E/Model/RenderNode.swift \
                           $E/Model/ExtensionPickerItem.swift \
                           $E/Model/ExtensionSearchAccessory.swift \
                           $E/Service/ExtensionCatalog.swift \
                           $E/Service/ExtensionFetcher.swift \
                           Ollie/Platform/ProcessExit.swift \
                           $E/Service/ExtensionIconCache.swift \
                           $E/Service/ExtensionNodeShims.swift \
                           $E/Service/ExtensionOAuthKeychain.swift \
                           $E/Service/ExtensionOAuthSession.swift \
                           $E/Service/ExtensionRuntime.swift \
                           $E/Service/ExtensionNameResolver.swift \
                           $E/Service/ExtensionWebSocketBridge.swift \
                           $E/UI/ExtensionAnimatedImage.swift \
                           $E/UI/ExtensionImage.swift \
                           $E/UI/ExtensionScreen.swift \
                           $L/SearchRelevance.swift \
                           Ollie/Platform/Compression/Zlib.swift \
                           Ollie/Features/Calculator/Model/ColorValue.swift \
                           Ollie/Features/Calculator/Model/ColorSpaces.swift
run -O clipboard-navigation-diagnostics-test -parse-as-library \
    Ollie/Platform/Diagnostics.swift \
    Ollie/Features/Clipboard/Service/ClipboardNavigationDiagnostics.swift
run diagnostics-test -parse-as-library Ollie/Platform/Diagnostics.swift Ollie/Platform/Signposts.swift Ollie/Features/Settings/AppSettingsKey.swift
run ollie-dictation-test Ollie/Features/Dictation/Service/{TranscriptionAudioFile,ElevenLabsPrerecordedClient,ElevenLabsClient,MusePrerecordedClient,MuseClient}.swift Ollie/Features/Dictation/Model/ElevenLabsRealtimeEvent.swift Ollie/Features/Dictation/UI/FileTranscriptionController.swift Ollie/Features/Dictation/Model/TranscriptSpan.swift -parse-as-library Ollie/Platform/Diagnostics.swift Ollie/Features/Dictation/Service/{CelerisClient,OpenRouterClient,MercuryClient,DictationHTTP}.swift Tests/Dictation/*.swift Ollie/Platform/AppPaths.swift Ollie/Features/Dictation/Runtime/{Ports,RecordingRuntime,PasteRuntime,ShortcutRuntime,ShortcutStateMachine}.swift Ollie/Features/Dictation/Service/AudioCaptureController.swift Ollie/Features/Dictation/Service/AudioBufferConverter.swift Ollie/Features/Dictation/Service/AudioInputSelection.swift Ollie/Features/Dictation/Service/DeepgramLanguage.swift Ollie/Features/Dictation/Service/TranscriptionProvider.swift Ollie/Features/Dictation/Service/EnhancementProvider.swift Ollie/Features/Dictation/Service/ShortcutConfig.swift Ollie/Features/Dictation/Service/Hotkey.swift Ollie/Features/Dictation/Service/RecordingOwnership.swift Ollie/Features/Dictation/Service/ShortcutOwnershipPolicy.swift Ollie/Features/Dictation/Service/StatusModel.swift Ollie/Features/Dictation/Service/LogEntry.swift Ollie/Features/Dictation/Service/DictationSessionState.swift Ollie/Features/Dictation/Service/DictationPreferences.swift Ollie/Features/Dictation/Service/TranscriptHistoryStore.swift Ollie/Features/Dictation/Service/RawRecordingStore.swift Ollie/Features/Dictation/Service/SystemMuteController.swift Ollie/Features/Dictation/Service/TranscriptionReconnectPolicy.swift Ollie/Features/Dictation/Service/String+Trim.swift
run ollie-switcher-test -parse-as-library Ollie/Platform/Diagnostics.swift Ollie/Features/WindowSwitcher/Service/*.swift
run snippet-expansion-test -parse-as-library \
    Ollie/Features/Clipboard/Model/{Snippet,SnippetExpansionPolicy}.swift \
    Ollie/Features/Clipboard/Service/SnippetStore.swift \
    Ollie/Features/Clipboard/Service/SnippetExpansionController.swift \
    Ollie/Features/TextInjection/Service/*.swift \
    Ollie/Features/Quicklinks/Model/QuicklinkTemplateEngine.swift \
    Ollie/DesignSystem/{Theme,InterfaceMetrics,HUDGlassBackground}.swift \
    Ollie/Platform/{Diagnostics,NotificationToken,Appearance,Paster,PasteboardFiles,Permissions,AccessibilityText,CalendarAccess,CameraAccess}.swift
run ollie-clipboard-test -parse-as-library \
    Ollie/Features/Clipboard/Model/*.swift \
    Ollie/Features/Clipboard/Service/ClipboardSearchSession.swift \
    Ollie/Features/Clipboard/Service/OCRService.swift \
    Ollie/Features/Clipboard/Service/ClipboardStore.swift \
    Ollie/Features/Clipboard/Service/ClipboardStorage.swift \
    Ollie/Features/Clipboard/Service/ClipboardWatcher.swift \
    Ollie/Features/Clipboard/Service/ClipboardImageCache.swift \
    Ollie/Platform/Diagnostics.swift \
    Ollie/Features/Clipboard/Service/SnippetStore.swift \
    Ollie/Features/Clipboard/Service/PasteController.swift \
    Ollie/Platform/NotificationToken.swift
run clipboard-coordinator-test -parse-as-library \
    Ollie/Features/Clipboard/Service/ClipboardNavigationDiagnostics.swift \
    Ollie/Features/Clipboard/ClipboardCoordinator.swift \
    Ollie/Features/Clipboard/Model/*.swift \
    Ollie/Features/Clipboard/Service/ClipboardSearchSession.swift \
    Ollie/Features/Clipboard/Service/ClipboardStore.swift \
    Ollie/Features/Clipboard/Service/ClipboardStorage.swift \
    Ollie/Features/Clipboard/Service/ClipboardWatcher.swift \
    Ollie/Features/Clipboard/Service/ClipboardImageCache.swift \
    Ollie/Platform/Diagnostics.swift \
    Ollie/Features/Clipboard/Service/SnippetStore.swift \
    Ollie/Platform/NotificationToken.swift
run media-import-state-test -parse-as-library \
    Ollie/Features/MediaImport/Service/*.swift \
    Ollie/Features/MediaImport/Settings/MediaImportSettingsStore.swift \
    Ollie/Platform/{AppPaths,ProcessExit}.swift
run nettop-lifecycle-test -parse-as-library \
    Ollie/Features/Network/Model/*.swift \
    Ollie/Features/Network/Service/NetTopMonitor.swift \
    Ollie/Platform/ProcessExit.swift
run ollie-services-test -parse-as-library \
    Ollie/Features/TypingSounds/Model/*.swift \
    Ollie/Features/TypingSounds/Service/SoundEngine.swift \
    Ollie/Features/TypingSounds/Service/SoundSamples.swift \
    Ollie/Features/Network/Model/*.swift \
    Ollie/Features/Network/Service/NetTopMonitor.swift \
    Ollie/Features/Network/Service/UsageStore.swift \
    Ollie/Features/Notifications/Model/*.swift \
    Ollie/Features/MediaImport/Service/MediaModels.swift \
    Ollie/Features/MediaImport/Service/ImportSupport.swift \
    Ollie/Features/MediaImport/Service/FFmpegService.swift \
    Ollie/Features/Updates/Model/UpdateReadiness.swift \
    Ollie/Platform/ProcessExit.swift \
    Ollie/Platform/AppPaths.swift
run transcription-timing-test Ollie/Features/Dictation/Model/*.swift
run screen-ink-test Ollie/Features/Dictation/Model/TranscriptSpan.swift Ollie/Features/ScreenNotes/Model/*.swift
run screen-note-clipboard-test Ollie/Features/Dictation/Model/TranscriptSpan.swift Ollie/Features/ScreenNotes/Model/*.swift \
    Ollie/Features/ScreenNotes/Service/ScreenNoteClipboard.swift Ollie/Platform/PasteboardFiles.swift
run -O feature-availability-test -parse-as-library \
    Ollie/Features/Settings/SettingsTab.swift \
    Ollie/Features/Settings/Model/FeatureAvailability.swift \
    Ollie/Features/Settings/Service/FeatureAccess.swift \
    Ollie/Palette/PaletteMode.swift \
    Ollie/Features/Launcher/Model/CommandID.swift \
    Ollie/Features/Launcher/Model/CommandCatalog.swift \
    Ollie/Features/HotKeys/Model/HotKeyAction.swift \
    Ollie/Features/SystemActions/Model/SystemAction.swift \
    Ollie/Features/WindowManagement/Model/WindowCommand.swift \
    Ollie/Features/QuickActions/Model/{QuickAction,BuiltInQuickAction,CustomQuickAction}.swift \
    Ollie/Features/Quicklinks/Model/{Quicklink,QuicklinkDestination}.swift
run -O settings-history-test  Ollie/Features/Settings/SettingsTab.swift \
                           Ollie/Features/Settings/Model/FeatureAvailability.swift \
                           Ollie/Features/Settings/SettingsHistory.swift \
                           Ollie/Features/Settings/SettingsAnchor.swift \
                           Ollie/Features/Settings/SettingsNavigationState.swift \
                           Ollie/Features/Settings/SettingsSearchCatalog.swift \
                           $L/SearchRelevance.swift
run updates-test           Ollie/Features/Updates/Model/*.swift \
                           Ollie/Features/Updates/Service/BundleSignature.swift
run update-check-test      Ollie/Features/Updates/Model/*.swift \
                           Ollie/Features/Updates/Service/UpdateCheckStore.swift \
                           Ollie/Platform/AppPaths.swift
run support-test           Ollie/Features/Support/Model/*.swift
run ai-provider-test       Ollie/Features/Settings/AppSettingsKey.swift \
                           Ollie/Features/AI/Model/*.swift \
                           Ollie/Features/AI/Settings/AISettingsStore.swift
run ai-chat-test           Ollie/Features/AI/Model/AIRequest.swift \
                           Ollie/Features/AI/Model/AIConnection.swift \
                           Ollie/Features/AI/Model/AppleIntelligence.swift \
                           Ollie/Features/AI/Model/AIAttachmentPolicy.swift \
                           Ollie/Features/AI/Model/AIRetention.swift \
                           Ollie/Features/AI/Model/AITool.swift \
                           Ollie/Features/AI/Model/JSONValue.swift \
                           Ollie/Features/AI/Model/ChatMessage.swift \
                           Ollie/Features/AI/Model/ChatSession.swift \
                           Ollie/Features/AI/Model/ChatChoices.swift \
                           Ollie/Features/AI/Model/ChatReferences.swift \
                           Ollie/Features/AI/Model/ChatTitle.swift \
                           Ollie/Features/AI/Model/ChatFind.swift \
                           Ollie/Features/AI/Model/ChatCitations.swift \
                           Ollie/Features/AI/Model/ChatToolScope.swift \
                           Ollie/Features/AI/Model/MarkdownBlock.swift \
                           Ollie/Features/AI/Model/MarkdownMath.swift \
                           Ollie/Features/AI/Model/MathFormula.swift \
                           Ollie/Features/AI/Model/MathNode.swift \
                           Ollie/Features/AI/Model/MathSymbolCatalog.swift \
                           Ollie/Features/AI/Service/AIProvider.swift \
                           Ollie/Features/AI/Service/ChatHistoryStore.swift \
                           Ollie/Features/AI/Service/AIToolLoopProvider.swift \
                           Ollie/Features/AI/UI/AIChatState.swift \
                           Ollie/Features/AI/UI/AIChatSurfacesState.swift \
                           Ollie/Features/AI/UI/ChatFindState.swift
run chat-markdown-test     Ollie/Platform/Appearance.swift \
                           Ollie/DesignSystem/Theme.swift \
                           Ollie/DesignSystem/InterfaceMetrics.swift \
                           Ollie/Features/Settings/InterfaceSize.swift \
                           Ollie/Features/AI/Model/AIRequest.swift \
                           Ollie/Features/AI/Model/AITool.swift \
                           Ollie/Features/AI/Model/JSONValue.swift \
                           Ollie/Features/AI/Model/ChatMessage.swift \
                           Ollie/Features/AI/Model/ChatChoices.swift \
                           Ollie/Features/AI/Model/ChatReferences.swift \
                           Ollie/Features/AI/Model/ChatCitations.swift \
                           Ollie/Features/AI/Model/ChatFind.swift \
                           Ollie/Features/AI/Model/MarkdownBlock.swift \
                           Ollie/Features/AI/Model/MarkdownMath.swift \
                           Ollie/Features/AI/Model/MathFormula.swift \
                           Ollie/Features/AI/Model/MathNode.swift \
                           Ollie/Features/AI/Model/MathSymbolCatalog.swift \
                           Ollie/Features/AI/UI/ChatTextHighlight.swift \
                           Ollie/Features/AI/UI/ChatMarkdownRenderer.swift \
                           Ollie/Features/AI/UI/MathAttachmentCell.swift \
                           Ollie/Features/AI/UI/MathBox.swift \
                           Ollie/Features/AI/UI/MathFont.swift \
                           Ollie/Features/AI/UI/MathLayoutEngine.swift
run mcp-test               Ollie/Features/Settings/AppSettingsKey.swift \
                           Ollie/Features/AI/Model/AIConnection.swift \
                           Ollie/Features/AI/Model/AppleIntelligence.swift \
                           Ollie/Features/AI/Model/AITool.swift \
                           Ollie/Features/AI/Model/AIToolServer.swift \
                           Ollie/Features/AI/Model/JSONValue.swift \
                           Ollie/Features/MCP/Model/*.swift \
                           Ollie/Features/MCP/Settings/MCPSettingsStore.swift
run -O text-diff-test      Ollie/Features/QuickActions/Model/TextDiffEngine.swift
run index text-diff-performance Ollie/Features/QuickActions/Model/TextDiffEngine.swift
run quick-action-test      Ollie/Features/Settings/AppSettingsKey.swift \
                           Ollie/Features/AI/Model/AIConnection.swift \
                           Ollie/Features/AI/Model/AppleIntelligence.swift \
                           Ollie/Features/AI/Model/ChatGPTSubscription.swift \
                           Ollie/Features/AI/Model/InstalledAI.swift \
                           Ollie/Features/QuickActions/Model/*.swift \
                           Ollie/Features/QuickActions/Settings/QuickActionSettingsStore.swift
run apple-intelligence-test Ollie/Features/Settings/AppSettingsKey.swift \
                           Ollie/Features/AI/Model/*.swift \
                           Ollie/Features/AI/Service/AIProvider.swift \
                           Ollie/Features/AI/Service/AppleIntelligenceProvider.swift
run mcp-oauth-test         Ollie/Platform/ExecutableLocator.swift \
                           Ollie/Platform/ProcessExit.swift \
                           Ollie/Platform/KeychainSecretStore.swift \
                           Ollie/Features/Settings/AppSettingsKey.swift \
                           Ollie/Features/AI/Model/AIConnection.swift \
                           Ollie/Features/AI/Model/AppleIntelligence.swift \
                           Ollie/Features/AI/Model/AITool.swift \
                           Ollie/Features/AI/Model/AIToolServer.swift \
                           Ollie/Features/AI/Model/AIStreamDecoder.swift \
                           Ollie/Features/AI/Model/AIThinkTagDecoder.swift \
                           Ollie/Features/AI/Model/AIRequest.swift \
                           Ollie/Features/AI/Model/JSONValue.swift \
                           Ollie/Features/MCP/Model/*.swift \
                           Ollie/Features/MCP/Service/*.swift
run slow mcp-stdio-test    Ollie/Platform/ExecutableLocator.swift \
                           Ollie/Platform/ProcessExit.swift \
                           Ollie/Platform/KeychainSecretStore.swift \
                           Ollie/Features/Settings/AppSettingsKey.swift \
                           Ollie/Features/AI/Model/AIConnection.swift \
                           Ollie/Features/AI/Model/AppleIntelligence.swift \
                           Ollie/Features/AI/Model/AITool.swift \
                           Ollie/Features/AI/Model/AIToolServer.swift \
                           Ollie/Features/AI/Model/AIStreamDecoder.swift \
                           Ollie/Features/AI/Model/AIThinkTagDecoder.swift \
                           Ollie/Features/AI/Model/AIRequest.swift \
                           Ollie/Features/AI/Model/JSONValue.swift \
                           Ollie/Features/MCP/Model/*.swift \
                           Ollie/Features/MCP/Service/*.swift
run slow codex-turn-test   Ollie/Platform/AppPaths.swift \
                           Ollie/Features/AI/Model/*.swift \
                           Ollie/Features/AI/Service/AIProvider.swift \
                           Ollie/Features/AI/Service/ChatGPTSubscriptionManager.swift \
                           Ollie/Features/AI/Service/CodexAppServerClient.swift \
                           Ollie/Features/AI/Service/InstalledAIProbe.swift \
                           Ollie/Platform/ExecutableLocator.swift \
                           Ollie/Platform/ProcessExit.swift \
                           Ollie/Features/AI/Service/CodexTurnRunner.swift
run installed-ai-test     Ollie/Features/AI/Model/*.swift \
                          Ollie/Features/AI/Service/AIProvider.swift \
                          Ollie/Platform/AppPaths.swift \
                          Ollie/Platform/ExecutableLocator.swift \
                          Ollie/Platform/ProcessExit.swift \
                          Ollie/Features/AI/Service/InstalledCLIProvider.swift \
                          Ollie/Features/AI/Service/InstalledAIProbe.swift \
                          Ollie/Features/AI/Service/InstalledAIManager.swift

if [ "$emit_db" -eq 1 ]; then
    printf ']\n' >> "$DB"
    [ -f .compile ] || echo '[]' > .compile
    node -e '
const fs = require("node:fs");
const [comp, db] = process.argv.slice(1);
const existing = JSON.parse(fs.readFileSync(comp, "utf8"));
const harnesses = JSON.parse(fs.readFileSync(db, "utf8"));
const kept = existing.filter((e) => !(e.files || []).some((f) => f.includes("/Tests/")));
fs.writeFileSync(comp, JSON.stringify([...kept, ...harnesses], null, 1));
console.log(harnesses.length + " harness entries indexed into .compile");
' .compile "$DB"
    exit 0
fi

if [ "$ran" -eq 0 ]; then
    echo "No harness named '$only'." >&2
    exit 2
fi

# `sort -s` is stable, so the slow harnesses lead and everything else keeps its declaration order.
JOBS="${OLLIE_TEST_JOBS:-4}"
export OLLIE_TEST_TIMEOUT="${OLLIE_TEST_TIMEOUT:-300}"
started=$SECONDS

# Numbers each result, and names what is still running whenever the output goes quiet.
report() {
    local finished=0 line asked running file
    while :; do
        asked=$SECONDS
        if IFS= read -r -t 15 line; then
            case "$line" in "dispatch "*) return "${line#dispatch }";; esac
            finished=$((finished + 1))
            printf '[%*d/%d] %s\n' "${#ran}" "$finished" "$ran" "$line"
            continue
        fi
        # Bash 3.2 returns the same status for a timeout and EOF; only EOF comes back at once.
        if [ $((SECONDS - asked)) -lt 10 ]; then return 1; fi
        running=""
        for file in "$BIN"/*.running; do
            [ -e "$file" ] && running="$running $(basename "$file" .running)"
        done
        printf '        \033[2mstill running after %ds:%s\033[0m\n' $((SECONDS - started)) "$running"
    done
}

# Without this the suite reports "all passed" whenever dispatch itself dies and no harness ran.
if ! { sort -s -k1,1n "$QUEUE" | cut -d' ' -f2- | xargs -P "$JOBS" -L1 "$SELF" --exec; echo "dispatch $?"; } | report; then
    echo "harness dispatch failed; no result below can be trusted" >&2
    exit 1
fi
elapsed=$((SECONDS - started))

# A compiler diagnostic is far longer than PIPE_BUF, so the workers log it and it is replayed here.
while read -r _ name _; do
    if [ -f "$BIN/$name.failed" ]; then failed+=("$name"); fi
done < "$QUEUE"

if [ ${#failed[@]} -gt 0 ]; then
    for name in "${failed[@]}"; do
        printf '\n\033[31m--- %s ---\033[0m\n' "$name"
        cat "$BIN/$name.log"
    done
    printf '\n\033[31mFAILED\033[0m  %d of %d harness(es) failed in %ds: %s\n' \
        "${#failed[@]}" "$ran" "$elapsed" "${failed[*]}" >&2
    exit 1
fi
printf '\n\033[32mPASSED\033[0m  All %d harness(es) passed in %ds.\n' "$ran" "$elapsed"
