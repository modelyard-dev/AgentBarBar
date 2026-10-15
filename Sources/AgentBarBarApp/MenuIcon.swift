import AppKit

/// A dedicated 18 pt ledger glyph. The cells have equal weight; status is expressed by shape.
enum MenuIcon {
    static func image(state:String="normal") -> NSImage {
        let image=NSImage(size:NSSize(width:18,height:18),flipped:false){_ in
            NSColor.black.setStroke();NSColor.black.setFill()
            let frame=NSBezierPath(roundedRect:NSRect(x:2,y:2,width:14,height:14),xRadius:2.5,yRadius:2.5);frame.lineWidth=1.4;frame.stroke()
            let spine=NSBezierPath();spine.move(to:NSPoint(x:6,y:2.6));spine.line(to:NSPoint(x:6,y:15.4));spine.move(to:NSPoint(x:9,y:13));spine.line(to:NSPoint(x:13.5,y:13));spine.lineWidth=1.2;spine.lineCapStyle = .round;spine.stroke()
            func dot(_ x:CGFloat,_ y:CGFloat,_ radius:CGFloat=0.9){NSBezierPath(ovalIn:NSRect(x:x-radius,y:y-radius,width:radius*2,height:radius*2)).fill()}
            if state=="error" {
                let cross=NSBezierPath();cross.move(to:NSPoint(x:9.3,y:9.4));cross.line(to:NSPoint(x:13.3,y:4.6));cross.move(to:NSPoint(x:13.3,y:9.4));cross.line(to:NSPoint(x:9.3,y:4.6));cross.lineWidth=1.3;cross.lineCapStyle = .round;cross.stroke()
            } else {
                dot(9.5,9);dot(9.5,5)
                if state=="warning" {
                    let mark=NSBezierPath();mark.move(to:NSPoint(x:13,y:9.5));mark.line(to:NSPoint(x:13,y:7));mark.lineWidth=1.3;mark.lineCapStyle = .round;mark.stroke();dot(13,4.6,0.65)
                } else {
                    dot(13,5)
                    if state=="collecting" {let arc=NSBezierPath();arc.appendArc(withCenter:NSPoint(x:13,y:9),radius:1.1,startAngle:0,endAngle:270,clockwise:false);arc.lineWidth=1;arc.lineCapStyle = .round;arc.stroke()}
                    else{dot(13,9)}
                }
            };return true
        }
        image.isTemplate=true;image.accessibilityDescription="AgentBarBar token ledger";return image
    }
}
