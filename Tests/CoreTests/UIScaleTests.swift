import Foundation
import Testing

@testable import ShlCommander

@Suite("UIScale")
struct UIScaleTests {
    @Test("Actual Size is one of the steps")
    func standardIsAStep() {
        #expect(UIScale.steps.contains(UIScale.standard.factor))
    }

    @Test("steps are sorted and start below Actual Size")
    func stepsAreOrdered() {
        #expect(UIScale.steps == UIScale.steps.sorted())
        #expect(UIScale.minimum < UIScale.standard.factor)
        #expect(UIScale.maximum > UIScale.standard.factor)
    }

    @Test("zooming walks one step at a time and stops at the ends")
    func stepping() {
        var factor = UIScale.standard.factor
        for _ in UIScale.steps {
            factor = UIScale.zoomedIn(from: factor)
        }
        #expect(factor == UIScale.maximum)

        for _ in UIScale.steps {
            factor = UIScale.zoomedOut(from: factor)
        }
        #expect(factor == UIScale.minimum)
    }

    @Test("a factor between two steps snaps to the next one either way")
    func steppingOffLadder() {
        #expect(UIScale.zoomedIn(from: 1.05) == 1.15)
        #expect(UIScale.zoomedOut(from: 1.05) == 1.0)
    }

    @Test("points scale and never round away to nothing")
    func scalingPoints() {
        #expect(UIScale.standard(20) == 20)
        #expect(UIScale(factor: 1.5)(20) == 30)
        #expect(UIScale(factor: 0.75)(1) >= 1)
    }
}

@MainActor
@Suite("UI scale settings")
struct UIScaleSettingsTests {
    private func settings(_ label: String) -> (AppSettings, UserDefaults, String) {
        let suite = "shl-commander.tests.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AppSettings(defaults: defaults), defaults, suite)
    }

    @Test("the app starts at Actual Size and persists a zoom")
    func persistence() {
        let (settings, defaults, suite) = settings("scale")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        #expect(settings.uiScale == UIScale.standard.factor)
        settings.uiScale = 1.5
        #expect(defaults.double(forKey: "uiScale") == 1.5)
    }

    @Test("a factor outside the range is pulled back into it")
    func clamping() {
        let (settings, _, suite) = settings("clamp")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        settings.uiScale = 12
        #expect(settings.uiScale == UIScale.maximum)
        settings.uiScale = 0.1
        #expect(settings.uiScale == UIScale.minimum)
    }

    @Test("a stored factor of zero reads back as Actual Size")
    func zeroIsIgnored() {
        let suite = "shl-commander.tests.zero.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        defaults.set(0, forKey: "uiScale")
        #expect(AppSettings(defaults: defaults).uiScale == UIScale.standard.factor)
    }
}
