/*
 * Rekordbox Accessibility Test POC - Menu Import + File Dialog
 * compile with: clang++ -framework Foundation -framework ApplicationServices -framework Cocoa rb_test.mm -o rb_test
 *
 * Usage:
 *   ./rb_test dump [depth]                — dump full AX tree
 *   ./rb_test import /path/to/track.mp3   — File > Import > Import Track, inject path
 *   ./rb_test importdir /path/to/folder   — File > Import > Import Folder, inject path
 *   ./rb_test export [device] ["query"]   — Track > Export Track > device (search+select if query given)
 *   ./rb_test dumpwin                     — dump AX tree of frontmost window (use after dialog opens)
 */

#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Cocoa/Cocoa.h>

// ─── Helpers ────────────────────────────────────────────────────

pid_t findRekordboxPID() {
    NSArray* apps = [[NSWorkspace sharedWorkspace] runningApplications];
    pid_t fallback = 0;
    for (NSRunningApplication* app in apps) {
        NSString* name = [app localizedName];
        if ([name isEqualToString:@"rekordbox"]) {
            return [app processIdentifier];  // exact match — the main UI process
        }
        if (!fallback && [name containsString:@"rekordbox"]) {
            fallback = [app processIdentifier];
        }
    }
    return fallback;
}

NSString* getAXAttribute(AXUIElementRef element, CFStringRef attr) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attr, &value) == kAXErrorSuccess && value) {
        NSString* str = [NSString stringWithFormat:@"%@", (__bridge id)value];
        CFRelease(value);
        return str;
    }
    return nil;
}

CGRect getAXFrame(AXUIElementRef element) {
    CGRect frame = CGRectZero;
    CFTypeRef posValue = NULL, sizeValue = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXPositionAttribute, &posValue) == kAXErrorSuccess) {
        CGPoint pos;
        AXValueGetValue((AXValueRef)posValue, (AXValueType)kAXValueCGPointType, &pos);
        frame.origin = pos;
        CFRelease(posValue);
    }
    if (AXUIElementCopyAttributeValue(element, kAXSizeAttribute, &sizeValue) == kAXErrorSuccess) {
        CGSize size;
        AXValueGetValue((AXValueRef)sizeValue, (AXValueType)kAXValueCGSizeType, &size);
        frame.size = size;
        CFRelease(sizeValue);
    }
    return frame;
}

// ─── Tree Dump ──────────────────────────────────────────────────

void dumpAXTree(AXUIElementRef element, int depth, int maxDepth) {
    if (depth > maxDepth) return;

    NSString* indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    NSString* role = getAXAttribute(element, kAXRoleAttribute) ?: @"(no role)";
    NSString* title = getAXAttribute(element, kAXTitleAttribute);
    NSString* desc = getAXAttribute(element, kAXDescriptionAttribute);
    NSString* value = getAXAttribute(element, kAXValueAttribute);
    NSString* subrole = getAXAttribute(element, kAXSubroleAttribute);
    NSString* identifier = getAXAttribute(element, kAXIdentifierAttribute);
    CGRect frame = getAXFrame(element);

    CFArrayRef actions = NULL;
    NSString* actionsStr = @"";
    if (AXUIElementCopyActionNames(element, &actions) == kAXErrorSuccess) {
        actionsStr = [NSString stringWithFormat:@" actions=%@", (__bridge NSArray*)actions];
        CFRelease(actions);
    }

    NSMutableString* info = [NSMutableString stringWithFormat:@"%@[%@]", indent, role];
    if (subrole) [info appendFormat:@" subrole=%@", subrole];
    if (title) [info appendFormat:@" title=\"%@\"", title];
    if (desc) [info appendFormat:@" desc=\"%@\"", desc];
    if (value) [info appendFormat:@" value=\"%@\"", value];
    if (identifier) [info appendFormat:@" id=\"%@\"", identifier];
    if (!CGRectIsEmpty(frame)) [info appendFormat:@" frame=(%.0f,%.0f %.0fx%.0f)", frame.origin.x, frame.origin.y, frame.size.width, frame.size.height];
    [info appendString:actionsStr];

    NSLog(@"%@", info);

    CFArrayRef children = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, (CFTypeRef*)&children) == kAXErrorSuccess && children) {
        CFIndex count = CFArrayGetCount(children);
        for (CFIndex i = 0; i < count; ++i) {
            dumpAXTree((AXUIElementRef)CFArrayGetValueAtIndex(children, i), depth + 1, maxDepth);
        }
        CFRelease(children);
    }
}

// ─── Menu Navigation ────────────────────────────────────────────

// Find a child element by role and title (exact match)
AXUIElementRef findChildByTitle(AXUIElementRef parent, NSString* role, NSString* title) {
    CFArrayRef children = NULL;
    if (AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute, (CFTypeRef*)&children) != kAXErrorSuccess || !children) {
        return NULL;
    }

    CFIndex count = CFArrayGetCount(children);
    for (CFIndex i = 0; i < count; ++i) {
        AXUIElementRef child = (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
        NSString* childRole = getAXAttribute(child, kAXRoleAttribute);
        NSString* childTitle = getAXAttribute(child, kAXTitleAttribute);

        if ([childRole isEqualToString:role] && [childTitle isEqualToString:title]) {
            CFRetain(child);
            CFRelease(children);
            return child;
        }

        // If this child is a menu container, search inside it too
        if ([childRole isEqualToString:@"AXMenu"]) {
            AXUIElementRef found = findChildByTitle(child, role, title);
            if (found) {
                CFRelease(children);
                return found;
            }
        }
    }
    CFRelease(children);
    return NULL;
}

