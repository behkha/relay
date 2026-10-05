import Foundation

/// Checks run by `Relay --self-test` (scripts/selftest.sh). Package.swift has no test target and XCTest
/// isn't guaranteed with only the Command Line Tools, so the app carries its own small harness.
/// It runs before NSApplication, listeners, hooks or UI exist, and only ever touches temp files.
enum SelfTest {
    private static var passed = 0
    private static var failures: [String] = []

    /// Runs every suite and prints a summary. True when all checks passed.
    static func runAll() -> Bool {
        harness()
        print("\(passed) passed, \(failures.count) failed")
        if !failures.isEmpty { print("Failed: " + failures.joined(separator: ", ")) }
        return failures.isEmpty
    }

    /// Records one check and prints `PASS name` or `FAIL name`. A thrown error counts as a failure.
    static func check(_ name: String, _ condition: @autoclosure () throws -> Bool) {
        do {
            if try condition() {
                passed += 1
                print("PASS \(name)")
            } else {
                failures.append(name)
                print("FAIL \(name)")
            }
        } catch {
            failures.append(name)
            print("FAIL \(name) (\(error))")
        }
    }

    // MARK: - Harness

    private static func harness() {
        check("harness: a true check passes", 1 + 1 == 2)
    }
}
