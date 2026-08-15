#import "NotesBridge.h"

#import <AppKit/AppKit.h>
#import <ScriptingBridge/ScriptingBridge.h>

// Hand-declared bindings for Notes, covering only the members this server sends.
//
// `sdef /System/Applications/Notes.app | sdp -fh` generates a 176-line header; declaring
// the handful of members actually used is smaller and auditable. Every selector here was
// checked against Notes' scripting dictionary — confirm before adding one:
//
//     sdef /System/Applications/Notes.app | grep 'name="password protected"'
//
// Scripting Bridge camel-cases dictionary names: `modification date` becomes
// `modificationDate`, `password protected` becomes `passwordProtected`. `id` stays `id`
// and is generated as a method rather than a property, because it collides with the
// Objective-C type name.
//
// Two members of the dictionary are deliberately absent. `application.selection` would
// read whatever the owner has open on screen, which is not this server's business, and
// the `show` command would take over their window. Nothing is declared "in case it is
// useful later": every member is one this server sends.

@protocol NotesFolder;

@protocol NotesAttachment <NSObject>
@property (copy, readonly) NSString *name;
- (NSString *)id;
@property (copy, readonly) NSString *contentIdentifier;
@property (copy, readonly) NSDate *creationDate;
@property (copy, readonly) NSDate *modificationDate;
@property (copy, readonly) NSString *URL;
@property (readonly) BOOL shared;
@end

@protocol NotesNote <NSObject>
@property (copy) NSString *name;
- (NSString *)id;
@property (copy, readonly) id<NotesFolder> container;
/// The note's content as HTML. Writable, and writing it also rewrites `name`, which Notes
/// derives from the first line.
@property (copy) NSString *body;
@property (copy, readonly) NSString *plaintext;
@property (copy, readonly) NSDate *creationDate;
@property (copy, readonly) NSDate *modificationDate;
@property (readonly) BOOL passwordProtected;
@property (readonly) BOOL shared;
@property (readonly) SBElementArray<id<NotesAttachment>> *attachments;
- (void)delete;
- (void)moveTo:(SBObject *)to;
@end

@protocol NotesFolder <NSObject>
@property (copy) NSString *name;
- (NSString *)id;
@property (readonly) BOOL shared;
@property (readonly) SBElementArray<id<NotesFolder>> *folders;
@property (readonly) SBElementArray<id<NotesNote>> *notes;
@end

@protocol NotesAccount <NSObject>
@property (copy) NSString *name;
- (NSString *)id;
@property (readonly) SBElementArray<id<NotesFolder>> *folders;
@end

@protocol NotesApplication <NSObject>
@property (readonly) SBElementArray<id<NotesAccount>> *accounts;
@property (readonly) SBElementArray<id<NotesNote>> *notes;
@end

NSString *const NotesBridgeErrorDomain = @"codes.eneko.apple-notes-mcp";
static NSString *const NotesBundleIdentifier = @"com.apple.Notes";

/// Separator between the levels of a folder path. Notes folders nest, so a bare name
/// cannot say which "Archive" was meant.
static NSString *const FolderPathSeparator = @"/";

@implementation NotesBridge

#pragma mark - Plumbing

+ (BOOL)isNotesRunning {
    return [NSRunningApplication
               runningApplicationsWithBundleIdentifier:NotesBundleIdentifier].count > 0;
}