// Walk menu path: File > Import > Import Track (or Import Folder)
bool navigateMenu(AXUIElementRef appRef, NSString* menuItemTitle) {
    // Step 1: Find the menu bar
    CFTypeRef menuBar = NULL;
    AXError err = AXUIElementCopyAttributeValue(appRef, kAXMenuBarAttribute, &menuBar);
    if (err != kAXErrorSuccess || !menuBar) {
        NSLog(@"ERROR: Cannot access menu bar (error %d)", err);
        return false;
    }
    NSLog(@"[1/4] Found menu bar");

    // Step 2: Find "File" menu bar item and press it
    AXUIElementRef fileItem = findChildByTitle((AXUIElementRef)menuBar, @"AXMenuBarItem", @"File");
    CFRelease(menuBar);
    if (!fileItem) {
        NSLog(@"ERROR: 'File' menu bar item not found");
        return false;
    }
    NSLog(@"[2/4] Found 'File' menu item — pressing...");
    err = (AXError)AXUIElementPerformAction(fileItem, kAXPressAction);
    if (err != kAXErrorSuccess) {
        NSLog(@"ERROR: AXPress on 'File' failed (error %d)", err);
        CFRelease(fileItem);
        return false;
    }
    usleep(200000);  // 200ms for menu to open

    // Step 3: Find "Import" submenu within File's children and press it
    // After pressing File, its children now include the opened AXMenu
    AXUIElementRef importItem = findChildByTitle(fileItem, @"AXMenuItem", @"Import");
    CFRelease(fileItem);
    if (!importItem) {
        NSLog(@"ERROR: 'Import' menu item not found inside File menu");
        // Cancel the menu
        AXUIElementPerformAction((AXUIElementRef)menuBar, kAXCancelAction);
        return false;
    }
    NSLog(@"[3/4] Found 'Import' submenu — pressing...");
    err = (AXError)AXUIElementPerformAction(importItem, kAXPressAction);
    if (err != kAXErrorSuccess) {
        NSLog(@"ERROR: AXPress on 'Import' failed (error %d)", err);
        CFRelease(importItem);
        return false;
    }
    usleep(200000);  // 200ms for submenu to open

    // Step 4: Find target item (e.g. "Import Track" or "Import Folder")
    AXUIElementRef targetItem = findChildByTitle(importItem, @"AXMenuItem", menuItemTitle);
    CFRelease(importItem);
    if (!targetItem) {
        NSLog(@"ERROR: '%@' not found inside Import submenu", menuItemTitle);
        return false;
    }
    NSLog(@"[4/4] Found '%@' — pressing...", menuItemTitle);
    err = (AXError)AXUIElementPerformAction(targetItem, kAXPressAction);
    CFRelease(targetItem);
    if (err != kAXErrorSuccess) {
        NSLog(@"ERROR: AXPress on '%@' failed (error %d)", menuItemTitle, err);
        return false;
    }

    NSLog(@"Menu action triggered! Waiting for file dialog...");
    return true;
}

// ─── Browser Search ─────────────────────────────────────────────

// Perform a search in the browser area: press search button, find field, inject text.
// Returns true if text was successfully injected.
bool performBrowserSearch(AXUIElementRef appRef, NSString* searchText) {
    // Step 1: Focus the search field by sending Cmd+F to Rekordbox.
    // CGEventPostToPSN targets the process directly (works in background).
    // JUCE browser elements aren't linked in the AX children hierarchy,
    // but become accessible via kAXFocusedUIElementAttribute once focused.
    NSLog(@"[1/2] Focusing search field via Cmd+F...");

    pid_t pid = 0;
    AXUIElementGetPid(appRef, &pid);
    if (!pid) {
        NSLog(@"ERROR: Cannot get PID from app element");
        return false;
    }

    ProcessSerialNumber psn;
    GetProcessForPID(pid, &psn);

    CGEventRef cmdFDown = CGEventCreateKeyboardEvent(NULL, 3 /*kVK_F*/, true);
    CGEventSetFlags(cmdFDown, kCGEventFlagMaskCommand);
    CGEventRef cmdFUp = CGEventCreateKeyboardEvent(NULL, 3, false);
    CGEventSetFlags(cmdFUp, kCGEventFlagMaskCommand);
    CGEventPostToPSN(&psn, cmdFDown);
    usleep(50000);
    CGEventPostToPSN(&psn, cmdFUp);
    CFRelease(cmdFDown);
    CFRelease(cmdFUp);
    usleep(500000);

    // Get the focused element — should be the AXTextArea search field
    AXUIElementRef searchField = NULL;
    CFTypeRef focused = NULL;
    if (AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute, &focused) == kAXErrorSuccess && focused) {
        NSString* role = getAXAttribute((AXUIElementRef)focused, kAXRoleAttribute);
        if ([role isEqualToString:@"AXTextArea"]) {
            searchField = (AXUIElementRef)focused;
            CFRetain(searchField);
        }
        CFRelease(focused);
    }

    if (!searchField) {
        NSLog(@"ERROR: Cmd+F did not focus the search text field");
        return false;
    }
    NSLog(@"  Search field focused: [AXTextArea]");

    // Step 2: Inject text
    {
        NSLog(@"[2/2] Injecting text into search field...");

        AXError setErr = AXUIElementSetAttributeValue(searchField, kAXValueAttribute,
                                                       (__bridge CFTypeRef)searchText);
        if (setErr == kAXErrorSuccess) {
            NSLog(@"  SUCCESS: Text injected via AXValue: \"%@\"", searchText);
        } else {
            NSLog(@"  AXValue failed (err %d). Trying focus + AXSelectedText...", setErr);

            AXUIElementSetAttributeValue(searchField, kAXFocusedAttribute, kCFBooleanTrue);
            usleep(200000);

            NSLog(@"  Sending Cmd+A to select all...");
            CGEventRef cmdA = CGEventCreateKeyboardEvent(NULL, 0 /*a*/, true);
            CGEventSetFlags(cmdA, kCGEventFlagMaskCommand);
            CGEventPostToPSN(&psn, cmdA);
            CFRelease(cmdA);
            usleep(100000);

            NSLog(@"  Typing \"%@\" via keystrokes...", searchText);
            for (NSUInteger i = 0; i < [searchText length]; i++) {
                unichar ch = [searchText characterAtIndex:i];
                CGEventRef keyDown = CGEventCreateKeyboardEvent(NULL, 0, true);
                CGEventRef keyUp = CGEventCreateKeyboardEvent(NULL, 0, false);
                CGEventKeyboardSetUnicodeString(keyDown, 1, &ch);
                CGEventKeyboardSetUnicodeString(keyUp, 1, &ch);
                CGEventPostToPSN(&psn, keyDown);
                usleep(10000);
                CGEventPostToPSN(&psn, keyUp);
                usleep(10000);
                CFRelease(keyDown);
                CFRelease(keyUp);
            }
            NSLog(@"  Text typed via keystrokes.");
        }

        usleep(300000);
        NSString* resultValue = getAXAttribute(searchField, kAXValueAttribute);
        NSLog(@"  Search field value after injection: \"%@\"", resultValue);

        // Ensure the search field retains focus so Tab can move from it
        AXUIElementSetAttributeValue(searchField, kAXFocusedAttribute, kCFBooleanTrue);
        usleep(100000);

        CFRelease(searchField);
        return true;
    }
}

// ─── Browser Row Selection ──────────────────────────────────────

