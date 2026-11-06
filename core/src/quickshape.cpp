#include "core/quickshape.h"

#include <algorithm>
#include <cmath>

namespace mc {

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kTwoPi = 2.0 * kPi;

/// Snap step for constrained lines, as Procreate's: 15°.
constexpr double kSnapStep = kPi / 12.0;

/// Spacing of the samples a fitted shape is walked out as. Dense enough that
/// the spline through them adds no visible rounding at a polygon's corners.
constexpr double kSampleStep = 1.5;

/// The speed the generated samples pretend to travel at, so a brush with
/// speed dynamics draws a shape at a moderate, steady speed rather than at
/// whatever the hold implied.
constexpr double kShapeSpeed = 600.0;

struct P {
    double x;
    double y;
};

double length(P a, P b) {
    return std::hypot(b.x - a.x, b.y - a.y);
}

/// Distance from p to the infinite line through a and b.
double lineDistance(P p, P a, P b) {
    const double len = length(a, b);
    if (len < 1e-9) return length(p, a);
    return std::fabs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / len;
}

/// Distance from p to the segment a-b.
double segmentDistance(P p, P a, P b) {
    const double dx = b.x - a.x;
    const double dy = b.y - a.y;
    const double len2 = dx * dx + dy * dy;
    if (len2 < 1e-12) return length(p, a);
    double t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2;
    t = std::clamp(t, 0.0, 1.0);
    return length(p, P{a.x + t * dx, a.y + t * dy});
}

void douglasPeucker(const std::vector<P>& pts, size_t first, size_t last, double epsilon,
                    std::vector<size_t>& keep) {
    double worst = 0.0;
    size_t index = first;
    for (size_t i = first + 1; i < last; ++i) {
        const double d = segmentDistance(pts[i], pts[first], pts[last]);
        if (d > worst) {
            worst = d;
            index = i;
        }
    }
    if (worst > epsilon) {
        douglasPeucker(pts, first, index, epsilon, keep);
        keep.push_back(index);
        douglasPeucker(pts, index, last, epsilon, keep);
    }
}

/// Interior turning angle at b, in radians: 0 is straight on, π a reversal.
double turn(P a, P b, P c) {
    const double h1 = std::atan2(b.y - a.y, b.x - a.x);
    const double h2 = std::atan2(c.y - b.y, c.x - b.x);
    double d = h2 - h1;
    while (d > kPi) d -= kTwoPi;
    while (d < -kPi) d += kTwoPi;
    return std::fabs(d);
}

bool fitEllipse(const std::vector<P>& pts, QuickShape& out) {
    // Principal axes from the covariance of the points, then the centre and
    // radii from the extents along those axes. Extents rather than a
    // least-squares radius, because a hand-drawn ellipse is sampled densely
    // where the hand slowed down, and a mean would be pulled toward there.
    double mx = 0.0, my = 0.0;
    for (const P& p : pts) { mx += p.x; my += p.y; }
    mx /= static_cast<double>(pts.size());
    my /= static_cast<double>(pts.size());
    double sxx = 0.0, syy = 0.0, sxy = 0.0;
    for (const P& p : pts) {
        const double dx = p.x - mx, dy = p.y - my;
        sxx += dx * dx; syy += dy * dy; sxy += dx * dy;
    }
    const double angle = 0.5 * std::atan2(2.0 * sxy, sxx - syy);
    const double c = std::cos(angle), s = std::sin(angle);

    double minU = 1e30, maxU = -1e30, minV = 1e30, maxV = -1e30;
    for (const P& p : pts) {
        const double u = (p.x - mx) * c + (p.y - my) * s;
        const double v = -(p.x - mx) * s + (p.y - my) * c;
        minU = std::min(minU, u); maxU = std::max(maxU, u);
        minV = std::min(minV, v); maxV = std::max(maxV, v);
    }
    const double a = 0.5 * (maxU - minU);
    const double b = 0.5 * (maxV - minV);
    if (a < 3.0 || b < 3.0) return false;
    const double cu = 0.5 * (maxU + minU);
    const double cv = 0.5 * (maxV + minV);

    double meanError = 0.0, maxError = 0.0;
    for (const P& p : pts) {
        const double u = (p.x - mx) * c + (p.y - my) * s - cu;
        const double v = -(p.x - mx) * s + (p.y - my) * c - cv;
        const double r = std::sqrt((u / a) * (u / a) + (v / b) * (v / b));
        const double e = std::fabs(r - 1.0);
        meanError += e;
        maxError = std::max(maxError, e);
    }
    meanError /= static_cast<double>(pts.size());
    if (meanError > 0.07 || maxError > 0.2) return false;

    out.kind = ShapeKind::Ellipse;
    out.closed = true;
    out.cx = static_cast<float>(mx + cu * c - cv * s);
    out.cy = static_cast<float>(my + cu * s + cv * c);
    out.rx = static_cast<float>(a);
    out.ry = static_cast<float>(b);
    out.rotation = static_cast<float>(angle);
    // Where the hand began, as an angle in the ellipse's own frame.
    const double u0 = (pts.front().x - out.cx) * c + (pts.front().y - out.cy) * s;
    const double v0 = -(pts.front().x - out.cx) * s + (pts.front().y - out.cy) * c;
    out.start = static_cast<float>(std::atan2(v0 / b, u0 / a));
    return true;
}

bool fitArc(const std::vector<P>& pts, double diagonal, QuickShape& out) {
    // Kåsa's algebraic circle fit, on coordinates centred at the mean for
    // numerical sanity: minimise the sum of (x² + y² + Dx + Ey + F)².
    double mx = 0.0, my = 0.0;
    for (const P& p : pts) { mx += p.x; my += p.y; }
    mx /= static_cast<double>(pts.size());
    my /= static_cast<double>(pts.size());

    double suu = 0, svv = 0, suv = 0, suuu = 0, svvv = 0, suvv = 0, svuu = 0;
    for (const P& p : pts) {
        const double u = p.x - mx, v = p.y - my;
        suu += u * u; svv += v * v; suv += u * v;
        suuu += u * u * u; svvv += v * v * v;
        suvv += u * v * v; svuu += v * u * u;
    }
    // Solve [suu suv; suv svv] [uc; vc] = 0.5 [suuu + suvv; svvv + svuu].
    const double det = suu * svv - suv * suv;
    if (std::fabs(det) < 1e-9) return false;
    const double r1 = 0.5 * (suuu + suvv);
    const double r2 = 0.5 * (svvv + svuu);
    const double uc = (r1 * svv - r2 * suv) / det;
    const double vc = (suu * r2 - suv * r1) / det;
    const double n = static_cast<double>(pts.size());
    const double radius = std::sqrt(uc * uc + vc * vc + (suu + svv) / n);
    if (!(radius > 3.0) || radius > 4.0 * diagonal) return false;

    const P centre{uc + mx, vc + my};
    double meanError = 0.0, maxError = 0.0;
    for (const P& p : pts) {
        const double e = std::fabs(length(p, centre) - radius) / radius;
        meanError += e;
        maxError = std::max(maxError, e);
    }
    meanError /= n;
    if (meanError > 0.04 || maxError > 0.1) return false;

    // Signed sweep, unwrapped point to point.
    double sweep = 0.0;
    double previous = std::atan2(pts.front().y - centre.y, pts.front().x - centre.x);
    const double first = previous;
    for (size_t i = 1; i < pts.size(); ++i) {
        const double a = std::atan2(pts[i].y - centre.y, pts[i].x - centre.x);
        double d = a - previous;
        while (d > kPi) d -= kTwoPi;
        while (d < -kPi) d += kTwoPi;
        sweep += d;
        previous = a;
    }
    // A sliver of an arc is a line drawn unsteadily; nearly a full turn is an
    // ellipse that did not close, and the closed test has already had it.
    const double degrees = std::fabs(sweep) * 180.0 / kPi;
    if (degrees < 15.0 || degrees > 330.0) return false;

    out.kind = ShapeKind::Arc;
    out.cx = static_cast<float>(centre.x);
    out.cy = static_cast<float>(centre.y);
    out.rx = out.ry = static_cast<float>(radius);
    out.start = static_cast<float>(first);
    out.sweep = static_cast<float>(sweep);
    return true;
}

bool fitPolyline(const std::vector<P>& pts, double diagonal, bool closed, QuickShape& out) {
    const double epsilon = std::max(3.0, 0.035 * diagonal);
    std::vector<size_t> keep{0};
    douglasPeucker(pts, 0, pts.size() - 1, epsilon, keep);
    keep.push_back(pts.size() - 1);
    std::sort(keep.begin(), keep.end());

    std::vector<P> corners;
    for (size_t i : keep) corners.push_back(pts[i]);
    if (closed) {
        // The last point returns to the first; the polygon closes itself.
        corners.back() = corners.front();
        corners.pop_back();
    }
    const size_t n = corners.size();
    if (n < 3 || n > static_cast<size_t>(QuickShape::kMaxVertices)) return false;

    // A smooth curve simplifies to a few vertices too, but its turns are
    // shallow. A polygon is drawn with corners, and that is what tells them
    // apart.
    const double minimumTurn = 35.0 * kPi / 180.0;
    const size_t interiorFrom = closed ? 0 : 1;
    const size_t interiorTo = closed ? n : n - 1;
    for (size_t i = interiorFrom; i < interiorTo; ++i) {
        const P& a = corners[(i + n - 1) % n];
        const P& b = corners[i];
        const P& c = corners[(i + 1) % n];
        if (turn(a, b, c) < minimumTurn) return false;
    }

    out.kind = ShapeKind::Polyline;
    out.closed = closed;
    out.vertexCount = static_cast<int32_t>(n);
    for (size_t i = 0; i < n; ++i) {
        out.vx[i] = static_cast<float>(corners[i].x);
        out.vy[i] = static_cast<float>(corners[i].y);
    }
    return true;
}

double snapAngle(double angle) {
    return std::round(angle / kSnapStep) * kSnapStep;
}

void appendSegment(std::vector<StrokeSample>& out, P a, P b, const StrokeSample& prototype,
                   double& time, bool includeStart) {
    const double len = length(a, b);
    const int steps = std::max(1, static_cast<int>(std::ceil(len / kSampleStep)));
    for (int i = includeStart ? 0 : 1; i <= steps; ++i) {
        const double t = static_cast<double>(i) / steps;
        StrokeSample s = prototype;
        s.x = static_cast<float>(a.x + (b.x - a.x) * t);
        s.y = static_cast<float>(a.y + (b.y - a.y) * t);
        if (i > 0) time += len / steps / kShapeSpeed;
        s.timestamp = time;
        out.push_back(s);
    }
}

}  // namespace

