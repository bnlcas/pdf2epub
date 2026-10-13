#!/usr/bin/env swift
// Copies selected pages of a PDF (text layer included) into a new PDF, to make smaller
// test excerpts of long books.
//
//   swift Scripts/excerpt-pdf.swift book.pdf excerpt.pdf 1-60,296-305
//
// Page numbers are 1-based PDF pages (not printed page numbers).
import Foundation
import PDFKit

let args = CommandLine.arguments
guard args.count == 4, let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else {
    print("usage: excerpt-pdf.swift <in.pdf> <out.pdf> <ranges, e.g. 1-60,296-305>")
    exit(1)
}
let out = PDFDocument()
for part in args[3].split(separator: ",") {
    let ends = part.split(separator: "-").compactMap { Int($0) }
    guard let lo = ends.first else { continue }
    for n in lo...(ends.last ?? lo) where n >= 1 && n <= doc.pageCount {
        if let page = doc.page(at: n - 1)?.copy() as? PDFPage { out.insert(page, at: out.pageCount) }
    }
}
out.documentAttributes = doc.documentAttributes
guard out.write(to: URL(fileURLWithPath: args[2])) else { print("could not write \(args[2])"); exit(1) }
print("wrote \(out.pageCount) pages to \(args[2])")