// After a search, select the first track row in the browser results.
// Returns true if a row was successfully selected.
bool selectFirstBrowserRow(AXUIElementRef appRef) {
    NSLog(@"Looking for track row to select...");

    // Rekordbox track rows are custom-rendered AXGroups with no children/actions.
    // But Tab from the search field moves focus to the first row.
    // AXUIElementPostKeyboardEvent sends keys directly to the process (works in background).
    NSLog(@"  Sending Tab key to Rekordbox to focus first row...");
    AXError tabDown = AXUIElementPostKeyboardEvent(appRef, 0, 48 /*kVK_Tab*/, true);
    usleep(50000);
    AXError tabUp = AXUIElementPostKeyboardEvent(appRef, 0, 48, false);

    if (tabDown != kAXErrorSuccess || tabUp != kAXErrorSuccess) {
        NSLog(@"ERROR: Failed to send Tab key (down=%d up=%d)", tabDown, tabUp);
        return false;
    }

    usleep(300000);  // 300ms for focus to move
    NSLog(@"  Tab sent — first row should be focused/selected.");
    return true;
}

// ─── Export Menu Navigation ─────────────────────────────────────

// Walk menu path: Track > Export Track > [deviceName]
// If deviceName is nil, lists available devices and returns false.
bool navigateExportMenu(AXUIElementRef appRef, NSString* deviceName) {
    // Step 1: Find the menu bar
    CFTypeRef menuBar = NULL;
    AXError err = AXUIElementCopyAttributeValue(appRef, kAXMenuBarAttribute, &menuBar);
    if (err != kAXErrorSuccess || !menuBar) {
        NSLog(@"ERROR: Cannot access menu bar (error %d)", err);
        return false;
    }
    NSLog(@"[1/4] Found menu bar");

    // Step 2: Find "Track" menu bar item and press it
    AXUIElementRef trackItem = findChildByTitle((AXUIElementRef)menuBar, @"AXMenuBarItem", @"Track");
    CFRelease(menuBar);
    if (!trackItem) {
        NSLog(@"ERROR: 'Track' menu bar item not found");
        return false;
    }
    NSLog(@"[2/4] Found 'Track' menu item — pressing...");
    err = (AXError)AXUIElementPerformAction(trackItem, kAXPressAction);
    if (err != kAXErrorSuccess) {
        NSLog(@"ERROR: AXPress on 'Track' failed (error %d)", err);
        CFRelease(trackItem);
        return false;
    }
    usleep(200000);  // 200ms for menu to open

    // Step 3: Find "Export Track" submenu and press it
    AXUIElementRef exportItem = findChildByTitle(trackItem, @"AXMenuItem", @"Export Track");
    CFRelease(trackItem);
    if (!exportItem) {
        NSLog(@"ERROR: 'Export Track' menu item not found inside Track menu");
        return false;
    }
    NSLog(@"[3/4] Found 'Export Track' submenu — pressing...");
    err = (AXError)AXUIElementPerformAction(exportItem, kAXPressAction);
    if (err != kAXErrorSuccess) {
        NSLog(@"ERROR: AXPress on 'Export Track' failed (error %d)", err);
        CFRelease(exportItem);
        return false;
    }
    usleep(200000);  // 200ms for submenu to open

    // If no device name given, list available devices and return
    if (!deviceName) {
        NSLog(@"Available export devices:");
        CFArrayRef children = NULL;
        if (AXUIElementCopyAttributeValue(exportItem, kAXChildrenAttribute, (CFTypeRef*)&children) == kAXErrorSuccess && children) {
            CFIndex count = CFArrayGetCount(children);
            for (CFIndex i = 0; i < count; ++i) {
                AXUIElementRef child = (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
                NSString* childRole = getAXAttribute(child, kAXRoleAttribute);
                NSString* childTitle = getAXAttribute(child, kAXTitleAttribute);
                if ([childRole isEqualToString:@"AXMenuItem"] || [childRole isEqualToString:@"AXMenu"]) {
                    // Check inside AXMenu containers too
                    if ([childRole isEqualToString:@"AXMenu"]) {
                        CFArrayRef subItems = NULL;
                        if (AXUIElementCopyAttributeValue(child, kAXChildrenAttribute, (CFTypeRef*)&subItems) == kAXErrorSuccess && subItems) {
                            CFIndex subCount = CFArrayGetCount(subItems);
                            for (CFIndex j = 0; j < subCount; ++j) {
                                AXUIElementRef subItem = (AXUIElementRef)CFArrayGetValueAtIndex(subItems, j);
                                NSString* subTitle = getAXAttribute(subItem, kAXTitleAttribute);
                                NSString* subEnabled = getAXAttribute(subItem, kAXEnabledAttribute);
                                if (subTitle && [subTitle length] > 0) {
                                    NSLog(@"  [%ld] \"%@\" (enabled=%@)", j, subTitle, subEnabled);
                                }
                            }
                            CFRelease(subItems);
                        }
                    } else if (childTitle && [childTitle length] > 0) {
                        NSLog(@"  \"%@\"", childTitle);
                    }
                }
            }
            CFRelease(children);
        }
        // Cancel the menu
        CGEventRef escape = CGEventCreateKeyboardEvent(NULL, 53 /*Escape*/, true);
        CGEventPost(kCGHIDEventTap, escape);
        CFRelease(escape);
        CFRelease(exportItem);
        return false;
    }

    // Step 4: Find the target device and press it
    AXUIElementRef deviceItem = findChildByTitle(exportItem, @"AXMenuItem", deviceName);
    CFRelease(exportItem);
    if (!deviceItem) {
        NSLog(@"ERROR: Device '%@' not found in Export Track submenu", deviceName);
        NSLog(@"TIP: Run './rb_test export' without a device name to list available devices.");
        // Cancel the menu
        CGEventRef escape = CGEventCreateKeyboardEvent(NULL, 53, true);
        CGEventPost(kCGHIDEventTap, escape);
        CFRelease(escape);
        return false;
    }
    NSLog(@"[4/4] Found device '%@' — pressing...", deviceName);
    err = (AXError)AXUIElementPerformAction(deviceItem, kAXPressAction);
    CFRelease(deviceItem);
    if (err != kAXErrorSuccess) {
        NSLog(@"ERROR: AXPress on device '%@' failed (error %d)", deviceName, err);
        return false;
    }

    NSLog(@"Export to '%@' triggered!", deviceName);
    return true;
}

// ─── File Dialog Interaction ────────────────────────────────────

// Recursively find an element by role (first match)
AXUIElementRef findElementByRole(AXUIElementRef element, NSString* targetRole, int depth) {
    if (depth > 15) return NULL;

    NSString* role = getAXAttribute(element, kAXRoleAttribute);
    if ([role isEqualToString:targetRole]) {
        CFRetain(element);
        return element;
    }

    CFArrayRef children = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, (CFTypeRef*)&children) == kAXErrorSuccess && children) {
        CFIndex count = CFArrayGetCount(children);
        for (CFIndex i = 0; i < count; ++i) {
            AXUIElementRef found = findElementByRole((AXUIElementRef)CFArrayGetValueAtIndex(children, i), targetRole, depth + 1);
            if (found) {
                CFRelease(children);
                return found;
            }
        }
        CFRelease(children);
    }
    return NULL;
}

