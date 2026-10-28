import AppKit
import Foundation
import PDFKit

/// Clean-room spreadsheet conversions without bundled POI.
/// Supports CSV / TSV / XLSX / ODS (+ PDF out, PDF→XLSX best-effort). XLS needs external tool.
enum SpreadsheetConverter {
    static func convert(source: URL, action: FanAction) throws -> URL {
        let kind = FileKind.classify(url: source)

        if kind == .pdf, action == .convertToXLSX {
            return try pdfToXLSX(source: source)
        }

        let table = try readTable(from: source)

        switch action {
        case .convertToCSV:
            return try writeDelimited(table, source: source, ext: "csv", separator: ",")
        case .convertToTSV:
            return try writeDelimited(table, source: source, ext: "tsv", separator: "\t")
        case .convertToXLSX:
            return try writeXLSX(table, source: source)
        case .convertToODS:
            return try writeODS(table, source: source)
        case .convertToPDF:
            return try writePDF(table, source: source)
        default:
            throw ConversionError.unsupported
        }
    }

    // MARK: - Read

    private static func readTable(from source: URL) throws -> [[String]] {
        let kind = FileKind.classify(url: source)
        switch kind {
        case .csv:
            return try parseDelimited(String(contentsOf: source, encoding: .utf8), separator: ",")
        case .tsv:
            return try parseDelimited(String(contentsOf: source, encoding: .utf8), separator: "\t")
        case .xlsx:
            return try readXLSX(source: source)
        case .ods:
            return try readODS(source: source)
        case .xls:
            throw ConversionError.toolMissing("xls→xlsx (install LibreOffice/ssconvert or convert to CSV first)")
        default:
            throw ConversionError.unsupported
        }
    }

