//! Physical coordinates only. Convert desired DIP once using anchor monitor DPI.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}
pub fn popup(anchor: Rect, work: Rect, scale: f64) -> Rect {
    popup_sized(anchor, work, scale, 367.)
}
pub fn popup_sized(anchor: Rect, work: Rect, scale: f64, height: f64) -> Rect {
    let gap = (8. * scale).round() as i32;
    let w = (320. * scale).round() as i32;
    let h = (height.clamp(220., 720.) * scale).round() as i32;
    let w = w.min(work.w);
    let h = h.min(work.h);
    let x = (anchor.x + anchor.w - w).clamp(work.x, work.x + work.w - w);
    let mut y = anchor.y - h - gap;
    if anchor.y < work.y + work.h / 2 {
        y = anchor.y + anchor.h + gap
    }
    Rect {
        x,
        y: y.clamp(work.y, work.y + work.h - h),
        w,
        h,
    }
}
pub fn visible(r: Rect, work: Rect) -> Rect {
    let w = r.w.clamp(640, work.w.max(640)).min(work.w);
    let h = r.h.clamp(480, work.h.max(480)).min(work.h);
    Rect {
        x: r.x.clamp(work.x, work.x + work.w - w),
        y: r.y.clamp(work.y, work.y + work.h - h),
        w,
        h,
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn all_dpis_and_edges() {
        for scale in [1., 1.25, 1.5, 1.75, 2.] {
            for work in [
                Rect {
                    x: 0,
                    y: 0,
                    w: 1920,
                    h: 1040,
                },
                Rect {
                    x: -1920,
                    y: 0,
                    w: 1920,
                    h: 1040,
                },
            ] {
                for anchor in [
                    Rect {
                        x: work.x + work.w - 40,
                        y: 1040,
                        w: 24,
                        h: 24,
                    },
                    Rect {
                        x: work.x + 40,
                        y: 0,
                        w: 24,
                        h: 24,
                    },
                    Rect {
                        x: work.x - 40,
                        y: 500,
                        w: 24,
                        h: 24,
                    },
                    Rect {
                        x: work.x + work.w,
                        y: 500,
                        w: 24,
                        h: 24,
                    },
                ] {
                    let r = popup(anchor, work, scale);
                    assert!(
                        r.x >= work.x
                            && r.y >= work.y
                            && r.x + r.w <= work.x + work.w
                            && r.y + r.h <= work.y + work.h
                    )
                }
            }
        }
    }
    #[test]
    fn removed_monitor_clamps() {
        assert_eq!(
            visible(
                Rect {
                    x: -5000,
                    y: 5000,
                    w: 3000,
                    h: 2000
                },
                Rect {
                    x: 0,
                    y: 0,
                    w: 1920,
                    h: 1040
                }
            ),
            Rect {
                x: 0,
                y: 0,
                w: 1920,
                h: 1040
            }
        )
    }
}