+ (NSError *)errorWithCode:(NotesBridgeError)code message:(NSString *)message {
    return [NSError errorWithDomain:NotesBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// The application object, or nil with `error` set. Casting to the protocol is a
/// compile-time annotation in Objective-C: no runtime check, no metadata symbol, and so
/// none of the trouble the same line causes in Swift.
+ (nullable SBApplication<NotesApplication> *)applicationWithError:(NSError **)error {
    if (!self.isNotesRunning) {
        if (error) {
            *error = [self errorWithCode:NotesBridgeErrorNotesNotRunning
                                 message:@"Notes is not running."];
        }
        return nil;
    }
    SBApplication *application =
        [SBApplication applicationWithBundleIdentifier:NotesBundleIdentifier];
    if (!application) {
        if (error) {
            *error = [self errorWithCode:NotesBridgeErrorNotReachable
                                 message:@"Notes could not be reached."];
        }
        return nil;
    }
    // No launch flag is set to keep Notes from starting, because none exists: the guard is
    // the isNotesRunning check above. Launching an app on the owner's behalf is a side
    // effect they did not ask for, and Scripting Bridge offers no way to forbid it.
    return (SBApplication<NotesApplication> *)application;
}

#pragma mark - Folder tree

/// Depth-first walk of one account's folders, calling `visit` with each folder and the
/// `/`-joined path that reaches it.
+ (void)walkFolders:(SBElementArray<id<NotesFolder>> *)folders
             prefix:(nullable NSString *)prefix
              visit:(void (^)(id<NotesFolder> folder, NSString *path))visit {
    for (id<NotesFolder> folder in folders) {
        NSString *name = folder.name;
        if (name.length == 0) continue;
        NSString *path = prefix.length > 0
                             ? [prefix stringByAppendingFormat:@"%@%@", FolderPathSeparator, name]
                             : name;
        visit(folder, path);
        [self walkFolders:folder.folders prefix:path visit:visit];
    }
}

/// The folder at `path` in `account`, or nil. When `account` is nil the first account that
/// has such a path wins, which is the only sensible reading of an unqualified request.
+ (nullable id<NotesFolder>)folderAtPath:(NSString *)path
                               inAccount:(nullable NSString *)accountName
                           ofApplication:(SBApplication<NotesApplication> *)application
                             accountName:(NSString *_Nullable *_Nullable)resolvedAccount {
    for (id<NotesAccount> account in application.accounts) {
        NSString *name = account.name;
        if (name.length == 0) continue;
        if (accountName && ![name isEqualToString:accountName]) continue;

        __block id<NotesFolder> match = nil;
        [self walkFolders:account.folders
                   prefix:nil
                    visit:^(id<NotesFolder> folder, NSString *folderPath) {
                        if (!match && [folderPath caseInsensitiveCompare:path] == NSOrderedSame) {
                            match = folder;
                        }
                    }];
        if (match) {
            if (resolvedAccount) *resolvedAccount = name;
            return match;
        }
    }
    return nil;
}

#pragma mark - Reads

+ (nullable NSArray<NSDictionary<NSString *, id> *> *)accountsWithError:(NSError **)error {
    SBApplication<NotesApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    NSMutableArray<NSDictionary<NSString *, id> *> *results = [NSMutableArray array];
    for (id<NotesAccount> account in application.accounts) {
        NSString *name = account.name;
        if (name.length == 0) continue;

        NSMutableArray<NSDictionary<NSString *, id> *> *folders = [NSMutableArray array];
        [self walkFolders:account.folders
                   prefix:nil
                    visit:^(id<NotesFolder> folder, NSString *path) {
                        [folders addObject:@{
                            @"name": folder.name ?: @"",
                            @"path": path,
                            @"id": [folder id] ?: @"",
                            @"shared": @(folder.shared),
                            @"noteCount": @(folder.notes.count),
                        }];
                    }];
        [results addObject:@{@"name": name, @"id": [account id] ?: @"", @"folders": folders}];
    }
    return results;
}

/// One scanned note as a dictionary. `plaintext` is only read when asked for: it is a
/// separate Apple event per note and only the text-matching path needs it.
+ (NSDictionary<NSString *, id> *)summaryOfNote:(id<NotesNote>)note
                                     folderPath:(NSString *)folderPath
                                        account:(NSString *)account
                                      needsText:(BOOL)needsText {
    NSString *plaintext = needsText ? note.plaintext : nil;
    return @{
        @"id": [note id] ?: @"",
        @"name": note.name ?: @"",
        @"folderPath": folderPath,
        @"account": account,
        @"creationDate": note.creationDate ?: NSDate.distantPast,
        @"modificationDate": note.modificationDate ?: NSDate.distantPast,
        @"passwordProtected": @(note.passwordProtected),
        @"shared": @(note.shared),
        @"plaintext": plaintext ?: @"",
    };
}

+ (nullable NSDictionary<NSString *, id> *)
    scanFolderPaths:(NSArray<NSString *> *)folderPaths
          inAccount:(nullable NSString *)accountName
           fromDate:(nullable NSDate *)fromDate
             toDate:(nullable NSDate *)toDate
    useCreationDate:(BOOL)useCreationDate
          needsText:(BOOL)needsText
            maxScan:(NSInteger)maxScan
              error:(NSError **)error {
    SBApplication<NotesApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    NSInteger remaining = maxScan;
    NSMutableArray<NSDictionary<NSString *, id> *> *notes = [NSMutableArray array];

    for (NSString *path in folderPaths) {
        if (remaining <= 0) break;

        NSString *resolvedAccount = accountName ?: @"";
        id<NotesFolder> folder = [self folderAtPath:path
                                          inAccount:accountName
                                      ofApplication:application
                                        accountName:&resolvedAccount];
        // A path that no longer resolves is skipped rather than fatal: the caller asked
        // for several folders and one having been renamed should not lose the rest.
        if (!folder) continue;

        // The date bound is pushed into Notes as a `whose` clause. The unfiltered array is
        // only materialised when there is no bound to push down — building it first and
        // then discarding it would pay for the whole folder on exactly the path the bound
        // exists to avoid.
        NSArray *candidates;
        if (fromDate || toDate) {
            NSString *field = useCreationDate ? @"creationDate" : @"modificationDate";
            NSMutableArray<NSString *> *clauses = [NSMutableArray array];
            NSMutableArray *values = [NSMutableArray array];
            if (fromDate) {
                [clauses addObject:[field stringByAppendingString:@" >= %@"]];
                [values addObject:fromDate];
            }
            if (toDate) {
                [clauses addObject:[field stringByAppendingString:@" <= %@"]];
                [values addObject:toDate];
            }
            NSPredicate *predicate =
                [NSPredicate predicateWithFormat:[clauses componentsJoinedByString:@" AND "]
                                   argumentArray:values];
            candidates = [folder.notes filteredArrayUsingPredicate:predicate];
        } else {
            candidates = [folder.notes get] ?: @[];
        }

        for (id<NotesNote> note in candidates) {
            if (remaining <= 0) break;
            remaining -= 1;
            [notes addObject:[self summaryOfNote:note
                                      folderPath:path
                                         account:resolvedAccount
                                       needsText:needsText]];
        }
    }
    return @{@"scanned": @(maxScan - remaining), @"notes": notes};
}

/// Resolves one note by its identifier.
///
/// Matched inside Notes with a `whose` clause rather than by walking every note here: the
/// identifier is unique across the library, and a linear walk would cost one Apple event
/// per note.
+ (nullable id<NotesNote>)noteWithIdentifier:(NSString *)identifier
                               ofApplication:(SBApplication<NotesApplication> *)application {
    NSArray *matching = [application.notes
        filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"id == %@", identifier]];
    return matching.firstObject;
}

+ (NSError *)noteNotFoundError {
    return [self errorWithCode:NotesBridgeErrorNoteNotFound
                       message:@"No note in Notes has that identifier any more."];
}

+ (nullable NSDictionary<NSString *, id> *)noteWithIdentifier:(NSString *)identifier
                                                  includeHTML:(BOOL)includeHTML
                                                        error:(NSError **)error {
    SBApplication<NotesApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    id<NotesNote> note = [self noteWithIdentifier:identifier ofApplication:application];
    if (!note) {
        if (error) *error = [self noteNotFoundError];
        return nil;
    }

    // The containing folder is reported by id and name only. Turning that into a path
    // means knowing the whole tree, and that resolution lives in Swift where it is
    // testable — the bridge stays the thin part.
    id<NotesFolder> folder = note.container;
    NSString *body = includeHTML ? note.body : nil;
    return @{
        @"id": [note id] ?: identifier,
        @"name": note.name ?: @"",
        @"folderID": folder ? ([folder id] ?: @"") : @"",
        @"folderName": folder ? (folder.name ?: @"") : @"",
        @"creationDate": note.creationDate ?: NSDate.distantPast,
        @"modificationDate": note.modificationDate ?: NSDate.distantPast,
        @"passwordProtected": @(note.passwordProtected),
        @"shared": @(note.shared),
        @"attachmentCount": @(note.attachments.count),
        @"plaintext": note.plaintext ?: @"",
        @"body": body ?: @"",
    };
}

+ (nullable NSArray<NSDictionary<NSString *, id> *> *)attachmentsOfNoteWithIdentifier:
                                                          (NSString *)identifier
                                                                               error:
                                                                                   (NSError **)
                                                                                       error {
    SBApplication<NotesApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    id<NotesNote> note = [self noteWithIdentifier:identifier ofApplication:application];
    if (!note) {
        if (error) *error = [self noteNotFoundError];
        return nil;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *results = [NSMutableArray array];
    for (id<NotesAttachment> attachment in note.attachments) {
        NSString *url = attachment.URL;
        [results addObject:@{
            @"id": [attachment id] ?: @"",
            @"name": attachment.name ?: @"",
            @"contentIdentifier": attachment.contentIdentifier ?: @"",
            @"url": url ?: @"",
            @"creationDate": attachment.creationDate ?: NSDate.distantPast,
            @"modificationDate": attachment.modificationDate ?: NSDate.distantPast,
            @"shared": @(attachment.shared),
        }];
    }
    return results;
}

#pragma mark - Writes

+ (nullable NSString *)createNoteInFolderPath:(NSString *)folderPath
                                    inAccount:(nullable NSString *)accountName
                                     bodyHTML:(NSString *)bodyHTML
                                        error:(NSError **)error {
    SBApplication<NotesApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    id<NotesFolder> folder = [self folderAtPath:folderPath
                                      inAccount:accountName
                                  ofApplication:application
                                    accountName:NULL];
    if (!folder) {
        if (error) {
            *error = [self errorWithCode:NotesBridgeErrorFolderNotFound
                                 message:[NSString stringWithFormat:@"No folder '%@'.",
                                                                    folderPath]];
        }
        return nil;
    }

    Class noteClass = [application classForScriptingClass:@"note"];
    if (!noteClass) {
        if (error) {
            *error = [self errorWithCode:NotesBridgeErrorCreateRefused
                                 message:@"Notes did not offer its note class."];
        }
        return nil;
    }

    // Properties are a dictionary of typed values, never text spliced into a script.
    id<NotesNote> note = [[noteClass alloc] initWithProperties:@{@"body": bodyHTML}];
    if (!note) {
        if (error) {
            *error = [self errorWithCode:NotesBridgeErrorCreateRefused
                                 message:@"Notes would not create the note."];
        }
        return nil;
    }

    // Insert before touching anything else. Scripting Bridge: an object "is not viable in
    // the application until it has been added to its container. Consequently, you cannot
    // set or access its properties until it's been added."
    [folder.notes addObject:note];

    NSString *identifier = [note id];
    if (identifier.length == 0) {
        if (error) {
            *error = [self errorWithCode:NotesBridgeErrorCreateRefused
                                 message:@"Notes created the note but did not return an "
                                          "identifier for it. Look in the folder before "
                                          "trying again, so a second copy is not made."];
        }
        return nil;
    }
    return identifier;
}

+ (BOOL)replaceBodyHTML:(NSString *)bodyHTML
       ofNoteWithIdentifier:(NSString *)identifier
                      error:(NSError **)error {
    SBApplication<NotesApplication> *application = [self applicationWithError:error];
    if (!application) return NO;

    id<NotesNote> note = [self noteWithIdentifier:identifier ofApplication:application];
    if (!note) {
        if (error) *error = [self noteNotFoundError];
        return NO;
    }
    note.body = bodyHTML;
    return YES;
}

+ (BOOL)moveNoteWithIdentifier:(NSString *)identifier
                toFolderPath:(NSString *)folderPath
                   inAccount:(nullable NSString *)accountName
                       error:(NSError **)error {
    SBApplication<NotesApplication> *application = [self applicationWithError:error];
    if (!application) return NO;

    id<NotesNote> note = [self noteWithIdentifier:identifier ofApplication:application];
    if (!note) {
        if (error) *error = [self noteNotFoundError];
        return NO;
    }

    id<NotesFolder> folder = [self folderAtPath:folderPath
                                      inAccount:accountName
                                  ofApplication:application
                                    accountName:NULL];
    if (!folder) {
        if (error) {
            *error = [self errorWithCode:NotesBridgeErrorFolderNotFound
                                 message:[NSString stringWithFormat:@"No folder '%@'.",
                                                                    folderPath]];
        }
        return NO;
    }

    // Notes cannot move a note between accounts — iCloud and On My Mac are separate
    // stores — and reports that as a failed Apple event rather than a no-op.
    [note moveTo:(SBObject *)folder];
    return YES;
}

+ (BOOL)deleteNoteWithIdentifier:(NSString *)identifier error:(NSError **)error {
    SBApplication<NotesApplication> *application = [self applicationWithError:error];
    if (!application) return NO;

    id<NotesNote> note = [self noteWithIdentifier:identifier ofApplication:application];
    if (!note) {
        if (error) *error = [self noteNotFoundError];
        return NO;
    }
    [note delete];
    return YES;
}

@end
