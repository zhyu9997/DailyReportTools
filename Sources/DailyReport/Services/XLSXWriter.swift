import Foundation

/// 极简 XLSX 写入器（单工作表，全部以 inlineStr 存字符串，stored 无压缩 ZIP）
/// 无第三方依赖，产物可被 Excel / Numbers / LibreOffice 正常打开。
struct XLSXWriter {
    private let sheetName: String
    private let rows: [[String]]

    init(sheetName: String = "Sheet1", rows: [[String]]) {
        self.sheetName = sheetName
        self.rows = rows
    }

    func data() -> Data {
        var entries: [(name: String, data: Data)] = []
        entries.append(("[Content_Types].xml", contentTypesXML()))
        entries.append(("_rels/.rels", rootRelsXML()))
        entries.append(("xl/workbook.xml", workbookXML()))
        entries.append(("xl/_rels/workbook.xml.rels", workbookRelsXML()))
        entries.append(("xl/worksheets/sheet1.xml", sheetXML()))
        return ZipBuilder().build(entries: entries)
    }

    // MARK: XML parts
    private func contentTypesXML() -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        </Types>
        """.utf8)
    }

    private func rootRelsXML() -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """.utf8)
    }

    private func workbookXML() -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets>
        <sheet name="\(escape(sheetName))" sheetId="1" r:id="rId1"/>
        </sheets>
        </workbook>
        """.utf8)
    }

    private func workbookRelsXML() -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        </Relationships>
        """.utf8)
    }

    private func sheetXML() -> Data {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        s += "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        s += "<sheetData>"
        for (rowIndex, row) in rows.enumerated() {
            s += "<row r=\"\(rowIndex + 1)\">"
            for (colIndex, value) in row.enumerated() {
                let ref = "\(columnLetter(colIndex + 1))\(rowIndex + 1)"
                s += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escape(value))</t></is></c>"
            }
            s += "</row>"
        }
        s += "</sheetData></worksheet>"
        return Data(s.utf8)
    }

    // MARK: helpers
    private func escape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // 过滤 XML 1.0 非法控制字符（保留制表符/换行/回车）
                let v = ch.value
                if v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D { continue }
                out += String(ch)
            }
        }
        return out
    }

    /// 1 索引列号 → 字母（1→A, 26→Z, 27→AA）
    private func columnLetter(_ n: Int) -> String {
        var n = n
        var out = ""
        while n > 0 {
            n -= 1
            out = String(Character(UnicodeScalar(65 + (n % 26))!)) + out
            n /= 26
        }
        return out
    }
}

/// 极简 ZIP 打包器（仅 stored，无压缩），符合 ZIP/File-Reader 规范
struct ZipBuilder {
    func build(entries: [(name: String, data: Data)]) -> Data {
        var output = Data()
        var central: [(name: String, crc: UInt32, size: UInt32, offset: UInt32)] = []
        let (dosDate, dosTime) = dosDateTime(Date())

        for entry in entries {
            let crc = crc32(entry.data)
            let offset = UInt32(output.count)
            let size = UInt32(entry.data.count)
            let nameBytes = Array(entry.name.utf8)

            // local file header
            output.appendUInt32(0x04034b50)
            output.appendUInt16(20)              // version needed
            output.appendUInt16(0)               // flags
            output.appendUInt16(0)               // method = stored
            output.appendUInt16(dosTime)
            output.appendUInt16(dosDate)
            output.appendUInt32(crc)
            output.appendUInt32(size)            // compressed size
            output.appendUInt32(size)            // uncompressed size
            output.appendUInt16(UInt16(nameBytes.count))
            output.appendUInt16(0)               // extra length
            output.append(contentsOf: nameBytes)
            output.append(entry.data)

            central.append((entry.name, crc, size, offset))
        }

        let cdOffset = UInt32(output.count)
        for c in central {
            let nameBytes = Array(c.name.utf8)
            // central directory header
            output.appendUInt32(0x02014b50)
            output.appendUInt16(20)              // version made by
            output.appendUInt16(20)              // version needed
            output.appendUInt16(0)               // flags
            output.appendUInt16(0)               // method
            output.appendUInt16(dosTime)
            output.appendUInt16(dosDate)
            output.appendUInt32(c.crc)
            output.appendUInt32(c.size)          // compressed
            output.appendUInt32(c.size)          // uncompressed
            output.appendUInt16(UInt16(nameBytes.count))
            output.appendUInt16(0)               // extra
            output.appendUInt16(0)               // comment
            output.appendUInt16(0)               // disk number start
            output.appendUInt16(0)               // internal attrs
            output.appendUInt32(0)               // external attrs
            output.appendUInt32(c.offset)
            output.append(contentsOf: nameBytes)
        }
        let cdSize = UInt32(output.count) - cdOffset

        // end of central directory
        output.appendUInt32(0x06054b50)
        output.appendUInt16(0)                   // disk number
        output.appendUInt16(0)                   // disk with cd
        output.appendUInt16(UInt16(central.count))
        output.appendUInt16(UInt16(central.count))
        output.appendUInt32(cdSize)
        output.appendUInt32(cdOffset)
        output.appendUInt16(0)                   // comment length
        return output
    }

    private func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let year = max(1980, c.year ?? 1980)
        let month = max(1, min(12, c.month ?? 1))
        let day = max(1, min(31, c.day ?? 1))
        let hour = c.hour ?? 0
        let minute = c.minute ?? 0
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        let dosTime = UInt16((hour << 11) | (minute << 5))
        return (dosDate, dosTime)
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendUInt16(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
    }
    mutating func appendUInt32(_ v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 24) & 0xFF))
    }
}
