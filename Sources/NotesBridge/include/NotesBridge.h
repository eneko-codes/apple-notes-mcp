#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const NotesBridgeErrorDomain;

/// Typed because Swift imports an `NSError **` method as `throws`, which would otherwise
/// flatten "that note is gone" — an ordinary outcome, since a note can be deleted or
/// moved between two calls — into the same channel as a real failure.
typedef NS_ERROR_ENUM(NotesBridgeErrorDomain, NotesBridgeError){
    NotesBridgeErrorNotesNotRunning = 1,
    NotesBridgeErrorNotReachable,
    NotesBridgeErrorAccountNotFound,
    NotesBridgeErrorFolderNotFound,
    NotesBridgeErrorNoteNotFound,
    NotesBridgeErrorCreateRefused,
    NotesBridgeErrorWriteRefused,
};

/// Everything this project sends to Notes, in Objective-C.
///
/// Objective-C rather than Swift on purpose, and not for taste. Apple documents exactly
/// one way to create a scriptable object — ask the application for the class with
/// `classForScriptingClass:`, `alloc`/`initWithProperties:` it, then insert it in the
/// container's element array — and that pattern cannot be expressed from Swift. The class
/// that comes back is an `SBPseudoClass`, which does not inherit from `SBObject` and turns
/// every class-level message into an `__NSMessageBuilder`, so a Swift metatype cast
/// against it aborts the process. Underneath is a Swift limitation of long standing: the
/// metadata symbols for Scripting Bridge classes do not exist at link time because the
/// classes are made at runtime (swiftlang/swift#43407, open since 2016).
///
/// In Objective-C none of that arises. A cast to a protocol is a compile-time annotation,
/// the documented creation pattern compiles as written, and no `unsafeBitCast` is needed
/// anywhere. The alternative — driving Notes through `NSAppleScript` — is the one thing
/// Apple's own guide tells you not to do: "You should not use NSAppleScript to execute a
/// script merely to result in sending an Apple event."
///
/// Everything crosses back to Swift as Foundation types, so no Scripting Bridge object
/// ever escapes this file. Policy — which folders are in scope, how a query matches, where
/// to stop scanning, how a result is formatted — stays in Swift, where the tests can
/// reach it.
///
/// Caller strings are passed as typed parameters throughout. There is no script source to
/// splice them into, which is this project's injection guarantee.
@interface NotesBridge : NSObject

/// Whether Notes is running. This server never launches it.
@property (class, readonly) BOOL isNotesRunning;

/// Every account, as `{name, id, folders: [{name, path, id, shared, noteCount}]}`.
///
/// `path` is the folder's position inside its account with `/` between levels, because
/// Notes folders nest and a bare name is not enough to say which one you meant.
+ (nullable NSArray<NSDictionary<NSString *, id> *> *)accountsWithError:(NSError **)error;

/// Walks the folders whose account and path are given and returns
/// `{scanned, notes: [{id, name, folderPath, account, creationDate, modificationDate,
/// passwordProtected, shared, plaintext}]}`.
///
/// A date bound is pushed into Notes as a `whose` clause rather than applied here:
/// filtering inside Notes is dramatically cheaper than shipping every note across the
/// Apple event boundary. `useCreationDate` selects which of the two date properties the
/// bound applies to. `needsText` decides whether `plaintext` is fetched at all — it is one
/// more Apple event per note, and it is only needed when the caller is matching text.
///
/// `maxScan` bounds the walk; `scanned` reports how far it actually got, which is what
/// lets the caller say a result was truncated.
+ (nullable NSDictionary<NSString *, id> *)
    scanFolderPaths:(NSArray<NSString *> *)folderPaths
          inAccount:(nullable NSString *)account
           fromDate:(nullable NSDate *)fromDate
             toDate:(nullable NSDate *)toDate
    useCreationDate:(BOOL)useCreationDate
          needsText:(BOOL)needsText
            maxScan:(NSInteger)maxScan
              error:(NSError **)error;

/// One note, or nil with `NotesBridgeErrorNoteNotFound` if that id no longer resolves.
/// `body` (HTML) is only fetched when `includeHTML` is YES.
+ (nullable NSDictionary<NSString *, id> *)noteWithIdentifier:(NSString *)identifier
                                                  includeHTML:(BOOL)includeHTML
                                                        error:(NSError **)error;

/// Attachments of one note, as `{name, id, contentIdentifier, url, creationDate,
/// modificationDate, shared}`.
+ (nullable NSArray<NSDictionary<NSString *, id> *> *)attachmentsOfNoteWithIdentifier:
                                                          (NSString *)identifier
                                                                               error:
                                                                                   (NSError **)
                                                                                       error;

/// Creates a note in the folder at `folderPath` and returns its identifier.
///
/// `bodyHTML` is the note's content. Notes stores a body as HTML, and the note's `name` is
/// the first line of it — so the title is not passed separately, because two sources of
/// truth for the same fact drift apart.
+ (nullable NSString *)createNoteInFolderPath:(NSString *)folderPath
                                    inAccount:(nullable NSString *)account
                                     bodyHTML:(NSString *)bodyHTML
                                        error:(NSError **)error;

/// Replaces the note's whole body with `bodyHTML`. Appending is composed by the caller,
/// which is where it can be tested.
+ (BOOL)replaceBodyHTML:(NSString *)bodyHTML
       ofNoteWithIdentifier:(NSString *)identifier
                      error:(NSError **)error;

/// Moves the note into the folder at `folderPath`.
+ (BOOL)moveNoteWithIdentifier:(NSString *)identifier
                toFolderPath:(NSString *)folderPath
                   inAccount:(nullable NSString *)account
                       error:(NSError **)error;

/// Deletes the note. Notes puts it in "Recently Deleted", but this server does not promise
/// that: treat it as gone.
+ (BOOL)deleteNoteWithIdentifier:(NSString *)identifier error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