    private static func parseDelimited(_ text: String, separator: Character) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                        continue
                    }
                    inQuotes = false
                    i += 1
                    continue
                }
                field.append(c)
                i += 1
                continue
            }
            if c == "\"" {
                inQuotes = true
                i += 1
                continue
            }
            if c == separator {
                row.append(field)
                field = ""
                i += 1
                continue
            }
            if c == "\n" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
                i += 1
                continue
            }
            field.append(c)
            i += 1
        }
        row.append(field)
        if !(row.count == 1 && row[0].isEmpty && rows.isEmpty) {
            rows.append(row)
        }
        return rows
    }

    private static func readXLSX(source: URL) throws -> [[String]] {
        let tmp = try unzipToTemp(source)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sheet = tmp.appendingPathComponent("xl/worksheets/sheet1.xml")
        let shared = tmp.appendingPathComponent("xl/sharedStrings.xml")
        let strings = try loadSharedStrings(shared)
        let xml = try String(contentsOf: sheet, encoding: .utf8)
        return parseSheetXML(xml, shared: strings)
    }

    private static func readODS(source: URL) throws -> [[String]] {
        let tmp = try unzipToTemp(source)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let content = tmp.appendingPathComponent("content.xml")
        let xml = try String(contentsOf: content, encoding: .utf8)
        return parseODSContent(xml)
    }

    private static func loadSharedStrings(_ url: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let xml = try String(contentsOf: url, encoding: .utf8)
        var result: [String] = []
        // Match <si>…</si> blocks and take concatenated <t> text.
        let siPattern = try NSRegularExpression(pattern: #"<si>(.*?)</si>"#, options: [.dotMatchesLineSeparators])
        let tPattern = try NSRegularExpression(pattern: #"<t[^>]*>(.*?)</t>"#, options: [.dotMatchesLineSeparators])
        let ns = xml as NSString
        let matches = siPattern.matches(in: xml, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let block = ns.substring(with: m.range(at: 1))
            let tMatches = tPattern.matches(in: block, range: NSRange(location: 0, length: (block as NSString).length))
            var text = ""
            for tm in tMatches {
                text += ((block as NSString).substring(with: tm.range(at: 1)))
            }
            result.append(decodeXML(text))
        }
        return result
    }

    private static func parseSheetXML(_ xml: String, shared: [String]) -> [[String]] {
        var grid: [Int: [Int: String]] = [:]
        var maxRow = 0
        var maxCol = 0
        let rowPattern = try! NSRegularExpression(pattern: #"<row[^>]*?(?: r=\"(\d+)\")?[^>]*>(.*?)</row>"#, options: [.dotMatchesLineSeparators])
        let cellPattern = try! NSRegularExpression(
            pattern: #"<c([^>]*)>(?:<v>(.*?)</v>)?"#,
            options: [.dotMatchesLineSeparators]
        )
        let ns = xml as NSString
        let rows = rowPattern.matches(in: xml, range: NSRange(location: 0, length: ns.length))
        var rowIndex = 0
        for rm in rows {
            if rm.range(at: 1).location != NSNotFound,
               let r = Int(ns.substring(with: rm.range(at: 1))) {
                rowIndex = r - 1
            }
            let body = ns.substring(with: rm.range(at: 2))
            let cells = cellPattern.matches(in: body, range: NSRange(location: 0, length: (body as NSString).length))
            var colIndex = 0
            for cm in cells {
                let attrs = (body as NSString).substring(with: cm.range(at: 1))
                if let ref = attrValue(attrs, key: "r"), let parsed = cellRef(ref) {
                    colIndex = parsed.col
                    rowIndex = parsed.row
                }
                let isShared = attrs.contains("t=\"s\"")
                var value = ""
                if cm.range(at: 2).location != NSNotFound {
                    value = (body as NSString).substring(with: cm.range(at: 2))
                    if isShared, let idx = Int(value), shared.indices.contains(idx) {
                        value = shared[idx]
                    }
                }
                grid[rowIndex, default: [:]][colIndex] = decodeXML(value)
                maxRow = max(maxRow, rowIndex)
                maxCol = max(maxCol, colIndex)
                colIndex += 1
            }
            rowIndex += 1
        }
        var table: [[String]] = []
        for r in 0...maxRow {
            var row: [String] = []
            for c in 0...maxCol {
                row.append(grid[r]?[c] ?? "")
            }
            table.append(row)
        }
        return table.isEmpty ? [[""]] : table
    }

    private static func parseODSContent(_ xml: String) -> [[String]] {
        var table: [[String]] = []
        let rowPattern = try! NSRegularExpression(
            pattern: #"<table:table-row\b[^>]*>(.*?)</table:table-row>"#,
            options: [.dotMatchesLineSeparators]
        )
        let cellPattern = try! NSRegularExpression(
            pattern: #"<table:table-cell\b([^>]*)>(?:.*?<text:p[^>]*>(.*?)</text:p>)?"#,
            options: [.dotMatchesLineSeparators]
        )
        let ns = xml as NSString
        for rm in rowPattern.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let body = ns.substring(with: rm.range(at: 1))
            var row: [String] = []
            for cm in cellPattern.matches(in: body, range: NSRange(location: 0, length: (body as NSString).length)) {
                let attrs = (body as NSString).substring(with: cm.range(at: 1))
                let repeatCount = Int(attrValue(attrs, key: "table:number-columns-repeated") ?? "1") ?? 1
                var value = ""
                if cm.range(at: 2).location != NSNotFound {
                    value = decodeXML((body as NSString).substring(with: cm.range(at: 2)))
                }
                for _ in 0..<min(repeatCount, 256) {
                    row.append(value)
                }
            }
            table.append(row)
        }
        return table.isEmpty ? [[""]] : table
    }

    // MARK: - Write

    private static func writeDelimited(_ table: [[String]], source: URL, ext: String, separator: String) throws -> URL {
        var lines: [String] = []
        for row in table {
            let fields = row.map { field -> String in
                if separator == "," {
                    if field.contains(",") || field.contains("\"") || field.contains("\n") {
                        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                    }
                }
                return field
            }
            lines.append(fields.joined(separator: separator))
        }
        let out = OutputNamer.adjacent(for: source, ext: ext)
        try lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    private static func writeXLSX(_ table: [[String]], source: URL) throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-xlsx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try FileManager.default.createDirectory(at: staging.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("xl/_rels"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
          <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
        </Types>
        """
        try contentTypes.write(to: staging.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)

        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """
        try rels.write(to: staging.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)

        let wb = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """
        try wb.write(to: staging.appendingPathComponent("xl/workbook.xml"), atomically: true, encoding: .utf8)

        let wbRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
        </Relationships>
        """
        try wbRels.write(to: staging.appendingPathComponent("xl/_rels/workbook.xml.rels"), atomically: true, encoding: .utf8)

        var shared: [String] = []
        var sharedIndex: [String: Int] = [:]
        func sid(_ s: String) -> Int {
            if let i = sharedIndex[s] { return i }
            let i = shared.count
            shared.append(s)
            sharedIndex[s] = i
            return i
        }

        var sheetBody = ""
        for (r, row) in table.enumerated() {
            sheetBody += "<row r=\"\(r + 1)\">"
            for (c, value) in row.enumerated() {
                let ref = colName(c) + "\(r + 1)"
                if let num = Double(value), value == String(num) || Int(value) != nil {
                    sheetBody += "<c r=\"\(ref)\"><v>\(escapeXML(value))</v></c>"
                } else {
                    let i = sid(value)
                    sheetBody += "<c r=\"\(ref)\" t=\"s\"><v>\(i)</v></c>"
                }
            }
            sheetBody += "</row>"
        }
        let sheetXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>\(sheetBody)</sheetData>
        </worksheet>
        """
        try sheetXML.write(to: staging.appendingPathComponent("xl/worksheets/sheet1.xml"), atomically: true, encoding: .utf8)

        var si = ""
        for s in shared {
            si += "<si><t>\(escapeXML(s))</t></si>"
        }
        let sharedXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\(shared.count)" uniqueCount="\(shared.count)">
        \(si)
        </sst>
        """
        try sharedXML.write(to: staging.appendingPathComponent("xl/sharedStrings.xml"), atomically: true, encoding: .utf8)

        let out = OutputNamer.adjacent(for: source, ext: "xlsx")
        try zipDirectory(staging, to: out)
        return out
    }

    private static func writeODS(_ table: [[String]], source: URL) throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-ods-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("META-INF"), withIntermediateDirectories: true)

        let mime = "application/vnd.oasis.opendocument.spreadsheet"
        try mime.write(to: staging.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)

        let manifest = """
        <?xml version="1.0" encoding="UTF-8"?>
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0">
          <manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/>
          <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
        </manifest:manifest>
        """
        try manifest.write(to: staging.appendingPathComponent("META-INF/manifest.xml"), atomically: true, encoding: .utf8)

        var rowsXML = ""
        for row in table {
            rowsXML += "<table:table-row>"
            for cell in row {
                rowsXML += "<table:table-cell office:value-type=\"string\"><text:p>\(escapeXML(cell))</text:p></table:table-cell>"
            }
            rowsXML += "</table:table-row>"
        }
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content
          xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
          xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
          <office:body><office:spreadsheet>
            <table:table table:name="Sheet1">\(rowsXML)</table:table>
          </office:spreadsheet></office:body>
        </office:document-content>
        """
        try content.write(to: staging.appendingPathComponent("content.xml"), atomically: true, encoding: .utf8)

        let out = OutputNamer.adjacent(for: source, ext: "ods")
        try zipDirectory(staging, to: out)
        return out
    }

    private static func writePDF(_ table: [[String]], source: URL) throws -> URL {
        let pageRect = CGRect(x: 0, y: 0, width: 792, height: 612) // landscape letter
        let margin: CGFloat = 36
        let out = OutputNamer.adjacent(for: source, ext: "pdf")
        var mediaBox = pageRect
        guard let consumer = CGDataConsumer(url: out as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw ConversionError.writeFailed("pdf context")
        }

        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let colCount = max(1, table.map(\.count).max() ?? 1)
        let usableW = pageRect.width - margin * 2
        let colW = usableW / CGFloat(colCount)
        let rowH: CGFloat = 14
        var y = pageRect.height - margin - rowH

        ctx.beginPage(mediaBox: &mediaBox)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: pageRect.height)
        ctx.scaleBy(x: 1, y: -1)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        for row in table {
            if y < margin {
                NSGraphicsContext.restoreGraphicsState()
                ctx.restoreGState()
                ctx.endPage()
                ctx.beginPage(mediaBox: &mediaBox)
                ctx.saveGState()
                ctx.translateBy(x: 0, y: pageRect.height)
                ctx.scaleBy(x: 1, y: -1)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                NSGraphicsContext.saveGraphicsState()
                y = pageRect.height - margin - rowH
            }
            for (c, cell) in row.enumerated() {
                let rect = CGRect(x: margin + CGFloat(c) * colW, y: y, width: colW - 4, height: rowH)
                (cell as NSString).draw(in: rect, withAttributes: attrs)
            }
            y -= rowH
        }

        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
        ctx.endPage()
        ctx.closePDF()
        return out
    }

    private static func pdfToXLSX(source: URL) throws -> URL {
        guard let doc = PDFDocument(url: source) else { throw ConversionError.readFailed }
        var rows: [[String]] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let text = page.string else { continue }
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                let cols = trimmed.split(whereSeparator: { $0 == "\t" || $0 == "," }).map(String.init)
                rows.append(cols.isEmpty ? [trimmed] : cols)
            }
        }
        if rows.isEmpty { rows = [[""]] }
        return try writeXLSX(rows, source: source)
    }

    // MARK: - Helpers

    private static func unzipToTemp(_ source: URL) throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-sheet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let unzipBin = "/usr/bin/unzip"
        guard FileManager.default.isExecutableFile(atPath: unzipBin) else {
            throw ConversionError.toolMissing("unzip")
        }
        try ProcessRunner.run(unzipBin, arguments: ["-o", source.path, "-d", dest.path])
        return dest
    }

    private static func zipDirectory(_ dir: URL, to out: URL) throws {
        let zipBin = "/usr/bin/zip"
        guard FileManager.default.isExecutableFile(atPath: zipBin) else {
            throw ConversionError.toolMissing("zip")
        }
        if FileManager.default.fileExists(atPath: out.path) {
            try FileManager.default.removeItem(at: out)
        }
        try ProcessRunner.run(zipBin, arguments: ["-r", "-X", out.path, "."], cwd: dir)
    }

    private static func colName(_ index: Int) -> String {
        var n = index
        var s = ""
        repeat {
            s = String(UnicodeScalar(65 + n % 26)!) + s
            n = n / 26 - 1
        } while n >= 0
        return s
    }

    private static func cellRef(_ ref: String) -> (row: Int, col: Int)? {
        let chars = Array(ref)
        var i = 0
        var col = 0
        while i < chars.count, chars[i].isLetter {
            col = col * 26 + Int(chars[i].asciiValue! - 64)
            i += 1
        }
        guard i < chars.count, let row = Int(String(chars[i...])) else { return nil }
        return (row - 1, col - 1)
    }

    private static func attrValue(_ attrs: String, key: String) -> String? {
        let pattern = #"\#(key)=\"([^\"]*)\""#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: attrs, range: NSRange(location: 0, length: (attrs as NSString).length)),
              m.range(at: 1).location != NSNotFound
        else { return nil }
        return (attrs as NSString).substring(with: m.range(at: 1))
    }

    private static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func decodeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