// Recursively find an element by subrole
AXUIElementRef findElementBySubrole(AXUIElementRef element, NSString* targetSubrole, int depth) {
    if (depth > 15) return NULL;

    NSString* subrole = getAXAttribute(element, kAXSubroleAttribute);
    if ([subrole isEqualToString:targetSubrole]) {
        CFRetain(element);
        return element;
    }

    CFArrayRef children = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, (CFTypeRef*)&children) == kAXErrorSuccess && children) {
        CFIndex count = CFArrayGetCount(children);
        for (CFIndex i = 0; i < count; ++i) {
            AXUIElementRef found = findElementBySubrole((AXUIElementRef)CFArrayGetValueAtIndex(children, i), targetSubrole, depth + 1);
            if (found) {
                CFRelease(children);
                return found;
            }
        }
        CFRelease(children);
    }
    return NULL;
}

// Find all text fields in an element tree
void findAllTextFields(AXUIElementRef element, NSMutableArray* results, int depth) {
    if (depth > 15) return;

    NSString* role = getAXAttribute(element, kAXRoleAttribute);
    if ([role isEqualToString:@"AXTextField"] || [role isEqualToString:@"AXComboBox"]) {
        [results addObject:(__bridge id)element];
    }

    CFArrayRef children = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, (CFTypeRef*)&children) == kAXErrorSuccess && children) {
        CFIndex count = CFArrayGetCount(children);
        for (CFIndex i = 0; i < count; ++i) {
            findAllTextFields((AXUIElementRef)CFArrayGetValueAtIndex(children, i), results, depth + 1);
        }
        CFRelease(children);
    }
}

// Find the file dialog (AXSheet or AXWindow with AXDialog subrole) and interact with it
bool interactWithFileDialog(AXUIElementRef appRef, NSString* filePath) {
    NSLog(@"Looking for file dialog...");

    // The file dialog appears as a new AXSheet or AXWindow on the app
    // Try multiple times with delays since the dialog may take time to appear
    AXUIElementRef dialog = NULL;
    for (int attempt = 0; attempt < 10; attempt++) {
        usleep(300000);  // 300ms between attempts

        // Check all windows for a sheet or dialog
        CFArrayRef windows = NULL;
        if (AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, (CFTypeRef*)&windows) == kAXErrorSuccess && windows) {
            CFIndex count = CFArrayGetCount(windows);
            NSLog(@"  Attempt %d: found %ld windows", attempt + 1, count);

            for (CFIndex i = 0; i < count; i++) {
                AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
                NSString* subrole = getAXAttribute(win, kAXSubroleAttribute);
                NSString* role = getAXAttribute(win, kAXRoleAttribute);
                NSString* title = getAXAttribute(win, kAXTitleAttribute);
                NSLog(@"    Window %ld: role=%@ subrole=%@ title=\"%@\"", i, role, subrole, title);

                // NSOpenPanel typically appears as AXDialog or as a sheet
                if ([subrole isEqualToString:@"AXDialog"] ||
                    [subrole isEqualToString:@"AXFloatingWindow"] ||
                    (title && ([title containsString:@"Open"] ||
                               [title containsString:@"Import"] ||
                               [title containsString:@"Choose"]))) {
                    CFRetain(win);
                    dialog = win;
                    break;
                }
            }
            CFRelease(windows);
        }

        // Also check for sheets attached to main window
        if (!dialog) {
            CFArrayRef mainWindows = NULL;
            if (AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, (CFTypeRef*)&mainWindows) == kAXErrorSuccess && mainWindows) {
                CFIndex count = CFArrayGetCount(mainWindows);
                for (CFIndex i = 0; i < count; i++) {
                    AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(mainWindows, i);
                    // Check for sheets
                    CFArrayRef sheets = NULL;
                    if (AXUIElementCopyAttributeValue(win, CFSTR("AXSheets"), (CFTypeRef*)&sheets) == kAXErrorSuccess && sheets) {
                        if (CFArrayGetCount(sheets) > 0) {
                            dialog = (AXUIElementRef)CFArrayGetValueAtIndex(sheets, 0);
                            CFRetain(dialog);
                            NSLog(@"  Found sheet attached to window!");
                        }
                        CFRelease(sheets);
                    }
                }
                CFRelease(mainWindows);
            }
        }

        if (dialog) break;
    }

    if (!dialog) {
        NSLog(@"ERROR: File dialog did not appear after 3 seconds.");
        NSLog(@"TIP: Run './rb_test dumpwin' while dialog is open to inspect its structure.");
        return false;
    }

    NSLog(@"Found file dialog! Dumping its structure...");
    dumpAXTree(dialog, 0, 6);

    // Strategy: Find the path text field in the dialog
    // NSOpenPanel has a "Go to folder" shortcut: Cmd+Shift+G which opens a path text field
    // Alternatively, we can look for existing text fields

    NSLog(@"\n=== Attempting path injection ===");

    // First, find text fields already visible in the dialog
    NSMutableArray* textFields = [NSMutableArray array];
    findAllTextFields(dialog, textFields, 0);
    NSLog(@"Found %lu text field(s) in dialog", (unsigned long)[textFields count]);

    if ([textFields count] > 0) {
        // Try the first text field — often the filename/path field
        AXUIElementRef pathField = (__bridge AXUIElementRef)[textFields objectAtIndex:0];
        NSString* currentValue = getAXAttribute(pathField, kAXValueAttribute);
        NSLog(@"  Text field current value: \"%@\"", currentValue);

        // Try to set the path
        AXError setErr = AXUIElementSetAttributeValue(pathField, kAXValueAttribute,
                                                       (__bridge CFTypeRef)filePath);
        if (setErr == kAXErrorSuccess) {
            NSLog(@"  Path injected via AXValue: %@", filePath);
        } else {
            NSLog(@"  AXValue injection failed (err %d). Trying focus + keystroke...", setErr);

            // Focus the field
            AXUIElementSetAttributeValue(pathField, kAXFocusedAttribute, kCFBooleanTrue);
            usleep(100000);

            // Select all existing text (Cmd+A) then type the path
            CGEventRef selectAll = CGEventCreateKeyboardEvent(NULL, 0, true);  // 'a' keycode
            CGEventSetFlags(selectAll, kCGEventFlagMaskCommand);
            CGEventPost(kCGHIDEventTap, selectAll);
            CFRelease(selectAll);
            usleep(50000);

            // Type the path character by character
            for (NSUInteger i = 0; i < [filePath length]; i++) {
                unichar ch = [filePath characterAtIndex:i];
                CGEventRef keyDown = CGEventCreateKeyboardEvent(NULL, 0, true);
                CGEventRef keyUp = CGEventCreateKeyboardEvent(NULL, 0, false);
                CGEventKeyboardSetUnicodeString(keyDown, 1, &ch);
                CGEventKeyboardSetUnicodeString(keyUp, 1, &ch);
                CGEventPost(kCGHIDEventTap, keyDown);
                usleep(5000);
                CGEventPost(kCGHIDEventTap, keyUp);
                usleep(5000);
                CFRelease(keyDown);
                CFRelease(keyUp);
            }
            NSLog(@"  Path typed via keystrokes: %@", filePath);
        }

        // Now try to confirm — press the "Open" / "Import" button
        usleep(200000);
        NSLog(@"\n=== Looking for confirmation button ===");

        // Search for buttons with typical confirm titles
        CFArrayRef dialogChildren = NULL;
        if (AXUIElementCopyAttributeValue(dialog, kAXChildrenAttribute, (CFTypeRef*)&dialogChildren) == kAXErrorSuccess && dialogChildren) {
            CFRelease(dialogChildren);
        }

        // Try to find "Open", "Import", or default button
        AXUIElementRef confirmBtn = findChildByTitle(dialog, @"AXButton", @"Open");
        if (!confirmBtn) confirmBtn = findChildByTitle(dialog, @"AXButton", @"Import");
        if (!confirmBtn) confirmBtn = findChildByTitle(dialog, @"AXButton", @"Choose");
        if (!confirmBtn) {
            // Try finding the default button
            CFTypeRef defaultBtn = NULL;
            if (AXUIElementCopyAttributeValue(dialog, kAXDefaultButtonAttribute, &defaultBtn) == kAXErrorSuccess && defaultBtn) {
                confirmBtn = (AXUIElementRef)defaultBtn;
                // Don't release, we're using it
            }
        }

        if (confirmBtn) {
            NSString* btnTitle = getAXAttribute(confirmBtn, kAXTitleAttribute);
            NSLog(@"  Found confirm button: \"%@\" — NOT pressing (dry run). Pass '--confirm' to press.", btnTitle);
            // Uncomment to actually press:
            // AXUIElementPerformAction(confirmBtn, kAXPressAction);
            CFRelease(confirmBtn);
        } else {
            NSLog(@"  No confirm button found. You may need to press Enter manually.");
        }
    } else {
        NSLog(@"  No text fields found in dialog. Try Cmd+Shift+G to open 'Go to folder'.");
        NSLog(@"  Run './rb_test dumpwin' while dialog is open for full inspection.");
    }

    CFRelease(dialog);
    return true;
}

