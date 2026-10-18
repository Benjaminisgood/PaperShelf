import Foundation
import CoreGraphics
import PaperCore

@main
struct ServerHarness {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let trusted = directory.appendingPathComponent("trusted",isDirectory:true)
        try FileManager.default.createDirectory(at:trusted,withIntermediateDirectories:true)
        var box = CGRect(x:0,y:0,width:200,height:200)
        let pdf = CGContext(trusted.appendingPathComponent("fixture.pdf") as CFURL,mediaBox:&box,nil)!
        pdf.beginPDFPage(nil); pdf.endPDFPage(); pdf.closePDF()
        var references = [Reference(id:UUID(uuidString:"00000000-0000-4000-8000-000000000001")!,title:"API Fixture",authors:["Doe, Jane"],year:"2024",doi:"10.1234/fixture",abstract:"Full abstract",notes:"User notes",isRead:true,isFavorite:true,citationKey:"Doe2024",extraFields:["custom":"keep"],rating:5)]
        let server = LocalAPIServer(storageDirectory:directory,snapshot:{ LocalAPISnapshot(references:references,collections:[],tags:[]) },save:{ value in
            references.removeAll { $0.id == value.id }; references.append(value); return true
        })
        try server.start(configuration:LocalAPIConfiguration(enabled:true,port:0,readOnly:CommandLine.arguments[2] == "readonly",trustedFolders:[trusted.path],allowedOrigins:["https://localhost:3456"]))
        while !Task.isCancelled { try await Task.sleep(nanoseconds:1_000_000_000) }
        server.stop()
    }
}
