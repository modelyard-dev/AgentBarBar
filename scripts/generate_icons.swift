import AppKit
import Foundation

let root=URL(fileURLWithPath:CommandLine.arguments.count>1 ? CommandLine.arguments[1]:FileManager.default.currentDirectoryPath)
let assets=root.appendingPathComponent("assets")
let concepts=assets.appendingPathComponent("concepts")
let appset=assets.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at:concepts,withIntermediateDirectories:true)
try FileManager.default.createDirectory(at:appset,withIntermediateDirectories:true)

func color(_ hex:UInt32) -> NSColor {NSColor(srgbRed:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:1)}
func render(_ size:Int,draw:() -> Void) -> NSBitmapImageRep {
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSGraphicsContext.current?.cgContext.scaleBy(x:CGFloat(size)/1024,y:CGFloat(size)/1024)
    draw();NSGraphicsContext.restoreGraphicsState();return bitmap
}
func draw(_ concept:Int) {
    let background=NSBezierPath(roundedRect:NSRect(x:74,y:74,width:876,height:876),xRadius:194,yRadius:194)
    NSGraphicsContext.saveGraphicsState();let shadow=NSShadow();shadow.shadowColor=NSColor.black.withAlphaComponent(0.2);shadow.shadowBlurRadius=26;shadow.shadowOffset=NSSize(width:0,height:-10);shadow.set()
    color(0x2c3530).setFill();background.fill();NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.1).setStroke();background.lineWidth=3;background.stroke()
    color(0xe4ebe2).setFill()
    if concept==0 {
        // Token ledger: a book spine, header and equal token cells; no rising bars.
        NSBezierPath(roundedRect:NSRect(x:290,y:228,width:444,height:568),xRadius:68,yRadius:68).fill()
        color(0x2c3530).setFill()
        NSRect(x:398,y:228,width:28,height:568).fill()
        NSBezierPath(roundedRect:NSRect(x:470,y:662,width:168,height:32),xRadius:16,yRadius:16).fill()
        for x in [502.0,634.0] {for y in [390.0,534.0] {NSBezierPath(ovalIn:NSRect(x:x-35,y:y-35,width:70,height:70)).fill()}}
    } else if concept==1 {
        // Token orbit: connected equal cells.
        let line=NSBezierPath();line.move(to:NSPoint(x:350,y:650));line.line(to:NSPoint(x:674,y:650));line.line(to:NSPoint(x:674,y:374));line.line(to:NSPoint(x:350,y:374));line.close();line.lineWidth=28;color(0xe4ebe2).setStroke();line.stroke()
        for x in [350.0,674.0] {for y in [374.0,650.0] {NSBezierPath(roundedRect:NSRect(x:x-75,y:y-75,width:150,height:150),xRadius:38,yRadius:38).fill()}}
    } else {
        // Layered receipt: a square stack with one perforated token.
        NSBezierPath(roundedRect:NSRect(x:252,y:302,width:450,height:450),xRadius:80,yRadius:80).fill()
        color(0x2c3530).setFill();NSBezierPath(roundedRect:NSRect(x:306,y:356,width:342,height:342),xRadius:35,yRadius:35).fill()
        color(0xe4ebe2).setFill();NSBezierPath(roundedRect:NSRect(x:400,y:212,width:374,height:374),xRadius:80,yRadius:80).fill()
        color(0x2c3530).setFill();NSBezierPath(ovalIn:NSRect(x:537,y:349,width:100,height:100)).fill()
    }
}
var images:[NSImage]=[]
for i in 0..<3 {
    let bitmap=render(1024){draw(i)};try bitmap.representation(using:.png,properties:[:])!.write(to:concepts.appendingPathComponent("concept-\(i+1).png"))
    let image=NSImage(size:NSSize(width:1024,height:1024));image.addRepresentation(bitmap);images.append(image)
}
let board=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1080,pixelsHigh:660,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:board)
color(0xf5f6f5).setFill();NSRect(x:0,y:0,width:1080,height:660).fill()
let names=["01 / Token ledger · Selected","02 / Token orbit","03 / Layered receipt"]
for i in 0..<3 {
    let x=CGFloat(i)*360+40
    images[i].draw(in:NSRect(x:x,y:300,width:280,height:280))
    (names[i] as NSString).draw(at:NSPoint(x:x+10,y:260),withAttributes:[.font:NSFont.systemFont(ofSize:17,weight:.medium),.foregroundColor:color(0x333d36)])
    for (j,bg) in [color(0xffffff),color(0x202723)].enumerated() {
        bg.setFill();NSBezierPath(roundedRect:NSRect(x:x,y:130-CGFloat(j)*70,width:280,height:58),xRadius:6,yRadius:6).fill()
        images[i].draw(in:NSRect(x:x+20,y:144-CGFloat(j)*70,width:32,height:32))
        images[i].draw(in:NSRect(x:x+75,y:152-CGFloat(j)*70,width:16,height:16))
        ((j==0 ? "32px / 16px · Light":"32px / 16px · Dark") as NSString).draw(at:NSPoint(x:x+115,y:151-CGFloat(j)*70),withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:j==0 ? color(0x46534b):color(0xe4ebe5)])
    }
}
NSGraphicsContext.restoreGraphicsState();try board.representation(using:.png,properties:[:])!.write(to:concepts.appendingPathComponent("comparison.png"))

var entries:[[String:String]]=[]
let iconset=assets.appendingPathComponent("AgentBarBar.iconset")
try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
for base in [16,32,128,256,512] {
    for scale in [1,2] {
        let filename="icon_\(base)x\(base)\(scale==2 ? "@2x":"").png"
        let bitmap=render(base*scale){draw(0)};let data=bitmap.representation(using:.png,properties:[:])!
        try data.write(to:appset.appendingPathComponent(filename));try data.write(to:iconset.appendingPathComponent(filename))
        entries.append(["size":"\(base)x\(base)","scale":"\(scale)x","idiom":"mac","filename":filename])
    }
}
let content:[String:Any]=["images":entries,"info":["author":"AgentBarBar","version":1]]
try JSONSerialization.data(withJSONObject:content,options:[.prettyPrinted,.sortedKeys]).write(to:appset.appendingPathComponent("Contents.json"))
print("Generated three non-signal concepts, comparison board, Token Ledger AppIcon assets and iconset.")
