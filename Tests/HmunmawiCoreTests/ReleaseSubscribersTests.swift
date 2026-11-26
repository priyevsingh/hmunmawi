import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct ReleaseSubscribersTests {
    @Test func forgivingCSVAndEmailListParsing() {
        let raw = """
        "Alex Rivera <alex@example.com>", Bob Lee <bob@example.org>; carol@example.com
        "Dana, K." <dana@example.net>
        not-an-email; missing@; @example.com
        alex@example.com
        """
        let parsed = ReleaseSubscriberImport.parse(raw, defaultApps: ["Pulse Diary"])
        #expect(parsed.entries.map(\.email) == [
            "alex@example.com",
            "bob@example.org",
            "carol@example.com",
            "dana@example.net",
        ])
        #expect(parsed.entries[0].name == "Alex Rivera")
        #expect(parsed.entries[1].name == "Bob Lee")
        #expect(parsed.entries[2].name == nil)
        #expect(parsed.entries[3].name == "Dana, K.")
        #expect(parsed.entries.allSatisfy { $0.apps == ["Pulse Diary"] })
        #expect(parsed.invalid == ["not-an-email", "missing@", "@example.com"])

        let csv = """
        email,name,apps
        sam@example.com,,Pulse Diary
        sam@example.com,Sam Taylor,Lift Crew|Pulse Diary
        pat@example.org,"Pat, Jr.",all
        bad-row,Nobody,Pulse Diary
        """
        let csvParsed = ReleaseSubscriberImport.parse(csv, defaultApps: ["DefaultApp"])
        #expect(csvParsed.entries.count == 2)
        #expect(csvParsed.entries[0] == ReleaseSubscriberImport.Entry(
            email: "sam@example.com",
            name: "Sam Taylor",
            apps: ["Pulse Diary", "Lift Crew"]
        ))
        #expect(csvParsed.entries[1] == ReleaseSubscriberImport.Entry(
            email: "pat@example.org",
            name: "Pat, Jr.",
            apps: ["all"]
        ))
        #expect(csvParsed.invalid == ["bad-row"])
    }

    @Test func storeUpsertMergeUnsubscribePreserveRemoveReactivateAndRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hm-sub-core-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: ReleaseSubscribersStore.fileName)

        var book = ReleaseSubscribersBook()
        let first = ReleaseSubscribersStore.upsert(
            book: &book,
            raw: "alex@example.com, Bob <bob@example.org>",
            defaultApps: ["Pulse Diary"],
            today: "2026-11-20"
        )
        #expect(first.added == 2 && first.updatedApps == 0 && first.duplicates == 0)

        let merged = ReleaseSubscribersStore.upsert(
            book: &book,
            raw: "Alex Rivera <alex@example.com>, bob@example.org",
            defaultApps: ["Lift Crew"],
            today: "2026-11-21"
        )
        #expect(merged.added == 0 && merged.updatedApps == 2)
        #expect(book.subscribers.first(where: { $0.email == "alex@example.com" })?.name == "Alex Rivera")
        #expect(book.subscribers.first(where: { $0.email == "alex@example.com" })?.apps == ["Pulse Diary", "Lift Crew"])

        let duplicate = ReleaseSubscribersStore.upsert(
            book: &book,
            raw: "alex@example.com",
            defaultApps: ["Pulse Diary"],
            today: "2026-11-22"
        )
        #expect(duplicate.duplicates == 1 && duplicate.added == 0 && duplicate.updatedApps == 0)

        // Unsubscribed status is never overwritten by a re-import.
        let alexIdx = try #require(book.subscribers.firstIndex(where: { $0.email == "alex@example.com" }))
        book.subscribers[alexIdx].unsubscribedAt = "2026-11-23"
        let optedOutRes = ReleaseSubscribersStore.upsert(
            book: &book,
            raw: "alex@example.com",
            defaultApps: ["all"],
            today: "2026-11-24"
        )
        #expect(optedOutRes.unsubscribedSkipped == 1 && optedOutRes.added == 0 && optedOutRes.updatedApps == 0)
        #expect(book.subscribers[alexIdx].unsubscribedAt == "2026-11-23")
        #expect(!book.subscribers[alexIdx].isActive)

        // Reactivate clears unsubscribedAt and bouncedAt.
        book.subscribers[alexIdx].bouncedAt = "2026-11-23"
        #expect(ReleaseSubscribersStore.reactivate(book: &book, email: "alex@example.com"))
        #expect(book.subscribers[alexIdx].isActive)
        #expect(!ReleaseSubscribersStore.reactivate(book: &book, email: "alex@example.com"))

        // Remove per-app vs global.
        #expect(ReleaseSubscribersStore.remove(book: &book, email: "alex@example.com", app: "Pulse Diary"))
        #expect(book.subscribers.first(where: { $0.email == "alex@example.com" })?.apps == ["Lift Crew"])
        #expect(!ReleaseSubscribersStore.remove(book: &book, email: "alex@example.com", app: "UnknownApp"))
        #expect(ReleaseSubscribersStore.remove(book: &book, email: "alex@example.com", app: "Lift Crew"))
        #expect(!book.subscribers.contains(where: { $0.email == "alex@example.com" }))
        #expect(ReleaseSubscribersStore.remove(book: &book, email: "bob@example.org", app: nil))
        #expect(book.subscribers.isEmpty)

        // Save/load round-trip with 0o600 permissions.
        ReleaseSubscribersStore.upsert(book: &book, raw: "Test <test@example.com>", defaultApps: ["Pulse Diary"], today: "2026-11-26")
        book.configs["Pulse Diary"] = ReleaseNotifyAppConfig(allowPatchUpdates: true, autoDraftOnRelease: false, customSubject: "Custom")
        book.notifiedVersions["Pulse Diary"] = "4.2.0"
        ReleaseSubscribersStore.save(book, to: fileURL)

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o600)

        let loaded = ReleaseSubscribersStore.load(fileURL)
        #expect(loaded.subscribers.count == 1)
        #expect(loaded.subscribers.first?.email == "test@example.com")
        #expect(loaded.configs["Pulse Diary"]?.allowPatchUpdates == true)
        #expect(loaded.notifiedVersions["Pulse Diary"] == "4.2.0")
    }

    @Test func patchUpdateGate() {
        #expect(ReleaseSubscribersStore.isPatchUpdate(from: "1.5.0", to: "1.5.1"))
        #expect(ReleaseSubscribersStore.isPatchUpdate(from: "1.5", to: "1.5.1"))
        #expect(!ReleaseSubscribersStore.isPatchUpdate(from: "1.5.1", to: "1.6.0"))
        #expect(!ReleaseSubscribersStore.isPatchUpdate(from: "1.6.0", to: "2.0.0"))
        #expect(!ReleaseSubscribersStore.isPatchUpdate(from: "1.5.0", to: "1.5.0"))
    }

    @Test func resumableDeliveryLedger() {
        var book = ReleaseSubscribersBook(subscribers: [
            ReleaseSubscriber(email: "alex@example.com", name: "Alex", apps: ["Pulse Diary"], addedAt: "2026-11-01"),
            ReleaseSubscriber(email: "bob@example.org", name: "Bob", apps: ["all"], addedAt: "2026-11-02"),
            ReleaseSubscriber(email: "optedout@example.com", apps: ["Pulse Diary"], addedAt: "2026-11-03", unsubscribedAt: "2026-11-10"),
            ReleaseSubscriber(email: "other@example.net", apps: ["OtherApp"], addedAt: "2026-11-04"),
        ])

        let initial = ReleaseSubscribersStore.eligibleRecipients(in: book, app: "Pulse Diary", version: "1.6.0")
        #expect(initial.map(\.email) == ["alex@example.com", "bob@example.org"])

        ReleaseSubscribersStore.recordFailure(book: &book, app: "Pulse Diary", version: "1.6.0", email: "alex@example.com", error: "421 temporary failure")
        let key16 = ReleaseSubscribersStore.deliveryKey(app: "Pulse Diary", version: "1.6.0")
        #expect(book.deliveries[key16]?.failedEmails?["alex@example.com"] == "421 temporary failure")
        #expect(ReleaseSubscribersStore.eligibleRecipients(in: book, app: "Pulse Diary", version: "1.6.0").map(\.email) == ["alex@example.com", "bob@example.org"])

        ReleaseSubscribersStore.recordSent(book: &book, app: "Pulse Diary", version: "1.6.0", email: "alex@example.com", today: "2026-11-26")
        #expect(book.deliveries[key16]?.sentEmails == ["alex@example.com"])
        #expect(book.deliveries[key16]?.failedEmails == nil)
        #expect(ReleaseSubscribersStore.eligibleRecipients(in: book, app: "Pulse Diary", version: "1.6.0").map(\.email) == ["bob@example.org"])

        // Still eligible for the next release 1.7.0.
        #expect(ReleaseSubscribersStore.eligibleRecipients(in: book, app: "Pulse Diary", version: "1.7.0").map(\.email) == ["alex@example.com", "bob@example.org"])
    }

    @Test func templateRenderAndPersonalizeBody() {
        let withNotes = ReleaseNotifyTemplate.render(
            app: "Pulse Diary",
            version: "4.2.0",
            whatsNew: "  Faster search  \n\n\n  Cleaner widgets  ",
            appStoreURL: "https://apps.apple.com/app/id123456",
            subscriberName: "Alex Rivera"
        )
        #expect(withNotes.subject == "Pulse Diary 4.2.0 is now available")
        #expect(withNotes.body.hasPrefix("Hi Alex,"))
        #expect(withNotes.body.contains("What's new:\nFaster search\n\n  Cleaner widgets"))
        #expect(withNotes.body.contains("PS, (escapethematrix.app)"))
        #expect(withNotes.body.lowercased().contains("unsubscribe"))

        let withoutNotesNil = ReleaseNotifyTemplate.render(
            app: "Pulse Diary",
            version: "4.2.0",
            whatsNew: nil,
            appStoreURL: "https://apps.apple.com/app/id123456",
            subscriberName: nil
        )
        #expect(withoutNotesNil.body.hasPrefix("Hi,"))
        #expect(!withoutNotesNil.body.contains("What's new:"))
        #expect(!withoutNotesNil.body.contains("\n\n\n"))

        let withoutNotesWhitespace = ReleaseNotifyTemplate.render(
            app: "Pulse Diary",
            version: "4.2.0",
            whatsNew: "   \n  ",
            appStoreURL: "https://apps.apple.com/app/id123456",
            subscriberName: nil
        )
        #expect(!withoutNotesWhitespace.body.contains("What's new:"))

        #expect(ReleaseNotifyTemplate.personalizeBody(withoutNotesNil.body, subscriberName: "Alex Rivera").hasPrefix("Hi Alex,"))
        #expect(ReleaseNotifyTemplate.personalizeBody(withoutNotesNil.body, subscriberName: nil).hasPrefix("Hi,"))
        #expect(ReleaseNotifyTemplate.personalizeBody("Hi there,\nBody", subscriberName: "Alex").hasPrefix("Hi Alex,"))
        #expect(ReleaseNotifyTemplate.personalizeBody("Hi there,\nBody", subscriberName: nil).hasPrefix("Hi,"))
    }

    @Test func spamLintCatchesPolicyAndDeliverabilityIssues() {
        let clean = ReleaseNotifyTemplate.render(
            app: "Pulse Diary",
            version: "4.2.0",
            whatsNew: "Smoother sync.",
            appStoreURL: "https://apps.apple.com/app/id123456"
        )
        #expect(ReleaseNotifySpamLint.problem(clean.body, subject: clean.subject) == nil)

        #expect(ReleaseNotifySpamLint.problem(clean.body + "\nGreat!!", subject: clean.subject) != nil)
        #expect(ReleaseNotifySpamLint.problem(clean.body + "\nUpdate! Try it!", subject: clean.subject) != nil)
        #expect(ReleaseNotifySpamLint.problem(clean.body + "\nhttps://bit.ly/pulse42", subject: clean.subject) != nil)
        #expect(ReleaseNotifySpamLint.problem(clean.body + "\nhttps://example.com/a\nhttps://example.org/b", subject: clean.subject) != nil)
        #expect(ReleaseNotifySpamLint.problem(clean.body + "\nACT NOW to update", subject: clean.subject) != nil)
        #expect(ReleaseNotifySpamLint.problem("Hi,\n\nPulse Diary 4.2.0 is live.", subject: clean.subject) != nil)
        #expect(ReleaseNotifySpamLint.problem(clean.body, subject: "PULSE DIARY LIVE") != nil)

        let wording = WordingRules(rules: [WordingRules.Rule(text: "clinically proven", why: "no clinical study")])
        #expect(ReleaseNotifySpamLint.problem(clean.body + "\nClinically proven calm.", subject: clean.subject, wording: wording) != nil)

        #expect(ReleaseNotifySpamLint.problem(
            "Hi,\n\nPulse Diary 4.1.9 is live.\nReply unsubscribe anytime.",
            subject: clean.subject,
            versions: ["Pulse Diary": "4.2.0"]
        ) != nil)

        // Developer location leak per AGENTS.md.
        #expect(ReleaseNotifySpamLint.problem(clean.body + "\nBuilt based in India.", subject: clean.subject) != nil)
    }

    @Test func mailMatchDetectsUnsubscribesBouncesIgnoresUnknownAndPreventsDoubleApply() {
        var book = ReleaseSubscribersBook(subscribers: [
            ReleaseSubscriber(email: "alex@example.com", name: "Alex", apps: ["Pulse Diary"], addedAt: "2026-11-01"),
            ReleaseSubscriber(email: "bob@example.org", name: "Bob", apps: ["Pulse Diary"], addedAt: "2026-11-01"),
            ReleaseSubscriber(email: "carol@example.net", name: "Carol", apps: ["Pulse Diary"], addedAt: "2026-11-01"),
        ])

        let mail = [
            ReplyMatch.Mail(
                id: "m-sub-unsub",
                from: "Alex <alex@example.com>",
                subject: "Unsubscribe",
                folder: "INBOX",
                day: "2026-11-26",
                text: "Thanks!"
            ),
            ReplyMatch.Mail(
                id: "m-body-unsub",
                from: "bob@example.org",
                subject: "Re: Pulse Diary 4.2.0 is now available",
                folder: "INBOX",
                day: "2026-11-26",
                text: "Please take me off this list.\n\n> On Nov 26 wrote:\n> If you'd rather not receive update notes..."
            ),
            ReplyMatch.Mail(
                id: "m-bounce",
                from: "MAILER-DAEMON@mx.example.com",
                subject: "Undelivered Mail Returned to Sender",
                folder: "INBOX",
                day: "2026-11-26",
                text: "550 5.1.1 <carol@example.net>: Recipient address rejected"
            ),
            ReplyMatch.Mail(
                id: "m-unknown",
                from: "stranger@example.com",
                subject: "Unsubscribe",
                folder: "INBOX",
                day: "2026-11-26",
                text: "unsubscribe"
            ),
            ReplyMatch.Mail(
                id: "m-sent",
                from: "alex@example.com",
                subject: "Unsubscribe",
                folder: "SENT",
                day: "2026-11-26",
                text: "unsubscribe"
            ),
        ]

        let detected = ReleaseSubscriberMailMatch.detect(mail: mail, book: book)
        #expect(detected.count == 3)
        let byMailID = Dictionary(detected.map { ($0.mailID, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byMailID["m-sub-unsub"]?.email == "alex@example.com")
        #expect(byMailID["m-sub-unsub"]?.kind == .unsubscribe)
        #expect(byMailID["m-body-unsub"]?.email == "bob@example.org")
        #expect(byMailID["m-body-unsub"]?.kind == .unsubscribe)
        #expect(byMailID["m-bounce"]?.email == "carol@example.net")
        #expect(byMailID["m-bounce"]?.kind == .bounce)

        let applied = ReleaseSubscriberMailMatch.apply(detected, to: &book)
        #expect(applied.count == 3)
        #expect(book.subscribers.allSatisfy { !$0.isActive })
        #expect(Set(book.processedMailIDs ?? []) == Set(["m-sub-unsub", "m-body-unsub", "m-bounce"]))
        #expect(book.mailActions?.count == 3)

        // Second pass with processedMailIDs prevents double-detecting/double-applying.
        let redetected = ReleaseSubscriberMailMatch.detect(mail: mail, book: book)
        #expect(redetected.isEmpty)
        let reapplied = ReleaseSubscriberMailMatch.apply(detected, to: &book)
        #expect(reapplied.isEmpty)
        #expect(book.mailActions?.count == 3)
    }
}
