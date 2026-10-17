import Testing
@testable import MediaCore

struct ExposureTriangleTests {
    @Test func referenceIsNeitherBrighterNorDarker() {
        #expect(ExposureSetting.reference.stopsFromReference == 0)
    }

    @Test func eachKnobAddsOneStopPerStep() {
        let reference = ExposureSetting.reference
        var wider = reference; wider.aperture -= 1
        var slower = reference; slower.shutter += 1
        var higher = reference; higher.iso += 1
        #expect(wider.stopsFromReference == 1 && slower.stopsFromReference == 1 && higher.stopsFromReference == 1)
    }

    /// The recipes are different pictures with the same brightness: all lie on the slab of equal exposure.
    @Test func everyRecipeIsExposedAlike() {
        for recipe in ExposureRecipe.allCases { #expect(recipe.setting.stopsFromReference == 0, "\(recipe)") }
        #expect(Set(ExposureRecipe.allCases.map { "\($0.setting)" }).count == ExposureRecipe.allCases.count)
    }

    @Test func settingsStayOnTheirScales() {
        for recipe in ExposureRecipe.allCases {
            let s = recipe.setting
            #expect((0..<ExposureSetting.apertureSteps).contains(s.aperture), "\(recipe)")
            #expect((0..<ExposureSetting.shutterSteps).contains(s.shutter), "\(recipe)")
            #expect((0..<ExposureSetting.isoSteps).contains(s.iso), "\(recipe)")
        }
    }

    /// The 3D view's axes: how far each knob is turned adds up to the exposure plus a constant.
    @Test func turnsAddUpToTheExposure() {
        let reference = ExposureSetting.reference.turns
        let constant = reference.opening + reference.shutter + reference.iso
        for aperture in 0..<ExposureSetting.apertureSteps {
            for shutter in 0..<ExposureSetting.shutterSteps {
                for iso in 0..<ExposureSetting.isoSteps {
                    let setting = ExposureSetting(aperture: aperture, shutter: shutter, iso: iso)
                    let turns = setting.turns
                    #expect(turns.opening + turns.shutter + turns.iso - constant == setting.stopsFromReference)
                }
            }
        }
    }
}
