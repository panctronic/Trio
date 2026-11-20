struct ExportSetting: Codable {
    let category: String
    let subcategory: String
    let name: String
    let value: String
    let unit: String

    init(category: String, subcategory: String = "", name: String, value: String, unit: String = "") {
        self.category = category
        self.subcategory = subcategory
        self.name = name
        self.value = value
        self.unit = unit
    }
}

struct ExportSettingPayload: Codable {
    let exportFormat: String
    let exportDate: String
    let settings: [ExportSetting]
}

extension ExportSetting {
    /// Header row of the settings export CSV (without the leading byte order mark).
    static let csvHeader = "Setting Category,Subcategory,Setting Name,Value,Unit"

    /// Renders settings as the CSV written by the settings export: a UTF-8 byte
    /// order mark (so spreadsheet apps detect the encoding), the header row,
    /// then one row per setting, each line terminated by "\n".
    static func csv(_ settings: [ExportSetting]) -> String {
        var csv = "\u{FEFF}\(csvHeader)\n"
        for setting in settings {
            csv += [setting.category, setting.subcategory, setting.name, setting.value, setting.unit]
                .map(csvEscape)
                .joined(separator: ",") + "\n"
        }
        return csv
    }

    /// Quotes a field that contains a comma, double quote, CR or LF, doubling
    /// any embedded double quotes (RFC 4180). Other values are returned as is.
    static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
