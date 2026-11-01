import AppKit
import SwiftMath

func now() -> Double {
    var t = mach_timebase_info_data_t(); mach_timebase_info(&t)
    return Double(mach_absolute_time()) * Double(t.numer) / Double(t.denom) / 1e6
}

let cases: [(String, String)] = [
    ("fraction", #"\frac{a+b}{c}"#), ("sqrt", #"\sqrt{x^2+y^2}"#), ("nth root", #"\sqrt[3]{x}"#),
    ("sum limits", #"\sum_{i=1}^{n} i^2 = \frac{n(n+1)(2n+1)}{6}"#), ("integral", #"\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}"#),
    ("greek", #"\alpha+\beta+\gamma+\Delta+\Omega"#), ("left right", #"\left( \frac{a}{b} \right)"#),
    ("pmatrix", #"\begin{pmatrix} a & b \\ c & d \end{pmatrix}"#), ("bmatrix", #"\begin{bmatrix} 1 & 0 \\ 0 & 1 \end{bmatrix}"#),
    ("cases", #"f(x)=\begin{cases} x & x>0 \\ 0 & x\le 0 \end{cases}"#),
    ("aligned", #"\begin{aligned} a &= b+c \\ d &= e \end{aligned}"#), ("align*", #"\begin{align*} a &= b \\ c &= d \end{align*}"#),
    ("mathbb", #"\mathbb{R}^n"#), ("mathcal", #"\mathcal{L}"#), ("mathbf", #"\mathbf{x}"#), ("text", #"x \text{ if } y"#),
    ("binom", #"\binom{n}{k}"#), ("overline", #"\overline{AB}"#), ("hat vec", #"\hat{x}+\vec{v}"#),
    ("underbrace", #"\underbrace{a+b}_{n}"#), ("lim", #"\lim_{x\to 0}\frac{\sin x}{x}=1"#),
    ("operatorname", #"\operatorname{argmax}_x f(x)"#), ("boxed", #"\boxed{E=mc^2}"#), ("cdots", #"a_1,\ldots,a_n,\cdots"#),
    ("dots arrows", #"A \rightarrow B \Longleftrightarrow C"#), ("color", #"\color{red}{x}"#),
    ("tag", #"E=mc^2 \tag{1}"#), ("newcommand", #"\newcommand{\R}{\mathbb{R}} \R"#), ("mhchem", #"\ce{H2O}"#),
    ("xrightarrow", #"\xrightarrow{f}"#), ("substack", #"\sum_{\substack{i<n \\ j<m}} a_{ij}"#),
    ("array", #"\begin{array}{cc} 1 & 2 \\ 3 & 4 \end{array}"#), ("not equal", #"a \neq b \approx c \equiv d"#),
    ("norm", #"\lVert x \rVert"#), ("dfrac", #"\dfrac{1}{2}"#), ("mod", #"a \pmod{n}"#), ("cancel", #"\cancel{x}"#),
    ("sin cos", #"\sin\theta\cos\theta"#), ("braces", #"\{ x \mid x>0 \}"#), ("prime", #"f'(x)"#),
]

var ok = 0; var failed: [String] = []
let rssBefore = ProcessInfo.processInfo.physicalMemory // unused, placeholder
for (name, tex) in cases {
    var err: NSError?
    if MTMathListBuilder.build(fromString: tex, error: &err) != nil { ok += 1 } else { failed.append("\(name): \(tex)  (\(err?.localizedDescription ?? "?"))") }
}
print("native (SwiftMath) coverage: \(ok)/\(cases.count) parse")
for f in failed { print("  UNSUPPORTED \(f)") }

var times: [Double] = []
for (_, tex) in cases {
    var err: NSError?
    guard MTMathListBuilder.build(fromString: tex, error: &err) != nil else { continue }
    let t = now()
    let img = MTMathImage(latex: tex, fontSize: 18, textColor: .black, labelMode: .text, textAlignment: .left)
    let (_, nsimg) = img.asImage()
    times.append(now() - t)
    _ = nsimg
}
times.sort()
print(String(format: "render to image (first call includes font load): first %.1f ms, p50 %.2f ms, p99/max %.2f ms", times.first!, times[times.count / 2], times.last!))
