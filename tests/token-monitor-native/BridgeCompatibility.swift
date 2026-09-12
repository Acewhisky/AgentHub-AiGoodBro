import Foundation
@main struct Main {
 static func main() throws {
  let directory = URL(fileURLWithPath: CommandLine.arguments[1])
  var failures = 0
  for name in ["usage", "usage-unavailable", "limits", "limits-unavailable"] {
   do {
    let input = try Data(contentsOf: directory.appendingPathComponent("compat-\(name)-request.json"))
    let output = try Data(contentsOf: directory.appendingPathComponent("compat-\(name)-response.json"))
    let request = try JSONDecoder().decode(TokenMonitorRequest.self, from: input)
    let response = try TokenMonitorResponse.decode(output, request: request)
    print("PASS actual corrected bridge original-upstream JSON native decode \(name)")
    if name == "usage" {
     precondition(response.payload["aggregate"]?["today"]?["totalTokens"]?.double == 33)
     precondition(request.sources.allSatisfy { $0.accountId == nil })
     print("PASS unattributed managed history preserves actual aggregate")
    }
    if name == "limits" {
     for source in request.sources {
      guard let provider = TokenMonitorCodexLimits.select(response, sourceID: source.id, accountID: source.accountId) else {
       failures += 1
       print("FAIL bound limits selector for distinct source and opaque account")
       continue
      }
      _ = try TokenMonitorCodexLimits(provider: provider, sourceID: source.id, accountID: source.accountId!, response: response)
      print("PASS bound original HTTP limits maps primary windows")
     }
    }
   } catch { failures += 1; print("FAIL native interop \(name) category \(String(describing: error))") }
  }
  if failures > 0 { exit(1) }
 }
}