QuickShape detectShape(const std::vector<StrokeSample>& samples) {
    QuickShape out;
    if (samples.size() < 2) return out;

    std::vector<P> pts;
    pts.reserve(samples.size());
    double pressure = 0.0, tilt = 0.0;
    for (const StrokeSample& s : samples) {
        pts.push_back(P{s.x, s.y});
        pressure += s.pressure;
        tilt += s.tilt;
    }
    out.pressure = static_cast<float>(pressure / static_cast<double>(samples.size()));
    out.tilt = static_cast<float>(tilt / static_cast<double>(samples.size()));

    double travelled = 0.0;
    double minX = pts[0].x, maxX = pts[0].x, minY = pts[0].y, maxY = pts[0].y;
    for (size_t i = 1; i < pts.size(); ++i) {
        travelled += length(pts[i - 1], pts[i]);
        minX = std::min(minX, pts[i].x); maxX = std::max(maxX, pts[i].x);
        minY = std::min(minY, pts[i].y); maxY = std::max(maxY, pts[i].y);
    }
    const double diagonal = std::hypot(maxX - minX, maxY - minY);
    if (travelled < 12.0 || diagonal < 8.0) return out;

    const P first = pts.front();
    const P last = pts.back();
    const double chord = length(first, last);

    // A line: every point close to the chord, and the path never doubled back
    // on itself — a scribble along one line is not a line. Doubling back is
    // measured as progress *against* the chord's direction, not as total path
    // length against chord: a hand's sample-to-sample tremor adds path length
    // without going anywhere, and would reject every honest line.
    double backwards = 0.0;
    if (chord > 1e-6) {
        const double ux = (last.x - first.x) / chord, uy = (last.y - first.y) / chord;
        for (size_t i = 1; i < pts.size(); ++i) {
            const double along = (pts[i].x - pts[i - 1].x) * ux + (pts[i].y - pts[i - 1].y) * uy;
            if (along < 0.0) backwards -= along;
        }
    }
    if (chord > 0.0 && backwards <= 0.1 * chord) {
        const double tolerance = std::max(2.5, 0.04 * chord);
        double worst = 0.0;
        for (const P& p : pts) worst = std::max(worst, lineDistance(p, first, last));
        if (worst <= tolerance) {
            out.kind = ShapeKind::Line;
            out.vertexCount = 2;
            out.vx[0] = static_cast<float>(first.x);
            out.vy[0] = static_cast<float>(first.y);
            out.vx[1] = static_cast<float>(last.x);
            out.vy[1] = static_cast<float>(last.y);
            return out;
        }
    }

    // Closed: ends near the start, having gone round rather than out and back.
    const bool closed = chord <= std::max(10.0, 0.25 * diagonal) && travelled >= 2.0 * diagonal;
    if (closed) {
        if (fitEllipse(pts, out)) return out;
        if (fitPolyline(pts, diagonal, true, out)) return out;
        return QuickShape{};
    }

    if (fitArc(pts, diagonal, out)) return out;
    if (fitPolyline(pts, diagonal, false, out)) return out;
    return QuickShape{};
}

