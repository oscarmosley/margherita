#!/usr/bin/env python3
"""Lexical missing-symbol guard, NOT a substitute for macOS SDK typechecking.

Checks every Swift file, not only Views. Lists capitalized references against project
 declarations and an explicit reviewed platform vocabulary. Checks unqualified calls
against declarations, closure bindings and known platform calls. Checks calls on
project types and conventional project receivers against project function names.
Cannot resolve overloads, extension availability, protocol requirements, or types of
arbitrary receivers. Imports/nested Apple types are included in the platform vocabulary.
"""
import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
# This is explicit, not a blanket NS*/CG*/AV* prefix allowlist, so typos fail.
PLATFORM = set('''
CGColorSpace Dictionary WritableKeyPath T
CFData CGImageSourceCreateImageAtIndex CGImageSourceCreateWithData NSBitmapImageRep XMLDocument XMLElement
AVAssetReader AVAssetReaderTrackOutput AVAudioFormat CMAudioFormatDescriptionGetStreamBasicDescription CMBlockBufferCopyDataBytes CMBlockBufferGetDataLength CMSampleBufferGetDataBuffer CMSampleBufferGetNumSamples Int16 AVAssetExportPresetAppleM4A AVAssetExportPresetHighestQuality AVAssetExportPresetLowQuality AVAssetExportPresetMediumQuality AVAssetExportSession AVAssetImageGenerator AVAudioFile AVAudioPCMBuffer AVFileType AVFormatIDKey AVFoundation AVLinearPCMBitDepthKey AVLinearPCMIsBigEndianKey AVLinearPCMIsFloatKey AVLinearPCMIsNonInterleaved AVMutableComposition AVNumberOfChannelsKey AVSampleRateKey AVURLAsset AXIsProcessTrusted AXIsProcessTrustedWithOptions CGPreflightListenEventAccess Any App AppKit ApplicationServices Array AttributedString Binding Bool Bundle Button CASpringAnimation CFAttributedString CFDictionary CFRange CFString CFURL CGColor CGContext CGDataConsumer CGEventSource CGFloat CGImage CGImageDestinationAddImage CGImageDestinationCopyTypeIdentifiers CGImageDestinationCreateWithData CGImageDestinationCreateWithURL CGImageDestinationFinalize CGImageDestinationSetProperties CGImageSource CGImageSourceCopyPropertiesAtIndex CGImageSourceCreateThumbnailAtIndex CGImageSourceCreateWithURL CGImageSourceGetCount CGKeyCode CGPath CGPoint CGRect CGRequestListenEventAccess CGSize CIColor CIContext CIImage CMTime CMTimeRange CTFrame CTFrameDraw CTFrameGetVisibleStringRange CTFramesetterCreateFrame CTFramesetterCreateWithAttributedString CancellationError Capsule CaseIterable Character CharacterSet CheckedContinuation Circle Rectangle Codable Color ColorPicker Context CoreGraphics CoreImage CoreText CryptoKit Darwin Data Date Dispatch DispatchQueue TaskLocal DispatchSemaphore Divider DocumentType Double EnvironmentObject Equatable Error EventType EventTypeMask FileHandle FileManager ForEach Form Foundation Glibc GridItem HStack Identifiable Image ImageIO Int Int64 JSONDecoder JSONEncoder Label LabeledContent LazyVGrid LazyVStack LocalizedError MainActor MarkdownParsingOptions MemoryLayout ModifierFlags NSAlert NSAnimationContext NSApp NSAppearance NSApplication NSApplicationDelegate NSApplicationDelegateAdaptor NSAttributedString NSBezierPath NSCoder NSColor NSData NSDragOperation NSDraggingInfo NSEvent NSFont NSGraphicsContext NSHomeDirectory NSHostingView NSImage NSLock NSMenu NSMenuItem NSMutableAttributedString NSMutableData NSMutableParagraphStyle NSNumber NSObject NSOpenPanel NSPanel NSPasteboard NSPoint NSRange NSRect NSRegularExpression NSScreen NSSelectorFromString NSShadow NSSize NSSound NSStatusBar NSStatusItem NSString NSURL NSTrackingArea NSClipView NSObjectProtocol NSView NSViewRepresentable NSVisualEffectView NSWindow NSWorkspace Never Notification OK ObservableObject ObservedObject PDFDocument PDFKit PDFPage Picker Process ProcessInfo ProgressView Published Range RoundedRectangle SHA256 SIGKILL SMAppService Scene ScrollView Section Selector Sendable ServiceManagement Set Settings Slider Spacer String Substring SwiftUI TabView Task Text TextField Thread TimeInterval Timer Toggle UInt16 UInt32 UNMutableNotificationContent UNNotificationRequest UNUserNotificationCenter URL URLResourceKey UTF8 UTType UUID UnicodeScalar UniformTypeIdentifiers UserDefaults UserNotifications VStack View Void XMLParser XMLParserDelegate ZStack
'''.split())
# Reviewed macOS and SwiftUI APIs introduced by HUD, shelf and annular paths.
PLATFORM.update("""ActivationPolicy AnyCancellable ByteCountFormatter CGAffineTransform CGColorSpaceCreateDeviceRGB CGImageAlphaInfo CGMutablePath Combine DispatchWorkItem EmptyView Environment GeometryReader NSButton NSDraggingContext NSDraggingItem NSDraggingSession NSDraggingSource NSEdgeInsets NSImageView NSLayoutConstraint NSMouseInRect NSScrollView NSSharingService NSSharingServiceDelegate NSStackView NSTextField NSWindowDelegate ObjCBool OpenConfiguration PasteboardType Path Shape ViewBuilder""".split())
# Reviewed native OCR/CoreText, audio encoder discovery, plist and AppleScript APIs.
PLATFORM.update("""CGImageSourceCopyTypeIdentifiers AVAudioFrameCount AVAudioFramePosition AVEncoderBitDepthHintKey AudioFormatGetProperty AudioFormatGetPropertyInfo AudioFormatID AudioToolbox CTFontCreateWithName CTLineCreateWithAttributedString CTLineDraw CTLineGetTypographicBounds Encoding FoundationXML Key NSAppleScript NSDictionary PropertyListSerialization UInt8 VNImageRequestHandler VNRecognizeTextRequest Vision""".split())
# Reviewed settings/onboarding SwiftUI controls and AppKit feedback/menu protocols.
PLATFORM.update("""Animation Content DisclosureGroup Grid GridRow Group LinearGradient Link NSHapticFeedbackManager NSMenuDelegate Name NotificationCenter RadialGradient Self StateObject UnitPoint Material""".split())
BUILTIN_CALLS = set('''lstat mode_t pow rename stat withExtendedLifetime abs addSubview addTrackingArea removeTrackingArea asin atan2 beginDraggingSession stride repeatElement setAccessibilityElement setAccessibilityRole sqrt canImport ceil cos escaping fatalError for guard hypot if in init kill let max min os private registerForDraggedTypes return selector setAccessibilityLabel sin step withAnimation withTaskCancellationHandler zip'''.split())

