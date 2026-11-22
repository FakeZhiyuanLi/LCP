import Foundation
import XCTest
import LCPContextCore
@testable import LCPContextServices

private final class CanvasFixtureProtocol: URLProtocol {
    static let site = "https://canvas.eee.uci.edu"
    static let nextCourses = site + "/api/v1/courses?enrollment_state=active&page=opaque,token"
    static var quizListStatus: Int?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return XCTFail("missing request URL") }
        XCTAssertEqual(request.httpMethod, "GET")
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        if url.host == "files.instructureusercontent.com" {
            XCTAssertNil(authorization)
            return send("PDF", type: "application/pdf")
        }
        XCTAssertEqual(url.host, "canvas.eee.uci.edu")
        XCTAssertEqual(authorization, "Bearer test-token")
        switch url.path {
        case "/api/v1/courses":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.contains(URLQueryItem(name: "page", value: "opaque,token")) {
                return send(#"[{"id":46,"name":"Algorithms","course_code":"TEST 46"}]"#)
            }
            XCTAssertTrue(query.contains(URLQueryItem(name: "enrollment_type", value: "student")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "enrollment_state", value: "active")))
            send(#"[{"id":40,"name":"Computing","course_code":"TEST 40"}]"#, link: "<\(Self.nextCourses)>; rel=\"next\", <\(Self.site)/api/v1/courses?page=1>; rel=\"first\"")
        case "/api/v1/courses/46/assignments":
            send(#"[{"id":11,"name":"Project One","due_at":"2026-11-23T12:00:00Z"}]"#)
        case "/api/v1/courses/46/assignments/11":
            send(#"{"id":11,"course_id":46,"name":"Project One","due_at":"2026-11-23T12:00:00Z","description":"<p>Describe A &amp; B.</p><p>Next line.<img alt='Square'></p><script>private script</script>"}"#)
        case "/api/v1/courses/46/assignments/99":
            send(#"{"id":99,"course_id":88,"name":"Unrelated"}"#)
        case "/api/v1/courses/46/assignments/12":
            send(#"{"id":12,"course_id":46,"name":"No deadline","due_at":null}"#)
        case "/api/v1/courses/46/assignments/13":
            send(#"{"id":13,"course_id":46,"name":"Fractional deadline","due_at":"2026-11-23T04:00:00.125-08:00"}"#)
        case "/api/v1/courses/46/assignments/14":
            send(#"{"id":14,"course_id":46,"name":"Ambiguous deadline","due_at":"2026-11-23"}"#)
        case "/api/v1/courses/46/assignments/15":
            send(#"{"id":15,"course_id":46,"name":"Locked assignment","locked_for_user":true}"#)
        case "/api/v1/courses/46/quizzes":
            if let status = Self.quizListStatus { return send("[]", status: status) }
            send(#"[{"id":12,"course_id":46,"title":"Quiz Seven","due_at":"2026-11-24T12:00:00Z","published":true},{"id":13,"course_id":46,"title":"Hidden quiz","published":false}]"#)
        case "/api/v1/courses/46/quizzes/12":
            send(#"{"id":12,"course_id":46,"title":"Quiz Seven","due_at":"2026-11-24T12:00:00Z","description":"<p>Explain the table.</p>","published":true}"#)
        case "/api/v1/courses/46/quizzes/99":
            send(#"{"id":99,"course_id":88,"title":"Wrong course"}"#)
        case "/api/v1/courses/46/pages":
            send(#"[{"page_id":92,"title":"Study Sheet","url":"72"},{"page_id":93,"title":"Missing slug","url":null},{"page_id":94,"title":"Unsafe slug","url":"../private"}]"#)
        case "/api/v1/courses/46/pages/72":
            send(#"{"page_id":92,"title":"Study Sheet","body":"<p>Week seven</p>","url":"72"}"#)
        case "/api/v1/courses/46/pages/other":
            send(#"{"page_id":92,"title":"Study Sheet","body":"<p>Week seven</p>","url":"72"}"#)
        case "/api/v1/courses/46":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(query.contains(URLQueryItem(name: "include[]", value: "syllabus_body")))
            send(#"{"id":46,"name":"Data Structures","syllabus_body":"<p>Use the <a href='/courses/46/files/1?verifier=temp'>reading</a>.</p>"}"#)
        case "/api/v1/courses/46/files":
            send(#"[{"id":1,"display_name":"Week Seven","filename":"week7.pdf","size":3},{"id":2,"filename":"hidden.pdf","hidden_for_user":true},{"id":3,"filename":"locked.pdf","locked_for_user":true}]"#)
        case "/api/v1/courses/46/files/1":
            send(#"{"id":1,"filename":"week7.pdf","url":"https://files.instructureusercontent.com/x?verifier=sample","size":3,"content-type":"application/pdf"}"#)
        case "/api/v1/courses/46/files/3":
            send(#"{"id":3,"filename":"locked.pdf","locked_for_user":true}"#)
        case "/api/v1/courses/46/files/4":
            send(#"{"id":4,"filename":"week7.pdf","url":"https://files.instructureusercontent.com/x","size":8}"#)
        case "/api/v1/courses/46/modules":
            send(#"[{"id":7,"name":"Module 7","items_count":7},{"id":8,"name":"Module 8","state":"locked"}]"#)
        case "/api/v1/courses/46/modules/7/items":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.contains(URLQueryItem(name: "page", value: "two")) { return send("[]") }
            send("""
                [{"id":100,"module_id":7,"title":"Read first","type":"SubHeader"},
                 {"id":109,"module_id":7,"title":"File","type":"File","content_id":1},
                 {"id":107,"module_id":7,"title":"Page","type":"Page","page_url":"72"},
                 {"id":106,"module_id":7,"title":"Homework","type":"Assignment","content_id":11},
                 {"id":113,"module_id":7,"title":"Module reading","type":"ExternalUrl","external_url":"https://example.edu/reading/week-seven"},
                 {"id":114,"module_id":7,"title":"Signed link","type":"ExternalUrl","external_url":"https://example.edu/reading?token=fixture-secret"},
                 {"id":157,"module_id":7,"title":"Locked file","type":"File","content_id":4,"content_details":{"locked_for_user":true}},
                 {"id":118,"module_id":7,"title":"Relinked","type":"File","content_id":1},
                 {"id":120,"module_id":7,"title":"Forum","type":"Discussion","content_id":201},
                 {"id":121,"module_id":7,"title":"Quiz","type":"Quiz","content_id":12}]
                """, link: "<\(Self.site)/api/v1/courses/46/modules/7/items?page=two>; rel=\"next\"")
        case "/api/v1/courses/46/modules/7/items/109":
            send(#"{"id":109,"module_id":7,"title":"File","type":"File","content_id":1}"#)
        case "/api/v1/courses/46/modules/7/items/107":
            send(#"{"id":107,"module_id":7,"title":"Page","type":"Page","page_url":"72"}"#)
        case "/api/v1/courses/46/modules/7/items/106":
            send(#"{"id":106,"module_id":7,"title":"Homework","type":"Assignment","content_id":11}"#)
        case "/api/v1/courses/46/modules/7/items/113":
            send(#"{"id":113,"module_id":7,"title":"Module reading","type":"ExternalUrl","external_url":"https://example.edu/reading/week-seven"}"#)
        case "/api/v1/courses/46/modules/7/items/114":
            send(#"{"id":114,"module_id":7,"title":"Signed link","type":"ExternalUrl","external_url":"https://example.edu/reading?token=fixture-secret"}"#)
        case "/api/v1/courses/46/modules/7/items/118":
            send(#"{"id":118,"module_id":7,"title":"Relinked","type":"File","content_id":4}"#)
        case "/api/v1/courses/46/modules/7/items/120":
            send(#"{"id":120,"module_id":7,"title":"Forum","type":"Discussion","content_id":201}"#)
        case "/api/v1/courses/46/modules/7/items/121":
            send(#"{"id":121,"module_id":7,"title":"Quiz","type":"Quiz","content_id":12}"#)
        case "/api/v1/courses/46/discussion_topics":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.contains(URLQueryItem(name: "only_announcements", value: "true")) {
                send(#"[{"id":301,"course_id":46,"title":"Exam announcement","message":"<p>Review the practice set.</p>","posted_at":"2026-11-18T10:00:00Z"}]"#)
            } else {
                send(#"[{"id":201,"course_id":46,"title":"Week 7 questions","message":"<p>Bring one question.</p>","posted_at":"2026-11-17T10:00:00Z"},{"id":202,"course_id":46,"title":"Locked","locked_for_user":true}]"#)
            }
        case "/api/v1/courses/46/discussion_topics/201":
            send(#"{"id":201,"course_id":46,"title":"Week 7 questions","message":"<p>Bring one question.</p><p><strong>Use the forum.</strong></p>","posted_at":"2026-11-17T10:00:00Z"}"#)
        case "/api/v1/courses/46/discussion_topics/301":
            send(#"{"id":301,"course_id":46,"title":"Exam announcement","message":"<p>Review the practice set.</p>","posted_at":"2026-11-18T10:00:00Z"}"#)
        case "/api/v1/courses/46/discussion_topics/203":
            send(#"{"id":203,"course_id":88,"title":"Wrong course","message":"<p>Do not import.</p>"}"#)
        case "/api/v1/calendar_events":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(query.contains(URLQueryItem(name: "context_codes[]", value: "course_46")))
            send(#"[{"id":401,"title":"Review session","description":"<p>Bring your questions.</p>","start_at":"2026-11-19T18:00:00Z","end_at":"2026-11-19T19:00:00Z","context_code":"course_46","html_url":"https://canvas.eee.uci.edu/calendar?event_id=401"},{"id":402,"title":"Other course","context_code":"course_88"}]"#)
        case "/api/v1/calendar_events/401":
            send(#"{"id":401,"title":"Review session","description":"<p>Bring your questions.</p>","start_at":"2026-11-19T18:00:00Z","end_at":"2026-11-19T19:00:00Z","context_code":"course_46","location_name":"ICS 46 lab","html_url":"https://canvas.eee.uci.edu/calendar?event_id=401"}"#)
        case "/api/v1/calendar_events/402":
            send(#"{"id":402,"title":"Other course","context_code":"course_88"}"#)
        default:
            XCTFail("Unexpected Canvas fixture request: \(url.path)")
            send("{}", status: 404)
        }
    }

    private func send(_ body: String, type: String = "application/json", link: String? = nil, status: Int = 200) {
        var headers = ["Content-Type": type]
        headers["Link"] = link
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class UciCanvasClientTests: XCTestCase {
    private var canvas: UciCanvasClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CanvasFixtureProtocol.self]
        return UciCanvasClient(token: "test-token", http: UniversityHTTP(configuration: config))
    }

    func testActiveStudentCoursesAndOpaquePagination() async throws {
        let first = try await canvas.courses()
        XCTAssertEqual(first.items.map(\.id), ["40"])
        XCTAssertEqual(first.next, CanvasFixtureProtocol.nextCourses)
        let last = try await canvas.courses(cursor: try XCTUnwrap(first.next))
        XCTAssertEqual(last.items.map(\.detail), ["TEST 46"])
        XCTAssertNil(last.next)
    }

    func testBoundedPaginationHelpersCollectEveryPageAndStopAtTheLimit() async throws {
        let allCourses = try await canvas.allCourses().map(\.id)
        XCTAssertEqual(allCourses, ["40", "46"])
        let boundedCourses = try await canvas.allCourses(maximum: 1).map(\.id)
        XCTAssertEqual(boundedCourses, ["40"])
        let allAssignments = try await canvas.allItems(courseID: "46", kind: .assignments).map(\.id)
        XCTAssertEqual(allAssignments, ["11"])
        let boundedAssignments = try await canvas.allItems(courseID: "46", kind: .assignments, maximum: 1).map(\.id)
        XCTAssertEqual(boundedAssignments, ["11"])
    }

    func testAssignmentAndPageProduceSearchableSources() async throws {
        let assignments = try await canvas.items(courseID: "46", kind: .assignments)
        let item = try XCTUnwrap(assignments.items.first)
        XCTAssertTrue(item.detail.contains("2026-11-23"))
        let doc = try await canvas.document(courseID: "46", kind: .assignments, item: item)
        let body = String(decoding: doc.data, as: UTF8.self)
        XCTAssertEqual(doc.filename, "Project One.txt")
        XCTAssertEqual(doc.sourceURL.absoluteString, CanvasFixtureProtocol.site + "/courses/46/assignments/11")
        XCTAssertTrue(body.contains("Describe A & B."))
        XCTAssertTrue(body.contains("Next line.Square"))
        XCTAssertFalse(body.contains("private script"))
        XCTAssertEqual(doc.courseworkContext?.title, "Project One")
        XCTAssertEqual(doc.courseworkContext?.dueAt, ISO8601DateFormatter().date(from: "2026-11-23T12:00:00Z"))
        let pages = try await canvas.items(courseID: "46", kind: .pages)
        XCTAssertEqual(pages.items.map(\.id), ["92"])
        XCTAssertEqual(pages.items.first?.metadata["pageSlug"], "72")
        let page = try await canvas.document(courseID: "46", kind: .pages, item: try XCTUnwrap(pages.items.first))
        XCTAssertEqual(page.sourceURL.path, "/courses/46/pages/72")
        XCTAssertTrue(String(decoding: page.data, as: UTF8.self).contains("Week seven"))
        XCTAssertNil(page.courseworkContext)
        for item in [
            UniversityItem(id: "92", title: "Study Sheet", detail: "", metadata: ["pageSlug": "other"]),
            UniversityItem(id: "92", title: "Study Sheet", detail: ""),
            UniversityItem(id: "92", title: "Study Sheet", detail: "", metadata: ["pageSlug": "../private"])
        ] {
            do {
                _ = try await canvas.document(courseID: "46", kind: .pages, item: item)
                XCTFail("Expected stale, missing, or malformed page slug to fail")
            } catch is UniversityServiceError {}
        }
    }

    func testCourseworkDeadlinesKeepInstantsAndRejectAmbiguousDatesBeforeImport() async throws {
        let noDeadline = try await canvas.document(courseID: "46", kind: .assignments,
            item: .init(id: "12", title: "Untrusted listing title", detail: ""))
        XCTAssertEqual(noDeadline.courseworkContext?.title, "No deadline", "Use refreshed detail facts, not the older list row")
        XCTAssertNil(noDeadline.courseworkContext?.dueAt)
        let fractional = try await canvas.document(courseID: "46", kind: .assignments,
            item: .init(id: "13", title: "Assignment", detail: ""))
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-23T12:00:00Z"))
        XCTAssertEqual(try XCTUnwrap(fractional.courseworkContext?.dueAt).timeIntervalSince(expected), 0.125, accuracy: 0.001)
        for id in ["14", "15", "99"] {
            do {
                _ = try await canvas.document(courseID: "46", kind: .assignments,
                    item: .init(id: id, title: "Assignment", detail: ""))
                XCTFail("Expected invalid, locked, or wrong-course coursework to fail")
            } catch is UniversityServiceError {}
        }
    }

    @MainActor func testCanvasApiAssignmentBecomesReviewedOfflineCoursework() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lcp-canvas-coursework-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("library"))
        let term = AcademicTerm(name: "Synthetic Fall", timeZoneID: "America/Los_Angeles")
        let enrollment = ClassEnrollment(termID: term.id, courseCode: "SYN 46", title: "Synthetic algorithms")
        try repository.update { $0.terms.append(term); $0.classes.append(enrollment) }
        let document = try await canvas.document(courseID: "46", kind: .assignments,
            item: .init(id: "11", title: "Project One", detail: ""))
        let material = try MaterialService(repository: repository).importUniversityDocument(document, classID: enrollment.id,
            provider: "uci-canvas", remoteID: XCTUnwrap(document.remoteID), title: "Project One")
        XCTAssertTrue(repository.state.coursework.isEmpty)
        let coursework = CourseworkService(repository: repository)
        let item = try coursework.accept(coursework.reviewCanvasMaterial(material.id))
        let reopened = try ContextRepository(rootURL: repository.rootURL)
        XCTAssertEqual(reopened.state.coursework.first, item)
        XCTAssertEqual(item.due, .timed(instant: try XCTUnwrap(document.courseworkContext?.dueAt), timeZoneID: term.timeZoneID))
        let passage = try RetrievalService(repository: reopened).resolve(XCTUnwrap(item.sourceCitation))
        XCTAssertTrue(passage.text.contains("Due: 2026-11-23T12:00:00Z"))
        XCTAssertTrue(passage.text.contains("Describe A & B."))
    }

    func testQuizzesStayCourseScopedAndImportAsSearchableSources() async throws {
        let quizzes = try await canvas.items(courseID: "46", kind: .quizzes)
        XCTAssertEqual(quizzes.items.map(\.id), ["12"])
        let quiz = try XCTUnwrap(quizzes.items.first)
        XCTAssertTrue(quiz.detail.contains("2026-11-24"))
        let doc = try await canvas.document(courseID: "46", kind: .quizzes, item: quiz)
        XCTAssertEqual(doc.remoteID, "46/quizzes/12")
        XCTAssertEqual(doc.courseworkContext?.kind, "quiz")
        XCTAssertEqual(doc.sourceURL.path, "/courses/46/quizzes/12")
        XCTAssertTrue(String(decoding: doc.data, as: UTF8.self).contains("Explain the table."))
        do {
            _ = try await canvas.document(courseID: "46", kind: .quizzes,
                                          item: .init(id: "99", title: "Wrong course", detail: ""))
            XCTFail("Expected an unrelated quiz to fail")
        } catch is UniversityServiceError {}
    }

    func testUnavailableQuizFeatureIsAnEmptyCollection() async throws {
        CanvasFixtureProtocol.quizListStatus = 404
        defer { CanvasFixtureProtocol.quizListStatus = nil }
        let quizzes = try await canvas.items(courseID: "46", kind: .quizzes)
        XCTAssertTrue(quizzes.items.isEmpty)
        XCTAssertNil(quizzes.next)
    }

    func testFileDownloadExcludesHiddenAndLockedFilesAndKeepsStableSource() async throws {
        let files = try await canvas.items(courseID: "46", kind: .files)
        XCTAssertEqual(files.items.map(\.id), ["1"])
        let doc = try await canvas.document(courseID: "46", kind: .files, item: try XCTUnwrap(files.items.first))
        XCTAssertEqual(doc.data, Data("PDF".utf8))
        XCTAssertEqual(doc.filename, "week7.pdf")
        XCTAssertEqual(doc.sourceURL.absoluteString, CanvasFixtureProtocol.site + "/courses/46/files/1")
        for id in ["3", "4"] {
            do {
                _ = try await canvas.document(courseID: "46", kind: .files, item: .init(id: id, title: "File", detail: ""))
                XCTFail("Expected locked or incomplete file to fail")
            } catch is UniversityServiceError {}
        }
    }

    func testCourseSyllabusRetainsAnOrdinaryReferenceToAnAttachedReading() async throws {
        let items = try await canvas.items(courseID: "46", kind: .syllabus)
        let doc = try await canvas.document(courseID: "46", kind: .syllabus, item: try XCTUnwrap(items.items.first))
        XCTAssertEqual(doc.sourceURL.absoluteString, CanvasFixtureProtocol.site + "/courses/46/assignments/syllabus")
        let content = String(decoding: doc.data, as: UTF8.self)
        XCTAssertTrue(content.contains("reading (https://canvas.eee.uci.edu/courses/46/files/1)"))
        XCTAssertFalse(content.contains("verifier"))
    }

    func testDiscussionTopicsAreBoundToTheCourseAndImportAsInertText() async throws {
        let topics = try await canvas.items(courseID: "46", kind: .discussionTopics)
        XCTAssertEqual(topics.items.map(\.id), ["201"])
        let topic = try XCTUnwrap(topics.items.first)
        let doc = try await canvas.document(courseID: "46", kind: .discussionTopics, item: topic)
        XCTAssertEqual(doc.remoteID, "46/discussion_topics/201")
        XCTAssertEqual(doc.sourceURL.path, "/courses/46/discussion_topics/201")
        let content = String(decoding: doc.data, as: UTF8.self)
        XCTAssertTrue(content.contains("Bring one question."))
        XCTAssertTrue(content.contains("Use the forum."))
        do {
            _ = try await canvas.document(courseID: "46", kind: .discussionTopics,
                                          item: .init(id: "203", title: "Wrong course", detail: ""))
            XCTFail("Expected a discussion topic from another course to fail")
        } catch is UniversityServiceError {}
    }

    func testAnnouncementsAndCalendarEventsStayCourseScoped() async throws {
        let announcements = try await canvas.items(courseID: "46", kind: .announcements)
        let announcement = try XCTUnwrap(announcements.items.first)
        XCTAssertEqual(announcement.title, "Exam announcement")
        let announcementDoc = try await canvas.document(courseID: "46", kind: .announcements, item: announcement)
        XCTAssertEqual(announcementDoc.remoteID, "46/announcements/301")
        XCTAssertTrue(String(decoding: announcementDoc.data, as: UTF8.self).contains("Review the practice set."))

        let events = try await canvas.items(courseID: "46", kind: .calendarEvents)
        XCTAssertEqual(events.items.map(\.id), ["401"])
        XCTAssertTrue(events.items.first?.detail.contains("2026-11-19") == true)
        let eventDoc = try await canvas.document(courseID: "46", kind: .calendarEvents, item: try XCTUnwrap(events.items.first))
        XCTAssertEqual(eventDoc.remoteID, "46/calendar_events/401")
        XCTAssertEqual(eventDoc.sourceURL.absoluteString, "https://canvas.eee.uci.edu/calendar?event_id=401")
        let body = String(decoding: eventDoc.data, as: UTF8.self)
        XCTAssertTrue(body.contains("Bring your questions."))
        XCTAssertTrue(body.contains("Location: ICS 46 lab"))

        do {
            _ = try await canvas.document(courseID: "46", kind: .calendarEvents,
                                          item: .init(id: "402", title: "Other course", detail: ""))
            XCTFail("Expected a calendar event from another course to fail")
        } catch is UniversityServiceError {}
    }

    func testPaginationAndFetchedObjectsStayInSelectedCourse() async throws {
        for url in ["https://unrelated.example/api/v1/courses/46/files?page=2",
                    CanvasFixtureProtocol.site + "/api/v1/courses/88/files?page=2"] {
            do {
                _ = try await canvas.items(courseID: "46", kind: .files, cursor: url)
                XCTFail("Expected mismatched course or origin to fail")
            } catch is UniversityServiceError {}
        }
        do {
            _ = try await canvas.document(courseID: "46", kind: .assignments, item: .init(id: "99", title: "Wrong course", detail: ""))
            XCTFail("Expected mismatched assignment to fail")
        } catch is UniversityServiceError {}
    }

    func testModuleBrowserPreservesOrderAndResolvesTheSameMaterialsAsDirectImport() async throws {
        let modules = try await canvas.items(courseID: "46", kind: .modules)
        XCTAssertEqual(modules.items.map(\.title), ["Module 7", "Module 8"])
        XCTAssertEqual(modules.items.last?.metadata["locked"], "true")
        let page = try await canvas.moduleItems(courseID: "46", moduleID: "7")
        XCTAssertEqual(page.items.map(\.id), ["100", "109", "107", "106", "113", "114", "157", "118", "120", "121"])
        XCTAssertEqual(page.items.map { $0.metadata["canvasKind"] }, [nil, "files", "pages", "assignments", "external_url", nil, nil, "files", "discussion_topics", "quizzes"])
        let next = try await canvas.moduleItems(courseID: "46", moduleID: "7", cursor: try XCTUnwrap(page.next))
        XCTAssertTrue(next.items.isEmpty)
        for (index, kind, id) in [(1, CanvasItemKind.files, "1"), (2, .pages, "92"), (3, .assignments, "11")] {
            let fromModule = try await canvas.document(courseID: "46", kind: .modules, item: page.items[index])
            let metadata = kind == .pages ? ["pageSlug": "72"] : [:]
            let direct = try await canvas.document(courseID: "46", kind: kind,
                                                   item: .init(id: id, title: "Direct", detail: "", metadata: metadata))
            XCTAssertEqual(fromModule.remoteID, "46/\(kind.rawValue)/\(id)")
            XCTAssertEqual(fromModule.remoteID, direct.remoteID)
            XCTAssertEqual(fromModule.data, direct.data)
            XCTAssertEqual(fromModule.sourceURL, direct.sourceURL)
        }
        do {
            _ = try await canvas.document(courseID: "46", kind: .modules, item: page.items[7])
            XCTFail("Relinked module item should require a fresh selection")
        } catch is UniversityServiceError {}
        let discussion = try await canvas.document(courseID: "46", kind: .modules, item: page.items[8])
        XCTAssertEqual(discussion.remoteID, "46/discussion_topics/201")
        let quiz = try await canvas.document(courseID: "46", kind: .modules, item: page.items[9])
        XCTAssertEqual(quiz.remoteID, "46/quizzes/12")

        let external = try await canvas.document(courseID: "46", kind: .modules, item: page.items[4])
        XCTAssertEqual(external.remoteID, "46/modules/7/items/113")
        XCTAssertEqual(external.sourceURL.absoluteString, "https://example.edu/reading/week-seven")
        XCTAssertTrue(String(decoding: external.data, as: UTF8.self).contains("https://example.edu/reading/week-seven"))
        do {
            _ = try await canvas.document(courseID: "46", kind: .modules, item: page.items[5])
            XCTFail("Signed external URLs should not be imported")
        } catch is UniversityServiceError {}
    }
}