void constrainShape(QuickShape& shape) {
    switch (shape.kind) {
    case ShapeKind::Line: {
        const double dx = shape.vx[1] - shape.vx[0];
        const double dy = shape.vy[1] - shape.vy[0];
        const double len = std::hypot(dx, dy);
        const double angle = snapAngle(std::atan2(dy, dx));
        shape.vx[1] = static_cast<float>(shape.vx[0] + len * std::cos(angle));
        shape.vy[1] = static_cast<float>(shape.vy[0] + len * std::sin(angle));
        break;
    }
    case ShapeKind::Ellipse: {
        const float r = 0.5f * (shape.rx + shape.ry);
        // The start angle is a parameter on the old ellipse; on the circle the
        // same parameter is the same direction, near enough for a seam.
        shape.rx = shape.ry = r;
        shape.rotation = 0.0f;
        break;
    }
    default:
        break;
    }
}

void moveShapeEnd(QuickShape& shape, float x, float y, bool constrained) {
    if (shape.kind != ShapeKind::Line) return;
    shape.vx[1] = x;
    shape.vy[1] = y;
    if (constrained) constrainShape(shape);
}

std::vector<StrokeSample> shapeSamples(const QuickShape& shape, double startTime,
                                       bool fromPressureDevice) {
    std::vector<StrokeSample> out;
    StrokeSample prototype;
    prototype.pressure = shape.pressure;
    prototype.tilt = shape.tilt;
    prototype.fromPressureDevice = fromPressureDevice;
    double time = startTime;

    switch (shape.kind) {
    case ShapeKind::None:
        break;

    case ShapeKind::Line:
        appendSegment(out, P{shape.vx[0], shape.vy[0]}, P{shape.vx[1], shape.vy[1]},
                      prototype, time, true);
        break;

    case ShapeKind::Polyline: {
        const int n = shape.vertexCount;
        const int segments = shape.closed ? n : n - 1;
        for (int i = 0; i < segments; ++i) {
            const int j = (i + 1) % n;
            appendSegment(out, P{shape.vx[i], shape.vy[i]}, P{shape.vx[j], shape.vy[j]},
                          prototype, time, i == 0);
        }
        break;
    }

    case ShapeKind::Arc:
    case ShapeKind::Ellipse: {
        const bool ellipse = shape.kind == ShapeKind::Ellipse;
        const double c = std::cos(shape.rotation), s = std::sin(shape.rotation);
        // Ramanujan's perimeter, only to choose a step count.
        const double a = shape.rx, b = shape.ry;
        // A degenerate shape from a caller would divide by zero below.
        // detectShape never makes one; the ABI can be handed anything.
        if (!(a > 1e-3) || !(b > 1e-3)) break;
        const double h = ((a - b) * (a - b)) / ((a + b) * (a + b));
        const double perimeter = kPi * (a + b) * (1.0 + 3.0 * h / (10.0 + std::sqrt(4.0 - 3.0 * h)));
        // An ellipse goes a little past its start so the seam overlaps rather
        // than leaving a notch where the two ends meet.
        const double sweep = ellipse ? kTwoPi * (1.0 + 3.0 / std::max(perimeter, 1.0))
                                     : static_cast<double>(shape.sweep);
        const double travel = perimeter * std::fabs(sweep) / kTwoPi;
        const int steps = std::max(2, static_cast<int>(std::ceil(travel / kSampleStep)));
        for (int i = 0; i <= steps; ++i) {
            const double t = shape.start + sweep * static_cast<double>(i) / steps;
            const double u = a * std::cos(t), v = b * std::sin(t);
            StrokeSample sample = prototype;
            sample.x = static_cast<float>(shape.cx + u * c - v * s);
            sample.y = static_cast<float>(shape.cy + u * s + v * c);
            if (i > 0) time += travel / steps / kShapeSpeed;
            sample.timestamp = time;
            out.push_back(sample);
        }
        break;
    }
    }
    return out;
}

}  // namespace mc