PLATFORM.update("""S_IFDIR S_IFMT S_IFREG Value CFArray CoreServices DirectoryEnumerationOptions FSEventStreamContext FSEventStreamCreate FSEventStreamCreateFlags FSEventStreamEventId FSEventStreamInvalidate FSEventStreamRef FSEventStreamRelease FSEventStreamSetDispatchQueue FSEventStreamStart FSEventStreamStop FileAttributeType RunLoop SPUStandardUpdaterController Sparkle UInt64 Unmanaged""".split())

def code_only(text):
    # Preserve interpolation expressions, otherwise calls inside Text("...\\(...)") vanish.
    expressions = []
    def literal(match):
        string = match.group()
        cursor = 0
        while True:
            start = string.find('\\(', cursor)
            if start < 0:
                break
            i, depth = start + 2, 1
            while i < len(string) and depth:
                if string[i] == '(':
                    depth += 1
                elif string[i] == ')':
                    depth -= 1
                i += 1
            expressions.append(string[start + 2:i - 1])
            cursor = i
        return ' '
    # Strip comments before literals, except // inside a literal must remain literal.
    pattern = r'//[^\n]*|/\*[\s\S]*?\*/|"""[\s\S]*?"""|"(?:\\.|[^"\\])*"'
    clean = re.sub(pattern, lambda m: literal(m) if m.group().startswith('"') else ' ', text)
    return clean + '\n' + '\n'.join(expressions)

def audit(root):
    files = {str(p.relative_to(root)): code_only(p.read_text()) for p in sorted((root / 'Margherita').glob('*.swift'))}
    source = '\n'.join(files.values())
    declarations = set(re.findall(r'\b(?:struct|class|actor|enum|protocol|typealias|associatedtype)\s+(\w+)', source))
    functions = set(re.findall(r'\bfunc\s+(\w+)', source))
    enum_cases = set(re.findall(r'\bcase\s+(\w+)', source))
    # Named closures/parameters may be called just like functions.
    bindings = set(re.findall(r'\b(?:let|var)\s+(\w+)', source))
    bindings.update(re.findall(r'\b(\w+)\s*:\s*(?:@escaping\s+|@Sendable\s+)*\(', source))
    used = set(re.findall(r'\b[A-Z][A-Za-z0-9_]*\b', source))
    calls = set(re.findall(r'(?<![.\w])([a-z]\w*)\s*\(', source))
    unknown_types = used - declarations - bindings - PLATFORM
    unknown_calls = calls - functions - enum_cases - bindings - BUILTIN_CALLS
    project_receivers = declarations | {'model', 'prefs', 'ui', 'recorder', 'engine'}
    member_calls = {(receiver, method) for receiver, method in re.findall(r'\b(\w+)\s*(?:\?\s*)?\.\s*(\w+)\s*\(', source) if receiver in project_receivers}
    # init/standard NSObject/SwiftUI entrypoints can be inherited by project classes.
    unknown_members = {(r, m) for r, m in member_calls if m not in functions | bindings | enum_cases | {'init'}}
    return {
        'files': list(files),
        'project_declarations': sorted(declarations),
        'project_functions': sorted(functions),
        'platform_references': sorted(used & PLATFORM),
        'function_calls': sorted(calls),
        'project_member_calls': sorted(r + '.' + m for r, m in member_calls),
        'unknown_capitalized_identifiers': sorted(unknown_types),
        'unknown_unqualified_calls': sorted(unknown_calls),
        'unknown_project_member_calls': sorted(r + '.' + m for r, m in unknown_members),
    }

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    result = audit(args.root)
    report = json.dumps(result, indent=2) + '\n'
    if args.report:
        args.report.write_text(report)
    else:
        print(report, end='')
    failed = any(value for name, value in result.items() if name.startswith('unknown_'))
    if args.report:
        print(f"Audited {len(result['files'])} Swift files; " + ('FAIL' if failed else 'PASS'))
        for name, value in result.items():
            if name.startswith('unknown_') and value:
                print(name, value)
    sys.exit(1 if failed else 0)