// ─── Main ───────────────────────────────────────────────────────

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSString* mode = @"help";
        if (argc > 1) {
            mode = [NSString stringWithUTF8String:argv[1]];
        }

        int maxDumpDepth = 4;
        if (argc > 2 && [mode isEqualToString:@"dump"]) {
            maxDumpDepth = atoi(argv[2]);
        }

        NSLog(@"Checking Accessibility Permissions...");
        NSDictionary* options = @{(id)kAXTrustedCheckOptionPrompt: @YES};
        if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) {
            NSLog(@"ERROR: No Accessibility Permissions. Allow in System Settings > Privacy > Accessibility.");
            return 1;
        }

        pid_t pid = findRekordboxPID();
        if (pid == 0) {
            NSLog(@"ERROR: Rekordbox is not running.");
            return 1;
        }
        NSLog(@"Found Rekordbox (PID: %d)", pid);

        AXUIElementRef appRef = AXUIElementCreateApplication(pid);

        // ── Mode: Dump ──
        if ([mode isEqualToString:@"dump"]) {
            NSLog(@"=== AX TREE DUMP (depth %d) ===", maxDumpDepth);
            dumpAXTree(appRef, 0, maxDumpDepth);
            NSLog(@"=== END DUMP ===");
        }
        // ── Mode: Dump current windows (use when dialog is open) ──
        else if ([mode isEqualToString:@"dumpwin"]) {
            int depth = (argc > 2) ? atoi(argv[2]) : 8;
            NSLog(@"=== DUMPING ALL WINDOWS (depth %d) ===", depth);
            CFArrayRef windows = NULL;
            if (AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, (CFTypeRef*)&windows) == kAXErrorSuccess && windows) {
                CFIndex count = CFArrayGetCount(windows);
                for (CFIndex i = 0; i < count; i++) {
                    AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
                    NSString* title = getAXAttribute(win, kAXTitleAttribute);
                    NSString* subrole = getAXAttribute(win, kAXSubroleAttribute);
                    NSLog(@"--- Window %ld: title=\"%@\" subrole=%@ ---", i, title, subrole);
                    dumpAXTree(win, 0, depth);
                }
                CFRelease(windows);
            }
            NSLog(@"=== END DUMP ===");
        }
        // ── Mode: Import Track ──
        else if ([mode isEqualToString:@"import"]) {
            NSString* filePath = (argc > 2) ? [NSString stringWithUTF8String:argv[2]] : @"/tmp/test.mp3";
            NSLog(@"=== IMPORT TRACK: %@ ===", filePath);

            if (navigateMenu(appRef, @"Import Track")) {
                usleep(500000);  // 500ms for dialog to fully appear
                interactWithFileDialog(appRef, filePath);
            }
        }
        // ── Mode: Import Folder ──
        else if ([mode isEqualToString:@"importdir"]) {
            NSString* folderPath = (argc > 2) ? [NSString stringWithUTF8String:argv[2]] : @"/tmp";
            NSLog(@"=== IMPORT FOLDER: %@ ===", folderPath);

            if (navigateMenu(appRef, @"Import Folder")) {
                usleep(500000);  // 500ms for dialog to fully appear
                interactWithFileDialog(appRef, folderPath);
            }
        }
        // ── Mode: Export Track to device ──
        else if ([mode isEqualToString:@"export"]) {
            NSString* deviceName = (argc > 2) ? [NSString stringWithUTF8String:argv[2]] : nil;
            NSString* trackQuery = (argc > 3) ? [NSString stringWithUTF8String:argv[3]] : nil;

            if (!deviceName) {
                NSLog(@"=== EXPORT TRACK: listing available devices ===");
                navigateExportMenu(appRef, nil);
            } else if (!trackQuery) {
                // Export currently selected track
                NSLog(@"=== EXPORT SELECTED TRACK TO: %@ ===", deviceName);
                navigateExportMenu(appRef, deviceName);
            } else {
                // Full flow: search → select → export
                NSLog(@"=== EXPORT TRACK \"%@\" TO: %@ ===", trackQuery, deviceName);

                // Step 1: Search for the track
                NSLog(@"--- Step 1: Search for track ---");
                if (!performBrowserSearch(appRef, trackQuery)) {
                    NSLog(@"ERROR: Search failed, aborting export.");
                    CFRelease(appRef);
                    return 1;
                }
                usleep(500000);  // 500ms for search results to populate

                // Step 2: Select the first result row
                NSLog(@"--- Step 2: Select track row ---");
                if (!selectFirstBrowserRow(appRef)) {
                    NSLog(@"ERROR: Could not select track row, aborting export.");
                    CFRelease(appRef);
                    return 1;
                }
                usleep(300000);  // 300ms for selection to settle

                // Step 3: Export via menu
                NSLog(@"--- Step 3: Export to device ---");
                navigateExportMenu(appRef, deviceName);
            }
        }
        // ── Mode: Menu only (just open menu, don't interact with dialog) ──
        else if ([mode isEqualToString:@"menutest"]) {
            NSString* target = (argc > 2) ? [NSString stringWithUTF8String:argv[2]] : @"Import Track";
            NSLog(@"=== MENU TEST: File > Import > %@ ===", target);
            navigateMenu(appRef, target);
            NSLog(@"Menu action complete. Dialog should be open now.");
            NSLog(@"Run './rb_test dumpwin' in another terminal to inspect the dialog.");
        }
        // ── Mode: Probe browser area by screen coordinates ──
        else if ([mode isEqualToString:@"probe"]) {
            NSLog(@"=== PROBING BROWSER AREA BY COORDINATES ===");

            // Get the main window frame to calculate browser region
            CFArrayRef windows = NULL;
            CGRect winFrame = CGRectZero;
            if (AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, (CFTypeRef*)&windows) == kAXErrorSuccess && windows) {
                if (CFArrayGetCount(windows) > 0) {
                    winFrame = getAXFrame((AXUIElementRef)CFArrayGetValueAtIndex(windows, 0));
                }
                CFRelease(windows);
            }
            NSLog(@"Window frame: (%.0f,%.0f %.0fx%.0f)", winFrame.origin.x, winFrame.origin.y, winFrame.size.width, winFrame.size.height);

            // Browser area is roughly the bottom 40% of the window
            float browserTop = winFrame.origin.y + winFrame.size.height * 0.6;
            float browserBottom = winFrame.origin.y + winFrame.size.height - 30;  // above status bar
            float browserLeft = winFrame.origin.x + 10;
            float browserRight = winFrame.origin.x + winFrame.size.width - 10;

            NSLog(@"Scanning browser region: y=%.0f to y=%.0f", browserTop, browserBottom);

            // Probe a grid of points in the browser area using AXUIElementCopyElementAtPosition
            // This bypasses tree traversal entirely — asks the system "what's at this pixel?"
            NSMutableSet* foundTitles = [NSMutableSet set];
            float stepX = 50, stepY = 20;

            for (float y = browserTop; y < browserBottom; y += stepY) {
                for (float x = browserLeft; x < browserRight; x += stepX) {
                    AXUIElementRef hitElement = NULL;
                    AXError err = AXUIElementCopyElementAtPosition(appRef, x, y, &hitElement);
                    if (err == kAXErrorSuccess && hitElement) {
                        NSString* role = getAXAttribute(hitElement, kAXRoleAttribute);
                        NSString* title = getAXAttribute(hitElement, kAXTitleAttribute);
                        NSString* value = getAXAttribute(hitElement, kAXValueAttribute);
                        NSString* help = getAXAttribute(hitElement, kAXHelpAttribute);
                        CGRect frame = getAXFrame(hitElement);

                        // Create a unique key to avoid duplicates
                        NSString* key = [NSString stringWithFormat:@"%@|%@|%.0f,%.0f",
                                         role, title ?: value ?: @"", frame.origin.x, frame.origin.y];
                        if (![foundTitles containsObject:key]) {
                            [foundTitles addObject:key];
                            NSLog(@"  HIT (%.0f,%.0f): [%@] title=\"%@\" value=\"%@\" help=\"%@\" frame=(%.0f,%.0f %.0fx%.0f)",
                                  x, y, role, title, value, help,
                                  frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);

                            // If this looks search-related, dump its subtree
                            if ((title && [title rangeOfString:@"Search" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                                (help && [help rangeOfString:@"Search" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
                                NSLog(@"    >>> SEARCH ELEMENT FOUND! Dumping subtree:");
                                dumpAXTree(hitElement, 0, 4);
                            }
                        }
                        CFRelease(hitElement);
                    }
                }
            }
            NSLog(@"Probe complete. Found %lu unique elements.", (unsigned long)[foundTitles count]);

            // Also try the exact coordinates from the Accessibility Inspector
            NSLog(@"\n=== DIRECT COORDINATE HITS ===");
            // Search button was at (2430, 613) in inspector - but that might be scaled
            // Try the browser area center
            float centerX = winFrame.origin.x + winFrame.size.width / 2;
            float centerY = browserTop + 30;  // near top of browser

            CGPoint probePoints[] = {
                {centerX, centerY},
                {centerX, browserTop + 10},
                {centerX, browserTop + 50},
                {browserLeft + 100, browserTop + 10},  // left side (tree view?)
                {browserLeft + 100, browserTop + 50},
            };
            int numPoints = sizeof(probePoints) / sizeof(probePoints[0]);

            for (int i = 0; i < numPoints; i++) {
                AXUIElementRef hitElement = NULL;
                AXError err = AXUIElementCopyElementAtPosition(appRef, probePoints[i].x, probePoints[i].y, &hitElement);
                if (err == kAXErrorSuccess && hitElement) {
                    NSString* role = getAXAttribute(hitElement, kAXRoleAttribute);
                    NSString* title = getAXAttribute(hitElement, kAXTitleAttribute);
                    NSString* value = getAXAttribute(hitElement, kAXValueAttribute);
                    NSString* help = getAXAttribute(hitElement, kAXHelpAttribute);
                    CGRect frame = getAXFrame(hitElement);
                    NSLog(@"  Point (%.0f,%.0f) → [%@] title=\"%@\" value=\"%@\" help=\"%@\" frame=(%.0f,%.0f %.0fx%.0f)",
                          probePoints[i].x, probePoints[i].y,
                          role, title, value, help,
                          frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);

                    // Walk up the parent chain to understand the hierarchy
                    NSLog(@"    Parent chain:");
                    AXUIElementRef current = hitElement;
                    CFRetain(current);
                    for (int depth = 0; depth < 5; depth++) {
                        CFTypeRef parent = NULL;
                        if (AXUIElementCopyAttributeValue(current, kAXParentAttribute, &parent) == kAXErrorSuccess && parent) {
                            NSString* pRole = getAXAttribute((AXUIElementRef)parent, kAXRoleAttribute);
                            NSString* pTitle = getAXAttribute((AXUIElementRef)parent, kAXTitleAttribute);
                            CGRect pFrame = getAXFrame((AXUIElementRef)parent);
                            NSLog(@"      %d: [%@] title=\"%@\" frame=(%.0f,%.0f %.0fx%.0f)",
                                  depth, pRole, pTitle, pFrame.origin.x, pFrame.origin.y, pFrame.size.width, pFrame.size.height);
                            CFRelease(current);
                            current = (AXUIElementRef)parent;
                        } else {
                            break;
                        }
                    }
                    CFRelease(current);
                    CFRelease(hitElement);
                } else {
                    NSLog(@"  Point (%.0f,%.0f) → no element (error %d)", probePoints[i].x, probePoints[i].y, err);
                }
            }
        }
        // ── Mode: Inspect the browser group directly ──
        else if ([mode isEqualToString:@"browser"]) {
            NSLog(@"=== INSPECTING BROWSER GROUP ===");

            // Find the browser group via position probe (center of browser area)
            CGRect winFrame = CGRectZero;
            CFArrayRef windows = NULL;
            if (AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, (CFTypeRef*)&windows) == kAXErrorSuccess && windows) {
                if (CFArrayGetCount(windows) > 0)
                    winFrame = getAXFrame((AXUIElementRef)CFArrayGetValueAtIndex(windows, 0));
                CFRelease(windows);
            }

            float probeX = winFrame.origin.x + winFrame.size.width / 2;
            float probeY = winFrame.origin.y + winFrame.size.height * 0.7;

            AXUIElementRef browserGroup = NULL;
            AXUIElementCopyElementAtPosition(appRef, probeX, probeY, &browserGroup);
            if (!browserGroup) {
                NSLog(@"ERROR: Could not find browser group at (%.0f, %.0f)", probeX, probeY);
                CFRelease(appRef);
                return 1;
            }

            NSString* bgTitle = getAXAttribute(browserGroup, kAXTitleAttribute);
            CGRect bgFrame = getAXFrame(browserGroup);
            NSLog(@"Got browser group: title=\"%@\" frame=(%.0f,%.0f %.0fx%.0f)",
                  bgTitle, bgFrame.origin.x, bgFrame.origin.y, bgFrame.size.width, bgFrame.size.height);

            // 1. List ALL available attributes on this element
            CFArrayRef attrNames = NULL;
            if (AXUIElementCopyAttributeNames(browserGroup, &attrNames) == kAXErrorSuccess && attrNames) {
                NSLog(@"\nAll attributes on browser group:");
                CFIndex count = CFArrayGetCount(attrNames);
                for (CFIndex i = 0; i < count; i++) {
                    CFStringRef attrName = (CFStringRef)CFArrayGetValueAtIndex(attrNames, i);
                    CFTypeRef attrValue = NULL;
                    NSString* valueStr = @"(failed to read)";
                    if (AXUIElementCopyAttributeValue(browserGroup, attrName, &attrValue) == kAXErrorSuccess && attrValue) {
                        if (CFGetTypeID(attrValue) == CFArrayGetTypeID()) {
                            valueStr = [NSString stringWithFormat:@"[array: %ld items]", CFArrayGetCount((CFArrayRef)attrValue)];
                        } else {
                            valueStr = [NSString stringWithFormat:@"%@", (__bridge id)attrValue];
                        }
                        CFRelease(attrValue);
                    }
                    NSLog(@"  %@ = %@", (__bridge NSString*)attrName, valueStr);
                }
                CFRelease(attrNames);
            }

            // 2. Try multiple child access methods
            NSLog(@"\n--- Trying child access methods ---");

            CFStringRef childAttrs[] = {
                kAXChildrenAttribute,
                kAXVisibleChildrenAttribute,
                CFSTR("AXContents"),
                CFSTR("AXVisibleContents"),
                CFSTR("AXRows"),
                CFSTR("AXVisibleRows"),
                CFSTR("AXColumns"),
                CFSTR("AXSelectedChildren"),
                CFSTR("AXDisclosedRows"),
            };
            int numAttrs = sizeof(childAttrs) / sizeof(childAttrs[0]);

            for (int i = 0; i < numAttrs; i++) {
                CFArrayRef children = NULL;
                AXError err = AXUIElementCopyAttributeValue(browserGroup, childAttrs[i], (CFTypeRef*)&children);
                if (err == kAXErrorSuccess && children && CFGetTypeID(children) == CFArrayGetTypeID()) {
                    CFIndex count = CFArrayGetCount(children);
                    NSLog(@"  %@: %ld items", (__bridge NSString*)childAttrs[i], count);

                    // Dump first few children
                    CFIndex maxShow = (count < 10) ? count : 10;
                    for (CFIndex j = 0; j < maxShow; j++) {
                        AXUIElementRef child = (AXUIElementRef)CFArrayGetValueAtIndex(children, j);
                        NSString* cRole = getAXAttribute(child, kAXRoleAttribute);
                        NSString* cTitle = getAXAttribute(child, kAXTitleAttribute);
                        NSString* cDesc = getAXAttribute(child, kAXDescriptionAttribute);
                        NSString* cValue = getAXAttribute(child, kAXValueAttribute);
                        NSString* cHelp = getAXAttribute(child, kAXHelpAttribute);
                        CGRect cFrame = getAXFrame(child);
                        NSLog(@"    [%ld] [%@] title=\"%@\" desc=\"%@\" value=\"%@\" help=\"%@\" frame=(%.0f,%.0f %.0fx%.0f)",
                              j, cRole, cTitle, cDesc, cValue, cHelp,
                              cFrame.origin.x, cFrame.origin.y, cFrame.size.width, cFrame.size.height);
                    }
                    if (count > maxShow) NSLog(@"    ... and %ld more", count - maxShow);
                    CFRelease(children);
                } else {
                    NSLog(@"  %@: not available (error %d)", (__bridge NSString*)childAttrs[i], err);
                }
            }

            // 3. Try parameterized attributes (some elements use these for children)
            CFArrayRef paramNames = NULL;
            if (AXUIElementCopyParameterizedAttributeNames(browserGroup, &paramNames) == kAXErrorSuccess && paramNames) {
                CFIndex count = CFArrayGetCount(paramNames);
                if (count > 0) {
                    NSLog(@"\nParameterized attributes:");
                    for (CFIndex i = 0; i < count; i++) {
                        NSLog(@"  %@", (__bridge NSString*)CFArrayGetValueAtIndex(paramNames, i));
                    }
                }
                CFRelease(paramNames);
            }

            // 4. Recursively search all 181 children for buttons/text fields with titles
            NSLog(@"\n--- Searching all children for interactive elements ---");
            CFArrayRef allChildren = NULL;
            if (AXUIElementCopyAttributeValue(browserGroup, kAXChildrenAttribute, (CFTypeRef*)&allChildren) == kAXErrorSuccess && allChildren) {
                CFIndex totalChildren = CFArrayGetCount(allChildren);
                for (CFIndex i = 0; i < totalChildren; i++) {
                    AXUIElementRef child = (AXUIElementRef)CFArrayGetValueAtIndex(allChildren, i);
                    NSString* cRole = getAXAttribute(child, kAXRoleAttribute);
                    NSString* cTitle = getAXAttribute(child, kAXTitleAttribute);
                    NSString* cHelp = getAXAttribute(child, kAXHelpAttribute);
                    NSString* cValue = getAXAttribute(child, kAXValueAttribute);
                    CGRect cFrame = getAXFrame(child);

                    // Print elements that have a title, help text, or are interactive types
                    bool isInteresting = false;
                    if (cTitle && [cTitle length] > 0) isInteresting = true;
                    if (cHelp && [cHelp length] > 0) isInteresting = true;
                    if ([cRole isEqualToString:@"AXButton"] ||
                        [cRole isEqualToString:@"AXTextField"] ||
                        [cRole isEqualToString:@"AXSearchField"] ||
                        [cRole isEqualToString:@"AXComboBox"] ||
                        [cRole isEqualToString:@"AXTable"] ||
                        [cRole isEqualToString:@"AXList"] ||
                        [cRole isEqualToString:@"AXOutline"]) isInteresting = true;

                    if (isInteresting) {
                        NSLog(@"  [%ld] [%@] title=\"%@\" value=\"%@\" help=\"%@\" frame=(%.0f,%.0f %.0fx%.0f)",
                              i, cRole, cTitle, cValue, cHelp,
                              cFrame.origin.x, cFrame.origin.y, cFrame.size.width, cFrame.size.height);
                    }

                    // Also check grandchildren (one level deeper)
                    CFArrayRef grandchildren = NULL;
                    if (AXUIElementCopyAttributeValue(child, kAXChildrenAttribute, (CFTypeRef*)&grandchildren) == kAXErrorSuccess && grandchildren) {
                        CFIndex gcCount = CFArrayGetCount(grandchildren);
                        for (CFIndex j = 0; j < gcCount; j++) {
                            AXUIElementRef gc = (AXUIElementRef)CFArrayGetValueAtIndex(grandchildren, j);
                            NSString* gcRole = getAXAttribute(gc, kAXRoleAttribute);
                            NSString* gcTitle = getAXAttribute(gc, kAXTitleAttribute);
                            NSString* gcHelp = getAXAttribute(gc, kAXHelpAttribute);
                            NSString* gcValue = getAXAttribute(gc, kAXValueAttribute);
                            CGRect gcFrame = getAXFrame(gc);

                            bool gcInteresting = false;
                            if (gcTitle && [gcTitle length] > 0) gcInteresting = true;
                            if (gcHelp && [gcHelp length] > 0) gcInteresting = true;
                            if ([gcRole isEqualToString:@"AXButton"] ||
                                [gcRole isEqualToString:@"AXTextField"] ||
                                [gcRole isEqualToString:@"AXSearchField"]) gcInteresting = true;

                            if (gcInteresting) {
                                NSLog(@"    [%ld.%ld] [%@] title=\"%@\" value=\"%@\" help=\"%@\" frame=(%.0f,%.0f %.0fx%.0f)",
                                      i, j, gcRole, gcTitle, gcValue, gcHelp,
                                      gcFrame.origin.x, gcFrame.origin.y, gcFrame.size.width, gcFrame.size.height);
                            }
                        }
                        CFRelease(grandchildren);
                    }
                }
                CFRelease(allChildren);
            }

            CFRelease(browserGroup);
        }
        // ── Mode: Press search button and inject text ──
        else if ([mode isEqualToString:@"search"]) {
            NSString* searchText = (argc > 2) ? [NSString stringWithUTF8String:argv[2]] : @"#GRV_TEST";
            NSLog(@"=== SEARCH: \"%@\" ===", searchText);
            performBrowserSearch(appRef, searchText);
        }
        else {
            NSLog(@"Usage:");
            NSLog(@"  ./rb_test dump [depth]                — dump AX tree");
            NSLog(@"  ./rb_test dumpwin [depth]             — dump all windows (use when dialog is open)");
            NSLog(@"  ./rb_test menutest [\"Import Track\"]    — open menu only, don't interact with dialog");
            NSLog(@"  ./rb_test import /path/to/track.mp3   — full import flow for a track");
            NSLog(@"  ./rb_test importdir /path/to/folder   — full import flow for a folder");
            NSLog(@"  ./rb_test export                      — list available export devices");
            NSLog(@"  ./rb_test export VEGA                 — export currently selected track to 'VEGA'");
            NSLog(@"  ./rb_test export VEGA \"track name\"    — search, select, and export track to 'VEGA'");
            NSLog(@"  ./rb_test probe                       — scan browser area by screen coordinates");
            NSLog(@"  ./rb_test browser                     — inspect browser group attributes + children");
        }

        CFRelease(appRef);
        NSLog(@"Done.");
    }
    return 0;
}
