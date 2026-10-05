// integrity_signals.swift — local, no-AI capture-integrity signal extractor (C4L-A).
//
// For one video, samples K evenly-spaced frames (small grayscale) and computes three
// cheap signals that a device can compute at capture with no model, no network:
//   mean_luma        : average brightness 0..255 (exposure proxy)
//   p_dark / p_bright: fraction of frames whose mean luma is <DARK or >BRIGHT
//   luma_shift       : mean absolute inter-frame luma change 0..1 (shake/motion proxy)
//   sharpness        : min / median variance-of-Laplacian across frames (focus proxy)
// Prints one JSON object. ffmpeg/pyav unavailable in-sandbox -> AVFoundation.
//
// This tool ONLY measures. Adoption thresholds and the accept/reject decision live in
// the Python harness so the decision is inspectable and tunable from the distributions.

import Foundation
import AVFoundation
import CoreGraphics

func die(_ m: String) -> Never { FileHandle.standardError.write((m+"\n").data(using:.utf8)!); exit(2) }
let args = CommandLine.arguments
guard args.count >= 2 else { die("usage: integrity_signals <input> [k=8]") }
let input = args[1]
let k = args.count > 2 ? (Int(args[2]) ?? 8) : 8

let asset = AVURLAsset(url: URL(fileURLWithPath: input))
let dur = CMTimeGetSeconds(asset.duration)
guard dur.isFinite && dur > 0 else { die("bad duration") }

let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
gen.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
gen.maximumSize = CGSize(width: 160, height: 160)

var times: [Double] = []
if k == 1 { times = [dur/2] } else { for i in 0..<k { times.append(dur*Double(i)/Double(k-1)) } }

func gray(_ cg: CGImage) -> ([Float],Int,Int) {
    let w=cg.width,h=cg.height; var px=[UInt8](repeating:0,count:w*h)
    let cs=CGColorSpaceCreateDeviceGray()
    guard let ctx=CGContext(data:&px,width:w,height:h,bitsPerComponent:8,bytesPerRow:w,space:cs,bitmapInfo:CGImageAlphaInfo.none.rawValue) else {return([],0,0)}
    ctx.draw(cg,in:CGRect(x:0,y:0,width:w,height:h))
    return (px.map{Float($0)},w,h)
}
func meanL(_ g:[Float])->Double{ g.isEmpty ?0:Double(g.reduce(0,+))/Double(g.count) }
func diff(_ a:[Float],_ b:[Float])->Double{
    guard a.count==b.count, !a.isEmpty else {return 0}
    var s=0.0; for i in 0..<a.count{ s+=Double(abs(a[i]-b[i])) }
    return (s/Double(a.count))/255.0
}
func lapVar(_ g:[Float],_ w:Int,_ h:Int)->Double{
    guard w>2,h>2 else {return 0}
    var v:[Double]=[]; v.reserveCapacity((w-2)*(h-2))
    for y in 1..<(h-1){ for x in 1..<(w-1){
        let c=Double(g[y*w+x])
        v.append(4*c-Double(g[y*w+x-1])-Double(g[y*w+x+1])-Double(g[(y-1)*w+x])-Double(g[(y+1)*w+x]))
    }}
    let m=v.reduce(0,+)/Double(v.count)
    return v.reduce(0){$0+($1-m)*($1-m)}/Double(v.count)
}

var lumas:[Double]=[], shifts:[Double]=[], sharps:[Double]=[]
var prev:[Float]?=nil
let t0=ProcessInfo.processInfo.systemUptime
for t in times{
    guard let cg=try? gen.copyCGImage(at:CMTime(seconds:t,preferredTimescale:600),actualTime:nil) else {continue}
    let (g,w,h)=gray(cg); if g.isEmpty{continue}
    lumas.append(meanL(g)); sharps.append(lapVar(g,w,h))
    if let p=prev{ shifts.append(diff(p,g)) }
    prev=g
}
let cpuMs=(ProcessInfo.processInfo.systemUptime-t0)*1000
func med(_ xs:[Double])->Double{ xs.isEmpty ?0:xs.sorted()[xs.count/2] }
let DARK=35.0, BRIGHT=225.0
let pDark=lumas.isEmpty ?0:Double(lumas.filter{$0<DARK}.count)/Double(lumas.count)
let pBright=lumas.isEmpty ?0:Double(lumas.filter{$0>BRIGHT}.count)/Double(lumas.count)
let obj:[String:Any]=[
  "input":(input as NSString).lastPathComponent, "duration_s":dur, "frames":lumas.count,
  "mean_luma":med(lumas), "min_luma":lumas.min() ?? 0, "max_luma":lumas.max() ?? 0,
  "p_dark":pDark, "p_bright":pBright,
  "luma_shift_mean":shifts.isEmpty ?0:shifts.reduce(0,+)/Double(shifts.count),
  "luma_shift_max":shifts.max() ?? 0,
  "sharpness_median":med(sharps), "sharpness_min":sharps.min() ?? 0,
  "cpu_ms":cpuMs,
]
print(String(data:try JSONSerialization.data(withJSONObject:obj,options:[.sortedKeys]),encoding:.utf8)!)
