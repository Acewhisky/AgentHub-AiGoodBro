let tool: [String:Int] = ["codex":60,"claude":40]
let model: [String:Int] = ["gpt":70,"deepseek":30]
let all = UsageSurfaceProjector.project(toolTokens:tool,modelTokens:model,dimension:nil,query:"",sharesAreComparable:true)
precondition(all.rows.first(where:{$0.id=="tool:codex"})!.share == 0.6)
precondition(all.rows.first(where:{$0.id=="model:gpt"})!.share == 0.7)
let filtered = UsageSurfaceProjector.project(toolTokens:tool,modelTokens:model,dimension:"tool",query:"codex",sharesAreComparable:true)
precondition(filtered.rows.count==1 && filtered.rows[0].share == 0.6)
let zero = UsageSurfaceProjector.project(toolTokens:["zero":0],modelTokens:model,dimension:"tool",query:"",sharesAreComparable:true)
precondition(zero.rows[0].share == nil)
let large = UsageSurfaceProjector.project(toolTokens:["a":Int.max,"b":Int.max],modelTokens:[:],dimension:"tool",query:"",sharesAreComparable:true)
precondition(large.rows.allSatisfy{$0.share == 0.5})
print("PASS: independent dimension totals, filters, zero and large sums")

let unverified = UsageSurfaceProjector.project(toolTokens:tool,modelTokens:model,dimension:nil,query:"")
precondition(unverified.rows.allSatisfy{$0.share == nil})
print("PASS: unverified overlap hides shares")
