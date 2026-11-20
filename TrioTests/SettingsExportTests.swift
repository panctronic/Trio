import Foundation
import Testing

@testable import Trio

/// Covers the CSV rendering used by `SettingsExport.StateModel.exportSettings`
/// (`ExportSetting.csv`) and the export error descriptions.
@Suite("Settings Export Tests") struct SettingsExportTests {
    @Test("Values with commas, quotes or line breaks are quoted, embedded quotes doubled") func csvEscapingSpecialCharacters() {
        #expect(ExportSetting.csvEscape("Test,Value\"With\nSpecial Characters") == "\"Test,Value\"\"With\nSpecial Characters\"")
        #expect(ExportSetting.csvEscape("a,b") == "\"a,b\"")
        #expect(ExportSetting.csvEscape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(ExportSetting.csvEscape("line\rbreak") == "\"line\rbreak\"")
    }

    @Test("Plain values are left unquoted") func csvEscapingSimple() {
        #expect(ExportSetting.csvEscape("SimpleValue") == "SimpleValue")
        #expect(ExportSetting.csvEscape("") == "")
        #expect(ExportSetting.csvEscape("5.5 mmol/L; 0.1 U") == "5.5 mmol/L; 0.1 U")
    }

    @Test("CSV starts with a BOM and the five-column header") func csvHeader() {
        let csv = ExportSetting.csv([])

        #expect(csv == "\u{FEFF}Setting Category,Subcategory,Setting Name,Value,Unit\n")
        #expect(ExportSetting.csvHeader.components(separatedBy: ",").count == 5)
    }

    @Test("Each setting becomes one escaped row in column order") func csvRows() {
        let csv = ExportSetting.csv([
            ExportSetting(category: "Therapy", subcategory: "Basal", name: "00:00", value: "0.85", unit: "U/hr"),
            ExportSetting(category: "Algorithm", name: "Max IOB", value: "8"),
            ExportSetting(category: "Presets", subcategory: "Pizza, large", name: "Note", value: "the \"big\" one")
        ])

        let lines = csv.components(separatedBy: "\n")
        #expect(lines == [
            "\u{FEFF}Setting Category,Subcategory,Setting Name,Value,Unit",
            "Therapy,Basal,00:00,0.85,U/hr",
            "Algorithm,,Max IOB,8,",
            "Presets,\"Pizza, large\",Note,\"the \"\"big\"\" one\",",
            ""
        ])
    }

    @Test("Every export error has a user-facing description") func exportErrorDescriptions() {
        let errors: [SettingsExport.StateModel.ExportError] = [
            .documentsDirectoryNotFound,
            .fileWriteError(TestError("disk full")),
            .unknown("Test message")
        ]

        for error in errors {
            let description = error.errorDescription
            #expect(description != nil)
            #expect(description?.isEmpty == false)
        }
    }
}
