import XCTest

final class WidgetArtworkSnapshotStoreTests: XCTestCase {
    private var baseURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WidgetArtworkSnapshotStoreTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let baseURL {
            try? FileManager.default.removeItem(at: baseURL)
        }
        baseURL = nil
        try super.tearDownWithError()
    }

    func testConcurrentSuccessfulRefreshGeneratesSnapshotOnlyOnce() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let gate = AsyncGate()
        let counter = InvocationCounter()
        let generationStarted = expectation(description: "first generation started")
        let expectedSnapshot = makeSnapshot(cycleKey: "success-cycle")

        let firstTask = Task<WidgetArtworkSnapshotStore.Snapshot, Error> {
            try await store.generateSnapshot { _ in
                let attempt = await counter.increment()
                XCTAssertEqual(attempt, 1)
                generationStarted.fulfill()
                await gate.wait()
                return await store.store(expectedSnapshot, imageData: nil)
            }
        }

        await fulfillment(of: [generationStarted], timeout: 1.0)

        let secondTask = Task<WidgetArtworkSnapshotStore.Snapshot, Error> {
            try await store.generateSnapshot { _ in
                XCTFail("A successful widget refresh should not generate a second snapshot.")
                return await store.store(self.makeSnapshot(cycleKey: "unexpected"), imageData: nil)
            }
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        await gate.open()

        let firstSnapshot = try await firstTask.value
        let secondSnapshot = try await secondTask.value

        XCTAssertEqual(firstSnapshot.cycleKey, expectedSnapshot.cycleKey)
        XCTAssertEqual(secondSnapshot.cycleKey, expectedSnapshot.cycleKey)
        let invocationCount = await counter.currentValue()
        XCTAssertEqual(invocationCount, 1)
    }

    func testFailedRefreshDoesNotCountAsCompletedGeneration() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let counter = InvocationCounter()

        do {
            _ = try await store.generateSnapshot { _ in
                _ = await counter.increment()
                throw StubError.expectedFailure
            }
            XCTFail("The first widget refresh attempt should fail.")
        } catch let error as StubError {
            XCTAssertEqual(error, .expectedFailure)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let latestSnapshot = await store.loadLatest()
        XCTAssertNil(latestSnapshot)

        let expectedSnapshot = makeSnapshot(cycleKey: "retry-cycle")
        let retrySnapshot = try await store.generateSnapshot { latestSnapshot in
            XCTAssertNil(latestSnapshot)
            let attempt = await counter.increment()
            XCTAssertEqual(attempt, 2)
            return await store.store(expectedSnapshot, imageData: nil)
        }

        XCTAssertEqual(retrySnapshot.cycleKey, expectedSnapshot.cycleKey)
        let retryInvocationCount = await counter.currentValue()
        XCTAssertEqual(retryInvocationCount, 2)
    }

    func testStoreKeepsNewerManualRefreshSnapshotWhenOlderRequestFinishesLater() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let newerSnapshot = makeSnapshot(
            cycleKey: "single:tnm|tnm:all|images|19.0|1",
            generatedAt: 200,
            manualRefreshNonce: 19
        )
        let olderSnapshot = makeSnapshot(
            cycleKey: "single:tnm|tnm:all|images|17.0|1",
            generatedAt: 100,
            manualRefreshNonce: 17
        )

        let firstStored = await store.store(newerSnapshot, imageData: nil)
        let secondStored = await store.store(olderSnapshot, imageData: nil)
        let loadedSnapshot = await store.loadLatest()
        let loaded = try XCTUnwrap(loadedSnapshot)

        XCTAssertEqual(firstStored.cycleKey, newerSnapshot.cycleKey)
        XCTAssertEqual(secondStored.cycleKey, newerSnapshot.cycleKey)
        XCTAssertEqual(loaded.cycleKey, newerSnapshot.cycleKey)
        XCTAssertEqual(loaded.manualRefreshNonce, 19)
    }

    func testNewerManualRefreshStealsOlderGenerationLock() async throws {
        let store = WidgetArtworkSnapshotStore(baseURL: baseURL)
        let gate = AsyncGate()
        let olderGenerationStarted = expectation(description: "older generation started")
        let newerGenerationFinished = expectation(description: "newer generation finished")

        let olderTask = Task<WidgetArtworkSnapshotStore.Snapshot, Error> {
            try await store.generateSnapshot(manualRefreshNonce: 11) { _ in
                olderGenerationStarted.fulfill()
                await gate.wait()
                return await store.store(
                    self.makeSnapshot(
                        cycleKey: "older-cycle",
                        generatedAt: 100,
                        manualRefreshNonce: 11
                    ),
                    imageData: nil
                )
            }
        }

        await fulfillment(of: [olderGenerationStarted], timeout: 1.0)

        let newerTask = Task<WidgetArtworkSnapshotStore.Snapshot, Error> {
            let snapshot = try await store.generateSnapshot(manualRefreshNonce: 12) { _ in
                await store.store(
                    self.makeSnapshot(
                        cycleKey: "newer-cycle",
                        generatedAt: 200,
                        manualRefreshNonce: 12
                    ),
                    imageData: nil
                )
            }
            newerGenerationFinished.fulfill()
            return snapshot
        }

        await fulfillment(of: [newerGenerationFinished], timeout: 2.0)
        await gate.open()

        let newerSnapshot = try await newerTask.value
        let olderSnapshot = try await olderTask.value
        let loadedSnapshot = await store.loadLatest()
        let loaded = try XCTUnwrap(loadedSnapshot)

        XCTAssertEqual(newerSnapshot.cycleKey, "newer-cycle")
        XCTAssertEqual(olderSnapshot.cycleKey, "newer-cycle")
        XCTAssertEqual(loaded.cycleKey, "newer-cycle")
        XCTAssertEqual(loaded.manualRefreshNonce, 12)
    }

    private func makeSnapshot(
        cycleKey: String,
        generatedAt: TimeInterval = 100,
        manualRefreshNonce: Int = 0
    ) -> WidgetArtworkSnapshotStore.Snapshot {
        WidgetArtworkSnapshotStore.Snapshot(
            cycleKey: cycleKey,
            museumName: "大都会艺术博物馆",
            title: "Test Artwork",
            subtitle: "2026",
            imageFileName: nil,
            appURL: nil,
            generatedAt: generatedAt,
            manualRefreshNonce: manualRefreshNonce
        )
    }
}

private actor InvocationCounter {
    private(set) var value = 0

    func increment() -> Int {
        value += 1
        return value
    }

    func currentValue() -> Int {
        value
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private enum StubError: Error, Equatable {
    case expectedFailure
}
